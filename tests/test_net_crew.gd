extends NetTest
## A full crew of four (cast's M0 crew test, crew size 3 -> 4): five processes start together; the first three clients
## are admitted (seats 2-4, each with its own head), the fourth is refused with "Crew is full"; every admitted client lists
## the same roster.

const PEERS := 5
const LINKS := ["off"]


func run_host() -> void:
	var full := await until(func() -> bool: return Session.roster.size() == 4 and Session.refusals.size() == 1, 25.0)
	if not check(full, "4 in the crew and one refused (crew %d, refusals %d)" % [Session.roster.size(), Session.refusals.size()]):
		return
	eq(str(Session.refusals[0]["reason"]), NetSession.CREW_FULL, "the 5th player is refused with \"Crew is full\"")
	var seats: Array = Session.crew().map(func(e: Dictionary) -> int: return int(e["seat"]))
	eq(seats, [1, 2, 3, 4], "seats 1-4 are taken")
	var heads := {}
	for e: Dictionary in Session.crew():
		heads[str(e["head"])] = true
	check(heads.size() >= 3, "the crew wears different heads (%s)" % str(heads.keys()))
	if not check(await wait_reports("roster", 3), "the three admitted clients report their roster"):
		return
	for p in peers_with("roster"):
		eq(str(reported(p, "roster")), roster_signature(), "peer %d lists the same crew as the host" % p)
	check(await wait_done(3), "the clients are done")


func run_client() -> void:
	var why := await connect_client()
	if why != "":
		eq(why, NetSession.CREW_FULL, "the refused client is told the crew is full")
		check(not Session.online() and Session.roster.is_empty(), "a refused client is not in a session")
		return
	check(await until(func() -> bool: return Session.roster.size() == 4, 20.0), "the roster fills to 4 (%d)" % Session.roster.size())
	report("roster", roster_signature())
