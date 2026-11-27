extends TestCase
## Impact decals go on static world surfaces only (playtest: "you shouldn't get blast craters in the air"): ImpactFx's
## scorch / ember / ring / pebbles are laid on the ground or a static wall, never on a target's hull, a moving body or in
## open air, while the air burst itself (flash, chunks) still shows. CombatWorld.spawn_impact decides it from the world
## (wall_at: a short world ray along the normal through the hit; surface_below for the ground), with real physics here.

const DECALS := ["scorch", "ember", "ring", "pebble"]
const WALL_X := -19.0          ## the static wall's face (normal +X)
const GROUND_Y := 0.0


func setup() -> void:
	var w := CombatWorld.new()
	w.mission_seed = 77
	w.use_physics = true
	add_child(w)
	var bodies: Array[Node] = [
		_body(StaticBody3D.new(), Vector3(120, 1, 120), Vector3(0, GROUND_Y - 0.5, 0)),   # ground
		_body(StaticBody3D.new(), Vector3(2, 12, 40), Vector3(WALL_X - 1.0, 6, 0)),     # wall, face at x = -19
		_body(CharacterBody3D.new(), Vector3(2, 6, 2), Vector3(31, 3, 0)),           # an unregistered mech-like body
		_body(AnimatableBody3D.new(), Vector3(6, 3, 3), Vector3(20, 1.5, 20)),          # a tram car (moving)
	]
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(w)
	var dr := EnemyDrone.new()
	dr.configure("drone", "drone_air", w, sq, null, 5)
	dr.ai_mode = "idle"
	sq.add_enemy(dr)
	await frames(3)
	dr.global_position = Vector3(0, 20, 0)

	_airborne_hits(w, dr)
	_airborne_shot(w, dr)
	_airborne_kill(w, dr)
	_grounded_target(w)
	_wall(w)
	_ground(w)
	_low_blast(w)
	_moving_bodies(w)

	sq.queue_free()
	for b in bodies:
		b.queue_free()
	w.queue_free()
	await frames(2)
	await _city_props()
	finish()


func _body(b: CollisionObject3D, size: Vector3, at: Vector3) -> CollisionObject3D:
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	b.add_child(cs)
	b.position = at
	add_child(b)
	return b


func _count(fx: ImpactFx, kind: String) -> int:
	var n := 0
	for p: Dictionary in fx._parts:
		if str(p["kind"]) == kind:
			n += 1
	return n


func _decals(fx: ImpactFx) -> int:
	var n := 0
	for k: String in DECALS:
		n += _count(fx, k)
	return n


## Decal parts lying neither on the ground nor on the static wall's face.
func _stray(fx: ImpactFx) -> int:
	var n := 0
	for p: Dictionary in fx._parts:
		if not (str(p["kind"]) in DECALS):
			continue
		var at: Vector3 = p["at"]
		var on_ground := absf(at.y - GROUND_Y) < 0.6
		var on_wall := absf(at.x - WALL_X) < 0.1 and at.y <= 12.0
		if not on_ground and not on_wall:
			n += 1
	return n


func _impacts(w: CombatWorld) -> Array[ImpactFx]:
	var out: Array[ImpactFx] = []
	for e in w.effects:
		if e is ImpactFx:
			out.append(e)
	return out


func _clear(w: CombatWorld) -> void:
	for fx in _impacts(w):
		w.remove_effect(fx)


## (a) Hits on the airborne drone's hull from the side, above and below, explosive or not: the air burst, no decal.
func _airborne_hits(w: CombatWorld, dr: EnemyDrone) -> void:
	var s: Dictionary = dr.world_spheres()[0]
	var c: Vector3 = s["center"]
	var r := float(s["radius"])
	check(c.y > 15.0, "the drone hovers high above the ground (y %.1f)" % c.y)
	for n: Vector3 in [Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0.7, 0.2, 0.7).normalized(), Vector3.UP, Vector3.DOWN]:
		for explosive: bool in [false, true]:
			var tag := "normal %s, %s" % [n, "explosive" if explosive else "plain"]
			var fx := w.spawn_impact(c + n * r, n, 2.0 if explosive else 1.0, LowPolyPalette.GREY, explosive)
			if not check(fx != null, "an impact on the drone (%s)" % tag):
				continue
			eq(_decals(fx), 0, "no scorch / ember / ring / pebble on the airborne drone (%s)" % tag)
			check(_count(fx, "flash") == 1 and _count(fx, "chunk") >= 5, "the air burst shows: flash and chunks (%s)" % tag)
			check(fx.visible_parts("flash") == 1, "the flash is visible (%s)" % tag)
			w.remove_effect(fx)


