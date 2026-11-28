extends TestCase
## The incremental stack build (CityStack.build_begin / build_step / build_progress / build_done, CityDistrict
## build_deck_begin / build_step; docs/design/city-ramps-and-stack.md section 8): a stack built one chunk per call
## (budget 0) is exactly the one built in one call (checksum, every deck's geometry digest, stats, node tree, collision
## shapes, props, entry and spawn transforms); progress only goes up and ends at 1; build_done is false until the last
## chunk; build_begin mid-build restarts cleanly; a district on its own steps the same way.

const SEEDS := [4, 1]


func setup() -> void:
	timeout_sec = 180.0
	for seed_: int in SEEDS:
		await _compare(seed_)
	await _restart(4)
	_district(2)
	await _life(4)
	finish()


## AmbientLife.setup_stack vs setup_stack_begin + setup_step(0.0) to the end: the same people, vehicles, poses, states,
## tallies and snapshot; nothing is visible (units, ids) until done; events heard meanwhile are kept for the end.
func _life(seed_: int) -> void:
	var what := "life %d" % seed_
	var st := CityStack.new()
	add_child(st)
	st.build(SectionPlan.make({"seed": seed_}))
	var a := AmbientLife.new()
	add_child(a)
	a.setup_stack(st)
	check(a.setup_done(), "%s: setup_stack leaves it done" % what)
	a.set_process(false)
	var b := AmbientLife.new()
	add_child(b)
	b.setup_stack_begin(st)
	check(not b.setup_done(), "%s: not done after setup_stack_begin" % what)
	var calls := 0
	var hidden := true
	while not b.setup_step(0.0):
		calls += 1
		hidden = hidden and b.units.is_empty() and b.ids().is_empty() and b.stack == null
		await frames(1)       # frames pass between chunks: the half-set-up units must not run
		if calls > 1000:
			break
	check(hidden, "%s: no unit is visible before the setup is done" % what)
	check(b.setup_done(), "%s: done" % what)
	eq(calls + 1, st.decks.size() * LifeDeck.SETUP_PARTS + 1, "%s: one chunk per call (%d decks x %d parts + 1)" % [what,
			st.decks.size(), LifeDeck.SETUP_PARTS])
	b.set_process(false)
	eq(b.ids(), a.ids(), "%s: same people" % what)
	eq(b.vehicle_ids(), a.vehicle_ids(), "%s: same vehicles" % what)
	a.advance_to(5.0)
	b.advance_to(5.0)
	var poses := true
	for id in a.ids():
		poses = poses and a.pose_of(id).is_equal_approx(b.pose_of(id)) and a.state_of(id) == b.state_of(id)
	check(poses, "%s: same poses and states at t = 5" % what)
	var vposes := true
	for id in a.vehicle_ids():
		vposes = vposes and a.vehicle_pose(id).is_equal_approx(b.vehicle_pose(id)) and a.vehicle_state(id) == b.vehicle_state(id)
	check(vposes, "%s: same vehicle poses and states at t = 5" % what)
	eq(b.tally(), a.tally(), "%s: same tally" % what)
	eq(b.snapshot(), a.snapshot(), "%s: same snapshot" % what)
	var names := []
	for u in b.units:
		names.append(str(u.name))
	eq(names, _child_names(a).filter(func(n: String) -> bool: return n.begins_with("Deck")), "%s: same unit nodes" % what)
	# A restart mid-setup throws the half away.
	b.setup_stack_begin(st)
	b.setup_step(0.0)
	b.setup_step(0.0)
	b.setup_stack_begin(st)
	while not b.setup_step(0.0):
		pass
	await frames(1)
	eq(b.units.size(), st.decks.size(), "%s: a restart gives one unit per deck" % what)
	var decks_named := 0
	for c in b.get_children():
		if str(c.name).begins_with("Deck") and not c.is_queued_for_deletion():
			decks_named += 1
	eq(decks_named, st.decks.size(), "%s: and no leftover unit" % what)
	a.queue_free()
	b.queue_free()
	st.queue_free()
	await frames(2)


