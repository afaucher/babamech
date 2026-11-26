class_name TestDrive
extends Node3D
## Test drive: your mech (head + loadout from settings) in a generated city district on the ring deck, driven by you.
##   Mouse         look / aim (the mech turns toward where you look, at its own turn rate)
##   W / S         walk forward / back      A / D   strafe       Shift   run      Space   thrusters (jump, hover, brake)
##   N             new city (next seed)     Tab     free / capture the mouse      F1  help      Esc  back to the menu
##   C             first-person / chase camera (cosmetic, local only: ChaseCamera.toggle_first_person)
##   Space (held, while DOWNED)  respawn after 3 s + a 5 s redeploy (DownedRules; a crewmate's repair drone revives instead)
## Open with `.\run.ps1 -TestDrive [-Seed N]`, or Play -> Launch mission in the menu.
##
## THE CITY (city_mode): STACK (the default; `--stack`) builds the multi-deck mission section (SectionPlan from the seed,
##   CityStack, docs/design/city-ramps-and-stack.md) and spawns the crew on the section's entry road
##   (CityStack.entry_transform(), entry_spawn()). The stack is placed so the ENTRY DECK's floor passes through the world
##   origin (stack.position = -section.deck_offset(entry deck)): `city` is that deck's CityDistrict, so every system that
##   still reads one district (combat, enemy spawner, audio, player AI) gets a plan and a RingFrame that are right in
##   world space on the entry deck. Every mech's ring is `city.ring`: the axis is shared, so its up / gravity is right on
##   every deck (CityStack.ring() / deck_ring(k) would do too). Falling out is CityStack.fell_out(); each mech's
##   MechAudio reads footstep surfaces from the deck it is on (_follow_audio_decks). Every deck's props are networked
##   (prop events carry the deck). The stack is the only city (the single-district mode was cut with the legacy
##   modes, user 2026-11-25); the load barrier compares mission_checksum() (CityStack.checksum() + the plan's).
## SOLO (offline, or no launched mission): your mech; seed from the menu's Launch (solo_launch: a fresh random
##   seed, like a host's), else --seed (default 1).
## CREW MISSION (co-op step 1, Session.mission_params() set by the host's Launch): the seed is the mission's, and there is
##   one mech per crew entry (by seat) at crew_spawn(i, n), each built with that entry's head / chassis / accent /
##   loadout and tagged with its owner (MechSpawn.owner_of). Only the local one (owner = Session.local_id()) is `mech`,
##   with the controller input, camera, HUD and combat; the others are PUPPETS in `mechs` (co-op step 2, `crew_sync`:
##   CrewSync streams the local mech and shows each other one from its owner's snapshots, MechPuppet). After building, the city checksum goes to Session.report_mission_built (the load barrier); the local mech is
##   held still until Session.mission_go. Esc ends the mission (the host's ends it for the crew); the host ending it, or
##   the session ending (e.g. sent out for a desync), goes back to the menu. N (new city) is off in a crew mission.
## HANGAR BOTS (docs/design/hangar-bots.md): a crew entry with "bot": true (pilot id < 0) gets a mech whose chassis and
##   loadout every machine derives from the seed and the bot slot (BotLoadout.pick). On the host it is a real mech run by
##   a CrewBot (`crew_bots`: PlayerTarget, WeaponRack, MissionBot from mission_go), streamed by CrewSync; elsewhere a
##   puppet. Its MechController.owner_peer is 1 (the host's machine); its pilot id is MechSpawn.owner_of. crew_members()
##   lists every pilot with its mech.
## ENEMIES (spawn_enemies, called by TestDriveCombat.rebuild_encounters): solo, EnemySpawner from the seed in front of the
##   spawn, as before. Crew mission (W4, `enemy_sync`, scripts/game/enemy_sync.gd): only the HOST spawns them (in front of
##   the entry, scaled to the crew size) and runs their AI; it streams them and each client
##   shows puppets. Stack: an encounter on every deck (its own plan and ring); each enemy carries `spawn_deck`, stays on
##   its deck and engages only mechs on it: enemies_alive_per_deck() for MissionRules.
## MISSION (W6, win side; `mission`, scripts/game/mission_flow.gd): the plan's objectives (the one mission mode) on every
##   machine; the host (or solo, locally) evaluates them once the mission is released and the enemies have spawned
##   (`enemies_spawned`), clients apply the host's "mission.state". The HUD shows the objectives (MissionHud). TEST-ONLY:
##   with MissionFlow.test_quiet (QuietSectionFixture) no plan is built and the full garrison stands. On the outcome every machine shows the banner, then the host ends the mission for the crew and
##   everyone goes back to the hangar (solo: FrontEnd.next_screen = "hangar"); only when this scene is the current one.

const SCENE := "res://scenes/test_drive.tscn"
const MODE_STACK := NetMission.MODE_STACK         ## "stack": the multi-deck mission section (CityStack), the default
const OFFLINE_PEER := 9000              ## offline crew: fake owner peer = OFFLINE_PEER + seat
const FALL_OUT := 25.0               ## m below the lowest floor: fell out of the city, back to the spawn
const KEEPALIVE_CHUNK_MS := 40.0     ## crew mission, unstepped load: stack build chunks between two transport services
const DEV_FAST_CLEAR := 10.0         ## DEV ONLY: --dev-fast-clear, enemies take this many times the damage
const STEP_BUDGET_MS := 8.0          ## stepped load: wall time per frame for the stack build / life setup

## The menu's solo Launch hands its {seed, mode, friendly_fire} to the next test drive here (consumed by _ready).
static var solo_launch: Dictionary = {}
## Tests (perf): a solo test drive with an OFFLINE CREW of this many mechs and no session (also `--offline-crew N`).
## Mechs 2..N are idle puppets (no input, no physics, no MechPuppet) with fake owner peers OFFLINE_PEER + seat, placed at
## the crew slots like a real crew; their rigs, gait, FX and audio still run. 0 / 1 = just your mech. Read once by _ready.
static var offline_crew := 0
## Tests (test_net_load_stall): a crew CLIENT blocks its main thread this many ms in _ready, right before the build (a
## slow laptop's load, with no transport servicing at all). 0 = off. Read once by _ready.
static var test_stall_ms := 0
## A crew mission in the stack loads STEPPED: CityStack.build_step and AmbientLife.setup_step once per frame with a
## progress line, mission.ready only after both. False: the whole load in _ready (crew tests that check the scene two
## frames after adding it; NetTest sets it, tests of the stepped load set it back). Solo always loads in _ready.
static var stepped_load := true
## Tests: run the mission bot (MissionBot) with this profile as if `--bot <profile>` were given ("" = only the flag).
static var bot_profile := ""
## Tests: DEV `--dev-bot-travel` for the mission bot (MissionBot.dev_travel).
static var dev_bot_travel := false
## Solo: put the loading screen up and let it draw (COVER_FRAMES) before the synchronous build, which blocks frames. Off
## under --run-test (most tests check the scene right after adding it: their solo load stays inside _ready, behind a
## screen that never draws) unless a test sets this.
static var cover_solo := false
const COVER_FRAMES := 2

