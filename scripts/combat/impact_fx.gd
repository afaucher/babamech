class_name ImpactFx
extends CombatEffect
## The one cosmetic impact builder (weapons.md §4.3), scaled by radius R: a faceted flash ball (0 -> R in 0.08 s, gone by
## 0.3 s), 5-12 fireball chunks stepping through the flame ramp and drifting up, debris shards in the hit surface's
## colour flung along the normal under gravity, a surface-aligned ground ring out to 1.5 R when the impact is within R
## of the ground, a surface-aligned faceted scorch polygon (10 s) with a cooling inner glowing ember polygon (2.5 s) and
## perimeter rubble pebbles. `explosive` adds a second, slower chunk wave and a few flame tongues licking up.
## `add_column(h)` (the mortar / tank blast) adds a tall faceted column aligned to local radial `up`.
## Faceted meshes only. Every random number comes from the world's LOOKS generator, never the shot generator.
## Cosmetic: nothing here is gameplay state (all LOCAL).
##
## PERFORMANCE (weapons.md §6.1): parts live in packed per-part arrays (`_p_*`, int kinds), filled straight from `_add`;
## `_parts` is a read-only record built from them when read (tests). Part nodes are borrowed from the world's mesh pool;
## a part that is over for good hands its node back at once (its record then shows "node": null, "mesh" stays). A part
## whose transform can no longer change (scorch / pebble once placed, the flash once grown, the ring once full) is
## written once and then left alone; resting impacts are skipped whole.

const FLASH_GROW := 0.08
const FLASH_LIFE := 0.3
const CHUNK_LIFE := 0.9
const SHARD_LIFE := 1.2
const RING_LIFE := 0.45
const TONGUE_LIFE := 0.4
const EMBER_LIFE := 2.5            ## s inner glowing ember polygon cools and shrinks away
const SCORCH_LIFE := 10.0
const COLUMN_RISE := 0.35          ## s for the column to reach its height
const COLUMN_LIFE := 1.0           ## s of the flame stem
const SMOKE_LIFE := 2.2            ## s of the smoke stem and the column's top chunks
const RING_COLOR := Color(1.0, 0.86, 0.55)
const SCORCH_COLOR := Color(0.09, 0.085, 0.08)
const RUBBLE_COLOR := Color(0.16, 0.155, 0.15)
const SMOKE := Color(0.24, 0.23, 0.23)
## The ramp a fireball chunk steps through by age: flat colours, no gradient (the last one is lit smoke).
const FLAME_RAMP := [LowPolyFlame.CORE, LowPolyFlame.MID, LowPolyFlame.OUTER, SMOKE]

static var _meshes: Dictionary = {}
## Fast paths to meshes the builders already cache (the same objects, without building a string key per part).
static var _ball_by: Dictionary = {}       ## Color -> flame_ball(c)
static var _ramp: Array = []               ## step -> ramp_mesh(step)
static var _tongue_v: Array = []           ## variant -> LowPolyFlame.tongue(WARM, variant)
static var _scorch_v: Array = []           ## variant -> CombatMeshes.scorch(SCORCH_COLOR, variant)
static var _ember_v: Array = []            ## variant -> CombatMeshes.ember_scorch(variant)
static var _ring_m: ArrayMesh = null       ## CombatMeshes.ring(RING_COLOR, 0.82)
static var _rubble_m: ArrayMesh = null     ## CombatMeshes.shard(RUBBLE_COLOR)

var radius := 1.0
var point := Vector3.ZERO
var normal := Vector3.UP
var ground_y := NAN            ## the ground height under the impact (NAN = none within reach)
var ground_point := Vector3(NAN, NAN, NAN)
var ground_normal := Vector3.UP
var up_dir := Vector3.UP
var _has_ground := false
var age := 0.0
var column := 0.0              ## column height (m), 0 = none
## The readable record of the parts (tests), built from the packed arrays on each read: [{node (null once handed back),
## mesh, kind, born, life, vel, size, at, spin, h, step, basis, placed}].
var _parts: Array:
	get:
		return _parts_record()
