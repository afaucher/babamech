class_name EquipmentLook
extends RefCounted
## Back-mount equipment looks on the mechs (docs/design/back-equipment.md "Look"): COSMETIC, every machine, no messages.
## One per CombatWorld (`world.equipment_look`), stepped at the end of CombatWorld.advance for every shooter that has an
## anchor (CombatWorld.set_anchor: the local rack's mech, each crew puppet's mech via CombatNet, the lab model) or was
## watched explicitly (`watch`).
##
## REPAIR DRONE CRADLE: MechModel mounts `Weapon_repair_drone` (mesh `weapon_repair_drone`: cradle + docked drone) under
## HP_<hardpoint>. This swaps that MeshInstance3D's mesh, from our side (no MechModel API):
##   a drone of that shooter is alive here (CombatWorld.drone_of: launched, repairing, or flying home) -> the empty
##   cradle (`weapon_repair_drone_cradle`); otherwise the docked drone (`weapon_repair_drone`), even with no charges left:
##   it visibly came home (the HUD reports EMPTY from the rack). The same rule on every machine, from the drone effect.
## If MechModel rebuilds the node (loadout / art change), the swap re-applies to the new node on the next step; a missing
## node or mesh (placeholder art, a part that isn't in MechMeshes.EQUIPMENT) is skipped harmlessly.
##
## RADIATOR GLOW: the radiator mesh's surface named "heat" (MeshKit) gets one emissive material per mech, its emission
## following that mech's heat fraction (dark at 0, the HUD's orange, red-hot near overheat: heat_glow). Heat source: the
## `heat` given to `watch` (the rack: the mech's gauge; the lab: its Heat), else the anchor's MechController heat /
## heat_cap (a puppet's mech carries the owner's streamed heat, MechPuppet.apply). The material is written only when the
## fraction moved by GLOW_STEP or more (no per-frame allocation).

const DRONE := "repair_drone"
const RADIATOR := "radiator"
const CRADLE_PART := "repair_drone_cradle"
const GLOW_STEP := 0.02           ## heat fraction change that rewrites the radiator material
const RESCAN := 0.5               ## s of clock between searches for a mech's model / equipment node while missing
const HOT := Color(1.0, 0.24, 0.10)   ## red-hot fins near overheat (the HUD's heat RED, a touch more orange)
const GLOW_ENERGY := 1.8          ## emission energy at a full gauge
const HOT_ALBEDO := Color(0.3, 0.3, 0.3)   ## the fins' albedo tint at a full gauge (darker: the glow colour reads)

## shooter -> {"model": Callable () -> MechModel, "heat": Callable () -> float 0..1}
var watched: Dictionary = {}
## shooter -> {"model", "mi", "hp", "id", "shown", "mat", "surf", "frac", "rescan"}: what is mounted and shown now
var _slots: Dictionary = {}


func net_fields() -> Dictionary:
	return {"watched": Net.LOCAL, "_slots": Net.LOCAL}


## Tell the looks where `shooter`'s model and heat fraction come from on this machine. Invalid Callables fall back to
## the anchor (model found under it, its MechController heat).
func watch(shooter: String, model: Callable, heat: Callable = Callable()) -> void:
	watched[shooter] = {"model": model, "heat": heat}


## A launch record reached this world (CombatWorld.launch_drone): show the empty cradle right away.
func on_launch(w: CombatWorld, record: Dictionary) -> void:
	_update(w, str(record.get("shooter", "")))


func step(w: CombatWorld) -> void:
	for s: String in w.anchors:
		_update(w, s)
	for s: String in watched:
		if not w.anchors.has(s):
			_update(w, s)


## What `shooter`'s drone mount shows now: "docked", "cradle", or "" (no drone equipment found / mounted).
func shown(shooter: String) -> String:
	var sl: Variant = _slots.get(shooter)
	return str((sl as Dictionary).get("shown", "")) if sl is Dictionary and str((sl as Dictionary).get("id", "")) == DRONE else ""


