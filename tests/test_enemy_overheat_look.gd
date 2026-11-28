extends TestCase
## The diegetic enemy overheat (R2.26 / R2.27, docs/design/enemy-ai-structure.md "Overheat look"), every enemy type on
## the host: the fins' glow follows the heat fraction (monotonic, peak at the cap), shutdown darkens the optics and sets
## the slump (sag / droop / flier wobble) on the visual pivots only (hit spheres unchanged), steam vents, the reboot
## brings the lights and the body back, the squad's "overheated" / "rebooted" events fire once each per cycle, and the
## status bar is the HP bar only (no tag, no heat bar).

const DT := 1.0 / 60.0
const TYPES := ["turret", "turret_sniper", "turret_missile", "strider", "strider_breacher", "tank", "drone",
	"trooper_rifle", "trooper_at", "gunship", "dropship"]


## A squad stand-in: collects the unit events (EnemySquad.emit_enemy_event).
class EventSink extends Node:
	var events: Array = []

	func emit_enemy_event(kind: String, _enemy: Node, payload: Dictionary) -> void:
		events.append([kind, payload.duplicate()])

	func count(kind: String) -> int:
		var n := 0
		for ev: Array in events:
			if ev[0] == kind:
				n += 1
		return n


func setup() -> void:
	timeout_sec = 120.0
	_vent_ramp()
	var w := CombatWorld.new()
	w.mission_seed = 31
	add_child(w)
	for t: String in TYPES:
		await _unit_cycle(w, t)
	finish()


## The fin colour rises monotonically with heat and peaks at the cap (white-hot: brighter in every channel than cool).
func _vent_ramp() -> void:
	var prev := -1.0
	var mono := true
	for i in 21:
		var c := EnemyGlow.vent_color(float(i) / 20.0)
		var luma := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
		mono = mono and luma > prev
		prev = luma
	check(mono, "the fin glow rises strictly with heat (0..1 in 0.05 steps)")
	var cool := EnemyGlow.vent_color(0.0)
	var hot := EnemyGlow.vent_color(1.0)
	check(hot.r > cool.r * 3.0 and hot.g > cool.g * 8.0 and hot.b > cool.b * 8.0,
		"white-hot at the cap vs a dim ember when cool (%s vs %s)" % [hot, cool])
	check(hot.g / hot.r > 0.8, "near shutdown the fins are near white, not orange (g/r %.2f)" % (hot.g / hot.r))


func _spawn(w: CombatWorld, t: String, sink: EventSink) -> EnemyBase:
	var e := EnemySpawner.make_enemy(t)
	e.configure(t, "ov_" + t, w, sink, null, 7)
	e.ai_mode = "idle"
	if e is EnemyTrooper:
		(e as EnemyTrooper).force_rig = true
	add_child(e)
	w.register(e)
	return e


func _ticks(e: EnemyBase, n: int, dt: float = DT) -> void:
	for i in n:
		e.tick(dt, null)


func _spheres(e: EnemyBase) -> Array:
	var out: Array = []
	for s: Dictionary in e.world_spheres():
		out.append([s["center"], s["radius"]])
	return out


