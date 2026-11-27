class_name PilotIntensity
extends RefCounted
## One pilot's intensity I in 0..100 (docs/design/pacing-director.md 1.2). PURE: every input is fed in by the caller (no
## node access, no clock, no randomness), so the same inputs always give the same value. The combat log runs one for the
## LOCAL pilot (CombatLog, `threat src=local`); the pacing director will own the host's instances (one per pilot, fed from
## replicated pilot state) and replicate the value in mission.state `intensity` (then the log prints `src=host`).
##
##   structure lost         +PER_PCT per 1 % of total structure lost since the last feed (repairs only move the baseline:
##                          they never lower I)                                              structure(total_pct)
##   component destroyed    +COMPONENT each                                                  component_destroyed()
##   mech disabled          +DISABLED                                                        disabled()
##   heat at shutdown       +HEAT_PER_S per second                                           step(dt, engaged, shutdown)
##   enemy killed near      +KILL_NEAR x (1 - dist / KILL_RANGE) within KILL_RANGE m           kill_near(dist)
##   decay                  -DECAY_PER_S per second, only while NOT engaged                   step(dt, engaged, shutdown)
## Clamped to 0..MAX after every change. "Engaged" is decided by the caller (an enemy fired at the pilot, or was awake
## within ENGAGE_RANGE m with the pilot as target, during the last ENGAGE_HOLD s): engaged(now, last) is that test.

const PER_PCT := 1.0
const COMPONENT := 15.0
const DISABLED := 40.0
const HEAT_PER_S := 5.0
const KILL_NEAR := 4.0
const KILL_RANGE := 40.0      ## m
const DECAY_PER_S := 4.0
const ENGAGE_RANGE := 60.0    ## m: an awake enemy with the pilot as target this close engages it
const ENGAGE_HOLD := 4.0      ## s an engagement lasts after the shot / the last time it was seen close
const MAX := 100.0

var value := 0.0
var _base := -1.0             ## total structure % at the last feed (-1: none yet)


## The log's copy is LOCAL (recomputed per machine). The director's host copy will be replicated through mission.state.
func net_fields() -> Dictionary:
	return {"value": Net.LOCAL, "_base": Net.LOCAL}


## Total structure % now (0..100). A drop since the last feed raises I; a rise (repair, respawn) only moves the baseline.
func structure(total_pct: float) -> void:
	if _base >= 0.0 and total_pct < _base:
		_add((_base - total_pct) * PER_PCT)
	_base = total_pct


func component_destroyed(n: int = 1) -> void:
	_add(COMPONENT * n)


func disabled() -> void:
	_add(DISABLED)


func kill_near(dist: float) -> void:
	if dist >= 0.0 and dist < KILL_RANGE:
		_add(KILL_NEAR * (1.0 - dist / KILL_RANGE))


## `dt` s pass: heat at shutdown adds, then decay if not engaged.
func step(dt: float, engaged: bool, shutdown: bool) -> void:
	if dt <= 0.0:
		return
	if shutdown:
		_add(HEAT_PER_S * dt)
	if not engaged:
		_add(-DECAY_PER_S * dt)


## The engaged test: something engaged the pilot at `last` (s), still counted at `now`.
static func engaged(now: float, last: float) -> bool:
	return now - last <= ENGAGE_HOLD


func reset() -> void:
	value = 0.0
	_base = -1.0


func _add(x: float) -> void:
	value = clampf(value + x, 0.0, MAX)
