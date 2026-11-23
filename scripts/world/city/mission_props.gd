class_name MissionProps
extends RefCounted
## The pieces MissionWorld puts in the city for mission objectives phase 1 (docs/design/city-ramps-and-stack.md "Mission
## world (phase 1)"): wave doors (a blast door in a wall gate, a freight lift's doors), the flag mast, the defend relay,
## the extraction portal, the zone rings on the ground, and the rule that snaps a site to clear ground. Presentation only:
## no clock, no state, no network; MissionWorld poses them from its schedules. Flat-shaded CityGeo boxes in CityPalette
## colours; glows use the emissive materials below (no Light3D here). Every mesh gets its render layer before it enters
## the tree (the stack's rule).

## Emissive materials by palette id and energy (shared, cached; never animated: an animated glow gets its own).
static var _glow: Dictionary = {}


static func c(id: String) -> Color:
	return CityPalette.C[id]


static func glow(id: String, energy: float = 2.5) -> StandardMaterial3D:
	var key := "%s@%.2f" % [id, energy]
	if not _glow.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = c(id)
		m.roughness = 1.0
		m.emission_enabled = true
		m.emission = c(id)
		m.emission_energy_multiplier = energy
		_glow[key] = m
	return _glow[key]


## A MeshInstance3D of `geo` on render layers `layer` (set before it enters any tree), no shadows unless asked.
static func mesh(geo: CityGeo, node_name: String, layer: int, material: Material = null, shadows: bool = false) -> MeshInstance3D:
	var mi := geo.instance(node_name, material)
	mi.layers = layer
	if not shadows:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## A box CollisionShape3D at `center` (local) of `size` under `body`.
static func box_shape(body: StaticBody3D, xf: Transform3D, center: Vector3, size: Vector3) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = size
	cs.shape = b
	cs.transform = xf * Transform3D(Basis.IDENTITY, center)
	body.add_child(cs)
	return cs


## A StaticBody3D on the same collision layer / mask as district d's own collision.
static func body_like(d: CityDistrict, node_name: String) -> StaticBody3D:
	var b := StaticBody3D.new()
	b.name = node_name
	var col := d.get_node_or_null("Collision") as StaticBody3D
	if col != null:
		b.collision_layer = col.collision_layer
		b.collision_mask = col.collision_mask
	return b


## The frame CityStreets._gate builds gate g of wall w in (district-local): origin on the wall plane at the floor, in the
## middle of the gate; local X along the wall, Y up, +Z into the map.
static func gate_frame(d: CityDistrict, w: Dictionary, g: Dictionary) -> Transform3D:
	var geo := CityGeo.new(d.ring)
	var side := int(w["side"])
	var at := float(w["at"])
	var inward := -1.0 if side % 2 == 0 else 1.0
	var mid := (float(g["a"]) + float(g["b"])) * 0.5
	if side >= 2:
		return geo.frame(mid, at, 0.0, 0.0 if inward > 0.0 else PI)
	return geo.frame(at, mid, 0.0, PI * 0.5 if inward > 0.0 else -PI * 0.5)


## Half the clear opening of gate g (between the hazard portal's posts), as CityStreets._gate draws it.
static func gate_half(g: Dictionary) -> float:
	return (float(g["b"]) - float(g["a"])) * 0.5 - 0.6


# --- Wave door in a wall gate ------------------------------------------------------------------------------------------

