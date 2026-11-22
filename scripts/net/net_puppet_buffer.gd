class_name NetPuppetBuffer
extends RefCounted
## The interpolation buffer behind one puppet mech (co-op step 2; cast's NetInterp): the owner's snapshot samples,
## shown about DELAY behind the shared clock so the puppet is always BETWEEN two samples and moves on smoothly through a
## lost or late packet.
##
##   position   cubic Hermite on all three axes from the samples' positions AND velocities (the deck curves, so "up"
##              is not one axis); linear across a stall (samples more than LINEAR_GAP apart)
##   velocity, leg_yaw, heat, aim, impact   linear
##   yaw        the short way round
##   flags      (grounded, thrust, emergency, shutdown, hover, designator) a step: the earlier sample's
##
## Past the newest sample (a packet late or lost) the puppet extrapolates along the last velocity for up to EXTRAP_MAX,
## then holds. A TELEPORT (the sample's counter changed: a respawn) empties the buffer, so the puppet jumps to the new
## spot and never slides across the gap (take_teleport tells the game to re-plant the feet).
##
## The delay adapts: the 90th percentile of how late samples arrive (arrival minus sample time) plus MARGIN, never below
## DELAY, slewed at SLEW s/s. A direct stream on a good link sits at DELAY; a mech forwarded through the host (two hops)
## or a bad link gets the room it needs.

const DELAY := 0.10
const DELAY_MAX := 0.40
const MARGIN := 0.03
const EXTRAP_MAX := 0.15
const KEEP := 24
const LAG_WINDOW := 60
const WARMUP := 8
const SLEW := 0.10
const LINEAR_GAP := 0.25

var delay := DELAY
var samples: Array[NetMechState] = []
var teleports := 0
var accepted := 0
var refused := 0
## Times sample() ran past the newest sample (extrapolating or holding).
var starved := 0

var _lags: Array[float] = []
var _tp := -1
var _teleported := false
var _target := DELAY


## Add a sample that arrived at `arrival` (host_time seconds). False when it is not newer than what we have.
func push(s: NetMechState, arrival: float) -> bool:
	if not samples.is_empty() and s.t <= samples[samples.size() - 1].t + 0.0001:
		refused += 1
		return false
	if _tp != -1 and s.tp != _tp:
		samples.clear()
		teleports += 1
		_teleported = true
	_tp = s.tp
	samples.append(s)
	if samples.size() > KEEP:
		samples.remove_at(0)
	accepted += 1
	_lags.append(maxf(arrival - s.t, 0.0))
	if _lags.size() > LAG_WINDOW:
		_lags.remove_at(0)
	_target = _compute_target()
	if accepted <= WARMUP:
		delay = _target
	return true


## True once after a teleport sample was pushed.
func take_teleport() -> bool:
	var t := _teleported
	_teleported = false
	return t


func newest() -> NetMechState:
	return samples[samples.size() - 1] if not samples.is_empty() else null


func clear() -> void:
	samples.clear()
	_lags.clear()
	_tp = -1
	_teleported = false
	_target = DELAY
	delay = DELAY
	accepted = 0


## Move the delay toward its target by `dt` seconds' worth of slewing.
func step_delay(dt: float) -> void:
	var step := SLEW * dt
	delay += clampf(_target - delay, -step, step)


func _compute_target() -> float:
	if _lags.is_empty():
		return DELAY
	var sorted := _lags.duplicate()
	sorted.sort()
	var p90: float = sorted[mini(int(float(sorted.size()) * 0.9), sorted.size() - 1)]
	return clampf(p90 + MARGIN, DELAY, DELAY_MAX)


## The state to show at shared-clock time `t`, or null with no samples. A new object every call.
func sample(t: float) -> NetMechState:
	if samples.is_empty():
		return null
	var first := samples[0]
	if t <= first.t:
		var s0 := first.copy()
		s0.t = t
		return s0
	var last := samples[samples.size() - 1]
	if t >= last.t:
		starved += 1
		var s := last.copy()
		s.pos += last.vel * minf(t - last.t, EXTRAP_MAX)
		s.t = t
		return s
	var i := samples.size() - 2
	while i > 0 and samples[i].t > t:
		i -= 1
	var a := samples[i]
	var b := samples[i + 1]
	var h := b.t - a.t
	var u := clampf((t - a.t) / maxf(h, 0.0001), 0.0, 1.0)
	var out := a.copy()
	out.t = t
	if h > LINEAR_GAP:
		out.pos = a.pos.lerp(b.pos, u)
	else:
		for c in 3:
			out.pos[c] = hermite(a.pos[c], a.vel[c], b.pos[c], b.vel[c], h, u)
	out.vel = a.vel.lerp(b.vel, u)
	out.yaw = lerp_angle(a.yaw, b.yaw, u)
	out.leg_yaw = lerpf(a.leg_yaw, b.leg_yaw, u)
	out.heat = lerpf(a.heat, b.heat, u)
	out.last_impact = b.last_impact if u > 0.5 else a.last_impact
	out.aim = a.aim.lerp(b.aim, u)
	return out


## Cubic Hermite: positions p0 / p1, velocities v0 / v1 (per second), samples h seconds apart, u in 0..1.
static func hermite(p0: float, v0: float, p1: float, v1: float, h: float, u: float) -> float:
	var u2 := u * u
	var u3 := u2 * u
	return (2.0 * u3 - 3.0 * u2 + 1.0) * p0 + (u3 - 2.0 * u2 + u) * v0 * h \
			+ (-2.0 * u3 + 3.0 * u2) * p1 + (u3 - u2) * v1 * h
