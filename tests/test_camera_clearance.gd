extends TestCase
## The chase camera keeps the own mech's weapons off the crosshair (playtest: a right-shoulder missile pod covered it).
## Pure geometry (CameraClearance on the real meshes of a MechModel at game scale), fixed sample steps, no wall clock:
##  - every item that fits the Strider's shoulder_r and side_r (rest of the default loadout), the heaviest full loadouts
##    and the Bulwark's side_r items (each chassis on its own framing: ChaseCamera.framing_config): every grid cell at its own stored length clears its samples (the fit's promise),
##    and the fitted offset clears every sample (pitch_min..pitch_max, body yaw lag +-45 deg,
##    normal and zoomed) by MARGIN for the items, and the hull no worse than at the default offsets;
##  - a denser resample (pitch 0.025 rad, yaw lag 7.5 deg, zoom 0 / 0.5 / 1) of the worst loadouts stays clear within
##    DENSE_TOL (between-sample safety of the dilated, interpolated grid);
##  - light loadouts (bare, left side only) keep the default offsets exactly ((0, 0) everywhere);
##  - ChaseCamera refits when the loadout changes (model.configure), blends to it, and goes back to (0, 0);
##  - prints the table: loadout -> extra shoulder / height (at rest: pitch -0.18, no yaw lag; and the grid's max) with
##    the BEFORE clearance (default offsets: the failure the user saw) and AFTER, plus the parallax added at 10 / 30 m.

const MARGIN := CameraClearance.MARGIN
const DENSE_TOL := 0.012
const REST_PITCH := -0.18

var _cfg: Dictionary
var _scale := 2.0


func setup() -> void:
	timeout_sec = 400.0
	var cam := ChaseCamera.new()
	_cfg = CameraClearance.config_of(cam)
	cam.free()
	var rig := MechRig.new()
	_scale = rig.mech_scale
	rig.free()
	print("  margin %.3f of screen height; samples: pitch %.2f..%.2f step %.2f, yaw lag %s, zoom %s" % [MARGIN,
		_cfg["pitch_min"], _cfg["pitch_max"], CameraClearance.PITCH_STEP, str(CameraClearance.YAW_LAG), str(CameraClearance.ZOOMS)])
	print("  %-9s %-42s %-22s %6s %6s %6s %6s  %-22s" % ["chassis", "loadout", "BEFORE items (at)", "sh@rest", "h@rest",
		"sh max", "h max", "AFTER items (at)"])
	var dflt := MechCatalog.sanitize_loadout("strider", {})
	var rows: Array = []
	# Light loadouts: nothing near the crosshair, the default offsets exactly.
	rows.append(["strider", _with(dflt, {"side_l": "", "side_r": "", "shoulder_l": "", "shoulder_r": "", "back": ""}), "light"])
	rows.append(["strider", _with(dflt, {"side_r": "", "shoulder_r": "", "back": ""}), "light"])
	rows.append(["strider", dflt, ""])
	for w: String in MechCatalog.items_for(_hp("strider", "shoulder_r")):
		rows.append(["strider", _with(dflt, {"shoulder_r": w}), "dense" if w in ["missiles", "railgun"] else ""])
	for w: String in MechCatalog.items_for(_hp("strider", "side_r")):
		if w != dflt["side_r"]:
			rows.append(["strider", _with(dflt, {"side_r": w}), "dense" if w == "flak" else ""])
	rows.append(["strider", {"side_l": "flak", "side_r": "flak", "shoulder_l": "missiles", "shoulder_r": "railgun", "back": "mortar"}, "dense"])
	rows.append(["strider", {"side_l": "autocannon", "side_r": "autocannon", "shoulder_l": "railgun", "shoulder_r": "missiles", "back": "repair_drone"}, ""])
	var bdflt := MechCatalog.sanitize_loadout("bulwark", {})
	rows.append(["bulwark", _with(bdflt, {"side_l": "", "side_r": "", "back_l": "", "back_r": ""}), ""])
	rows.append(["bulwark", bdflt, ""])
	for w: String in MechCatalog.items_for(_hp("bulwark", "side_r")):
		if w != bdflt["side_r"]:
			rows.append(["bulwark", _with(bdflt, {"side_r": w}), ""])
	var parallax_lo: Dictionary = _with(dflt, {"shoulder_r": "missiles"})
	for row: Array in rows:
		_row(str(row[0]), row[1], str(row[2]))
	_cfg = CameraClearance.config_of(ChaseCamera.framing_config("strider"))
	_parallax(parallax_lo)
	await _camera_refits()
	finish()


