class_name DownedCrew
extends Node
## The scene's side of downed / revive / respawn (DownedRules has the numbers and the rules; PlayerTarget runs the state
## on its owner's machine). One per test drive, child "DownedCrew" (MissionScene._finish_setup, DownedCrew.attach). Reads
## what this machine already knows (its own mech, the host's bots, the puppets' streamed mirrors: PlayerTarget.disabled /
## redeploying / revive_progress / aid_charges ride in the owner's mech snapshot) and writes only this machine's OWN
## targets (the local pilot's, and on the host its bots'). Nothing here sends anything.
##
##   CALL FOR HELP (automatic on going down):
##     the wreck   a red strobe beacon (light + glowing bulb) above the downed mech's back, on every machine, in the world
##                 (diegetic: no enemy indicator, enemies ignore it); its phase / rate from a looks generator per pilot.
##     crewmates   (player-side HUD, MissionHud.downed_source -> hud_state()) a world marker on the wreck ("DOWN  name",
##                 distance, the revive bar while a drone beams it) and a line in the top-right panel: "<name> is down:
##                 revive with a repair drone" when a standing crewmate can revive (has a repair drone with a charge left
##                 or one on duty, back mount intact), else "<name> is down".
##     the pilot   the centre prompt: "DOWN", "Help is <m> m away" / "No repair drone in the crew", the revive bar while a
##                 drone beams it, and "Hold SPACE to respawn" with the hold bar; then "REDEPLOYING <s>".
##   RESPAWN POINT (PlayerTarget.on_respawn -> _place): when the deck the pilot went down on has an ACTIVE defend or
##     hold objective, a clear spot 60-90 m from its site (DownedRules.RESPAWN_NEAR_*: out of its zone, clear ground by
##     SiteFit.snap, no live enemy within 40 m if a candidate allows it, facing the site). Otherwise the arrival point (SectionEncounters.arrival(sec, k), the enemy spawner's
##     safe bubble) of the deck the crew's LEAD pilot is on (the deepest deck any standing crewmate is on; nobody
##     standing: the deck the pilot went down on), offset by crew seat and dropped onto clear floor (arrival_spot: a lift /
##     shaft arrival anchors on the nearest walk node clear of the well); on the entry deck (and in a district) the pilot's
##     own crew spawn slot, the old respawn point. EVERY spot (objective or arrival) is a SAFE spot for the widest capsule,
##     whatever chassis respawns (2026-11-26, seed 6: a Strider respawned on deck 1's lift platform and fell to deck 2):
##     plan_safe (off lift platforms, floor openings, cuts, ramps; free on the fit mask; connected to the walk graph) and
##     spot_problems == "" (the widest capsule clear of static collision, floor under its whole footprint).
##   BOTS (host): every bot's PlayerTarget gets auto_redeploy (it cannot hold a key) and revive_wait (DownedRules.bot_wait:
##     8 s when a standing crewmate can revive it, else 2 s). The local mech flown by MissionBot (--bot) gets the same.
##   QUERIES for the bot (Engine session's MissionBot): downed_crew() -> [{peer, name, pos, revive, bot}] (revivable
##     downed crewmates, positions on this machine), can_revive(pilot_id), reviver_for(pilot_id), nearest_reviver(id).
## Cosmetic / local only: every var is LOCAL.

const MARK_H := 9.5               ## m above the wreck's feet where the crewmates' marker sits
const BEACON_H := 8.6             ## m above the feet: the beacon bulb (over the back mount)
const BEACON_COLOR := Color(1.0, 0.22, 0.12)
const BEACON_RANGE := 18.0        ## m the beacon light reaches
const BEACON_ON := 6.0            ## light energy during a flash
const BEACON_OFF := 0.35          ## light energy between flashes
const BEACON_DUTY := 0.18         ## share of a cycle the flash lasts
## Floor search around a respawn point (deck arc metres), nearest first.
const SEARCH := [Vector2.ZERO, Vector2(0, 8), Vector2(0, -8), Vector2(8, 0), Vector2(-8, 0), Vector2(0, 16),
	Vector2(0, -16), Vector2(16, 0), Vector2(-16, 0), Vector2(0, 24), Vector2(0, -24), Vector2(24, 0), Vector2(-24, 0)]

