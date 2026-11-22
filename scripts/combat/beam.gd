class_name Beam
extends CombatEffect
## A beam between two points (weapons.md §3.1, §3.6): a faceted n-sided prism CORE inside a wider, paler SHELL of
## alternate facets (the core shows through the gaps), both unshaded flat colours from the MechMeshes palette. The width
## grows along the beam (w0 at `a` -> w1 at w_full m) so it reads at distance; the shell pulses and turns slowly.
## Cosmetic only: whoever fires it resolves the hit (the laser resolves once at beam start, weapons/laser.gd), the beam
## just shows for `life` s. `life` < 0 keeps it until removed and `set_points` moves it: the missile designator reuses it
## that way (a thin 3-sided core, no shell).
##
##   var b := Beam.new()
##   b.look = {"core": MechMeshes.TEAL, "sides": 6, "w0": 0.15, "w1": 0.6, "w_full": 150.0}
##   b.start(world, record, stats)       # or setup_cosmetic(world, a, b, life)
##   b.set_points(a, b)
##
## FOLLOW (cosmetic): `follow`, a Callable returning a world position, moves the beam's start there every step of its
## life (the laser passes the firer's live muzzle, CombatWorld.muzzle_of); the end stays put. Small length changes
## stretch the built meshes; a big one rebuilds them.
##
## LOOK keys (all optional): core (Color), shell (Color, default = core lightened), sides (int), w0 / w1 (shell width, m,
## at the start / at w_full m), w_full (m), core_share (core width / shell width), has_shell (bool), pulse (share of
## width), pulse_hz, spin (deg/s of the shell), flash (bool: a faceted flash at the muzzle end).

const SECTIONS := 6               ## rings along the beam (follows the width curve)
const POP := 0.06                 ## s: the beam shrinks to nothing over its last POP s (no fade)

var look: Dictionary = {}
var a := Vector3.ZERO
var b := Vector3.FORWARD
var life := 0.3                   ## s shown; < 0 = until removed
var age := 0.0
var follow: Callable              ## optional: () -> Vector3, the start point now (a live muzzle)
var _len := 0.0
var _core: MeshInstance3D
var _shell: MeshInstance3D
var _flash: MeshInstance3D


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({"look": Net.SPAWN, "a": Net.SPAWN, "b": Net.SPAWN, "life": Net.SPAWN, "age": Net.LOCAL, "follow": Net.LOCAL, "_len": Net.LOCAL,
		"_core": Net.LOCAL, "_shell": Net.LOCAL, "_flash": Net.LOCAL})
	return f


## A beam with no fire record (a designator, a lab preview): starts now.
func setup_cosmetic(w: CombatWorld, from: Vector3, to: Vector3, seconds: float) -> void:
	world = w
	t0 = w.now
	life = seconds
	set_points(from, to)


## Move the beam (rebuilds the meshes when its length changes).
func set_points(from: Vector3, to: Vector3) -> void:
	a = from
	b = to
	var l := a.distance_to(b)
	if _core == null or absf(l - _len) > maxf(0.01, 0.04 * _len):
		_len = l
		_build()
	var stretch := l / _len if _len > 1e-4 else 1.0
	transform = Transform3D(Combat.look_basis(b - a if l > 1e-4 else Vector3.FORWARD) * Basis.from_scale(Vector3(1, 1, stretch)), a)
	_update_look()


func shell_width(d: float) -> float:
	var w0 := float(look.get("w0", 0.15))
	var w1 := float(look.get("w1", w0))
	return lerpf(w0, w1, clampf(d / maxf(float(look.get("w_full", 150.0)), 0.01), 0.0, 1.0))


func core_color() -> Color:
	return look.get("core", MechMeshes.TEAL)


func shell_color() -> Color:
	return look.get("shell", core_color().lerp(MechMeshes.WHITE, 0.55))


func _build() -> void:
	for n: Node in [_core, _shell, _flash]:
		if n != null:
			remove_child(n)
			n.queue_free()
	var sides := maxi(int(look.get("sides", 6)), 3)
	var share := float(look.get("core_share", 0.45))
	var core := core_color()
	var k := MeshKit.new()
	k.glow = true
	k.shade = 0.0
	var rings: Array = []
	for i in SECTIONS + 1:
		var d := _len * float(i) / float(SECTIONS)
		var r := shell_width(d) * share * 0.5
		rings.append(MeshKit.ring_uv(Vector3(0, 0, -d), Vector3(r, 0, 0), Vector3(0, r, 0), sides))
	# Flat per-facet shades (unlit, so the facets read by colour, not by light).
	k.loft(rings, func(_c: Vector3, n: Vector3) -> Color: return core.lightened(0.18 * (n.y * 0.5 + 0.5)), true, true)
	_core = CombatMeshes.instance(k.commit(MechMeshes.materials()))
	add_child(_core)
	if bool(look.get("has_shell", true)):
		var ks := MeshKit.new()
		ks.glow = true
		ks.shade = 0.0
		var pale := shell_color()
		var srings: Array = []
		for i in SECTIONS + 1:
			var d := _len * float(i) / float(SECTIONS)
			var r := shell_width(d) * 0.5
			srings.append(MeshKit.ring_uv(Vector3(0, 0, -d), Vector3(r, 0, 0), Vector3(0, r, 0), sides, 2.0, 0.0))
		for i in SECTIONS:
			var c := Vector3(0, 0, -_len * (float(i) + 0.5) / float(SECTIONS))
			var ra: PackedVector3Array = srings[i]
			var rb: PackedVector3Array = srings[i + 1]
			for s in sides:
				if s % 2 == 1:
					continue        # alternate facets only: the core shows through the gaps
				var s2 := (s + 1) % sides
				ks.quad(ra[s], rb[s], rb[s2], ra[s2], pale if s % 4 == 0 else pale.darkened(0.1), c)
		_shell = CombatMeshes.instance(ks.commit(MechMeshes.materials()))
		add_child(_shell)
	if bool(look.get("flash", true)):
		_flash = CombatMeshes.instance(CombatMeshes.ico(core.lerp(MechMeshes.WHITE, 0.35), true))
		add_child(_flash)


func advance_to(now: float) -> void:
	age = now - t0
	if follow.is_valid() and not finished() and age >= 0.0:
		var p: Variant = follow.call()
		if p is Vector3 and (p as Vector3).distance_squared_to(a) > 1e-8:
			set_points(p, b)
			return
	_update_look()


func finished() -> bool:
	return life >= 0.0 and age >= life


## Width factor of the whole beam at its age: 1, then down to 0 over the last POP s.
func width_factor() -> float:
	if life < 0.0 or age < 0.0:
		return 1.0 if age >= 0.0 else 0.0
	return clampf((life - age) / POP, 0.0, 1.0)


func _update_look() -> void:
	if _core == null:
		return
	var k := maxf(width_factor(), 0.0001)
	var on := age >= 0.0 and not finished()
	_core.visible = on
	_core.scale = Vector3(k, k, 1.0)
	if _shell != null:
		var hz := float(look.get("pulse_hz", 11.0))
		var pulse := 1.0 + float(look.get("pulse", 0.22)) * sin(TAU * hz * maxf(age, 0.0))
		_shell.visible = on
		_shell.transform = Transform3D(Basis(Vector3.FORWARD, deg_to_rad(float(look.get("spin", 90.0))) * age)
			* Basis.from_scale(Vector3(k * pulse, k * pulse, 1.0)), Vector3.ZERO)
	if _flash != null:
		_flash.visible = on
		_flash.scale = Vector3.ONE * shell_width(0.0) * 1.6 * k
