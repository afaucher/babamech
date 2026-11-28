class_name MissionStats
extends Node
## The debrief's counters (playtest R2.15 / R2.15a, docs/design/debrief-stats.md), after bridge-to-friendship's M19 stat
## registry: named counters per pilot, counted on the HOST only (solo: this machine), from facts the host already learns
## (signals; one cheap per-frame read of the client pilots' newest mech snapshot, which has no arrival event). Clients never
## build one (MissionFlow makes it only when it decides). Ranking is NOT here: the hangar board (DebriefStats) does it.
## Child "MissionStats" of MissionFlow, made fresh by MissionFlow.rebuild (= reset at mission start); at the outcome
## MissionFlow calls finish(), which freezes the counters and returns the debrief payload (NetMission DEBRIEF) that rides
## Session.mission.end(end_reason(), debrief).
##
## ROWS: string pilot id ("1", "2", "-1": bots are negative, strings survive the wire) -> {stat: number}. Every pilot of
## the launch crew gets every STATS key at its start value. add(pilot, stat, n) / lower(pilot, stat, v) (a min stat) are the
## only writers; an unknown pilot, a pilot who LEFT (frozen at the moment it left) and anything after finish() is ignored.
##
## SOURCES (host-side, exact unless noted; the table is in docs/design/debrief-stats.md):
##   shots / hits   CombatWorld.fired: one fire record of a pilot = one shot (round, rocket, laser pulse, flamer chunk:
##                  CombatLog's `shot` rule), the host runs every pilot's records (its own, its bots', clients' through
##                  CombatNet). CombatWorld.hit_landed on an EnemyBase: one hit per shot key, however many enemies it hit
##                  (clients' hits on host-owned enemies are applied here by CombatNet, which emits hit_landed). A hit
##                  counts only for a shot key counted as a shot (one arriving before its record waits for it), so
##                  hits <= shots always; splash shares its shot's key; burns are damage, not hits.
##   damage_dealt   EnemyBase.damaged (the HP actually removed, no overkill) by the src pilot. Enemies only (not relays,
##                  depots, banners, crewmates).
##   kills          EnemyBase.destroyed_enemy credited to the pilot whose damage was the last applied to it IN THE SAME
##                  FRAME (the kill happens inside that apply_damage); "shock" damage keeps the breaker's credit. A kill
##                  with no pilot damage that frame (fell out, timeout, crushed, enemy fire) credits nobody.
##                  Plus kills_<kind> (trooper, strider, tank, gunship, drone (+ dropship), turret).
##   damage_taken   host-owned pilots (the host's mech, bots): PlayerTarget.damaged, exact. CLIENT pilots: the sum of HP
##                  decreases between consecutive snapshots of the owner's stream (Session.mechs.newest, 30 Hz, u8 per
##                  component), increases (repairs, cores, revive, redeploy) never subtract. Error: see the doc.
##   hp_min         lowest total structure % (sum hp / sum max hp), from the same source as damage_taken; a downed pilot
##                  keeps what the killing hit left (a destroyed core does not force 0).
##   downs / redeploys / time_down   host-owned: player_disabled / player_respawned; clients: the snapshot's disabled
##                  edge, redeploying seen during that down. time_down = mission s spent down (open downs at the outcome).
##   revives / self_revives   host-owned victims: player_revived(by): by its own target = a self-revive, else a revive
##                  GIVEN by by's pilot. Client victims: the stand-up edge without a redeploy, credited to the pilot whose
##                  drone the host saw beaming it within GIVEN_HOLD s (drones are scheduled effects: the host runs every
##                  one); its own drone = a self-revive. No beam seen: nobody.
##   cores          MissionDepots.core_granted (the host's arbitration, every grant once).

const CORE := ["kills", "damage_dealt", "damage_taken", "shots", "hits", "revives", "downs", "cores", "hp_min"]
const TAIL := ["self_revives", "redeploys", "time_down"]   ## extras after the kill kinds, in the board's order
const STATS := CORE + TAIL
const MIN_STATS := {"hp_min": 100.0}   ## lowered, never added; start value
## Kill kinds as the board shows them (EnemyBase.enemy_type -> group); a group shows only once someone has a kill of it.
const KIND_GROUPS := ["trooper", "strider", "tank", "gunship", "drone", "turret"]
const LABELS := {"kills_trooper": "Kills: troopers", "kills_strider": "Kills: striders", "kills_tank": "Kills: tanks",
	"kills_gunship": "Kills: gunships", "kills_drone": "Kills: drones", "kills_turret": "Kills: turrets",
	"kills_other": "Kills: other", "self_revives": "Self-revives", "redeploys": "Redeploys", "time_down": "Time downed (s)"}