func _hp(chassis: String, id: String) -> Dictionary:
	for hp: Dictionary in MechCatalog.chassis(chassis)["hardpoints"]:
		if str(hp["id"]) == id:
			return hp
	return {}


static func _with(base: Dictionary, over: Dictionary) -> Dictionary:
	var out := base.duplicate()
	out.merge(over, true)
	return out


func _model(chassis: String, lo: Dictionary) -> MechModel:
	var m := MechModel.new()
	m.configure("chicken", chassis, lo)
	m.scale = Vector3.ONE * _scale
	add_child(m)
	return m


func _row(chassis: String, lo: Dictionary, mode: String) -> void:
	_cfg = CameraClearance.config_of(ChaseCamera.framing_config(chassis))   # the chassis' own framing (ChaseCamera)
	var m := _model(chassis, lo)
	var sil := CameraClearance.capture(m, m.global_transform.orthonormalized())
	var f := CameraClearance.fit(sil, _cfg)
	var smp := CameraClearance.samples(_cfg)
	var before := CameraClearance.measure(sil, _cfg, Vector2.ZERO, smp)
	var after := CameraClearance.measure(sil, _cfg, f, smp)
	var rest := CameraClearance.extra_at(f, REST_PITCH, 0.0)
	var mx := Vector2.ZERO
	for p in f["pitches"]:
		for y in f["yaws"]:
			var e := CameraClearance.extra_at(f, p, y)
			mx = Vector2(maxf(mx.x, e.x), maxf(mx.y, e.y))
	var name := _short(lo)
	print("  %-9s %-42s %.3f %-16s %6.2f %6.2f %6.2f %6.2f  %.3f %s" % [chassis, name, before["items"], _at(before["items_at"]),
		rest.x, rest.y, mx.x, mx.y, after["items"], _at(after["items_at"])])
	check(bool(f["solved"]), "%s %s: the fit clears every sample within %.1f m" % [chassis, name, CameraClearance.MAX_EXTRA])
	# The fit's own promise, cell by cell: each grid cell at its stored length (dir * len, no interpolation) clears both
	# zoom samples, the items by the full MARGIN and the hull no lower than at the default offsets (minus HULL_SLACK).
	# Guards a fit step (dilation, rounding) that moves a cell after it was checked.
	var ps: PackedFloat32Array = f["pitches"]
	var ys: PackedFloat32Array = f["yaws"]
	var cell_fail := 0
	var cell_worst := INF
	var cell_at := []
	for i in ps.size():
		for j in ys.size():
			var x: Vector2 = (f["dir"] as Vector2) * f["len"][i * ys.size() + j]
			for z: float in CameraClearance.ZOOMS:
				var h0 := CameraClearance.pose_clearance(sil, CameraClearance.pose(_cfg, ps[i], ys[j], z, Vector2.ZERO), MARGIN).x
				var c := CameraClearance.pose_clearance(sil, CameraClearance.pose(_cfg, ps[i], ys[j], z, x), MARGIN)
				if c.y < MARGIN or c.x < h0 - CameraClearance.HULL_SLACK:
					cell_fail += 1
				if c.y < cell_worst:
					cell_worst = c.y
					cell_at = [ps[i], ys[j], z]
	check(cell_fail == 0, "%s %s: every grid cell clears at its own length (%d failing, worst items %.4f at %s)" % [chassis, name,
		cell_fail, cell_worst, _at(cell_at)])
	check(float(after["items"]) >= MARGIN - 0.0005, "%s %s: items clear the crosshair by %.3f (got %.3f at %s)" % [chassis, name,
		MARGIN, after["items"], _at(after["items_at"])])
	# The hull never closer than at the default offsets (per sample, up to the margin).
	var worst_h := INF
	for s: Array in smp:
		var x := CameraClearance.extra_at(f, float(s[0]), float(s[1]))
		var h0 := CameraClearance.pose_clearance(sil, CameraClearance.pose(_cfg, s[0], s[1], s[2], Vector2.ZERO), MARGIN).x
		var h1 := CameraClearance.pose_clearance(sil, CameraClearance.pose(_cfg, s[0], s[1], s[2], x), MARGIN).x
		worst_h = minf(worst_h, h1 - h0)
	check(worst_h >= -CameraClearance.HULL_SLACK - 0.0005, "%s %s: the hull comes no closer to the crosshair than today (worst %.4f)" % [chassis, name, worst_h])
	if mode == "light":
		var all_zero := true
		for v in f["len"]:
			all_zero = all_zero and v == 0.0
		check(all_zero and rest == Vector2.ZERO and mx == Vector2.ZERO, "%s %s (light): the default offsets exactly" % [chassis, name])
	if mode == "dense":
		var dense: Array = []
		var p := float(_cfg["pitch_min"])
		while p <= float(_cfg["pitch_max"]) + 0.0001:
			for yi in range(-6, 7):
				for z: float in [0.0, 0.5, 1.0]:
					dense.append([p, yi * 7.5, z])
			p += 0.025
		var d := CameraClearance.measure(sil, _cfg, f, dense)
		print("            dense resample (%d poses): items %.3f at %s" % [dense.size(), d["items"], _at(d["items_at"])])
		check(float(d["items"]) >= MARGIN - DENSE_TOL, "%s %s: clear between samples too (%.3f at %s)" % [chassis, name, d["items"], _at(d["items_at"])])
	m.queue_free()


