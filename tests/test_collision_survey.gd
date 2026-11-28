extends TestCase
## COLLISION SURVEY (playtest backlog R2.25a; findings in docs/design/collision-survey.md). On the real stack of a few
## sections with the real mission on it (MissionPlan.make: wave gates and their staging bays, lift doors, the flag mast,
## the defend relay, the supply depots where MissionDepots places them), every box / convex collision shape a mech can
## touch is grouped by kind (the district's shapes carry meta "col_kind"; mission pieces by their body), and at every
## exposed vertical corner of it a real mech (StuckProbe: MechSpawn's MechController, both capsules, stepped by hand) walks
## in from beside, from the diagonal and off the top, rests, and is driven 4 ways along the corner's faces. A start that
## ends free in fewer than 2 ways is PINNED. Kinds fixed by the survey must show none; kinds whose code another session
## owns are in KNOWN with their owner (counted and printed, not failed).
## Regression run: SEEDS, at most CAP corners per kind and deck. Full survey (the doc's numbers): environment
## BABAMECH_SURVEY=1 runs SEEDS_FULL with CAP_FULL, and writes test_logs/collision_survey.json.

const TEST_TIMEOUT := 300
const SEEDS := [9, 22, 4]
const SEEDS_FULL := [1, 2, 4, 6, 9, 22]
const CAP := 10
const CAP_FULL := 80
const CHASSIS := ["strider", "bulwark"]
## Flat slabs and things a mech never stands beside: the deck, the ceiling, the 0.2 m sidewalks, the boundary walls (a
## straight face; their portal recesses are sealed by a plate), the ramps' underside beams.
const SKIP := ["deck", "ceiling", "sidewalk", "wall", "ramp_beam"]
## Kinds still pinning, with the owner who has the fix (docs/design/collision-survey.md "For Missions" / "For other owners").
const KNOWN := {
	# "tram_car" fixed 2026-11-27 (R2.11): LifeTramCars.car_collision is a CityGeo.rounded_box.
}
## Pins met walking off the top of something only a jump reaches: a mech perched on a narrow top, or dropping into a gap
## narrower than its capsule. Collision cannot remove these without changing shapes or layout (docs/design/collision-survey.md
## "Off the top"); the controller's safety net (R2.25b) frees them.
const TOP_OWNER := "Mech: the controller's stuck safety net (playtest backlog R2.25b); proposals in docs/design/collision-survey.md"
## Pins in a gap narrower than the capsule between two colliders (two buildings 4.0 - 4.2 m apart: the Strider is 4.4 m
## wide): a layout rule, or an invisible plug across the gap (docs/design/collision-survey.md "For other owners").
const GAP_OWNER := "Environment layout: building gaps narrower than a capsule (plan rule or filler collision, proposed in docs/design/collision-survey.md)"
const LEDGE := 1.7          ## m: a top at most this far over the shape's foot is a ledge a mech can walk onto
const MIN_RISE := 0.35      ## m: a corner lower than this over the mech's floor is stepped over

var full := OS.get_environment("BABAMECH_SURVEY") == "1"
var stats := {}              ## kind -> {corners, probed, pinned, examples: []}
var extents := {}            ## mission piece kind -> collision vs drawn extents


func setup() -> void:
	timeout_sec = 3000.0 if full else float(TEST_TIMEOUT)
	for seed_: int in (SEEDS_FULL if full else SEEDS):
		await _section(seed_)
	var kinds := stats.keys()
	kinds.sort()
	var total := 0
	for kind: String in kinds:
		var st: Dictionary = stats[kind]
		total += int(st["probed"])
		if int(st["probed"]) == 0 and int(st["corners"]) == 0:
			continue
		print("[survey] %-18s corners %5d  probed %5d  pinned %4d  cornered %4d  %s" % [kind, st["corners"], st["probed"], st["pinned"], st["cornered"],
				str((st["examples"] as Array).slice(0, 3))])
	for k: String in extents:
		print("[survey] extents %s: %s" % [k, str(extents[k])])
	if full:
		var f := FileAccess.open("res://test_logs/collision_survey.json", FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify({"stats": stats, "extents": extents}, "  "))
	check(total > 300, "enough probes ran (%d)" % total)
	for kind: String in kinds:
		var st: Dictionary = stats[kind]
		if KNOWN.has(kind) or kind.ends_with("_top") or kind.ends_with("_gap"):
			if int(st["pinned"]) > 0:
				print("[survey] KNOWN %s: %d pinned (owner: %s)" % [kind, st["pinned"], KNOWN.get(kind, GAP_OWNER if kind.ends_with("_gap") else TOP_OWNER)])
			continue
		check(int(st["pinned"]) == 0, "%s: %d of %d probes pinned, e.g. %s" % [kind, st["pinned"], st["probed"],
				str((st["examples"] as Array).slice(0, 4))])
	finish()