## A blast door standing in a gate of a boundary wall (the baked leaf is left out of the Walls mesh: CityStreets reads the
## plan's "mission_doors" meta). Two leaves just behind the wall plane slide sideways into the wall; behind them a dark
## recess as deep as the wall. A turning amber beacon on each post top (and one mid-lintel on a wide gate) and an amber
## strip under the lintel play the telegraph. Sealed: welded bars across, scorch, the beacons dead.
## Collision (the wall's own slab is cut at the gate by MissionWorld and rebuilt round it): `door_shape` fills the
## opening from the wall plane 2.8 m back (to the leaves' back) while shut / warning / opening / sealed; the recess's back plate is always solid.
class GateDoor extends Node3D:
	const LEAF_Z := -1.8     ## the leaves' face: behind a farm wall's backing (CityStreets.FARM_RECESS 1.6), hidden as they slide
	var half := 7.0
	var gh := 9.0
	var leaves: Array[Node3D] = []
	var beacons_lit: Array[Node3D] = []     ## turning paddles + glowing core (warn / opening)
	var beacons_idle: Array[Node3D] = []    ## unlit cores (any other state but sealed)
	var strip: MeshInstance3D               ## amber strip under the lintel (flashes in warn / opening)
	var sealed_look: Node3D
	var body: StaticBody3D
	var door_shape: CollisionShape3D

	func build(d: CityDistrict, w: Dictionary, g: Dictionary, look: RandomNumberGenerator) -> void:
		var layer := d.render_layer
		half = MissionProps.gate_half(g)
		gh = float(g["h"])
		transform = MissionProps.gate_frame(d, w, g)
		var w_out := half + 0.6
		# Static: the recess (faces turned inward) and its floor.
		var st := CityGeo.new()
		var dz := -CityStreets.WALL_THICK
		var col := MissionProps.c("m_recess")
		var sidec := MissionProps.c("concrete_dark").darkened(0.55)
		st.quad(Vector3(-w_out, 0, dz), Vector3(w_out, 0, dz), Vector3(w_out, gh, dz), Vector3(-w_out, gh, dz), col)
		st.quad(Vector3(-w_out, 0, 0), Vector3(-w_out, 0, dz), Vector3(-w_out, gh, dz), Vector3(-w_out, gh, 0), sidec)
		st.quad(Vector3(w_out, 0, dz), Vector3(w_out, 0, 0), Vector3(w_out, gh, 0), Vector3(w_out, gh, dz), sidec)
		st.quad(Vector3(-w_out, gh, 0), Vector3(-w_out, gh, dz), Vector3(w_out, gh, dz), Vector3(w_out, gh, 0), col)
		st.quad(Vector3(-w_out, 0.03, 0), Vector3(w_out, 0.03, 0), Vector3(w_out, 0.03, dz), Vector3(-w_out, 0.03, dz), sidec)
		# Beacon housings on the post tops (and mid-lintel on a wide gate).
		var spots: Array[float] = [-(half + 0.9), half + 0.9]
		if half > 10.0:
			spots.append(0.0)
		for x in spots:
			st.box(Transform3D.IDENTITY, Vector3(x, gh + 1.6 + 0.2, 0.9), Vector3(1.8, 0.4, 1.8), MissionProps.c("metal_dark"))
		add_child(MissionProps.mesh(st, "Recess", layer))
		# Leaves.
		for k: float in [-1.0, 1.0]:
			var leaf := Node3D.new()
			leaf.name = "Leaf%s" % ("L" if k < 0.0 else "R")
			var lg := CityGeo.new()
			var lw := half
			lg.box(Transform3D.IDENTITY, Vector3(0, gh * 0.5, LEAF_Z - 0.5), Vector3(lw, gh, 1.0), MissionProps.c("m_leaf"))
			# Horizontal ribs and a yellow hazard band; the meeting edge picked out.
			var y := 1.4
			while y < gh - 0.8:
				lg.box(Transform3D.IDENTITY, Vector3(0, y, LEAF_Z + 0.05), Vector3(lw - 0.4, 0.3, 0.1), MissionProps.c("metal_dark"))
				y += 2.2
			lg.box(Transform3D.IDENTITY, Vector3(0, gh * 0.55, LEAF_Z + 0.07), Vector3(lw * 0.8, 1.0, 0.1), MissionProps.c("marking_yellow"))
			lg.box(Transform3D.IDENTITY, Vector3(-k * (lw * 0.5 - 0.2), gh * 0.5, LEAF_Z + 0.06), Vector3(0.4, gh, 0.12), MissionProps.c("metal"))
			var lm := MissionProps.mesh(lg, "Mesh", layer, null, true)
			leaf.add_child(lm)
			leaf.position = Vector3(k * half * 0.5, 0, 0)
			add_child(leaf)
			leaves.append(leaf)
		# Beacons: lit (core + two crossed paddles that turn) and idle.
		for x in spots:
			var lit := Node3D.new()
			lit.name = "BeaconLit"
			lit.position = Vector3(x, gh + 2.0, 0.9)
			var core := CityGeo.new()
			core.prism(Transform3D.IDENTITY, Vector3.ZERO, 0.6, 1.3, 6, MissionProps.c("m_beacon"))
			lit.add_child(MissionProps.mesh(core, "Core", layer, MissionProps.glow("m_beacon", 3.0)))
			var pad := CityGeo.new()
			pad.box(Transform3D.IDENTITY, Vector3(0, 0.65, 0), Vector3(3.0, 0.75, 0.16), MissionProps.c("m_beacon"))
			pad.box(Transform3D.IDENTITY, Vector3(0, 0.65, 0), Vector3(0.16, 0.75, 3.0), MissionProps.c("m_beacon"))
			var spin := MissionProps.mesh(pad, "Paddles", layer, MissionProps.glow("m_beacon", 5.0))
			lit.add_child(spin)
			lit.visible = false
			add_child(lit)
			beacons_lit.append(lit)
			var idle := CityGeo.new()
			idle.prism(Transform3D.IDENTITY, Vector3.ZERO, 0.6, 1.3, 6, MissionProps.c("m_beacon_dead"))
			var im := MissionProps.mesh(idle, "BeaconIdle", layer)
			im.position = lit.position
			add_child(im)
			beacons_idle.append(im)
		var sg := CityGeo.new()
		sg.box(Transform3D.IDENTITY, Vector3(0, gh + 0.25, 1.9), Vector3(half * 2.0, 0.35, 0.2), MissionProps.c("m_beacon"))
		strip = MissionProps.mesh(sg, "Strip", layer, MissionProps.glow("m_beacon", 4.0))
		strip.visible = false
		add_child(strip)
		# Sealed: welded bars in an X and across, a bright weld seam, scorch on the leaves, a dead stripe over the beacons.
		var sl := CityGeo.new()
		var diag := atan2(gh - 1.0, half * 2.0 - 1.0)
		var dl := Vector2(half * 2.0 - 1.0, gh - 1.0).length()
		for k: float in [-1.0, 1.0]:
			sl.box(Transform3D(Basis(Vector3.BACK, k * diag), Vector3(0, gh * 0.5, 0.25)), Vector3.ZERO, Vector3(dl, 0.5, 0.25), MissionProps.c("m_weld"))
		for y2: float in [gh * 0.3, gh * 0.7]:
			sl.box(Transform3D.IDENTITY, Vector3(0, y2, 0.2), Vector3(half * 2.0, 0.6, 0.2), MissionProps.c("m_weld"))
		sl.box(Transform3D.IDENTITY, Vector3(0, gh * 0.5, 0.05), Vector3(0.25, gh - 0.4, 0.06), MissionProps.c("marking"))
		var n := look.randi_range(5, 8)
		for i in n:
			var cx := look.randf_range(-half + 1.0, half - 1.0)
			var cy := look.randf_range(0.6, gh - 1.0)
			var r := look.randf_range(0.8, 2.2)
			var pts: Array[Vector3] = []
			for j in 6:
				var a := TAU * float(j) / 6.0 + look.randf_range(-0.3, 0.3)
				var rr := r * look.randf_range(0.6, 1.0)
				pts.append(Vector3(cx + cos(a) * rr, clampf(cy + sin(a) * rr, 0.05, gh - 0.05), LEAF_Z + 0.08 + 0.002 * float(i)))
			for j in 6:
				sl.tri(Vector3(cx, cy, pts[0].z), pts[(j + 1) % 6], pts[j], MissionProps.c("m_scorch"))
		sealed_look = MissionProps.mesh(sl, "Sealed", layer)
		sealed_look.visible = false
		add_child(sealed_look)
		# Collision: the leaves' box and the recess back plate.
		body = MissionProps.body_like(d, "DoorBody")
		add_child(body)
		door_shape = MissionProps.box_shape(body, Transform3D.IDENTITY, Vector3(0, gh * 0.5, -1.4), Vector3(w_out * 2.0, gh, 2.8))
		MissionProps.box_shape(body, Transform3D.IDENTITY, Vector3(0, gh * 0.5, dz - 0.5), Vector3(w_out * 2.0 + 1.0, gh + 1.0, 1.0))

	## state: shut | warn | opening | open | closing | sealed; u 0..1 through opening / closing; t the clock (beacon turn).
	func pose(state: String, u: float, t: float) -> void:
		var open := 0.0
		match state:
			"opening": open = smoothstep(0.0, 1.0, u)
			"open": open = 1.0
			"closing": open = 1.0 - smoothstep(0.0, 1.0, u)
		for i in leaves.size():
			var k := -1.0 if i == 0 else 1.0
			leaves[i].position.x = k * half * (0.5 + open)
		var warn := state == "warn" or state == "opening"
		for b in beacons_lit:
			b.visible = warn
			if warn:
				(b.get_child(1) as Node3D).rotation.y = fposmod(t * TAU * 1.25, TAU)
		for b in beacons_idle:
			b.visible = not warn
		strip.visible = warn and fposmod(t, 0.5) < 0.3
		sealed_look.visible = state == "sealed"

	func blocks(state: String) -> bool:
		return state == "shut" or state == "warn" or state == "opening" or state == "sealed"

	func world_point() -> Vector3:
		return global_transform * Vector3(0, gh * 0.5, 0) if is_inside_tree() else transform * Vector3(0, gh * 0.5, 0)


