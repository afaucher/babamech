class_name MechHud
extends CanvasLayer
## The in-game mech HUD (docs/design/hud.md; picked layout "corners / holo" from docs/design/hud/grid_hud_r1.png):
##   bottom-left   the mech damage diagram (MechDiagram, front / schematic: the real mech's outline, a zone per head,
##                 torso, leg and hardpoint tinted by component health, slot badges 1-5) inside the heat arc, with the
##                 overheat / shutdown / reboot and thrust states
##   bottom-right  the weapons, one row per hardpoint, numbered 1-5 like the keys: enabled, name, mount, ammo (or inf),
##                 ready / reload bar, heat per shot, and NO LOS / RANGE / HOLD / LOCK / OFFLINE flags; a back-mount
##                 equipment slot (docs/design/back-equipment.md) shows drones left, the drone's time left (green bar +
##                 seconds) and DRONE OUT / EMPTY, or a dim PASSIVE (_draw_equipment_row); it never gets aim pips
##   left column   above the status panel, the crew panel (CrewPanel: one card per teammate; `crew_panel`)
##   top centre    the mission layer (MissionHud, `mission_hud`): the objective line, the extraction waypoint and the end
##                 banner, fed by the drive's MissionFlow (`mission.hud_state`)
##   centre        the crosshair, the aim point, and from each enabled weapon's muzzle a line of pips toward the aim
##                 point (lit by its ready fraction; amber when its line of sight is blocked)
## Read-only: polls WeaponRack (its HUD contract), MechController and the camera every frame. Never writes them, so it
## carries no gameplay state (cosmetic). Component health is a stub until S5: `component_source` (a Callable returning
## {id: 0..1}) or the mech's `components` dictionary if it has one, else everything at full health.
##   var hud := MechHud.new(); hud.bind(mech, rack, camera); add_child(hud)
##   MechHud.for_drive(test_drive)     (the test drive: finds its mech, rack and camera itself)
## `demo` shows fixed sample data (layout tests, screenshots).

const CYAN := Color(0.4, 0.92, 1.0)
const WHITE := Color(0.92, 0.98, 1.0)
const DIM := Color(0.55, 0.7, 0.78)
const AMBER := Color(1.0, 0.7, 0.2)
const RED := Color(1.0, 0.28, 0.22)
const GREEN := Color(0.45, 1.0, 0.6)
const GREY := Color(0.45, 0.5, 0.55)
const GLASS := Color(0.04, 0.11, 0.15, 0.55)
const EDGE := Color(0.4, 0.92, 1.0, 0.75)

const MARGIN := 24.0
const STATUS_SIZE := Vector2(300, 260)
const ROW_SIZE := Vector2(400, 46)
const ROW_GAP := 6.0
const CREW_GAP := 8.0               ## between the crew panel's last card and the status panel
const MOUNT_SHORT := {"side_l": "L SIDE", "side_r": "R SIDE", "shoulder_l": "L SHLDR", "shoulder_r": "R SHLDR", "back": "BACK"}
const PIPS := 4
const DIAGRAM_VIEW := "front"       ## the damage diagram (docs/design/hud/grid_hud_diagram_r1.png, pick 3)
const DIAGRAM_STYLE := "schematic"

var mech: MechController
var rack: WeaponRack
var camera: Camera3D
var drive: Node                     ## a TestDrive: mech / rack / camera are looked up from it until found
var component_source: Callable      ## () -> {component id: health 0..1}; S5 replaces the stub
var demo := false

var root: Control
var aim_view: Control               ## screen-centre look reticle (full screen; 3D tracking dots live in WorldAimMarkers)
var world_aim: WorldAimMarkers      ## depth-tested 3D aim ring & per-weapon tracking dots in world space
var status_panel: Control           ## bottom-left: diagram + heat arc
var status_diagram: MechDiagram     ## the damage diagram in it (pick 3: front / schematic, from the real mech's meshes)
var weapon_panel: Control           ## bottom-right: the rows
var crew_panel: CrewPanel           ## bottom-left, stacked above status_panel: one card per teammate (reads Session)
var mission_hud: MissionHud         ## objective line, extraction waypoint, end banner (reads the drive's MissionFlow)
var rows: Array[Control] = []

