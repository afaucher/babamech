extends TestCase
## R2.7: WorldAimMarkers hint effective range. A selected weapon's tracking rings turn RANGE_ORANGE while the aim point
## is out of that weapon's range (WeaponRack slots() `in_range`); the outer aim ring turns RANGE_ORANGE only when weapons
## are selected and every one is out of range. AMBER stays "line of sight blocked". A hint only: the rack still fires.

const DT := 1.0 / 60.0

var root3d: Node3D
var cam: Camera3D
var world: CombatWorld
var mech: MechController
var model: MechModel
var rack: WeaponRack
var wam: WorldAimMarkers
var n_laser := 0
var n_ac := 0


func setup() -> void:
	await _build()
	await _real_rack_cases()
	await _fake_rack_cases()
	await _fires_out_of_range()
	_teardown()
	await frames(1)
	finish()


func _build() -> void:
	root3d = Node3D.new()
	add_child(root3d)
	cam = Camera3D.new()
	root3d.add_child(cam)
	cam.position = Vector3(0, 6, 10)
	cam.current = true
	world = CombatWorld.new()
	world.mission_seed = 77
	world.use_physics = false
	add_child(world)
	mech = MechController.new()
	add_child(mech)
	model = MechModel.new()
	add_child(model)
	model.configure("chicken", "strider", {"side_l": "laser", "side_r": "autocannon", "shoulder_l": "", "shoulder_r": "", "back": ""})
	rack = WeaponRack.new()
	rack.auto_step = false
	rack.manual_aim = true
	add_child(rack)
	rack.bind(world, mech, model, null, "player1", 1)
	rack.aim_point = Vector3(0, 3, -20)
	wam = WorldAimMarkers.new()
	root3d.add_child(wam)
	wam.rack = rack
	wam.camera = cam
	await frames(2)
	n_laser = rack.hardpoints.find("side_l") + 1
	n_ac = rack.hardpoints.find("side_r") + 1
	check(n_laser > 0 and n_ac > 0, "rack has the laser and the autocannon")


func _range_of(n: int) -> float:
	return float((rack.mounts[n - 1] as WeaponMount).stats.get("range", 0.0))


## Aim straight ahead of the laser's muzzle at `d` m from it (along -Z, the mech's front).
func _aim_at(d: float) -> void:
	var m: Vector3 = rack.muzzle(n_laser)
	rack.aim_point = Vector3(m.x, m.y, m.z - d)
	wam.sync()


func _select(laser: bool, ac: bool) -> void:
	for j in rack.slot_count():
		rack.set_enabled(j + 1, false)
	rack.set_enabled(n_laser, laser)
	rack.set_enabled(n_ac, ac)


func _col(n: int) -> Variant:
	return wam.ring_colors()[n - 1]


func _real_rack_cases() -> void:
	var lr := _range_of(n_laser)
	var ar := _range_of(n_ac)
	check(lr > 0.0 and ar > lr + 20.0, "laser range %.0f is shorter than the autocannon's %.0f (test premise)" % [lr, ar])
	# Laser alone, inside range: cyan rings, cyan aim ring.
	_select(true, false)
	_aim_at(lr * 0.5)
	check(bool(rack.slots()[n_laser - 1]["in_range"]), "laser in range at half its range")
	eq(_col(n_laser), WorldAimMarkers.CYAN, "laser in range: cyan rings")
	eq(wam.aim_ring_color(), WorldAimMarkers.CYAN, "laser in range: cyan aim ring")
	check(not wam.aim_out_of_range(), "laser in range: aim not out of range")
	eq(_col(n_ac), null, "deselected autocannon draws no rings")
	# Laser alone, beyond range: orange rings and orange aim ring.
	_aim_at(lr + 15.0)
	check(not bool(rack.slots()[n_laser - 1]["in_range"]), "laser out of range past its range")
	eq(_col(n_laser), WorldAimMarkers.RANGE_ORANGE, "laser out of range: orange rings")
	eq(wam.aim_ring_color(), WorldAimMarkers.RANGE_ORANGE, "laser out of range: orange aim ring")
	check(wam.aim_out_of_range(), "laser out of range: aim_out_of_range")
	check(WorldAimMarkers.RANGE_ORANGE != WorldAimMarkers.AMBER, "range orange differs from blocked amber")
	# Laser + autocannon, aim between the two ranges: laser orange, autocannon cyan, aim ring cyan.
	_select(true, true)
	_aim_at((lr + ar) * 0.5)
	eq(_col(n_laser), WorldAimMarkers.RANGE_ORANGE, "between ranges: laser rings orange")
	eq(_col(n_ac), WorldAimMarkers.CYAN, "between ranges: autocannon rings cyan")
	eq(wam.aim_ring_color(), WorldAimMarkers.CYAN, "between ranges: aim ring stays cyan (one weapon reaches)")
	check(not wam.aim_out_of_range(), "between ranges: not all out of range")
	# Both beyond: everything orange.
	_aim_at(ar + 30.0)
	eq(_col(n_ac), WorldAimMarkers.RANGE_ORANGE, "beyond both: autocannon rings orange")
	eq(wam.aim_ring_color(), WorldAimMarkers.RANGE_ORANGE, "beyond both: aim ring orange")
	# Nothing selected: as before (cyan aim ring, no rings), even far out.
	_select(false, false)
	_aim_at(ar + 30.0)
	eq(_col(n_laser), null, "nothing selected: no laser rings")
	eq(_col(n_ac), null, "nothing selected: no autocannon rings")
	eq(wam.aim_ring_color(), WorldAimMarkers.CYAN, "nothing selected: aim ring cyan as before")
	check(not wam.aim_out_of_range(), "nothing selected: aim not out of range")


