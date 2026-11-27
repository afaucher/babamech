class_name WeaponRangeLab
extends Node3D
## Lab subject "weapon_range" (weapons.md §6): a mech on a stand fires the chosen weapon from the chosen hardpoint
## (from that HP node, `muzzle` ahead) at kinematic TargetDummy posts 25 / 50 / 100 / 200 m out, each with a wall
## behind it (impacts, wall slams). Dummies show HP and heat, get knocked around, stagger, and reset when destroyed or
## when an option changes. Sliders override the weapon's catalog numbers for this lab session only
## (CombatWorld.overrides). Unbuilt weapons (not in WeaponRegistry) mount but don't fire.
## Everything runs on the CombatWorld clock, advanced by delta × time_scale (the lab's speed / pause).
## Fire modes: "hold" keeps the trigger down; "single" presses it every TAP_EVERY s and holds it only until one shot
## (one salvo) has left, so spin-up and charge weapons fire once per tap too; "off". A charging weapon shows its charge
## telegraph (ChargeGlow) at the muzzle, and the laser beam follows the live muzzle (CombatWorld.set_muzzle).
## Option "Chassis" puts any built chassis on the stand (the Bulwark: side guns and two back saddles; the hardpoint's own
## aim range, WeaponMount.hardpoint_range, applies as in the game).
## Direct-fire weapons pivot at the mount toward the aim point and the model turns with them (WeaponPose); "Aim at"
## ground_10m picks a point on the ground close ahead, so a shoulder weapon visibly pitches down to it.
## BACK EQUIPMENT (docs/design/back-equipment.md) is in the Weapon list too; it works only on the back hardpoint. The
## repair drone launches by fire mode ("hold": whenever none is out; "single": on each tap with none out; "off": never;
## unlimited charges, 15 heat each) and repairs a PlayerTarget on the lab mech plus a repair dummy at REPAIR_DUMMY beside
## the stand (both exist only while the drone is selected); option "Repair demo" = "damaged" knocks them to about half
## HP on every change and again whenever both are full, "full" leaves them whole. Radiator: the lab heat gauge cools
## +3 /s, and a demo heat load (RADIATOR_DEMO_HEAT /s in "hold", RADIATOR_DEMO_TAP per tap in "single") makes it climb so
## the fins glow (EquipmentLook: the lab mech's radiator follows the lab gauge; the drone's cradle shows empty while the
## drone is out). Ammo bin: shown in the readout (it applies to the limited-ammo weapons of a whole loadout, not to this one).

const MECH_SCALE := 2.0
const SHOOTER := "range_mech"
## [distance from the stand (m), bearing (deg, + = right of straight ahead)]: fanned out so the shooter has a clear line
## to every dummy (no near dummy or wall in front of a far one, from either side hardpoint).
const DUMMIES := [[25.0, -22.0], [50.0, 14.0], [100.0, -6.0], [200.0, 3.0]]
const WALL_BEHIND := 4.0          ## m behind each dummy, along its bearing, facing the stand
const TAP_EVERY := 1.0            ## s between trigger taps in "single" mode
const DESIGNATOR_CYCLE := 2.0     ## "drop": on for 1 s, off for the rest of the cycle
const FIRE_MODES := ["off", "single", "hold"]
## "Aim at" choice: a point on the ground close ahead, so a shoulder weapon visibly pitches down to it (weapons.md §4.4).
const GROUND_AIM := "ground_10m"
const GROUND_POINT := Vector3(1.5, 0.05, -10.0)
## AIRBORNE dummy (the flak's proximity fuse, weapons.md §3.10): a static TargetDummy hovering AIR_DUMMY = [distance (m),
## bearing (deg), height (m)] out, off every ground firing line; not in `dummies`. "Aim at" AIR_AIM shoots straight at it,
## AIR_NEAR_AIM aims AIR_NEAR_OFFSET m beside it, so a flak shell passes it and the fuse bursts it alongside.
const AIR_DUMMY := [80.0, 30.0, 20.0]
const AIR_AIM := "air_80"
const AIR_NEAR_AIM := "air_80_near"
const AIR_NEAR_OFFSET := 4.0
const DESIGNATOR_MODES := ["off", "hold", "drop"]
const REPAIR_MODES := ["damaged", "full"]
const REPAIR_DUMMY := Vector3(10.0, 0.0, -6.0)   ## within the drone's 15 m, clear of the firing lines
const RADIATOR_DEMO_HEAT := 14.0  ## heat/s the radiator demo adds in "hold" (more than the 9 /s it sheds: it climbs)
const RADIATOR_DEMO_TAP := 25.0   ## heat the radiator demo adds per tap in "single"
## Slider id (a catalog stat), label, min, max.
const PARAMS := [
	["speed", "Projectile speed (m/s)", 5.0, 300.0],
	["rate", "Rate (shots/s)", 0.1, 20.0],
	["damage", "Damage / hit", 0.0, 300.0],
	["knockback", "Knockback dv (m/s)", 0.0, 20.0],
	["growth", "Growth g (drawn size x)", 1.0, 6.0],
	["growth_full", "Growth distance d_full (m)", 10.0, 300.0],
]

