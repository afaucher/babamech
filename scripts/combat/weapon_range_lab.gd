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
## Direct-fire weapons pivot at the mount toward the aim point and the model turns with them (WeaponPose); "Aim at"
## ground_10m picks a point on the ground close ahead, so a shoulder weapon visibly pitches down to it.

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
const DESIGNATOR_MODES := ["off", "hold", "drop"]
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
var weapon := "autocannon"
var hardpoint := "side_r"
var mass := "light"
var fire_mode := "hold"
var aim := "dummy_50"
var designator := "off"
var _designator_auto := true      ## the designator follows the weapon's default (missiles: "hold") until picked by hand

var world: CombatWorld
var mech: MechModel
var mount: WeaponMount
var heat: Heat
var dummies: Array[TargetDummy] = []
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
	_rebuild()


func lab_own_ground() -> bool:
	return true


## The ground, the stand, a 25 m scale line and a wall behind each dummy (static colliders: world geometry for shots
## and knockback).
func _build_range() -> void:
	_add_block(Vector3(80, 1, 280), Vector3(0, -0.5, -110), Color(0.34, 0.36, 0.37))
	_add_block(Vector3(4, 0.6, 4), Vector3(0, 0.3, 0), MechMeshes.GUN)
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
	mi.mesh = k.commit(MechMeshes.materials())
	body.add_child(mi)
	add_child(body)


func _rebuild() -> void:
	if mech == null:
		return
	mech.configure("chicken", "strider", {hardpoint: weapon})
	var c := MechCatalog.chassis("strider")
	heat = Heat.new(float(c["heat_cap"]), float(c["cooling"]), float(MechCatalog.weapon(weapon).get("passive_heat", 0.0)))
	mount = WeaponMount.new()
	mount.setup(weapon, hardpoint, SHOOTER, 1, world.stats(weapon))
	world.muzzles.clear()
	world.set_muzzle(SHOOTER, hardpoint, muzzle)
	_t = 0.0
	_single_hold = false
	for d in dummies:
		d.mass_class = mass
		d.reset_dummy()


func aim_dummy() -> TargetDummy:
	for d in dummies:
		if d.name == aim:
			return d
	return dummies[0] if not dummies.is_empty() else null


func aim_point() -> Vector3:
	if aim == GROUND_AIM:
		return GROUND_POINT
	var d := aim_dummy()
	return d.global_position + Vector3(0, 1.9, 0) if d != null else Vector3(0, 2, -50)


## Where shots leave: `muzzle` out along the weapon's turned barrel from the hardpoint node (weapons.md §4.4: direct-fire
## weapons pivot to the aim point), or straight ahead of it before the first step / for the mortar.
func muzzle() -> Vector3:
	var hp := mech.find_child("HP_" + hardpoint, true, false) as Node3D
	if hp != null and mount != null and mount.aim_dir != Vector3.ZERO:
		return WeaponPose.muzzle(hp, mount.aim_yaw, mount.aim_pitch, float(MechCatalog.weapon(weapon).get("muzzle", 1.0)))
	return rest_muzzle()


## The unturned muzzle: `muzzle` straight ahead of the hardpoint node (what the mount derives its pivot from).
func rest_muzzle() -> Vector3:
	var hp := mech.find_child("HP_" + hardpoint, true, false) as Node3D
	if hp == null:
		return mech.global_position + Vector3(0, 4, -2)
	return hp.global_transform * Vector3(0, 0, -float(MechCatalog.weapon(weapon).get("muzzle", 1.0)))


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
	if fire_mode == "single" and not _single_hold and (floor(_t / TAP_EVERY) > floor(prev / TAP_EVERY) or prev == 0.0):
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
	_glow.show_charge(from, ChargeGlow.fraction(mount), dt)
	var des_on := designator == "hold" or (designator == "drop" and fmod(_t, DESIGNATOR_CYCLE) < 1.0)
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
	for hp: Dictionary in MechCatalog.chassis("strider")["hardpoints"]:
		hps.append(str(hp["id"]))
	var aims: Array = []
	for d: Array in DUMMIES:
		aims.append("dummy_%d" % int(d[0]))
	aims.append(GROUND_AIM)
	return [
		{"id": "weapon", "label": "Weapon", "choices": weapons, "value": weapon},
		{"id": "hardpoint", "label": "Hardpoint", "choices": hps, "value": hardpoint},
		{"id": "mass", "label": "Dummy mass class", "choices": Combat.MASS_ORDER, "value": mass},
		{"id": "fire", "label": "Fire mode", "choices": FIRE_MODES, "value": fire_mode},
		{"id": "aim", "label": "Aim at", "choices": aims, "value": aim},
		{"id": "designator", "label": "Designator", "choices": DESIGNATOR_MODES, "value": designator},
		{"id": "arcs", "label": "Fixed arcs", "choices": ["off", "on"], "value": "on" if Combat.FIXED_ARC_ENABLED else "off"},
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
				var mounts: Array = MechCatalog.weapon(v)["mounts"]
				var cur := ""
				for hp: Dictionary in MechCatalog.chassis("strider")["hardpoints"]:
					if hp["id"] == hardpoint:
						cur = str(hp["mount"])
				if not cur in mounts:      # move to the first hardpoint that takes it
					for hp: Dictionary in MechCatalog.chassis("strider")["hardpoints"]:
						if str(hp["mount"]) in mounts:
							hardpoint = str(hp["id"])
							break
		"hardpoint": hardpoint = v
		"mass": mass = v if Combat.MASS.has(v) else "light"
		"fire": fire_mode = v if v in FIRE_MODES else "off"
		"aim": aim = v
		"designator":
			designator = v if v in DESIGNATOR_MODES else "off"
			_designator_auto = false      # an explicit pick sticks across weapon changes
		"arcs": Combat.FIXED_ARC_ENABLED = v == "on"     # the global switch (weapons.md §4.4), default off
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
	return Vector3(6.0, 3.0, -21.0)   # off centre: the lab panel covers the left of the view


func lab_radius() -> float:
	return 17.0
