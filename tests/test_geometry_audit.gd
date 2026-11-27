extends TestCase
## Automated 3D geometry & mesh integrity audit across CityDistrict, CityProps, MechMeshes, EnemyMeshes, CombatMeshes,
## PilotHead, and HangarBay. Verifies:
##   1. Winding vs. stored vertex normals on every triangle (Godot CW front-face convention: (v2 - v0) x (v1 - v0) == n).
##   2. Zero degenerate zero-area triangles and all stored normals valid.
##   3. Exposed-face & watertight checks:
##      - All toppleable CityProps have downward-facing bottom caps (and tree lower canopy underside cap).
##      - Building parapets rising above roof height have both outward and inward faces.
##      - Shop awnings have double-sided front valances and side gussets.
##      - Elevated water tanks, overhanging conical tank roofs, civic gable eaves, park column capitals, and park fountain
##        upper bowls have downward-facing underside caps.
##      - Hull boundary wall sill ledge has an underside cap and transoms have top & bottom caps.
##      - MechMeshes.hatch flat top rim faces strictly +Y (guards against coplanar-centroid flip) and hip_socket cup is
##        watertight underneath.
##      - EnemyMeshes parts are watertight (outside the two plinth/hull-buried lathe bases).
##      - HangarBay encloses its near bulkhead wall (z = NEAR_Z) for 360-degree lab orbit.


func setup() -> void:
	_audit_mech_meshes()
	_audit_enemy_meshes()
	_audit_combat_meshes()
	_audit_pilot_heads()
	_audit_city_props()
	_audit_city_districts()
	_audit_hangar_bay()
	await _audit_hangar_clamps()
	finish()


# --- Core mesh checks ------------------------------------------------------------------------------------

func _check_mesh_winding(mesh: ArrayMesh, label: String) -> Dictionary:
	var stats := {"tris": 0, "bad_winding": 0, "degenerate": 0, "bad_normal": 0, "open_edges": 0}
	if mesh == null:
		check(false, "%s: mesh is null" % label)
		return stats
	var edge_counts := {}
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var idx: Variant = arrays[Mesh.ARRAY_INDEX]
		var use_idx := idx is PackedInt32Array and not (idx as PackedInt32Array).is_empty()
		var n_verts := (idx as PackedInt32Array).size() if use_idx else verts.size()
		var n_tris := n_verts / 3
		stats["tris"] = int(stats["tris"]) + n_tris
		for t in n_tris:
			var i0 := (idx as PackedInt32Array)[t * 3] if use_idx else t * 3
			var i1 := (idx as PackedInt32Array)[t * 3 + 1] if use_idx else t * 3 + 1
			var i2 := (idx as PackedInt32Array)[t * 3 + 2] if use_idx else t * 3 + 2
			var v0 := verts[i0]
			var v1 := verts[i1]
			var v2 := verts[i2]
			var cross := (v2 - v0).cross(v1 - v0)
			var area2 := cross.length()
			if area2 < 1e-8 or not is_finite(area2):
				stats["degenerate"] = int(stats["degenerate"]) + 1
				continue
			var g := cross / area2
			for vi: int in [i0, i1, i2]:
				var n := norms[vi]
				if not is_finite(n.x) or not is_finite(n.y) or not is_finite(n.z) or n.length_squared() < 0.5:
					stats["bad_normal"] = int(stats["bad_normal"]) + 1
				elif g.dot(n.normalized()) < 0.95:
					stats["bad_winding"] = int(stats["bad_winding"]) + 1
			# Quantized directed half-edges for boundary / watertightness analysis.
			var qs := [_q(v0), _q(v1), _q(v2)]
			for e in [[qs[0], qs[1]], [qs[1], qs[2]], [qs[2], qs[0]]]:
				var k := "%s>%s" % [e[0], e[1]]
				edge_counts[k] = int(edge_counts.get(k, 0)) + 1
	for k: String in edge_counts:
		var parts := k.split(">")
		var rev := "%s>%s" % [parts[1], parts[0]]
		var c_fwd := int(edge_counts[k])
		var c_rev := int(edge_counts.get(rev, 0))
		if c_fwd > c_rev:
			stats["open_edges"] = int(stats["open_edges"]) + (c_fwd - c_rev)
	check(int(stats["tris"]) > 0, "%s: has triangles (%d)" % [label, stats["tris"]])
	eq(int(stats["degenerate"]), 0, "%s: zero degenerate triangles" % label)
	eq(int(stats["bad_normal"]), 0, "%s: all stored normals valid" % label)
	eq(int(stats["bad_winding"]), 0, "%s: every triangle winding matches stored normal" % label)
	return stats