# --- Wave door in a freight lift -----------------------------------------------------------------------------------------

## The freight lift's doors on one deck: two leaves on a track in front of the baked door pane (CityBuildings._pillar: a
## 10 x 8 m door on the core's `front` face), sliding apart to show the lit car; five lamps over the door count down the
## last 5 s (amber, one goes out a second) and all turn green when the doors open. No collision: the core is solid.
class LiftDoor extends Node3D:
	const W := 5.0
	const H := 8.0
	var leaves: Array[Node3D] = []
	var car: Node3D
	var lamps: Array[Node3D] = []
	var go: Node3D

	func build(d: CityDistrict, bi: int) -> void:
		var layer := d.render_layer
		var b: Dictionary = d.plan.buildings[bi]
		var front := int(b["front"])
		var size: Vector2 = b["core"]["size"]
		var n2: Vector2 = CityPlan.SIDE_N[front]
		var n := Vector3(n2.x, 0.0, n2.y)
		var depth := size.x if front < 2 else size.y
		transform = d.core_frame(bi) * Transform3D(Basis(Vector3.UP.cross(n), Vector3.UP, n), n * depth * 0.5)
		var st := CityGeo.new()
		st.box(Transform3D.IDENTITY, Vector3(0, H + 0.2, 0.86), Vector3(W * 4.2, 0.4, 0.3), MissionProps.c("metal_dark"))
		for i in 5:
			st.box(Transform3D.IDENTITY, Vector3(-2.4 + 1.2 * float(i), 9.4, 0.4), Vector3(0.8, 0.8, 0.8), MissionProps.c("metal_dark"))
		add_child(MissionProps.mesh(st, "Track", layer))
		car = Node3D.new()
		car.name = "Car"
		var cg := CityGeo.new()
		cg.quad(Vector3(-W, 0, 0.6), Vector3(W, 0, 0.6), Vector3(W, H, 0.6), Vector3(-W, H, 0.6), MissionProps.c("m_recess"))
		car.add_child(MissionProps.mesh(cg, "Inside", layer))
		var lg := CityGeo.new()
		lg.box(Transform3D.IDENTITY, Vector3(0, 0.15, 0.63), Vector3(W * 2.0 - 0.4, 0.3, 0.04), MissionProps.c("strip"))
		lg.box(Transform3D.IDENTITY, Vector3(0, H - 0.4, 0.63), Vector3(W * 2.0 - 0.8, 0.3, 0.04), MissionProps.c("strip"))
		car.add_child(MissionProps.mesh(lg, "Light", layer, MissionProps.glow("strip", 3.0)))
		car.visible = false
		add_child(car)
		for k: float in [-1.0, 1.0]:
			var leaf := Node3D.new()
			leaf.name = "Leaf%s" % ("L" if k < 0.0 else "R")
			var g := CityGeo.new()
			g.box(Transform3D.IDENTITY, Vector3(0, H * 0.5, 0.86), Vector3(W, H, 0.28), MissionProps.c("m_leaf"))
			g.box(Transform3D.IDENTITY, Vector3(0, H * 0.5, 1.01), Vector3(W - 0.6, 0.8, 0.04), MissionProps.c("marking_yellow"))
			g.box(Transform3D.IDENTITY, Vector3(-k * (W * 0.5 - 0.15), H * 0.5, 1.01), Vector3(0.3, H, 0.04), MissionProps.c("metal"))
			leaf.add_child(MissionProps.mesh(g, "Mesh", layer, null, true))
			leaf.position = Vector3(k * W * 0.5, 0, 0)
			add_child(leaf)
			leaves.append(leaf)
		for i in 5:
			var lamp := Node3D.new()
			lamp.name = "Lamp%d" % i
			var g := CityGeo.new()
			g.box(Transform3D.IDENTITY, Vector3(-2.4 + 1.2 * float(i), 9.4, 0.84), Vector3(0.6, 0.6, 0.1), MissionProps.c("m_beacon"))
			lamp.add_child(MissionProps.mesh(g, "Lit", layer, MissionProps.glow("m_beacon", 4.0)))
			lamp.visible = false
			add_child(lamp)
			lamps.append(lamp)
		go = Node3D.new()
		go.name = "Go"
		var gg := CityGeo.new()
		for i in 5:
			gg.box(Transform3D.IDENTITY, Vector3(-2.4 + 1.2 * float(i), 9.4, 0.84), Vector3(0.6, 0.6, 0.1), MissionProps.c("m_done"))
		go.add_child(MissionProps.mesh(gg, "Lit", layer, MissionProps.glow("m_done", 4.0)))
		go.visible = false
		add_child(go)

	## state as GateDoor.pose; `left` = seconds to open_at (the countdown).
	func pose(state: String, u: float, left: float) -> void:
		var open := 0.0
		match state:
			"opening": open = smoothstep(0.0, 1.0, u)
			"open": open = 1.0
			"closing": open = 1.0 - smoothstep(0.0, 1.0, u)
		for i in leaves.size():
			var k := -1.0 if i == 0 else 1.0
			leaves[i].position.x = k * W * (0.5 + open)
		car.visible = open > 0.0
		var counting := state == "warn" or state == "opening"
		for i in lamps.size():
			lamps[i].visible = counting and left > float(i)
		go.visible = state == "open" or (state == "opening" and u > 0.5)

	func blocks(_state: String) -> bool:
		return false

	func world_point() -> Vector3:
		return global_transform * Vector3(0, H * 0.5, 2.0) if is_inside_tree() else transform * Vector3(0, H * 0.5, 2.0)


# --- Flag mast -----------------------------------------------------------------------------------------------------------

