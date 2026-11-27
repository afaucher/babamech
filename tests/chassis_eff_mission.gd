extends "res://tests/bot_obj_case.gd"
## MEASUREMENT CASE (not a test_*: -TestAll skips it), docs/design/bulwark-effectiveness.md Part 1: the mission bot plays a
## whole solo plan-mode mission (tests/bot_obj_case.gd, veteran, no cheat, bonuses off, fixed step) in the chassis and
## loadout the environment names, and a sampler records what the effectiveness study needs. Driven by
## tools/balance/run_chassis_missions.ps1 (one process per chassis / loadout / seed):
##   EFF_CHASSIS strider|bulwark   EFF_LOADOUT a JSON loadout ({} = BotProfile's kit for the chassis / the catalog default)
##   EFF_SEED n   EFF_LIMIT s of game time (default 1100)   EFF_OUT file the result JSON is written to
## Recorded: outcome and win time, deaths, damage dealt by hardpoint and weapon, damage taken, kills and time to kill by
## enemy type (first hit by this mech to the kill), s an enemy was in sight, per weapon "can't bear" s (enemy in sight and
## in the weapon's range, barrel not on target), s holding fire for heat or shut down, s each limited-ammo slot sat dry.

const TEST_TIMEOUT := 900

var chassis := "bulwark"
var loadout := {}
var _saved_path := ""
var _td: MissionScene
var _t := 0.0
var _r := {"hp_damage": {}, "w_damage": {}, "taken": 0.0, "deaths": 0, "kills": {}, "ttk_sum": {}, "sight_s": 0.0,
	"bear": {}, "heat_hold_s": 0.0, "dry_s": {}, "outcome": "", "time": 0.0, "combat_s": 0.0}
var _first_hit := {}
var _killed := {}
var _was_down := false


func _init() -> void:
	chassis = OS.get_environment("EFF_CHASSIS") if OS.get_environment("EFF_CHASSIS") != "" else "bulwark"
	var lj: Variant = JSON.parse_string(OS.get_environment("EFF_LOADOUT")) if OS.get_environment("EFF_LOADOUT") != "" else {}
	loadout = lj if lj is Dictionary else {}
	if loadout.is_empty() and not BotProfile.LOADOUTS.has(chassis):
		loadout = MechCatalog.sanitize_loadout(chassis, {})
	var s := OS.get_environment("EFF_SEED")
	seed_n = int(s) if s.is_valid_int() else 2
	goal_id = ""
	var l := OS.get_environment("EFF_LIMIT")
	limit = float(l) if l.is_valid_float() else 1100.0
	timeout_sec = limit + 200.0


## As tests/bulwark_bot_case.gd, but with a settings file of this process's own (runs go in parallel).
func setup() -> void:
	_saved_path = GameSettings.path
	GameSettings.path = "user://chassis_eff_%s_%d_%d.cfg" % [chassis, seed_n, OS.get_process_id()]
	var d := GameSettings.DEFAULTS.duplicate(true)
	d["chassis"] = chassis
	d["loadout"] = loadout if not loadout.is_empty() else BotProfile.get_loadout(chassis)
	GameSettings.save_settings(d)
	print("[Test] chassis %s, loadout %s, seed %d" % [chassis, str(d["loadout"]), seed_n])
	await super.setup()


