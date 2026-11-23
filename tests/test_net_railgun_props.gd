extends NetTest
## The railgun slug knocks a row of street props over a real 2-process crew (docs/design/weapons.md §3.8): both machines
## build the same CityProps district and a CombatWorld. The host first runs its copy of the CLIENT's fire record (it
## doesn't decide that shot): nothing topples. Then the client fires the same record: its slug asks the host to topple
## every prop on the path (prop.req, one per prop), the host decides and broadcasts (prop.ev), and both machines end with
## the whole row down and the same snapshot.

const PEERS := 2
const Row := preload("res://tests/test_railgun_props.gd")

var props: CityProps
var world: CombatWorld


func _build() -> void:
	var plan := CityPlan.make({"seed": 3})
	props = CityProps.new()
	props.setup(plan, RingFrame.new(plan.p("radius")))
	add_child(props)
	world = CombatWorld.new()
	world.mission_seed = 5
	world.use_physics = false
	add_child(world)
	await frames(1)


func _record(peer: int) -> Dictionary:
	var ids := Row.row(props)
	var ln := Row.line(props, ids)
	return Combat.fire_record("pilot", peer, "shoulder_l", "railgun", ln[0], ln[1], world.now, 0)


func _fire(rec: Dictionary) -> void:
	world.fire(rec)
	for i in 90:
		world.advance(1.0 / 60.0)


func _all(ids: Array[int], state: int) -> bool:
	for id in ids:
		if props.state_of(id) != state:
			return false
	return true


func run_host() -> void:
	await _build()
	var ids := Row.row(props)
	if not check(ids.size() == Row.ROW, "the district has a row (%s)" % [ids]):
		return
	if not check(await until(func() -> bool: return Session.roster.size() == 2, 20.0), "the client joins"):
		return
	var client := int(Session.crew()[1]["peer"])
	_fire(_record(client))
	check(_all(ids, CityProps.STANDING), "the host's copy of the client's shot knocks nothing (the client decides it)")
	command(client, "fire", {})
	check(await until(func() -> bool: return _all(ids, CityProps.DOWN), 10.0),
		"the client's slug topples the whole row here (%s)" % [ids.map(func(id: int) -> int: return props.state_of(id))])
	if not check(await wait_reports("down", 1), "the client reports its snapshot"):
		return
	eq(str(reported(client, "down")), props.snapshot().hex_encode(), "both machines end with the same props")
	check(await wait_done(1), "the client is done")


func run_client() -> void:
	await _build()
	var ids := Row.row(props)
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	var cmd := await wait_command(20.0)
	if str(cmd.get("cmd", "")) != "fire":
		check(false, "the host asks for the shot (%s)" % str(cmd))
		return
	_fire(_record(Session.local_id()))
	check(_all(ids, CityProps.STANDING), "a client does not topple on its own (it asks the host)")
	check(await until(func() -> bool: return _all(ids, CityProps.DOWN), 10.0), "the row falls here when the host's events arrive")
	report("down", props.snapshot().hex_encode())
