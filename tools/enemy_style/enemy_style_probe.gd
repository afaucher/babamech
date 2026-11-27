extends Node
## Enemy colour-scheme render probe. Builds a seeded urban district with its real light rig (CityDistrict + CityLightRig
## "day", GraphicsQuality HIGH: the test drive's look), spawns every enemy unit idle (no firing, no telegraphs) at a street
## intersection plus a turret on a roof and a player mech for scale, then for each palette option recolours the enemy
## meshes by a vertex-colour remap (duplicated ArrayMeshes: scripts/enemy is never touched) and saves one PNG per camera.
## Run in a real renderer on the hidden desktop: tools/enemy_style/run_enemy_style.ps1 (takes the GPU lock).
##
## User args (after `--`):
##   --palettes <path>     JSON palette table (default res://tools/enemy_style/palettes_r1.json); see that file's format
##   --options A1,B2       option ids to render (default: all in the table); "current" = no remap (always allowed)
##   --baseline 0          skip the "current" baseline (rendered first by default)
##   --cams gameplay,lineup  camera presets (CAMS below)
##   --units a,b,...       unit set (default UNITS)
##   --seed N              city seed (default 7)
##   --lighting day        CityLightRig preset
##   --ai <mode>           enemy ai_mode (default idle); the world keeps ticking while a shot settles. Note: telegraph_loop
##                         shows no flare here yet (no CombatTarget in the probe)
##   --out <dir>           output dir (default res://art/renders/enemy_colour_r1); files <option>_<cam>.png
##   --banners 0           no placeholder invader banners (default: up to 4 facade banners + 1 pole banner, recoloured
##                         per option from banner_field / banner_sigil / banner_trim, defaults derived from the units)
## Prints "[estyle]" lines and quits.

const UNITS := ["turret", "turret_sniper", "turret_missile", "strider", "strider_breacher", "tank", "drone", "troop_squad"]

## Gameplay layout: arc offsets (dx, ds, h) from the intersection centre (avenue centre x, cross street centre s).
## Avenue runs along s (20 m wide), the cross street along x (12 m wide).
const PLAY_SPOTS := {
	"turret": Vector3(-17.0, 0.5, 0.0),
	"turret_sniper": Vector3(18.0, -1.0, 0.0),
	"turret_missile": Vector3(-5.0, 24.0, 0.0),
	"strider": Vector3(-6.0, 5.0, 0.0),
	"strider_breacher": Vector3(6.5, 9.0, 0.0),
	"tank": Vector3(1.0, 16.0, 0.0),
	"drone": Vector3(-1.0, 8.0, 11.0),
	"troop_squad": Vector3(4.0, -3.0, 0.0),
	"troop_roof": Vector3(4.0, -3.0, 0.0),
}
const LINEUP_SPACING := 6.2
const LINEUP_YAW := PI - 0.6     ## units turned 3/4 toward the lineup camera
const MECH_SCALE := 2.0      ## the player mech's model scale in the test drive / enemy lab

## Camera presets in arc offsets from the intersection centre: eye, target (dx, ds, h), vertical fov.
## gameplay: chase cam ~12 m behind / 10 m above a mech standing at the intersection's near edge, the group 40-65 m off.
## lineup: 3/4 view of the row of units along the cross street.
const CAMS := {
	# The game's ChaseCamera defaults (distance 16, pivot height 9.5, shoulder 3.2 right, pitch -0.18, fov 70) behind
	# PLAY_MECH, facing +s: the group stands 35-60 m from the camera.
	# Arc +x is screen LEFT when looking along +s, so the right shoulder is x - 3.2. The mech walks the avenue's left
	# lane and the view yaws slightly right toward the group, so the mech stands at the lower left, clear of the group.
	"gameplay": {"eye": Vector3(4.8, -35.7, 12.4), "target": Vector3(-1.0, 14.3, 0.4), "fov": 70.0, "layout": "play"},
	"lineup": {"eye": Vector3(-1.0, -33.0, 13.0), "target": Vector3(-1.0, 0.0, 2.0), "fov": 56.0, "layout": "lineup"},
	# Straight at facade banner 0 from 10 m (needs banners; eye / target are computed from the banner).
	"banner_close": {"eye": Vector3.ZERO, "target": Vector3.ZERO, "fov": 50.0, "layout": "play", "banner": 0, "dist": 10.0},
	# close: one shot per unit (alone at the intersection, turned 3/4), camera ~CLOSE_DIST[unit] m off: <opt>_close_<unit>.png
	"close": {"eye": Vector3.ZERO, "target": Vector3.ZERO, "fov": 50.0, "layout": "solo"},
	# parts: one shot per EnemyMeshes part id (bare mesh, 3/4 view, framed by its AABB): <opt>_part_<id>.png
	"parts": {"eye": Vector3.ZERO, "target": Vector3.ZERO, "fov": 45.0, "layout": "parts"},
}
## Camera distance per unit for the "close" preset (3/4 view, eye up at ~0.5 x distance).
const CLOSE_DIST := {"turret": 13.0, "turret_sniper": 14.0, "turret_missile": 13.0, "strider": 12.0, "strider_breacher": 12.0,
	"tank": 17.0, "drone": 8.0, "troop_squad": 12.0, "troop_roof": 12.0}
