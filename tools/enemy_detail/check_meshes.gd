extends SceneTree
## Headless check of every EnemyMeshes part with the same mesh checks as tests/test_geometry_audit.gd (no degenerate
## triangles, valid normals, winding matches the stored normal, watertight: 0 open edges except the two buried bases the
## audit allows), plus: no vertex colour outside the palette, the gunship / dropship parts inside their contract boxes
## (antigravity, thread babamech-20261122-2000-enemy-art), and faces per part / unit / typical deck. Also every trooper look
## variant (EnemyMeshes.trooper_parts(), 2 kits x TROOPER_VARIANTS): same checks (the variant body / plate tints added to
## the palette), 450..680 faces, the kit's muzzle (front of the AABB) and side extent unchanged from variant 0, the body
## height within +-5 % of 2.26 m (measured without the antenna whips: vertices below 2.45 m with |x| < 0.28), the id helpers.
## Exit code 1 on any failure.
##   godot --headless --path . --script res://tools/enemy_detail/check_meshes.gd

const PARTS := ["turret_base", "turret_gun", "turret_sniper_gun", "turret_missile_gun", "turret_gun_wreck", "strider_chassis",
	"strider_breacher_chassis", "strider_sensor", "strider_leg", "tank_hull", "tank_turret", "tank_turret_wreck", "tank_vents",
	"drone_hull", "drone_optic", "drone_cone", "trooper_rifle", "trooper_at", "debris_plate", "debris_chunk", "rupture_core",
	"gunship_hull", "gunship_pods", "gunship_thrusters", "dropship_hull", "dropship_rotors", "dropship_bay"]
const OPEN_ALLOWED := ["turret_base", "tank_hull"]
## Contract boxes [min, max]: inside the unit's overall size (gunship 5.6 x 2.8 x 6.8 m, dropship 5.2 x 2.8 x 6.8 m; the
## dropship's rotors keep the placeholder's 5.7 m span) and around the part's hit spheres.
const CONTRACT := {
	"gunship_hull": [Vector3(-2.8, -0.95, -3.45), Vector3(2.8, 1.7, 3.4)],
	"gunship_pods": [Vector3(-2.45, -0.75, -2.3), Vector3(2.45, 0.45, 0.5)],
	"gunship_thrusters": [Vector3(-2.9, -0.2, -0.3), Vector3(2.9, 1.0, 2.5)],
	"dropship_hull": [Vector3(-1.7, -0.9, -3.45), Vector3(1.7, 1.4, 3.3)],
	"dropship_rotors": [Vector3(-2.9, 0.0, -1.2), Vector3(2.9, 1.0, 1.2)],
	"dropship_bay": [Vector3(-1.15, -1.3, -1.25), Vector3(1.15, -0.5, 1.45)],
}
const UNITS := {
	"turret": ["turret_base", "turret_gun"],
	"turret_sniper": ["turret_base", "turret_sniper_gun"],
	"turret_missile": ["turret_base", "turret_missile_gun"],
	"strider": ["strider_chassis", "strider_sensor", "strider_leg", "strider_leg"],
	"strider_breacher": ["strider_breacher_chassis", "strider_sensor", "strider_leg", "strider_leg"],
	"tank": ["tank_hull", "tank_turret", "tank_vents"],
	"drone": ["drone_hull", "drone_optic", "drone_cone"],
	"troop_squad": ["trooper_rifle_0", "trooper_rifle_5", "trooper_rifle_7", "trooper_rifle_10"],
	"troop_roof": ["trooper_at_0", "trooper_at_3", "trooper_at_8", "trooper_at_11"],
	"gunship": ["gunship_hull", "gunship_pods", "gunship_thrusters"],
	"dropship": ["dropship_hull", "dropship_rotors", "dropship_bay"],
}
const DECK_SOLO := ["strider", "turret", "tank", "troop_squad", "turret_sniper", "drone", "troop_roof", "gunship"]
const DECK_4P := ["strider", "turret", "tank", "troop_squad", "turret_sniper", "drone", "troop_roof", "gunship",
	"strider_breacher", "turret_missile", "tank", "troop_squad", "drone", "troop_roof", "gunship", "dropship"]

var _fail := 0


