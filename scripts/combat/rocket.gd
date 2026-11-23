class_name Rocket
extends Projectile
## A dumb-fire rocket (weapons.md §3.5): leaves from one of the pod's six tubes, flies straight on a seeded launch error
## with a slow seeded corkscrew wobble around that line, and detonates on contact (direct damage + splash + a big
## explosive impact) or at range (an air burst: splash + impact). Guided missiles (§3.6) subclass it.
##
## FLIGHT stays a pure function of flight time e: flight_pos(e) = launch + dir × speed × e + wobble_offset(e). The launch
## error, the wobble's phase / rate / spin and the tube all come from Combat.shot_rng (draw order: spread, then wobble),
## so every machine flies the same rocket at any frame rate and when started late. Hits are swept on the fixed
## Combat.SWEEP_STEP grid (the path is curved).
##
## SUBCLASSING (each piece overridable on its own):
##   setup_flight(rng)                   draws the shot's random numbers (after super.start); default: spread + wobble
##   launch_offset()                     the tube offset from record.origin (world space)
##   flight_pos / flight_dir / flight_dist / sub_step     the path (a guided missile integrates its own on 1/60 s steps)
##   wobble_offset(e)                    the corkscrew (return ZERO for none)
##   build_body() -> Node3D              the drawn rocket, 1 unit long along -Z (nose at -0.5), exhaust included
##   exhaust_flicker(e) -> float         the exhaust cone's length factor
##   PUFF_* / puff_color(a) / puff_size(e)   the smoke-puff chain
##   on_hit(h, e) -> bool                a direct hit: damage, then detonate
##   detonate(point, normal, exclude, surface)   splash + impact (shared by hits and the range air burst)
##   on_expire()                         end of range / lifetime: an air burst by default

const WOBBLE_RAMP := 0.3          ## s over which the corkscrew opens up from the tube (leaves the tube on its line)
const WOBBLE_HZ := Vector2(0.9, 1.4)   ## corkscrew turns per second, drawn per rocket
## The pod's six tube mouths (MechMeshes "rockets": x = -0.215 / 0 / +0.215, y = -0.07 / +0.15, model units) in ripple
## order, and the scale they are drawn at (MechMeshes.BODY_SCALE × the default mech_scale 2.0).
const TUBES := [Vector2(-0.215, 0.15), Vector2(0.215, -0.07), Vector2(0.0, 0.15), Vector2(-0.215, -0.07),
	Vector2(0.215, 0.15), Vector2(0.0, -0.07)]
const TUBE_SCALE := MechMeshes.BODY_SCALE * 2.0
const PUFF_EVERY := 0.06          ## s of flight between smoke puffs
const PUFF_LIFE := 1.2            ## s a puff lives (then pops out)
const PUFF_POP := 0.07            ## s a puff takes to pop up to full size
const PUFF_RISE := 0.5            ## m/s a puff drifts up
## Flat greys a puff steps through by age (lighter -> darker), no gradient.
const PUFF_RAMP := [Color(0.74, 0.74, 0.72), Color(0.6, 0.6, 0.59), Color(0.47, 0.47, 0.47), Color(0.34, 0.34, 0.35)]

var launch := Vector3.ZERO        ## where it leaves (record.origin + the tube offset)
var wobble := 0.0                 ## m: corkscrew radius
var wobble_rate := 0.0            ## rad/s (signed: the spin direction)
var wobble_phase := 0.0           ## rad
var _side := Vector3.RIGHT        ## the corkscrew's plane, perpendicular to dir
var _up := Vector3.UP
var _burst := false               ## on_expire ran
var _body: Node3D
var _flame: MeshInstance3D
var _puffs: Array = []            ## pooled MeshInstance3D, one per live puff
## Per puff index: jitter, axis, spin (looks RNG, drawn once in puff order) + where / how big it was left (set on its
## first draw, _pl_set): packed, so the per-frame chain does no dictionary lookups.
var _pl_jitter := PackedVector3Array()
var _pl_axis := PackedVector3Array()
var _pl_spin := PackedFloat64Array()
var _pl_at := PackedVector3Array()
var _pl_size := PackedFloat64Array()
var _pl_set := PackedByteArray()
var _puffs_borrowed := false      ## _puffs came from world.take_mesh


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({"launch": Net.SPAWN, "wobble": Net.SPAWN, "wobble_rate": Net.SPAWN, "wobble_phase": Net.SPAWN, "_side": Net.SPAWN,
		"_up": Net.SPAWN, "_burst": Net.LOCAL, "_body": Net.LOCAL, "_flame": Net.LOCAL, "_puffs": Net.LOCAL,
		"_pl_jitter": Net.LOCAL, "_pl_axis": Net.LOCAL, "_pl_spin": Net.LOCAL, "_pl_at": Net.LOCAL, "_pl_size": Net.LOCAL,
		"_pl_set": Net.LOCAL, "_puffs_borrowed": Net.LOCAL})
	return f


