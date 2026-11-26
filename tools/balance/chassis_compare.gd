extends Node
## Strider vs Bulwark effectiveness (docs/design/bulwark-effectiveness.md): paper numbers from the catalog
## (tools/balance/chassis_paper.gd) and bot-driven scenario numbers (BalanceScenarios duels / pockets / city_solo with the
## chassis and loadout set per run). Fixed step (BalanceScenarios.DT), seeded, no wall clock in any number.
##
##   .\tools\balance\run_chassis_compare.ps1                         # paper + scenarios, current catalog
##   .\tools\balance\run_chassis_compare.ps1 -Part paper              # paper only (seconds)
##   .\tools\balance\run_chassis_compare.ps1 -Variant mortar6         # a what-if (see VARIANTS)
##
## Godot args after `--`: --part paper|scen|all  --variant <id>  --profiles veteran,average  --seeds 1,2,5,7
##   --tag <name> (output file test_logs/balance/chassis/<tag>.json + .md)  --shard i/n --shard-out <file>
## Scenario instrumentation per run (on top of BotMetrics): damage by hardpoint (from the hit's shot key), per weapon slot
## "can't bear" = s the bot had its enemy in sight and in that weapon's range while the barrel was not on target
## (slew + out of arc + body still turning), s with the bot holding fire for heat (its overheat wait) or shut down.

const Paper := preload("res://tools/balance/chassis_paper.gd")

const SCEN_IDS := ["duel_turret", "duel_strider", "duel_tank_street", "pocket_vanguard", "pocket_crossfire",
	"pocket_cover_siege", "city_solo"]
const DEFAULT_CITY_SEEDS := [1, 2, 5, 7]
## Option what-ifs (applied to the Bulwark only unless the key says otherwise):
##   mortar6       mortar ammo 6 for both chassis (backlog item 8, if it has not landed)
##   c_heat        Bulwark heat cap 160, cooling 16 (both big guns fire without pause)
##   c_turn        Bulwark turn rate 1.8 (the Strider's): how much of the gap is turn rate
##   c_braced      Bulwark: +25 % fire rate on direct-fire weapons (paper only: no rate hook in WeaponMount)
##   c_armor       Bulwark core HP x ARMOR_HP (an armour multiplier: incoming core damage / ARMOR_HP)
##   any tag containing "armor" applies it (e.g. belly_armor: the belly prototype in the catalog + armour)
const VARIANTS := ["base", "mortar6", "c_heat", "c_turn", "c_heat_turn", "c_armor"]
const ARMOR_HP := 1.5

var _hp_dmg := {}      ## player id -> {hardpoint: damage}
var _bear := {}        ## player id -> {hardpoint: {sight: s, off: s}}
var _heat_hold := {}   ## player id -> s
var _sight := {}       ## player id -> s an enemy was in sight


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var part := _arg(args, "--part", "all")
	var variant := _arg(args, "--variant", "base")
	var tag := _arg(args, "--tag", variant)
	var profiles := _arg(args, "--profiles", "veteran,average").split(",", false)
	var seeds: Array = []
	for s in _arg(args, "--seeds", "").split(",", false):
		seeds.append(int(s))
	if seeds.is_empty():
		seeds = DEFAULT_CITY_SEEDS.duplicate()
	var shard := _arg(args, "--shard", "")
	var shard_out := _arg(args, "--shard-out", "")
	var merge_dir := _arg(args, "--merge-dir", "")
	var scen_filter := _arg(args, "--scenarios", "")
	var out_dir := ProjectSettings.globalize_path("res://test_logs/balance/chassis")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var md := PackedStringArray()
	var report := {"variant": variant, "mortar_ammo": int(MechCatalog.weapon("mortar")["ammo"])}

	if part in ["paper", "all"]:
		var pr := paper_report(variant)
		report["paper"] = pr["data"]
		md.append(pr["md"])

	if part in ["scen", "all"] or merge_dir != "":
		var runs: Array = []
		if merge_dir != "":
			for fn in DirAccess.get_files_at(merge_dir):
				if fn.ends_with(".json"):
					var p: Variant = JSON.parse_string(FileAccess.get_file_as_string(merge_dir.path_join(fn)))
					if p is Dictionary:
						runs.append_array((p as Dictionary).get("runs", []))
		else:
			var specs := build_specs(variant, profiles, seeds, scen_filter)
			if shard != "":
				var sp := shard.split("/")
				var mine: Array = []
				for i in specs.size():
					if i % int(sp[1]) == int(sp[0]):
						mine.append(specs[i])
				specs = mine
			for spec: Dictionary in specs:
				runs.append(await run_one(spec, variant))
			if shard_out != "":
				_write(shard_out, JSON.stringify({"runs": runs}))
				get_tree().quit(0)
				return
		report["runs"] = runs
		md.append(scen_report(runs))

	var text := "\n".join(md)
	_write(out_dir.path_join(tag + ".md"), text)
	_write(out_dir.path_join(tag + ".json"), JSON.stringify(report, " "))
	print(text)
	print("Artifacts: %s.md / .json" % out_dir.path_join(tag))
	get_tree().quit(0)


