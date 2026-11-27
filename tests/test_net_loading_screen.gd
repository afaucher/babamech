extends NetTest
const QUIET_SECTION := true   # TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"): no director, no objectives
## The mission loading screen in a crew of 2 with the game's stepped load (LoadingScreen, docs/design/hud.md "Loading
## screen"; NetMission's mission.wait for the ready ticks). On each machine:
## - the screen is up and opaque in the very frame the mission scene is added, and every frame until mission_go, with
##   the HUD hidden; it goes through the build and then the "crew" phase once this machine has reported;
## - it lists both crew members; this machine's own row turns READY once it has reported, and at least one machine sees
##   the OTHER one ready before the start (the host from mission.ready, a client from the host's mission.wait);
## - at mission_go it comes down (at once under tests) and the HUD shows.

const PEERS := 2
const LINKS := ["off"]
const SEED := 5

var td: MissionScene


func run_host() -> void:
	net_timeout = 120.0
	MissionScene.stepped_load = true
	if not check(await until(func() -> bool: return Session.roster.size() == 2, 30.0), "the crew gathers"):
		return
	check(Session.mission.host_launch(SEED), "the host launches")
	var mine := await _load_and_watch()
	if not check(await wait_reports("screen", 1, 60.0), "the client reports its loading screen"):
		return
	var theirs: Dictionary = reported(peers_with("screen")[0], "screen")
	for r: Array in [["host", mine], ["client", theirs]]:
		var who: String = r[0]
		var d: Dictionary = r[1]
		check(bool(d["first_frame"]), "%s: the screen is up in the frame the scene is added" % who)
		eq(int(d["bad"]), 0, "%s: the screen covered every frame until mission_go" % who)
		eq(int(d["hud"]), 0, "%s: the HUD stayed hidden under it" % who)
		check(bool(d["went"]), "%s: the barrier passed" % who)
		eq(int(d["rows"]), 2, "%s: the crew list has both members" % who)
		check(bool(d["self_ready"]), "%s: its own row turned READY after it reported" % who)
		check(bool(d["crew_phase"]), "%s: the screen waited in the crew phase" % who)
		check(bool(d["gone"]), "%s: the screen came down at mission_go" % who)
		check(bool(d["hud_after"]), "%s: the HUD shows after it" % who)
	check(bool(mine["other_ready"]) or bool(theirs["other_ready"]),
		"one machine saw the other one READY before the start (host %s, client %s)" % [mine["other_ready"], theirs["other_ready"]])
	Session.mission.end()
	check(await wait_done(1, 30.0), "the client is done")


func run_client() -> void:
	net_timeout = 120.0
	MissionScene.stepped_load = true
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission.params.is_empty(), 40.0), "the host's launch arrives"):
		return
	report("screen", await _load_and_watch())
	await until(func() -> bool: return Session.mission.phase == NetMission.IDLE or ended, 30.0)


## Load the mission at start_t as the hangar would and watch the loading screen every frame until it is gone.
func _load_and_watch() -> Dictionary:
	await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0)
	td = (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	var ls := td.loading_screen
	var out := {"first_frame": ls != null and ls.covering(), "bad": 0, "hud": 0, "went": false, "rows": 0,
		"self_ready": false, "other_ready": false, "crew_phase": false, "gone": false, "hud_after": false}
	var me := Session.local_id()
	var end := Time.get_ticks_msec() + 90000
	while Time.get_ticks_msec() < end:
		await get_tree().process_frame
		if Session.mission.phase == NetMission.RUNNING:
			out["went"] = true
			break
		if ls == null or not is_instance_valid(ls) or not ls.covering():
			out["bad"] = int(out["bad"]) + 1
			continue
		var hud := td.get_node_or_null("MechHud") as MechHud
		if hud != null and hud.visible:
			out["hud"] = int(out["hud"]) + 1
		ls.refresh_crew()
		out["rows"] = maxi(int(out["rows"]), ls.rows.size())
		if ls.phase == "crew":
			out["crew_phase"] = true
		for e: Dictionary in ls.rows:
			if str(e["status"]) == "ready":
				if int(e["peer"]) == me:
					out["self_ready"] = true
				else:
					out["other_ready"] = true
	await frames(2)
	out["gone"] = td.loading_screen == null and (ls == null or not is_instance_valid(ls))
	var hud2 := td.get_node_or_null("MechHud") as MechHud
	out["hud_after"] = hud2 != null and hud2.visible
	return out