func _section(seed_: int) -> void:
	var sec := SectionPlan.make({"seed": seed_})
	var stack := CityStack.new()
	add_child(stack)
	stack.build(sec)
	var mplan := MissionPlan.make(sec, {})
	var mw := stack.setup_mission(mplan)
	var md := MissionDepots.place_on(stack, mw, mplan)
	for id: String in md.sites:     # the depots as a mission builds them (MissionDepots._place)
		var snap: Dictionary = md.sites[id]
		var k := int(snap["deck"])
		var dist: CityDistrict = stack.decks[k]
		var node := SupplyDepot.new()
		node.build(dist, MissionProps.site_frame(dist, float(snap["x"]), float(snap["s"]), float(snap["h"])), id, k, 1, int(snap["face"]))
		dist.add_child(node)
	md.free()
	# Every lift car open (R2.22): its doorway's jambs are surveyed as kind "lift_car", its inside by _lift_inside.
	var lifts: Array[MissionLiftDoor] = []
	for id: Variant in mw._doors:
		if mw._doors[id] is MissionLiftDoor and (mw._doors[id] as MissionLiftDoor).has_car:
			lifts.append(mw._doors[id] as MissionLiftDoor)
			mw.open_source(id, mw.now + 1.0, 100000.0)
	mw.advance_to(mw.now + 1.0 + MissionWorld.LIFT_OPEN + 0.5)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_extents(stack)
	# Corners per deck and kind, sampled.
	var work := []        # [deck, kind, corner]
	for k in stack.decks.size():
		var rk := stack.deck_ring(k)
		var by_kind := {}
		for cs: CollisionShape3D in _shapes(stack.decks[k]):
			var kind := _kind(cs)
			if kind == "" or kind in SKIP:
				continue
			for c: Dictionary in StuckProbe.corners(cs, rk):
				if float(c["top"]) - float(c["bot"]) < MIN_RISE:
					continue
				if not _exposed(stack.decks[k], rk, c):
					continue
				if not by_kind.has(kind):
					by_kind[kind] = []
				by_kind[kind].append(c)
		for kind: String in by_kind:
			var list: Array = by_kind[kind]
			_stat(kind)["corners"] += list.size()
			var cap := CAP_FULL if full else CAP
			var stride := maxf(1.0, float(list.size()) / float(cap))
			var f := 0.0
			while int(f) < list.size():
				work.append([k, kind, list[int(f)]])
				f += stride
	# A tram car standing still: its collider is enabled only while it is solid (LifeTramCars), so the stack sweep never
	# meets one. The same collision (LifeTramCars.car_collision: a rounded box) on a clear plaza of deck 0.
	var tram := _tram_car(stack)
	if tram != null:
		await get_tree().physics_frame
		await get_tree().physics_frame
		var rk0 := stack.deck_ring(0)
		for tc in tram.get_children():
			if not (tc is CollisionShape3D) or not ((tc as CollisionShape3D).shape is BoxShape3D):
				continue
			for c: Dictionary in StuckProbe.corners(tc as CollisionShape3D, rk0):
				if not _exposed(stack.decks[0], rk0, c):
					continue
				_stat("tram_car")["corners"] += 1
				work.append([0, "tram_car", c])
	for chassis: String in CHASSIS:
		var m := MechSpawn.make("chicken", chassis)
		add_child(m)
		await get_tree().physics_frame
		m.set_physics_process(false)
		for w: Array in work:
			_corner(seed_, stack, m, chassis, int(w[0]), str(w[1]), w[2])
		for lift in lifts:
			_lift_inside(seed_, stack, m, chassis, lift)
		m.queue_free()
		await get_tree().physics_frame
	print("[survey] seed %d: %d decks, %d corners sampled" % [seed_, stack.decks.size(), work.size()])
	stack.queue_free()
	await frames(2)


