extends TestCase
## Pilot heads (docs/design/pilot-heads.md): every registered head builds with all standard pieces inside the face budget
## and at the static head's size; every mood and reaction exists for every head and moves a piece; reactions decay back
## to the mood; react_hit flinches away then looks toward the source; the same seed gives the same pose stream and
## different seeds differ in idle; the neck stays bounded under abuse; feed picks the mood by priority, detects landings
## and never advances twice in one frame; set_inputs merges sticky state into every feed (feed keys win, effort ORs).

const DT := 1.0 / 60.0
## Seconds the springs get to settle after a reaction's envelope ends.
const SETTLE := 2.0


func setup() -> void:
	check(PilotHead.ids().size() >= 1, "at least one head is registered")
	for id: String in PilotHead.ids():
		_check_build(id)
		_check_moods(id)
		_check_reactions(id)
		_check_tics(id)
	_check_fallback()
	_check_hit_look()
	_check_determinism()
	_check_neck_bounded()
	_check_mood_priority()
	_check_landing()
	_check_fx()
	_check_sticky_inputs()
	await _check_no_double_advance()
	finish()


func _head(id: String, head_seed: int = 0, idle: bool = false) -> PilotHead:
	var h := PilotHead.make(id, head_seed)
	h.idle_enabled = idle
	add_child(h)
	h.set_process(false)
	return h


func _run(h: PilotHead, seconds: float) -> void:
	for i in roundi(seconds / DT):
		h.advance(DT)


func _snap(h: PilotHead) -> Dictionary:
	var out := {}
	for n: String in h.face.piece_names():
		out[n] = h.piece(n).transform
	return out


## The largest change of any piece between two snapshots (origin distance + basis column change).
func _diff(a: Dictionary, b: Dictionary) -> float:
	var worst := 0.0
	for n: String in a:
		var ta: Transform3D = a[n]
		var tb: Transform3D = b[n]
		var d := ta.origin.distance_to(tb.origin)
		for c in 3:
			d = maxf(d, ta.basis[c].distance_to(tb.basis[c]))
		worst = maxf(worst, d)
	return worst


func _ch_diff(a: Dictionary, b: Dictionary) -> float:
	var worst := 0.0
	for c: String in a:
		worst = maxf(worst, absf(float(a[c]) - float(b[c])))
	return worst


## The head's bounds in its own frame; `above_base` leaves out the collar plug under the neck base (the static heads
## have none).
func _bounds(h: PilotHead, above_base: bool = false) -> AABB:
	var inv := h.global_transform.affine_inverse()
	var box := AABB()
	var first := true
	for mi in h.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		var b := (inv * m.global_transform) * m.get_aabb()
		box = b if first else box.merge(b)
		first = false
	if above_base and box.position.y < 0.0:
		box.size.y += box.position.y
		box.position.y = 0.0
	return box


func _check_build(id: String) -> void:
	var h := _head(id)
	eq(h.head_id, id, "%s builds its own rig" % id)
	for n: String in PilotFace.STANDARD:
		check(h.piece(n) != null, "%s has piece %s" % [id, n])
	for n: String in h.face.flair_pieces:
		check(h.piece(n) != null, "%s has flair piece %s" % [id, n])
	# The budget is for the head itself; the neck seal's collar plug (PilotFace.add_neck_plug) comes on top.
	var faces := h.face_count() - PilotFace.PLUG_FACES
	check(faces >= 150 and faces <= 210, "%s is in the face budget 150-210 (%d + %d for the neck seal)"
		% [id, faces, PilotFace.PLUG_FACES])
	var full := _bounds(h)
	near(full.position.y, -PilotFace.PLUG_DEPTH, 0.005, "%s: only the collar plug reaches below the neck base (%s)" % [id, full])
	var bb := _bounds(h, true)
	check(bb.position.y > -0.01 and bb.end.y > 1.0, "%s stands on its neck base, top above 1.0 (%s)" % [id, bb])
	if id in MechMeshes.HEADS:   # the stern rest pose is the static head
		var sb := MechMeshes.build("head_" + id).get_aabb()
		check(bb.position.distance_to(sb.position) < 0.1 and bb.end.distance_to(sb.end) < 0.1,
			"%s at rest matches the static head's bounds (%s vs %s)" % [id, bb, sb])
	for c: String in PilotExpressions.CHANNEL_ORDER:
		check(h.channels().has(c), "%s has channel %s" % [id, c])
	h.queue_free()


