class_name MissionBays
extends RefCounted
## Host: a wave door never closes on a unit (playtest R2.4: "the door must not close until every staged unit is out, and a
## unit left inside must be pushed out or counted as gone"; docs/design/pacing-director.md 1.6b "Nobody is shut in").
## One per MissionFlow (flow.bays). MissionFlow tracks every door a staged group rolled out of (gate bays, lift cars once
## Environment builds them: any source whose MissionWorld.source_bay(id) is `ok`), and ticks this on the host:
##   1. HOLD: while any live unit is inside the bay or in the doorway (bay_contains, else the bay frame: |x| <= half width
##      + the wall margin, 0..BAY_DEPTH m behind the door plane; doorway: DOORWAY m either side of it, inside the jambs),
##      the door is kept open at least KEEP s ahead (MissionFlow.hold_door: replicated, every machine holds it), up to
##      HARD_LIMIT s past its normal close (the last roll-out + ROLL_OUT_HOLD).
##   2. PUSH: past that limit, with the door still open, every unit still inside walks out kinematically along the door
##      line to the bay's exit (EnemyBase.roll_out with BayFormation.exit_path from where it stands), the door held while
##      it does (at most PUSH_MAX s).
##   3. REMOVE: what is still inside after the push, or inside a door that is closing / shut / sealed anyway, is withdrawn
##      (EnemySquad.withdraw: no death, no kill credit, no wreck; a `[mission] bay` line + a CombatLog `source` note), so a
##      deck's sweep and the director's "group beaten" never wait on a unit behind a shut door. A unit at most
##      PUSH_DEPTH m inside a closing door (in the door line) is pushed out instead (the leaves have no collision while
##      they close: Environment). Wrecks inside a shut bay are cleared too.
##   4. NO WAY BACK IN: a unit that is out (not staged, not rolling out) found inside an open bay is pushed out at once,
##      unless it is after a crew mech standing inside that bay (then it counts for the hold like any other).
##   5. CREW (R2.22 / R2.4 for pilots): a door with an interior (every wave gate with a bay, every lift with a car: any
##      plan source whose source_bay is `ok`; never a sealed one; the entry / exit road doors are the extraction rules')
##      is never closed on a crew mech: while a crew mech (standing, downed or redeploying) is inside its bay / car or in
##      its doorway (crew_inside), the door is held open KEEP s ahead, with NO limit (a pilot is never pushed or
##      withdrawn); a door that is closing / shut with a crew mech inside is ordered open again (MissionFlow.reopen_door:
##      replicated). busy_sources() lists those doors for the director, which then picks another source (or the group
##      waits): a group is never staged onto a pilot.
## Pure host bookkeeping: positions come from the squad, doors from MissionWorld; nothing here is sent but the holds.

const STEP := 0.25           ## s between checks
const KEEP := 4.0            ## s the door is kept open ahead while anyone is inside ...
const RESEND := 2.5          ## ... re-held when less than this is left (few hold messages)
const HARD_LIMIT := 30.0     ## s past the door's normal close before units still inside are pushed out
const PUSH_MAX := 10.0       ## s the push-out may take, then what is still inside is withdrawn
const DOORWAY := 1.5         ## m either side of the door plane that counts as the doorway
const BAY_DEPTH := 26.0      ## m behind the door plane a bay reaches (MissionGateDoor.BAY_DEPTH), without bay_contains
const WALL_MARGIN := 1.0     ## m: source_bay's half_width is the usable floor; the walls stand this much further out
const PUSH_DEPTH := 3.0      ## m: a unit this close behind a closing door's plane is pushed out, deeper ones withdrawn
const REENTRY_DEPTH := 2.0   ## m behind the door plane before a unit that was out counts as walking back in
const REOPEN_LEAD := 1.0     ## s from the host's re-open order to the leaves moving (the order reaches every machine first)

var flow: MissionFlow
var _bays := {}              ## src -> {world (source_bay), arc (BayFormation bay), deck, normal_close, push_until, pushed}
var _acc := 0.0
var events: Array = []       ## [{t, src, ev: hold | push | reentry | removed | wreck | crew_hold | crew_reopen, id, kind}]
var _interior: Array = []    ## plan source ids whose door has an interior (source_bay ok): rule 5's doors (built once)
var _interior_ok := false
var _crew_held := {}         ## src -> true while rule 5 holds it (one log line per stay)


func net_fields() -> Dictionary:
	return {"flow": Net.LOCAL, "_bays": Net.PRIVATE, "_acc": Net.PRIVATE, "events": Net.PRIVATE,
		"_interior": Net.PRIVATE, "_interior_ok": Net.PRIVATE, "_crew_held": Net.PRIVATE}


func _init(f: MissionFlow = null) -> void:
	flow = f


