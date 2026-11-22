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
var _parts: Array = []         ## {node, kind, born, life, vel, size, at, spin, h, step, basis, placed}
## Part lifetimes, kept as parts are added (so `finished` and `advance_to` need no scan over the parts):
var _end := 0.0                ## latest born + life of any part (finished after it)
var _moving_end := 0.0         ## latest born + life of a part that animates (anything but scorch / pebble)
var _rest_from := 0.0          ## latest birth of a resting part (scorch / pebble)
var _rest_until := INF         ## earliest born + life of a resting part
## True after a full pass in the resting phase (age in [max(_moving_end, _rest_from), _rest_until)): every animated part
## is hidden and every resting part placed and shown, so later passes in that phase would change nothing and are skipped.
## An impact spends most of its 10 s there (the scorch outlives the fire by ~4x).
var _rested := false
var _live: Array = []          ## the parts not yet over (a part past born + life is hidden and dropped from here)
var _live_age := -INF          ## age at the last advance (a step back in time restores _live from _parts)


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({"radius": Net.LOCAL, "point": Net.LOCAL, "normal": Net.LOCAL, "ground_y": Net.LOCAL,
		"ground_point": Net.LOCAL, "ground_normal": Net.LOCAL, "up_dir": Net.LOCAL, "_has_ground": Net.LOCAL,
		"age": Net.LOCAL, "column": Net.LOCAL, "_parts": Net.LOCAL, "_end": Net.LOCAL, "_moving_end": Net.LOCAL,
		"_rest_from": Net.LOCAL, "_rest_until": Net.LOCAL, "_rested": Net.LOCAL, "_live": Net.LOCAL, "_live_age": Net.LOCAL})
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
	var key := "ball|" + c.to_html()
	if not _meshes.has(key):
		var k := MeshKit.new()
		k.glow = true
		k.shade = 0.07         # a flat colour per facet, a touch apart, so the ball reads as faceted, not a disc
		k.ico(Vector3.ZERO, Vector3.ONE, c)
		_meshes[key] = k.commit([LowPolyFlame.material(), LowPolyFlame.material()])
	return _meshes[key]


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
	var c: Color = FLAME_RAMP[step]
	return CombatMeshes.ico(c) if step == FLAME_RAMP.size() - 1 else flame_ball(c)


