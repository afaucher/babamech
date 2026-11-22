extends "res://tests/net_coop_case.gd"
## VISUAL co-op: two game processes over ENet on localhost (a host and a client), each a REAL rendered 1600x900 window on
## the hidden desktop (`.\test_runner.ps1 -Visual -TestName test_visual_coop`: VISUAL + PEERS = N windowed processes under
## one GPU lock; docs/testing.md "Visual tests"). The host launches a stack mission (Session.start_mission, the same load
## and barrier as the W9 e2e, net_coop_case.gd, whose helpers this reuses; the host idles its enemies' AI), both walk
## forward at one shared-clock moment, then at shared-clock moments each machine aims its own chase camera (test code:
## look_dir / pitch, smoothing off) and grabs shots (ShotCheck.grab):
##   coop_<role>_1   the teammate standing, after the walk
##   coop_<role>_2   the teammate mid-fire (every weapon held, aimed ahead and away from the other column)
##   coop_<role>_3   the same burst a little later
##   coop_<role>_4   a live enemy (with the teammate too when one look frames both)
## Every machine measures FACTS at each grab and the client reports its facts (NetTest.report); THE HOST JUDGES both
## machines with the same rules: the image is not blank; the teammate's puppet is in the camera frustum, on screen and in
## line of sight, with its pilot head node (the roster's head) on screen and its accent (MechAccent.applied = the roster's
## accent, and accent-hued pixels inside its screen box); the HUD crew panel shows exactly the teammate's card, on screen
## (LayoutCheck), with its head / accent and drawn pixels; during the fire, the teammate's shots arrived here through
## CombatNet (remote_fired) and its effects are in view at a grab; at shot 4 an enemy is alive here AND on the host, in the
## frustum, on screen and in line of sight.
## Headless (no -Visual) it prints a note and passes: nothing to see.

const VISUAL := true
const PEERS := 2
const LINKS := ["off"]

const SHOT_LEAD := 2.5             ## s between the host's command and the shared-clock grab (aiming takes a few frames)
const FIRE_HOLD := 1.6             ## s of trigger held in the fire step
const GRAB_A := 0.55               ## s into the burst: shot 2
const GRAB_B := 1.15               ## s into the burst: shot 3
const MECH_H := 8.0                ## m, the mech's visual height (MechSpawn)
const MECH_HALF_W := 4.0           ## m, half its visual width with the arm weapons out (screen boxes)
const CAM_DISTANCE := 22.0         ## m behind the pivot during the shots (the game's 16 m puts our own mech in the way)
const CHEST := 4.5                 ## m above the feet: the point the camera frames and the sight line goes to
const EDGE := 0.04                 ## fraction of the screen kept as margin for "on screen"
const ACCENT_MIN := 6              ## accent-hued samples (of 64 x 64) needed inside the teammate's box
const ENEMY_RANGE := 260.0         ## m: enemies farther than this are not tried for shot 4
const MAX_COVER := 0.12            ## the teammate's screen box may be covered this much by our own mech's

var sc: ShotCheck
var lc: LayoutCheck
var _mate := 0                     ## the teammate's peer
var _remote_seen := 0              ## the teammate's fire records CombatNet fired here during the burst


# --- Host -------------------------------------------------------------------------------------------------------