var seed_value := 1
## The crew's friendly fire option (the host's hangar choice, carried in mission.launch; solo: the hangar's, in
## solo_launch). True whenever it is absent. Set in _ready before TestDriveCombat sets up (which reads it once).
var friendly_fire := true
var prebuilt_plan: MissionPlan = null   ## stepped load: the plan whose MissionWorld was set up over frames
## Always MODE_STACK (the only city; what the launch's "mode" and the loading screen carry). Tests may still set it.
var city_mode := MODE_STACK
## Every deck of the mission section (the entry deck at the world origin).
var stack: CityStack
## The district the single-district systems use: the stack's entry deck.
var city: CityDistrict
var mech: MechController
var rig: MechRig
var cam: ChaseCamera
var drive_override := false        ## true: leave the mech's inputs alone (tests set them)
var combat: TestDriveCombat        ## weapons (1-5 pick, LMB fire; missiles track the crosshair), PlayerTarget + EnemySquad
var combat_audio: CombatAudio      ## cosmetic combat, prop, player-damage and enemy audio observer
## Every mech in the district: owner peer -> MechController (solo: just `mech`, under CombatWorld.local_peer()).
var mechs: Dictionary = {}
## The owner peers in spawn order (crew seat order); crew_spawn(i, n) places the i-th.
var spawn_order: Array[int] = []
## A crew mission launched by the host (Session.mission_params()), not a solo drive.
var crewed := false
## Crew mission: mech snapshots (streams the local mech, shows the others as puppets; scripts/game/crew_sync.gd).
var crew_sync: CrewSync
## Crew mission, host: the hangar bots this machine runs, pilot id (< 0) -> CrewBot (scripts/game/crew_bot.gd).
var crew_bots: Dictionary = {}
## Crew mission: each bot's accent, derived from the seed and the crew (BotLoadout.accents), pilot id -> MechAccent id.
var _bot_accents: Dictionary = {}
## Crew mission: the host's enemies streamed to the crew, puppets on a client (W4; scripts/game/enemy_sync.gd).
var enemy_sync: EnemySync
## The civilians and vehicles of the city (W5; scripts/world/life/ambient_life.gd): ONE per scene (group "ambient_life"),
## on every machine; the host arbitrates through Session events, offline it decides locally. Built after the city and
## the combat world (_build_life), rebuilt with the city (solo N).
var life: AmbientLife
var banners: OccupationBanners     ## the invaders' banners on every deck (scripts/world/occupation/, docs/design/banners.md)
## The mission's objectives and end (W6; scripts/game/mission_flow.gd).
var mission: MissionFlow
## This machine has spawned the mission's enemies (host / solo; spawn_enemies): MissionFlow evaluates only after that.
var enemies_spawned := false

var _help: Label
var _spawn := Transform3D.IDENTITY
var _ignore_mouse_until := 0      ## msec: the warp right after capturing the mouse arrives as one huge motion; skip it
var _shooting := false
var _held := false                ## crew mission: the local mech stands still until the load barrier passes (mission_go)
var _seats: Dictionary = {}       ## crew mission: owner peer -> crew seat (the snapshots name mechs by seat)
var _audio_deck: Dictionary = {}  ## stack: owner peer -> the deck its MechAudio reads footstep surfaces from
var _audio_check := 0.0           ## s until the next per-deck MechAudio check
var _leaving := false             ## a scene change back to the menu is under way
var _note_label: Label            ## crew mission: "c1 dropped: went silent while loading" (Session.crew_note), a few s
var _note_until := 0              ## msec the note hides at
var _left: Array[int] = []        ## host: pilots retired for good (crew_member_left fired), in order
var _told: Array[int] = []        ## host: pilots MissionFlow.on_member_retired was called for (tests)
var _flow: Dictionary = {}        ## [Flow] log watch: {contact, done: [objective ids], outcome, kills, check}
## The scene is fully set up (city, combat, life, HUD, crew sync): right after _ready for solo and unstepped loads,
## after the last step of a stepped crew load. `mission_loaded` fires then too. Wait for it before measuring.
signal mission_loaded()
## HOST ONLY: a crew member (player or hangar bot) is gone for good: its mech was retired (CrewSync.retire), and
## crew_members() no longer lists it. Once per pilot. MissionFlow.on_member_retired(pilot_id) is called at the same moment
## (duck-typed; for a retire during the load, as soon as MissionFlow exists): the host recomputes its crew scale.
signal crew_member_left(pilot_id: int)

## A stepped crew load is under way: the city, combat and life aren't there yet (no input, physics or HUD use).
var loading := false
var loaded := false
## --bot: the AI playing this machine's mech through the mission (scripts/game/mission_bot.gd), null otherwise.
var bot: MissionBot
var _t_load := 0                  ## msec the load started
var _t_city := 0                  ## msec the city was done
## ShaderWarmup is drawing every look behind its overlay (the load's first frames and its last ones; not headless).
var warming := false
## The mission loading screen (scripts/ui/loading_screen.gd): up from the first line of _ready until mission_go (crew) or
## the end of the solo load, and again while leaving. Null once it has come down.
var loading_screen: LoadingScreen
var _hud: MechHud                 ## the mech HUD, hidden while the loading screen is up
var _hud_layer: CanvasLayer       ## the help / note layer, hidden while the loading screen is up
## Downed / revive / respawn on this machine (scripts/game/downed_crew.gd, DownedRules): the call for help, the HUD, the
## respawn point, the bots' wait. While the local mech is downed it gets no movement and no weapons, and SPACE (the
## `respawn` action) is the hold-to-respawn key instead of the thrusters.
var downed: DownedCrew
var _rack_muted := false          ## the local rack's input is off because the mech is downed


## Authority (scripts/net/net.gd): the seed and the spawn layout are fixed by the mission; everything else here is this
## machine's scene wiring (the mechs declare their own state).
func net_fields() -> Dictionary:
	return {"seed_value": Net.SPAWN, "city_mode": Net.SPAWN, "friendly_fire": Net.SPAWN,"prebuilt_plan": Net.LOCAL, "stack": Net.LOCAL, "city": Net.LOCAL, "mech": Net.LOCAL,
		"rig": Net.LOCAL, "cam": Net.LOCAL, "enemy_sync": Net.LOCAL, "life": Net.LOCAL, "banners": Net.LOCAL, "_audio_deck": Net.LOCAL, "_audio_check": Net.LOCAL,
		"drive_override": Net.LOCAL, "combat": Net.LOCAL, "combat_audio": Net.LOCAL, "mechs": Net.LOCAL,
		"spawn_order": Net.SPAWN, "crewed": Net.SPAWN, "_help": Net.LOCAL, "_spawn": Net.SPAWN,
		"_ignore_mouse_until": Net.LOCAL, "_shooting": Net.LOCAL, "_held": Net.PRIVATE, "crew_sync": Net.LOCAL, "crew_bots": Net.LOCAL, "_bot_accents": Net.SPAWN,
		"_seats": Net.SPAWN, "mission": Net.LOCAL, "enemies_spawned": Net.LOCAL,
		"_leaving": Net.LOCAL, "_note_label": Net.LOCAL, "_note_until": Net.LOCAL, "_flow": Net.LOCAL,
		"loading": Net.LOCAL, "loaded": Net.LOCAL, "bot": Net.LOCAL, "_t_load": Net.LOCAL, "_t_city": Net.LOCAL,
		"warming": Net.LOCAL, "loading_screen": Net.LOCAL, "_hud": Net.LOCAL, "_hud_layer": Net.LOCAL, "downed": Net.LOCAL,
		"_rack_muted": Net.LOCAL, "_left": Net.LOCAL, "_told": Net.LOCAL}


