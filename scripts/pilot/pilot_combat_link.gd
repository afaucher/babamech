class_name PilotCombatLink
extends Node
## Feeds a mech's combat state into its pilot head (docs/design/pilot-heads.md §3.2, §7), cosmetically. It only READS
## gameplay objects (getters and signals) and only writes the head; nothing here changes combat, and gameplay never reads it.
##
##   var link := PilotCombatLink.new()
##   add_child(link)
##   link.bind(rig_or_model, controller, rack, player_target, world)    # every argument optional / null-safe
##
## Every physics frame it resolves the CURRENT `model.pilot` (MechModel makes a new head on configure() / rebuild(); a new
## head gets the state at once) and sets sticky inputs (PilotHead.set_inputs), which MechRig's own feed then merges:
##   heat      MechController.heat / heat_cap              shutdown  MechController.shutdown
##   hp        min(torso, head) of PlayerTarget.component_fractions(): the parts whose loss reads as "about to die"
##             (legs and weapon hardpoints are left out: a lost leg disables the mech, which is already Dazed)
##   disabled  PlayerTarget.disabled                        effort    MechController.thrusting (ORed with the rig's)
##   firing    WeaponRack.trigger held, or a `fired` shot in the last FIRING_HOLD s
##   aiming    firing, or the chase camera zoomed (WeaponRack.camera.zoomed)
## Look: while firing / aiming and LOOK_HOLD s after the last shot, look_at_point(WeaponRack.aim_point); else clear_look.
## Events (signals, connected in bind, disconnected in unbind / on exit):
##   PlayerTarget.damaged(amount, component, src)  -> react_hit(direction to src's position in the head frame, amount /
##                                                    that component's max HP); src found in CombatWorld.targets by
##                                                    target_id, straight ahead when unknown
##   PlayerTarget.player_component_destroyed       -> react("pain", 1)
##   MechController.rebooted, PlayerTarget.disabled true -> false (respawn / repair) -> react("revived")
##   CombatWorld.hit_landed(target, hit) with hit.shooter = this player and the target newly destroyed -> react("smirk")
## Local only: a remote player's puppet has none of these signals (its hp / disabled are written straight from the stream);
## PilotPuppetLink is its twin (see pilot-heads.md §7).

const FIRING_HOLD := 0.4
const LOOK_HOLD := 1.5
## The components whose HP drives fear (Afraid below PilotHead.HP_AFRAID).
const FEAR_COMPONENTS: Array[String] = ["torso", "head"]

var model_source: Node = null          ## a MechRig or a MechModel (the head lives at model.pilot)
var mech: MechController = null
var rack: WeaponRack = null
var target: PlayerTarget = null
var world: CombatWorld = null
var _head: PilotHead = null
var _since_shot := INF
var _looking := false
var _was_disabled := false
var _credited := {}                    ## instance ids of targets whose kill already smirked


func net_fields() -> Dictionary:
	return {"model_source": Net.LOCAL, "mech": Net.LOCAL, "rack": Net.LOCAL, "target": Net.LOCAL, "world": Net.LOCAL,
		"_head": Net.LOCAL, "_since_shot": Net.LOCAL, "_looking": Net.LOCAL, "_was_disabled": Net.LOCAL,
		"_credited": Net.LOCAL}


func bind(model_or_rig: Node = null, controller: MechController = null, weapon_rack: WeaponRack = null,
		player_target: PlayerTarget = null, combat_world: CombatWorld = null) -> void:
	unbind()
	model_source = model_or_rig
	mech = controller
	rack = weapon_rack
	target = player_target
	world = combat_world
	_since_shot = INF
	_was_disabled = target != null and target.disabled
	_connect(mech, "rebooted", _on_rebooted)
	_connect(rack, "fired", _on_fired)
	_connect(target, "damaged", _on_damaged)
	_connect(target, "player_component_destroyed", _on_component_destroyed)
	_connect(world, "hit_landed", _on_hit_landed)
	sync()


## Disconnects everything and hands the head back clean (no sticky inputs, no look).
func unbind() -> void:
	_disconnect(mech, "rebooted", _on_rebooted)
	_disconnect(rack, "fired", _on_fired)
	_disconnect(target, "damaged", _on_damaged)
	_disconnect(target, "player_component_destroyed", _on_component_destroyed)
	_disconnect(world, "hit_landed", _on_hit_landed)
	var h := _current_head()
	if h != null:
		h.clear_inputs()
		h.clear_look()
	model_source = null
	mech = null
	rack = null
	target = null
	world = null
	_head = null
	_looking = false
	_credited.clear()


func _exit_tree() -> void:
	unbind()


func _physics_process(delta: float) -> void:
	if is_finite(delta) and delta > 0.0:
		_since_shot += delta
	sync()


