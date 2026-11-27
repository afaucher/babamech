extends TestCase
## Draw quality (scripts/world/city/city_quality.gd, CityStack.set_quality, AmbientLife.set_quality; docs/design/
## city-ramps-and-stack.md section 8 "Quality levels"): presentation only. At LOW / MEDIUM / HIGH the stack's checksum,
## every deck's geometry_digest, props and collision shapes are identical (set before or after the build); LOW and MEDIUM
## hide the right decks and follow the active deck; HIGH after LOW restores every visibility flag, light, environment
## flag and range exactly; the life's states, poses, tallies and hit tests do not depend on its quality.

const SEED := 4
const T0 := 1000.0

var stack: CityStack


func setup() -> void:
	timeout_sec = 240.0
	stack = CityStack.new()
	add_child(stack)
	stack.build(SectionPlan.make({"seed": SEED}))
	_levels()
	_same_game()
	await _decks_follow()
	_restore()
	_life()
	finish()


func _levels() -> void:
	eq(GraphicsQuality.name_of(GraphicsQuality.LOW), "low", "name_of LOW")
	eq(GraphicsQuality.name_of(GraphicsQuality.MEDIUM), "medium", "name_of MEDIUM")
	eq(GraphicsQuality.name_of(GraphicsQuality.HIGH), "high", "name_of HIGH")
	eq(GraphicsQuality.from_name("Medium"), GraphicsQuality.MEDIUM, "from_name")
	eq(GraphicsQuality.name_of(9), "high", "a level out of range clamps")
	eq(stack.quality, GraphicsQuality.HIGH, "the default is HIGH")
	eq(int(CityQuality.level(GraphicsQuality.HIGH)["life_draw_r"]), int(LifeDeck.DRAW_R), "HIGH draws life as far as before")


# --- Same game at every level ----------------------------------------------------------------------------------

func _game_sig(s: CityStack) -> String:
	var parts := PackedStringArray([s.checksum()])
	for d in s.decks:
		var shapes := (d.get_node("Collision") as Node).get_child_count()
		parts.append("%d:%d:%d:%s" % [d.geometry_digest(), shapes, d.props.items.size(), CityPropLayout.checksum(d.props.items)])
		for it: Dictionary in d.props.items:
			parts.append(str(d.props.transform_of(int(it["id"])).origin.snapped(Vector3.ONE * 0.001)))
	parts.append(str(s.entry_transform().origin.snapped(Vector3.ONE * 0.001)))
	return "|".join(parts)


func _same_game() -> void:
	var high := _game_sig(stack)
	for q: int in [GraphicsQuality.LOW, GraphicsQuality.MEDIUM, GraphicsQuality.HIGH]:
		stack.set_quality(q)
		eq(_game_sig(stack), high, "%s: checksum, geometry digests, collision shapes and props unchanged" % GraphicsQuality.name_of(q))
	# A stack whose level is set before it is built builds the same game.
	var low := CityStack.new()
	low.set_quality(GraphicsQuality.LOW)
	add_child(low)
	low.build(SectionPlan.make({"seed": SEED}))
	eq(_game_sig(low), high, "a stack built at LOW is the same game as one built at HIGH")
	eq(low.decks_drawn(), [0, 1] as Array[int], "built at LOW: the level is applied at the end of the build")
	eq(low.rig.fills_on(), 0, "built at LOW: no fill lights")
	low.queue_free()
	stack.set_quality(GraphicsQuality.HIGH)


# --- Decks follow the active deck ------------------------------------------------------------------------------