## Stand-in rack for the cases a bare rack can't produce: blocked, designating, shutdown.
class FakeRack extends WeaponRack:
	var rows: Array[Dictionary] = []

	func slots() -> Array[Dictionary]:
		return rows

	func aim() -> Vector3:
		return Vector3(0, 2, -40)


static func _row(slot: int, in_range: bool, blocked: bool = false, designating: bool = false, hold: String = "") -> Dictionary:
	return {"slot": slot, "hardpoint": "side_l", "weapon": "laser", "enabled": true, "built": true, "ready": 1.0,
		"blocked": blocked, "in_range": in_range, "muzzle": Vector3(-1, 3, 0), "equipment": false, "designating": designating,
		"hold": hold, "usable": true}


func _fake_rack_cases() -> void:
	var fr := FakeRack.new()
	wam.rack = fr
	# Blocked keeps AMBER (and wins over out of range); it still counts as out of range for the aim ring.
	fr.rows = [_row(1, false, true)]
	wam.sync()
	eq(_col(1), WorldAimMarkers.AMBER, "blocked + out of range: rings stay blocked amber")
	eq(wam.aim_ring_color(), WorldAimMarkers.RANGE_ORANGE, "blocked + out of range only weapon: aim ring orange")
	# Designating and in range: green as before; designating and all out: orange.
	fr.rows = [_row(1, true, false, true)]
	wam.sync()
	eq(wam.aim_ring_color(), WorldAimMarkers.GREEN, "designating, in range: aim ring green as before")
	fr.rows = [_row(1, false, false, true)]
	wam.sync()
	eq(wam.aim_ring_color(), WorldAimMarkers.RANGE_ORANGE, "designating, out of range: aim ring orange")
	# Heat shutdown: no rings, aim ring as before (in_range is false for every slot then).
	fr.rows = [_row(1, false, false, false, "SHUTDOWN")]
	wam.sync()
	eq(_col(1), null, "shutdown: no rings")
	eq(wam.aim_ring_color(), WorldAimMarkers.CYAN, "shutdown: aim ring cyan as before")
	# Equipment never counts.
	var drone := _row(2, false)
	drone["equipment"] = true
	drone["weapon"] = "repair_drone"
	fr.rows = [drone]
	wam.sync()
	eq(wam.aim_ring_color(), WorldAimMarkers.CYAN, "equipment only: aim ring cyan as before")
	wam.rack = rack
	fr.free()


func _fires_out_of_range() -> void:
	_select(true, false)
	_aim_at(_range_of(n_laser) + 40.0)
	check(wam.aim_out_of_range(), "fire case: laser out of range")
	var shots := [0]
	rack.fired.connect(func(n: int) -> void:
		if n == n_laser:
			shots[0] += 1)
	rack.set_trigger(true)
	for _i in 90:
		rack.step(DT)
		world.advance(DT)
	rack.set_trigger(false)
	check(shots[0] >= 1, "the rack still fires the laser out of range (%d shots)" % shots[0])


func _teardown() -> void:
	rack.queue_free()
	model.queue_free()
	mech.queue_free()
	world.queue_free()
	root3d.queue_free()
