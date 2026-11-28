extends TestCase
## The debrief (playtest R2.15a): the host's debrief payload (NetMission DEBRIEF) maps to the board the hangar shows
## (DebriefStats.table): pilots across the top in seat order with bots by name, one registered stat per row in registry
## order, unknown keys as extra rows, accuracy from hits / shots ("--" for a pilot who never fired), leaders per row
## (ties all lead, nothing marked when everyone ties or on a MOST row at 0, none on Lowest HP). The wire cleaning
## (NetMission.clean_debrief) drops junk; solo end(reason, debrief) keeps it; the menu opens on the debrief board when one
## is waiting and Next goes to the loadout and forgets it.

const PATH := "user://test_debrief_settings.cfg"


func setup() -> void:
	GameSettings.path = PATH
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	_mapping()
	_leaders()
	_cleaning()
	_solo_end()
	await _menu()
	NetMission.clear_debrief()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	finish()


func _payload() -> Dictionary:
	return {"v": 1, "outcome": "won", "reason": "Mission complete", "time": 754.4,
		"pilots": [{"id": 1, "name": "Host"}, {"id": 2, "name": "Ripley"}, {"id": -1, "name": "Bishop"}],
		"stats": {
			"1": {"kills": 9, "damage_dealt": 2400.0, "damage_taken": 900, "shots": 200, "hits": 90, "revives": 1, "downs": 0,
				"cores": 1, "hp_min": 31.6, "flags_taken": 2},
			"2": {"kills": 9, "damage_dealt": 1800.5, "damage_taken": 600, "shots": 0, "hits": 0, "revives": 0, "downs": 0,
				"cores": 1, "hp_min": 12.0},
			"-1": {"kills": 4, "damage_dealt": 1100, "damage_taken": 1400, "shots": 120, "hits": 30, "revives": 2, "downs": 2,
				"cores": 1, "hp_min": 0.0}}}


func _row(t: Dictionary, key: String) -> Dictionary:
	for r: Dictionary in t["rows"]:
		if str(r["key"]) == key:
			return r
	return {}


