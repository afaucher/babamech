class_name FlameChunk
extends CombatEffect
## One flamer chunk (weapons.md §3.9, §5): the gameplay half of the flame. A fire record like any shot (10 a second while
## the trigger is held, WeaponMount), simulated identically on every machine from the record + the shared clock. It is
## INVISIBLE: the look is one LowPolyFlame.Stream per firing mount (FlamerFx), never a mesh per chunk.
##
## FLIGHT: straight along the record's aim thrown off inside the stats.spread cone by the shot generator
## (Combat.shot_rng), at stats.speed: position = origin + dir × speed × e, a pure function of flight time e. Its hit
## radius grows with distance, HIT_R0 at the muzzle to HIT_R1 at the end (wide and forgiving, a real cone), so a target
## 1.5 m off the axis at 30 m is still licked by part of the stream. REACH is the flame's FRONT: the chunk's centre stops
## HIT_R1 short of stats.range, so its sphere reaches exactly stats.range (a target whose surface is inside 45 m burns,
## one standing at 48 m doesn't).
## SWEEP: chords on a fixed grid of STEP s of flight time (the last one ends at range), each tested with the radius at
## its far end, so the hits are the same at any frame rate and when a record arrives late (fast-forward). Each chord is
## also reported to CombatWorld.life_sweep (clipped where the chunk was spent, r = that far-end radius), so the stream
## sweeps civilians muzzle to clipped end, chunk by chunk.
## HIT: the first target it meets takes the normal resolve_hit / deliver path (stats.damage, stats.target_heat as the
## Hit's heat, stats.knockback = 0, so no shove; victim / attacker authority as for every weapon), then the chunk is
## spent. World geometry and city props stop it without effect (no impulse: the flamer pushes nothing), including a
## target just behind cover that the fat chunk would otherwise touch through the wall (`_behind_cover`).

const STEP := 1.0 / 30.0       ## s of flight per swept chord (1.07 m at 32 m/s)
const HIT_R0 := 0.3            ## m: hit radius at the muzzle ...
const HIT_R1 := 1.8            ## ... growing linearly to this at full reach

var origin := Vector3.ZERO
var dir := Vector3.FORWARD     ## after spread
var speed := 32.0
var reach := 45.0              ## stats.range: how far the front of the chunk gets
var travel := 43.2             ## how far its centre gets (reach - HIT_R1)
var max_time := 1.0            ## flight time to reach
var elapsed := 0.0             ## flight time reached so far
var end_time := -1.0           ## flight time it was spent (hit something or reached range); -1 while flying
var _chord := 0                ## next grid chord to sweep


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({"origin": Net.SPAWN, "dir": Net.SPAWN, "speed": Net.SPAWN, "reach": Net.SPAWN, "travel": Net.SPAWN, "max_time": Net.SPAWN,
		"elapsed": Net.LOCAL, "end_time": Net.LOCAL, "_chord": Net.LOCAL})
	return f


func start(w: CombatWorld, rec: Dictionary, st: Dictionary) -> void:
	super.start(w, rec, st)
	origin = rec["origin"]
	var rng := Combat.shot_rng(w.mission_seed, str(rec["shooter"]), str(rec["hardpoint"]), int(rec["shot_index"]))
	dir = Combat.spread_dir(rec["dir"], float(rec.get("spread", 0.0)), rng)
	speed = maxf(float(st.get("speed", 32.0)), 0.1)
	reach = maxf(float(st.get("range", 45.0)), 0.1)
	travel = maxf(reach - HIT_R1, reach * 0.5)
	max_time = travel / speed


func flight_pos(e: float) -> Vector3:
	return origin + dir * speed * e


## Hit radius with the centre `d` m from the muzzle.
func hit_radius(d: float) -> float:
	return lerpf(HIT_R0, HIT_R1, clampf(d / travel, 0.0, 1.0))


func advance_to(now: float) -> void:
	var e := now - t0
	var n := int(ceil(max_time / STEP - 1e-9))
	while end_time < 0.0 and _chord < n:
		var ta := float(_chord) * STEP
		var tb := minf(float(_chord + 1) * STEP, max_time)
		if tb > e + 1e-9:
			break
		var a := flight_pos(ta)
		var b := flight_pos(tb)
		var r := hit_radius(speed * tb)
		var h := world.first_hit(a, b, r, str(record.get("shooter", "")))
		if not h.is_empty():
			end_time = lerpf(ta, tb, float(h["frac"]))
			b = a.lerp(b, float(h["frac"]))
			_on_hit(h)
		world.life_sweep(record, a, b, r)      # ambient life: the chord (clipped at what spent the chunk)
		_chord += 1
	if end_time < 0.0 and _chord >= n:
		end_time = max_time
	elapsed = maxf(e, elapsed)


func _on_hit(h: Dictionary) -> void:
	var target: CombatTarget = h["target"]
	if target != null and not _behind_cover(h):
		world.resolve_hit(record, stats, target, str(h["component"]), h["point"], h["normal"], dir,
			float(stats.get("damage", 0.0)) * Combat.falloff(stats, speed * end_time))


## A fat chunk touches a target's sphere up to its own radius away, so it could lick a target standing just behind a
## wall before its centre reaches the wall. Check the gap: from the chunk's centre toward the target, its own radius
## long. World geometry or a prop in it = the wall takes the chunk (spent, no effect).
func _behind_cover(h: Dictionary) -> bool:
	var p: Vector3 = h["point"]
	var r := hit_radius(p.distance_to(origin))
	var g := world.first_hit(p, p - (h["normal"] as Vector3) * r, 0.0, str(record.get("shooter", "")))
	return not g.is_empty() and g["target"] == null


func finished() -> bool:
	return end_time >= 0.0


## Spent on something (not just out of reach).
func hit_something() -> bool:
	return end_time >= 0.0 and end_time < max_time - 1e-9
