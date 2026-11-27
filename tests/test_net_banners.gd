extends NetTest
const QUIET_SECTION := true   # TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"): no director, no objectives
## Invader banners across machines (docs/design/banners.md) over a real crew mission of 2, once per link (off, coast).
## Both machines set up OccupationBanners on their own MissionScene's stack and CombatWorld (MissionScene.banners, the
## Engine wiring): the same checksum. The client shoots one banner with autocannon records; each hit is decided on the
## client and reaches the host through CombatNet "combat.hit"; the host tears it and sends one "banner.torn"; both see
## it torn, the client never decided a tear itself. A banner field built late on the client (standing in for a member
## who set up after the tear) is brought up to date by the host's "banner.sync" (the peer_joined hook).

const PEERS := 2
const SEED := 11

var td: MissionScene
var world: CombatWorld
var field: OccupationBanners
var deck := 0


func run_host() -> void:
	net_timeout = 120.0
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 30.0), "the crew gathers"):
		return
	check(Session.mission.host_launch(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	for e in td.combat.squad.enemies:
		e.ai_mode = "idle"
	if not check(await wait_reports("ready", peers - 1, 40.0), "the client is ready"):
		return
	var b := _other_peer()
	var mine: Dictionary = reported(b, "ready")
	eq(str(mine["sum"]), field.checksum(), "both machines place the same banners")
	eq(int(mine["count"]), field.banner_count(), "the same count (%d)" % field.banner_count())
	var events := [0]
	Session.event_received.connect(func(_f: int, kind: String, _d: Dictionary, _s: float) -> void:
		if kind == OccupationBanners.TORN:
			events[0] += 1)
	command(b, "shoot", {"deck": deck, "id": 0})
	check(await until(func() -> bool: return field.is_torn(deck, 0), 15.0), "the client's fire tears the banner on the host")
	eq(field.torn_count(), 1, "one torn on the host")
	near(field.target(deck, 0).total_hp(), 0.0, 1e-3, "the host applied the hits (HP 0)")
	command(b, "report", {"key": "after"})
	if check(await wait_reports("after", 1, 15.0), "the client reports"):
		var v: Dictionary = reported(b, "after")
		check(bool(v["torn"]), "the client sees it torn")
		eq(int(v["count"]), 1, "one torn on the client")
		check(int(v["hits_sent"]) >= 3, "the client sent its hits to the host (%d)" % int(v["hits_sent"]))
		near(float(v["hp"]), BannerTarget.MAX_HP, 1e-3, "the client never wrote the banner's HP")
		eq(events[0], 0, "the host hears no banner event back")
	# A field set up late on the client: the host's sync brings it up to date.
	command(b, "late", {})
	if check(await wait_reports("late_built", 1, 20.0), "the client built a late field"):
		field._on_peer_joined(b)
		if check(await wait_reports("late", 1, 15.0), "the late field reports"):
			check(bool(reported(b, "late")), "the late field sees the banner torn (banner.sync)")
	command(b, "finish", {})
	check(await wait_done(peers - 1, 20.0), "the client is done")


func run_client() -> void:
	net_timeout = 120.0
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission.params.is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	var tears := [0]
	field.banner_torn.connect(func(_k: int, _i: int) -> void: tears[0] += 1)
	report("ready", {"sum": field.checksum(), "count": field.banner_count()})
	var late: OccupationBanners = null
	while true:
		var c := await wait_command(60.0)
		if not check(not c.is_empty(), "the host's next command arrives"):
			return
		match str(c["cmd"]):
			"finish":
				return
			"shoot":
				var t := field.target(int(c["deck"]), int(c["id"]))
				var centre := t.world_spheres()[0]["center"] as Vector3
				var out := t.global_basis.z.normalized()
				var me := Session.local_id()
				for i in 5:
					if field.is_torn(int(c["deck"]), int(c["id"])):
						break
					world.fire(Combat.fire_record("player%d" % me, me, "side_r", "autocannon", centre + out * 8.0, centre,
						world.now, 9100 + i, 0.0))
					await sleep(0.6)
			"report":
				report(str(c["key"]), {"torn": field.is_torn(deck, 0), "count": field.torn_count(),
					"hits_sent": int(td.combat.net.stats["hits_sent"]), "hp": field.target(deck, 0).total_hp(),
					"tears": tears[0]})
			"late":
				late = OccupationBanners.new()
				add_child(late)
				late.setup(td.stack, null, SEED)
				report("late_built", true)
				check(await until(func() -> bool: return late.is_torn(deck, 0), 10.0), "the sync reaches the late field")
				report("late", late.is_torn(deck, 0))


func _load_and_go() -> bool:
	check(await until(func() -> bool: return Session.mission.seconds_to_load() <= 0.0, 10.0), "start_t comes on the shared clock")
	td = (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	add_child(td)
	if not check(await until(func() -> bool: return td.loaded, 60.0), "the drive loads"):
		return false
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	world = td.combat.world
	deck = int(td.stack.section.entry["deck"])
	field = td.banners   # Engine wires them into MissionScene now
	if field == null:
		field = OccupationBanners.new()
		add_child(field)
		field.setup(td.stack, world)
	if not check(field.banner_count(deck) > 0, "banners on the entry deck"):
		return false
	if not check(await until(func() -> bool: return Session.mission.phase == NetMission.RUNNING and not td.held, 40.0),
			"the load barrier passes"):
		return false
	return true


func _other_peer() -> int:
	for e: Dictionary in Session.crew():
		if int(e["peer"]) != Session.local_id():
			return int(e["peer"])
	return -1