static func _q(v: Vector3) -> String:
	return "%d,%d,%d" % [int(round(v.x * 2000.0)), int(round(v.y * 2000.0)), int(round(v.z * 2000.0))]


static func _triangles(mesh: ArrayMesh) -> Array:
	var out := []
	if mesh == null:
		return out
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for t in verts.size() / 3:
			var v0 := verts[t * 3]
			var v1 := verts[t * 3 + 1]
			var v2 := verts[t * 3 + 2]
			var n := norms[t * 3]
			var c := (v0 + v1 + v2) / 3.0
			out.append({"v0": v0, "v1": v1, "v2": v2, "n": n, "c": c})
	return out


# --- Audits ----------------------------------------------------------------------------------------------

func _audit_mech_meshes() -> void:
	for part: String in MechMeshes.all_parts():
		var m := MechMeshes.mesh(part)
		var st := _check_mesh_winding(m, "MechMeshes.%s" % part)
		if part in ["torso", "pelvis", "back_plate", "shoulder_pylon", "shoulder_pod", "side_mount",
				"thigh", "shin", "tarsus", "hip_socket", "hip_cap", "knee_cap", "ankle_cap", "foot", "toe", "spur"] \
				or part.trim_prefix("weapon_") in MechMeshes.EQUIPMENT:
			eq(int(st["open_edges"]), 0, "MechMeshes.%s: watertight (0 open edges)" % part)
	# Hatch flat top rim at y = 0.1 must face strictly +Y (no coplanar-centroid flip).
	var hatch := MechMeshes.mesh("hatch")
	var rim_up := 0
	var rim_down := 0
	for tri: Dictionary in _triangles(hatch):
		var c: Vector3 = tri["c"]
		var n: Vector3 = tri["n"]
		var r := Vector2(c.x, c.z).length()
		if absf(c.y - 0.1) < 0.01 and r > 0.38 and r < 0.48:
			if n.y > 0.9:
				rim_up += 1
			elif n.y < -0.9:
				rim_down += 1
	check(rim_up == 20 and rim_down == 0, "MechMeshes.hatch: top rim faces strictly +Y (up=%d, down=%d)" % [rim_up, rim_down])
	# Hip socket cup must be closed underneath at y = 0.1.
	var sock := MechMeshes.mesh("hip_socket")
	var sock_bot := 0
	for tri: Dictionary in _triangles(sock):
		var c: Vector3 = tri["c"]
		var n: Vector3 = tri["n"]
		if absf(c.y - 0.1) < 0.02 and Vector2(c.x, c.z).length() < 0.4 and n.y < -0.9:
			sock_bot += 1
	check(sock_bot >= 6, "MechMeshes.hip_socket: cup has bottom cap at y=0.1 (%d tris)" % sock_bot)
	# The Bulwark's parts (BulwarkMeshes): every one closed and outward-facing (chassis-rules 2.1, 9.1).
	for part: String in BulwarkMeshes.all_parts():
		var bst := _check_mesh_winding(BulwarkMeshes.mesh(part), "BulwarkMeshes.%s" % part)
		eq(int(bst["open_edges"]), 0, "BulwarkMeshes.%s: watertight (0 open edges)" % part)
	_audit_wasp_meshes()