func _compare(seed_: int) -> void:
	var what := "section %d" % seed_
	var sec := SectionPlan.make({"seed": seed_})
	var one := CityStack.new()
	add_child(one)
	one.build(sec)
	check(one.build_done(), "%s: build() leaves the stack done" % what)
	near(one.build_progress(), 1.0, 1e-6, "%s: build() leaves progress at 1" % what)
	var step := CityStack.new()
	add_child(step)
	check(not step.build_done(), "%s: not done before any build" % what)
	step.build_begin(SectionPlan.make({"seed": seed_}))
	check(not step.build_done(), "%s: not done right after build_begin" % what)
	var last := step.build_progress()
	var calls := 0
	var monotonic := true
	var done_early := false
	var follower := Node3D.new()
	add_child(follower)
	step.follow(follower)
	while true:
		var finished := step.build_step(0.0)
		calls += 1
		var p := step.build_progress()
		if p < last - 1e-9:
			monotonic = false
		last = p
		if finished:
			break
		if step.build_done():
			done_early = true
		step._process(1.0)      # the follow timer firing mid-build must not crash or touch the half-built stack
		if calls > 10000:
			break
	check(monotonic, "%s: build_progress never goes down" % what)
	check(not done_early, "%s: build_done is false until the last chunk" % what)
	check(step.build_done(), "%s: done after the last step" % what)
	near(step.build_progress(), 1.0, 1e-6, "%s: progress ends at 1" % what)
	eq(calls, step.chunk_log.size(), "%s: budget 0 runs one chunk per call" % what)
	eq(int(step.stats["chunks"]), calls, "%s: stats.chunks counts them" % what)
	check(calls > sec.deck_count * 10, "%s: the build is split into many chunks (%d)" % [what, calls])
	print("%s: %d chunks, stepped %s ms (max chunk %s), one-shot %s ms" % [what, calls, str(step.stats["ms"]),
			str(step.stats["max_chunk_ms"]), str(one.stats["ms"])])
	_same(one, step, what)
	follower.queue_free()
	one.queue_free()
	step.queue_free()
	await frames(2)


## build_begin again while a build is half done: the old half is thrown away and the new build matches build().
func _restart(seed_: int) -> void:
	var what := "restart %d" % seed_
	var one := CityStack.new()
	add_child(one)
	one.build(SectionPlan.make({"seed": seed_}))
	var step := CityStack.new()
	add_child(step)
	step.build_begin(SectionPlan.make({"seed": seed_ + 1}))
	var guard := 0
	while step.decks.size() < 1 and guard < 5000:
		step.build_step(0.0)
		guard += 1
	for i in 5:
		step.build_step(0.0)
	check(not step.build_done(), "%s: half built" % what)
	check(step.decks.size() >= 1, "%s: a finished deck is in the stack mid-build" % what)
	step.build_begin(SectionPlan.make({"seed": seed_}))
	check(not step.build_done(), "%s: not done after a restart" % what)
	eq(step.decks.size(), 0, "%s: the restart drops the old decks" % what)
	await frames(1)       # let the freed half-build go
	while not step.build_step(0.0):
		pass
	_same(one, step, what)
	var names := []
	for c in step.get_children():
		names.append(str(c.name))
	eq(names, _child_names(one), "%s: no leftover deck from the first build" % what)
	one.queue_free()
	step.queue_free()
	await frames(2)


## A district on its own: build() vs build_begin + build_step to the end.
func _district(seed_: int) -> void:
	var what := "district %d" % seed_
	var a := CityDistrict.new()
	add_child(a)
	a.build({"seed": float(seed_), "walls": 1.0})
	var b := CityDistrict.new()
	add_child(b)
	b.build_begin({"seed": float(seed_), "walls": 1.0})
	check(not b.build_done(), "%s: not done after build_begin" % what)
	var n := 0
	while not b.build_step():
		n += 1
	check(n > 5, "%s: stepped in chunks (%d)" % [what, n + 1])
	eq(a.plan.checksum(), b.plan.checksum(), "%s: same plan" % what)
	eq(a.geometry_digest(), b.geometry_digest(), "%s: same geometry digest" % what)
	eq(_tree(a), _tree(b), "%s: same node tree" % what)
	eq(_shapes(a), _shapes(b), "%s: same collision shapes" % what)
	a.queue_free()
	b.queue_free()


