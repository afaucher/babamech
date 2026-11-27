extends TestCase
## CombatLog (scripts/game/combat_log.gd): hits fed through the real damage path (CombatWorld.resolve_hit -> deliver ->
## apply_hit -> damaged / hit_landed; fall damage through PlayerTarget.apply_damage; a client's hit through remote_hit),
## mission time driven by hand (CombatLog.step), lines captured through `sink`. Asserts dmg_in coalescing and remaining
## HP, dmg_out aggregation / kill / est, the 10 s summary (window sums, combat flag off after 6 s quiet, enemies within
## 150 m), the down / respawn lines, the end summary (totals, lowest HP and when, combat vs quiet, longest stretches),
## that every line parses as `[Flow] t=<float> <tag> key=value...`, and that a disabled or unstarted log prints nothing.
## The `damaged` contract (HP actually removed: hardpoint overkill, a wrecked hardpoint's hit on the torso, zero-damage
## hits never paired with the next hit's damage). A bot's heat / shutdown come from its MechController.
## Threat and pacing (docs/design/pacing-director.md 3): PilotIntensity against the table of 1.2, PacingStats (quiet
## stretches, peaks, kill intervals), and a staged physics scene (real EnemyTurrets, a wall, CombatLog stepped at 60 Hz):
## own shots (hit / miss, coalesced), enemy shots at the pilot coalesced per 1 s with their hits, threat lines at 1 Hz
## with the right counts (one enemy in sight, one behind the wall, one beyond 200 m), the p>e ray budget (never more than
## 12 a second, 12 nearest listed), a host-owned hangar bot's own threat lines (bot=1, negative pilot id), intensity / director state from mission state (src=host, pace lines), and the
## note_release / note_scout / note_depot / note_pace / note_scale records (no-ops once the log ended).

var world: CombatWorld
var pt: PlayerTarget
var e1: CombatTarget
var e2: CombatTarget
var e3: CombatTarget
var cl: CombatLog
var out: Array[String] = []


func setup() -> void:
	_build()
	_run()
	_dealt_contract()
	_intensity_table()
	_pacing_stats()
	await _threat_scene()
	_check_parse()
	_disabled()
	finish()


func _enemy(id: String, hp: float, at: Vector3) -> CombatTarget:
	var e := CombatTarget.new()
	e.target_id = id
	e.team = "enemy"
	e.mass_class = "static"
	e.set_max_hp({"body": hp})
	e.add_hit_sphere("body", Vector3.ZERO, 1.0)
	world.add_child(e)
	e.position = at
	world.register(e)
	return e


func _build() -> void:
	world = CombatWorld.new()
	world.use_physics = false
	add_child(world)
	pt = PlayerTarget.new()
	world.add_child(pt)
	pt.bind(world, null, null, "player1", 1)
	world.register(pt)
	e1 = _enemy("e1", 500.0, Vector3(100, 0, 0))
	e2 = _enemy("e2", 20.0, Vector3(50, 0, 0))
	e3 = _enemy("e3", 500.0, Vector3(200, 0, 0))
	cl = _new_log()


func _new_log() -> CombatLog:
	var c := CombatLog.new()
	add_child(c)
	c.set_physics_process(false)   # mission time by hand
	c.sink = func(l: String) -> void: out.append(l)
	c.bind(world, pt)
	return c


## Advance the log's mission time to `t` in one step.
func _to(t: float) -> void:
	cl.step(t - cl.mt)


func _hit(shooter: String, peer: int, weapon: String, target: CombatTarget, comp: String, dmg: float, heat: float = 0.0) -> void:
	world.resolve_hit({"shooter": shooter, "peer": peer, "weapon": weapon, "hardpoint": "side_l", "shot_index": 0},
		{"target_heat": heat}, target, comp,
		target.position, Vector3.UP, Vector3.FORWARD, dmg)


## Lines with `tag`, each as {key: value} (plus "tag").
func _recs(tag: String) -> Array[Dictionary]:
	var r: Array[Dictionary] = []
	for l in out:
		var parts := l.split(" ")
		if parts.size() > 2 and parts[2] == tag:
			var d := {"tag": tag}
			for i in range(3, parts.size()):
				var kv := parts[i].split("=", true, 1)
				if kv.size() == 2:
					d[kv[0]] = kv[1]
			r.append(d)
	return r