var _t := 0.0
var _font: Font


static func for_drive(td: Node) -> MechHud:
	var hud := MechHud.new()
	hud.drive = td
	return hud


func bind(mech_: MechController, rack_: WeaponRack, camera_: Camera3D) -> void:
	mech = mech_
	rack = rack_
	camera = camera_


func _init() -> void:
	name = "MechHud"
	layer = 5


func _ready() -> void:
	_font = ThemeDB.fallback_font
	root = Control.new()
	root.name = "MechHudRoot"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	aim_view = _canvas("Aim", _draw_aim)
	root.add_child(aim_view)
	aim_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	status_panel = _canvas("Status", _draw_status)
	root.add_child(status_panel)
	status_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	status_panel.offset_left = MARGIN
	status_panel.offset_right = MARGIN + STATUS_SIZE.x
	status_panel.offset_top = -MARGIN - STATUS_SIZE.y
	status_panel.offset_bottom = -MARGIN
	status_diagram = MechDiagram.new()
	status_diagram.view = DIAGRAM_VIEW
	status_diagram.style = DIAGRAM_STYLE
	status_panel.add_child(status_diagram)
	status_diagram.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_sync_diagram()
	crew_panel = CrewPanel.new()
	crew_panel.demo = demo
	crew_panel.bottom_gap = MARGIN + STATUS_SIZE.y + CREW_GAP
	root.add_child(crew_panel)
	mission_hud = MissionHud.new()
	mission_hud.demo = demo
	root.add_child(mission_hud)
	weapon_panel = Control.new()
	weapon_panel.name = "Weapons"
	weapon_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(weapon_panel)
	_layout_rows(5)


## Bottom-right column of n rows (rebuilt when the slot count changes).
func _layout_rows(n: int) -> void:
	for r in rows:
		r.queue_free()
	rows.clear()
	var h := n * ROW_SIZE.y + maxi(n - 1, 0) * ROW_GAP
	weapon_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	weapon_panel.offset_left = -MARGIN - ROW_SIZE.x
	weapon_panel.offset_right = -MARGIN
	weapon_panel.offset_top = -MARGIN - h
	weapon_panel.offset_bottom = -MARGIN
	for i in n:
		var row := _canvas("Slot%d" % (i + 1), _draw_row.bind(i))
		weapon_panel.add_child(row)
		row.position = Vector2(0, i * (ROW_SIZE.y + ROW_GAP))
		row.size = ROW_SIZE
		rows.append(row)


func _canvas(n: String, painter: Callable) -> Control:
	var c := Control.new()
	c.name = n
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.draw.connect(func() -> void: painter.call(c))
	return c


func _exit_tree() -> void:
	if world_aim != null and is_instance_valid(world_aim):
		world_aim.queue_free()
		world_aim = null


func _process(delta: float) -> void:
	_t += delta
	_find_sources()
	_sync_world_aim()
	var n := slots().size()
	if n != rows.size() and n > 0:
		_layout_rows(n)
	crew_panel.demo = demo
	mission_hud.demo = demo
	aim_view.queue_redraw()
	status_panel.queue_redraw()
	_sync_diagram()
	for r in rows:
		r.queue_redraw()


## Feed the damage diagram: the bound mech's pilot head and loadout (its layout is cached per head + loadout, so a change
## rebuilds it), the slot numbers of the weapon rows and the component health.
func _sync_diagram() -> void:
	if status_diagram == null:
		return
	var hd := pilot_head()
	if status_diagram.head != hd:
		status_diagram.head = hd
	var l := diagram_loadout()
	if status_diagram.mounted != l:
		status_diagram.mounted = l
	var so := {}
	for s: Dictionary in slots():
		so[str(s["hardpoint"])] = int(s["slot"])
	if status_diagram.slot_of != so:
		status_diagram.slot_of = so
	status_diagram.health = components()


