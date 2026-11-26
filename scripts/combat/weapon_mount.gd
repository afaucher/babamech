class_name WeaponMount
extends RefCounted
## One mounted weapon's owner-side state (weapons.md §4.6, §6): cooldown, ammo, the salvo in progress, the shot counter,
## and the hook fields later weapons fill in through their WeaponBehaviour (spin, bloom, charge). It turns trigger input
## into FIRE RECORDS (Combat.fire_record) for CombatWorld.fire; it never spawns anything itself.
##
##   var m := WeaponMount.new()
##   m.setup("autocannon", "side_r", "pilot1", peer, world.stats("autocannon"))
##   for rec in m.update(dt, trigger_held, heat, world.now, muzzle, aim_point): world.fire(rec)
##
## Rules: no fire while `heat` is shut down; active heat is paid when a trigger cycle starts (per shot for single-shot
## weapons, per salvo for salvo weapons); ammo -1 = unlimited, 0 = dry (emits `dry`); a salvo, once started, ripples
## out at `rate` even if the trigger is released, then waits `reload` s. Shots due mid-step get their exact time
## (now + overshoot), so the cadence doesn't depend on the frame rate. All OWNER state of the shooter's machine.

signal dry

var weapon_id := ""
var hardpoint := ""
var shooter := ""
var peer := 1
var stats: Dictionary = {}        ## world.stats(weapon_id): refresh it when lab overrides change
var behaviour: WeaponBehaviour
var cooldown := 0.0               ## s until the next shot may leave
var ammo := -1
var shot_index := 0
var salvo_left := 0
var spin := 0.0                   ## hook: gatling spin-up (0..1)
var bloom := 0.0                  ## hook: extra spread, degrees
var charge := 0.0                 ## hook: charge time held, s (laser, railgun)
var held := false                 ## the trigger this step
var muzzle_at := Vector3.ZERO     ## this step's muzzle and aim point (update sets them before the behaviour's tick)
var aim_at := Vector3.ZERO
var hold_reason := ""             ## why the behaviour holds fire right now ("" = it may fire): HUD / lab readout
var frame: RingFrame = null       ## the deck frame range gates measure along (the mortar; WeaponRack sets it), null = flat
var heat_due := 0.0               ## hook: one-off heat a behaviour charges in tick, paid right after it (railgun cancel;
                                  ## dropped while the heat is shut down)
## The body this weapon is mounted on (its -Z = forward, +Y = up): the firer supplies it with set_body_basis (WeaponRack
## and the lab pass the hardpoint node's global basis). Default identity = world -Z forward. Used for fire arcs (§4.4).
var body_basis := Basis.IDENTITY
## AIM (pivoting direct-fire weapons, Combat.pivots, and the swivel): the barrel's yaw / pitch in the body's frame, deg
## (+ = right / up), and its world direction. OWNER state: remote machines pose the weapon models from aim_yaw /
## aim_pitch once mech snapshots exist (WeaponPose.apply); no network code here. A pivoting barrel slews toward
## pivot -> aim point at stats.slew °/s (Combat.PIVOT_SLEW) within Combat.pivot_limits, parks at a limit when the aim is
## outside it, and starts on the aim the first step it is ticked. Its shots leave pivot + barrel × muzzle along the
## barrel (_shape_pivot), so a slewing barrel fires where it points and a settled one straight at the aim point.
var aim_yaw := 0.0
var aim_pitch := 0.0
var aim_dir := Vector3.ZERO       ## the barrel's world direction (ZERO = not tracking / not ticked yet)
var aim_from := Vector2.ZERO      ## hook: (aim_yaw, aim_pitch) at the start of this step (shots mid-step interpolate)
var _arc_held := false            ## the fixed-weapon arc (Combat.FIXED_ARC_ENABLED) set hold_reason this step
## SHUTDOWN (weapons.md §4.7): while `heat` can't act, update fires nothing (as always), never tracks the aim point (a
## charge / spin-up still follows the trigger, so a charge is held through the shutdown) and parks a tracking barrel (pivoting weapons and the swivel) at PARK_YAW / PARK_PITCH in the body's frame (pitch
## clamped to its own limits) at PARK_SLEW °/s, then holds; hold_reason is Combat.SHUTDOWN. On reboot it tracks again
## from the parked pose at its normal slew (no snap). The parked angles are ordinary aim_yaw / aim_pitch (OWNER), so a
## puppet shows the park from the snapshot alone.
const PARK_YAW := 0.0
const PARK_PITCH := -12.0
const PARK_SLEW := 40.0
var parked := false               ## this step ran shut down (the barrel is parking / parked)
## HARDPOINT RANGE (chassis-rules.md 4.6): the hardpoint's own aim range in the body frame, Vector4(yaw_min, yaw_max,
## pitch_down, pitch_up) in degrees (yaw + = right, pitch_down a positive angle below level), INF = no limit. The firer
## sets it from the chassis (set_hardpoint_range(hardpoint_range(chassis, hp))). The barrel's range is the weapon's own
## (Combat.pivot_limits, the swivel's SwivelBoom.limits) intersected with it: aim_range(). The Strider's hardpoints add
## no limit; the Bulwark's side guns cap the INWARD yaw at the catalog's `yaw_in_max` (+ yaw on the left gun, - on the
## right). THE CAN'T-BEAR RULE (both chassis): the barrel slews to the nearest point of aim_range and parks there; a
## pivoting weapon fires along its parked barrel (Combat.FIXED_ARC_ENABLED off, the default) or holds with OUT_OF_ARC
## (on); the swivel always holds with OUT_OF_ARC. Shots always leave along the barrel, never bent toward the aim point.
var hp_range := Vector4(-INF, INF, INF, INF)