const GIVEN_HOLD := 2.0      ## s after a drone last beamed a downed client pilot its stand-up still counts as that revive
const HIT_KEYS_MAX := 4096   ## shot keys remembered for "one hit per shot" (cleared past this: a rare double count at worst)

var flow: MissionFlow
var drive: MissionScene
var world: CombatWorld
var rows: Dictionary = {}          ## "<pilot id>" -> {stat: number} (the host's numbers)
var pilots: Array = []             ## [{id, name}] the launch crew in seat order (solo: this pilot)
var left: Dictionary = {}          ## pilot id -> true: left mid-mission (row frozen)
var frozen := false                ## finish() ran: nothing counts any more
var debrief: Dictionary = {}       ## the payload finish() built
var unknown_revives := 0           ## client stand-ups without a redeploy and without a beam seen (diagnostics)
var _t0 := NAN                     ## mission clock at the release
var _shooter: Dictionary = {}      ## shooter id -> pilot id (0 = not a pilot of this mission)
var _shooter_of: Dictionary = {}   ## pilot id -> "player<id>"
var _kill_src: Dictionary = {}     ## enemy instance id -> [pilot, physics frame] of the last damage applied to it
var _hit_shots: Dictionary = {}    ## shot key -> true (counted as a hit)
var _shot_keys: Dictionary = {}    ## shot key -> pilot (counted as a shot)
var _hit_wait: Dictionary = {}     ## shot key -> pilot: a hit whose fire record has not been seen yet
var _hooked: Dictionary = {}       ## enemy instance id -> true
var _down_since: Dictionary = {}   ## pilot id -> mission clock when it went down
var _remote: Dictionary = {}       ## client pilot id -> {pt, t, hp: PackedFloat32Array, down, redeploy}
var _beam: Dictionary = {}         ## downed client pilot id -> [beaming pilot, clock]


## Authority (scripts/net/net.gd): the host decides every number (rows, the debrief, who left) and they reach the crew
## once, inside mission.end; the rest is the host's bookkeeping and wiring.
func net_fields() -> Dictionary:
	return {"flow": Net.LOCAL, "drive": Net.LOCAL, "world": Net.LOCAL, "rows": Net.OWNER, "pilots": Net.OWNER,
		"left": Net.OWNER, "frozen": Net.OWNER, "debrief": Net.OWNER, "unknown_revives": Net.LOCAL, "_t0": Net.PRIVATE,
		"_shooter": Net.PRIVATE, "_shooter_of": Net.PRIVATE, "_kill_src": Net.PRIVATE, "_hit_shots": Net.PRIVATE,
		"_shot_keys": Net.PRIVATE, "_hit_wait": Net.PRIVATE,
		"_hooked": Net.PRIVATE, "_down_since": Net.PRIVATE, "_remote": Net.PRIVATE, "_beam": Net.PRIVATE}


func _ready() -> void:
	process_physics_priority = 45   # after CrewSync fed / the puppets applied their snapshots


## Bind to the mission (MissionFlow.rebuild, deciding machine only): the pilot list, then every hook.
func setup(f: MissionFlow) -> void:
	flow = f
	drive = f.drive
	world = drive.combat.world if drive != null and drive.combat != null else null
	set_pilots(launch_pilots(f.crew))
	if world != null:
		world.fired.connect(_on_fired)
		world.hit_landed.connect(_on_hit_landed)
	if drive == null or drive.combat == null:
		return
	var sq := drive.combat.squad
	if sq != null:
		for e in sq.enemies:
			hook_enemy(e)
		sq.enemy_spawned.connect(hook_enemy)
	var me := CombatWorld.local_peer()
	if drive.combat.player_target != null:
		hook_owned(me, drive.combat.player_target)
	for id: int in drive.crew_bots:
		var cb := drive.crew_bots[id] as CrewBot
		if cb != null and cb.target != null:
			hook_owned(id, cb.target)
	if drive.crew_sync != null:
		for p: int in drive.crew_sync.targets:
			watch_remote(p, drive.crew_sync.targets[p] as PlayerTarget)
	if f.depots != null and f.depots.has_signal("core_granted"):
		f.depots.core_granted.connect(_on_core)
	if drive.has_signal("crew_member_left"):
		drive.crew_member_left.connect(pilot_left)


