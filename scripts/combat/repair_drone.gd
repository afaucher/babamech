class_name RepairDrone
extends CombatEffect
## The repair drone (docs/design/back-equipment.md): a SCHEDULED EFFECT. Everything follows from its launch record
## {shooter, peer, hardpoint, weapon "repair_drone", t} + the catalog stats + the shared clock + where the launcher is on
## this machine (its own mech, or its puppet: CombatWorld.anchor_of(shooter)). CombatWorld.launch_drone starts it on the
## launcher's machine; CombatNet's one "combat.drone" event starts it everywhere else (a late arrival fast-forwards).
##
## FLIGHT: pops up from the docked spot on the back mount out onto its orbit over `rise` s (0.5), then CIRCLES the
## launcher: `orbit` m (5) out from the launcher's up axis, `hover` m (6) above its back mount, one turn per
## `orbit_period` s (6). The orbit centre follows the launcher with exponential smoothing (`follow` s, ~0.4); the angle
## is a pure function of (clock - launch time) (orbit_angle), so every machine draws the same orbit from the one launch
## record: no messages, no RNG. After `life` s (60) it stops repairing and flies HOME over `dock` s (1.5): from the
## orbit point of angle(life) to the docked spot on the launcher's back mount (EquipmentLook.dock, re-read each step so
## it lands on a walking mech), shrinking from FLY_SCALE to the mount's scale and turning into the dock's orientation;
## then it is removed and the back mount shows the docked drone again. It does not return early when everyone is full.
## It dies at once (no return) with the launcher: the launcher's PlayerTarget is disabled (downed; on a remote machine
## its puppet target mirrors that from snapshots) or the launcher's node is gone.
## REPAIR (only while on its orbit: after the rise, before `life`): each step, every target THIS MACHINE OWNS
## (CombatWorld.owns) that is not on the enemy team and stands within `radius` m (15) of the LAUNCHER (the orbit centre,
## so the orbit never makes the range flicker), measured across the launcher's up axis (horizontal), gets
## heal(heal_rate × its max HP × dt) (1 %/s), most damaged component first (CombatTarget.heal). So each machine repairs
## only its own mech (and the host its host-owned non-enemy targets): no heal is ever sent and nobody writes another
## mech's HP.
## LOOK (cosmetic, every machine): the Mech session's flying drone mesh (MechMeshes part `weapon_repair_drone_flying`,
## origin at its centre, facing -Z) in the launcher's accent colour (MechMeshes.apply_accent, as MechModel tints its
## parts), FLY_SCALE x (about 1.6 m across the rotor guards); it leaves from the docked drone's spot on the back mount
## (HP_<hardpoint> x MechMeshes.DRONE_DOCK, EquipmentLook.dock) at the mount's size and grows to FLY_SCALE while it
## rises, then turns slowly toward where it travels (yaw only, YAW_FOLLOW s smoothing) and bobs a little. While it is
## out, the launcher's back mount shows the empty cradle (EquipmentLook, every machine). The placeholder MeshKit quad
## (spinning rotors) is the fallback when the part is missing. GREEN ONLY WHILE IT WORKS: a thin unshaded green beam to
## every non-enemy target in range that is being repaired right now (repairable: hittable, not destroyed, a component
## below full that isn't destroyed; on the owner's machine that is exactly what heal restores, on other machines the
## same test on the streamed mirror HP), and a faint green ring on the ground at `radius` around the launcher only while
## at least one beam shows. Nothing green during the rise, while idle (everyone full) or on the way home.

const GREEN := Color(0.25, 1.0, 0.45)
const RING_GREEN := Color(0.10, 0.38, 0.17)   ## the faint ground ring (unshaded: a dim colour reads as faint)
const MAX_STEP := 0.25            ## s: the longest repair step (a stall or a fast-forward never heals in one burst)
const ANCHOR_GRACE := 1.0         ## s a drone waits for its launcher's node before it dies (remote: the puppet appears)
const BEAMS := 4                  ## beams kept in the pool (a crew is at most 4)
const DRONE_SCALE := 1.0          ## m: the placeholder drone is about 1.6 m across
const FLY_SCALE := 2.1            ## the flying mesh (~0.76 model units across the rotor guards) -> about 1.6 m
const YAW_FOLLOW := 0.25          ## s: smoothing of the turn toward the direction of travel (small: it faces along the orbit)
const YAW_MIN_SPEED := 0.4        ## m/s of horizontal travel below which it keeps its heading
const BOB := 0.15                 ## m of slow up-and-down while it circles (faded in on the rise, out on the way home)

