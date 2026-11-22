class_name WeaponRack
extends Node
## A mech's weapons in play (weapons.md §4): one WeaponMount per loaded hardpoint, number keys to pick which fire, the
## trigger fires every enabled one at the aim point. Owner-side only: it turns input into fire records for
## CombatWorld.fire (scheduled effects) and pays heat on the mech's own gauge.
##
##   var rack := WeaponRack.new()
##   add_child(rack)
##   rack.bind(world, mech_controller, mech_model, chase_camera, "player1", 1)
##   rack.read_input = true            # number keys / mouse (false in tests: drive it through the methods below)
##
## SLOTS: one per chassis hardpoint, in MechCatalog chassis order. Strider: 1 side_l, 2 side_r, 3 shoulder_l,
## 4 shoulder_r, 5 back. An empty hardpoint is an empty slot (pressing its number does nothing). All start enabled.
##   number key      toggle that slot          same number again within DOUBLE_TAP s: solo it (only it enabled)
##   left mouse      held: fire every enabled weapon
## The left button only counts while the mouse is captured (the first click just captures it). The rack never reads the
## right button: that is the chase camera's zoom (test_drive.gd).
##
## GUIDED TRACK (automatic, no button): guided missiles steer toward the shooter's live crosshair aim point for their
## whole flight. Each step the rack writes world.designators[shooter] = {on, dot}: dot = this step's aim point, on = the
## mech can act (not shut down) and at least one enabled, intact slot holds a guided weapon (stats have
## `designator_heat`), built or not. No heat is charged for it here (the cost model comes with the missiles).
##
## --- HUD CONTRACT (read-only; poll it every frame) ------------------------------------------------------------------
##   slots() -> Array[Dictionary]      one per hardpoint, slot order:
##     slot: int (1..N)   hardpoint: String   weapon: String ("" = empty)   name: String
##     enabled: bool      ammo: int (-1 = unlimited)   ammo_max: int (-1 = unlimited)
##     ready: float 0..1  (cooldown / reload / charge / spin-up progress; 1 = can fire now; 0 when dry)
##     reloading: bool    (a salvo weapon between salvos)
##     heat_per_shot: float  (active heat per trigger cycle: per shot, per salvo for salvo weapons)
##     blocked: bool      (line of sight hardpoint -> aim point is obstructed; it still fires, into the obstacle)
##     in_range: bool     (aim point within the weapon's range, and past its min_range if it has one)
##     hold: String       (why the weapon holds fire right now, "" = it doesn't: e.g. the mortar's min range, "OUT OF ARC")
##     built: bool        (false: the weapon has no behaviour yet and never fires)
##     muzzle: Vector3    (world space: where this slot's shots leave, the turned barrel's muzzle; for an empty slot
##                        the hardpoint node's position)
##     designating: bool  (an enabled, intact guided weapon on a mech that can act: its missiles track the aim point)
##     on_target: bool    (the barrel points within Combat.ON_TARGET_DEG of the aim point: false while it is still
##                        slewing or parked at its pivot limit; always true for the mortar, false for an empty slot)
##   heat_state() -> {heat: float, cap: float, fraction: float 0..1, shutdown: bool}   (the MechController's gauge)
##   designator_on() -> bool  (the guided track is on, see above)   aim() -> Vector3 (this step's aim point)
##   substitutions() -> Array[String]  paused weapons swapped for the slot default ("LEFT SIDE: Flamer offline, using
##                                     Side Laser"), set by whoever built the loadout (TestDriveCombat); [] when none
##   signal slot_changed(slot: int)   a slot was enabled / disabled
##   signal fired(slot: int)          one shot left that slot (once per fire record: a rocket salvo emits six)
## ----------------------------------------------------------------------------------------------------------------------
##
## Control (tests / AI): press_slot(n, t = now), set_trigger(bool), set_enabled(n, bool), step(dt)
## (called by _physics_process while `auto_step`; a scene that must order it before CombatWorld.advance sets auto_step
## false and calls step itself).
##
## HEAT lives in the MechController (add_heat, shutdown): the rack hands WeaponMount.update a MechHeat bridge (can_act /
## add -> mech.add_heat) and adds the carried weapons' passive heat each step. No second gauge. Nothing fires and the
## guided track drops while the mech is shut down.
## PIVOTING (weapons.md §4.4): every direct-fire weapon turns at its mount toward the aim point (WeaponMount: slew rate
## and pivot range from the catalog / Combat.PIVOT_*), its shots leave out of the turned barrel, and each step the rack
## turns the `Weapon_<id>` model under its HP_ node to match (WeaponPose.apply). The mortar stays fixed.
## NET: enabled flags, trigger, aim point and the mounts are the owner's state (OWNER); no network code here. Remote
## machines pose the weapon models from each mount's OWNER aim_yaw / aim_pitch once mech snapshots exist.

