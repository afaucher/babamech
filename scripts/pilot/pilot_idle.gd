class_name PilotIdle
extends RefCounted
## Idle life for a pilot head (docs/design/pilot-heads.md section 5): seeded blinks (some double), glances (a look target
## in the front cone, held a while) and the head's own tics, all from its own RandomNumberGenerator seeded from the head
## id and the seed (a look generator: never the mission generator, never the global one). Same seed + same steps = same
## idle, which the tests rely on. Blinks always run; glances and tics only once the head has been calm for CALM_TIME
## (or always, in the menu / hangar: `always`).
##
## Tics are data in the head definition (PilotFace.tics), each a Dictionary with "id", "kind" and:
##   kind "pulse": "a" / "h" / "r" seconds, "neck" Vector3 degrees (pitch, yaw, roll) at the peak, optional "push"
##                 (metres), "lift" (metres, + = the head rises, - = sinks), "flair" Vector2 degrees, "ch" {channel:
##                 delta} - all scaled by the envelope. Optional: "pulses" N (the envelope repeats N times, "gap"
##                 seconds apart: a double quack, three sniffs), "ch_hz" (the channel deltas flutter at this rate between
##                 40 % and 100 %: nibbling, panting), "wobble" {"from", "dur", "hz", "neck" Vector3 deg, "flair" Vector2
##                 deg} (a fading oscillation starting "from" seconds in: a waggle as it settles).
##   kind "steps": "steps" count, "step_time" seconds, "yaw" / "pitch" degrees: the look jumps to a random point each
##                 step (bird saccades), then back to centre.
##   kind "shake": "dur" seconds, "hz", "neck" Vector3 degrees and "flair" Vector2 degrees of oscillation amplitude,
##                 fading out over the duration; optional "lift" (metres) oscillates with it.
## Cosmetic only (Net.LOCAL).

const CALM_TIME := 4.0
const BLINK_MIN := 2.5
const BLINK_MAX := 6.0
const DOUBLE_CHANCE := 0.15
const DOUBLE_GAP := 0.2
const GLANCE_MIN := 4.0
const GLANCE_MAX := 9.0
const GLANCE_HOLD := Vector2(0.5, 1.5)
const GLANCE_CONE := Vector2(deg_to_rad(40.0), deg_to_rad(15.0))
const TIC_MIN := 6.0
const TIC_MAX := 14.0
## Darting (afraid): glances come every DART_EVERY seconds, held DART_HOLD, from a wider cone.
const DART_EVERY := Vector2(0.3, 0.8)
const DART_HOLD := Vector2(0.15, 0.35)
const DART_CONE := Vector2(deg_to_rad(55.0), deg_to_rad(20.0))

var rng := RandomNumberGenerator.new()
var tics: Array = []

# Outputs, valid after step().
var glance := Vector2.ZERO      ## look (yaw, pitch), radians
var glance_on := false
var neck := Vector3.ZERO        ## (pitch, yaw, roll) radians
var push := 0.0
var lift := 0.0                 ## metres, + = head rises (PilotHead takes it off the sink)
var flair := Vector2.ZERO       ## (pitch, roll) radians
var channels := {}
var tic_id := ""                ## the tic playing, "" when none

var calm_time := 0.0
var _blink_t := 0.0
var _double_t := -1.0
var _glance_t := 0.0
var _hold_t := 0.0
var _tic_t := 0.0
var _tic: Dictionary = {}
var _tic_age := 0.0
var _steps: Array[Vector2] = []


func setup(head_id: String, seed: int, head_tics: Array) -> void:
	rng.seed = hash("%s:%d" % [head_id, seed])
	tics = head_tics
	_blink_t = rng.randf_range(0.5, BLINK_MAX)
	_glance_t = rng.randf_range(GLANCE_MIN * 0.5, GLANCE_MAX)
	_tic_t = rng.randf_range(TIC_MIN * 0.5, TIC_MAX)


## Advance by dt. `calm`: no reaction, no combat state this frame. `always`: menu / hangar, tics regardless of calm.
## `dart` 0..1: afraid darting glances. Returns the reactions to fire now (blinks).
func step(dt: float, calm: bool, always: bool, dart: float = 0.0) -> Array[String]:
	var fire: Array[String] = []
	calm_time = calm_time + dt if calm else 0.0
	var relaxed := always or calm_time >= CALM_TIME
	# Blinks.
	_blink_t -= dt
	if _blink_t <= 0.0:
		fire.append("blink")
		_blink_t = rng.randf_range(BLINK_MIN, BLINK_MAX)
		if rng.randf() < DOUBLE_CHANCE:
			_double_t = DOUBLE_GAP
	if _double_t >= 0.0:
		_double_t -= dt
		if _double_t < 0.0:
			fire.append("blink")
	# Glances (and darting).
	var darting := dart > 0.5
	if glance_on:
		_hold_t -= dt
		if _hold_t <= 0.0:
			glance_on = false
			glance = Vector2.ZERO
	_glance_t -= dt
	if _glance_t <= 0.0:
		if darting:
			glance = Vector2(rng.randf_range(-1.0, 1.0) * DART_CONE.x, rng.randf_range(-1.0, 1.0) * DART_CONE.y)
			_hold_t = rng.randf_range(DART_HOLD.x, DART_HOLD.y)
			glance_on = true
			_glance_t = rng.randf_range(DART_EVERY.x, DART_EVERY.y)
		else:
			if relaxed and _tic.is_empty():
				glance = Vector2(rng.randf_range(-1.0, 1.0) * GLANCE_CONE.x, rng.randf_range(-1.0, 1.0) * GLANCE_CONE.y)
				_hold_t = rng.randf_range(GLANCE_HOLD.x, GLANCE_HOLD.y)
				glance_on = true
			_glance_t = rng.randf_range(GLANCE_MIN, GLANCE_MAX)
	# Tics.
	if _tic.is_empty():
		_tic_t -= dt
		if _tic_t <= 0.0:
			_tic_t = rng.randf_range(TIC_MIN, TIC_MAX)
			if relaxed and not tics.is_empty() and not darting:
				_start_tic(tics[rng.randi_range(0, tics.size() - 1)])
	else:
		_tic_age += dt
	_tic_output()
	return fire


