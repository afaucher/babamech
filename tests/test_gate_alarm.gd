extends TestCase
## The gate alarm (docs/design/city-ramps-and-stack.md "Staging bay", timing): the siren is the door-opening signal. A wave
## gate sounds its own siren, flashes its recessed lamps and turns its beacons from alarm_from (open_at - ALARM_LEAD, at
## most; ALARM_LEAD is 0 now: open_at, the leaves starting to move) until the leaves are fully open (open_at + OPENING).
## A scheduled effect on the shared clock (MissionWorld.alarm_on), so snapshot / restore and late calls give the same
## state. Checks every case against _want() (written for any ALARM_LEAD, so a lead can be re-pinned by changing the
## constant): silent while warning, on through the opening, off once open / closing / shut, a follow-up order, an order
## arriving mid-opening, restore mid-opening, an old 3-long snapshot and an old 4-long one with a 10 s lead (clamped), the
## siren silent on a deck that is not the active one (lamps still lit), lifts without an alarm, sealing cuts it; the 3D
## player at the gate (loop stream, finite max distance, world bus or Master).

var mw: MissionWorld
var stack: CityStack
var gate: Variant
var lift: Variant
var door: MissionProps.GateDoor
var _oa := 0.0          ## the schedule _want() checks against
var _order := 0.0


func setup() -> void:
	timeout_sec = 120.0
	stack = CityStack.new()
	add_child(stack)
	stack.build(SectionPlan.make({"seed": 1}))
	mw = stack.setup_mission(MissionLab.make_plan(stack))
	var ids := mw._doors.keys()
	ids.sort()
	for id: Variant in ids:
		if gate == null and mw._doors[id] is MissionProps.GateDoor:
			gate = id
		if lift == null and mw._doors[id] is MissionProps.LiftDoor:
			lift = id
	if not check(gate != null, "a gate source found its door"):
		finish()
		return
	door = mw._doors[gate] as MissionProps.GateDoor
	stack.set_active_deck(int(mw._sources[gate]["deck"]))
	eq(MissionWorld.ALARM_LEAD, 0.0, "the siren leads the leaves by ALARM_LEAD = 0 s (lead still being settled)")
	eq(MissionWorld.OPENING, 3.0, "the leaves open over 3 s")
	_sound_setup()
	_from_order()
	_lead_cases()
	_follow_up()
	_restore()
	_other_deck()
	_lift()
	_sealed()
	print("[alarm] siren playing reported by this audio driver: %s (tests use GateDoor.siren_on)" % str(_driver_playing))
	finish()


var _driver_playing := "untested"


## The rule, for the schedule (_oa, _order): on from clamp(order, oa - ALARM_LEAD, oa) until oa + OPENING.
func _want(t: float) -> bool:
	var from := clampf(_order, _oa - MissionWorld.ALARM_LEAD, _oa)
	return t >= from and t < _oa + MissionWorld.OPENING


func _order_now(oa: float, hold: float, at: float) -> void:
	_oa = oa
	_order = at
	mw.open_source(gate, oa, hold, at)


## Is the alarm on at t as the rule says, and do the door's lamps, beacons and siren agree?
func _at(t: float, what: String, want: Variant = null) -> void:
	mw.advance_to(t)
	var w: bool = _want(t) if want == null else bool(want)
	eq(mw.alarm(gate), w, "%s (t %.2f): alarm %s" % [what, t, "on" if w else "off"])
	eq(bool(mw.source_state(gate)["alarm"]), w, "%s: source_state alarm" % what)
	eq(door.siren_on, w, "%s: siren told to %s" % [what, "play" if w else "stop"])
	eq(door.lamps_lit(), w, "%s: beacons %s" % [what, "turning" if w else "dark"])
	var lit := 0
	for m in door.wigwag:
		lit += 1 if m.visible else 0
	eq(lit, 1 if w else 0, "%s: %s" % [what, "one lamp group lit at a time" if w else "lamps dark"])
	if w:
		check(str(mw.source_state(gate)["state"]) == "opening" or MissionWorld.ALARM_LEAD > 0.0, "%s: the alarm runs while the leaves open" % what)
		_driver_playing = str(door.siren.playing)


