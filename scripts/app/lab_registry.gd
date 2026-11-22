class_name LabRegistry
extends RefCounted
## Every scene the lab can show (scripts/app/lab.gd; `.\lab.ps1 -List`). A subject is a Node3D script (or a scene) that
## implements the lab contract:
##   lab_params() -> [{id, label, min, max, value}]     sliders
##   set_lab_param(id, value)
##   lab_options() -> [{id, label, choices, value}]      drop-downs (choices are ids; "" shows as "(none)")
##   set_lab_option(id, value)
##   lab_focus() -> Vector3, lab_radius() -> float       where the camera orbits, and how far out it starts
##   var time_scale                                      the lab's speed / pause scales the subject's own clock
##   lab_own_ground() -> bool (optional)                 true hides the lab's grid floor (the subject brings its own)
##   lab_own_lighting() -> bool (optional)               true removes the lab's sun and environment (the subject lights itself)
##   lab_view_yaw() -> float (optional)                  radians added to the preset views' yaw (a subject whose front
##                                                       isn't -Z: the views still look at its front)
##   lab_actions() -> [{id, label}] (optional)           one-shot buttons in the side panel (re-read whenever the panel
##   do_lab_action(id) (optional)                        is rebuilt, e.g. after an option changes); also `--action <id>`
##                                                       on the lab's command line (applied after --action-after s)
## Register every new scene with tunable params here (decisions.md: "Lab view with every scene and tunable params").

const SUBJECTS := [
	{"id": "mech", "label": "Mech (assembled: head, loadout, art)", "path": "res://scripts/mech/mech_model.gd"},
	{"id": "mech_parts", "label": "Mech parts (low-poly meshes)", "path": "res://scripts/mech/mech_part_gallery.gd"},
	{"id": "heads", "label": "Pilot heads", "path": "res://scripts/mech/head_gallery.gd"},
	{"id": "hangar", "label": "Hangar (assault boat bay: prep / alert)", "path": "res://scripts/ui/hangar_bay.gd"},
	{"id": "ring_walk", "label": "Ring walk (S1: controller + IK gait)", "path": "res://scripts/world/ring_walk_lab.gd"},
	{"id": "thrusters", "label": "Thrusters (S2: jump, hover, emergency burn, overheat)", "path": "res://scripts/world/thruster_lab.gd"},
	{"id": "section", "label": "Mission section (decks, zones, pillars, transit)", "path": "res://scripts/world/section/section_lab.gd"},
	{"id": "city", "label": "City district (pristine urban, seeded)", "path": "res://scripts/world/city/city_lab.gd"},
	{"id": "life", "label": "Ambient life (civilians: calm, panic, killed)", "path": "res://scripts/world/life/life_lab.gd"},
	{"id": "weapon_range", "label": "Weapon range (combat: shots, dummies, knockback)", "path": "res://scripts/combat/weapon_range_lab.gd"},
	{"id": "enemies", "label": "Enemies (turret, skirmisher, siege tank, squad AI)", "path": "res://scripts/enemy/enemy_lab.gd"},
	{"id": "audio", "label": "Audio (soundboard, mix, 3D distance, heat, telegraphs)", "path": "res://scripts/audio/audio_lab.gd"},
	{"id": "pilot", "label": "Pilot expressions (moods, reactions, motion)", "path": "res://scripts/pilot/pilot_lab.gd"},
]


static func ids() -> Array[String]:
	var out: Array[String] = []
	for s: Dictionary in SUBJECTS:
		out.append(str(s["id"]))
	return out


static func find(id: String) -> Dictionary:
	for s: Dictionary in SUBJECTS:
		if s["id"] == id:
			return s
	return {}


## A new instance of a subject (a .gd script or a .tscn scene), or null.
static func make(id: String) -> Node3D:
	var s := find(id)
	if s.is_empty():
		return null
	var res: Resource = load(str(s["path"]))
	if res is PackedScene:
		return (res as PackedScene).instantiate() as Node3D
	if res is GDScript:
		return (res as GDScript).new() as Node3D
	return null
