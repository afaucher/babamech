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
## its puppet target mirrors that from snapshots) or the launcher's node is gone (a self-revive drone: see SELF-REVIVE).
## REPAIR (only while on its orbit: after the rise, before `life`): each step, every target THIS MACHINE OWNS
## (CombatWorld.owns) that is not on the enemy team and stands within `radius` m (30) of the LAUNCHER (the orbit centre,
## so the orbit never makes the range flicker), measured across the launcher's up axis (horizontal), gets
## heal(heal_rate × its max HP × dt) (1 %/s), most damaged component first (CombatTarget.heal; a PlayerTarget's
## DESTROYED weapon hardpoint counts as the most damaged and is rebuilt: PlayerTarget.heal). So each machine repairs
## only its own mech (and the host its host-owned non-enemy targets): no heal is ever sent and nobody writes another
## mech's HP. Two drones of one mech (the Bulwark's two saddles) both heal: 2 %/s.
## REVIVE (docs/design/pacing-director.md "Downed, revive, respawn", DownedRules): a DOWNED PlayerTarget in range
## (revivable: disabled, not redeploying; not the launcher's own, except for a self-revive drone) is not healed: the
## machine that owns it calls PlayerTarget.revive_tick(dt, shooter) each repair step, and DownedRules.REVIVE_TIME s of
## beam stand it up in place (its owner applies the revive; nothing is sent). The scan shows on the wreck on every
## machine while it is beamed. The revive costs the drone nothing extra: the charge that launched it is the price.
## SELF-REVIVE (user decision 2026-11-26, reverses "a drone never revives its launcher"): a record with "self": true
## (WeaponRack._self_revive launched it, on the owner's machine, when its mech went down; CombatNet carries the flag) is
## a drone that revives its OWN launcher once: while self_pending() it does not die because the launcher is down (only
## when the launcher is redeploying or its node is gone), and it beams the launcher with revive_tick(dt × REVIVE_TIME /
## self_revive_time, shooter) on the launcher's owner machine (catalog `self_revive_time`, 4 s = REVIVE_TIME today). Once
## the launcher has been seen down and then standing again (or, never seen down, after SELF_GRACE s: a remote machine
## can get the launch before the snapshot that shows the launcher down), `self_done` is set and it is an ordinary drone
## for the rest of its life (heals, revives others, dies if the launcher goes down again). It also revives other downed
## crewmates in range, as any drone does.
## LOOK (cosmetic, every machine): RepairDroneLook (`look`): the flying drone and the scan on every target being
## repaired (no ground ring); this drone hands it its state each step (look.update) and never reads anything back.

const MAX_STEP := 0.25            ## s: the longest repair step (a stall or a fast-forward never heals in one burst)
const ANCHOR_GRACE := 1.0         ## s a drone waits for its launcher's node before it dies (remote: the puppet appears)
const SELF_GRACE := 2.0           ## s a self-revive drone waits to see its launcher down before it counts as done

var anchor: Callable              ## () -> Node3D: the launcher (its mech / puppet / lab model) on this machine
var pos := Vector3.ZERO           ## the drone's world position now (derived each step)
var up_dir := Vector3.UP
var healed_total := 0.0           ## HP this drone restored on this machine (tests, diagnostics)
var dead := false                 ## the launcher went down / away: removed next step
var _last := NAN                  ## clock time of the previous step
var _missing := 0.0
var _beam_targets: Array = []     ## targets beamed this step (tests)
var _dock: Dictionary = {}        ## {pos, scale, basis} of the docked drone (EquipmentLook.dock): at launch, live going home
var centre := Vector3.ZERO        ## the launcher's position now (orbit centre on the ground: range and ring measure from it)
var _follow := Vector3.ZERO       ## the smoothed orbit centre at hover height (derived each step)
var look := RepairDroneLook.new() ## the cosmetic side: drawn from this drone's state, writes none of it
var self_done := false            ## a self-revive drone that revived its launcher (or never will): ordinary from now on
var _seen_down := false           ## a self-revive drone saw its launcher down here


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({"anchor": Net.LOCAL, "pos": Net.LOCAL, "up_dir": Net.LOCAL, "healed_total": Net.LOCAL, "dead": Net.LOCAL,
		"_last": Net.LOCAL, "_missing": Net.LOCAL, "_beam_targets": Net.LOCAL, "_dock": Net.LOCAL, "centre": Net.LOCAL,
		"_follow": Net.LOCAL, "look": Net.LOCAL, "self_done": Net.LOCAL, "_seen_down": Net.LOCAL})
	return f


func start(w: CombatWorld, rec: Dictionary, st: Dictionary) -> void:
	super.start(w, rec, st)
	anchor = w.anchor_of(str(rec.get("shooter", "")))
	top_level = true
	look.setup(self, w, shooter(), t0)


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


## Launched to revive its own launcher (record "self": true; see SELF-REVIVE).
func is_self() -> bool:
	return bool(record.get("self", false))


## A self-revive drone that is out and has not revived its launcher yet (CombatWorld.self_reviving).
func self_pending() -> bool:
	return is_self() and not self_done and not finished()


