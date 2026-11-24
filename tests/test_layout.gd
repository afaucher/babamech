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
		await _hud_bulwark(sz)
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
	# The mission layer (MissionHud, W6): exactly one objective panel, top right (the top-centre objective strip is
	# gone: playtest 2026-11-23), below the help line, clear of every corner; the waypoint canvas covers the screen and
	# the demo waypoint is on it; the end banner (demo_banner) fully on screen.
	var mh := hud.mission_hud
	if check(mh != null, tag + ": the HUD has a mission layer"):
		lc.fills_screen(mh, tag + " mission layer")
		lc.fills_screen(mh.markers, tag + " mission markers")
		_one_objective_panel(hud, mh, tag + " (demo objective)")
		check(not ("objective_panel" in mh), tag + ": no top-centre objective panel any more")
		eq(mh.shown_lines(), [str(MissionHud.DEMO_STATE["objective"])], tag + ": the panel shows the objective text")
		var obj_r := mh.list_panel.get_global_rect()
		check(not obj_r.intersects(cp.get_global_rect()), tag + ": the objective panel is clear of the crew panel")
		check(not obj_r.intersects(hud.status_panel.get_global_rect()) and not obj_r.intersects(hud.weapon_panel.get_global_rect()),
			tag + ": the objective panel is clear of the bottom corners")
		var ws := mh.waypoint_screen()
		check(not ws.is_empty() and hud.root.get_global_rect().has_point(ws["at"]), tag + ": the demo waypoint is on screen")
		mh.demo_banner = true
		await frames(2)
		check(mh.banner.visible, tag + ": the demo banner shows")
		lc.on_screen(mh.banner, tag + " end banner", MissionHud.BANNER_SIZE, 1.0)
		check(not mh.banner.get_global_rect().intersects(obj_r), tag + ": the banner is clear of the objective panel")
		_one_objective_panel(hud, mh, tag + " (banner)")
		# Plan mode (mission objectives phase 1, demo_plan): the objective list top right, the reinforcement line and the
		# zone bar centred under the alert line, an objective marker, the defend ring and the edge arrow inside the screen.
		mh.demo_banner = false
		mh.demo_plan = true
		await frames(2)
		check(mh.list_panel.visible and mh.alert_panel.visible and mh.zone_panel.visible, tag + ": the plan panels show")
		_one_objective_panel(hud, mh, tag + " (plan)")
		lc.on_screen(mh.alert_panel, tag + " reinforcement line", MissionHud.ALERT_SIZE, 1.0)
		lc.on_screen(mh.zone_panel, tag + " zone bar", MissionHud.ZONE_SIZE, 1.0)
		var lr := mh.list_panel.get_global_rect()
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
		# Supply depot (pacing-director.md §2): the pilot taking a power core reads as one more line in the SAME panel
		# (MissionFlow._plan_hud puts MissionDepots.progress_line() in `lines`), on screen with a full list of lines.
		var core_line := MissionDepots.line_for(0.6)
		eq(core_line, "Taking power core: 60%", tag + ": the core line's text")
		var plan_lines: Array = (MissionHud.DEMO_PLAN["lines"] as Array).duplicate()
		plan_lines.append(core_line)
		hud.demo = false
		mh.source = func() -> Dictionary: return {"objective": "", "waypoint": {}, "banner": {}, "plan": true, "deck": 0,
			"lines": plan_lines, "waves": [1, 3]}
		await frames(2)
		check(mh.shown_lines().has(core_line), tag + ": the core line is in the objective panel")
		_one_objective_panel(hud, mh, tag + " (core line)")
		lc.on_screen(mh.list_panel, tag + " objective panel with the core line",
			Vector2(MissionHud.LIST_W, MissionHud.LIST_HEAD + MissionHud.LIST_LINE * plan_lines.size()), 1.0)
		mh.source = Callable()
		hud.demo = true
		await _downed_hud(hud, mh, tag)
		await _long_panel(hud, mh, tag)
	hud.queue_free()
	await frames(1)