## The MechMeshes equipment part drawn in flight (tests point it at a missing part to see the fallback).
static var flying_id := "repair_drone_flying"

var anchor: Callable              ## () -> Node3D: the launcher (its mech / puppet / lab model) on this machine
var pos := Vector3.ZERO           ## the drone's world position now (derived each step)
var up_dir := Vector3.UP
var healed_total := 0.0           ## HP this drone restored on this machine (tests, diagnostics)
var dead := false                 ## the launcher went down / away: removed next step
var _last := NAN                  ## clock time of the previous step
var _missing := 0.0
var _body: MeshInstance3D
var _rotors: Array = []
var _ring: MeshInstance3D
var _beams: Array = []
var _beam_targets: Array = []     ## targets beamed this step (tests)
var flying_mesh := false          ## drawn with the Mech session's flying mesh (false: the placeholder)
var yaw := 0.0                    ## heading about up_dir in the drone's frame (rad; 0 = the frame's -Z)
var _dock: Dictionary = {}        ## {pos, scale, basis} of the docked drone (EquipmentLook.dock): at launch, live going home
var _prev_pos := Vector3.ZERO
var centre := Vector3.ZERO        ## the launcher's position now (orbit centre on the ground: range and ring measure from it)
var _follow := Vector3.ZERO       ## the smoothed orbit centre at hover height (derived each step)


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({"anchor": Net.LOCAL, "pos": Net.LOCAL, "up_dir": Net.LOCAL, "healed_total": Net.LOCAL, "dead": Net.LOCAL,
		"_last": Net.LOCAL, "_missing": Net.LOCAL, "_body": Net.LOCAL, "_rotors": Net.LOCAL, "_ring": Net.LOCAL,
		"_beams": Net.LOCAL, "_beam_targets": Net.LOCAL, "flying_mesh": Net.LOCAL, "yaw": Net.LOCAL, "_dock": Net.LOCAL,
		"_prev_pos": Net.LOCAL, "centre": Net.LOCAL, "_follow": Net.LOCAL})
	return f


func start(w: CombatWorld, rec: Dictionary, st: Dictionary) -> void:
	super.start(w, rec, st)
	anchor = w.anchor_of(str(rec.get("shooter", "")))
	top_level = true


func shooter() -> String:
	return str(record.get("shooter", ""))


func age() -> float:
	return (world.now if world != null else t0) - t0


func life() -> float:
	return float(stats.get("life", 60.0))


## Seconds the flight home takes (catalog `dock`).
func dock_time() -> float:
	return float(stats.get("dock", 1.5))


func rise_time() -> float:
	return float(stats.get("rise", 0.5))


func orbit_radius() -> float:
	return float(stats.get("orbit", 5.0))


func orbit_period() -> float:
	return float(stats.get("orbit_period", 6.0))


## Seconds of repair left (0 once it heads home or died).
func time_left() -> float:
	return 0.0 if dead else maxf(life() - age(), 0.0)


## On duty (launched, alive, inside its life): rising or circling.
func active() -> bool:
	return not dead and age() < life()


## Flying home to its dock (its life is over, not yet docked).
func returning() -> bool:
	return not dead and age() >= life() and not finished()


## On its orbit and repairing (after the rise, inside its life).
func repairing() -> bool:
	return active() and age() >= rise_time()


func finished() -> bool:
	return dead or age() >= life() + dock_time()


## The orbit angle at clock time `now` (rad about up_dir in _frame(), 0 = the frame's +X): a pure function of the time
## since launch, identical on every machine.
func orbit_angle(now: float) -> float:
	return TAU * (now - t0) / maxf(orbit_period(), 1e-3)


## The targets the beams point at this step (the ones being repaired right now: see `repairable`).
func beamed() -> Array:
	return _beam_targets.duplicate()


