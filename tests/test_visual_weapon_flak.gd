extends TestCase
## VISUAL: the flak cannon on the weapon range (run with .\test_runner.ps1 -Visual), aimed beside the lab's airborne
## dummy so the proximity fuse bursts its shells alongside it. Look at test_logs/shots/:
##   weapon_flak.png        the lane from the side: a shell in flight and a burst beside the hovering dummy (at the
##                          catalog rate, 1.5 /s, a shell and the previous burst share a frame)
##   weapon_flak_burst.png  close on one air burst a few frames after the fuse fires (placeholder look: the explosive
##                          ImpactFx, no flak puff art yet)

const VISUAL := true

var sc: ShotCheck


func setup() -> void:
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_weapon_flak needs a renderer: run .\\test_runner.ps1 -Visual")
		finish()
		return
	var lab := (load("res://scenes/lab.tscn") as PackedScene).instantiate() as Lab
	add_child(lab)
	await frames(5)
	lab.pick("weapon_range")
	var r := lab.subject as WeaponRangeLab
	r.set_lab_option("weapon", "flak")
	r.set_lab_option("aim", WeaponRangeLab.AIR_NEAR_AIM)
	r.set_lab_option("fire", "hold")
	lab.set_view("three")
	lab.set_process(false)          # the lab re-places its camera every frame: stop that for these shots
	var d := r.air_dummy.global_position + Vector3(0, 1.9, 0)
	var s := r.rest_muzzle()
	var lane := Vector3(d.x - s.x, 0, d.z - s.z).normalized()
	var right := lane.cross(Vector3.UP).normalized()
	var dist := Vector3(d.x - s.x, 0, d.z - s.z).length()
	# 1. The lane from its right side: shells climbing toward the dummy, a burst beside it.
	var eye := s + lane * dist * 0.55 + right * 48.0 + Vector3(0, 12.0, 0)
	var look := s + lane * dist * 0.62 + Vector3(0, 12.0, 0) - right * 8.0
	lab.cam.global_transform = Transform3D(Basis.looking_at(look - eye, Vector3.UP), eye)
	var guard := 0
	while guard < 900:
		await frames(1)
		guard += 1
		if _fused_bursts(r, d) >= 1 and _flying(r) >= 1:
			break
	await frames(2)
	var view := Rect2(0.3, 0.05, 0.7, 0.9)
	var img := await sc.grab("weapon_flak")
	sc.not_blank(img, view, "flak shell and burst beside the airborne dummy")
	check(_flying(r) >= 1, "a shell in flight at the shot (%d)" % _flying(r))
	check(_fused_bursts(r, d) >= 1, "a fuse burst beside the airborne dummy at the shot")
	# 2. Close on one air burst, a few frames after the fuse fires.
	eye = d + right * 22.0 - lane * 6.0 + Vector3(0, 3.0, 0)
	look = d - right * 4.0
	lab.cam.global_transform = Transform3D(Basis.looking_at(look - eye, Vector3.UP), eye)
	var before := _impact_ids(r)
	guard = 0
	var fresh := false
	while guard < 900 and not fresh:
		await frames(1)
		guard += 1
		for e in r.world.effects:
			if e is ImpactFx and not e.get_instance_id() in before and (e as ImpactFx).point.distance_to(d) < 9.0:
				fresh = true
		if not fresh:
			before = _impact_ids(r)
	await frames(3)
	var img2 := await sc.grab("weapon_flak_burst")
	sc.not_blank(img2, view, "a flak air burst up close")
	check(fresh, "a fresh burst beside the dummy for the close shot")
	lab.queue_free()
	finish()


func _flying(r: WeaponRangeLab) -> int:
	var n := 0
	for e in r.world.effects:
		if e is FlakShell and (e as FlakShell).end_time < 0.0:
			n += 1
	return n


func _fused_bursts(r: WeaponRangeLab, d: Vector3) -> int:
	var n := 0
	for e in r.world.effects:
		if e is ImpactFx and (e as ImpactFx).point.distance_to(d) < 9.0:
			n += 1
	return n


func _impact_ids(r: WeaponRangeLab) -> Array:
	var out := []
	for e in r.world.effects:
		if e is ImpactFx:
			out.append(e.get_instance_id())
	return out
