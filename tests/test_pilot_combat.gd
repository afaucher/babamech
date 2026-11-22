extends TestCase
## PilotCombatLink (scripts/pilot/pilot_combat_link.gd): combat state reaches the pilot head, cosmetically. Real classes,
## no physics, no rig (the test feeds the head the way MechRig does, with an empty movement state): heat -> strained /
## overheated, shutdown -> dazed, reboot -> revived; a hit from the left flinches away then looks left; a big hit hurts;
## low hull HP -> afraid; disabled -> dazed (no tint), repaired -> revived; firing -> focused + looking at the aim point, and
## the look clears after; a kill credited to this player smirks; a model rebuild mid-run picks up at once; unbind and
## freeing the sources first leave nothing connected and raise no errors.

const DT := 1.0 / 60.0

var model: MechModel
var mech: MechController
var world: CombatWorld
var target: PlayerTarget
var rack: WeaponRack
var link: PilotCombatLink
var enemy: TargetDummy


func setup() -> void:
	timeout_sec = 60.0
	await _make()
	var h := link.pilot()
	if not check(h != null, "the link finds the model's pilot head"):
		finish()
		return
	_heat_and_shutdown()
	_hits()
	_fear_and_disabled()
	_firing()
	_kill()
	await _rebuild()
	await _unbind_and_free()
	finish()


func _make() -> void:
	model = MechModel.new()
	model.configure("chicken", "strider", {"side_l": "laser"})
	add_child(model)
	mech = MechController.new()          # not in the tree: its state is set by hand
	world = CombatWorld.new()
	world.use_physics = false
	add_child(world)
	target = PlayerTarget.new()
	add_child(target)
	target.bind(world, null, model, "player1", 1)
	target.auto_respawn_delay = -1.0
	world.register(target)
	enemy = TargetDummy.new()
	enemy.name = "enemy1"
	enemy.target_id = "enemy1"
	enemy.position = Vector3(-40.0, 0.0, 0.0)  # on the mech's left (the mech faces -Z)
	add_child(enemy)
	world.register(enemy)
	rack = WeaponRack.new()
	rack.auto_step = false
	rack.manual_aim = true
	rack.shooter = "player1"
	add_child(rack)
	link = PilotCombatLink.new()
	add_child(link)
	link.set_physics_process(false)      # stepped by hand below
	link.bind(model, mech, rack, target, world)
	await frames(1)
	if model.pilot != null:
		model.pilot.idle_enabled = false


## n physics steps: the link, then the head's feed (as MechRig does it).
func _step(n: int) -> void:
	for i in n:
		link._physics_process(DT)
		var h := link.pilot()
		if h != null:
			h.feed(DT, {})


func _yaw() -> float:
	return link.pilot().neck.total().y


func _heat_and_shutdown() -> void:
	var h := link.pilot()
	mech.heat = 0.75 * mech.heat_cap
	_step(2)
	eq(h.mood(), "strained", "heat 0.75 -> strained")
	mech.heat = 0.95 * mech.heat_cap
	_step(2)
	eq(h.mood(), "overheated", "heat 0.95 -> overheated")
	mech.shutdown = true
	_step(2)
	eq(h.mood(), "dazed", "shutdown -> dazed")
	mech.shutdown = false
	mech.heat = 0.0
	mech.rebooted.emit()
	check(h.reacting("revived"), "rebooted -> the revived reaction")
	_step(2)
	eq(h.mood(), "stern", "cool again -> stern")
	mech.thrusting = true
	_step(1)
	check(h.reacting("effort"), "thrusting -> effort")
	mech.thrusting = false
	_step(120)


func _hits() -> void:
	var h := link.pilot()
	target.apply_damage(20.0, "torso", "enemy1")      # 5 % of the torso
	check(h.reacting("flinch") and not h.reacting("pain"), "a small hit flinches without pain")
	var away := 0.0
	for i in 6:
		_step(1)
		away = minf(away, _yaw())
	check(away < -deg_to_rad(3.0), "the flinch turns the head away from the left source (yaw %.1f deg)" % rad_to_deg(away))
	var toward := 0.0
	for i in 30:
		_step(1)
		toward = maxf(toward, _yaw())
	check(toward > deg_to_rad(20.0), "then it looks left, toward the source (yaw %.1f deg)" % rad_to_deg(toward))
	_step(150)
	target.apply_damage(80.0, "torso", "enemy1")      # 20 % of the torso
	check(h.reacting("pain"), "a big hit (20 % of the component) hurts")
	target.apply_damage(5.0, "head", "nobody_known")
	check(h.reacting("flinch"), "an unknown source still flinches (straight ahead)")
	_step(150)
	target.repair_all()
	_step(2)


