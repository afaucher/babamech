class_name AudioLab
extends Node3D
## Lab subject "audio" (docs/design/audio.md §5): interactive soundboard and 3D mix audition rig.
## Shows a mech stand at origin, a glowing 3D sound-emitter beacon at (0, 2, -distance) with 25/50/100/200 m distance
## rings, and a live readout of active voices, bus ducking, heat, and music intensity.
## Implements the LabRegistry contract (`lab_params`, `set_lab_param`, `lab_options`, `set_lab_option`, `lab_focus`,
## `lab_radius`, `time_scale`). Cosmetic only (Net LOCAL).

const TRIGGER_MODES := ["off", "once", "repeat"]
const SURFACES := ["concrete", "grass", "rooftop"]
const TELEGRAPHS := ["off", "beam", "cannon", "mortar", "pulse", "rush"]
const AMBIENCES := ["off", "city", "hangar"]
const MUSICS := ["off", "hangar", "calm", "combat"]
const PILOT_MODES := ["on", "off"]
const REPEAT_EVERY := 1.35

var time_scale := 1.0
var distance := 18.0
var heat := 0.0
var thrust := 0.0
var combat_intensity := 0.0
var telegraph_dur := 0.60
var impact_radius := 2.5
var sfx_trim := 1.0
var music_trim := 1.0

var cue := "wpn.autocannon.fire"
var trigger_mode := "off"
var surface := "concrete"
var telegraph := "off"
var ambience := "off"
var music_mode := "off"
var pilot_cues := "on"

var _mech: MechModel
var _beacon: MeshInstance3D
var _label: Label3D
var _t := 0.0
var _repeat_t := 0.0
var _heat_tick_t := 0.0
var _pulse := 0.0
var _last_played := "(none)"


func net_fields() -> Dictionary:
	return {
		"time_scale": Net.LOCAL, "distance": Net.LOCAL, "heat": Net.LOCAL, "thrust": Net.LOCAL,
		"combat_intensity": Net.LOCAL, "telegraph_dur": Net.LOCAL, "impact_radius": Net.LOCAL,
		"sfx_trim": Net.LOCAL, "music_trim": Net.LOCAL, "cue": Net.LOCAL, "trigger_mode": Net.LOCAL,
		"surface": Net.LOCAL, "telegraph": Net.LOCAL, "ambience": Net.LOCAL, "music_mode": Net.LOCAL,
		"pilot_cues": Net.LOCAL, "_mech": Net.LOCAL, "_beacon": Net.LOCAL, "_label": Net.LOCAL,
		"_t": Net.LOCAL, "_repeat_t": Net.LOCAL, "_heat_tick_t": Net.LOCAL, "_pulse": Net.LOCAL,
		"_last_played": Net.LOCAL,
	}


func _ready() -> void:
	_build_stage()
	_sync_beacon()


func _exit_tree() -> void:
	var a := _audio()
	if a != null:
		a.stop_loop(_thrust_tag())
		a.stop_loop(_heat_tag())
		a.set_heat_duck(false)
		if a.music != null:
			a.music.manual_intensity = false
			a.music.set_mode("off")
			a.music.set_ambience("off")
			a.music.set_trims(0.0, 0.0)


func _build_stage() -> void:
	# Plinth + low-poly mech silhouette at origin.
	add_child(MechParts.box(Vector3(4.2, 0.4, 4.2), MechMeshes.GUN, Vector3(0.0, 0.2, 0.0)))
	_mech = MechModel.new()
	_mech.position = Vector3(0.0, 0.4, 0.0)
	_mech.configure("chicken", "strider", MechCatalog.chassis("strider")["default_loadout"])
	add_child(_mech)
	# Distance guide markers along -Z (25, 50, 100, 200 m).
	for d: float in [25.0, 50.0, 100.0, 200.0]:
		var bar := MechParts.box(Vector3(14.0, 0.04, 0.35), Color(0.9, 0.55, 0.18), Vector3(0.0, 0.03, -d))
		add_child(bar)
	# Glowing 3D emitter beacon that moves along -Z with `distance`.
	_beacon = MechParts.sphere(0.85, Color(0.25, 0.92, 0.95), Vector3(0.0, 2.2, -distance), 12)
	_beacon.material_override = MechParts.mat(Color(0.25, 0.92, 0.95), 1.0, true)
	add_child(_beacon)
	# Floating live audio diagnostic readout (offset toward open right viewport, clear of the left Lab panel).
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.fixed_size = true
	_label.pixel_size = 0.00056
	_label.font_size = 22
	_label.outline_size = 8
	_label.no_depth_test = true
	_label.position = Vector3(-1.6, 5.8, -3.0)
	add_child(_label)