func _run() -> void:
	cl.start()
	_to(1.0)
	_hit("e1", 1, "cannon", pt, "torso", 42.0)
	_to(1.5)
	var din := _recs("dmg_in")
	if eq(din.size(), 1, "one dmg_in line for one hit, after its window"):
		eq(din[0]["src"], "e1/target", "source id / kind")
		eq(din[0]["wpn"], "cannon", "weapon")
		eq(din[0]["comp"], "torso", "component")
		eq(din[0]["amt"], "42.0", "amount")
		eq(din[0]["n"], "1", "one hit")
		eq(din[0]["mt"], "1.0", "mission time of the hit")
		check(str(din[0]["hp"]).begins_with("torso:358/400,"), "remaining torso HP: " + str(din[0]["hp"]))
		check(str(din[0]["hp"]).contains("leg_l:200/200") and str(din[0]["hp"]).contains("head:100/100"), "every component")
	# Continuous damage: five flamer ticks in 0.4 s from one source on one component -> one line.
	for i in 5:
		_hit("e1", 1, "flamer", pt, "torso", 3.0, 2.0)
		cl.step(0.1)
	_to(2.5)
	_hit("e1", 1, "cannon", pt, "leg_l", 20.0)
	_to(3.0)
	din = _recs("dmg_in")
	if eq(din.size(), 3, "flamer ticks coalesced into one line, then the leg hit"):
		eq(din[1]["wpn"], "flamer", "flamer line")
		eq(din[1]["amt"], "15.0", "flamer amount summed")
		eq(din[1]["n"], "5", "five ticks")
		eq(din[1]["heat_in"], "10.0", "heat summed")
		check(str(din[1]["hp"]).begins_with("torso:343/400"), "torso after the flamer: " + str(din[1]["hp"]))
		eq(din[2]["comp"], "leg_l", "leg line")
		check(str(din[2]["hp"]).contains("leg_l:180/200"), "leg HP left")
	# Dealt: three autocannon hits in one frame on e1 -> one line; a rail kill on e2 prints at once.
	for i in 3:
		_hit("player1", 1, "autocannon", e1, "body", 10.0)
	_hit("player1", 1, "rail", e2, "body", 25.0)
	var dout := _recs("dmg_out")
	if eq(dout.size(), 1, "the kill prints at once"):
		eq(dout[0]["tgt"], "e2/target", "kill target")
		eq(dout[0]["kill"], "1", "kill flag")
		eq(dout[0]["amt"], "20.0", "kill amount (the 20 HP it had: damaged reports HP dealt, not the 25 requested)")
		eq(dout[0]["est"], "0", "applied here: exact")
	_to(4.0)
	dout = _recs("dmg_out")
	if eq(dout.size(), 2, "autocannon hits aggregated per target + weapon"):
		eq(dout[1]["tgt"], "e1/target", "target")
		eq(dout[1]["wpn"], "autocannon", "weapon")
		eq(dout[1]["amt"], "30.0", "summed")
		eq(dout[1]["n"], "3", "three hits")
		eq(dout[1]["thp"], "94", "target HP left %")
		eq(dout[1]["kill"], "0", "no kill")
	# A client's hit on a host-owned target: only remote_hit is seen -> est.
	var h := Hit.new()
	h.damage = 7.0
	h.weapon = "laser"
	h.shooter = "player1"
	world.remote_hit.emit("e1", h)
	var hx := Hit.new()
	hx.damage = 99.0
	hx.shooter = "player2"
	world.remote_hit.emit("e1", hx)   # someone else's: not ours
	_to(5.0)
	dout = _recs("dmg_out")
	if eq(dout.size(), 3, "the remote hit logged once"):
		eq(dout[2]["est"], "1", "remote hit is an estimate")
		eq(dout[2]["amt"], "7.0", "remote amount")
	_to(9.0)
	_hit("e1", 1, "cannon", pt, "torso", 10.0)
	_to(10.0)
	var sums := _recs("summary")
	if eq(sums.size(), 1, "summary at 10 s"):
		eq(sums[0]["in"], "87.0", "damage taken in the window")
		eq(sums[0]["out"], "57.0", "damage dealt in the window (30 + 20 + 7)")
		eq(sums[0]["combat"], "1", "in combat (hit at 9 s)")
		eq(sums[0]["near"], "1", "one live enemy within 150 m (e2 dead, e3 at 200 m)")
		eq(sums[0]["nearest"], "100.0", "nearest enemy")
		eq(sums[0]["hp"], "90", "total HP %")
		eq(sums[0]["core"], "83", "weakest core component %")
		eq(sums[0]["deck"], "-1", "no deck source")
		eq(sums[0]["obj"], "-", "no objective source")
	_to(20.0)
	sums = _recs("summary")
	if eq(sums.size(), 2, "second summary at 20 s"):
		eq(sums[1]["combat"], "0", "quiet 6 s after the last activity")
		eq(sums[1]["in"], "0.0", "window reset")
		eq(sums[1]["out"], "0.0", "window reset")
	_to(20.5)
	_hit("e1", 1, "cannon", pt, "torso", 300.0)
	_to(22.0)
	_hit("e1", 1, "cannon", pt, "head", 150.0)
	check(pt.disabled, "the head hit downs the mech")
	_to(22.5)
	var down := _recs("down")
	if eq(down.size(), 1, "down line"):
		eq(down[0]["cause"], "head", "down cause")
		eq(down[0]["src"], "e1/target", "down source")
		eq(down[0]["wpn"], "cannon", "down weapon")
		eq(down[0]["mt"], "22.5", "printed at the next step")
	var last_in := _recs("dmg_in")
	check(out.find(_line_of("dmg_in", last_in.size() - 1)) < out.find(_line_of("down", 0)), "the killing hit's line before the down line")
	_to(23.0)
	pt.repair_all()
	_to(23.5)
	eq(_recs("respawn").size(), 1, "respawn line")
	_to(25.0)
	pt.apply_damage(30.0, "leg_l", "fall")   # the fall path: no hit
	_to(25.5)
	din = _recs("dmg_in")
	eq(din[din.size() - 1]["src"], "fall/env", "fall damage source")
	eq(din[din.size() - 1]["wpn"], "fall", "fall damage weapon")
	_to(30.0)
	cl.finish("won", "test run")
	cl.finish("lost", "again")   # once only
	var ends := _recs("end")
	if eq(ends.size(), 1, "one end line"):
		var e := ends[0]
		eq(e["outcome"], "won", "outcome")
		eq(e["reason"], "test_run", "reason without spaces")
		eq(e["in"], "517.0", "total taken (87 + 300 + 100 of the 150 head hit: the head had 100 + 30 fall)")
		eq(e["out"], "57.0", "total dealt")
		eq(e["kills"], "1", "kills")
		eq(e["est"], "1", "some dealt damage was estimated")
		eq(e["taken_by"], "target:487.0,env:30.0", "taken by source kind")
		eq(e["dealt_by"], "autocannon:30.0,rail:20.0,laser:7.0", "dealt by weapon")
		eq(e["hp_min"], "46", "lowest total HP %")
		eq(e["hp_min_mt"], "22.0", "when")
		eq(e["core_min"], "0", "lowest core component %")
		eq(e["deaths"], "1", "deaths")
		eq(e["death_mt"], "22.0", "death time")
		eq(e["respawns"], "1", "respawns")
		eq(e["respawn_mt"], "23.5", "respawn time")
		eq(e["combat_s"], "21.5", "combat 1-15 and 20.5-28")
		eq(e["quiet_s"], "8.5", "quiet 0-1, 15-20.5, 28-30 (the fall is not a fight)")
		eq(e["longest_quiet"], "5.5", "longest quiet stretch")
		eq(e["longest_quiet_mt"], "15.0", "it started at 15 s")
		eq(e["longest_combat"], "14.0", "longest combat stretch")
		eq(e["longest_combat_mt"], "1.0", "it started at 1 s")
	var n := out.size()
	_hit("e1", 1, "cannon", pt, "torso", 10.0)
	_to(40.0)
	eq(out.size(), n, "nothing after the end")


