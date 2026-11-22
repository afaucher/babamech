extends NetTest
## Street props of a multi-deck stack over a real 2-process crew (CityProps.deck, docs/design/city-ramps-and-stack.md
## section 8). Prop ids repeat on every deck and every deck's CityProps hears every prop event, so each event carries its
## deck. The host knocks over a lamp on deck 0 and another on deck 1 before anyone joins: the joiner gets each deck's
## snapshot into that deck only. Then the client asks for a lamp on deck 1 to topple: on BOTH machines deck 1's lamp goes
## down and deck 0's prop with the same id stays standing, and every deck ends with the same snapshot on both.

const PEERS := 2
const SEED := 4

var stack: CityStack


func _build() -> void:
	stack = CityStack.new()
	add_child(stack)
	stack.build(SectionPlan.make({"seed": SEED}))
	await frames(1)


func _p(k: int) -> CityProps:
	return stack.decks[k].props


func _lamps(k: int) -> Array[int]:
	var out: Array[int] = []
	var n := mini(_p(0).items.size(), _p(1).items.size())
	for it: Dictionary in _p(k).items:
		if it["type"] == "lamp" and int(it["id"]) < n:
			out.append(int(it["id"]))
	return out


## [deck 0 early lamp, deck 1 early lamp, deck 1 lamp the client asks for]: three different ids, valid on both decks.
func _ids() -> Array[int]:
	var a := _lamps(0)[0]
	var b := -1
	var c := -1
	for id in _lamps(1):
		if id == a:
			continue
		if b < 0:
			b = id
		elif c < 0:
			c = id
	return [a, b, c]


func _down(k: int, id: int) -> bool:
	return _p(k).state_of(id) == CityProps.DOWN


func _snaps() -> String:
	return "%s|%s|%s" % [_p(0).snapshot().hex_encode(), _p(1).snapshot().hex_encode(), _p(2).snapshot().hex_encode()]


func run_host() -> void:
	await _build()
	var ids := _ids()
	if not check(ids[1] >= 0 and ids[2] >= 0, "three lamp ids (%s)" % str(ids)):
		return
	_p(0).request(ids[0], CityProps.TOPPLE, Vector2(1, 0))
	_p(1).request(ids[1], CityProps.TOPPLE, Vector2(1, 0))
	check(await until(func() -> bool: return _down(0, ids[0]) and _down(1, ids[1]), 5.0), "the host's two lamps come down")
	check(_p(1).state_of(ids[0]) == CityProps.STANDING and _p(0).state_of(ids[1]) == CityProps.STANDING,
			"each topple stays on its own deck on the host")
	if not check(await until(func() -> bool: return Session.roster.size() == 2, 20.0), "the client joins"):
		return
	var client := int(Session.crew()[1]["peer"])
	if not check(await wait_reports("synced", 1), "the client reports its snapshots after joining"):
		return
	eq(str(reported(client, "synced")), _snaps(), "the joiner restored every deck's snapshot into that deck")
	command(client, "topple", {"id": ids[2]})
	check(await until(func() -> bool: return _down(1, ids[2]), 10.0), "the client's request topples deck 1's lamp on the host")
	eq(_p(0).state_of(ids[2]), CityProps.STANDING, "and deck 0's prop with the same id stays standing on the host")
	eq(_p(2).state_of(ids[2]), CityProps.STANDING, "and deck 2's")
	if not check(await wait_reports("toppled", 1), "the client reports its snapshots after the fall"):
		return
	eq(str(reported(client, "toppled")), _snaps(), "both machines end with the same props on every deck")
	check(await wait_done(1), "the client is done")


func run_client() -> void:
	await _build()
	var ids := _ids()
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	check(await until(func() -> bool: return _down(0, ids[0]) and _down(1, ids[1]), 10.0), "both of the host's lamps lie here after joining")
	check(_p(1).state_of(ids[0]) == CityProps.STANDING and _p(0).state_of(ids[1]) == CityProps.STANDING,
			"each deck's snapshot went into its own deck only")
	report("synced", _snaps())
	var cmd := await wait_command(20.0)
	if str(cmd.get("cmd", "")) != "topple":
		check(false, "the host asks for a topple (%s)" % str(cmd))
		return
	var id := int(cmd["id"])
	_p(1).request(id, CityProps.TOPPLE, Vector2(0, 1))
	check(_p(1).state_of(id) == CityProps.STANDING, "a client does not decide on its own")
	check(await until(func() -> bool: return _down(1, id), 10.0), "deck 1's lamp falls here when the host's event arrives")
	eq(_p(0).state_of(id), CityProps.STANDING, "and deck 0's prop with the same id stays standing here")
	report("toppled", _snaps())