func _mapping() -> void:
	var t := DebriefStats.table(NetMission.clean_debrief(_payload()))
	eq(str(t["title"]), "MISSION COMPLETE", "won: the board's title")
	check(str(t["subtitle"]).contains("Mission complete") and str(t["subtitle"]).contains("12:34"), "subtitle: reason and time (%s)" % t["subtitle"])
	eq((t["columns"] as Array).map(func(c: Dictionary) -> String: return str(c["name"])), ["Host", "Ripley", "Bishop"],
		"pilots across the top in seat order, the bot by name")
	eq((t["columns"] as Array).map(func(c: Dictionary) -> bool: return bool(c["bot"])), [false, false, true], "the bot is marked a bot")
	var keys: Array = (t["rows"] as Array).map(func(r: Dictionary) -> String: return str(r["key"]))
	var want: Array = []
	for k: String in DebriefStats.STATS:
		if not bool(DebriefStats.STATS[k].get("hidden", false)):
			want.append(k)
	want.append("flags_taken")
	eq(keys, want, "a row per registered stat in registry order (shots hidden), then the unknown key")
	eq(str(_row(t, "flags_taken")["label"]), "Flags Taken", "an unknown key gets a label from its name")
	eq(_row(t, "flags_taken")["cells"], ["2", "-", "-"], "an unknown key: '-' where a pilot has no value")
	eq(_row(t, "hits")["cells"], ["45%", "--", "25%"], "accuracy = hits / shots; '--' for a pilot who never fired")
	eq(_row(t, "damage_dealt")["cells"], ["2400", "1801", "1100"], "damage shows as whole numbers")
	eq(_row(t, "hp_min")["cells"], ["32%", "12%", "0%"], "lowest HP shows as a percent")
	eq(str(DebriefStats.table({"outcome": "lost"})["title"]), "MISSION FAILED", "lost: the board's title")
	var unnamed := DebriefStats.table({"pilots": [{"id": -2}, {"id": 3}]})
	eq((unnamed["columns"] as Array).map(func(c: Dictionary) -> String: return str(c["name"])), ["Bot 2", "Pilot 3"],
		"a pilot without a name still gets a column")
	# A pilot who left mid-mission keeps its column, marked; the payload's labels name extra keys; non-scalar stat
	# values never make a row (also when the payload skipped clean_debrief).
	var more := _payload()
	(more["pilots"] as Array)[1]["left"] = true
	more["labels"] = {"flags_taken": "Flags raised", "kills_by": "Kills by type"}
	(more["stats"]["1"] as Dictionary)["kills_by"] = {"drone": 3, "tank": 2}
	(more["stats"]["2"] as Dictionary)["route"] = [1, 2, 3]
	for src: Dictionary in [NetMission.clean_debrief(more), more]:
		var lt := DebriefStats.table(src)
		eq((lt["columns"] as Array).map(func(c: Dictionary) -> bool: return bool(c["left"])), [false, true, false],
			"a pilot who left keeps its column, flagged left")
		eq(str(_row(lt, "flags_taken")["label"]), "Flags raised", "the payload's label names an extra key")
		check(_row(lt, "kills_by").is_empty() and _row(lt, "route").is_empty(), "dict / array stats make no row")
		eq(_row(lt, "kills")["cells"], ["9", "9", "4"], "the left pilot's numbers still show")
	check(not (NetMission.clean_debrief(more)["stats"]["1"] as Dictionary).has("kills_by"), "clean drops non-scalar stats")
	# Extra rows follow the labels map's order (Missions' reading order), then unlabelled keys A-Z; raw shots / hits never
	# show as rows (shots count every round: a flamer pilot fires thousands), only Accuracy.
	var ord := _payload()
	ord["labels"] = {"kills_trooper": "Troopers killed", "kills_tank": "Tanks killed", "self_revives": "Self revives",
		"redeploys": "Redeploys", "time_down": "Time down"}
	for k: String in ["time_down", "redeploys", "zeta", "self_revives", "kills_tank", "alpha", "kills_trooper"]:
		(ord["stats"]["1"] as Dictionary)[k] = 1
	var ot := DebriefStats.table(NetMission.clean_debrief(ord))
	var okeys: Array = (ot["rows"] as Array).map(func(r: Dictionary) -> String: return str(r["key"]))
	eq(okeys.slice(okeys.find("kills_trooper")), ["kills_trooper", "kills_tank", "self_revives", "redeploys", "time_down",
		"alpha", "flags_taken", "zeta"], "extra rows in the labels' order, then unlabelled A-Z")
	check(not okeys.has("shots"), "no raw shots row")
	eq((ot["rows"] as Array).filter(func(r: Dictionary) -> bool: return str(r["label"]) in ["Hits", "Shots fired", "Shots"]).size(), 0,
		"no raw hits / shots rows")
	eq(str(_row(ot, "hits")["label"]), "Accuracy", "hits show only as Accuracy (hits / shots)")
	var board := DebriefBoard.new()
	add_child(board)
	board.show_table(DebriefStats.table(NetMission.clean_debrief(more)))
	eq(board.left_labels.size(), 1, "the board marks one pilot as left")
	eq(board.left_labels[0].text, "left", "the mark reads 'left'")
	eq(board.left_labels[0].get_parent(), board.name_labels[1].get_parent(), "the mark sits under that pilot's name")
	check(board.name_labels[1].get_theme_color("font_color") == DebriefBoard.GONE, "the left pilot's name is greyed")
	check((board.cells[1] as Array)[1].get_theme_color("font_color") == DebriefBoard.GONE, "the left pilot's cells are greyed")
	board.free()
	# The stub (until the host's counters exist; --menu-screen debrief) names every crew member, bots included.
	var crew := [{"peer": 1, "name": "A"}, {"peer": 5, "name": "B"}, {"peer": -1, "name": "Bot Bishop"}]
	var st := DebriefStats.table(NetMission.clean_debrief(DebriefStats.stub(crew)))
	eq((st["columns"] as Array).size(), 3, "the stub has a column per crew member")
	eq(str((st["columns"] as Array)[2]["name"]), "Bot Bishop", "the stub names the bot")