var time_scale := 1.0
var chassis := "strider"          ## option "Chassis": any built chassis (ChassisParts.ORDER), its hardpoints and ranges
var weapon := "autocannon"
var hardpoint := "side_r"
var mass := "light"
var fire_mode := "hold"
var aim := "dummy_50"
var designator := "off"
var _designator_auto := true      ## the designator follows the weapon's default (missiles: "hold") until picked by hand
var repair := "damaged"
var drone: RepairDrone            ## the lab drone while one is out
var lab_target: PlayerTarget      ## the lab mech as a repairable target (repair drone selected only)
var repair_dummy: TargetDummy     ## a damaged dummy next to the stand (repair drone selected only)

var world: CombatWorld
var mech: MechModel
var mount: WeaponMount
var heat: Heat
var dummies: Array[TargetDummy] = []
var air_dummy: TargetDummy        ## the airborne dummy (AIR_DUMMY)
var _t := 0.0
var _single_hold := false    ## "single": the trigger is down until the tap's shot has left
var _hold_from := 0          ## mount.shot_index when the tap started
var _glow: ChargeGlow
var _beam: MeshInstance3D
var _dot: MeshInstance3D
var _heat_label: Label3D


func _ready() -> void:
	world = CombatWorld.new()
	world.name = "CombatWorld"
	world.mission_seed = 1
	add_child(world)
	var ca := CombatAudio.new()
	ca.name = "CombatAudio"
	add_child(ca)
	ca.bind(world, null, null, SHOOTER)
	_build_range()
	mech = MechModel.new()
	mech.scale = Vector3.ONE * MECH_SCALE
	mech.position = Vector3(0, 0.6, 0)
	add_child(mech)
	_heat_label = Label3D.new()
	_heat_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_heat_label.fixed_size = true
	_heat_label.pixel_size = 0.0007
	_heat_label.font_size = 24
	_heat_label.outline_size = 8
	_heat_label.no_depth_test = true
	_heat_label.position = Vector3(0, 11.0, 0)
	add_child(_heat_label)
	_beam = CombatMeshes.instance(CombatMeshes.prism3(CombatMeshes.RED))
	_beam.top_level = true
	add_child(_beam)
	_dot = CombatMeshes.instance(CombatMeshes.ico(CombatMeshes.RED, true))
	_dot.top_level = true
	add_child(_dot)
	_glow = ChargeGlow.new()
	add_child(_glow)
	for i in DUMMIES.size():
		var d := TargetDummy.new()
		d.name = "dummy_%d" % int(DUMMIES[i][0])
		d.target_id = d.name
		d.position = dummy_dir(i) * float(DUMMIES[i][0])
		d.rotation.y = -deg_to_rad(float(DUMMIES[i][1]))     # the visor faces the stand
		add_child(d)
		world.register(d)
		dummies.append(d)
	air_dummy = TargetDummy.new()
	air_dummy.name = AIR_AIM
	air_dummy.target_id = AIR_AIM
	air_dummy.mass_class = "static"      # hovers in place (its ground plane is its own height: never falls)
	var ab := deg_to_rad(float(AIR_DUMMY[1]))
	air_dummy.position = Vector3(sin(ab), 0, -cos(ab)) * float(AIR_DUMMY[0]) + Vector3.UP * float(AIR_DUMMY[2])
	air_dummy.rotation.y = -ab
	add_child(air_dummy)
	world.register(air_dummy)
	_rebuild()


func lab_own_ground() -> bool:
	return true