## The mech HUD for a Bulwark pilot (demo_chassis "bulwark"): four weapon rows keyed 1-4, every row on screen and clear
## of the status corner, the drone row keyed by its own slot (4) with its hint, the diagram drawing the Bulwark (its
## hardpoints, no Strider shoulder / back zones), every zone inside the status panel.
func _hud_bulwark(sz: Vector2i) -> void:
	var hud := MechHud.new()
	hud.demo = true
	hud.demo_chassis = "bulwark"
	add_child(hud)
	await frames(3)
	var tag := "hud(bulwark)@%dx%d" % [sz.x, sz.y]
	lc.fills_screen(hud.root, tag + " root")
	lc.on_screen(hud.status_panel, tag + " status (heat + damage)", MechHud.STATUS_SIZE, 1.0)
	eq(hud.rows.size(), 4, tag + ": one row per Bulwark hardpoint")
	var keys: Array = hud.slots().map(func(s: Dictionary) -> int: return int(s["slot"]))
	eq(keys, [1, 2, 3, 4], tag + ": keys 1-4")
	for r: Control in hud.rows:
		lc.on_screen(r, "%s weapon row %s" % [tag, r.name], MechHud.ROW_SIZE, 1.0)
	check(not hud.status_panel.get_global_rect().intersects(hud.weapon_panel.get_global_rect()),
		tag + ": the status and weapon corners don't overlap")
	for s: Dictionary in hud.slots():
		check(MechHud.MOUNT_SHORT.has(str(s["hardpoint"])), tag + ": a short mount label for " + str(s["hardpoint"]))
		if bool(s.get("equipment", false)):
			eq(int(s["slot"]), MechCatalog.slot_key("bulwark", str(s["hardpoint"])), tag + ": the drone row's key is its slot")
			eq(str(s.get("hint", "")), "PRESS %d" % int(s["slot"]), tag + ": its hint names that key")
	eq(hud.status_diagram.chassis, "bulwark", tag + ": the diagram draws the Bulwark")
	var panel := hud.status_panel.size
	var z := MechDiagram.zones(hud.status_diagram.view, hud.status_diagram.style, hud.status_diagram.mounted, panel,
		hud.status_diagram.head, "bulwark")
	for id: String in MechDiagram.component_ids({}, "bulwark"):
		check(z.has(id) and (z[id] as Array).size() > 0, tag + ": the diagram has a %s zone" % id)
	for id: String in ["shoulder_l", "shoulder_r", "back"]:
		check(not z.has(id), tag + ": no Strider %s zone on the Bulwark" % id)
	var box := Rect2(Vector2.ZERO, panel).grow(0.5)
	var inside := true
	for id: String in z:
		for p: PackedVector2Array in z[id]:
			for q in p:
				inside = inside and box.has_point(q)
	check(inside, tag + ": every diagram zone is inside the status panel")
	hud.queue_free()
	await frames(1)