# --- Loadouts ---------------------------------------------------------------------------------------------------

static func default_loadout(chassis_id: String, opts: Dictionary = {}) -> Dictionary:
	var l := MechCatalog.sanitize_loadout(chassis_id, {})
	for id: Variant in opts.get("skip_hardpoints", []):
		l.erase(id)
	return l


## The best legal paper loadout for the scenario runs: highest 30 s damage at 80 m (a typical fight), walking, among loadouts
## that keep a mortar (both chassis get indirect fire for the roof turrets the bot cannot reach). Cached per chassis.
static func best_loadout(chassis_id: String, opts: Dictionary = {}) -> Dictionary:
	var o := opts.duplicate()
	o["range_m"] = 80.0
	var best := {}
	var best_s := -1.0
	for l: Dictionary in Paper.legal_loadouts(chassis_id, o):
		if not l.values().has("mortar"):
			continue
		var s := float(Paper.evaluate(chassis_id, l, o)["dmg30"])   # a 30 s fight: heat buffer + sustained
		if s > best_s:
			best_s = s
			best = l
	return best


static func paper_opts(variant: String) -> Dictionary:
	var o := {}
	if variant in ["mortar6"]:
		o["mortar_ammo"] = 6
	return o


## Bulwark-only paper what-ifs (merged over paper_opts for the bulwark rows).
static func bulwark_opts(variant: String) -> Dictionary:
	var o := paper_opts(variant)
	if not variant.begins_with("belly"):   # the belly turret prototype only in "belly*" variants
		o["skip_hardpoints"] = ["belly"]
	if variant in ["c_heat", "c_heat_turn"]:
		o["heat_cap_mult"] = 160.0 / 130.0
		o["cooling_add"] = 4.0
	return o


# --- Paper ------------------------------------------------------------------------------------------------------

