extends TestCase
## VISUAL: the pilot lab subject, shot for review (`.\test_runner.ps1 -Visual -TestName test_pilot_visual`): the chicken
## close up in each mood, at the peak of the main reactions, looking hard left; the effects (each kind mid-flight, and the
## same mood with effects off) and the colour flush (on / off) at a medium distance; the line-up of every head. Shots go to
## test_logs/shots/pilot_*.png. Checks are coarse (the 3D view shows detail; effects / flush change the picture); judge
## the shots by eye against docs/design/pilot-heads.md section 3.2 and art/picks/head_chicken.png.

const VISUAL := true
const CLOSE := 3.0     ## camera distance for the face close-ups
const MID := 3.5       ## for the effects / flush sets (head about a third of the frame)

var sc: ShotCheck
var lab: Lab
var p: PilotLab
var view := Rect2(0.3, 0.05, 0.7, 0.9)


func setup() -> void:
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_pilot_visual needs a renderer: run .\\test_runner.ps1 -Visual -TestName test_pilot_visual")
		finish()
		return
	lab = (load("res://scenes/lab.tscn") as PackedScene).instantiate() as Lab
	add_child(lab)
	await frames(3)
	lab.pick("pilot")
	p = lab.subject as PilotLab
	# The subject alone: no side panel or status line (the lab's own shots cover those).
	(lab._ui.get_parent().get_parent().get_parent() as Control).visible = false
	lab._status.visible = false
	view = Rect2(0.15, 0.05, 0.7, 0.9)
	var head := "chicken" if PilotHead.ids().has("chicken") else PilotHead.ids()[0]
	# Moods, close up, front three-quarter.
	for m: String in PilotHead.moods():
		await _state({"head": head, "mood": m}, CLOSE, 90)
		_check(await sc.grab("pilot_%s_%s" % [head, m]), "mood " + m)
	# Reaction peaks (frozen), from stern.
	for r: String in ["flinch", "pain", "smirk", "impact", "alert", "effort"]:
		await _state({"head": head, "mood": "stern", "pose": r}, CLOSE, 3)
		_check(await sc.grab("pilot_%s_peak_%s" % [head, r]), "peak " + r)
	# Looking hard left, and a profile.
	await _state({"head": head, "mood": "stern", "look": "left"}, CLOSE, 90)
	_check(await sc.grab("pilot_%s_look_left" % head), "look left")
	await _state({"head": head, "mood": "stern"}, CLOSE, 30, "side")
	_check(await sc.grab("pilot_%s_side" % head), "side")
	await _state({"head": head, "mood": "dazed"}, CLOSE, 60, "front")
	_check(await sc.grab("pilot_%s_dazed_front" % head), "dazed front")
	await _state({"head": head, "mood": "afraid"}, CLOSE, 60, "front")
	_check(await sc.grab("pilot_%s_afraid_front" % head), "afraid front")

	# Effects: each mid-flight, then the same moods with effects off.
	await _state({"head": head, "mood": "auto", "condition": "shutdown"}, MID, 70)
	var stars := await sc.grab("pilot_fx_stars")
	await _state({"head": head, "mood": "auto", "condition": "disabled"}, MID, 150)
	var smoke := await sc.grab("pilot_fx_smoke")
	await _state({"head": head, "mood": "overheated"}, MID, 60)
	for h in p.heads:
		h.fx.emit("steam", 1.0)
		h.fx.emit("sweat", 1.0)
	await frames(14)
	var steam := await sc.grab("pilot_fx_steam_sweat")
	await _state({"head": head, "mood": "stern"}, MID, 40)
	p.do_lab_action("pain")
	await frames(7)
	var chips := await sc.grab("pilot_fx_chips")
	await _state({"head": head, "mood": "stern"}, MID, 40)
	for h in p.heads:
		h.fx.emit("flash", 1.0)
	var flash := await sc.grab("pilot_fx_flash")
	await _state({"head": head, "mood": "auto", "condition": "shutdown", "fx": 0.0}, MID, 70)
	var stars_off := await sc.grab("pilot_fx_off_dazed")
	await _state({"head": head, "mood": "overheated", "fx": 0.0}, MID, 60)
	await sc.grab("pilot_fx_off_overheated")
	await _state({"head": head, "mood": "stern", "fx": 0.0}, MID, 40)
	await sc.grab("pilot_fx_off_stern")
	if stars != null and stars_off != null:
		var d := absf(float(ShotCheck.stats(stars, view)["mean"]) - float(ShotCheck.stats(stars_off, view)["mean"]))
		print("stars vs off mean delta %.4f" % d)
	for img: Image in [smoke, steam, chips, flash]:
		_check(img, "fx")

	# Flush on / off, on a light head (chicken) and a dark one (duck), when registered.
	for fh: String in ["chicken", "duck"]:
		if not PilotHead.ids().has(fh):
			continue
		for m: String in ["overheated", "afraid"]:
			for on in [1.0, 0.0]:
				await _state({"head": fh, "mood": m, "fx": 0.0, "flush": on}, MID, 70)
				_check(await sc.grab("pilot_flush_%s_%s_%s" % [fh, m, "on" if on > 0.5 else "off"]), "flush " + m)

	# Every head: stern vs afraid from the front (the brows must visibly flip), and three-quarter stern.
	for hid: String in PilotHead.ids():
		for m: String in ["stern", "afraid"]:
			await _state({"head": hid, "mood": m}, CLOSE, 60, "front")
			_check(await sc.grab("pilot_%s_%s_front" % [hid, m]), "%s %s front" % [hid, m])
		await _state({"head": hid, "mood": "stern"}, CLOSE, 30)
		_check(await sc.grab("pilot_%s_stern_3q" % hid), "%s stern 3q" % hid)

	# The line-up.
	await _state({"head": "all", "mood": "stern"}, -1.0, 60, "front")
	_check(await sc.grab("pilot_lineup"), "line-up")
	lab.queue_free()
	finish()


## Resets the subject to `opts` (options and params), idles off, then lets it run `n` frames.
func _state(opts: Dictionary, dist: float, n: int, v: String = "three_q") -> void:
	var defaults := {"head": "chicken", "mood": "auto", "drive": "idle", "condition": "none", "look": "none", "pose": "none"}
	p.set_lab_param("fx", float(opts.get("fx", 1.0)))
	p.set_lab_param("flush", float(opts.get("flush", 1.0)))
	p.set_lab_param("heat", 0.0)
	p.set_lab_param("hp", 1.0)
	p.pose = "none"
	for k: String in ["drive", "condition", "look", "mood"]:
		p.set_lab_option(k, str(opts.get(k, defaults[k])))
	p.set_lab_option("head", str(opts.get("head", "chicken")))   # rebuilds: fresh heads, no leftover effects
	for h in p.heads:
		h.idle_enabled = false
	if str(opts.get("pose", "none")) != "none":
		p.set_lab_option("pose", str(opts["pose"]))
	lab.set_view("three" if v == "three_q" else v)
	if v == "three_q":   # front three-quarter: mostly the face, a little of the right side
		lab._yaw = 0.45
		lab._pitch = 0.12
	lab._dist = dist if dist > 0.0 else float(p.lab_radius()) * 2.0
	await frames(n)


func _check(img: Image, what: String) -> void:
	sc.not_blank(img, view, "pilot %s 3D view" % what)
