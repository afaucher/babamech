extends TestCase
## Headless guard for the renderer's "BUG, indexing did not unpair geometries from light" (tests/test_render_unpair.gd
## is the real-renderer check). On Forward+, changing a GeometryInstance3D's `layers` while it is in the tree and lights
## exist leaves it paired with every light whose cull mask no longer matches (Godot's instance_set_layer_mask does not
## unpair on the clustered renderer); freeing such a light prints the error. So: a node's layers are set BEFORE it enters
## the tree, never changed after while an omni light is around.
##
## Checks the stepped mission load (CityStack.build_step, then AmbientLife.setup_stack_begin / setup_step, frames in
## between, as a crew mission loads): no GeometryInstance3D under the stack or life changes its layers from one step to
## the next once the rig's fills exist.

const SEED := 4


func setup() -> void:
	timeout_sec = 120.0
	var st := CityStack.new()
	add_child(st)
	st.build_begin(SectionPlan.make({"seed": SEED}))
	var seen := {}
	var relayered: Array[String] = []
	while not st.build_step(0.0):
		await frames(1)
		_scan(st, seen, relayered)
	await frames(1)
	_scan(st, seen, relayered)
	check(_lights(st) > 0, "the stack has its fills")
	var life := AmbientLife.new()
	add_child(life)
	life.setup_stack_begin(st)
	while not life.setup_step(0.0):
		await frames(1)
		_scan(st, seen, relayered)
		_scan(life, seen, relayered)
	await frames(1)
	_scan(life, seen, relayered)
	eq(relayered.size(), 0, "no geometry re-layered in the tree while lights exist (first: %s)" %
			", ".join(relayered.slice(0, 5)))
	life.queue_free()
	st.queue_free()
	await frames(2)
	finish()


func _lights(root: Node) -> int:
	return root.find_children("*", "OmniLight3D", true, false).size()


## Record every geometry's layers; once a fill exists, a change since the last scan is a re-layer in the tree.
func _scan(root: Node, seen: Dictionary, relayered: Array[String]) -> void:
	var lit := _lights(get_tree().root) > 0
	for g in root.find_children("*", "GeometryInstance3D", true, false):
		var gi := g as GeometryInstance3D
		var id := gi.get_instance_id()
		if lit and seen.has(id) and int(seen[id]) != gi.layers:
			relayered.append("%s %d -> %d" % [str(root.get_path_to(gi)), int(seen[id]), gi.layers])
		seen[id] = gi.layers