func _ready() -> void:
	# The loading screen before anything else: no frame may show the city being built, the camera or the HUD.
	loading_screen = LoadingScreen.cover(self)
	add_to_group(GraphicsQuality.GROUP)   # _on_graphics_quality when the setting changes
	var args := OS.get_cmdline_user_args()
	if DisplayServer.get_name() != "headless":
		HitchLog.attach(self, func() -> String: return "warmup" if warming else ("play" if loaded else "load"))
	if args.has("--no-shader-warmup"):
		ShaderWarmup.enabled = false   # DEV: measure without the warm-up
	var sess := Net.session()
	var params: Dictionary = sess.mission_params() if sess != null and sess.online() else {}
	crewed = not params.is_empty()
	var s := Boot.arg_value(args, "--seed")
	if crewed:
		seed_value = int(params.get("seed", 1))
		friendly_fire = bool(params.get("friendly_fire", true))
	elif not solo_launch.is_empty():
		seed_value = int(solo_launch.get("seed", 1))
		friendly_fire = bool(solo_launch.get("friendly_fire", true))
		solo_launch = {}
	elif s.is_valid_int():
		seed_value = int(s)
	city_mode = MODE_STACK   # the only city
	var mode := city_mode
	loading_screen.friendly_fire = friendly_fire
	loading_screen.set_mission(seed_value, city_mode)
	if crewed:
		loading_screen.crew_source = _crew_rows
	_t_load = Time.get_ticks_msec()
	if crewed:
		# Tell the host this machine is building (a slow laptop takes seconds). The stepped load builds over frames; the
		# unstepped one blocks this frame and keeps the transport serviced between its steps (_keep_alive).
		sess.report_mission_loading()
		sess.service_transport()
		FlowLog.say("load start", "seed %d, %s" % [seed_value, mode])
		if test_stall_ms > 0 and not sess.hosting:
			print("[TestDrive] test stall: blocking the main thread %d ms" % test_stall_ms)
			OS.delay_msec(test_stall_ms)
	stack = CityStack.new()
	stack.set_quality(GraphicsQuality.level())   # presentation only, any time (Settings > Graphics quality)
	stack.name = "Stack"
	add_child(stack)
	if crewed:
		_spawn_crew(params.get("crew", []) as Array, sess.local_id())
	if mech == null:   # solo (or, defensively, a crew list without this machine in it)
		mech = _make_mech()
		add_child(mech)
		mechs[MechSpawn.owner_of(mech)] = mech
		spawn_order.append(MechSpawn.owner_of(mech))
		var extra := Boot.arg_value(args, "--offline-crew")
		_spawn_offline_crew(int(extra) if extra.is_valid_int() else offline_crew)
	cam = ChaseCamera.new()
	cam.name = "ChaseCamera"
	cam.target = mech
	add_child(cam)
	cam.current = true
	if stack != null:
		stack.follow(cam)   # the daylight lights the deck this machine's camera is on (local presentation)
	_build_hud()
	if crewed:
		# Connected before the load, so the session ending (or the host ending the mission) while loading leaves too.
		_held = true
		sess.mission_go.connect(func(_elapsed: float) -> void: _held = false)
		sess.mission_go.connect(func(_elapsed: float) -> void: _uncover())
		sess.mission_ended.connect(func(_reason: String) -> void: _back_to_menu())
		sess.session_ended.connect(func(_reason: String) -> void: _back_to_menu())
		sess.crew_note.connect(_show_note)
		sess.mission_go.connect(func(_e: float) -> void: _flow_watch())
	if crewed and stack != null and stepped_load:
		_load_stepped(args)   # a coroutine: returns at its first frame
		return
	if not crewed and (cover_solo or not OS.get_cmdline_user_args().has("--run-test")):
		_load_solo(args)   # a coroutine: the loading screen draws first, then the synchronous build
		return
	_keep_alive()
	loading_screen.set_phase("build", 0.0)
	build_city(seed_value)
	_cover_section()
	_t_city = Time.get_ticks_msec()
	_finish_setup(args, false)


## The stepped crew load: the mechs wait (no physics) while the stack builds a few ms per frame, then the scene is set
## up and AmbientLife sets up a few ms per frame; mission.ready goes only after both (so mission.go waits for every
## machine's whole load).
func _load_stepped(args: PackedStringArray) -> void:
	loading = true
	for p: int in mechs:
		(mechs[p] as Node).process_mode = Node.PROCESS_MODE_DISABLED
	stack.position = Vector3.ZERO
	if ShaderWarmup.should_run():   # the shared materials first, so the build's frames don't compile them
		warming = true
		loading_screen.set_phase("shaders_pre", 0.0)
		await ShaderWarmup.warm(cam, null, "", false)
		warming = false
		if _leaving or not is_inside_tree():
			return
	var sec := SectionPlan.make({"seed": float(seed_value)})
	loading_screen.set_section(sec)
	stack.build_begin(sec)
	while not stack.build_step(STEP_BUDGET_MS):
		_show_loading(stack.build_progress())
		await get_tree().process_frame
		if _leaving or not is_inside_tree():
			return
	build_city(seed_value, true)
	_t_city = Time.get_ticks_msec()
	for p: int in mechs:
		(mechs[p] as Node).process_mode = Node.PROCESS_MODE_INHERIT
	await _finish_setup(args, true)


## Solo: the loading screen draws its first frames (the window shows it, not the hangar or a half-built city), then the
## synchronous build and setup run as before, then the warm-up; the screen comes down at the end of _finish_setup.
func _load_solo(args: PackedStringArray) -> void:
	loading = true
	for p: int in mechs:
		(mechs[p] as Node).process_mode = Node.PROCESS_MODE_DISABLED
	for i in COVER_FRAMES:
		await get_tree().process_frame
		if _leaving or not is_inside_tree():
			return
	loading_screen.set_section(SectionPlan.make({"seed": float(seed_value)}))   # cheap: plan data only
	loading_screen.set_phase("build", 0.05)
	await get_tree().process_frame
	if _leaving or not is_inside_tree():
		return
	build_city(seed_value)
	_t_city = Time.get_ticks_msec()
	_cover_section()
	loading_screen.set_phase("populate", 0.0)
	for p: int in mechs:
		(mechs[p] as Node).process_mode = Node.PROCESS_MODE_INHERIT
	loading = false
	await _finish_setup(args, false)


