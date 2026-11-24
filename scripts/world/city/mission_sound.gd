class_name MissionSound
extends RefCounted
## In-world sounds of MissionWorld's pieces (docs/design/pacing-director.md 1.6a; docs/design/city-ramps-and-stack.md
## "Gate alarm"). Diegetic only: positional AudioStreamPlayer3D on the piece itself, never a 2D / HUD sound.
## Cosmetic, no network, no randomness: the klaxon is synthesised once, deterministically, and cached.
##
## PLACEHOLDER: the gate klaxon is a procedural two-tone (hi-lo) horn until a real siren sample exists.

const BUS := "SFX_World"         ## the world SFX bus (AudioDirector.BUS_SFX_WORLD); Master when it does not exist (tests)
const SR := 22050
const HALF := 0.6                ## s per tone; 2 tones = one 1.2 s loop
const TONES: Array[float] = [585.0, 440.0]    ## Hz; f * HALF is a whole number of cycles, so every tone starts at phase 0 (no click)
const HARMONICS := 6             ## band-limited saw: harmonics 1..6 at 1/k
const TABLE := 2048              ## samples in the one-cycle wavetable
const SIREN_UNIT := 20.0         ## m: inverse-distance reference (full level inside ~20 m, -12 dB at ~80 m)
const SIREN_MAX := 140.0         ## m: silent beyond (across a deck's street)
const SIREN_DB := -4.0           ## base level
const SIREN_MAX_DB := 3.0        ## cap close up
const SIREN_UP := 4.0            ## m above the gate floor, mid-opening

static var _klaxon: AudioStreamWAV


## The looping two-tone klaxon (built on first use, then shared).
static func klaxon() -> AudioStreamWAV:
	if _klaxon != null:
		return _klaxon
	var table := PackedFloat32Array()
	table.resize(TABLE)
	var peak := 0.0
	for i in TABLE:
		var p := TAU * float(i) / float(TABLE)
		var s := 0.0
		for k in range(1, HARMONICS + 1):
			s += sin(p * float(k)) / float(k)
		table[i] = s
		peak = maxf(peak, absf(s))
	var per := int(round(HALF * float(SR)))
	var b := PackedFloat32Array()
	b.resize(per * TONES.size())
	for h in TONES.size():
		var f: float = TONES[h]
		for i in per:
			var ph := fposmod(f * float(i) / float(SR), 1.0) * float(TABLE)
			var j := int(ph)
			var fr := ph - float(j)
			var v := lerpf(table[j % TABLE], table[(j + 1) % TABLE], fr) / peak
			b[h * per + i] = tanh(v * 1.4) * 0.8          # a little horn grit
	_klaxon = AudioSynth.to_wav(b, SR, true)
	return _klaxon


## The length of one klaxon loop (s).
static func klaxon_length() -> float:
	return HALF * float(TONES.size())


## A siren for a gate door of height gh (local position: mid-opening, SIREN_UP m up, just in front of the wall plane).
static func gate_siren(gh: float) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.name = "Siren"
	p.stream = klaxon()
	p.position = Vector3(0.0, minf(SIREN_UP, gh * 0.5), 1.0)
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	p.unit_size = SIREN_UNIT
	p.max_distance = SIREN_MAX
	p.volume_db = SIREN_DB
	p.max_db = SIREN_MAX_DB
	p.attenuation_filter_cutoff_hz = 6000.0
	p.bus = bus()
	return p


## The bus to play on now (the world SFX bus once AudioDirector made it, else Master).
static func bus() -> String:
	return BUS if AudioServer.get_bus_index(BUS) >= 0 else "Master"


## Start (at the shared clock's phase: every machine hears the same tone at the same moment) or stop a siren. The caller
## calls it on a change only (it keeps its own flag: the dummy audio driver of a headless run need not report `playing`).
static func set_siren(p: AudioStreamPlayer3D, on: bool, t: float) -> void:
	if p == null or not is_instance_valid(p):
		return
	if on:
		p.bus = bus()
		if p.is_inside_tree():
			p.play(fposmod(t, klaxon_length()))
	else:
		p.stop()
