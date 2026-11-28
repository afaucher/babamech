extends TestCase
## Downed, revive, respawn (DownedRules, PlayerTarget's owner-side state, RepairDrone's revive beam, DownedCrew, the
## combat log; docs/design/pacing-director.md "Downed, revive, respawn"), single process, stepped by hand (no wall clock).
## A. No auto-respawn: a downed mech stays down, takes no damage, is not hittable, enemies drop it as a target.
## B. Hold to respawn: 2.9 s held then released resets the hold; 3 s held -> redeploying for 5 s -> standing, every
##    component at FULL (R2.12: RESPAWN_STRUCTURE 1.0), heat 0, on_respawn called once (the placement), player_respawned.
## C. Revive by a repair drone: 0.5 s rise + 4 s of beam in range stands it up in place at 30 % (destroyed rebuilt at
##    30 %, others at least 30 %), heat 0, 2 s invulnerable, player_revived (by the drone's shooter); the drone loses no
##    life and no charge (its cost is the charge that launched it); an ORDINARY drone of the downed mech dies with it and
##    never revives it; a SELF-REVIVE drone (R2.9, record "self") does: once, at 30 %, player_revived by its own id.
## D. An interrupted beam drains the bar over 2 s (decay, not reset), a beam resumes from what is left.
## E. A downed bot (pilot -1, auto_redeploy): waits 8 s with a reviver, 2 s without, then the respawn path, at full.
##    R2.9: while its own drone self-revives it (DownedRules.bot_wait_for) it does not redeploy, and stands up after the
##    revive; when the self-revive ends without one, the normal wait applies.
## F. A downed (or redeploying) mech gets no power core and holds no flag; `wipe` on loses only with everyone down and
##    nobody redeploying; `wipe` off never loses.
## G. The combat log: down + help, revive, respawn lines; end fields deaths (respawns only), revives, revives_given,
##    down_s; intensity +40 once per down; respawn tot=100 (R2.12); a self-revive logs `revive by=self`, no death, and
##    no revive given.
## H. A solo stack drive: the downed mech can't move; holding SPACE (respawn_held) respawns it at deck 1's arrival point
##    when it went down on deck 1, at its own spawn slot on the entry deck; the HUD state / prompt follow (a self-revive:
##    "Your repair drone is reviving you", the hold hint stays, holding SPACE still redeploys). R2.12: the redeploy brings
##    the mech back FULL (every component, a destroyed weapon usable and selectable, ammo and drone charges refilled by
##    DownedCrew on the owner, heat 0, shutdown cleared).
## H3. R2.9 end to end in a solo drive with a charged repair drone: down alone -> up by its own drone once (by=self);
##    down with no charge -> stays down; SPACE redeploys at full with the charges refilled; SPACE during a self-revive
##    still redeploys, at full.

const DT := 1.0 / 60.0
const SEED := 7
const TEST_TIMEOUT := 1200.0
## I. Safe respawn spots (2026-11-26: seed 6's deck 1 arrival is a lift; a Strider respawned on its platform and fell
## to deck 2): every arrival kind (portal, ramp foot, lift, shaft landing), every deck, every seat, both chassis, and the
## objective-near spot of every defend / hold.
const SAFE_SEEDS: Array[int] = [1, 3, 6, 7, 9, 22, 403112]

var world: CombatWorld


func _init() -> void:
	timeout_sec = TEST_TIMEOUT


func setup() -> void:
	world = CombatWorld.new()
	add_child(world)
	await frames(1)
	_no_auto_respawn()
	_hold_to_respawn()
	_revive()
	_decay()
	_bots()
	_depot_flag_wipe()
	_log()
	_self_log()
	await _drive()
	await _drive_self_revive()
	finish()


## A PlayerTarget in the tree at `at`, owned here (peer 1), with an off-tree MechController (no physics).
func _pilot(id: String, at: Vector3, loadout: Dictionary = {}) -> PlayerTarget:
	var model: MechModel = null
	if not loadout.is_empty():
		model = MechModel.new()
		add_child(model)
		model.configure("chicken", "strider", loadout)
	var mech := MechController.new()
	var pt := PlayerTarget.new()
	pt.name = id
	add_child(pt)
	pt.bind(world, mech, model, id, 1)
	pt.position = at
	world.register(pt)
	return pt


func _down(pt: PlayerTarget) -> void:
	pt.apply_damage(300.0, "torso", "test")
	pt.apply_damage(1000.0, "head", "test")


func _run(s: float) -> void:
	var n := roundi(s / DT)
	for i in n:
		world.advance(DT)


func _gone(pt: PlayerTarget) -> void:
	world.unregister(pt)
	if pt.mech != null:
		pt.mech.free()
	pt.queue_free()


# --- A ---------------------------------------------------------------------------------------------------------------

func _no_auto_respawn() -> void:
	var pt := _pilot("a1", Vector3(200, 0, 0))
	near(pt.auto_respawn_delay, -1.0, 1e-6, "the test hook is off by default")
	_down(pt)
	check(pt.disabled and not pt.redeploying, "downed")
	_run(12.0)
	check(pt.disabled and not pt.redeploying, "still downed after 12 s: no automatic respawn")
	near(pt.down_time, 12.0, 0.05, "time down counted")
	var hp0 := pt.total_hp()
	pt.apply_damage(200.0, "torso", "test")
	pt.apply_damage(200.0, "leg_l", "fall")
	near(pt.total_hp(), hp0, 1e-6, "a downed mech takes no damage")
	check(not pt.is_hittable(), "a downed mech is not hittable")
	var sq := EnemySquad.new()
	add_child(sq)
	sq.world = world
	var other := _pilot("a2", Vector3(230, 0, 0))
	var picked: CombatTarget = sq._nearest_player_on_deck(Vector3(200, 0, 5), 0)
	check(picked == other, "an enemy's target search drops the downed mech for the standing one (%s)" % [picked.target_id if picked != null else "none"])
	_gone(other)
	var none: CombatTarget = sq._nearest_player_on_deck(Vector3(200, 0, 5), 0)
	check(none == null or none.target_id != "a1", "and never picks the downed mech")
	sq.queue_free()
	_gone(pt)


# --- B ---------------------------------------------------------------------------------------------------------------