## Part lifetimes, kept as parts are added (so `finished` and `advance_to` need no scan over the parts):
var _end := 0.0                ## latest born + life of any part (finished after it)
var _moving_end := 0.0         ## latest born + life of a part that animates (anything but scorch / pebble)
var _rest_from := 0.0          ## latest birth of a resting part (scorch / pebble)
var _rest_until := INF         ## earliest born + life of a resting part
## True after a full pass in the resting phase (age in [max(_moving_end, _rest_from), _rest_until)): every animated part
## is hidden and every resting part placed and shown, so later passes in that phase would change nothing and are skipped.
## An impact spends most of its 10 s there (the scorch outlives the fire by ~4x).
var _rested := false
var _live := PackedInt32Array()   ## indices of the parts not yet over (a part past born + life is hidden and dropped)
var _live_age := -INF          ## age at the last advance (a step back in time restores _live from the parts)
## The parts, one entry per part in every array (kind as an int, the numbers packed, no lookups by name).
var _pn := 0                   ## parts so far
var _borrowed := false         ## part nodes came from world.take_mesh (handed back when over, or on leaving the tree)
var _p_kind := PackedInt32Array()
var _p_born := PackedFloat64Array()
var _p_life := PackedFloat64Array()
var _p_size := PackedFloat64Array()
var _p_h := PackedFloat64Array()
var _p_at := PackedVector3Array()
var _p_vel := PackedVector3Array()
var _p_spin := PackedVector3Array()
var _p_step := PackedInt32Array()
var _p_placed := PackedByteArray() ## the node holds the part's final transform (scorch / pebble placed, flash / ring settled)
var _p_shown := PackedByteArray()  ## the node's visible flag as last written (no redundant writes)
var _p_basis: Array[Basis] = []
var _p_node: Array[MeshInstance3D] = []   ## null once a borrowed node went back to the pool (the part is over)
var _p_mesh: Array[Mesh] = []             ## the mesh the part's node shows (kept after the node went back)

enum {K_FLASH, K_CHUNK, K_TONGUE, K_COLUMN, K_SHARD, K_RING, K_EMBER, K_SCORCH, K_PEBBLE}
const KINDS := {"flash": K_FLASH, "chunk": K_CHUNK, "tongue": K_TONGUE, "column": K_COLUMN, "shard": K_SHARD,
	"ring": K_RING, "ember": K_EMBER, "scorch": K_SCORCH, "pebble": K_PEBBLE}
const KIND_NAMES := ["flash", "chunk", "tongue", "column", "shard", "ring", "ember", "scorch", "pebble"]


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({"radius": Net.LOCAL, "point": Net.LOCAL, "normal": Net.LOCAL, "ground_y": Net.LOCAL,
		"ground_point": Net.LOCAL, "ground_normal": Net.LOCAL, "up_dir": Net.LOCAL, "_has_ground": Net.LOCAL,
		"age": Net.LOCAL, "column": Net.LOCAL, "_parts": Net.LOCAL, "_end": Net.LOCAL, "_moving_end": Net.LOCAL,
		"_rest_from": Net.LOCAL, "_rest_until": Net.LOCAL, "_rested": Net.LOCAL, "_live": Net.LOCAL, "_live_age": Net.LOCAL,
		"_pn": Net.LOCAL, "_borrowed": Net.LOCAL, "_p_kind": Net.LOCAL, "_p_born": Net.LOCAL, "_p_life": Net.LOCAL, "_p_size": Net.LOCAL, "_p_h": Net.LOCAL,
		"_p_at": Net.LOCAL, "_p_vel": Net.LOCAL, "_p_spin": Net.LOCAL, "_p_step": Net.LOCAL, "_p_placed": Net.LOCAL,
		"_p_shown": Net.LOCAL, "_p_basis": Net.LOCAL, "_p_node": Net.LOCAL, "_p_mesh": Net.LOCAL})
	return f


## Orthonormal right-handed basis whose +Y aligns strictly to surface normal `n`.
static func basis_for_normal(n: Vector3) -> Basis:
	var y := n.normalized() if n.length_squared() > 1e-6 else Vector3.UP
	var ref := Vector3.RIGHT if absf(y.x) < 0.92 else Vector3.FORWARD
	var z := ref.cross(y).normalized()
	var x := y.cross(z).normalized()
	return Basis(x, y, z)


