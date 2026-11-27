class_name PilotLab
extends Node3D
## Lab subject "pilot" (docs/design/pilot-heads.md section 8): the expressive pilot heads (PilotHead) on stub hatch blocks,
## one close up or every registered head in a line-up, with no mech needed.
## Options: head (each id in PilotHead.ids(), or "all"), mood ("auto" = picked from the inputs, or a forced mood), drive
## ("idle": still, the sliders' heat / hp / condition only; "scripted": the "mech moves" loop below; "manual": the speed
## and turn sliders as the mech's motion), condition (flags fed with idle / manual: firing, shutdown, disabled), look
## (none, left, right, up, orbit = a moving target), pose (freezes a reaction at its peak, for stills).
## Actions (LabRegistry's optional lab_actions hook): every reaction, "hit" (hit angle / amount sliders), each tic.
## The scripted loop feeds PilotHead.feed with synthetic velocity / yaw rate / grounded / heat / hp and fires the hits and
## events; a Label3D shows the current step. While scripted, the mood option is ignored (the loop drives the mood).
## Cosmetic only (Net.LOCAL): a viewer, nothing here is synced.

const PARAMS := [
	{"id": "scale", "label": "Head scale", "min": 0.5, "max": 3.0, "value": 1.0},
	{"id": "spacing", "label": "Line-up spacing", "min": 1.2, "max": 3.0, "value": 1.7},
	{"id": "heat", "label": "Heat (0..1)", "min": 0.0, "max": 1.0, "value": 0.0},
	{"id": "hp", "label": "HP (0..1)", "min": 0.0, "max": 1.0, "value": 1.0},
	{"id": "speed", "label": "Forward speed (manual, m/s)", "min": 0.0, "max": 10.0, "value": 3.0},
	{"id": "turn", "label": "Turn rate (manual, rad/s, + left)", "min": -2.5, "max": 2.5, "value": 0.0},
	{"id": "hit_angle", "label": "Hit from (deg, 0 front, + right)", "min": -180.0, "max": 180.0, "value": 90.0},
	{"id": "hit_amount", "label": "Hit amount (HP fraction)", "min": 0.0, "max": 0.5, "value": 0.08},
	{"id": "fx", "label": "Effects on (0/1)", "min": 0.0, "max": 1.0, "value": 1.0},
	{"id": "flush", "label": "Colour flush on (0/1)", "min": 0.0, "max": 1.0, "value": 1.0},
]
const DRIVES := ["idle", "scripted", "manual"]
const CONDITIONS := ["none", "firing", "shutdown", "disabled"]
const LOOKS := ["none", "left", "right", "up", "orbit"]
## Where the neck base sits: the top of the hatch block, the head sunk a little into it so the neck base is hidden.
const HATCH_TOP := 0.5
const HEAD_SINK := 0.16
## The "mech moves" loop: step id and seconds.
const SCRIPT := [
	["walk", 2.5], ["run", 2.0], ["hard stop", 1.5], ["turn left", 1.6], ["turn right", 1.6], ["aim + fire", 2.0],
	["jump", 0.9], ["land", 1.4], ["hit from left", 1.2], ["hit from right", 1.2], ["hit from front", 1.2],
	["hit from behind", 1.2], ["big hit", 1.8], ["heat ramp", 4.5], ["overheat", 2.2], ["shutdown", 3.0],
	["revive", 1.8], ["hull critical", 2.6], ["disabled", 2.6], ["reboot", 1.8], ["teammate down", 1.6],
	["kill smirk", 2.2],
]
const JUMP_VY := 5.0
const JUMP_G := 16.0

var params: Dictionary = {}
var head_opt := ""
var mood_opt := "auto"
var drive := "idle"
var condition := "none"
var look := "none"
var pose := "none"
var time_scale := 1.0
var heads: Array[PilotHead] = []
## Scripted loop progress, and what it has shown so far (tests).
var step_i := 0
var step_t := 0.0
var visited_moods := {}
var visited_reactions := {}
var _t := 0.0
var _mounts: Array[Node3D] = []
var _label: Label3D