func _sound_setup() -> void:
	var gates := 0
	for id: Variant in mw._doors:
		var n: Node = mw._doors[id]
		if n is MissionProps.GateDoor:
			gates += 1
			check((n as MissionProps.GateDoor).siren != null and (n as MissionProps.GateDoor).siren.get_parent() == n, "%s: a siren on the gate" % str(id))
		else:
			eq(n.find_children("*", "AudioStreamPlayer3D", true, false).size(), 0, "%s: a lift has no siren" % str(id))
	check(gates > 0, "gates found")
	var s := door.siren
	var wav := s.stream as AudioStreamWAV
	if check(wav != null, "the siren has a WAV stream"):
		eq(wav.loop_mode, AudioStreamWAV.LOOP_FORWARD, "the siren loops")
		check(wav.get_length() > 0.5, "a loop of %.2f s" % wav.get_length())
		var an := AudioSynth.analyze(wav)
		check(not bool(an["has_nan"]) and float(an["peak"]) > 0.3, "the klaxon is loud and clean (peak %.2f)" % float(an["peak"]))
		check(float(an["seam_delta"]) < 0.08, "loops without a click (seam %.3f)" % float(an["seam_delta"]))
		check(MissionSound.klaxon() == wav, "one shared klaxon")
	check(s.max_distance > 50.0 and s.max_distance < 1000.0, "finite max distance (%.0f m)" % s.max_distance)
	check(s.unit_size > 0.0, "unit size %.0f m" % s.unit_size)
	check(s.bus == "SFX_World" or s.bus == "Master", "on the world SFX bus or Master (%s)" % s.bus)
	var mid := door.world_point()
	check(s.global_position.distance_to(mid) < door.gh, "the siren is at the gate (%.1f m off its middle)" % s.global_position.distance_to(mid))
	check(not door.siren_on and not s.playing, "silent before any order")


func _from_order() -> void:
	var base := 100.0
	mw.advance_to(base)
	_at(base, "no order", false)
	_order_now(base + 10.0, 12.0, base)
	near(float(mw.source_state(gate)["alarm_from"]), base + 10.0 - MissionWorld.ALARM_LEAD, 1e-6, "alarm_from = open_at - ALARM_LEAD")
	_at(base + 0.01, "right after the order (leaves shut)")
	_at(base + 6.0, "warning")
	eq(str(mw.source_state(gate)["state"]), "warn", "the warn state still exists (signal), silent")
	_at(base + 9.9, "just before open_at")
	_at(base + 10.01, "the leaves start to move")
	eq(str(mw.source_state(gate)["state"]), "opening", "opening at open_at")
	_at(base + 12.9, "late in the opening")
	_at(base + 13.01, "fully open")
	eq(str(mw.source_state(gate)["state"]), "open", "the door is open")
	_at(base + 26.0, "closing")
	_at(base + 30.0, "shut again")


func _lead_cases() -> void:
	var base := 200.0
	mw.advance_to(base)
	_order_now(base + 20.0, 2.0, base)                      # a long lead
	_at(base + 1.0, "20 s lead: not yet")
	_at(base + 20.0 - MissionWorld.ALARM_LEAD + 0.01, "20 s lead: from open_at - ALARM_LEAD")
	_at(base + 23.01, "20 s lead: open")
	base = 300.0
	mw.advance_to(base)
	_order_now(base - 1.0, 5.0, base)                       # arrives 1 s into the opening
	_at(base + 0.01, "order mid-opening: on for the rest of the opening")
	_at(base + 2.01, "order mid-opening: open")
	base = 400.0
	mw.advance_to(base)
	_order_now(base - 5.0, 5.0, base)                       # arrives after the opening
	_at(base + 0.01, "order after the opening: no alarm")
	_at(base + 15.0, "shut")