func _decks_follow() -> void:
	var n := stack.decks.size()
	eq(n, 3, "seed 4 has three decks")
	var want := {
		GraphicsQuality.LOW: [[0, 1], [1, 2], [2]],
		GraphicsQuality.MEDIUM: [[0, 1], [0, 1, 2], [1, 2]],
		GraphicsQuality.HIGH: [[0, 1, 2], [0, 1, 2], [0, 1, 2]],
	}
	for q: int in want:
		stack.set_quality(q)
		for k in n:
			stack.set_active_deck(k)
			var exp: Array[int] = []
			exp.assign(want[q][k])
			eq(stack.decks_drawn(), exp, "%s, active deck %d: decks drawn" % [GraphicsQuality.name_of(q), k])
			_lights_match(q, k)
	# follow(): the deck under the followed node becomes active and the drawn decks move with it.
	stack.set_quality(GraphicsQuality.LOW)
	stack.set_active_deck(0)
	var walker := Node3D.new()
	add_child(walker)
	var d2 := stack.decks[2]
	walker.global_position = stack.from_deck_arc(2, d2.plan.avenue_x().x + 4.0, d2.plan.extent.get_center().y, 1.0)
	stack.follow(walker)
	stack._process(0.3)
	eq(stack.active_deck, 2, "follow: the walker's deck becomes active")
	eq(stack.decks_drawn(), [2] as Array[int], "follow at LOW: only the lowest deck is drawn when it is active")
	var d0 := stack.decks[0]
	walker.global_position = stack.from_deck_arc(0, d0.plan.avenue_x().x + 4.0, d0.plan.extent.get_center().y, 1.0)
	stack._process(0.3)
	eq(stack.decks_drawn(), [0, 1] as Array[int], "follow at LOW: back on deck 0, decks 0 and 1 are drawn")
	stack.follow(null)
	walker.queue_free()
	# Collision is never hidden: every deck's floor still stops a ray while its deck is not drawn.
	stack.set_active_deck(0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := stack.get_world_3d().direct_space_state
	var p := stack.from_deck_arc(2, d2.plan.avenue_x().x + 4.0, d2.plan.extent.get_center().y, 0.0)
	var up := stack.ring().up_at(p)
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + up * 3.0, p - up * 3.0))
	check(not hit.is_empty(), "LOW: a hidden deck's floor still collides")
	stack.set_quality(GraphicsQuality.HIGH)
	stack.set_active_deck(0)


func _lights_match(q: int, active: int) -> void:
	var lv := CityQuality.level(q)
	var r := stack.rig
	eq(r.sun.shadow_enabled, bool(lv["sun_shadows"]), "%s: daylight shadows" % GraphicsQuality.name_of(q))
	eq(r.env.ssao_enabled, bool(lv["ssao"]), "%s: SSAO" % GraphicsQuality.name_of(q))
	eq(r.env.glow_enabled, bool(lv["glow"]), "%s: glow" % GraphicsQuality.name_of(q))
	var on := 0
	for k in r._deck_fills.size():
		for l: OmniLight3D in r._deck_fills[k]:
			if l.visible:
				on += 1
				check(stack.decks[k].visible, "%s: a fill of deck %d is on only when that deck is drawn" % [GraphicsQuality.name_of(q), k])
	eq(r.fills_on(), on, "fills_on counts the visible fills")
	if q == GraphicsQuality.LOW:
		eq(on, 0, "LOW: no fill light at all")
		check(r.sun.light_cull_mask & CityStack.deck_layer(active) != 0, "LOW: the daylight lights the active deck")
		check(r.env.ambient_light_energy > float(CityLightRig.PRESETS[r.preset]["ambient_energy"]), "LOW: the ambient rises for the missing fills")
	elif q == GraphicsQuality.MEDIUM:
		var full := 0
		for k in r._deck_fills.size():
			if stack.decks[k].visible:
				full += (r._deck_fills[k] as Array).size()
		check(on > 0 and on <= (full + 3) / 2, "MEDIUM: about half the drawn decks' fills (%d of %d)" % [on, full])
	else:
		var all := 0
		for k in r._deck_fills.size():
			all += (r._deck_fills[k] as Array).size()
		eq(on, all, "HIGH: every fill")


# --- HIGH after LOW restores everything ------------------------------------------------------------------------

