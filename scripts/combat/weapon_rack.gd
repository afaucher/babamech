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
## 4 shoulder_r, 5 back. Bulwark: 1 side_l, 2 side_r, 3 back_l, 4 back_r (the same scheme: side guns first, left before
## right, the back last). Nothing here names a hardpoint: every per-slot array follows the chassis' list, so any count
## works. An empty hardpoint is an empty slot (pressing its number does nothing). Weapons start enabled,
## active equipment (the repair drone) starts deselected, passive equipment is always on.
##   number key      toggle that slot          same number again within DOUBLE_TAP s: solo it (only it enabled)
##                   (passive equipment: nothing; active equipment toggles like a weapon, see EQUIPMENT)
##   left mouse      held: fire every enabled weapon; a fresh press also launches a selected repair drone
## The left button only counts while the mouse is captured (the first click just captures it). The rack never reads the
## right button: that is the chase camera's zoom (test_drive.gd).
## UNUSABLE SLOTS: a weapon whose hardpoint component is destroyed (`slot_disabled`, PlayerTarget.is_slot_destroyed) or
## whose limited ammo is 0 is deselected automatically (enabled false, slot_changed), and its key can't select it again:
## a press or a double tap on it does nothing (soloing another slot still works, and still deselects it). It never fires,
## costs no heat (active or passive), drops out of the guided track, and shows no charge glow. When it becomes usable
## again (ammo refilled; a destroyed hardpoint restored) it stays deselected until its key is pressed. slots(): `usable`
## false, `hold` "DESTROYED" / "EMPTY", `enabled` false.
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
##     in_range: bool     (aim point within the weapon's range, and past its min_range if it has one; the mortar measures along the deck)
##     hold: String       (why the weapon holds fire right now, "" = it doesn't: e.g. the mortar's min range, "OUT OF ARC";
##                        "DESTROYED" = its hardpoint is destroyed, "EMPTY" = out of ammo; those two win; then
##                        "SHUTDOWN" while the mech is in heat shutdown: barrels parked, in_range / on_target false)
##     usable: bool       (false: destroyed or out of ammo, or an empty slot; it can't be selected; see UNUSABLE SLOTS)
##     built: bool        (false: the weapon has no behaviour yet and never fires)
##     muzzle: Vector3    (world space: where this slot's shots leave, the turned barrel's muzzle; for an empty slot
##                        the hardpoint node's position)
##     designating: bool  (an enabled, intact guided weapon on a mech that can act: its missiles track the aim point)
##     on_target: bool    (the barrel points within Combat.ON_TARGET_DEG of the aim point: false while it is still
##                        slewing or parked at its pivot limit; always true for the mortar, false for an empty slot)
##     equipment: bool    (back-mount equipment, docs/design/back-equipment.md: no fire records, no aim; false for
##                        weapons and empty slots)   passive: bool (passive equipment: radiator, ammo bin)
##     active_left: float (s of repair the slot's drone has left, 0 when none is out / it is flying home)
##     hint: String       (a control hint for the HUD; "" for weapons, passives and empty slots. The repair drone:
##                        "PRESS <n>" when usable, deselected and none out; "CLICK TO LAUNCH" when selected and it can
##                        launch now; "" otherwise)
##   For equipment: built true; enabled = selected (active: deselected by default, auto-deselected after each launch and
##   when unusable; passives always true); ammo / ammo_max = drones left / charges (-1 for passives), ready 1 = can
##   launch now (0 while a drone is out, when none are left, or shut down; passives 1), hold "DESTROYED" / "DRONE OUT"
##   (rising, circling or flying home) / "EMPTY" / "PASSIVE" / "", in_range false, blocked false, designating /
##   on_target false, muzzle = the hardpoint node, usable = not destroyed (and, active, a charge left).
##   heat_state() -> {heat: float, cap: float, fraction: float 0..1, shutdown: bool}   (the MechController's gauge)
##   designator_on() -> bool  (the guided track is on, see above)   aim() -> Vector3 (this step's aim point)
##   substitutions() -> Array[String]  paused weapons swapped for the slot default ("LEFT SIDE: Flamer offline, using
##                                     Side Laser"), set by whoever built the loadout (TestDriveCombat); [] when none
##   signal slot_changed(slot: int)   a slot was enabled / disabled
##   signal fired(slot: int)          one shot left that slot (once per fire record: a rocket salvo emits six)
## ----------------------------------------------------------------------------------------------------------------------
##
## EQUIPMENT (back slots only; MechCatalog.is_equipment; the Bulwark carries two, each its own slot, charges and key):
## ACTIVE equipment (the repair drone) is a selectable slot like a
## weapon: its key toggles it, a double tap solos it, soloing another slot deselects it, set_enabled works, and the
## UNUSABLE rule applies (no charges left / hardpoint destroyed). It starts deselected. While it is selected, a FRESH
## trigger press (edge, not hold-repeat) launches the drone if it can (can_launch: a charge left, none of this rack's
## drones out, hardpoint intact, the mech can act): it pays the catalog active_heat, calls CombatWorld.launch_drone
## (CombatNet broadcasts it), and the slot deselects itself, so a held / later trigger never spends the next charge;
## reselect to launch again. activate(n) launches directly regardless of selection (tests / bots). Passives ignore the
## key, stay enabled, and a double tap elsewhere never disables them. Passives apply here: the
## radiator's cooling_bonus heat/s is shed from the mech's gauge each step; the ammo bin's ammo_bonus (+50 %) is added
## to every limited-ammo weapon when the loadout is built (bonus_ammo: rounded up to a whole salvo).
##
## Control (tests / AI): press_slot(n, t = now), set_trigger(bool), set_enabled(n, bool), activate(n), step(dt)
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
var charges: Array[int] = []              ## per slot: launches left of active equipment (-1 = not equipment)
var ammo_max: Array[int] = []             ## per slot: the weapon's full ammo with the ammo bin (-1 = unlimited)
var cooling_bonus := 0.0                  ## heat/s the mounted equipment sheds (radiator)
var drone: RepairDrone                    ## this rack's repair drone while it is out, else null
var _trigger_was := false                 ## the trigger last step (equipment launches on a fresh press)

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

	## Shed `amount` heat (the radiator's extra cooling): never below 0, never triggers an overheat.
	func cool(amount: float) -> void:
		if mech != null and amount > 0.0:
			mech.add_heat(-minf(amount, mech.heat))


