extends NetTest
## The debrief rides the host's mission.end (playtest R2.15a, NetMission DEBRIEF) over a real 2-process crew with a
## hangar bot: the host launches, then ends the mission with a debrief built from its crew (Session.crew(): players and
## the bot by name, the shape MissionFlow is to send); the client's NetMission.last_debrief is exactly the host's (the
## host's numbers, never recomputed), its board names both pilots and the bot, and a client's own end() with a debrief
## changes nothing (only the host's numbers count). A new launch clears it on both machines.

const PEERS := 2
const LINKS := ["off"]


func _debrief_for(crew: Array) -> Dictionary:
	var pilots: Array = []
	var stats := {}
	for e: Dictionary in crew:
		var id := int(e["peer"])
		pilots.append({"id": id, "name": str(e["name"])})
		stats[str(id)] = {"kills": absi(id) + 2, "damage_dealt": 100.0 * absi(id), "shots": 10, "hits": absi(id)}
	return {"v": 1, "outcome": "won", "reason": "Mission complete", "time": 321.0, "pilots": pilots, "stats": stats}


func run_host() -> void:
	if not check(await until(func() -> bool: return Session.roster.size() == 2, 20.0), "the client joins"):
		return
	var bot := Session.add_bot("average")
	check(bot < 0, "the host seats a bot (%d)" % bot)
	var client := int(Session.roster.keys().filter(func(p: int) -> bool: return p != 1)[0])
	await frames(5)
	check(Session.mission.host_launch(5), "the host launches")
	if not check(await wait_reports("launched", 1, 15.0), "the client hears the launch"):
		return
	var sent := _debrief_for(Session.crew())
	Session.mission.end("Mission complete", sent)
	eq((NetMission.last_debrief["pilots"] as Array).size(), 3, "the host keeps its debrief: two pilots and the bot")
	if not check(await wait_reports("debrief", 1, 15.0), "the client reports the debrief it got"):
		return
	var got: Dictionary = reported(client, "debrief")
	eq(got.get("payload", {}), NetMission.last_debrief, "the client's debrief is exactly the host's")
	eq(got.get("names", []), ["host", "c1", (Session.member(bot)["name"])], "the client's board names both pilots and the bot")
	check(bool(got.get("own_end_ignored", false)), "a client's own end(debrief) doesn't replace the host's")
	# A new launch forgets the last debrief on every machine.
	await frames(5)
	check(Session.mission.host_launch(6), "the host launches again")
	check(NetMission.last_debrief.is_empty(), "the host's launch clears its debrief")
	if not check(await wait_reports("cleared", 1, 15.0), "the client reports after the second launch"):
		return
	check(bool(reported(client, "cleared")), "the client's debrief is cleared by the launch")
	Session.mission.end()
	check(await wait_done(1, 20.0), "the client is done")


func run_client() -> void:
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return Session.mission.active(), 20.0), "the launch arrives"):
		return
	report("launched", true)
	if not check(await until(func() -> bool: return not NetMission.last_debrief.is_empty(), 15.0), "the debrief arrives"):
		return
	var payload := NetMission.last_debrief.duplicate(true)
	var board := DebriefBoard.new()
	add_child(board)
	board.show_table(DebriefStats.table(payload))
	var names: Array = board.name_labels.map(func(l: Label) -> String: return l.text)
	board.queue_free()
	Session.mission.end("", {"pilots": [{"id": 99, "name": "forged"}]})
	report("debrief", {"payload": payload, "names": names, "own_end_ignored": NetMission.last_debrief == payload})
	report("cleared", await until(func() -> bool: return Session.mission.active() and NetMission.last_debrief.is_empty(), 15.0))
