class_name Projectile
extends CombatEffect
## A shot that flies (weapons.md §4.2, §5): shells, bullets, slugs; rockets, missiles and the mortar shell build on it.
##
## FLIGHT is a pure function of flight time `e` (= world.now - record.t): `flight_pos(e)`. Straight flight here; a
## subclass overrides `flight_pos` (and `flight_dir`) for a ballistic arc, and returns a `sub_step()` > 0 so the sweep
## runs on a fixed time grid (Combat.SWEEP_STEP) and stays frame-rate independent. A guided missile integrates its own
## path in fixed 1/60 s steps inside an override of `flight_pos` / `advance_to` (weapons.md §5 allows that).
## Spread is drawn once from the shot generator (Combat.shot_rng), so the path is the same on every machine.
##
## HITS: each advance sweeps the path from the last flight time to the new one against the world's targets (hit
## spheres, inflated by Combat.PROJECTILE_RADIUS) and world geometry (physics ray), earliest first, up to range.
## `on_hit(...)` resolves it (damage × falloff, Δv along the flight, splash, impact fx) and returns true to stop; the
## railgun overrides it to pierce. Reaching max_time with nothing met calls `reach_range()`: gone without a burst by
## default (the rocket air-bursts, the mortar shell lands).
## CURVED SWEEP (sub_step() > 0): chords run between grid points k × sub_step from the last grid point swept (`_swept`),
## plus max_time itself as the final point, so a frame step that doesn't reach the next grid point sweeps nothing yet and
## the chords are the same at any frame rate and when started late.
## AMBIENT LIFE: every chord swept is reported to CombatWorld.life_sweep (start -> end, or -> the stopping hit on the
## flight line) with r = Combat.PROJECTILE_RADIUS, so the reports cover the path contiguously from muzzle to impact.
##
## LOOK: a faceted shell drawn at Combat.growth_scale (visual only; never below Combat.MIN_PIXELS on screen) and a ribbon
## trail of flat quads (4-sided section, unlit, tapering, one segment per TRAIL_SEG s, width tied to the drawn scale),
## both sampled from flight_pos, so the trail is as deterministic as the shot. `look` (from the weapon behaviour) picks
## colours: {"color", "trail_color", "width", "glow" (unshaded tracer shell)}.

const TRAIL_SEG := 0.04
const TRAIL_WIDTH := 0.12      ## trail half-width as a share of the drawn shell length (the shell is 0.19 wide)

var look: Dictionary = {}
var origin := Vector3.ZERO
var dir := Vector3.FORWARD     ## after spread
var speed := 70.0
var max_time := 3.0            ## flight time to range
var elapsed := 0.0             ## flight time reached so far
var end_time := -1.0           ## flight time it hit (or expired); -1 while flying
var pierced: Array = []        ## target ids already hit (a piercing subclass skips them)
var _swept := 0.0              ## curved flights: flight time swept so far (a grid point, or max_time)
var _shell: MeshInstance3D
var _trail: MeshInstance3D
var _trail_mesh: ArrayMesh      ## rebuilt each frame from one vertex ring array + a cached index list (_draw_trail)
var _trail_arrays: Array = []    ## the surface arrays handed to add_surface_from_arrays, reused
var _trail_colors := PackedColorArray()

## Segment count n -> the trail's triangle list over the (n + 1) × 4 ring corners (the same triangles, in the same
## order, the ribbon always had); shared by every projectile.
static var _trail_index: Dictionary = {}


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({"look": Net.SPAWN, "origin": Net.SPAWN, "dir": Net.SPAWN, "speed": Net.SPAWN, "max_time": Net.SPAWN,
		"elapsed": Net.LOCAL, "end_time": Net.LOCAL, "pierced": Net.LOCAL, "_swept": Net.LOCAL, "_shell": Net.LOCAL, "_trail": Net.LOCAL,
		"_trail_mesh": Net.LOCAL, "_trail_arrays": Net.LOCAL, "_trail_colors": Net.LOCAL})
	return f


func start(w: CombatWorld, rec: Dictionary, st: Dictionary) -> void:
	super.start(w, rec, st)
	origin = rec["origin"]
	var rng := Combat.shot_rng(w.mission_seed, str(rec["shooter"]), str(rec["hardpoint"]), int(rec["shot_index"]))
	dir = Combat.spread_dir(rec["dir"], float(rec.get("spread", 0.0)), rng)
	speed = maxf(float(st.get("speed", 70.0)), 0.1)
	max_time = float(st.get("range", 200.0)) / speed
	_build_look()


# --- Flight (override for other flight modes) --------------------------------------------------------------

func flight_pos(e: float) -> Vector3:
	return origin + dir * speed * e


