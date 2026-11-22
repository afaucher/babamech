class_name EnemyCatalog
extends RefCounted
## Pure data for the starter enemy roster and enemy weapons (docs/design/enemies.md).
## Kept separate from MechCatalog so player hangar / WeaponRangeLab stay clean; CombatWorld.stats() falls back here.

const MIN_TELEGRAPH := 0.3        ## AGENTS.md rule 7: enemy telegraphs are never shorter than 0.3 s

const CLASS_ORDER := ["turret", "strider", "tank"]

## Enemy classes. `components` is ordered with the CORE component first (index 0) so splash / fallback damage hits core.
const CLASSES := {
	"turret": {
		"name": "Enforcer Turret",
		"mass_class": "static",
		"size": Vector3(4.8, 5.6, 4.8),
		"core": "base",
		"heat_cap": 60.0,
		"cooling": 4.0,
		"move_speed": 0.0,
		"flank_speed": 0.0,
		"turn_rate": 0.0,
		"slew_rate": 2.4,
		"patrol_sight_range": 68.0,
		"sight_range": 135.0,
		"fov_deg": 115.0,
		"primary_weapon": "enemy_bolter",
		"secondary_weapon": "",
		"preferred_range": 75.0,
		"min_range": 8.0,
		"explosion_radius": 4.5,
		"explosion_column": 0.0,
		"slot_priority": 1.5,
		"probe_height": 2.6,
		"body_radius": 2.4,
		"eye_height": 4.6,
		"bar_height": 6.6,
		"components": [
			{"id": "base", "hp": 150.0, "mult": 1.0, "heat_mult": 1.0, "weak_point": false, "critical_kill": false,
				"spheres": [{"center": Vector3(0.0, 1.3, 0.0), "radius": 2.3}]},
			{"id": "gun", "hp": 75.0, "mult": 1.25, "heat_mult": 1.0, "weak_point": true, "critical_kill": true,
				"spheres": [{"center": Vector3(0.0, 3.4, -0.3), "radius": 1.8}]},
		],
	},
	"strider": {
		"name": "Hound Skirmisher",
		"mass_class": "light",
		"size": Vector3(3.8, 5.2, 4.2),
		"core": "chassis",
		"heat_cap": 50.0,
		"cooling": 5.0,
		"move_speed": 9.5,
		"flank_speed": 13.5,
		"turn_rate": 3.0,
		"slew_rate": 3.6,
		"patrol_sight_range": 62.0,
		"sight_range": 125.0,
		"fov_deg": 100.0,
		"primary_weapon": "enemy_pulse",
		"secondary_weapon": "",
		"preferred_range": 40.0,
		"min_range": 16.0,
		"explosion_radius": 3.5,
		"explosion_column": 0.0,
		"slot_priority": 1.0,
		"probe_height": 2.6,
		"body_radius": 1.8,
		"eye_height": 4.3,
		"bar_height": 6.1,
		"components": [
			{"id": "chassis", "hp": 100.0, "mult": 1.0, "heat_mult": 1.0, "weak_point": false, "critical_kill": false,
				"spheres": [{"center": Vector3(0.0, 3.5, -0.1), "radius": 1.65}]},
			{"id": "legs", "hp": 55.0, "mult": 1.0, "heat_mult": 1.0, "weak_point": false, "critical_kill": false,
				"cripple_speed": 0.25, "cripple_stagger": 1.5, "overflow_to_core": 0.6,
				"spheres": [{"center": Vector3(0.0, 1.4, 0.0), "radius": 1.45}]},
			{"id": "sensor", "hp": 40.0, "mult": 1.5, "heat_mult": 1.0, "weak_point": true, "critical_kill": true,
				"spheres": [{"center": Vector3(0.0, 4.3, -1.2), "radius": 0.85}]},
		],
	},
	"tank": {
		"name": "Bastion Siege Tank",
		"mass_class": "heavy",
		"size": Vector3(6.8, 5.4, 9.6),
		"core": "hull",
		"heat_cap": 100.0,
		"cooling": 4.0,
		"move_speed": 5.5,
		"flank_speed": 5.5,
		"turn_rate": 0.9,
		"slew_rate": 1.4,
		"patrol_sight_range": 70.0,
		"sight_range": 145.0,
		"fov_deg": 105.0,
		"primary_weapon": "enemy_siege_shell",
		"secondary_weapon": "enemy_mortar",
		"preferred_range": 68.0,
		"min_range": 24.0,
		"explosion_radius": 6.5,
		"explosion_column": 14.0,
		"slot_priority": 2.0,
		"probe_height": 2.2,
		"body_radius": 3.5,
		"eye_height": 4.7,
		"bar_height": 6.5,
		"components": [
			{"id": "hull", "hp": 320.0, "mult": 1.0, "heat_mult": 1.0, "weak_point": false, "critical_kill": false,
				"spheres": [
					{"center": Vector3(0.0, 1.5, -2.0), "radius": 2.6},
					{"center": Vector3(0.0, 1.5, 2.0), "radius": 2.6},
				]},
			{"id": "turret", "hp": 140.0, "mult": 1.0, "heat_mult": 1.0, "weak_point": false, "critical_kill": false,
				"disable_primary": true, "shock_to_core": 90.0,
				"spheres": [{"center": Vector3(0.0, 3.5, -0.4), "radius": 2.1}]},
			{"id": "vents", "hp": 90.0, "mult": 1.75, "heat_mult": 1.5, "weak_point": true, "critical_kill": true,
				"kill_cause": "meltdown",
				"spheres": [{"center": Vector3(0.0, 3.1, 3.2), "radius": 1.5}]},
		],
	},
}

