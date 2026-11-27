class_name PilotFx
extends Node3D
## The pilot head's effects (docs/design/pilot-heads.md section 3.2, "Effect / colour"): tiny faceted flat-colour meshes
## moved in code, no textures, no GPUParticles. PilotHead makes one in setup(), connects its `fx(kind, strength)` signal
## (PilotHead.FX_KINDS) and advances it from PilotHead.advance, so time_scale and tests control it and every head has
## effects without the caller doing anything (fx_enabled false = the head emits nothing, so nothing spawns).
##   stars  continuous: 3 small stars orbit above the crown while on; strength 0 scatters them
##   smoke  continuous: slow dark wisp puffs rise off the crown while on; strength 0 stops new puffs
##   steam  one burst of white puffs off the crown per cue
##   sweat  a blue drop flung from a temple, falling
##   chips  2-3 shards in the head's own colour fly off and fall
##   flash  a white tint on the head's facets for about a frame (PilotFace.set_flash, on top of the flush)
## Positions are in the head root's local space and follow the skull (PilotFace.carried). Bounded: at most MAX_LIVE
## particles (the oldest is dropped), and every particle ends and is freed within its lifetime. Deterministic: its own
## RandomNumberGenerator seeded from the head id and seed (a look generator, never the global one).
## Cosmetic only (Net.LOCAL): every var here is local presentation state, nothing is synced or read by gameplay.

const MAX_LIVE := 24
const STAR_COUNT := 3
const STAR_ORBIT := 0.3          ## orbit radius (head units)
const STAR_RISE := 0.12          ## above the top of the head
const STAR_SPEED := 2.6          ## rad / s
const STAR_SCATTER := 0.45       ## seconds the scattered stars take to fly off and shrink away
const SMOKE_EVERY := 0.32
const SMOKE_LIFE := 2.2
const STEAM_PUFFS := 4
const STEAM_LIFE := 0.9
const SWEAT_LIFE := 1.0
const CHIP_LIFE := 1.1
const FLASH_HOLD := 0.035        ## seconds at full white (about two frames at 60 Hz), then FLASH_FADE back
const FLASH_FADE := 0.05
const GRAVITY := 6.0
const STAR_COLOUR := Color(1.0, 0.86, 0.25)
const SMOKE_COLOUR := Color(0.2, 0.2, 0.22)
const STEAM_COLOUR := Color(0.95, 0.96, 0.98)
const SWEAT_COLOUR := Color(0.35, 0.65, 1.0)

static var _meshes := {}

var head: PilotHead
var rng := RandomNumberGenerator.new()
var crown := Vector3(0, 1.15, 0)     ## top of the skull (head-rest, after girth)
var top := Vector3(0, 1.4, 0)        ## top of the whole head incl. flair
var skull_half := Vector3(0.3, 0.3, 0.3)
var skull_centre := Vector3(0, 0.8, 0)
var chip_colour := Color(0.9, 0.9, 0.85)
var stars_on := false
var smoke_on := false
var smoke_strength := 1.0
var flash := 0.0
var _flash_t := 1e9
var _smoke_t := 0.0
var _time := 0.0
var _live: Array[Dictionary] = []   ## {node, kind, t, life, pos, vel, spin, spin_v, size, phase}


## Hooks the effects to a head (called by PilotHead.setup after the face is built).
func attach(h: PilotHead) -> void:
	head = h
	name = "PilotFx"
	rng.seed = hash("pilotfx:%s:%d" % [h.head_id, h.look_seed])
	_measure()
	h.fx.connect(_on_fx)


## Live particle count (stars included).
func live_count() -> int:
	return _live.size()


func live_kinds() -> Dictionary:
	var out := {}
	for p in _live:
		out[p["kind"]] = int(out.get(p["kind"], 0)) + 1
	return out


## Drops every particle and the flash at once.
func clear() -> void:
	for p in _live:
		_free_node(p)
	_live.clear()
	stars_on = false
	smoke_on = false
	_set_flash(0.0)
	_flash_t = 1e9