## The stack build's progress on the loading screen (the "build" phase).
func _show_loading(f: float) -> void:
	if loading_screen != null:
		loading_screen.set_phase("build", f)


## The section line on the loading screen once the stack is built.
func _cover_section() -> void:
	if loading_screen != null and stack != null and stack.section != null:
		loading_screen.set_section(stack.section)


## The crew rows the loading screen lists: every member of the launch, by seat, ready once it has reported its build.
func _crew_rows() -> Array:
	var sess := Net.session()
	if sess == null or not sess.online():
		return []
	var ready := sess.mission_ready_peers()
	var out: Array = []
	var entries := (sess.mission_params().get("crew", []) as Array).duplicate()
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("seat", 0)) < int(b.get("seat", 0)))
	for e: Dictionary in entries:
		var p := int(e.get("peer", 0))
		if not sess.has_member(p):
			continue
		var bot := sess.is_bot(p)   # a bot loads with the host's machine: never waited for
		out.append({"peer": p, "name": str(e.get("name", p)), "head": str(e.get("head", "")),
			"accent": str(_bot_accents.get(p, e.get("accent", NetSession.DEFAULT_ACCENT))), "status": "ready" if bot or ready.has(p) else "loading",
			"local": p == sess.local_id()})
	return out


## Hide or show the HUD (the mech HUD and the help / note layer) under the loading screen.
func _set_hud_shown(on: bool) -> void:
	if _hud != null and is_instance_valid(_hud):
		_hud.visible = on
	if _hud_layer != null and is_instance_valid(_hud_layer):
		_hud_layer.visible = on


## The mission starts here (mission_go, or the solo load is done): the HUD comes back and the loading screen fades out.
func _uncover() -> void:
	if _leaving or loading_screen == null or not is_instance_valid(loading_screen):
		return
	_set_hud_shown(true)
	loading_screen.finish()
	loading_screen = null


## Leave this scene for `scene` behind a loading screen: it is up (and has drawn a frame) before anything is torn down,
## and the next scene (the menu) puts its own up first (LoadingScreen.handoff), so no frame shows a half-freed mission.
func _leave_to(scene: String) -> void:
	_leaving = true
	if loading_screen == null or not is_instance_valid(loading_screen) or loading_screen.fading:
		loading_screen = LoadingScreen.cover(self)
		loading_screen.friendly_fire = friendly_fire
		loading_screen.set_mission(seed_value, city_mode)
	loading_screen.set_phase("leave")
	_set_hud_shown(false)
	LoadingScreen.handoff = true
	LoadingScreen.handoff_phase = "leave"
	await get_tree().process_frame
	await get_tree().process_frame
	if is_inside_tree():
		get_tree().change_scene_to_file(scene)


## Everything after the city: combat, audio, life, HUD, the crew's sync, the mission, then (crew) mission.ready.
## `stepped`: life sets up over frames (AmbientLife.setup_step) before the report.
func _finish_setup(args: PackedStringArray, stepped: bool) -> void:
	var sess := Net.session()
	_keep_alive()
	combat = TestDriveCombat.new()
	combat.name = "Combat"
	add_child(combat)
	combat.setup(self)
	_keep_alive()
	combat_audio = CombatAudio.new()
	combat_audio.name = "CombatAudio"
	add_child(combat_audio)
	combat_audio.bind(combat.world, combat.rack, city.props, "player%d" % CombatWorld.local_peer())
	combat_audio.bind_squad(combat.squad)
	combat_audio.bind_player_target(combat.player_target)
	if stepped:
		life = AmbientLife.new()
		life.set_quality(GraphicsQuality.level())
		life.name = "AmbientLife"
		add_child(life)
		life.setup_stack_begin(stack)
		var steps := 0
		loading_screen.set_phase("populate", 0.0)
		while not life.setup_step(STEP_BUDGET_MS):
			steps += 1
			loading_screen.set_phase("populate", 1.0 - pow(0.93, float(steps)))   # no count to read: ease toward the end
			await get_tree().process_frame
			if _leaving or not is_inside_tree():
				return
		_bind_life()
		if stack != null:
			# The banners deck by deck (OccupationBanners.setup_step: one deck per call, 3-19 ms each).
			banners = _new_banners()
			banners.setup_begin(stack, combat.world)
			while not banners.setup_step(STEP_BUDGET_MS):
				await get_tree().process_frame
				if _leaving or not is_inside_tree():
					return
		loading = false
	else:
		if loading_screen != null:
			loading_screen.set_phase("populate", 0.0)
		_build_life()
		if stack != null:
			banners = _new_banners()
			banners.setup(stack, combat.world)
	_keep_alive()
	var hud := MechHud.for_drive(self)   # weapons, heat, damage, crosshair + aim pips (scripts/ui/mech_hud.gd)
	if combat.player_target != null:
		hud.component_source = combat.player_target.component_fractions
	add_child(hud)
	_hud = hud
	_set_hud_shown(loading_screen == null)
	if crewed:
		_setup_crew_bots()
		crew_sync = CrewSync.new()
		crew_sync.name = "CrewSync"
		add_child(crew_sync)
		crew_sync.setup(self, _seats)
		if hud.crew_panel != null:
			hud.crew_panel.status_source = crew_sync.status
		enemy_sync = EnemySync.new()
		enemy_sync.name = "EnemySync"
		add_child(enemy_sync)
		enemy_sync.setup(self)
	if stepped and not MissionFlow.test_quiet and stack != null and stack.section != null:
		# The mission world (wave doors, flag masts, relays, portal) sets up over frames too
		# (CityStack.setup_mission_begin / step), so a slow machine keeps its link and the loading screen keeps moving.
		prebuilt_plan = MissionPlan.make(stack.section, MissionFlow.test_plan)
		stack.setup_mission_begin(prebuilt_plan)
		while not stack.setup_mission_step(STEP_BUDGET_MS):
			if loading_screen != null:
				loading_screen.set_phase("populate", 0.9 + 0.1 * stack.setup_mission_progress())
			await get_tree().process_frame
			if _leaving or not is_inside_tree():
				return
	if stack != null:
		mission = MissionFlow.new()
		mission.name = "MissionFlow"
		add_child(mission)
		mission.setup(self)
		mission.finished.connect(func(_o: String) -> void: _leave_mission())
		for id: int in _left:
			_tell_mission_retired(id)   # retired while the mission loaded, before MissionFlow existed
		CombatLog.attach(self)   # [Flow] damage taken / dealt lines (scripts/game/combat_log.gd; off: --no-combat-log)
	downed = DownedCrew.attach(self)   # downed / revive / respawn: the call for help, HUD, respawn point, bots' wait
	if DisplayServer.get_name() != "headless" and Audio != null and Audio.music != null:
		Audio.music.set_ambience("city")
		Audio.music.set_mode("calm")
	if ShaderWarmup.should_run():
		# Every look in the scene (all decks, mechs, enemies, heads, life) and what play makes later (FX), drawn once
		# behind an overlay before play: solo too (paused), whose build was synchronous.
		warming = true
		var was_paused := get_tree().paused
		if not crewed:
			get_tree().paused = true
		if loading_screen != null:
			loading_screen.set_phase("shaders", 0.0)
		await ShaderWarmup.warm(cam, self, "", loading_screen == null)
		if is_inside_tree():
			get_tree().paused = was_paused
		warming = false
		if _leaving or not is_inside_tree():
			return
	# --shot <png> [--shot-after s] [--thrust]: walk forward (holding thrust), save the view, quit
	var shot := Boot.arg_value(args, "--shot")
	_shooting = shot != ""
	_capture(not _shooting)
	if HangarHandoff.playing():
		# The hangar's launch egress is still playing over the loading screen (HangarHandoff): report at the load
		# barrier / start only once it is over too (docs/design/hangar-v2/README.md). Solo waits paused.
		var was_paused := get_tree().paused
		if not crewed:
			get_tree().paused = true
		await HangarHandoff.wait_done()
		if is_inside_tree():
			get_tree().paused = was_paused
		if _leaving or not is_inside_tree():
			return
	if crewed:
		var ms := Time.get_ticks_msec() - _t_load
		FlowLog.say("load done", "%d ms%s (city %d ms, stack build %s ms, longest chunk %s ms), checksum %s" % [ms,
			" stepped" if stepped else "", _t_city - _t_load, str(stack.stats.get("ms", "?")) if stack != null else "-",
			str(stack.stats.get("max_chunk_ms", "?")) if stack != null else "-", mission_checksum()])
		if not sess.online():
			_back_to_menu.call_deferred()   # the session ended inside the build (seen by a keep-alive poll)
		else:
			sess.report_mission_built(mission_checksum(), ms)
			if loading_screen != null:
				loading_screen.set_phase("crew", 1.0)   # until mission_go (_uncover)
			if sess.mission.phase == NetMission.RUNNING:
				_uncover()   # the barrier passed already
	if not crew_bots.is_empty():
		if sess.mission.phase == NetMission.RUNNING:
			_start_crew_bots()
		else:
			sess.mission_go.connect(func(_e: float) -> void: _start_crew_bots())
	if args.has("--dev-fast-clear"):
		CombatWorld.dev_enemy_damage = DEV_FAST_CLEAR
		print("[TestDrive] DEV --dev-fast-clear: enemies take %.0fx damage" % DEV_FAST_CLEAR)
	if (args.has("--bot") or bot_profile != "") and stack != null:
		# --bot [profile]: the AI plays the mission (MissionBot). A crew's bot starts when the barrier passes.
		var profile := bot_profile if bot_profile != "" else Boot.arg_value(args, "--bot")
		if crewed:
			sess.mission_go.connect(func(_e: float) -> void:
				if bot == null and is_inside_tree():
					bot = MissionBot.attach(self, profile))
		else:
			bot = MissionBot.attach(self, profile)
			_flow_watch()
	loaded = true
	if not crewed:
		_uncover()   # solo: the load and warm-up are done
	mission_loaded.emit()
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