## The Wasp's parts (WaspMeshes): every one closed and outward-facing (chassis-rules 2.1, 9.1); it is seen from below (the
## belly, the fan undersides, the legs) and from behind, so the underside facets exist: the hull has downward faces under
## the belly, the fan ring under its duct; and no two different parts share a face plane where they meet (5.3: the
## coaming's top over the hatch collar's foot, the pads' faces under their mounts are offset, not coplanar).
func _audit_wasp_meshes() -> void:
	for part: String in WaspMeshes.all_parts():
		var st := _check_mesh_winding(WaspMeshes.mesh(part), "WaspMeshes.%s" % part)
		eq(int(st["open_edges"]), 0, "WaspMeshes.%s: watertight (0 open edges)" % part)
	for pair: Array in [["wasp_hull", -0.55], ["wasp_fan_ring", 0.11]]:
		var down := 0
		for tri: Dictionary in _triangles(WaspMeshes.mesh(pair[0])):
			if (tri["n"] as Vector3).y < -0.7 and (tri["c"] as Vector3).y < float(pair[1]):
				down += 1
		check(down >= 8, "WaspMeshes.%s: has underside faces seen from below (%d)" % [pair[0], down])
	# Coplanar checks at the seams that sit flush by design: the hatch collar's foot is 4 cm under the coaming's top; each
	# mount's base is sunk 5-10 mm into its pad.
	check(WaspMeshes.COAM_TOP - (WaspMeshes.HATCH_Y - 0.1) >= 0.004, "the hatch collar's foot is sunk into the coaming, not flush")
	check(absf(WaspMeshes.COAM_TOP - (WaspMeshes.HATCH_Y + 0.1)) >= 0.004, "the coaming's top is not the hatch rim's plane")
	var hull_top := (WaspMeshes.hull_at(WaspMeshes.HATCH_Z, 0.0)[0] as Vector3).y
	check(WaspMeshes.HATCH_Y - 0.04 - hull_top >= 0.004, "the hatch's lid sits over the hull's top inside the coaming (%.3f)" % (WaspMeshes.HATCH_Y - 0.04 - hull_top))


func _audit_enemy_meshes() -> void:
	var parts := ["turret_base", "turret_gun", "turret_gun_wreck", "turret_sniper_gun", "turret_missile_gun",
		"strider_chassis", "strider_breacher_chassis", "strider_sensor", "strider_leg",
		"strider_thigh", "strider_shin", "strider_foot",
		"trooperrig_rifle_0_torso", "trooperrig_rifle_4_head", "trooperrig_at_8_arms", "trooperrig_rifle_5_thigh_l",
		"trooperrig_at_3_shin_r", "trooperrig_rifle_11_boot_l",
		"tank_hull", "tank_turret", "tank_turret_wreck", "tank_vents",
		"drone_hull", "drone_optic", "drone_cone", "trooper_rifle", "trooper_at",
		"gunship_hull", "gunship_pods", "gunship_thrusters",
		"dropship_hull", "dropship_rotors", "dropship_bay",
		"debris_plate", "debris_chunk", "rupture_core"]
	for part: String in parts:
		var m := EnemyMeshes.mesh(part)
		var st := _check_mesh_winding(m, "EnemyMeshes.%s" % part)
		# turret_base (neck bottom buried in plinth) and tank_hull (turret ring buried in glacis) have 1 buried open base;
		# every other enemy mesh must be strictly watertight.
		if part not in ["turret_base", "tank_hull"]:
			eq(int(st["open_edges"]), 0, "EnemyMeshes.%s: watertight (0 open edges)" % part)
	for gpart: String in ["gunship_hull", "gunship_pods", "gunship_thrusters"]:
		var gm := EnemyGunship.placeholder_mesh(gpart)
		var gst := _check_mesh_winding(gm, "EnemyGunship.%s" % gpart)
		eq(int(gst["open_edges"]), 0, "EnemyGunship.%s: watertight (0 open edges)" % gpart)
	for dpart: String in ["dropship_hull", "dropship_rotors", "dropship_bay"]:
		var dm := EnemyDropDrone.placeholder_mesh(dpart)
		var dst := _check_mesh_winding(dm, "EnemyDropDrone.%s" % dpart)
		eq(int(dst["open_edges"]), 0, "EnemyDropDrone.%s: watertight (0 open edges)" % dpart)