func net_fields() -> Dictionary:
	return {"weapon_id": Net.SPAWN, "hardpoint": Net.SPAWN, "shooter": Net.SPAWN, "peer": Net.SPAWN, "stats": Net.SPAWN,
		"behaviour": Net.LOCAL, "cooldown": Net.OWNER, "ammo": Net.OWNER, "shot_index": Net.OWNER, "salvo_left": Net.OWNER,
		"spin": Net.OWNER, "bloom": Net.OWNER, "charge": Net.OWNER, "held": Net.PRIVATE, "muzzle_at": Net.PRIVATE,
		"aim_at": Net.PRIVATE, "hold_reason": Net.PRIVATE, "heat_due": Net.PRIVATE,
		"body_basis": Net.PRIVATE, "aim_yaw": Net.OWNER, "aim_pitch": Net.OWNER, "aim_dir": Net.OWNER, "aim_from": Net.PRIVATE,
		"_arc_held": Net.PRIVATE, "parked": Net.PRIVATE, "hp_range": Net.SPAWN, "frame": Net.LOCAL}


func setup(id: String, hp: String, shooter_id: String, shooter_peer: int, st: Dictionary) -> void:
	weapon_id = id
	hardpoint = hp
	shooter = shooter_id
	peer = shooter_peer
	stats = st
	behaviour = WeaponRegistry.behaviour(id)
	ammo = int(st.get("ammo", -1))
	cooldown = 0.0
	salvo_left = 0
	shot_index = 0


func built() -> bool:
	return behaviour != null


func interval() -> float:
	return 1.0 / maxf(float(stats.get("rate", 1.0)), 0.001)


## The body's basis for fire arcs (see body_basis). Call before update each step; optional.
func set_body_basis(b: Basis) -> void:
	body_basis = b


## The hardpoint's aim range (see hp_range). Set once after setup; optional (default: no limit).
func set_hardpoint_range(r: Vector4) -> void:
	hp_range = r