func run_host() -> void:
	net_timeout = 140.0
	if not _setup_visual():
		return
	if not check(await until(func() -> bool: return Session.roster.size() == peers, 40.0),
			"the crew gathers (%d of %d)" % [Session.roster.size(), peers]):
		return
	check(Session.start_mission(SEED), "the host launches the mission")
	if not await _load_and_go():
		return
	_mate = _clients()[0]
	check(td.stack != null, "the mission runs in the city stack")
	# Walk forward together (as W9 step c), and check each puppet stands where its owner stopped.
	var at := Session.host_time() + LEAD
	command(_mate, "walk", {"at": at})
	var mine := await _walk(at)
	if not check(await wait_reports("walk", 1, 30.0), "the client reports its walk"):
		return
	_judge_walk({Session.local_id(): mine, _mate: reported(_mate, "walk")})
	# Shot 1: the teammate.
	at = Session.host_time() + SHOT_LEAD
	command(_mate, "mate_shot", {"at": at})
	var f1 := await _mate_shot(1, at)
	if check(await wait_reports("shot1", 1, 30.0), "the client reports shot 1"):
		_judge("host", f1, Session.local_id())
		_judge("client", reported(_mate, "shot1"), _mate)
	# Shots 2 and 3: the burst.
	at = Session.host_time() + SHOT_LEAD
	command(_mate, "fire_shots", {"at": at})
	var fb := await _fire_shots(at)
	if check(await wait_reports("burst", 1, 30.0), "the client reports the burst"):
		_judge_burst("host", fb, Session.local_id())
		_judge_burst("client", reported(_mate, "burst"), _mate)
	# Shot 4: an enemy.
	await sleep(1.0)
	at = Session.host_time() + SHOT_LEAD
	command(_mate, "enemy_shot", {"at": at})
	var f4 := await _enemy_shot(4, at)
	if check(await wait_reports("shot4", 1, 30.0), "the client reports shot 4"):
		_judge("host", f4, Session.local_id())
		var r4: Dictionary = reported(_mate, "shot4")
		_judge("client", r4, _mate)
		var theirs := _enemy_by_id(str((r4.get("enemy", {}) as Dictionary).get("id", "")))
		check(theirs != null and not theirs.destroyed(), "the enemy in the client's shot (%s) is alive on the host too" %
			str((r4.get("enemy", {}) as Dictionary).get("id", "")))
		print("[coop visual] enemy framed: host %s, client %s" % [str((f4["enemy"] as Dictionary).get("id", "")),
			str((r4["enemy"] as Dictionary).get("id", ""))])
	command(_mate, "end")
	check(await wait_done(1, 20.0), "the client is done")


# --- Client -----------------------------------------------------------------------------------------------------

func run_client() -> void:
	net_timeout = 140.0
	if not _setup_visual():
		return
	var why := await connect_client()
	if not check(why == "", "welcomed (%s)" % why):
		return
	if not check(await until(func() -> bool: return not Session.mission_params().is_empty(), 40.0), "the host's launch arrives"):
		return
	if not await _load_and_go():
		return
	_mate = 1
	while true:
		var cmd := await wait_command(60.0)
		match str(cmd.get("cmd", "")):
			"walk":
				report("walk", await _walk(float(cmd["at"])))
			"mate_shot":
				report("shot1", await _mate_shot(1, float(cmd["at"])))
			"fire_shots":
				report("burst", await _fire_shots(float(cmd["at"])))
			"enemy_shot":
				report("shot4", await _enemy_shot(4, float(cmd["at"])))
			"end":
				return
			_:
				check(false, "the host's next step arrives (%s)" % str(cmd))
				return


# --- Both sides: shots and facts ---------------------------------------------------------------------------------

func _setup_visual() -> bool:
	sc = ShotCheck.new(self)
	lc = LayoutCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_coop needs a renderer: run .\\test_runner.ps1 -Visual -TestName test_visual_coop")
		return false
	return true


func _shot_name(n: int) -> String:
	return "coop_%s_%d" % ["host" if is_host() else "client", n]


## Shot n of the teammate: aim, wait for the shared-clock moment, grab, measure.
func _mate_shot(n: int, at: float) -> Dictionary:
	_hold_still()
	var aimed := await _aim_mate()
	await until(func() -> bool: return Session.host_time() >= at, SHOT_LEAD + 3.0)
	var img := await sc.grab(_shot_name(n))
	var f := _facts(img, n)
	f["aimed"] = aimed
	return f