func _audit_combat_meshes() -> void:
	var meshes := {
		"ico": CombatMeshes.ico(LowPolyPalette.ORANGE),
		"shell": CombatMeshes.shell(LowPolyPalette.AMBER),
		"shard": CombatMeshes.shard(LowPolyPalette.GREY),
		"ring": CombatMeshes.ring(LowPolyPalette.ORANGE),
		"scorch": CombatMeshes.scorch(Color.BLACK),
		"ember_scorch": CombatMeshes.ember_scorch(0),
		"prism3": CombatMeshes.prism3(LowPolyPalette.TEAL),
		"rocket": Rocket.rocket_mesh(),
		"mortar_shell": MortarShell.shell_mesh(),
		"muzzle_flash": MuzzleFlash.mesh(),
		"flame_ball": ImpactFx.flame_ball(LowPolyFlame.CORE),
		"stem_flame": ImpactFx.stem(false),
		"stem_smoke": ImpactFx.stem(true),
		"flame_jet": LowPolyFlame.jet(),
		"flame_tongue": LowPolyFlame.tongue(),
	}
	for k: String in meshes:
		_check_mesh_winding(meshes[k] as ArrayMesh, "Combat.%s" % k)
	# WorldAimMarkers built meshes.
	var aim := WorldAimMarkers.new()
	add_child(aim)
	for k in aim._pip_meshes.size():
		_check_mesh_winding(aim._pip_meshes[k], "WorldAimMarkers.pip_%d" % k)
	_check_mesh_winding(aim._ring_mesh, "WorldAimMarkers.ring")
	_check_mesh_winding(aim._x_mesh, "WorldAimMarkers.x")
	aim.queue_free()


func _audit_pilot_heads() -> void:
	var root := Node3D.new()
	var face := PilotHeadChicken.new()
	face.build(root)
	for pname: String in face.piece_names():
		var p := face.piece(pname)
		for c in p.get_children():
			if c is MeshInstance3D and (c as MeshInstance3D).mesh is ArrayMesh:
				var st := _check_mesh_winding((c as MeshInstance3D).mesh as ArrayMesh, "PilotHeadChicken.%s" % pname)
				if pname in ["WattleL", "WattleR"]:
					eq(int(st["open_edges"]), 0, "PilotHeadChicken.%s: watertight wattle" % pname)
	root.free()


func _audit_city_props() -> void:
	for sh: Array in CityProps._shapes():
		var type := str(sh[0])
		var variant := int(sh[1])
		var geo := CityProps._proto(type, variant)
		var m := geo.commit()
		var st := _check_mesh_winding(m, "CityProps.%s%d" % [type, variant])
		# Every toppleable prop must have downward-facing base cap triangles near y = 0 so knocking it over 78-90 deg
		# never exposes a hollow underside.
		var base_caps := 0
		var canopy_caps := 0
		for tri: Dictionary in _triangles(m):
			var c: Vector3 = tri["c"]
			var n: Vector3 = tri["n"]
			if n.y < -0.9 and c.y < 0.05:
				base_caps += 1
			if type == "tree" and n.y < -0.9 and absf(c.y - 2.2) < 0.05:
				canopy_caps += 1
		check(base_caps >= 2, "CityProps.%s%d: has base bottom cap for toppling (%d tris)" % [type, variant, base_caps])
		if type == "tree":
			check(canopy_caps >= 6, "CityProps.%s%d: lower canopy has bottom cap (%d tris)" % [type, variant, canopy_caps])
		if type in ["signal", "sign", "bench", "bin"]:
			eq(int(st["open_edges"]), 0, "CityProps.%s%d: watertight (0 open edges)" % [type, variant])


func _audit_city_districts() -> void:
	# Audit isolated building & street features once.
	_audit_isolated_features()
	# Audit full open (with atrium) and walled districts.
	for cfg: Dictionary in [
		{"name": "open_atrium", "params": {"seed": 3, "size_x": 120.0, "size_s": 130.0, "atrium": 1.0}},
		{"name": "walled", "params": {"seed": 3, "size_x": 120.0, "size_s": 130.0, "walls": 1.0}},
	]:
		var d := CityDistrict.new()
		d.with_rig = false
		add_child(d)
		d.build(cfg["params"] as Dictionary)
		var mis := d.find_children("*", "MeshInstance3D", true, false)
		for node in mis:
			var mi := node as MeshInstance3D
			if mi.mesh is ArrayMesh:
				_check_mesh_winding(mi.mesh as ArrayMesh, "City.%s.%s" % [cfg["name"], mi.name])
		_audit_district_buildings(d, str(cfg["name"]))
		if cfg["name"] == "walled":
			_audit_hull_walls(d)
		d.queue_free()