func reset() -> void:
	_bays = {}
	_acc = 0.0
	events = []
	_interior = []
	_interior_ok = false
	_crew_held = {}


## A staged group rolled out of source `src` (MissionFlow._roll_due): watch its door until it is shut with nobody inside.
## `normal_close`: when the door would close for this roll-out (its HARD_LIMIT counts from the latest one).
func track(src: String, normal_close: float, world_bay: Dictionary, arc_bay: Dictionary) -> void:
	if world_bay.is_empty() or not bool(world_bay.get("ok", false)) or arc_bay.is_empty():
		return
	var b: Dictionary = _bays.get(src, {})
	if b.is_empty():
		b = {"world": world_bay, "arc": arc_bay, "deck": int(world_bay.get("deck", 0)), "normal_close": normal_close,
			"push_until": INF, "pushed": {}, "held": false}
		_bays[src] = b
	else:
		b["world"] = world_bay
		b["arc"] = arc_bay
		b["normal_close"] = maxf(float(b["normal_close"]), normal_close)
		b["push_until"] = INF
		b["pushed"] = {}


## Sources watched now (tests).
func watched() -> Array:
	return _bays.keys()


## {inside, doorway, depth (m behind the door plane), x (m along the wall)} of world point `pos` for bay `src` (Environment's
## MissionWorld.bay_contains when it exists, else the bay frame from source_bay).
func contains(src: String, pos: Vector3) -> Dictionary:
	var b: Dictionary = _bays.get(src, {})
	if b.is_empty():
		return {"inside": false, "doorway": false, "depth": -INF, "x": 0.0}
	return contains_in(b["world"], pos, flow.world if flow != null else null, src)


## As contains, for a source_bay dictionary `wb` (static: tests use synthetic bays). `mw` (optional): its bay_contains wins.
static func contains_in(wb: Dictionary, pos: Vector3, mw: Object = null, src: String = "") -> Dictionary:
	if mw != null and src != "" and mw.has_method("bay_contains"):
		var r: Variant = mw.call("bay_contains", src, pos)
		if r is Dictionary and (r as Dictionary).has("inside"):
			var d := (r as Dictionary).duplicate()
			d["depth"] = float(d.get("depth", 0.0))
			d["x"] = float(d.get("x", 0.0))
			return d
	var fr: Variant = wb.get("frame")
	if not (fr is Transform3D):
		return {"inside": false, "doorway": false, "depth": -INF, "x": 0.0}
	var l := (fr as Transform3D).affine_inverse() * pos
	var depth := -l.z
	var hw := float(wb.get("half_width", 10.0)) + WALL_MARGIN
	var reach := float(wb.get("bay_depth", BAY_DEPTH))
	var tall := float(wb.get("height", 18.0)) + 3.0
	var in_y := l.y > -3.0 and l.y < tall
	var inside := in_y and absf(l.x) <= hw and depth >= 0.0 and depth <= reach
	var doorway := in_y and absf(depth) <= DOORWAY and absf(l.x) <= float(wb.get("door_w", 12.0)) * 0.5
	return {"inside": inside, "doorway": doorway, "depth": depth, "x": l.x}


func tick(dt: float) -> void:
	if flow == null or flow.world == null:
		return
	_acc += dt
	if _acc < STEP:
		return
	_acc = 0.0
	var t := flow.world.now
	_crew_step(t)
	if _bays.is_empty():
		return
	var squad := _squad()
	if squad == null:
		return
	var crew_in := _crew_inside()
	for src: String in _bays.keys():
		_step(src, _bays[src], squad, t, crew_in.get(src, {}))