func _hold_to_respawn() -> void:
	var pt := _pilot("b1", Vector3(260, 0, 0), {"side_l": "laser", "back": "radiator"})
	var placed := [0]
	var got := []
	pt.on_respawn = func() -> void: placed[0] += 1
	pt.player_respawned.connect(func(t: float, _held: bool) -> void: got.append(t))
	pt.mech.heat = 70.0
	_down(pt)
	pt.respawn_held = true
	_run(2.9)
	check(not pt.redeploying, "held 2.9 s: not yet")
	near(pt.respawn_hold, 2.9, 0.02, "the hold counts")
	pt.respawn_held = false
	_run(DT)
	near(pt.respawn_hold, 0.0, 1e-6, "releasing resets the hold")
	pt.respawn_held = true
	_run(DownedRules.RESPAWN_HOLD - 0.05)
	check(not pt.redeploying, "a fresh hold needs the full 3 s again")
	_run(0.1)
	check(pt.redeploying and pt.disabled, "held 3 s: redeploying (still out of the fight)")
	pt.respawn_held = false
	near(pt.redeploy_left, DownedRules.RESPAWN_PENALTY - 0.05, 0.05, "the penalty runs")
	_run(DownedRules.RESPAWN_PENALTY - 0.2)
	check(pt.redeploying and placed[0] == 0, "still redeploying before the penalty ends, not placed")
	pt.apply_damage(50.0, "torso", "test")
	_run(0.3)
	check(not pt.disabled and not pt.redeploying, "standing after the penalty")
	eq(placed[0], 1, "placed once (on_respawn)")
	eq(got.size(), 1, "player_respawned once")
	for c: String in pt.hp:
		near(float(pt.hp[c]), float(pt.max_hp[c]) * DownedRules.RESPAWN_STRUCTURE, 0.01, "respawn: %s at full (R2.12)" % c)
	near(pt.mech.heat, 0.0, 1e-6, "respawn: heat 0")
	_gone(pt)


# --- C ---------------------------------------------------------------------------------------------------------------

func _launch(shooter: String, anchor: Node3D) -> RepairDrone:
	world.set_anchor(shooter, func() -> Node3D: return anchor)
	return world.launch_drone({"shooter": shooter, "peer": 1, "hardpoint": "back", "weapon": "repair_drone", "t": world.now})


func _medic(id: String, at: Vector3) -> Node3D:
	var n := Node3D.new()
	n.name = id
	add_child(n)
	n.global_position = at
	return n


func _revive() -> void:
	var at := Vector3(400, 0, 0)
	var pt := _pilot("c1", at + Vector3(6, 0, 0))
	var revs := []
	pt.player_revived.connect(func(by: String, t: float) -> void: revs.append([by, t]))
	pt.apply_damage(300.0, "torso", "test")       # torso 100 / 400
	pt.apply_damage(190.0, "leg_l", "test")       # leg_l 10 / 200 (below 30 %)
	pt.apply_damage(1000.0, "head", "test")       # head destroyed: downed
	pt.mech.heat = 90.0
	pt.mech.shutdown = true
	check(pt.disabled, "downed for the revive")
	var medic := _medic("medic_n", at)
	var d := _launch("medic", medic)
	if not check(d != null, "the medic's drone launched"):
		return
	var t0 := world.now
	var life0 := d.life()
	_run(d.rise_time() + DownedRules.REVIVE_TIME - 0.1)
	check(pt.disabled, "not yet revived %.1f s after the launch" % (world.now - t0))
	check(d.beamed().has(pt), "the drone beams the downed mech (the scan shows on the wreck)")
	near(pt.revive_progress, DownedRules.REVIVE_TIME - 0.1, 0.05, "the bar fills with the beam")
	_run(0.2)
	check(not pt.disabled, "revived after rise + 4 s of beam (%.2f s)" % (world.now - t0))
	if eq(revs.size(), 1, "player_revived once"):
		eq(str(revs[0][0]), "medic", "revived by the drone's shooter")
	near(float(pt.hp["head"]), 100.0 * DownedRules.REVIVE_STRUCTURE, 1.0, "the destroyed head rebuilt at 30 % (the drone keeps repairing after)")
	near(float(pt.hp["leg_l"]), 200.0 * DownedRules.REVIVE_STRUCTURE, 1.0, "leg_l raised to 30 %")
	near(float(pt.hp["torso"]), 400.0 * DownedRules.REVIVE_STRUCTURE, 1.0, "torso 100 / 400 raised to 30 %")
	near(float(pt.hp["leg_r"]), 200.0, 0.01, "an intact leg keeps its HP (at least 30 %, not set to it)")
	near(pt.mech.heat, 0.0, 1e-6, "heat 0")
	check(not pt.mech.shutdown, "shutdown cleared")
	near(pt.invuln_left, DownedRules.REVIVE_INVULN, 0.15, "2 s of invulnerability")
	var hp1 := pt.total_hp()
	pt.apply_damage(500.0, "head", "test")
	near(pt.total_hp(), hp1 + 0.0, 0.05 * pt.total_max_hp(), "invulnerable: no damage while standing up")
	check(not pt.disabled, "not downed again while invulnerable")
	near(d.life(), life0, 1e-6, "the revive costs the drone no life")
	check(d.active(), "the drone stays on duty")
	_run(DownedRules.REVIVE_INVULN + 0.1)
	var hp2 := float(pt.hp["torso"])
	pt.apply_damage(10.0, "torso", "test")
	near(float(pt.hp["torso"]), hp2 - 10.0, 1e-3, "damage lands again after 2 s")
	# The downed mech's own drone does not revive it (and dies with it).
	var self_med := _pilot("selfmed", at + Vector3(0, 0, 40))
	var sm_node := _medic("selfmed_n", self_med.position)
	var d2 := _launch("selfmed", sm_node)
	_run(1.0)
	_down(self_med)
	_run(DownedRules.REVIVE_TIME + 1.0)
	check(self_med.disabled and self_med.revive_progress <= 0.0, "its own ORDINARY drone never revives a downed mech")
	check(d2 == null or not d2 in world.effects, "its drone died with it")
	_gone(self_med)
	sm_node.queue_free()
	# R2.9: a SELF-REVIVE drone (record "self": true, launched by the mech's own rack as it goes down) revives it once.
	var sr := _pilot("selfrev", at + Vector3(0, 0, 80))
	var sr_node := _medic("selfrev_n", sr.position)
	var sr_revs := []
	sr.player_revived.connect(func(by: String, t: float) -> void: sr_revs.append([by, t]))
	world.set_anchor("selfrev", func() -> Node3D: return sr_node)
	_down(sr)
	var d3 := world.launch_drone({"shooter": "selfrev", "peer": 1, "hardpoint": "back", "weapon": "repair_drone",
		"t": world.now, "self": true})
	if check(d3 != null, "R2.9: the self-revive drone launched"):
		_run(0.2)
		check(world.self_reviving("selfrev"), "R2.9: CombatWorld.self_reviving while it is out")
		check(sr.disabled, "R2.9: not yet revived")
		_run(d3.rise_time() + d3.self_revive_time() + 0.5)
		check(not sr.disabled, "R2.9: its own self-revive drone stood it up")
		if eq(sr_revs.size(), 1, "R2.9: player_revived once"):
			eq(str(sr_revs[0][0]), "selfrev", "R2.9: revived by its OWN id")
		near(float(sr.hp["head"]), 100.0 * DownedRules.REVIVE_STRUCTURE, 5.0, "R2.9: a self-revive is a revive (30 %, + the drone's repair since)")
		check(not world.self_reviving("selfrev"), "R2.9: no longer self-reviving once revived")
	_gone(sr)
	sr_node.queue_free()
	_gone(pt)
	medic.queue_free()
	_run(DT)


