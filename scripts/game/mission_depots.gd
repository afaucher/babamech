class_name MissionDepots
extends Node
## Military supply depots in a plan-mode mission (docs/design/pacing-director.md §2). Child "MissionDepots" of
## MissionFlow, on every machine, built in MissionFlow.rebuild from `plan.depots`.
##
## SHAPE: host-arbitrated world object (AGENTS rule 6). The pilot's machine asks, the host decides, the mech's owner
## applies the effect on its own mech (rule 2).
##   PLACE (every machine, plan data + the snap rule only): each plan depot snaps to clear ground like a flag site
##     (MissionProps.snap_site, reach plan `snap`, clear DEPOT_CLEAR, keeping clear of the snapped flag masts / relays and
##     the deck's other depot) and a SupplyDepot (look, collision, DepotTarget) goes under its deck's CityDistrict.
##   CORES: cores_max = plan cores (1 per pilot) x the crew at mission start, at least MissionPlan.DEPOT_CORES_MIN (2) (the launch's crew: the same on every
##     machine); the host then decides `cores_left` / `alive`, which ride in mission.state as "depots":
##     {id: [cores_left, alive 0 | 1]} (state / apply_state), so a barrier latecomer starts from them.
##   CLAIM (this machine's own pilot): standing (PlayerTarget not disabled) within CLAIM_RANGE of a live depot's
##     footprint that has cores, for CLAIM_TIME s without a break -> claim: a client sends depot.claim {depot, n}
##     (Session.claim_depot; n = this pilot's claim counter), the host / solo arbitrates its own at once. Unanswered after
##     RESEND s: re-sent with the same n. The HUD line "Taking power core: 60%" (progress_line) shows meanwhile.
##   ARBITRATE (host / solo only): the depot exists, is alive, has cores, the pilot (its replicated position: the host's
##     own mech or the puppet) stands on the depot's deck within CLAIM_RANGE + RANGE_SLACK of the footprint and is not
##     down, and its last grant is CLAIM_COOLDOWN s old -> cores_left - 1, seq + 1, depot.grant {depot, peer, seq,
##     cores_left} to the crew (Session.send_depot_grant); else depot.deny {depot, reason, n} to the asker. One answer
##     per (pilot, n): a re-sent claim gets the same answer again (a grant to the asker only, same seq), an older n
##     nothing. Only the host decrements, so a core is never spent twice.
##   GRANT (every machine): applied once, by seq: a grant whose seq is not newer than the last one applied here is
##     ignored (duplicate or out of order). The grant's cores_left is mirrored; when grant.peer is this machine's pilot,
##     the core's effect (apply_core_to) goes on its own mech.
##   DESTROYED (host): the DepotTarget reaching 0 HP (weapons fire: crew or stray shots; enemies never target it, team "")
##     -> alive false, the remaining cores lost; mission.state carries it, every machine shows the wreck.
## Log: CombatLog.note_depot when the drive's log has it, else one "[Flow] ... depot: kind=... depot=... key=value" line.

const CLAIM_RANGE := 6.0          ## m from the depot's footprint a pilot stands in to take a core
const CLAIM_TIME := 2.0           ## s standing in range, without a break
const RANGE_SLACK := 4.0          ## m the host allows on top (the puppet lags its owner)
const CLAIM_COOLDOWN := 5.0       ## s between two grants to one pilot
const RESEND := 1.0               ## s without an answer before a claim is re-sent
const DENY_PAUSE := 1.0           ## s the local claim waits after a deny before it counts again
const DEPOT_CLEAR := 4.5          ## m clear ground round a depot (snap)
## The effect of one core (pacing-director.md §2.1, proposal; tune here).
const CORE_REPAIR := 0.5          ## every surviving component gets this share of its missing structure back
const CORE_REBUILD := 0.3         ## destroyed components come back at this share of their max (their weapons work again)
const CORE_REFILL := true         ## every limited-ammo weapon (and active equipment's charges) refilled
const CORE_VENT := true           ## heat to zero, shutdown cleared
const LINE := "Taking power core: %d%%"
## HOST BOTS (hangar bots: negative pilot ids, their mechs run on the host: TestDrive.crew_bots -> CrewBot with its own
## PlayerTarget / WeaponRack). The host treats each like a local pilot (the same stand timer, claim_for through the same
## arbitration, the grant broadcast to the crew, the effect applied here on the bot's own mech: rule 2, the host owns it),
## but only while it NEEDS a core (needs_core), so a bot walking past never drains a depot. Human pilots decide by standing.
const BOT_NEED_STRUCTURE := 0.7   ## a bot needs a core below this share of its total structure ...
## ... or with any component destroyed, or any weapon empty / unusable (needs_core_of).

## Host: a core was granted to a pilot this machine owns that is NOT its own player: a host-owned bot (negative pilot id,
## docs/design/hangar-bots.md). The bot's code applies the effect on its mech: MissionDepots.apply_core_to(its
## PlayerTarget, its WeaponRack) (rule 2: the owner, the host, changes its own bot's mech).
signal bot_core_granted(pilot_id: int, depot_id: String)