## A static copy of a tram car's collision box on the first clear plaza of deck 0 (null when none is clear).
func _tram_car(stack: CityStack) -> StaticBody3D:
	var d := stack.decks[0]
	var size := Vector3(LifeTram.CAR_W, LifeTram.CAR_H, LifeTram.CAR_L)
	for n in 6:
		var site := MissionWorld._stand_in_site(stack, 0, n + 2)
		var body := StaticBody3D.new()
		body.transform = MissionProps.site_frame(d, float(site["x"]), float(site["s"]), CityPlan.CURB_H)
		LifeTramCars.car_collision(body)
		# Clear: no collider within 8 m of the car's box.
		var q := PhysicsShapeQueryParameters3D.new()
		var big := BoxShape3D.new()
		big.size = size + Vector3(16, 0, 16)
		q.shape = big
		q.transform = d.global_transform * body.transform * Transform3D(Basis.IDENTITY, Vector3(0, size.y * 0.5 + 0.1, 0) + Vector3(0, 0.3, 0))
		if d.get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty():
			d.add_child(body)
			return body
		body.free()
	return null


func _stat(kind: String) -> Dictionary:
	if not stats.has(kind):
		stats[kind] = {"corners": 0, "probed": 0, "pinned": 0, "cornered": 0, "fell": 0, "examples": [], "nooks": []}
	return stats[kind]


## Every enabled collision shape of a static / animatable body under district d (its own Collision and the mission
## pieces parented to it).
func _shapes(d: Node) -> Array[CollisionShape3D]:
	var out: Array[CollisionShape3D] = []
	for n in d.find_children("*", "CollisionShape3D", true, false):
		var cs := n as CollisionShape3D
		if cs.disabled or not (cs.get_parent() is StaticBody3D or cs.get_parent() is AnimatableBody3D):
			continue
		out.append(cs)
	return out


## The survey's kind of collision shape cs: the district's meta "col_kind", else the mission piece it belongs to.
func _kind(cs: CollisionShape3D) -> String:
	if cs.has_meta("col_kind"):
		return str(cs.get_meta("col_kind"))
	var body := cs.get_parent()
	var owner_node := body.get_parent()
	match str(body.name):
		"LiftBody":
			return "lift_car"
		"DoorBody":
			return "air_door" if str(owner_node.name).begins_with("MissionAir") else "gate"
		"FlagBody":
			return "flag_mast"
		"AssetBody":
			return "relay"
		"Body":
			if owner_node is SupplyDepot:
				return "depot"
	return "other_" + str(body.name)


## A corner is exposed when the point just outside it (diagonally, 0.2 m) at its lower part is in no collider.
func _exposed(d: Node3D, rk: RingFrame, c: Dictionary) -> bool:
	var diag := ((c["u"] as Vector2) + (c["v"] as Vector2)).normalized()
	var p: Vector2 = (c["at"] as Vector2) + diag * 0.2
	var h := clampf((float(c["bot"]) + float(c["top"])) * 0.5, float(c["bot"]) + 0.2, float(c["bot"]) + 2.0)
	var q := PhysicsPointQueryParameters3D.new()
	q.position = rk.arc_to_world(p.x, p.y, maxf(h, 0.2))
	return d.get_world_3d().direct_space_state.intersect_point(q, 1).is_empty()