## A flame ball (20 faces, radius 1) in a flame colour, on LowPolyFlame's unshaded material.
static func flame_ball(c: Color) -> ArrayMesh:
	var m: ArrayMesh = _ball_by.get(c)
	if m != null:
		return m
	var key := "ball|" + c.to_html()
	if not _meshes.has(key):
		var k := MeshKit.new()
		k.glow = true
		k.shade = 0.07         # a flat colour per facet, a touch apart, so the ball reads as faceted, not a disc
		k.ico(Vector3.ZERO, Vector3.ONE, c)
		_meshes[key] = k.commit([LowPolyFlame.material(), LowPolyFlame.material()])
	m = _meshes[key]
	_ball_by[c] = m
	return m


## The column's stem: a 5-sided tapered shaft, base radius 1 at y 0 up to y 1 (scale y for height), unshaded flame
## (an OUTER shell over a MID core) or lit smoke.
static func stem(smoke: bool) -> ArrayMesh:
	var key := "stem|%s" % smoke
	if not _meshes.has(key):
		var k := MeshKit.new()
		var prof := [Vector2(1.0, 0.0), Vector2(0.75, 0.3), Vector2(0.55, 0.75), Vector2(0.0, 1.0)]
		if smoke:
			k.lathe(prof, LowPolyFlame.SIDES, SMOKE)
			_meshes[key] = k.commit(MechMeshes.materials())
		else:
			k.glow = true
			k.shade = 0.0
			k.lathe(prof, LowPolyFlame.SIDES, LowPolyFlame.OUTER)
			k.push(MeshKit.xf(Vector3.ZERO, Vector3(0, 36, 0), Vector3(0.6, 1.08, 0.6)))
			k.lathe(prof, LowPolyFlame.SIDES, LowPolyFlame.MID)
			k.pop()
			_meshes[key] = k.commit([LowPolyFlame.material(), LowPolyFlame.material()])
	return _meshes[key]


static func ramp_mesh(step: int) -> ArrayMesh:
	if _ramp.is_empty():
		for i in FLAME_RAMP.size():
			var c: Color = FLAME_RAMP[i]
			_ramp.append(CombatMeshes.ico(c) if i == FLAME_RAMP.size() - 1 else flame_ball(c))
	return _ramp[step]


static func _tongue(variant: int) -> ArrayMesh:
	if _tongue_v.is_empty():
		for v in LowPolyFlame.VARIANTS:
			_tongue_v.append(LowPolyFlame.tongue(LowPolyFlame.WARM, v))
	return _tongue_v[variant] if variant >= 0 and variant < _tongue_v.size() else LowPolyFlame.tongue(LowPolyFlame.WARM, variant)


static func _scorch(variant: int) -> ArrayMesh:
	if _scorch_v.is_empty():
		for v in 4:
			_scorch_v.append(CombatMeshes.scorch(SCORCH_COLOR, v))
	return _scorch_v[variant]


static func _ember(variant: int) -> ArrayMesh:
	if _ember_v.is_empty():
		for v in 4:
			_ember_v.append(CombatMeshes.ember_scorch(v))
	return _ember_v[variant]


static func _ring() -> ArrayMesh:
	if _ring_m == null:
		_ring_m = CombatMeshes.ring(RING_COLOR, 0.82)
	return _ring_m


static func _rubble() -> ArrayMesh:
	if _rubble_m == null:
		_rubble_m = CombatMeshes.shard(RUBBLE_COLOR)
	return _rubble_m


## The mesh pool's warm-up plan for impacts (CombatWorld.prewarm_mesh_pool): [[mesh, nodes], ...] for the meshes every
## impact borrows (flash / chunk ball, grey and rubble shards, tongues, ring, scorch, ember, column stems, the wreck's
## charred shards), so a fight's first impacts find nodes already showing their mesh (no mesh swap per part).
static func pool_plan() -> Array:
	var plan: Array = [[ramp_mesh(0), 560], [CombatMeshes.shard(MechMeshes.GREY), 400], [_rubble(), 160], [_ring(), 40],
		[CombatMeshes.shard(EnemyMeshes.CHARRED), 64], [stem(false), 12], [stem(true), 12]]
	for v in LowPolyFlame.VARIANTS:
		plan.append([_tongue(v), 30])
	for v in 4:
		plan.append([_scorch(v), 16])
		plan.append([_ember(v), 16])
	return plan


