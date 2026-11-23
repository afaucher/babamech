class_name MechAudio
extends Node3D
## Cosmetic mech audio driver (docs/design/audio.md §3A-B). Child of a MechController (attached in MechSpawn.make()).
## Observes MechController, MechRig.gait, ThrusterFx and optional CityDistrict to trigger surface-aware footsteps,
## leg/yaw servos, thruster ignition + heat-tracked jet loop, emergency auto-burn alert, soft/hard landings,
## rising thermal turbine hum (>55%), accelerating overheat ticks (>80%), shutdown/reboot sequence, and subtle
## deadpan radio-filtered pilot cues on major events.
## Zero edits to gait.gd or mech_rig.gd; strictly cosmetic (Net LOCAL).

var is_local := true                 ## true = local player's mech (SFX_Player + cockpit heat cues); false = remote puppet
var city: CityDistrict               ## optional: resolves concrete / grass / rooftop footsteps (auto-discovered if null)

var _body: MechController
var _rig: MechRig
var _fx: ThrusterFx
var _prev_stepping: Array[bool] = []
var _was_thrusting := false
var _was_emergency := false
var _was_grounded := true
var _hard_landed_step := false
var _reboot_spooled := false
var _heat_tick_in := 0.0
var _turn_servo_cd := 0.0
var _city_scanned := false
var _gait: Gait                      ## the Gait whose `stepped` signal is connected (rebound if MechRig swaps it)
var _step_queue: Array = []          ## [foot, info] from Gait.stepped, played in the next _step_gait (keeps step() ordering)

## Footstep levels per Gait step kind (dB offsets on top of the cue's own db). "land" plays nothing: mech.land.* covers it.
const STRIDE_MIN_DB := -8.0          ## a stride of weight 0 (scaled linearly to 0 dB at weight 1), plus the speed term
const MINOR_DB := -9.0               ## "correction" / "settle": base offset, then -6 dB at weight 0 .. 0 dB at weight 1
const MINOR_MIN_WEIGHT := 0.05       ## "correction" / "settle" shorter than this share of step_length are silent


func net_fields() -> Dictionary:
	return {
		"is_local": Net.LOCAL, "city": Net.LOCAL, "_body": Net.LOCAL, "_rig": Net.LOCAL, "_fx": Net.LOCAL,
		"_prev_stepping": Net.LOCAL, "_was_thrusting": Net.LOCAL, "_was_emergency": Net.LOCAL,
		"_was_grounded": Net.LOCAL, "_hard_landed_step": Net.LOCAL, "_reboot_spooled": Net.LOCAL,
		"_heat_tick_in": Net.LOCAL, "_turn_servo_cd": Net.LOCAL, "_city_scanned": Net.LOCAL,
		"_gait": Net.LOCAL, "_step_queue": Net.LOCAL,
	}


func _ready() -> void:
	_body = get_parent() as MechController
	if _body != null:
		_rig = _body.get_node_or_null("Rig") as MechRig
		_fx = _body.get_node_or_null("Thrusters") as ThrusterFx
		_body.hard_landing.connect(_on_hard_landing)
		_body.overheated.connect(_on_overheated)
		_body.rebooted.connect(_on_rebooted)
		_was_grounded = _body.grounded()
		_bind_gait()
	process_physics_priority = 20   # after MechController and MechRig (priority 10) have stepped


func _exit_tree() -> void:
	_unbind_gait()
	var a := _audio()
	if a != null:
		a.stop_loop(_thrust_tag())
		a.stop_loop(_heat_tag())
		if _local():
			a.set_heat_duck(false)


func _physics_process(delta: float) -> void:
	step(delta)


## Public step so headless tests can drive it explicitly after MechController.step / MechRig.update_pose.
func step(delta: float) -> void:
	if _body == null or delta <= 0.0:
		return
	var a := _audio()
	if a == null:
		_step_queue.clear()
		return
	if city == null and not _city_scanned and is_inside_tree():
		_city_scanned = true
		_find_city()
	_step_gait(a)
	_step_turn_servo(a, delta)
	_step_thrusters(a)
	_step_landing(a)
	_step_heat(a, delta)
	_hard_landed_step = false


## Footfalls come from Gait.stepped (queued by _on_stepped, played here so step() keeps its order); the servo whine on
## lift-off is still polled from each foot's `stepping` flag.
func _step_gait(a: AudioDirector) -> void:
	_bind_gait()
	if _rig == null or _rig.gait == null:
		_step_queue.clear()
		return
	var speed_k := clampf(_body.ground_speed() / maxf(_body.run_speed, 1.0), 0.0, 1.0)
	var bus := AudioDirector.BUS_SFX_PLAYER if _local() else AudioDirector.BUS_SFX_WORLD
	var prof := "local_mech" if _local() else "foley"
	var grounded := _body.grounded()
	for ev: Array in _step_queue:
		if grounded:
			_play_footfall(a, ev[1] as Dictionary, speed_k, prof, bus)
	_step_queue.clear()
	var feet := _rig.gait.feet
	if _prev_stepping.size() != feet.size():
		_prev_stepping.clear()
		for f: Dictionary in feet:
			_prev_stepping.append(bool(f["stepping"]))
		return
	for i in feet.size():
		var now_step := bool(feet[i]["stepping"])
		var was_step := _prev_stepping[i]
		_prev_stepping[i] = now_step
		if not was_step and now_step and grounded and str(feet[i].get("kind", "")) != "land":
			a.play_3d("mech.servo.step", feet[i]["pos"], 0.0, lerpf(0.95, 1.15, speed_k), prof, bus)