const DOUBLE_TAP := 0.3           ## s: a second press of the same number within this solos the slot
const LOS_SLACK := 0.75           ## m short of the aim point a hit must be to count as blocked (the aim point is a surface)

signal slot_changed(slot: int)
signal fired(slot: int)

var world: CombatWorld
var mech: MechController
var model: MechModel
var camera: ChaseCamera
var shooter := "player"
var peer := 1
var read_input := false           ## read the keyboard / mouse (the thin input layer)
var auto_step := true             ## step from _physics_process
var manual_aim := false           ## true: `aim_point` is set from outside (tests), not from the camera

var hardpoints: Array[String] = []        ## slot order
var weapons: Array[String] = []           ## per slot, "" = empty
var mounts: Array = []                    ## per slot: WeaponMount or null
var enabled: Array[bool] = []
var blocked: Array[bool] = []
var trigger := false
var aim_point := Vector3.ZERO
var heat_bridge: MechHeat
var slot_disabled: Callable               ## optional: (hardpoint_id: String) -> bool (destroyed weapon hardpoint)
var _substitutions: Array[String] = []
var _glows: Array = []                    ## per slot: ChargeGlow for a charging weapon, else null

var _chassis := ""
var _loadout: Dictionary = {}
var _last_slot := 0
var _last_press := -INF
var _hp_nodes: Array = []


## WeaponMount.update's heat: the mech's own gauge (MechController.heat / shutdown) behind Heat's two methods.
class MechHeat extends RefCounted:
	var mech: MechController

	func _init(m: MechController = null) -> void:
		mech = m

	func can_act() -> bool:
		return mech == null or not mech.shutdown

	func add(amount: float) -> void:
		if mech != null and amount > 0.0:
			mech.add_heat(amount)


func net_fields() -> Dictionary:
	return {"world": Net.LOCAL, "mech": Net.LOCAL, "model": Net.LOCAL, "camera": Net.LOCAL, "shooter": Net.SPAWN,
		"peer": Net.SPAWN, "read_input": Net.LOCAL, "auto_step": Net.LOCAL, "manual_aim": Net.LOCAL,
		"hardpoints": Net.SPAWN, "weapons": Net.SPAWN, "mounts": Net.OWNER, "enabled": Net.OWNER, "blocked": Net.PRIVATE,
		"trigger": Net.OWNER, "aim_point": Net.OWNER, "heat_bridge": Net.LOCAL,
		"slot_disabled": Net.LOCAL,
		"_chassis": Net.LOCAL, "_loadout": Net.LOCAL, "_last_slot": Net.PRIVATE, "_last_press": Net.PRIVATE,
		"_hp_nodes": Net.LOCAL, "_substitutions": Net.LOCAL, "_glows": Net.LOCAL}


func bind(w: CombatWorld, m: MechController, mm: MechModel, cam: ChaseCamera = null, shooter_id: String = "player",
		shooter_peer: int = 1) -> void:
	world = w
	mech = m
	model = mm
	camera = cam
	shooter = shooter_id
	peer = shooter_peer
	heat_bridge = MechHeat.new(m)
	rebuild()


## (Re)build the slots from the model's chassis and loadout (keeps enabled flags by slot).
func rebuild() -> void:
	_chassis = model.chassis_id if model != null else "strider"
	_loadout = (model.loadout if model != null else {}).duplicate()
	hardpoints.clear()
	weapons.clear()
	mounts.clear()
	blocked.clear()
	_hp_nodes.clear()
	for g: Variant in _glows:
		if g != null and is_instance_valid(g):
			(g as Node).queue_free()
	_glows.clear()
	for hp: Dictionary in MechCatalog.chassis(_chassis)["hardpoints"]:
		var id := str(hp["id"])
		var w := str(_loadout.get(id, ""))
		hardpoints.append(id)
		weapons.append(w)
		blocked.append(false)
		_hp_nodes.append(null)
		var mount: WeaponMount = null
		var glow: ChargeGlow = null
		if w != "":
			mount = WeaponMount.new()
			mount.setup(w, id, shooter, peer, _stats(w))
			if float(mount.stats.get("charge", 0.0)) > 0.0:
				glow = ChargeGlow.new()
				add_child(glow)
			if world != null:
				world.set_muzzle(shooter, id, muzzle.bind(hardpoints.size()))   # live muzzle: the laser beam follows it
		mounts.append(mount)
		_glows.append(glow)
	while enabled.size() < hardpoints.size():
		enabled.append(true)
	enabled.resize(hardpoints.size())


func substitutions() -> Array[String]:
	return _substitutions.duplicate()


func set_substitutions(notes: Array) -> void:
	_substitutions.clear()
	for n: Variant in notes:
		_substitutions.append(str(n))