func net_fields() -> Dictionary:
	return {"world": Net.LOCAL, "mech": Net.LOCAL, "model": Net.LOCAL, "camera": Net.LOCAL, "shooter": Net.SPAWN,
		"peer": Net.SPAWN, "read_input": Net.LOCAL, "auto_step": Net.LOCAL, "manual_aim": Net.LOCAL,
		"hardpoints": Net.SPAWN, "weapons": Net.SPAWN, "mounts": Net.OWNER, "enabled": Net.OWNER, "blocked": Net.PRIVATE,
		"trigger": Net.OWNER, "aim_point": Net.OWNER, "heat_bridge": Net.LOCAL,
		"slot_disabled": Net.LOCAL,
		"_chassis": Net.LOCAL, "_loadout": Net.LOCAL, "_last_slot": Net.PRIVATE, "_last_press": Net.PRIVATE,
		"_hp_nodes": Net.LOCAL, "_substitutions": Net.LOCAL, "_glows": Net.LOCAL,
		"charges": Net.OWNER, "ammo_max": Net.SPAWN, "cooling_bonus": Net.SPAWN, "drone": Net.LOCAL,
		"_trigger_was": Net.PRIVATE}


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
	charges.clear()
	ammo_max.clear()
	cooling_bonus = 0.0
	var ammo_bonus := 0.0
	for w: Variant in _loadout.values():
		if MechCatalog.is_equipment(str(w)):
			cooling_bonus += float(_stats(str(w)).get("cooling_bonus", 0.0))
			ammo_bonus += float(_stats(str(w)).get("ammo_bonus", 0.0))
	for hp: Dictionary in MechCatalog.chassis(_chassis)["hardpoints"]:
		var id := str(hp["id"])
		var w := str(_loadout.get(id, ""))
		hardpoints.append(id)
		weapons.append(w)
		blocked.append(false)
		_hp_nodes.append(null)
		var mount: WeaponMount = null
		var glow: ChargeGlow = null
		var equip := MechCatalog.is_equipment(w)
		charges.append(int(_stats(w).get("charges", 0)) if equip and _active(w) else -1)
		ammo_max.append(-1)
		if w != "" and not equip:
			mount = WeaponMount.new()
			mount.setup(w, id, shooter, peer, _stats(w))
			mount.set_hardpoint_range(WeaponMount.hardpoint_range(_chassis, id))   # e.g. the Bulwark's yaw_in_max
			mount.ammo = bonus_ammo(mount.ammo, int(mount.stats.get("salvo", 1)), ammo_bonus)
			ammo_max[ammo_max.size() - 1] = mount.ammo
			if mount.behaviour != null:
				mount.behaviour.prewarm(mount.stats)   # its shots' cached meshes now, not on the first shot mid-fight
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
	for i in slot_count():
		if MechCatalog.is_equipment(weapons[i]):
			enabled[i] = not _active(weapons[i])    # passives always on; active equipment starts DESELECTED
	if world != null:
		world.set_anchor(shooter, _anchor)
		# The mech's equipment looks (cradle swap, radiator glow) read this rack's model and gauge.
		world.equipment_look.watch(shooter, _look_model, _look_heat)