const CLOSE_YAW := PI - 0.7
const PARTS := ["turret_base", "turret_gun", "turret_sniper_gun", "turret_missile_gun", "turret_gun_wreck", "strider_chassis",
	"strider_breacher_chassis", "strider_sensor", "strider_leg", "tank_hull", "tank_turret", "tank_turret_wreck", "tank_vents",
	"drone_hull", "drone_optic", "drone_cone", "trooper_rifle", "trooper_at", "debris_plate", "debris_chunk", "rupture_core"]
const PLAY_MECH := Vector3(8.0, -20.0, 0.0)   ## the player mech, left lane, short of the intersection

## Palette keys -> the EnemyMeshes constant they replace (read live, so the remap follows the current source palette).
const KEYS := ["body", "plate", "steel", "trim", "optic", "vent"]   ## optional extra key "scanner": the drone cone
const MATCH_TOL := 0.014     ## max channel residual (8-bit vertex colours + MeshKit's +-3.5 % shade jitter)
const SETTLE := 24           ## frames after a recolour before the shot

var _args: PackedStringArray
var _world: CombatWorld
var _squad: EnemySquad
var _district: CityDistrict
var _cam: Camera3D
var _mech: MechModel
var _centre := Vector2.ZERO      ## intersection (x, s)
var _remap_cache: Dictionary = {}    ## "<option>|<mesh rid>" -> ArrayMesh
var _unmatched: Dictionary = {}      ## rgba32 -> html of vertex colours no palette key matched (logged once)


func _ready() -> void:
	_run.call_deferred()


func _say(s: String) -> void:
	print("[estyle] " + s)


func _arg(key: String, def: String) -> String:
	var v := Boot.arg_value(_args, key)
	return v if v != "" else def


func _run() -> void:
	_args = OS.get_cmdline_user_args()
	var root := get_tree().root
	GraphicsQuality.apply_viewport(root, GraphicsQuality.HIGH)
	var out_dir := _arg("--out", "res://art/renders/enemy_colour_r1")
	if out_dir.begins_with("res://") or out_dir.begins_with("user://"):
		out_dir = ProjectSettings.globalize_path(out_dir)
	DirAccess.make_dir_recursive_absolute(out_dir)
	var table := _load_palettes(_arg("--palettes", "res://tools/enemy_style/palettes_r1.json"))
	var options: Array[Dictionary] = []
	if _arg("--baseline", "1") != "0":
		options.append({"id": "current"})
	var want := _arg("--options", "")
	var want_ids := want.split(",", false)
	for o: Dictionary in table:
		if want_ids.is_empty() or str(o["id"]) in want_ids:
			options.append(o)
	if "current" in want_ids and options.filter(func(o: Dictionary) -> bool: return o["id"] == "current").is_empty():
		options.push_front({"id": "current"})
	var cams := _arg("--cams", "gameplay,lineup").split(",", false)
	var units := _arg("--units", ",".join(UNITS)).split(",", false)

	_build_city(int(_arg("--seed", "7")), _arg("--lighting", "day"))
	_world = CombatWorld.new()
	_world.name = "CombatWorld"
	_world.mission_seed = 42
	add_child(_world)
	_squad = EnemySquad.new()
	_squad.name = "Squad"
	add_child(_squad)
	_squad.setup(_world, _district.plan, _district.ring)
	_cam = Camera3D.new()
	_cam.far = 1200.0
	add_child(_cam)
	_cam.make_current()
	if _arg("--banners", "1") != "0":
		_place_banners()

	for cam_id: String in cams:
		if not CAMS.has(cam_id):
			_say("unknown camera %s (have %s)" % [cam_id, ", ".join(CAMS.keys())])
			continue
		var cam: Dictionary = CAMS[cam_id]
		var layout := str(cam["layout"])
		if layout == "solo" or layout == "parts":
			var subjects: Array = Array(units) if layout == "solo" else PARTS
			var only := _arg("--parts", "")
			if layout == "parts" and only != "":
				subjects = Array(only.split(",", false))
			for subj: String in subjects:
				if layout == "solo":
					await _spawn_solo(subj)
				else:
					await _spawn_part(subj)
				for o: Dictionary in options:
					await _shot(o, "%s_%s_%s" % [o["id"], "close" if layout == "solo" else "part", subj], out_dir)
			continue
		await _spawn_layout(layout, units)
		_place_camera(cam)
		for o: Dictionary in options:
			await _shot(o, "%s_%s" % [o["id"], cam_id], out_dir)
	_say("done")
	get_tree().quit()


func _shot(o: Dictionary, name: String, out_dir: String) -> void:
	_apply_palette(o)
	_apply_banners(o)
	var tick := _arg("--ai", "idle") != "idle"   # keep the AI (and its telegraphs) running while the shot settles
	for i in SETTLE * (4 if tick else 1):
		if tick:
			_world.advance(1.0 / 60.0)
		await get_tree().process_frame
	var img := get_tree().root.get_texture().get_image()
	var path := out_dir.path_join(name + ".png")
	if img != null:
		img.save_png(path)
		_say("saved %s" % path)
	else:
		_say("ERROR no image for %s" % path)


var _part_root: Node3D


