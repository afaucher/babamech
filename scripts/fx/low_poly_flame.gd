class_name LowPolyFlame
extends RefCounted
## The game's ONE flame look (thrusters, flamethrower, burning hits): solid low-poly flames. Faceted, flat-shaded,
## nested shapes in three flat colours (outer orange, mid amber, white-yellow core), unshaded so they light themselves.
## No particles, no soft gradients, no textures. Animate them by moving / scaling / turning rigid pieces, never by
## smoothing.
##
## API
##   LowPolyFlame.material()        the shared unshaded vertex-colour material (colours read as sRGB, so OUTER really
##                                  is that orange; fog off, so distance doesn't wash it out).
##   LowPolyFlame.jet()             ArrayMesh: three nested 5-sided cones, ~0.6 wide, 1.7 long, origin = nozzle, tip -Y.
##   LowPolyFlame.tongue(band)      ArrayMesh: one flame chunk, a faceted teardrop, base at the origin, tip -Y, ~0.7 wide,
##                                  1.25 long. band HOT (amber skin, core inside) near a nozzle, WARM (orange, core),
##                                  COOL (orange, amber inside) at the end of a stream. tongue() = WARM.
##   LowPolyFlame.tongue(band, v)   the same tongue in colour variant v (0..VARIANTS-1, 0 = the centre colours above):
##                                  1 a step toward yellow, 2 a step toward red, 3 hotter / brighter, 4 deeper / darker.
##                                  Every variant is still one flat colour set per piece, cached like the centre one.
##   LowPolyFlame.variant_color(c, v)  the colour `c` (OUTER / MID / CORE) in variant v.
##   LowPolyFlame.Stream            Node3D: a flame stream of rigid tongues. Each tongue spawns at the node's origin,
##                                  flies out along -Y, grows then shrinks, drifts sideways and tumbles a little, with
##                                  deterministic jitter (hash of jitter_seed, tongue and life count; no global randf). A tongue
##                                  only lives if `emitting` was on when it spawned, so the stream lights up from the
##                                  nozzle outward and a cut-off flame detaches and flies off whole.
##     Point the node's -Y where the flame goes (its basis carries direction; keep the basis unscaled), then set:
##       emitting   bool    spawn new tongues
##       length     m       how far a tongue travels before it dies (the stream's reach)
##       width      m       a tongue's peak width (its length is ~1.75x that)
##       speed      m/s     tongue travel speed (rate of flow: lifetime = length / speed)
##       count      int     tongues in flight at once (density; set before adding to the tree, or call rebuild())
##       spread     0..1    sideways drift at the far end, as a share of length (a thruster ~0.06, a flamer ~0.15)
##       tumble     rad     how far a tongue tips off the axis
##       root       float   0 = none, else the scale of a jet() cone kept at the nozzle (a hot, steady base)
##       jitter_seed int   jitter seed (give each jet / weapon its own)
##       color_jitter 0..1 share of tongues drawn in a colour variant instead of the centre colours, and how far the
##                         bands overlap (some WARM tongues among the HOT ones and back): a mottled flame instead of
##                         flat bands. Picked per tongue life from hash01(jitter_seed, tongue, life). 0 = no jitter.
##       max_length m      INF = off (the default: the stream is exactly as without it). Else a cap along -Y where the
##                         flame meets something: a tongue reaching the last SPLAT_WIDTHS × width before it squashes
##                         wide and short, then shrinks in rigid steps and is gone at the cap (a splat, no fade); none
##                         flies past it. Set it every step from a ray along the axis (the flamer does).
##     active() -> bool     any tongue (or the root) is still showing.
##     advance(dt)          steps it; called from _process, or by hand with `manual = true` (tests, replays).
##   A flamethrower: add a Stream at the muzzle with -Y along the barrel, length = range, spread ~0.15, emitting while
##   the trigger is held. Tongues live in the stream's local space, so they swing with the muzzle (no world-space lag).

const OUTER := Color(1.0, 0.42, 0.06)
const MID := Color(1.0, 0.68, 0.12)
const CORE := Color(1.0, 0.95, 0.6)
const SIDES := 5                   ## facet count around a cone: few on purpose
const VARIANTS := 5                ## colour variants per tongue band (0 = the centre colours)
enum { HOT, WARM, COOL }

static var _mat: StandardMaterial3D
static var _cache: Dictionary = {}


## Flat vertex colours, unshaded: shared by every flame mesh.
static func material() -> StandardMaterial3D:
	if _mat == null:
		_mat = StandardMaterial3D.new()
		_mat.vertex_color_use_as_albedo = true
		_mat.vertex_color_is_srgb = true   # the constants are sRGB colours; read as linear they came out pale (255,173,69)
		_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mat.disable_fog = true
	return _mat


