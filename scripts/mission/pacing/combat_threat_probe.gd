class_name CombatThreatProbe
extends RefCounted
## The combat log's threat model (CombatLog owns one and asks it; docs/design/pacing-director.md 3): which enemies engage
## each pilot, p>e line of sight, kills near each pilot, and each pilot's PilotIntensity. One PilotTrack per pilot: the
## local pilot ([0]), plus the host's hangar bots (bots_fn: CrewBot by pilot id). Line text is the logger's: tick()
## returns each pilot's threat facts and the logger formats the `threat` / `los` records.
## Engagement: the AI's targets (host: _target_id + _is_awake, read; client: replicated ai_state, est) at each scan, plus
## the enemy shots the logger reports (engage / engage_est). p>e line of sight: at most LOS_RAYS rays per pilot per
## second (the nearest awake enemies within THREAT_RANGE, chosen at each tick), RAYS_PER_FRAME per physics step, through
## CombatWorld.shot_ray (the weapons' sight: same query, mech capsules excluded), enemy eye to pilot centre with the AI's
## own 2.6 m slack. No other raycasts.
## Logging only: every var is LOCAL, nothing is synced, no network messages; it reads the AI and the pilots, never writes
## them. The local pilot's heat / shutdown come from the logger (CombatLog._heat / _shut), a bot's from its PilotTrack.
## Interface, per logger step in this order: `mt` (the logger's mission clock, set by it), cast_rays(), scan() every
## CombatLog.SCAN_EVERY s, read_intensity(d), step(dt, local_down, local_shut), sync_bots() + tick(deck) every THREAT_EVERY
## s; from enemy shots engage(tid, e) / engage_est(e); reads engaged(pid), crew_engaged(), crew_i, eng_est, intensity (the
## local pilot's PilotIntensity), tracks, rays_total, rays_max_sec.

const THREAT_EVERY := 1.0    ## s between threat ticks (and the p>e ray budget's second)
const THREAT_RANGE := 200.0  ## m
const LOS_RAYS := 12         ## p>e rays per pilot per second at most
const RAYS_PER_FRAME := 3
const LOS_SLACK := 2.6       ## m short of the eye a hit still counts as in sight (EnemyBase._check_los)
const ENGAGED_STATES := ["engage", "flank", "telegraph", "fire", "cooldown"]   ## client estimate from replicated ai_state

var world: CombatWorld
var me := ""                       ## the local pilot's target id
var mt := 0.0                      ## the logger's mission time (CombatLog.mt), set by it before every call
var deck_at_fn := Callable()       ## (pos: Vector3) -> int: the deck at a point (bot tracks), or invalid
var bots_fn := Callable()          ## () -> Dictionary: the host's hangar bots (pilot id -> CrewBot), or invalid
var tracks: Array = []             ## PilotTrack: [0] = the local pilot, then the host's bots
var intensity := PilotIntensity.new()   ## the local pilot's (tracks[0].intensity), computed here (threat src=local)
var rays_total := 0                ## p>e rays cast
var rays_max_sec := 0              ## most p>e rays one pilot cast between two threat ticks (<= LOS_RAYS)
var eng_est := false               ## engagement estimated from replicated enemy state (a client)
var crew_i := 0.0                  ## crew intensity (read_intensity)
var _eng_p: Dictionary = {}        ## player target id -> mt an enemy last engaged it
var _alive: Dictionary = {}        ## enemy instance id -> CombatTarget (alive at the last scan)
var _players: Dictionary = {}      ## player target id -> PlayerTarget (refreshed each scan)


func net_fields() -> Dictionary:
	var f := {}
	for v: String in ["world", "me", "mt", "deck_at_fn", "bots_fn", "tracks", "intensity", "rays_total", "rays_max_sec",
			"eng_est", "crew_i", "_eng_p", "_alive", "_players"]:
		f[v] = Net.LOCAL
	return f


## The local pilot: its track ([0]) carries `intensity`.
func bind(w: CombatWorld, p: PlayerTarget, m: MechController = null) -> void:
	world = w
	me = p.target_id
	var tr := PilotTrack.new()
	tr.target = p
	tr.mech = m
	tr.peer = CombatWorld.local_peer()
	tr.intensity = intensity
	tracks = [tr]


func engaged(pid: String) -> bool:
	var v: Variant = _eng_p.get(pid)
	return v != null and PilotIntensity.engaged(mt, float(v))


