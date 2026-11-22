class_name TestDrive
extends Node3D
## Test drive: your mech (head + loadout from settings) in a generated city district on the ring deck, driven by you.
##   Mouse         look / aim (the mech turns toward where you look, at its own turn rate)
##   W / S         walk forward / back      A / D   strafe       Shift   run      Space   thrusters (jump, hover, brake)
##   N             new city (next seed)     Tab     free / capture the mouse      F1  help      Esc  back to the menu
##   C             first-person / chase camera (cosmetic, local only: ChaseCamera.toggle_first_person)
## Open with `.\run.ps1 -TestDrive [-Seed N]`, or Play -> Launch mission in the menu.
##
## SOLO (offline, or no launched mission): your mech, seed from --seed (default 1), exactly as before co-op.
## CREW MISSION (co-op step 1, Session.mission_params() set by the host's Launch): the seed is the mission's, and there is
##   one mech per crew entry (by seat) at spawn_point(i, n), each built with that entry's head / chassis / accent /
##   loadout and tagged with its owner (MechSpawn.owner_of). Only the local one (owner = Session.local_id()) is `mech`,
##   with the controller input, camera, HUD and combat; the others are PUPPETS in `mechs` (co-op step 2, `crew_sync`:
##   CrewSync streams the local mech and shows each other one from its owner's snapshots, MechPuppet). After building, the city checksum goes to Session.report_mission_built (the load barrier); the local mech is
##   held still until Session.mission_go. Esc ends the mission (the host's ends it for the crew); the host ending it, or
##   the session ending (e.g. sent out for a desync), goes back to the menu. N (new city) is off in a crew mission.

const SCENE := "res://scenes/test_drive.tscn"

var seed_value := 1
var city: CityDistrict
var mech: MechController
var rig: MechRig
var cam: ChaseCamera
var drive_override := false        ## true: leave the mech's inputs alone (tests set them)
var combat: TestDriveCombat        ## weapons (1-5 pick, LMB fire; missiles track the crosshair), PlayerTarget + EnemySquad
var combat_audio: CombatAudio      ## cosmetic combat, prop, player-damage and enemy audio observer
## Every mech in the district: owner peer -> MechController (solo: just `mech`, under CombatWorld.local_peer()).
var mechs: Dictionary = {}
## The owner peers in spawn order (crew seat order); spawn_point(i, n) places the i-th.
var spawn_order: Array[int] = []
## A crew mission launched by the host (Session.mission_params()), not a solo drive.
var crewed := false
## Crew mission: mech snapshots (streams the local mech, shows the others as puppets; scripts/game/crew_sync.gd).
var crew_sync: CrewSync

var _help: Label
var _spawn := Transform3D.IDENTITY
var _ignore_mouse_until := 0      ## msec: the warp right after capturing the mouse arrives as one huge motion; skip it
var _shooting := false
var _held := false                ## crew mission: the local mech stands still until the load barrier passes (mission_go)
var _seats: Dictionary = {}       ## crew mission: owner peer -> crew seat (the snapshots name mechs by seat)