func _check_moods(id: String) -> void:
	var h := _head(id)
	_run(h, 1.0)
	var stern := _snap(h)
	eq(h.mood(), "stern", "%s starts stern" % id)
	for m: String in PilotHead.moods():
		if m == "stern":
			continue
		var hm := _head(id)
		_run(hm, 1.0)
		hm.set_mood(m)
		_run(hm, 1.0)
		eq(hm.mood(), m, "%s takes mood %s" % [id, m])
		check(_diff(_snap(hm), stern) > 0.005, "%s mood %s moves a piece vs stern (%.4f)" % [id, m, _diff(_snap(hm), stern)])
		hm.clear_mood()
		_run(hm, 2.0)
		check(_diff(_snap(hm), stern) < 0.003, "%s mood %s fades back to stern (%.4f)" % [id, m, _diff(_snap(hm), stern)])
		hm.queue_free()
	h.queue_free()


func _check_reactions(id: String) -> void:
	for r: String in PilotHead.reactions():
		var h := _head(id)
		_run(h, 1.0)
		var base := _snap(h)
		var base_ch := h.channels()
		var d := PilotExpressions.reaction(r, h.face.overrides)
		h.react(r)
		check(h.reacting(r), "%s reaction %s starts" % [id, r])
		var peak := float(d["a"]) + float(d["h"]) * 0.5
		var moved := 0.0
		var t := 0.0
		while t < peak:
			h.advance(DT * 0.25)
			t += DT * 0.25
			moved = maxf(moved, _diff(_snap(h), base))
		check(moved > 0.005, "%s reaction %s moves a piece (%.4f)" % [id, r, moved])
		_run(h, PilotExpressions.duration(d) - peak + SETTLE)
		check(not h.reacting(r), "%s reaction %s ends" % [id, r])
		check(_diff(_snap(h), base) < 0.002, "%s reaction %s decays back to the mood pose (%.4f)" % [id, r, _diff(_snap(h), base)])
		check(_ch_diff(h.channels(), base_ch) < 0.001, "%s reaction %s decays back to the mood channels" % [id, r])
		h.queue_free()


func _check_tics(id: String) -> void:
	var h := _head(id, 3, true)
	h.idle_always = true
	for tic: String in h.tics():
		_run(h, 0.5)
		var base := _snap(h)
		check(h.play_tic(tic), "%s plays tic %s" % [id, tic])
		var moved := 0.0
		for i in 30:
			h.advance(DT)
			moved = maxf(moved, _diff(_snap(h), base))
		check(moved > 0.005, "%s tic %s moves a piece (%.4f)" % [id, tic, moved])
		_run(h, 2.0)
	check(not h.play_tic("no_such_tic"), "an unknown tic is refused")
	h.queue_free()


func _check_fallback() -> void:
	var h := PilotHead.make("no_such_head", 1)
	eq(h.head_id, PilotHead.FALLBACK, "an unknown head id falls back")
	eq(h.requested_id, "no_such_head", "and remembers what was asked")
	h.free()
	for id: String in MechCatalog.HEAD_ORDER:
		var hc := PilotHead.make(id)
		check(PilotHead.REGISTRY.has(hc.head_id), "catalog head %s builds a rig (%s)" % [id, hc.head_id])
		hc.free()


func _check_hit_look() -> void:
	var h := _head("chicken")
	_run(h, 1.0)
	h.react_hit(Vector3.LEFT, 0.2)   # shot from the head's left
	check(h.reacting("flinch") and h.reacting("pain"), "a big hit flinches and hurts")
	var away := 0.0
	for i in 6:   # 0.1 s
		h.advance(DT)
		away = minf(away, h.neck.total().y)
	check(away < -deg_to_rad(4.0), "the flinch turns the head away from the left (yaw %.1f deg)" % rad_to_deg(away))
	var toward := 0.0
	for i in 30:   # to 0.6 s
		h.advance(DT)
		toward = maxf(toward, h.neck.total().y)
	check(toward > deg_to_rad(20.0), "then it looks toward the source (yaw %.1f deg)" % rad_to_deg(toward))
	_run(h, 2.0)
	check(absf(h.neck.total().y) < deg_to_rad(2.0), "and comes back (yaw %.1f deg)" % rad_to_deg(h.neck.total().y))
	# A small hit flinches without pain; look_at_point turns the head within the limits.
	h.react_hit(Vector3.ZERO, 0.02)
	check(h.reacting("flinch") and not h.reacting("pain"), "a small hit only flinches")
	_run(h, 2.0)
	h.look_at_point(h.global_transform * Vector3(-10.0, 0.85, 0.0))
	_run(h, 1.5)
	near(h.neck.total().y, PilotNeck.YAW_LIMIT, deg_to_rad(3.0), "looking 90 degrees left holds at the yaw limit")
	check(h.channels()["gaze_x"] < -0.5, "and the eyes cover the rest (gaze_x %.2f)" % h.channels()["gaze_x"])
	h.clear_look()
	h.queue_free()


