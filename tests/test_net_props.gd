extends NetTest
## Street props over a real 2-process crew (docs/design/city-props.md section 6). The host knocks a lamp over before
## anyone joins; the joining client gets it lying in the same place from the host's snapshot (prop.sync). Then the client
## asks for another lamp to topple (prop.req): the host decides, both machines play the fall (prop.ev) and end with the
## same snapshot. Then the same for a roof unit (docs/design/city-rooftops.md): its pose is in its roof's frame on the
## same wire, and it lies on its roof on both machines.

const PEERS := 2

var props: CityProps


func _build() -> void:
	var plan := CityPlan.make({"seed": 3, "size_x": 100.0, "size_s": 110.0})
	props = CityProps.new()
	props.setup(plan, RingFrame.new(plan.p("radius")))
	add_child(props)
	await frames(1)


func _lamps() -> Array[int]:
	var out: Array[int] = []
	for it: Dictionary in props.items:
		if it["type"] == "lamp":
			out.append(int(it["id"]))
	return out


func _roof_unit() -> int:
	for it: Dictionary in props.items:
		if CityPropSim.is_roof(it):
			return int(it["id"])
	return -1


func _settled(id: int) -> bool:
	return props.state_of(id) == CityProps.DOWN


func run_host() -> void:
	await _build()
	var lamps := _lamps()
	var early := lamps[0]
	var asked := lamps[1]
	props.request(early, CityProps.TOPPLE, Vector2(1, 0))
	check(props.state_of(early) == CityProps.FALLING, "the host decides its own topple at once")
	check(await until(func() -> bool: return _settled(early), 5.0), "the host's lamp comes down")
	if not check(await until(func() -> bool: return Session.roster.size() == 2, 20.0), "the client joins"):
		return
	var client := int(Session.crew()[1]["peer"])
	if not check(await wait_reports("synced", 1), "the client reports the joining snapshot"):
		return
	eq(str(reported(client, "synced")), props.snapshot().hex_encode(), "the joiner restored the host's snapshot")
	command(client, "topple", {"id": asked})
	check(await until(func() -> bool: return props.state_of(asked) != CityProps.STANDING, 10.0), "the client's request topples the lamp on the host")
	check(await until(func() -> bool: return _settled(asked), 5.0), "and it comes down")
	if not check(await wait_reports("toppled", 1), "the client reports its snapshot after the fall"):
		return
	eq(str(reported(client, "toppled")), props.snapshot().hex_encode(), "both machines end with the same props")
	var pose := props.pose_of(asked)
	near(pose["lie"], 0.0, 1e-4, "the lamp fell the way the client pushed it (+s)")
	var roof := _roof_unit()
	if check(roof >= 0, "the district has a roof unit"):
		command(client, "topple", {"id": roof})
		check(await until(func() -> bool: return _settled(roof), 10.0), "the client's request topples the roof unit on the host")
		if check(await wait_reports("toppled_roof", 1), "the client reports its snapshot after the roof unit fell"):
			eq(str(reported(client, "toppled_roof")), props.snapshot().hex_encode(), "both machines end with the same props, roof unit included")
			var it: Dictionary = props.items[roof]
			near(float(props.pose_of(roof)["h"]), float(it["h"]), 1e-4, "the roof unit stays on its roof")
			near(float(props.pose_of(roof)["s"]), float(it["lz"]) + CityPropSim.BASE_SLIP, 1e-3, "it fell along the client's push in its roof's frame")
	check(await wait_done(1), "the client is done")


func run_client() -> void:
	await _build()
	var lamps := _lamps()
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	check(await until(func() -> bool: return _settled(lamps[0]), 10.0), "the host's fallen lamp lies here too after joining")
	report("synced", props.snapshot().hex_encode())
	var cmd := await wait_command(20.0)
	if str(cmd.get("cmd", "")) != "topple":
		check(false, "the host asks for a topple (%s)" % str(cmd))
		return
	var id := int(cmd["id"])
	props.request(id, CityProps.TOPPLE, Vector2(0, 1))
	check(props.state_of(id) == CityProps.STANDING, "a client does not decide on its own")
	check(await until(func() -> bool: return _settled(id), 10.0), "the lamp falls here when the host's event arrives")
	report("toppled", props.snapshot().hex_encode())
	var cmd2 := await wait_command(20.0)
	if str(cmd2.get("cmd", "")) != "topple":
		check(false, "the host asks for a roof topple (%s)" % str(cmd2))
		return
	var roof := int(cmd2["id"])
	props.request(roof, CityProps.TOPPLE, Vector2(0, 1))
	check(await until(func() -> bool: return _settled(roof), 10.0), "the roof unit falls here when the host's event arrives")
	report("toppled_roof", props.snapshot().hex_encode())