func _fear_and_disabled() -> void:
	var h := link.pilot()
	target.apply_damage(330.0, "torso", "enemy1")     # torso 70 / 400 = 0.175
	_step(2)
	near(link.fear_hp(), 70.0 / 400.0, 1e-4, "fear hp = the lowest of torso / head")
	eq(h.mood(), "afraid", "low hull HP -> afraid")
	target.apply_damage(200.0, "leg_l", "enemy1")     # a core component gone: disabled
	check(target.disabled, "(the target is disabled)")
	check(h.reacting("pain"), "a destroyed component -> pain")
	_step(60)
	eq(h.mood(), "dazed", "disabled -> dazed")
	var f := h.face._flush
	var flush_only := 1.0 - maxf(f, 0.0) * h.face.red_mix - maxf(-f, 0.0) * h.face.pale_mix
	near(h.face.material.albedo_color.r, flush_only, 0.01, "and keeps its own colours (no tint beyond the flush)")
	target.repair_all()
	_step(1)
	check(h.reacting("revived"), "repaired / respawned -> revived")
	_step(60)
	eq(h.mood(), "stern", "full HP again -> stern")
	_step(120)


func _firing() -> void:
	var h := link.pilot()
	rack.aim_point = h.global_transform * Vector3(30.0, 0.85, -10.0)   # to the head's right
	rack.trigger = true
	_step(60)
	eq(h.mood(), "focused", "trigger held -> focused")
	check(_yaw() < -deg_to_rad(15.0), "and the head turns right, toward the aim point (yaw %.1f deg)" % rad_to_deg(_yaw()))
	rack.trigger = false
	rack.fired.emit(1)
	_step(10)
	check(bool(h._in["firing"]), "a shot keeps it firing for a moment")
	_step(30)
	check(not bool(h._in["firing"]), "then firing ends")
	check(h._look_on, "the look holds a while after the last shot")
	_step(90)
	check(not h._look_on, "then the look clears")
	_step(120)
	check(absf(_yaw()) < deg_to_rad(3.0), "and the head comes back (yaw %.1f deg)" % rad_to_deg(_yaw()))


func _kill() -> void:
	var h := link.pilot()
	var hit := Hit.new()
	hit.shooter = "player1"
	hit.damage = 1e6
	enemy.apply_hit(hit)
	world.hit_landed.emit(enemy, hit)
	check(h.reacting("smirk"), "a kill credited to this player -> smirk")
	_step(120)
	world.hit_landed.emit(enemy, hit)
	check(not h.reacting("smirk"), "the same wreck does not smirk twice")


func _rebuild() -> void:
	var old := link.pilot()
	mech.heat = 0.95 * mech.heat_cap
	_step(2)
	model.rebuild()
	var h := model.pilot
	check(h != null and h != old, "(rebuild made a new head)")
	h.idle_enabled = false
	_step(1)
	check(link.pilot() == h, "the link follows the new head")
	near(float(h.inputs().get("heat", 0.0)), 0.95, 1e-4, "the new head has the state within a frame")
	eq(h.mood(), "overheated", "and shows it")
	await frames(2)
	_step(2)
	mech.heat = 0.0
	_step(2)


func _unbind_and_free() -> void:
	var h := link.pilot()
	link.unbind()
	check(not rack.fired.is_connected(link._on_fired), "unbind disconnects the rack")
	check(not target.damaged.is_connected(link._on_damaged), "unbind disconnects the target")
	check(not world.hit_landed.is_connected(link._on_hit_landed), "unbind disconnects the world")
	check(not mech.rebooted.is_connected(link._on_rebooted), "unbind disconnects the controller")
	check(h.inputs().is_empty() and not h._look_on, "unbind hands the head back clean")
	# Sources freed before the link: no errors, and the link keeps running.
	link.bind(model, mech, rack, target, world)
	rack.free()
	world.unregister(target)
	target.free()
	_step(3)
	link.queue_free()
	await frames(2)
	eq(world.hit_landed.get_connections().size(), 0, "freeing the link leaves nothing connected to the world")
	eq(mech.rebooted.get_connections().size(), 0, "nor to the controller")
	world.queue_free()
	model.queue_free()
	enemy.queue_free()
	mech.free()