## A thruster jet: three nested faceted cones, 1 unit wide at the nozzle-ish, ~1.7 long, pointing -Y.
static func jet() -> ArrayMesh:
	if _cache.has("jet"):
		return _cache["jet"]
	var k := MeshKit.new()
	k.glow = true
	k.shade = 0.0
	k.lathe([Vector2(0.22, 0.0), Vector2(0.3, -0.25), Vector2(0.2, -0.9), Vector2(0.0, -1.7)], SIDES, OUTER)
	k.lathe([Vector2(0.16, 0.01), Vector2(0.21, -0.22), Vector2(0.12, -0.75), Vector2(0.0, -1.3)], SIDES, MID)
	k.lathe([Vector2(0.1, 0.02), Vector2(0.12, -0.18), Vector2(0.05, -0.5), Vector2(0.0, -0.85)], SIDES, CORE)
	var m := k.commit([material(), material()])
	_cache["jet"] = m
	return m


## One flame tongue (a chunk for streams and fires): a squat faceted teardrop, base at the origin, tip -Y. Its inner
## piece pokes out of the wide end, so the hotter colour shows from behind as well as through the gaps of a stream.
static func tongue(band: int = WARM, variant: int = 0) -> ArrayMesh:
	variant = clampi(variant, 0, VARIANTS - 1)
	var key := "tongue_%d" % band if variant == 0 else "tongue_%d_%d" % [band, variant]
	if _cache.has(key):
		return _cache[key]
	var skin: Color = variant_color(MID if band == HOT else OUTER, variant)
	var heart: Color = variant_color(MID if band == COOL else CORE, variant)
	var k := MeshKit.new()
	k.glow = true
	k.shade = 0.0
	k.lathe([Vector2(0.0, 0.25), Vector2(0.35, 0.05), Vector2(0.3, -0.35), Vector2(0.0, -1.0)], SIDES, skin)
	k.lathe([Vector2(0.0, 0.32), Vector2(0.22, 0.08), Vector2(0.16, -0.3), Vector2(0.0, -0.6)], SIDES, heart)
	var m := k.commit([material(), material()])
	_cache[key] = m
	return m


## A flame colour in variant v (see tongue()): small steps around the centre colour, still saturated flame colours.
static func variant_color(c: Color, v: int) -> Color:
	match v:
		1: return Color(c.r, minf(c.g + 0.13, 1.0), minf(c.b + 0.04, 1.0))          # toward yellow
		2: return Color(c.r, c.g * 0.85, c.b * 0.7)                                  # toward red
		3: return c.lerp(Color(1.0, 0.92, 0.62), 0.3)                                # hotter, brighter
		4: return Color(c.r * 0.9, c.g * 0.84, c.b * 0.8)                           # deeper, darker
	return c


## A deterministic 0..1 value from integers (jitter without global randomness).
static func hash01(a: int, b: int, c: int, d: int = 0) -> float:
	return float(hash([a, b, c, d]) & 0xFFFFFF) / float(0xFFFFFF)


