extends RefCounted
## Paper numbers for a chassis + loadout (docs/design/bulwark-effectiveness.md, Part 1): what the catalog alone says a
## loadout can put out, every shot a hit. Pure data, no nodes, no wall clock: a fixed-step heat simulation at DT.
##
##   const Paper := preload("res://tools/balance/chassis_paper.gd")
##   var r := Paper.evaluate("bulwark", {"side_l": "autocannon", ...}, {"mortar_ammo": 6})
##
## THE PILOT MODEL ("perfect pilot"): every weapon fires the moment it is ready unless its trigger cycle's active heat
## would take the gauge over HEAT_MARGIN x cap (it never shuts down); weapons are tried in order of damage per heat
## (cheapest damage first). Heat in: carried passive heat, active heat per cycle, walk heat while `walking`. Heat out:
## the chassis cooling + intact radiators. Salvo weapons ripple `salvo` shots at `rate`, then `reload`. Charge weapons
## (laser, railgun) wait their charge before every shot; the gatling waits its spin-up once. Limited ammo runs dry
## (mortar ammo from `opts.mortar_ammo` when set: the backlog item 8 doubling; ammo bins add 50 % in whole salvos).
## Damage per hit = direct damage x Combat.falloff at `range_m` (0 = no falloff), zero past the weapon's range or under
## its min_range. Splash is reported apart (it lands on OTHER targets near the hit, CombatWorld.splash excludes the hit one).
##
## opts: walking (bool, default true: walk_heat at walk speed), range_m (float, default 0), mortar_ammo (int, -1 = catalog),
##       cooling_add / heat_cap_mult / cooling_mult (option C what-ifs), fire_rate_mult (option C "braced"),
##       duration (s, default 120), extra_hardpoints (Array of hp dicts appended to the chassis' list: option A / B),
##       skip_hardpoints (Array of hardpoint ids left out: the Bulwark without its belly turret prototype).

const DT := 0.05
const HEAT_MARGIN := 0.95


## Every hardpoint of a chassis for paper purposes (catalog list + opts.extra_hardpoints).
static func hardpoints(chassis_id: String, opts: Dictionary = {}) -> Array:
	var out: Array = []
	for h: Dictionary in MechCatalog.chassis(chassis_id)["hardpoints"]:
		if not str(h["id"]) in opts.get("skip_hardpoints", []):
			out.append(h)
	for h: Variant in opts.get("extra_hardpoints", []):
		out.append(h)
	return out


## Weapon stats as the paper sees them (catalog + opts).
static func _stats(w: String, opts: Dictionary, ammo_bonus: float) -> Dictionary:
	var st: Dictionary = MechCatalog.weapon(w).duplicate()
	if w == "mortar" and int(opts.get("mortar_ammo", -1)) > 0:
		st["ammo"] = int(opts["mortar_ammo"])
	var a := int(st.get("ammo", -1))
	if a > 0 and ammo_bonus > 0.0:
		st["ammo"] = WeaponRack.bonus_ammo(a, int(st.get("salvo", 1)), ammo_bonus)
	return st


