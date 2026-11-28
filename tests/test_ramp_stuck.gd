extends TestCase
## RAMP ENDS DON'T PIN A MECH (2026-11-26, Engine session's bot: section seed 9, deck 1, x -58 s -101, a Strider beside the
## foot of a deck ramp, just outside its lane, made no progress backward, forward or up, even with thrust). On the real
## stack (CityStack, default options) of a few sections, the real mech (MechSpawn: MechController with its capsule and
## move_and_slide settings, stepped by hand, deterministic) is put on a small grid round both corners of every ramp end on
## every deck: the top part's mouth on the upper deck and the bottom part's foot on the lower one; on the ramp, beside the
## parapet's end, just outside the lane and in front of the end. From each point where the capsule fits it walks into the
## corner for a second (the bot's way in), stops, and from where it rests is driven 0.5 s each way along +x, -x, +s, -s:
## it must make progress (MOVED m) at least 2 of the 4 ways (a corner blocks at most 2), and a mech that can move one way
## along an axis is not pinned in every other way. The Bulwark (3.6 m capsule) gets a coarser grid.
##
## Cause found 2026-11-26 (city_district.gd _ramp_collision): the parapet collision boxes were tilted to the slope, so
## their end faces leaned PARAPET_GUARD * slope (0.4 m at a 9 deg foot) out past the ramp's drawn end; a capsule walking
## into that invisible overhanging corner sank into it (Godot's capsule-vs-box contacts at a corner whose top is within
## the capsule's straight side) and every move_and_slide was then blocked. The 1.3 m end blocks did the same once the
## overhang was gone. Fixed: parapet prisms end square to the deck, flush with the drawn end; end blocks END_GUARD tall.

const SEEDS := [9, 1, 2, 4, 6]
const GRID: Array[float] = [-3.0, -1.5, 0.0, 1.5, 3.0]   ## m from the corner, across (+ = outside the lane) and along (+ = past the end)
const GRID_BULWARK: Array[float] = [-4.0, 0.0, 4.0]
const WAYS: Array = [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]    ## +x, -x, +s, -s

var pr: StuckProbe              ## the shared probe (scripts/test_support/stuck_probe.gd)
var probes := 0
var pinned := 0


func setup() -> void:
	timeout_sec = 240.0
	for seed_: int in SEEDS:
		await _section(seed_)
	print("[ramp_stuck] %d probes, %d pinned" % [probes, pinned])
	check(probes > 200, "enough probes ran (%d)" % probes)
	finish()


func _section(seed_: int) -> void:
	var stack := CityStack.new()
	add_child(stack)
	stack.build(SectionPlan.make({"seed": seed_}))
	await get_tree().physics_frame
	await get_tree().physics_frame
	var ends := 0
	for chassis: String in ["strider", "bulwark"]:
		var m := MechSpawn.make("chicken", chassis)
		add_child(m)
		await get_tree().physics_frame
		m.set_physics_process(false)
		for k in stack.decks.size():
			pr = StuckProbe.new(m, stack.deck_ring(k))
			var plan := stack.decks[k].plan
			for r: Dictionary in plan.ramps:
				var span := CityStreets.ramp_span(r, plan.site.slab)
				var end_s := float(r["s_top"]) if r["role"] == "top" else float(r["s_foot"])
				var away := 1.0 if end_s > (span.x + span.y) * 0.5 else -1.0
				for side: float in [-1.0, 1.0]:
					var xc := float(r["x0"]) if side < 0.0 else float(r["x1"])
					_corner(seed_, k, r, chassis, xc, side, end_s, away)
					ends += 1
		m.queue_free()
		await get_tree().physics_frame
	print("[ramp_stuck] seed %d: %d decks, %d ramp corners probed" % [seed_, stack.decks.size(), ends / 2])
	stack.queue_free()
	await frames(2)


func _corner(seed_: int, k: int, r: Dictionary, chassis: String, xc: float, side: float, end_s: float, away: float) -> void:
	var grid: Array[float] = GRID if chassis == "strider" else GRID_BULWARK
	for a: float in grid:
		for b: float in grid:
			var x := xc + side * a
			var s := end_s + away * b
			var start := pr.stand(x, s, maxf(CityPlan.ramp_height(r, s), 0.0) + 9.0)
			if start == Vector3.INF:
				continue
			var res := pr.probe(start, Vector2(xc, end_s), WAYS)
			probes += 1
			var ra: Vector3 = res["rest_arc"]
			if not check(not res["pinned"], "seed %d deck %d %s ramp %s corner x %.1f s %.1f: the %s walking in from (%.1f, %.1f) rests at (%.2f, %.2f, h %.2f) and is pinned: progress +x -x +s -s %s" % [
					seed_, k, r["role"], "foot" if r["role"] == "bottom" else "mouth", xc, end_s, chassis, x, s, ra.x, ra.y, ra.z,
					str(res["moves"].values())]):
				pinned += 1