## The debrief's pilots: the launch crew (Session's crew as launched, seat order, bots by name) in a crew; this pilot solo.
static func launch_pilots(crewed: bool) -> Array:
	var out: Array = []
	var s := Net.session()
	if crewed and s != null:
		for e: Variant in s.mission.params.get("crew", []) as Array:
			if e is Dictionary and int((e as Dictionary).get("peer", 0)) != 0:
				out.append({"id": int(e["peer"]), "name": str((e as Dictionary).get("name", ""))})
	if out.is_empty():
		out.append({"id": CombatWorld.local_peer(), "name": s.display_name("Pilot") if s != null else "Pilot"})
	return out


## Fresh rows for `list` ([{id, name}]).
func set_pilots(list: Array) -> void:
	pilots = []
	rows = {}
	for p: Dictionary in list:
		var id := int(p["id"])
		pilots.append({"id": id, "name": str(p.get("name", ""))})
		var row := {}
		for k: String in STATS:
			row[k] = MIN_STATS.get(k, 0)
		row["damage_dealt"] = 0.0
		row["damage_taken"] = 0.0
		row["time_down"] = 0.0
		rows[str(id)] = row
		_shooter_of[id] = "player%d" % id


func add(pilot: int, stat: String, amount: float = 1.0) -> void:
	var row := _row(pilot)
	if row.is_empty():
		return
	var cur: Variant = row.get(stat, 0)
	row[stat] = float(cur) + amount if cur is float else int(cur) + roundi(amount)   # counts stay ints, amounts floats


func lower(pilot: int, stat: String, v: float) -> void:
	var row := _row(pilot)
	if not row.is_empty() and v < float(row.get(stat, INF)):
		row[stat] = v


func value(pilot: int, stat: String) -> Variant:
	return (rows.get(str(pilot), {}) as Dictionary).get(stat)


## The row of a pilot that may still count ({} otherwise).
func _row(pilot: int) -> Dictionary:
	if frozen or left.has(pilot):
		return {}
	return rows.get(str(pilot), {})


## Mission seconds since the release (0 before).
func mission_time() -> float:
	return 0.0 if is_nan(_t0) else maxf(_now() - _t0, 0.0)


func _now() -> float:
	return flow.now() if flow != null else 0.0


## A pilot left mid-mission (MissionScene.crew_member_left, host): its row stays, frozen as it is now.
func pilot_left(pilot: int) -> void:
	if frozen or not rows.has(str(pilot)) or left.has(pilot):
		return
	_close_down(pilot)
	left[pilot] = true


func pilot_of(shooter: String) -> int:
	var v: Variant = _shooter.get(shooter)
	if v != null:
		return int(v)
	var id := 0
	if shooter.begins_with("player") and shooter.substr(6).is_valid_int():
		id = int(shooter.substr(6))
		if not rows.has(str(id)):
			id = 0
	_shooter[shooter] = id
	return id


# --- Hooks -------------------------------------------------------------------------------------------------

func hook_enemy(e: Node) -> void:
	if not (e is EnemyBase) or _hooked.has(e.get_instance_id()):
		return
	_hooked[e.get_instance_id()] = true
	(e as EnemyBase).damaged.connect(_on_enemy_damaged.bind(e))
	(e as EnemyBase).destroyed_enemy.connect(_on_enemy_destroyed)


## A pilot this machine owns (its own mech, a host bot): exact from its PlayerTarget's signals.
func hook_owned(pilot: int, pt: PlayerTarget) -> void:
	if pt == null or not rows.has(str(pilot)):
		return
	pt.damaged.connect(_on_owned_damaged.bind(pilot, pt))
	pt.player_disabled.connect(func(_c: String) -> void: _went_down(pilot))
	pt.player_revived.connect(_on_owned_revived.bind(pilot, pt))
	pt.player_respawned.connect(func(_t: float, _held: bool) -> void:
		_close_down(pilot)
		add(pilot, "redeploys"))


## A client pilot (its puppet's PlayerTarget here gives the max HP per component).
func watch_remote(pilot: int, pt: PlayerTarget) -> void:
	if pt != null and rows.has(str(pilot)):
		_remote[pilot] = {"pt": pt, "t": -INF, "hp": PackedFloat32Array(), "down": false, "redeploy": false}


func _on_fired(record: Dictionary) -> void:
	if frozen or bool(record.get("enemy", false)) or not record.has("hardpoint") or not record.has("shot_index"):
		return
	var p := pilot_of(str(record.get("shooter", "")))
	if p == 0:
		return
	add(p, "shots")
	var key := Combat.shot_key(record)
	if _shot_keys.size() >= HIT_KEYS_MAX:
		_shot_keys.clear()
	_shot_keys[key] = p
	if _hit_wait.has(key):   # its hit arrived first (a client's hit can overtake its batched record)
		_hit_wait.erase(key)
		_count_hit(p, key)