## The `damaged` contract (amount = HP actually removed, no event when nothing was dealt, a destroyed hardpoint's hits land
## on the torso) as the log sees it: overkill on a hardpoint logs its HP; the next hit on the wreck logs comp=torso; a hit
## that deals nothing (invulnerable) prints nothing, or amt=0 with its heat for a heat-only hit, and its hit_landed never
## takes the NEXT hit's damage; a hit on a dead target prints no dmg_out. A fresh log on the same world (the first ended).
func _dealt_contract() -> void:
	pt._setup_components({"side_l": "autocannon"})   # a fresh mech with a side_l weapon (WEAPON_HP)
	var lines: Array[String] = []
	var c := CombatLog.new()
	add_child(c)
	c.set_physics_process(false)
	c.sink = func(l: String) -> void:
		lines.append(l)
		out.append(l)
	c.bind(world, pt)
	c.start()
	c.step(1.0)
	_hit("e1", 1, "cannon", pt, "side_l", PlayerTarget.WEAPON_HP + 50.0)
	c.step(1.0)
	_hit("e1", 1, "lance", pt, "side_l", 30.0)   # the wrecked hardpoint: the torso takes it
	c.step(1.0)
	pt.invuln_left = 5.0
	_hit("e1", 1, "bolter", pt, "torso", 40.0)          # nothing dealt, no heat: no line
	_hit("e1", 1, "flamer", pt, "torso", 5.0, 3.0)      # nothing dealt, heat: amt 0 with its heat
	pt.invuln_left = 0.0
	_hit("e1", 1, "rifle", pt, "torso", 10.0)           # same shooter, same frame: its own 10 only
	c.step(1.0)
	check(e2.destroyed(), "e2 died in the first run")
	_hit("player1", 1, "rail", e2, "body", 25.0)        # a wreck: nothing dealt, no dmg_out
	c.step(2.0)
	c.finish("won")
	var din := _recs_in(lines, "dmg_in")
	var by_wpn := {}
	for d in din:
		by_wpn[d["wpn"]] = d
	eq(din.size(), 4, "four dmg_in lines (cannon, lance, flamer, rifle; the bolter dealt nothing): %s" % [by_wpn.keys()])
	if check(by_wpn.has("cannon"), "the hardpoint overkill line"):
		eq(by_wpn["cannon"]["comp"], "side_l", "on the hardpoint")
		eq(by_wpn["cannon"]["amt"], "%.1f" % PlayerTarget.WEAPON_HP, "the HP it had, not the 130 requested")
	if check(by_wpn.has("lance"), "the hit on the wrecked hardpoint"):
		eq(by_wpn["lance"]["comp"], "torso", "lands on the torso")
		eq(by_wpn["lance"]["amt"], "30.0", "in full")
		check(str(by_wpn["lance"]["hp"]).begins_with("torso:370/400"), "torso HP: " + str(by_wpn["lance"]["hp"]))
	check(not by_wpn.has("bolter"), "a hit that dealt nothing prints nothing")
	if check(by_wpn.has("flamer"), "a heat-only hit (no damage dealt) still logs its heat"):
		eq(by_wpn["flamer"]["amt"], "0.0", "no damage")
		eq(by_wpn["flamer"]["heat_in"], "3.0", "its heat")
	if check(by_wpn.has("rifle"), "the hit after the zero-damage ones"):
		eq(by_wpn["rifle"]["amt"], "10.0", "its own damage only (nothing carried over from the zero-damage hits)")
	eq(_recs_in(lines, "dmg_out").size(), 0, "a hit on a dead target: no dmg_out")
	var en := _recs_in(lines, "end")
	if eq(en.size(), 1, "end line"):
		eq(en[0]["in"], "%.1f" % (PlayerTarget.WEAPON_HP + 40.0), "total taken = HP actually lost (80 + 30 + 10)")
		eq(en[0]["out"], "0.0", "nothing dealt")
	c.queue_free()
	pt._setup_components({})


