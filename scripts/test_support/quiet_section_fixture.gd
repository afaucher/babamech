class_name QuietSectionFixture
extends RefCounted
## TEST-ONLY fixture (docs/testing.md "Fixtures"): a built mission section (the stack, its crew, the full garrison on
## every deck) with NO director releases, NO objectives and NO end: MissionFlow builds no rules (MissionFlow.test_quiet).
## For tests of a narrow system (a weapon, an enemy behaviour, net sync, city / stack layout, perf) that need "a section
## with enemies" and must not depend on the mission's pacing or outcome. Integration tests of the mission flow, the
## director, bots or co-op objectives run the real objectives mode instead (the only mode; MissionFlow.test_plan for a
## forced plan such as {"primary": "sweep"}).
##
## Use: declare `const QUIET_SECTION := true` in the test (or the shared case it extends): TestCase._ready arms it in
## every process of the test (net tests: host and clients alike) before setup(). Or call arm() / disarm() directly.
## MissionScene honours it too: no plan prebuild in the stepped load and the full garrison (share 1.0) in spawn_enemies.
##
## Never reachable from the game: nothing in scripts/app, scripts/ui or scripts/game references this class, and
## MissionFlow.test_quiet is written only here and in tests/ (tests/test_objectives_only.gd checks both).

const FLAG := "QUIET_SECTION"


static func arm() -> void:
	MissionFlow.test_quiet = true


static func disarm() -> void:
	MissionFlow.test_quiet = false


## The test (or a script it extends) declares `const QUIET_SECTION := true`.
static func wanted(test: Object) -> bool:
	var s: Script = test.get_script() if test != null else null
	while s != null:
		var consts: Dictionary = s.get_script_constant_map()
		if consts.has(FLAG):
			return bool(consts[FLAG])
		s = s.get_base_script()
	return false