## A hit counts only for a shot that was counted (hits <= shots by construction): one per shot key, on an EnemyBase. A hit
## whose record has not arrived yet waits for it (_hit_wait); one never matched (a staged test hit, a record the host
## refused) is never counted.
func _on_hit_landed(t: CombatTarget, h: Hit) -> void:
	if frozen or not (t is EnemyBase):
		return
	var p := pilot_of(h.shooter)
	if p == 0 or _hit_shots.has(h.shot):
		return
	if _shot_keys.has(h.shot):
		_count_hit(p, h.shot)
	else:
		if _hit_wait.size() >= HIT_KEYS_MAX:
			_hit_wait.clear()
		_hit_wait[h.shot] = p


func _count_hit(p: int, key: String) -> void:
	if _hit_shots.size() >= HIT_KEYS_MAX:
		_hit_shots.clear()
	_hit_shots[key] = true
	add(p, "hits")


func _on_enemy_damaged(amount: float, _component: String, src: String, e: EnemyBase) -> void:
	if frozen:
		return
	var p := pilot_of(src)
	if p != 0:
		add(p, "damage_dealt", amount)
		_kill_src[e.get_instance_id()] = [p, Engine.get_physics_frames()]
	elif src != "shock":
		_kill_src[e.get_instance_id()] = [0, Engine.get_physics_frames()]


func _on_enemy_destroyed(e: EnemyBase, _cause: String, _at: Vector3) -> void:
	var v: Variant = _kill_src.get(e.get_instance_id())
	_kill_src.erase(e.get_instance_id())
	if frozen or v == null or int(v[1]) != Engine.get_physics_frames() or int(v[0]) == 0:
		return
	var p := int(v[0])
	add(p, "kills")
	add(p, "kills_" + kind_group(e.enemy_type))


static func kind_group(enemy_type: String) -> String:
	if enemy_type == "dropship":
		return "drone"
	for g: String in KIND_GROUPS:   # catalog variants share their family: trooper_at, turret_sniper, strider_breacher
		if enemy_type == g or enemy_type.begins_with(g + "_"):
			return g
	return "other"


func _on_owned_damaged(amount: float, _component: String, _src: String, pilot: int, pt: PlayerTarget) -> void:
	add(pilot, "damage_taken", amount)
	lower(pilot, "hp_min", 100.0 * pt.total_hp() / maxf(pt.total_max_hp(), 0.001))


func _on_owned_revived(by: String, _time_down: float, pilot: int, pt: PlayerTarget) -> void:
	_close_down(pilot)
	if by != "" and by == pt.target_id:
		add(pilot, "self_revives")
	else:
		var giver := pilot_of(by)
		if giver != 0:
			add(giver, "revives")


func _went_down(pilot: int) -> void:
	if _row(pilot).is_empty() or _down_since.has(pilot):
		return
	add(pilot, "downs")
	_down_since[pilot] = _now()


func _close_down(pilot: int) -> void:
	if not _down_since.has(pilot):
		return
	add(pilot, "time_down", maxf(_now() - float(_down_since[pilot]), 0.0))
	_down_since.erase(pilot)


func _on_core(pilot_id: int, _depot_id: String) -> void:
	add(pilot_id, "cores")


func _physics_process(_dt: float) -> void:
	if frozen or flow == null:
		return
	if is_nan(_t0) and flow.released:
		_t0 = _now()
	if _remote.is_empty():
		return
	var s := Net.session()
	if s == null or s.mechs == null:
		return
	for p: int in _remote:
		var r: Dictionary = _remote[p]
		if bool(r["down"]) and not bool(r["redeploy"]):
			_watch_beams(p, r)
		var st := s.mechs.newest(p)
		if st != null and st.t != float(r["t"]):
			r["t"] = st.t
			take_snapshot(p, st.comp, st.disabled, st.redeploying)


