extends TestCase
## The lab shows every registered subject, and every param and option of each can be set to its ends without errors.


func setup() -> void:
	var lab := (load("res://scenes/lab.tscn") as PackedScene).instantiate() as Lab
	add_child(lab)
	await frames(2)
	check(LabRegistry.ids().has("mech"), "the placeholder mech is registered")
	for id: String in LabRegistry.ids():
		lab.pick(id)
		await frames(1)
		if not check(lab.subject != null and lab.subject_id == id, "subject %s loads" % id):
			continue
		for p: Dictionary in lab.subject.lab_params():
			for v in [float(p["min"]), float(p["max"])]:
				lab.subject.set_lab_param(str(p["id"]), v)
				await frames(1)
		lab.reset_params()
		for p: Dictionary in lab.subject.lab_params():
			near(float(p["value"]), float(lab._defaults[p["id"]]), 0.0001, "%s.%s resets to its default" % [id, p["id"]])
		for o: Dictionary in lab.subject.lab_options():
			for ch: Variant in o["choices"]:
				lab.subject.set_lab_option(str(o["id"]), str(ch))
		await frames(1)
		for v: String in Lab.VIEW_ORDER:
			lab.set_view(v)
		lab.toggle_pause()
		lab.set_speed(0.25)
		lab.toggle_pause()
		await frames(2)
	# The mech's options include a weapon per hardpoint.
	lab.pick("mech")
	await frames(1)
	var opts: Array = lab.subject.lab_options()
	check(opts.size() >= 2 + 5, "mech options: head, chassis and five hardpoints (%d)" % opts.size())
	lab.queue_free()
	finish()