## Downed / revive (DownedCrew -> MissionHud.downed_source, demo_downed): the downed pilot's centre prompt (with its
## hold bar) fully on screen, centred, clear of the objective panel and the bottom corners; the crewmate's line in the
## SAME top-right panel, inside its height (flat list and structured panel); the wreck marker inside the screen; still
## exactly one objective panel.
func _downed_hud(hud: MechHud, mh: MissionHud, tag: String) -> void:
	mh.demo_downed = true
	await frames(2)
	var t := tag + " (downed)"
	check(mh.downed_panel.visible, t + ": the downed prompt shows")
	lc.on_screen(mh.downed_panel, t + " downed prompt", MissionHud.DOWNED_SIZE, 1.0)
	var root := hud.root.get_global_rect()
	var dr := mh.downed_panel.get_global_rect()
	near(dr.get_center().x, root.get_center().x, 1.0, t + ": the prompt is centred")
	check(dr.position.y > root.get_center().y, t + ": the prompt sits under the crosshair")
	check(not dr.intersects(hud.status_panel.get_global_rect()) and not dr.intersects(hud.weapon_panel.get_global_rect()),
		t + ": the prompt is clear of the bottom corners")
	check(not dr.intersects(mh.list_panel.get_global_rect()), t + ": the prompt is clear of the objective panel")
	_one_objective_panel(hud, mh, t)
	var crew_line := str((MissionHud.DEMO_DOWNED["lines"] as Array)[0])
	var lines := mh.shown_lines()
	check(lines.has(crew_line), t + ": the crew line is in the objective panel (%s)" % [lines])
	var lr := mh.list_panel.get_global_rect()
	check(lr.size.y >= MissionHud.LIST_HEAD + MissionHud.LIST_LINE * float(lines.size()) - 0.5,
		t + ": the panel is tall enough for its %d lines (%.0f px)" % [lines.size(), lr.size.y])
	lc.on_screen(mh.list_panel, t + " objective panel with the crew line",
		Vector2(MissionHud.LIST_W, MissionHud.LIST_HEAD + MissionHud.LIST_LINE * float(lines.size())), 1.0)
	var scr := root.grow(-MissionHud.EDGE_PAD + 0.5)
	var dps := mh.downed_points()
	eq(dps.size(), 1, t + ": one downed crewmate marker")
	for m: Dictionary in dps:
		check(scr.has_point(m["at"]), t + ": the wreck marker is inside the screen")
	# The structured panel (plan mode): the crew line is a row of its own, kept when the panel is fitted.
	mh.demo_plan = true
	await frames(2)
	var rows := mh.shown_rows()
	var has_row := false
	for r: Dictionary in rows:
		has_row = has_row or (str(r["role"]) == "crew" and str(r["text"]) == crew_line)
	check(has_row, t + " (plan): the crew line is a row of the structured panel")
	var pr := mh.list_panel.get_global_rect()
	check(pr.size.y >= MissionHud.LIST_HEAD + MissionHud.ROW * float(rows.size()) - 0.5,
		t + " (plan): the panel is tall enough for its %d rows" % rows.size())
	check(pr.size.y <= root.size.y * MissionHud.PANEL_FRAC + 0.5, t + " (plan): within the panel's height cap")
	check(pr.end.y <= root.end.y and not pr.intersects(mh.downed_panel.get_global_rect()), t + " (plan): on screen, clear of the prompt")
	_one_objective_panel(hud, mh, t + " (plan)")
	mh.demo_plan = false
	mh.demo_downed = false
	await frames(2)
	check(not mh.downed_panel.visible, tag + ": no downed prompt when nobody is down")


## A hand-made 5-deck plan: per deck a flag primary and two bonuses (a flag and a defend), the hold on the last deck.
func _long_plan() -> MissionPlan:
	var mp := MissionPlan.new()
	mp.deck_count = 5
	var needs: Array = []
	for k in 5:
		mp.objectives.append({"id": "p%d" % k, "type": "flag", "deck": k, "role": "primary", "site": {"x": 0.0, "s": 50.0},
			"radius": 14.0, "needs": [], "params": {"hold": 20.0}})
		mp.objectives.append({"id": "f%d" % k, "type": "flag", "deck": k, "role": "bonus", "site": {"x": 60.0, "s": -80.0},
			"radius": 14.0, "needs": [], "params": {"hold": 20.0}})
		mp.objectives.append({"id": "d%d" % k, "type": "defend", "deck": k, "role": "bonus", "site": {"x": -60.0, "s": 90.0},
			"radius": 30.0, "needs": [], "params": {"waves": 3, "asset_hp": 1.0}})
		needs.append("p%d" % k)
	mp.objectives.append({"id": "hold", "type": "hold", "deck": 4, "role": "primary", "site": {"x": 0.0, "s": 0.0},
		"radius": 0.0, "needs": needs, "params": {"hold": 60.0, "zone": Rect2(-10, -10, 20, 20)}})
	return mp


