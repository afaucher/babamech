class_name TestCase
extends Node
## Base for tests in res://tests/ (from cast). Run with:
##   .\test_runner.ps1 -TestName <name>    or    .\test_runner.ps1 -TestAll
## Override setup() (may await). Assert with check/eq/near, then call finish().
## Use _physics_process / await for frame-based tests; the timeout is a Timer,
## so overriding _process is fine.

var timeout_sec := 60.0
var _failures := 0
var _done := false


func _ready() -> void:
	var t := Timer.new()
	t.one_shot = true
	t.wait_time = timeout_sec
	t.timeout.connect(func():
		_fail("timed out after %.0fs" % timeout_sec)
		finish())
	add_child(t)
	t.start()
	print("Running test: ", name)
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