## A 16 m mast (0.55 m pole) on a stepped base, a yard at the top, and two banners about 5 x 3.2 m that differ in SHAPE as
## well as colour: the alien one dark, torn and angular (a ragged swallowtail) with a harsh dark-red emblem block and a
## glowing slit; ours a clean rectangle in the crew's safety orange with a bright cream stripe. pose(raised, from, u)
## plays the swap: the banner up comes down over the first half, the other goes up over the second. Slim collision: the
## pole (r 0.6) and the base.
class FlagMast extends Node3D:
	const POLE := 16.0
	const TOP := 15.4        ## banner top when raised (under the yard)
	const LOW := 5.2         ## banner top when lowered
	const W := 5.0
	const H := 3.2
	var alien: Node3D
	var ours: Node3D
	var body: StaticBody3D

	func build(d: CityDistrict, xf: Transform3D) -> void:
		var layer := d.render_layer
		transform = xf
		var st := CityGeo.new()
		var I := Transform3D.IDENTITY
		st.box(I, Vector3(0, 0.2, 0), Vector3(3.6, 0.8, 3.6), MissionProps.c("concrete_dark"))
		st.box(I, Vector3(0, 0.85, 0), Vector3(2.6, 0.5, 2.6), MissionProps.c("concrete"))
		st.box(I, Vector3(0, 1.35, 0), Vector3(1.6, 0.5, 1.6), MissionProps.c("concrete_dark"))
		st.prism(I, Vector3(0, 1.6, 0), 0.55, POLE - 1.6, 8, MissionProps.c("metal"), 0.4)
		for y: float in [3.0, 3.8]:
			st.prism(I, Vector3(0, y, 0), 0.62, 0.4, 8, MissionProps.c("marking_yellow"))
		st.box(I, Vector3(W * 0.5 + 0.3, TOP + 0.2, 0), Vector3(W + 1.2, 0.35, 0.35), MissionProps.c("metal_dark"))
		st.prism(I, Vector3(0, POLE, 0), 0.55, 0.7, 8, MissionProps.c("marking_yellow"), 0.0)
		add_child(MissionProps.mesh(st, "Mast", layer, null, true))
		alien = Node3D.new()
		alien.name = "Alien"
		var ag := CityGeo.new()
		var torn: Array[Vector2] = [Vector2(0.4, 0), Vector2(0.4, -2.6), Vector2(1.2, -3.4), Vector2(1.8, -2.6), Vector2(2.9, -1.9),
				Vector2(3.6, -2.9), Vector2(4.5, -3.5), Vector2(4.9, -2.4), Vector2(5.4, -2.7), Vector2(5.0, -1.5), Vector2(5.5, -0.9),
				Vector2(5.0, 0)]
		MissionProps.flat_poly(ag, torn, 0.05, MissionProps.c("m_alien"))
		ag.box(Transform3D(Basis(Vector3.BACK, 0.18), Vector3(2.9, -1.15, 0)), Vector3.ZERO, Vector3(1.7, 1.3, 0.2), MissionProps.c("m_alien_mark"))
		for k: float in [-1.0, 1.0]:
			ag.box(Transform3D(Basis(Vector3.BACK, k * 0.75), Vector3(2.9 + k * 0.95, -2.0, 0)), Vector3.ZERO, Vector3(1.0, 0.28, 0.16), MissionProps.c("m_alien_mark"))
		alien.add_child(MissionProps.mesh(ag, "Banner", layer, null, true))
		var eye := CityGeo.new()
		eye.box(I, Vector3(2.9, -1.15, 0), Vector3(1.1, 0.26, 0.26), MissionProps.c("m_hostile"))
		alien.add_child(MissionProps.mesh(eye, "Eye", layer, MissionProps.glow("m_hostile", 4.0)))
		add_child(alien)
		ours = Node3D.new()
		ours.name = "Ours"
		var og := CityGeo.new()
		og.box(I, Vector3(0.4 + W * 0.5, -H * 0.5, 0), Vector3(W, H, 0.1), MissionProps.c("m_ours"))
		og.box(I, Vector3(0.4 + W * 0.5, -H * 0.5, 0), Vector3(W, 0.7, 0.16), MissionProps.c("m_ours_mark"))
		og.box(I, Vector3(0.4 + W * 0.5, -0.12, 0), Vector3(W, 0.24, 0.14), MissionProps.c("m_ours_mark"))
		ours.add_child(MissionProps.mesh(og, "Banner", layer, null, true))
		add_child(ours)
		body = MissionProps.body_like(d, "FlagBody")
		add_child(body)
		var cs := CollisionShape3D.new()
		var cyl := CylinderShape3D.new()
		cyl.radius = 0.6
		cyl.height = POLE
		cs.shape = cyl
		cs.position = Vector3(0, POLE * 0.5, 0)
		body.add_child(cs)
		MissionProps.box_shape(body, I, Vector3(0, 0.6, 0), Vector3(3.6, 1.6, 3.6))
		pose(false, false, 1.0)

	## raised: ours is (going) up; from: what was up before the last swap; u 0..1 through the swap.
	func pose(raised: bool, from: bool, u: float) -> void:
		var up_node := ours if raised else alien
		var down_node := alien if raised else ours
		if raised == from or u >= 1.0:
			up_node.visible = true
			up_node.position.y = TOP
			down_node.visible = false
			return
		if u < 0.5:
			down_node.visible = true
			down_node.position.y = lerpf(TOP, LOW, u * 2.0)
			up_node.visible = false
		else:
			down_node.visible = false
			up_node.visible = true
			up_node.position.y = lerpf(LOW, TOP, u * 2.0 - 1.0)

	func world_point() -> Vector3:
		return global_transform * Vector3(0, TOP, 0) if is_inside_tree() else transform * Vector3(0, TOP, 0)


## A flat polygon `pts` (counter-clockwise in local x / y, star-shaped round its centroid) drawn on both sides, `half`
## either side of z = 0.
static func flat_poly(geo: CityGeo, pts: Array[Vector2], half: float, col: Color) -> void:
	var c := Vector2.ZERO
	for p in pts:
		c += p
	c /= float(pts.size())
	for i in pts.size():
		var a := pts[i]
		var b := pts[(i + 1) % pts.size()]
		geo.tri(Vector3(c.x, c.y, half), Vector3(a.x, a.y, half), Vector3(b.x, b.y, half), col)
		geo.tri(Vector3(c.x, c.y, -half), Vector3(b.x, b.y, -half), Vector3(a.x, a.y, -half), col)


