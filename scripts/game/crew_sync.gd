class_name CrewSync
extends Node
## The test drive's side of mech snapshots (co-op step 2, docs/networking.md "Mech snapshots"). Built by TestDrive in a
## crew mission, child "CrewSync":
##   - feeds the local mech's state to Session.mechs every physics frame (after the rig posed it), which streams it;
##   - makes every other crew mech a puppet (MechPuppet, child "Puppet" of that mech) shown from its owner's snapshots;
##   - registers each puppet as a PlayerTarget with its owner's peer (so weapons and enemies see it; hits on it are its
##     owner's to decide, co-op step 3), carried along by its MechPuppet;
##   - answers the crew panel (hud.crew_panel.status_source): a teammate's hull HP, heat, overheat and downed state from
##     its snapshots.
##   - HANGAR BOTS (docs/design/hangar-bots.md): on the host, each bot's body (TestDrive.crew_bots, CrewBot) is streamed
##     like the local mech (Session.mechs.feed_owned); elsewhere a bot is a puppet like any teammate (its PlayerTarget's
##     owner is the host, PlayerTarget.bind clamps the negative pilot id to 1).
##   - LEAVERS (Session.peer_left, every machine): retire(peer) takes the leaver's mech out of the mission here: its
##     PlayerTarget leaves CombatWorld (enemies, weapons and bots stop seeing it), its puppet, pilot link and mech are
##     freed (TestDrive.drop_mech: also out of `mechs`, the life pushers and viewers). A member already gone when the
##     mission is set up (left while loading) is retired at setup. Crew lists (TestDrive.crew_members, DownedCrew, the
##     mission facts) already skip non-members; the HUD crew panel follows the roster.
## Nothing here touches the wire: it only asks Session (begin / feed / pose / end).

var drive: TestDrive
var puppets: Dictionary = {}        ## owner peer -> MechPuppet
var targets: Dictionary = {}        ## owner peer -> PlayerTarget (the puppets')

var retired: Array[int] = []       ## pilot ids whose mechs were retired here (left mid-mission; tests, diagnostics)

var _last_pos := Vector3.INF
var _bot_last: Dictionary = {}      ## host: bot pilot id -> its mech's position at the last feed


## Authority (scripts/net/net.gd): scene wiring on this machine; the state it moves is declared by the mechs.
func net_fields() -> Dictionary:
	return {"drive": Net.LOCAL, "puppets": Net.LOCAL, "targets": Net.LOCAL, "retired": Net.LOCAL, "_last_pos": Net.LOCAL,
		"_bot_last": Net.LOCAL}


func _ready() -> void:
	process_physics_priority = 20   # after the local mech moved (0) and its rig posed it (10)


## `seats`: owner peer -> crew seat for every mech of the mission (the local one too).
func setup(td: TestDrive, seats: Dictionary) -> void:
	drive = td
	var sess := Net.session()
	var local := sess.local_id() if sess != null else 0
	for p: int in td.mechs:
		var m: MechController = td.mechs[p]
		if m == td.mech or td.crew_bots.has(p):
			continue
		var pp := MechPuppet.new()
		pp.name = "Puppet"
		pp.bind(m, p)
		m.add_child(pp)
		puppets[p] = pp
		if td.combat != null and td.combat.world != null:
			var pt := PlayerTarget.new()
			pt.name = "PlayerTarget_p%d" % p
			pt.auto_respawn_delay = -1.0   # its owner revives / respawns it (a puppet's target is never ticked here)
			td.combat.add_child(pt)
			pt.bind(td.combat.world, m, MechSpawn.rig_of(m).model, "player%d" % p, p)
			td.combat.world.register(pt)
			pp.target = pt
			targets[p] = pt
		# Cosmetic: the teammate's pilot head reacts to its streamed state and the shots seen here (scripts/pilot/).
		var pl := PilotPuppetLink.new()
		pl.name = "PilotLink"
		m.add_child(pl)
		pl.bind_puppet(pp, td.combat.world if td.combat != null else null)
	if sess != null and sess.mechs != null:
		sess.mechs.begin(local, seats, td.crew_bots.keys())
	if sess != null and sess.online():
		if not sess.peer_left.is_connected(retire):
			sess.peer_left.connect(retire)
		# Left while the mission loaded: a player of the LAUNCH crew no longer in the roster (never a bot, never a mech
		# the launch didn't list, e.g. tests/test_perf_coop.gd's synthetic puppets).
		var launched := {}
		for e: Variant in sess.mission_params().get("crew", []) as Array:
			launched[int((e as Dictionary).get("peer", 0))] = true
		for p: int in puppets.keys():
			if launched.has(p) and not NetSession.is_bot_id(p) and not sess.has_member(p):
				retire(p)