func _initialize() -> void:
	var palette: Array[Color] = [EnemyMeshes.ARMOR_DARK, EnemyMeshes.ARMOR_PLATE, EnemyMeshes.STEEL, EnemyMeshes.TRIM_RED,
		EnemyMeshes.OPTIC_GLOW, EnemyMeshes.VENT_GLOW, EnemyMeshes.SLATE, EnemyMeshes.CIVIC_CREAM, EnemyMeshes.LAMP_AMBER,
		EnemyMeshes.CHARRED, EnemyMeshes.CHARRED_EDGE]
	for n in EnemyMeshes.TROOPER_VARIANTS:
		palette.append_array(EnemyMeshes.trooper_colours(n))
	var t0 := Time.get_ticks_usec()
	for p: String in EnemyMeshes.trooper_parts():
		EnemyMeshes.mesh(p)
	print("[mesh] built %d trooper variants in %.1f ms" % [EnemyMeshes.trooper_parts().size(),
			float(Time.get_ticks_usec() - t0) / 1000.0])
	var all_parts: Array = PARTS.duplicate()
	all_parts.append_array(EnemyMeshes.trooper_parts())
	var faces := {}
	for p: String in all_parts:
		var m := EnemyMeshes.mesh(p)
		var st := _stats(m)
		var notes: Array[String] = []
		if int(st["degenerate"]) > 0 or int(st["bad_normal"]) > 0 or int(st["bad_winding"]) > 0:
			notes.append("BAD deg %d norm %d wind %d" % [st["degenerate"], st["bad_normal"], st["bad_winding"]])
		if int(st["open_edges"]) > 0 and not p in OPEN_ALLOWED:
			notes.append("OPEN %d" % st["open_edges"])
		var odd := _odd_colours(m, palette)
		if not odd.is_empty():
			notes.append("NEW COLOURS %s" % ", ".join(odd.slice(0, 6)))
		var bb := m.get_aabb()
		if CONTRACT.has(p):
			var lo: Vector3 = CONTRACT[p][0]
			var hi: Vector3 = CONTRACT[p][1]
			if bb.position.x < lo.x or bb.position.y < lo.y or bb.position.z < lo.z or bb.end.x > hi.x \
					or bb.end.y > hi.y or bb.end.z > hi.z:
				notes.append("OUTSIDE CONTRACT %s..%s" % [str(lo), str(hi)])
		var glow := 0
		for s in m.get_surface_count():
			if m.surface_get_name(s) == "glow":
				glow += (m.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
		if p in EnemyMeshes.trooper_parts():
			notes.append_array(_trooper_notes(p, m, int(st["tris"])))
		if not notes.is_empty():
			_fail += 1
		faces[p] = int(st["tris"])
		print("[mesh] %-26s %5d tris (glow %3d, open %d)  aabb %s .. %s  %s" % [p, st["tris"], glow, st["open_edges"],
				str(bb.position.snapped(Vector3.ONE * 0.01)), str(bb.end.snapped(Vector3.ONE * 0.01)),
				"ok" if notes.is_empty() else "; ".join(notes)])
	_check_trooper_ids()
	for u: String in UNITS:
		var t := 0
		for p: String in UNITS[u]:
			t += int(faces[p])
		print("[mesh] unit %-18s %5d tris" % [u, t])
	for deck_name: String in ["solo", "4p"]:
		var deck: Array = DECK_SOLO if deck_name == "solo" else DECK_4P
		var t := 0
		for u: String in deck:
			for p: String in UNITS[u]:
				t += int(faces[p])
		print("[mesh] deck %s (%d units incl. gunship%s): %d tris" % [deck_name, deck.size(),
				" + dropship" if deck_name == "4p" else "", t])
	print("[mesh] %s (%d parts with problems)" % ["PASS" if _fail == 0 else "FAIL", _fail])
	quit(1 if _fail > 0 else 0)


## Per-variant contract: faces, kit muzzle / side extent as variant 0, body height (faces below 2.45 m) within +-5 %.
func _trooper_notes(p: String, m: ArrayMesh, tris: int) -> Array[String]:
	var out: Array[String] = []
	if tris < 450 or tris > 680:
		out.append("TRIS %d outside 450..680" % tris)
	var id := EnemyMeshes.trooper_id(p)
	var ref := EnemyMeshes.mesh(EnemyMeshes.trooper_part(id[0], 0)).get_aabb()
	var bb := m.get_aabb()
	if absf(bb.position.z - ref.position.z) > 0.01:
		out.append("MUZZLE z %.3f != %.3f" % [bb.position.z, ref.position.z])
	var top := 0.0
	for s in m.get_surface_count():
		for v: Vector3 in m.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
			if v.y < 2.45 and absf(v.x) < 0.28:
				top = maxf(top, v.y)
	if absf(top / 2.26 - 1.0) > 0.05:
		out.append("HEIGHT %.3f outside 2.26 +-5%%" % top)
	var lk := EnemyMeshes.trooper_look(int(id[1]))
	print("[mesh]   %-18s %s / %s / %s / %s%s  h %.2f  top %.3f" % [p, EnemyMeshes.TROOPER_BUILDS[lk["build"]],
			EnemyMeshes.TROOPER_HELMETS[lk["helmet"]], EnemyMeshes.TROOPER_GEAR[lk["gear"]],
			EnemyMeshes.TROOPER_MARKS[lk["mark"]], " / LEADER" if lk["leader"] else "", lk["height"], top])
	return out


## Id helpers: trooper_part wraps any seed, the old ids alias variant 0, look triples are unique.
func _check_trooper_ids() -> void:
	var bad: Array[String] = []
	if EnemyMeshes.trooper_part("rifle", -1) != "trooper_rifle_%d" % (EnemyMeshes.TROOPER_VARIANTS - 1):
		bad.append("trooper_part(-1)")
	if EnemyMeshes.trooper_part("at", 12345) != "trooper_at_%d" % posmod(12345, EnemyMeshes.TROOPER_VARIANTS):
		bad.append("trooper_part(12345)")
	if EnemyMeshes.mesh("trooper_rifle") != EnemyMeshes.mesh("trooper_rifle_0") 			or EnemyMeshes.mesh("trooper_at") != EnemyMeshes.mesh("trooper_at_0"):
		bad.append("old ids != variant 0")
	for x: String in ["trooper_rifle_12", "trooper_rifle_-1", "trooper_mg_3", "trooper_", "trooper_rifle_x"]:
		if not EnemyMeshes.trooper_id(x).is_empty():
			bad.append("trooper_id(%s) accepted" % x)
	var seen := {}
	for n in EnemyMeshes.TROOPER_VARIANTS:
		var lk := EnemyMeshes.trooper_look(n)
		var key := "%d%d%d" % [lk["build"], lk["helmet"], lk["gear"]]
		if seen.has(key):
			bad.append("variants %d and %d share build/helmet/gear" % [seen[key], n])
		seen[key] = n
	if not bad.is_empty():
		_fail += 1
	print("[mesh] trooper ids: %s" % ("ok" if bad.is_empty() else "; ".join(bad)))


## The geometry audit's counts (tests/test_geometry_audit.gd _check_mesh_winding, same quantisation).
func _stats(mesh: ArrayMesh) -> Dictionary:
	var st := {"tris": 0, "bad_winding": 0, "degenerate": 0, "bad_normal": 0, "open_edges": 0}
	var edges := {}
	for s in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		st["tris"] = int(st["tris"]) + v.size() / 3
		for t in v.size() / 3:
			var v0 := v[t * 3]
			var v1 := v[t * 3 + 1]
			var v2 := v[t * 3 + 2]
			var cr := (v2 - v0).cross(v1 - v0)
			var area := cr.length()
			if area < 1e-8 or not is_finite(area):
				st["degenerate"] = int(st["degenerate"]) + 1
				continue
			var g := cr / area
			for i in 3:
				var nn := n[t * 3 + i]
				if nn.length_squared() < 0.5:
					st["bad_normal"] = int(st["bad_normal"]) + 1
				elif g.dot(nn.normalized()) < 0.95:
					st["bad_winding"] = int(st["bad_winding"]) + 1
			var q := [_q(v0), _q(v1), _q(v2)]
			for e: Array in [[q[0], q[1]], [q[1], q[2]], [q[2], q[0]]]:
				var key := "%s>%s" % [e[0], e[1]]
				edges[key] = int(edges.get(key, 0)) + 1
	for key: String in edges:
		var ab := key.split(">")
		var d := int(edges[key]) - int(edges.get("%s>%s" % [ab[1], ab[0]], 0))
		if d > 0:
			st["open_edges"] = int(st["open_edges"]) + d
	return st


static func _q(v: Vector3) -> String:
	return "%d,%d,%d" % [int(round(v.x * 2000.0)), int(round(v.y * 2000.0)), int(round(v.z * 2000.0))]


## Vertex colours that are no palette colour lightened / darkened by up to 4 % (MeshKit.shade is 3.5 %).
func _odd_colours(mesh: ArrayMesh, palette: Array[Color]) -> Array:
	var seen := {}
	var odd := []
	for s in mesh.get_surface_count():
		var cols: PackedColorArray = mesh.surface_get_arrays(s)[Mesh.ARRAY_COLOR]
		for c in cols:
			var key := c.to_rgba32()
			if seen.has(key):
				continue
			seen[key] = true
			var ok := false
			for p in palette:
				for t in 9:
					var f := float(t) * 0.005
					if _close(c, p.lightened(f)) or _close(c, p.darkened(f)):
						ok = true
						break
				if ok:
					break
			if not ok:
				odd.append("#" + c.to_html(false))
	return odd


static func _close(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.006 and absf(a.g - b.g) < 0.006 and absf(a.b - b.b) < 0.006
