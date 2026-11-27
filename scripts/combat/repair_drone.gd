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
## REVIVE (docs/design/pacing-director.md "Downed, revive, respawn", DownedRules): a DOWNED PlayerTarget in range
## (revivable: disabled, not redeploying; never the launcher's own) is not healed: the machine that owns it calls
## PlayerTarget.revive_tick(dt, shooter) each repair step, and DownedRules.REVIVE_TIME s of beam stand it up in place
## (its owner applies the revive; nothing is sent). The scan shows on the wreck on every machine while it is beamed.
## The revive costs the drone nothing extra: the charge that launched it is the price (no life is taken off).
## LOOK (cosmetic, every machine): the Mech session's flying drone mesh (MechMeshes part `weapon_repair_drone_flying`,
## origin at its centre, facing -Z) in the launcher's accent colour (LowPolyMaterials.apply_accent, as MechModel tints its
## parts), FLY_SCALE x (about 1.6 m across the rotor guards); it leaves from the docked drone's spot on the back mount
## (HP_<hardpoint> x MechMeshes.DRONE_DOCK, EquipmentLook.dock) at the mount's size and grows to FLY_SCALE while it
## rises, then turns slowly toward where it travels (yaw only, YAW_FOLLOW s smoothing) and bobs a little. While it is
## out, the launcher's back mount shows the empty cradle (EquipmentLook, every machine). The placeholder MeshKit quad
## (spinning rotors) is the fallback when the part is missing. GREEN ONLY WHILE IT WORKS: a SCAN on every non-enemy
## target in range that is being repaired right now (repairable: hittable, not destroyed, a component below full that
## isn't destroyed; on the owner's machine that is exactly what heal restores, on other machines the same test on the
## streamed mirror HP), and a faint green ring on the ground at `radius` around the launcher only while at least one
## scan shows. Nothing green during the rise, while idle (everyone full) or on the way home.
## THE SCAN (the user's pick, cell C3 of the render probe tools/scanner_beam/): one bright ring (CORE) round the target,
## level in the target's own up frame (CombatTarget.up), travelling up and down its body between SCAN_LO and SCAN_HI of
## its height once per SCAN_PERIOD s (eased at the turns), with three fainter trail rings where it was TRAIL_DT, 2x, 3x
## ago and a soft band fading back to where it was BAND_DT ago, joined to the drone's lens by a faint thin wedge (a
## fan onto the hot ring's drone-facing arc, two faint edge lines). Its height is a pure function of (clock - launch
## time) (scan_fraction): every machine draws the same scan, no RNG. Ring radius and height fit the target (scan_fit,
## cached per target: its MechModel's mesh bounds, so every chassis; else its hit spheres). Unshaded, alpha-blended,
## no shadows; cached meshes per radius bucket, only transforms change per frame; the nodes come from the world's mesh
## pool (CombatWorld.take_mesh) and go back when the drone leaves.

