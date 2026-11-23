class_name Missile
extends Rocket
## A guided missile (weapons.md §3.6): leaves the pod like a rocket, then steers toward ITS SHOOTER'S LIVE AIM POINT for
## its whole flight (user decision: the crosshair is the track; no lock-on, no designator button).
##
## STEERING, every fixed STEP (1/60 s) of flight, from world.designators[record.shooter] = {on, dot} (written each step
## by the shooter's WeaponRack, or the weapon_range lab):
##   on    turn the heading toward `dot` by at most stats.turn_rate °/s, and speed up from stats.speed toward
##         stats.speed_max at ACCEL m/s²
##   off   (no entry, shooter shut down, slot disabled) fly straight on the current heading at the current speed;
##         when `on` comes back it steers again
## Self-destructs with its explosion at stats.lifetime (Rocket.on_expire's air burst); a contact detonates as a rocket.
##
## NET (design §5: scheduled effect + owner-streamed input): the launch is the fire record; the path is integrated in
## fixed STEP steps (never per-frame dt) and kept, so flight_pos(e) is a lookup and the sweep runs on the same grid
## (Combat.SWEEP_STEP). Step k is integrated on the first world advance whose clock passes k × STEP and reads the
## designator as it is at that advance: the same sequence of designator samples gives the same path at any frame rate.
## A missile started late (a network event arriving after record.t) fast-forwards every missed step with the CURRENT
## designator state: that is the accepted divergence (only the deciding machine's path counts, its detonation is an
## event). The designator's dot is the shooter's aim point (OWNER state of the shooter's mech).
##
## LASER LINE: while any of a shooter's missiles from one hardpoint flies, one MissileLaser (scripts/combat/
## missile_laser.gd) draws the red line launcher -> dot; the first live missile creates it, it removes itself after the
## last one.

const STEP := 1.0 / 60.0          ## s: the fixed guidance step (= Combat.SWEEP_STEP, so sweep chords are guidance steps)
const ACCEL := 20.0               ## m/s² while tracking (35 -> 55 m/s in 1 s)
const PUFF_JITTER := 0.35         ## share of the rocket's puff jitter: a thinner, straighter trail
## Red-tinted greys a puff steps through by age (lighter -> darker).
const MISSILE_PUFFS := [Color(0.82, 0.68, 0.66), Color(0.68, 0.55, 0.54), Color(0.53, 0.44, 0.44), Color(0.39, 0.33, 0.34)]

var turn_rate := 120.0            ## °/s (stats.turn_rate)
var speed_max := 55.0             ## m/s (stats.speed_max)
var _pos := PackedVector3Array()  ## position at k × STEP, k = 0.._pos.size()-1
var _head := PackedVector3Array() ## [0] = the launch heading, [k] = the heading flown over step k-1 -> k
var _spd := PackedFloat32Array()  ## same indexing: speed
var _dist := PackedFloat32Array() ## distance flown at k × STEP


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({"turn_rate": Net.SPAWN, "speed_max": Net.SPAWN, "_pos": Net.LOCAL, "_head": Net.LOCAL, "_spd": Net.LOCAL,
		"_dist": Net.LOCAL})
	return f


## The launch: the pod's tube and the (zero) seeded spread like a rocket; no wobble. One draw for the exhaust flicker phase.
func setup_flight(rng: RandomNumberGenerator) -> void:
	dir = Combat.spread_dir(record["dir"], float(record.get("spread", 0.0)), rng)
	launch = origin + launch_offset()
	wobble = 0.0
	wobble_phase = TAU * rng.randf()
	turn_rate = float(stats.get("turn_rate", 120.0))
	speed_max = maxf(float(stats.get("speed_max", speed)), speed)
	max_time = maxf(float(stats.get("lifetime", 9.0)), STEP)
	_pos = PackedVector3Array([launch])
	_head = PackedVector3Array([dir])
	_spd = PackedFloat32Array([speed])
	_dist = PackedFloat32Array([0.0])


func wobble_offset(_e: float) -> Vector3:
	return Vector3.ZERO


func sub_step() -> float:
	return STEP


# --- Guidance ----------------------------------------------------------------------------------------

## Steps integrated so far.
func steps() -> int:
	return _pos.size() - 1


## Integrate one STEP with the shooter's designator as it is now.
func _integrate_step() -> void:
	var n := steps()
	var p := _pos[n]
	var h := _head[n]
	var s := _spd[n]
	var d: Dictionary = world.designators.get(str(record.get("shooter", "")), {})
	if bool(d.get("on", false)) and d.get("dot") is Vector3:
		var to: Vector3 = (d["dot"] as Vector3) - p
		if to.length_squared() > 1e-6:
			h = turn_toward(h, to.normalized(), deg_to_rad(turn_rate) * STEP)
		s = minf(s + ACCEL * STEP, speed_max)
	_pos.append(p + h * s * STEP)
	_head.append(h)
	_spd.append(s)
	_dist.append(_dist[n] + s * STEP)