## The radiator material of `shooter` (null when none is mounted / found). Tests.
func glow_material(shooter: String) -> StandardMaterial3D:
	var sl: Variant = _slots.get(shooter)
	return (sl as Dictionary).get("mat") as StandardMaterial3D if sl is Dictionary else null


## `shooter`'s MechModel on this machine (watched source, else found under its anchor), or null.
func model_of(w: CombatWorld, shooter: String) -> MechModel:
	var sl := _slot(shooter)
	var m: Variant = sl.get("model")
	if m != null and is_instance_valid(m) and not (m as Node).is_queued_for_deletion():
		return m as MechModel
	sl["model"] = null
	var wd: Variant = watched.get(shooter)
	if wd is Dictionary and ((wd as Dictionary)["model"] as Callable).is_valid():
		var got: Variant = ((wd as Dictionary)["model"] as Callable).call()
		if got != null and is_instance_valid(got) and got is MechModel:
			sl["model"] = got
			return got as MechModel
	var f := w.anchor_of(shooter)
	if not f.is_valid():
		return null
	var node: Variant = f.call()
	if node == null or not is_instance_valid(node):
		return null
	var found := find_model(node as Node)
	sl["model"] = found
	return found


## The first MechModel at or under `root` (breadth first, 4 levels: Mech > Rig > Model).
static func find_model(root: Node) -> MechModel:
	var level: Array = [root] if root != null else []
	var depth := 0
	while not level.is_empty() and depth < 4:
		var next: Array = []
		for n: Variant in level:
			if n is MechModel:
				return n as MechModel
			next.append_array((n as Node).get_children())
		level = next
		depth += 1
	return null


## The world position, model-to-world scale and orientation (unscaled Basis) of `shooter`'s docked drone on
## `hardpoint`: HP_<hardpoint> × MechMeshes.DRONE_DOCK. {} when the model / node isn't here.
func dock(w: CombatWorld, shooter: String, hardpoint: String) -> Dictionary:
	var m := model_of(w, shooter)
	if m == null or not m.is_inside_tree():
		return {}
	var hp := m.find_child("HP_" + hardpoint, true, false) as Node3D
	if hp == null or not hp.is_inside_tree():
		return {}
	var xf := hp.global_transform
	return {"pos": xf * MechMeshes.DRONE_DOCK, "scale": xf.basis.get_scale().x, "basis": xf.basis.orthonormalized()}


## A MechMeshes equipment part's mesh, or null when it isn't one (a missing part never builds a stray mesh).
static func part_mesh(id: String) -> Mesh:
	if not id in MechMeshes.EQUIPMENT:
		return null
	var m := MechMeshes.mesh("weapon_" + id)
	return m if m != null and m.get_surface_count() > 0 else null


## The radiator's emission colour (energy folded in by the caller) at heat fraction `f`: black -> ORANGE -> HOT.
static func heat_glow(f: float) -> Color:
	var c := Color.BLACK.lerp(LowPolyPalette.ORANGE, smoothstep(0.05, 0.6, f))
	return c.lerp(HOT, smoothstep(0.6, 1.0, f))


static func heat_energy(f: float) -> float:
	return GLOW_ENERGY * clampf(f, 0.0, 1.0)


# --- Per shooter ------------------------------------------------------------------------------------------

func _slot(shooter: String) -> Dictionary:
	if not _slots.has(shooter):
		_slots[shooter] = {"model": null, "mi": null, "hp": "", "id": "", "shown": "", "mat": null, "surf": -1,
			"frac": -1.0, "rescan": -INF}
	return _slots[shooter]


func _update(w: CombatWorld, shooter: String) -> void:
	var sl := _slot(shooter)
	var mi := _mount(w, shooter, sl)
	if mi == null:
		return
	match str(sl["id"]):
		DRONE:
			var want := "cradle" if w.drone_of(shooter) != null else "docked"
			if want != str(sl["shown"]):
				_show_drone(mi, sl, want)
		RADIATOR:
			_glow(mi, sl, _heat(w, shooter))