const GREEN := Color(0.25, 1.0, 0.45)
const RING_GREEN := Color(0.10, 0.38, 0.17)   ## the faint ground ring (unshaded: a dim colour reads as faint)
const MAX_STEP := 0.25            ## s: the longest repair step (a stall or a fast-forward never heals in one burst)
const ANCHOR_GRACE := 1.0         ## s a drone waits for its launcher's node before it dies (remote: the puppet appears)
const BEAMS := 4                  ## scan sets kept (one per repaired target; a crew is at most 4)
## The scan look (user's pick: render probe tools/scanner_beam/, cell C3). Parts of one set, in order:
const SCAN_PARTS := ["head", "trail1", "trail2", "trail3", "band", "wedge", "edge", "edge"]
const CORE := Color(0.62, 1.0, 0.72)    ## the hot ring (GREEN lightened)
const SCAN_ALPHAS := [1.0, 0.5, 0.26, 0.12]   ## hot ring, then the trail rings
const HEAD_W := 0.10              ## m: hot ring bar width
const TRAIL_W := 0.06             ## m: trail ring bar width
const BAND_ALPHA := 0.16          ## the soft band's alpha at the hot ring (clear at its far edge)
const SCAN_SIDES := 12            ## ring polygon sides
const SCAN_PERIOD := 3.0          ## s: one trip up and back down
const SCAN_LO := 0.15             ## share of the target's height at the bottom of the scan ...
const SCAN_HI := 0.95             ## ... and at the top
const TRAIL_DT := 0.08            ## s: each trail ring is where the hot ring was this long before the previous one
const BAND_DT := 0.25             ## s: the band reaches back to where the hot ring was this long ago
const WEDGE_HALF := PI / 3.0      ## the wedge lands on the hot ring's arc +-60 deg either side of the drone
const EDGE_W := 0.03              ## m: the wedge's two edge lines
const RING_MIN := 1.0             ## m: ring radius clamp (before RING_PAD) ...
const RING_MAX := 3.4
const RING_PAD := 0.3             ## m outside the body
const RING_STEP := 0.1            ## m: ring radius buckets (one cached mesh set per bucket)
const DRONE_SCALE := 1.0          ## m: the placeholder drone is about 1.6 m across
const FLY_SCALE := 2.1            ## the flying mesh (~0.76 model units across the rotor guards) -> about 1.6 m
const YAW_FOLLOW := 0.25          ## s: smoothing of the turn toward the direction of travel (small: it faces along the orbit)
const YAW_MIN_SPEED := 0.4        ## m/s of horizontal travel below which it keeps its heading
const BOB := 0.15                 ## m of slow up-and-down while it circles (faded in on the rise, out on the way home)

## The MechMeshes equipment part drawn in flight (tests point it at a missing part to see the fallback).
static var flying_id := "repair_drone_flying"
static var _scan_meshes: Dictionary = {}    ## cached scan meshes by part + ring radius bucket (cosmetic)
static var _scan_mats: Array = []           ## [volume material, line material]

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
var _beams: Array = []            ## BEAMS scan sets: each an Array of SCAN_PARTS.size() MeshInstance3D
var _beam_targets: Array = []     ## targets beamed this step (tests)
var _fit: Dictionary = {}         ## target instance id -> scan_fit {h, r} (cached once)
var _borrowed := false            ## scan nodes came from world.take_mesh (handed back in _exit_tree)
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
		"_prev_pos": Net.LOCAL, "centre": Net.LOCAL, "_follow": Net.LOCAL, "_fit": Net.LOCAL, "_borrowed": Net.LOCAL})
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
	return base + u * (_launcher_back_height() + float(stats.get("hover", 6.0)))


## back_height() of the launcher's chassis and the hardpoint the drone flew from (record "hardpoint"; the launcher's
## PlayerTarget, own or a puppet's mirror, gives the chassis: SPAWN data, the same on every machine).
func _launcher_back_height() -> float:
	var hp_id := str(record.get("hardpoint", "back"))
	if world != null:
		for t in world.targets:
			if is_instance_valid(t) and t.target_id == shooter() and t is PlayerTarget:
				return back_height((t as PlayerTarget).chassis, hp_id)
	return back_height("strider", hp_id)


## The orbit offset (across up_dir) at angle `ang` in frame `b`.
func orbit_offset(ang: float, b: Basis) -> Vector3:
	return (b.x * cos(ang) + b.z * sin(ang)) * orbit_radius()