## The ground, the stand, a 25 m scale line and a wall behind each dummy (static colliders: world geometry for shots
## and knockback).
func _build_range() -> void:
	_add_block(Vector3(80, 1, 280), Vector3(0, -0.5, -110), Color(0.34, 0.36, 0.37))
	_add_block(Vector3(4, 0.6, 4), Vector3(0, 0.3, 0), LowPolyPalette.GUN)
	for i in range(1, 9):
		var m := MechParts.box(Vector3(30, 0.02, 0.25), Color(0.45, 0.47, 0.48), Vector3(0, 0.01, -25.0 * i))
		add_child(m)
	for i in DUMMIES.size():
		var at := dummy_dir(i) * (float(DUMMIES[i][0]) + WALL_BEHIND + 0.5) + Vector3(0, 3, 0)
		_add_block(Vector3(8, 6, 1), at, Color(0.52, 0.5, 0.46), -deg_to_rad(float(DUMMIES[i][1])))


## Unit direction from the stand to dummy i (on the ground plane; -Z is straight ahead).
static func dummy_dir(i: int) -> Vector3:
	var b := deg_to_rad(float(DUMMIES[i][1]))
	return Vector3(sin(b), 0, -cos(b))


func _add_block(size: Vector3, at: Vector3, c: Color, yaw: float = 0.0) -> void:
	var body := StaticBody3D.new()
	body.position = at
	body.rotation.y = yaw
	body.set_meta("surface_color", c)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	var k := MeshKit.new()
	k.box(size, c)
	var mi := MeshInstance3D.new()
	mi.mesh = k.commit(LowPolyMaterials.materials())
	body.add_child(mi)
	add_child(body)


func _rebuild() -> void:
	if mech == null:
		return
	mech.configure("chicken", chassis, {hardpoint: weapon})
	var c := MechCatalog.chassis(chassis)
	var eq := equipped()
	var cool := float(c["cooling"]) + (float(world.stats(eq).get("cooling_bonus", 0.0)) if eq != "" else 0.0)
	heat = Heat.new(float(c["heat_cap"]), cool, float(MechCatalog.weapon(weapon).get("passive_heat", 0.0)))
	world.set_anchor(SHOOTER, _lab_anchor)
	world.equipment_look.watch(SHOOTER, _lab_anchor, _lab_heat)
	if drone != null and is_instance_valid(drone):
		world.remove_effect(drone)
	drone = null
	_setup_repair(eq == "repair_drone")
	mount = WeaponMount.new()
	mount.setup(weapon, hardpoint, SHOOTER, 1, world.stats(weapon))
	mount.set_hardpoint_range(WeaponMount.hardpoint_range(chassis, hardpoint))   # e.g. the Bulwark's yaw_in_max
	world.muzzles.clear()
	world.set_muzzle(SHOOTER, hardpoint, muzzle)
	_t = 0.0
	_single_hold = false
	for d in dummies:
		d.mass_class = mass
		d.reset_dummy()
	if air_dummy != null:
		air_dummy.reset_dummy()


func _lab_anchor() -> Node3D:
	return mech


func _lab_heat() -> float:
	return heat.fraction() if heat != null else 0.0


## The equipment in use: `weapon` when it is back-mount equipment on a hardpoint that takes it, else "".
func equipped() -> String:
	if not MechCatalog.is_equipment(weapon):
		return ""
	for hp: Dictionary in MechCatalog.chassis(chassis)["hardpoints"]:
		if hp["id"] == hardpoint and MechCatalog.fits(hp, weapon):
			return weapon
	return ""


## The chassis' hardpoint `id`, or {}.
func _hp(id: String) -> Dictionary:
	for hp: Dictionary in MechCatalog.chassis(chassis)["hardpoints"]:
		if str(hp["id"]) == id:
			return hp
	return {}


## Keep `hardpoint` on the chassis and on one that takes `weapon`: else the first hardpoint that does (else the first).
func _fit_hardpoint() -> void:
	var hps: Array = MechCatalog.chassis(chassis)["hardpoints"]
	var cur := _hp(hardpoint)
	if not cur.is_empty() and MechCatalog.fits(cur, weapon):
		return
	for hp: Dictionary in hps:
		if MechCatalog.fits(hp, weapon):
			hardpoint = str(hp["id"])
			return
	if cur.is_empty():
		hardpoint = str((hps[0] as Dictionary)["id"])


