extends NetTest
const QUIET_SECTION := true   # TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"): no director, no objectives
## The host's crew option "Friendly fire" (docs/networking.md "Crew options") over a real 2-process crew, both running the
## front end:
## - the host turns it off in its hangar (FrontEnd.ff_check, saved in its settings); the client's hangar shows it off,
##   read-only (welcome or sys.crew_opts), and follows the host's changes live (on, then off again);
## - a client can't change it (Session.set_friendly_fire refused on a client);
## - the host launches: mission.launch carries friendly_fire false and both machines' test drives have
##   td.friendly_fire == false (what TestDriveCombat reads). The default launch (true) is covered by net_mission_case.

const PEERS := 2
const SEED := 11

var fe: FrontEnd
var td: TestDrive


func _open_menu() -> void:
	GameSettings.path = "user://test_net_crew_opts_%s.cfg" % role
	GameSettings.save_settings(GameSettings.DEFAULTS.duplicate(true))
	fe = (load(Boot.MENU_SCENE) as PackedScene).instantiate() as FrontEnd
	get_tree().root.add_child(fe)
	await frames(2)


func _close_menu() -> void:
	if is_instance_valid(fe):
		get_tree().root.remove_child(fe)
		fe.free()   # before the launch: its own Launch would change the scene
	fe = null


## The hangar's friendly fire box as {pressed, disabled, text}.
func _ff_view() -> Dictionary:
	if fe == null or fe.ff_check == null or not is_instance_valid(fe.ff_check):
		return {}
	return {"pressed": fe.ff_check.button_pressed, "disabled": fe.ff_check.disabled, "text": fe.ff_check.text}


func _host_toggle(on: bool) -> void:
	fe.ff_check.button_pressed = on   # emits toggled: the hangar's own handler (settings + Session)
	await frames(1)


func run_host() -> void:
	await _open_menu()
	fe.show_screen("hangar")
	await frames(1)
	var v := _ff_view()
	if not check(not v.is_empty(), "the host's hangar has the friendly fire box"):
		return
	check(bool(v["pressed"]) and not bool(v["disabled"]), "on by default, and the host can change it: %s" % str(v))
	await _host_toggle(false)
	check(not Session.friendly_fire, "the host's box sets the crew option")
	check(not bool(GameSettings.load_settings()["friendly_fire"]), "the host's choice is saved")
	if not check(await until(func() -> bool: return Session.roster.size() == 2, 20.0), "the client joins"):
		return
	var client := int(Session.crew()[1]["peer"])
	if not check(await wait_reports("off1", 1), "the client reports its hangar"):
		return
	var cv: Dictionary = reported(client, "off1")
	check(not bool(cv.get("pressed", true)), "the client's hangar shows the host's 'off': %s" % str(cv))
	check(bool(cv.get("disabled", false)), "read-only on the client")
	check(not bool(cv.get("client_set", true)), "a client can't set the crew option")
	await _host_toggle(true)
	command(client, "expect", {"on": true})
	if not check(await wait_reports("on", 1), "the client reports the change to on"):
		return
	check(bool(reported(client, "on")), "the client's hangar follows the host to 'on'")
	await _host_toggle(false)
	command(client, "expect", {"on": false})
	if not check(await wait_reports("off2", 1), "the client reports the change back to off"):
		return
	check(bool(reported(client, "off2")), "the client's hangar follows the host back to 'off'")
	command(client, "close", {})
	if not check(await wait_reports("closed", 1), "the client closes its menu"):
		return
	_close_menu()
	check(Session.start_mission(SEED), "the host launches")
	eq(Session.mission_params().get("friendly_fire", null), false, "the launch carries friendly_fire false")
	await _load()
	if not check(await wait_reports("td", 1, 40.0), "the client loads the mission"):
		return
	eq(td.friendly_fire, false, "the host's test drive has friendly fire off")
	var t: Dictionary = reported(client, "td")
	eq(t.get("params_ff", null), false, "the client's launch params carry friendly_fire false")
	eq(t.get("td_ff", null), false, "the client's test drive has friendly fire off")
	check(await wait_done(1, 20.0), "the client is done")


func run_client() -> void:
	await _open_menu()
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return fe.screen == "hangar" and not _ff_view().is_empty() \
			and not bool(_ff_view()["pressed"]), 10.0), "the client's hangar shows the host's 'off' (%s)" % str(_ff_view())):
		return
	var v := _ff_view()
	v["client_set"] = Session.set_friendly_fire(true)
	v["after"] = Session.friendly_fire
	report("off1", v)
	var keys := ["on", "off2"]
	for k: String in keys:
		var cmd := await wait_command(20.0)
		var want := bool(cmd.get("on", false))
		report(k, await until(func() -> bool: return not _ff_view().is_empty() and bool(_ff_view()["pressed"]) == want \
			and Session.friendly_fire == want, 10.0))
	var c := await wait_command(20.0)
	if str(c.get("cmd", "")) == "close":
		_close_menu()
		report("closed", true)
	if not check(await until(func() -> bool: return not Session.mission_params().is_empty(), 40.0), "the host's launch arrives"):
		return
	await _load()
	report("td", {"params_ff": Session.mission_params().get("friendly_fire", null), "td_ff": td.friendly_fire})


func _load() -> void:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	td = (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	add_child(td)
	await frames(2)
	check(td.crewed, "the test drive runs the crew mission")
