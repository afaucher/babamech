class_name PacingFacts
extends RefCounted
## The host's view of the fight for the PacingDirector (docs/design/pacing-director.md 1.2): who is engaged, how many
## enemies engage the crew and are in play per deck, kills since the last read, and each pilot's structure / heat from the
## state the host already has (its own PlayerTarget, teammates' puppets mirrored from their owner's stream). No new
## messages: everything is read on the host. Host bookkeeping only (PRIVATE / LOCAL), recomputed every evaluate.
##
## engaged (per pilot): a host-owned enemy fired at the pilot (CombatWorld.fired with the enemy's _target_id), or an awake
## enemy with the pilot as its target was within PilotIntensity.ENGAGE_RANGE, in the last PilotIntensity.ENGAGE_HOLD s.
## A staged unit (closed gate bay) is not awake: it never engages. in play (per deck, only on a deck with a standing
## mech): wave units (staged included) and garrison units that are alerted or within IN_PLAY_RANGE of a standing mech.

const IN_PLAY_RANGE := 150.0   ## m: idle garrison farther than this from every standing mech does not count for the deck cap

var world: CombatWorld
var _now: Callable              ## the mission clock (MissionFlow.now)
var _eng_p: Dictionary = {}     ## pilot target id -> t last engaged
var _eng_e: Dictionary = {}     ## enemy instance id -> t it last engaged someone
var _alive: Dictionary = {}     ## enemy instance id -> EnemyBase (alive at the last read)
var _kills: Array = []          ## [{deck, x, s}] since the last read
var _scouts: Dictionary = {}    ## drone instance id -> true (comms_relayed connected)
var scout_call: Callable        ## (deck, x, s, scout id) on a completed beacon (MissionFlow -> PacingDirector)


func net_fields() -> Dictionary:
	return {"world": Net.LOCAL, "_now": Net.LOCAL, "_eng_p": Net.PRIVATE, "_eng_e": Net.PRIVATE, "_alive": Net.PRIVATE,
		"_kills": Net.PRIVATE, "_scouts": Net.PRIVATE, "scout_call": Net.LOCAL}


func bind(w: CombatWorld, now_fn: Callable) -> void:
	world = w
	_now = now_fn
	if world != null and not world.fired.is_connected(_on_fired):
		world.fired.connect(_on_fired)


func unbind() -> void:
	if world != null and is_instance_valid(world) and world.fired.is_connected(_on_fired):
		world.fired.disconnect(_on_fired)
	world = null


## Host: pilot `pilot_id` left the crew: forget when its target was last engaged (its target id, "player<id>").
func forget_pilot(pilot_id: int) -> void:
	_eng_p.erase("player%d" % pilot_id)


func _t() -> float:
	return float(_now.call()) if _now.is_valid() else 0.0


func _on_fired(record: Dictionary) -> void:
	if not bool(record.get("enemy", false)) or world == null:
		return
	var sh := str(record.get("shooter", ""))
	for t in world.targets:
		if is_instance_valid(t) and t is EnemyBase and t.target_id == sh:
			var e := t as EnemyBase
			if not world.owns(e) or e.current_target_id() == "":
				return
			var now := _t()
			_eng_p[e.current_target_id()] = now
			_eng_e[e.get_instance_id()] = now
			return