func _init() -> void:
	for p: Dictionary in PARAMS:
		params[p["id"]] = p["value"]
	var ids := PilotHead.ids()
	head_opt = "chicken" if ids.has("chicken") else ids[0]


func _ready() -> void:
	rebuild()


func rebuild() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	heads.clear()
	_mounts.clear()
	var ids: Array = [head_opt]
	if head_opt == "all":
		ids.assign(PilotHead.ids())
	var n := ids.size()
	var s := float(params["scale"])
	var sp := float(params["spacing"]) * s
	for i in n:
		var mount := Node3D.new()
		mount.name = "Mount_" + str(ids[i])
		mount.position = Vector3((float(i) - float(n - 1) * 0.5) * sp, 0.0, 0.0)
		mount.scale = Vector3.ONE * s
		add_child(mount)
		_build_hatch(mount)
		var h := PilotHead.make(str(ids[i]), i)
		h.position = Vector3(0.0, HATCH_TOP - HEAD_SINK, 0.0)
		h.set_process(false)
		h.idle_always = true
		mount.add_child(h)
		heads.append(h)
		_mounts.append(mount)
		if n > 1:
			var name_l := Label3D.new()
			name_l.text = str(ids[i])
			name_l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			name_l.font_size = 40
			name_l.pixel_size = 0.004
			name_l.position = Vector3(0.0, 0.2, -0.75)
			mount.add_child(name_l)
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 32
	_label.pixel_size = 0.0022
	_label.outline_size = 8
	_label.position = Vector3(0.0, HATCH_TOP + 1.75 * s, 0.0)
	add_child(_label)
	_apply_settings()
	step_i = 0
	step_t = 0.0
	if drive == "scripted":
		_enter_step()
	_apply_pose()
	_update_label()


## The stub hatch the head sits in: a hull block with a collar, so the neck base is hidden like on the mech.
func _build_hatch(mount: Node3D) -> void:
	mount.add_child(MechParts.box(Vector3(1.15, HATCH_TOP - 0.06, 1.05), Color(0.46, 0.48, 0.5),
		Vector3(0.0, (HATCH_TOP - 0.06) * 0.5, 0.05)))
	mount.add_child(MechParts.box(Vector3(1.2, 0.06, 1.1), Color(0.3, 0.31, 0.33), Vector3(0.0, HATCH_TOP - 0.03, 0.05)))
	mount.add_child(MechParts.box(Vector3(1.17, 0.07, 0.02), LowPolyPalette.ORANGE, Vector3(0.0, HATCH_TOP * 0.55, -0.48)))


func _apply_settings() -> void:
	for h in heads:
		h.fx_enabled = float(params["fx"]) >= 0.5
		if not h.fx_enabled and h.fx_node != null:
			h.fx_node.clear()
		h.face.set_tint_enabled(float(params["flush"]) >= 0.5)
		if mood_opt == "auto" or drive == "scripted":
			h.clear_mood()
		else:
			h.set_mood(mood_opt)


## Freezes every head at the peak of the `pose` reaction (stills); "none" lets them run.
func _apply_pose() -> void:
	if pose == "none":
		for h in heads:
			h.idle_enabled = true
		return
	for h in heads:
		h.idle_enabled = false
		var st := _base_state()
		for i in 30:   # settle the mood first
			h.feed(1.0 / 60.0, st)
		_fire(h, pose)
		var d := PilotExpressions.reaction(pose, h.face.overrides)
		var peak := float(d["a"]) + float(d["h"]) * 0.5
		var t := 0.0
		while t < peak:
			h.feed(1.0 / 60.0, st)
			t += 1.0 / 60.0