func crew_engaged() -> bool:
	for k: Variant in _eng_p:
		if PilotIntensity.engaged(mt, float(_eng_p[k])):
			return true
	return false


## Host / solo: enemy `e` fired at pilot `tid` (its target when it fired: exact).
func engage(tid: String, e: CombatTarget) -> void:
	_eng_p[tid] = mt
	var tr := _track_of(tid)
	if tr != null:
		tr.eng_e[e.get_instance_id()] = mt


## Client: a replayed shot of enemy `e` aimed close to the local pilot counts as fired at it (estimate).
func engage_est(e: CombatTarget) -> void:
	(tracks[0] as PilotTrack).eng_e[e.get_instance_id()] = mt
	_eng_p[me] = mt
	eng_est = true


static func is_enemy(t: CombatTarget) -> bool:
	return t.team == "enemy" and not (t is AssetTarget) and not (t is BannerTarget)


## The track of pilot target `tid` (the local pilot, or a host bot), or null.
func _track_of(tid: String) -> PilotTrack:
	for tr: PilotTrack in tracks:
		if tr.id() == tid and tid != "":
			return tr
	return null


## The host's hangar bots (bots_fn: CrewBot by pilot id): one track each, `bot=1`.
func sync_bots() -> void:
	var i := 1
	while i < tracks.size():
		if not (tracks[i] as PilotTrack).valid():
			tracks.remove_at(i)
		else:
			i += 1
	if not bots_fn.is_valid():
		return
	var bots: Dictionary = bots_fn.call()
	for id: Variant in bots:
		var cb: Variant = bots[id]
		if not is_instance_valid(cb):
			continue
		var bt: Variant = cb.get("target")
		if not is_instance_valid(bt) or not (bt is PlayerTarget) or _track_of((bt as PlayerTarget).target_id) != null:
			continue
		var tr := PilotTrack.new()
		tr.target = bt as PlayerTarget
		var bm: Variant = cb.get("mech")
		tr.mech = bm as Node3D if is_instance_valid(bm) and bm is Node3D else null
		tr.peer = int(id)
		tr.bot = true
		var bpt := tr.pt()
		tr.intensity.structure(tot_pct_of(bpt))
		var pi := tr.intensity
		bpt.player_component_destroyed.connect(func(_c: String) -> void: pi.component_destroyed())
		bpt.player_disabled.connect(func(_c: String) -> void: pi.disabled())
		tracks.append(tr)


## The AI's targets (engagement), kills (each pilot's intensity kill_near) and the bots' structure. Returns
## {kills: enemies destroyed since the last scan, fresh: [enemies first seen alive]} for the logger (pacing stats, hooks).
func scan() -> Dictionary:
	var kills := 0
	var fresh: Array = []
	var local := tracks[0] as PilotTrack
	_players.clear()
	for t in world.targets:
		if is_instance_valid(t) and t is PlayerTarget:
			_players[t.target_id] = t
	for t in world.targets:
		if not is_instance_valid(t) or not is_enemy(t):
			continue
		var iid := t.get_instance_id()
		if t.destroyed():
			if _alive.has(iid):
				_alive.erase(iid)
				for tr: PilotTrack in tracks:
					tr.eng_e.erase(iid)
					tr.pe.erase(iid)
				_on_kill(t)
				kills += 1
			continue
		if not _alive.has(iid):
			_alive[iid] = t
			fresh.append(t)
		if not (t is EnemyBase):
			continue
		var e := t as EnemyBase
		if world.owns(e):
			var tid := e.current_target_id()
			if tid != "" and e.is_awake():
				var p: Variant = _players.get(tid)
				if p != null and _pos(e).distance_to(_pos(p)) <= PilotIntensity.ENGAGE_RANGE:
					_eng_p[tid] = mt
					var tr := _track_of(tid)
					if tr != null:
						tr.eng_e[iid] = mt
		else:
			eng_est = true
			if e.ai_state in ENGAGED_STATES and _pos(e).distance_to(local.pos()) <= PilotIntensity.ENGAGE_RANGE:
				local.eng_e[iid] = mt
				_eng_p[me] = mt
	# Enemies gone from the world without being destroyed (despawned): forget them.
	if not _alive.is_empty():
		for iid: int in _alive.keys():
			if not is_instance_valid(_alive[iid]):
				_alive.erase(iid)
	for i in range(1, tracks.size()):   # bots: structure from their own target (the local pilot's comes with its damage)
		var tr := tracks[i] as PilotTrack
		if tr.valid():
			tr.intensity.structure(tot_pct_of(tr.pt()))
	return {"kills": kills, "fresh": fresh}