func _physics_process(_dt: float) -> void:
	if _td == null:
		var found: MissionScene = null
		for c in get_children():
			if c is MissionScene:
				found = c
		if found == null or not found.loaded or found.combat == null or found.combat.rack == null \
				or found.combat.player_target == null:
			return
		_td = found
		_td.combat.world.hit_landed.connect(_on_hit)
		_td.combat.player_target.damaged.connect(func(a: float, _c: String, _s: String) -> void: _r["taken"] += a)
	if _td == null or not is_instance_valid(_td) or not _td.loaded:
		return
	var dt := Engine.time_scale / float(Engine.physics_ticks_per_second)
	_t += dt
	var pt := _td.combat.player_target
	var rack := _td.combat.rack
	var mech := _td.mech
	var down := pt.disabled
	if down and not _was_down:
		_r["deaths"] += 1
	_was_down = down
	if _td.mission != null and _td.mission.rules != null and _r["outcome"] == "" and _td.mission.rules.outcome != "":
		_r["outcome"] = _td.mission.rules.outcome
		_r["time"] = _t
	if down:
		return
	var pb: PlayerBot = null
	if _td.bot != null and _td.bot.pilot != null:
		pb = _td.bot.pilot.bot
	if mech.shutdown or (pb != null and bool(pb.get("_overheat_wait"))):
		_r["heat_hold_s"] += dt
	var slots := rack.slots()
	for sl: Dictionary in slots:
		if int(sl["ammo_max"]) > 0 and int(sl["ammo"]) == 0:
			_r["dry_s"][sl["hardpoint"]] = float(_r["dry_s"].get(sl["hardpoint"], 0.0)) + dt
	if pb == null:
		return
	var e: Variant = pb.get("_current_enemy")
	if e == null or not is_instance_valid(e) or (e as EnemyBase).destroyed():
		return
	_r["combat_s"] += dt
	var mem: Dictionary = (pb.get("_memory") as Dictionary).get((e as EnemyBase).target_id, {})
	if not bool(mem.get("has_los", false)):
		return
	_r["sight_s"] += dt
	var dist := mech.global_position.distance_to((e as EnemyBase).global_position)
	for sl: Dictionary in slots:
		var wid := str(sl["weapon"])
		if wid == "" or MechCatalog.is_equipment(wid) or str(MechCatalog.weapon(wid).get("kind", "")) == "arc":
			continue
		if dist > float(MechCatalog.weapon(wid)["range"]) or int(sl["ammo"]) == 0 or not bool(sl["built"]):
			continue
		var per: Dictionary = (_r["bear"] as Dictionary).get_or_add(str(sl["hardpoint"]), {"sight": 0.0, "off": 0.0})
		per["sight"] = float(per["sight"]) + dt
		if not bool(sl["on_target"]):
			per["off"] = float(per["off"]) + dt


func _on_hit(t: CombatTarget, h: Hit) -> void:
	if t.team == "player" or _td == null or h.shooter != _td.combat.rack.shooter:
		return
	var parts := h.shot.split("/")
	var hp := parts[1] if parts.size() >= 3 else "?"
	_r["hp_damage"][hp] = float(_r["hp_damage"].get(hp, 0.0)) + h.damage
	_r["w_damage"][h.weapon] = float(_r["w_damage"].get(h.weapon, 0.0)) + h.damage
	if t is EnemyBase:
		var en := t as EnemyBase
		if not _first_hit.has(en.target_id):
			_first_hit[en.target_id] = _t
		if en.destroyed() and not _killed.has(en.target_id):
			_killed[en.target_id] = true
			_r["kills"][en.enemy_type] = int(_r["kills"].get(en.enemy_type, 0)) + 1
			_r["ttk_sum"][en.enemy_type] = float(_r["ttk_sum"].get(en.enemy_type, 0.0)) + (_t - float(_first_hit[en.target_id]))


func _restore() -> void:
	# the case's loop stops on the step the outcome is set, before this sampler sees it
	if _r["outcome"] == "" and _td != null and is_instance_valid(_td) and _td.mission != null and _td.mission.rules != null:
		_r["outcome"] = _td.mission.rules.outcome
	if _r["time"] == 0.0:
		_r["time"] = _t
	_r["chassis"] = chassis
	_r["seed"] = seed_n
	_r["loadout"] = loadout if not loadout.is_empty() else BotProfile.get_loadout(chassis)
	var out := OS.get_environment("EFF_OUT")
	var txt := JSON.stringify(_r)
	print("[EFF] " + txt)
	if out != "":
		var f := FileAccess.open(out, FileAccess.WRITE)
		if f != null:
			f.store_string(txt)
			f.close()
	super._restore()
	if _saved_path != "":
		DirAccess.remove_absolute(ProjectSettings.globalize_path(GameSettings.path))
		GameSettings.path = _saved_path