# --- Defend asset ----------------------------------------------------------------------------------------------------------

## A relay about 6 m to the dish's rim on a plinth: a cabinet with a bold blinking cyan band, a mast, a big dish and a tall
## thin antenna (8.6 m, glowing tip) that marks it above parked props. look(level): 0 intact, 1 damaged (dish knocked
## askew, antenna bent, sparks and smoke), 2 wreck (cabinet slumped and scorched, mast snapped with its top on the
## ground, dish fallen on its rim, antenna down, nothing glows). `body` is the damageable target (MissionWorld puts it in
## group "mission_asset" with meta objective_id); the look never changes it.
class RelayAsset extends Node3D:
	var intact: Node3D
	var dish: Node3D
	var antenna: Node3D
	var band_on: MeshInstance3D
	var band_off: MeshInstance3D
	var wreck: MeshInstance3D
	var sparks: CPUParticles3D
	var smoke: CPUParticles3D
	var body: StaticBody3D
	var level := 0

	func build(d: CityDistrict, xf: Transform3D) -> void:
		var layer := d.render_layer
		transform = xf
		var I := Transform3D.IDENTITY
		var st := CityGeo.new()
		st.box(I, Vector3(0, 0.4, 0), Vector3(4.2, 1.2, 4.2), MissionProps.c("concrete_dark"))
		for k: Vector2 in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			st.box(I, Vector3(k.x * 1.8, 1.15, k.y * 1.8), Vector3(0.6, 0.3, 0.6), MissionProps.c("marking_yellow"))
		add_child(MissionProps.mesh(st, "Plinth", layer, null, true))
		intact = Node3D.new()
		intact.name = "Intact"
		var ig := CityGeo.new()
		ig.box(I, Vector3(0, 2.6, 0), Vector3(2.8, 2.8, 2.8), MissionProps.c("m_relay"))
		ig.box(I, Vector3(0, 4.1, 0), Vector3(3.2, 0.3, 3.2), MissionProps.c("metal_dark"))
		ig.prism(I, Vector3(0, 4.2, 0), 0.32, 1.4, 6, MissionProps.c("metal"))
		intact.add_child(MissionProps.mesh(ig, "Body", layer, null, true))
		var bg := CityGeo.new()
		bg.box(I, Vector3(0, 3.2, 0), Vector3(2.95, 0.7, 2.95), MissionProps.c("m_relay_band"))
		band_on = MissionProps.mesh(bg, "BandOn", layer, MissionProps.glow("m_relay_band", 4.5))
		intact.add_child(band_on)
		var bo := CityGeo.new()
		bo.box(I, Vector3(0, 3.2, 0), Vector3(2.95, 0.7, 2.95), MissionProps.c("m_relay").darkened(0.35))
		band_off = MissionProps.mesh(bo, "BandOff", layer)
		band_off.visible = false
		intact.add_child(band_off)
		dish = Node3D.new()
		dish.name = "Dish"
		dish.position = Vector3(0, 5.5, 0)
		var dg := CityGeo.new()
		var tilt := Transform3D(Basis(Vector3.RIGHT, -0.7), Vector3.ZERO)
		dg.prism(tilt, Vector3.ZERO, 0.45, 1.1, 10, MissionProps.c("cream_light"), 2.3, null, MissionProps.c("metal"))
		dg.prism(tilt, Vector3(0, 1.1, 0), 0.1, 1.2, 4, MissionProps.c("metal_dark"))
		dish.add_child(MissionProps.mesh(dg, "Mesh", layer, null, true))
		intact.add_child(dish)
		antenna = Node3D.new()
		antenna.name = "Antenna"
		antenna.position = Vector3(1.1, 4.25, -1.1)
		var ag := CityGeo.new()
		ag.box(I, Vector3(0, 2.15, 0), Vector3(0.14, 4.3, 0.14), MissionProps.c("metal_dark"))
		for y: float in [1.2, 2.4, 3.4]:
			ag.box(I, Vector3(0, y, 0), Vector3(0.7, 0.08, 0.08), MissionProps.c("metal_dark"))
		antenna.add_child(MissionProps.mesh(ag, "Mast", layer, null, true))
		var tip := CityGeo.new()
		tip.box(I, Vector3(0, 4.4, 0), Vector3(0.32, 0.32, 0.32), MissionProps.c("m_ours"))
		antenna.add_child(MissionProps.mesh(tip, "Tip", layer, MissionProps.glow("m_ours", 4.0)))
		intact.add_child(antenna)
		add_child(intact)
		# The wreck: a slumped, scorched cabinet; the mast's stump and its snapped top on the ground; the dish fallen on its
		# rim; the antenna lying across the plinth.
		var wg := CityGeo.new()
		wg.box(Transform3D(Basis(Vector3(1, 0, 0.4).normalized(), 0.3), Vector3(0.1, 1.9, 0.0)), Vector3.ZERO, Vector3(2.8, 1.6, 2.8), MissionProps.c("m_scorch"))
		wg.box(Transform3D(Basis(Vector3.FORWARD, 0.25), Vector3(0.2, 2.8, 0.0)), Vector3.ZERO, Vector3(3.0, 0.3, 3.0), MissionProps.c("metal_dark"))
		wg.prism(Transform3D(Basis(Vector3.FORWARD, 0.2), Vector3(0.1, 2.9, 0)), Vector3.ZERO, 0.32, 0.8, 6, MissionProps.c("metal_dark"))
		wg.prism(Transform3D(Basis(Vector3.FORWARD, 1.45), Vector3(3.6, 0.35, 0.6)), Vector3.ZERO, 0.3, 2.2, 6, MissionProps.c("metal"))
		wg.prism(Transform3D(Basis(Vector3.RIGHT, 1.5) * Basis(Vector3.UP, 0.3), Vector3(-2.6, 1.6, 2.2)), Vector3.ZERO, 0.45, 1.1, 10,
				MissionProps.c("m_scorch"), 2.3, null, MissionProps.c("metal_dark"))
		wg.box(Transform3D(Basis(Vector3.UP, 0.7) * Basis(Vector3.FORWARD, 1.5), Vector3(-0.4, 1.25, -2.4)), Vector3.ZERO, Vector3(0.14, 4.3, 0.14), MissionProps.c("metal_dark"))
		wreck = MissionProps.mesh(wg, "Wreck", layer, null, true)
		wreck.visible = false
		add_child(wreck)
		body = MissionProps.body_like(d, "AssetBody")
		add_child(body)
		MissionProps.box_shape(body, I, Vector3(0, 2.5, 0), Vector3(4.2, 5.4, 4.2))

	## Sparks and smoke while damaged (CPUParticles3D, made on first need; none at CityQuality.LOW).
	func _fx(on: bool, layer: int) -> void:
		if on and sparks == null:
			sparks = CPUParticles3D.new()
			sparks.name = "Sparks"
			sparks.amount = 14
			sparks.lifetime = 0.6
			sparks.explosiveness = 0.6
			sparks.direction = Vector3.UP
			sparks.spread = 70.0
			sparks.initial_velocity_min = 3.0
			sparks.initial_velocity_max = 6.0
			sparks.gravity = Vector3(0, -12, 0)
			sparks.scale_amount_min = 0.08
			sparks.scale_amount_max = 0.14
			var qm := BoxMesh.new()
			qm.size = Vector3.ONE
			qm.material = MissionProps.glow("m_beacon", 6.0)
			sparks.mesh = qm
			sparks.layers = layer
			sparks.position = Vector3(0, 4.6, 0)
			add_child(sparks)
			smoke = CPUParticles3D.new()
			smoke.name = "Smoke"
			smoke.amount = 10
			smoke.lifetime = 2.6
			smoke.direction = Vector3.UP
			smoke.spread = 15.0
			smoke.initial_velocity_min = 1.2
			smoke.initial_velocity_max = 2.0
			smoke.gravity = Vector3(0, 0.4, 0)
			smoke.scale_amount_min = 0.6
			smoke.scale_amount_max = 1.2
			var sm := BoxMesh.new()
			sm.size = Vector3.ONE
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(0.18, 0.17, 0.17)
			mat.roughness = 1.0
			sm.material = mat
			smoke.mesh = sm
			smoke.layers = layer
			smoke.position = Vector3(0, 4.4, 0)
			add_child(smoke)
		if sparks != null:
			sparks.emitting = on
			sparks.visible = on
			smoke.emitting = on
			smoke.visible = on

	## lv 0 intact, 1 damaged, 2 wreck; fx = particles allowed (quality above LOW).
	func look(lv: int, fx: bool, layer: int) -> void:
		level = lv
		intact.visible = lv < 2
		wreck.visible = lv == 2
		dish.position = Vector3(0.6, 4.6, 0.4) if lv == 1 else Vector3(0, 5.5, 0)
		dish.rotation = Vector3(0.9, 0.4, 0.6) if lv == 1 else Vector3.ZERO
		antenna.rotation = Vector3(0.0, 0.0, 0.55) if lv == 1 else Vector3.ZERO
		_fx(lv == 1 and fx, layer)

	func blink(on: bool) -> void:
		band_on.visible = on and level == 0
		band_off.visible = not band_on.visible

	func world_point() -> Vector3:
		return global_transform * Vector3(0, 3.0, 0) if is_inside_tree() else transform * Vector3(0, 3.0, 0)


