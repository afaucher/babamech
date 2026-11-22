class_name TestDriveCombat
extends Node
## Combat in the test drive: one CombatWorld (the combat clock, advanced every physics frame after the rack), one
## WeaponRack on the player's mech (keys 1-5 pick, LMB fire; RMB is the camera zoom), one PlayerTarget bridging enemy fire
## onto MechController / MechHud / WeaponRack, and one host-owned EnemySquad populated deterministically from the
## city seed by EnemySpawner (rooftop turrets, street skirmishers, avenue/checkpoint siege tanks).
##
##   var combat := TestDriveCombat.new()
##   add_child(combat)
##   combat.setup(test_drive)
##   # On new city seed: combat.rebuild_encounters(test_drive)

var world: CombatWorld
var rack: WeaponRack
var player_target: PlayerTarget
var squad: EnemySquad
var enemies: Array[EnemyBase] = []
var dummies: Array[TargetDummy] = []     ## kept empty (WeaponRangeLab still uses TargetDummy)
var _drive: Node = null
var pilot_link: PilotCombatLink         ## cosmetic: heat / hp / hits / firing / aim -> the pilot head (scripts/pilot/)


func net_fields() -> Dictionary:
	return {"world": Net.LOCAL, "rack": Net.LOCAL, "player_target": Net.LOCAL, "squad": Net.LOCAL,
		"enemies": Net.LOCAL, "dummies": Net.LOCAL, "_drive": Net.LOCAL, "pilot_link": Net.LOCAL}


## The paused-weapon swaps made for this drive ("LEFT SIDE: Flamer offline, using Side Laser"), [] when none.
func substitutions() -> Array[String]:
	return rack.substitutions() if rack != null else ([] as Array[String])


func setup(td: TestDrive) -> void:
	_drive = td
	world = CombatWorld.new()
	world.name = "CombatWorld"
	world.mission_seed = td.seed_value
	add_child(world)
	var p := CombatWorld.local_peer()
	var pid := "player%d" % p

	player_target = PlayerTarget.new()
	player_target.name = "PlayerTarget"
	add_child(player_target)
	player_target.bind(world, td.mech, td.rig.model, pid, p)
	player_target.on_respawn = td.respawn
	world.register(player_target)

	rack = WeaponRack.new()
	rack.name = "WeaponRack"
	rack.auto_step = false
	rack.read_input = true
	rack.slot_disabled = player_target.is_slot_destroyed
	add_child(rack)
	rack.bind(world, td.mech, td.rig.model, td.cam, pid, p)
	pilot_link = PilotCombatLink.new()
	pilot_link.name = "PilotCombatLink"
	add_child(pilot_link)
	pilot_link.bind(td.rig, td.mech, rack, player_target, world)
	var raw: Dictionary = GameSettings.load_settings().get("loadout", {})
	rack.set_substitutions(WeaponRegistry.playable_loadout(td.rig.model.chassis_id, raw)["notes"])
	for n in rack.substitutions():
		print("[weapons] " + n)

	squad = EnemySquad.new()
	squad.max_attackers = 1            # solo test drive: one readable incoming telegraph at a time
	squad.slot_stagger = 0.35
	add_child(squad)
	rebuild_encounters(td)
	_bind_hud.call_deferred(td)


## Rebuild the deterministic enemy encounters for the current city plan (called on setup and when TestDrive changes seed).
func rebuild_encounters(td: TestDrive) -> void:
	if world == null or squad == null or td == null or td.city == null:
		return
	world.mission_seed = td.seed_value
	world.ring = td.city.ring
	squad.clear_enemies()
	enemies.clear()
	squad.setup(world, td.city.plan, td.city.ring)
	if player_target != null:
		player_target.repair_all()
	enemies = EnemySpawner.spawn_all(td.city.plan, td.city.ring, td.mech.global_position, world, squad, td.seed_value, false)


func _bind_hud(td: Node) -> void:
	if td == null or not is_instance_valid(td) or player_target == null:
		return
	var hud := td.get_node_or_null("MechHud") as MechHud
	if hud != null and not hud.component_source.is_valid():
		hud.component_source = player_target.component_fractions


func _physics_process(delta: float) -> void:
	if world == null:
		return
	rack.step(delta)
	world.advance(delta)