func _line_of(tag: String, i: int) -> String:
	var k := 0
	for l in out:
		var parts := l.split(" ")
		if parts.size() > 2 and parts[2] == tag:
			if k == i:
				return l
			k += 1
	return ""


func _check_parse() -> void:
	var re := RegEx.new()
	re.compile("^\\[Flow\\] t=-?[0-9]+\\.[0-9]+ [a-z_]+( [a-z0-9_]+=\\S+)+$")
	check(out.size() > 10, "lines printed: %d" % out.size())
	for l in out:
		check(re.search(l) != null, "parses: " + l)


func _disabled() -> void:
	pt.repair_all()
	var before := out.size()
	# Not started (no mission running): nothing.
	cl.queue_free()
	cl = _new_log()
	_hit("e1", 1, "cannon", pt, "torso", 10.0)
	_hit("player1", 1, "autocannon", e3, "body", 10.0)
	_to(15.0)
	cl.finish("won")
	eq(out.size(), before, "an unstarted log prints nothing")
	eq(cl.lines, 0, "no lines")
	# Disabled (--no-combat-log): start() refuses, nothing prints.
	var was := CombatLog.enabled
	CombatLog.enabled = false
	cl.queue_free()
	cl = _new_log()
	cl.running_fn = func() -> bool: return true
	cl.start()
	_hit("e1", 1, "cannon", pt, "torso", 10.0)
	_to(15.0)
	cl.finish("won")
	eq(out.size(), before, "a disabled log prints nothing")
	eq(CombatLog.attach(null), null, "attach without a drive: none")
	CombatLog.enabled = was


# --- Threat and pacing -----------------------------------------------------------------------------------------

## PilotIntensity against pacing-director.md 1.2: each input, decay only when not engaged, clamp 0..100.
func _intensity_table() -> void:
	var pi := PilotIntensity.new()
	pi.structure(100.0)
	eq(pi.value, 0.0, "the first structure feed is the baseline")
	pi.structure(90.0)
	eq(pi.value, 10.0, "+1 per 1 % of total structure lost")
	pi.structure(95.0)
	eq(pi.value, 10.0, "a repair never lowers I")
	pi.structure(85.0)
	eq(pi.value, 20.0, "loss counted from the repaired baseline")
	pi.component_destroyed()
	eq(pi.value, 35.0, "+15 per component destroyed")
	pi.disabled()
	eq(pi.value, 75.0, "+40 when disabled")
	pi.kill_near(20.0)
	eq(pi.value, 77.0, "kill at 20 m: +4 x (1 - 20/40)")
	pi.kill_near(40.0)
	pi.kill_near(55.0)
	eq(pi.value, 77.0, "kills at 40 m or farther add nothing")
	pi.step(1.0, true, false)
	eq(pi.value, 77.0, "no decay while engaged")
	pi.step(1.0, false, false)
	eq(pi.value, 73.0, "-4 per second while not engaged")
	pi.step(1.0, true, true)
	eq(pi.value, 78.0, "+5 per second at heat shutdown")
	pi.step(0.5, false, true)
	eq(pi.value, 78.5, "shutdown and decay together: +2.5 - 2")
	pi.disabled()
	pi.disabled()
	eq(pi.value, 100.0, "clamped at 100")
	pi.step(100.0, false, false)
	eq(pi.value, 0.0, "clamped at 0")
	check(PilotIntensity.engaged(10.0, 6.0), "engaged 4 s after the last engagement")
	check(not PilotIntensity.engaged(10.0, 5.9), "not past 4 s")
	var a := PilotIntensity.new()
	var b := PilotIntensity.new()
	for p: PilotIntensity in [a, b]:
		p.structure(100.0)
		p.structure(70.0)
		p.kill_near(10.0)
		p.step(2.0, false, true)
	eq(a.value, b.value, "deterministic: same inputs, same value")