# --- D ---------------------------------------------------------------------------------------------------------------

func _decay() -> void:
	var at := Vector3(600, 0, 0)
	var pt := _pilot("d1", at + Vector3(6, 0, 0))
	_down(pt)
	var medic := _medic("medic2_n", at)
	var d := _launch("medic2", medic)
	_run(d.rise_time() + 2.0)
	near(pt.revive_progress, 2.0, 0.05, "2 s of beam")
	pt.position = at + Vector3(40, 0, 0)          # out of the drone's 30 m
	_run(0.5)
	near(pt.revive_progress, 2.0 - 0.5 * DownedRules.decay_rate(), 0.06, "the bar drains over 2 s (half a second: -1 s)")
	check(pt.disabled, "still downed")
	pt.position = at + Vector3(6, 0, 0)
	var left := pt.revive_progress
	_run(DownedRules.REVIVE_TIME - left - 0.1)
	check(pt.disabled, "the beam resumes from what was left")
	_run(0.2)
	check(not pt.disabled, "revived after the remaining %.1f s" % (DownedRules.REVIVE_TIME - left))
	_gone(pt)
	medic.queue_free()
	_run(DT)


# --- E ---------------------------------------------------------------------------------------------------------------

func _bots() -> void:
	for helped: bool in [true, false]:
		var bt := _pilot("player-1", Vector3(800 if helped else 900, 0, 0))
		bt.auto_redeploy = true
		var h := helped
		bt.revive_wait = func() -> float: return DownedRules.bot_wait(h)
		var placed := [0]
		bt.on_respawn = func() -> void: placed[0] += 1
		_down(bt)
		var wait := DownedRules.BOT_REVIVE_WAIT if helped else DownedRules.BOT_ALONE_WAIT
		_run(wait - 0.1)
		check(bt.disabled and not bt.redeploying, "bot (reviver %s): still waiting at %.1f s" % [helped, wait - 0.1])
		_run(0.2)
		check(bt.redeploying, "bot (reviver %s): takes the respawn path after %.0f s" % [helped, wait])
		_run(DownedRules.RESPAWN_PENALTY + 0.1)
		check(not bt.disabled and placed[0] == 1, "bot (reviver %s): respawned after the penalty" % helped)
		for c: String in bt.hp:
			near(float(bt.hp[c]), float(bt.max_hp[c]) * DownedRules.RESPAWN_STRUCTURE, 0.01, "bot respawn: %s at full (R2.12)" % c)
		_gone(bt)
	# R2.9: while its own drone self-revives it the bot does not redeploy (stub: the flag DownedCrew reads from
	# CombatWorld.self_reviving), then stands up after the revive; the flag gone without a revive: the normal wait.
	for revived: bool in [true, false]:
		var sb := _pilot("player-3", Vector3(1100 if revived else 1150, 0, 0))
		sb.auto_redeploy = true
		var flag := [true]
		sb.revive_wait = func() -> float: return DownedRules.bot_wait_for(flag[0], false)
		_down(sb)
		_run(DownedRules.BOT_REVIVE_WAIT + 2.0)
		check(sb.disabled and not sb.redeploying, "R2.9 bot: no redeploy while its own drone self-revives it (%.0f s)" % sb.down_time)
		flag[0] = false
		if revived:
			sb.revive("player-3")
			check(not sb.disabled and not sb.redeploying, "R2.9 bot: stood up by the self-revive")
		else:
			_run(DT * 2.0)
			check(sb.redeploying, "R2.9 bot: the self-revive gone without a revive: the normal wait (already past) redeploys it")
		_gone(sb)
	# A revive in progress keeps the bot waiting past its wait.
	var at := Vector3(1000, 0, 0)
	var bt2 := _pilot("player-2", at + Vector3(6, 0, 0))
	bt2.auto_redeploy = true
	bt2.revive_wait = func() -> float: return 1.0
	_down(bt2)
	var medic := _medic("medic3_n", at)
	var d := _launch("medic3", medic)
	_run(1.5)
	check(bt2.disabled and not bt2.redeploying and bt2.revive_progress > 0.5,
		"bot: a revive in progress keeps it waiting past its wait (progress %.2f)" % bt2.revive_progress)
	_run(d.rise_time() + DownedRules.REVIVE_TIME - 1.5 + 0.1)
	check(not bt2.disabled, "bot: revived in place")
	_gone(bt2)
	medic.queue_free()
	_run(DT)


# --- F ---------------------------------------------------------------------------------------------------------------