func start(w: CombatWorld, rec: Dictionary, st: Dictionary) -> void:
	super.start(w, rec, st)
	setup_flight(Combat.shot_rng(w.mission_seed, str(rec["shooter"]), str(rec["hardpoint"]), int(rec["shot_index"])))


## Draw everything random about this rocket from the shot generator: the launch error (same draw as Projectile.start),
## then the wobble.
func setup_flight(rng: RandomNumberGenerator) -> void:
	dir = Combat.spread_dir(record["dir"], float(record.get("spread", 0.0)), rng)
	launch = origin + launch_offset()
	wobble = float(stats.get("wobble", 0.0))
	wobble_phase = TAU * rng.randf()
	wobble_rate = TAU * lerpf(WOBBLE_HZ.x, WOBBLE_HZ.y, rng.randf()) * (1.0 if rng.randf() < 0.5 else -1.0)
	_side = dir.cross(Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT).normalized()
	_up = _side.cross(dir).normalized()


## The tube this shot leaves from, offset across the (unspread) aim direction.
func launch_offset() -> Vector3:
	var tube: Vector2 = TUBES[posmod(int(record.get("shot_index", 0)), TUBES.size())]
	var b := Combat.look_basis(record["dir"])
	return b * Vector3(tube.x, tube.y, 0.0) * TUBE_SCALE


# --- Flight ------------------------------------------------------------------------------------------

func flight_pos(e: float) -> Vector3:
	return launch + dir * speed * e + wobble_offset(e)


func wobble_offset(e: float) -> Vector3:
	if wobble <= 0.0:
		return Vector3.ZERO
	var a := wobble_phase + wobble_rate * e
	return (_side * cos(a) + _up * sin(a)) * wobble * smoothstep(0.0, WOBBLE_RAMP, e)


## The heading along the curved path (central difference: works for any flight_pos override).
func flight_dir(e: float) -> Vector3:
	var h := 0.01
	var d := flight_pos(e + h) - flight_pos(maxf(e - h, 0.0))
	return d.normalized() if d.length_squared() > 1e-10 else dir


func sub_step() -> float:
	return Combat.SWEEP_STEP


# --- Hits --------------------------------------------------------------------------------------------

func advance_to(now: float) -> void:
	var flying := end_time < 0.0
	super.advance_to(now)
	if flying and end_time >= 0.0 and end_time >= max_time - 1e-6 and not _burst:
		_burst = true
		on_expire()


func on_hit(h: Dictionary, e: float) -> bool:
	var target: CombatTarget = h["target"]
	if target != null:
		pierced.append(target.target_id)
		world.resolve_hit(record, stats, target, str(h["component"]), h["point"], h["normal"], flight_dir(e),
			float(stats.get("damage", 0.0)) * Combat.falloff(stats, flight_dist(e)))
	world.hit_prop(record, stats, h, flight_dir(e))
	detonate(h["point"], h["normal"], target, h.get("color", MechMeshes.GREY))
	return true


## The explosion: splash on everyone else in range, and the explosive impact.
func detonate(point: Vector3, normal: Vector3, exclude: CombatTarget, surface: Color) -> void:
	world.splash(record, stats, point, exclude)
	world.spawn_impact(point, normal, float(stats.get("impact_radius", 1.0)), surface, bool(stats.get("explosive", true)))


