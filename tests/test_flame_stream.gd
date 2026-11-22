extends TestCase
## LowPolyFlame.Stream (thrusters and the flamer): off it shows nothing; switched on it lights up from the nozzle
## outward; tongues fly along -Y within the reach, grow then shrink, drift a little sideways; the same seed gives the same
## flame (deterministic jitter); switched off, the tongues in flight finish and it goes dark. The material keeps the
## palette colours (sRGB vertex colours, no fog).

const DT := 1.0 / 60.0


func setup() -> void:
	var mat := LowPolyFlame.material()
	check(mat.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED, "flame material is unshaded")
	check(mat.vertex_color_is_srgb, "flame vertex colours are read as sRGB (else OUTER renders pale)")
	check(mat.disable_fog, "flame material ignores fog")
	var a := _make(7)
	var b := _make(7)
	var c := _make(8)
	for i in 30:
		_step([a, b, c])
	check(not a.active(), "off: no tongues")
	for st: LowPolyFlame.Stream in [a, b, c]:
		st.emitting = true
	# Lighting up: after a short burst, the live tongues are all near the nozzle.
	for i in 6:
		_step([a, b, c])
	var live := _live(a)
	check(live.size() > 0, "on: tongues appear")
	for mi: MeshInstance3D in live:
		check(mi.position.y > -a.length * 0.5, "lights up from the nozzle (tongue at %.2f)" % mi.position.y)
	# Running: tongues spread over the reach, stay along -Y, the middle ones bigger than the ends.
	var reach := 0.0
	var sizes := {}
	for i in 120:
		_step([a, b, c])
		for mi: MeshInstance3D in _live(a):
			var p := mi.position
			check(p.y <= a.width and p.y >= -a.length - a.width, "tongue within the reach (y %.2f)" % p.y)
			check(Vector2(p.x, p.z).length() < a.length * a.spread + a.width, "tongue near the axis (%s)" % p)
			reach = minf(reach, p.y)
			var band := clampi(int(-p.y / a.length * 3.0), 0, 2)
			sizes[band] = maxf(float(sizes.get(band, 0.0)), mi.basis.get_scale().x)
	check(reach < -a.length * 0.8, "tongues travel the whole reach (%.2f of %.2f)" % [reach, a.length])
	check(float(sizes.get(1, 0.0)) > float(sizes.get(2, 0.0)), "tongues shrink toward the end (%s)" % sizes)
	check(_live(a).size() >= 6, "a full stream has most tongues alive (%d)" % _live(a).size())
	# Deterministic: same seed, same flame; another seed differs.
	var same := true
	var differs := false
	for i in a.get_child_count():
		var ma := a.get_child(i) as Node3D
		same = same and ma.transform.is_equal_approx((b.get_child(i) as Node3D).transform)
		differs = differs or not ma.transform.is_equal_approx((c.get_child(i) as Node3D).transform)
	check(same, "same seed, same flame")
	check(differs, "another seed, another flame")
	# Cut off: the flame finishes its flight and goes dark (lifetime = length / speed).
	a.emitting = false
	for i in int(ceil(a.length / a.speed / DT)) + 2:
		a.advance(DT)
	check(not a.active(), "off again: dark once the tongues in flight are done")
	for st in [a, b, c]:
		st.queue_free()
	_cap()
	_colors()
	await frames(1)
	finish()


## max_length: unset (INF), every tongue sits exactly where the uncapped formula puts it; set, nothing shows past the cap
## and the tongues near it are squashed / shrinking (the splat).
func _cap() -> void:
	var uncap := _make(11)
	var big := _make(11)
	big.max_length = 1000.0
	var capped := _make(11)
	capped.max_length = 3.0
	for st: LowPolyFlame.Stream in [uncap, big, capped]:
		st.emitting = true
	check(is_inf(uncap.max_length), "max_length is off (INF) by default")
	var exact := true
	var same := true
	var past := 0.0
	var near_cap: Array = []
	var mid: Array = []
	for i in 150:
		_step([uncap, big, capped])
		for k in uncap._tongues.size():
			var t: Dictionary = uncap._tongues[k]
			var mi: MeshInstance3D = t["mi"]
			if mi.visible:
				exact = exact and mi.transform.is_equal_approx(_uncapped(uncap, t))
			same = same and mi.transform.is_equal_approx((big._tongues[k]["mi"] as MeshInstance3D).transform)
		if i < 60:
			continue
		for mi: MeshInstance3D in _live(capped):
			var tip := mi.transform * Vector3(0, -1.0, 0)
			past = maxf(past, -tip.y - capped.max_length)
			var scale := mi.basis.get_scale()
			if -mi.position.y > capped.max_length - 0.6:
				near_cap.append(scale.y / scale.x)
			elif -mi.position.y < capped.max_length - 2.5:
				mid.append(scale.y / scale.x)
	check(exact, "unset: every tongue is posed exactly as before (uncapped formula)")
	check(same, "a cap beyond the reach changes nothing")
	check(past < 0.25, "capped at %.1f m: no tongue shows past the cap (worst %.2f m over)" % [capped.max_length, past])
	check(near_cap.size() > 0 and mid.size() > 0, "tongues both near the cap and before it (%d / %d)" % [near_cap.size(), mid.size()])
	var squash := 0.0
	for r: float in near_cap:
		squash += r / maxf(near_cap.size(), 1)
	var normal := 0.0
	for r: float in mid:
		normal += r / maxf(mid.size(), 1)
	check(squash < normal * 0.8, "tongues at the cap are squashed / shrinking (h/w %.2f vs %.2f before it)" % [squash, normal])
	var far := 0
	for mi: MeshInstance3D in _live(uncap):
		if -mi.position.y > capped.max_length + 0.5:
			far += 1
	check(far > 0, "the uncapped twin does reach past 3 m (%d tongues)" % far)
	for st in [uncap, big, capped]:
		st.queue_free()


