class_name CityPropLayout
extends RefCounted
## Where a district's loose props stand (docs/design/city-props.md, city-rooftops.md): the layout CityProps sets up and
## LifePlan / LifeTraffic keep clear of, as plain data from the plan alone. GAMEPLAY: props are host-arbitrated by index
## (the layout index is the prop id) and stop shots, so the layout joins the load checksum (checksum(), in
## CityStack.checksum). Its own generators (CityPlan.props_seed() + 1 street props, + 2 roof units), so it never depends on
## what the meshers draw. Pure: no nodes, no state.
##
## Item: {id, type, x, s, h, yaw, scale, variant, pit}; a roof unit also has building, tier and its spot lx, ly, lz in that
## building's flat frame (building_xf).

## Roof unit footprints (m, centre to farthest edge, at any yaw) for placing them clear of each other and of what
## stands on the roof; the contact radius in CityPropSim.TYPES is what the sim uses.
const ROOF_FOOT := {"water_tank": 1.5, "ac": 1.35, "vent": 0.5, "planter": 1.75}
const ROOF_KIND := {"tank": "water_tank", "ac": "ac", "vent": "vent", "planter": "planter"}     ## plan slot kind -> type


## Every prop of the district as plain data, from its own generator so it never depends on what the meshers draw.
## Street trees every ~9 m along each block edge with a lamp in every third slot, a bin beside some lamps and a bench
## beside some trees; a signal pole and a sign post at the low end of each edge; median, garden, plaza and park trees;
## plaza and park benches. Nothing stands in a floor hole or on ground kept clear. ids are array indices.
static func layout(p: CityPlan) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = p.props_seed() + 1
	var out: Array = []
	for bi in p.blocks.size():
		var sf: Array = [] if p.forms.is_empty() else [p.block_side_form(bi, 0), p.block_side_form(bi, 1), p.block_side_form(bi, 2), p.block_side_form(bi, 3)]
		_block_items(out, p.blocks[bi]["rect"], rng, sf)
	var av := p.avenue_x()
	for road: Dictionary in p.roads_x:
		if road["kind"] != "avenue" and road["kind"] != "spine":
			continue
		var mid := (av.x + av.y) * 0.5      # the median of the avenue (its own lane on a section's spine)
		for j in p.roads_s.size() - 1:
			var v0: float = float(p.roads_s[j]["b"]) + 12.0
			var v1: float = float(p.roads_s[j + 1]["a"]) - 12.0
			var n := int((v1 - v0) / 15.0)
			for i in n + 1:
				if n > 0:
					_tree(out, rng, mid, v0 + (v1 - v0) * float(i) / float(n), CityPlan.CURB_H, 0.8, false)
	for l: Dictionary in p.lots:
		if l["kind"] == "open":
			_lot_items(out, l, rng)
	# City variety (docs/design/city-variety.md): bins in the service alleys, then the road forms' street furniture.
	# After everything else, so a plan without them lays out exactly as before.
	for a: Dictionary in p.alleys:
		_alley_items(out, a, rng)
	var keys := p.forms.keys()
	keys.sort()
	for k: int in keys:
		var axis := "x" if k >= 65536 else "s"
		_form_items(out, str(p.forms[k]), p.seg_inner(axis, (k % 65536) / 256, k % 256), axis == "s", rng)
	var kept: Array = []
	for it: Dictionary in out:
		if p.clear_at(Vector2(it["x"], it["s"])):
			it["id"] = kept.size()
			kept.append(it)
	_roof_items(kept, p)      # after the street props, so their ids do not move
	return kept


## The flat frame building i stands in, in the district's space (the same as CityDistrict.building_frame).
static func building_xf(ring: RingFrame, p: CityPlan, i: int) -> Transform3D:
	var c: Vector2 = p.buildings[i]["center"]
	return Transform3D(CityGeo.frame_basis(ring, c.y), ring.arc_to_world(c.x, c.y, CityPlan.CURB_H))


