extends TestCase
## The "pilot" lab subject (scripts/pilot/pilot_lab.gd): every option value and every action runs for a few advanced
## seconds without error, with one head and with the "all" line-up; the scripted "mech moves" loop visits every mood and
## every reaction; the pose option freezes a reaction at its peak; the lab shows a button per action.

const DT := 1.0 / 60.0


func setup() -> void:
	check(LabRegistry.ids().has("pilot"), "the pilot subject is registered")
	var p := LabRegistry.make("pilot") as PilotLab
	add_child(p)
	await frames(1)
	eq(p.heads.size(), 1, "one head by default")
	_run(p, 0.5)
	for o: Dictionary in p.lab_options():
		for ch: Variant in o["choices"]:
			p.set_lab_option(str(o["id"]), str(ch))
			_run(p, 0.6)
			check(not p.heads.is_empty(), "%s=%s keeps heads" % [o["id"], ch])
		p.set_lab_option(str(o["id"]), str(o["choices"][0]) if o["id"] != "head" else str(PilotHead.ids()[0]))
	p.set_lab_option("pose", "none")
	p.set_lab_option("drive", "manual")
	for head: String in ["all", PilotHead.ids()[0]]:
		p.set_lab_option("head", head)
		eq(p.heads.size(), PilotHead.ids().size() if head == "all" else 1, "head=%s: head count" % head)
		var acts: Array = p.lab_actions()
		check(acts.size() >= PilotHead.reactions().size() + 1, "head=%s: an action per reaction, hit and tics" % head)
		for a: Dictionary in acts:
			p.do_lab_action(str(a["id"]))
			_run(p, 0.4)
		for t: String in p.heads[0].tics():
			check(acts.any(func(a: Dictionary) -> bool: return a["id"] == t), "tic %s is an action" % t)
		_run(p, 2.0)
	# Pose freezes at the reaction's peak.
	p.set_lab_option("pose", "pain")
	check(p.heads[0].reacting("pain"), "pose=pain holds the pain reaction")
	var before := p.heads[0].channels()
	_run(p, 1.0)
	eq(p.heads[0].channels(), before, "a frozen pose doesn't move")
	p.set_lab_option("pose", "none")
	# The scripted loop: every mood and reaction, with one head and with all.
	for head: String in [PilotHead.ids()[0], "all"]:
		p.set_lab_option("head", head)
		p.set_lab_option("mood", "auto")
		p.set_lab_option("drive", "scripted")
		p.visited_moods.clear()
		p.visited_reactions.clear()
		var total := 0.0
		for s: Array in PilotLab.SCRIPT:
			total += float(s[1])
		var steps := {}
		for i in roundi((total + 1.0) / DT):
			p._process(DT)
			steps[p.script_step()] = true
		eq(steps.size(), PilotLab.SCRIPT.size(), "head=%s: the loop visits every step" % head)
		for m: String in PilotHead.moods():
			check(p.visited_moods.has(m), "head=%s: the loop shows mood %s (%s)" % [head, m, p.visited_moods.keys()])
		for r: String in PilotHead.reactions():
			check(p.visited_reactions.has(r), "head=%s: the loop shows reaction %s (%s)" % [head, r, p.visited_reactions.keys()])
	# Params to their ends.
	for prm: Dictionary in p.lab_params():
		for v in [float(prm["min"]), float(prm["max"])]:
			p.set_lab_param(str(prm["id"]), v)
			_run(p, 0.2)
	p.queue_free()
	await frames(1)
	await _check_buttons()
	finish()


func _run(p: PilotLab, seconds: float) -> void:
	for i in roundi(seconds / DT):
		p._process(DT)


## The lab builds a button per action for this subject, and none for subjects without the hook.
func _check_buttons() -> void:
	var lab := (load("res://scenes/lab.tscn") as PackedScene).instantiate() as Lab
	add_child(lab)
	await frames(2)
	lab.pick("pilot")
	await frames(2)
	eq(lab._actions_box.get_child_count(), (lab.subject as PilotLab).lab_actions().size(), "a lab button per action")
	check(lab._actions_box.visible, "the action buttons show for the pilot subject")
	var b := lab._actions_box.get_child(0) as Button
	b.pressed.emit()
	check((lab.subject as PilotLab).heads[0].reacting(str((lab.subject as PilotLab).lab_actions()[0]["id"])),
		"pressing a button fires its action")
	lab.pick("mech")
	await frames(2)
	check(not lab._actions_box.visible, "no action buttons for a subject without lab_actions")
	lab.queue_free()
	await frames(1)