## One unit alone at the intersection, turned 3/4; camera at CLOSE_DIST along -s, looking at its middle.
func _spawn_solo(u: String) -> void:
	await _spawn_layout("none", PackedStringArray())
	var h := 3.5 if u == "drone" else 0.0
	_spawn(u, "es_" + u, _centre.x, _centre.y, h, CLOSE_YAW)
	for i in 20:
		_world.advance(1.0 / 60.0)
		await get_tree().process_frame
	var d: float = CLOSE_DIST.get(u, 12.0)
	var mid := h + (1.0 if u == "drone" else d * 0.17)
	_place_camera({"eye": Vector3(0.0, -d, mid + d * 0.42), "target": Vector3(0.0, 0.0, mid), "fov": 50.0})


## One bare EnemyMeshes part on a 1 m plinth-less spot at the intersection, framed by its AABB from a 3/4 high angle.
func _spawn_part(p: String) -> void:
	await _spawn_layout("none", PackedStringArray())
	if _part_root != null:
		_part_root.queue_free()
	_part_root = Node3D.new()
	_part_root.name = "Parts"
	add_child(_part_root)
	var mi := EnemyMeshes.instance(p)
	if p == "drone_cone":
		mi.material_override = EnemyMeshes.scanner_material()
	var aabb := mi.mesh.get_aabb()
	var lift := maxf(0.0, -aabb.position.y) + 0.05
	_part_root.add_child(mi)
	_part_root.transform = _arc_xf(_centre.x, _centre.y, lift, CLOSE_YAW)
	await get_tree().process_frame
	var r := maxf(aabb.size.length() * 0.5, 0.6)
	var d := r / tan(deg_to_rad(45.0) * 0.5) * 1.05
	var c := aabb.get_center() + Vector3(0.0, lift, 0.0)
	_place_camera({"eye": Vector3(0.0, -d * 0.9, c.y + d * 0.42), "target": Vector3(0.0, 0.0, c.y), "fov": 45.0})


# --- Palettes ----------------------------------------------------------------------------------------------