func _audit_isolated_features() -> void:
	# 1. Water tank: elevated cylinder (y = 1.4) and overhanging cone roof (y = 3.6) both capped underneath.
	var wt := CityGeo.new()
	CityBuildings._water_tank(wt, Transform3D.IDENTITY, Vector3.ZERO, CityPalette.C["metal"])
	var wt_mesh := wt.commit()
	_check_mesh_winding(wt_mesh, "Feature.water_tank")
	var tank_bot := 0
	var cone_bot := 0
	for tri: Dictionary in _triangles(wt_mesh):
		var c: Vector3 = tri["c"]
		var n: Vector3 = tri["n"]
		if n.y < -0.9 and absf(c.y - 1.4) < 0.05:
			tank_bot += 1
		if n.y < -0.9 and absf(c.y - 3.6) < 0.05:
			cone_bot += 1
	check(tank_bot >= 8, "Feature.water_tank: elevated cylinder has bottom cap (%d)" % tank_bot)
	check(cone_bot >= 8, "Feature.water_tank: overhanging conical roof has bottom cap (%d)" % cone_bot)

	# 2. Shop awning: front valance and both side gussets are double-sided so viewing from below never culls them.
	var aw := CityGeo.new()
	var f := CityBuildings.Face.new()
	f.xf = Transform3D.IDENTITY
	f.w = 4.0
	f.y0 = 0.0
	f.y1 = 6.5
	CityBuildings._awning(aw, f, 0.3, 3.7, 3.3, 2.75, 1.5, CityPalette.C["terracotta"], CityPalette.C["terracotta_dark"])
	var aw_mesh := aw.commit()
	_check_mesh_winding(aw_mesh, "Feature.awning")
	var val_pos := 0
	var val_neg := 0
	var side_pos := 0
	var side_neg := 0
	for tri: Dictionary in _triangles(aw_mesh):
		var c: Vector3 = tri["c"]
		var n: Vector3 = tri["n"]
		if absf(c.z - 1.5) < 0.02:
			if n.z > 0.9:
				val_pos += 1
			elif n.z < -0.9:
				val_neg += 1
		if absf(c.x - 0.3) < 0.02 or absf(c.x - 3.7) < 0.02:
			if n.x > 0.9:
				side_pos += 1
			elif n.x < -0.9:
				side_neg += 1
	check(val_pos >= 2 and val_neg >= 2, "Feature.awning: front valance is double-sided (pos=%d neg=%d)" % [val_pos, val_neg])
	check(side_pos >= 2 and side_neg >= 2, "Feature.awning: side gussets are double-sided (pos=%d neg=%d)" % [side_pos, side_neg])

	# 3. Park column capital drum underside at ceiling - 1.2.
	var col_geo := CityGeo.new()
	CityBuildings.column(col_geo, Transform3D.IDENTITY, {"half": 2.0}, 40.0)
	var col_mesh := col_geo.commit()
	_check_mesh_winding(col_mesh, "Feature.park_column")
	var cap_bot := 0
	for tri: Dictionary in _triangles(col_mesh):
		var c: Vector3 = tri["c"]
		var n: Vector3 = tri["n"]
		if n.y < -0.9 and absf(c.y - 38.8) < 0.05:
			cap_bot += 1
	check(cap_bot >= 8, "Feature.park_column: overhanging capital drum has bottom cap (%d)" % cap_bot)