var flow: MissionFlow
var drive: TestDrive
var plan: MissionPlan
var crew := false
var sites: Dictionary = {}        ## depot id -> {deck, x, s, h, snapped, ok}: where it stands (plan + snap rule)
var nodes: Dictionary = {}        ## depot id -> SupplyDepot
var cores_max: Dictionary = {}    ## depot id -> cores at mission start
var cores_left: Dictionary = {}   ## depot id -> cores left (the host decides; clients mirror grants and the state)
var alive: Dictionary = {}        ## depot id -> bool (the host decides)
var applied := 0                  ## cores applied to this machine's mech (tests)
var dup_grants := 0               ## grants ignored here as duplicate / out of order (tests)
var records: Array = []           ## this machine's depot records [{kind, depot, ...}] (tests, logs)
var _seq := 0                     ## host: the last grant's sequence number
var _granted_at: Dictionary = {}  ## host: peer -> mission time of its last grant
var _answered: Dictionary = {}    ## host: peer -> {n, kind, data}: its last claim's answer
var _last_seq := 0                ## the newest grant applied on this machine
var _t := 0.0                     ## local seconds (claim timers)
var _stand_depot := ""            ## the depot this pilot stands at ("" = none)
var _stand_t := 0.0               ## s standing there without a break
var _inflight: Dictionary = {}    ## {depot, n, sent}: this pilot's unanswered claim
var _nonce := 0                   ## this pilot's claim counter
var _cooldown_until := 0.0        ## _t before which no new claim counts
var _registered: Dictionary = {}  ## depot id -> true once its target is in the combat world
var _bot_nonce: Dictionary = {}   ## host: bot pilot id -> its claim counter (claim_for)
var _bot_stand: Dictionary = {}   ## host: bot pilot id -> [depot id, s standing there]
var _bot_wait: Dictionary = {}    ## host: bot pilot id -> _t before which its timer doesn't count (after an answer)
var last_grant: Dictionary = {}   ## the newest grant applied here, any pilot (tests, logs)


func net_fields() -> Dictionary:
	return {"flow": Net.LOCAL, "drive": Net.LOCAL, "plan": Net.LOCAL, "crew": Net.SPAWN,
		"sites": Net.SPAWN,           # plan + snap rule: the same on every machine
		"nodes": Net.LOCAL, "cores_max": Net.SPAWN,
		"cores_left": Net.OWNER, "alive": Net.OWNER,   # the host decides; grants + mission.state carry them
		"applied": Net.LOCAL, "dup_grants": Net.LOCAL, "records": Net.LOCAL,
		"_seq": Net.PRIVATE, "_granted_at": Net.PRIVATE, "_answered": Net.PRIVATE,
		"_last_seq": Net.LOCAL, "_t": Net.LOCAL, "_stand_depot": Net.PRIVATE, "_stand_t": Net.PRIVATE,
		"_inflight": Net.PRIVATE, "_nonce": Net.PRIVATE, "_cooldown_until": Net.PRIVATE, "_registered": Net.LOCAL,
		"_bot_nonce": Net.PRIVATE, "placement_fallbacks": Net.LOCAL, "_keep": Net.LOCAL, "_bot_stand": Net.PRIVATE, "_bot_wait": Net.PRIVATE, "last_grant": Net.LOCAL}


func _ready() -> void:
	process_physics_priority = 41   # after MissionFlow (40)


func setup(f: MissionFlow) -> void:
	flow = f
	drive = f.drive
	plan = f.plan
	crew = f.crew
	# The crew at mission start = the launch's crew (players AND hangar bots, negative ids: TestDrive._spawn_crew adds a
	# mech per launch crew entry, Session.crew() at the launch, to spawn_order), never the
	# roster / connected peers. Pilot ids are keys everywhere (bots' are negative): no id > 0 assumption.
	var n_crew := drive.spawn_order.size() if crew and drive != null else 1
	for d: Dictionary in plan.depots:
		var id := str(d["id"])
		cores_max[id] = maxi(int(d["cores"]) * maxi(n_crew, 1), MissionPlan.DEPOT_CORES_MIN)
		cores_left[id] = int(cores_max[id])
		alive[id] = true
	_place()
	var s := Net.session()
	if crew and s != null:
		# Methods, not lambdas: Session outlives this node, and a method connection goes away with it.
		s.depot_claimed.connect(_on_claim)
		s.depot_granted.connect(_on_grant)
		s.depot_denied.connect(_on_deny)


## Remove the depots from the world and the combat world (MissionFlow.rebuild, solo N).
func teardown() -> void:
	var w := _world()
	for id: String in nodes:
		var n := _live(nodes[id]) as SupplyDepot
		if n == null or not is_instance_valid(n):
			continue
		if w != null and is_instance_valid(n.target):
			w.unregister(n.target)
		n.queue_free()
	nodes = {}
	_registered = {}


func _world() -> CombatWorld:
	return drive.combat.world if drive != null and drive.combat != null else null


# --- Placement (every machine) ---------------------------------------------------------------------------------

func _place() -> void:
	if drive == null or drive.stack == null:
		return
	for d: Dictionary in plan.depots:
		var id := str(d["id"])
		var k := int(d["deck"])
		if k < 0 or k >= drive.stack.decks.size():
			continue
		var dist: CityDistrict = drive.stack.decks[k]
		var at := Vector2(float(d["site"]["x"]), float(d["site"]["s"]))
		var snap := find_site(dist, k, at, float(d.get("snap", MissionPlan.DEPOT_SNAP)))
		if not bool(snap["ok"]):   # nothing clear within PLACE_REACHES: the old snap (counted, reported)
			placement_fallbacks += 1
			snap = MissionProps.snap_site(dist, at, float(d.get("snap", MissionPlan.DEPOT_SNAP)), DEPOT_CLEAR, _avoid(k))
			snap["face"] = open_face(dist, Vector2(float(snap["x"]), float(snap["s"])), _avoid(k))
			snap["fallback"] = true
			push_warning("[depot] %s: no site off the roads within %.0f m, placed by the plain snap" % [id, PLACE_REACHES[-1]])
		snap["deck"] = k
		sites[id] = snap
		var node := SupplyDepot.new()
		node.build(dist, MissionProps.site_frame(dist, float(snap["x"]), float(snap["s"]), float(snap["h"])), id, k,
			int(cores_max[id]), int(snap["face"]))
		dist.add_child(node)
		nodes[id] = node
		node.show_state(int(cores_left[id]), true)


