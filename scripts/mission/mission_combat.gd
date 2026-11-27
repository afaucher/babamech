class_name MissionCombat
extends Node
## Combat in the test drive: one CombatWorld (the combat clock, advanced every physics frame after the rack), one
## WeaponRack on the player's mech (keys 1-5 pick, LMB fire; RMB is the camera zoom), one PlayerTarget bridging enemy fire
## onto MechController / MechHud / WeaponRack, and one host-owned EnemySquad populated deterministically from the
## city seed by EnemySpawner (rooftop turrets, street skirmishers, avenue/checkpoint siege tanks).
##
##   var combat := MissionCombat.new()
##   add_child(combat)
##   combat.setup(test_drive)
##   # On new city seed: combat.rebuild_encounters(test_drive)
##
## CREW MISSION (co-op step 3): the CombatWorld runs on the shared clock (Session.host_time, CombatNet.session_clock) and
## a CombatNet ("CombatNet", `net`) sends this machine's fire records to the crew and fires theirs here (weapons.md §5).
## STACK: rebuild_encounters hands td.stack to the CombatWorld (`world.stack`), which then asks each deck's props and the
## stack's ring per point (CombatWorld header, CITY PROPS); null in district mode.

var world: CombatWorld
var rack: WeaponRack
var player_target: PlayerTarget
var squad: EnemySquad
var enemies: Array[EnemyBase] = []
var dummies: Array[TargetDummy] = []     ## kept empty (WeaponRangeLab still uses TargetDummy)
var _drive: Node = null
var pilot_link: PilotCombatLink         ## cosmetic: heat / hp / hits / firing / aim -> the pilot head (scripts/pilot/)
var net: CombatNet                      ## crew mission only: fire records across machines, host-owned hits to the host
var assets: Dictionary = {}             ## mission asset id -> AssetTarget (add_asset, on every machine)
## Hidden effect nodes made at load for the world's mesh pool (ImpactFx parts, rocket puffs: CombatWorld.take_mesh), about
## the parts of ~50 live impacts, so a fight's first seconds don't create nodes; most already show the mesh their
## borrower will ask for (ImpactFx.pool_plan + Rocket.pool_plan: no mesh swap on borrow), the rest are blank.
const MESH_POOL_PREWARM := 2048


func net_fields() -> Dictionary:
	return {"world": Net.LOCAL, "rack": Net.LOCAL, "player_target": Net.LOCAL, "squad": Net.LOCAL,
		"enemies": Net.LOCAL, "dummies": Net.LOCAL, "_drive": Net.LOCAL, "pilot_link": Net.LOCAL, "net": Net.LOCAL,
		"assets": Net.LOCAL}


## The paused-weapon swaps made for this drive ("LEFT SIDE: Flamer offline, using Side Laser"), [] when none.
func substitutions() -> Array[String]:
	return rack.substitutions() if rack != null else ([] as Array[String])


func setup(td: MissionScene) -> void:
	_drive = td
	world = CombatWorld.new()
	world.name = "CombatWorld"
	world.mission_seed = td.seed_value
	# Friendly fire (weapons.md §4.6): the crew's mission launch param when the drive carries one, else on (the default).
	world.friendly_fire = bool(td.get("friendly_fire")) if "friendly_fire" in td else true
	add_child(world)
	world.prewarm_mesh_pool(MESH_POOL_PREWARM, ImpactFx.pool_plan() + Rocket.pool_plan() + RepairDroneLook.pool_plan())
	CombatWorld.warm_target_scripts()    # splash's per-script check, at load instead of on a target's first splash
	WeaponRegistry.prewarm_enemy_weapons()   # enemy shots' meshes (rockets, shells) at load, not on their first shot
	var crew := td.crewed and Net.online()
	if crew:
		world.set_clock(CombatNet.session_clock)   # fire records' t on the shared clock (before anything reads now)
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
	if crew:
		net = CombatNet.new()
		net.name = "CombatNet"
		add_child(net)
		net.bind(world, rack, td)
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


## Rebuild the deterministic enemy encounters for the current city plan (called on setup and when MissionScene changes seed).
func rebuild_encounters(td: MissionScene) -> void:
	if world == null or squad == null or td == null or td.city == null:
		return
	world.mission_seed = td.seed_value
	world.ring = td.city.ring
	world.stack = td.stack     # null in district mode: CombatWorld falls back to the one "city_props" node and `ring`
	squad.clear_enemies()
	enemies.clear()
	squad.setup(world, td.city.plan, td.city.ring)
	if player_target != null:
		player_target.repair_all()
	enemies = td.spawn_enemies(world, squad)   # solo: EnemySpawner as before; crew: host only (W4, MissionScene.spawn_enemies)


## MISSION ASSETS (weapons.md §5 "Mission assets"): the mission layer calls this on EVERY machine with the same id. Makes
## an AssetTarget ("asset_<id>", host-owned, team "player") as a child of `node` and registers it; on the machine that
## owns it (host / solo) each applied hit goes to `td.mission.damage_asset(id, amount)` when the drive has a mission with
## that method (duck-typed, looked up per hit). Calling it again with the same id and node returns the same target.
func add_asset(id: String, node: Node3D, radius: float = 2.5, height: float = 6.0) -> AssetTarget:
	if world == null or node == null:
		return null
	var old: AssetTarget = asset(id)
	if old != null:
		if old.get_parent() == node:
			return old
		remove_asset(id)
	var t := AssetTarget.new(id, radius, height)
	node.add_child(t)
	world.register(t)
	assets[id] = t
	if world.owns(t):
		t.asset_damaged.connect(_on_asset_damaged)
	return t


func remove_asset(id: String) -> void:
	var t: Variant = assets.get(id)
	assets.erase(id)
	if t == null or not is_instance_valid(t):
		return
	if world != null:
		world.unregister(t as AssetTarget)
	(t as Node).queue_free()


func asset(id: String) -> AssetTarget:
	var t: Variant = assets.get(id)
	return t as AssetTarget if t != null and is_instance_valid(t) else null


func _on_asset_damaged(id: String, amount: float, _src: String) -> void:
	var m: Variant = _drive.get("mission") if _drive != null and is_instance_valid(_drive) else null
	if m != null and is_instance_valid(m) and m is Object and (m as Object).has_method("damage_asset"):
		(m as Object).call("damage_asset", id, amount)


func _bind_hud(td: Node) -> void:
	if td == null or not is_instance_valid(td) or player_target == null:
		return
	var hud := td.get_node_or_null("MechHud") as MechHud
	if hud != null and not hud.component_source.is_valid():
		hud.component_source = player_target.component_fractions


func _physics_process(delta: float) -> void:
	if world == null:
		return
	var pp0 := Time.get_ticks_usec() if PerfProbe.on else 0   # bench instrumentation (tests/bench_bot_perf.gd)
	rack.step(delta)
	var pp1 := Time.get_ticks_usec() if PerfProbe.on else 0
	if net != null:
		net.pre_advance()
	world.advance(delta)
	var pp2 := Time.get_ticks_usec() if PerfProbe.on else 0
	if net != null:
		net.post_step(delta)
	if PerfProbe.on:
		PerfProbe.add("combat.rack.local", pp1 - pp0)
		PerfProbe.add("combat.advance", pp2 - pp1)
		PerfProbe.add("combat.net_post", Time.get_ticks_usec() - pp2)