func _depot_flag_wipe() -> void:
	var pt := _pilot("f1", Vector3(1200, 0, 0), {"side_l": "laser", "back": "repair_drone"})
	_down(pt)
	var eff := MissionDepots.apply_core_to(pt, null)
	check(not bool(eff.get("applied", false)), "a downed mech gets no power core")
	pt.respawn_held = true
	_run(DownedRules.RESPAWN_HOLD + 0.1)
	check(pt.redeploying, "redeploying")
	eff = MissionDepots.apply_core_to(pt, null)
	check(not bool(eff.get("applied", false)), "a redeploying mech gets no power core")
	_gone(pt)
	# The flag: only a standing mech raises it.
	var sec := SectionPlan.make({"seed": 21.0})
	var mp := MissionPlan.new()
	mp.deck_count = 1
	mp.objectives.append({"id": "flag", "type": "flag", "deck": 0, "role": "primary", "site": {"x": 0.0, "s": 50.0},
		"radius": 14.0, "needs": [], "params": {"hold": 20.0}})
	var rules := MissionRules.make(sec, {"plan": mp})
	for i in 6:
		rules.evaluate({"t": float(i), "enemies": [0], "crew": [{"peer": 1, "downed": true, "redeploying": false, "deck": 0,
			"x": 0.0, "s": 50.0}]})
	var objs: Dictionary = rules.state().get("objs", {})
	near(float((objs.get("flag", ["", 0.0]) as Array)[1]), 0.0, 1e-6, "a downed mech in the flag zone raises nothing")
	for i in range(6, 10):
		rules.evaluate({"t": float(i), "enemies": [0], "crew": [{"peer": 1, "downed": false, "deck": 0, "x": 0.0, "s": 50.0}]})
	objs = rules.state().get("objs", {})
	check(float((objs.get("flag", ["", 0.0]) as Array)[1]) > 1.0, "a standing one does")
	# wipe
	var crew_down := [{"peer": 1, "downed": true, "deck": 0, "x": 0.0, "s": 0.0},
		{"peer": -1, "downed": true, "deck": 0, "x": 5.0, "s": 0.0}]
	var crew_redeploy := [{"peer": 1, "downed": true, "deck": 0, "x": 0.0, "s": 0.0},
		{"peer": -1, "downed": true, "redeploying": true, "deck": 0, "x": 5.0, "s": 0.0}]
	var off := MissionRules.make(sec, {"plan": mp})
	var on := MissionRules.make(sec, {"plan": mp, "wipe": true})
	var on2 := MissionRules.make(sec, {"plan": mp, "wipe": true})
	for i in 4:
		off.evaluate({"t": float(i), "enemies": [3, 3, 3], "crew": crew_down})
		on.evaluate({"t": float(i), "enemies": [3, 3, 3], "crew": crew_down})
		on2.evaluate({"t": float(i), "enemies": [3, 3, 3], "crew": crew_redeploy})
	eq(off.outcome, "", "wipe off: the whole crew down never loses")
	eq(on.outcome, "lost", "wipe on: everyone down, nobody redeploying: lost")
	eq(on2.outcome, "", "wipe on: a pilot redeploying keeps the mission going")


# --- G ---------------------------------------------------------------------------------------------------------------

func _recs(out: Array, tag: String) -> Array:
	var got: Array = []
	for l: String in out:
		var parts := l.split(" ")
		if parts.size() < 3 or parts[2] != tag:
			continue
		var d := {}
		for i in range(3, parts.size()):
			var kv := parts[i].split("=", true, 1)
			if kv.size() == 2:
				d[kv[0]] = kv[1]
		got.append(d)
	return got


func _log() -> void:
	var at := Vector3(1400, 0, 0)
	var pt := _pilot("g1", at + Vector3(6, 0, 0))
	var medic_pt := _pilot("gmed", at)
	var out: Array = []
	var med_out: Array = []
	var cl := CombatLog.new()
	add_child(cl)
	cl.bind(world, pt)
	cl.sink = func(l: String) -> void: out.append(l)
	cl.help_fn = func() -> Dictionary: return {"reviver": true, "dist": 6.0}
	cl.start()
	var ml := CombatLog.new()
	add_child(ml)
	ml.bind(world, medic_pt)
	ml.sink = func(l: String) -> void: med_out.append(l)
	ml.start()
	var steps := func(s: float) -> void:
		for i in roundi(s / DT):
			world.advance(DT)
			cl.step(DT)
			ml.step(DT)
	_down(pt)
	check(cl.threat.intensity.value >= PilotIntensity.DISABLED - 1e-3, "intensity +40 on the down")
	steps.call(0.2)
	var i0 := cl.threat.intensity.value
	var downs := _recs(out, "down")
	eq(downs.size(), 1, "one down line")
	var help := _recs(out, "help")
	if eq(help.size(), 1, "one help line"):
		eq(help[0].get("reviver", ""), "1", "help: a reviver is available")
		eq(help[0].get("dist", ""), "6.0", "help: nearest reviver distance")
	var medic := _medic("gmed_n", at)
	var d := _launch("gmed", medic)
	steps.call(d.rise_time() + DownedRules.REVIVE_TIME + 0.2)
	check(not pt.disabled, "revived (log case)")
	check(cl.threat.intensity.value <= i0 + 1e-3, "the revive adds no intensity (+40 once per down)")
	var rv := _recs(out, "revive")
	if eq(rv.size(), 1, "one revive line"):
		eq(rv[0].get("by", ""), "gmed", "revive by the medic")
		check(float(rv[0].get("down_s", "0")) > 4.0, "revive: time down %s" % rv[0].get("down_s", ""))
	eq(_recs(out, "respawn").size(), 0, "a revive is not a respawn")
	# Down again (out of the drone's reach), hold to respawn.
	steps.call(DownedRules.REVIVE_INVULN + 0.1)
	pt.position = at + Vector3(60, 0, 0)
	_down(pt)
	steps.call(0.2)
	pt.respawn_held = true
	steps.call(DownedRules.RESPAWN_HOLD + 0.05)
	pt.respawn_held = false
	steps.call(DownedRules.RESPAWN_PENALTY + 0.2)
	check(not pt.disabled, "respawned (log case)")
	var rs := _recs(out, "respawn")
	if eq(rs.size(), 1, "one respawn line"):
		eq(rs[0].get("hold", ""), "1", "respawn: by the hold")
		eq(rs[0].get("tot", ""), "100", "respawn: tot=100 (R2.12: back at full structure)")
		check(float(rs[0].get("down_s", "0")) >= DownedRules.RESPAWN_HOLD + DownedRules.RESPAWN_PENALTY - 0.1,
			"respawn: time down %s" % rs[0].get("down_s", ""))
	cl.finish("won", "test")
	ml.finish("won", "test")
	var ends := _recs(out, "end")
	if eq(ends.size(), 1, "end line"):
		var e: Dictionary = ends[0]
		eq(e.get("deaths", ""), "1", "deaths: the respawn only (the revived down is not a death)")
		eq(e.get("respawns", ""), "1", "respawns")
		eq(e.get("downs", ""), "2", "downs")
		eq(e.get("revives", ""), "1", "revives received")
		check(float(e.get("down_s", "0")) > DownedRules.REVIVE_TIME + DownedRules.RESPAWN_HOLD + DownedRules.RESPAWN_PENALTY,
			"total time down %s" % e.get("down_s", ""))
	var mends := _recs(med_out, "end")
	if eq(mends.size(), 1, "the medic's end line"):
		eq(mends[0].get("revives_given", ""), "1", "the medic's log counts the revive it gave")
	cl.queue_free()
	ml.queue_free()
	medic.queue_free()
	_gone(pt)
	_gone(medic_pt)
	_run(DT)