# --- Placement off the roads (every machine; plan data, the built deck's plan and the snapped world sites only) -----

## KEEP-OUT: a depot's footprint (6 x 4 m turned by its facing) never comes within KEEP_MARGIN of a road segment's strip
## (street, lane, pedestrian; crossings are in the strips), a ramp (and its mouth / foot, RAMP_MOUTH along s), a floor
## cut, a gate's staging bay mouth and exit corridor (MissionWorld.source_bay: door -> exit, + BAY_RUN beyond), a lift /
## shaft / ramp source (SOURCE_KEEP), a flag mast or relay; and stays WALK_GAP + the edge's half-width off every
## walk-graph edge's centre line (CityPlan.walk_graph(true): what enemies and bots path along). The STANDING AREA in front
## of the socket wall (STAND_GAP out, a mech capsule MECH_R) must be clear ground. Search: the plan site, then a 1 m grid
## nearest first out to PLACE_REACHES (widened in steps); each point also needs clear ground under the depot
## (MissionProps.snap_site at reach 0, the flag rule). FACING among the facings that pass: toward the nearest road (a mech
## walks up to it from the street), ties +s, +x, -s, -x.
const KEEP_MARGIN := 4.0
const WALK_GAP := 3.0
const WALK_HALF := {"street": 0.0, "lane": 0.0, "pedestrian": 0.0, "none": 2.5, "alley": 2.0}   ## road edges: their strip
const RAMP_MOUTH := 12.0
const BAY_RUN := 10.0
const SOURCE_KEEP := 8.0
const STAND_GAP := 3.0
const MECH_R := 2.2
const ROAD_LOOK := 30.0           ## m a facing looks for a road
const PLACE_REACHES: Array[float] = [25.0, 50.0, 80.0, 120.0]

var placement_fallbacks := 0      ## depots placed by the plain snap (no site off the roads within reach)
var _keep: Dictionary = {}        ## deck -> keep_out(k) (built once per deck)


## The keep-out of deck k (see KEEP-OUT): {roads: [Rect2 road strips], rects: [Rect2 ramps / cuts, already grown],
## caps: [[Vector2 a, Vector2 b, float r]] corridors, discs (a == b) and walk edges}.
func keep_out(k: int) -> Dictionary:
	if _keep.has(k):
		return _keep[k]
	var roads: Array[Rect2] = []
	var rects: Array[Rect2] = []
	var caps: Array = []
	var sec := drive.stack.section if drive != null and drive.stack != null else null
	if sec != null:
		for sg: Dictionary in sec.segments(k):
			if str(sg["form"]) != "none":
				roads.append(sg["rect"])
	var dist: CityDistrict = drive.stack.decks[k]
	var cp := dist.plan
	for rp: Dictionary in cp.ramps:
		var s0 := minf(float(rp["s_top"]), float(rp["s_foot"]))
		var s1 := maxf(float(rp["s_top"]), float(rp["s_foot"]))
		rects.append(Rect2(float(rp["x0"]), s0, float(rp["x1"]) - float(rp["x0"]), s1 - s0).grow_individual(2.0,
			RAMP_MOUTH, 2.0, RAMP_MOUTH))
	for c: Rect2 in cp.floor_cuts():
		rects.append(c.grow(CityStreets.HOLE_CURB + 1.0))
	var w := flow.world if flow != null else null
	for src: Dictionary in plan.deck_sources(k):
		var at := Vector2(float(src["x"]), float(src["s"]))
		if str(src["kind"]) == "gate" and w != null and is_instance_valid(w):
			var bay: Dictionary = w.source_bay(src["id"])
			if bool(bay.get("ok", false)):
				var door: Vector2 = bay["door"]
				var ex_a := drive.stack.to_deck_arc(bay["exit"])
				var ex := Vector2(float(ex_a["x"]), float(ex_a["s"]))
				var dir := (ex - door).normalized() if ex.distance_to(door) > 0.1 else Vector2.ZERO
				caps.append([door, ex + dir * BAY_RUN, float(bay["half_width"]) + 1.0])
				continue
		caps.append([at, at, SOURCE_KEEP])
	for av: Array in _avoid(k):     # flag masts, relays and the depots placed already
		caps.append([av[0], av[0], float(av[1]) + 2.0])
	var g := cp.walk_graph(true)
	var nodes: Array = g["nodes"]
	var forms: Dictionary = g.get("forms", {})
	for ed: Array in g["edges"]:
		var a := int(ed[0])
		var b := int(ed[1])
		var form := str(forms.get(Vector2i(mini(a, b), maxi(a, b)), "street"))
		caps.append([nodes[a] as Vector2, nodes[b] as Vector2, float(WALK_HALF.get(form, 2.5)) + WALK_GAP])
	var ko := {"roads": roads, "rects": rects, "caps": caps}
	_keep[k] = ko
	return ko