func _sync_world_aim() -> void:
	if demo:
		return
	if world_aim == null and rack != null:
		var host := drive if (drive != null and drive is Node3D) else (get_parent() as Node)
		if host != null and host.is_inside_tree():
			world_aim = WorldAimMarkers.new()
			host.add_child(world_aim)
	if world_aim != null and is_instance_valid(world_aim):
		world_aim.rack = rack
		world_aim.camera = _camera()
		world_aim.mech = mech
		world_aim.sync()


func _find_sources() -> void:
	if drive == null:
		return
	if mech == null and "mech" in drive:
		mech = drive.get("mech")
	if camera == null and "cam" in drive:
		camera = drive.get("cam")
	if rack == null and "combat" in drive and drive.get("combat") != null:
		rack = drive.get("combat").get("rack")
	if not mission_hud.source.is_valid() and "mission" in drive and drive.get("mission") != null:
		mission_hud.source = Callable(drive.get("mission"), "hud_state")
	if mission_hud.from == null and mech != null:
		mission_hud.from = mech


# --- Data (read-only) ---------------------------------------------------------------------------------------------

func slots() -> Array:
	if demo:
		return DEMO_SLOTS
	if rack != null:
		return rack.slots()
	return []


func heat() -> Dictionary:
	if demo:
		return {"heat": 46.0, "cap": 100.0, "fraction": 0.46, "shutdown": false}
	if rack != null:
		return rack.heat_state()
	if mech != null:
		return {"heat": mech.heat, "cap": mech.heat_cap, "fraction": mech.heat / maxf(mech.heat_cap, 0.001), "shutdown": mech.shutdown}
	return {"heat": 0.0, "cap": 100.0, "fraction": 0.0, "shutdown": false}


## The mech's state line: "" | THRUST | EMERGENCY BURN | SHUTDOWN | REBOOTING.
func mech_state() -> String:
	if demo or mech == null:
		return "THRUST" if demo else ""
	if mech.shutdown:
		return "REBOOTING" if mech.heat <= mech.reboot_heat else "SHUTDOWN"
	if mech.emergency:
		return "EMERGENCY BURN"
	return "THRUST" if mech.thrusting else ""


## The mech's model (MechSpawn's MechRig child), or null.
func _model() -> MechModel:
	if mech == null:
		return null
	var rig := mech.get_node_or_null("Rig")
	if rig != null and "model" in rig:
		return rig.get("model") as MechModel
	return null


## The pilot head id the diagram traces: the bound mech's (chicken in the demo or before a mech is bound).
func pilot_head() -> String:
	var m := _model()
	return m.head_id if (not demo and m != null) else MechDiagram.HEAD


## {hardpoint id: weapon id ("" = empty)} for the diagram: the weapon rows' slots, else the model's loadout.
func diagram_loadout() -> Dictionary:
	var out := {}
	for s: Dictionary in slots():
		out[str(s["hardpoint"])] = str(s["weapon"])
	if out.is_empty() and _model() != null:
		out = _model().loadout.duplicate()
	return out


## Component health {id: 0..1}: head, torso, leg_l, leg_r and each hardpoint id. Stub until S5.
func components() -> Dictionary:
	var out := {"head": 1.0, "torso": 1.0, "leg_l": 1.0, "leg_r": 1.0}
	for s: Dictionary in slots():
		out[str(s["hardpoint"])] = 1.0
	var src: Variant = null
	if component_source.is_valid():
		src = component_source.call()
	elif demo:
		src = {"leg_l": 0.45, "shoulder_l": 0.25, "shoulder_r": 0.0, "side_r": 0.8}
	elif mech != null and "components" in mech:
		src = mech.get("components")
	if src is Dictionary:
		for k: String in (src as Dictionary):
			out[k] = clampf(float(src[k]), 0.0, 1.0)
	return out


func _aim_screen() -> Variant:
	if demo:
		return root.size * 0.5 + Vector2(6, -4)
	var cam := _camera()
	if rack == null or cam == null:
		return null
	var p := rack.aim()
	if cam.is_position_behind(p):
		return null
	return cam.unproject_position(p)


func _muzzle_screen(s: Dictionary) -> Variant:
	if demo:
		var i := int(s["slot"]) - 1
		return root.size * 0.5 + DEMO_MUZZLES[i] * minf(root.size.x / 1600.0, root.size.y / 900.0)
	var cam := _camera()
	if cam == null or not s.has("muzzle"):
		return null
	var p: Vector3 = s["muzzle"]
	if cam.is_position_behind(p):
		return null
	return cam.unproject_position(p)