## Shots 2 and 3: the camera on the teammate, every weapon held from `at` for FIRE_HOLD (aimed ahead and away from the
## other column, as W9 step d), grabs at GRAB_A and GRAB_B into the burst. Also: own records fired, the teammate's
## records CombatNet fired here.
func _fire_shots(at: float) -> Dictionary:
	_hold_still()
	var aimed := await _aim_mate()
	var world := td.combat.world
	var net := _fire_net()
	var me := CombatWorld.local_peer()
	var own := [0]
	_remote_seen = 0
	var on_fired := func(rec: Dictionary) -> void:
		if int(rec.get("peer", 0)) == me:
			own[0] += 1
	var on_remote := func(rec: Dictionary, _e: Variant) -> void:
		if int(rec.get("peer", 0)) == _mate:
			_remote_seen += 1
	world.fired.connect(on_fired)
	if net != null:
		net.connect("remote_fired", on_remote)
	var rack := td.combat.rack
	rack.read_input = false
	rack.manual_aim = true
	await until(func() -> bool: return Session.host_time() >= at, SHOT_LEAD + 3.0)
	var m := td.mech
	var side := -1.0 if td.spawn_order.find(Session.local_id()) % 2 == 0 else 1.0
	rack.aim_point = m.global_position + m.forward() * 40.0 + m.global_basis.x * side * 25.0 + m.up() * 3.0
	rack.set_trigger(true)
	await until(func() -> bool: return Session.host_time() >= at + GRAB_A, GRAB_A + 2.0)
	var fa := _facts(await sc.grab(_shot_name(2)), 2)
	await until(func() -> bool: return Session.host_time() >= at + GRAB_B, GRAB_B + 2.0)
	var fb := _facts(await sc.grab(_shot_name(3)), 3)
	await until(func() -> bool: return Session.host_time() >= at + FIRE_HOLD, FIRE_HOLD + 2.0)
	rack.set_trigger(false)
	await until(func() -> bool: return Session.host_time() >= at + FIRE_HOLD + FIRE_SETTLE, FIRE_SETTLE + 2.0)
	world.fired.disconnect(on_fired)
	if net != null:
		net.disconnect("remote_fired", on_remote)
	fa["aimed"] = aimed
	fb["aimed"] = aimed
	return {"a": fa, "b": fb, "own_fired": own[0], "mate_remote": _remote_seen, "bridge": net != null}


## Shot n of a live enemy: the nearest enemy in sight (with the teammate in the same look when one frames both).
func _enemy_shot(n: int, at: float) -> Dictionary:
	_hold_still()
	var cands: Array[EnemyBase] = []
	for e in td.combat.squad.enemies:
		if is_instance_valid(e) and not e.destroyed() and e.global_position.distance_to(td.mech.global_position) < ENEMY_RANGE:
			cands.append(e)
	var from := td.mech.global_position
	cands.sort_custom(func(a: EnemyBase, b: EnemyBase) -> bool: return a.global_position.distance_to(from) < b.global_position.distance_to(from))
	var chosen: EnemyBase = null
	var with_mate := false
	for pass_i in 2:
		for e in cands:
			var pts: Array[Vector3] = [_enemy_point(e)]
			var subj: Array = [e]
			if pass_i == 0:
				pts.append(_mate_point())
				subj.append(_mate_mech())
			if await _aim(pts, subj, pass_i == 0):
				chosen = e
				with_mate = pass_i == 0
				break
		if chosen != null:
			break
	await until(func() -> bool: return Session.host_time() >= at, SHOT_LEAD + 6.0)
	var img := await sc.grab(_shot_name(n))
	var f := _facts(img, n, chosen)
	f["aimed"] = chosen != null
	f["enemy_with_mate"] = with_mate
	f["enemy_candidates"] = cands.size()
	return f


## The walk leaves the inputs to the test; keep the mech standing.
func _hold_still() -> void:
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	td.mech.turn_input = 0.0
	td.mech.running = false
	td.mech.thrust_input = false


func _aim_mate() -> bool:
	var pts: Array[Vector3] = [_mate_point()]
	return await _aim(pts, [_mate_mech()])


func _mate_mech() -> MechController:
	return td.mech_of(_mate)


func _mate_point() -> Vector3:
	var m := _mate_mech()
	return m.global_position + m.up() * CHEST if m != null else Vector3.ZERO


func _enemy_point(e: EnemyBase) -> Vector3:
	return e.global_position + e.up * 2.0


