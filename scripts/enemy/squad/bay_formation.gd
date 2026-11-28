class_name BayFormation
extends RefCounted
## Where a reinforcement group stands inside a closed gate bay, and how it rolls out (docs/design/pacing-director.md,
## "Staging in gate bays"; user: "the door opens to reveal the enemies ... not a tight clump and not a straight line, ready
## to roll out"). PURE: positions from the bay rectangle, the unit kinds and a seeded generator (the mission-seed gameplay
## RNG, drawn in a fixed order: per unit, lateral jitter then depth jitter), so the layout never depends on frame timing.
##
## bay (arc coordinates of the bay's deck; from_world_bay(MissionWorld.source_bay(id)), else fallback_bay() from a plain
## recess): {out: Vector2 (unit, into the deck), door: Vector2 (mid-gate on the wall plane), half (usable lateral half
## width: every footprint inside +-half), v_min, v_max (usable metres behind the wall plane: every footprint inside),
## height, door_w, door_h, exit: Vector2 (street point in front of the door)}.
## Layout: staggered rows facing `out`, filled from the front (the door side) back; in each row the heaviest units sit in
## the middle; spacing from each kind's clearance radius (EnemySpawner.*_CLEAR) + GAP + 2 x JITTER, so the jitter can never
## make two footprints overlap; every footprint inside the usable rectangle: source_bay's half_width x [depth_from,
## depth_to] (the coordinator's agreed rule; that keeps GateDoor.MARGIN 1 m from the side walls, 2 m from the back wall
## and 8 m behind the wall plane, past the leaves; DOOR_MARGIN 4 m is the floor for any other bay). Odd rows shift sideways by half a slot (stagger). Units that do not fit are left out (the caller's
## follow-up load). Fliers stand in the same slots, hovering FLIER_H low (under the lintel).
## Roll-out: row by row (ROW_STAGGER s apart, COL_STAGGER within a row, front first), each unit funnels to its lane inside
## the door opening (lateral clamped to door_w / 2 - radius - LANE_MARGIN), walks LANE_OUT m past the door plane, then to the
## bay's street exit fanned by lane; fliers keep under the lintel to past the door, then climb to their cruise height.

const DOOR_MARGIN := 4.0     ## m: footprint edge behind the door plane
const GAP := 1.0             ## m between two footprints (before jitter)
const JITTER := 0.4          ## m: the most a unit moves off its spot (seeded; spacing reserves it on both units)
const ROW_JITTER := 1.5      ## m: a unit starts its search up to this much deeper than the front (seeded): loose rows
const USTEP := 0.5           ## m lateral scan step
const VSTEP := 0.5           ## m depth scan step
const ROW_BAND := 5.0        ## m of depth per roll-out row
const ROW_STAGGER := 0.8     ## s between rows leaving
const COL_STAGGER := 0.25    ## s between units of one row
const LANE_MARGIN := 0.6     ## m between a unit's footprint and the door jamb
const LANE_OUT := 6.0        ## m past the door plane before fanning to the exit
const FLIER_H := 4.0         ## m: fliers hover this low in the bay (capped under the door's lintel)
const LINTEL_CLEAR := 2.0    ## m under door_h a flier's body keeps
const HEAVY := ["tank", "gunship"]
const FALLBACK := {"half": 5.0, "v_min": 1.0, "v_max": 5.0, "height": 10.0, "door_w": 10.0, "door_h": 10.0}   ## a plain 6 m recess


## The bay of a gate from Environment's MissionWorld.source_bay(id) dictionary (`ok` true; arc keys origin, out, door,
## half_width, depth_from, depth_to, door_w, door_h, height; `exit_arc` added by the caller from the world `exit`).
static func from_world_bay(b: Dictionary) -> Dictionary:
	var o: Variant = b.get("origin")
	var out_v: Variant = b.get("out")
	var origin := o as Vector2 if o is Vector2 else Vector2(float(b.get("x", 0.0)), float(b.get("s", 0.0)))
	var out := (out_v as Vector2).normalized() if out_v is Vector2 and (out_v as Vector2).length() > 0.01 else Vector2(0, 1)
	var d_from := float(b.get("depth_from", 8.0))
	var d_to := float(b.get("depth_to", d_from + float(b.get("depth", 16.0))))
	var door := origin + out * (d_from + d_to) * 0.5
	if b.get("door") is Vector2:
		door = b["door"]
	var ex: Variant = b.get("exit_arc")
	var exit := ex as Vector2 if ex is Vector2 else door + out * 6.0
	var hw := float(b.get("half_width", float(b.get("width", 20.0)) * 0.5))
	var margin := float(b.get("door_margin", DOOR_MARGIN))   # a lift car (no leaves inside): MissionFlow passes 1 m
	return {"out": out, "door": door, "exit": exit, "door_margin": margin,
			"half": maxf(hw, 0.0), "v_min": maxf(d_from, margin), "v_max": d_to,
			"height": float(b.get("height", 12.0)), "door_w": float(b.get("door_w", hw * 2.0)),
			"door_h": float(b.get("door_h", b.get("height", 12.0)))}


## A world without source_bay: a small rectangle in a plain recess. `point`: MissionWorld.source_point (`behind` m behind
## the wall plane), `front`: the plan source's point (inside the wall, on the road line).
static func fallback_bay(point: Vector2, front: Vector2, behind: float = 3.0) -> Dictionary:
	var out := (front - point).normalized() if front.distance_to(point) > 0.1 else Vector2(0, 1)
	var door := point + out * behind
	var b := FALLBACK.duplicate()
	b["out"] = out
	b["door"] = door
	b["exit"] = door + out * 6.0
	return b