## The slots that get aim pips: built, enabled weapons. Back-mount equipment has no aim and no muzzle: never.
static func aim_pip_slots(all: Array) -> Array:
	return all.filter(func(s: Dictionary) -> bool:
		return str(s["weapon"]) != "" and bool(s["enabled"]) and bool(s.get("built", true)) and not bool(s.get("equipment", false)))


func _camera() -> Camera3D:
	if camera != null and camera.is_inside_tree():
		return camera
	return root.get_viewport().get_camera_3d() if root != null else null


# --- Drawing ------------------------------------------------------------------------------------------------------

func _draw_aim(c: Control) -> void:
	var centre := c.size * 0.5
	var cam := _camera()
	var z := float(cam.get("zoom_amount")) if (cam != null and "zoom_amount" in cam) else 0.0
	var r_arc := lerpf(11.0, 7.5, z)
	var tick0 := lerpf(15.0, 10.5, z)
	var tick1 := lerpf(22.0, 18.0, z)
	# The screen-centre reticle (where you look; tightens cleanly while zoomed with RMB).
	c.draw_arc(centre, r_arc, 0.0, TAU, 32, Color(CYAN if z > 0.1 else WHITE, lerpf(0.55, 0.85, z)), 1.3, true)
	for d: Vector2 in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
		c.draw_line(centre + d * tick0, centre + d * tick1, Color(WHITE, 0.75), 1.5, true)
	# Live 3D play draws the aim ring & per-weapon tracking dots in depth-tested world space (WorldAimMarkers).
	if not demo:
		return
	var aim: Variant = _aim_screen()
	if aim == null:
		return
	var a: Vector2 = aim
	# Per-weapon pips: from each enabled weapon's muzzle toward the aim point, lit by its ready fraction.
	for s: Dictionary in aim_pip_slots(slots()):
		var m: Variant = _muzzle_screen(s)
		if m == null:
			continue
		var from: Vector2 = m
		var col := AMBER if bool(s.get("blocked", false)) else (CYAN if bool(s.get("in_range", true)) else DIM)
		var lit := ceili(float(s.get("ready", 1.0)) * PIPS - 0.001)
		# A barrel still turning toward the crosshair (or parked at its swivel limit) fires along the barrel, not at the
		# aim point: its pips go faint until it is on target.
		var fade := 1.0 if bool(s.get("on_target", true)) else 0.4
		for k in PIPS:
			var t := 0.5 + 0.12 * float(k)
			var p := from.lerp(a, t)
			var on := k < lit
			c.draw_circle(p, 3.2 if on else 2.2, Color(col, (0.95 if on else 0.35) * fade))
		var tag := from.lerp(a, 0.98)
		if bool(s.get("blocked", false)):
			var off := Vector2(5, 5)
			c.draw_line(tag - off, tag + off, AMBER, 1.6, true)
			c.draw_line(tag + Vector2(off.x, -off.y), tag - Vector2(off.x, -off.y), AMBER, 1.6, true)
	# The aim point on the target surface.
	var designating := rack != null and rack.designator_on()
	c.draw_arc(a, 6.0, 0.0, TAU, 20, GREEN if designating else CYAN, 1.8, true)
	c.draw_circle(a, 1.8, WHITE)


