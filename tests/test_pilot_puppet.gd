extends TestCase
## PilotPuppetLink (scripts/pilot/pilot_puppet_link.gd): a teammate's pilot head on this machine reacts to the puppet's
## streamed state and to the shots seen here, cosmetically. A real puppet (MechSpawn mech + MechPuppet, owned by peer 2,
## its PlayerTarget owned by peer 2: this offline machine is peer 1, so it never decides hits on it), fed by hand with
## NetMechStates through MechPuppet.apply (no session); the real MechRig feeds the head. Checks: the head and accent come
## from make(); the rig feeds it and idle runs; heat -> strained / overheated (red flush), shutdown -> dazed, reboot ->
## revived; thrusting -> effort; an enemy shot striking the puppet (impact only, no damage here) flinches away from its
## side then looks toward it, a far impact does not; a damage event still flinches; a fire record of this teammate ->
## focused + looks at MechPuppet.aim_point, then clears, another shooter's record does nothing; the designator -> aiming;
## streamed HP (NetMechState.comp): low torso / head -> afraid, a part falling to 0 -> pain (once, not on rebind);
## streamed disabled -> dazed, its end -> revived; unbind disconnects.

var world: CombatWorld
var mech: MechController
var pp: MechPuppet
var link: PilotPuppetLink
var st := NetMechState.new()


func setup() -> void:
	timeout_sec = 90.0
	world = CombatWorld.new()
	world.use_physics = false
	add_child(world)
	mech = MechSpawn.make("pickle", "strider", {}, 2, "red")
	add_child(mech)
	await frames(1)
	pp = MechPuppet.new()
	pp.name = "Puppet"
	pp.bind(mech, 2)
	mech.add_child(pp)
	var pt := PlayerTarget.new()
	pt.auto_respawn_delay = -1.0
	add_child(pt)
	pt.bind(world, mech, pp.rig.model, "player2", 2)
	world.register(pt)
	pp.target = pt
	link = PilotPuppetLink.new()
	link.name = "PilotLink"
	mech.add_child(link)
	link.bind_puppet(pp, world)
	st.pos = Vector3.ZERO
	st.yaw = PI                        # facing -Z (no ring: yaw 0 is +Z), so -X is the mech's left
	st.grounded = true
	_apply()
	var h := link.pilot()
	if not check(h != null, "the link finds the puppet's pilot head"):
		finish()
		return
	eq(h.head_id, "pickle", "the puppet's head is the one it was made with")
	eq(MechAccent.applied(pp.rig.model), "red", "and its accent")
	await _phys(20)
	check(not h.idle_always and Engine.get_process_frames() - h._fed_frame <= 2, "MechRig feeds the puppet's head")
	var t0 := h.elapsed()
	await _phys(10)
	check(h.elapsed() > t0 and h.idle_enabled, "the head runs (idle on)")
	h.idle_enabled = false             # exact poses below
	await _heat()
	await _hits()
	await _firing()
	await _damage()
	await _stream()
	await _disabled()
	_unbind()
	finish()


## Push `st` into the puppet as a snapshot would, and keep its PlayerTarget on it (MechPuppet does both with a session).
func _apply() -> void:
	pp.apply(st)
	pp.shown = st
	pp.target.global_transform = mech.global_transform
	pp.target.up = mech.up()


func _phys(n: int) -> void:
	for i in n:
		_apply()
		await get_tree().physics_frame


func _yaw() -> float:
	return link.pilot().neck.total().y


func _heat() -> void:
	var h := link.pilot()
	st.heat = 0.75
	await _phys(3)
	eq(h.mood(), "strained", "streamed heat 0.75 -> strained")
	st.heat = 0.95
	await _phys(40)
	eq(h.mood(), "overheated", "heat 0.95 -> overheated")
	check(h.face._flush > 0.5, "with the red flush (%.2f)" % h.face._flush)
	st.shutdown = true
	await _phys(3)
	eq(h.mood(), "dazed", "streamed shutdown -> dazed")
	st.shutdown = false
	st.heat = 0.0
	await _phys(1)
	check(h.reacting("revived"), "shutdown ends (reboot) -> revived")
	await _phys(3)
	eq(h.mood(), "stern", "cool again -> stern")
	st.thrusting = true
	await _phys(2)
	check(h.reacting("effort"), "streamed thrusting -> effort")
	st.thrusting = false
	await _phys(120)