func flight_dir(_e: float) -> Vector3:
	return dir


## Distance travelled at flight time e (drives growth and falloff).
func flight_dist(e: float) -> float:
	return speed * e


## 0 = sweep exact chords between frame times (straight lines); > 0 = sweep only on this fixed time grid (curves).
func sub_step() -> float:
	return 0.0


# --- Clock --------------------------------------------------------------------------------------------

func advance_to(now: float) -> void:
	var e := now - t0
	if end_time < 0.0:
		var e1 := minf(e, max_time)
		if e1 > (_swept if sub_step() > 0.0 else elapsed):
			_sweep(elapsed, e1)
		if end_time < 0.0 and e >= max_time:
			reach_range()
	elapsed = maxf(e, elapsed)
	_update_look()


## Flight time max_time reached with nothing met: gone (override: an air burst, a landing).
func reach_range() -> void:
	end_time = max_time


func finished() -> bool:
	return end_time >= 0.0 and elapsed - float(stats.get("trail", 0.0)) >= end_time


## Sweep flight times e0 -> e1 for the first thing hit (curved flights: from `_swept` on the grid, see the header).
func _sweep(e0: float, e1: float) -> void:
	var times: Array[float] = [e0]
	var sub := sub_step()
	if sub > 0.0:
		times[0] = _swept         # resume from the last grid point swept, not the frame time: chords stay on the grid
		var k := int(round(_swept / sub)) + 1
		while float(k) * sub <= e1 + 1e-9 and float(k) * sub < max_time - 1e-9:
			times.append(float(k) * sub)
			k += 1
		if e1 >= max_time - 1e-9 and times[times.size() - 1] < max_time:
			times.append(max_time)    # the last, partial chord up to range
		if times.size() == 1:
			return            # not yet at the next grid point: the sweep waits for it (keeps it frame-rate independent)
	else:
		times.append(e1)
	for i in times.size() - 1:
		var ta := times[i]
		var tb := times[i + 1]
		var a := flight_pos(ta)
		var b := flight_pos(tb)
		var c0 := a           # the chord's start: ambient life is told chord by chord (CombatWorld.life_sweep)
		var h := world.first_hit(a, b, Combat.PROJECTILE_RADIUS, str(record.get("shooter", "")), pierced)
		while not h.is_empty():
			var te := lerpf(ta, tb, float(h["frac"]))
			var hp := a.lerp(b, float(h["frac"]))     # on the flight line (a prop's surface point may sit off it)
			if on_hit(h, te):
				world.life_sweep(record, c0, hp, Combat.PROJECTILE_RADIUS)
				end_time = te
				return
			ta = te       # pierced: carry on from the hit (a piercing on_hit must return true for world geometry)
			a = h["point"]
			h = world.first_hit(a, b, Combat.PROJECTILE_RADIUS, str(record.get("shooter", "")), pierced)
		world.life_sweep(record, c0, b, Combat.PROJECTILE_RADIUS)
		_swept = tb


## Resolve a hit `h` (CombatWorld.first_hit: {target (or null for world), component, point, normal, frac, color}) at
## flight time e. Return true to stop the projectile.
func on_hit(h: Dictionary, e: float) -> bool:
	var d := flight_dist(e)
	var fdir := flight_dir(e)
	var target: CombatTarget = h["target"]
	if target != null:
		pierced.append(target.target_id)
		world.resolve_hit(record, stats, target, str(h["component"]), h["point"], h["normal"], fdir,
			float(stats.get("damage", 0.0)) * Combat.falloff(stats, d))
	world.hit_prop(record, stats, h, fdir)
	world.splash(record, stats, h["point"], target)
	world.spawn_impact(h["point"], h["normal"], float(stats.get("impact_radius", 1.0)), h.get("color", MechMeshes.GREY),
		bool(stats.get("explosive", false)))
	return true


# --- Look ---------------------------------------------------------------------------------------------

func _build_look() -> void:
	_shell = CombatMeshes.instance(CombatMeshes.shell(look.get("color", MechMeshes.AMBER), float(look.get("width", 0.38)),
		bool(look.get("glow", false))))
	_shell.top_level = true
	add_child(_shell)
	if float(stats.get("trail", 0.0)) > 0.0:
		_trail_mesh = ArrayMesh.new()
		_trail = CombatMeshes.instance(_trail_mesh)
		_trail.top_level = true
		add_child(_trail)


func drawn_scale(e: float) -> float:
	return Combat.growth_scale(float(stats.get("size", 0.3)), float(stats.get("growth", 1.0)), float(stats.get("growth_full", 120.0)),
		flight_dist(e))