func paper_report(variant: String) -> Dictionary:
	var lines := PackedStringArray()
	var data := {}
	lines.append("## Paper (variant %s, mortar ammo in catalog %d)\n" % [variant, int(MechCatalog.weapon("mortar")["ammo"])])
	lines.append("Every shot a hit; perfect heat management (never over 95 % of cap); walking heat on. dmg = direct damage.\n")
	lines.append("| chassis | loadout | wt/max | burst 5 s | DPS 30 s | DPS 120 s | DPS120 @30m | @80m | @150m | @250m | ammo dmg | heat-held s/120 |")
	lines.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
	var rows: Array = []
	for cfg: Array in _configs(variant):
		var cid: String = cfg[1]
		var o: Dictionary = cfg[2]
		var picks := {"default": default_loadout(cid, o), "best_mortar": best_loadout(cid, o)}
		var top := Paper.best(cid, "dmg120", _with(o, {"range_m": 80.0}), 1)
		if not top.is_empty():
			picks["best_any"] = top[0]["loadout"]
		var topb := Paper.best(cid, "burst5", _with(o, {"range_m": 80.0}), 1)
		if not topb.is_empty():
			picks["best_burst"] = topb[0]["loadout"]
		for name: String in picks:
			var l: Dictionary = picks[name]
			var r := Paper.evaluate(cid, l, o)
			var at := {}
			for m in [30.0, 80.0, 150.0, 250.0]:
				at[m] = float(Paper.evaluate(cid, l, _with(o, {"range_m": m}))["dps120"])
			var row := {"chassis": cfg[0], "name": name, "loadout": l, "r": r, "at": at,
				"surv": Paper.survivability(cid, l)}
			rows.append(row)
			lines.append("| %s | %s %s | %.0f/%.0f | %.0f | %.1f | %.1f | %.1f | %.1f | %.1f | %.1f | %.0f | %.0f |" % [cfg[0], name,
				_lstr(l), r["weight"], r["max_weight"], r["burst5"], r["dps30"], r["dps120"], at[30.0], at[80.0], at[150.0],
				at[250.0], r["ammo_total"], r["heat_capped_s"]])
	data["rows"] = rows
	# Back items' real contribution, measured on each chassis' default loadout by swapping the item out.
	lines.append("\n### Back items (delta against an empty slot, default loadout, 120 s at 80 m)\n")
	lines.append("| chassis | slot | item | dDPS120 | d ammo dmg | notes |")
	lines.append("|---|---|---|---|---|---|")
	for cfg: Array in _configs(variant):
		var cid: String = cfg[1]
		var o := _with(cfg[2], {"range_m": 80.0})
		var l := default_loadout(cid, o)
		var slot := "back" if cid == "strider" else "back_r"
		for item in ["mortar", "radiator", "ammo_bin", "repair_drone"]:
			var with_l := l.duplicate()
			with_l[slot] = item
			var without := l.duplicate()
			without[slot] = ""
			var a := Paper.evaluate(cid, with_l, o)
			var b := Paper.evaluate(cid, without, o)
			var note := ""
			if item == "repair_drone":
				var sv := Paper.survivability(cid, with_l)
				note = "heals %.0f HP per charge (60 s), %.0f per mission (2 charges)" % [sv["drone_heal_per_charge"], sv["drone_heal_mission"]]
			elif item == "mortar":
				var ammo := int(o.get("mortar_ammo", int(MechCatalog.weapon("mortar")["ammo"])))
				note = "%d shells x 80 direct (+50 splash r 8): %.0f dmg per load, then empty until a depot" % [ammo, 80.0 * ammo]
			lines.append("| %s | %s | %s | %+.1f | %+.0f | %s |" % [cfg[0], slot, item, float(a["dps120"]) - float(b["dps120"]),
				float(a["ammo_total"]) - float(b["ammo_total"]), note])
	# Survivability
	lines.append("\n### Survivability (paper)\n")
	lines.append("| chassis | core HP | torso | leg | hit-sphere area m^2 | HP per m^2 |")
	lines.append("|---|---|---|---|---|---|")
	for cid: String in ["strider", "bulwark"]:
		var sv := Paper.survivability(cid, default_loadout(cid))
		lines.append("| %s | %.0f | %.0f | %.0f | %.0f | %.1f |" % [cid, sv["core_hp"], sv["torso_hp"], sv["leg_hp"], sv["sphere_area"],
			float(sv["core_hp"]) / maxf(float(sv["sphere_area"]), 1.0)])
	return {"md": "\n".join(lines), "data": data}


## The paper rows: the Strider, the Bulwark as the variant has it, and (when the catalog has it and the variant does
## not) the Bulwark with its belly turret prototype: [label, chassis, opts].
static func _configs(variant: String) -> Array:
	var out: Array = [["strider", "strider", paper_opts(variant)], ["bulwark", "bulwark", bulwark_opts(variant)]]
	var o := bulwark_opts(variant)
	if o.has("skip_hardpoints") and MechCatalog.slot_key("bulwark", "belly") > 0:
		o.erase("skip_hardpoints")
		out.append(["bulwark+belly", "bulwark", o])
	elif not o.has("skip_hardpoints"):
		out[1][0] = "bulwark+belly"
		var nb := o.duplicate()
		nb["skip_hardpoints"] = ["belly"]
		out.insert(1, ["bulwark", "bulwark", nb])
	return out