func _draw_status(c: Control) -> void:
	var sz := c.size
	var centre := Vector2(sz.x * 0.5, sz.y * 0.47)
	_glass(c, Rect2(Vector2.ZERO, sz))
	# Heat arc around the diagram: 270 degrees, opening at the bottom.
	var h := heat()
	var f := clampf(float(h["fraction"]), 0.0, 1.0)
	var r := minf(sz.x, sz.y) * 0.44
	var a0 := deg_to_rad(135.0)
	var a1 := deg_to_rad(405.0)
	c.draw_arc(centre, r, a0, a1, 64, Color(CYAN, 0.18), 9.0, true)
	var hc := CYAN if f < 0.6 else (AMBER if f < 0.85 else RED)
	var shut := bool(h["shutdown"])
	if shut:
		hc = RED if fmod(_t * 2.0, 1.0) < 0.6 else Color(RED, 0.4)
	if f > 0.002:
		c.draw_arc(centre, r, a0, lerpf(a0, a1, f), 64, hc, 9.0, true)
	for k in 11:   # ticks every 10 %
		var ang := lerpf(a0, a1, float(k) / 10.0)
		var dir := Vector2(cos(ang), sin(ang))
		c.draw_line(centre + dir * (r + 7.0), centre + dir * (r + 11.0 + (3.0 if k % 5 == 0 else 0.0)), Color(CYAN, 0.6), 1.2)
	_text(c, Vector2(0, sz.y - 30), sz.x, "HEAT %d%%" % roundi(f * 100.0), 16, hc if f >= 0.6 or shut else WHITE)
	_text(c, Vector2(0, sz.y - 13), sz.x, "%d / %d" % [roundi(float(h["heat"])), roundi(float(h["cap"]))], 11, DIM)
	var st := mech_state()
	if st != "":
		var sc := RED if st == "SHUTDOWN" else (AMBER if st in ["REBOOTING", "EMERGENCY BURN"] else CYAN)
		_text(c, Vector2(0, sz.y - 50), sz.x, st, 13, sc)


func _draw_row(c: Control, i: int) -> void:
	var all := slots()
	if i >= all.size():
		return
	var s: Dictionary = all[i]
	var sz := c.size
	var empty := str(s["weapon"]) == ""
	var equip := bool(s.get("equipment", false)) and not empty
	var passive := equip and bool(s.get("passive", false))
	# Equipment: the key is lit while it can be used (active: a drone ready to launch); a passive is never "on".
	var on := (bool(s["enabled"]) and not empty) if not equip else (not passive and float(s.get("ready", 0.0)) >= 1.0)
	var built := bool(s.get("built", true))
	var a := 1.0 if (on or (equip and not passive)) else (0.6 if passive else 0.38)
	_glass(c, Rect2(Vector2.ZERO, sz), a)
	# The key number.
	var key := Rect2(8, 8, sz.y - 16, sz.y - 16)
	if on:
		c.draw_rect(key, Color(CYAN, 0.85), true)
	c.draw_rect(key, Color(CYAN, a), false, 1.5)
	_text(c, Vector2(key.position.x, key.position.y + key.size.y * 0.5 + 6), key.size.x, str(int(s["slot"])), 17,
		Color(0.02, 0.08, 0.1) if on else Color(CYAN, a))
	var x := key.end.x + 10.0
	var mount := str(MOUNT_SHORT.get(str(s["hardpoint"]), str(s["hardpoint"]).to_upper()))
	if empty:
		_text(c, Vector2(x, 21), 200, "-- empty --", 14, Color(DIM, a), HORIZONTAL_ALIGNMENT_LEFT)
		_text(c, Vector2(x, 37), 200, mount, 11, Color(DIM, a), HORIZONTAL_ALIGNMENT_LEFT)
		return
	_text(c, Vector2(x, 20), 190, str(s["name"]).to_upper(), 14, Color(WHITE, a), HORIZONTAL_ALIGNMENT_LEFT)
	_text(c, Vector2(x + 150, 20), 60, mount, 10, Color(DIM, a), HORIZONTAL_ALIGNMENT_LEFT)
	if equip:
		_draw_equipment_row(c, s, x, a, passive)
		return
	# Ready / reload bar.
	var bar := Rect2(x, 29, 200, 7)
	var ready := clampf(float(s.get("ready", 1.0)), 0.0, 1.0)
	var reloading := bool(s.get("reloading", false))
	c.draw_rect(bar, Color(CYAN, 0.15 * a), true)
	var bc := AMBER if reloading else (CYAN if ready >= 1.0 else Color(CYAN, 0.7))
	if not built:
		bc = GREY
		ready = 0.0
	if ready > 0.0:
		c.draw_rect(Rect2(bar.position, Vector2(bar.size.x * ready, bar.size.y)), Color(bc, a), true)
	c.draw_rect(bar, Color(CYAN, 0.5 * a), false, 1.0)
	# Ammo and heat per shot, right-aligned.
	var ammo := int(s.get("ammo", -1))
	var ammo_max := int(s.get("ammo_max", -1))
	var ammo_txt := "INF" if ammo < 0 else ("%d/%d" % [ammo, ammo_max] if ammo_max > 0 else str(ammo))
	var ac := RED if ammo == 0 else WHITE
	_text(c, Vector2(sz.x - 96, 21), 84, ammo_txt, 15, Color(ac, a), HORIZONTAL_ALIGNMENT_RIGHT)
	_text(c, Vector2(sz.x - 96, 37), 84, "+%s HEAT" % _num(float(s.get("heat_per_shot", 0.0))), 10, Color(AMBER, 0.85 * a),
		HORIZONTAL_ALIGNMENT_RIGHT)
	# The one flag that matters most right now.
	var flag := ""
	var fc := AMBER
	var hold := str(s.get("hold", "")).to_upper()
	if not built:
		flag = "OFFLINE"
		fc = GREY
	elif hold == "DESTROYED" or hold == "EMPTY" or not bool(s.get("usable", true)):
		# Unusable (rack: destroyed / out of ammo): the row is already dimmed (enabled false); the flag says why, in red.
		flag = hold if hold != "" else "OFFLINE"
		fc = RED
	elif reloading:
		flag = "RELOAD"
	elif str(s.get("hold", "")) != "":
		flag = str(s["hold"]).to_upper()
	elif bool(s.get("blocked", false)):
		flag = "NO LOS"
	elif not bool(s.get("in_range", true)):
		flag = "RANGE"
		fc = DIM
	elif bool(s.get("designating", false)):
		flag = "LOCK"
		fc = GREEN
	if flag != "":
		_text(c, Vector2(x + 210, 37), 80, flag, 10, Color(fc, a), HORIZONTAL_ALIGNMENT_LEFT)