func _on_fx(kind: String, strength: float) -> void:
	var s := clampf(strength if is_finite(strength) else 0.0, 0.0, 2.0)
	match kind:
		"stars":
			if s > 0.0:
				_stars_start()
			else:
				_stars_scatter()
		"smoke":
			smoke_on = s > 0.0
			smoke_strength = maxf(s, 0.3)
			_smoke_t = 0.0
		"steam":
			for i in maxi(1, roundi(STEAM_PUFFS * clampf(s, 0.4, 1.0))):
				_spawn_steam()
		"sweat":
			_spawn_sweat()
		"chips":
			for i in rng.randi_range(2, 3):
				_spawn_chip(maxf(s, 0.5))
		"flash":
			_flash_t = 0.0
			_set_flash(clampf(s, 0.5, 1.0))


## One deterministic step (PilotHead.advance calls it with the head's scaled delta).
func advance(delta: float) -> void:
	if delta <= 0.0 or not is_finite(delta):
		return
	_time += delta
	# Flash: hold, then fade.
	if _flash_t < 1e8:
		_flash_t += delta
		if _flash_t >= FLASH_HOLD + FLASH_FADE:
			_set_flash(0.0)
			_flash_t = 1e9
		elif _flash_t > FLASH_HOLD:
			_set_flash(flash * (1.0 - (_flash_t - FLASH_HOLD) / FLASH_FADE))
	# Smoke: a wisp every SMOKE_EVERY while on.
	if smoke_on:
		_smoke_t -= delta
		if _smoke_t <= 0.0:
			_smoke_t = SMOKE_EVERY * rng.randf_range(0.8, 1.25)
			_spawn_smoke()
	var tp := _carried(top)
	var keep: Array[Dictionary] = []
	for p in _live:
		p["t"] = float(p["t"]) + delta
		var t := float(p["t"])
		var life := float(p["life"])
		if life > 0.0 and t >= life:
			_free_node(p)
			continue
		var n: Node3D = p["node"]
		var k := str(p["kind"])
		var scl := 1.0
		match k:
			"star":
				var a := float(p["phase"]) + _time * STAR_SPEED
				var bob := sin(_time * 3.0 + float(p["phase"])) * 0.025
				p["pos"] = tp + Vector3(cos(a) * STAR_ORBIT, STAR_RISE + bob, sin(a) * STAR_ORBIT * 0.8)
				n.rotation = Vector3(0.0, -a * 2.0, 0.25)
				scl = minf(t / 0.15, 1.0)
			"star_out":
				p["vel"] = (p["vel"] as Vector3) * exp(-2.0 * delta)
				p["pos"] = (p["pos"] as Vector3) + (p["vel"] as Vector3) * delta
				n.rotation.y += 9.0 * delta
				scl = 1.0 - t / life
			"smoke":
				p["vel"] = (p["vel"] as Vector3) * exp(-0.6 * delta) + Vector3(0, 0.25, 0) * delta
				p["pos"] = (p["pos"] as Vector3) + (p["vel"] as Vector3) * delta
				scl = _puff_env(t / life) * lerpf(1.0, 2.2, t / life)
			"steam":
				p["vel"] = (p["vel"] as Vector3) * exp(-3.0 * delta)
				p["pos"] = (p["pos"] as Vector3) + (p["vel"] as Vector3) * delta
				scl = _puff_env(t / life) * lerpf(0.8, 1.8, t / life)
			"sweat", "chip":
				p["vel"] = (p["vel"] as Vector3) + Vector3(0, -GRAVITY, 0) * delta
				p["pos"] = (p["pos"] as Vector3) + (p["vel"] as Vector3) * delta
				n.rotation += (p["spin_v"] as Vector3) * delta
				scl = 1.0 - smoothstep(0.75, 1.0, t / life)
		n.position = p["pos"]
		n.scale = Vector3.ONE * maxf(float(p["size"]) * scl, 0.001)
		keep.append(p)
	_live = keep
	if stars_on:
		var any := false
		for p in _live:
			if p["kind"] == "star":
				any = true
		if not any:
			stars_on = false


# --- spawning ---------------------------------------------------------------------------------------

func _stars_start() -> void:
	if stars_on:
		return
	stars_on = true
	for i in STAR_COUNT:
		var p := _spawn("star", _mesh_star(), 0.0, _carried(top), Vector3.ZERO, 1.0)
		p["phase"] = TAU * float(i) / float(STAR_COUNT)