## The small floor search around a spot near an objective (it must not slide back toward the zone).
const NEAR_STEPS := [Vector2.ZERO, Vector2(0, 3), Vector2(0, -3), Vector2(3, 0), Vector2(-3, 0)]
## Arrival respawn (arrival_spot): each crew seat's offset from the anchor (9 m apart: two Bulwarks side by side), the
## rings searched round it and the bearings per ring; a lift / shaft anchor moves to a walk node this far from the well.
const SEAT_OFFS := [Vector2(-4.5, 0), Vector2(4.5, 0), Vector2(-4.5, 9), Vector2(4.5, 9)]
const SPOT_RINGS := [4.0, 8.0, 12.0, 16.0, 20.0, 25.0, 30.0, 36.0, 42.0, 50.0, 60.0, 70.0]
const SPOT_BEARINGS := 12
const ANCHOR_CLEAR := 8.0
const SEAT_APART := 2.0 * CityPlan.MECH_R_MAX + 1.0   ## m between two seats' arrival spots (two Bulwarks + 1 m)

var drive: MissionScene
var beacons: Dictionary = {}      ## pilot id -> Node3D beacon on its wreck (cosmetic)
var placed: Array = []            ## [pilot id, deck, Transform3D, kind] of each respawn placement here (tests, diagnostics)
var last_kind := ""               ## the last redeploy_transform's pick: objective | arrival | slot
var _look := {}                   ## pilot id -> [rate, phase] of its beacon (looks generator)
var _t := 0.0                     ## looks clock
var _seat_spots: Dictionary = {}  ## deck -> [arrival_spot per seat, in seat order] (plan + static collision: cached)


func net_fields() -> Dictionary:
	return {"drive": Net.LOCAL, "beacons": Net.LOCAL, "placed": Net.LOCAL, "last_kind": Net.LOCAL, "_look": Net.LOCAL,
		"_t": Net.LOCAL, "_seat_spots": Net.LOCAL}


static func attach(td: MissionScene) -> DownedCrew:
	if td == null or td.combat == null or td.combat.player_target == null:
		return null
	var dc := DownedCrew.new()
	dc.name = "DownedCrew"
	td.add_child(dc)
	dc.setup(td)
	return dc


func _ready() -> void:
	process_physics_priority = -5   # before the combat world steps (0): the owner's targets read auto_redeploy / charges


func setup(td: MissionScene) -> void:
	drive = td
	DownedRules.ensure_input()
	var me := local_id()
	var pt := td.combat.player_target
	pt.on_respawn = func() -> void: _place(me, td.mech)
	pt.revive_wait = func() -> float: return DownedRules.bot_wait(reviver_for(me))
	for id: int in td.crew_bots:
		var cb := _bot(id)
		if cb == null or cb.target == null:
			continue
		var bid := id
		var bm := cb.mech
		cb.target.auto_redeploy = true
		cb.target.on_respawn = func() -> void: _place(bid, bm)
		cb.target.revive_wait = func() -> float: return DownedRules.bot_wait(reviver_for(bid))
	if td.hud != null and td.hud.mission_hud != null:
		td.hud.mission_hud.downed_source = hud_state
	var cl := td.get_node_or_null("CombatLog") as CombatLog
	if cl != null:
		cl.help_fn = help_facts


## Host bot id's CrewBot, or null (gone / freed).
func _bot(id: int) -> CrewBot:
	var v: Variant = drive.crew_bots.get(id) if drive != null else null
	return v as CrewBot if v != null and is_instance_valid(v) else null


func local_id() -> int:
	return MechSpawn.owner_of(drive.mech) if drive != null and drive.mech != null else 0


## Every pilot as this machine sees it: [{peer, name, mech, target (PlayerTarget here: own, bot or a puppet's mirror),
## downed, redeploying, revive (0..1 of the bar), bot, local}] in MissionScene.crew_members order.
func members() -> Array:
	var out: Array = []
	if drive == null or drive.combat == null:
		return out
	var names := _names()
	var me := local_id()
	for c: Dictionary in drive.crew_members():
		var id := int(c["peer"])
		var t := target_of(id)
		out.append({"peer": id, "name": str(names.get(id, "Pilot %d" % absi(id))), "mech": c["mech"], "target": t,
			"downed": bool(c["downed"]), "redeploying": t != null and t.redeploying,
			"revive": clampf(t.revive_progress / DownedRules.REVIVE_TIME, 0.0, 1.0) if t != null else 0.0,
			"bot": bool(c.get("bot", false)), "local": id == me})
	return out


