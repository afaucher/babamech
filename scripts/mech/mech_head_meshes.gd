class_name MechHeadMeshes
extends RefCounted
## The five pilot heads (art/picks/head_*.png): true low poly (about 150 faces each), one flat colour per face, stern
## (heavy angled brows, narrowed eyes, mouth closed). Origin at the neck base, facing -Z, about 1.2 tall; only the head
## and neck stick out of the hatch. Built with MeshKit, saved by MechMeshes as head_<id>.res.

const EYE_WHITE := Color(0.95, 0.94, 0.9)
const PUPIL := Color(0.08, 0.06, 0.05)
## How much wider than authored each head is drawn (X and Z).
const GIRTH := {"chicken": 1.3, "pickle": 1.12, "corn": 1.12, "dog": 1.25, "duck": 1.2}
## The duck (art/picks/head_duck.png, a mallard drake), shared with its rig (PilotHeadDuck) so both keep one silhouette.
## Neck-and-skull sections [y, centre z, half width, half depth]: brown chest band, white neck ring, green above.
const DUCK_SECS := [[0.0, 0.07, 0.3, 0.32], [0.12, 0.05, 0.25, 0.26], [0.18, 0.045, 0.235, 0.245],
	[0.44, 0.04, 0.215, 0.235], [0.72, -0.03, 0.3, 0.35], [0.95, -0.03, 0.3, 0.34], [1.14, 0.0, 0.19, 0.23]]
const DUCK_GREEN := Color(0.17, 0.36, 0.22)
const DUCK_GREEN_LIGHT := Color(0.25, 0.47, 0.3)
const DUCK_BROWN := Color(0.45, 0.27, 0.16)
const DUCK_RING := Color(0.92, 0.9, 0.86)
const DUCK_BILL := Color(0.93, 0.74, 0.22)
const DUCK_BROW := Color(0.11, 0.22, 0.14)
const DUCK_NOSTRIL := Color(0.22, 0.15, 0.06)
## The duck's stern eye: right eye position and the way the face points there.
const DUCK_EYE := Vector3(0.18, 0.87, -0.272)
const DUCK_EYE_OUT := Vector3(0.5, 0.08, -0.86)
## Upper bill [root, tip, root half width / height, tip half width / height]; lower bill the same.
const DUCK_BILL_UP := [Vector3(0, 0.765, -0.22), Vector3(0, 0.66, -0.76), Vector2(0.15, 0.09), Vector2(0.115, 0.038)]
const DUCK_BILL_LOW := [Vector3(0, 0.69, -0.24), Vector3(0, 0.64, -0.7), Vector2(0.12, 0.04), Vector2(0.09, 0.022)]
## Crest tuft at the back of the crown: three shards [root, tip], fanning from upright to swept back.
const DUCK_CREST := [[Vector3(0, 1.08, 0.02), Vector3(0, 1.37, 0.16)], [Vector3(0.05, 1.02, 0.13), Vector3(0.07, 1.28, 0.4)],
	[Vector3(-0.04, 0.95, 0.2), Vector3(-0.06, 1.1, 0.5)]]


static func build(k: MeshKit, id: String) -> void:
	var g := float(GIRTH.get(id, 1.0))
	k.push(MeshKit.xf(Vector3.ZERO, Vector3.ZERO, Vector3(g, 1, g)))
	match id:
		"pickle": _pickle(k)
		"corn": _corn(k)
		"dog": _dog(k)
		"duck": _duck(k)
		_: _chicken(k)
	k.pop()


## Skin a neck-and-skull from sections [y, centre z, half width, half depth] (8 sides, open at the neck base).
static func _skull(k: MeshKit, secs: Array, col: Variant, power: float = 2.2) -> void:
	var rings: Array = []
	for s: Array in secs:
		rings.append(MeshKit.ring(Vector3(0, s[0], s[1]), s[2], s[3], 8, "y", power))
	k.loft(rings, col, false, true)