## Turn the local chase camera (rigid: smoothing off, boom CAM_DISTANCE) so every point is on screen and in line of sight: the look toward
## the first point, then offsets of +-12..45 deg (so our own mech does not block the view) and three pitches. With
## `quick`, fewer tries (used when also trying the teammate in the same look). True when one look works.
func _aim(points: Array[Vector3], subjects: Array, quick := false) -> bool:
	var cam := td.cam
	cam.smooth = 0.0
	cam.zoomed = false
	cam.distance = CAM_DISTANCE
	var m := td.mech
	var up := m.up()
	var d := points[0] - m.global_position
	d -= up * d.dot(up)
	if d.length() < 0.5:
		return false
	var base := d.normalized()
	if points.size() > 1:   # aim between them
		var d2 := points[1] - m.global_position
		d2 -= up * d2.dot(up)
		base = (base + d2.normalized()).normalized() if d2.length() > 0.5 else base
	var offs := [0.0, 14.0, -14.0, 24.0, -24.0] if quick else [0.0, 12.0, -12.0, 22.0, -22.0, 32.0, -32.0, 45.0, -45.0]
	for pitch: float in [-0.2, -0.32, -0.1]:
		for o: float in offs:
			cam.look_dir = base.rotated(up, deg_to_rad(o))
			cam.pitch = pitch
			await get_tree().process_frame
			await get_tree().process_frame
			var all := true
			for i in points.size():
				var subj := subjects[i] as Node
				if not (_on_screen(points[i]) and _in_sight(points[i], subj)):
					all = false
					break
				# Our own mech must not cover the subject (its collision capsule is slimmer than its look).
				var own_box := _screen_box(m)
				var cover := _cover(_screen_box(subj as MechController), own_box) if subj is MechController 					else (1.0 if own_box.grow(-own_box.size.x * 0.1).has_point(td.cam.unproject_position(points[i])) else 0.0)
				if cover > MAX_COVER:
					all = false
					break
			if all:
				return true
	return false


func _on_screen(p: Vector3) -> bool:
	var cam := td.cam
	if cam.is_position_behind(p) or not cam.is_position_in_frustum(p):
		return false
	var vs := get_viewport().get_visible_rect().size
	var s := cam.unproject_position(p)
	return Rect2(vs * EDGE, vs * (1.0 - 2.0 * EDGE)).has_point(s)


## Nothing but the subject (or something past it) is hit along the ray from the camera to p.
func _in_sight(p: Vector3, subject: Node) -> bool:
	var cam := td.cam
	var space := cam.get_world_3d().direct_space_state
	var from := cam.global_position
	var q := PhysicsRayQueryParameters3D.create(from, p)
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return true
	var col := hit["collider"] as Node
	if col != null and subject != null and (col == subject or subject.is_ancestor_of(col) or col.is_ancestor_of(subject)):
		return true
	return from.distance_to(hit["position"] as Vector3) >= from.distance_to(p) - 1.0