## The faint green ground ring shows now (only while at least one beam does).
func ring_shown() -> bool:
	return _ring != null and _ring.visible and visible


## `t` is being repaired by a drone in range right now: hittable, not destroyed, and a component below full that isn't
## destroyed (exactly when CombatTarget.heal would restore something). The owner's own target and a puppet's streamed
## mirror (PlayerTarget hp / max_hp) answer the same way.
static func repairable(t: CombatTarget) -> bool:
	if t == null or not t.is_hittable() or t.destroyed():
		return false
	for c: String in t.hp:
		var cap := float(t.max_hp.get(c, 0.0))
		var v := float(t.hp[c])
		if v > 0.0 and cap > 0.0 and v < cap - 1e-6:
			return true
	return false


## The launcher's node on this machine, or null.
func launcher() -> Node3D:
	if not anchor.is_valid():
		anchor = world.anchor_of(shooter()) if world != null else Callable()
		if not anchor.is_valid():
			return null
	var n: Variant = anchor.call()
	return n as Node3D if n != null and is_instance_valid(n) else null


## The orbit centre for a launcher at `base` with up `u`: `hover` m above its back mount.
func hover_point(base: Vector3, u: Vector3) -> Vector3:
	return base + u * (back_height() + float(stats.get("hover", 6.0)))


## The orbit offset (across up_dir) at angle `ang` in frame `b`.
func orbit_offset(ang: float, b: Basis) -> Vector3:
	return (b.x * cos(ang) + b.z * sin(ang)) * orbit_radius()


## Height of the back mount above the launcher's origin (PlayerTarget's back hit sphere: an 8 m strider).
static func back_height() -> float:
	return float((PlayerTarget.HARDPOINT_SPHERES["back"]["center"] as Vector3).y)


func advance_to(now: float) -> void:
	if dead or world == null:
		return
	var a := now - t0
	var node := launcher()
	if node == null:
		_missing += maxf(now - (_last if not is_nan(_last) else now), 0.0)
		_last = now
		visible = false
		if _missing > ANCHOR_GRACE:
			dead = true
		return
	_missing = 0.0
	if _launcher_down():
		dead = true
		visible = false
		return
	var base := node.global_position if node.is_inside_tree() else node.position
	centre = base
	up_dir = _up_of(node)
	var hover := hover_point(base, up_dir)
	var rise := rise_time()
	var first := is_nan(_last)
	var dt := 0.0 if first else clampf(now - _last, 0.0, MAX_STEP)
	_last = now
	if first:
		_follow = hover                # (a late arrival: already up and circling)
	else:
		_follow = _follow.lerp(hover, 1.0 - exp(-dt / maxf(float(stats.get("follow", 0.4)), 1e-3)))
	var b := _frame()
	_beam_targets.clear()
	if a < rise:                       # rising from the dock out onto the orbit: no repair, nothing green
		if _dock.is_empty():
			_dock = _dock_now(base)
		var on_orbit := _follow + orbit_offset(orbit_angle(now), b)
		pos = (_dock["pos"] as Vector3).lerp(on_orbit, clampf(a / maxf(rise, 1e-3), 0.0, 1.0))
	elif a < life():                   # circling and repairing
		pos = _follow + orbit_offset(orbit_angle(now), b)
		_repair(dt)
	else:                              # flying home: from where its life ended to the dock on the (moving) launcher
		_dock = _dock_now(base)
		var from := _follow + orbit_offset(orbit_angle(t0 + life()), b)
		pos = from.lerp(_dock["pos"] as Vector3, smoothstep(0.0, 1.0, home_fraction()))
	_turn(dt, first)
	_draw(base, now)


## 0..1 of the flight home (0 before / at the end of its life, 1 docked).
func home_fraction() -> float:
	return clampf((age() - life()) / maxf(dock_time(), 1e-3), 0.0, 1.0)


## The docked drone's spot on the launcher now (EquipmentLook.dock), else the back mount above `base`.
func _dock_now(base: Vector3) -> Dictionary:
	var d := world.equipment_look.dock(world, shooter(), str(record.get("hardpoint", "back")))
	if d.has("pos"):
		return d
	return {"pos": base + up_dir * back_height()}