## Authority (scripts/net/net.gd): the seed and the spawn layout are fixed by the mission; everything else here is this
## machine's scene wiring (the mechs declare their own state).
func net_fields() -> Dictionary:
	return {"seed_value": Net.SPAWN, "city": Net.LOCAL, "mech": Net.LOCAL, "rig": Net.LOCAL, "cam": Net.LOCAL,
		"drive_override": Net.LOCAL, "combat": Net.LOCAL, "combat_audio": Net.LOCAL, "mechs": Net.LOCAL,
		"spawn_order": Net.SPAWN, "crewed": Net.SPAWN, "_help": Net.LOCAL, "_spawn": Net.SPAWN,
		"_ignore_mouse_until": Net.LOCAL, "_shooting": Net.LOCAL, "_held": Net.PRIVATE, "crew_sync": Net.LOCAL,
		"_seats": Net.SPAWN}


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var sess := Net.session()
	var params: Dictionary = sess.mission_params() if sess != null and sess.online() else {}
	crewed = not params.is_empty()
	var s := Boot.arg_value(args, "--seed")
	if crewed:
		seed_value = int(params.get("seed", 1))
	elif s.is_valid_int():
		seed_value = int(s)
	city = CityDistrict.new()
	city.name = "City"
	add_child(city)
	if crewed:
		_spawn_crew(params.get("crew", []) as Array, sess.local_id())
	if mech == null:   # solo (or, defensively, a crew list without this machine in it)
		mech = _make_mech()
		add_child(mech)
		mechs[MechSpawn.owner_of(mech)] = mech
		spawn_order.append(MechSpawn.owner_of(mech))
	cam = ChaseCamera.new()
	cam.name = "ChaseCamera"
	cam.target = mech
	add_child(cam)
	cam.current = true
	_build_hud()
	build_city(seed_value)
	combat = TestDriveCombat.new()
	combat.name = "Combat"
	add_child(combat)
	combat.setup(self)
	combat_audio = CombatAudio.new()
	combat_audio.name = "CombatAudio"
	add_child(combat_audio)
	combat_audio.bind(combat.world, combat.rack, city.props, "player%d" % CombatWorld.local_peer())
	combat_audio.bind_squad(combat.squad)
	combat_audio.bind_player_target(combat.player_target)
	var hud := MechHud.for_drive(self)   # weapons, heat, damage, crosshair + aim pips (scripts/ui/mech_hud.gd)
	if combat.player_target != null:
		hud.component_source = combat.player_target.component_fractions
	add_child(hud)
	if crewed:
		crew_sync = CrewSync.new()
		crew_sync.name = "CrewSync"
		add_child(crew_sync)
		crew_sync.setup(self, _seats)
		if hud.crew_panel != null:
			hud.crew_panel.status_source = crew_sync.status
	if DisplayServer.get_name() != "headless" and Audio != null and Audio.music != null:
		Audio.music.set_ambience("city")
		Audio.music.set_mode("calm")
	# --shot <png> [--shot-after s] [--thrust]: walk forward (holding thrust), save the view, quit
	var shot := Boot.arg_value(args, "--shot")
	_shooting = shot != ""
	_capture(not _shooting)
	if crewed:
		_held = true
		sess.mission_go.connect(func(_elapsed: float) -> void: _held = false)
		sess.mission_ended.connect(func(_reason: String) -> void: _back_to_menu())
		sess.session_ended.connect(func(_reason: String) -> void: _back_to_menu())
		sess.report_mission_built(city.plan.checksum())
	if _shooting:
		var after := float(Boot.arg_value(args, "--shot-after")) if Boot.arg_value(args, "--shot-after").is_valid_float() else 4.0
		_shot.call_deferred(shot, after, args.has("--thrust"))


func _shot(path: String, after: float, thrust: bool = false) -> void:
	drive_override = true
	mech.move_input = Vector2(0, 1)
	mech.thrust_input = thrust   # --thrust: the thrusters burn through the shot (flames from the chase camera)
	await get_tree().create_timer(after).timeout
	var err := get_viewport().get_texture().get_image().save_png(path)
	print("shot %s %s" % [path, "ok" if err == OK else "error %d" % err])
	get_tree().quit()


func _exit_tree() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if Audio != null and Audio.music != null:
		Audio.music.set_ambience("off")
		Audio.music.set_mode("off")


## Generate the district for `seed` and put the mechs on the central avenue.
func build_city(seed: int) -> void:
	seed_value = seed
	city.build({"seed": float(seed), "walls": 1.0})
	var n := spawn_order.size()
	for i in n:
		var m: MechController = mechs[spawn_order[i]]
		m.ring = city.ring
		var ma := m.get_node_or_null("Audio") as MechAudio
		if ma != null:
			ma.city = city
		var at := spawn_point(i, n)
		var xf := Transform3D(city.ring.basis_at_arc(at.y), city.ring.arc_to_world(at.x, at.y, CityPlan.CURB_H + 0.3))
		if m == mech:
			_spawn = xf
		else:
			m.global_transform = xf
			m.velocity = Vector3.ZERO
			MechSpawn.rig_of(m).gait.reset([])
	respawn()
	if combat != null:
		combat.rebuild_encounters(self)
	if combat_audio != null and city.props != null:
		combat_audio.bind_props(city.props)


## Where the i-th of n mechs starts, as (x across the avenue, s along it) in the district's arc frame. The central avenue
## crosses the centre of the district (arc 0, 0); a mech alone stands a little up the road (0, 12), facing along it (the
## solo spawn, unchanged); a crew stands in two columns 8 m apart and rows 10 m apart (the capsule is 4.4 m across), on
## the avenue's lanes (20 m wide), in seat order: the same on every machine.
static func spawn_point(i: int, n: int) -> Vector2:
	if n <= 1:
		return Vector2(0.0, 12.0)
	return Vector2(-4.0 + 8.0 * float(i % 2), 12.0 + 10.0 * floorf(i / 2.0))


func respawn() -> void:
	mech.global_transform = _spawn
	mech.velocity = Vector3.ZERO
	rig.gait.reset([])
	cam.reset_behind()