## What this machine shows at shot n (the host judges it): image stats, the teammate (frustum, screen, sight, box, head,
## accent), the crew panel card, the teammate's effects in view, and (`enemy`) one enemy.
func _facts(img: Image, n: int, enemy: EnemyBase = null) -> Dictionary:
	var cam := td.cam
	var vs := get_viewport().get_visible_rect().size
	var f := {"n": n, "shot": _shot_name(n), "img": [img.get_width(), img.get_height()] if img != null else [0, 0]}
	var whole := ShotCheck.stats(img, Rect2(0, 0, 1, 1)) if img != null else {"std": 0.0, "colours": 0, "mean": 0.0}
	f["blank"] = {"std": float(whole["std"]), "colours": int(whole["colours"])}
	# The teammate.
	var m := _mate_mech()
	var mate := {"exists": m != null}
	if m != null:
		var chest := _mate_point()
		var pp := m.get_node_or_null("Puppet") as MechPuppet
		var model := MechSpawn.rig_of(m).model
		var box := _screen_box(m)
		mate["puppet"] = m.puppet and pp != null and pp.peer == _mate and pp.shown != null
		mate["frustum"] = cam.is_position_in_frustum(chest) and not cam.is_position_behind(chest)
		mate["on_screen"] = _on_screen(chest)
		mate["sight"] = _in_sight(chest, m)
		mate["box"] = [box.position.x, box.position.y, box.size.x, box.size.y]
		mate["box_px"] = box.size.y
		mate["own_cover"] = _cover(box, _screen_box(td.mech))
		mate["head"] = model.head_id
		var pilot: PilotHead = model.pilot
		mate["head_node"] = pilot != null and is_instance_valid(pilot) and pilot.is_inside_tree() and pilot.is_visible_in_tree() \
			and model.find_child("Head_" + model.head_id, true, false) != null
		mate["head_on_screen"] = pilot != null and is_instance_valid(pilot) and _on_screen(pilot.global_position)
		mate["accent"] = MechAccent.applied(model)
		mate["accent_px"] = _accent_px(img, box, vs, MechAccent.color(MechAccent.applied(model)))
		# The teammate's shots / effects here, and how many are in view.
		var fx := 0
		var fx_view := 0
		for e in td.combat.world.effects:
			if is_instance_valid(e) and int(e.record.get("peer", 0)) == _mate and e.record.has("shot_index"):
				fx += 1
				if _fx_on_screen(e):
					fx_view += 1
		mate["fx"] = fx
		mate["fx_view"] = fx_view
	f["mate"] = mate
	# The crew panel.
	var hud := td.get_node_or_null("MechHud") as MechHud
	var crew := {"panel": hud != null and hud.crew_panel != null}
	if hud != null and hud.crew_panel != null:
		var cp := hud.crew_panel
		crew["visible"] = cp.is_visible_in_tree()
		crew["cards"] = cp.cards.size()
		if not cp.cards.is_empty():
			var c: CrewPanel.Card = cp.cards[0]
			var r := c.get_global_rect()
			crew["peer"] = c.peer
			crew["head"] = str(c.entry.get("head", ""))
			crew["accent"] = str(c.entry.get("accent", ""))
			crew["portrait"] = c.portrait != null
			crew["label"] = str(c.look()["label"])
			crew["on_screen"] = lc.on_screen(c, "%s: the teammate's crew card" % _shot_name(n))
			crew["rect"] = [r.position.x, r.position.y, r.size.x, r.size.y]
			var st := ShotCheck.stats(img, Rect2(r.position / vs, r.size / vs)) if img != null else {"std": 0.0, "colours": 0}
			crew["stats"] = {"std": float(st["std"]), "colours": int(st["colours"])}
	f["crew"] = crew
	if enemy != null and is_instance_valid(enemy):
		var p := _enemy_point(enemy)
		f["enemy"] = {"id": enemy.target_id, "type": enemy.enemy_type, "alive": not enemy.destroyed(),
			"frustum": cam.is_position_in_frustum(p) and not cam.is_position_behind(p), "on_screen": _on_screen(p),
			"sight": _in_sight(p, enemy), "dist": cam.global_position.distance_to(p)}
	else:
		f["enemy"] = {}
	return f


## The fraction of `box` that `cover` hides (screen rects).
static func _cover(box: Rect2, cover: Rect2) -> float:
	if box.get_area() <= 0.0:
		return 1.0
	return box.intersection(cover).get_area() / box.get_area()


## A shot effect is in view: its node or one of its visible 3D parts (a projectile's shell and trail are top level).
func _fx_on_screen(e: Node3D) -> bool:
	if _on_screen(e.global_position):
		return true
	for c in e.find_children("*", "VisualInstance3D", true, false):
		var v := c as VisualInstance3D
		if v.is_visible_in_tree() and _on_screen(v.global_position):
			return true
	return false


## A mech's box on screen (pixels): its feet and top, MECH_HALF_W to either side, projected.
func _screen_box(m: MechController) -> Rect2:
	var cam := td.cam
	if m == null:
		return Rect2()
	var up := m.up()
	var side := cam.global_basis.x
	var pts: Array[Vector2] = []
	for h: float in [0.0, MECH_H]:
		for s: float in [-MECH_HALF_W, MECH_HALF_W]:
			var p := m.global_position + up * h + side * s
			if not cam.is_position_behind(p):
				pts.append(cam.unproject_position(p))
	if pts.is_empty():
		return Rect2()
	var r := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		r = r.expand(p)
	return r.intersection(Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size))


