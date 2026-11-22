class_name FlowLog
extends RefCounted
## One "[Flow]" line per game-flow transition (session joined / refused / ended, hangar, launch, load, barrier, mission
## go, contact, kills, decks cleared, extraction, won, mission end, back in the hangar, relaunch), on every machine, so a
## LAN run can be followed through two logs side by side:
##   [Flow] t=12.345 peer=1 host load done: 812 ms (...)
## t is the shared clock (Session.host_time(); offline, seconds since the process started), peer this machine's peer id (0 offline). Prints only: release
## builds flush stdout on print (project.godot), so `--log-file` shows them live.

## Print one transition. `what` is the transition's name, `detail` optional.
static func say(what: String, detail: String = "") -> void:
	var s := Net.session()
	var t := s.host_time() if s != null and s.online() else Time.get_ticks_msec() / 1000.0   # solo: process seconds
	var peer := s.local_id() if s != null else 0
	var role := "solo"
	if s != null and s.online():
		role = "host" if s.hosting else "client"
	print("[Flow] t=%.3f peer=%d %s %s%s" % [t, peer, role, what, (": " + detail) if detail != "" else ""])