func _corner(seed_: int, stack: CityStack, m: MechController, chassis: String, k: int, kind: String, c: Dictionary) -> void:
	var rk := stack.deck_ring(k)
	var pr := StuckProbe.new(m, rk)
	var r := pr.radius()
	var at: Vector2 = c["at"]
	var u: Vector2 = c["u"]
	var v: Vector2 = c["v"]
	var diag := (u + v).normalized()
	var top := float(c["top"])
	var bot := float(c["bot"])
	var from_h := minf(top, bot + 12.0) + 1.5
	# [start (x, s), target, off the top]
	var starts := [[at + diag * (r + 1.0), at, false], [at + u * (r + 0.8) - v * 2.5, at, false],
			[at + v * (r + 0.8) - u * 2.5, at, false], [at - diag * 1.6, at + diag * (r + 1.5), true]]
	for sd: Array in starts:
		# Off the top of something only a jump reaches (taller than a Bulwark steps): its own "<kind>_top" line, known
		# (TOP_OWNER); off a low top (a ledge a mech walks onto): "<kind>_ledge", checked like the rest.
		var st := _stat(kind if not sd[2] else (kind + ("_top" if top - bot > LEDGE else "_ledge")))
		var sp: Vector2 = sd[0]
		var p := pr.stand(sp.x, sp.y, from_h)
		if p == Vector3.INF:
			continue
		var h0 := rk.world_to_arc(p).z
		if sd[2]:
			if h0 < top - 0.4:
				continue      # not on the top (a tall box, or one a capsule does not fit on)
		elif top - h0 < MIN_RISE or bot > h0 + 5.8:
			continue          # steps over it, or it is overhead
		var res := pr.probe(p, sd[1], [u, -u, v, -v])
		if res["fell"]:
			st["fell"] += 1
			continue      # walked off a high edge and still falling: not a pin
		st["probed"] += 1
		if res["cornered"] and not res["pinned"]:
			st["cornered"] += 1
			if (st["nooks"] as Array).size() < 20:
				var na: Vector3 = res["rest_arc"]
				(st["nooks"] as Array).append("seed %d deck %d %s corner (%.1f, %.1f) rests (%.2f, %.2f, h %.2f) moves %s" % [
						seed_, k, chassis, at.x, at.y, na.x, na.y, na.z, str(res["moves"])])
		if res["pinned"]:
			var ra: Vector3 = res["rest_arc"]
			if not sd[2] and _in_gap(rk, m, ra, r):
				st = _stat(kind + "_gap")      # wedged in a gap narrower than the capsule (layout: GAP_OWNER)
				st["probed"] += 1
			st["pinned"] += 1
			(st["examples"] as Array).append("seed %d deck %d %s corner (%.1f, %.1f) top %.2f bot %.2f from (%.1f, %.1f)%s rests (%.2f, %.2f, h %.2f) moves %s" % [
					seed_, k, chassis, at.x, at.y, top, bot, sp.x, sp.y, " off the top" if sd[2] else "", ra.x, ra.y, ra.z,
					str(res["moves"])])


## Inside an open lift car (R2.22): from the car's middle the mech walks into each of its four inner corners (the back
## wall's and the front wall's beside the doorway), rests and is driven along the car's axes (kind "lift_car_inside":
## never pinned); and from 4 m inside it walks straight out through the doorway (kind "lift_car_exit": pinned when it
## does not get 1 m past the door plane).
func _lift_inside(seed_: int, stack: CityStack, m: MechController, chassis: String, lift: MissionLiftDoor) -> void:
	var d := lift.get_parent() as CityDistrict
	var k := stack.decks.find(d)
	var rk := stack.deck_ring(k)
	var pr := StuckProbe.new(m, rk)
	var ways := [lift.arc_x, -lift.arc_x, lift.arc_in, -lift.arc_in]
	var mid := lift.arc(0.0, lift.car_back * 0.5)
	var ch := lift.car_half
	for t: Vector2 in [Vector2(-ch, lift.car_back), Vector2(ch, lift.car_back), Vector2(-ch, MissionLiftDoor.WALL), Vector2(ch, MissionLiftDoor.WALL)]:
		var st := _stat("lift_car_inside")
		var p := pr.stand(mid.x, mid.y, 6.0)
		if p == Vector3.INF:
			continue
		var res := pr.probe(p, lift.arc(t.x, t.y), ways)
		st["probed"] += 1
		st["corners"] += 1
		if res["cornered"] and not res["pinned"]:
			st["cornered"] += 1
		if res["pinned"]:
			st["pinned"] += 1
			(st["examples"] as Array).append("seed %d deck %d %s lift car corner %s rests %s moves %s" % [seed_, k, chassis, str(t), str(res["rest_arc"]), str(res["moves"])])
	var se := _stat("lift_car_exit")
	var deep := lift.arc(0.0, 4.0)      # 4 m in (the probe walks 7 m (Bulwark) to 11 m (Strider) in its approach)
	var p0 := pr.stand(deep.x, deep.y, 6.0)
	if p0 == Vector3.INF:
		return
	var res2 := pr.probe(p0, lift.arc(0.0, -12.0), [lift.arc_in])
	se["probed"] += 1
	se["corners"] += 1
	var ra: Vector3 = res2["rest_arc"]
	var past := (Vector2(ra.x, ra.y) - lift.arc_mid).dot(lift.arc_in)
	if past < 1.0:
		se["pinned"] += 1
		(se["examples"] as Array).append("seed %d deck %d %s: walking out of the lift car it rests %.1f m past the door plane" % [seed_, k, chassis, past])