func _look_model() -> MechModel:
	return model if model != null and is_instance_valid(model) else null


func _look_heat() -> float:
	return float(heat_state()["fraction"]) if mech != null and is_instance_valid(mech) else 0.0


## Full ammo of a limited-ammo weapon carrying `bonus` extra (the ammo bin's 0.5), rounded UP to a whole salvo of
## `salvo` shots: rockets 36 -> 54, missiles 18 -> 27, mortar 3 -> 5. Unlimited (-1) stays unlimited; bonus 0 = base.
static func bonus_ammo(base: int, salvo: int, bonus: float) -> int:
	if base < 0 or bonus <= 0.0:
		return base
	var per := maxi(salvo, 1)
	return int(ceil(float(base) * (1.0 + bonus) / float(per) - 1e-6)) * per


## The launcher this rack's drone follows on this machine: the mech (its model when there is none).
func _anchor() -> Node3D:
	if mech != null and is_instance_valid(mech):
		return mech
	return model if model != null and is_instance_valid(model) else null


func _active(w: String) -> bool:
	return str(MechCatalog.weapon(w).get("equipment", "")) == "active"


func _is_equipment(i: int) -> bool:
	return i >= 0 and i < weapons.size() and MechCatalog.is_equipment(weapons[i])


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
	if _is_equipment(i) and not _active(weapons[i]):   # passives: the key does nothing, and breaks a pending double tap
		_last_slot = 0
		_last_press = -INF
		return
	if not usable(n):              # destroyed / out of ammo: the key does nothing (no toggle, no solo)
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
	if i < 0 or i >= slot_count() or enabled[i] == on or (_is_equipment(i) and not _active(weapons[i])):   # passives stay on
		return
	if on and weapons[i] != "" and not usable(n):   # a destroyed / dry weapon can't be selected (empty slots: as before)
		return
	enabled[i] = on
	slot_changed.emit(n)


## Slot `n` (1-based) holds a weapon that can fire at all: not an empty slot, its hardpoint not destroyed, ammo left
## (unlimited counts). Equipment: not destroyed and, active, a charge left.
func usable(n: int) -> bool:
	var i := n - 1
	if i < 0 or i >= slot_count() or weapons[i] == "":
		return false
	if _slot_broken(hardpoints[i]):
		return false
	if _is_equipment(i):
		return not _active(weapons[i]) or charges[i] > 0
	var m: WeaponMount = mounts[i]
	return m != null and m.ammo != 0


## Why slot index `i` is unusable for the HUD: "DESTROYED", "EMPTY", or "".
func _unusable_reason(i: int) -> String:
	if _slot_broken(hardpoints[i]):
		return "DESTROYED"
	var m: WeaponMount = mounts[i]
	return "EMPTY" if m != null and m.ammo == 0 else ""


## Use slot `n`'s active equipment now (the repair drone), whether the slot is selected or not (tests / bots; players
## select the slot and pull the trigger): see _launch. Emits slot_changed. False when it can't (passives, weapons, empty
## slots never activate).
func activate(n: int) -> bool:
	if not _launch(n - 1):
		return false
	slot_changed.emit(n)
	return drone != null


## Resupply (the owner, a supply depot's power core): every limited-ammo weapon back to its full ammo (ammo_max, with
## the ammo bin), and active equipment back to its catalog charges. A slot that was EMPTY becomes usable again but stays
## deselected (UNUSABLE SLOTS). Returns the slots refilled.
func refill_ammo() -> int:
	var n := 0
	for i in slot_count():
		var m: WeaponMount = mounts[i]
		if m != null and ammo_max[i] >= 0 and m.ammo != ammo_max[i]:
			m.ammo = ammo_max[i]
			n += 1
		elif _is_equipment(i) and _active(weapons[i]):
			var full := int(_stats(weapons[i]).get("charges", 0))
			if charges[i] != full:
				charges[i] = full
				n += 1
	return n


## Slot index `i`'s active equipment can launch now: a charge left, no drone of this rack out (rising, circling or flying
## home), hardpoint intact, the mech can act.
func can_launch(i: int) -> bool:
	if not _is_equipment(i) or not _active(weapons[i]) or world == null:
		return false
	return charges[i] > 0 and not drone_out() and heat_bridge != null and heat_bridge.can_act() \
		and not _slot_broken(hardpoints[i])


