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
	"duck": {"name": "Duck", "color": Color(0.2, 0.42, 0.26)},
}
const HEAD_ORDER := ["chicken", "pickle", "corn", "dog", "duck"]

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

## Combat stats (docs/design/weapons.md §3; first pass, tuned in the `weapon_range` lab). Every weapon has (WEAPON_STATS):
##   kind, damage (per hit), rate (shots/s; inside a salvo for salvo weapons), salvo (shots per trigger cycle), reload
##   (s after a salvo), speed (m/s; 0 = instant / ballistic), range (m), falloff_start (m) / falloff_min (share of damage
##   left at range), spread (deg, cone half-angle), knockback (Δv m/s along the shot, before the target's mass class),
##   splash_damage / splash_radius (m), target_heat (heat added to the target per hit), ammo (-1 = unlimited), growth
##   (drawn size multiplier) / growth_full (m to reach it), size (m, drawn launch size), trail (s of trail), impact_radius
##   (m, ImpactFx R), muzzle (model units ahead of the mount point where shots leave). active_heat is per trigger cycle:
##   per shot, per salvo for salvo weapons. Optional: max_per_mech, explosive, prop_blast (splash Δv on city props only,
##   default splash_knockback), and the per-weapon extras.
##   slew (°/s): how fast a direct-fire weapon pivots at its mount toward the aim point (weapons.md §4.4; default
##   Combat.PIVOT_SLEW; pivot range Combat.PIVOT_YAW / _PITCH_DOWN / _PITCH_UP unless the entry sets yaw_arc /
##   pitch_down / pitch_up). The mortar does not pivot; the swivel uses its own wide arc.
const WEAPONS := {
	"laser": {"name": "Side Laser", "mounts": ["side"], "weight": 4.0, "passive_heat": 0.5, "active_heat": 9.0,
		"note": "Straight beam; needs line of sight from the hardpoint.",
		"kind": "beam", "damage": 55.0, "rate": 0.8, "salvo": 1, "reload": 0.0, "speed": 0.0, "range": 150.0,
		"falloff_start": 80.0, "falloff_min": 0.5, "spread": 0.0, "knockback": 8.0, "splash_damage": 0.0, "splash_radius": 0.0,
		"target_heat": 0.0, "ammo": -1, "growth": 2.86, "growth_full": 150.0, "size": 0.35, "trail": 0.0, "impact_radius": 2.0,
		"muzzle": 1.07, "charge": 0.15, "beam_time": 0.3, "slew": 180.0},
	"autocannon": {"name": "Autocannon", "mounts": ["side", "shoulder"], "weight": 7.0, "passive_heat": 0.3, "active_heat": 1.5,
		"note": "Slow heavy shells with a real kick.",
		"kind": "shell", "damage": 22.0, "rate": 2.5, "salvo": 1, "reload": 0.0, "speed": 70.0, "range": 220.0,
		"falloff_start": 120.0, "falloff_min": 0.6, "spread": 0.4, "knockback": 3.0, "splash_damage": 6.0, "splash_radius": 1.5,
		"target_heat": 0.0, "ammo": -1, "growth": 3.5, "growth_full": 120.0, "size": 0.6, "trail": 0.45, "impact_radius": 1.6,
		"muzzle": 1.46, "slew": 180.0},
	"gatling": {"name": "Rotary Gatling", "mounts": ["side"], "weight": 6.0, "passive_heat": 0.4, "active_heat": 0.45,
		"note": "Close-range hose; spins up, blooms.",
		"kind": "bullet", "damage": 6.0, "rate": 12.0, "salvo": 1, "reload": 0.0, "speed": 85.0, "range": 200.0,
		"falloff_start": 60.0, "falloff_min": 0.5, "spread": 1.2, "knockback": 1.1, "splash_damage": 0.0, "splash_radius": 0.0,
		"target_heat": 0.0, "ammo": -1, "growth": 3.5, "growth_full": 120.0, "size": 0.5, "trail": 0.2, "impact_radius": 1.1,
		"muzzle": 1.02, "spin_up": 0.6, "spin_hold": 1.0, "spread_max": 4.0, "bloom": 0.25, "bloom_recover": 3.0, "slew": 180.0},
	"swivel": {"name": "Swivel Boom", "mounts": ["side"], "weight": 4.0, "passive_heat": 0.3, "active_heat": 1.0,
		"note": "Off-axis twin slugs on a tracking boom.",
		"kind": "slug", "damage": 12.0, "rate": 4.0, "salvo": 1, "reload": 0.0, "speed": 75.0, "range": 160.0,
		"falloff_start": 80.0, "falloff_min": 0.5, "spread": 0.8, "knockback": 1.6, "splash_damage": 0.0, "splash_radius": 0.0,
		"target_heat": 0.0, "ammo": -1, "growth": 3.5, "growth_full": 120.0, "size": 0.5, "trail": 0.3, "impact_radius": 1.0,
		"muzzle": 1.25, "yaw_arc": 120.0, "pitch_down": 40.0, "pitch_up": 60.0, "slew": 240.0},
	"rockets": {"name": "Rocket Pod", "mounts": ["shoulder"], "weight": 6.0, "passive_heat": 0.2, "active_heat": 10.0,
		"note": "Salvo of dumb-fire rockets.",
		"kind": "rocket", "damage": 26.0, "rate": 10.0, "salvo": 6, "reload": 4.0, "speed": 45.0, "range": 250.0,
		"falloff_start": 250.0, "falloff_min": 1.0, "spread": 3.5, "knockback": 0.4, "splash_damage": 18.0, "splash_radius": 4.0,
		"target_heat": 0.0, "ammo": 36, "growth": 2.0, "growth_full": 120.0, "size": 0.9, "trail": 1.2, "impact_radius": 2.5,
		"muzzle": 0.46, "explosive": true, "wobble": 0.6, "prop_blast": 3.0, "slew": 120.0},
	"missiles": {"name": "Guided Missiles", "mounts": ["shoulder"], "weight": 7.0, "passive_heat": 0.4, "active_heat": 8.0,
		"note": "Guided: follows your crosshair while it flies.",
		"kind": "missile", "damage": 30.0, "rate": 3.33, "salvo": 3, "reload": 5.0, "speed": 35.0, "range": 350.0,
		"falloff_start": 350.0, "falloff_min": 1.0, "spread": 0.0, "knockback": 0.6, "splash_damage": 12.0, "splash_radius": 5.0,
		"target_heat": 0.0, "ammo": 18, "growth": 2.8, "growth_full": 120.0, "size": 1.0, "trail": 1.2, "impact_radius": 3.0,
		"muzzle": 0.46, "explosive": true, "speed_max": 55.0, "turn_rate": 120.0, "lifetime": 9.0, "designator_heat": 1.5, "slew": 120.0},
	"mortar": {"name": "Mortar", "mounts": ["back"], "weight": 9.0, "passive_heat": 0.4, "active_heat": 18.0,
		"note": "Indirect fire over buildings.",
		"kind": "arc", "damage": 80.0, "rate": 0.2857, "salvo": 1, "reload": 0.0, "speed": 0.0, "range": 250.0,
		"falloff_start": 250.0, "falloff_min": 1.0, "spread": 0.0, "knockback": 4.0, "splash_damage": 50.0, "splash_radius": 8.0,
		"target_heat": 0.0, "ammo": 12, "growth": 3.0, "growth_full": 120.0, "size": 0.9, "trail": 0.5, "impact_radius": 6.0,
		"muzzle": 1.3, "explosive": true, "min_range": 30.0, "flight_base": 2.0, "flight_per_100": 1.0, "scatter_max": 3.0,
		"splash_knockback": 4.0, "splash_lift": 3.0, "apex_min": 10.0, "apex_max": 28.0, "prop_blast": 8.0},
	"railgun": {"name": "Coil Railgun", "mounts": ["shoulder"], "weight": 14.0, "passive_heat": 1.0, "active_heat": 30.0,
		"note": "One big charged shot; pierces. One per mech.",
		"kind": "slug", "damage": 200.0, "rate": 0.25, "salvo": 1, "reload": 0.0, "speed": 200.0, "range": 400.0,
		"falloff_start": 400.0, "falloff_min": 1.0, "spread": 0.0, "knockback": 14.0, "splash_damage": 0.0, "splash_radius": 0.0,
		"target_heat": 0.0, "ammo": -1, "growth": 1.5, "growth_full": 120.0, "size": 1.0, "trail": 1.5, "impact_radius": 3.5,
		"muzzle": 2.05, "max_per_mech": 1, "charge": 1.0, "pierce": 3, "pierce_loss": 0.25, "cancel_heat": 10.0, "charge_steps": 4, "slew": 90.0},
	"flamer": {"name": "Flamer", "mounts": ["side", "shoulder"], "weight": 3.0, "passive_heat": 1.0, "active_heat": 0.6,
		"note": "Short range; a focused jet that overheats the target.",
		"kind": "flame", "damage": 1.5, "rate": 10.0, "salvo": 1, "reload": 0.0, "speed": 32.0, "range": 45.0,
		"falloff_start": 45.0, "falloff_min": 1.0, "spread": 5.0, "knockback": 0.0, "splash_damage": 0.0, "splash_radius": 0.0,
		"target_heat": 2.2, "ammo": -1, "growth": 6.0, "growth_full": 45.0, "size": 0.25, "trail": 0.0, "impact_radius": 0.0,
		"muzzle": 0.85, "slew": 180.0},
}
## Weapons the hangar offers.
const WEAPON_ORDER := ["laser", "autocannon", "gatling", "swivel", "rockets", "missiles", "flamer", "mortar", "railgun"]
## Every stat a weapon entry carries (test_combat checks them all).
const WEAPON_STATS := ["name", "mounts", "weight", "passive_heat", "active_heat", "kind", "damage", "rate", "salvo", "reload",
	"speed", "range", "falloff_start", "falloff_min", "spread", "knockback", "splash_damage", "splash_radius", "target_heat", "ammo",
	"growth", "growth_full", "size", "trail", "impact_radius", "muzzle"]


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
		var ok := w != "" and WEAPONS.has(w) and str(hp["mount"]) in (WEAPONS[w]["mounts"] as Array)
		if ok and int(WEAPONS[w].get("max_per_mech", 0)) > 0:   # e.g. one railgun per mech: later hardpoints are emptied
			ok = out.values().count(w) < int(WEAPONS[w]["max_per_mech"])
		out[hp["id"]] = w if ok else ""
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