## The footprint rect of a depot at `at` facing `f` (deck arc coordinates).
static func footprint_rect(at: Vector2, f: int) -> Rect2:
	var half := SupplyDepot.footprint_half(f)
	return Rect2(at - half, half * 2.0)


## What a footprint at `at` facing `f` hits in `ko` (keep_out): "road", "ramp_or_cut", "corridor", or "" when clear.
static func keep_hit(ko: Dictionary, at: Vector2, f: int) -> String:
	var r := footprint_rect(at, f)
	var rm := r.grow(KEEP_MARGIN)
	for rd: Rect2 in ko["roads"]:
		if rm.intersects(rd):
			return "road"
	for rc: Rect2 in ko["rects"]:
		if rm.intersects(rc):
			return "ramp_or_cut"
	for c: Array in ko["caps"]:
		if rect_seg_dist(r, c[0], c[1]) < float(c[2]):
			return "corridor"
	return ""


## Distance from rect `r` to segment a-b (0 when they touch).
static func rect_seg_dist(r: Rect2, a: Vector2, b: Vector2) -> float:
	if r.has_point(a) or r.has_point(b):
		return 0.0
	var corners: Array[Vector2] = [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]
	for i in 4:
		if Geometry2D.segment_intersects_segment(a, b, corners[i], corners[(i + 1) % 4]) != null:
			return 0.0
	var best := INF
	for p: Vector2 in [a, b]:
		var q := Vector2(clampf(p.x, r.position.x, r.end.x), clampf(p.y, r.position.y, r.end.y))
		best = minf(best, p.distance_to(q))
	for cn in corners:
		best = minf(best, cn.distance_to(Geometry2D.get_closest_point_to_segment(cn, a, b)))
	return best


## The point in front of facing `f`'s socket wall where a pilot stands (STAND_GAP out from the wall).
static func stand_point(at: Vector2, f: int) -> Vector2:
	var half := SupplyDepot.footprint_half(f)
	var dir: Vector2 = FACE_DIRS[f]
	return at + dir * (absf(dir.x) * half.x + absf(dir.y) * half.y + STAND_GAP)


## Every 1 m grid offset within `reach` and beyond `inner` (< 0: from the centre), nearest first (ties smaller y, then
## x); cached.
static var _rings: Dictionary = {}

static func _ring(inner: float, reach: float) -> Array:
	var key := Vector2(inner, reach)
	if not _rings.has(key):
		var keyed := []
		var n := int(floor(reach))
		for i in range(-n, n + 1):
			for j in range(-n, n + 1):
				var l := Vector2(i, j).length()
				if l <= reach + 0.001 and (inner < 0.0 or l > inner + 0.001):
					keyed.append([l, float(j), float(i)])
		keyed.sort()
		var out := []
		for kk: Array in keyed:
			out.append(Vector2(float(kk[2]), float(kk[1])))
		_rings[key] = out
	return _rings[key]


## The depot site for plan site `at` on deck k: snap_site's {x, s, h, ok} + face, reach, snapped; ok false when nothing
## within the widest PLACE_REACHES satisfies the keep-out (the caller falls back). Deterministic: plan data, the built
## deck's plan, the snapped world sites.
func find_site(d: CityDistrict, k: int, at: Vector2, first_reach: float) -> Dictionary:
	var ko := keep_out(k)
	var avoid := _avoid(k)
	var inner := -1.0
	var reaches: Array[float] = [first_reach]
	for rr in PLACE_REACHES:
		if rr > first_reach:
			reaches.append(rr)
	for reach in reaches:
		for off: Vector2 in _ring(inner, reach):
			var pt: Vector2 = at + off
			var faces: Array[int] = []
			for f in 4:
				if keep_hit(ko, pt, f) != "":
					continue
				if not bool(MissionProps.snap_site(d, stand_point(pt, f), 0.0, MECH_R, avoid)["ok"]):
					continue
				faces.append(f)
			if faces.is_empty():
				continue
			var g := MissionProps.snap_site(d, pt, 0.0, DEPOT_CLEAR, avoid)
			if not bool(g["ok"]):
				continue
			g["face"] = _road_face(ko, pt, faces)
			g["reach"] = reach
			g["snapped"] = not pt.is_equal_approx(at)
			return g
		inner = reach
	return {"ok": false}


## Of the facings `faces`, the one whose wall looks at the nearest road strip (within ROAD_LOOK m); ties in order.
static func _road_face(ko: Dictionary, at: Vector2, faces: Array[int]) -> int:
	var best := faces[0]
	var best_d := INF
	for f in faces:
		var half := SupplyDepot.footprint_half(f)
		var dir: Vector2 = FACE_DIRS[f]
		var from := at + dir * (absf(dir.x) * half.x + absf(dir.y) * half.y)
		var dd := INF
		var t := 0.0
		while t <= ROAD_LOOK and dd == INF:
			var p := from + dir * t
			for rd: Rect2 in ko["roads"]:
				if rd.has_point(p):
					dd = t
					break
			t += 1.0
		if dd < best_d:
			best_d = dd
			best = f
	return best


## FACING (every machine, plan data + the snap rule only): which way the socket wall looks (0 +s, 1 +x, 2 -s, 3 -x):
## the direction with the longest run of clear ground in front of the wall, probed every FACE_STEP m out to FACE_REACH m
## with MissionProps.snap_site at reach 0 (clear radius FACE_CLEAR: the same test that places flags); ties in that
## order. So the cores face the street or plaza, not a wall.
const FACE_STEP := 3.0
const FACE_REACH := 15.0
const FACE_CLEAR := 1.5
const FACE_DIRS: Array[Vector2] = [Vector2(0, 1), Vector2(1, 0), Vector2(0, -1), Vector2(-1, 0)]   ## (x, s) per face