## `id`'s PlayerTarget on this machine (own, bot, or the puppet's mirror), or null.
func target_of(id: int) -> PlayerTarget:
	if drive == null or drive.combat == null:
		return null
	if id == local_id():
		return drive.combat.player_target
	if drive.crew_bots.has(id):
		var cb := _bot(id)
		return cb.target if cb != null else null
	if drive.crew_sync != null:
		var t: Variant = drive.crew_sync.targets.get(id)
		return t as PlayerTarget if t != null and is_instance_valid(t) else null
	return null


## `id` can revive someone now: standing, carries a repair drone on an intact back mount, and has a charge left or a
## drone on duty (aid_charges is the owner's, streamed; the drone is the scheduled effect every machine runs).
func can_revive(id: int) -> bool:
	for m: Dictionary in members():
		if int(m["peer"]) == id:
			return _can_revive(m)
	return false


func _can_revive(m: Dictionary) -> bool:
	if bool(m["downed"]):
		return false
	var mech := m["mech"] as MechController
	var t := m["target"] as PlayerTarget
	if mech == null or t == null or not is_instance_valid(mech):
		return false
	var rig := MechSpawn.rig_of(mech)
	if rig == null or rig.model == null:
		return false
	# a repair drone on a back hardpoint that still stands (the Strider's "back", the Bulwark's back_l / back_r)
	var has_drone := false
	for hp_id: String in PlayerTarget.back_hardpoints(rig.model.chassis_id):
		if str(rig.model.loadout.get(hp_id, "")) == DownedRules.REVIVER and not t.is_slot_destroyed(hp_id):
			has_drone = true
	if not has_drone:
		return false
	if t.aid_charges > 0:
		return true
	var d := drive.combat.world.drone_of(t.target_id) if drive.combat.world != null else null
	return d != null and d.active()


## A standing crewmate other than `id` can revive it.
func reviver_for(id: int) -> bool:
	return not nearest_reviver(id).is_empty()


## The nearest standing crewmate (not `id`) who can revive: {peer, dist (m from `id`'s mech)}, {} when none.
func nearest_reviver(id: int) -> Dictionary:
	var ms := members()
	var at := Vector3.INF
	for m: Dictionary in ms:
		if int(m["peer"]) == id and m["mech"] != null and is_instance_valid(m["mech"]):
			at = (m["mech"] as Node3D).global_position
	if at == Vector3.INF:
		return {}
	var best := {}
	for m: Dictionary in ms:
		if int(m["peer"]) == id or not _can_revive(m):
			continue
		var d := (m["mech"] as Node3D).global_position.distance_to(at)
		if best.is_empty() or d < float(best["dist"]):
			best = {"peer": int(m["peer"]), "dist": d}
	return best


## The revivable downed crewmates (downed, not redeploying), positions on this machine: [{peer, name, pos, revive, bot}].
func downed_crew() -> Array:
	var out: Array = []
	for m: Dictionary in members():
		if bool(m["downed"]) and not bool(m["redeploying"]) and m["mech"] != null and is_instance_valid(m["mech"]):
			out.append({"peer": m["peer"], "name": m["name"], "pos": (m["mech"] as Node3D).global_position,
				"revive": m["revive"], "bot": m["bot"]})
	return out


## The combat log's `help` record for the local pilot: {reviver: bool, dist: m to the nearest reviver (-1 none)}.
func help_facts() -> Dictionary:
	var n := nearest_reviver(local_id())
	return {"reviver": not n.is_empty(), "dist": float(n.get("dist", -1.0))}