static func _short(lo: Dictionary) -> String:
	var parts: Array[String] = []
	for k: String in lo:
		parts.append("%s=%s" % [k.replace("shoulder", "sh").replace("side", "sd"), str(lo[k]) if str(lo[k]) != "" else "-"])
	return " ".join(parts)


static func _at(at: Array) -> String:
	if at.is_empty():
		return "(none)"
	return "(p%.2f y%+.0f z%.0f)" % [at[0], at[1], at[2]]


## Parallax: the weapons converge on aim_point(), so a shot lands on the crosshair's surface wherever the eye is; what a
## wider shoulder changes is the angle between the view ray and each shot (an object standing just in front of the aimed
## surface, off the shot line, is what a shot can then "miss"). For the missile-pod loadout at rest pitch: per weapon, the
## lateral gap between the shot path and the view ray 2 m short of an aim point 10 / 30 m ahead, before and after.
func _parallax(lo: Dictionary) -> void:
	var m := _model("strider", lo)
	var f := CameraClearance.fit(CameraClearance.capture(m, m.global_transform.orthonormalized()), _cfg)
	var worst_added := {10.0: 0.0, 30.0: 0.0}
	for dist: float in [10.0, 30.0]:
		var line := "  parallax at %2.0f m (gap shot path / view ray 2 m short of the aim point, before -> after):" % dist
		for hp: Dictionary in MechCatalog.chassis("strider")["hardpoints"]:
			var id := str(hp["id"])
			var w := str(lo.get(id, ""))
			if w == "" or MechCatalog.is_equipment(w) or str(MechCatalog.weapon(w).get("kind", "")) == "arc":
				continue
			var node := m.find_child("HP_" + id, true, false) as Node3D
			var muzzle := node.global_transform * Vector3(0, 0, -float(MechCatalog.weapon(w)["muzzle"]))
			var gaps: Array[float] = []
			for x: Vector2 in [Vector2.ZERO, CameraClearance.extra_at(f, REST_PITCH, 0.0)]:
				var cam := CameraClearance.pose(_cfg, REST_PITCH, 0.0, 0.0, x)
				var o: Vector3 = cam["o"]
				var v: Vector3 = cam["view"]
				# Aim point: on the view ray, `dist` m ahead of the mech (along its facing, -Z).
				var t := (dist - (-o.z)) / (-v.z)
				var aim := o + v * t
				var shot := (aim - muzzle).normalized()
				var probe := aim - shot * 2.0
				var rel := probe - o
				gaps.append((rel - v * rel.dot(v)).length())
			line += " %s %.2f->%.2f m" % [id, gaps[0], gaps[1]]
			worst_added[dist] = maxf(worst_added[dist], gaps[1] - gaps[0])
		print(line)
	print("  parallax: worst added gap %.2f m at 10 m, %.2f m at 30 m" % [worst_added[10.0], worst_added[30.0]])
	m.queue_free()