## The aim range hardpoint `hp_id` of chassis `chassis_id` allows, as hp_range: from its catalog entry's `yaw_in_max`
## (deg the barrel may turn INWARD, toward the hull's centreline) and, when present, `yaw_out_max`, `pitch_down_max`,
## `pitch_up_max`. Inward is + yaw for a hardpoint left of the centreline (ChassisParts mount x < 0, or an id ending
## "_l"), - yaw for one on the right; a centred hardpoint caps both sides with yaw_in_max. No keys: no limit.
static func hardpoint_range(chassis_id: String, hp_id: String) -> Vector4:
	var hp := {}
	for h: Dictionary in MechCatalog.chassis(chassis_id)["hardpoints"]:
		if str(h["id"]) == hp_id:
			hp = h
	var y_in := float(hp.get("yaw_in_max", INF))
	var y_out := float(hp.get("yaw_out_max", INF))
	var r := Vector4(-INF, INF, float(hp.get("pitch_down_max", INF)), float(hp.get("pitch_up_max", INF)))
	var side := hardpoint_side(chassis_id, hp_id)
	if side < 0.0:          # left gun: inward is to the right (+ yaw)
		r.x = -y_out
		r.y = y_in
	elif side > 0.0:        # right gun: inward is to the left (- yaw)
		r.x = -y_in
		r.y = y_out
	else:
		r.x = -y_in
		r.y = y_in
	return r


## -1 for a hardpoint left of the chassis' centreline, +1 right of it, 0 on it (the art's mount point, else the id).
static func hardpoint_side(chassis_id: String, hp_id: String) -> float:
	var mounts: Dictionary = ChassisParts.of(chassis_id).get("mounts", {})
	if mounts.has(hp_id):
		var x := (mounts[hp_id] as Vector3).x
		return 0.0 if absf(x) < 1e-4 else signf(x)
	return -1.0 if hp_id.ends_with("_l") else (1.0 if hp_id.ends_with("_r") else 0.0)


## The weapon's own range: Vector3(yaw half-width, pitch down, pitch up) (the swivel's arc, else Combat.pivot_limits).
func weapon_limits() -> Vector3:
	if behaviour != null and behaviour.has_method("shape_record"):
		return SwivelBoom.limits(stats)
	return Combat.pivot_limits(stats)


## The barrel's range now: the weapon's own intersected with the hardpoint's, Vector4(yaw_min, yaw_max, pitch_down,
## pitch_up) degrees.
func aim_range() -> Vector4:
	var w := weapon_limits()
	var lo := maxf(-w.x, hp_range.x)
	var hi := minf(w.x, hp_range.y)
	if lo > hi:             # no overlap (bad data): the hardpoint's limit nearest the weapon's range
		lo = clampf(0.0, hp_range.x, hp_range.y)
		hi = lo
	return Vector4(lo, hi, minf(w.y, hp_range.z), minf(w.z, hp_range.w))


## MINIMUM CONVERGENCE RANGE: a barrel pivoting `lateral` m off the mech's centreline that may turn at most `yaw_in`
## degrees inward can bear on a point of the centreline only `lateral / tan(yaw_in)` m or more ahead of its pivot
## (straight lines: the barrel's line passes through its pivot; pitch does not change the body-frame yaw). Closer, the
## barrel parks at its inward limit and its shots cross the centreline at that distance. INF for yaw_in <= 0.
## Bulwark side guns (pivots 3.57 m out at mech scale 2): 6.18 m for every pivoting weapon (yaw_in = min(30, yaw_in_max
## 55) = 30), 2.50 m for the swivel (55); the Strider's side guns (2.90 m out, 30 deg): 5.03 m.
static func min_convergence_range(lateral: float, yaw_in: float) -> float:
	if yaw_in <= 0.0:
		return INF
	return absf(lateral) / tan(deg_to_rad(minf(yaw_in, 89.9)))


## The most this barrel may turn inward, toward the centreline on hardpoint side `side` (-1 left, +1 right; 0: the
## smaller of both ways), degrees (from aim_range()).
func inward_limit(side: float) -> float:
	var r := aim_range()
	if side < 0.0:
		return r.y
	if side > 0.0:
		return -r.x
	return minf(r.y, -r.x)


## Body-frame (yaw, pitch) clamped into aim_range().
func clamp_aim(a: Vector2) -> Vector2:
	var r := aim_range()
	return Vector2(clampf(a.x, r.x, r.y), clampf(a.y, -r.z, r.w))


