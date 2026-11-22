class_name MusicDirector
extends Node
## Adaptive music stem crossfader & habitat ambience controller (docs/design/audio.md §3, §4).
## Child of AudioDirector (`Audio.music`).
##   Music modes:    "off" | "hangar" | "calm" | "combat"
##                   In "calm" or "combat" mode, calm + combat stems run phase-locked and crossfade by
##                   `combat_intensity` (0..1), which rises via `bump_combat(amount)` and decays after quiet.
##   Ambience modes: "off" | "city" | "hangar"
##                   City mode runs the sunlit curfew HVAC bed + sparse looks_rng one-shots (alien PA chime,
##                   structural creak, breeze flutter).
## Strictly cosmetic (Net LOCAL); uses its own seeded `looks_rng`, never global randf/randi.

const ATTACK_RATE := 1.0        ## intensity/s when climbing
const RELEASE_RATE := 0.25      ## intensity/s when decaying
const HOLD_BEFORE_DECAY := 6.0  ## s after last combat bump before intensity drops
const SILENT_DB := -60.0

var music_mode := "off"
var ambience_mode := "off"
var combat_intensity := 0.0     ## 0 = pure calm occupation .. 1 = full combat layer
var target_intensity := 0.0
var manual_intensity := false   ## true in audio_lab so slider drives intensity directly
var music_trim_db := 0.0
var ambience_trim_db := 0.0
var looks_rng := RandomNumberGenerator.new()

var _director: Node             ## AudioDirector
var _calm_player: AudioStreamPlayer
var _combat_player: AudioStreamPlayer
var _hangar_player: AudioStreamPlayer
var _amb_player: AudioStreamPlayer
var _hold_t := 0.0
var _oneshot_in := 16.0


func _init() -> void:
	name = "MusicDirector"
	looks_rng.seed = 0xBABA11


func net_fields() -> Dictionary:
	return {
		"music_mode": Net.LOCAL, "ambience_mode": Net.LOCAL, "combat_intensity": Net.LOCAL,
		"target_intensity": Net.LOCAL, "manual_intensity": Net.LOCAL, "music_trim_db": Net.LOCAL,
		"ambience_trim_db": Net.LOCAL, "looks_rng": Net.LOCAL, "_director": Net.LOCAL,
		"_calm_player": Net.LOCAL, "_combat_player": Net.LOCAL, "_hangar_player": Net.LOCAL,
		"_amb_player": Net.LOCAL, "_hold_t": Net.LOCAL, "_oneshot_in": Net.LOCAL,
	}


func setup(director: Node) -> void:
	_director = director
	_calm_player = _make_player("MusicCalm", "Music")
	_combat_player = _make_player("MusicCombat", "Music")
	_hangar_player = _make_player("MusicHangar", "Music")
	_amb_player = _make_player("AmbienceBed", "Ambience")