## MissionHud.downed_source: {lines: [crew lines for the top-right panel], marks: [{pos, label, revive}], prompt: {} or
## {title, help, revive, hold, hint, left}} (see the header).
func hud_state() -> Dictionary:
	var lines: Array = []
	var marks: Array = []
	var prompt := {}
	var me := local_id()
	var ms := members()
	for m: Dictionary in ms:
		var mech := m["mech"] as MechController
		if int(m["peer"]) == me:
			if bool(m["downed"]):
				prompt = _prompt(m)
			continue
		if not bool(m["downed"]) or bool(m["redeploying"]) or mech == null or not is_instance_valid(mech):
			continue
		var help := reviver_for(int(m["peer"]))
		lines.append(("%s is down: revive with a repair drone" if help else "%s is down") % str(m["name"]))
		marks.append({"pos": mech.global_position + mech.up() * MARK_H, "label": "DOWN  %s" % str(m["name"]),
			"revive": float(m["revive"])})
	return {"lines": lines, "marks": marks, "prompt": prompt}


func _prompt(m: Dictionary) -> Dictionary:
	var t := m["target"] as PlayerTarget
	if t == null:
		return {}
	if t.redeploying:
		return {"title": "REDEPLOYING", "left": t.redeploy_left, "hold": 1.0, "hint": "", "help": "", "revive": 0.0}
	var n := nearest_reviver(int(m["peer"]))
	var help := "Help is %d m away" % roundi(float(n["dist"])) if not n.is_empty() else "No repair drone in the crew"
	return {"title": "DOWN", "help": help, "revive": float(m["revive"]),
		"hold": clampf(t.respawn_hold / DownedRules.RESPAWN_HOLD, 0.0, 1.0),
		"hint": "Hold %s to respawn" % DownedRules.key_name(), "left": 0.0}


## The repair-drone charges a rack has left (every repair-drone slot).
static func drone_charges(rack: WeaponRack) -> int:
	if rack == null:
		return 0
	var n := 0
	for i in mini(rack.weapons.size(), rack.charges.size()):
		if rack.weapons[i] == DownedRules.REVIVER:
			n += maxi(rack.charges[i], 0)
	return n


func _physics_process(delta: float) -> void:
	if drive == null or drive.combat == null or drive.loading:
		return
	_t += delta
	var pt := drive.combat.player_target
	if pt != null:
		pt.aid_charges = drone_charges(drive.combat.rack)
		pt.auto_redeploy = drive.bot != null and is_instance_valid(drive.bot)   # the local mech flown by MissionBot (--bot) cannot hold a key either
	for id: int in drive.crew_bots:
		var cb := _bot(id)
		if cb != null and cb.target != null:
			cb.target.aid_charges = drone_charges(cb.rack)
	_beacons()


# --- Respawn placement ---------------------------------------------------------------------------------------------

## PlayerTarget.on_respawn: put `id`'s mech at its respawn point (redeploy_transform), still, feet re-planted.
func _place(id: int, m: MechController) -> void:
	if m == null or not is_instance_valid(m):
		return
	var xf := redeploy_transform(id, m)
	m.global_transform = xf
	m.velocity = Vector3.ZERO
	var rig := MechSpawn.rig_of(m)
	if rig != null:
		rig.gait.reset([])
	m.reset_physics_interpolation()
	if m == drive.mech and drive.cam != null:
		drive.cam.reset_behind()
	placed.append([id, drive.stack.deck_at(xf.origin) if drive.stack != null else 0, xf, last_kind])


## Where `id` respawns (see the header): the arrival point of the lead pilot's deck, or its own spawn slot on the entry
## deck / in a district.
func redeploy_transform(id: int, m: MechController) -> Transform3D:
	var slot := _slot_of(id)
	last_kind = "slot"
	if drive.stack == null or drive.stack.section == null:
		return slot
	var down_k := drive.stack.deck_at(m.global_position)
	var o := active_objective(down_k)
	if not o.is_empty():
		var near := near_objective(down_k, o, m)
		if not near.is_empty():
			last_kind = "objective"
			return near["xf"]
	var k := lead_deck(id, m)
	if k == int(drive.stack.section.entry["deck"]):
		return slot
	var got := arrival_spot(k, maxi(drive.spawn_order.find(id), 0), m)
	if got.has("xf"):
		last_kind = "arrival"
	return got.get("xf", slot)