static func open_face(d: CityDistrict, at: Vector2, avoid: Array = []) -> int:
	var best := 0
	var best_run := -1
	for f in FACE_DIRS.size():
		var half := SupplyDepot.footprint_half(f)
		var dir: Vector2 = FACE_DIRS[f]
		var wall := absf(dir.x) * half.x + absf(dir.y) * half.y   # centre to the wall face along dir
		var run := 0
		var dist := FACE_STEP
		while dist <= FACE_REACH + 0.001:
			var r := MissionProps.snap_site(d, at + dir * (wall + dist), 0.0, FACE_CLEAR, avoid)
			if not bool(r["ok"]):
				break
			run += 1
			dist += FACE_STEP
		if run > best_run:
			best_run = run
			best = f
	return best


## What a depot on deck k keeps clear of: the snapped flag masts and defend relays there, and the depots placed already.
func _avoid(k: int) -> Array:
	var out: Array = []
	var w := flow.world if flow != null else null
	if w != null and is_instance_valid(w):
		for o: Dictionary in plan.deck_objectives(k):
			var st: Dictionary = {}
			var r := 0.0
			match str(o["type"]):
				"flag":
					st = w.flag_site(o["id"])
					r = MissionWorld.FLAG_CLEAR
				"defend":
					st = w.asset_site(o["id"])
					r = MissionWorld.ASSET_CLEAR
			if not st.is_empty():
				out.append([Vector2(float(st["x"]), float(st["s"])), r])
	for id: String in sites:
		if int(sites[id]["deck"]) == k:
			out.append([Vector2(float(sites[id]["x"]), float(sites[id]["s"])), DEPOT_CLEAR])
	return out


## Distance (m, in the deck's arc coordinates) from (x, s) to depot `id`'s footprint (SupplyDepot.BLOCK).
func footprint_dist(id: String, x: float, s: float) -> float:
	var st: Dictionary = sites.get(id, {})
	if st.is_empty():
		return INF
	var half := SupplyDepot.footprint_half(int(st.get("face", 0)))
	var dx := maxf(absf(x - float(st["x"])) - half.x, 0.0)
	var ds := maxf(absf(s - float(st["s"])) - half.y, 0.0)
	return sqrt(dx * dx + ds * ds)


## World point of depot `id` on the ground (Vector3.ZERO if unknown).
func depot_pos(id: String) -> Vector3:
	var st: Dictionary = sites.get(id, {})
	if st.is_empty() or drive == null or drive.stack == null:
		return Vector3.ZERO
	return drive.stack.from_deck_arc(int(st["deck"]), float(st["x"]), float(st["s"]), float(st.get("h", 0.0)))


func has_cores(id: String) -> bool:
	return bool(alive.get(id, false)) and int(cores_left.get(id, 0)) > 0


## The live depot with cores whose footprint is nearest to world point `pos` within `reach` m on pos's deck; "" if none.
func depot_in_range(pos: Vector3, reach: float) -> String:
	if drive == null or drive.stack == null:
		return ""
	var a := drive.stack.to_deck_arc(pos)
	var best := ""
	var best_d := INF
	for id: String in sites:
		if not has_cores(id) or int(sites[id]["deck"]) != int(a["deck"]):
			continue
		var d := footprint_dist(id, float(a["x"]), float(a["s"]))
		if d <= reach and d < best_d:
			best_d = d
			best = id
	return best


## BOT HOOK (Engine's MissionBot / scripts/ai): the live depot with cores on deck `deck` nearest to world point `pos`:
## {id, deck, x, s, pos: Vector3 on the ground, cores_left, dist: m in arc coordinates}, or {} when none. Standing within
## CLAIM_RANGE of its footprint for CLAIM_TIME s takes a core automatically (the same rule as a player; nothing to call).
func nearest_with_cores(deck: int, pos: Vector3) -> Dictionary:
	if drive == null or drive.stack == null:
		return {}
	var a := drive.stack.to_deck_arc(pos)
	var best: Dictionary = {}
	var best_d := INF
	for id: String in sites:
		var st: Dictionary = sites[id]
		if not has_cores(id) or int(st["deck"]) != deck:
			continue
		var d := Vector2(float(a["x"]), float(a["s"])).distance_to(Vector2(float(st["x"]), float(st["s"])))
		if d < best_d:
			best_d = d
			best = {"id": id, "deck": deck, "x": float(st["x"]), "s": float(st["s"]), "pos": depot_pos(id),
				"cores_left": int(cores_left[id]), "dist": d}
	return best


# --- Replicated state ------------------------------------------------------------------------------------------

## What mission.state carries: {id: [cores_left, alive 0 | 1]}.
func state() -> Dictionary:
	var out := {}
	for id: String in cores_left:
		out[id] = [int(cores_left[id]), 1 if bool(alive[id]) else 0]
	return out


## Client: the host's state.
func apply_state(d: Dictionary) -> void:
	for id: Variant in d:
		var v: Variant = d[id]
		if not cores_left.has(str(id)) or not (v is Array) or (v as Array).size() < 2:
			continue
		cores_left[str(id)] = int(v[0])
		alive[str(id)] = int(v[1]) != 0


# --- Every frame -----------------------------------------------------------------------------------------------