func _leaders() -> void:
	var t := DebriefStats.table(NetMission.clean_debrief(_payload()))
	eq(_row(t, "kills")["lead"], [true, true, false], "kills: a tie leads together (joint firsts)")
	eq(_row(t, "damage_taken")["lead"], [false, true, false], "damage taken: LEAST is best")
	eq(_row(t, "downs")["lead"], [true, true, false], "downs: zero is the best score when less is better")
	eq(_row(t, "cores")["lead"], [false, false, false], "cores: everyone tied, nobody marked")
	eq(_row(t, "hits")["lead"], [true, false, false], "accuracy: a pilot who never fired neither leads nor counts")
	eq(_row(t, "hp_min")["lead"], [false, false, false], "lowest HP marks nobody")
	eq(DebriefStats.leaders([0.0, 0.0, 0.0], DebriefStats.MOST), [false, false, false], "MOST at zero: nobody")
	eq(DebriefStats.leaders([0.0, 2.0], DebriefStats.MOST), [false, true], "MOST: the higher leads")
	eq(DebriefStats.leaders([5.0], DebriefStats.MOST), [false], "solo: nothing to compare, nothing marked")
	eq(DebriefStats.leaders([NAN, 3.0], DebriefStats.MOST), [false, false], "one value among two: nothing marked")


func _cleaning() -> void:
	var junk := {"outcome": "won", "time": "soon", "pilots": [{"id": 1, "name": "A".repeat(80)}, "x", {"id": 0}, {"id": 1, "name": "dup"},
		{"id": -3, "name": "Bot"}], "stats": {"1": {"kills": 3, "bad": "str", "flag": true, "nested": {}, "inf": INF}, 9: {"kills": 1}}}
	var c := NetMission.clean_debrief(junk)
	eq((c["pilots"] as Array).size(), 2, "clean: junk pilots, id 0 and duplicate ids dropped")
	eq(str(c["pilots"][0]["name"]).length(), NetMission.DEBRIEF_NAME, "clean: names cut")
	check(bool(c["pilots"][1]["bot"]), "clean: a negative id is a bot")
	eq(c["stats"]["1"], {"kills": 3}, "clean: only finite numbers stay")
	eq(c["stats"]["-3"], {}, "clean: a pilot without a row gets an empty one")
	check(not (c["stats"] as Dictionary).has("9"), "clean: rows of pilots not listed are dropped")
	near(float(c["time"]), 0.0, 0.0001, "clean: a non-number time is 0")


func _solo_end() -> void:
	NetMission.clear_debrief()
	check(not Session.online(), "(solo: no session)")
	Session.mission.end("Mission complete", _payload())
	eq((NetMission.last_debrief.get("pilots", []) as Array).size(), 3, "solo end(reason, debrief) keeps the debrief")
	Session.mission.end("")
	eq((NetMission.last_debrief.get("pilots", []) as Array).size(), 3, "an end without one leaves it")
	NetMission.clear_debrief()
	check(NetMission.last_debrief.is_empty(), "clear_debrief forgets it")


func _menu() -> void:
	NetMission.last_debrief = NetMission.clean_debrief(_payload())
	FrontEnd.next_screen = "hangar"   # what MissionScene sets when a solo mission ends
	var fe := (load(Boot.MENU_SCENE) as PackedScene).instantiate() as FrontEnd
	add_child(fe)
	await frames(3)
	eq(fe.screen, "debrief", "back from a mission with a debrief: the hangar opens on the board")
	if check(fe.debrief_board != null, "the board exists"):
		eq(fe.debrief_board.name_labels.map(func(l: Label) -> String: return l.text), ["Host", "Ripley", "Bishop"],
			"the board's top row names every pilot, the bot too")
		eq(fe.debrief_board.row_labels.size(), (DebriefStats.table(NetMission.last_debrief)["rows"] as Array).size(), "a row per stat")
		check(fe.stage.in_bay, "the board stands in the hangar (the bay behind it)")
		var tags := fe.stage.bay.find_children("Tag*", "Label3D", true, false)
		check(not tags.is_empty() and tags.all(func(n: Node) -> bool: return not (n as Label3D).visible),
			"the bay's name tags are hidden under the board")
		check(fe.panel_box.find_children("*", "Label", true, false).all(func(n: Node) -> bool:
			return not (n as Label).text.contains("12:34")), "the outcome and time are on the board only, not the panel")
	check(fe.btn_next != null and fe.btn_next.get_parent() == fe.footer, "Next is in the pinned footer")
	fe.btn_next.pressed.emit()
	await frames(2)
	eq(fe.screen, "hangar", "Next goes to the loadout")
	check(fe.debrief_board == null and fe.find_child("DebriefLayer", true, false) == null, "the board is gone")
	check(NetMission.last_debrief.is_empty(), "the debrief is forgotten")
	fe.queue_free()
	await frames(1)