## Colour jitter: 0 = the old flat bands (centre meshes, band by position exactly as before); the default mottles the
## stream with several variants, the same for the same seed; every variant stays close to its centre colour.
func _colors() -> void:
	for band in [LowPolyFlame.HOT, LowPolyFlame.WARM, LowPolyFlame.COOL]:
		check(LowPolyFlame.tongue(band, 0) == LowPolyFlame.tongue(band), "variant 0 is the centre tongue (band %d)" % band)
	var worst := 0.0
	for c: Color in [LowPolyFlame.OUTER, LowPolyFlame.MID, LowPolyFlame.CORE]:
		for v in LowPolyFlame.VARIANTS:
			var cv := LowPolyFlame.variant_color(c, v)
			worst = maxf(worst, Vector3(cv.r - c.r, cv.g - c.g, cv.b - c.b).length())
			check(cv.r >= 0.85 and cv.r >= cv.g - 0.06 and cv.g >= cv.b, "variant %d of %s is still a flame colour (%s)" % [v, c, cv])
	check(worst < 0.25, "every variant stays near its centre colour (worst %.3f)" % worst)
	var flat := _make(21)
	flat.color_jitter = 0.0
	var a := _make(21)
	var b := _make(21)
	check(a.color_jitter > 0.0, "colour jitter is on by default (%.2f)" % a.color_jitter)
	for st: LowPolyFlame.Stream in [flat, a, b]:
		st.emitting = true
	var old := true
	var same := true
	var kinds := {}
	for i in 150:
		_step([flat, a, b])
		for k in flat._tongues.size():
			var t: Dictionary = flat._tongues[k]
			var mi: MeshInstance3D = t["mi"]
			if mi.visible:
				var p := float(t["p"])
				var band := LowPolyFlame.HOT if p < 0.3 else (LowPolyFlame.WARM if p < 0.65 else LowPolyFlame.COOL)
				old = old and mi.mesh == LowPolyFlame.tongue(band)
			var ma: MeshInstance3D = a._tongues[k]["mi"]
			same = same and ma.mesh == (b._tongues[k]["mi"] as MeshInstance3D).mesh
			if ma.visible:
				kinds[ma.mesh] = true
	check(old, "jitter 0: every tongue has today's band colour")
	check(same, "same seed, same colours")
	check(kinds.size() > 6, "default jitter mottles the stream (%d distinct tongue colourings)" % kinds.size())
	for st in [flat, a, b]:
		st.queue_free()


## The tongue's transform by the pre-cap formula (LowPolyFlame.Stream._pose as it was before max_length).
func _uncapped(st: LowPolyFlame.Stream, t: Dictionary) -> Transform3D:
	var p := float(t["p"])
	var j: Array = t["j"]
	var g := sin(PI * pow(p, 0.55)) * (0.8 + 0.4 * float(j[0]))
	g = maxf(g, 0.12) * st.width
	var a := TAU * float(j[1])
	var drift := Vector3(cos(a), 0.0, sin(a)) * st.spread * st.length * p * (0.4 + 0.6 * float(j[2]))
	var spin := TAU * float(j[3]) + p * (float(j[4]) - 0.5) * 6.0
	var tip := (float(j[5]) - 0.5) * 2.0 * st.tumble * (0.3 + p)
	var b := Basis(Vector3.UP, spin) * Basis(Vector3.RIGHT, tip)
	var at := Vector3(0.0, -p * st.length, 0.0) + drift
	return Transform3D(b.scaled_local(Vector3(g, g * 1.4, g)), at + b * Vector3(0.0, 0.35 * g * 1.4, 0.0))


func _make(s: int) -> LowPolyFlame.Stream:
	var st := LowPolyFlame.Stream.new()
	st.manual = true
	st.length = 6.0
	st.width = 1.5
	st.speed = 15.0
	st.spread = 0.1
	st.root = 0.5
	st.jitter_seed = s
	add_child(st)
	return st


func _step(streams: Array) -> void:
	for st: LowPolyFlame.Stream in streams:
		st.advance(DT)


func _live(st: LowPolyFlame.Stream) -> Array:
	var out: Array = []
	for n in st.get_children():
		var mi := n as MeshInstance3D
		if mi != null and mi.visible and mi.mesh != LowPolyFlame.jet():
			out.append(mi)
	return out