## One landed step (Gait.stepped info {kind, length, weight, pos}): stride = speed level scaled by weight; correction /
## settle = clearly quieter, silent below MINOR_MIN_WEIGHT; land = nothing (mech.land.* covers the touchdown).
func _play_footfall(a: AudioDirector, info: Dictionary, speed_k: float, prof: String, bus: String) -> void:
	var kind := str(info.get("kind", "stride"))
	var w := clampf(float(info.get("weight", 1.0)), 0.0, 1.0)
	var fpos: Vector3 = info.get("pos", _body.global_position)
	var db: float
	var pt: float
	match kind:
		"land":
			return
		"stride":
			db = lerpf(-2.0, 1.5, speed_k) + lerpf(STRIDE_MIN_DB, 0.0, w)
			pt = lerpf(0.92, 1.10, speed_k)
		_:   # "correction", "settle"
			if w < MINOR_MIN_WEIGHT:
				return
			db = MINOR_DB + lerpf(-6.0, 0.0, w)
			pt = lerpf(1.02, 1.10, speed_k)
	a.play_3d("mech.step." + surface_at(fpos), fpos, db, pt, prof, bus)


func _on_stepped(foot: int, info: Dictionary) -> void:
	_step_queue.append([foot, info])
	if _step_queue.size() > 8:   # step() not running (no Audio, paused): keep only the latest few
		_step_queue.pop_front()


## Connect to the rig's current Gait (once); rebinds if MechRig replaced it.
func _bind_gait() -> void:
	var g: Gait = _rig.gait if _rig != null else null
	if g == _gait:
		return
	_unbind_gait()
	_gait = g
	if _gait != null and not _gait.stepped.is_connected(_on_stepped):
		_gait.stepped.connect(_on_stepped)


func _unbind_gait() -> void:
	if _gait != null and _gait.stepped.is_connected(_on_stepped):
		_gait.stepped.disconnect(_on_stepped)
	_gait = null
	_step_queue.clear()


## The local player's own mech: is_local, and never a teammate's puppet (MechPuppet sets MechController.puppet).
func _local() -> bool:
	return is_local and not (_body != null and _body.puppet)


func _step_turn_servo(a: AudioDirector, delta: float) -> void:
	_turn_servo_cd = maxf(_turn_servo_cd - delta, 0.0)
	if not _body.shutdown and absf(_body.turn_input) > 0.35 and _turn_servo_cd <= 0.0:
		var bus := AudioDirector.BUS_SFX_PLAYER if _local() else AudioDirector.BUS_SFX_WORLD
		var prof := "local_mech" if _local() else "foley"
		a.play_3d("mech.servo.turn", _body.global_position, 0.0, 1.0, prof, bus)
		_turn_servo_cd = 0.28


func _step_thrusters(a: AudioDirector) -> void:
	var thrusting := _body.thrusting
	var emerg := _body.emergency
	var bus := AudioDirector.BUS_SFX_PLAYER if _local() else AudioDirector.BUS_SFX_WORLD
	var prof := "local_mech" if _local() else "foley"
	if thrusting and not _was_thrusting:
		a.play_3d("mech.thrust.ignite", _body.global_position, 1.5 if emerg else 0.0, 1.15 if emerg else 1.0, prof, bus)
	if emerg and not _was_emergency:
		if _local():
			a.play_2d("mech.thrust.emergency", 0.0, 1.0, AudioDirector.BUS_SFX_TELEGRAPH)
		else:
			a.play_3d("mech.thrust.emergency", _body.global_position, -3.0, 1.0, "telegraph", AudioDirector.BUS_SFX_TELEGRAPH)
	_was_thrusting = thrusting
	_was_emergency = emerg
	var lvl := _fx.level if _fx != null else (1.0 if thrusting else 0.0)
	var tag := _thrust_tag()
	if thrusting or lvl > 0.05:
		var hf := clampf(_body.heat / maxf(_body.heat_cap, 1.0), 0.0, 1.0)
		var db := lerpf(-18.0, 0.5, clampf(lvl, 0.0, 1.0)) + (2.0 if emerg else 0.0)
		var pitch := lerpf(0.90, 1.35, hf) + (0.20 if emerg else 0.0)
		a.start_loop(tag, "mech.thrust.loop", true, _body.global_position, db, pitch, bus, prof)
	elif a.has_loop(tag):
		a.stop_loop(tag)


