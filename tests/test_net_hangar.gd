extends NetTest
## The menus over a real 2-process ENet crew (what `.\run.ps1 -Crew 2` shows, headless): both machines run the front end;
## once the client joins, each one's hangar lists both pilots with their name and head, and its 3D line-up shows both
## mechs wearing the right heads. The client then picks the corn head in Settings and the host's hangar follows.

const PEERS := 2
const LINKS := ["off"]

var fe: FrontEnd


func _open_menu() -> void:
	GameSettings.path = "user://test_net_hangar_%s.cfg" % role
	GameSettings.save_settings(GameSettings.DEFAULTS.duplicate(true))
	fe = (load(Boot.MENU_SCENE) as PackedScene).instantiate() as FrontEnd
	get_tree().root.add_child(fe)
	await frames(2)


## The crew list's text and the line-up's heads, as one comparable report.
func _hangar_view() -> Dictionary:
	var lines: Array = []
	if fe.crew_list != null:
		for c in fe.crew_list.get_children():
			if c is Label:
				lines.append((c as Label).text)
	var heads: Array = []
	for m in fe.stage.models:
		heads.append(m.head_id)
	return {"screen": fe.screen, "lines": lines, "heads": heads}


func _shows(view: Dictionary, name_: String, head: String) -> bool:
	for l: Variant in view["lines"]:
		if str(l).contains(name_) and str(l).contains(MechCatalog.head_name(head)):
			return true
	return false


func run_host() -> void:
	await _open_menu()
	await frames(1)
	if not check(await until(func() -> bool: return Session.roster.size() == 2, 20.0), "the client joins"):
		return
	check(await until(func() -> bool: return fe.screen == "hangar" and fe.stage.models.size() == 2, 5.0), "the host's hangar shows two mechs")
	var v := _hangar_view()
	print("[NetTest] host hangar: ", v)
	check(_shows(v, "host", "chicken") and _shows(v, "c1", "pickle"), "the host's crew list shows both pilots and heads: %s" % str(v["lines"]))
	eq(v["heads"], ["chicken", "pickle"], "the host's line-up wears both heads")
	if not check(await wait_reports("view", 1), "the client reports its hangar"):
		return
	var client := int(Session.crew()[1]["peer"])
	var cv: Dictionary = reported(client, "view")
	check(_shows(cv, "host", "chicken") and _shows(cv, "c1", "pickle"), "the client's crew list shows both pilots and heads: %s" % str(cv["lines"]))
	eq(cv["heads"], ["chicken", "pickle"], "the client's line-up wears both heads")
	command(client, "corn")
	check(await until(func() -> bool: return _hangar_view()["heads"] == ["chicken", "corn"], 10.0),
		"the client's Settings head change shows in the host's line-up (%s)" % str(_hangar_view()["heads"]))
	check(_shows(_hangar_view(), "c1", "corn"), "and in the host's crew list")
	check(await wait_done(1), "the client is done")
	fe.queue_free()


func run_client() -> void:
	await _open_menu()
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	check(await until(func() -> bool: return fe.screen == "hangar" and fe.stage.models.size() == 2, 10.0), "the client's hangar shows two mechs")
	report("view", _hangar_view())
	var cmd := await wait_command(20.0)
	if str(cmd.get("cmd", "")) == "corn":
		fe.show_screen("settings")
		await frames(1)
		var i := MechCatalog.HEAD_ORDER.find("corn")
		fe.head_pick.select(i)
		fe.head_pick.item_selected.emit(i)
		fe.btn_back.pressed.emit()
		await frames(2)
		check(fe.screen == "hangar", "Back from Settings returns to the hangar while in a crew")


func after_end() -> void:
	await frames(2)
	eq(fe.screen, "main", "the host leaving takes the client back to the main menu")
	check(fe.status_label.text.contains(NetSession.HOST_ENDED) or Session.last_reason == NetSession.HOST_ENDED, "with the reason")
	fe.queue_free()