func _make_player(node_name: String, bus_name: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.name = node_name
	p.bus = bus_name
	p.volume_db = SILENT_DB
	add_child(p)
	return p


## Set music mode: "off" | "hangar" | "calm" | "combat".
func set_mode(mode: String) -> void:
	if mode == music_mode:
		return
	music_mode = mode
	if _director == null:
		return
	match mode:
		"hangar":
			_stop_if(_calm_player)
			_stop_if(_combat_player)
			_try_start_music()
		"calm", "combat":
			_stop_if(_hangar_player)
			if mode == "combat":
				target_intensity = 1.0
				combat_intensity = 1.0
				_hold_t = HOLD_BEFORE_DECAY
			elif not manual_intensity:
				target_intensity = 0.0
			_try_start_music()
		_:
			music_mode = "off"
			_stop_if(_hangar_player)
			_stop_if(_calm_player)
			_stop_if(_combat_player)


func _try_start_music() -> void:
	if _director == null:
		return
	match music_mode:
		"hangar":
			if _hangar_player != null and not _hangar_player.playing:
				var s: AudioStreamWAV = _director._fetch_stream("music.hangar")
				if s != null:
					_hangar_player.stream = s
					_hangar_player.volume_db = float(SoundBank.spec("music.hangar").get("db", -7.0)) + music_trim_db
					_hangar_player.play()
		"calm", "combat":
			if _calm_player != null and _combat_player != null and (not _calm_player.playing or not _combat_player.playing):
				var sc: AudioStreamWAV = _director._fetch_stream("music.calm")
				var sb: AudioStreamWAV = _director._fetch_stream("music.combat")
				if sc != null and sb != null:
					_calm_player.stream = sc
					_combat_player.stream = sb
					_calm_player.play(0.0)
					_combat_player.play(0.0)
					_apply_music_mix()


## Set ambience mode: "off" | "city" | "hangar".
func set_ambience(mode: String) -> void:
	if mode == ambience_mode:
		return
	ambience_mode = mode
	if _director == null:
		return
	match mode:
		"city":
			_oneshot_in = looks_rng.randf_range(12.0, 22.0)
			_try_start_ambience()
		"hangar":
			_try_start_ambience()
		_:
			ambience_mode = "off"
			_stop_if(_amb_player)


func _try_start_ambience() -> void:
	if _director == null or _amb_player == null:
		return
	var cid := "amb.city.bed" if ambience_mode == "city" else ("amb.hangar.bed" if ambience_mode == "hangar" else "")
	if cid == "":
		return
	if _amb_player.playing and _amb_player.stream != null:
		return
	var s: AudioStreamWAV = _director._fetch_stream(cid)
	if s != null:
		_amb_player.stream = s
		_amb_player.volume_db = float(SoundBank.spec(cid).get("db", -12.0)) + ambience_trim_db
		_amb_player.play()


## Bump combat intensity (called by CombatAudio on fire, alerts, damage).
func bump_combat(amount: float) -> void:
	if manual_intensity:
		return
	target_intensity = clampf(target_intensity + amount, 0.0, 1.0)
	_hold_t = HOLD_BEFORE_DECAY


func set_intensity(v: float) -> void:
	combat_intensity = clampf(v, 0.0, 1.0)
	target_intensity = combat_intensity
	_apply_music_mix()


func set_trims(music_db: float, ambience_db: float) -> void:
	music_trim_db = music_db
	ambience_trim_db = ambience_db
	_apply_music_mix()
	if ambience_mode == "city" and _amb_player != null:
		_amb_player.volume_db = float(SoundBank.spec("amb.city.bed").get("db", -12.0)) + ambience_trim_db
	elif ambience_mode == "hangar" and _amb_player != null:
		_amb_player.volume_db = float(SoundBank.spec("amb.hangar.bed").get("db", -11.0)) + ambience_trim_db


func _process(delta: float) -> void:
	step(delta)


func step(delta: float) -> void:
	if delta <= 0.0:
		return
	if music_mode != "off":
		_try_start_music()
	if ambience_mode != "off":
		_try_start_ambience()
	if not manual_intensity and (music_mode == "calm" or music_mode == "combat"):
		if _hold_t > 0.0:
			_hold_t = maxf(_hold_t - delta, 0.0)
		elif music_mode == "calm":
			target_intensity = maxf(target_intensity - RELEASE_RATE * delta, 0.0)
	var rate := ATTACK_RATE if target_intensity > combat_intensity else RELEASE_RATE
	var prev := combat_intensity
	combat_intensity = move_toward(combat_intensity, target_intensity, rate * delta)
	if absf(combat_intensity - prev) > 1e-4:
		_apply_music_mix()
	if ambience_mode == "city" and _director != null:
		_oneshot_in -= delta
		if _oneshot_in <= 0.0:
			_oneshot_in = looks_rng.randf_range(14.0, 28.0)
			var choices: Array[String] = ["amb.city.pa_chime", "amb.city.creak", "amb.city.breeze"]
			var pick := choices[looks_rng.randi_range(0, 2)]
			_director.play_2d(pick, ambience_trim_db)


func _apply_music_mix() -> void:
	if _calm_player == null or _combat_player == null:
		return
	if music_mode == "hangar" and _hangar_player != null:
		_hangar_player.volume_db = float(SoundBank.spec("music.hangar").get("db", -7.0)) + music_trim_db
		return
	if music_mode != "calm" and music_mode != "combat":
		return
	var k := clampf(combat_intensity, 0.0, 1.0)
	var calm_base := float(SoundBank.spec("music.calm").get("db", -7.0)) + music_trim_db
	var comb_base := float(SoundBank.spec("music.combat").get("db", -6.0)) + music_trim_db
	# Equal-power crossfade between calm occupation and driving combat layer.
	var calm_lin := cos(k * PI * 0.5)
	var comb_lin := sin(k * PI * 0.5)
	_calm_player.volume_db = calm_base + linear_to_db(maxf(calm_lin, 0.0001)) if calm_lin > 0.01 else SILENT_DB
	_combat_player.volume_db = comb_base + linear_to_db(maxf(comb_lin, 0.0001)) if comb_lin > 0.01 else SILENT_DB


static func _stop_if(p: AudioStreamPlayer) -> void:
	if p != null and p.playing:
		p.stop()