## Enemy weapons (scheduled effects via CombatWorld.fire): fewer, slower, loudly telegraphed shots that HIT HARD.
const WEAPONS := {
	"enemy_bolter": {
		"name": "Enforcer Bolter", "kind": "shell", "damage": 34.0, "rate": 4.5, "salvo": 1, "reload": 0.0,
		"speed": 42.0, "range": 160.0, "falloff_start": 95.0, "falloff_min": 0.70, "spread": 1.6,
		"knockback": 2.5, "splash_damage": 0.0, "splash_radius": 0.0, "target_heat": 0.0, "ammo": -1,
		"growth": 2.6, "growth_full": 100.0, "size": 0.72, "trail": 0.40, "impact_radius": 1.9, "muzzle": 3.8,
		"telegraph": 0.65, "telegraph_kind": "cannon", "lock_share": 0.45, "lead_factor": 0.65,
		"burst": 2, "burst_interval": 0.24, "burst_cooldown": 2.8, "self_heat": 10.0,
	},
	"enemy_pulse": {
		"name": "Hound Pulse Carbine", "kind": "bullet", "damage": 18.0, "rate": 6.5, "salvo": 1, "reload": 0.0,
		"speed": 48.0, "range": 115.0, "falloff_start": 65.0, "falloff_min": 0.65, "spread": 2.4,
		"knockback": 1.0, "splash_damage": 0.0, "splash_radius": 0.0, "target_heat": 0.0, "ammo": -1,
		"growth": 2.8, "growth_full": 90.0, "size": 0.56, "trail": 0.30, "impact_radius": 1.2, "muzzle": 2.4,
		"telegraph": 0.55, "telegraph_kind": "pulse", "lock_share": 0.45, "lead_factor": 0.65,
		"burst": 3, "burst_interval": 0.16, "burst_cooldown": 2.4, "self_heat": 8.0,
	},
	"enemy_siege_shell": {
		"name": "Bastion Siege Cannon", "kind": "shell", "damage": 85.0, "rate": 1.0, "salvo": 1, "reload": 0.0,
		"speed": 36.0, "range": 180.0, "falloff_start": 130.0, "falloff_min": 0.80, "spread": 0.6,
		"knockback": 7.5, "splash_damage": 40.0, "splash_radius": 6.5, "splash_knockback": 5.0, "splash_lift": 2.2,
		"target_heat": 0.0, "ammo": -1, "explosive": true, "prop_blast": 7.0,
		"growth": 2.6, "growth_full": 120.0, "size": 1.15, "trail": 0.50, "impact_radius": 5.0, "muzzle": 6.4,
		"telegraph": 1.05, "telegraph_kind": "cannon", "lock_share": 0.45, "lead_factor": 0.65,
		"burst": 1, "burst_interval": 0.0, "burst_cooldown": 4.0, "self_heat": 22.0,
	},
	"enemy_mortar": {
		"name": "Bastion Flush Mortar", "kind": "arc", "damage": 65.0, "rate": 0.25, "salvo": 1, "reload": 0.0,
		"speed": 0.0, "range": 175.0, "min_range": 32.0, "falloff_start": 175.0, "falloff_min": 1.0, "spread": 0.0,
		"knockback": 4.5, "splash_damage": 35.0, "splash_radius": 6.5, "splash_knockback": 4.0, "splash_lift": 2.5,
		"target_heat": 0.0, "ammo": -1, "explosive": true, "prop_blast": 6.5,
		"growth": 3.0, "growth_full": 120.0, "size": 0.85, "trail": 0.45, "impact_radius": 5.2, "muzzle": 1.5,
		"flight_base": 2.6, "flight_per_100": 0.9, "scatter_max": 3.5, "apex_min": 12.0, "apex_max": 26.0,
		"telegraph": 0.70, "telegraph_kind": "mortar", "lock_share": 0.45, "lead_factor": 0.35,
		"burst": 1, "burst_interval": 0.0, "burst_cooldown": 6.5, "self_heat": 24.0,
	},
}


static func unit(id: String) -> Dictionary:
	return CLASSES.get(id, {})


static func weapon(id: String) -> Dictionary:
	return WEAPONS.get(id, {})


static func telegraph_duration(weapon_id: String, scale: float = 1.0) -> float:
	var base := float(weapon(weapon_id).get("telegraph", 0.5))
	return maxf(base * scale, MIN_TELEGRAPH)