func _physics_process(dt: float) -> void:
	_t += dt
	_register_targets()
	for id: String in nodes:
		var n := _live(nodes[id]) as SupplyDepot
		if n != null and is_instance_valid(n):
			n.show_state(int(cores_left.get(id, 0)), bool(alive.get(id, false)))
	_claim_tick(dt)
	_bot_tick(dt)


## Each depot's DepotTarget joins the combat world once it exists (every machine; the host / solo hears its depot_down).
func _register_targets() -> void:
	var w := _world()
	if w == null or _registered.size() == nodes.size():
		return
	for id: String in nodes:
		var n := _live(nodes[id]) as SupplyDepot
		if _registered.has(id) or n == null or not is_instance_valid(n.target):
			continue
		w.register(n.target)
		_registered[id] = true
		if w.owns(n.target):
			n.target.depot_down.connect(_on_depot_down)


func local_peer() -> int:
	return MechSpawn.owner_of(drive.mech) if drive != null else 0


## Host: the CrewBot of bot pilot `pilot_id` this machine runs (TestDrive.crew_bots), or null.
func _crew_bot(pilot_id: int) -> Node:
	if drive == null or not ("crew_bots" in drive):
		return null
	return _live((drive.get("crew_bots") as Dictionary).get(pilot_id)) as Node


## `v` when it is a live object, else null: read stored references through this BEFORE any `as` / `is` (a cast on a
## freed object raises).
static func _live(v: Variant) -> Object:
	return v as Object if is_instance_valid(v) else null   # is_instance_valid first: `is` on a freed object raises


## A CrewBot's field (mech / target / rack) when it is live, else null.
static func _bot_field(cb: Node, field: String) -> Object:
	return _live(cb.get(field)) if cb != null and is_instance_valid(cb) else null


## Whether host bot `pilot_id` needs a power core now (its own mech's state; false for anyone else). For the bot's AI:
## steer to nearest_with_cores while this is true.
func needs_core(pilot_id: int) -> bool:
	var cb := _crew_bot(pilot_id)
	if cb == null:
		return false
	return needs_core_of(_bot_field(cb, "target") as PlayerTarget, _bot_field(cb, "rack") as WeaponRack)


## The need rule: standing (not disabled) and total structure < BOT_NEED_STRUCTURE, or a component destroyed, or a
## weapon slot unusable (empty or on a destroyed hardpoint).
static func needs_core_of(pt: PlayerTarget, rack: WeaponRack) -> bool:
	if pt == null or pt.disabled:
		return false
	if pt.total_max_hp() > 0.0 and pt.total_hp() / pt.total_max_hp() < BOT_NEED_STRUCTURE:
		return true
	for c: String in pt.hp:
		if float(pt.hp[c]) <= 0.0:
			return true
	if rack != null:
		for i in rack.slot_count():
			if rack.weapons[i] != "" and not MechCatalog.is_equipment(rack.weapons[i]) and not rack.usable(i + 1):
				return true
	return false


## Host: every bot it runs takes a core like a local pilot: standing within CLAIM_RANGE of a live depot with cores for
## CLAIM_TIME s while it needs one -> claim_for.
func _bot_tick(dt: float) -> void:
	if not _deciding() or flow == null or not flow.released or flow.ended or drive == null or not ("crew_bots" in drive):
		return
	for pid: int in (drive.get("crew_bots") as Dictionary):
		var cb := _crew_bot(pid)
		var m := _bot_field(cb, "mech") as Node3D   # null when the bot or its mech is gone: skipped this tick
		var id := ""
		if m != null and _t >= float(_bot_wait.get(pid, 0.0)) and needs_core(pid):
			id = depot_in_range(m.global_position, CLAIM_RANGE)
		var st: Array = _bot_stand.get(pid, ["", 0.0])
		if id == "":
			_bot_stand.erase(pid)
			continue
		if str(st[0]) != id:
			st = [id, 0.0]
		st[1] = float(st[1]) + dt
		_bot_stand[pid] = st
		if float(st[1]) >= CLAIM_TIME:
			_bot_stand.erase(pid)
			_note("claim", id, {"peer": pid})
			var why := claim_for(pid, id)
			_bot_wait[pid] = _t + (CLAIM_COOLDOWN if why == "" else DENY_PAUSE)


## A pilot that is a bot of the host (TestDrive.crew_bots, else Session.is_bot when it exists, else a negative id).
func _bot(pilot_id: int) -> bool:
	if _crew_bot(pilot_id) != null:
		return true
	var s := Net.session()
	if s != null and s.has_method("is_bot"):
		return bool(s.call("is_bot", pilot_id))
	return pilot_id < 0


func _deciding() -> bool:
	return flow != null and flow.deciding()


func _claim_tick(dt: float) -> void:
	if flow == null or not flow.released or flow.ended or drive == null or drive.mech == null:
		_stand_t = 0.0
		_stand_depot = ""
		return
	if not _inflight.is_empty():
		if _t - float(_inflight["sent"]) >= RESEND:
			_inflight["sent"] = _t
			_send(str(_inflight["depot"]), int(_inflight["n"]))
		return
	var pt := drive.combat.player_target if drive.combat != null else null
	var id := ""
	if pt != null and not pt.disabled and _t >= _cooldown_until:
		id = depot_in_range(drive.mech.global_position, CLAIM_RANGE)
	if id == "":
		_stand_t = 0.0
		_stand_depot = ""
		return
	if id != _stand_depot:
		_stand_depot = id
		_stand_t = 0.0
	_stand_t += dt
	if _stand_t >= CLAIM_TIME:
		_stand_t = CLAIM_TIME
		claim_now(id)