func _step(src: String, b: Dictionary, squad: EnemySquad, t: float, crew_in: Dictionary) -> void:
	var st := flow.world.source_state(src)
	var state := str(st.get("state", ""))
	var occ: Array = []          # [e, info] live units inside / in the doorway (staged ones wait for their roll-out)
	var wrecks: Array = []
	for e in squad.enemies:
		if not is_instance_valid(e) or e.is_queued_for_deletion() or e.puppet or e.spawn_deck != int(b["deck"]):
			continue
		var pos := e.global_position if e.is_inside_tree() else e.position
		var info := contains(src, pos)
		if not bool(info["inside"]) and not bool(info["doorway"]):
			continue
		if e.destroyed():
			wrecks.append(e)
		elif not e.staged:
			occ.append([e, info])
	var passable := state == "open"
	var due_open := state == "warn" or state == "opening"
	var pushed: Dictionary = b["pushed"]
	if passable:
		# 4. No way back in: out units walking into an open bay are walked out again (unless after a crew mech in it).
		for it: Array in occ:
			var e := it[0] as EnemyBase
			var info: Dictionary = it[1]
			if e.is_rolling_out() or pushed.has(e.get_instance_id()) or float(info["depth"]) < REENTRY_DEPTH:
				continue
			if crew_in.has(e.current_target_id()):
				continue
			_push(src, b, e, info, "reentry", t)
		if not occ.is_empty():
			# 1. Hold, 2. push past the hard limit, 3. withdraw what the push left inside.
			var limit := float(b["normal_close"]) + HARD_LIMIT
			if t >= limit:
				if float(b["push_until"]) == INF:
					b["push_until"] = t + PUSH_MAX
					for it: Array in occ:
						if not pushed.has((it[0] as EnemyBase).get_instance_id()):
							_push(src, b, it[0], it[1], "push", t)
				if t >= float(b["push_until"]):
					for it: Array in occ:
						_remove(src, squad, it[0], "held_too_long", t)
					occ = []
			if not occ.is_empty():
				var close_at := float(st.get("close_at", INF))
				if close_at - t < RESEND:
					flow.hold_door(src, t + KEEP)
					if not bool(b["held"]):
						b["held"] = true
						_note(src, "hold", null, t, "%d inside" % occ.size())
		else:
			b["held"] = false
		return
	if due_open:
		return   # it is about to open: whoever is inside walks out then
	# Closing / shut / sealed (our hold lapsed or something closed it): nobody stays behind the leaves.
	for it: Array in occ:
		var e := it[0] as EnemyBase
		var info: Dictionary = it[1]
		if state == "closing" and float(info["depth"]) <= PUSH_DEPTH:
			if not e.is_rolling_out():
				_push(src, b, e, info, "push", t)
		elif float(info["depth"]) > 0.0:
			_remove(src, squad, e, "door_" + state, t)
	if state == "shut" or state == "sealed":
		for w: EnemyBase in wrecks:
			var pos := w.global_position if w.is_inside_tree() else w.position
			if float(contains(src, pos)["depth"]) > 0.0:
				squad.remove_enemy(w)
				if squad.world != null:
					squad.world.unregister(w)
				w.queue_free()
				_note(src, "wreck", w, t, "")
		if occ.is_empty() and t > float(b["normal_close"]):
			_bays.erase(src)


## Walk `e` out of bay `src` from where it stands: its lane in the door, LANE_OUT m past it, then the bay's exit.
func _push(src: String, b: Dictionary, e: EnemyBase, _info: Dictionary, why: String, t: float) -> void:
	var path := push_path(b["arc"], e, flow.drive.stack if flow.drive != null else null)
	if path.is_empty():
		return
	(b["pushed"] as Dictionary)[e.get_instance_id()] = true
	e.roll_out(path, 0.0)
	_note(src, why, e, t, "")


## The push-out path (arc x, s, h of the unit's deck) of unit `e` in bay `arc_bay` (BayFormation's bay), [] without a stack.
static func push_path(arc_bay: Dictionary, e: EnemyBase, stack: CityStack) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if stack == null or arc_bay.is_empty():
		return out
	var pos := e.global_position if e.is_inside_tree() else e.position
	var a := stack.to_deck_arc(pos)
	var p := Vector2(float(a["x"]), float(a["s"]))
	var o: Vector2 = arc_bay["out"]
	var right := Vector2(-o.y, o.x)
	var rel := p - (arc_bay["door"] as Vector2)
	var kind := e.enemy_type
	var air := BayFormation.is_air(kind)
	var slot := {"kind": kind, "r": BayFormation.radius_of(kind), "u": rel.dot(right), "v": -rel.dot(o), "row": 0,
		"h": clampf(float(a.get("h", 0.0)) - CityPlan.CURB_H, 1.5, BayFormation.FLIER_H) if air else 0.0}
	var cruise := CityPlan.CURB_H + (EnemySpawner.GUNSHIP_CRUISE_ALT if kind == "gunship" else EnemySpawner.DRONE_CRUISE_ALT)
	return BayFormation.exit_path(arc_bay, slot, cruise, CityPlan.CURB_H)


func _remove(src: String, squad: EnemySquad, e: EnemyBase, why: String, t: float) -> void:
	var id := e.target_id
	var kind := e.enemy_type
	if squad.withdraw(e, "bay:" + why):
		events.append({"t": t, "src": src, "ev": "removed", "id": id, "kind": kind, "why": why})
		print("[mission] bay %s: %s (%s) removed, counted gone (%s)" % [src, id, kind, why])
		CombatLog.note_source("removed", src, id, kind, why)


func _note(src: String, ev: String, e: EnemyBase, t: float, extra: String) -> void:
	var id := e.target_id if e != null else ""
	var kind := e.enemy_type if e != null else ""
	events.append({"t": t, "src": src, "ev": ev, "id": id, "kind": kind, "why": extra})
	print("[mission] bay %s: %s %s %s" % [src, ev, id if id != "" else extra, kind])
	CombatLog.note_source(ev, src, id, kind, extra)