## The mounted equipment MeshInstance3D (cached; re-found after MechModel rebuilt it, at most every RESCAN s).
func _mount(w: CombatWorld, shooter: String, sl: Dictionary) -> MeshInstance3D:
	var mi: Variant = sl["mi"]
	if mi != null and is_instance_valid(mi) and (mi as Node).is_inside_tree() and sl["model"] != null \
			and is_instance_valid(sl["model"]):
		return mi as MeshInstance3D
	sl["mi"] = null
	if w.now < float(sl["rescan"]) and mi == null:
		return null
	sl["rescan"] = w.now + RESCAN
	sl["shown"] = ""
	sl["surf"] = -1
	sl["frac"] = -1.0
	var m := model_of(w, shooter)
	if m == null or not m.is_inside_tree():
		return null
	for hp: Variant in m.loadout:
		var id := str(m.loadout[hp])
		if id != DRONE and id != RADIATOR:
			continue
		var hp_node := m.find_child("HP_" + str(hp), true, false)
		var wn := hp_node.get_node_or_null("Weapon_" + id) if hp_node != null else null
		if wn == null or wn.is_queued_for_deletion():
			continue
		for c in wn.get_children():
			if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
				sl["mi"] = c
				sl["hp"] = str(hp)
				sl["id"] = id
				return c as MeshInstance3D
	sl["id"] = ""
	return null


func _show_drone(mi: MeshInstance3D, sl: Dictionary, want: String) -> void:
	var mesh := part_mesh(CRADLE_PART if want == "cradle" else DRONE)
	if mesh == null:
		sl["shown"] = want              # a missing part: leave the mount as it is
		return
	if mi.mesh != mesh:
		mi.mesh = mesh
		for i in mi.get_surface_override_material_count():
			mi.set_surface_override_material(i, null)
		var m: Variant = sl["model"]
		LowPolyMaterials.apply_accent(mi, (m as MechModel).accent if m != null and is_instance_valid(m) else LowPolyPalette.ORANGE)
	sl["shown"] = want


func _heat(w: CombatWorld, shooter: String) -> float:
	var wd: Variant = watched.get(shooter)
	if wd is Dictionary and ((wd as Dictionary)["heat"] as Callable).is_valid():
		return clampf(float(((wd as Dictionary)["heat"] as Callable).call()), 0.0, 1.0)
	var f := w.anchor_of(shooter)
	var node: Variant = f.call() if f.is_valid() else null
	if node is MechController and is_instance_valid(node):
		var mc := node as MechController
		return clampf(mc.heat / maxf(mc.heat_cap, 0.001), 0.0, 1.0)
	return 0.0


func _glow(mi: MeshInstance3D, sl: Dictionary, f: float) -> void:
	if int(sl["surf"]) < 0:
		var am := mi.mesh as ArrayMesh
		if am == null:
			return
		for i in am.get_surface_count():
			if am.surface_get_name(i) == "heat":
				sl["surf"] = i
		if int(sl["surf"]) < 0:
			sl["surf"] = 1 << 20         # no heat surface on this mesh: nothing to glow
			return
		if sl["mat"] == null:
			sl["mat"] = make_glow_material()
		mi.set_surface_override_material(int(sl["surf"]), sl["mat"])
		sl["frac"] = -1.0
	if int(sl["surf"]) >= mi.get_surface_override_material_count():
		return
	if absf(f - float(sl["frac"])) < GLOW_STEP and not (f <= 0.0 and float(sl["frac"]) > 0.0):
		return
	sl["frac"] = f
	var mat := sl["mat"] as StandardMaterial3D
	mat.emission = heat_glow(f)
	mat.emission_energy_multiplier = heat_energy(f)
	mat.albedo_color = Color.WHITE.lerp(HOT_ALBEDO, clampf(f, 0.0, 1.0))


## The fins' material: vertex colours lit like the matte surface, plus an emission written by _glow.
static func make_glow_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.roughness = 0.6
	m.metallic_specular = 0.3
	m.emission_enabled = true
	m.emission = Color.BLACK
	m.emission_energy_multiplier = 0.0
	return m
