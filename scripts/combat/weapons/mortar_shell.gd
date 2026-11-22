class_name MortarShell
extends Projectile
## The Back Mortar's shell (weapons.md §3.7): a ballistic arc from the muzzle to the LANDING point (the fire record's aim
## point + seeded scatter). Flight time T = flight_base + flight_per_100 × range / 100 (range = horizontal distance to
## the aim point); the arc is the parabola through both ends with apex `apex(range)` above the chord, i.e. constant
## gravity 8 h / T². So the whole flight is a pure function of the flight time e: the same on every machine, at every
## frame rate, and when started late. No line of sight is needed; the shell detonates on whatever it meets first
## (ceiling, wall, target, ground), swept on the fixed Combat.SWEEP_STEP grid. Nothing met by T: it bursts at the landing
## point.
##
## Hit: `damage` to a directly hit target, splash (splash_damage within splash_radius, linear falloff) to the others;
## knockback is radial from the blast (knockback / splash_knockback) plus lift (splash_lift) for both.
## Telegraph (cosmetic, but drawn from the same record, so everyone sees it): a flat faceted ring at the splash radius on
## the ground under the landing point and a second ring closing on the landing point as the shell falls; both stay
## from launch to impact (T >= flight_base >= 2 s).

const SCATTER_RING_SIDES := 20
const RING_CLOSE_TO := 0.6         ## m: the closing ring's radius at impact
const COLUMN_HEIGHT := 16.0        ## m: the explosion's column (ImpactFx.add_column)
const TUMBLE_ROLL := 1.7           ## rad/s about the shell's axis
const TUMBLE_PITCH := 0.45         ## rad of slow end-over-end wobble ...
const TUMBLE_RATE := 1.3           ## ... at this rate (rad/s)

var landing := Vector3.ZERO        ## aim point + scatter: where the arc ends
var range_m := 0.0                 ## horizontal distance origin -> aim point
var flight_time := 2.0             ## T
var apex_h := 10.0                 ## m above the chord's midpoint
var scatter := Vector3.ZERO        ## the landing offset drawn from the shot generator
var ring_y := 0.0                  ## height of the telegraph rings (ground under the landing point)
var _ring_outer: MeshInstance3D
var _ring_inner: MeshInstance3D


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({"landing": Net.SPAWN, "range_m": Net.SPAWN, "flight_time": Net.SPAWN, "apex_h": Net.SPAWN, "scatter": Net.SPAWN,
		"ring_y": Net.LOCAL, "_ring_outer": Net.LOCAL, "_ring_inner": Net.LOCAL})
	return f


## Flight time for a range (m), from the catalog numbers.
static func flight_time_for(st: Dictionary, dist: float) -> float:
	return float(st.get("flight_base", 2.0)) + float(st.get("flight_per_100", 1.0)) * dist / 100.0


## Scatter radius (m) at a range: 0 at min_range, scatter_max at range.
static func scatter_for(st: Dictionary, dist: float) -> float:
	var lo := float(st.get("min_range", 30.0))
	var hi := float(st.get("range", 250.0))
	return float(st.get("scatter_max", 3.0)) * clampf((dist - lo) / maxf(hi - lo, 0.001), 0.0, 1.0)


## Apex height above the chord (m) at a range: apex_min at min_range up to apex_max at range (under the 40 m ceiling).
static func apex_for(st: Dictionary, dist: float) -> float:
	var lo := float(st.get("min_range", 30.0))
	var hi := float(st.get("range", 250.0))
	return lerpf(float(st.get("apex_min", 10.0)), float(st.get("apex_max", 28.0)), clampf((dist - lo) / maxf(hi - lo, 0.001), 0.0, 1.0))


static func horizontal(a: Vector3, b: Vector3) -> float:
	return Vector2(b.x - a.x, b.z - a.z).length()


