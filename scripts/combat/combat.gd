class_name Combat
extends RefCounted
## The one shared combat module (docs/design/weapons.md §2, §4, §5): the shared rule numbers, the fire record, the shot
## generator and the pure maths every weapon uses. No state, no nodes. Hit resolution lives in CombatWorld (which owns
## the clock, the targets and the live effects); this file is what it and the effects compute with.
##
## Rule numbers (knockback, stagger, wall slam, aim kick) are here and nowhere else; weapon numbers are in
## MechCatalog.WEAPONS. Both are first-pass and tuned in the lab (`weapon_range`).
##
## FIRE RECORD: the one event a shot is (weapons.md §5, a scheduled effect). Every machine that gets it simulates the
## same flight from these params and the shared clock:
##   {shooter: String, peer: int, hardpoint: String, weapon: String, origin: Vector3, dir: Vector3 (unspread aim),
##    target: Vector3 (the aim point), t: float (shared-clock time the shot left), shot_index: int, spread: float (deg)}
## `peer` is the machine that owns the shooter (1 = host): it decides who resolves hits (CombatWorld.decides).

## Knockback multiplier per mass class (weapons.md §2). "static" takes aim kick instead.
const MASS := {"light": 1.0, "mech": 0.5, "heavy": 0.25, "static": 0.0}
const MASS_ORDER := ["light", "mech", "heavy", "static"]
const FRICTION := 8.0             ## m/s² of knockback speed shed on the ground (none in the air)
## HIT-SLIDE: for HIT_SLIDE_TIME s after any knockback the target slides on SLIDE_FRICTION instead of FRICTION, so a
## stream of small shoves (the gatling, the autocannon) builds into a real slide instead of being swallowed by the
## ground, while a single shove still comes to rest quickly once the hits stop.
const SLIDE_FRICTION := 3.0       ## m/s² while sliding from a fresh hit
const HIT_SLIDE_TIME := 0.35      ## s after each hit
const GRAVITY := 9.8              ## m/s² on a target knocked into the air
const STAGGER_DV := 6.0           ## m/s of knockback (after the mass class) accumulated ...
const STAGGER_WINDOW := 0.5       ## ... within this many seconds staggers the target
const STAGGER_TIME := 0.6         ## s of stagger: no fire, aim thrown
const SLAM_SPEED := 5.0           ## m/s into a wall before a slam hurts
const SLAM_DAMAGE := 4.0          ## damage per m/s over SLAM_SPEED
const AIM_KICK_DEG := 3.0         ## a static target's barrel is thrown off by Δv × this (degrees)
const AIM_KICK_RECOVER := 60.0    ## deg/s back
const PROJECTILE_RADIUS := 0.2    ## m: a projectile's hit shape (never grows: growth is visual only, §4.2)
const SWEEP_STEP := 1.0 / 60.0    ## s: the fixed grid curved flights are swept on (frame-rate independent)
const MIN_PIXELS := 6.0           ## a projectile is never drawn smaller than this on screen (§4.2)


## A fire record (see the header). `dir` is normalized here.
static func fire_record(shooter: String, peer: int, hardpoint: String, weapon: String, origin: Vector3, target: Vector3,
		t: float, shot_index: int, spread: float = 0.0) -> Dictionary:
	var dir := (target - origin).normalized() if target.distance_squared_to(origin) > 1e-8 else Vector3.FORWARD
	return {"shooter": shooter, "peer": peer, "hardpoint": hardpoint, "weapon": weapon, "origin": origin, "dir": dir,
		"target": target, "t": t, "shot_index": shot_index, "spread": spread}


## The id of one shot on every machine (a hit event names it so the others can drop their copy).
static func shot_key(record: Dictionary) -> String:
	return "%s/%s/%d" % [record["shooter"], record["hardpoint"], int(record["shot_index"])]