func _same_spheres(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if (a[i][0] as Vector3).distance_to(b[i][0] as Vector3) > 1e-4 or absf(float(a[i][1]) - float(b[i][1])) > 1e-4:
			return false
	return true


func _lit_params_ok(e: EnemyBase, key: String, want: float) -> bool:
	for mi: MeshInstance3D in e.heat_look.lit_meshes():
		if absf(float(mi.get_instance_shader_parameter(key)) - want) > 1e-3:
			return false
	return not e.heat_look.lit_meshes().is_empty()


## The unit's shutdown pose, read from its visual pivots.
func _slumped_pose(e: EnemyBase) -> bool:
	if e is EnemyTurret:
		return (e as EnemyTurret)._gun_pivot.rotation.x < deg_to_rad(-18.0)
	if e is EnemyStrider:
		return (e as EnemyStrider)._chassis_pivot.position.y < EnemyStrider.HIP_Y - 0.4
	if e is EnemyTank:
		var tp := (e as EnemyTank)._turret_pivot
		return (tp.global_basis * Vector3.FORWARD).dot(e.global_basis.y) < -0.15
	if e is EnemyTrooper:
		return (e as EnemyTrooper)._pivot.rotation.x < -0.25
	if e is EnemyFlier:
		return (e as EnemyFlier)._body_pivot.rotation.x < -0.1
	return false


func _upright_pose(e: EnemyBase) -> bool:
	if e is EnemyTurret:
		return absf((e as EnemyTurret)._gun_pivot.rotation.x) < 0.02
	if e is EnemyStrider:
		return (e as EnemyStrider)._chassis_pivot.position.y > EnemyStrider.HIP_Y - 0.05
	if e is EnemyTank:
		var tp := (e as EnemyTank)._turret_pivot
		return absf((tp.global_basis * Vector3.FORWARD).dot(e.global_basis.y)) < 0.02
	if e is EnemyTrooper:
		return absf((e as EnemyTrooper)._pivot.rotation.x) < 0.02
	if e is EnemyFlier:
		return absf((e as EnemyFlier)._body_pivot.rotation.x) < 0.05
	return false


func _unit_cycle(w: CombatWorld, t: String) -> void:
	var sink := EventSink.new()
	add_child(sink)
	var e := _spawn(w, t, sink)
	await frames(1)
	_ticks(e, 3)
	var look := e.heat_look
	check(not look.lit_meshes().is_empty(), "%s: its lit meshes take the heat look" % t)
	var spheres0 := _spheres(e)

	# Status bar: the HP bar only.
	var sb := e._status_bar
	var labels := 0
	for c in sb.get_children():
		if c is Label3D:
			labels += 1
	check(labels == 0 and sb.get_child_count() == 2, "%s: no tag text, no heat bar over the unit" % t)

	# Fin glow follows the heat fraction (monotonic), the optics stay lit while cool / warm.
	var prev := -1.0
	var mono := true
	for i in 10:
		e.heat.value = e.heat.cap * float(i) / 10.0
		_ticks(e, 1, 0.11)    # one write period
		var sh := look.shown_heat()
		mono = mono and sh >= prev and absf(sh - float(i) / 10.0) < 0.06
		prev = sh
	check(mono, "%s: the fin glow follows the heat fraction up (0 -> 0.9)" % t)
	check(_lit_params_ok(e, "vent_heat", look.shown_heat()) and _lit_params_ok(e, "lights", 1.0),
		"%s: every lit mesh carries the glow, optics lit while warm" % t)
	check(not look.shut and look.slump < 0.01, "%s: no slump before the shutdown" % t)

	# Overheat: one event, fins at their peak, optics dark, slump on the pivots, steam, hit spheres unchanged.
	e.heat.add(e.heat.cap)
	_ticks(e, 1)
	check(look.shut and look.overheats == 1, "%s: the look shuts down on the overheated moment" % t)
	check(look.shown_heat() >= 0.95, "%s: the fins peak at the shutdown (%.2f)" % [t, look.shown_heat()])
	_ticks(e, 60)
	eq(sink.count("overheated"), 1, "%s: the squad hears 'overheated' once" % t)
	check(_lit_params_ok(e, "lights", 0.0), "%s: optics / lamps dark while shut down" % t)
	check(look.slump > 0.85, "%s: slumped (%.2f)" % [t, look.slump])
	check(_slumped_pose(e), "%s: the sag / droop / wobble shows on its pivots" % t)
	check(look.steam_live() > 0, "%s: steam vents from the fins" % t)
	print("  %s: %d lit meshes, shut 1 s: fins %.2f, lights %.2f, slump %.2f, steam %d" % [t, look.lit_meshes().size(),
		look.shown_heat(), look.shown_lights(), look.slump, look.steam_live()])
	check(_same_spheres(spheres0, _spheres(e)), "%s: the hit spheres did not move with the slump" % t)

	# Reboot: one event, lights flicker back, the body rises.
	e.heat.value = e.heat.cap * (Heat.REBOOT_AT - 0.02)
	_ticks(e, 1)
	check(not look.shut and look.reboots == 1, "%s: the look reboots on the rebooted moment" % t)
	var flicker_dark := false
	for i in 40:
		_ticks(e, 1)
		flicker_dark = flicker_dark or look.lights < 0.5
	check(flicker_dark, "%s: the lights flicker on the way back" % t)
	_ticks(e, 60)
	eq(sink.count("rebooted"), 1, "%s: the squad hears 'rebooted' once" % t)
	eq(sink.count("overheated"), 1, "%s: still one 'overheated' in the cycle" % t)
	check(_lit_params_ok(e, "lights", 1.0), "%s: lights back on after the reboot" % t)
	check(absf(look.slump) < 0.02 and _upright_pose(e), "%s: the body / barrel back up (slump %.3f)" % [t, look.slump])
	check(_same_spheres(spheres0, _spheres(e)), "%s: hit spheres unchanged after the cycle" % t)

	# HP bar still works.
	e.apply_damage(1.0, e.core_component(), "test")
	_ticks(e, 1)
	check(sb.visible and sb._bar_hp.visible, "%s: the HP bar shows once damaged" % t)

	# Dead: the wreck keeps the meshes' plain look (no heat uniforms).
	e._kill("test")
	check(_lit_params_ok(e, "vent_heat", -1.0), "%s: a wreck shows the plain look" % t)
	e.queue_free()
	sink.queue_free()
	await frames(1)
