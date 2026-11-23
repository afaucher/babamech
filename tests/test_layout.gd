extends TestCase
## Headless layout: the menu (main, settings, hangar) and the lab (every subject) really cover the screen, their panels
## have real sizes and their key buttons are on screen, at the project size and at other window shapes. Catches the
## "game opens to an empty grey screen" class of bug (front_end.gd once used set_anchors_preset(FULL_RECT), which keeps
## a zero size) that every other headless test missed. Helpers: scripts/test_support/layout_check.gd, docs/testing.md.

const PATH := "user://test_layout_settings.cfg"
## Window shapes to lay out at: the project size, 4:3 (the canvas grows taller under stretch "expand") and ultrawide
## (wider). Same-aspect sizes scale to the same 1600x900 canvas, so only the shape matters.
const SIZES := [Vector2i(1600, 900), Vector2i(1024, 768), Vector2i(2560, 1080)]

var lc: LayoutCheck


func setup() -> void:
	lc = LayoutCheck.new(self)
	GameSettings.path = PATH
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	Session.set_profile("Layout", "dog", "strider")
	for sz: Vector2i in SIZES:
		get_tree().root.size = sz
		await frames(2)
		print("layout at %s (viewport %s)" % [sz, get_tree().root.get_visible_rect().size])
		await _menu(sz)
		await _lab(sz)
		await _hud(sz)
		await _loading(sz)
	get_tree().root.size = SIZES[0]
	await _world_aim_skips_equipment()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	finish()


## A rack stand-in for WorldAimMarkers: one enabled built weapon (slot 1) and the repair drone (slot 5, equipment).
class PipRack extends WeaponRack:
	func slots() -> Array[Dictionary]:
		var weapon := {"slot": 1, "hardpoint": "side_l", "weapon": "laser", "enabled": true, "built": true, "ready": 1.0,
			"blocked": false, "in_range": true, "muzzle": Vector3(-1, 3, 0), "equipment": false}
		var drone := {"slot": 2, "hardpoint": "back", "weapon": "repair_drone", "enabled": true, "built": true, "ready": 1.0,
			"blocked": false, "in_range": false, "muzzle": Vector3(0, 4, 1), "equipment": true, "passive": false}
		return [weapon, drone]

	func aim() -> Vector3:
		return Vector3(0, 2, -40)


## WorldAimMarkers (live 3D pips) draws a weapon's pips but none from an equipment slot (the back mount).
func _world_aim_skips_equipment() -> void:
	var root3d := Node3D.new()
	add_child(root3d)
	var cam := Camera3D.new()
	root3d.add_child(cam)
	cam.position = Vector3(0, 5, 8)
	cam.current = true
	var wam := WorldAimMarkers.new()
	root3d.add_child(wam)
	var rack := PipRack.new()
	wam.rack = rack
	wam.camera = cam
	await frames(1)
	wam.sync()
	var weapon_pips := (wam._slot_pips[0] as Array).filter(func(m: MeshInstance3D) -> bool: return m.visible).size()
	var drone_pips := (wam._slot_pips[1] as Array).filter(func(m: MeshInstance3D) -> bool: return m.visible).size()
	eq(weapon_pips, WorldAimMarkers.PIPS, "world aim: the weapon slot draws its pips")
	eq(drone_pips, 0, "world aim: the equipment slot draws no pips")
	check(not (wam._slot_x[1] as MeshInstance3D).visible, "world aim: no blocked cross for the equipment slot")
	rack.free()
	root3d.queue_free()
	await frames(1)