## The shot generator (§4.5): every random number in a shot comes from here, so every machine draws the same shot.
static func shot_rng(mission_seed: int, shooter: String, hardpoint: String, shot_index: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([mission_seed, shooter, hardpoint, shot_index])
	return rng


## `dir` thrown off by up to `deg` degrees (uniform over the cone's disc), drawn from `rng`.
static func spread_dir(dir: Vector3, deg: float, rng: RandomNumberGenerator) -> Vector3:
	var r := deg_to_rad(deg) * sqrt(rng.randf())
	var phi := TAU * rng.randf()
	if r <= 0.0:
		return dir.normalized()
	var side := dir.cross(Vector3.UP if absf(dir.normalized().y) < 0.99 else Vector3.RIGHT).normalized()
	var up := side.cross(dir).normalized()
	var axis := (side * cos(phi) + up * sin(phi)).normalized()
	return dir.normalized().rotated(axis, r)


## Share of full damage at `dist` m: 1 up to falloff_start, down to falloff_min at range (weapons.md §3).
static func falloff(stats: Dictionary, dist: float) -> float:
	var a := float(stats.get("falloff_start", 0.0))
	var b := float(stats.get("range", 0.0))
	var lo := float(stats.get("falloff_min", 1.0))
	if dist <= a or b <= a:
		return 1.0
	return lerpf(1.0, lo, clampf((dist - a) / (b - a), 0.0, 1.0))


## Drawn scale of a projectile `d` m from the muzzle (§4.2): s0 × lerp(1, g, smoothstep(0, d_full, d)). Visual only.
static func growth_scale(s0: float, g: float, d_full: float, d: float) -> float:
	return s0 * lerpf(1.0, g, smoothstep(0.0, maxf(d_full, 0.001), d))


## Where along p0 -> p1 (0..1) the segment first touches a sphere, or -1. A start inside the sphere counts as 0.
static func segment_sphere(p0: Vector3, p1: Vector3, c: Vector3, r: float) -> float:
	var d := p1 - p0
	var f := p0 - c
	var cc := f.dot(f) - r * r
	if cc <= 0.0:
		return 0.0
	var a := d.dot(d)
	if a < 1e-12:
		return -1.0
	var b := f.dot(d)
	var disc := b * b - a * cc
	if disc < 0.0 or b > 0.0:
		return -1.0
	var t := (-b - sqrt(disc)) / a
	return t if t >= 0.0 and t <= 1.0 else -1.0


## A basis whose -Z looks along `dir` (any up that isn't parallel).
static func look_basis(dir: Vector3) -> Basis:
	var d := dir.normalized()
	if d.length_squared() < 1e-8:
		return Basis.IDENTITY
	return Basis.looking_at(d, Vector3.UP if absf(d.y) < 0.99 else Vector3.RIGHT)


# --- Fire arcs (weapons.md §4.4) -----------------------------------------------------------------------------
## PIVOTING DIRECT-FIRE WEAPONS (WeaponMount.pivoting): every straight-flight player weapon (laser, autocannon, gatling,
## rockets, missiles, railgun, flamer; not the mortar, not enemy weapons, not the swivel, which tracks on its own) turns
## at its mount toward the aim point at stats.slew °/s (default PIVOT_SLEW), within ±yaw_arc yaw and
## -pitch_down..+pitch_up pitch of the body (defaults PIVOT_YAW / PIVOT_PITCH_DOWN / PIVOT_PITCH_UP), and its shots
## leave along the barrel. Outside that range the barrel parks at its limit.
const PIVOT_YAW := 30.0
const PIVOT_PITCH_DOWN := 50.0
const PIVOT_PITCH_UP := 45.0
const PIVOT_SLEW := 180.0
const ON_TARGET_DEG := 1.0        ## a barrel within this of the direction pivot -> aim point is on target (HUD)
## FIXED-WEAPON ARC SWITCH, default OFF (open question 2 in docs/paused/weapons.md: the user hasn't decided). ON: every
## pivoting weapon holds fire (WeaponMount.hold_reason = OUT_OF_ARC) while the aim point is outside its pivot range
## (pivot_limits, seen from its pivot): the fire arc IS the pivot range, one set of numbers. Exempt: weapons with their
## own arc (own_arc: the swivel boom), arcing fire (kind "arc": the mortar), guided missiles (kind "missile" /
## designator_heat) and enemy weapons. OFF: a weapon aimed outside its range fires along its parked barrel.
## Turn it on with `Combat.FIXED_ARC_ENABLED = true`, or the weapon_range lab option "Fixed arcs".
static var FIXED_ARC_ENABLED := false
const FIXED_ARC_YAW := PIVOT_YAW
const FIXED_ARC_PITCH_DOWN := PIVOT_PITCH_DOWN
const FIXED_ARC_PITCH_UP := PIVOT_PITCH_UP
const OUT_OF_ARC := "OUT OF ARC"


## Does this weapon pivot at its mount (see PIVOTING above)? Straight-flight player weapons without their own arc.
static func pivots(weapon_id: String, st: Dictionary) -> bool:
	return not weapon_id.begins_with("enemy_") and str(st.get("kind", "")) != "arc" and not own_arc(weapon_id)


## A weapon that aims its own barrel (its behaviour shapes its records: the swivel boom).
static func own_arc(weapon_id: String) -> bool:
	var b := WeaponRegistry.behaviour(weapon_id)
	return b != null and b.has_method("shape_record")


## A pivoting weapon's range: Vector3(yaw half-width, pitch down, pitch up), degrees (catalog keys or the defaults).
static func pivot_limits(st: Dictionary) -> Vector3:
	return Vector3(float(st.get("yaw_arc", PIVOT_YAW)), float(st.get("pitch_down", PIVOT_PITCH_DOWN)),
		float(st.get("pitch_up", PIVOT_PITCH_UP)))


## `dir` in a body's frame as Vector2(yaw, pitch) in degrees: yaw + = right of the body's forward (-Z), pitch + = up
## (the body's +Y). Scale in `body` is ignored.
static func arc_angles(body: Basis, dir: Vector3) -> Vector2:
	var l := body.orthonormalized().inverse() * dir.normalized()
	return Vector2(rad_to_deg(atan2(l.x, -l.z)), rad_to_deg(asin(clampf(l.y, -1.0, 1.0))))


## The world direction of body-frame Vector2(yaw, pitch) degrees (the inverse of arc_angles).
static func arc_dir(body: Basis, yaw_pitch: Vector2) -> Vector3:
	var y := deg_to_rad(yaw_pitch.x)
	var p := deg_to_rad(yaw_pitch.y)
	return (body.orthonormalized() * Vector3(sin(y) * cos(p), sin(p), -cos(y) * cos(p))).normalized()


## Body-frame angles `a` (arc_angles) within ±yaw, -down..+up.
static func in_arc(a: Vector2, yaw: float, down: float, up: float) -> bool:
	return absf(a.x) <= yaw + 1e-4 and a.y >= -down - 1e-4 and a.y <= up + 1e-4


## Does the fixed-weapon arc hold this weapon (the switch is on and the weapon isn't exempt, see above)?
static func fixed_arc_applies(weapon_id: String, st: Dictionary) -> bool:
	var kind := str(st.get("kind", ""))
	return FIXED_ARC_ENABLED and not weapon_id.begins_with("enemy_") and kind != "arc" and kind != "missile" \
		and not own_arc(weapon_id) and not st.has("designator_heat")


## Is the aim point `aim`, seen from `origin`, inside the fixed-weapon arc of `body`?
static func in_fixed_arc(body: Basis, origin: Vector3, aim: Vector3) -> bool:
	if aim.distance_squared_to(origin) < 1e-6:
		return true
	return in_arc(arc_angles(body, aim - origin), FIXED_ARC_YAW, FIXED_ARC_PITCH_DOWN, FIXED_ARC_PITCH_UP)