## G2 (R2.9): a self-revive in the combat log: `revive by=self`, the down is not a death, no revive given.
func _self_log() -> void:
	var at := Vector3(1600, 0, 0)
	var pt := _pilot("g2", at)
	var node := _medic("g2_n", at)
	world.set_anchor("g2", func() -> Node3D: return node)
	var out: Array = []
	var cl := CombatLog.new()
	add_child(cl)
	cl.bind(world, pt)
	cl.sink = func(l: String) -> void: out.append(l)
	cl.start()
	_down(pt)
	var d := world.launch_drone({"shooter": "g2", "peer": 1, "hardpoint": "back", "weapon": "repair_drone", "t": world.now,
		"self": true})
	if check(d != null, "G2: self-revive drone launched"):
		for i in roundi((d.rise_time() + d.self_revive_time() + 0.5) / DT):
			world.advance(DT)
			cl.step(DT)
		check(not pt.disabled, "G2: self-revived")
		var rv := _recs(out, "revive")
		if eq(rv.size(), 1, "G2: one revive line"):
			eq(rv[0].get("by", ""), "self", "G2: revive by=self")
	cl.finish("won", "test")
	var ends := _recs(out, "end")
	if eq(ends.size(), 1, "G2: end line"):
		eq(ends[0].get("deaths", ""), "0", "G2: a self-revive is not a death")
		eq(ends[0].get("revives", ""), "1", "G2: it counts as a revive received")
		eq(ends[0].get("revives_given", ""), "0", "G2: and never as a revive given")
	cl.queue_free()
	node.queue_free()
	_gone(pt)
	_run(DT)


# --- H ---------------------------------------------------------------------------------------------------------------