func _process(delta: float) -> void:
	var dt := delta * time_scale
	if dt <= 0.0 or not is_finite(dt):
		return
	_t += dt
	if pose != "none":
		return
	var st := _base_state()
	if drive == "scripted":
		st = _script_state(dt)
	elif drive == "manual":
		st["vel"] = Vector3(0.0, 0.0, -float(params["speed"]))
		st["yaw_rate"] = float(params["turn"])
	for i in heads.size():
		var h := heads[i]
		_aim(h, _mounts[i])
		h.feed(dt, st)
	_track()
	_update_label()


func _base_state() -> Dictionary:
	return {"heat": float(params["heat"]), "hp": float(params["hp"]), "firing": condition == "firing",
		"shutdown": condition == "shutdown", "disabled": condition == "disabled"}


func _aim(h: PilotHead, mount: Node3D) -> void:
	var p := Vector3.ZERO
	match look:
		"left": p = Vector3(-8.0, 0.85, -1.2)
		"right": p = Vector3(8.0, 0.85, -1.2)
		"up": p = Vector3(0.0, 6.0, -3.0)
		"orbit":
			var a := _t * 0.9
			p = Vector3(sin(a) * 4.0, 0.85 + sin(_t * 0.55) * 1.6, -cos(a) * 4.0)
		_:
			h.clear_look()
			return
	h.look_at_point(mount.to_global(Vector3(0.0, HATCH_TOP - HEAD_SINK, 0.0) + p) if mount.is_inside_tree() else p)


func _track() -> void:
	if heads.is_empty():
		return
	var h := heads[0]
	visited_moods[h.mood()] = true
	for r: String in PilotHead.reactions():
		if h.reacting(r):
			visited_reactions[r] = true


# --- the scripted "mech moves" loop -------------------------------------------------------------------

func script_step() -> String:
	return str(SCRIPT[step_i][0])


func _script_state(dt: float) -> Dictionary:
	step_t += dt
	while step_t >= float(SCRIPT[step_i][1]):
		step_t -= float(SCRIPT[step_i][1])
		step_i = (step_i + 1) % SCRIPT.size()
		_enter_step()
	var t := step_t
	var dur := float(SCRIPT[step_i][1])
	var st := {"vel": Vector3.ZERO, "yaw_rate": 0.0, "grounded": true, "heat": 0.0, "hp": 1.0}
	match script_step():
		"walk":
			st["vel"] = Vector3(0, 0, -3.0)
			st["footfall"] = _tick(t, dt, 0.5)
		"run":
			st["vel"] = Vector3(0, 0, -7.5)
			st["footfall"] = _tick(t, dt, 0.3)
			st["effort"] = t < 0.6
		"turn left":
			st["vel"] = Vector3(0, 0, -2.0)
			st["yaw_rate"] = 1.8
		"turn right":
			st["vel"] = Vector3(0, 0, -2.0)
			st["yaw_rate"] = -1.8
		"aim + fire":
			st["firing"] = true
		"jump":
			st["grounded"] = false
			st["effort"] = t < 0.5
			st["vel"] = Vector3(0, JUMP_VY - JUMP_G * t, -2.0)
		"heat ramp":
			st["heat"] = 0.95 * t / dur
		"overheat":
			st["heat"] = 0.97
		"shutdown":
			st["heat"] = 1.0
			st["shutdown"] = true
		"revive":
			st["heat"] = 0.3
		"hull critical":
			st["hp"] = 0.18
		"disabled":
			st["hp"] = 0.0
			st["disabled"] = true
		"reboot":
			st["hp"] = 0.5
		"teammate down", "kill smirk":
			st["hp"] = 0.6
	return st