## Out of range: air burst where it is.
func on_expire() -> void:
	detonate(flight_pos(end_time), -flight_dir(end_time), null, MechMeshes.GREY)


# --- Look --------------------------------------------------------------------------------------------

func _build_look() -> void:
	_body = build_body()
	_body.top_level = true
	add_child(_body)


## The drawn rocket, 1 unit long along -Z (nose at -0.5): a white faceted body, an orange nose, dark fins and nozzle,
## and the amber exhaust cone (LowPolyFlame) behind the tail. Scaled by drawn_scale.
func build_body() -> Node3D:
	var root := Node3D.new()
	root.add_child(CombatMeshes.instance(rocket_mesh()))
	_flame = CombatMeshes.instance(LowPolyFlame.jet())
	root.add_child(_flame)
	return root


## Build ahead of time the cached look a Rocket draws (body, exhaust, smoke puffs, muzzle flash): see
## Projectile.prewarm_look.
static func prewarm_rocket() -> void:
	rocket_mesh()
	LowPolyFlame.jet()
	for c: Color in PUFF_RAMP:
		CombatMeshes.ico(c)
	MuzzleFlash.mesh()


## The mesh pool's warm-up plan for smoke puffs (CombatWorld.prewarm_mesh_pool): puff nodes are borrowed showing the
## first puff colour.
static func pool_plan() -> Array:
	return [[CombatMeshes.ico(PUFF_RAMP[0]), 200]]


static func rocket_mesh() -> ArrayMesh:
	var key := "rocket_mesh"
	if CombatMeshes._cache.has(key):
		return CombatMeshes._cache[key]
	var k := MeshKit.new()
	k.push(Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3.ZERO))      # lathe +Y -> -Z (the nose)
	k.lathe([Vector2(0.075, -0.42), Vector2(0.11, -0.36), Vector2(0.11, 0.2)], 6, MechMeshes.WHITE, true, false)
	k.lathe([Vector2(0.11, 0.2), Vector2(0.07, 0.36), Vector2(0.0, 0.5)], 6, MechMeshes.ORANGE, false, false)
	k.lathe([Vector2(0.075, -0.42), Vector2(0.085, -0.5)], 6, MechMeshes.DARK, false, true)
	for f in 4:
		var a := TAU * float(f) / 4.0 + PI * 0.25
		k.push(Transform3D(Basis(Vector3.UP, a), Vector3.ZERO))
		k.box(Vector3(0.13, 0.2, 0.025), MechMeshes.DARK, Vector3(0.15, -0.3, 0.0))
		k.pop()
	k.pop()
	var m := k.commit(MechMeshes.materials())
	CombatMeshes._cache[key] = m
	return m


func exhaust_flicker(e: float) -> float:
	return 1.0 + 0.18 * sin(e * 53.0 + wobble_phase * 7.0) + 0.1 * sin(e * 97.0)


func puff_color(age_frac: float) -> Color:
	return PUFF_RAMP[clampi(int(age_frac * PUFF_RAMP.size()), 0, PUFF_RAMP.size() - 1)]


## A puff's peak radius when it is left at flight time e (tied to the rocket's drawn size).
func puff_size(e: float) -> float:
	return 0.2 + drawn_scale(e) * 0.36


func _update_look() -> void:
	if not is_inside_tree():
		return
	var flying := end_time < 0.0
	_body.visible = flying
	if flying:
		var p := flight_pos(elapsed)
		var s := _screen_scale(elapsed, p)
		_body.global_transform = Transform3D(Combat.look_basis(flight_dir(elapsed)) * Basis.from_scale(Vector3.ONE * s), p)
		if _flame != null:
			# LowPolyFlame points -Y from the nozzle: turn it to +Z, at the tail, ~0.3 wide and 0.5-0.8 long.
			var fl := exhaust_flicker(elapsed)
			_flame.transform = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5) * Basis.from_scale(Vector3(0.36, 0.42 * fl, 0.36)),
				Vector3(0, 0, 0.5))
	_draw_puffs()