# --- Scenarios --------------------------------------------------------------------------------------------------

func build_specs(variant: String, profiles: PackedStringArray, seeds: Array, scen_filter: String) -> Array:
	var specs: Array = []
	var only := scen_filter.split(",", false)
	for cid: String in ["strider", "bulwark"]:
		var o := paper_opts(variant) if cid == "strider" else bulwark_opts(variant)
		var loads := {"default": default_loadout(cid, o), "best": best_loadout(cid, o)}
		for lname: String in loads:
			for sc: String in SCEN_IDS:
				if not only.is_empty() and not only.has(sc):
					continue
				for prof: String in profiles:
					var sds: Array = seeds if sc == "city_solo" else ([101] if sc.begins_with("duel") else [202])
					for sd: int in sds:
						specs.append({"scenario": sc, "profile": prof, "seed": sd, "loadout": "%s_%s" % [cid, lname],
							"loadout_dict": loads[lname], "chassis": cid, "overrides": {}, "lname": lname})
	return specs


func run_one(spec: Dictionary, variant: String) -> Dictionary:
	_hp_dmg.clear()
	_bear.clear()
	_heat_hold.clear()
	_sight.clear()
	var cid := str(spec["chassis"])
	var s := spec.duplicate()
	if variant == "mortar6":
		s["overrides"] = {"mortar.ammo": 6.0}
	s["on_spawn"] = func(mech: MechController, _rack: WeaponRack, _pt: PlayerTarget) -> void:
		if cid != "bulwark":
			return
		if variant in ["c_heat", "c_heat_turn"]:
			mech.heat_cap = 160.0
			mech.cooling += 4.0
		if variant in ["c_turn", "c_heat_turn"]:
			mech.turn_rate = 1.8
		if variant.contains("armor"):
			# armour what-if: core components x ARMOR_HP (= damage x 1 / ARMOR_HP on them), hardpoints unchanged
			var caps := _pt.max_hp.duplicate()
			for c: String in PlayerTarget.CORE_COMPONENTS:
				caps[c] = float(caps[c]) * ARMOR_HP
			_pt.set_max_hp(caps)
	s["on_step"] = _on_step
	var hook := func(t: CombatTarget, h: Hit) -> void:
		if t.team == "player" or h.shot == "":
			return
		var parts := h.shot.split("/")
		if parts.size() < 3:
			return
		var who: Dictionary = _hp_dmg.get_or_add(parts[0], {})
		who[parts[1]] = float(who.get(parts[1], 0.0)) + h.damage
	_pending_hook = hook
	var res := await BalanceScenarios.run_scenario(self, s)
	res["chassis"] = cid
	res["lname"] = str(spec["lname"])
	res["loadout_dict"] = spec["loadout_dict"]
	res["hp_damage"] = _hp_dmg.duplicate(true)
	res["bear"] = _bear.duplicate(true)
	res["heat_hold_s"] = _heat_hold.duplicate()
	res["sight_s"] = _sight.duplicate()
	return res


var _pending_hook: Callable
var _hooked: CombatWorld