## `flash_color`: the flash ball's colour (default the flame core; the laser's is teal).
## `ground_surf`: optional {point, normal} from CombatWorld.surface_below() for flush curved-deck alignment.
func setup(w: CombatWorld, at: Vector3, n: Vector3, r: float, surface: Color, ground: float, explosive: bool,
		flash_color: Color = LowPolyFlame.CORE, ground_surf: Dictionary = {}, local_up: Vector3 = Vector3.UP) -> void:
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
	_add("flash", flame_ball(flash_color), 0.0, FLASH_LIFE, Vector3.ZERO, radius, point)
	var chunks := clampi(int(5.0 + radius * 2.5), 5, 12)
	for wave in (2 if explosive else 1):
		for i in chunks:
			var off_local := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.3, 1), rng.randf_range(-1, 1)) * radius * 0.5
			var vel := (normal * rng.randf_range(0.5, 1.5) + up_dir * rng.randf_range(0.8, 2.0)) * (0.6 + radius * 0.4) * (0.5 if wave == 1 else 1.0)
			var life := CHUNK_LIFE * rng.randf_range(0.7, 1.2) * (1.6 if wave == 1 else 1.0)
			_add("chunk", null, 0.05 + 0.15 * wave, life, vel, radius * rng.randf_range(0.25, 0.45) * (1.3 if wave == 1 else 1.0), point + up_b * off_local)
	if explosive:
		for i in clampi(int(2.0 + radius), 3, 7):
			var off_t := (up_b.x * rng.randf_range(-1, 1) + up_b.z * rng.randf_range(-1, 1)) * radius * 0.35
			_add("tongue", LowPolyFlame.tongue(LowPolyFlame.WARM, rng.randi() % LowPolyFlame.VARIANTS), 0.02 * i, TONGUE_LIFE * rng.randf_range(0.7, 1.1), up_dir * radius * 0.8,
				radius * rng.randf_range(0.5, 0.8), point + off_t, up_b)
	for i in clampi(int(4.0 + radius * 4.0), 4, 16):
		var spread_v := up_b * Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.2, 1), rng.randf_range(-1, 1)) * 0.8
		var cone := (normal + spread_v).normalized()
		_add("shard", CombatMeshes.shard(surface), 0.0, SHARD_LIFE * rng.randf_range(0.6, 1.0), cone * rng.randf_range(4.0, 9.0) * sqrt(radius),
			radius * rng.randf_range(0.08, 0.18), point)
	if _has_ground:
		var surf_b := basis_for_normal(ground_normal)
		var yaw_b := surf_b * Basis(Vector3.UP, rng.randf_range(0.0, TAU))
		var scorch_r := radius * 0.8
		_add("ring", CombatMeshes.ring(RING_COLOR, 0.82), 0.0, RING_LIFE, Vector3.ZERO, radius * 1.5,
			ground_point + ground_normal * 0.05, surf_b)
		_add("scorch", CombatMeshes.scorch(SCORCH_COLOR, rng.randi_range(0, 3)), 0.0, SCORCH_LIFE, Vector3.ZERO, scorch_r,
			ground_point + ground_normal * 0.025, yaw_b)
		_add("ember", CombatMeshes.ember_scorch(rng.randi_range(0, 3)), 0.0, EMBER_LIFE, Vector3.ZERO, scorch_r * 0.56,
			ground_point + ground_normal * 0.055, yaw_b)
		var n_peb := clampi(int(2.5 + radius * 0.55), 3, 5)
		for i in n_peb:
			var ang := (TAU / float(n_peb)) * float(i) + rng.randf_range(-0.35, 0.35)
			var dist_r := scorch_r * rng.randf_range(0.55, 0.96)
			var peb_sz := clampf(radius * rng.randf_range(0.07, 0.13), 0.10, 0.42)
			var off_t := (surf_b.x * cos(ang) + surf_b.z * sin(ang)) * dist_r
			var peb_at := ground_point + off_t + ground_normal * (peb_sz * 0.32)
			var peb_b := surf_b * Basis(Vector3.UP, rng.randf_range(0.0, TAU)) * Basis.from_scale(Vector3(1.15, 0.58, 0.95))
			_add("pebble", CombatMeshes.shard(RUBBLE_COLOR), 0.0, SCORCH_LIFE, Vector3.ZERO, peb_sz, peb_at, peb_b)
	elif normal.dot(up_dir) < 0.7:   # a wall: the scorch + cooling ember sit flush on the wall normal
		var surf_b := basis_for_normal(normal)
		var yaw_b := surf_b * Basis(Vector3.UP, rng.randf_range(0.0, TAU))
		var scorch_r := radius * 0.7
		_add("scorch", CombatMeshes.scorch(SCORCH_COLOR, rng.randi_range(0, 3)), 0.0, SCORCH_LIFE, Vector3.ZERO, scorch_r,
			point + normal * 0.03, yaw_b)
		_add("ember", CombatMeshes.ember_scorch(rng.randi_range(0, 3)), 0.0, EMBER_LIFE, Vector3.ZERO, scorch_r * 0.52,
			point + normal * 0.055, yaw_b)
	for p: Dictionary in _parts:
		p["spin"] = Vector3(rng.randf_range(-6, 6), rng.randf_range(-6, 6), rng.randf_range(-6, 6))
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
	_add("column", stem(false), 0.0, COLUMN_LIFE, Vector3.ZERO, w, base, up_b)
	_parts[-1]["h"] = height
	_add("column", stem(true), 0.25, SMOKE_LIFE, Vector3.ZERO, w * 1.25, base, up_b)
	_parts[-1]["h"] = height * 1.1
	var n := 6
	for i in n:
		var f := float(i + 1) / float(n)
		var off := (up_b.x * rng.randf_range(-0.5, 0.5) + up_b.z * rng.randf_range(-0.5, 0.5)) * w + up_dir * (height * f)
		var life := lerpf(CHUNK_LIFE * 1.2, SMOKE_LIFE, f)
		_add("chunk", null, COLUMN_RISE * f, life, up_dir * rng.randf_range(0.5, 1.5), radius * lerpf(0.3, 0.55, f * f), base + off)
		_parts[-1]["spin"] = Vector3(rng.randf_range(-3, 3), rng.randf_range(-3, 3), rng.randf_range(-3, 3))
	advance_to(world.now)


func _add(kind: String, m: Mesh, born: float, life: float, vel: Vector3, size: float, at: Vector3,
		basis: Basis = Basis.IDENTITY) -> void:
	var mi := CombatMeshes.instance(m if m != null else ramp_mesh(0))
	mi.top_level = true
	mi.visible = false
	add_child(mi)
	_parts.append({"node": mi, "kind": kind, "born": born, "life": life, "vel": vel, "size": size, "at": at, "spin": Vector3.ZERO,
		"h": 0.0, "step": 0, "basis": basis, "placed": false})
	_end = maxf(_end, born + life)
	if kind == "scorch" or kind == "pebble":
		_rest_from = maxf(_rest_from, born)
		_rest_until = minf(_rest_until, born + life)
	else:
		_moving_end = maxf(_moving_end, born + life)
	_rested = false
	_live.append(_parts[-1])