## `flash_color`: the flash ball's colour (default the flame core; the laser's is teal).
## `ground_surf`: optional {point, normal} from CombatWorld.surface_below() for flush curved-deck alignment.
## `wall_surf`: optional {point, normal} of the static world surface the impact sits on (CombatWorld.wall_at); the wall
## scorch + ember go there and only there, so a hit on a target's hull or a blast in the air leaves no floating decal.
func setup(w: CombatWorld, at: Vector3, n: Vector3, r: float, surface: Color, ground: float, explosive: bool,
		flash_color: Color = LowPolyFlame.CORE, ground_surf: Dictionary = {}, local_up: Vector3 = Vector3.UP,
		wall_surf: Dictionary = {}) -> void:
	world = w
	t0 = w.now
	point = at
	normal = n.normalized() if n.length_squared() > 1e-6 else Vector3.UP
	up_dir = local_up.normalized() if local_up.length_squared() > 1e-6 else Vector3.UP
	radius = maxf(r, 0.1)
	ground_y = ground
	_has_ground = false
	if not ground_surf.is_empty() and ground_surf.has("point") and ground_surf.has("normal"):
		ground_point = ground_surf["point"] as Vector3
		ground_normal = (ground_surf["normal"] as Vector3).normalized()
		var dist := (point - ground_point).dot(up_dir)
		_has_ground = dist <= radius and dist >= -0.6 and ground_normal.dot(up_dir) >= 0.5
	elif not is_nan(ground_y):
		ground_point = Vector3(point.x, ground_y, point.z)
		ground_normal = up_dir
		var dist := (point - ground_point).dot(up_dir)
		_has_ground = dist <= radius and dist >= -0.6

	var rng := w.looks_rng
	var up_b := basis_for_normal(up_dir)
	_add(K_FLASH, flame_ball(flash_color), 0.0, FLASH_LIFE, Vector3.ZERO, radius, point)
	var chunks := clampi(int(5.0 + radius * 2.5), 5, 12)
	for wave in (2 if explosive else 1):
		for i in chunks:
			var off_local := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.3, 1), rng.randf_range(-1, 1)) * radius * 0.5
			var vel := (normal * rng.randf_range(0.5, 1.5) + up_dir * rng.randf_range(0.8, 2.0)) * (0.6 + radius * 0.4) * (0.5 if wave == 1 else 1.0)
			var life := CHUNK_LIFE * rng.randf_range(0.7, 1.2) * (1.6 if wave == 1 else 1.0)
			_add(K_CHUNK, null, 0.05 + 0.15 * wave, life, vel, radius * rng.randf_range(0.25, 0.45) * (1.3 if wave == 1 else 1.0), point + up_b * off_local)
	if explosive:
		for i in clampi(int(2.0 + radius), 3, 7):
			var off_t := (up_b.x * rng.randf_range(-1, 1) + up_b.z * rng.randf_range(-1, 1)) * radius * 0.35
			_add(K_TONGUE, _tongue(rng.randi() % LowPolyFlame.VARIANTS), 0.02 * i, TONGUE_LIFE * rng.randf_range(0.7, 1.1), up_dir * radius * 0.8,
				radius * rng.randf_range(0.5, 0.8), point + off_t, up_b)
	var shard_m := CombatMeshes.shard(surface)
	for i in clampi(int(4.0 + radius * 4.0), 4, 16):
		var spread_v := up_b * Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.2, 1), rng.randf_range(-1, 1)) * 0.8
		var cone := (normal + spread_v).normalized()
		_add(K_SHARD, shard_m, 0.0, SHARD_LIFE * rng.randf_range(0.6, 1.0), cone * rng.randf_range(4.0, 9.0) * sqrt(radius),
			radius * rng.randf_range(0.08, 0.18), point)
	if _has_ground:
		var surf_b := basis_for_normal(ground_normal)
		var yaw_b := surf_b * Basis(Vector3.UP, rng.randf_range(0.0, TAU))
		var scorch_r := radius * 0.8
		_add(K_RING, _ring(), 0.0, RING_LIFE, Vector3.ZERO, radius * 1.5,
			ground_point + ground_normal * 0.05, surf_b)
		_add(K_SCORCH, _scorch(rng.randi_range(0, 3)), 0.0, SCORCH_LIFE, Vector3.ZERO, scorch_r,
			ground_point + ground_normal * 0.025, yaw_b)
		_add(K_EMBER, _ember(rng.randi_range(0, 3)), 0.0, EMBER_LIFE, Vector3.ZERO, scorch_r * 0.56,
			ground_point + ground_normal * 0.055, yaw_b)
		var n_peb := clampi(int(2.5 + radius * 0.55), 3, 5)
		for i in n_peb:
			var ang := (TAU / float(n_peb)) * float(i) + rng.randf_range(-0.35, 0.35)
			var dist_r := scorch_r * rng.randf_range(0.55, 0.96)
			var peb_sz := clampf(radius * rng.randf_range(0.07, 0.13), 0.10, 0.42)
			var off_t := (surf_b.x * cos(ang) + surf_b.z * sin(ang)) * dist_r
			var peb_at := ground_point + off_t + ground_normal * (peb_sz * 0.32)
			var peb_b := surf_b * Basis(Vector3.UP, rng.randf_range(0.0, TAU)) * Basis.from_scale(Vector3(1.15, 0.58, 0.95))
			_add(K_PEBBLE, _rubble(), 0.0, SCORCH_LIFE, Vector3.ZERO, peb_sz, peb_at, peb_b)
	elif wall_surf.has("point") and wall_surf.has("normal") and (wall_surf["normal"] as Vector3).dot(up_dir) < 0.7:
		# a static wall: the scorch + cooling ember sit flush on the wall's own surface and normal
		var wn := (wall_surf["normal"] as Vector3).normalized()
		var wp := wall_surf["point"] as Vector3
		var surf_b := basis_for_normal(wn)
		var yaw_b := surf_b * Basis(Vector3.UP, rng.randf_range(0.0, TAU))
		var scorch_r := radius * 0.7
		_add(K_SCORCH, _scorch(rng.randi_range(0, 3)), 0.0, SCORCH_LIFE, Vector3.ZERO, scorch_r,
			wp + wn * 0.03, yaw_b)
		_add(K_EMBER, _ember(rng.randi_range(0, 3)), 0.0, EMBER_LIFE, Vector3.ZERO, scorch_r * 0.52,
			wp + wn * 0.055, yaw_b)
	for j in _pn:
		_p_spin[j] = Vector3(rng.randf_range(-6, 6), rng.randf_range(-6, 6), rng.randf_range(-6, 6))
	advance_to(w.now)


