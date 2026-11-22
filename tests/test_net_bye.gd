extends NetTest
## Two processes, once per link (off, coast): a host that ends the session normally says why, and the client shows THAT
## reason, not a lost-host one (a LAN test showed "The host left", the timeout text, after a normal auto-quit):
## - the client joins and says done;
## - the host leaves the way an auto-quit run does (Session.leave("", HOST_ENDED)), without quitting its process;
## - the client's session ends with HOST_ENDED, not HOST_SILENT / HOST_LOST_LOADING / HOST_LEFT, and last_reason (what
##   the menu shows) carries it;
## - the host's transport, kept open after the bye, closes as soon as the client has closed its end (well before
##   BYE_LINGER), so the next crew can open at once.

const PEERS := 2


func run_host() -> void:
	if not check(await until(func() -> bool: return Session.roster.size() == 2, 20.0), "the client joins"):
		return
	if not check(await wait_done(1), "the client is done"):
		return
	var t0 := Time.get_ticks_usec()
	Session.leave("", NetSession.HOST_ENDED)
	eq(Session.last_reason, NetSession.CREW_CLOSED, "the host's own reason is its own")
	check(multiplayer.multiplayer_peer != null and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer),
		"the transport stays open after the bye")
	check(await until(func() -> bool: return multiplayer.multiplayer_peer == null or multiplayer.multiplayer_peer is OfflineMultiplayerPeer, 5.0),
		"the transport closes after the bye")
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	print("[NetTest] transport closed %.0f ms after the bye" % ms)
	check(ms < NetSession.BYE_LINGER * 1000.0 - 100.0, "it closed because the client closed its end (%.0f ms)" % ms)


func run_client() -> void:
	var why := await connect_client()
	check(why == "", "welcomed (%s)" % why)


func after_end() -> void:
	check(ended_reason != NetSession.HOST_SILENT and ended_reason != NetSession.HOST_LOST_LOADING
		and ended_reason != NetSession.HOST_LEFT, "not a lost-host reason (%s)" % ended_reason)
	eq(Session.last_reason, NetSession.HOST_ENDED, "the menu shows the host's reason")
