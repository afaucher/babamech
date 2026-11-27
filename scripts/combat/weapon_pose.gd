class_name WeaponPose
extends RefCounted
## Turns a mounted weapon model to its mount's aim (weapons.md §4.4), cosmetic: the `Weapon_<id>` node that
## MechParts.weapon puts under each `HP_<id>` node (origin at the mount point, barrel along -Z) is rotated about its own
## origin to body-frame (yaw, pitch) degrees (+ = right / up, as WeaponMount.aim_yaw / aim_pitch). The HP_ node is the
## body frame, so this is a local rotation applied ON TOP of the node's rest basis (remembered the first time, so a
## mirrored or scaled rest basis stays mirrored / scaled and only the barrel's direction changes).
## `muzzle` is the matching gameplay point: hardpoint + the barrel's world direction × length × the body scale, which is
## exactly where a child at (0, 0, -length) of the turned model ends up (test_weapon_pivot checks it).
##
##   WeaponPose.apply(hp_node, "autocannon", mount.aim_yaw, mount.aim_pitch)
##   var p := WeaponPose.muzzle(hp_node, mount.aim_yaw, mount.aim_pitch, float(stats["muzzle"]))
##
## Remote machines pose models from the mount's OWNER aim_yaw / aim_pitch once mech snapshots exist; nothing here is
## gameplay state.

const REST_META := &"weapon_pose_rest"
## Weapons whose barrel does NOT lie along the model's -Z: the point their shots leave the UNTURNED model, in the
## hardpoint's frame (model units, before the body scale). The mortar's tube rises up and forward from its base plate
## (MechWeaponMeshes._weapon_mortar: from (0, 0.12, 0.14) to the muzzle ring at (0, 1.22, -0.3), the ring's face 0.025 further
## along it), so its shells leave the tube's mouth above and behind the pilot, never `muzzle` ahead of the back mount
## (which on the Strider is inside the pilot's head). Every other weapon: `muzzle` straight ahead (rest_offset).
const MUZZLE_TIPS := {"mortar": Vector3(0, 1.2432, -0.3093)}


## Where weapon `weapon_id`'s shots leave its unturned model, in the hardpoint's frame (model units): its MUZZLE_TIPS
## entry, else `length` (the catalog's `muzzle`) straight ahead.
static func rest_offset(weapon_id: String, length: float) -> Vector3:
	return MUZZLE_TIPS.get(weapon_id, Vector3(0, 0, -length))


## The weapon model under a hardpoint node, or null.
static func node_of(hp: Node3D, weapon_id: String) -> Node3D:
	if hp == null or weapon_id == "":
		return null
	return hp.get_node_or_null("Weapon_" + weapon_id) as Node3D


## The local rotation that turns -Z to body-frame (yaw, pitch) degrees (Combat.arc_dir's convention).
static func rotation(yaw: float, pitch: float) -> Basis:
	return Basis.from_euler(Vector3(deg_to_rad(pitch), -deg_to_rad(yaw), 0.0))


## Turn the weapon model under `hp` to (yaw, pitch). No-op when the model isn't there.
static func apply(hp: Node3D, weapon_id: String, yaw: float, pitch: float) -> void:
	var n := node_of(hp, weapon_id)
	if n == null:
		return
	if not n.has_meta(REST_META):
		n.set_meta(REST_META, n.basis)
	n.basis = rotation(yaw, pitch) * (n.get_meta(REST_META) as Basis)


## Back to the rest pose.
static func reset(hp: Node3D, weapon_id: String) -> void:
	apply(hp, weapon_id, 0.0, 0.0)


## The world point `length` model units out along the barrel turned to (yaw, pitch) from the hardpoint `hp`.
static func muzzle(hp: Node3D, yaw: float, pitch: float, length: float) -> Vector3:
	var b := hp.global_basis
	return hp.global_position + Combat.arc_dir(b, Vector2(yaw, pitch)) * length * b.x.length()
