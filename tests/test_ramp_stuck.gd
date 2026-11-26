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
const DT := 1.0 / 60.0
const APPROACH := 60           ## steps walking into the corner
const DRIVE := 30              ## steps driven each way from the resting point
const MOVED := 0.5             ## m along a way that counts as progress
const GRID: Array[float] = [-3.0, -1.5, 0.0, 1.5, 3.0]   ## m from the corner, across (+ = outside the lane) and along (+ = past the end)
const GRID_BULWARK: Array[float] = [-4.0, 0.0, 4.0]
const WAYS := {"+x": Vector2(1, 0), "-x": Vector2(-1, 0), "+s": Vector2(0, 1), "-s": Vector2(0, -1)}

var mech: MechController
var rk: RingFrame
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
		mech = m
		for k in stack.decks.size():
			rk = stack.deck_ring(k)
			mech.ring = rk
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
			var start := _stand(x, s, r)
			if start == Vector3.INF:
				continue
			# Walk into the corner, then rest.
			_place(start)
			for i in 10:
				mech.step(DT)
			var to := Vector2(xc - x, end_s - s)
			if to.length() > 0.3:
				_face(to)
				mech.move_input = Vector2(0, 1)
				for i in APPROACH:
					mech.step(DT)
			mech.move_input = Vector2.ZERO
			for i in 10:
				mech.step(DT)
			var rest := mech.global_position
			var moves := {}
			var free := 0
			for w: String in WAYS:
				_place(rest)
				var a0 := rk.world_to_arc(rest)
				var dv: Vector2 = WAYS[w]
				_face(dv)
				mech.move_input = Vector2(0, 1)
				for i in DRIVE:
					mech.step(DT)
				mech.move_input = Vector2.ZERO
				var a1 := rk.world_to_arc(mech.global_position)
				var prog := (a1.x - a0.x) * dv.x + (a1.y - a0.y) * dv.y
				moves[w] = snappedf(prog, 0.01)
				if prog > MOVED:
					free += 1
			probes += 1
			var ra := rk.world_to_arc(rest)
			if not check(free >= 2, "seed %d deck %d %s ramp %s corner x %.1f s %.1f: the %s walking in from (%.1f, %.1f) rests at (%.2f, %.2f, h %.2f) and is pinned: progress %s" % [
					seed_, k, r["role"], "foot" if r["role"] == "bottom" else "mouth", xc, end_s, chassis, x, s, ra.x, ra.y, ra.z,
					str(moves)]):
				pinned += 1


## The resting place of the capsule at arc (x, s) on deck rk: just above the walking surface found by a ray down (the
## ramp's ribbon or the floor), Vector3.INF where the capsule does not fit there (inside a parapet, over the floor cut).
func _stand(x: float, s: float, r: Dictionary) -> Vector3:
	var top := maxf(CityPlan.ramp_height(r, s), 0.0) + 9.0
	var q := PhysicsRayQueryParameters3D.create(rk.arc_to_world(x, s, top), rk.arc_to_world(x, s, top - 60.0))
	q.exclude = [mech.get_rid()]
	var hit := mech.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty() or not (hit["collider"] is StaticBody3D):
		return Vector3.INF
	var p: Vector3 = hit["position"] + rk.up_at(hit["position"]) * 0.3
	var cs := mech.get_node("Shape") as CollisionShape3D
	var sq := PhysicsShapeQueryParameters3D.new()
	sq.shape = cs.shape
	var u := rk.up_at(p)
	var fwd := rk.tangent_at(p)
	sq.transform = Transform3D(Basis(fwd.cross(u), u, -fwd), p + u * cs.position.y)
	sq.exclude = [mech.get_rid()]
	if not mech.get_world_3d().direct_space_state.intersect_shape(sq, 1).is_empty():
		return Vector3.INF
	return p


func _place(p: Vector3) -> void:
	var u := rk.up_at(p)
	var fwd := rk.tangent_at(p)
	mech.global_transform = Transform3D(Basis(fwd.cross(u), u, -fwd), p)
	mech.velocity = Vector3.ZERO
	mech.move_input = Vector2.ZERO
	mech.thrust_input = false
	mech.heat = 0.0
	mech.shutdown = false
	mech._wedge_t = 0.0
	mech._wedge_nudge = 0.0
	mech._climbing = false


## Turn the mech to face arc direction dv (x along the ring's axis, s along the floor).
func _face(dv: Vector2) -> void:
	var p := mech.global_position
	var u := rk.up_at(p)
	var fwd := Vector3.RIGHT * dv.x + rk.tangent_at(p) * dv.y
	fwd = (fwd - u * fwd.dot(u)).normalized()
	mech.global_basis = Basis(fwd.cross(u), u, -fwd)