## (a) A real autocannon shot at the drone from the ground: the hit lands on its sphere and leaves no decal.
func _airborne_shot(w: CombatWorld, dr: EnemyDrone) -> void:
	var c: Vector3 = dr.world_spheres()[0]["center"]
	var r := float(dr.world_spheres()[0]["radius"])
	w.fire(Combat.fire_record("me", 1, "side_r", "autocannon", Vector3(15, 2, 10), c, w.now, 0))
	var fxs: Array[ImpactFx] = []
	for i in 120:
		w.advance(1.0 / 60.0)
		for fx in _impacts(w):
			if not fx in fxs:
				fxs.append(fx)
		if w.live_shots() == 0:
			break
	if check(fxs.size() >= 1, "it spawns an impact (%d)" % fxs.size()):
		for fx in fxs:
			check(fx.point.distance_to(c) < r + 0.6, "the round bursts on the drone's hull (%s, %.2f m from its centre)" % [fx.point, fx.point.distance_to(c)])
			eq(_decals(fx), 0, "no decal from the autocannon hit on the airborne drone (at %s)" % fx.point)
	_clear(w)


## (b) Killing the drone in the air: its death blast and anything after it leave no decal above the ground.
func _airborne_kill(w: CombatWorld, dr: EnemyDrone) -> void:
	_clear(w)
	dr.apply_damage(1.0e6, dr.core_component(), "me")
	check(dr.destroyed(), "the drone is destroyed")
	var fxs := _impacts(w)
	check(fxs.size() >= 1, "its death spawns a blast (%d)" % fxs.size())
	for fx in fxs:
		check(fx.point.y > 10.0, "the death blast is in the air (y %.1f)" % fx.point.y)
		check(_count(fx, "flash") == 1 and _count(fx, "chunk") >= 5, "the death blast shows flash and chunks")
	var stray := 0
	var seen: Array[ImpactFx] = []
	for i in 180:
		for fx in _impacts(w):
			if not fx in seen:
				seen.append(fx)
				stray += _stray(fx)
		w.advance(1.0 / 60.0)
	eq(stray, 0, "no scorch / ember / ring / pebble above the ground anywhere after the kill (%d impacts)" % seen.size())
	_clear(w)


## (c) A hit on the side of a grounded target's hull 4 m up: no wall scorch (no static wall there; a mech-like
## CharacterBody3D there is not one either).
func _grounded_target(w: CombatWorld) -> void:
	var fx := w.spawn_impact(Vector3(8, 4, 0), Vector3(-1, 0, 0), 1.0, LowPolyPalette.GREY, false)
	eq(_decals(fx), 0, "a hull hit 4 m up places no wall scorch")
	var fx2 := w.spawn_impact(Vector3(30, 4, 0), Vector3(-1, 0, 0), 1.0, LowPolyPalette.GREY, true)
	eq(_decals(fx2), 0, "a hit on a CharacterBody3D's face places no decal (a mech is not a wall)")
	check(_count(fx2, "flash") == 1, "but still bursts")
	# A real shot at a grounded dummy's hull.
	var d := TargetDummy.new()
	d.target_id = "dummy"
	d.position = Vector3(0, 0, -10)
	add_child(d)
	w.register(d)
	var top: Dictionary = {}
	for s: Dictionary in d.world_spheres():
		if top.is_empty() or (s["center"] as Vector3).y > (top["center"] as Vector3).y:
			top = s
	var aim: Vector3 = top["center"]
	w.fire(Combat.fire_record("me", 1, "side_r", "autocannon", Vector3(aim.x + 25, aim.y, aim.z), aim, w.now, 1))
	var stray := 0
	var n := 0
	for i in 120:
		w.advance(1.0 / 60.0)
		if w.live_shots() == 0:
			break
	for f in _impacts(w):
		n += 1
		stray += _stray(f)
		if f.point.y - GROUND_Y > f.radius:
			eq(_decals(f), 0, "the hull hit on the dummy (y %.1f) places no decal" % f.point.y)
	check(n >= 1, "the shot at the dummy spawned an impact")
	eq(stray, 0, "no floating decal from the shot at the dummy")
	w.unregister(d)
	d.queue_free()
	_clear(w)