## The mission loading screen (LoadingScreen) with a crew of four: it fills the screen, and the progress bar, the phase
## line, the crew list (every row) and the tip are on screen, inside the screen with nothing clipped.
func _loading(sz: Vector2i) -> void:
	var ls := LoadingScreen.cover(self)
	ls.set_mission(57036)
	ls.set_section(SectionPlan.make({"seed": 57036.0}))
	ls.crew_source = func() -> Array:
		var out: Array = []
		for i in 4:
			out.append({"peer": i + 1, "name": "Pilot %d" % (i + 1), "head": "dog", "accent": MechAccent.ORDER[i],
				"status": "ready" if i % 2 == 0 else "loading", "local": i == 0})
		return out
	ls.set_phase("crew", 1.0)
	await frames(3)
	var tag := "loading@%dx%d" % [sz.x, sz.y]
	lc.fills_screen(ls.root, tag + " root")
	lc.fills_screen(ls.backdrop, tag + " backdrop")
	lc.on_screen(ls.bar, tag + " progress bar", Vector2(400, LoadingScreen.BAR_H), 1.0)
	lc.on_screen(ls.phase_label, tag + " phase line", Vector2(100, 16), 1.0)
	lc.on_screen(ls.crew_box, tag + " crew list", Vector2(400, 4 * LoadingScreen.ROW_H), 1.0)
	eq(ls.crew_rows().size(), 4, tag + ": a row per crew member")
	for r: Control in ls.crew_rows():
		lc.on_screen(r, "%s crew row %s" % [tag, r.name], Vector2(400, LoadingScreen.ROW_H), 1.0)
	lc.on_screen(ls.tip_label, tag + " tip", Vector2(100, 12), 1.0)
	lc.on_screen(ls.mission_label, tag + " mission line", Vector2(100, 16), 1.0)
	check(not ls.tip_label.get_global_rect().intersects(ls.card.get_global_rect()), tag + ": the tip is clear of the card")
	ls.queue_free()
	await frames(1)