## Samples (of 64 x 64 over the box) whose hue is the accent's: saturated, not dark, hue within 0.045.
static func _accent_px(img: Image, box: Rect2, vs: Vector2, col: Color) -> int:
	if img == null or box.size.x < 2.0 or box.size.y < 2.0:
		return 0
	var sx := img.get_width() / vs.x
	var sy := img.get_height() / vs.y
	var n := 0
	for iy in 64:
		for ix in 64:
			var x := clampi(int((box.position.x + (ix + 0.5) * box.size.x / 64.0) * sx), 0, img.get_width() - 1)
			var y := clampi(int((box.position.y + (iy + 0.5) * box.size.y / 64.0) * sy), 0, img.get_height() - 1)
			var c := img.get_pixel(x, y)
			var dh := absf(c.h - col.h)
			dh = minf(dh, 1.0 - dh)
			if c.s > 0.4 and c.v > 0.2 and dh < 0.045:
				n += 1
	return n


# --- Host: judging -----------------------------------------------------------------------------------------------

## The roster entry of `peer`.
func _entry(peer: int) -> Dictionary:
	for e: Dictionary in Session.crew():
		if int(e["peer"]) == peer:
			return e
	return {}


## One machine's facts at one shot. `viewer`: that machine's peer (its teammate is the other one).
func _judge(who: String, f: Dictionary, viewer: int) -> void:
	var shot := str(f.get("shot", "?"))
	var mate_peer := _mate if viewer == Session.local_id() else Session.local_id()
	var want: Dictionary = _entry(mate_peer)
	var b: Dictionary = f.get("blank", {})
	check(int(b.get("colours", 0)) >= 4 and (float(b.get("std", 0.0)) >= 0.02 or int(b.get("colours", 0)) >= 10),
		"%s %s: the image is not blank (luminance std %.3f, %d colours)" % [who, shot, float(b.get("std", 0.0)), int(b.get("colours", 0))])
	var mt: Dictionary = f.get("mate", {})
	var n := int(f.get("n", 0))
	var framed := n != 4 or bool(f.get("enemy_with_mate", false))
	print("[coop visual] %s %s: %s" % [who, shot, str(f)])
	if check(bool(mt.get("exists", false)), "%s %s: the teammate's mech exists here" % [who, shot]):
		check(bool(mt.get("puppet", false)), "%s %s: the teammate is a MechPuppet of peer %d with a snapshot shown" % [who, shot, mate_peer])
		check(bool(mt.get("head_node", false)), "%s %s: the teammate has its pilot head node" % [who, shot])
		eq(str(mt.get("head", "")), str(want.get("head", "")), "%s %s: the teammate's head is the roster's" % [who, shot])
		eq(str(mt.get("accent", "")), str(want.get("accent", "")), "%s %s: the teammate's accent is the roster's" % [who, shot])
		if framed:
			check(bool(f.get("aimed", false)), "%s %s: the camera found a look with the teammate in view" % [who, shot])
			check(bool(mt.get("frustum", false)), "%s %s: the teammate is in the camera frustum" % [who, shot])
			check(bool(mt.get("on_screen", false)), "%s %s: the teammate is on screen" % [who, shot])
			check(bool(mt.get("sight", false)), "%s %s: nothing hides the teammate" % [who, shot])
			check(float(mt.get("own_cover", 1.0)) <= MAX_COVER + 0.05, "%s %s: our own mech does not cover the teammate (%.0f%% of its box)" %
				[who, shot, float(mt.get("own_cover", 1.0)) * 100.0])
			check(bool(mt.get("head_on_screen", false)), "%s %s: the teammate's pilot head is on screen" % [who, shot])
			check(float(mt.get("box_px", 0.0)) >= 60.0, "%s %s: the teammate is big enough to see (%.0f px tall)" % [who, shot, float(mt.get("box_px", 0.0))])
			check(int(mt.get("accent_px", 0)) >= ACCENT_MIN, "%s %s: the teammate's accent (%s) shows in its box (%d samples)" %
				[who, shot, str(mt.get("accent", "")), int(mt.get("accent_px", 0))])
	var cr: Dictionary = f.get("crew", {})
	check(bool(cr.get("panel", false)) and bool(cr.get("visible", false)), "%s %s: the HUD crew panel shows" % [who, shot])
	eq(int(cr.get("cards", 0)), 1, "%s %s: the crew panel has one card (the teammate)" % [who, shot])
	eq(int(cr.get("peer", 0)), mate_peer, "%s %s: the card is the teammate's" % [who, shot])
	eq(str(cr.get("head", "")), str(want.get("head", "")), "%s %s: the card shows the teammate's head" % [who, shot])
	eq(str(cr.get("accent", "")), str(want.get("accent", "")), "%s %s: the card carries the teammate's accent" % [who, shot])
	check(bool(cr.get("portrait", false)), "%s %s: the card has a portrait" % [who, shot])
	check(bool(cr.get("on_screen", false)), "%s %s: the card is on screen" % [who, shot])
	var cs: Dictionary = cr.get("stats", {})
	check(int(cs.get("colours", 0)) >= 4 and (float(cs.get("std", 0.0)) >= 0.02 or int(cs.get("colours", 0)) >= 10),
		"%s %s: the card is drawn (std %.3f, %d colours)" % [who, shot, float(cs.get("std", 0.0)), int(cs.get("colours", 0))])
	if n == 4:
		var en: Dictionary = f.get("enemy", {})
		if check(not en.is_empty(), "%s %s: an enemy within %.0f m is in sight (%d candidates)" % [who, shot, ENEMY_RANGE, int(f.get("enemy_candidates", 0))]):
			check(bool(en.get("alive", false)), "%s %s: enemy %s is alive" % [who, shot, str(en.get("id", ""))])
			check(bool(en.get("frustum", false)), "%s %s: enemy %s is in the frustum" % [who, shot, str(en.get("id", ""))])
			check(bool(en.get("on_screen", false)), "%s %s: enemy %s is on screen" % [who, shot, str(en.get("id", ""))])
			check(bool(en.get("sight", false)), "%s %s: nothing hides enemy %s" % [who, shot, str(en.get("id", ""))])