## Roof units on every roof slot of the plan (CityPlan.roof_slots), from their own stream: as many tries as the old
## roof clutter, each at least 3.6 m from the others and clear of what stands on the roof (CityPlan.roof_blockers).
static func _roof_items(out: Array, p: CityPlan) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = p.props_seed() + 2
	var ring := RingFrame.new(p.p("radius"))
	for i in p.buildings.size():
		var xf := building_xf(ring, p, i)
		for slot: Array in p.roof_slots(i):
			var t: int = slot[0]
			var kinds: Array = []
			for k: String in slot[1]:
				if ROOF_KIND.has(k):
					kinds.append(ROOF_KIND[k])
			if kinds.is_empty():
				continue
			var tier: Dictionary = p.buildings[i]["tiers"][t]
			var size: Vector2 = tier["size"]
			var off: Vector2 = tier["off"]
			var y := float(tier["y1"])
			var blockers := p.roof_blockers(i, t)
			var n := clampi(int(size.x * size.y / 70.0), 1, 5)
			var used: Array[Vector2] = []
			for k in n:
				var pos := off + Vector2(rng.randf_range(-1.0, 1.0) * maxf(size.x * 0.5 - CityPlan.ROOF_INSET, 0.0),
						rng.randf_range(-1.0, 1.0) * maxf(size.y * 0.5 - CityPlan.ROOF_INSET, 0.0))
				var type: String = kinds[rng.randi_range(0, kinds.size() - 1)]
				var yaw := 0.0 if rng.randf() < 0.5 else PI * 0.5
				var variant := rng.randi_range(0, CityBuildings.TANK_COLOURS.size() - 1) if type == "water_tank" else 0
				var ok := true
				for q in used:
					if q.distance_to(pos) < 3.6:
						ok = false
				for q in blockers:
					if q.grow(float(ROOF_FOOT[type]) + CityPlan.ROOF_MARGIN).has_point(pos):
						ok = false
				if not ok:
					continue
				used.append(pos)
				var arc := ring.world_to_arc(xf * Vector3(pos.x, y, pos.y))
				out.append({"id": out.size(), "type": type, "x": arc.x, "s": arc.y, "h": arc.z, "yaw": yaw, "scale": 1.0,
						"variant": variant, "pit": false, "building": i, "tier": t, "lx": pos.x, "lz": pos.y, "ly": y})


## The layout's checksum (in CityStack.checksum: host-arbitrated by index, props stop shots).
static func checksum(list: Array) -> String:
	var buf := StreamPeerBuffer.new()
	for it: Dictionary in list:
		buf.put_32(int(it["id"]))
		buf.put_8(CityPropSim.TYPE_ORDER.find(it["type"]))
		for k: String in ["x", "s", "h", "yaw", "scale"]:
			buf.put_32(int(round(float(it[k]) * 1000.0)))
		buf.put_8(int(it["variant"]))
		buf.put_8(1 if it["pit"] else 0)
		if CityPropSim.is_roof(it):
			buf.put_32(int(it["building"]))
			buf.put_8(int(it["tier"]))
			for k: String in ["lx", "lz", "ly"]:
				buf.put_32(int(round(float(it[k]) * 1000.0)))
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(buf.data_array)
	return ctx.finish().hex_encode().substr(0, 16)


static func _add(out: Array, type: String, x: float, s: float, h: float, yaw: float, scale: float = 1.0, variant: int = 0, pit: bool = false) -> void:
	out.append({"id": out.size(), "type": type, "x": x, "s": s, "h": h, "yaw": yaw, "scale": scale, "variant": variant, "pit": pit})


static func _tree(out: Array, rng: RandomNumberGenerator, x: float, s: float, h: float, scale: float, pit: bool) -> void:
	var yaw := rng.randf() * TAU
	var sc := scale * rng.randf_range(0.9, 1.1)
	_add(out, "tree", x, s, h, yaw, sc, rng.randi_range(0, CityStreets.TREE_LEAVES.size() - 1), pit)


static func _yaw(side: int) -> float:
	var n: Vector2 = CityPlan.SIDE_N[side]
	return atan2(n.x, n.y)


## A point on the sidewalk: `t` along the block edge `side` from its low end, `d` in from the curb line.
static func _edge_point(r: Rect2, side: int, t: float, d: float) -> Vector2:
	match side:
		0: return Vector2(r.end.x - d, r.position.y + t)
		1: return Vector2(r.position.x + d, r.position.y + t)
		2: return Vector2(r.position.x + t, r.end.y - d)
	return Vector2(r.position.x + t, r.position.y + d)


## `forms`: the form of the road beside each side ([] = all streets, CityPlan.block_side_form). The generator is drawn the
## same whatever the forms, so one edge's form never moves another edge's props. Beside a lane: no street trees or
## benches (its buildings carry wall lamps and hanging signs); beside a pedestrian street or a court: no signal pole.
static func _block_items(out: Array, r: Rect2, rng: RandomNumberGenerator, forms: Array = []) -> void:
	var h := CityPlan.CURB_H
	for side in 4:
		var form: String = forms[side] if side < forms.size() else "street"
		var length := r.size.y if side < 2 else r.size.x
		var a := 8.5
		var n := maxi(int((length - a * 2.0) / 9.0), 0)
		var yaw := _yaw(side)
		for i in n + 1:
			var t := a + (length - a * 2.0) * (float(i) / float(n) if n > 0 else 0.5)
			var d := 0.95       # distance in from the curb line
			var pos := _edge_point(r, side, t, d)
			if i % 3 == 1:
				_add(out, "lamp", pos.x, pos.y, h, yaw)
				if rng.randf() < 0.5:
					var q := _edge_point(r, side, t + 1.3, d)
					_add(out, "bin", q.x, q.y, h, yaw)
			else:
				if form == "lane":
					rng.randf()
					rng.randf_range(0.9, 1.1)
					rng.randi_range(0, CityStreets.TREE_LEAVES.size() - 1)
				else:
					_tree(out, rng, pos.x, pos.y, h, 0.9, true)
				if rng.randf() < 0.3 and form != "lane":
					var q := _edge_point(r, side, t + 2.6, d + 0.1)
					_add(out, "bench", q.x, q.y, h, yaw + PI)
		# A signal pole by the crosswalk at the low end of each edge, a street sign just past the corner ramp.
		if form != "pedestrian" and form != "none":
			var sp := _edge_point(r, side, 1.2, 0.8)
			_add(out, "signal", sp.x, sp.y, h, yaw)
		var sg := _edge_point(r, side, 5.6, 0.6)
		_add(out, "sign", sg.x, sg.y, h, yaw)