# --- Extraction portal -----------------------------------------------------------------------------------------------------

## A charging frame in the extraction portal gate: SEGMENTS pairs of segments up both posts and along the lintel to its
## middle, the first `progress` of them lit, and an energy curtain across the opening: none below CURTAIN_FROM, then
## rising from the floor with a bright top edge, thin until 1.0, where it fills the opening and turns solid.
class Portal extends Node3D:
	const SEGMENTS := 12
	const CURTAIN_FROM := 0.15   ## progress below which there is no curtain
	var half := 20.0
	var gh := 14.0
	var lit: Array[Node3D] = []
	var curtain: MeshInstance3D
	var curtain_mat: StandardMaterial3D
	var edge: MeshInstance3D          ## the curtain's bright rising top edge

	func build(d: CityDistrict, w: Dictionary, g: Dictionary) -> void:
		var layer := d.render_layer
		half = MissionProps.gate_half(g)
		gh = float(g["h"])
		transform = MissionProps.gate_frame(d, w, g)
		var off := CityGeo.new()
		var segs := _segments()
		for sg: Array in segs:
			off.box(sg[0], Vector3.ZERO, sg[1], MissionProps.c("m_portal_off"))
		add_child(MissionProps.mesh(off, "Frame", layer))
		for i in SEGMENTS:
			var n := Node3D.new()
			n.name = "Lit%d" % i
			var g2 := CityGeo.new()
			for sg: Array in [segs[i * 2], segs[i * 2 + 1]]:
				g2.box(sg[0], Vector3.ZERO, (sg[1] as Vector3) + Vector3(0.04, 0.04, 0.04), MissionProps.c("m_portal"))
			n.add_child(MissionProps.mesh(g2, "Mesh", layer, MissionProps.glow("m_portal", 4.0)))
			n.visible = false
			add_child(n)
			lit.append(n)
		var cg := CityGeo.new()           # one metre tall: pose() scales it up from the floor
		var x := half - 0.7
		cg.quad(Vector3(-x, 0.0, -0.6), Vector3(x, 0.0, -0.6), Vector3(x, 1.0, -0.6), Vector3(-x, 1.0, -0.6), MissionProps.c("m_portal"))
		curtain_mat = StandardMaterial3D.new()
		curtain_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		curtain_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		curtain_mat.albedo_color = MissionProps.c("m_portal")
		curtain_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		curtain = MissionProps.mesh(cg, "Curtain", layer, curtain_mat)
		curtain.visible = false
		add_child(curtain)
		var eg := CityGeo.new()
		eg.box(Transform3D.IDENTITY, Vector3(0, 0, -0.5), Vector3(x * 2.0, 0.3, 0.2), MissionProps.c("m_portal"))
		edge = MissionProps.mesh(eg, "Edge", layer, MissionProps.glow("m_portal", 5.0))
		edge.visible = false
		add_child(edge)

	## [xf, size] of every segment, in pairs (left, right), bottom of the posts first, the lintel's middle last.
	func _segments() -> Array:
		var out := []
		var post := gh - 0.6
		var top := half - 0.4
		var total := post + top
		var step := total / float(SEGMENTS)
		for i in SEGMENTS:
			var a := step * float(i) + 0.15
			var b := step * float(i + 1) - 0.15
			for k: float in [-1.0, 1.0]:
				if b <= post:
					out.append([Transform3D(Basis.IDENTITY, Vector3(k * (half - 0.35), 0.3 + (a + b) * 0.5, 1.0)), Vector3(0.7, b - a, 0.6)])
				elif a >= post:
					var u0 := half - 0.4 - (a - post)
					var u1 := half - 0.4 - (b - post)
					out.append([Transform3D(Basis.IDENTITY, Vector3(k * (u0 + u1) * 0.5, gh - 0.35, 1.0)), Vector3(absf(u0 - u1), 0.7, 0.6)])
				else:
					out.append([Transform3D(Basis.IDENTITY, Vector3(k * (half - 0.35), 0.3 + (a + post) * 0.5, 1.0)), Vector3(0.7, post - a, 0.6)])
		return out

	func pose(progress: float) -> void:
		for i in lit.size():
			lit[i].visible = progress >= float(i + 1) / float(SEGMENTS) - 0.0001
		# The curtain: nothing below CURTAIN_FROM, then rising from the floor to the lintel as progress goes to 1, thin at
		# first and solid only at 1 (a bright edge on its top while it rises).
		var f := clampf((progress - CURTAIN_FROM) / (1.0 - CURTAIN_FROM), 0.0, 1.0)
		curtain.visible = f > 0.0
		edge.visible = f > 0.0 and f < 1.0
		var top := 0.1 + (gh - 0.5) * f
		curtain.scale = Vector3(1.0, maxf(top, 0.01), 1.0)
		edge.position.y = top
		var col := MissionProps.c("m_portal")
		col.a = 0.12 + 0.43 * f + (0.35 if f >= 1.0 else 0.0)
		curtain_mat.albedo_color = col

	func world_point() -> Vector3:
		return global_transform * Vector3(0, gh * 0.5, 0) if is_inside_tree() else transform * Vector3(0, gh * 0.5, 0)