## The objective panel with the longest content (5 decks, two found bonuses on each, the depot line, this deck's primary
## done so "Proceed to the next floor" leads): still the one panel, top right, on screen, at most MissionHud.PANEL_FRAC
## of the screen height; every deck still has a line (other decks collapse to one line each); the depot line shows.
func _long_panel(hud: MechHud, mh: MissionHud, tag: String) -> void:
	var sec := SectionPlan.make({"seed": 21.0, "decks": 5.0})
	var rules := MissionRules.make(sec, {"plan": _long_plan()})
	var objs := {}
	for o: Dictionary in rules.objectives:
		objs[o["id"]] = ["known", 3.0, 20.0]
	objs["p0"] = ["done", 20.0, 20.0]
	rules.apply_state({"objs": objs, "left": [4, 6, 8, 10, 12], "reached": 0})
	var core_line := MissionDepots.line_for(0.6)
	for v: int in [0, 2, 4]:
		var pn := rules.panel(v, Vector2(20.0, 30.0), MissionHud.ascii_arrows())
		pn["extra"] = [core_line]
		hud.demo = false
		mh.source = func() -> Dictionary: return {"objective": rules.text(), "waypoint": {}, "banner": {}, "plan": true,
			"deck": v, "panel": pn, "waves": [1, 3]}
		await frames(2)
		var t := "%s (5 decks, viewer deck %d)" % [tag, v + 1]
		_one_objective_panel(hud, mh, t)
		var r := mh.list_panel.get_global_rect()
		var root := hud.root.get_global_rect()
		check(r.size.y <= root.size.y * MissionHud.PANEL_FRAC + 0.5,
			t + ": the panel stays within %d %% of the screen height (%.0f of %.0f)" % [roundi(MissionHud.PANEL_FRAC * 100.0), r.size.y, root.size.y])
		lc.on_screen(mh.list_panel, t + " long objective panel", Vector2(MissionHud.LIST_W, MissionHud.LIST_HEAD + MissionHud.ROW * 3.0), 1.0)
		var shown := mh.shown_lines()
		check(str(pn["header"]).begins_with("DECK %d of 5" % (v + 1)), t + ": header %s" % pn["header"])
		check(shown.has(core_line), t + ": the depot line is in the panel")
		for d in 5:
			if d == v:
				continue
			var any := false
			for s: String in shown:
				any = any or s.contains("DECK %d" % (d + 1))
			check(any, t + ": deck %d still has a line (%s)" % [d + 1, shown])
		var ok := mh.list_panel.get_global_rect().end.y <= root.end.y
		check(ok and not r.intersects(hud.weapon_panel.get_global_rect()) and not r.intersects(hud.crew_panel.get_global_rect()),
			t + ": clear of the weapons and the crew panel")
		print("%s: %d rows, panel %.0f x %.0f at (%.0f, %.0f)" % [t, shown.size(), r.size.x, r.size.y, r.position.x, r.position.y])
	# The demo panel (deck 1 of 3) shows its header, the sub-headers and the route line.
	mh.source = Callable()
	hud.demo = true
	mh.demo_plan = true
	await frames(2)
	var demo := mh.shown_lines()
	check(demo.size() >= 6, tag + ": the demo panel lists this deck, deck 2 with its route, deck 3 (%s)" % [demo])
	mh.demo_plan = false
	await frames(1)


## Exactly one objective panel on the mission layer: the top-right list, visible, fully on screen, right-aligned at the
## HUD margin, in the top part of the screen; no other visible panel draws objective text.
func _one_objective_panel(hud: MechHud, mh: MissionHud, tag: String) -> void:
	var panels: Array = []
	for c: Node in mh.get_children():
		if c is Control and (c as Control).visible and str(c.name).to_lower().contains("objective"):
			panels.append(c)
	eq(panels.size(), 1, tag + ": exactly one visible objective panel (%s)" % [panels.map(func(n: Node) -> String: return str(n.name))])
	check(mh.get_node_or_null("Objective") == null, tag + ": the top-centre 'Objective' strip is gone")
	check(mh.list_panel.visible, tag + ": the objective panel shows")
	lc.on_screen(mh.list_panel, tag + " objective panel", Vector2(MissionHud.LIST_W, MissionHud.LIST_HEAD + MissionHud.LIST_LINE), 1.0)
	var r := mh.list_panel.get_global_rect()
	var root := hud.root.get_global_rect()
	near(r.end.x, root.end.x - MechHud.MARGIN, 1.0, tag + ": the objective panel is right-aligned (top right)")
	check(r.position.x > root.get_center().x, tag + ": the objective panel is in the right half")
	check(r.position.y >= MissionHud.OBJ_TOP - 0.5 and r.position.y < root.size.y * 0.35,
		tag + ": the objective panel is at the top, below the help line (y %.0f)" % r.position.y)


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
	lc.on_screen(fe.obj_check, tag + " hangar objectives")
	await _hangar_framing(fe, left, tag)
	for hp: String in fe.weapon_picks:
		await _reachable(fe.weapon_picks[hp], "%s hangar %s" % [tag, hp])
	await _hangar_bulwark(fe, left, tag)
	# The main actions are pinned in the footer: fully on screen without scrolling, even when a long note and a crew
	# list make the panel taller than the window.
	fe.note = "A long status note. ".repeat(30)
	fe.show_screen("hangar")
	await frames(2)
	for b: Button in [fe.btn_launch, fe.btn_leave]:
		lc.on_screen(b, "%s hangar footer '%s' (no scrolling)" % [tag, b.text], Vector2(100, 40), 1.0)
		check(b.get_parent() == fe.footer, "%s: '%s' sits in the pinned footer" % [tag, b.text])
	fe.note = ""
	await _hangar_bots(fe, tag)
	fe.queue_free()
	await frames(1)