## (d) A hit on the real wall: the scorch sits flush on the wall normal.
func _wall(w: CombatWorld) -> void:
	var fx := w.spawn_impact(Vector3(WALL_X, 4, 5), Vector3(1, 0, 0), 1.0, LowPolyPalette.GREY, false)
	eq(_count(fx, "scorch"), 1, "a wall hit places a scorch")
	eq(_count(fx, "ember"), 1, "and a cooling ember")
	check(fx.scorch_normal().dot(Vector3(1, 0, 0)) > 0.99, "flush on the wall normal (%s)" % fx.scorch_normal())
	eq(_stray(fx), 0, "on the wall's face")
	# A real autocannon round into the wall.
	_clear(w)
	w.fire(Combat.fire_record("me", 1, "side_r", "autocannon", Vector3(0, 3, 6), Vector3(-30, 3, 6), w.now, 2))
	for i in 120:
		w.advance(1.0 / 60.0)
		if w.live_shots() == 0:
			break
	var walled := 0
	for f in _impacts(w):
		if absf(f.point.x - WALL_X) < 0.3:
			walled += 1
			check(f.scorch_normal().dot(Vector3(1, 0, 0)) > 0.99, "the round's scorch is flush on the wall (%s)" % f.scorch_normal())
	eq(walled, 1, "the autocannon round scorches the wall")
	_clear(w)


## (e) A hit on the ground: ring + scorch + ember + pebbles.
func _ground(w: CombatWorld) -> void:
	var fx := w.spawn_impact(Vector3(5, GROUND_Y, 5), Vector3.UP, 2.0, LowPolyPalette.GREY, true)
	eq(_count(fx, "ring"), 1, "a ground hit places a ring")
	eq(_count(fx, "scorch"), 1, "a scorch")
	eq(_count(fx, "ember"), 1, "an ember")
	var peb := _count(fx, "pebble")
	check(peb >= 3 and peb <= 5, "3-5 pebbles (%d)" % peb)
	check(fx.scorch_normal().dot(Vector3.UP) > 0.99, "flush on the ground")
	eq(_stray(fx), 0, "all on the ground")
	_clear(w)


## (f) A blast low over the ground (within its radius) still craters the ground under it.
func _low_blast(w: CombatWorld) -> void:
	var fx := w.spawn_impact(Vector3(5, GROUND_Y + 2.0, -5), Vector3.UP, 3.0, LowPolyPalette.GREY, true)
	eq(_count(fx, "ring"), 1, "a low blast rings the ground")
	eq(_count(fx, "scorch"), 1, "and scorches it")
	eq(_stray(fx), 0, "on the ground, not in the air")
	var hi := w.spawn_impact(Vector3(5, GROUND_Y + 6.0, -5), Vector3.UP, 3.0, LowPolyPalette.GREY, true)
	eq(_decals(hi), 0, "a blast higher than its radius leaves the ground alone")
	_clear(w)