func _enemy_shot(from: Vector3, to: Vector3, i: int) -> Dictionary:
	var r := Combat.fire_record("enemy_t", 1, "gun", "laser", from, to, world.now, i)
	r["team"] = "enemy"
	r["enemy"] = true
	return r


func _hits() -> void:
	var h := link.pilot()
	var torso := mech.global_position + Vector3(0.0, 4.4, 0.0)
	var impacts := [0]
	world.impact_spawned.connect(func(_p: Vector3, _r: float, _e: bool, _en: bool) -> void: impacts[0] += 1)
	world.fire(_enemy_shot(torso + Vector3(-40.0, 0.0, 0.0), torso, 1))
	check(impacts[0] == 1, "(the enemy laser struck the puppet: one impact)")
	check(h.reacting("flinch"), "a shot seen striking the puppet flinches its head")
	near(float(pp.target.hp["torso"]), 400.0, 1e-3, "and does no damage here (its owner decides)")
	var away := 0.0
	for i in 6:
		await _phys(1)
		away = minf(away, _yaw())
	check(away < -deg_to_rad(3.0), "the flinch turns away from the left side (yaw %.1f deg)" % rad_to_deg(away))
	var toward := 0.0
	for i in 30:
		await _phys(1)
		toward = maxf(toward, _yaw())
	check(toward > deg_to_rad(20.0), "then it looks left, toward the shot (yaw %.1f deg)" % rad_to_deg(toward))
	await _phys(150)
	check(not h.reacting("flinch"), "(the flinch is over)")
	world.spawn_impact(mech.global_position + Vector3(30.0, 1.0, 0.0), Vector3.UP, 2.0)
	check(not h.reacting("flinch"), "an impact 30 m away does not flinch")
	world.spawn_impact(mech.global_position + Vector3(0.0, 1.0, -6.0), Vector3.UP, 6.0, LowPolyPalette.GREY, true)
	check(h.reacting("flinch"), "a blast a few metres away does")
	await _phys(150)
	pp.target.apply_damage(80.0, "torso", "enemy_t")
	check(h.reacting("flinch") and h.reacting("pain"), "a damage event on the puppet target (20 % torso) flinches and hurts")
	pp.target.repair_all()
	await _phys(150)


func _firing() -> void:
	var h := link.pilot()
	st.aim = h.global_transform * Vector3(30.0, 0.85, -10.0)   # to the head's right (streamed aim)
	_apply()
	var muzzle := mech.global_position + Vector3(2.8, 4.2, -2.0)
	world.fire(Combat.fire_record("player3", 3, "side_l", "laser", muzzle, pp.aim_point, world.now, 1))
	await _phys(2)
	check(not bool(h._in["firing"]), "another teammate's shot does not make this head fire")
	world.fire(Combat.fire_record("player2", 2, "side_l", "laser", muzzle, pp.aim_point, world.now, 1))
	await _phys(2)
	check(bool(h._in["firing"]), "this teammate's fire record -> firing")
	eq(h.mood(), "focused", "-> focused")
	check(h._look_on and h._look_point.is_equal_approx(pp.aim_point), "looking at the streamed aim point")
	await _phys(40)
	check(_yaw() < -deg_to_rad(15.0), "the head turns right, toward it (yaw %.1f deg)" % rad_to_deg(_yaw()))
	check(not bool(h._in["firing"]), "firing ends a moment after the shot")
	check(h._look_on, "the look holds a while")
	await _phys(80)
	check(not h._look_on, "then clears")
	st.designator = true
	await _phys(2)
	check(bool(h._in["aiming"]) and h._look_on, "the streamed designator -> aiming and looking")
	st.designator = false
	await _phys(2)
	check(not h._look_on, "designator off -> the look clears")
	await _phys(60)