## The chassis picker: switching to the Bulwark rebuilds the loadout rows for its four hardpoints (each reachable, the
## side guns offering shoulder weapons too), the bay frames the wide mech, and switching back brings the Strider's
## loadout back (remembered per chassis).
func _hangar_bulwark(fe: FrontEnd, left: Control, tag: String) -> void:
	var strider_loadout := fe._loadout()
	fe._set_chassis("bulwark")
	fe.show_screen("hangar")
	await frames(2)
	eq(fe.chassis_pick.selected, MechCatalog.CHASSIS_ORDER.find("bulwark"), tag + ": the picker shows the Bulwark")
	var ids: Array = []
	for hp: Dictionary in MechCatalog.chassis("bulwark")["hardpoints"]:
		ids.append(str(hp["id"]))
	eq(str(fe.weapon_picks.keys()), str(ids), tag + ": one loadout row per Bulwark hardpoint")
	for hp: String in fe.weapon_picks:
		await _reachable(fe.weapon_picks[hp], "%s hangar Bulwark %s" % [tag, hp])
	var side := fe.weapon_picks["side_l"] as OptionButton
	var labels: Array = []
	for i in side.item_count:
		labels.append(side.get_item_text(i))
	check(labels.any(func(s: String) -> bool: return s.begins_with(str(MechCatalog.weapon("rockets")["name"]))),
		tag + ": the Bulwark's side gun offers the rocket pod (a shoulder weapon)")
	eq(str(fe._loadout()), str(MechCatalog.sanitize_loadout("bulwark", {})), tag + ": a first Bulwark gets its default loadout")
	await _hangar_framing(fe, left, tag + " Bulwark")
	fe._set_chassis("strider")
	fe.show_screen("hangar")
	await frames(2)
	eq(str(fe._loadout()), str(strider_loadout), tag + ": back in the Strider, its loadout is remembered")


## Hangar bots (docs/design/hangar-bots.md): the host of an online crew gets Add bot, the skill picker and a Remove
## button per bot, on screen (or reachable in the scroll panel); solo and a joiner get none of them.
func _hangar_bots(fe: FrontEnd, tag: String) -> void:
	fe.show_screen("hangar")
	await frames(2)
	check(fe.btn_add_bot == null and fe.bot_skill_pick == null, tag + ": solo hangar has no bot controls")
	if not check(Session.host_enet(test_port(24711)), tag + ": hosts a crew for the bot controls"):
		return
	await frames(2)
	var id := Session.add_bot("average")
	check(id < 0, tag + ": the host seats a bot (%d)" % id)
	fe.show_screen("hangar")
	await frames(2)
	await _reachable(fe.btn_add_bot, tag + " hangar Add bot")
	if FrontEnd.SHOW_BOT_SKILL:
		await _reachable(fe.bot_skill_pick, tag + " hangar bot skill")
	if check(fe.bot_remove.has(id), tag + ": the bot's line has a Remove button"):
		await _reachable(fe.bot_remove[id], tag + " hangar Remove bot")
	check(fe.btn_add_bot != null and not fe.btn_add_bot.disabled, tag + ": Add bot is enabled with seats free")
	Session.add_bot()
	Session.add_bot()
	await frames(2)
	check(fe.btn_add_bot != null and fe.btn_add_bot.disabled, tag + ": Add bot is disabled with the crew full")
	# A joiner's view: the same crew list (bots shown) but no controls. (Faked: the hosting flag off for one rebuild.)
	Session.hosting = false
	fe.show_screen("hangar")
	check(fe.btn_add_bot == null and fe.bot_skill_pick == null and fe.bot_remove.is_empty(),
		tag + ": a joiner's hangar has no bot controls")
	Session.hosting = true
	Session.leave()
	await frames(2)


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