func advance_to(now: float) -> void:
	age = now - t0
	if not is_inside_tree():
		return
	if age < _live_age:         # the clock went back: every part may show again
		_live = _parts.duplicate()
		_rested = false
	_live_age = age
	var resting := age >= _moving_end and age >= _rest_from and age < _rest_until
	if resting and _rested:
		return
	_rested = resting
	var i := _live.size()
	while i > 0:               # backwards, so a part that is over can be dropped in place (parts are independent)
		i -= 1
		var p: Dictionary = _live[i]
		var mi: MeshInstance3D = p["node"]
		var a := age - float(p["born"])
		var life := float(p["life"])
		if a < 0.0 or a >= life:
			mi.visible = false
			if a >= life:
				_live.remove_at(i)     # over for good (the clock only moves on): hidden, never looked at again
			continue
		var kind := str(p["kind"])
		if (kind == "scorch" or kind == "pebble") and bool(p["placed"]):
			mi.visible = true
			continue
		mi.visible = true
		var u := a / life
		var at: Vector3 = p["at"]
		var size := float(p["size"])
		var b: Basis = p["basis"]
		match kind:
			"flash":
				b = Basis.IDENTITY
				size *= minf(a / FLASH_GROW, 1.0)
			"chunk":
				at += (p["vel"] as Vector3) * a
				size *= lerpf(0.6, 1.3, minf(u * 2.0, 1.0))
				var step := mini(int(u * FLAME_RAMP.size()), FLAME_RAMP.size() - 1)
				if step != int(p["step"]) or a <= 0.0:
					p["step"] = step
					mi.mesh = ramp_mesh(step)
				b = Basis.from_euler((p["spin"] as Vector3) * a * 0.3)
				if u > 0.93:
					size = 0.0      # pops out (no fade)
			"tongue":
				at += (p["vel"] as Vector3) * a
				# The tongue points -Y: flip it to lick up along local up_dir, leaning by its spin, stretching then popping out.
				var s := p["spin"] as Vector3
				b = b * Basis.from_euler(Vector3(PI + s.x * 0.05, s.y, s.z * 0.05)) * Basis.from_scale(Vector3(1.0, lerpf(0.6, 1.6, u), 1.0))
				if u > 0.9:
					size = 0.0
			"column":
				# Rises to full height along local up_dir in COLUMN_RISE s, then thins out until it pops.
				var hgt := float(p["h"]) * minf(a / COLUMN_RISE, 1.0)
				var wid := size * lerpf(1.0, 0.45, u)
				b = b * Basis.from_scale(Vector3(1.0, maxf(hgt, 0.01) / maxf(wid, 0.001), 1.0))
				size = wid if u < 0.95 else 0.0
			"shard":
				at += (p["vel"] as Vector3) * a - up_dir * (0.5 * Combat.GRAVITY * a * a)
				if _has_ground:
					var h_above := (at - ground_point).dot(ground_normal)
					var min_h := size * 0.3
					if h_above < min_h:
						at += ground_normal * (min_h - h_above)
				b = Basis.from_euler((p["spin"] as Vector3) * a)
			"ring":
				size *= minf(u * 1.4, 1.0)
			"ember":
				size *= pow(maxf(1.0 - u, 0.0), 1.35)
			"scorch", "pebble":
				p["placed"] = true
		mi.global_transform = Transform3D(b.scaled(Vector3.ONE * maxf(size, 0.0001)) if size > 0.0 else b.scaled(Vector3.ONE * 0.0001), at)


## Surface normal of the placed scorch decal, or Vector3.ZERO if no scorch was placed.
func scorch_normal() -> Vector3:
	for p: Dictionary in _parts:
		if str(p["kind"]) == "scorch":
			return ((p["basis"] as Basis).y).normalized()
	return Vector3.ZERO


## Parts of a kind now showing (tests): "flash", "chunk", "tongue", "column", "shard", "ring", "scorch", "ember", "pebble".
func visible_parts(kind: String) -> int:
	var n := 0
	for p: Dictionary in _parts:
		if str(p["kind"]) == kind and (p["node"] as MeshInstance3D).visible:
			n += 1
	return n


func finished() -> bool:
	return age >= _end