# --- Ground marks ----------------------------------------------------------------------------------------------------------

## Height of the walking surface at (x, s): curb height on a block (sidewalk, plaza, park), else the road.
static func ground_h(plan: CityPlan, pt: Vector2) -> float:
	for b: Dictionary in plan.blocks:
		if (b["rect"] as Rect2).has_point(pt):
			return CityPlan.CURB_H
	return 0.0


## A thin ring of radius r round (x, s) on the faceted floor, 6 cm above whatever it crosses (road or curb), left out over
## floor cuts and inside building footprints. District-local.
static func zone_ring(d: CityDistrict, at: Vector2, r: float, width: float = 0.6) -> CityGeo:
	var geo := CityGeo.new(d.ring)
	var blocked := _blockers(d.plan)
	var cuts := d.plan.floor_cuts()
	var n := maxi(int(TAU * r / 1.5), 24)
	for i in n:
		var a0 := TAU * float(i) / float(n)
		var a1 := TAU * float(i + 1) / float(n)
		var am := (a0 + a1) * 0.5
		var mid := at + Vector2(cos(am), sin(am)) * r
		if _in_rects(blocked, mid) or _in_rects(cuts, mid, CityStreets.HOLE_CURB + 0.2):
			continue
		var h := ground_h(d.plan, mid) + 0.06
		var p0i := at + Vector2(cos(a0), sin(a0)) * (r - width * 0.5)
		var p0o := at + Vector2(cos(a0), sin(a0)) * (r + width * 0.5)
		var p1i := at + Vector2(cos(a1), sin(a1)) * (r - width * 0.5)
		var p1o := at + Vector2(cos(a1), sin(a1)) * (r + width * 0.5)
		geo.g_quad(Vector3(p0i.x, p0i.y, h), Vector3(p0o.x, p0o.y, h), Vector3(p1o.x, p1o.y, h), Vector3(p1i.x, p1i.y, h), c("m_zone"))
	return geo


## The outline of rect z (deck arc coords) on the floor: four bands `width` wide, each cut at the block edges so it sits
## 6 cm above the road on the road and above the curb on a block; corner squares. District-local.
static func zone_rect(d: CityDistrict, z: Rect2, width: float = 0.9) -> CityGeo:
	var geo := CityGeo.new(d.ring)
	geo.holes = d.plan.floor_cuts()
	var bands: Array[Rect2] = [Rect2(z.position.x, z.position.y, z.size.x, width), Rect2(z.position.x, z.end.y - width, z.size.x, width),
			Rect2(z.position.x, z.position.y, width, z.size.y), Rect2(z.end.x - width, z.position.y, width, z.size.y)]
	var blocks: Array[Rect2] = []
	for b: Dictionary in d.plan.blocks:
		blocks.append(b["rect"])
	for band in bands:
		for q in CityGeo.cut(band, blocks):
			geo.g_rect(q.position.x, q.end.x, q.position.y, q.end.y, 0.06, c("m_zone"))
		for bk in blocks:
			if bk.intersects(band):
				var q := bk.intersection(band)
				geo.g_rect(q.position.x, q.end.x, q.position.y, q.end.y, CityPlan.CURB_H + 0.06, c("m_zone"))
	return geo


static func _in_rects(rects: Array, pt: Vector2, grow: float = 0.0) -> bool:
	for r: Rect2 in rects:
		if r.grow(grow).has_point(pt):
			return true
	return false


## Building footprints on a plan (the footprint of every building, and a pillar's core), as Rect2.
static func _blockers(plan: CityPlan) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for b: Dictionary in plan.buildings:
		var sz: Vector2 = b.get("size", Vector2.ZERO)
		if sz.x > 0.0 and not (b["pillar"] and (b["tiers"] as Array).is_empty()):
			out.append(Rect2((b["center"] as Vector2) - sz * 0.5, sz))
		if b["pillar"]:
			var cs: Vector2 = b["core"]["size"]
			var cc := Vector2(float(b["core"]["x"]), float(b["core"]["s"]))
			out.append(Rect2(cc - cs * 0.5, cs))
	return out


# --- Site snapping ---------------------------------------------------------------------------------------------------------

const SNAP_STEP := 1.0        ## m between candidate points
const ROAD_COST := 6.0        ## m a road point counts further away than a sidewalk / plaza point (prefer the latter)
const WALL_MARGIN := 4.0      ## m kept between a placed piece's disc and the boundary walls