## A tall faceted column rising from the impact (on the ground under it when there is one) to `height` m: a flame stem,
## a smoke stem that outlasts it and a stack of flame chunks turning to smoke, the top ones bigger (a cap). Additive:
## call it right after setup.
func add_column(height: float) -> void:
	if height <= 0.0 or world == null:
		return
	column = height
	var rng := world.looks_rng
	var base := ground_point if _has_ground else point
	var up_b := basis_for_normal(up_dir)
	var w := radius * 0.32
	_add(K_COLUMN, stem(false), 0.0, COLUMN_LIFE, Vector3.ZERO, w, base, up_b)
	_p_h[_pn - 1] = height
	_add(K_COLUMN, stem(true), 0.25, SMOKE_LIFE, Vector3.ZERO, w * 1.25, base, up_b)
	_p_h[_pn - 1] = height * 1.1
	var n := 6
	for i in n:
		var f := float(i + 1) / float(n)
		var off := (up_b.x * rng.randf_range(-0.5, 0.5) + up_b.z * rng.randf_range(-0.5, 0.5)) * w + up_dir * (height * f)
		var life := lerpf(CHUNK_LIFE * 1.2, SMOKE_LIFE, f)
		_add(K_CHUNK, null, COLUMN_RISE * f, life, up_dir * rng.randf_range(0.5, 1.5), radius * lerpf(0.3, 0.55, f * f), base + off)
		_p_spin[_pn - 1] = Vector3(rng.randf_range(-3, 3), rng.randf_range(-3, 3), rng.randf_range(-3, 3))
	advance_to(world.now)


