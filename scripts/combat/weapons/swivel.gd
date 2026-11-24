class_name SwivelBoom
extends WeaponBehaviour
## Swivel Boom (weapons.md §3.4, §4.4): the off-axis gun. Twin dark slugs with thin orange tracers, 4 a second in all,
## leaving alternately from the left and the right barrel (even shot_index = left). Every number is
## MechCatalog.WEAPONS["swivel"] (damage, rate, speed, range / falloff, spread, knockback, heat, yaw_arc, pitch_down,
## pitch_up, slew, muzzle).
##
## THE BOOM TRACKS. Its direction is per-mount OWNER state on the WeaponMount, in the body's frame: aim_yaw (deg, + =
## right of the body's forward) and aim_pitch (deg, + = up), plus aim_dir (the same direction in world space). The body
## is WeaponMount.body_basis (the firer supplies the hardpoint node's global basis; default identity = world -Z forward,
## +Y up). Each tick the boom slews toward the direction from its pivot to the aim point at up to `slew` °/s (a straight
## line in yaw/pitch), clamped to ±yaw_arc yaw and -pitch_down..+pitch_up pitch, cut by the hardpoint's own range
## (WeaponMount.aim_range: the Bulwark's side guns turn at most yaw_in_max inward). When the aim point is outside that arc
## the boom stops at the limit and the weapon holds fire (hold_reason Combat.OUT_OF_ARC).
## Shots leave along the boom's CURRENT direction, not straight at the aim point: after a snap turn the first rounds lag
## behind until the boom catches up. A shot due mid-step takes the boom direction at its exact time (re-slewed from the
## step's start, WeaponMount.aim_from), so the fan of a slew doesn't depend on the frame rate.
##
## GEOMETRY. The pivot is the hardpoint (the muzzle point the firer passes, minus `muzzle` along the body's forward:
## WeaponRack / the lab put the muzzle there). A round leaves at pivot + aim_dir × muzzle (× the body scale), ±BARREL
## across the boom. All of it goes into the fire record (origin, dir, target), so every machine flies the same slug from
## the record alone.

const BARREL := 0.05                      ## m (× the body scale): each barrel's offset across the boom
const SLUG_COLOR: Color = MechMeshes.DARK
const TRACER_COLOR: Color = LowPolyFlame.OUTER     ## orange (the one flame palette)
const WEAPON_NODE := "Weapon_swivel"      ## MechParts.weapon's root under the HP_ node: rotated by pose_boom


## The arc in force: Vector3(yaw half-width, pitch down, pitch up), degrees.
static func limits(st: Dictionary) -> Vector3:
	return Vector3(float(st.get("yaw_arc", 120.0)), float(st.get("pitch_down", 40.0)), float(st.get("pitch_up", 60.0)))


## The boom's pivot for this step (the hardpoint): the muzzle point minus `muzzle` along the body's forward.
static func pivot(mount: WeaponMount) -> Vector3:
	return mount.muzzle_at - mount.body_basis * Vector3(0, 0, -float(mount.stats.get("muzzle", 0.0)))


func tick(mount: WeaponMount, _held: bool, dt: float) -> void:
	var st := mount.stats
	var cur := Vector2(mount.aim_yaw, mount.aim_pitch)
	mount.aim_from = cur
	var to := mount.aim_at - pivot(mount)
	if to.length_squared() < 1e-6:
		mount.hold_reason = ""
		mount.aim_dir = Combat.arc_dir(mount.body_basis, cur)
		return
	var want := Combat.arc_angles(mount.body_basis, to)
	# The arc in force: limits(st) cut by the hardpoint's own range (WeaponMount.aim_range: the Bulwark's yaw_in_max).
	var goal := mount.clamp_aim(want)
	mount.hold_reason = "" if mount.in_aim_range(want) else Combat.OUT_OF_ARC
	var step := maxf(float(st.get("slew", 240.0)), 0.0) * dt
	var d := goal - cur
	cur = goal if d.length() <= step else cur + d.normalized() * step
	mount.aim_yaw = cur.x
	mount.aim_pitch = cur.y
	mount.aim_dir = Combat.arc_dir(mount.body_basis, cur)


func wants_fire(mount: WeaponMount, held: bool) -> bool:
	return held and mount.hold_reason == ""


## WeaponMount hook: the record of one round leaves from the boom's barrel along the boom's direction at the shot's time
## (`into` = s into this step: the boom moved from aim_from toward its end-of-step angles at `slew` °/s).
func shape_record(mount: WeaponMount, rec: Dictionary, into: float) -> void:
	var b := mount.body_basis
	var slew := maxf(float(mount.stats.get("slew", 240.0)), 0.0)
	var yp := mount.aim_from.move_toward(Vector2(mount.aim_yaw, mount.aim_pitch), slew * maxf(into, 0.0))
	var dir := Combat.arc_dir(b, yp)
	var s := b.x.length()
	var up := b.orthonormalized().y
	var side := dir.cross(up)
	if side.length_squared() < 1e-6:
		side = b.orthonormalized().x
	side = side.normalized()
	var sgn := -1.0 if int(rec["shot_index"]) % 2 == 0 else 1.0
	var origin := pivot(mount) + dir * float(mount.stats.get("muzzle", 0.0)) * s + side * BARREL * s * sgn
	rec["origin"] = origin
	rec["dir"] = dir
	rec["target"] = origin + dir * maxf(origin.distance_to(mount.aim_at), 1.0)


## Turn the mounted boom model (the WEAPON_NODE child of a HP_ node, which sits at the pivot) to the mount's yaw/pitch.
## Cosmetic; the HP_ node itself is the body frame, so this is a local rotation (WeaponPose, shared with every pivoting
## weapon).
static func pose_boom(hp: Node3D, mount: WeaponMount) -> void:
	if hp == null or mount == null:
		return
	WeaponPose.apply(hp, "swivel", mount.aim_yaw, mount.aim_pitch)


func look() -> Dictionary:
	return {"color": SLUG_COLOR, "trail_color": TRACER_COLOR, "width": 0.3}