## The launcher is down: its PlayerTarget (own, or the puppet's mirror) is disabled.
func _launcher_down() -> bool:
	for t in world.targets:
		if is_instance_valid(t) and t.target_id == shooter() and t is PlayerTarget:
			return (t as PlayerTarget).disabled
	return false


static func _up_of(node: Node3D) -> Vector3:
	if node.has_method("up"):
		var u: Variant = node.call("up")
		if u is Vector3 and (u as Vector3).length_squared() > 1e-6:
			return (u as Vector3).normalized()
	return Vector3.UP


## Horizontal distance (across up_dir) from the LAUNCHER (the orbit centre) to `p`: the repair radius is measured from it.
func reach_to(p: Vector3) -> float:
	var d := p - centre
	return (d - up_dir * d.dot(up_dir)).length()


## Horizontal distance (across up_dir) from the launcher to the drone (about `orbit` m once it circles).
func orbit_distance() -> float:
	return reach_to(pos)


func _repair(dt: float) -> void:
	var r := float(stats.get("radius", 15.0))
	var rate := float(stats.get("heal_rate", 0.01))
	for t in world.targets:
		if not is_instance_valid(t) or t.team == "enemy" or not t.is_inside_tree():
			continue
		if reach_to(t.global_position) > r:
			continue
		if dt > 0.0 and world.owns(t):
			healed_total += t.heal(rate * t.total_max_hp() * dt, shooter())
		if repairable(t):
			_beam_targets.append(t)


# --- Look (cosmetic) ----------------------------------------------------------------------------------------

## The drone's level frame: up = up_dir, a fixed horizontal -Z (yaw turns the body inside it; the ring uses it as is).
func _frame() -> Basis:
	var fwd := up_dir.cross(Vector3.RIGHT if absf(up_dir.x) < 0.9 else Vector3.FORWARD).normalized()
	return Basis(fwd.cross(up_dir).normalized(), up_dir, -fwd).orthonormalized()


## Turn slowly toward the horizontal direction of travel (cosmetic).
func _turn(dt: float, first: bool) -> void:
	var moved := pos - _prev_pos
	_prev_pos = pos
	if first or dt <= 0.0:
		return
	var b := _frame()
	var x := moved.dot(b.x)
	var z := moved.dot(b.z)
	if Vector2(x, z).length() < YAW_MIN_SPEED * dt:
		return
	yaw = lerp_angle(yaw, atan2(-x, -z), 1.0 - exp(-dt / YAW_FOLLOW))


## The body's size now: the docked drone's (mount scale) at launch, growing to full size while it rises, shrinking back
## to the mount's scale on the way home.
func _body_scale() -> float:
	var full := FLY_SCALE if flying_mesh else DRONE_SCALE
	if not flying_mesh or not _dock.has("scale"):
		return full
	if age() >= life():
		return lerpf(full, float(_dock["scale"]), smoothstep(0.0, 1.0, home_fraction()))
	return lerpf(float(_dock["scale"]), full, clampf(age() / maxf(rise_time(), 1e-3), 0.0, 1.0))


## How much of the bob shows: faded in over the rise, out on the way home (it lands exactly on the dock).
func _bob_weight() -> float:
	if age() >= life():
		return 1.0 - home_fraction()
	return clampf(age() / maxf(rise_time(), 1e-3), 0.0, 1.0)


func _draw(base: Vector3, now: float) -> void:
	if _body == null:
		_build()
	visible = true
	var b := _frame()
	var turn := b * Basis(Vector3.UP, yaw)
	if age() >= life() and _dock.has("basis"):     # going home: turn into the docked drone's orientation as it lands
		var to := (_dock["basis"] as Basis).orthonormalized()
		turn = Basis(turn.get_rotation_quaternion().slerp(to.get_rotation_quaternion(), smoothstep(0.0, 1.0, home_fraction())))
	global_transform = Transform3D(turn, pos + up_dir * sin(now * 2.6) * BOB * _bob_weight())
	if flying_mesh:
		_body.scale = Vector3.ONE * _body_scale()
	for i in _rotors.size():
		(_rotors[i] as Node3D).rotation.y = now * 40.0 * (1.0 if i % 2 == 0 else -1.0)
	var r := float(stats.get("radius", 15.0))
	_ring.global_transform = Transform3D(b * Basis.from_scale(Vector3(r, 1.0, r)), base + up_dir * 0.08)
	_ring.visible = not _beam_targets.is_empty()      # green only while it repairs someone
	for i in _beams.size():
		var mi := _beams[i] as MeshInstance3D
		if i >= _beam_targets.size():
			mi.visible = false
			continue
		var t := _beam_targets[i] as CombatTarget
		var to := t.global_position + t.up * float(t.probe_height)
		var from := global_position - up_dir * 0.3
		var length := from.distance_to(to)
		mi.visible = length > 0.5
		if mi.visible:
			mi.global_transform = Transform3D(Combat.look_basis(to - from) * Basis.from_scale(Vector3(0.06, 0.06, length)), from)