## Height of a back mount above the launcher's origin: the chassis' hit sphere of hardpoint `hp_id` (the Strider's
## "back", 5.8 m; the Bulwark's back_l / back_r, 7.6 m); a hardpoint the chassis lacks uses its first back hardpoint.
static func back_height(chassis_id: String = "strider", hp_id: String = "back") -> float:
	var spheres := PlayerTarget.hardpoint_spheres(chassis_id)
	if not spheres.has(hp_id):
		var backs := PlayerTarget.back_hardpoints(chassis_id)
		hp_id = backs[0] if not backs.is_empty() and spheres.has(backs[0]) else ""
	if hp_id == "":
		return float((PlayerTarget.HARDPOINT_SPHERES["back"]["center"] as Vector3).y)
	return float((spheres[hp_id]["center"] as Vector3).y)


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
	return {"pos": base + up_dir * _launcher_back_height()}


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
		if t is PlayerTarget and (t as PlayerTarget).revivable():
			# REVIVE (DownedRules): a downed crewmate in range (never the launcher itself) gets the beam; the machine that
			# owns it counts the beam toward the revive (PlayerTarget.revive_tick), every machine draws the scan on it.
			if t.target_id != shooter():
				if dt > 0.0 and world.owns(t):
					(t as PlayerTarget).revive_tick(dt, shooter())
				_beam_targets.append(t)
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
	if _beams.is_empty() and not _beam_targets.is_empty():
		_build_scans()                                # (handed back on leaving the tree: borrow again)
	for i in _beams.size():
		if i >= _beam_targets.size():
			_show_scan(_beams[i] as Array, false)
			continue
		var bt: Variant = _beam_targets[i]
		if bt == null or not is_instance_valid(bt):      # freed since the repair step: `as` on it would raise
			_show_scan(_beams[i] as Array, false)
			continue
		_place_scan(_beams[i] as Array, bt as CombatTarget, now)


func _build() -> void:
	var accent := _accent()
	var fly := EquipmentLook.part_mesh(flying_id)
	flying_mesh = fly != null
	if flying_mesh:
		_body = MeshInstance3D.new()
		_body.name = "weapon_" + flying_id
		_body.mesh = fly
		LowPolyMaterials.apply_accent(_body, accent)
		_body.scale = Vector3.ONE * _body_scale()
		add_child(_body)
	else:
		_build_placeholder(accent)
	_ring = CombatMeshes.instance(CombatMeshes.ring(RING_GREEN, 0.985, 48))
	_ring.top_level = true
	add_child(_ring)
	_build_scans()


## The BEAMS scan sets (pooled nodes, hidden).
func _build_scans() -> void:
	for i in BEAMS:
		var parts: Array = []
		var r0 := _bucket(1.3)
		for k in SCAN_PARTS.size():
			parts.append(_take(_scan_mesh(k, r0)))
		_beams.append(parts)


## A scan node showing `m`: borrowed from the world's mesh pool (CombatWorld.take_mesh, handed back in _exit_tree), or
## made here as a top-level child when the world isn't in the tree.
func _take(m: Mesh) -> MeshInstance3D:
	var mi: MeshInstance3D = world.take_mesh(m) if world != null and is_instance_valid(world) else null
	if mi != null:
		_borrowed = true
	else:
		mi = CombatMeshes.instance(m)
		mi.top_level = true
		add_child(mi)
	mi.visible = false
	return mi


func _exit_tree() -> void:
	_give_back()


## Pooled scan nodes are not our children: hide them with the drone (dead / launcher missing) and hand them back when it
## leaves.
func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not visible:
		for parts: Array in _beams:
			_show_scan(parts, false)


func _give_back() -> void:
	if not _borrowed:
		return
	_borrowed = false
	var ok := world != null and is_instance_valid(world)
	for parts: Array in _beams:
		for mi: Variant in parts:
			if mi == null or not is_instance_valid(mi) or (mi as Node).get_parent() == self:
				continue
			if ok:
				world.give_mesh(mi as MeshInstance3D)
			else:
				(mi as Node).queue_free()
	_beams.clear()


func _show_scan(parts: Array, on: bool) -> void:
	for mi: Variant in parts:
		if mi != null and is_instance_valid(mi):
			(mi as MeshInstance3D).visible = on


## Scan height as a fraction of the target's height at clock time `now`: up and down between SCAN_LO and SCAN_HI once per
## SCAN_PERIOD s, eased at the turns, a pure function of the time since launch (every machine draws the same scan).
func scan_fraction(now: float) -> float:
	var k := 0.5 - 0.5 * cos(TAU * (now - t0) / SCAN_PERIOD)
	return lerpf(SCAN_LO, SCAN_HI, k)