## The head in the cockpit now (null when none: placeholder art, nothing bound, or freed).
func pilot() -> PilotHead:
	return _current_head()


## Pushes the current state into the current head (every physics frame; tests call it directly).
func sync() -> void:
	var h := _current_head()
	if h != _head:
		_head = h
		_looking = false
	var disabled := target != null and is_instance_valid(target) and target.disabled
	if _was_disabled and not disabled and h != null:
		h.react("revived")
	_was_disabled = disabled
	if h == null:
		return
	var in_ := {"hp": fear_hp(), "disabled": disabled}
	var m := _valid(mech) as MechController
	if m != null:
		in_["heat"] = clampf(m.heat / maxf(m.heat_cap, 0.001), 0.0, 1.0)
		in_["shutdown"] = m.shutdown
		in_["effort"] = m.thrusting
	var r := _valid(rack) as WeaponRack
	var firing := _since_shot < FIRING_HOLD or (r != null and r.trigger)
	var zoomed := r != null and r.camera != null and is_instance_valid(r.camera) and r.camera.zoomed
	in_["firing"] = firing
	in_["aiming"] = firing or zoomed
	h.set_inputs(in_)
	var look := r != null and (firing or zoomed or _since_shot < LOOK_HOLD) and r.aim_point.is_finite()
	if look:
		h.look_at_point(r.aim_point)
		_looking = true
	elif _looking:
		h.clear_look()
		_looking = false


## min over FEAR_COMPONENTS of the PlayerTarget's component fractions (1 without a target).
func fear_hp() -> float:
	var t := _valid(target) as PlayerTarget
	if t == null:
		return 1.0
	var f := t.component_fractions()
	var out := 1.0
	for c: String in FEAR_COMPONENTS:
		if f.has(c):
			out = minf(out, float(f[c]))
	return out


func _current_head() -> PilotHead:
	var src := _valid(model_source)
	if src == null:
		return null
	var model: MechModel = (src as MechRig).model if src is MechRig else src as MechModel
	if model == null or not is_instance_valid(model):
		return null
	var h := model.pilot
	return h if h != null and is_instance_valid(h) and not h.is_queued_for_deletion() else null


## Untyped on purpose: a freed object passed to an Object-typed parameter is a script error.
func _valid(o: Variant) -> Object:
	return o if is_instance_valid(o) else null


func _connect(o: Variant, sig: String, c: Callable) -> void:
	if is_instance_valid(o) and o.has_signal(sig) and not o.is_connected(sig, c):
		o.connect(sig, c)


func _disconnect(o: Variant, sig: String, c: Callable) -> void:
	if is_instance_valid(o) and o.has_signal(sig) and o.is_connected(sig, c):
		o.disconnect(sig, c)


# --- Events ------------------------------------------------------------------------------------------------

func _on_fired(_slot: int) -> void:
	_since_shot = 0.0


func _on_rebooted() -> void:
	var h := _current_head()
	if h != null:
		h.react("revived")


func _on_component_destroyed(_component: String) -> void:
	var h := _current_head()
	if h != null:
		h.react("pain", 1.0)


func _on_damaged(amount: float, component: String, src: String) -> void:
	var h := _current_head()
	if h == null:
		return
	var cap := 0.0
	var t := _valid(target) as PlayerTarget
	if t != null:
		cap = float(t.max_hp.get(component, 0.0))
	var frac := amount / cap if cap > 0.0 else 0.0
	h.react_hit(_dir_to(src, h), frac)


## The direction from the head toward the damage source, in the head's frame (straight ahead, -Z, when unknown).
func _dir_to(src: String, h: PilotHead) -> Vector3:
	var ahead := Vector3(0.0, 0.0, -1.0)
	var w := _valid(world) as CombatWorld
	if w == null or src == "" or not h.is_inside_tree():
		return ahead
	for t in w.targets:
		if t == null or not is_instance_valid(t) or t.target_id != src or not t.is_inside_tree():
			continue
		var from := h.global_position
		var to := t.global_position + t.up * t.probe_height
		var d := h.global_basis.orthonormalized().inverse() * (to - from)
		return d.normalized() if d.length_squared() > 1e-6 else ahead
	return ahead


func _on_hit_landed(hit_target: CombatTarget, hit: Hit) -> void:
	if hit_target == null or hit == null or not is_instance_valid(hit_target) or hit_target == target:
		return
	var me := ""
	if rack != null and is_instance_valid(rack):
		me = rack.shooter
	elif target != null and is_instance_valid(target):
		me = target.target_id
	if me == "" or hit.shooter != me or not hit_target.destroyed():
		return
	var id := hit_target.get_instance_id()
	if _credited.has(id):
		return
	_credited[id] = true
	var h := _current_head()
	if h != null:
		h.react("smirk")