func _build() -> void:
	var accent := _accent()
	var fly := EquipmentLook.part_mesh(flying_id)
	flying_mesh = fly != null
	if flying_mesh:
		_body = MeshInstance3D.new()
		_body.name = "weapon_" + flying_id
		_body.mesh = fly
		MechMeshes.apply_accent(_body, accent)
		_body.scale = Vector3.ONE * _body_scale()
		add_child(_body)
	else:
		_build_placeholder(accent)
	_ring = CombatMeshes.instance(CombatMeshes.ring(RING_GREEN, 0.985, 48))
	_ring.top_level = true
	add_child(_ring)
	for i in BEAMS:
		var mi := CombatMeshes.instance(CombatMeshes.prism3(GREEN))
		mi.top_level = true
		mi.visible = false
		add_child(mi)
		_beams.append(mi)


## The fallback look (no flying mesh): the MeshKit quad body and four spinning rotors.
func _build_placeholder(accent: Color) -> void:
	_body = CombatMeshes.instance(body_mesh(accent))
	_body.scale = Vector3.ONE * DRONE_SCALE
	add_child(_body)
	for i in 4:
		var rot := CombatMeshes.instance(rotor_mesh())
		var ang := PI * 0.25 + PI * 0.5 * i
		rot.position = Vector3(cos(ang), 0.12, sin(ang)) * 0.8 * DRONE_SCALE
		rot.scale = Vector3.ONE * DRONE_SCALE
		add_child(rot)
		_rotors.append(rot)


## The launcher's accent colour: its MechModel's (EquipmentLook's source, else found under the launcher node), else the
## default orange.
func _accent() -> Color:
	var mm := world.equipment_look.model_of(world, shooter()) if world != null else null
	if mm != null:
		return mm.accent
	var node := launcher()
	var stack: Array = [node] if node != null else []
	var depth := 0
	while not stack.is_empty() and depth < 4:
		var next: Array = []
		for n: Variant in stack:
			if n is MechModel:
				return (n as MechModel).accent
			next.append_array((n as Node).get_children())
		stack = next
		depth += 1
	return MechMeshes.ORANGE


## The drone body: a flat hub, four arms, a sensor ball underneath; accent hub, grey arms. Cached per colour.
static func body_mesh(accent: Color) -> ArrayMesh:
	return CombatMeshes._mesh("drone|%s" % accent.to_html(), func(k: MeshKit) -> void:
		k.box(Vector3(0.7, 0.22, 0.7), accent)
		k.box(Vector3(0.45, 0.14, 0.45), accent.darkened(0.25), Vector3(0, 0.17, 0))
		for i in 4:
			var ang := PI * 0.25 + PI * 0.5 * i
			var tip := Vector3(cos(ang), 0.0, sin(ang)) * 0.8
			k.tube(Vector3(0, 0.02, 0), tip, 0.05, 4, MechMeshes.GUN)
			k.tube(tip - Vector3(0, 0.1, 0), tip + Vector3(0, 0.1, 0), 0.08, 6, MechMeshes.GUN)
		k.glow = true
		k.ico(Vector3(0, -0.16, 0), Vector3.ONE * 0.12, GREEN))


## One rotor: a thin flat bar (spun about its local Y each step).
static func rotor_mesh() -> ArrayMesh:
	return CombatMeshes._mesh("drone_rotor", func(k: MeshKit) -> void:
		k.box(Vector3(0.62, 0.02, 0.08), Color(0.12, 0.12, 0.13)))