## The smoke chain: puff k is left at flight time k × PUFF_EVERY + phase at flight_pos, pops up, tumbles, rises, shrinks and steps
## darker, and pops out at PUFF_LIFE. Positions follow the flight (deterministic); tumble and jitter are looks.
func _draw_puffs() -> void:
	var head := elapsed if end_time < 0.0 else minf(elapsed, end_time)
	# Each rocket's puffs sit on its own phase of the grid, so a salvo's chains don't line up in columns.
	var phase := fposmod(float(record.get("shot_index", 0)) * 0.618, 1.0) * PUFF_EVERY
	var first := maxi(int(ceil((elapsed - PUFF_LIFE - phase) / PUFF_EVERY)), 0)
	var last := int(floor((head - phase) / PUFF_EVERY))
	var used := 0
	for k in range(first, last + 1):
		var tk := float(k) * PUFF_EVERY + phase
		var age := elapsed - tk
		if age < 0.0 or age >= PUFF_LIFE:
			continue
		_puff_look(k)
		if _pl_set[k] == 0:        # where and how big the puff was left: fixed per puff (the flight is a pure function of e)
			_pl_set[k] = 1
			_pl_at[k] = flight_pos(tk)
			_pl_size[k] = puff_size(tk)
		var a := age / PUFF_LIFE
		var grow := clampf(age / PUFF_POP, 0.0, 1.0)
		var size := _pl_size[k] * lerpf(0.45, 1.0, grow) * lerpf(1.0, 0.35, a)
		var p := _pl_at[k] + _pl_jitter[k] * (0.3 + a) + Vector3.UP * PUFF_RISE * age
		var mi := _puff_node(used)
		used += 1
		var pm := CombatMeshes.ico(puff_color(a))
		if mi.mesh != pm:
			mi.mesh = pm
		var rot := Basis(_pl_axis[k], _pl_spin[k] * age + float(k))
		mi.global_transform = Transform3D(rot * Basis.from_scale(Vector3.ONE * size), p)
		if not mi.visible:
			mi.visible = true
	for i in range(used, _puffs.size()):
		var h := _puffs[i] as MeshInstance3D
		if h.visible:
			h.visible = false


## A factor on every puff's jitter (the missile's chain hugs its line).
func puff_jitter_scale() -> float:
	return 1.0


## Puff k's looks (drawn from the looks generator in puff order, once each, on first use), kept in the _pl_* arrays.
func _puff_look(k: int) -> void:
	while _pl_spin.size() <= k:
		var r := world.looks_rng
		var j := Vector3(r.randf_range(-1.0, 1.0), r.randf_range(-1.0, 1.0), r.randf_range(-1.0, 1.0)) * 0.18
		var axis := Vector3(r.randf_range(-1.0, 1.0), r.randf_range(-1.0, 1.0), r.randf_range(-1.0, 1.0))
		var js := puff_jitter_scale()
		_pl_jitter.append(j * js if js != 1.0 else j)
		_pl_axis.append(axis.normalized() if axis.length_squared() > 1e-4 else Vector3.UP)
		_pl_spin.append(r.randf_range(2.0, 5.0) * (1.0 if r.randf() < 0.5 else -1.0))
		_pl_at.append(Vector3.ZERO)
		_pl_size.append(0.0)
		_pl_set.append(0)


func _puff_node(i: int) -> MeshInstance3D:
	while _puffs.size() <= i:
		var m := CombatMeshes.ico(PUFF_RAMP[0])
		var mi: MeshInstance3D = world.take_mesh(m) if world != null and is_instance_valid(world) else null
		if mi != null:
			_puffs_borrowed = true
		else:
			mi = CombatMeshes.instance(m)
			mi.top_level = true
			mi.visible = false
			add_child(mi)
		_puffs.append(mi)
	return _puffs[i]


## Puff nodes borrowed from the world's mesh pool go back when the rocket leaves.
func _exit_tree() -> void:
	if not _puffs_borrowed or world == null or not is_instance_valid(world):
		return
	_puffs_borrowed = false
	for mi: MeshInstance3D in _puffs:
		if is_instance_valid(mi) and mi.get_parent() != self:
			world.give_mesh(mi)
	_puffs.clear()
