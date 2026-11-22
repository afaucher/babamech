class_name BurnFx
extends Node3D
## Flames stuck on a hot target (weapons.md §3.9): while its heat is above ON_AT of its cap, a few LowPolyFlame.tongue()
## chunks (the one flame look) sit on its hit spheres, pointing up, flickering by rigid steps (every FLICKER s each
## tongue jumps to a new scale, lean and spin from LowPolyFlame.hash01: no smoothing, no randomness); below it they go.
## Cosmetic and LOCAL. Any CombatTarget can adopt it: `BurnFx.attach(target)` once, then `step(dt)` from its tick.

const ON_AT := 0.5             ## heat share above which it burns
const FLICKER := 0.07          ## s per rigid flicker step
const MAX_TONGUES := 4
const MIN_TONGUES := 2

var target: CombatTarget
var spots: Array = []          ## per tongue: {"at": Vector3 (target-local), "size": float}
var jitter_seed := 0
var _tongues: Array[MeshInstance3D] = []
var _t := 0.0
var _step := -1


func net_fields() -> Dictionary:
	return {"target": Net.LOCAL, "spots": Net.LOCAL, "jitter_seed": Net.LOCAL, "_tongues": Net.LOCAL, "_t": Net.LOCAL,
		"_step": Net.LOCAL}


## The target's BurnFx (made on first use, a child named "BurnFx").
static func attach(t: CombatTarget) -> BurnFx:
	var b := t.get_node_or_null("BurnFx") as BurnFx
	if b == null:
		b = BurnFx.new()
		b.name = "BurnFx"
		b.target = t
		b.jitter_seed = hash(t.target_id) & 0xFFFF
		t.add_child(b)
	return b


## Where the tongues sit: around the target's hit spheres (bigger spheres take bigger tongues), MIN..MAX of them.
func _place() -> void:
	spots.clear()
	var shapes: Array = target.hit_shapes if target != null else []
	if shapes.is_empty():
		shapes = [{"center": Vector3(0, 1, 0), "radius": 0.8}]
	var n := clampi(shapes.size() + 1, MIN_TONGUES, MAX_TONGUES)
	for i in n:
		var s: Dictionary = shapes[i % shapes.size()]
		var r := float(s["radius"])
		var a := TAU * (float(i) / float(n)) + TAU * LowPolyFlame.hash01(jitter_seed, i, 0, 7)
		var at: Vector3 = (s["center"] as Vector3) + Vector3(cos(a) * r * 0.55, r * 0.35, sin(a) * r * 0.55)
		spots.append({"at": at, "size": clampf(r * 0.95, 0.35, 1.3)})


func burning() -> bool:
	return target != null and target.heat.fraction() > ON_AT


## Visible stuck tongues.
func showing() -> int:
	var n := 0
	for mi in _tongues:
		if mi.visible:
			n += 1
	return n


func step(dt: float) -> void:
	_t += maxf(dt, 0.0)
	var on := burning()
	if on and _tongues.is_empty():
		_place()
		for i in spots.size():
			var mi := MeshInstance3D.new()
			mi.mesh = LowPolyFlame.tongue(LowPolyFlame.WARM if i % 2 == 0 else LowPolyFlame.HOT,
				int(LowPolyFlame.hash01(jitter_seed, i, 0, 9) * float(LowPolyFlame.VARIANTS)))   # mottled, like the streams
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mi)
			_tongues.append(mi)
		_step = -1
	for mi in _tongues:
		mi.visible = on
	if not on:
		return
	var k := int(floor(_t / FLICKER))
	if k == _step:
		return
	_step = k
	for i in _tongues.size():
		var sp: Dictionary = spots[i]
		var j0 := LowPolyFlame.hash01(jitter_seed, i, k, 0)
		var j1 := LowPolyFlame.hash01(jitter_seed, i, k, 1)
		var j2 := LowPolyFlame.hash01(jitter_seed, i, k, 2)
		var g := float(sp["size"]) * (0.7 + 0.55 * j0)
		# Tip up (the tongue points -Y), spun about the vertical, leaning a little.
		var b := Basis(Vector3.UP, TAU * j1) * Basis(Vector3.RIGHT, PI + (j2 - 0.5) * 0.5)
		_tongues[i].transform = Transform3D(b.scaled_local(Vector3(g, g * (1.1 + 0.4 * j2), g)),
			(sp["at"] as Vector3) + Vector3(0, 0.1 * j0, 0))