## Claim a core of depot `id` now, skipping the stand timer (the timer calls it; tests). The answer clears it.
func claim_now(id: String) -> void:
	_nonce += 1
	_inflight = {"depot": id, "n": _nonce, "sent": _t}
	_note("claim", id, {"peer": local_peer(), "n": _nonce})
	_send(id, _nonce)


## HOST: claim a core of depot `id` for pilot `pilot_id` this machine owns (a host-owned bot, negative id): the same
## arbitration as any claim (range from the bot's mech, cooldown keyed by pilot id). The answer: a grant goes to the
## crew and bot_core_granted fires here; a deny is returned. Returns "" when granted, else the deny reason.
func claim_for(pilot_id: int, id: String) -> String:
	if not _deciding():
		return "not_host"
	var n := int(_bot_nonce.get(pilot_id, 0)) + 1
	_bot_nonce[pilot_id] = n
	_arbitrate(pilot_id, id, n)
	var ans: Dictionary = _answered.get(pilot_id, {})
	return "" if str(ans.get("kind", "")) == "grant" else str(ans.get("data", {}).get("reason", "unknown"))


func _send(id: String, n: int) -> void:
	if _deciding():
		_arbitrate(local_peer(), id, n)
	else:
		var s := Net.session()
		if s != null:
			s.claim_depot(id, n)


## "Taking power core: 60%" while this pilot is taking one (the objective panel's line), else "".
func progress_line() -> String:
	if _stand_depot == "" or (_stand_t <= 0.0 and _inflight.is_empty()):
		return ""
	return line_for(1.0 if not _inflight.is_empty() else _stand_t / CLAIM_TIME)


static func line_for(fraction: float) -> String:
	return LINE % int(floor(clampf(fraction, 0.0, 1.0) * 100.0 + 1e-6))


# --- Host: arbitration -----------------------------------------------------------------------------------------

func _on_claim(from: int, data: Dictionary) -> void:
	if _deciding():
		_arbitrate(from, str(data.get("depot", "")), int(data.get("n", 0)))


func _arbitrate(peer: int, id: String, n: int) -> void:
	var prev: Dictionary = _answered.get(peer, {})
	if not prev.is_empty() and n <= int(prev["n"]):
		if n == int(prev["n"]):
			_reply(peer, prev, true)   # a re-sent claim: the same answer again
		return
	var reason := refusal(peer, id)
	var ans: Dictionary
	if reason == "":
		cores_left[id] = int(cores_left[id]) - 1
		_seq += 1
		_granted_at[peer] = flow.now()
		ans = {"n": n, "kind": "grant", "data": {"depot": id, "peer": peer, "seq": _seq, "cores_left": int(cores_left[id])}}
	else:
		ans = {"n": n, "kind": "deny", "data": {"depot": id, "reason": reason, "n": n}}
	_answered[peer] = ans
	_reply(peer, ans, false)


## Host: why `peer` may not take a core of depot `id` now ("" = it may).
func refusal(peer: int, id: String) -> String:
	if not cores_left.has(id):
		return "unknown"
	if not bool(alive[id]):
		return "destroyed"
	if int(cores_left[id]) <= 0:
		return "empty"
	if _granted_at.has(peer) and flow.now() - float(_granted_at[peer]) < CLAIM_COOLDOWN:
		return "cooldown"
	var p := _pilot(peer)
	if p.is_empty():
		return "no_pilot"
	if bool(p["downed"]):
		return "down"
	var a := drive.stack.to_deck_arc(p["pos"])
	if int(a["deck"]) != int(sites[id]["deck"]) or footprint_dist(id, float(a["x"]), float(a["s"])) > CLAIM_RANGE + RANGE_SLACK:
		return "range"
	return ""


## Host: {pos, downed} of `peer`'s mech as this machine knows it (its own, or the puppet of the owner's stream); {} if none.
func _pilot(peer: int) -> Dictionary:
	if peer == local_peer():
		var pt := drive.combat.player_target if drive.combat != null else null
		return {"pos": drive.mech.global_position, "downed": pt != null and pt.disabled}
	var cb := _crew_bot(peer)
	if cb != null:
		var bm := _bot_field(cb, "mech") as Node3D
		if bm == null:
			return {}   # the bot's mech is gone
		var bt := _bot_field(cb, "target") as PlayerTarget
		return {"pos": bm.global_position, "downed": bt != null and bt.disabled}
	var pp := _live(drive.crew_sync.puppets.get(peer)) as MechPuppet if drive.crew_sync != null else null
	if pp != null and is_instance_valid(pp.mech):
		return {"pos": pp.mech.global_position, "downed": pp.downed}
	# A host-owned bot (negative pilot id): its mech is this machine's, its PlayerTarget (group player_target) says down.
	var m := _live(drive.mechs.get(peer)) as Node3D
	if m == null:
		return {}
	var downed := false
	for t: Node in get_tree().get_nodes_in_group("player_target"):
		if t is PlayerTarget and (t as PlayerTarget).mech == m:
			downed = (t as PlayerTarget).disabled
	return {"pos": m.global_position, "downed": downed}