## The respawn spot by deck k's arrival for crew seat `seat`: {xf, x, s} or {} when nothing near is safe. ANCHOR: the
## arrival point (SectionEncounters.arrival(sec, k)). The seat's offset (SEAT_OFFS) on top, then rings of SPOT_BEARINGS bearings at
## SPOT_RINGS m round it, nearest first, the first SAFE spot (_floor_near: plan_safe + spot_problems; a lift platform /
## opening is never one) at least SEAT_APART from the lower seats' spots wins; for a lift / shaft arrival with nothing
## safe in reach, the same search from the nearest walk-graph node clear of the well by ANCHOR_CLEAR. Plan data + the built deck's static collision: the owner decides, every machine sees
## its teleport.
func arrival_spot(k: int, seat: int, m: MechController) -> Dictionary:
	var seat_n := posmod(seat, SEAT_OFFS.size())
	var cached: Array = _seat_spots.get(k, [])
	if seat_n < cached.size():
		return cached[seat_n]
	var sec := drive.stack.section
	var arr: Dictionary = SectionEncounters.arrival(sec, k)
	var anchor := Vector2(float(arr["x"]), float(arr["s"]))
	var well := str(arr["kind"]) in ["lift", "shaft"]
	var steps: Array = [Vector2.ZERO]
	for r: float in SPOT_RINGS:
		for i in SPOT_BEARINGS:
			steps.append(Vector2.from_angle(TAU * float(i) / float(SPOT_BEARINGS)) * r)
	# Seats in order, each SEAT_APART from the seats before it (two pilots respawning together never share a spot).
	while cached.size() <= seat_n:
		var s := cached.size()
		var start: Vector2 = anchor + SEAT_OFFS[s]
		var taken: Array = []
		for c: Dictionary in cached:
			if c.has("x"):
				taken.append(Vector2(float(c["x"]), float(c["s"])))
		var got := _floor_near(k, start.x, start.y, m, steps, taken)
		if got.is_empty() and well:
			# nothing safe round the well within SPOT_RINGS: from the nearest walk node clear of it
			var alt: Vector2 = _clear_node(k, anchor) + SEAT_OFFS[s]
			got = _floor_near(k, alt.x, alt.y, m, steps, taken)
		if got.is_empty() and not taken.is_empty():
			got = _floor_near(k, start.x, start.y, m, steps)   # crowded: a safe spot all the same
		cached.append(got)
	if m.is_inside_tree():
		_seat_spots[k] = cached
	return cached[seat_n]


## The walk-graph node of deck k nearest `p` that is ANCHOR_CLEAR m clear of every lift platform and floor opening there
## (`p` itself when the deck has no node).
func _clear_node(k: int, p: Vector2) -> Vector2:
	var sec := drive.stack.section
	var g := CityGraphs.walk_graph((drive.stack.decks[k] as CityDistrict).plan)
	var best := p
	var best_d := INF
	for n: Vector2 in g["nodes"]:
		var d := n.distance_to(p)
		if d >= best_d:
			continue
		var clear := true
		for ci in sec.connectors.size():
			var lift := str(sec.connectors[ci]["kind"]) == "lift"
			if (lift or sec.is_hole(ci, k)) and sec.connector_rect(ci, k).grow(ANCHOR_CLEAR).has_point(n):
				clear = false
				break
		if clear:
			best_d = d
			best = n
	return best


## The ACTIVE defend or hold objective on deck k (the replicated mission state: MissionRules.obj_state, applied from the
## host on a client), {} when none (or no plan mode).
func active_objective(k: int) -> Dictionary:
	var mf: MissionFlow = drive.mission
	if mf == null or mf.rules == null or mf.rules.plan == null:
		return {}
	for o: Dictionary in mf.rules.objectives:
		if int(o.get("deck", -1)) == k and str(o.get("type", "")) in ["defend", "hold"] \
				and mf.rules.obj_state(str(o["id"])) == "active":
			return o
	return {}


