extends TestCase
## Steam lobby edge cases against a fake Steam object (SteamIdentity.use_for_tests), headless, no Steam client:
## 1. Join's pick (NetSession.pick_lobby): skips other builds, full crews and crews on a mission (lobby data
##    state = "mission"); with only busy crews the reason is ON_MISSION, with none NO_CREWS.
## 2. Ghost lobby (SteamLobby): a createLobby answered after leave() (the session's open timeout gave up) is left at
##    once, keeps lobby_id 0 and emits no `created`; the next create() works. A joinLobby answered after leave() is
##    left too. A normal create still opens the lobby.


class FakeSteam extends Object:
	signal lobby_created(result: int, id: int)
	signal lobby_joined(lobby: int, permissions: int, locked: bool, response: int)
	signal lobby_match_list(lobbies: Array)
	signal join_requested(lobby: int, friend: int)
	var created_calls := 0
	var joins: Array = []
	var left: Array = []
	var data := {}

	func run_callbacks() -> void:
		pass

	func getPersonaName() -> String:
		return "Fake"

	func getSteamID() -> int:
		return 1234

	func createLobby(_type: int, _max: int) -> void:
		created_calls += 1

	func joinLobby(id: int) -> void:
		joins.append(id)

	func leaveLobby(id: int) -> void:
		left.append(id)

	func setLobbyData(id: int, key: String, value: String) -> void:
		data["%d/%s" % [id, key]] = value

	func getLobbyData(id: int, key: String) -> String:
		return str(data.get("%d/%s" % [id, key], ""))

	func getLobbyOwner(_id: int) -> int:
		return 1234

	func getFriendPersonaName(_id: int) -> String:
		return ""


func setup() -> void:
	_pick()
	await _ghost()
	finish()


func _pick() -> void:
	var v := "build-1"
	var rows := {
		1: {"version": "other", "seats_free": "3", "state": "lobby"},
		2: {"version": v, "seats_free": "0", "state": "lobby"},
		3: {"version": v, "seats_free": "2", "state": "mission"},
		4: {"version": v, "seats_free": "1", "state": "lobby"},
	}
	var data := func(lid: int, key: String) -> String: return str((rows.get(lid, {}) as Dictionary).get(key, ""))
	var p := NetSession.pick_lobby([1, 2, 3, 4], data, v)
	eq(int(p["id"]), 4, "Join picks the open crew in the hangar, not the one on a mission")
	p = NetSession.pick_lobby([1, 2, 3], data, v)
	eq(int(p["id"]), 0, "only a crew on a mission: nothing to join")
	eq(str(p["reason"]), NetSession.ON_MISSION, "only a crew on a mission: says so")
	p = NetSession.pick_lobby([1, 2], data, v)
	eq(str(p["reason"]), NetSession.NO_CREWS, "no open crew of this build: NO_CREWS")
	p = NetSession.pick_lobby([], data, v)
	eq(str(p["reason"]), NetSession.NO_CREWS, "an empty list: NO_CREWS")
	rows[5] = {"version": v, "seats_free": "1", "state": ""}
	eq(int(NetSession.pick_lobby([3, 5], data, v)["id"]), 5, "a lobby with no state yet counts as in the hangar")


func _ghost() -> void:
	var fake := FakeSteam.new()
	SteamIdentity.use_for_tests(fake)
	var lob: SteamLobby = Session.lobby
	await frames(2)   # SteamLobby wires itself to the fake in _process
	var created: Array = []
	var on_created := func(id: int) -> void: created.append(id)
	lob.created.connect(on_created)
	# A late creation after leave().
	check(lob.create(4), "create() asks Steam")
	eq(fake.created_calls, 1, "createLobby called once")
	lob.leave()
	fake.lobby_created.emit(1, 99)
	check(fake.left.has(99), "a lobby created after leave() is left at once (no ghost)")
	eq(lob.lobby_id, 0, "and it never becomes our lobby")
	eq(created.size(), 0, "and `created` is not emitted")
	# The next create works (it used to fail: "already in a lobby").
	check(lob.create(4), "the next create() is allowed")
	fake.lobby_created.emit(1, 77)
	eq(lob.lobby_id, 77, "a normal creation opens the lobby")
	eq(created, [77], "`created` fires for it")
	check(not fake.left.has(77), "a normal creation is kept")
	eq(fake.getLobbyData(77, "game"), SteamLobby.LOBBY_GAME_KEY, "lobby data written")
	lob.leave()
	check(fake.left.has(77), "leave() leaves it")
	# A late join after leave().
	check(lob.join(55), "join() asks Steam")
	lob.leave()
	fake.lobby_joined.emit(55, 0, false, SteamLobby.ENTER_SUCCESS)
	check(fake.left.has(55), "a lobby entered after leave() is left at once")
	eq(lob.lobby_id, 0, "and it never becomes our lobby")
	lob.created.disconnect(on_created)
	SteamIdentity.reset_for_tests()
	await frames(1)
	fake.free()
