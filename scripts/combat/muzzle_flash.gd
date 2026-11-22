class_name MuzzleFlash
extends CombatEffect
## A projectile weapon's muzzle flash (weapons.md §4.3, cosmetic): a faceted flame star at the muzzle, pointing along
## the shot: a 5-sided cone of the flame MID colour around a CORE cone, with four short OUTER petals around it. It shows
## for LIFE s in three hard steps (full, then smaller and turned, then smallest: about three frames at 60 fps), no fade.
## LowPolyFlame colours on its unshaded material. CombatWorld.fire spawns one for every Projectile it starts on time
## (a shot fast-forwarded past LIFE gets none). Nothing here is gameplay state.

const LIFE := 0.06
const STEPS := 3

static var _mesh: ArrayMesh

var at := Vector3.ZERO
var dir := Vector3.FORWARD
var size := 1.0                ## m: length of the flash at its first step
var age := 0.0
var _mi: MeshInstance3D


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({"at": Net.LOCAL, "dir": Net.LOCAL, "size": Net.LOCAL, "age": Net.LOCAL, "_mi": Net.LOCAL})
	return f


## Flash length (m) for a weapon's stats: tied to its drawn launch size.
static func size_for(st: Dictionary) -> float:
	return clampf(float(st.get("size", 0.4)) * 3.0, 0.8, 2.6)


## The star, 1 m long along -Z from the origin.
static func mesh() -> ArrayMesh:
	if _mesh == null:
		var k := MeshKit.new()
		k.glow = true
		k.shade = 0.08
		k.seg(Vector3.ZERO, Vector3(0, 0, -1.0), Vector2(0.32, 0.32), Vector2(0.02, 0.02), LowPolyFlame.SIDES, LowPolyFlame.MID)
		k.seg(Vector3(0, 0, 0.05), Vector3(0, 0, -0.62), Vector2(0.2, 0.2), Vector2(0.01, 0.01), LowPolyFlame.SIDES, LowPolyFlame.CORE)
		for i in 4:
			var a := TAU * float(i) / 4.0 + PI * 0.25
			var out := Vector3(cos(a), sin(a), -0.35).normalized() * 0.55
			k.seg(Vector3(0, 0, -0.08), Vector3(0, 0, -0.08) + out, Vector2(0.09, 0.09), Vector2(0.01, 0.01), 4, LowPolyFlame.OUTER)
		_mesh = k.commit([LowPolyFlame.material(), LowPolyFlame.material()])
	return _mesh


func setup(w: CombatWorld, p: Vector3, d: Vector3, length: float, t_start: float) -> void:
	world = w
	t0 = t_start
	at = p
	dir = d.normalized() if d.length_squared() > 1e-8 else Vector3.FORWARD
	size = length
	_mi = CombatMeshes.instance(mesh())
	_mi.top_level = true
	add_child(_mi)
	advance_to(w.now)


## 0, 1, 2 while showing, -1 before / after.
func step_index() -> int:
	if age < 0.0 or age >= LIFE:
		return -1
	return mini(int(age / (LIFE / float(STEPS))), STEPS - 1)


func advance_to(now: float) -> void:
	age = now - t0
	if _mi == null or not is_inside_tree():
		return
	var s := step_index()
	_mi.visible = s >= 0
	if s < 0:
		return
	var k: float = [1.0, 0.72, 0.45][s]
	var roll := Basis(Vector3.BACK, deg_to_rad(36.0 * float(s)))
	_mi.global_transform = Transform3D(Combat.look_basis(dir) * roll * Basis.from_scale(Vector3(k, k, k) * size), at)


func finished() -> bool:
	return age >= LIFE