## Crew mission: service the transport from inside the blocking load (Session.service_transport: no dispatch).
func _keep_alive() -> void:
	var sess := Net.session()
	if crewed and sess != null:
		sess.service_transport()


## Crew mission: a short line under the help text ("c1 dropped: went silent while loading"), for a few seconds.
func _show_note(text: String) -> void:
	if _note_label == null:
		return
	_note_label.text = text
	_note_label.visible = true
	_note_until = Time.get_ticks_msec() + 8000


func _process(delta: float) -> void:
	if _note_label != null and _note_label.visible and Time.get_ticks_msec() > _note_until:
		_note_label.visible = false
	if not _flow.is_empty():
		_flow["check"] = float(_flow["check"]) - delta
		if float(_flow["check"]) <= 0.0:
			_flow["check"] = 0.25
			_flow_progress()


## [Flow] lines for the mission's transitions on this machine (FlowLog): first enemy contact, each kill, each objective
## (objective done <id>), the outcome. Started at mission_go (crew) or at once (solo with --bot).
func _flow_watch() -> void:
	if not _flow.is_empty() or combat == null:
		return
	_flow = {"contact": false, "done": [], "outcome": "", "kills": 0, "check": 0.0}
	combat.world.hit_landed.connect(func(t: CombatTarget, h: Hit) -> void:
		if t is BannerTarget:
			return   # tearing a banner is not enemy contact
		if not bool(_flow.get("contact", true)) and (t.team == "enemy" or str(h.shooter).begins_with("enemy") or t.team == "player"):
			_flow["contact"] = true
			FlowLog.say("first enemy contact", "%s hit %s" % [h.shooter, t.target_id]))
	if combat.squad != null:
		for e in combat.squad.enemies:
			_flow_enemy(e)
		combat.squad.enemy_spawned.connect(_flow_enemy)


func _flow_enemy(e: EnemyBase) -> void:
	if not is_instance_valid(e):
		return
	e.destroyed_enemy.connect(func(en: EnemyBase, cause: String, _at: Vector3) -> void:
		_flow["kills"] = int(_flow.get("kills", 0)) + 1
		FlowLog.say("enemy killed", "%s (deck %d, %s), kill %d, alive per deck %s" % [en.name, en.spawn_deck, cause,
			int(_flow["kills"]), str(enemies_alive_per_deck())]))


func _flow_progress() -> void:
	if mission == null or mission.rules == null:
		return
	var st := mission.rules.state()
	var done: Array = _flow["done"]
	for id: Variant in st.get("done", []) as Array:
		if not done.has(id):
			done.append(id)
			FlowLog.say("objective done", str(id))
	var outcome := str(st.get("outcome", ""))
	if outcome != "" and outcome != str(_flow["outcome"]):
		_flow["outcome"] = outcome
		FlowLog.say("mission " + outcome, str(st.get("reason", "")))