## Seconds of beam a self-revive takes (catalog `self_revive_time`, default DownedRules.REVIVE_TIME's 4 s).
func self_revive_time() -> float:
	return float(stats.get("self_revive_time", 4.0))


## Dies now (no flight home): the launcher went down (WeaponRack._self_revive kills the mech's other drones first).
func kill() -> void:
	dead = true
	visible = false


## The orbit angle at clock time `now` (rad about up_dir in _frame(), 0 = the frame's +X): a pure function of the time
## since launch, identical on every machine.
func orbit_angle(now: float) -> float:
	return TAU * (now - t0) / maxf(orbit_period(), 1e-3)


## The targets the beams point at this step (the ones being repaired right now: see `repairable`).
func beamed() -> Array:
	return _beam_targets.duplicate()


## `t` is being repaired by a drone in range right now: hittable, not destroyed, and a component below full that isn't
## destroyed, or (a PlayerTarget) a destroyed weapon hardpoint (exactly when CombatTarget.heal / PlayerTarget.heal would
## restore something). The owner's own target and a puppet's streamed mirror (PlayerTarget hp / max_hp) answer the same way.
static func repairable(t: CombatTarget) -> bool:
	if t == null or not t.is_hittable() or t.destroyed():
		return false
	var player := t is PlayerTarget
	for c: String in t.hp:
		var cap := float(t.max_hp.get(c, 0.0))
		var v := float(t.hp[c])
		if cap > 0.0 and v < cap - 1e-6 and (v > 0.0 or (player and not c in PlayerTarget.CORE_COMPONENTS)):
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
	if _launcher_lost():
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
	visible = true
	look.update({"pos": pos, "up": up_dir, "frame": b, "base": base, "now": now, "dt": dt, "first": first,
		"beamed": _beam_targets, "age": age(), "life": life(),
		"rise": rise, "home": home_fraction(), "dock": _dock, "launcher": node})


## 0..1 of the flight home (0 before / at the end of its life, 1 docked).
func home_fraction() -> float:
	return clampf((age() - life()) / maxf(dock_time(), 1e-3), 0.0, 1.0)


## The docked drone's spot on the launcher now (EquipmentLook.dock), else the back mount above `base`.
func _dock_now(base: Vector3) -> Dictionary:
	var d := world.equipment_look.dock(world, shooter(), str(record.get("hardpoint", "back")))
	if d.has("pos"):
		return d
	return {"pos": base + up_dir * _launcher_back_height()}


## The launcher's PlayerTarget here (own, or the puppet's mirror), or null.
func _launcher_target() -> PlayerTarget:
	for t in world.targets:
		if is_instance_valid(t) and t.target_id == shooter() and t is PlayerTarget:
			return t as PlayerTarget
	return null


## The drone dies with its launcher: an ordinary drone when the launcher is disabled (down or redeploying); a self-revive
## drone still pending (SELF-REVIVE) only when the launcher is redeploying (it stays to revive a downed one). Also
## settles the self-revive state: launcher seen down, then standing (or never seen down within SELF_GRACE s) = done.
func _launcher_lost() -> bool:
	var lt := _launcher_target()
	if lt == null:
		return false
	if is_self() and not self_done:
		if lt.disabled:
			_seen_down = true
		elif _seen_down or age() > SELF_GRACE:
			self_done = true
	if is_self() and not self_done:
		return lt.redeploying
	return lt.disabled


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
	var r := float(stats.get("radius", 30.0))
	var rate := float(stats.get("heal_rate", 0.01))
	for t in world.targets:
		if not is_instance_valid(t) or t.team == "enemy" or not t.is_inside_tree():
			continue
		if reach_to(t.global_position) > r:
			continue
		if t is PlayerTarget and (t as PlayerTarget).revivable():
			# REVIVE (DownedRules): a downed crewmate in range (the launcher itself only for a pending self-revive drone)
			# gets the beam; the machine that owns it counts the beam toward the revive (PlayerTarget.revive_tick), every
			# machine draws the scan on it. A self-revive beams at REVIVE_TIME / self_revive_time speed.
			var own := t.target_id == shooter()
			if not own or self_pending():
				if dt > 0.0 and world.owns(t):
					var k := DownedRules.REVIVE_TIME / maxf(self_revive_time(), 1e-3) if own else 1.0
					(t as PlayerTarget).revive_tick(dt * k, shooter())
				_beam_targets.append(t)
			continue
		if dt > 0.0 and world.owns(t):
			healed_total += t.heal(rate * t.total_max_hp() * dt, shooter())
		if repairable(t):
			_beam_targets.append(t)


## The drone's level frame: up = up_dir, a fixed horizontal -Z (the orbit is measured in it; the look turns the body
## inside it).
func _frame() -> Basis:
	var fwd := up_dir.cross(Vector3.RIGHT if absf(up_dir.x) < 0.9 else Vector3.FORWARD).normalized()
	return Basis(fwd.cross(up_dir).normalized(), up_dir, -fwd).orthonormalized()


func _exit_tree() -> void:
	look.give_back()


## The look's pooled scan nodes are not our children: hide them with the drone (dead / launcher missing).
func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not visible:
		look.hide_scans()