## Component fractions in NetMechCodec.COMPONENTS order, as CrewSync streams them: `over` {name: fraction}, the rest full,
## -1 for hardpoints this mech has no weapon on.
func _comp(over: Dictionary = {}) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for c: String in NetMechCodec.COMPONENTS:
		out.append(float(over.get(c, 1.0)) if pp.target.max_hp.has(c) else -1.0)
	return out


## HP arrives in the stream now (MechPuppet mirrors it onto the puppet target): low torso / head -> afraid; a part
## falling to 0 -> pain (detected by the link: hp is written directly, so player_component_destroyed never fires here).
func _damage() -> void:
	var h := link.pilot()
	var lost := [0]
	var on_lost := func(_c: String) -> void: lost[0] += 1
	pp.target.player_component_destroyed.connect(on_lost)
	st.comp = _comp()
	await _phys(3)
	eq(h.mood(), "stern", "full streamed HP -> stern")
	st.comp = _comp({"torso": 0.2})
	await _phys(3)
	near(float(pp.target.hp["torso"]), 80.0, 1.0, "(the streamed torso fraction reaches the puppet target)")
	near(link.fear_hp(), 0.2, 0.01, "fear_hp reads it")
	eq(h.mood(), "afraid", "streamed torso 20 % -> afraid")
	st.comp = _comp({"head": 0.1})
	await _phys(3)
	eq(h.mood(), "afraid", "streamed head 10 % -> afraid")
	st.comp = _comp({"leg_l": 0.1, "side_l": 0.5})
	await _phys(3)
	eq(h.mood(), "stern", "a low leg or arm alone is not fear")
	await _phys(150)
	check(not h.reacting("pain"), "(no pain yet)")
	var arm := "side_l" if pp.target.max_hp.has("side_l") else "leg_l"
	st.comp = _comp({arm: 0.0})
	await _phys(1)
	check(h.reacting("pain"), "a streamed %s fraction falling to 0 -> pain" % arm)
	eq(lost[0], 0, "(player_component_destroyed does not fire on a puppet target: the link detects the loss itself)")
	await _phys(150)
	check(not h.reacting("pain"), "(the pain is over)")
	await _phys(5)
	check(not h.reacting("pain"), "a part that stays at 0 does not hurt again")
	pp.target.player_component_destroyed.disconnect(on_lost)
	# A part already at 0 when the link binds (a late joiner, a rebind) is not a fresh loss.
	link.unbind()
	link.bind_puppet(pp, world)
	h = link.pilot()
	await _phys(150)
	check(not h.reacting("pain"), "rebinding with a part already at 0 -> no pain")
	st.comp = _comp()
	await _phys(3)


## The running flinch's strength (react_hit: 0.35 + amount * 4), -1 when none.
func _flinch_s(h: PilotHead) -> float:
	for r: Dictionary in h._reactions:
		if r["id"] == "flinch":
			return float(r["s"])
	return -1.0