## The drawn scale, raised so it never draws under Combat.MIN_PIXELS on the current camera.
func _screen_scale(e: float, at: Vector3) -> float:
	var s := drawn_scale(e)
	var vp := get_viewport()
	var cam := vp.get_camera_3d() if vp != null else null
	if cam != null and cam.projection == Camera3D.PROJECTION_PERSPECTIVE:
		var dist := maxf(cam.global_position.distance_to(at), 0.01)
		var px_per_m := float(vp.get_visible_rect().size.y) / (2.0 * dist * tan(deg_to_rad(cam.fov) * 0.5))
		s = maxf(s, Combat.MIN_PIXELS / px_per_m)
	return s


func _update_look() -> void:
	if not is_inside_tree():
		return
	var flying := end_time < 0.0
	_shell.visible = flying
	if flying:
		var p := flight_pos(elapsed)
		_shell.global_transform = Transform3D(Combat.look_basis(flight_dir(elapsed)) * Basis.from_scale(Vector3.ONE * _screen_scale(elapsed, p)), p)
	if _trail_mesh != null:
		_draw_trail()


func _draw_trail() -> void:
	_trail_mesh.clear_surfaces()
	var head := elapsed if end_time < 0.0 else minf(elapsed, end_time)
	var tail := maxf(elapsed - float(stats.get("trail", 0.0)), 0.0)
	if head - tail < 0.005:
		return
	var n := maxi(int(ceil((head - tail) / TRAIL_SEG)), 1)
	var col: Color = look.get("trail_color", MechMeshes.AMBER)
	var rings := PackedVector3Array()      # 4 corners per ring, flat (no per-frame nested arrays)
	rings.resize((n + 1) * 4)
	for i in n + 1:
		var e := lerpf(tail, head, float(i) / float(n))
		var p := flight_pos(e)
		var w := drawn_scale(e) * TRAIL_WIDTH * (float(i) / float(n))     # tapers to a point at the tail
		var fwd := flight_dir(e)
		var side := fwd.cross(Vector3.UP if absf(fwd.y) < 0.99 else Vector3.RIGHT).normalized()
		var up := side.cross(fwd).normalized()
		rings[i * 4] = p + up * w
		rings[i * 4 + 1] = p + side * w
		rings[i * 4 + 2] = p - up * w
		rings[i * 4 + 3] = p - side * w
	if _trail_arrays.is_empty():
		_trail_arrays.resize(Mesh.ARRAY_MAX)
	if _trail_colors.size() != rings.size():
		_trail_colors.resize(rings.size())
	_trail_colors.fill(col)
	_trail_arrays[Mesh.ARRAY_VERTEX] = rings
	_trail_arrays[Mesh.ARRAY_COLOR] = _trail_colors
	_trail_arrays[Mesh.ARRAY_INDEX] = trail_indices(n)
	_trail_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _trail_arrays)
	_trail_mesh.surface_set_material(0, CombatMeshes.ribbon_material())


## Build ahead of time the cached look a default Projectile with `lk` / `st` draws (its shell mesh, the trail material and
## index lists, the muzzle flash star), so a weapon's FIRST shot doesn't build them mid-fight (WeaponBehaviour.prewarm,
## from WeaponRack.rebuild). The same cached resources the shot would build on demand: nothing drawn changes.
static func prewarm_look(lk: Dictionary, st: Dictionary) -> void:
	CombatMeshes.shell(lk.get("color", MechMeshes.AMBER), float(lk.get("width", 0.38)), bool(lk.get("glow", false)))
	prewarm_trail(st)
	MuzzleFlash.mesh()


## The trail's cached material and index lists for every segment count a trail of stats.trail s can have.
static func prewarm_trail(st: Dictionary) -> void:
	var trail := float(st.get("trail", 0.0))
	if trail <= 0.0:
		return
	CombatMeshes.ribbon_material()
	for n in range(1, int(ceil(trail / TRAIL_SEG)) + 2):
		trail_indices(n)


## The ribbon's triangles for n segments over ring corners 4 per ring: per segment, per side k, (a+k, b+k, b+k2) and
## (a+k, b+k2, a+k2) with a = 4i, b = a + 4, k2 = (k + 1) % 4. Cached per n.
static func trail_indices(n: int) -> PackedInt32Array:
	var idx: Variant = _trail_index.get(n)
	if idx == null:
		var out := PackedInt32Array()
		out.resize(n * 24)
		var w := 0
		for i in n:
			var a := i * 4
			var b := a + 4
			for k in 4:
				var k2 := (k + 1) % 4
				for v: int in [a + k, b + k, b + k2, a + k, b + k2, a + k2]:
					out[w] = v
					w += 1
		_trail_index[n] = out
		idx = out
	return idx