func _audit_district_buildings(d: CityDistrict, tag: String) -> void:
	var plan := d.plan
	# Civic hall overhanging gable eaves soffit at y = roof.
	for i in plan.buildings.size():
		if str(plan.buildings[i]["style"]) == "civic":
			var cg := CityGeo.new()
			var rng := RandomNumberGenerator.new()
			rng.seed = 1
			CityBuildings.build(cg, Transform3D.IDENTITY, Transform3D.IDENTITY, plan, i, rng)
			var cm := cg.commit()
			_check_mesh_winding(cm, "%s.civic_%d" % [tag, i])
			var roof_h := float(plan.buildings[i]["roof_h"])
			var soffit := 0
			for tri: Dictionary in _triangles(cm):
				var c: Vector3 = tri["c"]
				var n: Vector3 = tri["n"]
				if n.y < -0.9 and absf(c.y - roof_h) < 0.05:
					soffit += 1
			check(soffit >= 2, "%s.civic: overhanging gable roof has bottom soffit (%d)" % [tag, soffit])
			break

	# Park fountain upper basin underside at y = CURB_H + 2.2.
	var furn := d.get_node_or_null("Furniture") as MeshInstance3D
	if furn != null and furn.mesh is ArrayMesh:
		var has_park := false
		for l: Dictionary in plan.lots:
			if l["kind"] == "open" and str(l["open"]) == "park":
				has_park = true
		if has_park:
			var bowl_bot := 0
			for tri: Dictionary in _triangles(furn.mesh as ArrayMesh):
				var c: Vector3 = tri["c"]
				var n: Vector3 = tri["n"]
				var arc := d.ring.world_to_arc(c)
				if absf(arc.z - (CityPlan.CURB_H + 2.2)) < 0.1 and n.dot(d.ring.up_at(c)) < -0.9:
					bowl_bot += 1
			check(bowl_bot >= 8, "%s.fountain: overhanging upper basin has bottom cap (%d)" % [tag, bowl_bot])

	# Building parapets rising above tier roof height have both outward and inward horizontal faces.
	for i in plan.buildings.size():
		var b: Dictionary = plan.buildings[i]
		if str(b["style"]) in ["apartment", "office", "sage", "shops"]:
			var bg := CityGeo.new()
			var rng := RandomNumberGenerator.new()
			rng.seed = 7 + i
			CityBuildings.build(bg, Transform3D.IDENTITY, Transform3D.IDENTITY, plan, i, rng)
			var bm := bg.commit()
			var top_tier: Dictionary = b["tiers"][0]
			var y1 := float(top_tier["y1"])
			var sz: Vector2 = top_tier["size"]
			var off: Vector2 = top_tier["off"]
			var px_pos := 0
			var px_neg := 0
			for tri: Dictionary in _triangles(bm):
				var v0: Vector3 = tri["v0"]
				var v1: Vector3 = tri["v1"]
				var v2: Vector3 = tri["v2"]
				var max_y := maxf(v0.y, maxf(v1.y, v2.y))
				var c: Vector3 = tri["c"]
				var n: Vector3 = tri["n"]
				if max_y > y1 + 0.05 and max_y < y1 + 0.75 and c.x >= off.x + sz.x * 0.5 - 0.05 and absf(c.z - off.y) < sz.y * 0.45:
					if n.x > 0.9:
						px_pos += 1
					elif n.x < -0.9:
						px_neg += 1
			check(px_pos >= 2 and px_neg >= 2, "%s.building_%d (%s): parapet has front & back faces (out=%d in=%d)" % [
				tag, i, b["style"], px_pos, px_neg])


func _audit_hull_walls(d: CityDistrict) -> void:
	var walls := d.get_node_or_null("Walls") as MeshInstance3D
	check(walls != null and walls.mesh is ArrayMesh, "walled: Walls mesh exists")
	if walls == null or not (walls.mesh is ArrayMesh):
		return
	var hull_xs: Array[float] = []
	for w: Dictionary in d.plan.boundary():
		if str(w["kind"]) == "window":
			hull_xs.append(float(w["at"]))
	var sill_bot := 0
	var transom_top := 0
	var transom_bot := 0
	var sill_lo := CityWalls.HULL_SILL - 0.6
	for tri: Dictionary in _triangles(walls.mesh as ArrayMesh):
		var c: Vector3 = tri["c"]
		var n: Vector3 = tri["n"]
		var arc := d.ring.world_to_arc(c)
		var on_hull := false
		for hx in hull_xs:
			if absf(arc.x - hx) < 0.8:
				on_hull = true
				break
		if not on_hull:
			continue
		var up := d.ring.up_at(c)
		var h := arc.z
		if absf(h - sill_lo) < 0.08 and n.dot(up) < -0.9:
			sill_bot += 1
		if h > CityWalls.HULL_SILL + 2.0 and h < d.plan.p("ceiling") - 2.0:
			if n.dot(up) > 0.9:
				transom_top += 1
			elif n.dot(up) < -0.9:
				transom_bot += 1
	check(sill_bot >= 8, "walled.hull: sill ledge has underside cap (%d tris)" % sill_bot)
	check(transom_top >= 8 and transom_bot >= 8, "walled.hull: transoms have top & bottom caps (top=%d bot=%d)" % [transom_top, transom_bot])


func _audit_hangar_bay() -> void:
	var bay := HangarBay.new()
	bay.own_environment = false
	add_child(bay)
	# Verify there is a near bulkhead enclosing z >= HangarBay.NEAR_Z so 360-deg lab orbit has no open void.
	var near_wall := false
	for c in bay.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh is BoxMesh:
			var mi := c as MeshInstance3D
			var bm := mi.mesh as BoxMesh
			if mi.position.z >= HangarBay.NEAR_Z - 0.1 and bm.size.x >= HangarBay.HALF_WIDTH * 2.0 and bm.size.y >= HangarBay.HEIGHT - 0.1:
				near_wall = true
	check(near_wall, "HangarBay: near bulkhead wall encloses z = NEAR_Z")
	bay.queue_free()