func _same(one: CityStack, step: CityStack, what: String) -> void:
	eq(step.checksum(), one.checksum(), "%s: same checksum" % what)
	eq(step.decks.size(), one.decks.size(), "%s: same deck count" % what)
	for key: String in one.stats:
		if key == "ms" or key == "max_chunk_ms":
			continue
		eq(step.stats.get(key), one.stats[key], "%s: same stats.%s" % [what, key])
	eq(_child_names(step), _child_names(one), "%s: same stack children" % what)
	for k in mini(one.decks.size(), step.decks.size()):
		var a := one.decks[k]
		var b := step.decks[k]
		eq(b.geometry_digest(), a.geometry_digest(), "%s deck %d: same geometry digest" % [what, k])
		eq(b.plan.checksum(), a.plan.checksum(), "%s deck %d: same plan checksum" % [what, k])
		for key: String in a.stats:
			if key != "ms":
				eq(b.stats.get(key), a.stats[key], "%s deck %d: same stats.%s" % [what, k, key])
		eq(_tree(b), _tree(a), "%s deck %d: same node tree" % [what, k])
		eq((b.get_node("Collision") as Node).get_child_count(), (a.get_node("Collision") as Node).get_child_count(),
				"%s deck %d: same collision shape count" % [what, k])
		eq(_shapes(b), _shapes(a), "%s deck %d: same collision shapes (transforms and sizes)" % [what, k])
		check(b.props.items == a.props.items, "%s deck %d: same props layout" % [what, k])
		eq(b.strip_x, a.strip_x, "%s deck %d: same ceiling strips" % [what, k])
		eq(_layers(b), _layers(a), "%s deck %d: same render layers" % [what, k])
	check(step.entry_transform().is_equal_approx(one.entry_transform()), "%s: same entry transform" % what)
	for n in [1, 2, 3, 4]:
		var sa := one.spawn_transforms(n)
		var sb := step.spawn_transforms(n)
		var same := sa.size() == sb.size()
		for i in mini(sa.size(), sb.size()):
			same = same and sa[i].is_equal_approx(sb[i])
		check(same, "%s: same spawn transforms for %d" % [what, n])
	eq(step.active_deck, one.active_deck, "%s: same active deck" % what)


func _child_names(n: Node) -> Array:
	var out := []
	for c in n.get_children():
		out.append(str(c.name))
	return out


## Every node under `n` as "path:class" in tree order (unnamed nodes, "@CollisionShape3D@123", as "@").
func _tree(n: Node) -> Array:
	var out := []
	for c in n.find_children("*", "", true, false):
		var path := str(n.get_path_to(c))
		if str(c.name).begins_with("@"):
			path = path.get_base_dir() + "/@"
		out.append("%s:%s" % [path, c.get_class()])
	return out


func _layers(n: Node) -> Array:
	var out := []
	for g in n.find_children("*", "GeometryInstance3D", true, false):
		out.append((g as GeometryInstance3D).layers)
	return out


## A hash of every collision shape in order: its transform and its box size or convex points.
func _shapes(d: CityDistrict) -> int:
	var h := 0
	for c in (d.get_node("Collision") as Node).get_children():
		var cs := c as CollisionShape3D
		var key: Variant = (cs.shape as BoxShape3D).size if cs.shape is BoxShape3D else ((cs.shape as ConvexPolygonShape3D).points if cs.shape is ConvexPolygonShape3D else Vector2((cs.shape as CylinderShape3D).radius, (cs.shape as CylinderShape3D).height))
		h = hash([h, cs.transform, key])
	return h