func _stars_scatter() -> void:
	stars_on = false
	var tp := _carried(top)
	for p in _live:
		if p["kind"] == "star":
			p["kind"] = "star_out"
			p["t"] = 0.0
			p["life"] = STAR_SCATTER
			var out := ((p["pos"] as Vector3) - tp)
			out.y = 0.0
			p["vel"] = out.normalized() * 2.2 + Vector3(0, 0.8, 0)


func _spawn_smoke() -> void:
	var off := Vector3(rng.randf_range(-0.06, 0.06), 0.02, rng.randf_range(-0.06, 0.06))
	var vel := Vector3(rng.randf_range(-0.05, 0.05), 0.3, rng.randf_range(-0.05, 0.05))
	_spawn("smoke", _mesh_puff(SMOKE_COLOUR, false), SMOKE_LIFE, _carried(crown) + off, vel,
		rng.randf_range(0.8, 1.15) * clampf(smoke_strength, 0.5, 1.2))


func _spawn_steam() -> void:
	var a := rng.randf_range(0.0, TAU)
	var vel := Vector3(cos(a) * 0.35, rng.randf_range(1.0, 1.5), sin(a) * 0.35)
	var off := Vector3(cos(a) * 0.08, 0.0, sin(a) * 0.08)
	_spawn("steam", _mesh_puff(STEAM_COLOUR, true), STEAM_LIFE * rng.randf_range(0.8, 1.1), _carried(crown) + off, vel,
		rng.randf_range(0.8, 1.2))


func _spawn_sweat() -> void:
	var side := 1 if rng.randf() < 0.5 else 0
	var e: Dictionary = head.face.eyes[side] if head.face.eyes.size() > side else {}
	var at := skull_centre + Vector3(0.25 if side == 1 else -0.25, 0.15, 0)
	var out := Vector3(1.0 if side == 1 else -1.0, 0.0, 0.0)
	if not e.is_empty():
		var across: Vector3 = (e["across"] as Vector3).normalized()
		at = (e["p"] as Vector3) + across * 0.12 + Vector3(0, 0.08, 0)
		out = across
	var vel := out * rng.randf_range(0.8, 1.2) + Vector3(0, rng.randf_range(0.6, 1.0), 0)
	var p := _spawn("sweat", _mesh_drop(), SWEAT_LIFE, _carried(at), vel, 1.0)
	p["spin_v"] = Vector3(0, 0, -out.x * 3.0)


func _spawn_chip(s: float) -> void:
	var dir := Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(0.2, 1.0), rng.randf_range(-0.3, 1.0)).normalized()
	var at := skull_centre + dir * skull_half * 0.9
	var vel := dir * rng.randf_range(1.4, 2.2) * s + Vector3(0, 1.0, 0)
	var p := _spawn("chip", _mesh_chip(chip_colour), CHIP_LIFE * rng.randf_range(0.85, 1.1), _carried(at), vel,
		rng.randf_range(0.8, 1.2))
	p["spin_v"] = Vector3(rng.randf_range(-12, 12), rng.randf_range(-12, 12), rng.randf_range(-12, 12))


func _spawn(kind: String, mesh: Mesh, life: float, pos: Vector3, vel: Vector3, size: float) -> Dictionary:
	while _live.size() >= MAX_LIVE:
		_free_node(_live[0])
		_live.remove_at(0)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = pos
	mi.scale = Vector3.ONE * 0.001
	add_child(mi)
	var p := {"node": mi, "kind": kind, "t": 0.0, "life": life, "pos": pos, "vel": vel, "spin_v": Vector3.ZERO,
		"size": size, "phase": 0.0}
	_live.append(p)
	return p


func _free_node(p: Dictionary) -> void:
	var n: Node = p["node"]
	if is_instance_valid(n):
		if n.get_parent() == self:
			remove_child(n)
		n.queue_free()


## Sets the face's flash; `flash` keeps the cue's peak so the fade scales from it.
func _set_flash(v: float) -> void:
	if v <= 0.0:
		flash = 0.0
	elif _flash_t <= FLASH_HOLD:
		flash = v
	if head != null and head.face != null:
		head.face.set_flash(maxf(v, 0.0))


func _carried(p: Vector3) -> Vector3:
	if head == null or head.face == null:
		return p
	return head.face.carried("Skull", p)