## The bay's clamps and brace arms with a Bulwark and a Strider in their alcoves (playtest backlog 6: the Bulwark's
## clamps were 0.3 m stubs, and the brace pads shared a face with their sleeves), open, mid-swing and closed:
##   - no clamp face is coplanar (within 1 mm, same facing, overlapping) with another clamp face or with a mech triangle
##     (chassis rules 5.3: no z-fighting);
##   - no mech vertex is inside a clamp box (the clamps never cut into a mech);
##   - closed, every swinging clamp reaches at least ARM_MIN past its post face (no stubs), and the Bulwark's hold-down
##     shoes rest just over its hip pods (HangarBay.HOLD_GAP).
const ARM_MIN := 0.6
const COPLANAR := 0.001

func _audit_hangar_clamps() -> void:
	var bay := HangarBay.new()
	bay.own_environment = false
	add_child(bay)
	await get_tree().process_frame
	bay.show_crew([{"head": "chicken", "chassis": "bulwark", "loadout": {}}, {"head": "dog", "chassis": "strider", "loadout": {}}])
	await get_tree().process_frame
	for m in bay.models:
		m.time_scale = 0.0   # the pose fit_clamps measured (rest, no idle bob)
	var mech_tris: Array = []   # per alcove: triangles in bay space
	for i in 2:
		var tris: Array = []
		var stack: Array[Node] = [bay.models[i]]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			stack.append_array(n.get_children())
			var mi := n as MeshInstance3D
			if mi == null or not (mi.mesh is ArrayMesh) or not mi.is_visible_in_tree():
				continue
			var t := HangarBay._to_space(mi, bay)
			var flip := t.basis.determinant() < 0.0   # a mirrored part: keep the drawn facing
			for tri: Dictionary in _triangles(mi.mesh as ArrayMesh):
				var a := t * (tri["v0"] as Vector3)
				var b := t * (tri["v1"] as Vector3)
				var c := t * (tri["v2"] as Vector3)
				tris.append([a, c, b] if flip else [a, b, c])
		mech_tris.append(tris)
	for phase: float in [0.0, 0.5, 1.0]:
		bay.set_clamps(phase)   # clamp closedness (hangar v2: stored = closed, Launch opens them)
		for i in 2:
			var tag := "hangar clamps %s k=%.1f" % [bay.models[i].chassis_id, phase]
			var boxes: Array = []   # [transform (bay space, unit box scaled to size), size, node]
			for mi in bay.clamp_meshes(i):
				boxes.append([HangarBay._to_space(mi, bay), (mi.mesh as BoxMesh).size, mi])
			var region := AABB()
			for b: Array in boxes:
				var bb := (b[0] as Transform3D) * AABB(-(b[1] as Vector3) * 0.5, b[1] as Vector3)
				region = bb if region.size == Vector3.ZERO else region.merge(bb)
			region = region.grow(0.05)
			var near: Array = []
			for tri: Array in mech_tris[i]:
				if region.has_point(tri[0]) or region.has_point(tri[1]) or region.has_point(tri[2]):
					near.append(tri)
			var coplanar := 0
			var inside := 0
			for a in boxes.size():
				var fa := _box_faces(boxes[a][0], boxes[a][1])
				for b in range(a + 1, boxes.size()):
					for f: Dictionary in fa:
						for g: Dictionary in _box_faces(boxes[b][0], boxes[b][1]):
							if _faces_coplanar(f, g):
								coplanar += 1
								print("%s: coplanar %s / %s" % [tag, (boxes[a][2] as Node).get_path(), (boxes[b][2] as Node).get_path()])
				var inv := (boxes[a][0] as Transform3D).affine_inverse()
				var half := (boxes[a][1] as Vector3) * 0.5 - Vector3.ONE * 0.002
				for tri: Array in near:
					for f: Dictionary in fa:
						if _tri_on_face(tri, f):
							coplanar += 1
					for v: Vector3 in tri:
						var l := inv * v
						if absf(l.x) < half.x and absf(l.y) < half.y and absf(l.z) < half.z:
							inside += 1
			eq(coplanar, 0, "%s: no coplanar clamp faces (z-fighting)" % tag)
			eq(inside, 0, "%s: no mech vertex inside a clamp" % tag)
	# Closed: every swinging clamp reaches ARM_MIN past its post; the Bulwark's shoes rest over its hip pods.
	for i in 2:
		var tag := "hangar clamps %s closed" % bay.models[i].chassis_id
		var cx := float(HangarBay.ALCOVE_X[i])
		for c: Dictionary in bay._clamps:
			var node: Node3D = c["node"]
			if node.get_parent() != bay._clamp_roots[i] or c["kind"] != "clamp":
				continue
			var s: float = c["side"]
			var box := HangarBay.mesh_box(node, bay)
			var tip := -s * ((box.position.x if s > 0.0 else box.end.x) - (cx + s * HangarBay.ALCOVE_HALF))
			check(tip >= ARM_MIN, "%s: the %s clamp reaches %.2f m past its post (at least %.2f)" % [tag, "right" if s > 0.0 else "left", tip, ARM_MIN])
			if bay.models[i].chassis_id == "bulwark":
				var pod := bay._hold_part(i, s)
				var gap := box.position.y - pod.end.y
				check(gap > 0.004 and gap < 0.08, "%s: the hold-down shoe rests %.3f m over the hip pod" % [tag, gap])
				check(box.position.x < pod.get_center().x and box.end.x > pod.get_center().x, "%s: the pad is over the pod's middle" % tag)
	bay.queue_free()