func _on_kill(t: CombatTarget) -> void:
	for tr: PilotTrack in tracks:
		if tr.valid():
			tr.intensity.kill_near(_pos(t).distance_to(tr.pos()))


## The host director's intensities from mission state (`intensity`: pilot id -> value; empty when absent): each track's
## shown source and value, and the crew intensity (the max over pilots).
func read_intensity(d: Dictionary) -> void:
	crew_i = 0.0
	for tr: PilotTrack in tracks:
		var peer := CombatWorld.local_peer() if not tr.bot else tr.peer
		var v: Variant = d.get(peer, d.get(str(peer))) if not d.is_empty() else null
		tr.i_src = "host" if v != null else "local"
		tr.host_i = float(v) if v != null else 0.0
		crew_i = maxf(crew_i, tr.shown_intensity())
	for k: Variant in d:   # the host's values for pilots this machine has no track of
		crew_i = maxf(crew_i, float(d[k]))


## One step of every pilot's intensity: the local pilot is never engaged while downed (`local_down`).
func step(dt: float, local_down: bool, local_shut: bool) -> void:
	intensity.step(dt, engaged(me) and not local_down, local_shut)
	for i in range(1, tracks.size()):
		var bt := tracks[i] as PilotTrack
		if bt.valid():
			bt.intensity.step(dt, engaged(bt.id()), bt.shutdown())


## This physics step's share of every pilot's p>e rays.
func cast_rays() -> void:
	for tr: PilotTrack in tracks:
		if tr.ray_i < tr.ray_q.size():
			_step_rays(tr)


## THREAT_EVERY s: per valid pilot track, its threat facts (the logger's `threat` / `los` records), then its next
## second's p>e rays. `deck` = the local pilot's deck (a bot's comes from deck_at_fn). Each entry: {track, i, src, eng,
## engaging, near, sees, seen_by, nearest, est, crew_i, crew_eng, deck, alive, tot, core, rays, pilot, bot,
## los: [[target id, p>e 1|0|-1, e>p 1|0], ...]}; heat / shut are the logger's (the local pilot) or the track's (a bot).
func tick(deck: int) -> Array:
	var out: Array = []
	for tr: PilotTrack in tracks:
		if tr.valid():
			out.append(_tick_for(tr, deck))
	return out


func _tick_for(tr: PilotTrack, local_deck: int) -> Dictionary:
	var tid := tr.id()
	var at := tr.pos()
	var deck := local_deck
	if tr.bot:
		deck = int(deck_at_fn.call(at)) if deck_at_fn.is_valid() else local_deck
	var near := 0
	var nearest := -1.0
	var sees := 0
	var seen_by := 0
	var alive := 0
	var host_ai := true
	tr.cands.clear()
	for t in world.targets:
		if not is_instance_valid(t) or not is_enemy(t) or t.destroyed() or not t.is_hittable():
			continue
		var e := t as EnemyBase
		if deck < 0 or e == null or e.spawn_deck == deck:
			alive += 1
		var d := _pos(t).distance_to(at)
		if d > THREAT_RANGE:
			continue
		near += 1
		if nearest < 0.0 or d < nearest:
			nearest = d
		var owned := e == null or world.owns(e)
		var awake := e == null or (e.is_awake() if owned else true)
		if not awake:
			continue
		tr.cands.append([d, t])
		var pe := _pe_of(tr, t.get_instance_id())
		if pe == 1:
			sees += 1
		if e != null:
			if owned:
				if e.current_target_id() == tid and e.has_los():
					seen_by += 1
			else:
				host_ai = false
				if e.ai_state in ENGAGED_STATES and d <= e.sight_range and pe == 1:
					seen_by += 1
	var engaging := 0
	for iid: int in tr.eng_e.keys():
		if PilotIntensity.engaged(mt, float(tr.eng_e[iid])):
			engaging += 1
		elif mt - float(tr.eng_e[iid]) > 30.0:
			tr.eng_e.erase(iid)
	tr.cands.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	if tr.cands.size() > LOS_RAYS:
		tr.cands.resize(LOS_RAYS)
	var est := eng_est or not host_ai
	rays_max_sec = maxi(rays_max_sec, tr.rays_sec)
	var p := tr.pt()
	var f := {"track": tr, "i": tr.shown_intensity(), "src": tr.i_src, "eng": engaged(tid), "engaging": engaging,
		"near": near, "sees": sees, "seen_by": seen_by, "nearest": nearest, "est": est, "crew_i": crew_i,
		"crew_eng": crew_engaged(), "deck": deck, "alive": alive, "tot": tot_pct_of(p), "core": core_pct_of(p),
		"rays": tr.rays_sec, "pilot": _pilot_no(tr), "bot": tr.bot}
	var los: Array = []
	for c: Array in tr.cands:
		var t := c[1] as CombatTarget
		var pe := _pe_of(tr, t.get_instance_id())
		var ep := 0
		if t is EnemyBase:
			var e := t as EnemyBase
			if world.owns(e):
				ep = 1 if e.current_target_id() == tid and e.has_los() else 0
			else:
				ep = 1 if e.ai_state in ENGAGED_STATES and float(c[0]) <= e.sight_range and pe == 1 else 0
		los.append([t.target_id, pe, ep])
	f["los"] = los
	# Next second's rays: these enemies, a few per physics step.
	tr.rays_sec = 0
	tr.ray_q.clear()
	for c: Array in tr.cands:
		tr.ray_q.append(c[1])
	tr.ray_i = 0
	return f