## PacingStats: engaged share, quiet stretches (> 30 s listed), peaks with re-arm, kill intervals, body fields.
func _pacing_stats() -> void:
	var ps := PacingStats.new()
	ps.begin(0.0, false)
	eq(ps.sample(20.0, false, 10.0), 0.0, "still quiet")
	eq(ps.sample(35.0, true, 10.0), 35.0, "a 35 s quiet stretch ends at 35")
	eq(ps.sample(50.0, false, 40.0), 0.0, "engaged 35-50")
	ps.sample(60.0, false, 75.0)
	ps.sample(61.0, false, 80.0)
	ps.sample(70.0, false, 30.0)
	ps.sample(71.0, false, 72.0)
	eq(ps.sample(90.0, true, 50.0), 40.0, "a 40 s quiet stretch 50-90")
	eq(ps.sample(95.0, true, 20.0), 0.0, "engaged")
	eq(ps.close(100.0), 0.0, "closed while engaged: no open quiet stretch")
	eq(ps.sample(110.0, false, 90.0), 0.0, "nothing after close")
	eq(ps.peaks, 2, "two peaks (crossing 70, re-armed under 35)")
	eq(PacingStats.times(ps.peak_t), "60.0;71.0", "peak times")
	eq(ps.eng_s, 25.0, "engaged 35-50 and 90-100")
	eq(roundi(ps.engaged_pct()), 25, "25 % of 100 s")
	eq(ps.q_max, 40.0, "longest quiet")
	eq(ps.q_max_t, 50.0, "it started at 50")
	eq(PacingStats._pairs(ps.quiet30), "0.0+35.0;50.0+40.0", "every quiet stretch over 30 s with its start")
	for t: float in [10.0, 16.0, 30.0, 31.0]:
		ps.kill(t)
	var k := ps.kill_intervals()
	eq(k[0], 6.0, "median kill interval (1, 6, 14)")
	eq(k[1], 14.0, "p90 (nearest rank)")
	eq(k[2], 14.0, "longest")
	ps.dmg_in = 50.0
	eq(ps.per_minute(ps.dmg_in), 30.0, "damage per minute")
	var body := ps.body(false)
	check(body.contains("quiet30=0.0+35.0;50.0+40.0") and body.contains("peaks=2") and body.contains("kint_med=6.0"), body)
	var one := PacingStats.new()
	one.begin(0.0, false)
	one.kill(5.0)
	eq(one.kill_intervals()[0], -1.0, "fewer than 2 kills: no interval")
	eq(one.close(40.0), 40.0, "closing a quiet deck closes its stretch")
	eq(PacingStats._pairs(one.quiet30), "0.0+40.0", "listed")


func _turret(w: CombatWorld, id: String, at: Vector3) -> EnemyTurret:
	var t := EnemyTurret.new()
	t.configure("turret", id, w, null, null, 1)
	w.add_child(t)
	t.position = at
	w.register(t)
	return t


func _step_log(c: CombatLog, until: float) -> void:
	while c.mt < until - 1e-6:
		c.step(1.0 / 60.0)