## One-shot events at the start of a step.
func _enter_step() -> void:
	for h in heads:
		match script_step():
			"hit from left": h.react_hit(Vector3.LEFT, 0.08)
			"hit from right": h.react_hit(Vector3.RIGHT, 0.08)
			"hit from front": h.react_hit(Vector3.FORWARD, 0.08)
			"hit from behind": h.react_hit(Vector3.BACK, 0.08)
			"big hit": h.react_hit(Vector3(0.7, 0.1, -0.7), 0.3)
			"revive", "reboot": h.react("revived")
			"teammate down": h.react("alert", 1.0, Vector3(-0.8, 0.0, -0.4))
			"kill smirk": h.react("smirk")


static func _tick(t: float, dt: float, period: float) -> bool:
	return floori(t / period) != floori((t - dt) / period)


func _update_label() -> void:
	if _label == null:
		return
	var m := heads[0].mood() if not heads.is_empty() else ""
	if pose != "none":
		_label.text = "pose: %s" % pose
	elif drive == "scripted":
		_label.text = "%s   (%s)" % [script_step(), m]
	else:
		_label.text = "%s   %s" % [drive, m]


# --- actions -------------------------------------------------------------------------------------------

func _hit_dir() -> Vector3:
	var a := deg_to_rad(float(params["hit_angle"]))
	return Vector3(sin(a), 0.0, -cos(a))


func _fire(h: PilotHead, id: String) -> void:
	if id == "hit":
		h.react_hit(_hit_dir(), float(params["hit_amount"]))
	elif id in ["flinch", "alert"]:
		h.react(id, 1.0, _hit_dir())
	elif id in PilotHead.reactions():
		h.react(id)
	else:
		h.play_tic(id)


func lab_actions() -> Array:
	var out: Array = []
	for r: String in PilotHead.reactions():
		out.append({"id": r, "label": r})
	out.append({"id": "hit", "label": "hit"})
	var seen := {}
	for h in heads:
		for t: String in h.tics():
			if not seen.has(t):
				seen[t] = true
				out.append({"id": t, "label": t})
	return out


func do_lab_action(id: String) -> void:
	if pose != "none":
		pose = "none"
		_apply_pose()
	for h in heads:
		_fire(h, id)


# --- lab contract -----------------------------------------------------------------------------------------

func lab_params() -> Array:
	return LabRegistry.param_rows(PARAMS, params)


func set_lab_param(id: String, v: float) -> void:
	params[id] = v
	if id == "scale" or id == "spacing":
		rebuild()
	elif id == "fx" or id == "flush":
		_apply_settings()


func lab_options() -> Array:
	var head_choices: Array = PilotHead.ids()
	head_choices.append("all")
	var moods: Array = ["auto"]
	moods.append_array(PilotHead.moods())
	var poses: Array = ["none"]
	poses.append_array(PilotHead.reactions())
	return [
		{"id": "head", "label": "Head", "choices": head_choices, "value": head_opt},
		{"id": "mood", "label": "Mood", "choices": moods, "value": mood_opt},
		{"id": "drive", "label": "Drive", "choices": DRIVES, "value": drive},
		{"id": "condition", "label": "Condition (idle / manual)", "choices": CONDITIONS, "value": condition},
		{"id": "look", "label": "Look", "choices": LOOKS, "value": look},
		{"id": "pose", "label": "Freeze at peak (stills)", "choices": poses, "value": pose},
	]


func set_lab_option(id: String, v: String) -> void:
	match id:
		"head":
			if v == "all" or PilotHead.ids().has(v):
				head_opt = v
				rebuild()
		"mood":
			mood_opt = v
			_apply_settings()
		"drive":
			drive = v
			rebuild()
		"condition":
			condition = v
		"look":
			look = v
		"pose":
			pose = v
			rebuild()


func lab_focus() -> Vector3:
	var s := float(params["scale"])
	return Vector3(0.0, HATCH_TOP * s + 0.7 * s, 0.0)


func lab_radius() -> float:
	var s := float(params["scale"])
	if head_opt == "all":
		return (0.55 * float(heads.size()) * float(params["spacing"]) + 1.0) * s
	return 1.6 * s
