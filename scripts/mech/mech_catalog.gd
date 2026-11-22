class_name MechCatalog
extends RefCounted
## Placeholder data: heads, chassis and weapons (docs/design/decisions.md "Mechs"). All numbers are first guesses for the
## scaffold; nothing is balanced. Pure data + helpers, no nodes.
##
## WEAPONS carry the three fields the design names: weight (t, a penalty), passive_heat (heat/s while carried) and
## active_heat (heat per shot / use). Heat is the primary limit: a chassis sheds `cooling` heat/s and shuts down at
## `heat_cap`. A weapon fits a hardpoint whose `mount` is in its `mounts`.

const HEADS := {
	"chicken": {"name": "Chicken", "color": Color(0.96, 0.94, 0.88)},
	"pickle": {"name": "Pickle", "color": Color(0.42, 0.62, 0.22)},
	"corn": {"name": "Corn", "color": Color(0.98, 0.82, 0.25)},
	"dog": {"name": "Dog", "color": Color(0.66, 0.46, 0.28)},
}
const HEAD_ORDER := ["chicken", "pickle", "corn", "dog"]

const CHASSIS := {
	"strider": {
		"name": "Strider",
		"blurb": "Medium biped. Reverse-jointed legs, nose cockpit, five hardpoints.",
		"base_weight": 38.0,
		"max_weight": 30.0,    ## weapons over this slow the mech (the penalty is not built yet)
		"heat_cap": 100.0,
		"cooling": 6.0,
		"hardpoints": [
			{"id": "side_l", "label": "Left side", "mount": "side"},
			{"id": "side_r", "label": "Right side", "mount": "side"},
			{"id": "shoulder_l", "label": "Left shoulder", "mount": "shoulder"},
			{"id": "shoulder_r", "label": "Right shoulder", "mount": "shoulder"},
			{"id": "back", "label": "Back", "mount": "back"},
		],
		"default_loadout": {"side_l": "laser", "side_r": "autocannon", "shoulder_l": "rockets", "shoulder_r": "", "back": "mortar"},
	},
}
const CHASSIS_ORDER := ["strider"]

const WEAPONS := {
	"laser": {"name": "Side Laser", "mounts": ["side"], "weight": 4.0, "passive_heat": 0.5, "active_heat": 7.0,
		"note": "Straight beam; needs line of sight from the hardpoint."},
	"autocannon": {"name": "Autocannon", "mounts": ["side"], "weight": 7.0, "passive_heat": 0.3, "active_heat": 2.5,
		"note": "Rapid kinetic rounds, low heat per shot."},
	"rockets": {"name": "Rocket Pod", "mounts": ["shoulder"], "weight": 6.0, "passive_heat": 0.2, "active_heat": 12.0,
		"note": "Salvo of dumb-fire rockets."},
	"flamer": {"name": "Flamer", "mounts": ["side", "shoulder"], "weight": 3.0, "passive_heat": 1.0, "active_heat": 4.0,
		"note": "Short range, runs hot."},
	"mortar": {"name": "Mortar", "mounts": ["back"], "weight": 9.0, "passive_heat": 0.3, "active_heat": 18.0,
		"note": "Indirect fire over buildings."},
}
const WEAPON_ORDER := ["laser", "autocannon", "rockets", "flamer", "mortar"]


static func head_name(id: String) -> String:
	return str((HEADS.get(id, {}) as Dictionary).get("name", id.capitalize()))


static func chassis(id: String) -> Dictionary:
	return CHASSIS.get(id, CHASSIS["strider"])


static func weapon(id: String) -> Dictionary:
	return WEAPONS.get(id, {})


## Weapon ids that fit a mount, in display order.
static func weapons_for(mount: String) -> Array[String]:
	var out: Array[String] = []
	for id: String in WEAPON_ORDER:
		if mount in (WEAPONS[id]["mounts"] as Array):
			out.append(id)
	return out


## A loadout made valid for a chassis: every hardpoint present, unknown or misfit weapons emptied. An empty saved
## loadout gets the chassis default.
static func sanitize_loadout(chassis_id: String, loadout: Dictionary) -> Dictionary:
	var c := chassis(chassis_id)
	var src: Dictionary = loadout if not loadout.is_empty() else c["default_loadout"]
	var out := {}
	for hp: Dictionary in c["hardpoints"]:
		var w := str(src.get(hp["id"], ""))
		out[hp["id"]] = w if w != "" and WEAPONS.has(w) and str(hp["mount"]) in (WEAPONS[w]["mounts"] as Array) else ""
	return out


## Totals for the hangar's readout: weapon weight, passive heat/s, the hottest single use, and the chassis limits.
static func loadout_stats(chassis_id: String, loadout: Dictionary) -> Dictionary:
	var c := chassis(chassis_id)
	var weight := 0.0
	var passive := 0.0
	var peak := 0.0
	var count := 0
	for w: Variant in loadout.values():
		var d := weapon(str(w))
		if d.is_empty():
			continue
		count += 1
		weight += float(d["weight"])
		passive += float(d["passive_heat"])
		peak = maxf(peak, float(d["active_heat"]))
	return {"weapons": count, "weight": weight, "max_weight": float(c["max_weight"]), "overweight": weight > float(c["max_weight"]),
		"passive_heat": passive, "cooling": float(c["cooling"]), "net_cooling": float(c["cooling"]) - passive,
		"peak_heat": peak, "heat_cap": float(c["heat_cap"])}