## The rest of a back-mount equipment row (docs/design/back-equipment.md), after the key and the name:
## passive: a dim "PASSIVE" and nothing else. Active (repair drone): a bar that is the ready bar while a drone can
## launch and the drone's time left (green, with seconds) while one is out; drones left as ammo / ammo_max; the heat a
## launch costs (hidden while a drone is out); the hold flag (DRONE OUT / EMPTY / destroyed).
func _draw_equipment_row(c: Control, s: Dictionary, x: float, a: float, passive: bool) -> void:
	var sz := c.size
	var hold := str(s.get("hold", "")).to_upper()
	if passive:
		var pc := RED if hold == "DESTROYED" else DIM
		_text(c, Vector2(x, 37), 200, "DESTROYED" if hold == "DESTROYED" else "PASSIVE", 10, Color(pc, a), HORIZONTAL_ALIGNMENT_LEFT)
		return
	var bar := Rect2(x, 29, 200, 7)
	var left := float(s.get("active_left", 0.0))
	var life := float(MechCatalog.weapon(str(s["weapon"])).get("life", 60.0))
	c.draw_rect(bar, Color(CYAN, 0.15 * a), true)
	if left > 0.0:
		var f := clampf(left / maxf(life, 0.001), 0.0, 1.0)
		c.draw_rect(Rect2(bar.position, Vector2(bar.size.x * f, bar.size.y)), Color(GREEN, a), true)
	elif float(s.get("ready", 0.0)) >= 1.0:
		c.draw_rect(bar, Color(CYAN, a), true)
	c.draw_rect(bar, Color(CYAN, 0.5 * a), false, 1.0)
	var ammo := int(s.get("ammo", -1))
	var ammo_max := int(s.get("ammo_max", -1))
	var ammo_txt := ("%d/%d" % [ammo, ammo_max]) if ammo_max > 0 else str(maxi(ammo, 0))
	_text(c, Vector2(sz.x - 96, 21), 84, ammo_txt, 15, Color(RED if ammo == 0 else WHITE, a), HORIZONTAL_ALIGNMENT_RIGHT)
	if left <= 0.0:   # the launch cost; while a drone is out its countdown needs the room
		_text(c, Vector2(sz.x - 96, 37), 84, "+%s HEAT" % _num(float(s.get("heat_per_shot", 0.0))), 10, Color(AMBER, 0.85 * a),
			HORIZONTAL_ALIGNMENT_RIGHT)
	var flag := hold
	var fc := AMBER
	if left > 0.0:
		flag = "%s %ds" % [hold if hold != "" else "DRONE OUT", ceili(left)]
		fc = GREEN
	elif hold == "EMPTY" or hold == "DESTROYED":
		fc = RED
	if flag != "":
		_text(c, Vector2(x + 210, 37), 90, flag, 10, Color(fc, a), HORIZONTAL_ALIGNMENT_LEFT)