## The stern look: a brow wedge over each eye, low at the nose and high at the temple, and a narrowed eye under it.
## `at` is the right eye on the face, `out` the way the face points there (both mirrored for the left). `eye` is the
## colour of the eyeball (null = a bird's all-dark eye).
static func _stern_eyes(k: MeshKit, at: Vector3, out: Vector3, brow: Color, eye: Variant, size: float = 1.0) -> void:
	for side: float in [-1.0, 1.0]:
		var m := Vector3(side, 1, 1)
		var p := at * m
		var o := (out * m).normalized()
		var across := Vector3.UP.cross(o).normalized() * side   # toward the temple
		var up := o.cross(across).normalized() * side
		var pr := 0.04
		if eye != null:
			k.poly(MeshKit.ring_uv(p + o * 0.03, across * 0.085 * size, up * 0.055 * size, 4, 2.0, 0.0), eye, p - o)
		else:
			pr = 0.062
		k.poly(MeshKit.ring_uv(p + o * 0.045 - across * 0.012 * size, across * pr * size, up * pr * size, 4, 2.0, 0.0), PUPIL, p - o)
		var inner := p - across * 0.11 * size + Vector3(0, 0.03, 0) * size + o * 0.07
		var outer := p + across * 0.14 * size + Vector3(0, 0.13, 0) * size + o * 0.02
		k.seg(inner, outer, Vector2(0.05, 0.055) * size, Vector2(0.035, 0.04) * size, 3, brow)


static func _chicken(k: MeshKit) -> void:
	var white := Color(0.93, 0.9, 0.83)
	var red := Color(0.78, 0.17, 0.14)
	var beak := Color(0.95, 0.69, 0.14)
	_skull(k, [[0.0, 0.06, 0.3, 0.31], [0.3, 0.05, 0.24, 0.26], [0.55, 0.0, 0.27, 0.3], [0.76, -0.03, 0.31, 0.35],
		[0.96, -0.02, 0.29, 0.32], [1.1, 0.02, 0.19, 0.21]], white)
	# Beak: upper and lower.
	k.seg(Vector3(0, 0.8, -0.28), Vector3(0, 0.69, -0.68), Vector2(0.13, 0.095), Vector2.ZERO, 4, beak, 2.0, false, 0.0)
	k.seg(Vector3(0, 0.71, -0.28), Vector3(0, 0.66, -0.55), Vector2(0.09, 0.05), Vector2.ZERO, 4, beak.darkened(0.2), 2.0, false, 0.0)
	# Comb: four red spikes along the crown.
	for s: Array in [[-0.2, 0.22, -0.1], [-0.07, 0.36, -0.05], [0.08, 0.38, 0.03], [0.21, 0.26, 0.1]]:
		k.seg(Vector3(0, 1.03, s[0]), Vector3(0, 1.08 + s[1], s[0] + s[2]), Vector2(0.06, 0.1), Vector2.ZERO, 4, red, 2.0, false, 0.0)
	# Wattles: two red drops under the beak (single watertight loft per wattle).
	for side: float in [-1.0, 1.0]:
		var top := Vector3(side * 0.05, 0.68, -0.31)
		var mid := Vector3(side * 0.08, 0.46, -0.35)
		var bot := Vector3(side * 0.08, 0.3, -0.33)
		k.loft([MeshKit.ring(top, 0.0, 0.0, 4, "y", 2.0, 0.0), MeshKit.ring(mid, 0.07, 0.07, 4, "y", 2.0, 0.0),
			MeshKit.ring(bot, 0.0, 0.0, 4, "y", 2.0, 0.0)], [red, red.darkened(0.12)], false, false)
	_stern_eyes(k, Vector3(0.2, 0.86, -0.275), Vector3(0.6, 0.05, -0.8), white.darkened(0.1), null, 1.1)


static func pickle_colour(_c: Vector3, n: Vector3) -> Color:
	var a := int(floor((atan2(n.x, n.z) + PI) / (TAU / 8.0) + 0.5))
	return Color(0.4, 0.55, 0.2) if a % 2 == 0 else Color(0.33, 0.48, 0.16)