## The repair demo's targets: made (and damaged, in "damaged") while the drone is selected, removed otherwise.
func _setup_repair(on: bool) -> void:
	if not on:
		for t: CombatTarget in [lab_target, repair_dummy]:
			if t != null and is_instance_valid(t):
				world.unregister(t)
				t.queue_free()
		lab_target = null
		repair_dummy = null
		return
	if lab_target == null:
		lab_target = PlayerTarget.new()
		lab_target.name = "LabMechTarget"
		lab_target.auto_respawn_delay = -1.0
		add_child(lab_target)
		lab_target.position = mech.position
		lab_target.bind(world, null, mech, SHOOTER, 1)
		world.register(lab_target)
	if repair_dummy == null:
		repair_dummy = TargetDummy.new()
		repair_dummy.name = "repair_dummy"
		repair_dummy.target_id = "repair_dummy"
		repair_dummy.position = REPAIR_DUMMY
		add_child(repair_dummy)
		world.register(repair_dummy)
	lab_target.repair_all()
	repair_dummy.reset_dummy()
	if repair == "damaged":
		_damage_demo()


## Knock the demo targets to about half HP (their owner's verbs: this machine owns both).
func _damage_demo() -> void:
	if lab_target != null:
		lab_target.apply_damage(200.0, "torso", "lab")
		lab_target.apply_damage(90.0, "leg_l", "lab")
	if repair_dummy != null:
		repair_dummy.apply_damage(TargetDummy.HP * 0.5, "body", "lab")


## The repair drone, each step: launch by fire mode, and keep the "damaged" demo going.
func _step_drone(tap: bool) -> void:
	if drone != null and (not is_instance_valid(drone) or drone.finished()):
		drone = null
	var out := drone != null              # rising, circling or flying home: the next one waits until it has docked
	if not out and (fire_mode == "hold" or (fire_mode == "single" and tap)) and heat.can_act():
		heat.add(float(world.stats("repair_drone").get("active_heat", 0.0)))
		drone = world.launch_drone({"shooter": SHOOTER, "peer": 1, "hardpoint": hardpoint, "weapon": "repair_drone",
			"t": world.now})
	if repair != "damaged" or lab_target == null or repair_dummy == null:
		return
	if lab_target.total_hp() >= lab_target.total_max_hp() - 1e-3 and repair_dummy.total_hp() >= TargetDummy.HP - 1e-3:
		_damage_demo()


func aim_dummy() -> TargetDummy:
	for d in dummies:
		if d.name == aim:
			return d
	return dummies[0] if not dummies.is_empty() else null


func aim_point() -> Vector3:
	if aim == GROUND_AIM:
		return GROUND_POINT
	if (aim == AIR_AIM or aim == AIR_NEAR_AIM) and air_dummy != null:
		var at := air_dummy.global_position + Vector3(0, 1.9, 0)
		if aim == AIR_NEAR_AIM:      # beside it, across the line of fire
			at += (at - rest_muzzle()).cross(Vector3.UP).normalized() * AIR_NEAR_OFFSET
		return at
	var d := aim_dummy()
	return d.global_position + Vector3(0, 1.9, 0) if d != null else Vector3(0, 2, -50)


## Where shots leave: `muzzle` out along the weapon's turned barrel from the hardpoint node (weapons.md §4.4: direct-fire
## weapons pivot to the aim point), or straight ahead of it before the first step / for the mortar.
func muzzle() -> Vector3:
	var hp := mech.find_child("HP_" + hardpoint, true, false) as Node3D
	if hp != null and mount != null and mount.aim_dir != Vector3.ZERO:
		return WeaponPose.muzzle(hp, mount.aim_yaw, mount.aim_pitch, float(MechCatalog.weapon(weapon).get("muzzle", 1.0)))
	return rest_muzzle()


## The unturned muzzle: `muzzle` straight ahead of the hardpoint node (what the mount derives its pivot from); the
## mortar's tube mouth (WeaponPose.rest_offset).
func rest_muzzle() -> Vector3:
	var hp := mech.find_child("HP_" + hardpoint, true, false) as Node3D
	if hp == null:
		return mech.global_position + Vector3(0, 4, -2)
	return hp.global_transform * WeaponPose.rest_offset(weapon, float(MechCatalog.weapon(weapon).get("muzzle", 1.0)))


func trigger() -> bool:
	match fire_mode:
		"hold": return true
		"single": return _single_hold
	return false



func _physics_process(delta: float) -> void:
	step(delta * time_scale)