func start(w: CombatWorld, rec: Dictionary, st: Dictionary) -> void:
	# CombatEffect.start, then our own flight setup (Projectile.start's straight-line setup doesn't apply).
	world = w
	record = rec
	stats = st
	t0 = float(rec.get("t", w.now))
	origin = rec["origin"]
	var target: Vector3 = rec["target"]
	range_m = horizontal(origin, target)
	var rng := Combat.shot_rng(w.mission_seed, str(rec["shooter"]), str(rec["hardpoint"]), int(rec["shot_index"]))
	var r := scatter_for(st, range_m) * sqrt(rng.randf())
	var phi := TAU * rng.randf()
	scatter = Vector3(cos(phi) * r, 0.0, sin(phi) * r)
	landing = target + scatter
	flight_time = flight_time_for(st, range_m)
	apex_h = apex_for(st, range_m)
	max_time = flight_time
	dir = (landing - origin).normalized() if landing.distance_squared_to(origin) > 1e-8 else Vector3.FORWARD
	speed = range_m / flight_time
	var gy := w.ground_below(landing + Vector3.UP * 0.5, 80.0)
	ring_y = (gy if not is_nan(gy) else landing.y) + 0.06
	_build_look()


## The gravity the arc falls under (m/s²): chosen so the apex fits the flight time.
func gravity() -> float:
	return 8.0 * apex_h / (flight_time * flight_time)


# --- Flight ---------------------------------------------------------------------------------------------

func flight_pos(e: float) -> Vector3:
	var u := e / flight_time
	return origin.lerp(landing, u) + Vector3.UP * (4.0 * apex_h * u * (1.0 - u))


func flight_dir(e: float) -> Vector3:
	var u := e / flight_time
	var v := (landing - origin) / flight_time + Vector3.UP * (4.0 * apex_h * (1.0 - 2.0 * u) / flight_time)
	return v.normalized() if v.length_squared() > 1e-10 else Vector3.DOWN


## Horizontal distance travelled (falloff; the mortar has none inside its range).
func flight_dist(e: float) -> float:
	return range_m * clampf(e / flight_time, 0.0, 1.0)


func sub_step() -> float:
	return Combat.SWEEP_STEP


# --- Clock --------------------------------------------------------------------------------------------

## The sweep is Projectile's curved sweep (fixed grid k × SWEEP_STEP from the last grid point swept, then T itself),
## so the chords are the same at any frame step and when started late. Reaching T with nothing met: `_land`.
func reach_range() -> void:
	_land()


## Nothing met by T: the ground just under the landing point (a short probe on along the arc), else the point itself.
func _land() -> void:
	var a := flight_pos(flight_time)
	var b := a + flight_dir(flight_time) * 1.5
	var h := world.first_hit(a, b, Combat.PROJECTILE_RADIUS, str(record.get("shooter", "")), pierced)
	if h.is_empty():
		h = {"target": null, "component": "", "point": landing, "normal": Vector3.UP, "frac": 0.0, "color": MechMeshes.GREY}
	on_hit(h, flight_time)
	end_time = flight_time


## Direct hit: damage + radial knockback with lift; splash on everyone else; the big explosion with its column.
func on_hit(h: Dictionary, e: float) -> bool:
	var point: Vector3 = h["point"]
	var target: CombatTarget = h["target"]
	if target != null:
		pierced.append(target.target_id)
		var centre := target.global_position
		for s: Dictionary in target.world_spheres():
			if str(s["component"]) == str(h["component"]):
				centre = s["center"]
				break
		var out := centre - point
		out.y = 0.0
		if out.length_squared() < 1e-4:
			out = flight_dir(e)
			out.y = 0.0
		var kv := out.normalized() * float(stats.get("knockback", 0.0)) + Vector3.UP * float(stats.get("splash_lift", 0.0))
		var st := stats.duplicate()
		st["knockback"] = kv.length()
		world.resolve_hit(record, st, target, str(h["component"]), point, h["normal"], kv, float(stats.get("damage", 0.0)))
	world.hit_prop(record, stats, h, flight_dir(e))
	world.splash(record, stats, point, target)
	var fx := world.spawn_impact(point, h["normal"], float(stats.get("impact_radius", 6.0)), h.get("color", MechMeshes.GREY), true)
	if fx != null:
		fx.add_column(COLUMN_HEIGHT)
	return true