## Fixed-step simulation of one loadout. Returns {burst5, dmg30, dmg120, dps30, dps120, ammo_total, by_slot {hp: dmg120},
## splash120, heat_capped_s (s the pilot held a ready weapon for heat), weight, passive, cooling, cap, items}.
static func evaluate(chassis_id: String, loadout: Dictionary, opts: Dictionary = {}) -> Dictionary:
	var c := MechCatalog.chassis(chassis_id)
	var mv: Dictionary = c["movement"]
	var cap := float(c["heat_cap"]) * float(opts.get("heat_cap_mult", 1.0))
	var cooling := float(c["cooling"]) * float(opts.get("cooling_mult", 1.0)) + float(opts.get("cooling_add", 0.0))
	var ammo_bonus := 0.0
	var weight := 0.0
	var passive := 0.0
	var hps := hardpoints(chassis_id, opts)
	var guns: Array[Dictionary] = []
	for hp: Dictionary in hps:
		var w := str(loadout.get(hp["id"], ""))
		if w == "":
			continue
		var d := MechCatalog.weapon(w)
		weight += float(d["weight"])
		passive += float(d["passive_heat"])
		if MechCatalog.is_equipment(w):
			cooling += float(d.get("cooling_bonus", 0.0))
			ammo_bonus += float(d.get("ammo_bonus", 0.0))
	for hp: Dictionary in hps:
		var w := str(loadout.get(hp["id"], ""))
		if w == "" or MechCatalog.is_equipment(w):
			continue
		var st := _stats(w, opts, ammo_bonus)
		var rng_m := float(opts.get("range_m", 0.0))
		var share := 1.0
		if rng_m > 0.0:
			if rng_m > float(st["range"]) or rng_m < float(st.get("min_range", 0.0)):
				share = 0.0
			else:
				share = Combat.falloff(st, rng_m)
		var salvo := maxi(int(st.get("salvo", 1)), 1)
		var dmg := float(st["damage"]) * share
		var heat := float(st["active_heat"])
		guns.append({"hp": str(hp["id"]), "w": w, "dmg": dmg, "splash": float(st.get("splash_damage", 0.0)) * share,
			"heat": heat, "salvo": salvo, "interval": 1.0 / maxf(float(st["rate"]) * float(opts.get("fire_rate_mult", 1.0)), 0.001),
			"reload": float(st.get("reload", 0.0)) / float(opts.get("fire_rate_mult", 1.0)),
			"charge": float(st.get("charge", 0.0)), "spin": float(st.get("spin_up", 0.0)),
			"ammo": int(st.get("ammo", -1)), "ammo_total": 0.0,
			"ready": float(st.get("spin_up", 0.0)), "left": 0, "next": 0.0, "dealt": 0.0,
			"prio": (dmg * salvo) / maxf(heat, 0.01)})
		if int(st.get("ammo", -1)) > 0:
			guns[-1]["ammo_total"] = dmg * float(st["ammo"])
	guns.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["prio"]) > float(b["prio"]))
	var walk_heat := float(mv.get("walk_heat", 2.5)) if bool(opts.get("walking", true)) else 0.0
	var duration := float(opts.get("duration", 120.0))
	var h := 0.0
	var t := 0.0
	var total := 0.0
	var splash := 0.0
	var burst5 := 0.0
	var dmg30 := 0.0
	var capped := 0.0
	var steps := int(round(duration / DT))
	for _i in steps:
		var held := false
		for g: Dictionary in guns:
			if float(g["dmg"]) <= 0.0:
				continue
			# a salvo in progress ripples out regardless of heat (its heat was paid at the start)
			if int(g["left"]) > 0:
				while int(g["left"]) > 0 and float(g["next"]) <= t + 1e-6:
					total += float(g["dmg"])
					g["dealt"] = float(g["dealt"]) + float(g["dmg"])
					splash += float(g["splash"])
					g["left"] = int(g["left"]) - 1
					g["next"] = float(g["next"]) + float(g["interval"])
					if int(g["left"]) == 0:
						g["ready"] = float(g["next"]) - float(g["interval"]) + maxf(float(g["reload"]), float(g["interval"]))
				continue
			# single shots keep their cadence across steps (a 12/s gatling fires 12/s at DT 0.05)
			while float(g["ready"]) <= t + 1e-6 and int(g["ammo"]) != 0 and int(g["left"]) == 0:
				if h + float(g["heat"]) > cap * HEAT_MARGIN:
					held = true
					g["ready"] = t + DT     # re-try next step: the cadence restarts after a heat hold
					break
				h += float(g["heat"])
				var start := maxf(float(g["ready"]), t - DT) + float(g["charge"])
				if int(g["salvo"]) > 1:
					g["left"] = int(g["salvo"])
					g["next"] = start
					if int(g["ammo"]) > 0:
						g["ammo"] = maxi(int(g["ammo"]) - int(g["salvo"]), 0)
				else:
					total += float(g["dmg"])
					g["dealt"] = float(g["dealt"]) + float(g["dmg"])
					splash += float(g["splash"])
					g["ready"] = start + float(g["interval"])
					if int(g["ammo"]) > 0:
						g["ammo"] = int(g["ammo"]) - 1
		if held:
			capped += DT
		h = clampf(h + (passive + walk_heat - cooling) * DT, 0.0, cap)
		t += DT
		if t <= 5.0 + 1e-6:
			burst5 = total
		if t <= 30.0 + 1e-6:
			dmg30 = total
	var by_slot := {}
	var ammo_total := 0.0
	for g: Dictionary in guns:
		by_slot[g["hp"]] = snappedf(float(g["dealt"]), 0.1)
		ammo_total += float(g["ammo_total"])
	return {"burst5": burst5, "dmg30": dmg30, "dmg120": total, "dps5": burst5 / 5.0, "dps30": dmg30 / 30.0,
		"dps120": total / duration, "ammo_total": ammo_total, "by_slot": by_slot, "splash120": splash,
		"heat_capped_s": capped, "weight": weight, "max_weight": float(c["max_weight"]), "passive": passive,
		"cooling": cooling, "cap": cap, "net_cooling": cooling - passive - walk_heat}