## The knockable furniture of a road form's segment (inner stretch r; `along_s`: its road runs along s): down the middle
## of a pedestrian street trees, planters and pairs of benches in turn; in a superblock's court two trees and benches.
static func _form_items(out: Array, form: String, r: Rect2, along_s: bool, rng: RandomNumberGenerator) -> void:
	var a := 1 if along_s else 0          # the axis the segment runs along
	var c := r.get_center()
	var yaw_along := 0.0 if along_s else PI * 0.5
	match form:
		"pedestrian":
			var length := r.size[a]
			# Clear of the crossings at both ends (a walkway crossing runs 3 m in from each end, 3 m wide).
			var n := maxi(int((length - 14.0) / 11.0), 1)
			for i in n + 1:
				var p := c
				p[a] = r.position[a] + 7.0 + (length - 14.0) * float(i) / float(n)
				match (i + rng.randi_range(0, 2)) % 3:
					0: _tree(out, rng, p.x, p.y, 0.0, 1.0, false)
					1: _add(out, "planter", p.x, p.y, 0.0, yaw_along)
					_:
						var q := p
						q[1 - a] += 0.7
						_add(out, "bench", q.x, q.y, 0.0, yaw_along + PI * 0.5)
						q[1 - a] -= 1.4
						_add(out, "bench", q.x, q.y, 0.0, yaw_along - PI * 0.5)
		"none":
			for k: float in [-0.25, 0.25]:
				var p := c
				p[a] += r.size[a] * k
				_tree(out, rng, p.x, p.y, CityPlan.CURB_H, 1.1, false)
				var q := p
				q[1 - a] += 2.2
				_add(out, "bench", q.x, q.y, CityPlan.CURB_H, yaw_along + PI * 0.5)


## Bins along a service alley, close to its walls, alternating sides (props never block a mech).
static func _alley_items(out: Array, a: Dictionary, rng: RandomNumberGenerator) -> void:
	var r: Rect2 = a["rect"]
	var along := int(a["axis"])
	var length := r.size[along]
	var t := 4.0 + rng.randf() * 4.0
	var k := 0
	while t < length - 3.0:
		var pos := Vector2.ZERO
		pos[along] = r.position[along] + t
		pos[1 - along] = r.position[1 - along] + 0.9 if k % 2 == 0 else r.end[1 - along] - 0.9
		var yaw := _yaw((2 if k % 2 == 0 else 3) if along == 0 else (0 if k % 2 == 0 else 1))
		_add(out, "bin", pos.x, pos.y, CityPlan.CURB_H, yaw)
		if rng.randf() < 0.5:
			var q := pos
			q[along] += 0.8
			_add(out, "bin", q.x, q.y, CityPlan.CURB_H, yaw)
		t += rng.randf_range(8.0, 13.0)
		k += 1


static func _lot_items(out: Array, l: Dictionary, rng: RandomNumberGenerator) -> void:
	var r: Rect2 = (l["rect"] as Rect2).grow(-2.0)
	if r.size.x < 1.0 or r.size.y < 1.0:
		return
	var c := r.get_center()
	var h := CityPlan.CURB_H
	match str(l["open"]):
		"garden":
			var n := clampi(int(r.size.x * r.size.y / 60.0), 1, 6)
			for i in n:
				var x := rng.randf_range(r.position.x, r.end.x)
				var s := rng.randf_range(r.position.y, r.end.y)
				_tree(out, rng, x, s, h + 0.25, rng.randf_range(0.9, 1.3), false)
		"plaza":
			_tree(out, rng, c.x, c.y, h + 0.7, 1.2, false)
			if r.size.y > 8.0:
				_add(out, "bench", c.x, r.position.y + 0.5, h, 0.0)
				_add(out, "bench", c.x, r.end.y - 0.5, h, PI)
		"park":
			# Benches around the fountain, trees on the lawns.
			for k in 4:
				var ang := PI * 0.25 + PI * 0.5 * float(k)
				_add(out, "bench", c.x + sin(ang) * 5.6, c.y + cos(ang) * 5.6, h, ang + PI)
			var n := clampi(int(r.size.x * r.size.y / 55.0), 4, 40)
			for i in n:
				var q := Vector2(rng.randf_range(r.position.x, r.end.x), rng.randf_range(r.position.y, r.end.y))
				if absf(q.x - c.x) < 3.2 or absf(q.y - c.y) < 3.2 or q.distance_to(c) < 8.0:
					continue
				_tree(out, rng, q.x, q.y, h, rng.randf_range(1.0, 1.6), false)