## Crew mission: one mech per crew entry, by seat. The local one becomes `mech` / `rig` (driven, camera, combat).
func _spawn_crew(crew: Array, local_peer: int) -> void:
	var entries := crew.duplicate()
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("seat", 0)) < int(b.get("seat", 0)))
	for e: Dictionary in entries:
		var peer := int(e.get("peer", 0))
		if peer <= 0 or mechs.has(peer):
			continue
		var chassis := str(e.get("chassis", NetSession.DEFAULT_CHASSIS))
		var loadout := NetSession.clean_loadout(chassis, e.get("loadout", {}))
		var m := MechSpawn.make(str(e.get("head", NetSession.DEFAULT_HEAD)), chassis,
			WeaponRegistry.playable_loadout(chassis, loadout)["loadout"], peer, str(e.get("accent", NetSession.DEFAULT_ACCENT)))
		var r := MechSpawn.rig_of(m)
		if peer == local_peer:
			mech = m
			rig = r
		else:
			m.name = "Mech_p%d" % peer   # a puppet of its owner's snapshots (CrewSync / MechPuppet)
			m.puppet = true
		add_child(m)
		mechs[peer] = m
		spawn_order.append(peer)
		_seats[peer] = int(e.get("seat", spawn_order.size()))


## The mech owned by `peer` (null if none).
func mech_of(peer: int) -> MechController:
	return mechs.get(peer) as MechController


func _back_to_menu() -> void:
	if crewed and is_inside_tree() and get_tree().current_scene == self:
		get_tree().change_scene_to_file.call_deferred(Boot.MENU_SCENE)


func _make_mech() -> MechController:
	var st := GameSettings.load_settings()
	var sess := Net.session()
	var head := sess.head_id if sess != null and sess.head_id != "" else str(st["head"])
	var chassis := sess.chassis_id if sess != null and sess.chassis_id != "" else str(st["chassis"])
	# Paused weapons (no behaviour yet) fly the slot's default instead; TestDriveCombat reports the swaps.
	var m := MechSpawn.make(head, chassis, WeaponRegistry.playable_loadout(chassis, st["loadout"] as Dictionary)["loadout"],
		CombatWorld.local_peer(), sess.accent_id if sess != null and sess.accent_id != "" else str(st["accent"]))
	rig = MechSpawn.rig_of(m)
	return m


func _physics_process(_delta: float) -> void:
	if mech == null:
		return
	if _held and not drive_override:
		mech.move_input = Vector2.ZERO
		mech.turn_input = 0.0
		mech.running = false
		mech.thrust_input = false
	elif not drive_override:
		var mv := Vector2.ZERO
		if Input.is_physical_key_pressed(KEY_W): mv.y += 1.0
		if Input.is_physical_key_pressed(KEY_S): mv.y -= 1.0
		if Input.is_physical_key_pressed(KEY_D): mv.x += 1.0
		if Input.is_physical_key_pressed(KEY_A): mv.x -= 1.0
		mech.move_input = mv.limit_length(1.0)
		mech.running = Input.is_physical_key_pressed(KEY_SHIFT)
		mech.thrust_input = Input.is_physical_key_pressed(KEY_SPACE)
		if cam != null:
			cam.zoomed = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
		# Turn the body toward the camera's yaw (full turn input beyond ~15 degrees off).
		mech.turn_input = clampf(cam.yaw_error() * 4.0, -1.0, 1.0)
	# Fell out of the district: back to the spawn.
	if city.ring != null and city.ring.height(mech.global_position) < -25.0:
		respawn()


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if Time.get_ticks_msec() < _ignore_mouse_until:
			return
		cam.add_mouse((e as InputEventMouseMotion).relative.limit_length(300.0))
	elif e is InputEventMouseButton and (e as InputEventMouseButton).pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_capture(true)
	elif e is InputEventKey and (e as InputEventKey).pressed and not (e as InputEventKey).echo:
		match (e as InputEventKey).keycode:
			KEY_ESCAPE:
				if crewed and Net.session() != null:
					Net.session().end_mission()
				get_tree().change_scene_to_file(Boot.MENU_SCENE)
			KEY_TAB:
				_capture(Input.mouse_mode != Input.MOUSE_MODE_CAPTURED)
			KEY_N:
				if not crewed:   # every machine must stay on the mission's seed
					build_city(seed_value + 1)
			KEY_C:
				cam.toggle_first_person()
			KEY_F1:
				_help.visible = not _help.visible


func _capture(on: bool) -> void:
	if DisplayServer.get_name() == "headless":
		return
	if on and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_ignore_mouse_until = Time.get_ticks_msec() + 250
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "Hud"
	add_child(layer)
	var root := Control.new()
	root.name = "HudRoot"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(root)
	_help = Label.new()
	_help.name = "Help"
	_help.text = "LMB fire   RMB zoom   W/S walk   A/D strafe   Shift run   Space thrust   C view   1-5 weapons   N new city   Tab mouse   F1 help   Esc menu"
	_help.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)   # the bottom corners belong to the mech HUD
	_help.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_help.offset_top = 12
	_help.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	_help.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_help.add_theme_constant_override("outline_size", 4)
	root.add_child(_help)
