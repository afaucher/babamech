extends TestCase
## VISUAL: the Back Mortar really draws (run with .\test_runner.ps1 -Visual -TestName test_visual_weapon_mortar).
## Two shots: a shell high on its arc over the range with the ground ring closing on its landing point
## (test_logs/shots/weapon_mortar_flight.png), and the explosion: fireball, column, ground ring, shards
## (weapon_mortar_impact.png).

const VISUAL := true

var sc: ShotCheck


func setup() -> void:
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_weapon_mortar needs a renderer: run .\test_runner.ps1 -Visual")
		finish()
		return
	var lab := (load("res://scenes/lab.tscn") as PackedScene).instantiate() as Lab
	add_child(lab)
	await frames(5)
	lab.pick("weapon_range")
	var r := lab.subject as WeaponRangeLab
	r.set_lab_option("weapon", "mortar")
	r.set_lab_option("designator", "off")
	# The dummy nearest 60 m out (found by distance: the range layout may change).
	var best: TargetDummy = null
	for d in r.dummies:
		var dist := MortarShell.horizontal(r.muzzle(), d.global_position)
		if dist > 35.0 and (best == null or absf(dist - 60.0) < absf(MortarShell.horizontal(r.muzzle(), best.global_position) - 60.0)):
			best = d
	if not check(best != null, "a dummy in mortar range"):
		lab.queue_free()
		finish()
		return
	r.set_lab_option("aim", best.name)
	r.set_lab_option("fire", "hold")
	# Shot 1: from the side, high, while the shell is on its way down.
	lab.set_view("side")
	lab._pitch = 0.32
	lab._dist = 52.0
	var shell := await _wait_for(r, func() -> bool:
		var s := _shell(r)
		return s != null and s.elapsed > s.flight_time * 0.6)
	lab.toggle_pause()
	await frames(3)
	var view := Rect2(0.3, 0.05, 0.7, 0.9)
	var img := await sc.grab("weapon_mortar_flight")
	sc.not_blank(img, view, "mortar shell in flight")
	if check(shell, "a shell is high on its arc at the shot"):
		var s := _shell(r)
		check(s.telegraph_visible(), "its ground ring is up")
	lab.toggle_pause()
	# Shot 2: the camera orbits the lab focus, so put it on the far side of the focus from the landing point, looking
	# through the focus at the burst; taken once the flash is gone (fireball chunks, column, ring, shards).
	var land := best.global_position
	var focus := r.lab_focus()
	lab._yaw = atan2(focus.x - land.x, -(focus.z - land.z))
	lab._pitch = 0.02
	lab._dist = 4.0
	var boom := await _wait_for(r, func() -> bool:
		var fx := _impact(r)
		return fx != null and fx.age > 0.3)
	lab.toggle_pause()
	await frames(3)
	var img2 := await sc.grab("weapon_mortar_impact")
	sc.not_blank(img2, view, "mortar explosion")
	check(boom, "an explosion is showing at the shot")
	lab.toggle_pause()
	lab.queue_free()
	finish()


func _shell(r: WeaponRangeLab) -> MortarShell:
	for e in r.world.effects:
		if e is MortarShell and (e as MortarShell).end_time < 0.0:
			return e
	return null


func _impact(r: WeaponRangeLab) -> ImpactFx:
	for e in r.world.effects:
		if e is ImpactFx and (e as ImpactFx).column > 0.0:
			return e
	return null


func _wait_for(r: WeaponRangeLab, cond: Callable, max_frames: int = 900) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await frames(1)
	return false