## Starts a tic now (the lab and tests use this; the idle picks them on its own otherwise).
func play_tic(id: String) -> bool:
	for t: Dictionary in tics:
		if t.get("id", "") == id:
			_start_tic(t)
			_tic_output()
			return true
	return false


func _start_tic(t: Dictionary) -> void:
	_tic = t
	_tic_age = 0.0
	tic_id = str(t.get("id", ""))
	_steps.clear()
	if t.get("kind", "") == "steps":
		for i in int(t.get("steps", 3)):
			_steps.append(Vector2(rng.randf_range(-1.0, 1.0) * deg_to_rad(float(t.get("yaw", 30.0))),
				rng.randf_range(-1.0, 1.0) * deg_to_rad(float(t.get("pitch", 10.0)))))


func _tic_output() -> void:
	neck = Vector3.ZERO
	push = 0.0
	lift = 0.0
	flair = Vector2.ZERO
	channels = {}
	if _tic.is_empty():
		return
	var t := _tic
	var age := _tic_age
	var done := false
	match str(t.get("kind", "pulse")):
		"steps":
			var st := float(t.get("step_time", 0.3))
			var i := int(floor(age / st))
			if i >= _steps.size():
				done = true
			else:
				glance = _steps[i]
				glance_on = true
				_hold_t = st - fmod(age, st)
		"shake":
			var dur := float(t.get("dur", 0.6))
			if age >= dur:
				done = true
			else:
				var s := sin(TAU * float(t.get("hz", 6.0)) * age) * (1.0 - age / dur)
				neck = (t.get("neck", Vector3.ZERO) as Vector3) * deg_to_rad(1.0) * s
				flair = (t.get("flair", Vector2.ZERO) as Vector2) * deg_to_rad(1.0) * s
				lift = float(t.get("lift", 0.0)) * s
		_:
			var a := float(t.get("a", 0.1))
			var h := float(t.get("h", 0.1))
			var r := float(t.get("r", 0.2))
			var n := maxi(int(t.get("pulses", 1)), 1)
			var period := a + h + r + float(t.get("gap", 0.0))
			var total := period * float(n) - float(t.get("gap", 0.0))
			var wob: Dictionary = t.get("wobble", {})
			if not wob.is_empty():
				total = maxf(total, float(wob.get("from", 0.0)) + float(wob.get("dur", 0.0)))
			if age >= total:
				done = true
			else:
				var e := 0.0
				if age < period * float(n):
					e = PilotExpressions.envelope(fmod(age, period), a, h, r)
				neck = (t.get("neck", Vector3.ZERO) as Vector3) * deg_to_rad(1.0) * e
				push = float(t.get("push", 0.0)) * e
				lift = float(t.get("lift", 0.0)) * e
				flair = (t.get("flair", Vector2.ZERO) as Vector2) * deg_to_rad(1.0) * e
				var ce := e
				if float(t.get("ch_hz", 0.0)) > 0.0:
					ce *= 0.4 + 0.6 * absf(sin(PI * float(t["ch_hz"]) * age))
				var ch: Dictionary = t.get("ch", {})
				for c: String in ch:
					channels[c] = float(ch[c]) * ce
				if not wob.is_empty():
					var w := age - float(wob.get("from", 0.0))
					var dur := float(wob.get("dur", 0.5))
					if w > 0.0 and w < dur:
						var ws := sin(TAU * float(wob.get("hz", 5.0)) * w) * (1.0 - w / dur)
						neck += (wob.get("neck", Vector3.ZERO) as Vector3) * deg_to_rad(1.0) * ws
						flair += (wob.get("flair", Vector2.ZERO) as Vector2) * deg_to_rad(1.0) * ws
	if done:
		if str(t.get("kind", "")) == "steps":
			glance_on = false
			glance = Vector2.ZERO
		_tic = {}
		tic_id = ""
		neck = Vector3.ZERO
		push = 0.0
		lift = 0.0
		flair = Vector2.ZERO
		channels = {}