## One new snapshot of client pilot `p`: component fractions (NetMechCodec.COMPONENTS order, -1 absent), downed and
## redeploying flags. Public for tests.
func take_snapshot(p: int, comp: PackedFloat32Array, disabled: bool, redeploying: bool) -> void:
	var r: Dictionary = _remote.get(p, {})
	var pt := r.get("pt") as PlayerTarget if not r.is_empty() and is_instance_valid(r.get("pt")) else null
	if pt == null or _row(p).is_empty():
		return
	var n := mini(comp.size(), NetMechCodec.COMPONENTS.size())
	var prev: PackedFloat32Array = r["hp"]
	var cur := PackedFloat32Array()
	cur.resize(n)
	var tot := 0.0
	var tot_max := 0.0
	var taken := 0.0
	for i in n:
		var f := comp[i]
		var mx := float(pt.max_hp.get(NetMechCodec.COMPONENTS[i], 0.0))
		if f < 0.0 or mx <= 0.0:
			cur[i] = -1.0
			continue
		var v := f * mx
		cur[i] = v
		tot += v
		tot_max += mx
		if prev.size() == n and prev[i] >= 0.0 and prev[i] > v:
			taken += prev[i] - v
	r["hp"] = cur
	var was_down := bool(r["down"])
	var stood_from_redeploy := false
	if disabled and not was_down:
		_went_down(p)
	elif was_down and not disabled:
		_close_down(p)
		if bool(r["redeploy"]):
			add(p, "redeploys")
			stood_from_redeploy = true
		else:
			_credit_remote_revive(p)
		_beam.erase(p)
	r["down"] = disabled
	r["redeploy"] = disabled and (redeploying or (was_down and bool(r["redeploy"])))
	if taken > 0.0 and not stood_from_redeploy:
		add(p, "damage_taken", taken)
	if tot_max > 0.0:
		lower(p, "hp_min", 100.0 * tot / tot_max)


func _watch_beams(p: int, r: Dictionary) -> void:
	if world == null:
		return
	var pt: Variant = r.get("pt")
	for q: int in _shooter_of:
		for d: RepairDrone in world.drones_of(str(_shooter_of[q])):
			if d.beamed().has(pt):
				_beam[p] = [q, _now()]
				return


func _credit_remote_revive(p: int) -> void:
	var b: Variant = _beam.get(p)
	if b == null or _now() - float(b[1]) > GIVEN_HOLD:
		unknown_revives += 1
		return
	if int(b[0]) == p:
		add(p, "self_revives")
	else:
		add(int(b[0]), "revives")


# --- The outcome --------------------------------------------------------------------------------------------

## The counters now, as the debrief's stats: {"<id>": {stat: number}} (a copy; open downs counted to now; kill kinds
## nobody has are left out, a kind someone has is 0 for the others). Every row lists its keys in key_order() (the board
## follows `labels`' order for the extra rows; Dictionaries keep insertion order through the wire).
func snapshot() -> Dictionary:
	var out := {}
	var order := key_order()
	for p: Dictionary in pilots:
		var id := int(p["id"])
		var src: Dictionary = rows[str(id)]
		var row := {}
		for k: String in order:
			row[k] = src.get(k, 0)
		if _down_since.has(id) and not left.has(id):
			row["time_down"] = float(row["time_down"]) + maxf(_now() - float(_down_since[id]), 0.0)
		for k: String in ["damage_dealt", "damage_taken", "time_down"]:
			row[k] = snappedf(float(row[k]), 0.1)
		row["hp_min"] = clampf(snappedf(float(row["hp_min"]), 0.1), 0.0, 100.0)
		out[str(id)] = row
	return out


## The debrief's key order: the board's nine (CORE), then kills_<kind> in KIND_GROUPS order (only kinds someone killed;
## kills_other last), then TAIL.
func key_order() -> Array:
	var out: Array = CORE.duplicate()
	for g: String in KIND_GROUPS + ["other"]:
		var k := "kills_" + g
		for id: String in rows:
			if (rows[id] as Dictionary).has(k):
				out.append(k)
				break
	out.append_array(TAIL)
	return out


## The outcome: freeze the counters and build the debrief payload once (NetMission DEBRIEF v1, plus `left` on a leaver's
## pilot entry and `labels` for the extra keys). A second call returns the same payload.
func finish(outcome: String, reason: String) -> Dictionary:
	if frozen:
		return debrief
	var s := Net.session()
	var list: Array = []
	for p: Dictionary in pilots:
		var id := int(p["id"])
		var e := {"id": id, "name": str(p["name"]), "bot": id < 0}
		if left.has(id) or (flow != null and flow.crew and s != null and s.online() and not s.has_member(id)):
			e["left"] = true
		list.append(e)
	var stats := snapshot()
	frozen = true
	var labels := {}   # in key_order(): the board orders its extra rows by this map's keys
	for k: String in key_order():
		if LABELS.has(k):
			labels[k] = LABELS[k]
	debrief = {"v": 1, "outcome": outcome, "reason": reason, "time": snappedf(mission_time(), 0.1), "pilots": list,
		"stats": stats, "labels": labels}
	CombatLog.note_debrief(debrief)
	return debrief