## One machine's burst: both grabs judged as shots, its own mech fired, the teammate's records arrived here, and the
## teammate's effects were in view at a grab.
func _judge_burst(who: String, r: Dictionary, viewer: int) -> void:
	var fa: Dictionary = r.get("a", {})
	var fb: Dictionary = r.get("b", {})
	_judge(who, fa, viewer)
	_judge(who, fb, viewer)
	print("[coop visual] %s burst: own %d records, teammate's records fired here %d, teammate fx at grabs %d/%d (in view %d/%d)" %
		[who, int(r.get("own_fired", 0)), int(r.get("mate_remote", 0)), int((fa.get("mate", {}) as Dictionary).get("fx", 0)),
		int((fb.get("mate", {}) as Dictionary).get("fx", 0)), int((fa.get("mate", {}) as Dictionary).get("fx_view", 0)),
		int((fb.get("mate", {}) as Dictionary).get("fx_view", 0))])
	check(bool(r.get("bridge", false)), "%s: the crew mission has the fire-record bridge (CombatNet)" % who)
	check(int(r.get("own_fired", 0)) > 0, "%s: its own mech fired" % who)
	check(int(r.get("mate_remote", 0)) > 0, "%s: the teammate's shots arrived and fired here (%d records)" % [who, int(r.get("mate_remote", 0))])
	var fx := int((fa.get("mate", {}) as Dictionary).get("fx", 0)) + int((fb.get("mate", {}) as Dictionary).get("fx", 0))
	var fxv := int((fa.get("mate", {}) as Dictionary).get("fx_view", 0)) + int((fb.get("mate", {}) as Dictionary).get("fx_view", 0))
	check(fx > 0, "%s: the teammate's shot effects exist here at a grab (%d)" % [who, fx])
	check(fxv > 0, "%s: the teammate's shot effects are in view at a grab (%d)" % [who, fxv])