## The staged scene: physics on, a pilot at the origin, turret A 50 m away in the open with the pilot as its target and
## in sight, turret B 80 m away behind a wall (also targeting, no sight), turret C 250 m away. CombatLog stepped at 60 Hz.
func _threat_scene() -> void:
	var w := CombatWorld.new()
	w.use_physics = true
	add_child(w)
	var p := PlayerTarget.new()
	w.add_child(p)
	p.bind(w, null, null, "player1", 1)
	w.register(p)
	var ta := _turret(w, "tA", Vector3(50, 0, 0))
	var tb := _turret(w, "tB", Vector3(-80, 0, 0))
	_turret(w, "tC", Vector3(0, 0, 250))
	var dummy := CombatTarget.new()   # a neutral target for the own shots (not an enemy: not counted)
	dummy.target_id = "d1"
	dummy.mass_class = "static"
	dummy.set_max_hp({"body": 1000.0})
	dummy.add_hit_sphere("body", Vector3.ZERO, 1.0)
	w.add_child(dummy)
	dummy.position = Vector3(0, 3, 30)
	w.register(dummy)
	var wall := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(2, 40, 40)
	cs.shape = bs
	wall.add_child(cs)
	w.add_child(wall)
	wall.position = Vector3(-40, 5, 0)
	ta._target_id = "player1"
	ta._has_los = true
	tb._target_id = "player1"
	tb._has_los = false
	await frames(3)   # the wall in the physics space
	var lines: Array[String] = []
	var c := CombatLog.new()
	add_child(c)
	c.set_physics_process(false)
	c.sink = func(l: String) -> void:
		lines.append(l)
		out.append(l)   # every line parses (_check_parse)
	c.bind(w, p)
	c.start()
	_step_log(c, 0.1)
	# Own shots: two hit d1 (resolved at their hit), one misses (no hit within the autocannon's flight time + pad).
	for i in 3:
		var rec := Combat.fire_record("player1", 1, "side_l", "autocannon", Vector3(0, 3, 0),
			dummy.position if i < 2 else Vector3(40, 3, 0), 0.0, 100 + i)
		w.fired.emit(rec)
		if i < 2:
			w.resolve_hit(rec, {}, dummy, "body", dummy.position, Vector3.UP, Vector3.FORWARD, 6.0)
	# Enemy shots from A at the pilot, 0.2 s apart; the second hits.
	for i in 3:
		_step_log(c, 0.2 + 0.2 * i)
		var er := Combat.fire_record("tA", 1, "enemy_cannon", "enemy_cannon", Vector3(50, 4, 0), Vector3(0, 3, 0), 0.0, i)
		er["enemy"] = true
		er["team"] = "enemy"
		w.fired.emit(er)
		if i == 1:
			w.resolve_hit(er, {}, p, "torso", p.position, Vector3.UP, Vector3.FORWARD, 5.0)
	_step_log(c, 5.5)   # the autocannon's miss resolves at 0.1 + 220/70 + 0.5 s, its line 1 s later
	var shots := _recs_in(lines, "shot")
	var own_hit := shots.filter(func(d: Dictionary) -> bool: return d["src"] == "player1/player" and d["tgt"] == "d1/target")
	var own_miss := shots.filter(func(d: Dictionary) -> bool: return d["src"] == "player1/player" and d["tgt"] == "-")
	var enemy := shots.filter(func(d: Dictionary) -> bool: return d["src"] == "tA/turret")
	if eq(own_hit.size(), 1, "own hits on one target + weapon coalesce into one shot line"):
		eq(own_hit[0]["n"], "2", "two shots")
		eq(own_hit[0]["hits"], "2", "both hit")
		eq(own_hit[0]["hit"], "1", "hit flag")
		eq(own_hit[0]["wpn"], "autocannon", "weapon")
		eq(own_hit[0]["dist"], "30.0", "muzzle to hit point")
		eq(own_hit[0]["est"], "0", "own shots are exact")
	if eq(own_miss.size(), 1, "the miss: its own line, no target"):
		eq(own_miss[0]["hit"], "0", "miss flag")
		eq(own_miss[0]["hits"], "0", "no hits")
		eq(own_miss[0]["dist"], "40.0", "muzzle to aim point")
		eq(own_miss[0]["mt"], "0.1", "the shot's time")
	if eq(enemy.size(), 1, "the host coalesces an enemy's shots at one pilot over 1 s"):
		eq(enemy[0]["tgt"], "player1/player", "fired at the pilot (the enemy's target)")
		eq(enemy[0]["n"], "3", "three shots")
		eq(enemy[0]["hits"], "1", "one hit (exact: the host owns this pilot)")
		eq(enemy[0]["hit"], "1", "hit flag")
		eq(enemy[0]["est"], "0", "exact")
		eq(enemy[0]["mt"], "0.2", "first shot")
	var th := _recs_in(lines, "threat")
	if eq(th.size(), 5, "threat lines at 1 Hz (5.5 s: at 1, 2, 3, 4, 5)"):
		var last := th[4]
		eq(last["near"], "2", "two enemies within 200 m (A, B; C is at 250 m)")
		eq(last["sees"], "1", "the pilot sees A, not B behind the wall")
		eq(last["seen_by"], "1", "A has the pilot as target with line of sight (read from its AI)")
		eq(last["engaging"], "1", "A engages (fired, and awake within 60 m with the pilot as target); B is 80 m away")
		eq(last["eng"], "1", "engaged")
		eq(last["nearest"], "50.0", "nearest enemy")
		eq(last["src"], "local", "no director: intensity computed here")
		eq(last["est"], "0", "host / solo: exact")
		eq(last["crew_eng"], "1", "the crew is engaged")
		check(int(last["i"]) > 0, "intensity rose from the hit: " + str(last["i"]))
		eq(last["rays"], "2", "two p>e rays in the last second (the two awake enemies in range)")
	var los := _recs_in(lines, "los")
	if check(not los.is_empty(), "los detail lines"):
		eq(los[los.size() - 1]["list"], "tA:1:1,tB:0:0", "per enemy p>e, e>p, nearest first")
	# The ray budget: 15 more enemies within 200 m -> at most 12 rays a second, the 12 nearest listed.
	for i in 15:
		var ang := PI * (0.15 + 0.7 * float(i) / 14.0)
		_turret(w, "tx%d" % i, Vector3(cos(ang), 0, sin(ang)) * (100.0 + 4.0 * i))
	# A host-owned hangar bot (negative pilot id) in the crew: it gets its own threat lines (bot=1), its own ray budget.
	var bp := PlayerTarget.new()
	w.add_child(bp)
	bp.bind(w, null, null, "player-2", 1)
	w.register(bp)
	bp.position = Vector3(45, 0, 20)
	var cb := CrewBot.new()
	cb.target = bp
	add_child(cb)
	# Its MechController, out of the tree (no physics step: the heat stays where the test puts it). As in play, the bot's
	# target is bound to it: heat lives on the controller, the target's own gauge is never ticked (regression: bots logged
	# heat 0 / shut 0 from PlayerTarget.heat).
	var bm := MechController.new()
	bm.position = bp.position
	bm.heat = 0.7 * bm.heat_cap
	cb.mech = bm
	bp.mech = bm
	var bots := {-2: cb}   # (captured as a dictionary: a lambda capturing cb itself errors once cb is freed)
	c.threat.bots_fn = func() -> Dictionary: return bots
	ta._target_id = "player-2"   # A turns on the bot
	_step_log(c, 8.5)
	var bth := _recs_bot(lines, "threat", "1")
	if check(bth.size() >= 2, "threat lines for the bot pilot: %d" % bth.size()):
		var bl := bth[bth.size() - 1]
		eq(bl["pilot"], "-2", "the bot's pilot id")
		eq(bl["engaging"], "1", "A engages the bot (target, awake, within 60 m)")
		eq(bl["seen_by"], "1", "A sees the bot")
		check(int(bl["rays"]) <= CombatThreatProbe.LOS_RAYS, "the bot's own ray budget")
		eq(bl["heat"], "0.70", "the bot's heat from its MechController")
		eq(bl["shut"], "0", "not shut down")
	var bi0 := (c.threat.tracks[1] as PilotTrack).intensity.value if c.threat.tracks.size() > 1 else -1.0
	bm.add_heat(bm.heat_cap)   # overheat: shutdown
	th = _recs_bot(lines, "threat", "0")
	eq(th[th.size() - 1]["pilot"], "0", "the local pilot's line: pilot = the line's peer")
	eq(th[th.size() - 1]["seen_by"], "0", "A no longer has the local pilot as target")
	eq(th[th.size() - 1]["near"], "17", "17 enemies within 200 m")
	eq(th[th.size() - 1]["rays"], "12", "12 rays in the last second")
	check(c.threat.rays_max_sec <= CombatThreatProbe.LOS_RAYS, "never more than 12 rays a second (max %d)" % c.threat.rays_max_sec)
	los = _recs_bot(lines, "los", "0")
	eq(str(los[los.size() - 1]["list"]).split(",").size(), 12, "the 12 nearest listed")
	# Intensity and director state from mission state (the host director's, when it exists).
	var st := {"intensity": {1: 55, 2: 80, -2: 30}, "pace": {0: ["build", 1.0, 0.0]}}
	c.state_fn = func() -> Dictionary: return st
	_step_log(c, 9.5)
	bth = _recs_bot(lines, "threat", "1")
	eq(bth[bth.size() - 1]["i"], "30", "the bot's intensity from mission state (negative id key)")
	eq(bth[bth.size() - 1]["heat"], "1.00", "the bot overheated: its controller's heat")
	eq(bth[bth.size() - 1]["shut"], "1", "the bot's shutdown in its threat line")
	var bi1 := (c.threat.tracks[1] as PilotTrack).intensity.value if c.threat.tracks.size() > 1 else -1.0
	check(bi1 >= minf(bi0 + 4.9, 100.0), "the bot's own intensity gets +5/s while shut down (its controller's shutdown): %.1f -> %.1f" % [bi0, bi1])
	th = _recs_bot(lines, "threat", "0")
	eq(th[th.size() - 1]["src"], "host", "intensity from mission state")
	eq(th[th.size() - 1]["i"], "55", "this pilot's (peer 1)")
	eq(th[th.size() - 1]["crew_i"], "80", "crew intensity = max over pilots")
	st["pace"] = {0: ["peak", 0.0, 0.0, "build"]}
	_step_log(c, 10.5)
	var pace := _recs_in(lines, "pace")
	if eq(pace.size(), 2, "a pace line per replicated state change"):
		eq(pace[0]["from"], "-", "first seen")
		eq(pace[0]["to"], "build", "build")
		eq(pace[1]["from"], "build", "from build")
		eq(pace[1]["to"], "peak", "to peak")
		eq(pace[1]["reason"], "build", "reason when the state carries one")
	CombatLog.note_pace(0, "peak", "fade", 72.0, "timer")
	st["pace"] = {0: ["rest", 0.0, 0.0]}
	_step_log(c, 11.5)
	pace = _recs_in(lines, "pace")
	if eq(pace.size(), 3, "note_pace prints; mission state is no longer diffed after it"):
		eq(pace[2]["to"], "fade", "the noted change")
		eq(pace[2]["i"], "72", "crew intensity")
	CombatLog.note_release("w3", 1, "gate_2", 3, ["tank", "drone", "tank"], "cap")
	CombatLog.note_scout("completed", "drone_7", 1)
	CombatLog.note_depot("grant", "dep_0", 2)
	CombatLog.note_scale(3, 2, "leave", -1, 123.4567)
	var scl := _recs_in(lines, "scale")
	if eq(scl.size(), 1, "scale line"):
		eq([scl[0]["from"], scl[0]["to"], scl[0]["reason"], scl[0]["pilot"], scl[0]["at"]], ["3", "2", "leave", "-1", "123.457"],
			"scale: from, to, reason, pilot (a bot's negative id), at")
	var rel := _recs_in(lines, "release")
	if eq(rel.size(), 1, "release line"):
		eq(rel[0]["kinds"], "tank:2,drone:1", "kinds counted")
		eq(rel[0]["reason"], "cap", "reason")
		eq(rel[0]["src"], "gate_2", "source")
		eq(rel[0]["size"], "3", "size")
	var sc := _recs_in(lines, "scout")
	check(sc.size() == 1 and sc[0]["ev"] == "completed" and sc[0]["drone"] == "drone_7", "scout line")
	var dp := _recs_in(lines, "depot")
	check(dp.size() == 1 and dp[0]["ev"] == "grant" and dp[0]["left"] == "2", "depot line")
	# Lifetimes (regression for "Trying to cast a freed object" under load): an enemy and the bot pilot (its target and
	# CrewBot) freed mid-mission while still listed in world.targets / bots_fn, an enemy shot from the freed enemy's id and a
	# pending own shot at it: the log keeps stepping, prints its lines and drops them.
	var before_free := _recs_bot(lines, "threat", "0").size()
	w.fired.emit(Combat.fire_record("player1", 1, "side_l", "autocannon", Vector3(0, 3, 0), tb.position, 0.0, 200))
	tb.free()
	# Its controller freed first while the track still holds it (cb.mech / PilotTrack.mech): no "Trying to cast a freed
	# object". (The target lets go of it first: CombatWorld._body_excludes tests `is` before is_instance_valid on a
	# PlayerTarget's freed mech, a separate bug, reported.)
	bp.mech = null
	bm.free()
	_step_log(c, 12.5)
	var bot_nomech := _recs_bot(lines, "threat", "1")
	check(not bot_nomech.is_empty() and float(bot_nomech[bot_nomech.size() - 1]["mt"]) > 11.5, "the bot still logs with its controller freed")
	bp.free()
	cb.free()
	var gone := Combat.fire_record("tB", 1, "enemy_cannon", "enemy_cannon", Vector3(-80, 4, 0), Vector3(0, 3, 0), 0.0, 9)
	gone["enemy"] = true
	w.fired.emit(gone)
	_step_log(c, 16.5)
	th = _recs_bot(lines, "threat", "0")
	eq(th.size() - before_free, 5, "threat lines go on after enemies / bots are freed under the log")
	eq(th[th.size() - 1]["near"], "16", "the freed enemy is not counted")
	var bot_after := _recs_bot(lines, "threat", "1")
	check(bot_after.is_empty() or float(bot_after[bot_after.size() - 1]["mt"]) <= 12.5 + 0.01, "no bot lines once it is freed")
	c.finish("won")
	var ds := _recs_in(lines, "deck_sum")
	check(ds.size() == 1 and ds[0].has("eng_pct") and ds[0].has("quiet30") and ds[0].has("kint_med"), "deck summary at the end")
	var en := _recs_in(lines, "end")
	if eq(en.size(), 1, "end line"):
		check(int(en[0]["eng_pct"]) >= 90, "engaged almost all the time: " + str(en[0]["eng_pct"]))
		check(en[0].has("quiet30") and en[0].has("kint_p90") and en[0].has("in_pm"), "pacing fields on the end line")
	var n := lines.size()
	CombatLog.note_release("w4", 1, "gate_2", 3)
	CombatLog.note_scale(2, 1, "leave", 3, 1.0)
	eq(lines.size(), n, "notes are no-ops once the log ended")
	eq(CombatLog.current, null, "no running log")
	_report_tool(lines)
	c.queue_free()
	w.queue_free()
	await frames(1)


