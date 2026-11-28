class_name CrewBot
extends Node
## A hangar bot's body on the HOST (docs/design/hangar-bots.md §5): the machine that runs it. MissionScene builds one per
## bot in the launch crew, after combat, on the host only; on every other machine the bot is an ordinary puppet
## (CrewSync / MechPuppet).
##   mech     the bot's MechController (real physics, not a puppet; owner_peer 1 = this machine, pilot id in the
##            MechSpawn "owner_peer" meta), made by MissionScene._spawn_crew
##   target   its PlayerTarget "player<id>" (owner 1: every hit on the bot is decided here); downed it holds still with
##            no weapons, waits for a revive and then redeploys (auto_redeploy, DownedCrew / DownedRules; once its AI
##            runs, BotAid.wait_s decides how long: while a reviver is plausibly coming)
##   rack     its WeaponRack (shooter "player<id>", peer 1, no camera, no input), stepped here before CombatWorld.advance;
##            CombatNet.add_bot(id) sends its fire records and drone launches to the crew
##   ai       its MissionBot (attach_crew), started at mission_go; until then the mech stands still
## CrewSync streams it (Session.mechs.feed_owned) every physics frame like the local mech.

var id := 0                       ## the bot's pilot id (< 0)
var skill := "veteran"            ## its BotProfile id (the hangar's)
var drive: MissionScene
var mech: MechController
var rig: MechRig
var target: PlayerTarget
var rack: WeaponRack
var ai: MissionBot
var spawn := Transform3D.IDENTITY ## where it (re)spawns: its crew slot


func net_fields() -> Dictionary:
	return {"id": Net.SPAWN, "skill": Net.SPAWN, "drive": Net.LOCAL, "mech": Net.LOCAL, "rig": Net.LOCAL,
		"target": Net.LOCAL, "rack": Net.LOCAL, "ai": Net.LOCAL, "spawn": Net.SPAWN}


func _ready() -> void:
	process_physics_priority = -10   # after PlayerBot (-20) and MissionBot (-19) chose the inputs, before CombatWorld steps


## Wire the bot's combat on `td` (its combat world exists); `m` is its mech, already in the tree.
func setup(td: MissionScene, bot_id: int, m: MechController, skill_: String) -> void:
	drive = td
	id = bot_id
	skill = skill_
	mech = m
	rig = MechSpawn.rig_of(m)
	spawn = m.global_transform
	var world := td.combat.world
	var pid := "player%d" % id
	target = PlayerTarget.new()
	target.name = "PlayerTarget"
	add_child(target)
	target.bind(world, m, rig.model, pid, NetSession.machine_of(id))
	target.on_respawn = respawn          # DownedCrew replaces it with the deck arrival point
	target.auto_redeploy = true          # a bot cannot hold the respawn key (DownedRules.bot_wait)
	world.register(target)
	rack = WeaponRack.new()
	rack.name = "WeaponRack"
	rack.auto_step = false
	rack.read_input = false
	rack.slot_disabled = target.is_slot_destroyed
	add_child(rack)
	rack.bind(world, m, rig.model, null, pid, NetSession.machine_of(id))
	if td.combat.net != null:
		td.combat.net.add_bot(id, rack)   # fire records, drone launches and railgun charge glows to the crew


## The barrier passed: the AI takes the controls.
func start() -> void:
	if ai == null and is_inside_tree():
		ai = MissionBot.attach_crew(drive, self, mech, rack, target, id, skill)


func respawn() -> void:
	if mech == null:
		return
	mech.global_transform = spawn
	mech.velocity = Vector3.ZERO
	if rig != null:
		rig.gait.reset([])


func _physics_process(delta: float) -> void:
	if drive == null or mech == null or drive.loading:
		return
	var down := target != null and target.disabled
	if ai == null or down:   # held until mission_go, like every crew mech; downed: no movement (DownedRules)
		mech.move_input = Vector2.ZERO
		mech.turn_input = 0.0
		mech.running = false
		mech.thrust_input = false
	if drive.stack != null and drive.stack.fell_out(mech.global_position, MissionScene.FALL_OUT):
		respawn()
	if rack != null:
		var pp0 := Time.get_ticks_usec() if PerfProbe.on else 0   # bench instrumentation (tests/bench_bot_perf.gd)
		if down:
			rack.trigger = false                 # downed: no weapons
		rack.step(delta)
		if PerfProbe.on:
			PerfProbe.add("bot.rack", Time.get_ticks_usec() - pp0)


## The crew panel's status for this bot (as CrewSync.status for a puppet).
func status() -> Dictionary:
	var hull := 1.0
	if target != null and target.max_hp.has("torso"):
		hull = clampf(float(target.hp.get("torso", 0.0)) / maxf(float(target.max_hp["torso"]), 0.001), 0.0, 1.0)
	var heat := mech.heat / maxf(mech.heat_cap, 0.001) if mech != null else 0.0
	var st := "disabled" if target != null and target.disabled else ("overheat" if mech != null and mech.shutdown else "ok")
	return {"hp": hull, "heat": heat, "state": st}