func _reply(peer: int, ans: Dictionary, repeat: bool) -> void:
	var me := local_peer()
	var data: Dictionary = ans["data"]
	var s := Net.session()
	if str(ans["kind"]) == "grant":
		if repeat:
			if peer != me and crew and s != null:
				s.send_depot_grant(data, peer)
			return
		if crew and s != null:
			s.send_depot_grant(data, 0)
		if peer != me and not (_deciding() and _bot(peer)):   # a host bot's grant is noted with its effect
			_note("grant", str(data["depot"]), {"peer": peer, "seq": int(data["seq"])})
		_take_grant(data)
	else:
		if peer == me:
			_take_deny(data)
		else:
			_note("deny", str(data["depot"]), {"peer": peer, "reason": str(data["reason"])})
			if crew and s != null and not _bot(peer):
				s.send_depot_deny(peer, data)


## Host / solo: a depot's bunker was destroyed: its cores are lost.
func _on_depot_down(id: String) -> void:
	if not alive.has(id) or not bool(alive[id]):
		return
	var lost := int(cores_left[id])
	alive[id] = false
	cores_left[id] = 0
	_note("destroyed", id, {"lost": lost})


# --- Every machine: answers ------------------------------------------------------------------------------------

func _on_grant(g: Dictionary) -> void:
	_take_grant(g)


func _on_deny(d: Dictionary) -> void:
	_take_deny(d)


## A grant (the host's own, or heard): applied once by seq; the effect on this machine's mech when it is the winner.
## True when it was new.
func _take_grant(g: Dictionary) -> bool:
	var seq := int(g.get("seq", 0))
	if seq <= _last_seq:
		dup_grants += 1
		return false
	_last_seq = seq
	var id := str(g.get("depot", ""))
	if cores_left.has(id):
		cores_left[id] = int(g.get("cores_left", 0))
	last_grant = g.duplicate()
	if int(g.get("peer", 0)) != local_peer() or drive == null:
		var bp := int(g.get("peer", 0))
		if _deciding() and _bot(bp):
			var cb := _crew_bot(bp)
			var beff := apply_core_to(_bot_field(cb, "target") as PlayerTarget, _bot_field(cb, "rack") as WeaponRack) 				if cb != null else {"applied": false}
			var bx := beff.duplicate()
			bx["peer"] = bp
			bx["seq"] = seq
			_note("grant", id, bx)
			bot_core_granted.emit(bp, id)
		return true
	_inflight = {}
	_stand_t = 0.0
	_stand_depot = ""
	_cooldown_until = _t + CLAIM_COOLDOWN
	var eff := apply_core_to(drive.combat.player_target if drive.combat != null else null,
		drive.combat.rack if drive.combat != null else null)
	if bool(eff.get("applied", false)):
		applied += 1
	var extra := eff.duplicate()
	extra["peer"] = local_peer()
	extra["seq"] = seq
	_note("grant", id, extra)
	return true


func _take_deny(d: Dictionary) -> void:
	if _inflight.is_empty() or str(d.get("depot", "")) != str(_inflight["depot"]) or int(d.get("n", -1)) != int(_inflight["n"]):
		return
	_inflight = {}
	_stand_t = 0.0
	_stand_depot = ""
	_cooldown_until = _t + DENY_PAUSE
	_note("deny", str(d.get("depot", "")), {"peer": local_peer(), "reason": str(d.get("reason", ""))})


## The effect of one power core on a mech, applied by its OWNER through the verbs (PlayerTarget repair_fraction /
## rebuild_destroyed / vent_heat, WeaponRack refill_ammo). A disabled mech gets nothing (no revive).
## {applied, repaired: HP, rebuilt: [components], refilled: slots}.
static func apply_core_to(pt: PlayerTarget, rack: WeaponRack) -> Dictionary:
	if pt == null or pt.disabled:
		return {"applied": false}
	var repaired := pt.repair_fraction(CORE_REPAIR, "depot")    # first: the rebuilt ones get only CORE_REBUILD
	var rebuilt := pt.rebuild_destroyed(CORE_REBUILD, "depot")
	var refilled := rack.refill_ammo() if CORE_REFILL and rack != null else 0
	if CORE_VENT:
		pt.vent_heat()
	return {"applied": true, "repaired": snappedf(repaired, 0.1), "rebuilt": rebuilt, "refilled": refilled}


# --- Log -------------------------------------------------------------------------------------------------------

func _note(kind: String, id: String, extra: Dictionary = {}) -> void:
	var left := int(cores_left.get(id, 0))
	var rec := {"kind": kind, "depot": id, "left": left}
	rec.merge(extra)
	records.append(rec)
	# CombatLog (another session's) logs this machine's pilot only: the host's answers to other pilots print below.
	var pilot := int(extra.get("peer", local_peer()))
	var bot := pilot != local_peer() and _deciding() and _bot(pilot)
	var cl: Node = drive.get_node_or_null("CombatLog") if drive != null else null
	if (pilot == local_peer() or bot) and cl != null and cl.has_method("note_depot") 			and cl.get_method_argument_count("note_depot") == 3:
		var ev := "empty" if kind == "deny" and str(extra.get("reason", "")) == "empty" else kind
		if bot:
			ev += ":pilot%d" % pilot   # a host bot: its pilot id in the event (note_depot has no pilot field)
		cl.call("note_depot", ev, id, left)
		return
	var parts := PackedStringArray()
	for key: String in extra:
		var v: Variant = extra[key]
		parts.append("%s=%s" % [key, ",".join(PackedStringArray(v)) if v is Array else str(v)])
	FlowLog.say("depot", "kind=%s depot=%s left=%d %s" % [kind, id, left, " ".join(parts)])