## The mech HUD (demo data): its root fills the screen, the status corner and every weapon row are fully on screen,
## sized as designed, and the two corners don't overlap; the crew panel's three demo cards sit above the status panel.
func _hud(sz: Vector2i) -> void:
	var hud := MechHud.new()
	hud.demo = true
	add_child(hud)
	await frames(3)
	var tag := "hud@%dx%d" % [sz.x, sz.y]
	lc.fills_screen(hud.root, tag + " root")
	lc.fills_screen(hud.aim_view, tag + " aim view")
	lc.on_screen(hud.status_panel, tag + " status (heat + damage)", MechHud.STATUS_SIZE, 1.0)
	eq(hud.rows.size(), 5, tag + ": one row per hardpoint")
	for r: Control in hud.rows:
		lc.on_screen(r, "%s weapon row %s" % [tag, r.name], MechHud.ROW_SIZE, 1.0)
	check(not hud.status_panel.get_global_rect().intersects(hud.weapon_panel.get_global_rect()),
		tag + ": the status and weapon corners don't overlap")
	# Back-mount equipment (docs/design/back-equipment.md): the demo's back slot is the repair drone; its row (key 5) is
	# a full row on screen, and it never gets aim pips.
	var equip := -1
	for i in hud.slots().size():
		if bool((hud.slots()[i] as Dictionary).get("equipment", false)):
			equip = i
	if check(equip >= 0 and equip < hud.rows.size(), tag + ": the demo has an equipment row"):
		eq(int(hud.slots()[equip]["slot"]), 5, tag + ": the equipment row is key 5")
		lc.on_screen(hud.rows[equip], tag + " equipment row", MechHud.ROW_SIZE, 1.0)
	for s: Dictionary in MechHud.aim_pip_slots(hud.slots()):
		check(not bool(s.get("equipment", false)), tag + ": no aim pip for equipment (%s)" % s["weapon"])
	# Heat shutdown (rack hold "SHUTDOWN", selection kept): the mounts park, so no slot gets an aim pip.
	var shut: Array = hud.slots().map(func(s: Dictionary) -> Dictionary:
		var d := s.duplicate()
		d["hold"] = "SHUTDOWN"
		return d)
	eq(MechHud.aim_pip_slots(shut).size(), 0, tag + ": no aim pips while shut down")
	# The crew panel (demo: three teammates): one column of cards straight above the status panel.
	var cp := hud.crew_panel
	check(cp != null and cp.visible, tag + ": the crew panel exists and shows")
	eq(cp.cards.size(), 3, tag + ": a card per demo teammate")
	var status_r := hud.status_panel.get_global_rect()
	var prev := Rect2()
	for i in cp.cards.size():
		var card: Control = cp.cards[i]
		var r := card.get_global_rect()
		var ct := "%s crew card %s" % [tag, card.name]
		lc.on_screen(card, ct, Vector2(CrewPanel.CARD_W, CrewPanel.CARD_MIN_H), 1.0)
		check(not r.intersects(status_r), ct + ": doesn't overlap the status panel")
		check(r.end.y <= status_r.position.y + 0.5, ct + ": sits above the status panel")
		near(r.position.x, status_r.position.x, 0.5, ct + ": left-aligned with the status panel")
		check(not r.intersects(hud.weapon_panel.get_global_rect()), ct + ": clear of the weapon rows")
		if i > 0:
			check(not r.intersects(prev) and r.position.y >= prev.end.y, ct + ": below the previous card, no overlap")
		prev = r
	check(cp.get_global_rect().position.y >= CrewPanel.TOP_RESERVE - 0.5, tag + ": the crew column leaves the top line clear")
	# The mission layer (MissionHud, W6): the objective strip top centre, below the help line, clear of every corner; the
	# waypoint canvas covers the screen and the demo waypoint is on it; the end banner (demo_banner) fully on screen.
	var mh := hud.mission_hud
	if check(mh != null, tag + ": the HUD has a mission layer"):
		lc.fills_screen(mh, tag + " mission layer")
		lc.fills_screen(mh.markers, tag + " mission markers")
		check(mh.objective_panel.visible, tag + ": the demo objective line shows")
		lc.on_screen(mh.objective_panel, tag + " objective line", MissionHud.OBJ_SIZE, 1.0)
		var obj_r := mh.objective_panel.get_global_rect()
		near(obj_r.get_center().x, hud.root.get_global_rect().get_center().x, 1.0, tag + ": the objective line is centred")
		check(obj_r.position.y >= MissionHud.OBJ_TOP - 0.5, tag + ": the objective line sits below the help line")
		check(not obj_r.intersects(cp.get_global_rect()), tag + ": the objective line is clear of the crew panel")
		check(not obj_r.intersects(hud.status_panel.get_global_rect()) and not obj_r.intersects(hud.weapon_panel.get_global_rect()),
			tag + ": the objective line is clear of the bottom corners")
		var ws := mh.waypoint_screen()
		check(not ws.is_empty() and hud.root.get_global_rect().has_point(ws["at"]), tag + ": the demo waypoint is on screen")
		mh.demo_banner = true
		await frames(2)
		check(mh.banner.visible, tag + ": the demo banner shows")
		lc.on_screen(mh.banner, tag + " end banner", MissionHud.BANNER_SIZE, 1.0)
		check(not mh.banner.get_global_rect().intersects(obj_r), tag + ": the banner is clear of the objective line")
		# Plan mode (mission objectives phase 1, demo_plan): the objective list top right, the reinforcement line and the
		# zone bar centred under the alert line, an objective marker, the defend ring and the edge arrow inside the screen.
		mh.demo_banner = false
		mh.demo_plan = true
		await frames(2)
		check(mh.list_panel.visible and mh.alert_panel.visible and mh.zone_panel.visible, tag + ": the plan panels show")
		lc.on_screen(mh.list_panel, tag + " objective list", Vector2(MissionHud.LIST_W, MissionHud.LIST_HEAD + MissionHud.LIST_LINE), 1.0)
		lc.on_screen(mh.alert_panel, tag + " reinforcement line", MissionHud.ALERT_SIZE, 1.0)
		lc.on_screen(mh.zone_panel, tag + " zone bar", MissionHud.ZONE_SIZE, 1.0)
		var lr := mh.list_panel.get_global_rect()
		var obj2 := mh.objective_panel.get_global_rect()
		check(not lr.intersects(obj2), tag + ": the objective list is clear of the objective line")
		check(not lr.intersects(hud.weapon_panel.get_global_rect()) and not lr.intersects(cp.get_global_rect()),
			tag + ": the objective list is clear of the weapons and the crew panel")
		var ar := mh.alert_panel.get_global_rect()
		var zr := mh.zone_panel.get_global_rect()
		check(not ar.intersects(zr) and zr.position.y >= ar.end.y, tag + ": the zone bar sits below the reinforcement line")
		check(not ar.intersects(lr) and not zr.intersects(lr), tag + ": the centre strips are clear of the objective list")
		near(zr.get_center().x, hud.root.get_global_rect().get_center().x, 1.0, tag + ": the zone bar is centred")
		var scr := hud.root.get_global_rect().grow(-MissionHud.EDGE_PAD + 0.5)
		var ops := mh.objective_points()
		eq(ops.size(), 1, tag + ": one demo objective marker")
		for m: Dictionary in ops:
			check(scr.has_point(m["at"]), tag + ": the objective marker is inside the screen")
		var aps := mh.alert_points()
		eq(aps.size(), 1 if MissionHud.SOURCE_ARROW else 0, tag + ": the demo reinforcement arrow only with SOURCE_ARROW")
		for a: Dictionary in aps:
			check(scr.has_point(a["at"]) and not bool(a["on_screen"]) and a.has("dir"), tag + ": the reinforcement arrow sticks to the edge")
		var rl := mh.ring_lines()
		check(rl.size() == 1 and (rl[0] as PackedVector2Array).size() > 8, tag + ": the demo defend ring projects")
		for p: Vector2 in rl[0]:
			if not hud.root.get_global_rect().has_point(p):
				check(false, tag + ": the demo ring point %s is on screen" % p)
				break
		mh.demo_plan = false
	hud.queue_free()
	await frames(1)