## Clearance radius of a unit kind (EnemySpawner's constants).
static func radius_of(kind: String) -> float:
	if kind == "tank":
		return EnemySpawner.TANK_CLEAR
	if kind == "gunship":
		return EnemySpawner.GUNSHIP_CLEAR
	if kind == "drone":
		return EnemySpawner.DRONE_CLEAR
	if kind.begins_with("trooper_"):
		return EnemySpawner.TROOP_CLEAR
	return EnemySpawner.STRIDER_CLEAR


static func is_air(kind: String) -> bool:
	return kind == "drone" or kind == "gunship"


## Slots for `kinds` (the result keeps their order): [{i, kind, r, u (lateral, + = right of out), v (behind the door
## plane), row, col, arc: Vector2, h}] for those that fit; the rest are left out. Greedy front-first packing, heaviest
## first: each unit takes the first free spot scanning from the door side back (VSTEP) and from the centre outward (USTEP),
## starting a seeded 0..ROW_JITTER m deeper than the front (loose, staggered, never a straight line); spots keep GAP between
## footprints grown by JITTER, then each unit moves by a seeded offset of at most JITTER (so jitter never overlaps).
static func layout(bay: Dictionary, kinds: Array, rng: RandomNumberGenerator) -> Array[Dictionary]:
	var out: Vector2 = bay["out"]
	var right := Vector2(-out.y, out.x)
	var door: Vector2 = bay["door"]
	var half := float(bay["half"])
	var v_min := float(bay["v_min"])
	var v_max := float(bay["v_max"])
	var order: Array = []
	for i in kinds.size():
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		var ra := radius_of(str(kinds[a]))
		var rb := radius_of(str(kinds[b]))
		return ra > rb if absf(ra - rb) > 0.01 else a < b)
	var spots: Array = []      # [u, v, r grown, idx]
	for idx: int in order:
		var kind := str(kinds[idx])
		var r := radius_of(kind) + JITTER
		var v0 := v_min + (rng.randf() * ROW_JITTER if not spots.is_empty() else 0.0)   # the heaviest leads at the front
		var ja := rng.randf() * TAU
		var jr := sqrt(rng.randf()) * JITTER
		var found := false
		var v := v0 + r
		var retried := false
		while not found:
			if v > v_max - r + 0.001:
				if retried or v0 <= v_min:
					break
				retried = true   # no room behind its seeded start: search again from the front
				v = v_min + r
				continue
			var lim := half - r
			var n := int(floor(maxf(lim, 0.0) / USTEP))
			for j in 2 * n + 1:
				var u := float((j + 1) / 2) * USTEP * (1.0 if j % 2 == 1 else -1.0)
				if absf(u) > lim + 0.001:
					continue
				var ok := true
				for sp: Array in spots:
					if Vector2(u, v).distance_to(Vector2(float(sp[0]), float(sp[1]))) < r + float(sp[2]) + GAP:
						ok = false
						break
				if ok:
					spots.append([u + cos(ja) * jr, v + sin(ja) * jr, r, idx])
					found = true
					break
			if not found:
				v += VSTEP
	var placed: Array[Dictionary] = []
	for sp: Array in spots:
		var idx := int(sp[3])
		var kind := str(kinds[idx])
		var r0 := radius_of(kind)
		var pu := float(sp[0])
		var pv := float(sp[1])
		var h := 0.0
		if is_air(kind):
			h = minf(FLIER_H, maxf(float(bay["door_h"]) - LINTEL_CLEAR - r0, 1.5))
		placed.append({"i": idx, "kind": kind, "r": r0, "u": pu, "v": pv, "row": int(floor((pv - v_min) / ROW_BAND)),
				"col": 0, "arc": door - out * pv + right * pu, "h": h})
	# Columns: within a row, centre first (the roll-out order).
	for a: Dictionary in placed:
		var c := 0
		for b: Dictionary in placed:
			if b["row"] == a["row"] and (absf(float(b["u"])) < absf(float(a["u"])) - 0.001
					or (absf(absf(float(b["u"])) - absf(float(a["u"]))) <= 0.001 and int(b["i"]) < int(a["i"]))):
				c += 1
		a["col"] = c
	placed.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["i"]) < int(b["i"]))
	return placed


## Roll-out path of one slot: [Vector3(arc x, arc s, height)] (the caller adds CURB_H for ground units) and its wait.
static func exit_path(bay: Dictionary, slot: Dictionary, cruise_h: float, ground_h: float) -> Array[Vector3]:
	var out: Vector2 = bay["out"]
	var right := Vector2(-out.y, out.x)
	var door: Vector2 = bay["door"]
	var r := float(slot["r"])
	var lane_half := maxf(float(bay["door_w"]) * 0.5 - r - LANE_MARGIN, 0.0)
	var lane := clampf(float(slot["u"]), -lane_half, lane_half)
	var air := is_air(str(slot["kind"]))
	var low := float(slot["h"]) if air else ground_h
	var pts: Array[Vector3] = []
	var funnel := door - out * minf(float(slot["v"]), float(bay.get("door_margin", DOOR_MARGIN))) + right * lane
	pts.append(Vector3(funnel.x, funnel.y, low))
	var past := door + out * LANE_OUT + right * lane
	pts.append(Vector3(past.x, past.y, low))
	var ex: Vector2 = bay["exit"]
	var fan := ex + out * (4.0 + float(slot["row"]) * 3.0) + right * lane * 1.5
	pts.append(Vector3(fan.x, fan.y, cruise_h if air else ground_h))
	return pts


static func exit_wait(slot: Dictionary) -> float:
	return float(slot["row"]) * ROW_STAGGER + float(slot["col"]) * COL_STAGGER