## A crew member left (Session.peer_left): take its mech out of the mission on this machine. Its PlayerTarget leaves
## CombatWorld first (nothing targets or hits it from now on), then its nodes go. Its owner decided its HP, downed and
## revive state, and that owner is gone: nothing is handed over (the mission facts count the members still here).
func retire(peer: int) -> void:
	if drive == null or peer == MechSpawn.owner_of(drive.mech) or drive.crew_bots.has(peer) or NetSession.is_bot_id(peer):
		return   # never this machine's own mech, and never a hangar bot (bots leave with the host's session, not alone)
	if not puppets.has(peer) and not targets.has(peer):
		return
	var pt := targets.get(peer) as PlayerTarget
	targets.erase(peer)
	var w: CombatWorld = drive.combat.world if drive.combat != null else null
	if pt != null and is_instance_valid(pt):
		if w != null:
			w.unregister(pt)
		pt.queue_free()
	if w != null:
		# CombatNet's live hooks for this shooter bind the puppet and its model: drop them before those nodes go.
		var key := "player%d" % peer
		w.set_anchor(key, Callable())
		w.designators.erase(key)
		for k: String in w.muzzles.keys():
			if k.begins_with(key + "/"):
				w.muzzles.erase(k)
	var pp := puppets.get(peer) as MechPuppet
	puppets.erase(peer)
	if pp != null and is_instance_valid(pp):
		pp.target = null
	var sess := Net.session()
	if sess != null and sess.mechs != null:
		sess.mechs.drop(peer)
	drive.drop_mech(peer)
	retired.append(peer)
	drive.member_retired(peer)   # host: TestDrive.crew_member_left + MissionFlow.on_member_retired (crew_members() is clean now)
	FlowLog.say("crew mech retired", "pilot %d left: mech and target removed" % peer)


func _exit_tree() -> void:
	var sess := Net.session()
	if sess != null and sess.peer_left.is_connected(retire):
		sess.peer_left.disconnect(retire)
	if sess != null and sess.mechs != null:
		sess.mechs.end()


func _physics_process(delta: float) -> void:
	var sess := Net.session()
	if drive == null or drive.mech == null or sess == null or sess.mechs == null or not sess.mechs.active:
		return
	var pp0 := Time.get_ticks_usec() if PerfProbe.on else 0   # bench instrumentation (tests/bench_bot_perf.gd)
	sess.mechs.feed(sample(delta), delta)
	var pp1 := Time.get_ticks_usec() if PerfProbe.on else 0
	for id: int in drive.crew_bots:
		var cb := drive.crew_bots[id] as CrewBot
		if cb == null or not is_instance_valid(cb) or cb.mech == null:
			continue
		var st := sample_mech(cb.mech, cb.rig, cb.rack, cb.target, _bot_last.get(id, Vector3.INF), delta)
		_bot_last[id] = st.pos
		sess.mechs.feed_owned(id, st, delta)
	if PerfProbe.on:
		PerfProbe.add("net.sample.local", pp1 - pp0)
		PerfProbe.add("net.sample.bots", Time.get_ticks_usec() - pp1)


## The local mech's state now (velocity from its motion over the last physics frame, so it matches the positions the
## puppets interpolate between).
func sample(delta: float) -> NetMechState:
	var st := sample_mech(drive.mech, drive.rig, drive.combat.rack if drive.combat != null else null,
		drive.combat.player_target if drive.combat != null else null, _last_pos, delta)
	_last_pos = st.pos
	return st