## Body-frame (yaw, pitch) inside aim_range() (the barrel can bear on it).
func in_aim_range(a: Vector2) -> bool:
	var r := aim_range()
	return a.x >= r.x - 1e-4 and a.x <= r.y + 1e-4 and a.y >= -r.z - 1e-4 and a.y <= r.w + 1e-4


## The fixed-weapon arc (Combat.FIXED_ARC_ENABLED, off by default): outside it, hold with Combat.OUT_OF_ARC. Clears
## only the reason it set itself, so a behaviour's own hold_reason is left alone.
func _check_fixed_arc() -> void:
	var out := false
	if Combat.fixed_arc_applies(weapon_id, stats):
		if pivoting():      # the fire arc is the pivot range, seen from the pivot
			var to := aim_at - pivot()
			out = to.length_squared() >= 1e-6 and not in_aim_range(Combat.arc_angles(body_basis, to))
		else:
			out = not Combat.in_fixed_arc(body_basis, muzzle_at, aim_at)
	if out:
		hold_reason = Combat.OUT_OF_ARC
	elif _arc_held and hold_reason == Combat.OUT_OF_ARC:
		hold_reason = ""
	_arc_held = out


## This weapon pivots at its mount to track the aim point (Combat.pivots; the swivel aims itself, the mortar is fixed).
func pivoting() -> bool:
	return behaviour != null and not behaviour.has_method("shape_record") and Combat.pivots(weapon_id, stats)


## The mount point the barrel turns about: this step's muzzle point minus `muzzle` along the body's forward (the firer
## passes the unturned muzzle, `muzzle` ahead of the hardpoint).
func pivot() -> Vector3:
	return muzzle_at - body_basis * Vector3(0, 0, -float(stats.get("muzzle", 0.0)))


## Where the turned barrel's muzzle is now: pivot + barrel × muzzle (× the body scale); the unturned muzzle before the
## first tick or for a weapon that doesn't track.
func barrel_muzzle() -> Vector3:
	if aim_dir == Vector3.ZERO:
		return muzzle_at
	return pivot() + aim_dir * float(stats.get("muzzle", 0.0)) * body_basis.x.length()


## The barrel points within Combat.ON_TARGET_DEG of pivot -> aim point (false while slewing or parked at a limit).
## Always true for a weapon that doesn't track (the mortar lobs to the aim point).
func on_target() -> bool:
	if not pivoting() and not (behaviour != null and behaviour.has_method("shape_record")):
		return true
	if aim_dir == Vector3.ZERO:
		return false
	var to := aim_at - pivot()
	return to.length_squared() < 1e-6 or rad_to_deg(aim_dir.angle_to(to)) <= Combat.ON_TARGET_DEG + 1e-4


## One step of the pivoting barrel: slew toward pivot -> aim point, clamped to the pivot range.
func _track(dt: float) -> void:
	var cur := Vector2(aim_yaw, aim_pitch)
	var to := aim_at - pivot()
	if to.length_squared() < 1e-6:
		aim_from = cur
		aim_dir = Combat.arc_dir(body_basis, cur)
		return
	var goal := clamp_aim(Combat.arc_angles(body_basis, to))
	if aim_dir == Vector3.ZERO:
		cur = goal                   # a fresh mount starts on the aim
	aim_from = cur
	var step := maxf(float(stats.get("slew", Combat.PIVOT_SLEW)), 0.0) * dt
	var d := goal - cur
	cur = goal if d.length() <= step else cur + d.normalized() * step
	aim_yaw = cur.x
	aim_pitch = cur.y
	aim_dir = Combat.arc_dir(body_basis, cur)


## The parked pose in the body's frame: Vector2(PARK_YAW, PARK_PITCH), clamped to this barrel's range (aim_range: the
## swivel's arc or Combat.pivot_limits, with the hardpoint's).
func park_pose() -> Vector2:
	return clamp_aim(Vector2(PARK_YAW, PARK_PITCH))


## One step of a shut-down barrel: ease toward park_pose at PARK_SLEW °/s (from the rest pose if it never tracked).
func _park(dt: float) -> void:
	var cur := Vector2(aim_yaw, aim_pitch)
	aim_from = cur
	cur = cur.move_toward(park_pose(), PARK_SLEW * dt)
	aim_yaw = cur.x
	aim_pitch = cur.y
	aim_dir = Combat.arc_dir(body_basis, cur)