func slot_count() -> int:
	return hardpoints.size()


# --- Control ---------------------------------------------------------------------------------------------

## A number key: toggle slot `n` (1-based), or solo it when the same number was pressed within DOUBLE_TAP s.
## `t` = the press time in seconds (default: the wall clock).
func press_slot(n: int, t: float = NAN) -> void:
	var i := n - 1
	if i < 0 or i >= slot_count() or weapons[i] == "":
		return
	var now := t if not is_nan(t) else Time.get_ticks_msec() / 1000.0
	if n == _last_slot and now - _last_press <= DOUBLE_TAP:
		for j in slot_count():
			set_enabled(j + 1, j == i)
		_last_slot = 0
		_last_press = -INF
		return
	set_enabled(n, not enabled[i])
	_last_slot = n
	_last_press = now


func set_enabled(n: int, on: bool) -> void:
	var i := n - 1
	if i < 0 or i >= slot_count() or enabled[i] == on:
		return
	enabled[i] = on
	slot_changed.emit(n)


func set_trigger(on: bool) -> void:
	trigger = on


## The guided track: the mech can act and an enabled, intact slot holds a guided weapon (built or not).
func designator_on() -> bool:
	for i in slot_count():
		if _guiding(i):
			return true
	return false


## Slot index `i` is an enabled, intact guided weapon on a mech that can act.
func _guiding(i: int) -> bool:
	var m: WeaponMount = mounts[i]
	return m != null and enabled[i] and m.stats.has("designator_heat") and not _slot_broken(hardpoints[i]) 			and heat_bridge != null and heat_bridge.can_act()


func aim() -> Vector3:
	return aim_point


# --- Step ------------------------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if auto_step:
		step(delta)


func step(dt: float) -> void:
	if world == null or dt <= 0.0:
		return
	if model != null and (model.chassis_id != _chassis or model.loadout != _loadout):
		rebuild()
	if read_input:
		_poll_mouse()
	if not manual_aim:
		aim_point = _camera_aim()
	var passive := 0.0
	for i in slot_count():
		var m: WeaponMount = mounts[i]
		if m == null:
			continue
		m.stats = _stats(weapons[i])
		passive += float(m.stats.get("passive_heat", 0.0))
		var intact := not _slot_broken(hardpoints[i])
		var rest := _rest_muzzle(i)                # the unturned muzzle: the mount derives its pivot from it
		var hp_node := _hp_node(i)
		if hp_node != null:
			m.set_body_basis(hp_node.global_basis)     # fire arcs (§4.4) follow the body's facing
		for rec in m.update(dt, trigger and enabled[i] and intact, heat_bridge, world.now, rest, aim_point):
			world.fire(rec)
			fired.emit(i + 1)
		if m.aim_dir != Vector3.ZERO:
			WeaponPose.apply(hp_node, weapons[i], m.aim_yaw, m.aim_pitch)   # the model turns with its barrel (cosmetic)
		var from := muzzle(i + 1)                  # the turned barrel's muzzle
		blocked[i] = _blocked(from, m.stats)
		if _glows[i] != null:
			(_glows[i] as ChargeGlow).show_charge(from, ChargeGlow.fraction(m) if intact else 0.0, dt)
	heat_bridge.add(passive * dt)
	world.designators[shooter] = {"on": designator_on(), "dot": aim_point}


## Where slot `n`'s shots leave: `muzzle` out along its turned barrel from the hardpoint node (WeaponPose.muzzle: the
## model's own muzzle), or straight ahead of it before the barrel was first ticked / for a weapon that doesn't track (the
## mortar); an empty slot: the hardpoint node's position. Live: the beam, charge glow, flamer stream and missile laser
## start here.
func muzzle(n: int) -> Vector3:
	var i := n - 1
	if i < 0 or i >= slot_count():
		return Vector3.ZERO
	var m: WeaponMount = mounts[i]
	var node := _hp_node(i)
	if m != null and node != null and m.aim_dir != Vector3.ZERO:
		return WeaponPose.muzzle(node, m.aim_yaw, m.aim_pitch, float(MechCatalog.weapon(weapons[i]).get("muzzle", 0.0)))
	return _rest_muzzle(i)


## Slot index `i`'s unturned muzzle: `muzzle` straight ahead of its hardpoint node (as the weapon_range lab does).
func _rest_muzzle(i: int) -> Vector3:
	var node := _hp_node(i)
	if node == null:
		return mech.global_position if mech != null and mech.is_inside_tree() else Vector3.ZERO
	var st: Dictionary = MechCatalog.weapon(weapons[i]) if weapons[i] != "" else {}
	return node.global_transform * Vector3(0, 0, -float(st.get("muzzle", 0.0)))