func _look(s: CityStack) -> String:
	var parts := PackedStringArray()
	for g in s.find_children("*", "GeometryInstance3D", true, false):
		var gi := g as GeometryInstance3D
		parts.append("%s:%s:%s:%.3f:%d:%d" % [s.get_path_to(gi), gi.visible, gi.is_visible_in_tree(), gi.visibility_range_end,
				gi.cast_shadow, gi.layers])
	for d in s.decks:
		parts.append("%s:%s" % [d.name, d.visible])
	for l in s.rig.find_children("*", "Light3D", true, false):
		var li := l as Light3D
		parts.append("%s:%s:%.4f:%s:%d:%s" % [li.name, li.visible, li.light_energy, li.light_color, li.light_cull_mask, li.shadow_enabled])
		if li is OmniLight3D:
			parts.append("%.3f" % (li as OmniLight3D).omni_range)
	var sun := s.rig.sun
	parts.append("sun:%d:%.2f:%d" % [sun.shadow_caster_mask, sun.directional_shadow_max_distance, sun.directional_shadow_mode])
	var e := s.rig.env
	parts.append("env:%s:%s:%.4f:%s:%.5f:%s:%s:%s:%s:%d:%.3f" % [e.ssao_enabled, e.glow_enabled, e.ambient_light_energy,
			e.ambient_light_color, e.fog_density, e.fog_enabled, e.ssil_enabled, e.sdfgi_enabled, e.volumetric_fog_enabled,
			e.tonemap_mode, e.tonemap_exposure])
	return "\n".join(parts)


func _restore() -> void:
	stack.set_quality(GraphicsQuality.HIGH)
	stack.set_active_deck(1)
	var before := _look(stack)
	for q: int in [GraphicsQuality.LOW, GraphicsQuality.MEDIUM, GraphicsQuality.LOW]:
		stack.set_quality(q)
		check(_look(stack) != before, "%s changes the look" % GraphicsQuality.name_of(q))
	stack.set_active_deck(2)
	stack.set_active_deck(1)
	stack.set_quality(GraphicsQuality.HIGH)
	var after := _look(stack)
	eq(after, before, "HIGH after LOW restores every visibility flag, light, environment flag and range")
	# The rig's preset changes on top of a level, and the level still holds.
	stack.set_quality(GraphicsQuality.LOW)
	stack.rig.apply("dusk")
	eq(stack.rig.fills_on(), 0, "a preset applied at LOW keeps the fills off")
	check(not stack.rig.sun.shadow_enabled, "and the shadows off")
	stack.set_quality(GraphicsQuality.HIGH)
	stack.rig.apply("day")
	eq(_look(stack), before, "HIGH and the day preset again: as before")
	# A single district's own rig takes a level too (no decks: its fills are the active deck's).
	var d := CityDistrict.new()
	add_child(d)
	d.build({"seed": 1.0})
	var fills := d.rig.fills_on()
	d.rig.set_quality(GraphicsQuality.LOW)
	eq(d.rig.fills_on(), 0, "a district's rig at LOW: no fills")
	d.rig.set_quality(GraphicsQuality.HIGH)
	eq(d.rig.fills_on(), fills, "and HIGH again: every fill")
	d.queue_free()


# --- Life: drawing only ----------------------------------------------------------------------------------------

func _make_life() -> AmbientLife:
	var l := AmbientLife.new()
	add_child(l)
	l.set_process(false)
	l.setup_stack(stack)
	l.advance_to(T0)
	return l


func _frames(l: AmbientLife, n: int, dt: float) -> void:
	for i in n:
		l._process(dt)      # (steps every deck)


func _sig(l: AmbientLife) -> String:
	var parts := PackedStringArray()
	for id in l.ids():
		var xf := l.pose_of(id)
		parts.append("%d:%s:%s" % [id, l.state_of(id), xf.origin.snapped(Vector3.ONE * 0.001)])
	for id in l.vehicle_ids():
		parts.append("v%d:%s:%s" % [id, l.vehicle_state(id), l.vehicle_pose(id).origin.snapped(Vector3.ONE * 0.001)])
	parts.append(JSON.stringify(l.tally()))
	return "|".join(parts)


