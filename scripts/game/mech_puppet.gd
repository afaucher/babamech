class_name MechPuppet
extends Node
## Shows another crew member's mech here (co-op step 2, docs/networking.md "Mech snapshots"): a child "Puppet" of a
## MechController whose `puppet` flag is on (no input, no physics). Every physics frame, before the rig poses it, it
## reads the owner's interpolated state from Session.mechs.pose(peer) and writes it into the mech: position, facing,
## velocity, grounded, heat, thrust / emergency / shutdown, the last landing speed, and the hip twist (MechRig's
## twist_override). The rig, gait (the feet still plant locally against this machine's ground), ThrusterFx, the pilot head
## and MechAudio then run from that exactly as they do for your own mech.
##
## A teleport (the owner respawned: the snapshot's counter changed) or a jump of more than SNAP_DIST in one frame re-plants
## the feet at the new spot instead of striding across the gap. The remote mech's PlayerTarget (`target`, registered by
## CrewSync with the owner's peer) is carried along, since only its owner's machine ticks it.
##
## `aim_point` / `designator` are the owner's (hooks for combat across owners, co-op step 3); `shown` is the state applied
## last (its `t` is the render time on the shared clock), null before the first snapshot.

const SNAP_DIST := 6.0

var peer := 0
var mech: MechController
var rig: MechRig
var target: PlayerTarget
var shown: NetMechState = null
var aim_point := Vector3.ZERO
var designator := false
var snaps := 0                      ## times the feet were re-planted for a jump (tests, diagnostics)


## Authority (scripts/net/net.gd): this machine's presentation of a mech another machine owns. Everything it holds is
## either set at spawn (who, which nodes) or the owner's streamed state as received here.
func net_fields() -> Dictionary:
	return {"peer": Net.SPAWN, "mech": Net.LOCAL, "rig": Net.LOCAL, "target": Net.LOCAL, "shown": Net.LOCAL,
		"aim_point": Net.LOCAL, "designator": Net.LOCAL, "snaps": Net.LOCAL}


func _ready() -> void:
	process_physics_priority = 5   # after the controllers (0), before every MechRig (10) poses its model


func bind(m: MechController, owner_peer: int) -> void:
	mech = m
	peer = owner_peer
	rig = MechSpawn.rig_of(m)
	m.puppet = true


func _physics_process(_delta: float) -> void:
	var sess := Net.session()
	if mech == null or sess == null or sess.mechs == null:
		return
	var st := sess.mechs.pose(peer)
	if st == null:
		return
	var b := sess.mechs.buffer(peer)
	var jumped := b != null and b.take_teleport()
	if shown != null and st.pos.distance_to(mech.global_position) > SNAP_DIST:
		jumped = true
	apply(st)
	if jumped:
		snaps += 1
		rig.gait.reset([])
		mech.reset_physics_interpolation()
	shown = st
	if target != null and is_instance_valid(target) and target.is_inside_tree():
		target.global_transform = mech.global_transform
		target.up = mech.up()


## Write a state into the puppet mech.
func apply(st: NetMechState) -> void:
	mech.global_position = st.pos
	var u := mech.up()
	var f := CrewSync.heading_dir(mech.ring, st.pos, st.yaw)
	mech.global_basis = Basis(f.cross(u), u, -f)
	mech.velocity = st.vel
	mech.puppet_grounded = st.grounded
	mech.heat = st.heat * mech.heat_cap
	mech.shutdown = st.shutdown
	mech.thrusting = st.thrusting
	mech.emergency = st.emergency
	mech.last_impact = st.last_impact
	# The pilot head's "effort" cue reads `running`: recomputed here from the speed (the owner's input never crosses).
	mech.running = mech.ground_speed() > mech.walk_speed + 1.0
	if rig != null:
		rig.twist_override = st.leg_yaw
	aim_point = st.aim
	designator = st.designator
