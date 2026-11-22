class_name CrewSync
extends Node
## The test drive's side of mech snapshots (co-op step 2, docs/networking.md "Mech snapshots"). Built by TestDrive in a
## crew mission, child "CrewSync":
##   - feeds the local mech's state to Session.mechs every physics frame (after the rig posed it), which streams it;
##   - makes every other crew mech a puppet (MechPuppet, child "Puppet" of that mech) shown from its owner's snapshots;
##   - registers each puppet as a PlayerTarget with its owner's peer (so weapons and enemies see it; hits on it are its
##     owner's to decide, co-op step 3), carried along by its MechPuppet;
##   - answers the crew panel (hud.crew_panel.status_source): a teammate's heat and overheat from its snapshots (hp
##     stays 1 until component HP is streamed).
## Nothing here touches the wire: it only asks Session (begin / feed / pose / end).

var drive: TestDrive
var puppets: Dictionary = {}        ## owner peer -> MechPuppet
var targets: Dictionary = {}        ## owner peer -> PlayerTarget (the puppets')

var _last_pos := Vector3.INF


## Authority (scripts/net/net.gd): scene wiring on this machine; the state it moves is declared by the mechs.
func net_fields() -> Dictionary:
	return {"drive": Net.LOCAL, "puppets": Net.LOCAL, "targets": Net.LOCAL, "_last_pos": Net.LOCAL}


func _ready() -> void:
	process_physics_priority = 20   # after the local mech moved (0) and its rig posed it (10)


## `seats`: owner peer -> crew seat for every mech of the mission (the local one too).
func setup(td: TestDrive, seats: Dictionary) -> void:
	drive = td
	var sess := Net.session()
	var local := sess.local_id() if sess != null else 0
	for p: int in td.mechs:
		var m: MechController = td.mechs[p]
		if m == td.mech:
			continue
		var pp := MechPuppet.new()
		pp.name = "Puppet"
		pp.bind(m, p)
		m.add_child(pp)
		puppets[p] = pp
		if td.combat != null and td.combat.world != null:
			var pt := PlayerTarget.new()
			pt.name = "PlayerTarget_p%d" % p
			pt.auto_respawn_delay = -1.0   # its owner respawns it
			td.combat.add_child(pt)
			pt.bind(td.combat.world, m, MechSpawn.rig_of(m).model, "player%d" % p, p)
			td.combat.world.register(pt)
			pp.target = pt
			targets[p] = pt
	if sess != null and sess.mechs != null:
		sess.mechs.begin(local, seats)


func _exit_tree() -> void:
	var sess := Net.session()
	if sess != null and sess.mechs != null:
		sess.mechs.end()


func _physics_process(delta: float) -> void:
	var sess := Net.session()
	if drive == null or drive.mech == null or sess == null or sess.mechs == null or not sess.mechs.active:
		return
	sess.mechs.feed(sample(delta), delta)


## The local mech's state now (velocity from its motion over the last physics frame, so it matches the positions the
## puppets interpolate between).
func sample(delta: float) -> NetMechState:
	var m := drive.mech
	var st := NetMechState.new()
	st.pos = m.global_position
	st.vel = m.velocity
	if _last_pos != Vector3.INF and delta > 0.0 and st.pos.distance_to(_last_pos) < NetMechStream.TELEPORT_DIST:
		st.vel = (st.pos - _last_pos) / delta
	_last_pos = st.pos
	st.yaw = heading_of(m.ring, st.pos, m.forward())
	st.leg_yaw = drive.rig.leg_yaw if drive.rig != null else 0.0
	st.heat = m.heat / maxf(m.heat_cap, 0.001)
	st.last_impact = m.last_impact
	st.grounded = m.grounded()
	st.thrusting = m.thrusting
	st.emergency = m.emergency
	st.shutdown = m.shutdown
	st.hover = m.thrusting and not st.grounded and absf(m.velocity.dot(m.up())) < 2.0
	var rack := drive.combat.rack if drive.combat != null else null
	if rack != null:
		st.aim = rack.aim()
		st.designator = rack.designator_on()
	else:
		st.aim = st.pos + m.forward() * 50.0
	return st


## A teammate's status for the crew panel: {hp, heat 0..1, state "ok" | "overheat"} (hp 1 until component HP streams).
func status(peer: int) -> Dictionary:
	var pp := puppets.get(peer) as MechPuppet
	if pp == null or pp.shown == null:
		return {"hp": 1.0, "heat": 0.0, "state": "ok"}
	return {"hp": 1.0, "heat": pp.shown.heat, "state": "overheat" if pp.shown.shutdown else "ok"}


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