func _life() -> void:
	stack.set_quality(GraphicsQuality.HIGH)
	var viewer := Node3D.new()
	add_child(viewer)
	var d0 := stack.decks[0]
	var e := d0.plan.extent
	viewer.global_position = stack.from_deck_arc(0, d0.plan.avenue_x().x, e.position.y + 30.0, 5.0)
	var hi := _make_life()
	var lo := _make_life()
	lo.set_quality(GraphicsQuality.LOW)
	eq(lo.quality, GraphicsQuality.LOW, "life: set_quality stores the level")
	for l: AmbientLife in [hi, lo]:
		l.add_viewer(viewer)
		l.advance_to(T0 + 20.0)
		_frames(l, 6, 0.05)
	eq(_sig(lo), _sig(hi), "life: LOW and HIGH agree on every state, pose and the tally")
	# Someone between LOW's draw radius and DRAW_R: drawn at HIGH, not at LOW, and hit the same by a shot.
	var u_hi := hi.unit(0)
	var u_lo := lo.unit(0)
	var r_low := float(CityQuality.level(GraphicsQuality.LOW)["life_draw_r"])
	var mid := -1
	for i in u_hi.count():
		if not u_hi.visible_now(i) or u_hi.state_of(i) != "calm":
			continue
		var dist := u_hi.pose_of(i).origin.distance_to(viewer.global_position)
		if dist > r_low + 10.0 and dist < LifeDeck.DRAW_R - 30.0:
			mid = i
			break
	check(mid >= 0, "life: someone outdoors between LOW's draw radius and DRAW_R")
	if mid >= 0:
		check(u_hi.drawn_now(mid), "life HIGH: drawn at %.0f m" % u_hi.pose_of(mid).origin.distance_to(viewer.global_position))
		check(not u_lo.drawn_now(mid), "life LOW: not drawn there")
		eq(u_lo._on[mid], u_hi._on[mid], "life: whether it can be hit does not depend on the quality")
		var xf := hi.pose_of(mid)
		var n_hi := hi.sweep(xf.origin + xf.basis.y - xf.basis.x, xf.origin + xf.basis.y + xf.basis.x, 0.2, 3)
		var n_lo := lo.sweep(xf.origin + xf.basis.y - xf.basis.x, xf.origin + xf.basis.y + xf.basis.x, 0.2, 3)
		eq(n_lo, n_hi, "life: the same sweep hits the same at LOW and HIGH (%d)" % n_hi)
		check(n_hi >= 1, "life: and it hits")
	# A blast on deck 0's vehicle, then time on: still the same game.
	for v in u_hi.vehicle_count():
		if u_hi.vehicle_state(v) != "wreck":
			var vx := u_hi.vehicle_pose(v)
			eq(lo.blast(vx.origin + vx.basis.y * 0.8, 2.0, 3), hi.blast(vx.origin + vx.basis.y * 0.8, 2.0, 3), "life: a blast hits the same")
			break
	for l: AmbientLife in [hi, lo]:
		_frames(l, 40, 0.05)
		l.advance_to(T0 + 30.0)
	eq(_sig(lo), _sig(hi), "life: after a kill and a blast LOW and HIGH still agree")
	# Back to HIGH: the person is drawn again.
	lo.set_quality(GraphicsQuality.HIGH)
	_frames(lo, 2, 0.05)
	_frames(hi, 2, 0.05)
	var drawn_hi := 0
	var drawn_lo := 0
	for i in u_hi.count():
		drawn_hi += 1 if u_hi.drawn_now(i) else 0
		drawn_lo += 1 if u_lo.drawn_now(i) else 0
	eq(drawn_lo, drawn_hi, "life: HIGH again draws as many people as HIGH")
	hi.queue_free()
	lo.queue_free()
	viewer.queue_free()
