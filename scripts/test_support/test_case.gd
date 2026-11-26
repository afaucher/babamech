class_name TestCase
extends Node
## Base for tests in res://tests/ (from cast). Run with:
##   .\test_runner.ps1 -TestName <name>    or    .\test_runner.ps1 -TestAll
## Override setup() (may await). Assert with check/eq/near, then call finish().
## Use _physics_process / await for frame-based tests; the timeout is a Timer,
## so overriding _process is fine.

## Game seconds before the test fails (the Timer runs on scaled game time, so a test that speeds the sim up with
## Engine.time_scale gets more of it per wall second). Set it in _init() or in setup(): setting it while the timer runs
## restarts the timer with the new value (code-audit-2026-11 #8: a value set in setup() used to be ignored and every
## such test kept 60 s). Unset, a test's `const TEST_TIMEOUT := N` (test_runner's wall limit) is used when larger.
## NetTest stops this timer and watches the wall clock (net_timeout) instead; setting timeout_sec doesn't revive it.
var timeout_sec := 60.0:
	set(v):
		timeout_sec = v
		_timeout_set = true
		if _timer != null and not _timer.is_stopped():
			_timer.start(v)
var _failures := 0
var _done := false
var _timer: Timer = null
var _timeout_set := false


func _ready() -> void:
	if not _timeout_set:
		var consts: Dictionary = get_script().get_script_constant_map() if get_script() != null else {}
		if consts.has("TEST_TIMEOUT") and float(consts["TEST_TIMEOUT"]) > timeout_sec:
			timeout_sec = float(consts["TEST_TIMEOUT"])
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.wait_time = timeout_sec
	_timer.timeout.connect(func():
		_fail("timed out after %.0fs (game time)" % timeout_sec)
		finish())
	add_child(_timer)
	_timer.start()
	print("Running test: ", name)
	if QuietSectionFixture.wanted(self):   # `const QUIET_SECTION := true`: no director, no objectives (docs/testing.md)
		QuietSectionFixture.arm()
	await setup()


## Override.
func setup() -> void:
	finish()


func check(cond: bool, msg: String = "") -> bool:
	if not cond:
		_fail("check failed: " + msg)
	return cond


func eq(a, b, msg: String = "") -> bool:
	if a != b:
		_fail("expected %s == %s  %s" % [str(a), str(b), msg])
		return false
	return true


func near(a: float, b: float, tol: float = 0.001, msg: String = "") -> bool:
	if absf(a - b) > tol:
		_fail("expected %f ~= %f (tol %f)  %s" % [a, b, tol, msg])
		return false
	return true


func _fail(msg: String) -> void:
	_failures += 1
	push_error("ASSERT FAILED [%s]: %s" % [name, msg])
	printerr("ASSERT FAILED [%s]: %s" % [name, msg])


## The port a single-process test should open a crew on: test_runner passes a free random one as `--net-port`
## (docs/testing.md "Ports"); `fallback` when run some other way.
func test_port(fallback: int) -> int:
	var v := Boot.arg_value(OS.get_cmdline_user_args(), "--net-port")
	return int(v) if v.is_valid_int() else fallback


## Wait n physics frames.
func frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func finish() -> void:
	if _done:
		return
	_done = true
	if _failures == 0:
		print(">>> [TEST PASSED] %s <<<" % name)
		get_tree().quit(0)
	else:
		print(">>> [TEST FAILED] %s (%d failures) <<<" % [name, _failures])
		get_tree().quit(1)