func _menu(sz: Vector2i) -> void:
	var fe := (load(Boot.MENU_SCENE) as PackedScene).instantiate() as FrontEnd
	add_child(fe)
	await frames(3)
	var tag := "menu@%dx%d" % [sz.x, sz.y]
	lc.fills_screen(fe, tag + " root")
	var left := fe.footer.get_parent().get_parent().get_parent() as Control   # PanelContainer > Margin > column > footer
	lc.full_height(left, tag + " left panel")
	lc.at_least(left, Vector2(520, 0), tag + " left panel")
	lc.at_least(fe.stage, Vector2(200, 200), tag + " mech preview")
	check(fe.stage.get_global_rect().end.x >= lc.screen(fe).end.x - 1.0, "%s: the preview reaches the right edge" % tag)
	lc.all_controls_sane(fe, tag)
	for b: Button in [fe.btn_play, fe.btn_join, fe.btn_settings, fe.btn_lab, fe.btn_quit]:
		lc.on_screen(b, "%s main '%s'" % [tag, b.text])

	fe.show_screen("settings")
	await frames(2)
	lc.on_screen(fe.name_edit, tag + " settings name")
	lc.on_screen(fe.head_pick, tag + " settings head")
	for id: String in fe.accent_picks:
		lc.on_screen(fe.accent_picks[id], "%s settings accent %s" % [tag, id], Vector2(24, 24), 1.0)
	await _reachable(fe.quality_pick, tag + " settings graphics quality")
	await _reachable(fe.renderer_pick, tag + " settings renderer")
	await _reachable(fe.quality_note, tag + " settings graphics note")
	await _reachable(fe.btn_back, tag + " settings Back")

	fe.show_screen("hangar")
	await frames(2)
	lc.on_screen(fe.chassis_pick, tag + " hangar chassis")
	lc.on_screen(fe.ff_check, tag + " hangar friendly fire")
	await _hangar_framing(fe, left, tag)
	for hp: String in fe.weapon_picks:
		await _reachable(fe.weapon_picks[hp], "%s hangar %s" % [tag, hp])
	# The main actions are pinned in the footer: fully on screen without scrolling, even when a long note and a crew
	# list make the panel taller than the window.
	fe.note = "A long status note. ".repeat(30)
	fe.show_screen("hangar")
	await frames(2)
	for b: Button in [fe.btn_launch, fe.btn_leave]:
		lc.on_screen(b, "%s hangar footer '%s' (no scrolling)" % [tag, b.text], Vector2(100, 40), 1.0)
		check(b.get_parent() == fe.footer, "%s: '%s' sits in the pinned footer" % [tag, b.text])
	fe.note = ""
	fe.queue_free()
	await frames(1)


func _lab(sz: Vector2i) -> void:
	var lab := (load("res://scenes/lab.tscn") as PackedScene).instantiate() as Lab
	add_child(lab)
	await frames(3)
	var tag := "lab@%dx%d" % [sz.x, sz.y]
	var panel := lab._ui.get_parent().get_parent().get_parent() as Control   # PanelContainer > Margin > Scroll > _ui
	for id: String in LabRegistry.ids():
		lab.pick(id)
		await frames(2)
		var t := "%s %s" % [tag, id]
		lc.full_height(panel, t + " side panel")
		lc.at_least(panel, Vector2(380, 0), t + " side panel")
		lc.on_screen(lab._subject_pick, t + " subject pick")
		lc.all_controls_sane(panel, t)
		# The first param / option widget is on screen; the rest may need the scroll bar.
		var first: Control = null
		for c in lab._params_box.get_children():
			if c is Range or c is OptionButton:
				first = c
				break
		if first != null:
			lc.on_screen(first, t + " first param")
		# Subjects with lab_actions (the pilot lab's reactions / tics): every action button is on screen, no scrolling.
		if id == "pilot":
			check(lab._actions_box.visible and lab._actions_box.get_child_count() > 0, t + ": action buttons exist")
			lc.buttons_on_screen(lab._actions_box, t + " actions")
		check(lab.cam != null and lab.cam.is_current(), "%s: the lab camera is current" % t)
	lab.queue_free()
	await frames(1)