## One lab step of `dt` seconds of combat time.
func step(dt: float) -> void:
	if world == null or dt <= 0.0:
		return
	var prev := _t
	_t += dt
	var tap: bool = floorf(_t / TAP_EVERY) > floorf(prev / TAP_EVERY) or prev == 0.0
	if equipped() == "repair_drone":
		_step_drone(tap)
	elif equipped() == "radiator" and heat.can_act():
		if fire_mode == "hold":
			heat.add(RADIATOR_DEMO_HEAT * dt)
		elif fire_mode == "single" and tap:
			heat.add(RADIATOR_DEMO_TAP)
	if fire_mode == "single" and not _single_hold and tap:
		_single_hold = true
		_hold_from = mount.shot_index
	heat.tick(dt)
	var to := aim_point()
	var hp := mech.find_child("HP_" + hardpoint, true, false) as Node3D
	if hp != null:
		mount.set_body_basis(hp.global_basis)     # fire arcs (§4.4) follow the mech's facing
	for rec in mount.update(dt, trigger(), heat, world.now, rest_muzzle(), to):
		world.fire(rec)
	if mount.aim_dir != Vector3.ZERO:
		WeaponPose.apply(hp, weapon, mount.aim_yaw, mount.aim_pitch)   # the model turns with its barrel
	var from := muzzle()                          # the turned barrel's muzzle
	if _single_hold and mount.shot_index > _hold_from:
		_single_hold = false      # one shot (a salvo ripples on by itself) has left: release
	world.advance(dt)
	_glow.show_charge(from, 0.0 if mount.parked else ChargeGlow.fraction(mount), dt)   # no glow while shut down
	var des_on := (designator == "hold" or (designator == "drop" and fmod(_t, DESIGNATOR_CYCLE) < 1.0)) and heat.can_act()
	world.designators[SHOOTER] = {"on": des_on, "dot": to}
	var preview := des_on and weapon != "missiles"     # built missiles draw their own laser line (MissileLaser)
	_beam.visible = preview
	_dot.visible = preview
	if preview:
		var length := from.distance_to(to)
		_beam.global_transform = Transform3D(Combat.look_basis(to - from) * Basis.from_scale(Vector3(0.03, 0.03, length)), from)
		_dot.global_transform = Transform3D(Basis.from_scale(Vector3.ONE * 0.15), to)
	_heat_label.text = "%s  %s\nHEAT %3d / %d%s%s" % [weapon, hardpoint, int(heat.value), int(heat.cap),
		"  SHUTDOWN" if heat.shutdown else "", "" if mount.built() else "\n(not built yet: doesn't fire)"]
	if mount.ammo >= 0:     # ammo weapons (rockets): count, DRY when empty; any option change refills (_rebuild)
		_heat_label.text += "\nAMMO %d / %d%s" % [mount.ammo, int(mount.stats.get("ammo", 0)), "  DRY" if mount.ammo == 0 else ""]
	var eq := equipped()
	if eq != "":
		_heat_label.text = "%s  %s\nHEAT %3d / %d   cooling %.0f/s%s" % [eq, hardpoint, int(heat.value), int(heat.cap),
			heat.cooling, "  SHUTDOWN" if heat.shutdown else ""]
		if eq == "repair_drone":
			var live := drone != null and is_instance_valid(drone) and not drone.finished()
			var state := "docked"
			if live:
				state = "returning" if drone.returning() else "%.0f s left, repaired %.0f HP" % [drone.time_left(), drone.healed_total]
			_heat_label.text += "\nDRONE " + state
		elif eq == "radiator":
			_heat_label.text += "\nfins glow with heat (demo load %s)" % ("%.0f/s" % RADIATOR_DEMO_HEAT if fire_mode == "hold"
				else ("%.0f per tap" % RADIATOR_DEMO_TAP if fire_mode == "single" else "off"))
		elif eq == "ammo_bin":
			_heat_label.text += "\n+50%% ammo on limited-ammo weapons (rockets %d, missiles %d, mortar %d)" % [
				WeaponRack.bonus_ammo(36, 6, 0.5), WeaponRack.bonus_ammo(18, 3, 0.5), WeaponRack.bonus_ammo(3, 1, 0.5)]
	elif MechCatalog.is_equipment(weapon):
		_heat_label.text += "\n(equipment: back hardpoint only)"
	if mount.hold_reason != "":     # a weapon holding fire says why (the mortar: inside its minimum range / out of range)
		_heat_label.text += "\nHOLD: " + mount.hold_reason


# --- Lab contract --------------------------------------------------------------------------------------