func _glass(c: Control, r: Rect2, a: float = 1.0) -> void:
	draw_glass(c, r, a)


## The HUD's panel look (translucent glass, a thin cyan edge, white corner brackets); shared with CrewPanel.
static func draw_glass(c: Control, r: Rect2, a: float = 1.0) -> void:
	c.draw_rect(r, Color(GLASS, GLASS.a * a), true)
	c.draw_rect(r, Color(EDGE, EDGE.a * a), false, 1.0)
	var k := 8.0   # corner brackets
	for p: Vector2 in [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]:
		var dx := k if p.x == r.position.x else -k
		var dy := k if p.y == r.position.y else -k
		c.draw_line(p, p + Vector2(dx, 0), Color(WHITE, 0.9 * a), 2.0)
		c.draw_line(p, p + Vector2(0, dy), Color(WHITE, 0.9 * a), 2.0)


func _text(c: Control, pos: Vector2, width: float, t: String, size_: int, col: Color,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_CENTER) -> void:
	c.draw_string(_font, pos, t, align, width, size_, col)


static func _num(v: float) -> String:
	return str(roundi(v)) if absf(v - roundf(v)) < 0.05 else "%.1f" % v


# --- Demo data (layout tests, screenshots) ------------------------------------------------------------------------

const DEMO_SLOTS := [
	{"slot": 1, "hardpoint": "side_l", "weapon": "laser", "name": "Side Laser", "enabled": true, "ammo": -1, "ammo_max": -1,
		"ready": 1.0, "reloading": false, "heat_per_shot": 9.0, "blocked": false, "in_range": true, "hold": "", "built": true,
		"designating": false},
	{"slot": 2, "hardpoint": "side_r", "weapon": "autocannon", "name": "Autocannon", "enabled": true, "ammo": 34, "ammo_max": 60,
		"ready": 0.55, "reloading": false, "heat_per_shot": 2.0, "blocked": true, "in_range": true, "hold": "", "built": true,
		"designating": false},
	{"slot": 3, "hardpoint": "shoulder_l", "weapon": "rockets", "name": "Rocket Pod", "enabled": true, "ammo": 12, "ammo_max": 24,
		"ready": 0.3, "reloading": true, "heat_per_shot": 10.0, "blocked": false, "in_range": true, "hold": "", "built": true,
		"designating": false},
	{"slot": 4, "hardpoint": "shoulder_r", "weapon": "", "name": "", "enabled": true, "ammo": -1, "ammo_max": -1,
		"ready": 0.0, "reloading": false, "heat_per_shot": 0.0, "blocked": false, "in_range": true, "hold": "", "built": false,
		"designating": false},
	# Back-mount equipment (docs/design/back-equipment.md): the repair drone with one drone out, 42 s left.
	{"slot": 5, "hardpoint": "back", "weapon": "repair_drone", "name": "Repair Drone", "enabled": true, "ammo": 1, "ammo_max": 2,
		"ready": 0.0, "reloading": false, "heat_per_shot": 15.0, "blocked": false, "in_range": false, "hold": "DRONE OUT",
		"built": true, "designating": false, "on_target": false, "equipment": true, "passive": false, "active_left": 42.0},
]
## Demo muzzle positions in screen space, relative to the centre (at 1600x900): the mech below the crosshair.
const DEMO_MUZZLES := [Vector2(-70, 210), Vector2(70, 210), Vector2(-55, 120), Vector2(55, 120), Vector2(0, 110)]