## A pivoting weapon's record leaves from the barrel's muzzle along the barrel at the shot's time (`into` s into this
## step: the barrel moved from aim_from toward its end-of-step angles at `slew` °/s). The seeded spread stays in the
## record (applied by the effect), so it is around the barrel's direction.
func _shape_pivot(rec: Dictionary, into: float) -> void:
	var slew := maxf(float(stats.get("slew", Combat.PIVOT_SLEW)), 0.0)
	var yp := aim_from.move_toward(Vector2(aim_yaw, aim_pitch), slew * maxf(into, 0.0))
	var dir := Combat.arc_dir(body_basis, yp)
	var origin := pivot() + dir * float(stats.get("muzzle", 0.0)) * body_basis.x.length()
	rec["origin"] = origin
	rec["dir"] = dir
	rec["target"] = origin + dir * maxf(origin.distance_to(aim_at), 1.0)


## Fire records due this step. `origin` = the muzzle, `aim` = the aim point (convergence). `heat` is duck-typed: a Heat,
## or anything with can_act() and add(amount) (WeaponRack.MechHeat: the MechController's gauge), or null.
func update(dt: float, trigger: bool, heat: Variant, now: float, origin: Vector3, aim: Vector3) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var was_parked := parked
	parked = heat != null and not heat.can_act()
	if not parked and was_parked and hold_reason == Combat.SHUTDOWN:
		hold_reason = ""
	var was_held := held or salvo_left > 0
	held = trigger
	muzzle_at = origin
	aim_at = aim
	cooldown -= dt
	if not was_held:
		cooldown = maxf(cooldown, 0.0)    # a fresh press fires now, not back-dated into the idle step
	if behaviour == null:
		cooldown = maxf(cooldown, 0.0)
		return out
	if parked:
		# Charge / spin / release run as before (a charge is held through the shutdown; the fire loop below refuses to
		# fire); the swivel's tick is its tracking, so it is skipped while parked.
		if not behaviour.has_method("shape_record"):
			behaviour.tick(self, trigger, dt)
		if pivoting() or behaviour.has_method("shape_record"):
			_park(dt)
		hold_reason = Combat.SHUTDOWN
		_arc_held = false
	else:
		behaviour.tick(self, trigger, dt)
		if pivoting():
			_track(dt)
		_check_fixed_arc()
	if heat_due > 0.0:
		if heat != null and heat.can_act():    # a release while shut down is not a cancel: no heat on a dead mech
			heat.add(heat_due)
		heat_due = 0.0
	var salvo := maxi(int(stats.get("salvo", 1)), 1)
	while cooldown <= 0.0:
		if heat != null and not heat.can_act():
			salvo_left = 0
			break
		if salvo_left <= 0:
			if not behaviour.wants_fire(self, trigger) or _arc_held:
				break
			if ammo == 0:
				dry.emit()
				break
			if heat != null:
				heat.add(float(stats.get("active_heat", 0.0)))
			salvo_left = salvo
		if ammo == 0:
			salvo_left = 0
			break
		var t := now + cooldown
		var rec := Combat.fire_record(shooter, peer, hardpoint, weapon_id, origin, aim, t, shot_index, behaviour.spread(self))
		if behaviour.has_method("shape_record"):     # hook: a tracking barrel (swivel) sets origin / dir / target
			behaviour.shape_record(self, rec, clampf(dt + cooldown, 0.0, dt))    # s into this step the shot leaves
		elif pivoting():                                 # a pivoting barrel: out of the barrel, along it
			_shape_pivot(rec, clampf(dt + cooldown, 0.0, dt))
		out.append(rec)
		shot_index += 1
		if ammo > 0:
			ammo -= 1
		salvo_left -= 1
		behaviour.on_shot(self)
		cooldown += interval()
		if salvo_left <= 0 and salvo > 1:
			cooldown += float(stats.get("reload", 0.0))
	if cooldown < 0.0:
		cooldown = 0.0        # an idle trigger doesn't bank shots
	return out