func _hp_node(i: int) -> Node3D:
	var n: Variant = _hp_nodes[i]
	if n != null and is_instance_valid(n) and (n as Node3D).is_inside_tree():
		return n
	_hp_nodes[i] = null
	if model == null:
		return null
	var found := model.find_child("HP_" + hardpoints[i], true, false) as Node3D
	if found != null and found.is_inside_tree() and not found.is_queued_for_deletion():
		_hp_nodes[i] = found
		return found
	return null


func _stats(w: String) -> Dictionary:
	return world.stats(w) if world != null else MechCatalog.weapon(w)


## Line of sight from the muzzle to the aim point through world geometry (the mech itself excluded). Arcing weapons
## (the mortar) don't need it.
func _blocked(from: Vector3, st: Dictionary) -> bool:
	if str(st.get("kind", "")) == "arc":
		return false
	var sp := world.space()
	var d := from.distance_to(aim_point)
	if sp == null or d < LOS_SLACK * 2.0:
		return false
	var q := PhysicsRayQueryParameters3D.create(from, aim_point)
	if mech != null:
		q.exclude = [mech.get_rid()]
	var h := sp.intersect_ray(q)
	return not h.is_empty() and from.distance_to(h["position"]) < d - LOS_SLACK


## The camera's aim point, pulled in to a combat target the view ray passes through first (targets have hit spheres,
## not colliders, so the camera's own ray goes through them).
func _camera_aim() -> Vector3:
	if camera == null or not camera.is_inside_tree():
		return aim_point
	var p := camera.aim_point()
	var h := world.first_hit(camera.global_position, p, 0.0, shooter)
	return h["point"] if not h.is_empty() else p


func _slot_broken(hp_id: String) -> bool:
	return slot_disabled.is_valid() and bool(slot_disabled.call(hp_id))


# --- HUD state ---------------------------------------------------------------------------------------------

func slots() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in slot_count():
		var w := weapons[i]
		var m: WeaponMount = mounts[i]
		var st: Dictionary = m.stats if m != null else {}
		var broken := _slot_broken(hardpoints[i])
		var d := {"slot": i + 1, "hardpoint": hardpoints[i], "weapon": w, "name": str(st.get("name", "")),
			"enabled": enabled[i], "ammo": m.ammo if m != null else -1, "ammo_max": int(st.get("ammo", -1)),
			"ready": 0.0 if broken else _ready_of(m), "reloading": not broken and _reloading(m),
			"heat_per_shot": float(st.get("active_heat", 0.0)), "blocked": blocked[i], "in_range": _in_range(i, st),
			"hold": "destroyed" if broken else (m.hold_reason if m != null else ""),
			"built": m != null and m.built(), "muzzle": muzzle(i + 1),
			"designating": _guiding(i), "on_target": m != null and m.on_target()}
		out.append(d)
	return out


func heat_state() -> Dictionary:
	if mech == null:
		return {"heat": 0.0, "cap": 0.0, "fraction": 0.0, "shutdown": false}
	return {"heat": mech.heat, "cap": mech.heat_cap, "fraction": mech.heat / mech.heat_cap if mech.heat_cap > 0.0 else 0.0,
		"shutdown": mech.shutdown}


func _reloading(m: WeaponMount) -> bool:
	return m != null and int(m.stats.get("salvo", 1)) > 1 and m.salvo_left <= 0 and m.cooldown > m.interval() + 1e-6


func _ready_of(m: WeaponMount) -> float:
	if m == null or not m.built() or m.ammo == 0:
		return 0.0
	var need := float(m.stats.get("charge", 0.0))
	if need > 0.0 and m.charge > 0.0 and m.charge < need:
		return clampf(m.charge / need, 0.0, 1.0)
	if float(m.stats.get("spin_up", 0.0)) > 0.0 and m.spin > 0.0 and m.spin < 1.0:
		return m.spin
	var period := m.interval()
	if _reloading(m):
		period += float(m.stats.get("reload", 0.0))
	return clampf(1.0 - maxf(m.cooldown, 0.0) / maxf(period, 1e-6), 0.0, 1.0)


func _in_range(i: int, st: Dictionary) -> bool:
	if st.is_empty():
		return false
	var d := muzzle(i + 1).distance_to(aim_point)
	return d <= float(st.get("range", INF)) and d >= float(st.get("min_range", 0.0))


# --- Input (the thin layer) ---------------------------------------------------------------------------------

func _poll_mouse() -> void:
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	set_trigger(captured and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT))


func _unhandled_input(e: InputEvent) -> void:
	if not read_input or not (e is InputEventKey):
		return
	var k := e as InputEventKey
	if not k.pressed or k.echo:
		return
	var code := k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode
	if code >= KEY_1 and code <= KEY_9:
		press_slot(int(code - KEY_1) + 1)