## A flame stream of rigid tongues (see the API at the top of this file).
class Stream extends Node3D:
	var emitting := false
	var length := 4.0
	var width := 1.0
	var speed := 12.0
	var count := 8
	var spread := 0.08
	var tumble := 0.3
	var root := 0.0
	var jitter_seed := 0
	var manual := false
	var max_length := INF              ## cap along -Y (see the API); INF = off
	var color_jitter := 0.6            ## colour variants and band overlap (see the API); 0 = flat bands
	const SPLAT_WIDTHS := 1.5          ## the splat runs over this many widths before the cap
	const SPLAT_STEPS := 4             ## rigid steps of the splat: squash wide, then shrink, shrink, gone

	var _tongues: Array = []           ## per tongue: {mi, p (0..1 along the flight), life, alive, j (jitter Array)}
	var _root: MeshInstance3D
	var _t := 0.0

	func _ready() -> void:
		if _tongues.is_empty():
			rebuild()

	## (Re)make the tongues, all dead, evenly staggered along the flight.
	func rebuild() -> void:
		for t: Dictionary in _tongues:
			(t["mi"] as Node).queue_free()
		_tongues.clear()
		for i in count:
			var mi := MeshInstance3D.new()
			mi.mesh = LowPolyFlame.tongue()
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.visible = false
			add_child(mi)
			var t := {"mi": mi, "p": float(i) / float(count), "life": -1, "alive": false, "j": []}
			_jitter(t, i)
			_tongues.append(t)
		if _root == null:
			_root = MeshInstance3D.new()
			_root.mesh = LowPolyFlame.jet()
			_root.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_root.visible = false
			add_child(_root)

	func active() -> bool:
		if _root != null and _root.visible:
			return true
		for t: Dictionary in _tongues:
			if t["alive"]:
				return true
		return false

	func _process(delta: float) -> void:
		if not manual:
			advance(delta)

	func advance(delta: float) -> void:
		if _tongues.is_empty():
			rebuild()
		_t += delta
		var step := delta * speed / maxf(length, 0.1)
		for i in _tongues.size():
			var t: Dictionary = _tongues[i]
			t["p"] = float(t["p"]) + step
			if t["p"] >= 1.0:   # back to the nozzle: a new tongue, alive only if the stream is on now
				t["p"] = fmod(float(t["p"]), 1.0)
				t["life"] = int(t["life"]) + 1
				t["alive"] = emitting
				_jitter(t, i)
			_pose(t)
		if _root != null:
			_root.visible = emitting and root > 0.0
			if _root.visible:
				var f := 0.9 + 0.1 * sin(_t * 41.0 + float(jitter_seed)) + 0.06 * sin(_t * 17.0)
				_root.transform = Transform3D(Basis.from_scale(Vector3(width, width * f, width) * root), Vector3.ZERO)

	func _jitter(t: Dictionary, i: int) -> void:
		var life := int(t["life"])
		var j: Array = []
		for k in 8:      # 0..5 shape the flight, 6..7 the colour (added later: 0..5 are unchanged)
			j.append(LowPolyFlame.hash01(jitter_seed, i, life, k))
		t["j"] = j

	func _pose(t: Dictionary) -> void:
		var mi: MeshInstance3D = t["mi"]
		mi.visible = t["alive"]
		if not mi.visible:
			return
		var p := float(t["p"])
		var j: Array = t["j"]
		# Grow fast out of the nozzle, peak about a third of the way, shrink to nothing at the end.
		var g := sin(PI * pow(p, 0.55)) * (0.8 + 0.4 * float(j[0]))
		g = maxf(g, 0.12) * width
		var pb := p + (float(j[6]) - 0.5) * 0.36 * color_jitter     # bands overlap a little: mottled, not striped
		var band := LowPolyFlame.HOT if pb < 0.3 else (LowPolyFlame.WARM if pb < 0.65 else LowPolyFlame.COOL)
		var variant := 0
		if float(j[7]) < color_jitter:
			variant = 1 + mini(int(float(j[7]) / color_jitter * float(LowPolyFlame.VARIANTS - 1)), LowPolyFlame.VARIANTS - 2)
		var mesh := LowPolyFlame.tongue(band, variant)
		if mi.mesh != mesh:
			mi.mesh = mesh
		# Drift sideways (more the further out), spin about the axis and tip off it, all from this life's jitter.
		var a := TAU * float(j[1])
		var drift := Vector3(cos(a), 0.0, sin(a)) * spread * length * p * (0.4 + 0.6 * float(j[2]))
		var spin := TAU * float(j[3]) + p * (float(j[4]) - 0.5) * 6.0
		var tip := (float(j[5]) - 0.5) * 2.0 * tumble * (0.3 + p)
		var b := Basis(Vector3.UP, spin) * Basis(Vector3.RIGHT, tip)
		# The tongue's base trails its centre, so it starts at the nozzle: place it by its middle.
		var at := Vector3(0.0, -p * length, 0.0) + drift
		var gx := g
		var gy := g * 1.4
		if max_length < length:     # capped: splat against the cap (off by default, so the stream is unchanged)
			var cap := maxf(max_length, 0.0)
			var zone := minf(SPLAT_WIDTHS * width, maxf(cap, 0.01))
			var k := clampf((p * length - (cap - zone)) / zone, 0.0, 1.0)
			var step := int(floor(k * float(SPLAT_STEPS)))
			if step >= SPLAT_STEPS:
				mi.visible = false
				return
			if step > 0:
				var wide: float = [1.0, 1.35, 0.8, 0.45][step]
				var tall: float = [1.0, 0.6, 0.4, 0.22][step]
				gx = g * wide
				gy = g * 1.4 * tall
				drift *= 1.0 + 0.4 * float(step)
			# Never past the cap: the tongue's front (its tip, ~0.65 of its length ahead of the middle) stops at it.
			at = Vector3(0.0, -minf(p * length, maxf(cap - 0.65 * gy, 0.0)), 0.0) + drift
		mi.transform = Transform3D(b.scaled_local(Vector3(gx, gy, gx)), at + b * Vector3(0.0, 0.35 * gy, 0.0))