func _process(delta: float) -> void:
	var dt := delta * time_scale
	_t += dt
	_pulse = maxf(_pulse - dt * 3.0, 0.0)
	_sync_beacon()
	var a := _audio()
	if a == null or dt <= 0.0:
		_update_label(a)
		return
	# Repeat audition timer.
	if trigger_mode == "repeat":
		_repeat_t -= dt
		if _repeat_t <= 0.0:
			_repeat_t = REPEAT_EVERY
			trigger_now()
	# Continuous thruster audition loop.
	var t_tag := _thrust_tag()
	if thrust > 0.03:
		var hf := clampf(heat / 100.0, 0.0, 1.0)
		a.start_loop(t_tag, "mech.thrust.loop", true, _emitter_pos(), lerpf(-18.0, 0.5, thrust), lerpf(0.90, 1.35, hf),
			AudioDirector.BUS_SFX_PLAYER, "local_mech")
	elif a.has_loop(t_tag):
		a.stop_loop(t_tag)
	# Continuous heat turbine & >80% warning tick audition.
	var h_tag := _heat_tag()
	var h_frac := clampf(heat / 100.0, 0.0, 1.0)
	if h_frac > 0.55:
		var k := (h_frac - 0.55) / 0.45
		a.start_loop(h_tag, "mech.heat.loop", false, Vector3.ZERO, lerpf(-22.0, 0.0, k), lerpf(0.85, 1.50, k),
			AudioDirector.BUS_SFX_PLAYER)
	elif a.has_loop(h_tag):
		a.stop_loop(h_tag)
	if h_frac > 0.80:
		var u := clampf((h_frac - 0.80) / 0.20, 0.0, 1.0)
		_heat_tick_t -= dt
		if _heat_tick_t <= 0.0:
			a.play_2d("mech.heat.tick", lerpf(-4.0, 1.0, u), lerpf(0.95, 1.28, u), AudioDirector.BUS_SFX_TELEGRAPH)
			_heat_tick_t = lerpf(0.40, 0.14, u)
	else:
		_heat_tick_t = 0.0
	a.set_heat_duck(h_frac > 0.85)
	_update_label(a)


## Audition the currently selected telegraph or cue at the beacon's 3D distance.
func trigger_now() -> void:
	var a := _audio()
	if a == null:
		return
	var pos := _emitter_pos()
	var sfx_db := linear_to_db(maxf(sfx_trim, 0.001)) if sfx_trim < 0.999 else 0.0
	if telegraph != "off":
		a.play_enemy_telegraph("audio_lab", telegraph, pos, telegraph_dur)
		_last_played = "enemy.telegraph." + telegraph
		_pulse = 1.0
		return
	var target_cue := cue
	if target_cue.begins_with("mech.step."):
		target_cue = "mech.step." + surface
	if target_cue.begins_with("impact.explosive"):
		target_cue = "impact.explosive.large" if impact_radius >= 4.5 else "impact.explosive.med"
	var sp := SoundBank.spec(target_cue)
	if str(sp.get("profile", "weapon")) == "2d":
		a.play_2d(target_cue, sfx_db)
	else:
		a.play_3d(target_cue, pos, sfx_db)
	_last_played = target_cue
	_pulse = 1.0


func _emitter_pos() -> Vector3:
	return Vector3(0.0, 2.2, -distance)


func _sync_beacon() -> void:
	if _beacon == null:
		return
	_beacon.position = _emitter_pos()
	var sc := 1.0 + 0.45 * _pulse + 0.08 * sin(_t * 4.0)
	_beacon.scale = Vector3.ONE * sc


func _update_label(a: AudioDirector) -> void:
	if _label == null:
		return
	var v2 := a.active_2d_count() if a != null else 0
	var v3 := a.active_3d_count() if a != null else 0
	var vl := a.active_loop_count() if a != null else 0
	var dw := a.duck_world_db() if a != null else 0.0
	var dm := a.duck_music_db() if a != null else 0.0
	_label.text = "AUDIO LAB   dist %.0f m   heat %.0f%%\nLast: %s   Voices 2D:%d 3D:%d Loops:%d\nDuck world %.1f dB   music %.1f dB   intensity %.2f" % [
		distance, heat, _last_played, v2, v3, vl, dw, dm, combat_intensity]


# --- Lab contract ---------------------------------------------------------------------------------------