## Scan sets showing now (one per repaired target; tests).
func scans_shown() -> int:
	if not visible:
		return 0
	var n := 0
	for parts: Array in _beams:
		if not parts.is_empty() and is_instance_valid(parts[0]) and (parts[0] as MeshInstance3D).visible:
			n += 1
	return n


## {h: height (m along its up), r: scan ring radius (m)} of `t`, worked out once and cached: from its MechModel's meshes
## when it has one (fits every chassis), else from its hit spheres (dummies, assets), else probe_height / body_radius.
func scan_fit(t: CombatTarget) -> Dictionary:
	var key := t.get_instance_id()
	var got: Variant = _fit.get(key)
	if got is Dictionary:
		return got
	var anchored := false
	var model: MechModel = null
	if world != null:
		var f := world.anchor_of(t.target_id)
		if f.is_valid():
			anchored = true
			var n: Variant = f.call()
			if n != null and is_instance_valid(n):
				model = EquipmentLook.find_model(n as Node)
	if model == null:
		model = EquipmentLook.find_model(t)
	var fit := {}
	if model != null and model.is_inside_tree():
		fit = _fit_model(model, t.global_position, t.up)
	if fit.is_empty():
		fit = _fit_spheres(t)
		if anchored:
			return fit                  # its model may not be built yet: look again next time
	_fit[key] = fit
	return fit


## Height along `u` of the model's mesh bounds above `origin`, and the ring radius round its body band (55-80 % of the
## height), padded a little so the ring sits just outside the body.
static func _fit_model(model: MechModel, origin: Vector3, u: Vector3) -> Dictionary:
	var hi := 0.0
	var pts: Array[Vector3] = []
	for c: Node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := c as MeshInstance3D
		if mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var bb := mi.mesh.get_aabb()
		var xf := mi.global_transform
		for k in 8:
			var w := xf * bb.get_endpoint(k) - origin
			pts.append(w)
			hi = maxf(hi, w.dot(u))
	if hi < 2.0:
		return {}
	var rad := 0.0
	for w in pts:
		var h := w.dot(u)
		if h > hi * 0.55 and h < hi * 0.8:
			rad = maxf(rad, (w - u * h).length())
	return {"h": hi, "r": clampf(rad * 0.6, RING_MIN, RING_MAX) + RING_PAD}


static func _fit_spheres(t: CombatTarget) -> Dictionary:
	var hi := 0.0
	var rad := 0.0
	var s := t.global_transform.basis.get_scale().x if t.is_inside_tree() else 1.0
	for hs: Dictionary in t.hit_shapes:
		var c := hs["center"] as Vector3
		var r := float(hs["radius"])
		hi = maxf(hi, (c.y + r) * s)
		rad = maxf(rad, r * s)
	if hi <= 0.0:
		hi = float(t.probe_height) * 2.0
		rad = float(t.body_radius)
	return {"h": maxf(hi, 1.0), "r": clampf(rad, RING_MIN * 0.5, RING_MAX) + RING_PAD}