func _add(kind: int, m: Mesh, born: float, life: float, vel: Vector3, size: float, at: Vector3,
		basis: Basis = Basis.IDENTITY) -> void:
	var mesh := m if m != null else ramp_mesh(0)
	var mi: MeshInstance3D = world.take_mesh(mesh) if world != null and is_instance_valid(world) else null
	if mi != null:
		_borrowed = true
	else:
		mi = CombatMeshes.instance(mesh)
		mi.top_level = true
		mi.visible = false
		add_child(mi)
	_p_kind.append(kind)
	_p_born.append(born)
	_p_life.append(life)
	_p_size.append(size)
	_p_h.append(0.0)
	_p_at.append(at)
	_p_vel.append(vel)
	_p_spin.append(Vector3.ZERO)
	_p_step.append(0)
	_p_placed.append(0)
	_p_shown.append(1 if mi.visible else 0)
	_p_basis.append(basis)
	_p_node.append(mi)
	_p_mesh.append(mesh)
	_pn += 1
	_end = maxf(_end, born + life)
	if kind == K_SCORCH or kind == K_PEBBLE:
		_rest_from = maxf(_rest_from, born)
		_rest_until = minf(_rest_until, born + life)
	else:
		_moving_end = maxf(_moving_end, born + life)
	_rested = false
	_live.append(_pn - 1)


func advance_to(now: float) -> void:
	age = now - t0
	if not is_inside_tree():
		return
	if age < _live_age:         # the clock went back: every part may show again
		_rewind()
	_live_age = age
	var resting := age >= _moving_end and age >= _rest_from and age < _rest_until
	if resting and _rested:
		return
	_rested = resting
	var i := _live.size()
	while i > 0:               # backwards, so a part that is over can be dropped in place (parts are independent)
		i -= 1
		var j := _live[i]
		var a := age - _p_born[j]
		var life := _p_life[j]
		if a < 0.0 or a >= life:
			if _p_shown[j] != 0:
				_p_shown[j] = 0
				_p_node[j].visible = false
			if a >= life:
				_live.remove_at(i)     # over for good (the clock only moves on): hidden, never looked at again
				_hand_back(j)
			continue
		if _p_placed[j] != 0:      # its node already holds its final transform
			if _p_shown[j] == 0:
				_p_shown[j] = 1
				_p_node[j].visible = true
			continue
		var kind := _p_kind[j]
		var mi := _p_node[j]
		if _p_shown[j] == 0:
			_p_shown[j] = 1
			mi.visible = true
		var u := a / life
		var at := _p_at[j]
		var size := _p_size[j]
		var b := _p_basis[j]
		match kind:
			K_CHUNK:
				at += _p_vel[j] * a
				size *= lerpf(0.6, 1.3, minf(u * 2.0, 1.0))
				var step := mini(int(u * FLAME_RAMP.size()), FLAME_RAMP.size() - 1)
				if step != _p_step[j] or a <= 0.0:
					_p_step[j] = step
					var rm := ramp_mesh(step)
					mi.mesh = rm
					_p_mesh[j] = rm
				b = Basis.from_euler(_p_spin[j] * a * 0.3)
				if u > 0.93:
					size = 0.0      # pops out (no fade)
			K_SHARD:
				at += _p_vel[j] * a - up_dir * (0.5 * Combat.GRAVITY * a * a)
				if _has_ground:
					var h_above := (at - ground_point).dot(ground_normal)
					var min_h := size * 0.3
					if h_above < min_h:
						at += ground_normal * (min_h - h_above)
				b = Basis.from_euler(_p_spin[j] * a)
			K_FLASH:
				b = Basis.IDENTITY
				if a >= FLASH_GROW:
					_p_placed[j] = 1    # grown: the same transform every frame until it is over
				size *= minf(a / FLASH_GROW, 1.0)
			K_TONGUE:
				at += _p_vel[j] * a
				# The tongue points -Y: flip it to lick up along local up_dir, leaning by its spin, stretching then popping out.
				var s := _p_spin[j]
				b = b * Basis.from_euler(Vector3(PI + s.x * 0.05, s.y, s.z * 0.05)) * Basis.from_scale(Vector3(1.0, lerpf(0.6, 1.6, u), 1.0))
				if u > 0.9:
					size = 0.0
			K_COLUMN:
				# Rises to full height along local up_dir in COLUMN_RISE s, then thins out until it pops.
				var hgt := _p_h[j] * minf(a / COLUMN_RISE, 1.0)
				var wid := size * lerpf(1.0, 0.45, u)
				b = b * Basis.from_scale(Vector3(1.0, maxf(hgt, 0.01) / maxf(wid, 0.001), 1.0))
				size = wid if u < 0.95 else 0.0
			K_RING:
				if u * 1.4 >= 1.0:
					_p_placed[j] = 1    # full size: the same transform every frame until it is over
				size *= minf(u * 1.4, 1.0)
			K_EMBER:
				size *= pow(maxf(1.0 - u, 0.0), 1.35)
			K_SCORCH, K_PEBBLE:
				_p_placed[j] = 1
		# Part nodes are top_level: their transform is their global transform (the same write as global_transform).
		mi.transform = Transform3D(b.scaled(Vector3.ONE * maxf(size, 0.0001)) if size > 0.0 else b.scaled(Vector3.ONE * 0.0001), at)


