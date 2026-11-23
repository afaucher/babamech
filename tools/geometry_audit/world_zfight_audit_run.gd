extends Node
## The world z-fighting audit (docs/design/city-geometry-audit.md) as a headless tool: builds the real world (the
## CityStack of a section seed, with a mission set up so wave doors, flags and the portal are included, and the static
## part of ambient life: barriers, stations, tram) with CityGeo.audit on, runs WorldZfightAudit per deck, prints the
## grouped findings and writes them to test_logs\zfight_audit_s<seed>.txt. Also prints a hash of every deck's collision
## shapes (the gameplay shape: a looks-only fix must leave it unchanged).
##   .\tools\geometry_audit\run_world_zfight_audit.ps1 [-Seed 4] [-Decks 0,1,2] [-NoMission] [-NoLife] [-Limit 40]

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var seed_ := int(_arg(args, "--audit-seed", "4"))
	var limit := int(_arg(args, "--audit-limit", "40"))
	var decks_arg := _arg(args, "--audit-decks", "")
	var mission := not args.has("--audit-no-mission")
	var life := not args.has("--audit-no-life")
	var out := PackedStringArray()
	var t0 := Time.get_ticks_msec()
	CityGeo.audit = true
	var so := {"seed": seed_}
	if args.has("--audit-forms"):      # the section's road forms on (docs/design/city-variety.md: the mix Missions will use)
		so.merge({"f_lane": 0.20, "f_pedestrian": 0.10, "f_none": 0.08})
	var sec := SectionPlan.make(so)
	var stack := CityStack.new()
	add_child(stack)
	stack.build(sec)
	if mission:
		stack.setup_mission(MissionPlan.make(sec))
	var al: Node = null
	if life:     # loaded by path: a life script being edited elsewhere must not stop the tool from compiling (-NoLife)
		al = (load("res://scripts/world/life/ambient_life.gd") as GDScript).new()
		add_child(al)
		al.set_process(false)
		al.setup_stack(stack, 0, 0, 0)
	await get_tree().process_frame
	await get_tree().physics_frame
	out.append("[zfight] section seed %d, stack checksum %s, built in %d ms (mission %s, life %s)" % [seed_, stack.checksum(),
			Time.get_ticks_msec() - t0, str(mission), str(life)])
	for k in stack.decks.size():
		out.append("[zfight] deck %d collision %s" % [k, str(collision_hash(stack.decks[k]))])
	var audit := WorldZfightAudit.new()
	audit.deck_of = stack.deck_at
	audit.arc_of = stack.to_deck_arc
	audit.trace = _arg(args, "--audit-trace", "")
	audit.add_node(stack)
	if al != null:
		audit.add_node(al)
	out.append("[zfight] %d triangles collected in %d ms" % [audit.tri_count(), int(audit.ms["collect"])])
	var decks: Array[int] = []
	if decks_arg == "":
		for k in stack.decks.size():
			decks.append(k)
	else:
		for p in decks_arg.split(",", false):
			decks.append(int(p))
	for k in decks:
		audit.run(k)
		out.append("[zfight] ===== deck %d =====" % k)
		for line in audit.report(limit):
			out.append("[zfight] " + line)
	CityGeo.audit = false
	out.append("[zfight] total %d ms" % (Time.get_ticks_msec() - t0))
	for line in out:
		print(line)
	var f := FileAccess.open("res://test_logs/zfight_audit_s%d.txt" % seed_, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(out) + "\n")
	get_tree().quit(0)


## (count, hash) of a district's collision shapes: every shape's transform and size, in order.
static func collision_hash(d: CityDistrict) -> Array:
	var h := 0
	var col := d.get_node_or_null("Collision")
	if col == null:
		return [0, 0]
	for c in col.get_children():
		var cs := c as CollisionShape3D
		var sz: Variant = (cs.shape as BoxShape3D).size if cs.shape is BoxShape3D else (cs.shape as ConvexPolygonShape3D).points
		h = hash([h, cs.transform, sz])
	return [col.get_child_count(), h]


static func _arg(args: PackedStringArray, key: String, def: String) -> String:
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else def