## One repaired target's scan look this step: the hot ring at scan_fraction × its height, the trail rings where the hot
## ring was TRAIL_DT, 2 × and 3 × ago, the soft band between it and where it was BAND_DT ago, and the faint wedge from the
## drone's lens to the drone-facing arc of the hot ring. Cached meshes, transforms only.
func _place_scan(parts: Array, t: CombatTarget, now: float) -> void:
	var fit := scan_fit(t)
	var hgt := float(fit["h"])
	var rc := _bucket(float(fit["r"]))
	var u := t.up.normalized() if t.up.length_squared() > 1e-6 else up_dir
	var base := t.global_position
	var lens := global_position - up_dir * 0.3
	var h0 := hgt * scan_fraction(now)
	var c0 := base + u * h0
	var tw := lens - c0                 # toward the drone, across the target's up
	tw -= u * tw.dot(u)
	if tw.length_squared() < 1e-6:
		tw = _frame().z - u * _frame().z.dot(u)
	tw = tw.normalized()
	var side := u.cross(tw).normalized()
	var b := Basis(side, u, tw)
	for i in SCAN_PARTS.size():
		var mi := parts[i] as MeshInstance3D
		var m := _scan_mesh(i, rc)
		if mi.mesh != m:
			mi.mesh = m
	for k in 4:                         # head + 3 trail rings
		var hk := h0 if k == 0 else hgt * scan_fraction(now - TRAIL_DT * k)
		(parts[k] as MeshInstance3D).global_transform = Transform3D(b, base + u * hk)
	var dh := h0 - hgt * scan_fraction(now - BAND_DT)   # >0 moving up (band below), <0 moving down (band above)
	if absf(dh) < 0.02:
		dh = 0.02 if dh >= 0.0 else -0.02
	(parts[4] as MeshInstance3D).global_transform = Transform3D(Basis(side, u * dh, tw), c0)
	_show_scan(parts.slice(0, 5), true)
	var reach := lens - c0
	var lens_ok := reach.length() > rc + 0.5
	for i in [5, 6, 7]:
		(parts[i] as MeshInstance3D).visible = lens_ok
	if not lens_ok:
		return
	(parts[5] as MeshInstance3D).global_transform = Transform3D(Basis(side * rc, reach, tw * rc), c0)
	for e in 2:
		var a := WEDGE_HALF * (1.0 if e == 0 else -1.0)
		var to := c0 + (side * sin(a) + tw * cos(a)) * rc
		var d := to - lens
		(parts[6 + e] as MeshInstance3D).global_transform = Transform3D(
			Combat.look_basis(d) * Basis.from_scale(Vector3(EDGE_W, EDGE_W, d.length())), lens)


## For CombatWorld.prewarm_mesh_pool: one drone's scan nodes (BEAMS sets) with their meshes built, so a launch takes
## them from the pool instead of building 32 nodes and 7 meshes mid-fight (and the shader warm-up sees the scan looks).
static func pool_plan() -> Array:
	var plan: Array = []
	for k in SCAN_PARTS.size():
		plan.append([_scan_mesh(k, _bucket(1.3)), BEAMS])
	return plan


## Ring radii come in RING_STEP buckets so a handful of meshes serve every target.
static func _bucket(r: float) -> float:
	return maxf(snappedf(r, RING_STEP), RING_STEP)



## The cached mesh for scan part `part` (index into SCAN_PARTS) at ring radius `r` (bucketed). Rings are square-section
## bars round a SCAN_SIDES-gon of radius r in XZ (vertex 0 on +Z); the band is the same polygon's open side from y -1
## (clear) to y 0; the wedge is a fan from an apex at (0, 1, 0) to the unit polygon's +Z arc (its transform shears it
## onto the lens and the hot ring); an edge is a square bar along -Z, 1 m long, 1 m across (scaled).
static func _scan_mesh(part: int, r: float) -> ArrayMesh:
	var key := Vector2i(mini(part, 6), roundi(r * 100.0) if part < 5 else 0)    # (no string per frame; both edges share)
	var got: Variant = _scan_meshes.get(key)
	if got != null:
		return got
	var kind := str(SCAN_PARTS[part])
	if _scan_mats.is_empty():
		_scan_mats = [_scan_material(0), _scan_material(1)]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := SCAN_SIDES
	var poly: Array[Vector3] = []
	for i in n:
		var a := TAU * float(i) / float(n)
		poly.append(Vector3(sin(a), 0.0, cos(a)))
	var line := true
	match kind:
		"head", "trail1", "trail2", "trail3":
			var k := ["head", "trail1", "trail2", "trail3"].find(kind)
			var col := _a(SCAN_ALPHAS[k], CORE if k == 0 else GREEN)
			for i in n:
				_bar(st, poly[i] * r, poly[(i + 1) % n] * r, HEAD_W if k == 0 else TRAIL_W, col, col)
		"band":
			line = false
			for i in n:
				var p: Vector3 = poly[i] * r
				var q: Vector3 = poly[(i + 1) % n] * r
				_quad(st, p - Vector3.UP, q - Vector3.UP, q, p, _a(0.0), _a(0.0), _a(BAND_ALPHA), _a(BAND_ALPHA))
		"wedge":
			line = false
			var steps := roundi(WEDGE_HALF / (TAU / float(n)))
			for i in range(-steps, steps):
				var a0 := TAU * float(i) / float(n)
				var a1 := TAU * float(i + 1) / float(n)
				_tri(st, Vector3.UP, Vector3(sin(a0), 0, cos(a0)), Vector3(sin(a1), 0, cos(a1)),
					_a(0.02), _a(0.08), _a(0.08))
		"edge":
			_bar(st, Vector3.ZERO, Vector3(0, 0, -1), 1.0, _a(0.08), _a(0.3))
	st.set_material(_scan_mats[1 if line else 0])
	var m := st.commit()
	_scan_meshes[key] = m
	return m