## Generate the stack for `seed` and put the mechs at the start: the stack's entry road.
func build_city(seed: int, built: bool = false) -> void:
	seed_value = seed
	if built:
		pass   # the stepped load built it (CityStack.build_step)
	elif crewed:
		stack.position = Vector3.ZERO
		# The chunked build (CityStack.build_begin / build_step), the transport serviced between chunks so a slow machine
		# keeps its link alive; the same city and checksum as build().
		stack.build_begin(SectionPlan.make({"seed": float(seed)}))
		while not stack.build_step(KEEPALIVE_CHUNK_MS):
			_keep_alive()
	else:
		stack.position = Vector3.ZERO
		stack.build(SectionPlan.make({"seed": float(seed)}))
	var k := int(stack.section.entry["deck"])
	stack.position = -stack.section.deck_offset(k)   # the entry deck's floor through the world origin
	city = stack.decks[k]
	var n := spawn_order.size()
	for i in n:
		var m := mech_of(spawn_order[i])
		if m == null:
			continue   # a member who left (CrewSync.retire): spawn_order keeps the launch crew's slots
		m.ring = city.ring   # stack: the entry deck's frame, on the shared axis (right on every deck)
		var ma := m.get_node_or_null("Audio") as MechAudio
		if ma != null:
			ma.city = city
		_audio_deck.erase(spawn_order[i])
		# The stack's crew slots: one column per carriageway (clear of the planted median and the rail lane), rows going
		# in, slid past anything blocking (plan data only: the same on every machine).
		var xf := crew_spawn(i, n)
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
	if life != null:
		_setup_life()
	if banners != null:
		banners.setup(stack, combat.world)
	if mission != null:
		mission.rebuild()   # solo N: the new city's section and objectives


## Ambient life for this scene: the city's civilians and vehicles, pushed by every mech (puppets too: src = owner peer)
## and every enemy (src -1), seen from every mech and the camera.
func _new_banners() -> OccupationBanners:
	var b := OccupationBanners.new()
	b.name = "OccupationBanners"
	b.set_quality(GraphicsQuality.level())
	add_child(b)
	return b


func _build_life() -> void:
	life = AmbientLife.new()
	life.set_quality(GraphicsQuality.level())
	life.name = "AmbientLife"
	add_child(life)
	_setup_life()
	_bind_life(false)


## Wire life to the scene once its units exist: the pushers (after a stepped setup: `pushers`), the combat world, the
## viewers, enemies coming and going.
func _bind_life(pushers: bool = true) -> void:
	if pushers:
		for p: int in mechs:
			life.add_pusher(mechs[p], 1.0, _pusher_src(p))
		if combat.squad != null:
			for e in combat.squad.enemies:
				if is_instance_valid(e):
					life.add_pusher(e, e.body_radius, -1)
	life.bind_combat(combat.world)
	for p: int in mechs:
		life.add_viewer(mechs[p])
	life.add_viewer(cam)
	if combat.squad != null:
		combat.squad.enemy_spawned.connect(func(e: EnemyBase) -> void:
			if life != null and is_instance_valid(e):
				life.add_pusher(e, e.body_radius, -1))
		combat.squad.enemy_removed.connect(func(e: EnemyBase) -> void:
			if life != null:
				life.remove_pusher(e))


## (Re)build life on the current city and register the pushers (also after N rebuilt the city).
## Settings > Graphics quality changed (GraphicsQuality.notify): the city and the ambient life redraw at the new level
## (presentation only: no checksum, collision or synced state changes).
func _on_graphics_quality(q: int) -> void:
	if stack != null:
		stack.set_quality(q)
	if life != null:
		life.set_quality(q)
	if banners != null:
		banners.set_quality(q)


func _setup_life() -> void:
	life.setup_stack(stack)
	for p: int in mechs:
		life.add_pusher(mechs[p], 1.0, _pusher_src(p))
	if combat != null and combat.squad != null:
		for e in combat.squad.enemies:
			if is_instance_valid(e):
				life.add_pusher(e, e.body_radius, -1)


## Where the i-th of n mechs starts, around the section's entry transform (CityStack.entry_transform(): on the avenue
## lane of the entry road, 18 m wide, facing into the map): alone, right on the entry; a crew in two columns 8 m apart
## across the lane and rows 10 m apart going in, in seat order. Offsets follow
## the deck's curve (arc coordinates of `deck`), each mech faces into the map. The same on every machine.
static func entry_spawn(entry: Transform3D, deck: CityDistrict, i: int, n: int) -> Transform3D:
	var off := Vector2.ZERO if n <= 1 else Vector2(-4.0 + 8.0 * float(i % 2), 10.0 * floorf(i / 2.0))
	var to_deck := deck.global_transform if deck.is_inside_tree() else deck.transform
	var local := to_deck.affine_inverse() * entry
	var ring := deck.ring
	var a := ring.world_to_arc(local.origin)
	var ahead := signf((-local.basis.z).dot(ring.tangent_at(local.origin)))
	var right := signf(local.basis.x.x)
	var p := ring.arc_to_world(a.x + right * off.x, a.y + ahead * off.y, a.z)
	return to_deck * Transform3D(ring.basis_at(p, ring.tangent_at(p) * ahead), p)


## Stack mode: the i-th of n crew slots, from CityStack.spawn_transforms(n) (one column per carriageway, clear of the
## planted median and the rail lane, rows going in, slid past anything blocking: plan data only, the same on every
## machine). Beyond the stack's 4 slots (offline perf crews), entry_spawn() around the entry.
func crew_spawn(i: int, n: int) -> Transform3D:
	var slots := stack.spawn_transforms(n)
	if i < slots.size():
		return slots[i]
	return entry_spawn(stack.entry_transform(), city, i, n)


## The enemies of this mission (TestDriveCombat.rebuild_encounters asks): solo, EnemySpawner in front of the local
## mech's spawn (as before). Crew mission: the host spawns them around encounter_origin() (the same spot whatever seat it
## has), scaled to the crew size, each tagged with its spawn_deck; a client spawns none (EnemySync builds the host's as
## puppets).
func spawn_enemies(w: CombatWorld, sq: EnemySquad) -> Array[EnemyBase]:
	var sess := Net.session()
	if crewed and sess != null and sess.online() and not sess.hosting:
		return [] as Array[EnemyBase]
	var origin := encounter_origin() if crewed else mech.global_position
	var crew := spawn_order.size() if crewed else 1
	# Stack: one encounter on EVERY deck, in that deck's plan and frame (deck_ring), laid out from the entry's spot in the
	# deck's own arc coordinates; the plan (from the mission seed and the deck index) seeds it. Ids on decks other than the
	# entry's get a "d<k>_" prefix (unique target ids for CombatNet / EnemySync). Each enemy paths on its deck's road
	# graph and engages only targets on its deck (EnemySquad.deck_of).
	sq.deck_of = stack.deck_at
	var entry_k := int(stack.section.entry["deck"])
	var ea := stack.to_deck_arc(origin)
	var out: Array[EnemyBase] = []
	# Only the deck pool's garrison share stands at the start (0.5; 1.0 on a deck without wave sources); the rest arrives
	# in waves (MissionFlow -> EnemySpawner.spawn_wave). The same plan MissionFlow builds right after. TEST-ONLY
	# (QuietSectionFixture, MissionFlow.test_quiet): no plan, the full garrison (share 1.0).
	var mp: MissionPlan = null if MissionFlow.test_quiet else MissionPlan.make(stack.section, MissionFlow.test_plan)
	for k in stack.decks.size():
		sq.add_deck_nav(k, stack.decks[k].plan)
		var o := origin if k == entry_k else stack.from_deck_arc(k, float(ea["x"]), float(ea["s"]), float(ea["h"]))
		var share := float(mp.pool(k).get("garrison", 1.0)) if mp != null else 1.0
		var got := EnemySpawner.spawn_all(stack.decks[k].plan, city.ring if k == entry_k else stack.deck_ring(k), o, w,
			sq, seed_value, false, crew, "" if k == entry_k else "d%d_" % k, k, [], share)
		if mp != null:
			print("[mission] deck %d garrison: %d units (share %.2f)" % [k, got.size(), share])
		out.append_array(got)
	enemies_spawned = true
	return out


