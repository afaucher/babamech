class_name MortarShell
extends Projectile
## The Back Mortar's shell (weapons.md §3.7): a ballistic arc from the muzzle to the LANDING point (the fire record's aim
## point + seeded scatter). Flight time T = flight_base + flight_per_100 × range / 100 (range = distance to the aim
## point along the deck: horizontal on a flat floor, see CURVED DECKS); the arc is the parabola through both ends with apex `apex(range)` above the chord, i.e. constant
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
##
## CURVED DECKS (weapons.md §3.7 "On a ring deck"; code-audit-2026-11): with a deck frame (`frame` = CombatWorld.ring_at
## of the record's aim point: the stack's ring of the deck under it, else the world's `ring`) the shot lives in that
## deck's ARC COORDINATES (x along the axis, s along the deck, h above the floor; every deck shares the axis): range is
## sqrt(dx² + ds²) (deck_distance: the arc along that deck's floor, height ignored, as on a flat floor), scatter is an
## offset in (x, s) at the aim point's h, and the arc is x and s linear in u = e / T with h = lerp(h0, h1, u) +
## 4·apex·u(1-u). So "up" is the local up at every point of the flight (radial about the ring axis), the apex is apex(range)
## above the chord measured as height above the deck, the shell can't dip under the curved floor between two points
## above it and clears the ceiling exactly as on a flat floor, and T is the flat floor's for the same deck distance.
## Every input is the record plus the stack's fixed geometry: the same on every machine. No frame (the lab, a test world):
## the flat formulas, unchanged. Direct-hit knockback uses the target's own `up`, like CombatWorld's splash.

const SCATTER_RING_SIDES := 20
const RING_CLOSE_TO := 0.6         ## m: the closing ring's radius at impact
const COLUMN_HEIGHT := 16.0        ## m: the explosion's column (ImpactFx.add_column)
const TUMBLE_ROLL := 1.7           ## rad/s about the shell's axis
const TUMBLE_PITCH := 0.45         ## rad of slow end-over-end wobble ...
const TUMBLE_RATE := 1.3           ## ... at this rate (rad/s)

var landing := Vector3.ZERO        ## aim point + scatter: where the arc ends
var range_m := 0.0                 ## distance origin -> aim point along the deck (deck_distance; flat: horizontal)
var flight_time := 2.0             ## T
var apex_h := 10.0                 ## m above the chord's midpoint (along the local up)
var scatter := Vector3.ZERO        ## the landing offset drawn from the shot generator
var frame: RingFrame = null        ## the deck frame under the aim point (see CURVED DECKS), null = flat floor
var arc0 := Vector3.ZERO           ## the muzzle in frame's arc coordinates (x, s, h); x is world x
var arc1 := Vector3.ZERO           ## the landing point, s unwrapped to the short way round from arc0
var ring_y := 0.0                  ## height of the telegraph rings (ground under the landing point)
var ring_pos := Vector3.ZERO       ## the telegraph rings' centre (on the ground under the landing point)
var ring_basis := Basis.IDENTITY   ## and their orientation (Y = the local up there)
var _ring_outer: MeshInstance3D
var _ring_inner: MeshInstance3D


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({"landing": Net.SPAWN, "range_m": Net.SPAWN, "flight_time": Net.SPAWN, "apex_h": Net.SPAWN, "scatter": Net.SPAWN,
		"frame": Net.LOCAL, "arc0": Net.SPAWN, "arc1": Net.SPAWN,
		"ring_y": Net.LOCAL, "ring_pos": Net.LOCAL, "ring_basis": Net.LOCAL, "_ring_outer": Net.LOCAL, "_ring_inner": Net.LOCAL})
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


## The deck frame a mortar shot at `p` uses: CombatWorld.ring_at(p) (the stack's ring of the deck under p, else the
## world's `ring`), or null on a flat floor.
static func frame_at(w: CombatWorld, p: Vector3) -> RingFrame:
	return w.ring_at(p) if w != null else null


## Distance a -> b along the deck, height ignored: the horizontal distance on a flat floor (frame null), else
## sqrt(dx² + ds²) with ds the arc along the frame's floor (the short way round). The range gate and range_m use it.
static func deck_distance(fr: RingFrame, a: Vector3, b: Vector3) -> float:
	if fr == null:
		return horizontal(a, b)
	return Vector2(b.x - a.x, _ds(fr, fr.world_to_arc(a), fr.world_to_arc(b))).length()


## s(b) - s(a) in fr's arc coordinates, wrapped to the short way round.
static func _ds(fr: RingFrame, a: Vector3, b: Vector3) -> float:
	var half := PI * fr.radius
	return wrapf(b.y - a.y, -half, half)


## World point of arc coordinates (x = world x, s, h) in `frame` (RingFrame's own x would add a DeckRing's origin x).
func _arc_world(x: float, s: float, h: float) -> Vector3:
	var p := frame.arc_to_world(0.0, s, h)
	p.x = x
	return p


