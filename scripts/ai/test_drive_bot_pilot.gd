class_name TestDriveBotPilot
extends Node
## Self-contained spectator / autopilot bridge for TestDrive (docs/design/player-ai.md §6.2).
## Attach with a single call once TestDrive is ready: `TestDriveBotPilot.attach(test_drive)`.
##   --bot <rookie|average|veteran|brawler>   start TestDrive in live AI autopilot mode
##   F6                                       toggle live AI autopilot on / off seamlessly
##   F7                                       cycle AI skill profile while autopilot is active
## Strictly input-only: drives drive.mech, drive.combat.rack, and spectator drive.cam; cleanly restores
## human controls (drive.drive_override = false, rack.read_input = true, rack.manual_aim = false) when toggled off.

signal toggled(active: bool, profile: String)

var profile_id := "veteran"
var active := false
var drive: Node                  ## TestDrive instance (typed loosely so Engine's co-op edits never clash)
var bot: PlayerBot
var _bound_seed := -1
## Engine (hangar bots, docs/design/hangar-bots.md): drive ANOTHER mech than drive.mech: {mech, rack, pt, id}. Empty =
## the local mech (the default). With a body, drive_override and the camera are left alone.
var body: Dictionary = {}


func net_fields() -> Dictionary:
	return {
		"profile_id": Net.SPAWN, "active": Net.PRIVATE, "drive": Net.LOCAL,
		"bot": Net.LOCAL, "_bound_seed": Net.PRIVATE, "body": Net.LOCAL,
	}


static func attach(td: Node) -> TestDriveBotPilot:
	var pilot := TestDriveBotPilot.new()
	pilot.name = "BotPilot"
	pilot.drive = td
	td.add_child(pilot)
	var args := OS.get_cmdline_user_args()
	var flag := Boot.arg_value(args, "--bot").strip_edges().to_lower()
	if flag != "":
		pilot.profile_id = flag if BotProfile.has_profile(flag) else "veteran"
		pilot.set_active(true)
	return pilot


func set_profile(pid: String) -> void:
	if not BotProfile.has_profile(pid):
		return
	profile_id = pid
	if active:
		_bind_bot()
		toggled.emit(true, profile_id)


func cycle_profile() -> void:
	var idx := BotProfile.PROFILE_ORDER.find(profile_id)
	var next_id: String = BotProfile.PROFILE_ORDER[(idx + 1) % BotProfile.PROFILE_ORDER.size()]
	set_profile(next_id)


func toggle() -> void:
	set_active(not active)


func set_active(on: bool) -> void:
	if active == on:
		return
	active = on
	if drive == null or not is_instance_valid(drive):
		return
	if active:
		_bind_bot()
	else:
		_release_controls()
	toggled.emit(active, profile_id)


func _bind_bot() -> void:
	if drive == null or not is_instance_valid(drive):
		return
	var mech: MechController = drive.get("mech") as MechController
	var combat: Node = drive.get("combat") as Node
	var city: CityDistrict = drive.get("city") as CityDistrict
	var cam: ChaseCamera = drive.get("cam") as ChaseCamera
	if not body.is_empty():
		mech = body.get("mech") as MechController
		cam = null
	if mech == null or combat == null:
		return
	var rack: WeaponRack = combat.get("rack") as WeaponRack
	var pt: PlayerTarget = combat.get("player_target") as PlayerTarget
	if not body.is_empty():
		rack = body.get("rack") as WeaponRack
		pt = body.get("pt") as PlayerTarget
	var world: CombatWorld = combat.get("world") as CombatWorld
	var squad: EnemySquad = combat.get("squad") as EnemySquad
	var plan: CityPlan = city.plan if city != null else null
	var ring: RingFrame = city.ring if city != null else null
	var seed_val := int(drive.get("seed_value"))

	if body.is_empty():
		drive.set("drive_override", true)
	if bot == null or not is_instance_valid(bot):
		bot = PlayerBot.new()
		bot.name = "SpectatorPlayerBot"
		bot.auto_step = false
		add_child(bot)
	bot.configure(profile_id, seed_val, "spectator_bot" if body.is_empty() else "crew_bot%d" % int(body.get("id", 0)))
	bot.bind(mech, rack, pt, world, squad, plan, ring, cam)
	_bound_seed = seed_val
	# Run before MechController and TestDriveCombat step each physics frame.
	process_physics_priority = -20


func _release_controls() -> void:
	if bot != null and is_instance_valid(bot):
		bot.queue_free()
		bot = null
	_bound_seed = -1
	if drive == null or not is_instance_valid(drive):
		return
	if not body.is_empty():
		var bm := body.get("mech") as MechController
		if bm != null and is_instance_valid(bm):
			bm.move_input = Vector2.ZERO
			bm.turn_input = 0.0
			bm.running = false
			bm.thrust_input = false
		var br := body.get("rack") as WeaponRack
		if br != null and is_instance_valid(br):
			br.set_trigger(false)
		return
	drive.set("drive_override", false)
	var mech: MechController = drive.get("mech") as MechController
	if mech != null and is_instance_valid(mech):
		mech.move_input = Vector2.ZERO
		mech.turn_input = 0.0
		mech.running = false
		mech.thrust_input = false
	var combat: Node = drive.get("combat") as Node
	if combat != null and is_instance_valid(combat):
		var rack: WeaponRack = combat.get("rack") as WeaponRack
		if rack != null and is_instance_valid(rack):
			rack.set_trigger(false)
			rack.manual_aim = false
			rack.read_input = true


func _physics_process(delta: float) -> void:
	if not active or drive == null or not is_instance_valid(drive):
		return
	# Re-bind automatically if the user presses N to generate a new city seed.
	var cur_seed := int(drive.get("seed_value"))
	if cur_seed != _bound_seed or bot == null or not is_instance_valid(bot):
		_bind_bot()
	if bot != null and is_instance_valid(bot):
		bot.step(delta)


func _unhandled_input(e: InputEvent) -> void:
	if not body.is_empty() or not (e is InputEventKey):
		return
	var k := e as InputEventKey
	if not k.pressed or k.echo:
		return
	if k.keycode == KEY_F6:
		toggle()
	elif k.keycode == KEY_F7 and active:
		cycle_profile()