## The real camera on a real mech: light loadout -> (0, 0); a missile pod on shoulder_r -> a fit lands (worker thread),
## the offset blends in; back to light -> (0, 0) again (cached).
func _camera_refits() -> void:
	var floor := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 1, 200)
	shape.shape = box
	shape.position = Vector3(0, -0.5, 0)
	floor.add_child(shape)
	add_child(floor)
	var light := {"side_l": "laser", "side_r": "", "shoulder_l": "rockets", "shoulder_r": "", "back": ""}
	var mech := MechSpawn.make("chicken", "strider", light)
	add_child(mech)
	var cam := ChaseCamera.new()
	cam.target = mech
	add_child(cam)
	cam.current = true
	await frames(5)
	for i in 6000:   # frames run unthrottled headless: the worker needs wall time, not a frame count
		if not cam.fit_pending() and not cam.clear_fit.is_empty():
			break
		await frames(1)
	check(not cam.clear_fit.is_empty(), "the camera fitted the light loadout")
	await frames(3)
	eq(cam.fit_extra, Vector2.ZERO, "light loadout: the camera keeps its default offsets exactly")
	var model := MechSpawn.rig_of(mech).model
	var heavy := _with(light, {"shoulder_r": "missiles"})
	model.configure("chicken", "strider", heavy)
	var landed := false
	for i in 6000:   # signature check (fit_check) + the worker
		await frames(1)
		if not cam.fit_pending() and float(cam.clear_fit.get("max", 0.0)) > 0.0:
			landed = true
			break
	check(landed, "a loadout change (missile pod on shoulder_r) starts a new fit")
	var x0 := cam.fit_extra
	await frames(90)   # blend (fit_blend_rate 2.5/s: 0.4 s)
	var want := CameraClearance.extra_at(cam.clear_fit, cam.pitch, rad_to_deg(cam.yaw_error()))
	check(want.x > 0.5 or want.y > 0.5, "the missile pod needs a real offset at rest (%s)" % str(want))
	check(cam.fit_extra.distance_to(want) < 0.01, "the camera blended to the new offset (%s, want %s; %s right after the fit)" % [str(cam.fit_extra), str(want), str(x0)])
	check(x0.distance_to(want) > 0.05, "it blends in rather than jumping (%s right after the fit)" % str(x0))
	# Live clearance through the real camera transform: nothing of the mech near the crosshair.
	var sil := CameraClearance.capture(model, cam.mech_frame())
	var inv := cam.mech_frame().affine_inverse()
	var b := inv.basis * cam.global_basis
	var live := {"o": inv * cam.global_position, "view": -b.z, "right": b.x, "up": b.y, "tan": tan(deg_to_rad(cam.fov) * 0.5),
		"pivot": inv * cam.global_position - b.z * cam.distance}
	var c := CameraClearance.pose_clearance(sil, live)
	check(c.y >= MARGIN - 0.005, "through the live camera the pod clears the crosshair (%.3f)" % c.y)
	model.configure("chicken", "strider", light)
	for i in 120:
		await frames(1)
	eq(cam.fit_extra, Vector2.ZERO, "back to the light loadout: the default offsets again")
	cam.queue_free()
	mech.queue_free()
	floor.queue_free()
	await frames(2)
