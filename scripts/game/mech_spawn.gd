class_name MechSpawn
extends RefCounted
## Builds a playable mech: MechController + collision capsule + MechRig (low-poly model, IK legs) + ThrusterFx.
## Used by the test drive and the thruster lab, so they always get the same mech the game will.

const OWNER_META := &"owner_peer"


## A new mech (not yet in the tree). Head/chassis/loadout are applied once it is ready; step-up follows the legs.
## `peer` is the owner (the crew member whose machine drives it; owner authority, docs/networking.md), kept as the
## "owner_peer" meta (owner_of): 0 = nobody's (labs). `accent` (a MechAccent id, "" = the default) is applied once the
## model exists (the rig builds it when it enters the tree).
static func make(head: String = "chicken", chassis: String = "strider", loadout: Dictionary = {}, peer: int = 0,
		accent: String = "") -> MechController:
	var m := MechController.new()
	m.name = "Mech"
	m.set_meta(OWNER_META, peer)
	m.owner_peer = peer
	var shape := CollisionShape3D.new()
	shape.name = "Shape"
	var cap := CapsuleShape3D.new()
	shape.shape = cap
	m.add_child(shape)
	var rig := MechRig.new()
	rig.name = "Rig"
	m.add_child(rig)
	var fx := ThrusterFx.new()
	fx.name = "Thrusters"
	m.add_child(fx)
	var audio := MechAudio.new()
	audio.name = "Audio"
	m.add_child(audio)
	# The chassis' movement numbers and capsule (MechCatalog "movement": the Strider's r 2.2 / h 8, the Bulwark's r 3.6 / h 8),
	# the same on every machine (puppets too): the crew entry carries the chassis id.
	m.apply_chassis(chassis)
	m.ready.connect(func() -> void:
		rig.model.configure(head, chassis, loadout)
		rig.sync_chassis()   # the chassis' rig numbers, before max_step()
		if accent != "":
			MechAccent.apply(rig.model, accent)
		m.max_step_up = rig.max_step())
	return m


## The owner peer of a mech made by make() (0 = none).
static func owner_of(m: Node) -> int:
	return int(m.get_meta(OWNER_META, 0)) if m != null else 0


## The rig of a mech made by make().
static func rig_of(m: MechController) -> MechRig:
	return m.get_node("Rig") as MechRig