func lab_params() -> Array:
	var st := world.stats(weapon) if world != null else MechCatalog.weapon(weapon)
	var out: Array = []
	for p: Array in PARAMS:
		out.append({"id": p[0], "label": p[1], "min": p[2], "max": p[3], "value": float(st.get(p[0], 0.0))})
	return out


func set_lab_param(id: String, v: float) -> void:
	if world == null:
		return
	var o: Dictionary = world.overrides.get(weapon, {})
	o[id] = v
	world.overrides[weapon] = o
	if mount != null:
		mount.stats = world.stats(weapon)


func lab_options() -> Array:
	var weapons: Array = MechCatalog.WEAPON_ORDER.duplicate()
	for w: String in MechCatalog.WEAPONS:
		if not w in weapons:
			weapons.append(w)
	var hps: Array = []
	for hp: Dictionary in MechCatalog.chassis(chassis)["hardpoints"]:
		hps.append(str(hp["id"]))
	var aims: Array = []
	for d: Array in DUMMIES:
		aims.append("dummy_%d" % int(d[0]))
	aims.append(GROUND_AIM)
	aims.append(AIR_AIM)
	aims.append(AIR_NEAR_AIM)
	return [
		{"id": "weapon", "label": "Weapon", "choices": weapons, "value": weapon},
		{"id": "hardpoint", "label": "Hardpoint", "choices": hps, "value": hardpoint},
		{"id": "mass", "label": "Dummy mass class", "choices": Combat.MASS_ORDER, "value": mass},
		{"id": "fire", "label": "Fire mode", "choices": FIRE_MODES, "value": fire_mode},
		{"id": "aim", "label": "Aim at", "choices": aims, "value": aim},
		{"id": "designator", "label": "Designator", "choices": DESIGNATOR_MODES, "value": designator},
		{"id": "arcs", "label": "Fixed arcs", "choices": ["off", "on"], "value": "on" if Combat.FIXED_ARC_ENABLED else "off"},
		{"id": "repair", "label": "Repair demo (drone)", "choices": REPAIR_MODES, "value": repair},
		{"id": "chassis", "label": "Chassis", "choices": ChassisParts.ORDER, "value": chassis},
	]


func set_lab_option(id: String, v: String) -> void:
	match id:
		"weapon":
			if MechCatalog.WEAPONS.has(v):
				weapon = v
				# Missiles guide out of the box: their designator defaults to "hold" (the user can still pick off /
				# drop); leaving the missiles puts back a designator that only that default had switched on.
				if v == "missiles" and _designator_auto:
					designator = "hold"
				elif v != "missiles" and _designator_auto:
					designator = "off"
				_fit_hardpoint()           # move to the first hardpoint that takes it
		"hardpoint": hardpoint = v
		"chassis":
			chassis = v if v in ChassisParts.ORDER else "strider"
			_fit_hardpoint()
		"mass": mass = v if Combat.MASS.has(v) else "light"
		"fire": fire_mode = v if v in FIRE_MODES else "off"
		"aim": aim = v
		"designator":
			designator = v if v in DESIGNATOR_MODES else "off"
			_designator_auto = false      # an explicit pick sticks across weapon changes
		"arcs": Combat.FIXED_ARC_ENABLED = v == "on"     # the global switch (weapons.md §4.4), default off
		"repair": repair = v if v in REPAIR_MODES else "damaged"
	_rebuild()
	_refresh_panel()


## An option set from code (a test, another option's default) must show in the lab's side panel too: ask the Lab that
## holds this subject to rebuild its panel from lab_options() (deferred; the Lab does the same after a user's pick).
func _refresh_panel() -> void:
	var lab := get_parent()
	while lab != null and not lab.has_method("_rebuild_params"):
		lab = lab.get_parent()
	if lab != null:
		lab.call_deferred("_rebuild_params")


func lab_focus() -> Vector3:
	if equipped() == "repair_drone":
		return Vector3(3.0, 6.0, -3.0)   # the stand, the drone above it and the repair dummy
	if equipped() != "":
		var hp := mech.find_child("HP_" + hardpoint, true, false) as Node3D if mech != null else null
		if hp != null and hp.is_inside_tree():
			return hp.global_position     # the radiator / ammo bin on the back mount
	return Vector3(6.0, 3.0, -21.0)   # off centre: the lab panel covers the left of the view


func lab_radius() -> float:
	return 17.0