## Where the encounter is laid out from: the stack's entry.
func encounter_origin() -> Vector3:
	return stack.entry_transform().origin


## Alive enemies per deck (MissionRules.evaluate's "enemies"): every deck of the stack. Right on the
## host; a client's puppets follow the host's destruction events.
func enemies_alive_per_deck() -> Array[int]:
	var decks := stack.decks.size() if stack != null else 1
	return EnemySync.alive_per_deck(combat.squad.enemies if combat != null and combat.squad != null else [], decks)


## What the load barrier compares: the stack's checksum (section + every deck's plan) with the MissionPlan's checksum
## joined ("<stack>/<plan>"; the stack's alone under the TEST-ONLY quiet fixture, which builds no plan).
func mission_checksum() -> String:
	if stack == null:
		return ""
	if mission != null and mission.plan != null:
		return stack.checksum() + "/" + mission.plan.checksum()
	return stack.checksum()


## The distance from the habitat's axis below which the city has floor (the lowest deck's floor radius).
func floor_radius() -> float:
	if stack != null and stack.section != null:
		return stack.section.radius_of(stack.section.deck_count - 1)
	return city.ring.radius if city != null and city.ring != null else 0.0


func respawn() -> void:
	mech.global_transform = _spawn
	mech.velocity = Vector3.ZERO
	rig.gait.reset([])
	cam.reset_behind()


## Crew mission: one mech per crew entry, by seat. The local one becomes `mech` / `rig` (driven, camera, combat).
func _spawn_crew(crew: Array, local_peer: int) -> void:
	var entries := crew.duplicate()
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("seat", 0)) < int(b.get("seat", 0)))
	var sess := Net.session()
	var bot_accents := BotLoadout.accents(seed_value, entries)   # each bot's colour, none another member wears
	_bot_accents = bot_accents
	if sess != null and sess.hosting:
		for id: int in bot_accents:
			sess.set_bot_fields(id, {"accent": bot_accents[id]})   # the crew panel / hangar show it too
	for e: Dictionary in entries:
		var peer := int(e.get("peer", 0))
		var bot := bool(e.get("bot", false)) and NetSession.is_bot_id(peer)
		if (peer <= 0 and not bot) or mechs.has(peer):
			continue
		var chassis := str(e.get("chassis", NetSession.DEFAULT_CHASSIS))
		var loadout := NetSession.clean_loadout(chassis, e.get("loadout", {}))
		if bot:   # the bot picks its own mech: the same on every machine (seed + slot), nothing travels
			var pick := BotLoadout.pick(seed_value, -peer, str(e.get("skill", "")))
			chassis = str(pick["chassis"])
			loadout = pick["loadout"]
		var accent := str(bot_accents.get(peer, e.get("accent", NetSession.DEFAULT_ACCENT)))
		var m := MechSpawn.make(str(e.get("head", NetSession.DEFAULT_HEAD)), chassis,
			WeaponRegistry.playable_loadout(chassis, loadout)["loadout"], peer, accent)
		m.owner_peer = NetSession.machine_of(peer)   # a bot runs on the host's machine (props / life ownership)
		var r := MechSpawn.rig_of(m)
		if peer == local_peer:
			mech = m
			rig = r
		elif bot and sess != null and sess.hosting:
			m.name = "Mech_bot%d" % -peer   # run here by a CrewBot (_setup_crew_bots)
		else:
			m.name = "Mech_p%d" % peer   # a puppet of its owner's snapshots (CrewSync / MechPuppet)
			m.puppet = true
		add_child(m)
		mechs[peer] = m
		spawn_order.append(peer)
		_seats[peer] = int(e.get("seat", spawn_order.size()))


## Host: a CrewBot (PlayerTarget, WeaponRack, later its MissionBot) for each bot mech of the crew. After combat.
func _setup_crew_bots() -> void:
	var sess := Net.session()
	if sess == null or not sess.hosting or combat == null or combat.world == null:
		return
	for e: Dictionary in sess.mission_params().get("crew", []) as Array:
		var id := int(e.get("peer", 0))
		var m := mech_of(id)
		if not bool(e.get("bot", false)) or not NetSession.is_bot_id(id) or m == null or crew_bots.has(id):
			continue
		var cb := CrewBot.new()
		cb.name = "CrewBot_%d" % -id
		add_child(cb)
		cb.setup(self, id, m, str(e.get("skill", NetSession.BOT_SKILL)))
		crew_bots[id] = cb
		FlowLog.say("crew bot", "%s (pilot %d) %s: %s" % [str(e.get("name", "")), id,
			str(BotLoadout.pick(seed_value, -id, str(e.get("skill", "")))["archetype"]), str(MechSpawn.rig_of(m).model.loadout)])


func _start_crew_bots() -> void:
	for id: int in crew_bots:
		var cb := crew_bots[id] as CrewBot
		if cb != null and is_instance_valid(cb):
			cb.start()


## Every pilot of the mission with its mech, as this machine sees it: [{peer: pilot id, mech, downed, redeploying, bot}]
## (the local mech first, then the host's bots, then the puppets of members still in the crew). MissionFlow.crew_facts
## reads it. downed = PlayerTarget.disabled (also while redeploying); redeploying = held to respawn, the penalty runs.
func crew_members() -> Array:
	var out: Array = []
	if mech == null:
		return out
	var pt := combat.player_target if combat != null else null
	out.append({"peer": MechSpawn.owner_of(mech), "mech": mech, "downed": pt != null and pt.disabled,
		"redeploying": pt != null and pt.redeploying, "bot": false})
	if not crewed:
		return out
	for id: int in crew_bots:
		var cb := crew_bots[id] as CrewBot
		if cb != null and is_instance_valid(cb) and cb.mech != null:
			out.append({"peer": id, "mech": cb.mech, "downed": cb.target != null and cb.target.disabled,
				"redeploying": cb.target != null and cb.target.redeploying, "bot": true})
	if crew_sync == null:
		return out
	var sess := Net.session()
	for p: int in crew_sync.puppets:
		if sess != null and not sess.has_member(p):
			continue   # left the crew: no longer extracts
		var pp := crew_sync.puppets[p] as MechPuppet
		if pp == null or not is_instance_valid(pp) or pp.mech == null:
			continue
		out.append({"peer": p, "mech": pp.mech, "downed": pp.downed, "redeploying": pp.redeploying,
			"bot": NetSession.is_bot_id(p)})
	return out