## A part over for good gives its borrowed node back to the pool at once (hidden already; the record keeps its mesh).
func _hand_back(j: int) -> void:
	var mi := _p_node[j]
	if not _borrowed or mi == null or world == null or not is_instance_valid(world) or not is_instance_valid(mi) \
			or mi.get_parent() == self:
		return
	_p_node[j] = null
	world.give_mesh(mi)


## The clock went back (never in play: the world clock only moves on): every part is live again; a part whose node went
## back to the pool borrows one again showing its mesh, and placed / settled parts are written again.
func _rewind() -> void:
	_live.resize(_pn)
	for j in _pn:
		_live[j] = j
		if _p_kind[j] == K_FLASH or _p_kind[j] == K_RING:
			_p_placed[j] = 0
		if _p_node[j] == null:
			var mi: MeshInstance3D = world.take_mesh(_p_mesh[j]) if world != null and is_instance_valid(world) else null
			if mi == null:
				mi = CombatMeshes.instance(_p_mesh[j])
				mi.top_level = true
				mi.visible = false
				add_child(mi)
			_p_node[j] = mi
			_p_shown[j] = 1 if mi.visible else 0
			_p_placed[j] = 0
	_rested = false


func _exit_tree() -> void:
	if not _borrowed or world == null or not is_instance_valid(world):
		return
	_borrowed = false
	for mi in _p_node:
		if mi != null and is_instance_valid(mi) and mi.get_parent() != self:
			world.give_mesh(mi)


## The parts as dictionaries (the `_parts` record).
func _parts_record() -> Array:
	var out: Array = []
	for j in _pn:
		out.append({"node": _p_node[j], "mesh": _p_mesh[j], "kind": KIND_NAMES[_p_kind[j]], "born": _p_born[j],
			"life": _p_life[j], "vel": _p_vel[j], "size": _p_size[j], "at": _p_at[j], "spin": _p_spin[j], "h": _p_h[j],
			"step": _p_step[j], "basis": _p_basis[j], "placed": _p_placed[j] != 0})
	return out


## Surface normal of the placed scorch decal, or Vector3.ZERO if no scorch was placed.
func scorch_normal() -> Vector3:
	for j in _pn:
		if _p_kind[j] == K_SCORCH:
			return _p_basis[j].y.normalized()
	return Vector3.ZERO


## Parts of a kind now showing (tests): "flash", "chunk", "tongue", "column", "shard", "ring", "scorch", "ember", "pebble".
func visible_parts(kind: String) -> int:
	var k := int(KINDS.get(kind, -1))
	var n := 0
	for j in _pn:
		if _p_kind[j] == k and _p_node[j] != null and _p_node[j].visible:
			n += 1
	return n


func finished() -> bool:
	return age >= _end