## The SNAP RULE (the same on every machine: plan data and the props' initial layout only). Candidates: `site` and every
## point of a SNAP_STEP grid centred on it within `reach` (the snap distance: MissionWorld.snap_reach); each scored by its distance from the site, plus ROAD_COST when
## it is not on a block (sidewalk, plaza, park). In score order (ties: smaller s, then smaller x), the first CLEAR point
## wins: a disc of `clear_r` round it is inside the walls (WALL_MARGIN 4 m to spare), clear of every building footprint and pillar core,
## floor cut (+ its curb), ramp, park column, kept-clear rect, prop (its radius), the ground in front of every wall gate (gate_aprons), the rail lane and the avenue's median, and
## `avoid` ([[Vector2, radius]]: pieces placed before it, e.g. the mast a chained defend relay stands beside).
## Returns {x, s, h (ground height there), snapped: moved off the site, ok: a clear point was found}; when none is, the
## site itself with ok = false.
static func snap_site(d: CityDistrict, site: Vector2, reach: float, clear_r: float, avoid: Array = []) -> Dictionary:
	var plan := d.plan
	# Only what can touch a candidate's disc (the same answer, far fewer checks over a 45 m reach).
	var area := Rect2(site, Vector2.ZERO).grow(reach + clear_r + 1.0)
	var blockers: Array[Rect2] = []
	for b in _blockers(plan):
		if b.intersects(area):
			blockers.append(b)
	var cuts: Array[Rect2] = []
	for o in plan.floor_cuts():
		if o.grow(CityStreets.HOLE_CURB + 1.0).intersects(area):
			cuts.append(o)
	var items := []
	if d.props != null:
		for it: Dictionary in d.props.items:
			if area.grow(3.0).has_point(Vector2(float(it["x"]), float(it["s"]))):
				items.append(it)
	var blocks: Array[Rect2] = []
	for b: Dictionary in plan.blocks:
		if (b["rect"] as Rect2).intersects(area):
			blocks.append(b["rect"])
	var inner := plan.extent.grow(-(clear_r + WALL_MARGIN))
	# Nearest first: a candidate's score is at least its distance, so once the distance passes the best score found
	# nothing later can win; among equal scores the smaller s, then x (the same pick as sorting every candidate).
	var best := []
	for off: Vector2 in _offsets(reach):
		var dist := off.length()
		if not best.is_empty() and dist > float(best[0]) + 1e-9:
			break
		var pt := site + off
		var cost := dist + (0.0 if _in_rects(blocks, pt) else ROAD_COST)
		var key := [cost, pt.y, pt.x]
		if not best.is_empty() and key >= best:
			continue
		if inner.has_point(pt) and clear_at(d, pt, clear_r, blockers, cuts, avoid, items):
			best = key
	if best.is_empty():
		return {"x": site.x, "s": site.y, "h": ground_h(plan, site), "snapped": false, "ok": false}
	var at := Vector2(float(best[2]), float(best[1]))
	return {"x": at.x, "s": at.y, "h": ground_h(plan, at), "snapped": not at.is_equal_approx(site), "ok": true}


## Every SNAP_STEP grid offset within `reach`, nearest first (ties: smaller y, then x); cached per reach.
static var _offset_cache: Dictionary = {}

static func _offsets(reach: float) -> Array:
	if not _offset_cache.has(reach):
		var keyed := []
		var n := int(floor(reach / SNAP_STEP))
		for i in range(-n, n + 1):
			for j in range(-n, n + 1):
				var off := Vector2(float(i), float(j)) * SNAP_STEP
				if off.length() <= reach + 0.001:
					keyed.append([off.length(), off.y, off.x])
		keyed.sort()
		var out := []
		for k: Array in keyed:
			out.append(Vector2(float(k[2]), float(k[1])))
		_offset_cache[reach] = out
	return _offset_cache[reach]


## Whether a disc of radius r at pt is clear ground (see snap_site).
static func clear_at(d: CityDistrict, pt: Vector2, r: float, blockers: Array[Rect2], cuts: Array[Rect2], avoid: Array = [],
		items: Variant = null) -> bool:
	var plan := d.plan
	for av: Array in avoid:      # [Vector2, radius]: pieces already placed (a defend relay beside its flag's mast)
		if (av[0] as Vector2).distance_to(pt) < float(av[1]) + r:
			return false
	var box := Rect2(pt - Vector2(r, r), Vector2(r, r) * 2.0)
	for b in blockers:
		if b.intersects(box):
			return false
	for o in cuts:
		if o.grow(CityStreets.HOLE_CURB + 0.5).intersects(box):
			return false
	for k: Rect2 in plan.site.keep_clear:
		if k.intersects(box):
			return false
	for ap in gate_aprons(plan):
		if ap.intersects(box):
			return false
	for rp: Dictionary in plan.ramps:
		var s0 := minf(float(rp["s_top"]), float(rp["s_foot"]))
		var s1 := maxf(float(rp["s_top"]), float(rp["s_foot"]))
		if Rect2(float(rp["x0"]), s0, float(rp["x1"]) - float(rp["x0"]), s1 - s0).grow(2.0).intersects(box):
			return false
	for col: Dictionary in plan.columns:
		if Vector2(float(col["x"]), float(col["s"])).distance_to(pt) < float(col["half"]) + 2.0 + r:
			return false
	if plan.section != null:
		var rail := plan.section.lane_x("rail")
		if pt.x + r > rail.x and pt.x - r < rail.y:
			return false
		var av := plan.section.lane_x("avenue")
		if absf(pt.x - (av.x + av.y) * 0.5) < 1.5 + r:
			return false
	var props: Array = items if items != null else (d.props.items if d.props != null else [])
	for it: Dictionary in props:
		var pr := float(CityPropSim.TYPES[it["type"]]["radius"])
		if Vector2(float(it["x"]), float(it["s"])).distance_to(pt) < pr + r:
			return false
	return true


## The ground in front of every gate in the walls (GATE_APRON m into the map, 1 m past each side): where waves walk in
## and the hatched keep-clear box is painted; nothing is placed there.
const GATE_APRON := 12.0

static func gate_aprons(plan: CityPlan) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for w: Dictionary in plan.boundary():
		var side := int(w["side"])
		var at := float(w["at"])
		var inward := -1.0 if side % 2 == 0 else 1.0
		var d0 := minf(at, at + inward * GATE_APRON)
		for g: Dictionary in w["gates"]:
			var a := float(g["a"]) - 1.0
			var b := float(g["b"]) + 1.0
			out.append(Rect2(a, d0, b - a, GATE_APRON) if side >= 2 else Rect2(d0, a, GATE_APRON, b - a))
	return out


## The upright frame at (x, s) standing on the ground there (district-local).
static func site_frame(d: CityDistrict, x: float, s: float, h: float) -> Transform3D:
	var geo := CityGeo.new(d.ring)
	return Transform3D(CityGeo.frame_basis(d.ring, s), geo.g_point(x, s, h))
