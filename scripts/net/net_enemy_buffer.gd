class_name NetEnemyBuffer
extends RefCounted
## The interpolation buffer behind one enemy puppet (W4; NetPuppetBuffer's little sibling): the host's samples, shown
## `delay` behind the shared clock so the puppet sits between two samples.
##
##   position, lock   linear (enemies carry no velocity: they are slow, and the 20 Hz stream is dense while they move)
##   yaw, aim yaw     the short way round; aim pitch, heat, kick linear
##   state, flags, hp a step: the earlier sample's
##
## Past the newest sample it extrapolates along the last two samples' motion for up to EXTRAP_MAX, then holds (an idle
## enemy's keep-alive comes every 1 / IDLE_RATE s and it does not move). The delay adapts like NetPuppetBuffer's: the
## 90th percentile of arrival lag plus MARGIN, within DELAY..DELAY_MAX, slewed at SLEW s/s.

const DELAY := 0.10
const DELAY_MAX := 0.40
const MARGIN := 0.03
const EXTRAP_MAX := 0.15
const KEEP := 16
const LAG_WINDOW := 40
const WARMUP := 6
const SLEW := 0.10
const MOTION_GAP := 0.3           ## s: two samples further apart than this give no extrapolation velocity

var delay := DELAY
var samples: Array[NetEnemyState] = []
var accepted := 0
var refused := 0
var starved := 0

var _lags: Array[float] = []
var _target := DELAY


## Add a sample that arrived at `arrival` (host_time seconds). False when it is not newer than what we have.
func push(s: NetEnemyState, arrival: float) -> bool:
	if not samples.is_empty() and s.t <= samples[samples.size() - 1].t + 0.0001:
		refused += 1
		return false
	samples.append(s)
	if samples.size() > KEEP:
		samples.remove_at(0)
	accepted += 1
	_lags.append(maxf(arrival - s.t, 0.0))
	if _lags.size() > LAG_WINDOW:
		_lags.remove_at(0)
	var sorted := _lags.duplicate()
	sorted.sort()
	var p90: float = sorted[mini(int(float(sorted.size()) * 0.9), sorted.size() - 1)]
	_target = clampf(p90 + MARGIN, DELAY, DELAY_MAX)
	if accepted <= WARMUP:
		delay = _target
	return true


func newest() -> NetEnemyState:
	return samples[samples.size() - 1] if not samples.is_empty() else null


func step_delay(dt: float) -> void:
	var step := SLEW * dt
	delay += clampf(_target - delay, -step, step)


## The state to show at shared-clock time `t`, or null with no samples. A new object every call.
func sample(t: float) -> NetEnemyState:
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
		s.t = t
		if samples.size() >= 2:
			var prev := samples[samples.size() - 2]
			var h := last.t - prev.t
			if h > 0.0001 and h <= MOTION_GAP:
				var ahead := minf(t - last.t, EXTRAP_MAX)
				s.pos += (last.pos - prev.pos) / h * ahead
		return s
	var i := samples.size() - 2
	while i > 0 and samples[i].t > t:
		i -= 1
	var a := samples[i]
	var b := samples[i + 1]
	var u := clampf((t - a.t) / maxf(b.t - a.t, 0.0001), 0.0, 1.0)
	var out := a.copy()
	out.t = t
	out.pos = a.pos.lerp(b.pos, u)
	out.yaw = lerp_angle(a.yaw, b.yaw, u)
	out.aim = Vector2(lerp_angle(a.aim.x, b.aim.x, u), lerpf(a.aim.y, b.aim.y, u))
	out.heat = lerpf(a.heat, b.heat, u)
	out.kick = lerpf(a.kick, b.kick, u)
	out.lock = a.lock.lerp(b.lock, u)
	return out