func _on_step(dt: float, mechs: Array, racks: Array, targets: Array, bots: Array) -> void:
	# connect the hardpoint-damage hook to this run's world on its first step
	if not racks.is_empty():
		var w: CombatWorld = (racks[0] as WeaponRack).world
		if w != _hooked and _pending_hook.is_valid():
			w.hit_landed.connect(_pending_hook)
			_hooked = w
	for i in racks.size():
		var rack: WeaponRack = racks[i]
		var bot: PlayerBot = bots[i]
		var mech: MechController = mechs[i]
		var pid := str(rack.shooter)
		if mech.shutdown or bool(bot.get("_overheat_wait")):
			_heat_hold[pid] = float(_heat_hold.get(pid, 0.0)) + dt
		var e: Variant = bot.get("_current_enemy")
		if e == null or not is_instance_valid(e) or (e as EnemyBase).destroyed():
			continue
		var mem: Dictionary = (bot.get("_memory") as Dictionary).get((e as EnemyBase).target_id, {})
		if not bool(mem.get("has_los", false)):
			continue
		_sight[pid] = float(_sight.get(pid, 0.0)) + dt
		var dist := mech.global_position.distance_to((e as EnemyBase).global_position)
		for sl: Dictionary in rack.slots():
			var wid := str(sl["weapon"])
			if wid == "" or MechCatalog.is_equipment(wid) or str(MechCatalog.weapon(wid).get("kind", "")) == "arc":
				continue
			if dist > float(MechCatalog.weapon(wid)["range"]) or int(sl["ammo"]) == 0 or not bool(sl["built"]):
				continue
			var per: Dictionary = (_bear.get_or_add(pid, {}) as Dictionary).get_or_add(str(sl["hardpoint"]), {"sight": 0.0, "off": 0.0})
			per["sight"] = float(per["sight"]) + dt
			if not bool(sl["on_target"]):
				per["off"] = float(per["off"]) + dt


func scen_report(runs: Array) -> String:
	var lines := PackedStringArray()
	lines.append("\n## Scenarios (bot-driven, BalanceScenarios, fixed step)\n")
	# per run table
	lines.append("| chassis | loadout | scenario | prof | seed | won | time s | dmg dealt | dealt/min | taken/min | downs | can't bear % | heat-held % | dry |")
	lines.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
	var agg := {}
	for r: Dictionary in runs:
		var key := "%s/%s" % [r["chassis"], r["lname"]]
		var dealt := 0.0
		for wid: String in (r.get("player_weapons", {}) as Dictionary):
			dealt += float(r["player_weapons"][wid].get("damage", 0.0))
		var t := maxf(float(r["clear_time_s"]), 1.0)
		var sight := 0.0
		var off := 0.0
		for pid: String in (r.get("bear", {}) as Dictionary):
			for hp: String in r["bear"][pid]:
				sight += float(r["bear"][pid][hp]["sight"])
				off += float(r["bear"][pid][hp]["off"])
		var hold := 0.0
		for pid: String in (r.get("heat_hold_s", {}) as Dictionary):
			hold += float(r["heat_hold_s"][pid])
		var cb := 100.0 * off / maxf(sight, 0.001)
		lines.append("| %s | %s | %s | %s | %d | %s | %.1f | %.0f | %.0f | %.0f | %d | %.0f | %.0f | %s |" % [r["chassis"], r["lname"],
			r["scenario"], r["profile"], int(r["seed"]), "Y" if bool(r["won"]) else "n", t, dealt, 60.0 * dealt / t,
			60.0 * float(r["damage_taken"]) / t, int(r["disables"]), cb, 100.0 * hold / t, "Y" if bool(r.get("ammo_dry", false)) else ""])
		var group := "city_solo" if str(r["scenario"]) == "city_solo" else "duels + pockets"
		for g: String in ["all", group]:
			_accumulate((agg.get_or_add(g, {}) as Dictionary).get_or_add(key, {"n": 0, "won": 0, "time": 0.0, "dealt": 0.0,
				"taken": 0.0, "downs": 0, "sight": 0.0, "off": 0.0, "hold": 0.0, "dry": 0, "hp": {}, "ttk": {}, "dpm_list": [],
				"tpm_list": [], "kills": 0, "enemies": 0}), r, dealt, t, sight, off, hold)
	for g: String in ["all", "city_solo", "duels + pockets"]:
		if agg.has(g):
			_totals(lines, g, agg[g])
	return "\n".join(lines)