## Wedged in a gap: from the resting point (arc ra) at the capsule's middle, horizontal rays in two opposite directions
## (of 8 axes) both hit a collider within the capsule's radius + 0.6 m.
func _in_gap(rk: RingFrame, m: MechController, ra: Vector3, r: float) -> bool:
	var space := m.get_world_3d().direct_space_state
	var h := ra.z + 4.0
	var from := rk.arc_to_world(ra.x, ra.y, h)
	var hits: Array[bool] = []
	for i in 8:
		var a := TAU * float(i) / 8.0
		var to := rk.arc_to_world(ra.x + cos(a) * (r + 0.6), ra.y + sin(a) * (r + 0.6), h)
		var q := PhysicsRayQueryParameters3D.create(from, to)
		q.exclude = [m.get_rid()]
		hits.append(not space.intersect_ray(q).is_empty())
	for i in 4:
		if hits[i] and hits[i + 4]:
			return true
	return false


## Mission pieces: their collision's extent against their drawn meshes' (piece-local AABBs), per kind (first seen).
func _extents(stack: CityStack) -> void:
	for d: CityDistrict in stack.decks:
		for n in d.find_children("*", "StaticBody3D", true, false):
			var body := n as StaticBody3D
			if body.name == "Collision":
				continue
			var piece := body.get_parent() as Node3D
			var kind := ""
			for c in body.get_children():
				if c is CollisionShape3D:
					kind = _kind(c)
					break
			if kind == "" or extents.has(kind):
				continue
			var inv := piece.global_transform.affine_inverse()
			var col := AABB()
			var first := true
			for c in body.get_children():
				if not (c is CollisionShape3D) or (c as CollisionShape3D).disabled:
					continue
				var cs := c as CollisionShape3D
				var box := AABB()
				if cs.shape is BoxShape3D:
					var sz := (cs.shape as BoxShape3D).size
					box = AABB(-sz * 0.5, sz)
				elif cs.shape is CylinderShape3D:
					var cy := cs.shape as CylinderShape3D
					box = AABB(Vector3(-cy.radius, -cy.height * 0.5, -cy.radius), Vector3(cy.radius * 2.0, cy.height, cy.radius * 2.0))
				elif cs.shape is ConvexPolygonShape3D:
					var pts := (cs.shape as ConvexPolygonShape3D).points
					box = AABB(pts[0], Vector3.ZERO)
					for p in pts:
						box = box.expand(p)
				box = (inv * cs.global_transform) * box
				col = box if first else col.merge(box)
				first = false
			var mesh := AABB()
			first = true
			for mi in piece.find_children("*", "MeshInstance3D", true, false):
				var g := mi as MeshInstance3D
				if not g.is_visible_in_tree() or g.mesh == null:
					continue
				var box := (inv * g.global_transform) * g.mesh.get_aabb()
				mesh = box if first else mesh.merge(box)
				first = false
			extents[kind] = {"collision": [_v(col.position), _v(col.end)], "drawn": [_v(mesh.position), _v(mesh.end)],
					"past_drawn": _v((col.end - mesh.end).max(Vector3.ZERO) + (mesh.position - col.position).max(Vector3.ZERO))}


static func _v(v: Vector3) -> Array:
	return [snappedf(v.x, 0.01), snappedf(v.y, 0.01), snappedf(v.z, 0.01)]