## A respawn spot near objective `o` on deck k (DownedRules.RESPAWN_NEAR_*): {xf} facing the site, or {} when no
## candidate has clear ground. Deterministic from plan data + the replicated state (bearings start toward the deck's
## arrival point); only the enemy check reads live state, and the owner's teleport is what every machine then sees.
func near_objective(k: int, o: Dictionary, m: MechController) -> Dictionary:
	var site := Vector2(float(o["site"]["x"]), float(o["site"]["s"]))
	var arr: Dictionary = SectionEncounters.arrival(drive.stack.section, k)
	var toward := Vector2(float(arr["x"]), float(arr["s"])) - site
	var a0 := toward.angle() if toward.length() > 1.0 else -PI * 0.5
	var dist := drive.stack.decks[k] as CityDistrict
	var fallback := {}
	for r: float in DownedRules.RESPAWN_NEAR_TRIES:
		for i in 8:
			var ang := a0 + float((i + 1) / 2) * PI * 0.25 * (1.0 if i % 2 == 0 else -1.0)
			var p := site + Vector2.from_angle(ang) * r
			var sn := SiteFit.snap(dist, p, DownedRules.RESPAWN_SNAP_REACH, DownedRules.RESPAWN_CLEAR_R)
			if not bool(sn.get("ok", false)):
				continue
			var q := Vector2(float(sn["x"]), float(sn["s"]))
			if _in_zone(o, q):
				continue
			var got := _floor_near(k, q.x, q.y, m, NEAR_STEPS)
			if got.is_empty():
				continue
			var xf: Transform3D = got["xf"]
			var face := drive.stack.from_deck_arc(k, site.x, site.y) - xf.origin
			var u := xf.basis.y
			face -= u * face.dot(u)
			if face.length() > 1.0:
				face = face.normalized()
				xf.basis = Basis(face.cross(u), u, -face)
			got = {"xf": xf, "x": q.x, "s": q.y, "r": q.distance_to(site)}
			if not _enemy_near(k, xf.origin):
				return got
			if fallback.is_empty():
				fallback = got
	return fallback


## (x, s) is inside objective `o`'s zone (its radius, or the hold's zone rect) plus RESPAWN_ZONE_MARGIN.
func _in_zone(o: Dictionary, q: Vector2) -> bool:
	var site := Vector2(float(o["site"]["x"]), float(o["site"]["s"]))
	var zone: Variant = o.get("zone", (o.get("params", {}) as Dictionary).get("zone"))
	if zone is Rect2 and (zone as Rect2).grow(DownedRules.RESPAWN_ZONE_MARGIN).has_point(q):
		return true
	return q.distance_to(site) < float(o.get("radius", 0.0)) + DownedRules.RESPAWN_ZONE_MARGIN


## A live enemy on deck k within RESPAWN_ENEMY_CLEAR m of `p`.
func _enemy_near(k: int, p: Vector3) -> bool:
	var w := drive.combat.world
	if w == null:
		return false
	for t in w.targets:
		if not is_instance_valid(t) or t.team != "enemy" or not t.is_hittable() or t.destroyed() or not t.is_inside_tree():
			continue
		if t.global_position.distance_to(p) <= DownedRules.RESPAWN_ENEMY_CLEAR and drive.stack.deck_at(t.global_position) == k:
			return true
	return false


## The deck the crew's lead pilot is on: the deepest deck a standing crewmate (not `id`) is on; nobody standing: the
## deck `id`'s mech is on.
func lead_deck(id: int, m: MechController) -> int:
	var k := -1
	for c: Dictionary in members():
		if int(c["peer"]) == id or bool(c["downed"]) or c["mech"] == null or not is_instance_valid(c["mech"]):
			continue
		k = maxi(k, drive.stack.deck_at((c["mech"] as Node3D).global_position))
	if k < 0:
		k = drive.stack.deck_at(m.global_position)
	return k


func _slot_of(id: int) -> Transform3D:
	if id == local_id():
		return drive.spawn_xf
	if _bot(id) != null:
		return _bot(id).spawn
	return drive.spawn_xf


