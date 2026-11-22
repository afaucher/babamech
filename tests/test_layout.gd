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
	get_tree().root.size = SIZES[0]
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	finish()


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
	await _reachable(fe.btn_back, tag + " settings Back")

	fe.show_screen("hangar")
	await frames(2)
	lc.on_screen(fe.chassis_pick, tag + " hangar chassis")
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