func _load_palettes(path: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var txt := FileAccess.get_file_as_string(path)
	var data: Variant = JSON.parse_string(txt)
	if not data is Dictionary or not (data as Dictionary).has("options"):
		_say("ERROR cannot read palette table %s" % path)
		return out
	for o: Variant in data["options"]:
		if o is Dictionary and (o as Dictionary).has("id"):
			out.append(o)
	_say("palette table %s: %d options" % [path, out.size()])
	return out


func _source_colour(key: String) -> Color:
	match key:
		"body": return EnemyMeshes.ARMOR_DARK
		"plate": return EnemyMeshes.ARMOR_PLATE
		"steel": return EnemyMeshes.STEEL
		"trim": return EnemyMeshes.TRIM_RED
		"optic": return EnemyMeshes.OPTIC_GLOW
		"vent": return EnemyMeshes.VENT_GLOW
	return Color.MAGENTA


## [[old, new], ...] for the keys this option sets.
func _pairs(o: Dictionary) -> Array:
	var pairs := []
	for k: String in KEYS:
		if o.has(k):
			pairs.append([_source_colour(k), Color.html(str(o[k]))])
	return pairs


## Every MeshInstance3D under the enemies: original mesh kept in meta "estyle_orig", remapped copy swapped in.
func _apply_palette(o: Dictionary) -> void:
	var id := str(o["id"])
	var pairs := _pairs(o) if id != "current" else []
	var n := 0
	var hits := 0
	var roots: Array[Node] = []
	for e in _squad.enemies:
		if is_instance_valid(e):
			roots.append(e)
	if _part_root != null:
		roots.append(_part_root)
	for e: Node in roots:
		for mi: MeshInstance3D in _mesh_instances(e):
			_tint_scanner(mi, o if id != "current" else {})
			if not mi.has_meta("estyle_orig"):
				if not mi.mesh is ArrayMesh:
					continue
				mi.set_meta("estyle_orig", mi.mesh)
			var orig: ArrayMesh = mi.get_meta("estyle_orig")
			if pairs.is_empty():
				mi.mesh = orig
				continue
			var key := "%s|%d" % [id, orig.get_rid().get_id()]
			if not _remap_cache.has(key):
				var res := _remap(orig, pairs)
				_remap_cache[key] = res[0]
				hits += int(res[1])
			mi.mesh = _remap_cache[key]
			n += 1
	_say("option %s: %d meshes recoloured (%d new vertex hits)" % [id, n, hits])
	if not _unmatched.is_empty():
		_say("unmatched vertex colours (kept): %s" % ", ".join(_unmatched.values().slice(0, 24)))
		_unmatched.clear()


## The drone's translucent scanner cone is a material, not vertex colours: tint a copy with the option's "scanner"
## colour, else its "vent" colour (alpha kept). {} restores the shared material.
func _tint_scanner(mi: MeshInstance3D, o: Dictionary) -> void:
	var base := EnemyMeshes.scanner_material()
	if mi.material_override != base and not mi.has_meta("estyle_scanner"):
		return
	mi.set_meta("estyle_scanner", true)
	var hex := str(o.get("scanner", o.get("vent", "")))
	if hex == "":
		mi.material_override = base
		return
	var key := "scanner|" + hex
	if not _remap_cache.has(key):
		var m := base.duplicate() as StandardMaterial3D
		var c := Color.html(hex)
		c.a = base.albedo_color.a
		m.albedo_color = c
		_remap_cache[key] = m
	mi.material_override = _remap_cache[key]


func _mesh_instances(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for c in n.get_children():
		if c is MeshInstance3D:
			out.append(c)
		out.append_array(_mesh_instances(c))
	return out


## A copy of `src` with each vertex colour that matches an old palette colour (allowing MeshKit's lighten/darken shade
## jitter) replaced by the new colour with the same jitter. Unmatched colours stay. Returns [mesh, matched count].
func _remap(src: ArrayMesh, pairs: Array) -> Array:
	var dst := ArrayMesh.new()
	var matched := 0
	for i in src.get_surface_count():
		var arrays := src.surface_get_arrays(i)
		var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
		var memo := {}
		for v in cols.size():
			var c := cols[v]
			var k := c.to_rgba32()
			if not memo.has(k):
				memo[k] = _remap_colour(c, pairs)
			var nc: Variant = memo[k]
			if nc != null:
				cols[v] = nc
				matched += 1
			elif not _unmatched.has(k):
				_unmatched[k] = "#" + c.to_html(false)
		if cols.size() > 0:
			arrays[Mesh.ARRAY_COLOR] = cols
		dst.add_surface_from_arrays(src.surface_get_primitive_type(i), arrays)
		dst.surface_set_material(i, src.surface_get_material(i))
		dst.surface_set_name(i, src.surface_get_name(i))
	return [dst, matched]


## The new colour for `c`, or null when no old colour matches.
func _remap_colour(c: Color, pairs: Array) -> Variant:
	var best: Variant = null
	var best_res := MATCH_TOL
	var cv := Vector3(c.r, c.g, c.b)
	for pr: Array in pairs:
		var old: Color = pr[0]
		var nw: Color = pr[1]
		var p := Vector3(old.r, old.g, old.b)
		# darkened: c = p * (1 - t)
		var td := clampf(1.0 - cv.dot(p) / maxf(p.dot(p), 1e-6), 0.0, 0.06)
		var rd := _maxabs(cv - p * (1.0 - td))
		# lightened: c = p + (1 - p) * t
		var w := Vector3.ONE - p
		var tl := clampf((cv - p).dot(w) / maxf(w.dot(w), 1e-6), 0.0, 0.06)
		var rl := _maxabs(cv - (p + w * tl))
		if rd <= rl and rd < best_res:
			best_res = rd
			best = Color(nw.r * (1.0 - td), nw.g * (1.0 - td), nw.b * (1.0 - td), c.a)
		elif rl < rd and rl < best_res:
			best_res = rl
			best = Color(nw.r + (1.0 - nw.r) * tl, nw.g + (1.0 - nw.g) * tl, nw.b + (1.0 - nw.b) * tl, c.a)
	return best


func _maxabs(v: Vector3) -> float:
	return maxf(absf(v.x), maxf(absf(v.y), absf(v.z)))


# --- Scene -------------------------------------------------------------------------------------------------

func _build_city(seed: int, lighting: String) -> void:
	_district = CityDistrict.new()
	_district.name = "District"
	add_child(_district)
	_district.build({"seed": seed, "walls": 1.0})
	_district.set_ceiling_visible(true)
	_district.set_backdrop_visible(true)
	if _district.rig != null:
		_district.rig.apply(lighting)
		_district.rig.set_quality(GraphicsQuality.HIGH)
	var plan := _district.plan
	var av := plan.avenue_x()
	# Cross street nearest the district's middle.
	var best_s := 0.0
	var best_d := INF
	var mid_s := plan.extent.get_center().y
	for r: Dictionary in plan.roads_s:
		if str(r.get("kind", "")) == "perimeter":
			continue
		var s := (float(r["a"]) + float(r["b"])) * 0.5
		if absf(s - mid_s) < best_d:
			best_d = absf(s - mid_s)
			best_s = s
	_centre = Vector2((av.x + av.y) * 0.5, best_s)
	_say("city seed %d checksum %s, intersection at x %.1f s %.1f" % [seed, plan.checksum(), _centre.x, _centre.y])


func _arc_xf(x: float, s: float, h: float, yaw: float) -> Transform3D:
	var ring := _district.ring
	var pos := ring.arc_to_world(x, s, h)
	var base_b := ring.basis_at_arc(s)
	return Transform3D(Basis(base_b.y, yaw) * base_b, pos)


func _spawn_layout(layout: String, units: PackedStringArray) -> void:
	_squad.clear_enemies()
	if _part_root != null:
		_part_root.queue_free()
		_part_root = null
	if _mech != null:
		_mech.queue_free()
		_mech = null
	await get_tree().process_frame
	var ring := _district.ring
	_mech = MechModel.new()
	_mech.name = "PlayerMech"
	_mech.scale = Vector3.ONE * MECH_SCALE
	add_child(_mech)
	_mech.configure("chicken", "strider", {})
	if layout == "play":
		_mech.transform = _arc_xf(_centre.x + PLAY_MECH.x, _centre.y + PLAY_MECH.y, 0.0, 0.0).scaled_local(Vector3.ONE * MECH_SCALE)
		for u: String in units:
			var at: Vector3 = PLAY_SPOTS.get(u, Vector3.ZERO)
			_spawn(u, "es_" + u, _centre.x + at.x, _centre.y + at.y, at.z, PI)
		_spawn_roof_turret()
	elif layout == "none":
		_mech.visible = false
		return
	else:
		# One row along the cross street, centred on the avenue: units, then the mech at the end for scale.
		var n := units.size() + 1
		for i in units.size():
			var x := _centre.x - (float(i) - float(n - 1) * 0.5) * LINEUP_SPACING   # -x: left to right on screen
			var h := 6.0 if units[i] == "drone" else 0.0
			_spawn(units[i], "es_" + units[i], x, _centre.y, h, LINEUP_YAW)
		var mx := _centre.x - (float(n - 1) * 0.5) * LINEUP_SPACING
		_mech.transform = _arc_xf(mx, _centre.y, 0.0, LINEUP_YAW).scaled_local(Vector3.ONE * MECH_SCALE)
	# A few idle world steps so legs / hover settle into their poses (idle AI: no alert, no fire, no telegraph).
	for i in 20:
		_world.advance(1.0 / 60.0)
		await get_tree().process_frame
	_say("layout %s: %d enemies" % [layout, _squad.enemies.size()])


func _spawn(type_id: String, id: String, x: float, s: float, h: float, yaw: float) -> EnemyBase:
	var e := EnemySpawner.make_enemy(type_id)
	e.configure(type_id, id, _world, _squad, _district.ring, 42)
	e.ai_mode = _arg("--ai", "idle")
	e.transform = _arc_xf(x, s, h, yaw)
	e.up = _district.ring.up_at(e.position)
	if not EnemySpawner.clear_of_buildings(_district.plan, Vector2(x, s), 2.0, h + 0.2):
		_say("warning: %s at x %.1f s %.1f overlaps a building" % [type_id, x, s])
	_squad.add_enemy(e)
	return e


## The extra turret on the roof nearest the intersection that the gameplay camera can see (same placement as the spawner).
func _spawn_roof_turret() -> void:
	var cands := EnemySpawner._rooftop_candidates(_district.plan, _centre.x)
	var best: Dictionary = {}
	var best_d := INF
	for c: Dictionary in cands:
		var ds := float(c["s"]) - _centre.y
		var dx := float(c["x"]) - _centre.x
		if ds < -2.0 or ds > 70.0 or absf(dx) > 60.0:
			continue
		var d := Vector2(dx, ds).length()
		if d < best_d:
			best_d = d
			best = c
	if best.is_empty():
		_say("warning: no roof in view for the roof turret (%d candidates)" % cands.size())
		return
	var ring := _district.ring
	var e := EnemySpawner.make_enemy("turret")
	e.configure("turret", "es_roof_turret", _world, _squad, ring, 42)
	e.ai_mode = _arg("--ai", "idle")
	var bc: Vector2 = best["b_center"]
	var off: Vector2 = best["t_off"]
	var bxf := Transform3D(CityGeo.frame_basis(ring, bc.y), ring.arc_to_world(bc.x, bc.y, CityPlan.CURB_H))
	var pos := bxf * Vector3(off.x, float(best["t_y1"]), off.y)
	var base_b := ring.basis_at_arc(float(best["s"]))
	e.transform = Transform3D(Basis(base_b.y, PI) * base_b, pos)
	e.up = ring.up_at(pos)
	_squad.add_enemy(e)
	_say("roof turret at x %.1f s %.1f h %.1f" % [best["x"], best["s"], best["h"]])


func _place_camera(cam: Dictionary) -> void:
	var ring := _district.ring
	if cam.has("banner"):
		if _banners.is_empty():
			_say("warning: no banners for camera banner_close")
			return
		var bm: MeshInstance3D = _banners[clampi(int(cam["banner"]), 0, _banners.size() - 1)]
		var bx := bm.global_transform
		var mid := bx.origin - bx.basis.y * float(bm.get_meta("h")) * 0.5
		var from := mid + bx.basis.z * float(cam["dist"]) + bx.basis.y * 0.5
		_cam.fov = float(cam["fov"])
		_cam.global_transform = Transform3D(Basis.looking_at(mid - from, bx.basis.y), from)
		_cam.make_current()
		return
	var eye: Vector3 = cam["eye"]
	var tgt: Vector3 = cam["target"]
	var p := ring.arc_to_world(_centre.x + eye.x, _centre.y + eye.y, eye.z)
	var q := ring.arc_to_world(_centre.x + tgt.x, _centre.y + tgt.y, tgt.z)
	_cam.fov = float(cam["fov"])
	_cam.global_transform = Transform3D(Basis.looking_at(q - p, ring.up_at(p)), p)
	_cam.make_current()


# --- Placeholder invader banners -----------------------------------------------------------------------------
# Tall cloth banners on facades around the intersection and one on a free-standing pole near the units: a folded
# three-panel field, a border stripe, a sigil (an eye inside a downward chevron, a bar above), an iron cross-bar.
# Colours per option: banner_field / banner_sigil / banner_trim, else derived from the unit palette
# (field = body darkened 45 %, sigil = trim, trim = steel), so "current" gets the old black and red.

const BANNER_W := 4.0           ## the concept's ~1.6:1 proportions
const BANNER_H := 6.4           ## to the swallowtail points
const EMBLEM_SCALE := 0.85      ## the Descent emblem, relative to its 4 m-banner layout
const BANNER_MAX := 4            ## facade banners
const BANNER_IRON := Color("2e2e33")
## Pole banner spots (arc offsets from the intersection, corner sidewalks), first clear one wins: far corners first, so
## the pole stands behind the units.
const POLE_SPOTS: Array[Vector2] = [Vector2(-13.5, 9.5), Vector2(13.5, 9.5), Vector2(-13.5, -9.5), Vector2(13.5, -9.5)]

var _banners: Array[MeshInstance3D] = []   ## facade + pole banners (cloth); meta "h" = banner height


func _hex_or(o: Dictionary, key: String, def: Color) -> Color:
	return Color.html(str(o[key])) if o.has(key) else def


func _unit_colour(o: Dictionary, key: String) -> Color:
	return _hex_or(o, key, _source_colour(key))


func _banner_colours(o: Dictionary) -> Array[Color]:
	var field := _hex_or(o, "banner_field", _unit_colour(o, "body").darkened(0.45))
	var sigil := _hex_or(o, "banner_sigil", _unit_colour(o, "trim"))
	var trim := _hex_or(o, "banner_trim", _unit_colour(o, "steel"))
	var sigil2 := _hex_or(o, "banner_sigil2", sigil.lerp(field, 0.4))
	return [field, sigil, trim, sigil2]


func _apply_banners(o: Dictionary) -> void:
	if _banners.is_empty():
		return
	var c := _banner_colours(o)
	for mi in _banners:
		mi.mesh = _banner_mesh(c[0], c[1], c[2], c[3], float(mi.get_meta("h")))


## Facade spots: points every 7 m along the faces of ground tiers (y0 <= 1.5 m, >= 7 m tall; banner 5-8 m) that open
## onto a road (nothing built 6 m out) and face every camera preset. Banners seen by every camera come first, then those
## seen by at least one; nearest the intersection first, 9 m apart.
func _place_banners() -> void:
	var plan := _district.plan
	var ring := _district.ring
	var dbg := _arg("--debug", "") == "1"
	var cands: Array[Dictionary] = []
	for bi in plan.buildings.size():
		var b: Dictionary = plan.buildings[bi]
		if bool(b.get("pillar", false)):
			continue
		var c: Vector2 = b["center"]
		if absf(c.x - _centre.x) > 70.0 or c.y - _centre.y < -60.0 or c.y - _centre.y > 90.0:
			continue
		for t: Dictionary in b.get("tiers", []):
			if not t.has("y0") or float(t["y0"]) > 1.5 or float(t["y1"]) < 7.0:
				continue
			var off: Vector2 = t["off"]
			var sz: Vector2 = t["size"]
			for side in 4:
				var n: Vector2 = CityPlan.SIDE_N[side]
				var along := Vector2(absf(n.y), absf(n.x))
				var span := along.x * sz.x + along.y * sz.y
				if span < BANNER_W + 2.0:
					continue
				var steps := maxi(int((span - BANNER_W - 2.0) / 7.0), 0)
				for i in steps + 1:
					var u := (float(i) - float(steps) * 0.5) * 7.0
					var face := c + off + Vector2(n.x * sz.x, n.y * sz.y) * 0.5 + along * u
					if not EnemySpawner.clear_of_buildings(plan, face + n * 6.0, 1.0, 4.0):
						continue
					var top := minf(float(t["y1"]) - 0.8, BANNER_H + 4.0)
					var cd := {"n": n, "face": face, "top": top, "h": clampf(top - 1.6, 4.8, BANNER_H), "seen": 0,
							"bi": bi, "style": str(b.get("style", ""))}
					var mid := ring.arc_to_world(face.x, face.y, top - float(cd["h"]) * 0.5)
					var facing := true
					for cam: Dictionary in CAMS.values():
						if cam.has("banner") or (cam["eye"] as Vector3) == (cam["target"] as Vector3):   # computed cameras
							continue
						var eye: Vector3 = cam["eye"]
						if (Vector2(_centre.x + eye.x, _centre.y + eye.y) - face).normalized().dot(n) < 0.25:
							facing = false
							break
						_place_camera(cam)
						if _cam.is_position_in_frustum(mid):
							cd["seen"] = int(cd["seen"]) + 1
					if facing and int(cd["seen"]) > 0:
						cands.append(cd)
					elif dbg:
						_say("  skip facade dx %.1f ds %.1f n %s (facing %s, seen %d)" % [face.x - _centre.x,
								face.y - _centre.y, str(n), str(facing), cd["seen"]])
			break
	cands.sort_custom(func(a: Dictionary, b2: Dictionary) -> bool:
		if int(a["seen"]) != int(b2["seen"]):
			return int(a["seen"]) > int(b2["seen"])
		return (a["face"] as Vector2).distance_to(_centre) < (b2["face"] as Vector2).distance_to(_centre))
	# Spread over facades: pass 0 = a building and a style not used yet, pass 1 = a new building, pass 2 = anything.
	var picked: Array[Dictionary] = []
	for pass_i in 3:
		for cd: Dictionary in cands:
			if picked.size() >= BANNER_MAX:
				break
			var ok := not picked.has(cd)
			for pk: Dictionary in picked:
				if (cd["face"] as Vector2).distance_to(pk["face"]) < 9.0:
					ok = false
				if pass_i <= 1 and int(pk["bi"]) == int(cd["bi"]):
					ok = false
				if pass_i == 0 and str(pk["style"]) == str(cd["style"]):
					ok = false
			if ok:
				picked.append(cd)
	for cd: Dictionary in picked:
		var face: Vector2 = cd["face"]
		var n: Vector2 = cd["n"]
		var at := face + n * 0.7
		# Building frame (CityGeo.frame_basis): X = arc +x, Z = arc +s, Y = up; the banner's +Z faces out along n.
		var z := Vector3(n.x, 0.0, n.y)
		var lb := Basis(Vector3.UP.cross(z), Vector3.UP, z)
		var pos := ring.arc_to_world(at.x, at.y, float(cd["top"]) + CityPlan.CURB_H)
		_add_banner(Transform3D(CityGeo.frame_basis(ring, at.y) * lb, pos), float(cd["h"]), true)
		_say("banner on facade at dx %.1f ds %.1f, top %.1f m, seen by %d cameras, building %d (%s)" % [at.x - _centre.x,
				at.y - _centre.y, cd["top"], cd["seen"], cd["bi"], cd["style"]])
	# Free-standing pole banner on the near corner, facing the cameras (-s).
	var p := _centre + POLE_SPOTS[0]
	for sp: Vector2 in POLE_SPOTS:
		if EnemySpawner.clear_of_buildings(plan, _centre + sp, 2.2, 0.5):
			p = _centre + sp
			break
	var pole_xf := _arc_xf(p.x, p.y, CityPlan.CURB_H, 0.0)
	var pole := MeshInstance3D.new()
	pole.name = "BannerPole"
	var k := MeshKit.new()
	k.box(Vector3(0.28, 11.2, 0.28), BANNER_IRON, Vector3(0.0, 5.6, 0.0))
	k.box(Vector3(0.7, 0.4, 0.7), BANNER_IRON, Vector3(0.0, 0.2, 0.0))
	k.box(Vector3(BANNER_W + 1.0, 0.16, 0.16), BANNER_IRON, Vector3(BANNER_W * 0.5 + 0.4, 10.7, 0.0))
	pole.mesh = k.commit(LowPolyMaterials.materials())
	pole.transform = pole_xf
	add_child(pole)
	_add_banner(pole_xf * Transform3D(Basis.IDENTITY, Vector3(BANNER_W * 0.5 + 0.45, 10.7, 0.12)), 5.6, false)
	_say("%d facade banners + 1 pole banner at dx %.1f ds %.1f (%d facade candidates)" % [picked.size(), p.x - _centre.x,
			p.y - _centre.y, cands.size()])


func _add_banner(xf: Transform3D, h: float, wall: bool) -> void:
	var mi := MeshInstance3D.new()
	mi.name = "Banner%d" % _banners.size()
	mi.set_meta("h", h)
	mi.transform = xf
	add_child(mi)
	_banners.append(mi)
	if wall:   # iron cross-bar with two wall brackets (the same for every option)
		var k := MeshKit.new()
		k.box(Vector3(BANNER_W + 0.4, 0.16, 0.16), BANNER_IRON, Vector3.ZERO)
		for sx: float in [-1.0, 1.0]:
			k.box(Vector3(0.12, 0.12, 0.75), BANNER_IRON, Vector3(sx * (BANNER_W * 0.5 - 0.1), 0.0, -0.38))
			k.box(Vector3(0.24, 0.24, 0.24), BANNER_IRON, Vector3(sx * (BANNER_W * 0.5 + 0.25), 0.0, 0.0))
		var bar := MeshInstance3D.new()
		bar.name = "Bar"
		bar.mesh = k.commit(LowPolyMaterials.materials())
		mi.add_child(bar)


## The cloth: origin at the top centre (the cross-bar), hanging down -Y, facing +Z. Three panels, the outer two folded
## back; a swallowtail notch cut up into the middle panel. Field on both sides; border stripe and emblem on the front.
## Emblem "Descent" (banner design 9, art/renders/banner_r1): a bold arrowhead pointing straight down with a field-coloured
## split, three trailing bars above it in the second tone. Cached per colours and height.
func _banner_mesh(field: Color, sigil: Color, trim: Color, sigil2: Color, h: float) -> ArrayMesh:
	var key := "banner|%s|%s|%s|%s|%.1f" % [field.to_html(), sigil.to_html(), trim.to_html(), sigil2.to_html(), h]
	if _remap_cache.has(key):
		return _remap_cache[key]
	var k := MeshKit.new()
	var hw := BANNER_W * 0.5
	var mw := hw * 0.62         # middle panel half width
	var fold := -0.22           # outer edges set back
	var notch := 1.4            # swallowtail: the cut rises this far into the middle panel
	var front := Vector3(0.0, -h * 0.5, -5.0)   # "away" point behind the cloth: faces point +Z
	var back := Vector3(0.0, -h * 0.5, 5.0)
	var e := 0.025
	var sides := [
		[Vector3(-hw, 0, fold), Vector3(-mw, 0, 0), Vector3(-mw, -h, 0), Vector3(-hw, -h, fold)],
		[Vector3(mw, 0, 0), Vector3(hw, 0, fold), Vector3(hw, -h, fold), Vector3(mw, -h, 0)],
	]
	for pn: Array in sides:
		k.quad(pn[0], pn[1], pn[2], pn[3], field, front)
		k.quad(pn[0], pn[1], pn[2], pn[3], field, back)
	# Middle panel as two halves (the notch makes it concave).
	for sx: float in [-1.0, 1.0]:
		var half := PackedVector3Array([Vector3(0, 0, 0), Vector3(sx * mw, 0, 0), Vector3(sx * mw, -h, 0), Vector3(0, -h + notch, 0)])
		k.poly(half, field, front)
		k.poly(half, field, back)
	# Border stripe: the top band, the outer edges, the side panels' bottoms and both edges of the notch.
	var bw := 0.16
	for sx: float in [-1.0, 1.0]:
		var o0 := Vector3(sx * hw, 0, fold + e)
		var m0 := Vector3(sx * mw, 0, e)
		k.quad(o0, m0, m0 + Vector3(0, -0.32, 0), o0 + Vector3(0, -0.32, 0), trim, front)
		var i0 := Vector3(sx * (hw - bw), 0, fold * (hw - bw - mw) / (hw - mw) + e)
		k.quad(o0, i0, i0 + Vector3(0, -h, 0), o0 + Vector3(0, -h, 0), trim, front)
		var b0 := Vector3(sx * hw, -h, fold + e)
		var b1 := Vector3(sx * mw, -h, e)
		k.quad(b0, b1, b1 + Vector3(0, bw, 0), b0 + Vector3(0, bw, 0), trim, front)
		var n1 := Vector3(0, -h + notch, e)
		k.quad(b1, n1, n1 + Vector3(0, bw * 1.3, 0), b1 + Vector3(0, bw * 1.1, 0), trim, front)
	k.quad(Vector3(-mw, 0, e), Vector3(mw, 0, e), Vector3(mw, -0.32, e), Vector3(-mw, -0.32, e), trim, front)
	# Emblem "Descent" as in the concept (art/renders/banner_r1/b9_descent_s4242.png): one broad arrowhead pointing
	# diagonally down-left, a thin field-coloured slit from its tip up its middle to its back edge, and three long parallel
	# bars trailing from inside its back toward the upper right (the middle one longest). Laid out in 2D on the cloth
	# (x right as seen from the front, y up), clipped at the folds and lifted onto each panel's plane.
	var d := Vector2(-0.68, -0.73).normalized()      # arrow direction: down-left, about 47 degrees
	var pv := Vector2(-d.y, d.x)                      # across the arrow
	var bk := Vector2(0.0, -h * 0.42)               # middle of the arrowhead's back edge (upper middle, as the concept)
	var a_len := 1.9                                  # back edge to tip
	var a_half := 1.2                                 # half the back edge: a fat head
	var tip_pt := bk + d * a_len
	# Bars first (under the arrowhead), overlapping only its back third; then the head; then the slit on top.
	var polys := []                                   # [points, colour, lift]
	var bar_w := 0.26
	for i in 3:
		var v := (float(i) - 1.0) * 0.42
		var s0 := a_len / 3.0                         # reaches a third of the way into the head
		var s1 := -(2.2 if i == 1 else 1.9)           # ends this far behind the back edge
		var c0 := bk + pv * v
		polys.append([[c0 + d * s0 + pv * bar_w * 0.5, c0 + d * s0 - pv * bar_w * 0.5, c0 + d * s1 - pv * bar_w * 0.5,
				c0 + d * s1 + pv * bar_w * 0.5], sigil2, e * 2.0])
	polys.append([[bk + pv * a_half, bk - pv * a_half, tip_pt], sigil, e * 3.0])
	polys.append([[bk + pv * 0.07, bk - pv * 0.07, bk + d * (a_len - 0.2)], field, e * 4.0])
	# Scale the whole emblem (EMBLEM_SCALE) about its bounding-box centre, then centre that box horizontally on the cloth.
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for pl: Array in polys:
		for q: Vector2 in pl[0]:
			lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
			hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
	var mid_box := (lo + hi) * 0.5
	var place := Vector2(0.0, mid_box.y)
	for pl: Array in polys:
		var pts := []
		for q: Vector2 in pl[0]:
			pts.append(place + (q - mid_box) * EMBLEM_SCALE)
		_emblem_poly(k, pts, pl[1], front, hw, mw, fold, pl[2])
	var m := k.commit(LowPolyMaterials.materials())
	_remap_cache[key] = m
	return m


## A flat convex 2D polygon on the folded cloth: split at the folds (x = +-mw) and each piece lifted onto its panel's
## plane, `lift` in front of the cloth.
func _emblem_poly(k: MeshKit, pts: Array, col: Color, away: Vector3, hw: float, mw: float, fold: float, lift: float) -> void:
	for band: Vector2 in [Vector2(-INF, -mw), Vector2(-mw, mw), Vector2(mw, INF)]:
		var piece := _clip_x(_clip_x(pts, band.x, true), band.y, false)
		if piece.size() < 3:
			continue
		var out := PackedVector3Array()
		for q: Vector2 in piece:
			var z := 0.0
			if absf(q.x) > mw:
				z = fold * (absf(q.x) - mw) / (hw - mw)
			out.append(Vector3(q.x, q.y, z + lift))
		k.poly(out, col, away)


## Sutherland-Hodgman against one vertical line: keep x >= x0 (keep_greater) or x <= x0.
func _clip_x(pts: Array, x0: float, keep_greater: bool) -> Array:
	if is_inf(x0):
		return pts
	var out := []
	for i in pts.size():
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[(i + 1) % pts.size()]
		var ina := (a.x >= x0) if keep_greater else (a.x <= x0)
		var inb := (b.x >= x0) if keep_greater else (b.x <= x0)
		if ina:
			out.append(a)
		if ina != inb:
			var t := (x0 - a.x) / (b.x - a.x)
			out.append(a.lerp(b, t))
	return out