static func _pickle(k: MeshKit) -> void:
	var green := Color(0.4, 0.55, 0.2)
	_skull(k, [[0.0, 0.0, 0.27, 0.27], [0.16, 0.0, 0.33, 0.33], [0.5, 0.0, 0.35, 0.35], [0.85, 0.0, 0.35, 0.35],
		[1.1, 0.0, 0.3, 0.3], [1.24, 0.0, 0.17, 0.17]], pickle_colour, 2.0)
	_stern_eyes(k, Vector3(0.14, 0.7, -0.325), Vector3(0.3, 0.0, -0.95), green.lightened(0.12), EYE_WHITE, 1.2)
	# Nose, a closed mouth, warts.
	k.seg(Vector3(0, 0.66, -0.33), Vector3(0, 0.56, -0.45), Vector2(0.03, 0.03), Vector2(0.07, 0.05), 4, green.lightened(0.08), 2.0, true, 0.0)
	k.seg(Vector3(-0.13, 0.4, -0.335), Vector3(0.13, 0.4, -0.335), Vector2(0.02, 0.03), Vector2(0.02, 0.03), 3, green.darkened(0.45))
	for w: Array in [[0.33, 0.95, -0.12], [-0.34, 0.6, 0.05], [0.3, 0.3, -0.16], [-0.26, 1.02, -0.2]]:
		var p := Vector3(w[0], w[1], w[2])
		k.seg(p, p + Vector3(w[0], 0, w[2]).normalized() * 0.08, Vector2(0.05, 0.05), Vector2.ZERO, 3, green.lightened(0.1), 2.0, false)


static func corn_colour(c: Vector3, n: Vector3) -> Color:
	var a := int(floor((atan2(n.x, n.z) + PI) / (TAU / 8.0) + 0.5))
	var band := int(floor(c.y / 0.14))
	return Color(0.97, 0.8, 0.25) if (a + band) % 2 == 0 else Color(0.9, 0.7, 0.18)


static func _corn(k: MeshKit) -> void:
	var yellow := Color(0.97, 0.8, 0.25)
	var husk := Color(0.36, 0.56, 0.2)
	_skull(k, [[0.0, 0.0, 0.2, 0.2], [0.2, 0.0, 0.32, 0.32], [0.5, 0.0, 0.34, 0.34], [0.82, 0.0, 0.31, 0.31],
		[1.08, 0.0, 0.23, 0.23], [1.26, 0.0, 0.11, 0.11]], corn_colour, 2.0)
	# Husk leaves around the base (none across the face): a creased blade each, outside and inside.
	for i in 5:
		var a := TAU * (float(i) + 1.0) / 6.0
		var d := Vector3(sin(a), 0, -cos(a))
		var side := Vector3(d.z, 0, -d.x)
		var base := d * 0.24
		var mid := d * 0.46 + Vector3(0, 0.36, 0)
		var tip := d * 0.6 + Vector3(0, 0.8, 0)
		var core := Vector3(0, 0.4, 0)
		for sgn: float in [-1.0, 1.0]:
			var edge := d * 0.36 + side * 0.22 * sgn + Vector3(0, 0.34, 0)
			k.tri(base, edge, mid, husk, core)
			k.tri(edge, tip, mid, husk.darkened(0.12), core)
			k.tri(base, edge, tip, husk.darkened(0.3), core + d * 2.0)
	_stern_eyes(k, Vector3(0.13, 0.66, -0.32), Vector3(0.3, 0.0, -0.95), husk, EYE_WHITE, 1.15)
	k.seg(Vector3(0, 0.62, -0.33), Vector3(0, 0.52, -0.44), Vector2(0.03, 0.03), Vector2(0.07, 0.05), 4, yellow.darkened(0.08), 2.0, true, 0.0)
	k.seg(Vector3(-0.12, 0.38, -0.33), Vector3(0.12, 0.38, -0.33), Vector2(0.02, 0.03), Vector2(0.02, 0.03), 3, yellow.darkened(0.5))