func _squad() -> EnemySquad:
	if flow.drive == null or flow.drive.combat == null:
		return null
	var sq: Variant = flow.drive.combat.squad
	return sq as EnemySquad if is_instance_valid(sq) else null


## src -> {crew target id: true} for crew mechs standing inside a watched bay (rule 4's exception).
func _crew_inside() -> Dictionary:
	var out := {}
	var sq := _squad()
	if sq == null or sq.world == null:
		return out
	for t: CombatTarget in sq.world.targets:
		if not is_instance_valid(t) or t.team != "player" or (t is AssetTarget) or not t.is_hittable():
			continue
		for src: String in _bays:
			if bool(contains(src, t.global_position)["inside"]):
				if not out.has(src):
					out[src] = {}
				out[src][t.target_id] = true
	return out


# --- Rule 5: never closed on a crew mech -------------------------------------------------------------------------------

## True while any crew mech of this machine's crew (MissionScene.crew_members: the local mech, the host's bots, the
## puppets; standing, downed or redeploying) is inside door `id`'s bay / car or in its doorway (MissionWorld.bay_contains:
## gates, lift cars, the entry / exit road doors alike). The extraction rules may call it for the road doors.
func crew_inside(id: String) -> bool:
	if flow == null or flow.world == null or flow.drive == null:
		return false
	var k := _door_deck(id)
	for c: Array in _crew_positions():
		if (k < 0 or int(c[1]) < 0 or int(c[1]) == k) and _in_door(id, c[0]):
			return true
	return false


## Doors with an interior that have a crew mech inside or in the doorway now: {src: true} (the director's facts: it picks
## another source for a release, a follow-up load waits).
func busy_sources() -> Dictionary:
	var out := {}
	if flow == null or flow.world == null or flow.drive == null:
		return out
	var ps := _crew_positions()
	if ps.is_empty():
		return out
	for src: String in _interior_ids():
		var k := _door_deck(src)
		for c: Array in ps:
			if (k < 0 or int(c[1]) < 0 or int(c[1]) == k) and _in_door(src, c[0]):
				out[src] = true
				break
	return out


## The deck door `id` is on (-1 unknown): a crew mech is only tested against doors of its own deck (bay_contains works in
## the door's own ring frame, so a mech on another deck near the same wall could read as inside).
func _door_deck(id: String) -> int:
	var sp := flow.world.source_point(id)
	return int(sp.get("deck", -1)) if not sp.is_empty() else -1


func _in_door(id: String, p: Vector3) -> bool:
	var bc: Dictionary = flow.world.bay_contains(id, p)
	return bool(bc.get("inside", false)) or bool(bc.get("doorway", false))


## [[world position, deck]] of every crew mech of this machine's crew (deck -1 without a stack).
func _crew_positions() -> Array:
	var out: Array = []
	if flow.drive == null or not flow.drive.has_method("crew_members"):
		return out
	var stack: CityStack = flow.drive.stack
	for c: Dictionary in flow.drive.crew_members():
		var m: Variant = c.get("mech")
		if m is Node3D and is_instance_valid(m):
			var p := (m as Node3D).global_position if (m as Node3D).is_inside_tree() else (m as Node3D).position
			out.append([p, int(stack.to_deck_arc(p)["deck"]) if stack != null else -1])
	return out


func _interior_ids() -> Array:
	if _interior_ok:
		return _interior
	_interior = []
	if flow.plan == null:
		return _interior
	for s: Dictionary in flow.plan.sources:
		var id := str(s.get("id", ""))
		var kind := str(s.get("kind", ""))
		if (kind == "gate" or kind == "lift") and bool(flow.world.source_bay(id).get("ok", false)):
			_interior.append(id)
	_interior_ok = true
	return _interior


## Rule 5, host, every STEP: hold (no limit) or re-open every door with an interior that has a crew mech in it.
func _crew_step(t: float) -> void:
	var busy := busy_sources()
	for src: String in _crew_held.keys():
		if not busy.has(src):
			_crew_held.erase(src)
	for src: String in busy:
		var st := flow.world.source_state(src)
		var state := str(st.get("state", ""))
		if state == "sealed":
			continue
		if state == "open" or state == "opening" or state == "warn":
			if float(st.get("close_at", INF)) - t < RESEND:
				flow.hold_door(src, t + KEEP)
				if not _crew_held.has(src):
					_crew_held[src] = true
					_note(src, "crew_hold", null, t, "crew inside")
			continue
		# Closing or shut with a pilot inside (respawned there, a late door state): open it again, unless that is due.
		var oa := float(st.get("open_at", INF))
		if oa != INF and oa > t:
			continue
		flow.reopen_door(src, t + REOPEN_LEAD)
		_crew_held[src] = true
		_note(src, "crew_reopen", null, t, "crew inside a %s door" % state)