## The pilot number printed: the line's own peer for the local pilot, the bot's (negative) pilot id for a bot.
func _pilot_no(tr: PilotTrack) -> int:
	if tr.bot:
		return tr.peer
	var s := Net.session()
	return s.local_id() if s != null else 0


## p>e for this enemy from the last second's ray: 1 in sight, 0 not, -1 no fresh ray.
func _pe_of(tr: PilotTrack, iid: int) -> int:
	var v: Variant = tr.pe.get(iid)
	if v == null or mt - float((v as Array)[1]) > THREAT_EVERY + 0.5:
		return -1
	return 1 if bool((v as Array)[0]) else 0


func _step_rays(tr: PilotTrack) -> void:
	var n := 0
	while n < RAYS_PER_FRAME and tr.ray_i < tr.ray_q.size() and tr.rays_sec < LOS_RAYS:
		var v: Variant = tr.ray_q[tr.ray_i]
		tr.ray_i += 1
		if not is_instance_valid(v):
			continue
		var t := v as CombatTarget
		if t.destroyed():
			continue
		tr.pe[t.get_instance_id()] = [_ray_sight(tr, t), mt]
		n += 1
		tr.rays_sec += 1
		rays_total += 1


## Line of sight pilot -> enemy through the weapons' sight query (CombatWorld.shot_ray). No physics (tests): in sight.
func _ray_sight(tr: PilotTrack, t: CombatTarget) -> bool:
	var sp := world.space()
	if sp == null:
		return true
	var a := _center(tr.pt()) if tr.valid() else tr.pos()
	var b := (t as EnemyBase).eye_world() if t is EnemyBase else _center(t)
	var d := a.distance_to(b)
	if d < 2.0:
		return true
	var h := world.shot_ray(sp, a, b)
	return h.is_empty() or a.distance_to(h["position"] as Vector3) >= d - LOS_SLACK


static func _center(t: CombatTarget) -> Vector3:
	if t.hit_shapes.size() > 0:
		var xf := t.global_transform if t.is_inside_tree() else t.transform
		if t.wc_rev != t.shapes_rev or t.wc_xf != xf or t.wc_n != t.hit_shapes.size():
			t.refresh_world_cache(xf)
		if t.wc_n > 0:
			return t.wc_centers[0]
	return _pos(t) + t.up * 3.5


static func tot_pct_of(p: PlayerTarget) -> float:
	if p == null or not is_instance_valid(p):
		return 100.0
	return 100.0 * p.total_hp() / maxf(p.total_max_hp(), 0.001)


static func core_pct_of(p: PlayerTarget) -> float:
	if p == null or not is_instance_valid(p):
		return 100.0
	var lo := 1.0
	for c: String in PlayerTarget.CORE_COMPONENTS:
		if p.max_hp.has(c):
			lo = minf(lo, float(p.hp.get(c, 0.0)) / maxf(float(p.max_hp[c]), 0.001))
	return 100.0 * lo


static func _pos(n: Node3D) -> Vector3:
	if n == null or not is_instance_valid(n):
		return Vector3.ZERO
	return n.global_position if n.is_inside_tree() else n.position