## Streamed HP drops are the real hit signal (hits on player mechs never cross the wire): a drop with no impact seen
## flinches with the real amount toward the struck side; an impact then its drop flinches once (pain from the real
## amount); a repair, the first frame after bind and a component first seen do nothing; a burn trickle is rate-limited.
func _stream() -> void:
	st.comp = _comp()
	await _phys(150)
	# First frame after bind: the fractions are a baseline, not a drop.
	link.unbind()
	st.comp = _comp({"torso": 0.6})
	_apply()
	link.bind_puppet(pp, world)
	var h := link.pilot()
	var n := link.flinches
	await _phys(3)
	eq(link.flinches, n, "binding with torso at 60 % -> no flinch (a baseline, not a drop)")
	check(not h.reacting("flinch"), "(no flinch running)")
	st.comp = _comp()
	await _phys(3)
	eq(link.flinches, n, "a repair (fractions rising) -> nothing")
	check(not h.reacting("flinch") and not h.reacting("pain"), "(no flinch, no pain)")
	# A drop with no impact seen here (an enemy shot simulated only on the host).
	st.comp = _comp({"torso": 0.9})
	await _phys(1)
	eq(link.flinches, n + 1, "a streamed torso drop of 10 %, no impact seen -> one flinch")
	near(_flinch_s(h), 0.35 + 0.1 * 4.0, 0.03, "with the real amount (strength %.2f)" % _flinch_s(h))
	check(not h.reacting("pain"), "10 % is below pain")
	await _phys(3)
	eq(link.flinches, n + 1, "and only once")
	await _phys(150)
	# Toward the struck side: a left leg drop looks left.
	st.comp = _comp({"torso": 0.9, "leg_l": 0.7})
	var toward := 0.0
	for i in 40:
		await _phys(1)
		toward = maxf(toward, _yaw())
	eq(link.flinches, n + 2, "a left leg drop -> a flinch")
	check(toward > deg_to_rad(10.0), "that looks left, toward the struck leg (yaw %.1f deg)" % rad_to_deg(toward))
	await _phys(150)
	# An impact seen here, then its HP drop a snapshot later: one flinch, the pain of the real amount.
	n = link.flinches
	var torso := mech.global_position + Vector3(0.0, 4.4, 0.0)
	world.fire(_enemy_shot(torso + Vector3(-40.0, 0.0, 0.0), torso, 7))
	eq(link.flinches, n + 1, "(the impact flinches)")
	check(not h.reacting("pain"), "(an impact alone does not hurt)")
	await _phys(10)
	st.comp = _comp({"torso": 0.6, "leg_l": 0.7})
	await _phys(1)
	eq(link.flinches, n + 1, "its 30 %% HP drop 10 frames later -> no second flinch (window %.2f s)" % link._dedupe_window())
	check(h.reacting("pain"), "but the pain of the real 30 %")
	await _phys(150)
	st.comp = _comp()
	await _phys(3)
	# Burn: many tiny drops (one 1/255 step per frame) pool into a bounded number of flinches.
	n = link.flinches
	var frac := 1.0
	var frames_n := 120
	for i in frames_n:
		frac -= 1.0 / 255.0
		st.comp = _comp({"torso": frac})
		await _phys(1)
	var burn := link.flinches - n
	var cap := ceili(float(frames_n) / Engine.physics_ticks_per_second / PilotPuppetLink.STREAM_GAP) + 1
	check(burn >= 1 and burn <= cap, "a burn trickle over %d frames -> %d flinches (1..%d), not one per frame" \
		% [frames_n, burn, cap])
	st.comp = _comp()
	await _phys(150)


## Downed arrives in the stream (NetMechState.disabled), mirrored onto the puppet target by MechPuppet.
func _disabled() -> void:
	var h := link.pilot()
	st.comp = _comp({"leg_r": 0.0})
	st.disabled = true
	st.disable_cause = "leg_r"
	await _phys(30)
	check(pp.target.disabled and pp.downed, "(the streamed downed flag reaches the puppet target)")
	eq(h.mood(), "dazed", "streamed disabled -> dazed")
	st.comp = _comp()
	st.disabled = false
	st.disable_cause = ""
	await _phys(1)
	check(h.reacting("revived"), "streamed disabled ends (revive / repair) -> revived")
	await _phys(3)
	eq(h.mood(), "stern", "whole again -> stern")


func _unbind() -> void:
	var h := link.pilot()
	link.unbind()
	check(not world.fired.is_connected(link._on_world_fired), "unbind disconnects fired")
	check(not world.impact_spawned.is_connected(link._on_impact), "and impacts")
	check(not world.remote_hit.is_connected(link._on_remote_hit), "and remote hits")
	check(h.inputs().is_empty() and not h._look_on, "and hands the head back clean")