## The src a mech pushes ambient life with: its pilot's machine (a bot's is the host's; life reads src < 0 as enemies).
static func _pusher_src(p: int) -> int:
	return NetSession.machine_of(p)


## Offline crew (tests): mechs 2..n as idle puppets with fake owner peers, in seat order after your mech.
func _spawn_offline_crew(n: int) -> void:
	for seat in range(2, mini(n, NetSession.MAX_CREW) + 1):
		var peer := OFFLINE_PEER + seat
		var m := MechSpawn.make(NetSession.DEFAULT_HEAD, NetSession.DEFAULT_CHASSIS, {}, peer, NetSession.DEFAULT_ACCENT)
		m.name = "Mech_p%d" % peer
		m.puppet = true
		add_child(m)
		mechs[peer] = m
		spawn_order.append(peer)
		_seats[peer] = seat


## The mech owned by `peer` (null if none: also a launch-crew member who left, CrewSync.retire; spawn_order still lists
## it, so callers walking spawn_order check for null).
func mech_of(peer: int) -> MechController:
	return mechs.get(peer) as MechController


## A crew member left mid-mission (CrewSync.retire, after its PlayerTarget left CombatWorld): its mech leaves `mechs`,
## ambient life's pushers and viewers, and the scene. spawn_order keeps the launch crew (respawn slots stay put).
func drop_mech(peer: int) -> void:
	var m := mechs.get(peer) as MechController
	mechs.erase(peer)
	_audio_deck.erase(peer)
	if m == null or not is_instance_valid(m) or m == mech:
		return
	if life != null:
		life.remove_pusher(m)
		life.remove_viewer(m)
	m.queue_free()


## CrewSync.retire is done with pilot `id` (out of CombatWorld, `mechs`, crew_members()): on the host, say so once
## (crew_member_left, MissionFlow.on_member_retired). Clients: nothing (the host's scale reaches them replicated).
func member_retired(id: int) -> void:
	var sess := Net.session()
	if sess == null or not sess.hosting or _left.has(id):
		return
	_left.append(id)
	crew_member_left.emit(id)
	_tell_mission_retired(id)


func _tell_mission_retired(id: int) -> void:
	if mission != null and is_instance_valid(mission) and mission.has_method("on_member_retired"):
		mission.call("on_member_retired", id)
		_told.append(id)


func _back_to_menu() -> void:
	if crewed and not _leaving and is_inside_tree() and get_tree().current_scene == self:
		_leave_to(Boot.MENU_SCENE)


## The mission's end flow is over (MissionFlow.finished): back to the hangar. A crew goes there through the menu (online:
## the hangar); solo asks the menu for its hangar. Only when this scene is the running one (tests keep theirs).
func _leave_mission() -> void:
	if _leaving or not is_inside_tree() or get_tree().current_scene != self:
		return
	if not crewed:
		FrontEnd.next_screen = "hangar"
	_leave_to(Boot.MENU_SCENE)


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


func _physics_process(delta: float) -> void:
	if mech == null or loading:
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
	_downed_controls()
	# Fell out of the city (below the lowest deck's floor): back to the spawn.
	if stack != null:
		if stack.fell_out(mech.global_position, FALL_OUT):
			respawn()
		_audio_check -= delta
		if _audio_check <= 0.0:
			_audio_check = 0.25
			_follow_audio_decks()


## Downed (DownedRules): the local mech holds still (also against a bot's or a test's inputs), its weapons are off (the
## rack's input muted, trigger off) and SPACE (the `respawn` action) feeds PlayerTarget.respawn_held instead of the
## thrusters; tests (drive_override) set respawn_held themselves. Standing again gives the rack its input back.
func _downed_controls() -> void:
	var pt := combat.player_target if combat != null else null
	var down := pt != null and pt.disabled
	if down:
		mech.move_input = Vector2.ZERO
		mech.turn_input = 0.0
		mech.running = false
		mech.thrust_input = false
		if not drive_override:
			pt.respawn_held = InputMap.has_action(DownedRules.ACTION) and Input.is_action_pressed(DownedRules.ACTION)
		if combat.rack != null:
			if combat.rack.read_input:
				combat.rack.read_input = false
				_rack_muted = true
			combat.rack.trigger = false
	elif _rack_muted:
		_rack_muted = false
		if combat.rack != null:
			combat.rack.read_input = true
		if pt != null and not drive_override:
			pt.respawn_held = false


## Stack: each mech's footstep surfaces come from the deck it is on (MechAudio.city), switched when it changes deck.
func _follow_audio_decks() -> void:
	for p: int in mechs:
		var m := mechs[p] as MechController
		if m == null or not is_instance_valid(m):
			continue
		var k := stack.deck_at(m.global_position)
		if int(_audio_deck.get(p, -1)) == k:
			continue
		_audio_deck[p] = k
		var ma := m.get_node_or_null("Audio") as MechAudio
		if ma != null:
			ma.city = stack.decks[k]


func _unhandled_input(e: InputEvent) -> void:
	if loading and not (e is InputEventKey and (e as InputEventKey).keycode == KEY_ESCAPE):
		return
	if e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if Time.get_ticks_msec() < _ignore_mouse_until:
			return
		cam.add_mouse((e as InputEventMouseMotion).relative.limit_length(300.0))
	elif e is InputEventMouseButton and (e as InputEventMouseButton).pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_capture(true)
	elif e is InputEventKey and (e as InputEventKey).pressed and not (e as InputEventKey).echo:
		match (e as InputEventKey).keycode:
			KEY_ESCAPE:
				if _leaving:
					return
				if crewed and Net.session() != null:
					Net.session().end_mission()
				if get_tree().current_scene == self:
					_leave_to(Boot.MENU_SCENE)
				else:
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
	_hud_layer = layer
	layer.visible = loading_screen == null
	var root := Control.new()
	root.name = "HudRoot"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(root)
	_help = Label.new()
	_help.name = "Help"
	var n_hp := (MechCatalog.chassis(mech.chassis_id if mech != null else "strider")["hardpoints"] as Array).size()   # Strider 5, Bulwark 4
	_help.text = "LMB fire   RMB zoom   W/S walk   A/D strafe   Shift run   Space thrust   C view   1-%d weapons   N new city   Tab mouse   F1 help   Esc menu" % n_hp
	_help.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)   # the bottom corners belong to the mech HUD
	_help.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_help.offset_top = 12
	_help.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	_help.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_help.add_theme_constant_override("outline_size", 4)
	root.add_child(_help)
	_note_label = Label.new()
	_note_label.name = "CrewNote"
	_note_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_note_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_note_label.offset_top = 40
	_note_label.add_theme_color_override("font_color", Color(1.0, 0.65, 0.4))
	_note_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_note_label.add_theme_constant_override("outline_size", 4)
	_note_label.visible = false
	root.add_child(_note_label)