## A mech's snapshot state: `last_pos` is its position at the previous feed (velocity from the motion over `delta`).
static func sample_mech(m: MechController, rig: MechRig, rack: WeaponRack, pt: PlayerTarget, last_pos: Vector3,
		delta: float) -> NetMechState:
	var st := NetMechState.new()
	st.pos = m.global_position
	st.vel = m.velocity
	if last_pos != Vector3.INF and delta > 0.0 and st.pos.distance_to(last_pos) < NetMechStream.TELEPORT_DIST:
		st.vel = (st.pos - last_pos) / delta
	st.yaw = heading_of(m.ring, st.pos, m.forward())
	st.leg_yaw = rig.leg_yaw if rig != null else 0.0
	st.heat = m.heat / maxf(m.heat_cap, 0.001)
	st.last_impact = m.last_impact
	st.grounded = m.grounded()
	st.thrusting = m.thrusting
	st.emergency = m.emergency
	st.shutdown = m.shutdown
	st.hover = m.thrusting and not st.grounded and absf(m.velocity.dot(m.up())) < 2.0
	if rack != null:
		st.aim = rack.aim()
		st.designator = rack.designator_on()
	else:
		st.aim = st.pos + m.forward() * 50.0
	st.comp = component_fractions(pt)
	if pt != null:
		st.disabled = pt.disabled
		st.disable_cause = pt.disable_cause
		st.redeploying = pt.redeploying
		st.revive = pt.revive_progress / DownedRules.REVIVE_TIME
		st.aid = pt.aid_charges
	st.mount_aim = mount_aims(rack)
	return st


## A PlayerTarget's component HP as fractions in NetMechCodec.COMPONENTS order (-1 = no such component).
static func component_fractions(pt: PlayerTarget) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for c: String in NetMechCodec.COMPONENTS:
		if pt == null or not pt.max_hp.has(c):
			out.append(-1.0)
		else:
			out.append(clampf(float(pt.hp.get(c, 0.0)) / maxf(float(pt.max_hp[c]), 0.001), 0.0, 1.0))
	return out


## Each hardpoint's barrel aim (aim_yaw, aim_pitch, deg) in NetMechCodec.MOUNTS order: 0, 0 (the rest pose) for an empty
## slot or a weapon that doesn't track (the rack only turns models whose mount has an aim_dir).
static func mount_aims(rack: WeaponRack) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for h: String in NetMechCodec.MOUNTS:
		var i := rack.hardpoints.find(h) if rack != null else -1
		var m: WeaponMount = rack.mounts[i] if i >= 0 and i < rack.mounts.size() else null
		if m != null and m.aim_dir != Vector3.ZERO:
			out.append_array([m.aim_yaw, m.aim_pitch])
		else:
			out.append_array([0.0, 0.0])
	return out


## A teammate's status for the crew panel: {hp 0..1 (the hull: torso HP), heat 0..1, state "ok" | "overheat" |
## "disabled" (downed: PlayerTarget.disabled from its owner's snapshots)}.
func status(peer: int) -> Dictionary:
	if drive != null and drive.crew_bots.has(peer):
		return (drive.crew_bots[peer] as CrewBot).status()
	var pp := puppets.get(peer) as MechPuppet
	if pp == null or pp.shown == null:
		return {"hp": 1.0, "heat": 0.0, "state": "ok"}
	var state := "disabled" if pp.downed else ("overheat" if pp.shown.shutdown else "ok")
	return {"hp": pp.hull, "heat": pp.shown.heat, "state": state}


## The ring frame's axes at p for headings: the floor tangent toward +s (yaw 0) and world +X (yaw +90 deg). Flat world:
## +Z and +X.
static func _axes(ring: RingFrame, p: Vector3) -> Array[Vector3]:
	return [ring.tangent_at(p) if ring != null else Vector3.BACK, Vector3.RIGHT]


## The heading (rad) of direction `f` about local up at p, in the ring frame.
static func heading_of(ring: RingFrame, p: Vector3, f: Vector3) -> float:
	var ax := _axes(ring, p)
	return atan2(f.dot(ax[1]), f.dot(ax[0]))


## The unit floor direction for heading `yaw` at p (inverse of heading_of).
static func heading_dir(ring: RingFrame, p: Vector3, yaw: float) -> Vector3:
	var ax := _axes(ring, p)
	return (ax[0] * cos(yaw) + ax[1] * sin(yaw)).normalized()