func _drive() -> void:
	var td := (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	td.city_mode = MissionScene.MODE_STACK
	td.seed_value = SEED
	add_child(td)
	await frames(4)
	var dc := td.downed
	if not check(dc != null and td.stack != null, "the drive has DownedCrew and a stack"):
		td.queue_free()
		return
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	td.combat.squad.clear_enemies()
	td.combat.enemies.clear()
	check(InputMap.has_action(DownedRules.ACTION), "the respawn action exists")
	var pt := td.combat.player_target
	var hud := td.get_node_or_null("MechHud") as MechHud
	check(hud != null and hud.mission_hud != null and hud.mission_hud.downed_source.is_valid(), "the HUD reads DownedCrew")
	# Deck 1: put the mech at deck 1's arrival point + 30 m, down it, hold, respawn near the arrival point.
	var sec := td.stack.section
	var arr: Dictionary = SectionEncounters.arrival(sec, 1)
	var at := td.stack.from_deck_arc(1, float(arr["x"]), float(arr["s"]) + 30.0)
	td.mech.global_position = at + td.stack.deck_ring(1).up_at(at) * 1.0
	td.mech.velocity = Vector3.ZERO
	await frames(30)
	eq(td.stack.deck_at(td.mech.global_position), 1, "the mech stands on deck 1")
	_down(pt)
	var hs := dc.hud_state()
	var pr: Dictionary = hs.get("prompt", {})
	eq(str(pr.get("title", "")), "DOWN", "the prompt: DOWN")
	eq(str(pr.get("help", "")), "No repair drone in the crew", "solo: no repair drone in the crew")
	eq(str(pr.get("hint", "")), "Hold SPACE to respawn", "the hold hint")
	var p0 := td.mech.global_position
	td.mech.move_input = Vector2(0, 1)
	td.mech.running = true
	await frames(30)
	check(td.mech.global_position.distance_to(p0) < 0.5, "a downed mech can't move (%.2f m)" % td.mech.global_position.distance_to(p0))
	check(dc.beacons.has(dc.local_id()), "the wreck carries the distress beacon")
	pt.respawn_held = true
	await frames(int(DownedRules.RESPAWN_HOLD * 60.0) + 10)
	pt.respawn_held = false
	check(pt.redeploying, "redeploying after the hold")
	eq(str((dc.hud_state()["prompt"] as Dictionary).get("title", "")), "REDEPLOYING", "the prompt: REDEPLOYING")
	check(not dc.beacons.has(dc.local_id()), "no beacon while redeploying")
	await frames(int(DownedRules.RESPAWN_PENALTY * 60.0) + 10)
	check(not pt.disabled, "respawned")
	if check(not dc.placed.is_empty(), "placed by DownedCrew"):
		var pl: Array = dc.placed[-1]
		eq(int(pl[1]), 1, "respawned on deck 1 (the deck it went down on, solo)")
		var target := td.stack.from_deck_arc(1, float(arr["x"]), float(arr["s"]))
		var dist := (pl[2] as Transform3D).origin.distance_to(target)
		check(dist < 40.0, "at deck 1's arrival point (%.1f m from it)" % dist)
	for c: String in pt.hp:
		near(float(pt.hp[c]), float(pt.max_hp[c]) * DownedRules.RESPAWN_STRUCTURE, 0.01, "drive respawn: %s at full (R2.12)" % c)
	# R2.9 prompt: down with a self-revive drone out (the record the rack sends as its mech goes down): the help line says
	# so, the hold hint stays, and holding SPACE still redeploys (the drone dies with the redeploy), at full.
	var cw := td.combat.world
	var rk0 := td.combat.rack
	await frames(5)
	_down(pt)
	var sd := cw.launch_drone({"shooter": pt.target_id, "peer": rk0.peer, "hardpoint": "back", "weapon": "repair_drone",
		"t": cw.now, "self": true})
	await frames(3)
	if check(sd != null and dc.self_reviving(dc.local_id()), "R2.9: DownedCrew sees the self-revive"):
		var pr2: Dictionary = dc.hud_state().get("prompt", {})
		eq(str(pr2.get("help", "")), DownedCrew.SELF_HELP, "R2.9: the prompt: Your repair drone is reviving you")
		eq(str(pr2.get("hint", "")), "Hold SPACE to respawn", "R2.9: the hold hint stays")
		var dl := dc.downed_crew()
		check(dl.size() == 1 and bool((dl[0] as Dictionary).get("self_revive", false)), "R2.9: downed_crew marks the wreck self_revive")
	pt.respawn_held = true
	await frames(int(DownedRules.RESPAWN_HOLD * 60.0) + 10)
	pt.respawn_held = false
	check(pt.redeploying, "R2.9: holding SPACE still redeploys during a self-revive")
	await frames(int(DownedRules.RESPAWN_PENALTY * 60.0) + 10)
	check(not pt.disabled, "R2.9: back after the redeploy")
	for c: String in pt.hp:
		near(float(pt.hp[c]), float(pt.max_hp[c]), 0.01, "R2.9 redeploy over a self-revive: %s at full" % c)
	# Entry deck: the own spawn slot (the old point). R2.12: before going down a weapon's hardpoint is destroyed, every
	# limited-ammo weapon is emptied, the drone charges spent, the mech overheated into a shutdown; the redeploy brings
	# it back FULL: every component at max, the destroyed weapon usable (it can be selected), ammo and charges full, cold.
	td.mech.move_input = Vector2.ZERO
	td.mech.running = false
	td.respawn()
	await frames(10)
	var rack := td.combat.rack
	var broke := -1
	var dry: Array[int] = []
	for i in rack.slot_count():
		if rack.weapons[i] == "" or rack.charges[i] >= 0 or rack.mounts[i] == null:
			continue
		if rack.ammo_max[i] >= 0:
			dry.append(i)
			(rack.mounts[i] as WeaponMount).ammo = 0
		elif broke < 0:
			broke = i
	if broke < 0 and not dry.is_empty():
		broke = dry[0]
	for i in rack.slot_count():
		if rack.charges[i] >= 0:
			rack.charges[i] = 0
	check(not dry.is_empty(), "R2.12: the drive's loadout has a limited-ammo weapon (%s)" % str(rack.weapons))
	if check(broke >= 0, "R2.12: a weapon slot to destroy"):
		pt.apply_damage(1000.0, rack.hardpoints[broke], "test")
		check(not rack.usable(broke + 1), "R2.12: its hardpoint destroyed, the weapon is unusable")
	for i: int in dry:
		check(not rack.usable(i + 1), "R2.12: %s emptied: unusable" % rack.weapons[i])
	td.mech.add_heat(1000.0)
	check(td.mech.shutdown, "R2.12: overheated into a shutdown before going down")
	_down(pt)
	pt.respawn_held = true
	await frames(int(DownedRules.RESPAWN_HOLD * 60.0) + 10)
	pt.respawn_held = false
	await frames(int(DownedRules.RESPAWN_PENALTY * 60.0) + 10)
	if check(not pt.disabled and dc.placed.size() >= 2, "respawned again"):
		var pl2: Array = dc.placed[-1]
		near((pl2[2] as Transform3D).origin.distance_to(td.spawn_xf.origin), 0.0, 0.01, "on the entry deck: the own spawn slot")
	for c: String in pt.hp:
		near(float(pt.hp[c]), float(pt.max_hp[c]), 0.01, "R2.12 redeploy: %s at full" % c)
	near(td.mech.heat, 0.0, 1.0, "R2.12 redeploy: heat cleared")
	check(not td.mech.shutdown, "R2.12 redeploy: shutdown cleared")
	if broke >= 0:
		check(rack.usable(broke + 1), "R2.12 redeploy: the destroyed %s's weapon works again" % rack.hardpoints[broke])
		rack.set_enabled(broke + 1, false)
		rack.set_enabled(broke + 1, true)
		check(rack.enabled[broke], "R2.12 redeploy: and can be selected")
	for i: int in dry:
		eq((rack.mounts[i] as WeaponMount).ammo, rack.ammo_max[i], "R2.12 redeploy: %s refilled" % rack.weapons[i])
		check(rack.usable(i + 1), "R2.12 redeploy: %s usable" % rack.weapons[i])
	for i in rack.slot_count():
		if rack.charges[i] >= 0:
			eq(rack.charges[i], int(MechCatalog.weapon(rack.weapons[i]).get("charges", rack.charges[i])),
				"R2.12 redeploy: %s charges full" % rack.weapons[i])
	td.queue_free()
	await frames(2)
	await _drive_defend()
	await _safe_spots()


## H2. Seed 7 in plan mode (deck 1: the defend d1_p): a respawn from deck 1 lands at deck 1's arrival point while the
## defend is not active, and 60-90 m from the defend site (out of its zone, on clear ground, facing it) while it is.
## Prints the walk from the arrival point to the relay (the road route) for the report.
func _drive_defend() -> void:
	var td := (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	td.city_mode = MissionScene.MODE_STACK
	td.seed_value = SEED
	add_child(td)
	await frames(4)
	var dc := td.downed
	if not check(dc != null and td.mission != null and td.mission.rules != null and td.mission.rules.plan != null,
			"seed 7 plan mode with DownedCrew"):
		td.queue_free()
		return
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	td.combat.squad.clear_enemies()
	td.combat.enemies.clear()
	var rules := td.mission.rules
	var o := {}
	for ob: Dictionary in rules.objectives:
		if int(ob["deck"]) == 1 and str(ob["type"]) == "defend" and str(ob["role"]) == "primary":
			o = ob
	if not check(not o.is_empty(), "seed 7 has a primary defend on deck 1"):
		td.queue_free()
		return
	var sec := td.stack.section
	var arr: Dictionary = SectionEncounters.arrival(sec, 1)
	var site := Vector2(float(o["site"]["x"]), float(o["site"]["s"]))
	var at := td.stack.from_deck_arc(1, float(arr["x"]), float(arr["s"]) + 20.0)
	td.mech.global_position = at + td.stack.deck_ring(1).up_at(at) * 1.0
	td.mech.velocity = Vector3.ZERO
	await frames(20)
	eq(td.stack.deck_at(td.mech.global_position), 1, "defend case: the mech stands on deck 1")
	var me := dc.local_id()
	rules.apply_state({"objs": {str(o["id"]): ["known", 0.0, 2.0]}})
	dc.redeploy_transform(me, td.mech)
	eq(dc.last_kind, "arrival", "defend not active: the deck's arrival point")
	rules.apply_state({"objs": {str(o["id"]): ["active", 0.0, 2.0]}})
	check(not dc.active_objective(1).is_empty(), "the active defend is seen")
	var xf := dc.redeploy_transform(me, td.mech)
	eq(dc.last_kind, "objective", "defend active: next to the objective")
	var a := td.stack.to_deck_arc(xf.origin)
	var d := Vector2(float(a["x"]), float(a["s"])).distance_to(site)
	check(d >= 60.0 - DownedRules.RESPAWN_SNAP_REACH - 3.5 and d <= 90.0 + DownedRules.RESPAWN_SNAP_REACH + 3.5,
		"defend active: %.1f m from the site (60-90 m, snap included)" % d)
	check(d > float(o.get("radius", 0.0)), "out of the defend zone (radius %.0f)" % float(o.get("radius", 0.0)))
	eq(int(a["deck"]), 1, "on deck 1")
	var face := td.stack.from_deck_arc(1, site.x, site.y) - xf.origin
	check((-xf.basis.z).dot(face.normalized()) > 0.8, "facing the site")
	# The walk the old point cost: arrival -> relay along the road graph (the enemy squad's arc path, as the director).
	var from := Vector2(float(arr["x"]), float(arr["s"]))
	var path: Array = td.combat.squad.nav.find_arc_path(from, site, 1)
	var route := -1.0
	if not path.is_empty():
		route = from.distance_to(path[0])
		for i in range(1, path.size()):
			route += (path[i - 1] as Vector2).distance_to(path[i])
		route += (path[path.size() - 1] as Vector2).distance_to(site)
	print("[downed] seed 7 deck 1: arrival -> defend site straight %.1f m, road route %.1f m (%.0f s walking at %.0f m/s, %.0f s running at %.0f m/s); respawn spot %.1f m from the site" % [
		from.distance_to(site), route, route / td.mech.walk_speed, td.mech.walk_speed, route / td.mech.run_speed,
		td.mech.run_speed, d])
	td.queue_free()
	await frames(2)


# --- I ---------------------------------------------------------------------------------------------------------------

## For every seed in SAFE_SEEDS, every deck, every seat (0-3), both chassis: DownedCrew.arrival_spot is a safe standing
## spot for the widest capsule on THAT deck (DownedCrew.spot_problems: off lift platforms / floor openings / cuts / ramps,
## free on the fit mask, the widest capsule clear of static collision, floor under its whole footprint), the same for both
## chassis, two seats never closer than SEAT_APART; the objective-near spot of every defend / hold (60-90 m) passes the same
## criteria. Then a mech of each chassis dropped on every spot at once is still on that deck 5 s later (and has not slid
## off it). Seed 6 deck 1 (a lift arrival) is checked by name.
func _safe_spots() -> void:
	var bad := 0
	var n_spots := 0
	var kinds := {}
	for sd in SAFE_SEEDS:
		var td := (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
		td.city_mode = MissionScene.MODE_STACK
		td.seed_value = sd
		add_child(td)
		await frames(4)
		var dc := td.downed
		if not check(dc != null and td.stack != null and td.stack.section != null, "seed %d: a stack drive with DownedCrew" % sd):
			td.queue_free()
			await frames(2)
			continue
		td.drive_override = true
		td.mech.move_input = Vector2.ZERO
		td.combat.squad.clear_enemies()
		td.combat.enemies.clear()
		var sec := td.stack.section
		var space := td.get_world_3d().direct_space_state
		var bw := MechSpawn.make("pickle", "bulwark", {}, -7, "red")
		bw.ring = td.city.ring
		td.add_child(bw)
		bw.global_position = td.stack.from_deck_arc(0, 0.0, 0.0, 300.0)
		await frames(2)
		var spots: Array = []   # [tag, deck, Transform3D]
		for k in sec.deck_count:
			var arr := SectionEncounters.arrival(sec, k)
			kinds[str(arr["kind"])] = int(kinds.get(str(arr["kind"]), 0)) + 1
			var mine: Array[Vector2] = []
			for seat in 4:
				var tag := "seed %d deck %d (%s arrival) seat %d" % [sd, k, str(arr["kind"]), seat]
				var got: Dictionary = dc.arrival_spot(k, seat, td.mech)
				if not check(got.has("xf"), tag + ": a respawn spot"):
					bad += 1
					continue
				var got_b: Dictionary = dc.arrival_spot(k, seat, bw)
				check(got_b.has("xf") and (got_b["xf"] as Transform3D).origin.is_equal_approx((got["xf"] as Transform3D).origin),
					tag + ": the same spot for a Bulwark")
				var xf: Transform3D = got["xf"]
				var why := DownedCrew.spot_problems(td.stack, k, xf.origin, space)
				n_spots += 1
				if not check(why == "", tag + ": a safe spot for the widest capsule (%s)" % why):
					bad += 1
				var a := td.stack.to_deck_arc(xf.origin)
				var p := Vector2(float(a["x"]), float(a["s"]))
				for q in mine:
					check(q.distance_to(p) >= DownedCrew.SEAT_APART - 0.01, tag + ": %.1f m from another seat's spot" % q.distance_to(p))
				mine.append(p)
				if sd == 6 and k == 1:
					eq(str(arr["kind"]), "lift", "seed 6 deck 1's arrival is a lift")
					for ci in sec.connectors.size():
						if str(sec.connectors[ci]["kind"]) == "lift":
							var lr := sec.connector_rect(ci, 1).grow(CityPlan.MECH_R_MAX)
							check(not lr.has_point(p), tag + ": off lift %d's platform by the widest capsule (%s)" % [ci, p])
				spots.append([tag, k, xf])
			# The objective-near spot (a defend / hold active on this deck).
			var objs: Array = td.mission.rules.objectives if td.mission != null and td.mission.rules != null else []
			for o: Dictionary in objs:
				if int(o.get("deck", -1)) != k or not str(o.get("type", "")) in ["defend", "hold"]:
					continue
				var tag := "seed %d deck %d %s (%s) objective-near" % [sd, k, str(o["id"]), str(o["type"])]
				var nr: Dictionary = dc.near_objective(k, o, td.mech)
				if not check(nr.has("xf"), tag + ": a spot 60-90 m from the objective"):
					bad += 1
					continue
				var xf2: Transform3D = nr["xf"]
				var why2 := DownedCrew.spot_problems(td.stack, k, xf2.origin, space)
				n_spots += 1
				if not check(why2 == "", tag + ": a safe spot for the widest capsule (%s)" % why2):
					bad += 1
				spots.append([tag, k, xf2])
		bw.queue_free()
		# Drop tests: every spot at once, one chassis at a time (seats are SEAT_APART apart; an objective-near spot may sit
		# by an arrival spot, so those go in a second wave).
		for ch: String in ["strider", "bulwark"]:
			for wave in 2:
				var live: Array = []
				for sp: Array in spots:
					var is_obj := str(sp[0]).contains("objective-near")
					if is_obj != (wave == 1):
						continue
					var mm := MechSpawn.make("pickle", ch, {}, -20 - live.size(), "blue")
					mm.ring = td.city.ring
					td.add_child(mm)
					mm.global_transform = sp[2]
					mm.velocity = Vector3.ZERO
					live.append([sp, mm])
				if live.is_empty():
					continue
				Engine.time_scale = 4.0
				for i in 300:
					await get_tree().physics_frame
				Engine.time_scale = 1.0
				for l: Array in live:
					var mm: MechController = l[1]
					var sp: Array = l[0]
					var k2 := td.stack.deck_at(mm.global_position)
					var moved := mm.global_position.distance_to((sp[2] as Transform3D).origin)
					if not check(k2 == int(sp[1]) and moved < 3.0, "%s, %s: still on deck %d after 5 s (deck %d, moved %.1f m)" % [
							sp[0], ch, int(sp[1]), k2, moved]):
						bad += 1
					mm.queue_free()
				await frames(2)
		td.queue_free()
		await frames(3)
	print("[downed] safe respawn spots: %d spots over seeds %s (arrival kinds %s), %d bad" % [n_spots, SAFE_SEEDS, kinds, bad])


## H3 (R2.9 end to end, the real path: the drive's own WeaponRack, DownedCrew, CombatLog): a solo Strider with a charged
## repair drone on its back goes down alone and gets up by itself, once (prompt "Your repair drone is reviving you",
## `revive by=self`); down again with no charge left: no self-revive ("No repair drone in the crew", still down after
## 6 s), holding SPACE redeploys at full with the drone's charges refilled (R2.12); down a third time (charged again):
## holding SPACE during the self-revive still redeploys, at full.
const SELF_SETTINGS := "user://test_downed_self_settings.cfg"


func _drive_self_revive() -> void:
	var saved := GameSettings.path
	GameSettings.path = SELF_SETTINGS
	var st := GameSettings.DEFAULTS.duplicate(true)
	st["chassis"] = "strider"
	st["loadout"] = {"side_l": "laser", "side_r": "autocannon", "shoulder_l": "rockets", "shoulder_r": "", "back": "repair_drone"}
	GameSettings.save_settings(st)
	var td := (load(MissionScene.SCENE) as PackedScene).instantiate() as MissionScene
	td.city_mode = MissionScene.MODE_STACK
	td.seed_value = SEED
	add_child(td)
	await frames(4)
	GameSettings.path = saved
	var dc := td.downed
	var rack := td.combat.rack
	var pt := td.combat.player_target
	var slot := rack.weapons.find("repair_drone")
	if not check(dc != null and slot >= 0, "H3: the drive's mech carries a repair drone (%s)" % str(rack.weapons)):
		td.queue_free()
		await frames(2)
		return
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	td.combat.squad.clear_enemies()
	td.combat.enemies.clear()
	var out: Array = []
	var cl := td.get_node_or_null("CombatLog") as CombatLog
	if cl != null:
		cl.sink = func(l: String) -> void: out.append(l)
	var revs := []
	pt.player_revived.connect(func(by: String, _t: float) -> void: revs.append(by))
	await frames(10)
	var full := rack.charges[slot]
	check(full > 0, "H3: charged (%d)" % full)
	# 1. Alone, charged: up by itself, once.
	_down(pt)
	var pr: Dictionary = dc.hud_state().get("prompt", {})
	eq(str(pr.get("help", "")), DownedCrew.SELF_HELP, "H3: the prompt right at the down (the launch is on its way)")
	await frames(3)
	check(dc.self_reviving(dc.local_id()), "H3: its own drone launched (self_reviving)")
	eq(rack.charges[slot], full - 1, "H3: one charge spent")
	pr = dc.hud_state().get("prompt", {})
	eq(str(pr.get("help", "")), DownedCrew.SELF_HELP, "H3: Your repair drone is reviving you")
	eq(str(pr.get("hint", "")), "Hold SPACE to respawn", "H3: the hold hint stays")
	var up := await _wait_for(func() -> bool: return not pt.disabled, 8.0)
	check(up, "H3: stood up by its own drone")
	if eq(revs.size(), 1, "H3: revived once"):
		eq(str(revs[0]), pt.target_id, "H3: by its own id")
	if cl != null:
		var rv := _recs(out, "revive")
		check(not rv.is_empty() and str(rv[-1].get("by", "")) == "self", "H3: the log says revive by=self (%s)" % str(rv))
	# 2. Down again with no charge left: no self-revive; SPACE redeploys at full, charges refilled.
	await frames(int(DownedRules.REVIVE_INVULN * 60.0) + 10)
	rack.charges[slot] = 0
	_down(pt)
	await frames(10)
	check(pt.disabled and not dc.self_reviving(dc.local_id()), "H3: no charge: no self-revive")
	eq(str((dc.hud_state().get("prompt", {}) as Dictionary).get("help", "")), "No repair drone in the crew", "H3: no charge: no help line")
	await frames(360)
	check(pt.disabled, "H3: still down after 6 s")
	eq(revs.size(), 1, "H3: no second revive")
	pt.respawn_held = true
	await frames(int(DownedRules.RESPAWN_HOLD * 60.0) + 10)
	pt.respawn_held = false
	await frames(int(DownedRules.RESPAWN_PENALTY * 60.0) + 10)
	check(not pt.disabled, "H3: redeployed")
	for c: String in pt.hp:
		near(float(pt.hp[c]), float(pt.max_hp[c]), 0.01, "H3 redeploy: %s at full" % c)
	eq(rack.charges[slot], full, "H3 redeploy: the drone's charges refilled (R2.12)")
	# 3. Charged again: holding SPACE during the self-revive still redeploys, at full.
	await frames(10)
	_down(pt)
	pt.respawn_held = true
	await frames(5)
	check(dc.self_reviving(dc.local_id()), "H3: self-reviving again")
	await frames(int(DownedRules.RESPAWN_HOLD * 60.0) + 10)
	pt.respawn_held = false
	check(pt.redeploying, "H3: holding SPACE during a self-revive redeploys")
	check(not dc.self_reviving(dc.local_id()), "H3: the self-revive drone died with the redeploy")
	await frames(int(DownedRules.RESPAWN_PENALTY * 60.0) + 10)
	check(not pt.disabled, "H3: back after the redeploy")
	eq(revs.size(), 1, "H3: that was a redeploy, not a revive")
	for c: String in pt.hp:
		near(float(pt.hp[c]), float(pt.max_hp[c]), 0.01, "H3 redeploy over a self-revive: %s at full" % c)
	td.queue_free()
	await frames(2)


func _wait_for(f: Callable, s: float) -> bool:
	for i in ceili(s * 60.0):
		if f.call():
			return true
		await get_tree().physics_frame
	return f.call()
