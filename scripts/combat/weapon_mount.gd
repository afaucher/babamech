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


func net_fields() -> Dictionary:
	return {"weapon_id": Net.SPAWN, "hardpoint": Net.SPAWN, "shooter": Net.SPAWN, "peer": Net.SPAWN, "stats": Net.SPAWN,
		"behaviour": Net.LOCAL, "cooldown": Net.OWNER, "ammo": Net.OWNER, "shot_index": Net.OWNER, "salvo_left": Net.OWNER,
		"spin": Net.OWNER, "bloom": Net.OWNER, "charge": Net.OWNER, "held": Net.PRIVATE, "muzzle_at": Net.PRIVATE,
		"aim_at": Net.PRIVATE, "hold_reason": Net.PRIVATE, "heat_due": Net.PRIVATE,
		"body_basis": Net.PRIVATE, "aim_yaw": Net.OWNER, "aim_pitch": Net.OWNER, "aim_dir": Net.OWNER, "aim_from": Net.PRIVATE,
		"_arc_held": Net.PRIVATE}


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


## The fixed-weapon arc (Combat.FIXED_ARC_ENABLED, off by default): outside it, hold with Combat.OUT_OF_ARC. Clears
## only the reason it set itself, so a behaviour's own hold_reason is left alone.
func _check_fixed_arc() -> void:
	var out := false
	if Combat.fixed_arc_applies(weapon_id, stats):
		if pivoting():      # the fire arc is the pivot range, seen from the pivot
			var to := aim_at - pivot()
			var lim := Combat.pivot_limits(stats)
			out = to.length_squared() >= 1e-6 and not Combat.in_arc(Combat.arc_angles(body_basis, to), lim.x, lim.y, lim.z)
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
	var lim := Combat.pivot_limits(stats)
	var cur := Vector2(aim_yaw, aim_pitch)
	var to := aim_at - pivot()
	if to.length_squared() < 1e-6:
		aim_from = cur
		aim_dir = Combat.arc_dir(body_basis, cur)
		return
	var want := Combat.arc_angles(body_basis, to)
	var goal := Vector2(clampf(want.x, -lim.x, lim.x), clampf(want.y, -lim.y, lim.z))
	if aim_dir == Vector3.ZERO:
		cur = goal                   # a fresh mount starts on the aim
	aim_from = cur
	var step := maxf(float(stats.get("slew", Combat.PIVOT_SLEW)), 0.0) * dt
	var d := goal - cur
	cur = goal if d.length() <= step else cur + d.normalized() * step
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