func _accumulate(a: Dictionary, r: Dictionary, dealt: float, t: float, sight: float, off: float, hold: float) -> void:
	a["n"] += 1
	a["won"] += 1 if bool(r["won"]) else 0
	a["time"] += t
	a["dealt"] += dealt
	a["taken"] += float(r["damage_taken"])
	a["downs"] += int(r["disables"])
	a["sight"] += sight
	a["off"] += off
	a["hold"] += hold
	a["dry"] += 1 if bool(r.get("ammo_dry", false)) else 0
	(a["dpm_list"] as Array).append(60.0 * dealt / t)
	(a["tpm_list"] as Array).append(60.0 * float(r["damage_taken"]) / t)
	for pid: String in (r.get("hp_damage", {}) as Dictionary):
		for hp: String in r["hp_damage"][pid]:
			a["hp"][hp] = float(a["hp"].get(hp, 0.0)) + float(r["hp_damage"][pid][hp])
	for et: String in (r.get("enemy_classes", {}) as Dictionary):
		var ec: Dictionary = r["enemy_classes"][et]
		var tk: Dictionary = a["ttk"].get_or_add(et, {"kills": 0, "sum": 0.0})
		tk["kills"] += int(ec.get("kills", 0))
		tk["sum"] += float(ec.get("survival_sum", 0.0))
	a["kills"] += int(r.get("enemies_killed", 0))
	a["enemies"] += int(r.get("enemies_total", 0))


static func _totals(lines: PackedStringArray, title: String, agg: Dictionary) -> void:
	lines.append("\n### Totals per chassis / loadout: %s\n" % title)
	lines.append("| chassis / loadout | runs | wins | kills / enemies | sum time s | dealt / min (sd) | taken / min (sd) | downs | can't bear % | heat-held % | dry runs | TTK turret / strider / tank s | dmg by hardpoint |")
	lines.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
	for key: String in agg:
		var a: Dictionary = agg[key]
		var ttk := []
		for et in ["turret", "strider", "tank"]:
			var tk: Dictionary = a["ttk"].get(et, {"kills": 0, "sum": 0.0})
			ttk.append("%.1f" % (float(tk["sum"]) / float(tk["kills"])) if int(tk["kills"]) > 0 else "-")
		var hps := []
		var tot := 0.0
		for hp: String in a["hp"]:
			tot += float(a["hp"][hp])
		for hp: String in a["hp"]:
			hps.append("%s %.0f%%" % [hp, 100.0 * float(a["hp"][hp]) / maxf(tot, 1.0)])
		lines.append("| %s | %d | %d | %d / %d | %.0f | %.0f (%.0f) | %.0f (%.0f) | %d | %.0f | %.0f | %d | %s | %s |" % [key, a["n"], a["won"],
			a["kills"], a["enemies"], a["time"], 60.0 * float(a["dealt"]) / float(a["time"]), _sd(a["dpm_list"]), 60.0 * float(a["taken"]) / float(a["time"]),
			_sd(a["tpm_list"]), a["downs"], 100.0 * float(a["off"]) / maxf(float(a["sight"]), 0.001),
			100.0 * float(a["hold"]) / float(a["time"]), a["dry"], " / ".join(ttk), ", ".join(hps)])


# --- helpers ----------------------------------------------------------------------------------------------------

static func _sd(xs: Array) -> float:
	if xs.size() < 2:
		return 0.0
	var m := 0.0
	for x: float in xs:
		m += x
	m /= float(xs.size())
	var v := 0.0
	for x: float in xs:
		v += (x - m) * (x - m)
	return sqrt(v / float(xs.size() - 1))


static func _with(a: Dictionary, b: Dictionary) -> Dictionary:
	var o := a.duplicate()
	o.merge(b, true)
	return o


static func _lstr(l: Dictionary) -> String:
	var parts := []
	for k: String in l:
		parts.append(str(l[k]) if str(l[k]) != "" else "-")
	return "[%s]" % "/".join(parts)


static func _arg(args: PackedStringArray, key: String, fallback: String) -> String:
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback


static func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