func _follow_up() -> void:
	var base := 600.0
	mw.advance_to(base)
	_order_now(base + 6.0, 4.0, base)                       # opening 606..609, open to 613 (merged: 615), then closing
	_at(base + 7.0, "first opening")
	_at(base + 9.5, "first opening done")
	mw.open_source(gate, base + 8.0, 4.0, base + 9.6)       # while open: merges (hold only), no second opening
	mw.advance_to(base + 9.7)
	_at(base + 10.0, "a merged order while open sounds nothing")
	_at(base + 13.6, "the merged hold (to 615) keeps it open, silent")
	eq(str(mw.source_state(gate)["state"]), "open", "still open on the merged hold")
	_order_now(base + 22.0, 4.0, base + 15.2)               # while closing (615 .. 617): a new opening
	_at(base + 15.5, "follow-up order while closing: silent until its leaves move")
	eq(str(mw.source_state(gate)["state"]), "closing", "the leaves still closing")
	_at(base + 22.01, "follow-up: opening")
	_at(base + 25.01, "follow-up: open")
	_at(base + 40.0, "shut")


func _restore() -> void:
	var base := 700.0
	mw.advance_to(base)
	_order_now(base + 8.0, 4.0, base)
	_at(base + 1.0, "before snapshot")
	var snap := mw.snapshot()
	eq((snap["doors"][gate] as Array).size(), 4, "the schedule carries alarm_from")
	var clean := snap.duplicate(true)
	clean["doors"] = {}
	clean["now"] = base + 1.5
	mw.restore(clean)
	_at(base + 1.5, "restored with no door: silent", false)
	snap["now"] = base + 9.0
	mw.restore(snap)
	eq(mw.alarm(gate), true, "restored mid-opening: on at once")
	eq(door.siren_on, true, "restored mid-opening: siren on")
	eq(str(mw.source_state(gate)["state"]), "opening", "restored: leaves opening")
	_at(base + 11.01, "restored: off once open")
	var old := snap.duplicate(true)
	(old["doors"][gate] as Array).resize(3)                 # a snapshot from before the alarm
	old["now"] = base + 9.0
	mw.restore(old)
	_at(base + 9.0, "old 3-long snapshot: on through the opening")
	_at(base + 11.01, "old 3-long snapshot: off once open")
	var long := snap.duplicate(true)
	(long["doors"][gate] as Array)[3] = base + 8.0 - 10.0   # the old 10 s lead
	long["now"] = base + 2.0
	mw.restore(long)
	_at(base + 2.0, "old 10 s lead restored: cut to the current rule")
	clean["now"] = base + 20.0
	mw.restore(clean)


## A gate on a deck that is not the active one: lamps and beacons run, the siren stays quiet; back on its deck it plays.
func _other_deck() -> void:
	var base := 750.0
	mw.advance_to(base)
	_order_now(base + 2.0, 4.0, base)
	var k := int(mw._sources[gate]["deck"])
	var other := (k + 1) % stack.decks.size()
	stack.set_active_deck(other)
	mw.advance_to(base + 3.0)
	eq(mw.alarm(gate), true, "other deck: the alarm runs")
	check(door.lamps_lit(), "other deck: the beacons turn")
	eq(door.siren_on, false, "other deck: the siren is quiet")
	stack.set_active_deck(k)
	mw.advance_to(base + 3.5)
	eq(door.siren_on, true, "back on its deck: the siren plays")
	mw.advance_to(base + 20.0)


func _lift() -> void:
	if lift == null:
		return
	var base := 800.0
	mw.advance_to(base)
	mw.open_source(lift, base + 8.0, 4.0)
	mw.advance_to(base + 8.5)
	eq(mw.alarm(lift), false, "a lift has no alarm")
	eq(bool(mw.source_state(lift)["alarm"]), false, "a lift's source_state alarm is off")
	mw.advance_to(base + 20.0)


func _sealed() -> void:
	var base := 900.0
	mw.advance_to(base)
	_order_now(base + 8.0, 4.0, base)
	_at(base + 9.0, "before sealing")
	mw.close_source(gate)
	_at(base + 9.01, "close_source cuts the alarm", false)
	eq(str(mw.source_state(gate)["state"]), "closing", "an opening door closes before it is sealed")
	mw.advance_to(base + 12.0)
	eq(str(mw.source_state(gate)["state"]), "sealed", "sealed")
	mw.open_source(gate, base + 20.0)
	_at(base + 21.0, "an order to a sealed gate sounds nothing", false)