static func _puff_env(u: float) -> float:
	return smoothstep(0.0, 0.15, u) * (1.0 - smoothstep(0.6, 1.0, u))


## Reads the rest shape: the skull's top / centre / size and its main colour, the whole head's top.
func _measure() -> void:
	var skull := head.face.piece("Skull")
	var all := AABB()
	var first := true
	for mi in head.find_children("*", "MeshInstance3D", true, false):
		if is_ancestor_of(mi):
			continue
		var m := (mi as MeshInstance3D).mesh
		if m == null:
			continue
		all = m.get_aabb() if first else all.merge(m.get_aabb())
		first = false
	var body := head.face.body
	if skull != null and body != null:
		var b := body.skull_box()   # the part of the one body mesh the Skull carries alone (with its extras)
		crown = Vector3(0.0, b.end.y, b.get_center().z)
		skull_half = b.size * 0.5
		skull_centre = b.get_center()
		chip_colour = _main_colour(body.skull_colours())
	if not first:
		top = Vector3(0.0, all.end.y, crown.z)


static func _main_colour(cols: PackedColorArray) -> Color:
	var votes := {}
	var best := Color(0.9, 0.9, 0.85)
	var most := 0
	for i in range(0, cols.size(), 3):
		var c := cols[i]
		var key := "%d,%d,%d" % [int(c.r * 8.0), int(c.g * 8.0), int(c.b * 8.0)]
		votes[key] = int(votes.get(key, 0)) + 1
		if int(votes[key]) > most:
			most = int(votes[key])
			best = c
	return best


# --- meshes (built once, shared) --------------------------------------------------------------------

static func _mesh_star() -> Mesh:
	if not _meshes.has("star"):
		var k := MeshKit.new()
		k.glow = true
		var rim: Array[Vector3] = []
		for i in 10:
			var a := TAU * float(i) / 10.0 + PI / 2.0
			var r := 0.075 if i % 2 == 0 else 0.032
			rim.append(Vector3(cos(a) * r, sin(a) * r, 0.0))
		for i in 10:
			var a := rim[i]
			var b := rim[(i + 1) % 10]
			k.tri(Vector3(0, 0, 0.024), a, b, STAR_COLOUR, Vector3.ZERO)
			k.tri(Vector3(0, 0, -0.024), a, b, STAR_COLOUR.darkened(0.15), Vector3.ZERO)
		_meshes["star"] = k.commit(LowPolyMaterials.materials())
	return _meshes["star"]


static func _mesh_puff(col: Color, glow: bool) -> Mesh:
	var key := "puff" + col.to_html()
	if not _meshes.has(key):
		var k := MeshKit.new()
		k.glow = glow
		k.ico(Vector3.ZERO, Vector3(0.07, 0.06, 0.07), col)
		_meshes[key] = k.commit(LowPolyMaterials.materials())
	return _meshes[key]


static func _mesh_drop() -> Mesh:
	if not _meshes.has("drop"):
		var k := MeshKit.new()
		k.seg(Vector3(0, 0.1, 0), Vector3(0, 0.0, 0), Vector2.ZERO, Vector2(0.05, 0.05), 5, SWEAT_COLOUR, 2.0, false, 0.0)
		k.seg(Vector3(0, 0.0, 0), Vector3(0, -0.05, 0), Vector2(0.05, 0.05), Vector2.ZERO, 5, SWEAT_COLOUR.darkened(0.1),
			2.0, false, 0.0)
		_meshes["drop"] = k.commit(LowPolyMaterials.materials())
	return _meshes["drop"]


static func _mesh_chip(col: Color) -> Mesh:
	var key := "chip" + col.to_html()
	if not _meshes.has(key):
		var k := MeshKit.new()
		var a := Vector3(0.1, 0.0, 0.0)
		var b := Vector3(-0.065, 0.06, 0.0)
		var c := Vector3(-0.05, -0.065, 0.015)
		var d := Vector3(0.0, 0.0, 0.04)
		var ctr := (a + b + c + d) * 0.25
		for f: Array in [[a, b, c], [a, b, d], [b, c, d], [c, a, d]]:
			k.tri(f[0], f[1], f[2], col, ctr)
		_meshes[key] = k.commit(LowPolyMaterials.materials())
	return _meshes[key]