func start(w: CombatWorld, rec: Dictionary, st: Dictionary) -> void:
	# CombatEffect.start, then our own flight setup (Projectile.start's straight-line setup doesn't apply).
	world = w
	record = rec
	stats = st
	t0 = float(rec.get("t", w.now))
	origin = rec["origin"]
	var target: Vector3 = rec["target"]
	frame = frame_at(w, target)
	range_m = deck_distance(frame, origin, target)
	var rng := Combat.shot_rng(w.mission_seed, str(rec["shooter"]), str(rec["hardpoint"]), int(rec["shot_index"]))
	var r := scatter_for(st, range_m) * sqrt(rng.randf())
	var phi := TAU * rng.randf()
	if frame == null:
		scatter = Vector3(cos(phi) * r, 0.0, sin(phi) * r)
		landing = target + scatter
	else:
		var at := frame.world_to_arc(target)
		landing = _arc_world(target.x + cos(phi) * r, at.y + sin(phi) * r, at.z)     # on the deck, at the aim's height
		scatter = landing - target
		arc0 = frame.world_to_arc(origin)
		arc0.x = origin.x
		arc1 = frame.world_to_arc(landing)
		arc1.x = landing.x
		arc1.y = arc0.y + _ds(frame, arc0, arc1)
	flight_time = flight_time_for(st, range_m)
	apex_h = apex_for(st, range_m)
	max_time = flight_time
	dir = (landing - origin).normalized() if landing.distance_squared_to(origin) > 1e-8 else Vector3.FORWARD
	speed = range_m / flight_time
	if frame == null:
		var gy := w.ground_below(landing + Vector3.UP * 0.5, 80.0)
		ring_y = (gy if not is_nan(gy) else landing.y) + 0.06
		ring_pos = Vector3(landing.x, ring_y, landing.z)
		ring_basis = Basis.IDENTITY
	else:
		var up := frame.up_at(landing)
		var sb := w.surface_below(landing + up * 0.5, up, 80.0)
		var ground: Vector3 = sb["point"] if sb.has("point") else landing
		ring_pos = ground + up * 0.06
		ring_basis = frame.basis_at(landing)
		ring_y = ring_pos.y
	_build_look()


## The gravity the arc falls under (m/s²): chosen so the apex fits the flight time.
func gravity() -> float:
	return 8.0 * apex_h / (flight_time * flight_time)


# --- Flight ---------------------------------------------------------------------------------------------

func flight_pos(e: float) -> Vector3:
	var u := e / flight_time
	var lift := 4.0 * apex_h * u * (1.0 - u)
	if frame == null:
		return origin.lerp(landing, u) + Vector3.UP * lift
	return _arc_world(lerpf(arc0.x, arc1.x, u), lerpf(arc0.y, arc1.y, u), lerpf(arc0.z, arc1.z, u) + lift)


## The flight direction: d flight_pos / de. On a deck frame: x' along X, s' along the floor tangent scaled to the shell's
## distance from the axis (r / radius), h' along the local up.
func flight_dir(e: float) -> Vector3:
	var u := e / flight_time
	var v: Vector3
	if frame == null:
		v = (landing - origin) / flight_time + Vector3.UP * (4.0 * apex_h * (1.0 - 2.0 * u) / flight_time)
	else:
		var p := flight_pos(e)
		v = (Vector3.RIGHT * (arc1.x - arc0.x) + frame.tangent_at(p) * ((arc1.y - arc0.y) * frame.dist_to_axis(p) / frame.radius)
			+ frame.up_at(p) * (arc1.z - arc0.z + 4.0 * apex_h * (1.0 - 2.0 * u))) / flight_time
	return v.normalized() if v.length_squared() > 1e-10 else -_up_at(landing)


## The local up at p: the frame's, else world +Y.
func _up_at(p: Vector3) -> Vector3:
	return frame.up_at(p) if frame != null else Vector3.UP


## Distance travelled along the deck (falloff; the mortar has none inside its range).
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
		h = {"target": null, "component": "", "point": landing, "normal": _up_at(landing), "frac": 0.0, "color": MechMeshes.GREY}
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
		# Radial along the target's own ground plane + lift along its up (CombatWorld._splash does the same).
		var up := target.up.normalized() if target.up.length_squared() > 1e-6 else _up_at(point)
		var out := centre - point
		out -= up * out.dot(up)
		if out.length_squared() < 1e-4:
			out = flight_dir(e)
			out -= up * out.dot(up)
		var kv := out.normalized() * float(stats.get("knockback", 0.0)) + up * float(stats.get("splash_lift", 0.0))
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
		_trail_mesh = ArrayMesh.new()
		_trail = CombatMeshes.instance(_trail_mesh)
		_trail.top_level = true
		add_child(_trail)
	_ring_outer = CombatMeshes.instance(CombatMeshes.ring(MechMeshes.ORANGE, 0.93, SCATTER_RING_SIDES))
	_ring_outer.top_level = true
	add_child(_ring_outer)
	_ring_inner = CombatMeshes.instance(CombatMeshes.ring(CombatMeshes.RED, 0.8, SCATTER_RING_SIDES))
	_ring_inner.top_level = true
	add_child(_ring_inner)


## Build ahead of time the cached look a MortarShell draws (shell, trail, scatter rings, muzzle flash): see
## Projectile.prewarm_look.
static func prewarm_mortar(st: Dictionary) -> void:
	shell_mesh()
	Projectile.prewarm_trail(st)
	CombatMeshes.ring(MechMeshes.ORANGE, 0.93, SCATTER_RING_SIDES)
	CombatMeshes.ring(CombatMeshes.RED, 0.8, SCATTER_RING_SIDES)
	MuzzleFlash.mesh()


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
	_ring_outer.visible = flying
	_ring_inner.visible = flying
	if flying:
		_ring_outer.global_transform = Transform3D(ring_basis * Basis.from_scale(Vector3.ONE * float(stats.get("splash_radius", 8.0))), ring_pos)
		_ring_inner.global_transform = Transform3D(ring_basis * Basis.from_scale(Vector3.ONE * ring_radius(elapsed)), ring_pos + ring_basis.y * 0.02)
	if _trail_mesh != null:
		_draw_trail()