## A SAFE floor spot near deck k's (x, s), trying `steps` offsets in order: a downward ray (static collision only: lift
## platforms move) hits level floor, a mech's height above it is free, and is_safe_spot holds (the WIDEST capsule, for
## every chassis: one rule, so the spot never depends on who respawns). {xf, x, s} facing along the deck, or {}.
func _floor_near(k: int, x: float, s: float, m: MechController, steps: Array = SEARCH, taken: Array = []) -> Dictionary:
	var st := drive.stack
	if not m.is_inside_tree():
		return {}
	var space := m.get_world_3d().direct_space_state
	var ring := st.deck_ring(k)
	var fq := SiteFit.mask((st.decks[k] as CityDistrict).plan).query([], 0.6)
	for off: Vector2 in steps:
		var px := x + off.x
		var ps := s + off.y
		var near_taken := false
		for tk: Vector2 in taken:
			near_taken = near_taken or tk.distance_to(Vector2(px, ps)) < SEAT_APART
		if near_taken or not plan_safe(st, k, Vector2(px, ps), fq):
			continue
		var base := st.from_deck_arc(k, px, ps)
		var up := ring.up_at(base)
		var q := PhysicsRayQueryParameters3D.create(base + up * 4.0, base - up * 3.0)
		var hit := BotFit._static_ray(space, q)
		if hit.is_empty() or (hit["normal"] as Vector3).dot(up) < 0.8:
			continue
		var p: Vector3 = (hit["position"] as Vector3) + up * 0.3
		var q2 := PhysicsRayQueryParameters3D.create(p + up * 0.5, p + up * 8.0)
		if not BotFit._static_ray(space, q2).is_empty():
			continue
		if spot_problems(st, k, p, space) != "":
			continue
		var f := ring.tangent_at(p)
		f = (f - up * f.dot(up)).normalized()
		return {"xf": Transform3D(Basis(f.cross(up), up, -f), p), "x": px, "s": ps}
	return {}


## The plan-data half of a safe spot at deck k's `p`: off every lift platform / floor opening / floor cut / ramp by the
## widest capsule, free on the fit mask, and connected there to the deck's walk graph (`fq`: a FitMask query; not in a
## sealed pocket a mech could never leave).
static func plan_safe(st: CityStack, k: int, p: Vector2, fq: SiteFit.FitQuery) -> bool:
	var plan: CityPlan = (st.decks[k] as CityDistrict).plan
	var r := CityPlan.MECH_R_MAX
	var sec := st.section
	for ci in sec.connectors.size():
		if (str(sec.connectors[ci]["kind"]) == "lift" or sec.is_hole(ci, k)) and sec.connector_rect(ci, k).grow(r).has_point(p):
			return false
	for c: Rect2 in plan.floor_cuts():
		if c.grow(r + CityDims.HOLE_CURB).has_point(p):
			return false
	for rp: Dictionary in plan.ramps:
		var s0 := minf(float(rp["s_top"]), float(rp["s_foot"]))
		var s1 := maxf(float(rp["s_top"]), float(rp["s_foot"]))
		if Rect2(float(rp["x0"]), s0, float(rp["x1"]) - float(rp["x0"]), s1 - s0).grow(r).has_point(p):
			return false
	var c := fq.m.index_of(p)
	if c < 0 or fq.m.free[c] == 0:
		return false
	return fq.reaches(p)


## What is wrong with a respawn spot at world point `pos` for deck k ("" = a safe standing spot for the widest capsule):
## "deck" (not on deck k), "lift" (a lift platform / well, + the capsule), "hole" (a connector's opening in deck k's
## floor), "cut" (a floor cut + curb), "ramp" (a ramp's surface), "fit" (the fit mask: the widest capsule + margin
## touches a building, column, wall or bay), "capsule" (the widest capsule hits static collision there), "edge" (no floor
## under part of the capsule's footprint). Plan data + the built deck's static collision only.
static func spot_problems(st: CityStack, k: int, pos: Vector3, space: PhysicsDirectSpaceState3D) -> String:
	var out := PackedStringArray()
	var a := st.to_deck_arc(pos)
	if int(a["deck"]) != k:
		out.append("deck")
	var p := Vector2(float(a["x"]), float(a["s"]))
	var r := CityPlan.MECH_R_MAX
	var sec := st.section
	var plan: CityPlan = (st.decks[k] as CityDistrict).plan
	for ci in sec.connectors.size():
		var kind := str(sec.connectors[ci]["kind"])
		if kind == "lift" and sec.connector_rect(ci, k).grow(r).has_point(p):
			out.append("lift")
		elif kind != "lift" and sec.is_hole(ci, k) and sec.connector_rect(ci, k).grow(r).has_point(p):
			out.append("hole")
	for c: Rect2 in plan.floor_cuts():
		if c.grow(r + CityDims.HOLE_CURB).has_point(p):
			out.append("cut")
	for rp: Dictionary in plan.ramps:
		var s0 := minf(float(rp["s_top"]), float(rp["s_foot"]))
		var s1 := maxf(float(rp["s_top"]), float(rp["s_foot"]))
		if Rect2(float(rp["x0"]), s0, float(rp["x1"]) - float(rp["x0"]), s1 - s0).grow(r).has_point(p):
			out.append("ramp")
	var mask := SiteFit.mask(plan)
	var c := mask.index_of(p)
	if c < 0 or mask.free[c] == 0:
		out.append("fit")
	var ring := st.deck_ring(k)
	var h := ring.height(pos) - ring.height(st.from_deck_arc(k, p.x, p.y))
	if space != null:
		if not BotFit.clear_at(space, ring, p.x, p.y, r, 8.0, maxf(h, 0.0)):
			out.append("capsule")
		for off: Vector2 in [Vector2.ZERO, Vector2(r, 0), Vector2(-r, 0), Vector2(0, r), Vector2(0, -r)]:
			var b := st.from_deck_arc(k, p.x + off.x, p.y + off.y)
			var up := ring.up_at(b)
			var q := PhysicsRayQueryParameters3D.create(b + up * 2.0, b - up * 1.5)
			var hit := BotFit._static_ray(space, q)
			if hit.is_empty():
				out.append("edge")
				break
	return " ".join(out)


