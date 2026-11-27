class_name PacingStats
extends RefCounted
## Pacing numbers over one stretch of a mission (a deck, or the whole mission) for the combat log's `deck_sum` and `end`
## records (docs/design/pacing-research.md 8.6, targets 8.2). PURE: the caller feeds times and values (CombatLog), no node
## access, no clock. Accumulates numbers only; body() builds the string once, when the record prints.
##   share of time with someone engaged; longest stretch with nobody engaged and every one over QUIET_LIST s (start + dur);
##   peaks (crew intensity crossing PEAK_ON upward, re-armed once it fell under PEAK_REARM: the director's fade end);
##   kill intervals (median, p90 nearest-rank, longest); damage in / out per minute; lowest total structure, lowest core
##   component (which, when); deaths.

const QUIET_LIST := 30.0      ## s: quiet stretches longer than this are listed
const PEAK_ON := 70.0
const PEAK_REARM := 35.0

var t0 := 0.0
var t_end := 0.0
var eng_s := 0.0
var engaged := false
var q_start := 0.0
var q_max := 0.0
var q_max_t := 0.0
var quiet30 := PackedFloat64Array()   ## start, dur, start, dur ...
var peaks := 0
var peak_t := PackedFloat64Array()
var _armed := true
var kill_t := PackedFloat64Array()
var dmg_in := 0.0
var dmg_out := 0.0
var hp_min := 100.0
var hp_min_t := 0.0
var core_min := 100.0
var core_min_c := ""
var core_min_t := 0.0
var deaths := 0
var closed := false


func net_fields() -> Dictionary:
	var f := {}
	for v: String in ["t0", "t_end", "eng_s", "engaged", "q_start", "q_max", "q_max_t", "quiet30", "peaks", "peak_t", "_armed",
			"kill_t", "dmg_in", "dmg_out", "hp_min", "hp_min_t", "core_min", "core_min_c", "core_min_t", "deaths", "closed"]:
		f[v] = Net.LOCAL
	return f


func begin(t: float, is_engaged: bool, intensity: float = 0.0) -> void:
	t0 = t
	t_end = t
	engaged = is_engaged
	q_start = t
	_armed = intensity < PEAK_ON


## Time moves to `t` with this engaged state (held since the last sample). Returns the length of a quiet stretch that ended
## at this sample (0 when none did).
func sample(t: float, is_engaged: bool, intensity: float) -> float:
	if closed:
		return 0.0
	var dt := maxf(t - t_end, 0.0)
	if engaged:
		eng_s += dt
	t_end = t
	var ended := 0.0
	if is_engaged and not engaged:
		ended = _quiet_until(t)
	elif not is_engaged and engaged:
		q_start = t
	engaged = is_engaged
	if _armed and intensity >= PEAK_ON:
		peaks += 1
		peak_t.append(t)
		_armed = false
	elif not _armed and intensity < PEAK_REARM:
		_armed = true
	return ended


func kill(t: float) -> void:
	kill_t.append(t)


func structure(t: float, total_pct: float, core_pct: float, core_comp: String) -> void:
	if total_pct < hp_min:
		hp_min = total_pct
		hp_min_t = t
	if core_pct < core_min:
		core_min = core_pct
		core_min_c = core_comp
		core_min_t = t


## Ends the stretch at `t` (an open quiet stretch is closed there). Returns that quiet stretch's length (0 if engaged).
func close(t: float) -> float:
	if closed:
		return 0.0
	sample(t, engaged, -1.0)
	closed = true
	if not engaged:
		return _quiet_until(t)
	return 0.0


func duration() -> float:
	return maxf(t_end - t0, 0.0)


func engaged_pct() -> float:
	var d := duration()
	return 100.0 * eng_s / d if d > 0.0 else 0.0


## [median, p90, longest] of the gaps between kills (-1 each with fewer than 2 kills).
func kill_intervals() -> PackedFloat64Array:
	if kill_t.size() < 2:
		return PackedFloat64Array([-1.0, -1.0, -1.0])
	var gaps := PackedFloat64Array()
	for i in range(1, kill_t.size()):
		gaps.append(kill_t[i] - kill_t[i - 1])
	gaps.sort()
	var n := gaps.size()
	var med := gaps[n / 2] if n % 2 == 1 else 0.5 * (gaps[n / 2 - 1] + gaps[n / 2])
	var p90 := gaps[clampi(ceili(0.9 * n) - 1, 0, n - 1)]
	return PackedFloat64Array([med, p90, gaps[n - 1]])


func per_minute(x: float) -> float:
	var d := duration()
	return x * 60.0 / d if d > 0.0 else 0.0


## The record's fields (fixed order), `est` = engagement is this machine's estimate (a client).
func body(est: bool) -> String:
	var k := kill_intervals()
	return ("dur=%.1f eng_s=%.1f eng_pct=%d quiet_max=%.1f quiet_max_mt=%.1f quiet30=%s peaks=%d peak_mt=%s kills=%d"
		+ " kint_med=%.1f kint_p90=%.1f kint_max=%.1f in_pm=%.1f out_pm=%.1f hp_min=%d hp_min_mt=%.1f core_min=%d"
		+ " core_min_c=%s core_min_mt=%.1f deaths=%d est=%d") % [duration(), eng_s, roundi(engaged_pct()), q_max, q_max_t,
		_pairs(quiet30), peaks, times(peak_t), kill_t.size(), k[0], k[1], k[2], per_minute(dmg_in), per_minute(dmg_out),
		roundi(hp_min), hp_min_t, roundi(core_min), core_min_c if core_min_c != "" else "-", core_min_t, deaths,
		1 if est else 0]


func _quiet_until(t: float) -> float:
	var d := maxf(t - q_start, 0.0)
	if d > q_max:
		q_max = d
		q_max_t = q_start
	if d > QUIET_LIST:
		quiet30.append(q_start)
		quiet30.append(d)
	return d


## Times as "60.0;71.0" (one decimal, ";"-joined), "-" when empty (the pacing and combat log lines).
static func times(a: PackedFloat64Array) -> String:
	if a.is_empty():
		return "-"
	var parts := PackedStringArray()
	for x in a:
		parts.append("%.1f" % x)
	return ";".join(parts)


static func _pairs(a: PackedFloat64Array) -> String:
	if a.is_empty():
		return "-"
	var parts := PackedStringArray()
	for i in range(0, a.size() - 1, 2):
		parts.append("%.1f+%.1f" % [a[i], a[i + 1]])
	return ";".join(parts)