## Launch slot index `i`'s drone: pays the catalog active_heat on the mech's gauge, spends a charge and launches
## (CombatWorld.launch_drone; CombatNet sends it to the crew). No signal.
func _launch(i: int) -> bool:
	if not can_launch(i):
		return false
	var st := _stats(weapons[i])
	heat_bridge.add(float(st.get("active_heat", 0.0)))
	charges[i] -= 1
	drone = world.launch_drone({"shooter": shooter, "peer": peer, "hardpoint": hardpoints[i], "weapon": weapons[i],
		"t": world.now})
	return true


## Extra cooling (heat/s) from intact equipment now: the radiator's cooling_bonus unless its hardpoint is destroyed.
func _cooling_now() -> float:
	if cooling_bonus <= 0.0:
		return 0.0
	var c := 0.0
	for i in slot_count():
		if _is_equipment(i) and not _slot_broken(hardpoints[i]):
			c += float(_stats(weapons[i]).get("cooling_bonus", 0.0))
	return c


## This rack's repair drone is out (launched, not yet docked: rising, circling or flying home).
func drone_out() -> bool:
	if drone != null and (not is_instance_valid(drone) or drone.finished()):
		drone = null
	return drone != null


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
	return m != null and enabled[i] and m.stats.has("designator_heat") and usable(i + 1) and heat_bridge != null \
		and heat_bridge.can_act()


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
	var pull := trigger and not _trigger_was          # a fresh trigger press (equipment launches on the edge only)
	_trigger_was = trigger
	_step_equipment(pull)
	var pf := CombatWorld.profiling                   # bench only (tests/bench_combat_fx.gd): per-phase timers
	var passive := 0.0
	for i in slot_count():
		var m: WeaponMount = mounts[i]
		if m == null:
			continue
		var p0 := Time.get_ticks_usec() if pf else 0
		m.stats = _stats(weapons[i])
		var intact := usable(i + 1)                 # destroyed / dry: deselected, no fire, no heat, no glow
		if not intact and enabled[i]:
			enabled[i] = false
			slot_changed.emit(i + 1)
		if intact:
			passive += float(m.stats.get("passive_heat", 0.0))
		var rest := _rest_muzzle(i)                # the unturned muzzle: the mount derives its pivot from it
		var hp_node := _hp_node(i)
		if hp_node != null:
			m.set_body_basis(hp_node.global_basis)     # fire arcs (§4.4) follow the body's facing
		if str(m.stats.get("kind", "")) == "arc":
			m.frame = MortarShell.frame_at(world, aim_point)   # the mortar's range gate measures along the deck (§3.7)
		var recs := m.update(dt, trigger and enabled[i] and intact, heat_bridge, world.now, rest, aim_point)
		var p1 := Time.get_ticks_usec() if pf else 0
		for rec in recs:
			world.fire(rec)
			fired.emit(i + 1)
		var p2 := Time.get_ticks_usec() if pf else 0
		if m.aim_dir != Vector3.ZERO:
			WeaponPose.apply(hp_node, weapons[i], m.aim_yaw, m.aim_pitch)   # the model turns with its barrel (cosmetic)
		var from := muzzle(i + 1)                  # the turned barrel's muzzle
		var p3 := Time.get_ticks_usec() if pf else 0
		blocked[i] = _blocked(from, m.stats)
		var p4 := Time.get_ticks_usec() if pf else 0
		if _glows[i] != null:
			# No glow while destroyed / dry or shut down (a charge held through the shutdown shows again on reboot).
			(_glows[i] as ChargeGlow).show_charge(from, ChargeGlow.fraction(m) if intact and not m.parked else 0.0, dt)
		if pf:
			var p5 := Time.get_ticks_usec()
			CombatWorld.prof_add("r.update:" + weapons[i], p1 - p0)
			CombatWorld.prof_add("r.fire:" + weapons[i], p2 - p1, recs.size())
			CombatWorld.prof_add("r.pose+muzzle", p3 - p2)
			CombatWorld.prof_add("r.blocked", p4 - p3)
			CombatWorld.prof_add("r.glow", p5 - p4)
	heat_bridge.add(passive * dt)
	var cool := _cooling_now()
	if cool > 0.0:
		heat_bridge.cool(cool * dt)                 # the radiator: extra cooling on the mech's own gauge
	drone_out()                                     # drop the reference once the drone is gone
	world.designators[shooter] = {"on": designator_on(), "dot": aim_point}