## Unshaded, alpha-blended, vertex colour, both faces; volumes draw before lines (render_priority).
static func _scan_material(prio: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.render_priority = prio
	return m


static func _a(alpha: float, col: Color = GREEN) -> Color:
	return Color(col.r, col.g, col.b, alpha)


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, ca: Color, cb: Color, cc: Color) -> void:
	st.set_color(ca)
	st.add_vertex(a)
	st.set_color(cb)
	st.add_vertex(b)
	st.set_color(cc)
	st.add_vertex(c)


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, ca: Color, cb: Color, cc: Color,
		cd: Color) -> void:
	_tri(st, a, b, c, ca, cb, cc)
	_tri(st, a, c, d, ca, cc, cd)


## A thin square-section bar from a to b, `w` across (reads the same from any side), colour ca at a to cb at b.
static func _bar(st: SurfaceTool, a: Vector3, b: Vector3, w: float, ca: Color, cb: Color) -> void:
	var d := b - a
	if d.length() < 1e-5:
		return
	var dn := d.normalized()
	var p := dn.cross(Vector3.UP if absf(dn.y) < 0.95 else Vector3.RIGHT).normalized() * w * 0.5
	var q := dn.cross(p).normalized() * w * 0.5
	var ofs := [p + q, p - q, -p - q, -p + q]
	for i in 4:
		var o1: Vector3 = ofs[i]
		var o2: Vector3 = ofs[(i + 1) % 4]
		_quad(st, a + o1, a + o2, b + o2, b + o1, ca, ca, cb, cb)


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
	return LowPolyPalette.ORANGE


## The drone body: a flat hub, four arms, a sensor ball underneath; accent hub, grey arms. Cached per colour.
static func body_mesh(accent: Color) -> ArrayMesh:
	return CombatMeshes._mesh("drone|%s" % accent.to_html(), func(k: MeshKit) -> void:
		k.box(Vector3(0.7, 0.22, 0.7), accent)
		k.box(Vector3(0.45, 0.14, 0.45), accent.darkened(0.25), Vector3(0, 0.17, 0))
		for i in 4:
			var ang := PI * 0.25 + PI * 0.5 * i
			var tip := Vector3(cos(ang), 0.0, sin(ang)) * 0.8
			k.tube(Vector3(0, 0.02, 0), tip, 0.05, 4, LowPolyPalette.GUN)
			k.tube(tip - Vector3(0, 0.1, 0), tip + Vector3(0, 0.1, 0), 0.08, 6, LowPolyPalette.GUN)
		k.glow = true
		k.ico(Vector3(0, -0.16, 0), Vector3.ONE * 0.12, GREEN))


## One rotor: a thin flat bar (spun about its local Y each step).
static func rotor_mesh() -> ArrayMesh:
	return CombatMeshes._mesh("drone_rotor", func(k: MeshKit) -> void:
		k.box(Vector3(0.62, 0.02, 0.08), Color(0.12, 0.12, 0.13)))