## Real CityProps on a real district (its StaticBody3D is the ground and the buildings): a tree and a lamp hit from the
## side on the trunk / post, plain (a real autocannon round) and explosive (the rockets' on_hit path), fall over and
## leave no scorch / ember at the hit point and no decal above the street once down.
func _city_props() -> void:
	var d := CityDistrict.new()
	d.with_rig = false
	add_child(d)
	d.build({"seed": 3, "size_x": 100.0, "size_s": 110.0})
	var w := CombatWorld.new()
	w.mission_seed = 78
	w.use_physics = true
	w.ring = d.ring
	add_child(w)
	await frames(3)
	var props: CityProps = d.props
	props.set_physics_process(false)
	w.advance(1.0 / 60.0)
	check(w.props() == props, "props: the world finds the district's CityProps")
	var used: Array[int] = []
	var shot := 10
	for type: String in ["tree", "lamp"]:
		for explosive: bool in [false, true]:
			var tag := "%s, %s" % [type, "explosive" if explosive else "plain"]
			var aim := _clean_prop_shot(w, props, type, used)
			if not check(not aim.is_empty(), "props: a standing %s with a clear side shot at its trunk (%s)" % [type, tag]):
				continue
			var id := int(aim["id"])
			used.append(id)
			var a: Vector3 = aim["from"]
			var b: Vector3 = aim["to"]
			var hit_at: Vector3 = aim["point"]
			_clear(w)
			if explosive:
				# Projectile.on_hit with the mortar shell's stats (one rocket's prop_blast doesn't fell a tree; a real
				# shell's arc can't be aimed at a trunk side-on). Its 6 m radius reaches the street: a crater there is fine.
				var st := w.stats("mortar")
				var rec := Combat.fire_record("me", 1, "back", "mortar", a, b, w.now, shot)
				var h := w.first_hit(a, b, Combat.PROJECTILE_RADIUS, "me")
				w.hit_prop(rec, st, h, (b - a).normalized())
				w.splash(rec, st, h["point"], null)
				w.spawn_impact(h["point"], h["normal"], float(st.get("impact_radius", 1.0)), h.get("color", LowPolyPalette.GREY), true)
			else:
				w.fire(Combat.fire_record("me", 1, "side_r", "autocannon", a, b, w.now, shot))
				for i in 60:
					w.advance(1.0 / 60.0)
					if w.live_shots() == 0:
						break
			shot += 1
			var fxs := _impacts(w)
			check(fxs.size() >= 1, "props: the hit spawns an impact (%s)" % tag)
			var near_hit := 0
			for fx in fxs:
				check(fx.point.distance_to(hit_at) < 1.5, "props: the impact is on the %s (%.2f m from the trunk point) (%s)" % [type, fx.point.distance_to(hit_at), tag])
				check(_count(fx, "flash") == 1, "props: the burst still shows (%s)" % tag)
				for p: Dictionary in fx._parts:
					if str(p["kind"]) in ["scorch", "ember"] and (p["at"] as Vector3).distance_to(hit_at) < 1.2:
						near_hit += 1
			eq(near_hit, 0, "props: no scorch / ember at the hit point on the %s (%s)" % [type, tag])
			# Let it fall (props clock and the world's), then nothing may float above the street.
			for i in 4 * 60:
				props.step(1.0 / 60.0)
				w.advance(1.0 / 60.0)
			check(props.state_of(id) != CityProps.STANDING, "props: the %s was knocked over (%s)" % [type, tag])
			var stray := 0
			for fx in fxs:
				for p: Dictionary in fx._parts:
					if str(p["kind"]) in DECALS and d.ring.height(p["at"] as Vector3) > 0.6:
						stray += 1
			eq(stray, 0, "props: no decal above street level after the %s fell (%s)" % [type, tag])
			_clear(w)
	w.queue_free()
	d.queue_free()
	await frames(1)


## A standing prop of `type` (not in `skip`) and a clear horizontal shot at its trunk 2.2 m up: {id, from, to, point}
## (first_hit from `from` meets that prop first), or {}.
func _clean_prop_shot(w: CombatWorld, props: CityProps, type: String, skip: Array[int]) -> Dictionary:
	for it: Dictionary in props.items:
		var id := int(it["id"])
		if str(it["type"]) != type or id in skip or CityPropSim.is_roof(it) or props.state_of(id) != CityProps.STANDING:
			continue
		var xf := props.global_transform * props.transform_of(id)
		var u := w.up_at(xf.origin)
		var trunk := xf.origin + u * 2.2
		var side0 := u.cross(Vector3.RIGHT)
		if side0.length_squared() < 1e-4:
			side0 = u.cross(Vector3.FORWARD)
		side0 = side0.normalized()
		for k in 8:
			var side := side0.rotated(u, TAU * float(k) / 8.0)
			var a := trunk + side * 10.0
			var b := trunk - side * 4.0
			var h := w.first_hit(a, b, Combat.PROJECTILE_RADIUS, "me")
			if h.has("prop") and int(h["prop"]) == id:
				return {"id": id, "from": a, "to": b, "point": h["point"]}
	return {}


## A moving body (a tram car's roof or side) is no ground and no wall.
func _moving_bodies(w: CombatWorld) -> void:
	var fx := w.spawn_impact(Vector3(20, 3.0, 20), Vector3.UP, 1.0, LowPolyPalette.GREY, true)
	eq(_decals(fx), 0, "no crater on a tram roof")
	var fx2 := w.spawn_impact(Vector3(17, 2.0, 20), Vector3(-1, 0, 0), 1.0, LowPolyPalette.GREY, false)
	eq(_decals(fx2), 0, "no scorch on a tram's side")
	_clear(w)