## The facts for one director tick. `pilots`: [{peer, target: PlayerTarget, mech: MechController, deck, x, s, downed}];
## `stack`: CityStack (deck / arc of enemies). Returns {"pilots": {peer: {...}}, "engaging": [], "active": [], "kills": []}.
func collect(pilots: Array, stack: Node, live: Array, decks: int) -> Dictionary:
	var now := _t()
	var engaging: Array[int] = []
	var active: Array[int] = []
	engaging.resize(decks)
	engaging.fill(0)
	active.resize(decks)
	active.fill(0)
	var tid_pos := {}
	var tid_deck := {}
	for p: Dictionary in pilots:
		var pt := _live(p.get("target")) as PlayerTarget
		var mech := _live(p.get("mech")) as Node3D
		# Standing: not downed, and its mech still exists (a freed controller's pilot is treated as not standing).
		if pt != null and mech != null and not bool(p.get("downed", false)):
			tid_pos[pt.target_id] = mech.global_position
			tid_deck[pt.target_id] = int(p.get("deck", -1))
	var seen := {}
	for e: EnemyBase in live:
		var iid := e.get_instance_id()
		seen[iid] = true
		if not _alive.has(iid):
			_alive[iid] = e
			if e is EnemyDrone and not _scouts.has(iid):
				_scouts[iid] = true
				e.comms_relayed.connect(_on_relayed.bind(stack))
		var pos := e.global_position if e.is_inside_tree() else e.position
		var k := clampi(e.spawn_deck, 0, decks - 1)
		var tid := e.current_target_id()
		if tid != "" and tid_pos.has(tid) and e.is_awake() \
				and pos.distance_to(tid_pos[tid]) <= PilotIntensity.ENGAGE_RANGE:
			_eng_p[tid] = now
			_eng_e[iid] = now
		if PilotIntensity.engaged(now, float(_eng_e.get(iid, -INF))):
			engaging[k] += 1
		# In play only on a deck with a standing pilot (defend balance 2026-11-24: 17 wave units stuck on a deck the crew
		# had left counted against SECTION_CAP); the alive ceilings still count them.
		var in_play := e.wave != "" or e.is_alerted()
		if e.squad != null and e.squad.has_method("min_crew_dist_sq"):
			var d2 := float(e.squad.min_crew_dist_sq(pos, e.spawn_deck))
			in_play = d2 >= 0.0 and (in_play or d2 <= IN_PLAY_RANGE * IN_PLAY_RANGE)
		if in_play:
			active[k] += 1
	# Kills: alive at the last read, destroyed now (or gone).
	for iid: int in _alive.keys():
		if seen.has(iid):
			continue
		var e: Variant = _alive[iid]
		_alive.erase(iid)
		_eng_e.erase(iid)
		if e != null and is_instance_valid(e) and stack != null:
			var a: Dictionary = stack.to_deck_arc((e as Node3D).global_position)
			_kills.append({"deck": int(a["deck"]), "x": float(a["x"]), "s": float(a["s"])})
	var pf := {}
	for p: Dictionary in pilots:
		var pt := _live(p.get("target")) as PlayerTarget
		var mech := _live(p.get("mech"))
		var tot := 100.0
		var destroyed := 0
		if pt != null:
			var hp := 0.0
			var mx := 0.0
			for c: Variant in pt.max_hp:
				var m := float(pt.max_hp[c])
				if m <= 0.0:
					continue
				mx += m
				hp += clampf(float(pt.hp.get(c, 0.0)), 0.0, m)
				if float(pt.hp.get(c, 0.0)) <= 0.0:
					destroyed += 1
			tot = 100.0 * hp / mx if mx > 0.0 else 100.0
		var shut := false
		if mech != null:
			shut = bool(mech.get("shutdown")) if mech.get("shutdown") != null else false
		var down := bool(p.get("downed", false)) or mech == null   # no mech: not standing
		var eng := false
		if pt != null and not down:   # downed: never engaged (DownedRules)
			eng = PilotIntensity.engaged(now, float(_eng_p.get(pt.target_id, -INF)))
		pf[str(p["peer"])] = {"tot": snappedf(tot, 0.1), "destroyed": destroyed,
				"disabled": down, "shutdown": shut, "engaged": eng}
	var kills := _kills
	_kills = []
	return {"pilots": pf, "engaging": engaging, "active": active, "kills": kills}


## `v` when it is a live object, else null. Stored references (a crew member's mech or target, an enemy) are read through
## this BEFORE any `is` / `as`: either raises on a freed instance.
static func _live(v: Variant) -> Object:
	return v as Object if is_instance_valid(v) else null


func _on_relayed(e: EnemyBase, stack: Node) -> void:
	if not scout_call.is_valid() or e == null or not is_instance_valid(e) or stack == null:
		return
	var a: Dictionary = stack.to_deck_arc(e.global_position)
	scout_call.call(int(a["deck"]), float(a["x"]), float(a["s"]), e.target_id)