## `h` turned toward `want` (both unit) by at most `max_angle` radians.
static func turn_toward(h: Vector3, want: Vector3, max_angle: float) -> Vector3:
	var ang := h.angle_to(want)
	if ang < 1e-7:
		return h
	if ang <= max_angle:
		return want
	var axis := h.cross(want)
	if axis.length_squared() < 1e-12:       # straight behind: turn up (or sideways when flying vertically)
		axis = h.cross(Vector3.UP if absf(h.y) < 0.99 else Vector3.RIGHT)
	return h.rotated(axis.normalized(), max_angle).normalized()


func advance_to(now: float) -> void:
	if end_time < 0.0:
		var need := mini(int(ceil((now - t0) / STEP - 1e-6)), int(ceil(max_time / STEP - 1e-6)))
		while steps() < need:
			_integrate_step()
	super.advance_to(now)
	if end_time < 0.0:
		_ensure_laser()


# --- Flight (lookups into the integrated path) ---------------------------------------------------------

func flight_pos(e: float) -> Vector3:
	var x := maxf(e, 0.0) / STEP
	var n := steps()
	var i := int(floor(x))
	if i >= n:
		return _pos[n] + _head[n] * _spd[n] * (maxf(e, 0.0) - float(n) * STEP)
	return _pos[i].lerp(_pos[i + 1], x - float(i))


func flight_dir(e: float) -> Vector3:
	return _head[clampi(int(floor(maxf(e, 0.0) / STEP)) + 1, 0, steps())]


func flight_dist(e: float) -> float:
	var x := maxf(e, 0.0) / STEP
	var n := steps()
	var i := int(floor(x))
	if i >= n:
		return _dist[n] + _spd[n] * (maxf(e, 0.0) - float(n) * STEP)
	return lerpf(_dist[i], _dist[i + 1], x - float(i))


## Speed at flight time e (the step's speed).
func flight_speed(e: float) -> float:
	return _spd[clampi(int(floor(maxf(e, 0.0) / STEP)) + 1, 0, steps())]


# --- Laser line -------------------------------------------------------------------------------------

func _ensure_laser() -> void:
	if world == null:
		return
	var nm := MissileLaser.node_name(record)
	var l := world.get_node_or_null(NodePath(nm)) as MissileLaser
	if l != null and not l.finished():
		return
	l = MissileLaser.new()
	l.setup(world, record)
	world._add_effect(l)
	l.advance_to(world.now)


# --- Look -------------------------------------------------------------------------------------------

func build_body() -> Node3D:
	var root := Node3D.new()
	root.add_child(CombatMeshes.instance(missile_mesh()))
	_flame = CombatMeshes.instance(LowPolyFlame.jet())
	root.add_child(_flame)
	return root


## Build ahead of time the cached look a Missile draws (body, exhaust, the first puff node's mesh and its red puffs, the
## laser line's dot, muzzle flash): see Projectile.prewarm_look.
static func prewarm_missile() -> void:
	missile_mesh()
	LowPolyFlame.jet()
	CombatMeshes.ico(PUFF_RAMP[0])
	for c: Color in MISSILE_PUFFS:
		CombatMeshes.ico(c)
	CombatMeshes.ico(CombatMeshes.RED, true)
	MuzzleFlash.mesh()


## 1 unit long along -Z (nose at -0.5): a slimmer, longer-reading body than the rocket, white with a red band, a red tip,
## four red tail fins and four small red canards, a dark nozzle.
static func missile_mesh() -> ArrayMesh:
	var key := "missile_mesh"
	if CombatMeshes._cache.has(key):
		return CombatMeshes._cache[key]
	var red := MechMeshes.MISSILE_RED
	var k := MeshKit.new()
	k.push(Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3.ZERO))      # lathe +Y -> -Z (the nose)
	k.lathe([Vector2(0.05, -0.44), Vector2(0.068, -0.4), Vector2(0.068, 0.12)], 6, MechMeshes.WHITE, true, false)
	k.lathe([Vector2(0.068, 0.12), Vector2(0.068, 0.24)], 6, red, false, false)
	k.lathe([Vector2(0.068, 0.24), Vector2(0.042, 0.41)], 6, MechMeshes.WHITE, false, false)
	k.lathe([Vector2(0.042, 0.41), Vector2(0.0, 0.5)], 6, red, false, false)
	k.lathe([Vector2(0.05, -0.44), Vector2(0.06, -0.5)], 6, MechMeshes.DARK, false, true)
	for f in 4:
		var a := TAU * float(f) / 4.0 + PI * 0.25
		k.push(Transform3D(Basis(Vector3.UP, a), Vector3.ZERO))
		k.box(Vector3(0.12, 0.17, 0.02), red, Vector3(0.11, -0.33, 0.0))
		k.box(Vector3(0.06, 0.07, 0.016), red, Vector3(0.085, 0.06, 0.0))
		k.pop()
	k.pop()
	var m := k.commit(MechMeshes.materials())
	CombatMeshes._cache[key] = m
	return m


func puff_color(age_frac: float) -> Color:
	return MISSILE_PUFFS[clampi(int(age_frac * MISSILE_PUFFS.size()), 0, MISSILE_PUFFS.size() - 1)]


## Smaller puffs for the drawn size than the rocket's: the bigger missile body (catalog size / growth) stays in front.
func puff_size(e: float) -> float:
	return 0.12 + drawn_scale(e) * 0.15


## The rocket's puff jitter scaled down: the chain stays on the flight line.
func puff_jitter_scale() -> float:
	return PUFF_JITTER
