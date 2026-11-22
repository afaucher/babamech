extends NetTest
## Two processes over ENet (cast's harness), once per link (off, coast): the join handshake carries each pilot's
## name, head and chassis, so both machines list the same crew:
## - the client joins; the host's roster has it as seat 2 with its name "c1", head "pickle" and chassis;
## - the client lists the same roster (it sees the host's "chicken");
## - the client changes its head to "dog" (sys.profile): the host's roster and the client's both show it;
## - the host's process exits: the client's session ends with HOST_LEFT.

const PEERS := 2


func run_host() -> void:
	if not check(await until(func() -> bool: return Session.roster.size() == 2, 20.0), "the client joins (crew %d)" % Session.roster.size()):
		return
	var crew := Session.crew()
	eq(str(crew[0]["name"]), "host", "seat 1 is the host")
	eq(str(crew[0]["head"]), "chicken", "the host plays the chicken head")
	eq(int(crew[1]["seat"]), 2, "the client takes seat 2")
	eq(str(crew[1]["name"]), "c1", "the hello carried the client's name")
	eq(str(crew[1]["head"]), "pickle", "the hello carried the client's head")
	eq(str(crew[1]["chassis"]), NetSession.DEFAULT_CHASSIS, "the hello carried the client's chassis")
	if not check(await wait_reports("roster", 1), "the client reports its roster"):
		return
	var client := int(crew[1]["peer"])
	eq(str(reported(client, "roster")), roster_signature(), "the client lists the same crew as the host")
	print("[NetTest] crew: ", roster_signature())

	command(client, "head", {"head": "dog"})
	check(await until(func() -> bool: return str((Session.roster.get(client, {}) as Dictionary).get("head", "")) == "dog", 10.0),
		"the client's new head reaches the host")
	check(await wait_reports("roster2", 1), "the client reports again")
	eq(str(reported(client, "roster2")), roster_signature(), "both list the changed head")
	check(await wait_done(1), "the client is done")


func run_client() -> void:
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	check(await until(func() -> bool: return Session.roster.size() == 2, 10.0), "the roster lists 2")
	eq(Session.host_name(), "host", "the client knows the host's name")
	eq(str((Session.crew()[0] as Dictionary)["head"]), "chicken", "the client sees the host's head")
	report("roster", roster_signature())
	var cmd := await wait_command(20.0)
	if not check(str(cmd.get("cmd", "")) == "head", "the host asks for a head change (%s)" % str(cmd)):
		return
	Session.set_profile(Session.player_name, str(cmd["head"]), Session.local_chassis())
	check(await until(func() -> bool: return str(Session.local_entry().get("head", "")) == "dog", 10.0),
		"the host's roster comes back with the new head")
	report("roster2", roster_signature())