func _script_state(i: int) -> Dictionary:
	var t := float(i) * DT
	return {"vel": Vector3(sin(t * 1.3) * 4.0, (-8.0 if i % 120 > 100 else 0.0), -6.0 * float(i % 200 < 120)),
		"yaw_rate": sin(t * 0.7) * 1.5, "grounded": i % 120 <= 100, "heat": fmod(t * 0.1, 1.0),
		"hp": 1.0 if i < 400 else 0.2, "firing": i % 90 < 30, "effort": i % 150 < 20, "footfall": i % 25 == 0}


func _check_determinism() -> void:
	var a := _head("chicken", 7, true)
	var b := _head("chicken", 7, true)
	var same := true
	for i in 600:
		var s := _script_state(i)
		a.feed(DT, s)
		b.feed(DT, s)
		if i % 60 == 30:
			a.react_hit(Vector3(1, 0, -1), 0.1)
			b.react_hit(Vector3(1, 0, -1), 0.1)
		if a.channels() != b.channels() or _diff(_snap(a), _snap(b)) > 0.0:
			same = false
	check(same, "same seed + same inputs give identical channel and pose streams")
	a.queue_free()
	b.queue_free()
	var c := _head("chicken", 1, true)
	var d := _head("chicken", 2, true)
	var differ := false
	for i in 1800:
		c.advance(DT)
		d.advance(DT)
		if c.channels() != d.channels():
			differ = true
	check(differ, "different seeds differ in idle")
	c.queue_free()
	d.queue_free()


func _finite_pose(h: PilotHead) -> bool:
	for n: String in h.face.piece_names():
		var t := h.piece(n).transform
		if not (t.origin.is_finite() and t.basis.x.is_finite() and t.basis.y.is_finite() and t.basis.z.is_finite()):
			return false
	for c: String in h.channels():
		if not is_finite(float(h.channels()[c])):
			return false
	return true


func _within_limits(h: PilotHead) -> bool:
	var t := h.neck.total()
	var e := 1e-4
	return absf(t.x) <= PilotNeck.PITCH_LIMIT + e and absf(t.y) <= PilotNeck.YAW_LIMIT + e \
		and absf(t.z) <= PilotNeck.ROLL_LIMIT + e and absf(h.neck.flair.x) <= PilotNeck.FLAIR_LIMIT + e \
		and absf(h.neck.flair.y) <= PilotNeck.FLAIR_LIMIT + e


func _check_neck_bounded() -> void:
	var h := _head("chicken", 0, true)
	var ok := true
	var bounded := true
	var deltas := [DT, 1e-6, 10.0, 0.5, DT, 0.0, 3.0]
	for i in 200:
		var sgn := 1.0 if i % 2 == 0 else -1.0
		var v := Vector3(1e4, -1e4, 1e5) * sgn
		if i == 50:
			v = Vector3(NAN, 0, 0)
		if i == 51:
			v = Vector3(INF, -INF, 0)
		h.feed(float(deltas[i % deltas.size()]), {"vel": v, "yaw_rate": 1e3 * sgn, "grounded": i % 3 == 0,
			"heat": 0.95, "effort": true})
		if i % 10 == 0:
			h.react_hit(Vector3(sgn, 1, 0), 1.0)
			h.react("pain", 1.5)
		ok = ok and _finite_pose(h)
		bounded = bounded and _within_limits(h)
	check(ok, "the neck stays finite under extreme acceleration, yaw rate and deltas")
	check(bounded, "the neck stays within its angle limits")
	h.advance(INF)
	h.advance(NAN)
	check(_finite_pose(h), "a non-finite delta is ignored")
	h.queue_free()


func _check_mood_priority() -> void:
	var cases := [
		[{}, "stern"], [{"heat": 0.75}, "strained"], [{"heat": 0.95}, "overheated"], [{"hp": 0.1}, "afraid"],
		[{"disabled": true}, "dazed"], [{"shutdown": true}, "dazed"], [{"firing": true}, "focused"],
		[{"aiming": true}, "focused"], [{"heat": 0.95, "hp": 0.1}, "afraid"], [{"hp": 0.1, "shutdown": true}, "dazed"],
		[{"heat": 0.8, "firing": true}, "strained"],
	]
	var h := _head("chicken")
	for c: Array in cases:
		h.feed(DT, c[0])
		eq(h.mood(), c[1], "feed %s picks mood %s" % [c[0], c[1]])
	h.set_mood("smug_does_not_exist")
	h.set_mood("afraid")
	h.feed(DT, {"heat": 0.95})
	eq(h.mood(), "afraid", "set_mood overrides the fed mood")
	h.clear_mood()
	eq(h.mood(), "overheated", "clear_mood returns to the fed mood")
	h.queue_free()