## The hangar bay (HangarBay, docs/design/hangar.md): at crew sizes 1-4, every crew mech's measured box (all 8 corners)
## and its name tag project inside the 3D preview, which lies right of the menu panel. The framing comes from the
## preview's real size (HangarBay.camera_frame), so this holds at every window shape; checked at the drag orbit's
## limits too.
func _hangar_framing(fe: FrontEnd, left: Control, tag: String) -> void:
	var srect := fe.stage.get_global_rect()
	check(srect.position.x >= left.get_global_rect().end.x - 1.0,
		"%s: the bay preview starts right of the menu panel (%.0f >= %.0f)" % [tag, srect.position.x, left.get_global_rect().end.x])
	var heads := MechCatalog.HEAD_ORDER
	var inner := srect.grow(-2.0)
	for n in range(1, 5):
		var entries: Array = []
		for i in n:
			entries.append({"head": heads[(i + 1) % heads.size()], "chassis": "strider", "name": "Pilot %d" % (i + 1)})
		fe.stage.show_mechs(entries, true)
		await frames(2)
		var vs := Vector2(fe.stage.viewport.size)
		check(absf(vs.x / vs.y - srect.size.x / srect.size.y) < 0.02,
			"%s crew %d: the bay viewport (%s) has the preview's shape (%s)" % [tag, n, vs, srect.size])
		eq(fe.stage.models.size(), n, "%s crew %d: %d mechs in the bay" % [tag, n, n])
		for orbit: float in [0.0, -HangarBay.ORBIT_MAX, HangarBay.ORBIT_MAX]:
			fe.stage._orbit = orbit
			fe.stage._place_camera()
			var cam := fe.stage.camera
			var scale := srect.size / vs
			var worst := ""
			var lo := Vector2(INF, INF)
			var hi := Vector2(-INF, -INF)
			for i in n:
				var box := fe.stage.bay.mech_box(i)
				var pts: Array[Vector3] = []
				for k in 8:
					pts.append(fe.stage.bay.to_global(box.get_endpoint(k)))
				var tag3 := fe.stage.bay.get_node_or_null("Crew/Tag%d" % i) as Label3D
				if tag3 != null:
					pts.append(tag3.global_position)
				for p in pts:
					var g := srect.position + cam.unproject_position(p) * scale
					lo = lo.min(g)
					hi = hi.max(g)
					if cam.is_position_behind(p) or not inner.has_point(g):
						worst = "seat %d point %s -> %s" % [i + 1, p, g]
			if orbit == 0.0:
				print("%s bay crew %d: preview %s, mechs span %s..%s" % [tag, n, srect, lo.round(), hi.round()])
			check(worst == "", "%s crew %d orbit %.2f: every mech and tag inside the preview %s (spans %s..%s) %s"
				% [tag, n, orbit, srect, lo.round(), hi.round(), worst])
		fe.stage._orbit = 0.0


## On screen, or inside the scroll panel with the panel able to scroll to it (content below the fold is fine when it can
## be scrolled to; a zero-size or hidden control is not).
func _reachable(c: Control, what: String) -> void:
	if not check(c != null and c.is_visible_in_tree(), what + " exists and is visible"):
		return
	var r := c.get_global_rect()
	check(r.size.x >= 4.0 and r.size.y >= 4.0, "%s has a real size (%s)" % [what, r.size])
	var p := c.get_parent()
	while p != null and not (p is ScrollContainer):
		p = p.get_parent()
	if p == null:
		lc.on_screen(c, what)
		return
	var sc := p as ScrollContainer
	lc.on_screen(sc, what + "'s scroll panel", Vector2(100, 100), 1.0)
	sc.ensure_control_visible(c)
	await get_tree().process_frame
	lc.on_screen(c, what + " (scrolled to)")
	sc.scroll_vertical = 0