## The six faces of a box (bay-space transform, size): centre, unit normal, half-extent axes u and v.
static func _box_faces(t: Transform3D, size: Vector3) -> Array:
	var out := []
	for ax in 3:
		for sg: float in [-1.0, 1.0]:
			var e := Vector3.ZERO
			e[ax] = sg * size[ax] * 0.5
			var u := Vector3.ZERO
			var v := Vector3.ZERO
			u[(ax + 1) % 3] = size[(ax + 1) % 3] * 0.5
			v[(ax + 2) % 3] = size[(ax + 2) % 3] * 0.5
			out.append({"c": t * e, "n": (t.basis * (e / maxf(absf(e[ax]), 1e-9))).normalized(), "u": t.basis * u, "v": t.basis * v})
	return out


## Two faces in one plane (within COPLANAR), facing the same way, with overlapping area.
static func _faces_coplanar(f: Dictionary, g: Dictionary) -> bool:
	var n: Vector3 = f["n"]
	if n.dot(g["n"]) < 0.999 or absf(((g["c"] as Vector3) - (f["c"] as Vector3)).dot(n)) > COPLANAR:
		return false
	var u: Vector3 = f["u"]
	var v: Vector3 = f["v"]
	var hu := u.length()
	var hv := v.length()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for su: float in [-1.0, 1.0]:
		for sv: float in [-1.0, 1.0]:
			var p: Vector3 = (g["c"] as Vector3) + (g["u"] as Vector3) * su + (g["v"] as Vector3) * sv - (f["c"] as Vector3)
			var q := Vector2(p.dot(u) / hu, p.dot(v) / hv)
			lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
			hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
	return minf(hi.x, hu) - maxf(lo.x, -hu) > 1e-4 and minf(hi.y, hv) - maxf(lo.y, -hv) > 1e-4


## A triangle lying on a box face (all three vertices within COPLANAR of its plane, facing the same way, its centroid on
## the face).
static func _tri_on_face(tri: Array, f: Dictionary) -> bool:
	var n: Vector3 = f["n"]
	var c: Vector3 = f["c"]
	var tn := ((tri[2] as Vector3) - (tri[0] as Vector3)).cross((tri[1] as Vector3) - (tri[0] as Vector3))
	if tn.length_squared() < 1e-12 or tn.normalized().dot(n) < 0.999:
		return false
	for p: Vector3 in tri:
		if absf((p - c).dot(n)) > COPLANAR:
			return false
	var m: Vector3 = ((tri[0] as Vector3) + (tri[1] as Vector3) + (tri[2] as Vector3)) / 3.0 - c
	var u: Vector3 = f["u"]
	var v: Vector3 = f["v"]
	return absf(m.dot(u)) <= u.length_squared() and absf(m.dot(v)) <= v.length_squared()