static func _dog(k: MeshKit) -> void:
	var fur := Color(0.72, 0.45, 0.2)
	_skull(k, [[0.0, 0.08, 0.28, 0.29], [0.3, 0.06, 0.26, 0.28], [0.52, 0.0, 0.34, 0.36], [0.76, -0.01, 0.37, 0.38],
		[0.97, 0.0, 0.32, 0.33], [1.08, 0.02, 0.2, 0.22]], fur)
	# Snout, nose, the set jaw.
	k.loft([MeshKit.ring(Vector3(0, 0.64, -0.28), 0.19, 0.15, 6, "z", 2.6), MeshKit.ring(Vector3(0, 0.6, -0.66), 0.14, 0.11, 6, "z", 2.6)],
		fur.lightened(0.08), false, true)
	k.seg(Vector3(0, 0.68, -0.62), Vector3(0, 0.65, -0.73), Vector2(0.08, 0.06), Vector2(0.05, 0.035), 4, Color(0.09, 0.08, 0.08), MeshKit.SQUARE)
	k.seg(Vector3(0, 0.47, -0.3), Vector3(0, 0.47, -0.58), Vector2(0.13, 0.035), Vector2(0.1, 0.03), 4, fur.darkened(0.25), MeshKit.SQUARE)
	# Floppy ears.
	for side: float in [-1.0, 1.0]:
		var root := Vector3(side * 0.3, 1.0, 0.06)
		var bend := Vector3(side * 0.5, 0.84, 0.02)
		k.seg(root, bend, Vector2(0.05, 0.14), Vector2(0.04, 0.17), 4, fur.darkened(0.18), MeshKit.SQUARE)
		k.seg(bend, Vector3(side * 0.53, 0.46, -0.04), Vector2(0.04, 0.17), Vector2.ZERO, 4, fur.darkened(0.28), MeshKit.SQUARE, true)
	_stern_eyes(k, Vector3(0.17, 0.83, -0.325), Vector3(0.35, 0.05, -0.93), fur.darkened(0.1), EYE_WHITE, 1.15)


## Faceted mallard green: alternate light and dark facets around and up the head.
static func duck_green(c: Vector3, n: Vector3) -> Color:
	var a := int(floor((atan2(n.x, n.z) + PI) / (TAU / 8.0) + 0.5))
	var band := int(floor(c.y / 0.2))
	return DUCK_GREEN_LIGHT if (a + band) % 2 == 0 else DUCK_GREEN


## A duck bill half: a six-sided (upper) or four-sided (lower) section from root to a blunt, capped tip.
static func duck_bill(k: MeshKit, b: Array, sides: int, col: Color) -> void:
	var r0: Vector2 = b[2]
	var r1: Vector2 = b[3]
	k.loft([MeshKit.ring_uv(b[0], Vector3.RIGHT * r0.x, Vector3.UP * r0.y, sides, 2.0, 0.0),
		MeshKit.ring_uv(b[1], Vector3.RIGHT * r1.x, Vector3.UP * r1.y, sides, 2.0, 0.0)], col, false, true)


## The two nostrils on the upper bill's top faces.
static func duck_nostrils(k: MeshKit) -> void:
	for side: float in [-1.0, 1.0]:
		var c := Vector3(side * 0.05, 0.7965, -0.382)
		k.poly(MeshKit.ring_uv(c, Vector3(0, 0.0087, 0.03), Vector3(0.012, -0.0037 * side, 0), 4, 2.0, 0.0), DUCK_NOSTRIL,
			c + Vector3.DOWN)


## One crest shard: a three-sided blade, thin across X, tapering to a point.
static func duck_shard(k: MeshKit, root: Vector3, tip: Vector3, col: Color) -> void:
	k.seg(root, tip, Vector2(0.03, 0.07), Vector2.ZERO, 3, col, 2.0, false, 0.0)


static func _duck(k: MeshKit) -> void:
	var rings: Array = []
	for s: Array in DUCK_SECS:
		rings.append(MeshKit.ring(Vector3(0, s[0], s[1]), s[2], s[3], 8, "y", 2.2))
	k.loft(rings, [DUCK_BROWN, DUCK_RING, duck_green], false, true)
	duck_bill(k, DUCK_BILL_UP, 6, DUCK_BILL)
	duck_bill(k, DUCK_BILL_LOW, 4, DUCK_BILL.darkened(0.18))
	duck_nostrils(k)
	for c: Array in DUCK_CREST:
		duck_shard(k, c[0], c[1], DUCK_GREEN.darkened(0.15))
	_stern_eyes(k, DUCK_EYE, DUCK_EYE_OUT, DUCK_BROW, EYE_WHITE, 1.1)