func lab_params() -> Array:
	return [
		{"id": "distance", "label": "Emitter distance (m)", "min": 0.0, "max": 220.0, "value": distance},
		{"id": "heat", "label": "Mech heat (%)", "min": 0.0, "max": 100.0, "value": heat},
		{"id": "thrust", "label": "Thruster level", "min": 0.0, "max": 1.0, "value": thrust},
		{"id": "combat_intensity", "label": "Combat intensity", "min": 0.0, "max": 1.0, "value": combat_intensity},
		{"id": "telegraph_dur", "label": "Telegraph duration (s)", "min": 0.3, "max": 1.5, "value": telegraph_dur},
		{"id": "impact_radius", "label": "Impact radius (m)", "min": 1.0, "max": 8.0, "value": impact_radius},
		{"id": "sfx_trim", "label": "SFX trim", "min": 0.0, "max": 1.0, "value": sfx_trim},
		{"id": "music_trim", "label": "Music trim", "min": 0.0, "max": 1.0, "value": music_trim},
	]


func set_lab_param(id: String, value: float) -> void:
	match id:
		"distance": distance = clampf(value, 0.0, 220.0)
		"heat": heat = clampf(value, 0.0, 100.0)
		"thrust": thrust = clampf(value, 0.0, 1.0)
		"combat_intensity":
			combat_intensity = clampf(value, 0.0, 1.0)
			var a := _audio()
			if a != null and a.music != null:
				a.music.manual_intensity = true
				a.music.set_intensity(combat_intensity)
		"telegraph_dur": telegraph_dur = clampf(value, 0.3, 1.5)
		"impact_radius": impact_radius = clampf(value, 1.0, 8.0)
		"sfx_trim": sfx_trim = clampf(value, 0.0, 1.0)
		"music_trim":
			music_trim = clampf(value, 0.0, 1.0)
			var a := _audio()
			if a != null and a.music != null:
				var db := linear_to_db(maxf(music_trim, 0.0001)) if music_trim < 0.999 else 0.0
				a.music.set_trims(db, 0.0)
	_sync_beacon()


func lab_options() -> Array:
	return [
		{"id": "cue", "label": "Sound cue", "choices": SoundBank.all_ids(), "value": cue},
		{"id": "trigger", "label": "Trigger", "choices": TRIGGER_MODES, "value": trigger_mode},
		{"id": "surface", "label": "Footstep surface", "choices": SURFACES, "value": surface},
		{"id": "telegraph", "label": "Enemy telegraph", "choices": TELEGRAPHS, "value": telegraph},
		{"id": "ambience", "label": "Ambience", "choices": AMBIENCES, "value": ambience},
		{"id": "music", "label": "Music layer", "choices": MUSICS, "value": music_mode},
		{"id": "pilot_cues", "label": "Deadpan pilot cues", "choices": PILOT_MODES, "value": pilot_cues},
	]


func set_lab_option(id: String, value: String) -> void:
	var a := _audio()
	match id:
		"cue":
			if SoundBank.has_cue(value):
				cue = value
				if trigger_mode != "off":
					trigger_now()
		"trigger":
			trigger_mode = value if value in TRIGGER_MODES else "off"
			if trigger_mode == "once":
				trigger_now()
				trigger_mode = "off"
			elif trigger_mode == "repeat":
				_repeat_t = 0.0
		"surface":
			surface = value if value in SURFACES else "concrete"
		"telegraph":
			telegraph = value if value in TELEGRAPHS else "off"
			if telegraph != "off" and trigger_mode != "off":
				trigger_now()
		"ambience":
			ambience = value if value in AMBIENCES else "off"
			if a != null and a.music != null:
				a.music.set_ambience(ambience)
		"music":
			music_mode = value if value in MUSICS else "off"
			if a != null and a.music != null:
				a.music.manual_intensity = true
				a.music.set_mode(music_mode)
				if music_mode == "calm" or music_mode == "combat":
					a.music.set_intensity(1.0 if music_mode == "combat" else combat_intensity)
		"pilot_cues":
			pilot_cues = value if value in PILOT_MODES else "on"
			if a != null:
				a.pilot_cues_enabled = (pilot_cues == "on")


func lab_focus() -> Vector3:
	return Vector3(2.2, 2.5, -1.5)   # shifted so the mech and Label3D sit clear of the 380 px left panel


func lab_radius() -> float:
	return 8.5


func _thrust_tag() -> String:
	return "audiolab.thrust.%d" % get_instance_id()


func _heat_tag() -> String:
	return "audiolab.heat.%d" % get_instance_id()


func _audio() -> AudioDirector:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null("Audio") as AudioDirector
