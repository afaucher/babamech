extends TestCase
## MIXED CREW (docs/design/chassis-rules.md "Bulwark world fit"): a Bulwark and a Strider on the SAME solo plan-mode
## mission, each driven by its own MissionBot: the local mech is a Bulwark (settings file of the test's own, as
## tests/bulwark_bot_case.gd) with the `--bot` MissionBot; the offline crew's second mech (TestDrive.offline_crew 2, a
## Strider) is taken off puppet and driven by a CrewBot (PlayerTarget, WeaponRack, MissionBot.attach_crew) like a
## hangar bot on the host. Enemies take DEV_FAST_CLEAR damage (the check is about getting places, not the fight).
## Checked within LIMIT s of game time: BOTH mechs stood inside the zone of the same flag / defend / hold objective, and
## BOTH crossed a deck connector (stood on a deck below the entry deck). Seed 4: deck 0 sweep, then its bonus flag
## d0_b0 (reachable for a Bulwark: tests/test_bulwark_world_fit.gd), then the ramp or a shaft down to deck 1.

const SERIAL := true   # a bot-played mission: alone after the batch
const TEST_TIMEOUT := 420
const SEED := 4
const LIMIT := 600.0
const SPEED := 2.0
const SETTINGS := "user://test_bot_bulwark_mixed_settings.cfg"

var _saved_path := ""


func _init() -> void:
	timeout_sec = LIMIT + 120.0


func setup() -> void:
	_saved_path = GameSettings.path
	GameSettings.path = SETTINGS
	var d := GameSettings.DEFAULTS.duplicate(true)
	d["chassis"] = "bulwark"
	d["loadout"] = BotProfile.get_loadout("bulwark")
	GameSettings.save_settings(d)
	TestDrive.solo_launch = {"seed": SEED, "mode": TestDrive.MODE_STACK}
	TestDrive.bot_profile = "veteran"
	TestDrive.dev_bot_travel = false
	TestDrive.offline_crew = 2
	MissionBot.bonuses = true
	CombatWorld.dev_enemy_damage = TestDrive.DEV_FAST_CLEAR
	Engine.time_scale = SPEED
	var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	var w := 0.0
	while not td.loaded and w < 60.0:
		await get_tree().process_frame
		w += get_process_delta_time()
	await frames(4)
	if not check(td.bot != null and td.mission != null and td.mission.plan != null, "the plan-mode drive runs the mission bot"):
		_restore(td)
		return
	var bul := td.mech
	var str_m: MechController = null
	for p: int in td.mechs:
		if td.mechs[p] != bul:
			str_m = td.mechs[p]
	if not check(str_m != null, "the offline crew has a second mech"):
		_restore(td)
		return
	eq(bul.chassis_id, "bulwark", "the local mech is a Bulwark")
	eq(str_m.chassis_id, "strider", "the crewmate is a Strider")
	str_m.puppet = false
	var cb := CrewBot.new()
	cb.name = "CrewBot_test"
	td.add_child(cb)
	cb.setup(td, -2, str_m, "veteran")
	cb.start()
	var rules := td.mission.rules
	var k0 := td.stack.deck_at(bul.global_position)
	var zones := {}   # objective id -> {bul: bool, str: bool}
	var decks := {"bul": {}, "str": {}}
	var tt := 0.0
	var both_zone := ""
	var both_deck := false
	while tt < LIMIT:
		await get_tree().physics_frame
		tt += Engine.time_scale / float(Engine.physics_ticks_per_second)
		for who: String in ["bul", "str"]:
			var m: MechController = bul if who == "bul" else str_m
			if m.is_on_floor():
				(decks[who] as Dictionary)[td.stack.deck_at(m.global_position)] = true
			var a := td.stack.to_deck_arc(m.global_position)
			for o: Dictionary in rules.objectives:
				if not str(o["type"]) in ["flag", "defend", "hold"] or int(o["deck"]) != int(a["deck"]):
					continue
				var p := Vector2(float(a["x"]), float(a["s"]))
				var inside := false
				if str(o["type"]) == "hold":
					inside = (o["zone"] as Rect2).has_point(p)
				else:
					inside = p.distance_to(Vector2(float(o["site"]["x"]), float(o["site"]["s"]))) <= float(o["radius"])
				if inside:
					var z: Dictionary = zones.get_or_add(str(o["id"]), {})
					if not z.has(who):
						z[who] = snappedf(tt, 0.1)
						print("[Test] %s in %s (%s) at %.1f s" % ["Bulwark" if who == "bul" else "Strider", o["id"], o["type"], tt])
		for id: String in zones:
			if both_zone == "" and (zones[id] as Dictionary).size() == 2:
				both_zone = id
		both_deck = (decks["bul"] as Dictionary).keys().any(func(k: int) -> bool: return k > k0) \
			and (decks["str"] as Dictionary).keys().any(func(k: int) -> bool: return k > k0)
		if both_zone != "" and both_deck:
			break
	print("[Test] mixed crew seed %d after %.1f s: zones %s; decks stood: Bulwark %s, Strider %s; Bulwark bot %s / Strider bot %s" % [
		SEED, tt, str(zones), str((decks["bul"] as Dictionary).keys()), str((decks["str"] as Dictionary).keys()),
		str(td.bot.stats()["deck_changes"]), str(cb.ai.stats()["deck_changes"]) if cb.ai != null else "-"])
	check(both_zone != "", "both mechs stood in the same objective zone (%s)" % str(zones))
	check(both_deck, "both mechs crossed a deck connector (Bulwark %s, Strider %s)" % [str((decks["bul"] as Dictionary).keys()),
		str((decks["str"] as Dictionary).keys())])
	_restore(td)


func _restore(td: TestDrive) -> void:
	Engine.time_scale = 1.0
	TestDrive.bot_profile = ""
	TestDrive.offline_crew = 0
	TestDrive.dev_bot_travel = false
	CombatWorld.dev_enemy_damage = 1.0
	GameSettings.path = _saved_path
	if td != null:
		td.queue_free()
	await frames(2)
	finish()