## Every legal loadout of a chassis (items fit their hardpoint, weight <= max_weight, max_per_mech): mirror-symmetric
## pairs of hardpoints that take the same items are enumerated once (unordered).
static func legal_loadouts(chassis_id: String, opts: Dictionary = {}) -> Array[Dictionary]:
	var c := MechCatalog.chassis(chassis_id)
	var hps := hardpoints(chassis_id, opts)
	var lists: Array = []
	for hp: Dictionary in hps:
		var items: Array = [""]
		for w: String in MechCatalog.items_for(hp):
			items.append(w)
		for w: Variant in hp.get("extra_items", []):
			if not items.has(w):
				items.append(w)
		lists.append(items)
	var out: Array[Dictionary] = []
	_enum(hps, lists, 0, {}, out, float(c["max_weight"]))
	return out


static func _enum(hps: Array, lists: Array, i: int, cur: Dictionary, out: Array[Dictionary], max_w: float) -> void:
	if i == hps.size():
		out.append(cur.duplicate())
		return
	var id := str(hps[i]["id"])
	var mirror := ""
	if id.ends_with("_r"):
		mirror = id.substr(0, id.length() - 2) + "_l"
	for w: String in lists[i]:
		# mirror pairs: the right takes an item at or after the left's (unordered pairs)
		if mirror != "" and cur.has(mirror) and lists[i] == lists[i - 1]:
			if (lists[i] as Array).find(w) < (lists[i] as Array).find(str(cur[mirror])):
				continue
		if w != "":
			var d := MechCatalog.weapon(w)
			var mx := int(d.get("max_per_mech", 0))
			if mx > 0 and cur.values().count(w) >= mx:
				continue
		cur[id] = w
		var wt := 0.0
		for v: Variant in cur.values():
			if str(v) != "":
				wt += float(MechCatalog.weapon(str(v))["weight"])
		if wt <= max_w + 1e-6:
			_enum(hps, lists, i + 1, cur, out, max_w)
		cur.erase(id)


## The best legal loadouts by `key` of evaluate (e.g. "dps120") at opts; returns [{loadout, r}] best first.
static func best(chassis_id: String, key: String, opts: Dictionary = {}, top: int = 3) -> Array[Dictionary]:
	var scored: Array[Dictionary] = []
	for l: Dictionary in legal_loadouts(chassis_id, opts):
		var r := evaluate(chassis_id, l, opts)
		scored.append({"loadout": l, "r": r, "score": float(r[key])})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["score"]) > float(b["score"]))
	return scored.slice(0, top)


## Survivability on paper: core HP, hardpoint HP, repair-drone healing per charge / per mission, and the body's
## presented area (sum of the hit spheres' cross sections, a rough "how easy to hit": overlap counted).
static func survivability(chassis_id: String, loadout: Dictionary) -> Dictionary:
	var comp: Dictionary = PlayerTarget.CHASSIS_COMPONENT_HP.get(chassis_id, PlayerTarget.COMPONENT_HP)
	var core := 0.0
	for k: String in comp:
		core += float(comp[k])
	var hp_n := 0
	var drones := 0
	for v: Variant in loadout.values():
		if str(v) != "":
			hp_n += 1
		if str(v) == "repair_drone":
			drones += 1
	var max_total := core + PlayerTarget.WEAPON_HP * hp_n
	var dr := MechCatalog.weapon("repair_drone")
	var per_charge := float(dr["heal_rate"]) * max_total * float(dr["life"])
	var spheres: Array = PlayerTarget.CHASSIS_BODY_SPHERES.get(chassis_id, PlayerTarget.BODY_SPHERES)
	var area := 0.0
	for s: Dictionary in spheres:
		area += PI * float(s["radius"]) * float(s["radius"])
	return {"core_hp": core, "torso_hp": float(comp["torso"]), "leg_hp": float(comp["leg_l"]), "max_hp": max_total,
		"drone_heal_per_charge": per_charge * drones, "drone_heal_mission": per_charge * float(dr["charges"]) * drones,
		"sphere_area": area}