# --- Look ---------------------------------------------------------------------------------------------

## Drawn scale: s0 growing to g × s0 over the descent (visual only).
func drawn_scale(e: float) -> float:
	var s0 := float(stats.get("size", 0.7))
	return s0 * lerpf(1.0, float(stats.get("growth", 3.0)), smoothstep(0.3, 0.85, e / flight_time))


## Telegraph: is the ring up, and the closing ring's radius now.
func telegraph_visible() -> bool:
	return end_time < 0.0 and _ring_inner != null


func ring_radius(e: float) -> float:
	return lerpf(float(stats.get("splash_radius", 8.0)), RING_CLOSE_TO, clampf(e / flight_time, 0.0, 1.0))


func _build_look() -> void:
	_shell = CombatMeshes.instance(shell_mesh())
	_shell.top_level = true
	add_child(_shell)
	if float(stats.get("trail", 0.0)) > 0.0:
		_trail_mesh = ImmediateMesh.new()
		_trail = CombatMeshes.instance(_trail_mesh)
		_trail.top_level = true
		add_child(_trail)
	_ring_outer = CombatMeshes.instance(CombatMeshes.ring(MechMeshes.ORANGE, 0.93, SCATTER_RING_SIDES))
	_ring_outer.top_level = true
	add_child(_ring_outer)
	_ring_inner = CombatMeshes.instance(CombatMeshes.ring(CombatMeshes.RED, 0.8, SCATTER_RING_SIDES))
	_ring_inner.top_level = true
	add_child(_ring_inner)


## A fat dark shell, 1 m long along -Z (nose at -0.5): a 6-sided lathe, an orange band, four tail fins.
static func shell_mesh() -> ArrayMesh:
	return CombatMeshes._mesh("mortar_shell", func(k: MeshKit) -> void:
		k.push(MeshKit.xf(Vector3.ZERO, Vector3(-90, 0, 0)))      # lathe +Y -> -Z
		k.lathe([Vector2(0.13, -0.5), Vector2(0.2, -0.42), Vector2(0.29, -0.2), Vector2(0.3, 0.1), Vector2(0.22, 0.32),
			Vector2(0.09, 0.46), Vector2(0.0, 0.5)], 6, MechMeshes.DARK)
		k.lathe([Vector2(0.315, -0.06), Vector2(0.315, 0.08)], 6, MechMeshes.ORANGE)
		for i in 4:
			k.push(MeshKit.xf(Vector3.ZERO, Vector3(0, 45 + 90 * i, 0)))
			k.box(Vector3(0.04, 0.22, 0.42), MechMeshes.GUN, Vector3(0, -0.4, 0.18))
			k.pop()
		k.pop())


func _update_look() -> void:
	if not is_inside_tree():
		return
	var flying := end_time < 0.0
	_shell.visible = flying
	if flying:
		var p := flight_pos(elapsed)
		var tumble := Basis(Vector3.RIGHT, TUMBLE_PITCH * sin(elapsed * TUMBLE_RATE)) * Basis(Vector3.BACK, elapsed * TUMBLE_ROLL)
		_shell.global_transform = Transform3D(Combat.look_basis(flight_dir(elapsed)) * tumble * Basis.from_scale(Vector3.ONE * _screen_scale(elapsed, p)), p)
	var g := Vector3(landing.x, ring_y, landing.z)
	_ring_outer.visible = flying
	_ring_inner.visible = flying
	if flying:
		_ring_outer.global_transform = Transform3D(Basis.from_scale(Vector3.ONE * float(stats.get("splash_radius", 8.0))), g)
		_ring_inner.global_transform = Transform3D(Basis.from_scale(Vector3.ONE * ring_radius(elapsed)), g + Vector3.UP * 0.02)
	if _trail_mesh != null:
		_draw_trail()