## Active equipment slots, each step: an unusable one (no charges, hardpoint destroyed) is deselected; a selected one
## launches on a fresh trigger press when it can (one launch per press), then deselects itself.
func _step_equipment(pull: bool) -> void:
	for i in slot_count():
		if not _is_equipment(i) or not _active(weapons[i]):
			continue
		if enabled[i] and not usable(i + 1):
			enabled[i] = false
			slot_changed.emit(i + 1)
		elif enabled[i] and pull and _launch(i):
			set_enabled(i + 1, false)                   # emits slot_changed once (the HUD and the slot cue)


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
	return node.global_transform * WeaponPose.rest_offset(weapons[i], float(st.get("muzzle", 0.0)))


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
## not colliders, so the camera's own ray goes through them). Teammates never pull it in, friendly fire or not (a query:
## the mortar and the missiles' track keep aiming past a teammate at what is behind).
func _camera_aim() -> Vector3:
	if camera == null or not camera.is_inside_tree():
		return aim_point
	var p := camera.aim_point()
	var h := world.first_hit(camera.global_position, p, 0.0, shooter, [], true)
	return h["point"] if not h.is_empty() else p


func _slot_broken(hp_id: String) -> bool:
	return slot_disabled.is_valid() and bool(slot_disabled.call(hp_id))


# --- HUD state ---------------------------------------------------------------------------------------------

func slots() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var down := heat_bridge != null and not heat_bridge.can_act()    # shut down: parked, no range / on-target / track
	for i in slot_count():
		var w := weapons[i]
		if _is_equipment(i):
			out.append(_equipment_slot(i))
			continue
		var m: WeaponMount = mounts[i]
		var st: Dictionary = m.stats if m != null else {}
		var broken := _slot_broken(hardpoints[i])
		var d := {"slot": i + 1, "hardpoint": hardpoints[i], "weapon": w, "name": str(st.get("name", "")),
			"enabled": enabled[i] and usable(i + 1), "ammo": m.ammo if m != null else -1, "ammo_max": ammo_max[i] if m != null else -1,
			"ready": 0.0 if broken else _ready_of(m), "reloading": not broken and _reloading(m),
			"heat_per_shot": float(st.get("active_heat", 0.0)), "blocked": blocked[i], "in_range": not down and _in_range(i, st),
			"hold": _unusable_reason(i) if not usable(i + 1) and m != null else (Combat.SHUTDOWN if down and m != null
				else (m.hold_reason if m != null else "")),
			"built": m != null and m.built(), "muzzle": muzzle(i + 1),
			"designating": _guiding(i), "on_target": not down and m != null and m.on_target(),
			"equipment": false, "passive": false, "active_left": 0.0, "usable": usable(i + 1), "hint": ""}
		out.append(d)
	return out


## The HUD row of an equipment slot (see the contract above).
func _equipment_slot(i: int) -> Dictionary:
	var w := weapons[i]
	var st := _stats(w)
	var broken := _slot_broken(hardpoints[i])
	var active := _active(w)
	var out_now := active and drone_out()
	var can := can_launch(i)
	var sel: bool = (enabled[i] and usable(i + 1)) if active else true
	var hint := ""
	if active and usable(i + 1) and not out_now:
		if not sel:
			hint = "PRESS %d" % (i + 1)
		elif can:
			hint = "CLICK TO LAUNCH"
	var hold := ""
	if broken:
		hold = "DESTROYED"
	elif not active:
		hold = "PASSIVE"
	elif out_now:
		hold = "DRONE OUT"
	elif charges[i] <= 0:
		hold = "EMPTY"
	return {"slot": i + 1, "hardpoint": hardpoints[i], "weapon": w, "name": str(st.get("name", w)), "enabled": sel,
		"ammo": charges[i] if active else -1, "ammo_max": int(st.get("charges", -1)) if active else -1,
		"ready": (1.0 if can else 0.0) if active else (0.0 if broken else 1.0), "reloading": false,
		"heat_per_shot": float(st.get("active_heat", 0.0)), "blocked": false, "in_range": false, "hold": hold,
		"built": true, "muzzle": muzzle(i + 1), "designating": false, "on_target": false,
		"equipment": true, "passive": not active, "active_left": drone.time_left() if out_now else 0.0,
		"usable": usable(i + 1), "hint": hint}


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
	if str(st.get("kind", "")) == "arc":     # the mortar: the along-the-deck distance its range gate uses (Mortar.range_problem)
		d = MortarShell.deck_distance(MortarShell.frame_at(world, aim_point), muzzle(i + 1), aim_point)
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