func _step_landing(a: AudioDirector) -> void:
	var g := _body.grounded()
	if g and not _was_grounded and not _hard_landed_step and _body.last_impact > 2.0:
		var bus := AudioDirector.BUS_SFX_PLAYER if _local() else AudioDirector.BUS_SFX_WORLD
		var prof := "local_mech" if _local() else "foley"
		a.play_3d("mech.land.soft", _body.global_position, 0.0, 1.0, prof, bus)
	_was_grounded = g


func _step_heat(a: AudioDirector, delta: float) -> void:
	if not _local():
		return
	var cap := maxf(_body.heat_cap, 1.0)
	var hf := clampf(_body.heat / cap, 0.0, 1.0)
	var tag := _heat_tag()
	if not _body.shutdown and hf > 0.55:
		var k := (hf - 0.55) / 0.45
		var db := lerpf(-22.0, 0.0, k)
		var pitch := lerpf(0.85, 1.50, k)
		a.start_loop(tag, "mech.heat.loop", false, Vector3.ZERO, db, pitch, AudioDirector.BUS_SFX_PLAYER)
	elif a.has_loop(tag):
		a.stop_loop(tag)
	if not _body.shutdown and hf > 0.80:
		var u := clampf((hf - 0.80) / 0.20, 0.0, 1.0)
		_heat_tick_in -= delta
		if _heat_tick_in <= 0.0:
			a.play_2d("mech.heat.tick", lerpf(-4.0, 1.0, u), lerpf(0.95, 1.28, u), AudioDirector.BUS_SFX_TELEGRAPH)
			_heat_tick_in = lerpf(0.40, 0.14, u)
	else:
		_heat_tick_in = 0.0
	if _body.shutdown and _body.heat <= _body.reboot_heat and not _reboot_spooled:
		_reboot_spooled = true
		a.play_2d("mech.heat.reboot_spool", 0.0, 1.0, AudioDirector.BUS_SFX_PLAYER)
	a.set_heat_duck(_body.shutdown or hf > 0.85)


func _on_hard_landing(_speed: float, severity: float) -> void:
	_hard_landed_step = true
	var a := _audio()
	if a == null or _body == null:
		return
	var bus := AudioDirector.BUS_SFX_PLAYER if _local() else AudioDirector.BUS_SFX_WORLD
	var prof := "local_mech" if _local() else "foley"
	var db := lerpf(-3.0, 2.5, clampf(severity, 0.0, 1.0))
	var pt := lerpf(1.08, 0.86, clampf(severity, 0.0, 1.0))
	a.play_3d("mech.land.hard", _body.global_position, db, pt, prof, bus)
	if _local() and severity >= 0.55:
		a.play_pilot_cue(_head_id())


func _on_overheated() -> void:
	_reboot_spooled = false
	var a := _audio()
	if a == null or _body == null:
		return
	a.stop_loop(_heat_tag())
	if _local():
		a.play_2d("mech.heat.shutdown", 0.0, 1.0, AudioDirector.BUS_SFX_TELEGRAPH)
		a.play_pilot_cue(_head_id())
		a.set_heat_duck(true)
	else:
		a.play_3d("mech.heat.shutdown", _body.global_position, -2.0, 1.0, "weapon", AudioDirector.BUS_SFX_WORLD)


func _on_rebooted() -> void:
	_reboot_spooled = false
	var a := _audio()
	if a == null or _body == null:
		return
	if _local():
		a.play_2d("mech.heat.reboot_ok", 0.0, 1.0, AudioDirector.BUS_SFX_PLAYER)
		a.set_heat_duck(false)
	else:
		a.play_3d("mech.heat.reboot_ok", _body.global_position, -4.0, 1.0, "weapon", AudioDirector.BUS_SFX_WORLD)


## Surface classification under `world_pos`: "rooftop" | "grass" | "concrete".
func surface_at(world_pos: Vector3) -> String:
	if city == null or city.plan == null or city.ring == null:
		return "concrete"
	var arc := city.ring.world_to_arc(city.to_local(world_pos))
	if arc.z > CityPlan.CURB_H + 1.5:
		return "rooftop"
	var pt := Vector2(arc.x, arc.y)
	for b: Dictionary in city.plan.blocks:
		if str(b.get("kind", "")) == "park" and (b["rect"] as Rect2).has_point(pt):
			return "grass"
	for l: Dictionary in city.plan.lots:
		if str(l.get("kind", "")) == "open" and str(l.get("open", "")) in ["park", "garden"]:
			if (l["rect"] as Rect2).has_point(pt):
				return "grass"
	return "concrete"


func _find_city() -> void:
	var root := get_tree().current_scene
	if root == null:
		return
	if "city" in root and root.get("city") is CityDistrict:
		city = root.get("city") as CityDistrict
		return
	for n in root.find_children("*", "CityDistrict", true, false):
		city = n as CityDistrict
		return


func _head_id() -> String:
	if _rig != null and _rig.model != null and _rig.model.head_id != "":
		return _rig.model.head_id
	return "chicken"


func _thrust_tag() -> String:
	return "mech.thrust.%d" % get_instance_id()


func _heat_tag() -> String:
	return "mech.heat.%d" % get_instance_id()


func _audio() -> AudioDirector:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null("Audio") as AudioDirector
