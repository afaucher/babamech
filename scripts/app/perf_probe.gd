class_name PerfProbe
extends RefCounted
## Opt-in per-frame timers and counters for headless perf benches (tests/bench_bot_perf.gd). OFF by default: a probe
## site costs one static bool test. Instrumentation only: never changes what the game does.
##   var t0 := Time.get_ticks_usec() if PerfProbe.on else 0
##   ...
##   if PerfProbe.on: PerfProbe.add("bot.player", Time.get_ticks_usec() - t0)
## The bench calls take() once per physics frame and keeps its own per-frame series.

static var on := false
static var acc: Dictionary = {}   ## key -> usec accumulated since the last take()
static var cnt: Dictionary = {}   ## key -> calls since the last take()


static func add(key: String, us: int, n: int = 1) -> void:
	acc[key] = int(acc.get(key, 0)) + us
	cnt[key] = int(cnt.get(key, 0)) + n


static func count(key: String, n: int = 1) -> void:
	cnt[key] = int(cnt.get(key, 0)) + n


## [acc, cnt] since the last take(), then clears both.
static func take() -> Array:
	var r := [acc, cnt]
	acc = {}
	cnt = {}
	return r
