extends TestCase
## Shared body of test_bot_nav_up*: the mission bot gets back UP a deck. Solo stack mission in the real objectives mode
## with the forced all-sweep plan (bot_nav_case.gd PLAN), `--dev-fast-clear`; deck 0's enemies are killed outright so
## the objective is deck 1's sweep; the bot's mech is then put on deck 2 (as after an
## unplanned drop). Checked within LIMIT s: it goes 2 -> 1 the expected way: by ramp (BotRoutePlanner ramp legs walked
## foot to top; no DEV travel, no jump), or on a lift-only seed by DEV travel (no ramp up; lifts don't move yet), with no
## unplanned deck change.


var seed_n := 4
var dev := false           ## DEV travel on (a lift-only seed: no ramp up, so the jump is the way)
var expect_by := "ramp"    ## how the 2 -> 1 change must happen
const LIMIT := 90.0


func _init() -> void:
	timeout_sec = LIMIT + 60.0


func setup() -> void:
	MissionScene.solo_launch = {"seed": seed_n, "mode": MissionScene.MODE_STACK}
	MissionScene.bot_profile = "veteran"
	MissionScene.dev_bot_travel = dev
	MissionFlow.test_plan = load("res://tests/bot_nav_case.gd").get_script_constant_map()["PLAN"]
	CombatWorld.dev_enemy_damage = MissionScene.DEV_FAST_CLEAR
	Engine.time_scale = float(load("res://tests/bot_nav_case.gd").call("speed"))   # the same test speed (2x)
	var td := (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	await frames(4)
	if not check(td.bot != null and td.stack != null and td.mission != null and td.mission.plan != null,
			"the solo stack drive runs the mission bot on the plan"):
		_restore()
		finish()
		return
	for e in td.combat.squad.enemies.duplicate():
		if is_instance_valid(e) and e.spawn_deck == 0:
			for i in 12:   # a troop squad goes down one trooper per core hit (bounded)
				if e.destroyed():
					break
				e.apply_damage(1.0e7, e.core_component(), "test")
	var rules := td.mission.rules
	var deck1 := str(td.mission.plan.primary(1)["id"])
	eq(str(td.mission.plan.primary(0)["type"]), "sweep", "deck 0's primary is the forced sweep")
	var waited := 0
	while rules.current() != deck1 and waited < 120:
		await get_tree().physics_frame
		waited += 1
	eq(rules.current(), deck1, "deck 0 is cleared, the objective is deck 1's sweep")
	# Onto deck 2's arterial, standing.
	var st := td.stack
	var p := st.from_deck_arc(2, -45.0, 0.0, CityPlan.CURB_H + 0.3)
	var up := st.deck_ring(2).up_at(p)
	var f := st.deck_ring(2).tangent_at(p)
	td.mech.global_transform = Transform3D(Basis(f.cross(up), up, -f), p)
	td.mech.velocity = Vector3.ZERO
	var tt := 0.0
	var up_at := -1.0
	while tt < LIMIT:
		await get_tree().physics_frame
		tt += Engine.time_scale / float(Engine.physics_ticks_per_second)
		for c: Dictionary in td.bot.deck_changes:
			if int(c["from"]) == 2 and int(c["to"]) == 1 and up_at < 0.0:
				up_at = tt
		if up_at >= 0.0 and td.stack.deck_at(td.mech.global_position) == 1 and td.mech.is_on_floor():
			break
	var s := td.bot.stats()
	print("[Test] up: deck 2 -> 1 at %.1f s; deck changes %s; stuck %d; roof_max %.1f s; stall_max %.1f s" % [up_at,
		str(s["deck_changes"]), int(s["stuck"]), float(s["roof_max"]), float(s["stall_max"])])
	var by_ramp := false
	for c: Dictionary in s["deck_changes"]:
		if int(c["from"]) == 2 and int(c["to"]) == 1 and c["by"] == expect_by:
			by_ramp = true
	check(by_ramp, "seed %d: the bot gets from deck 2 to deck 1 by %s within %.0f s (%s)" % [seed_n, expect_by, LIMIT,
		str(s["deck_changes"])])
	eq(int((s["by"] as Dictionary).get("unplanned", 0)), 0, "no unplanned deck change")
	if not dev:
		eq(int(s["dev_jumps"]), 0, "no DEV jump")
	_restore()
	finish()


func _restore() -> void:
	Engine.time_scale = 1.0
	MissionScene.bot_profile = ""
	MissionScene.dev_bot_travel = false
	CombatWorld.dev_enemy_damage = 1.0
	MissionFlow.test_plan = {}