# --- The beacon on a wreck (cosmetic) --------------------------------------------------------------------------------

func _beacons() -> void:
	var want := {}
	for m: Dictionary in members():
		var mech := m["mech"] as MechController
		if bool(m["downed"]) and not bool(m["redeploying"]) and mech != null and is_instance_valid(mech):
			want[int(m["peer"])] = mech
	for id: int in beacons.keys():
		var b: Variant = beacons[id]
		if not want.has(id) or b == null or not is_instance_valid(b) or (b as Node).get_parent() != want[id]:
			if b != null and is_instance_valid(b):
				(b as Node).queue_free()
			beacons.erase(id)
	for id: int in want:
		if not beacons.has(id):
			beacons[id] = _make_beacon(id, want[id] as MechController)
		_pulse(id, beacons[id] as Node3D)


func _make_beacon(id: int, mech: MechController) -> Node3D:
	if not _look.has(id):
		var rng := RandomNumberGenerator.new()   # looks only: its own generator, per pilot
		rng.seed = hash("beacon:%d" % id)
		_look[id] = [rng.randf_range(1.1, 1.5), rng.randf()]
	var b := Node3D.new()
	b.name = "DownBeacon"
	b.position = Vector3.UP * BEACON_H
	var bulb := MeshInstance3D.new()
	bulb.name = "Bulb"
	var sm := SphereMesh.new()
	sm.radius = 0.32
	sm.height = 0.64
	sm.radial_segments = 10
	sm.rings = 5
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = BEACON_COLOR
	sm.material = mat
	bulb.mesh = sm
	bulb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	b.add_child(bulb)
	var light := OmniLight3D.new()
	light.name = "Light"
	light.light_color = BEACON_COLOR
	light.omni_range = BEACON_RANGE
	light.shadow_enabled = false
	b.add_child(light)
	mech.add_child(b)
	return b


func _pulse(id: int, b: Node3D) -> void:
	if b == null or not is_instance_valid(b):
		return
	var lk: Array = _look.get(id, [1.3, 0.0])
	var on := fposmod(_t * float(lk[0]) + float(lk[1]), 1.0) < BEACON_DUTY
	var light := b.get_node_or_null("Light") as OmniLight3D
	if light != null:
		light.light_energy = BEACON_ON if on else BEACON_OFF
	var bulb := b.get_node_or_null("Bulb") as MeshInstance3D
	if bulb != null:
		bulb.scale = Vector3.ONE * (1.25 if on else 0.8)


## Pilot id -> name from the launch's crew list (bots' names too); the local pilot's own name; solo "You".
func _names() -> Dictionary:
	var out := {}
	var sess := Net.session()
	if sess != null and sess.online():
		for e: Dictionary in sess.mission.params.get("crew", []) as Array:
			out[int(e.get("peer", 0))] = str(e.get("name", ""))
	var me := local_id()
	if not out.has(me) or str(out[me]) == "":
		out[me] = "You"
	return out