## These real lines through tools/pacing_report/pacing_report.py (Python 3 standard library). Skipped, with a note, on a
## machine without `python`; its own checks (quiet-stretch labels, older logs, -Latest) are tools/pacing_report/selftest.py.
func _report_tool(lines: Array[String]) -> void:
	var ver: Array = []
	if OS.execute("python", ["--version"], ver, true) != 0:
		print("[test_combat_log] python not found: pacing_report check skipped (run tools/pacing_report/selftest.py)")
		return
	var dir := ProjectSettings.globalize_path("user://test_pacing_report")
	DirAccess.make_dir_recursive_absolute(dir)
	var log_path := dir.path_join("run.log")
	var html_path := dir.path_join("report.html")
	var f := FileAccess.open(log_path, FileAccess.WRITE)
	f.store_string("\n".join(lines) + "\n")
	f.close()
	var res: Array = []
	var code := OS.execute("python", [ProjectSettings.globalize_path("res://tools/pacing_report/pacing_report.py"), log_path,
		"-o", html_path], res, true)
	if not eq(code, 0, "pacing_report runs on this log: " + str(res)):
		return
	var h := FileAccess.get_file_as_string(html_path)
	for s: String in ["Structure %", "Intensity", "Enemies", "Damage per 10 s", "Director state and events",
			"Quiet stretches", 'class="st-peak"', 'class="m-release"', 'class="m-scout"', 'class="m-depot"', "mission"]:
		check(h.contains(s), "the report has " + s)
	check(not h.contains("http://") and not h.contains("https://"), "self-contained")
	DirAccess.remove_absolute(log_path)
	DirAccess.remove_absolute(html_path)


func _recs_bot(src: Array[String], tag: String, bot: String) -> Array[Dictionary]:
	var r: Array[Dictionary] = []
	for d in _recs_in(src, tag):
		if d.get("bot", "0") == bot:
			r.append(d)
	return r


func _recs_in(src: Array[String], tag: String) -> Array[Dictionary]:
	var r: Array[Dictionary] = []
	for l in src:
		var parts := l.split(" ")
		if parts.size() > 2 and parts[2] == tag:
			var d := {"tag": tag}
			for i in range(3, parts.size()):
				var kv := parts[i].split("=", true, 1)
				if kv.size() == 2:
					d[kv[0]] = kv[1]
			r.append(d)
	return r