func _check_landing() -> void:
	var h := _head("chicken")
	for i in 10:
		h.feed(DT, {"grounded": false, "vel": Vector3(0, -10.0, 0)})
	check(not h.reacting("impact"), "no impact while airborne")
	h.feed(DT, {"grounded": true, "vel": Vector3.ZERO})
	check(h.reacting("impact"), "landing at speed triggers impact")
	check(h.reacting("flinch"), "a hard landing adds a flinch")
	var g := _head("chicken")
	for i in 10:
		g.feed(DT, {"grounded": false, "vel": Vector3(0, -0.5, 0)})
	g.feed(DT, {"grounded": true})
	check(not g.reacting("impact"), "a soft step down is no impact")
	for i in 10:
		g.feed(DT, {"grounded": true})
	check(not g.reacting("impact"), "staying grounded is no landing")
	g.feed(DT, {"effort": true})
	g.feed(1.0, {"effort": true})
	check(g.reacting("effort"), "effort holds while fed")
	g.feed(DT, {})
	g.feed(1.0, {})
	check(not g.reacting("effort"), "and releases when it stops")
	h.queue_free()
	g.queue_free()


func _check_fx() -> void:
	var h := _head("chicken")
	var got := {}
	h.fx.connect(func(kind: String, s: float) -> void: got[kind] = s)
	for i in 240:
		h.feed(DT, {"heat": 0.95})
	check(got.has("steam") and got.has("sweat"), "overheated puffs steam and sweats (%s)" % got)
	h.react_hit(Vector3.RIGHT, 0.3)
	check(got.has("flash") and got.has("chips"), "a big hit flashes and throws chips")
	h.feed(DT, {"shutdown": true})
	check(got.get("stars", -1.0) == 1.0, "dazed starts the stars")
	h.feed(DT, {})
	check(got.get("stars", -1.0) == 0.0, "and stops them after")
	got.clear()
	h.fx_enabled = false
	h.react("pain")
	check(got.is_empty(), "fx_enabled false emits nothing")
	for k: String in got:
		check(k in PilotHead.FX_KINDS, "fx kind %s is listed" % k)
	h.queue_free()


func _check_no_double_advance() -> void:
	var h := PilotHead.make("chicken", 0)
	add_child(h)
	await get_tree().process_frame
	h.feed(DT, {})
	var t0 := h.elapsed()
	for i in 30:
		await get_tree().process_frame
		h.feed(DT, {})
	near(h.elapsed() - t0, 30.0 * DT, 1e-4, "a fed head advances once per frame (no double advance)")
	var t1 := h.elapsed()
	for i in 30:
		await get_tree().process_frame
	check(h.elapsed() - t1 > 20.0 * DT, "an unfed head idles on its own (%.3f s)" % (h.elapsed() - t1))
	h.time_scale = 0.0
	var t2 := h.elapsed()
	await get_tree().process_frame
	await get_tree().process_frame
	near(h.elapsed(), t2, 1e-6, "time_scale 0 freezes the idle")
	h.queue_free()


func _check_sticky_inputs() -> void:
	var h := _head("chicken")
	h.set_inputs({"heat": 0.95})
	h.feed(DT, {})
	eq(h.mood(), "overheated", "sticky heat reaches a feed that does not carry it")
	h.feed(DT, {"heat": 0.0})
	eq(h.mood(), "stern", "an explicit feed key wins over the sticky one")
	h.set_inputs({"hp": 0.1})
	h.feed(DT, {})
	eq(h.mood(), "afraid", "set_inputs calls accumulate (hp added, heat kept)")
	near(float(h.inputs()["heat"]), 0.95, 1e-6, "and earlier keys stay")
	h.clear_inputs()
	h.feed(DT, {})
	eq(h.mood(), "stern", "clear_inputs drops them")
	h.set_inputs({"effort": true})
	h.feed(DT, {"effort": false})
	check(h.reacting("effort"), "sticky effort ORs with the feed's effort")
	h.set_inputs({"effort": false})
	h.feed(DT, {"effort": true})
	check(bool(h._in["effort"]), "and the feed's effort still counts when the sticky one is off")
	h.clear_inputs()
	h.set_inputs({"vel": Vector3.ONE})
	check(not h.inputs().has("vel"), "set_inputs ignores keys outside EXTRA_KEYS")
	h.queue_free()
