class_name MechController
extends CharacterBody3D
## The mech's body in the world: a kinematic character (no rigid bodies, so motion can be replayed) whose "up" follows
## the ring's gravity at its position (RingFrame). It turns, walks/runs and strafes from an input vector, falls along
## local gravity, and keeps its basis upright to the local floor every physics frame.
##
## Stepping up: a ledge no higher than `max_step_up` above the feet is climbed, not a wall. When a move is blocked by
## an edge that low, the body rises along local up (at `climb_speed`) and retries the move, so it rides over the edge
## instead of popping onto it. Anything taller blocks: use the thrusters. The origin is at the feet.
##
## Thrusters (S2): `thrust_input` (Space) pushes along local up at `thrust_accel` (more than gravity, so it lifts),
## costing heat. On a long fall an automatic landing burn fires as late as is safe (a "suicide burn", AUTO_LAND_ON) and
## brakes only to `auto_land_speed` (16 m/s): the touchdown is a heavy `hard_landing` (camera dip, audio, rig) but below
## PlayerTarget's fall-damage speed (20). The touchdown point is swept with the capsule's bottom under the feet and ahead
## along the ground-plane velocity (landing_distance), so roof edges and lower roofs count. Shut down (or overheating
## mid-burn) = no burn: the fall is uncushioned (leg damage, docs/design/weapons.md "Fall damage"). Heat is the primary limit: thrust, walking and running heat, the frame cools; at `heat_cap` the mech
## SHUTS DOWN (no move, no thrust), cools to `reboot_heat`, then reboots after `reboot_time` spent at or under it (heat
## climbing back over `reboot_heat` while shut down, from add_heat or anything else, restarts that countdown).
##
## Blocked motion: vertical velocity is reconciled with the motion move_and_slide achieved (_reconcile), a body jammed in
## the air is zeroed and nudged free (_unstick), and speed is capped at MAX_SPEED, so gravity never piles up while the
## mech cannot move (no fling, no false hard landing).
##
## Per chassis (apply_chassis, from MechCatalog's "movement" block; MechSpawn applies it on every machine): speeds, turn,
## accel, thrust, heat, landing thresholds and the capsule. Height is limited by heat alone: the Bulwark's pilot thrust
## heats much faster (`thrust_heat`) than its automatic landing burn (`auto_burn_heat`), so it can push a climb but
## pays for it, and the safety burn is not starved (user playtest 2026-11-25: no artificial hop ceiling).
##
## Input comes from whoever drives it (player, lab bot, later the network for puppets): set `move_input`, `turn_input`,
## `running` and `thrust_input`. Heat from outside goes through the verbs `add_heat()` and `reset_heat()` (the controller
## is the only writer of heat / shutdown on the owner's machine).
##
## Networking: the owner's machine runs this; position, velocity and facing (engine properties) will be streamed by the
## mech codec in S7. Remote copies will be interpolated puppets, not simulated.
##
## HOVER BRANCH (docs/design/wasp-hover.md; the Wasp, MechCatalog entry "move" "hover": `hover_mode`, set by
## apply_chassis): step() runs _step_hover() instead, the biped path is untouched. No gravity while it flies: move_input
## moves it at walk_speed (cruise) / run_speed (`running` = boost) the same forward and sideways, accel toward the wanted
## velocity and, with no move input, a drift that eases to a stop (hover_drag x speed + hover_brake). `climb_input`
## (-1..1: Space / Ctrl) climbs / descends at climb_rate (eased at climb_accel; the descent slows near the surface, so it
## settles gently). With no climb input it HOLDS its height above the SURFACE UNDER IT (_surface_alt: the capsule's
## footprint swept down under the feet, and under where its ground-plane velocity takes it in hover_ahead s, swept from
## as high as the deck above allows, so a roof ahead lifts it before it gets there and a ledge behind it is only left once
## the footprint is clear of it), never lower than hover_height and never into the slab above (headroom()). No altitude cap:
## only collision stops it, so it flies through ceiling openings and shafts. Touching a walkable floor (floor_max_angle)
## while descending, falling or with a hard impact LANDS it (grounded(): on its legs, zero velocity, it turns but does
## not move; climb_input > 0 lifts off); a steeper face never lands it, it slides down along it. Shut down or with a
## dead fan (can_fly() false) it falls under gravity onto its legs (hard_landing as for walkers) and, rebooted, stays
## landed until climb_input lifts it off. Heat: hovering in place costs nothing, moving walk_heat .. run_heat by speed
## like a walker, climbing up to run_heat (the larger of the two), cooling x landed_cooling while landed. thrust_input,
## auto_burn and the step-up are not used. Hooks for every chassis: can_fly(), working_fans(), altitude(), headroom().

var ring: RingFrame                  ## the deck this mech stands on; null = flat world (+Y up)
var walk_speed := 12.0               ## m/s
var run_speed := 22.0                ## m/s
var strafe_scale := 1.0              ## sideways speed as a fraction of forward speed (full-speed strafe for clean dodging)
var accel := 30.0                    ## m/s^2 toward the wanted velocity (walk in 0.4 s, run in 0.7 s)
var turn_rate := 1.8                 ## rad/s at full turn input
var gravity := 22.0                  ## m/s^2 along local down (mechs fall heavy)
var max_step_up := 0.0               ## highest ledge (m above the feet) the legs step onto; 0 = none
var climb_speed := 10.0              ## m/s the body rises while stepping up (keeps pace with the walk)
var thrust_accel := 34.0             ## m/s^2 along local up while thrusting (gravity is subtracted)
var air_control := 0.35              ## share of `accel` available while airborne
var thrust_heat := 24.0              ## heat per second of the pilot's thrust
var auto_burn_heat := 24.0           ## heat per second of the automatic landing burn at full throttle
var walk_heat := 2.5                 ## heat/s walking at walk_speed (scales with ground speed; docs/design/weapons.md)
var run_heat := 9.0                  ## heat/s running at run_speed (lerps from walk_heat above walk_speed)
var cooling := 9.0                   ## heat shed per second
var heat_cap := 100.0                ## overheat: shutdown
var reboot_heat := 35.0              ## cooled to this, the reboot starts
var reboot_time := 1.2               ## seconds of reboot before control returns
var auto_burn := true                ## emergency burn on long falls
var safe_land_speed := 10.0          ## m/s down: landings at or below this are soft
var hard_land_speed := 18.0          ## m/s down: landings at this or more are the worst hard landing
var auto_land_speed := 16.0          ## m/s down: the automatic burn brakes a fall only to this (a heavy landing, below
                                     ## PlayerTarget.FALL_DAMAGE_SPEED 20 with headroom: tests/test_auto_land.gd)
var chassis_id := "strider"          ## the MechCatalog chassis whose movement block was applied (apply_chassis)
## Hover chassis only (apply_chassis, from the movement block's MechCatalog.HOVER_KEYS; a biped never reads them):
var hover_mode := false              ## the chassis flies (MechCatalog entry "move" "hover"): step() takes the hover branch
var climb_rate := 9.0                ## m/s up / down at full climb_input
var climb_accel := 18.0              ## m/s^2 toward the wanted vertical speed (climb, descend, height hold)
var hover_drag := 0.6                ## 1/s: with no move input the drift slows by this share of its speed per second ...
var hover_brake := 3.0               ## m/s^2 ... plus this constant brake (it eases to a stop, does not stop dead)
var hover_height := 3.0              ## m: the lowest height it holds above the surface under it
var hover_ahead := 1.2               ## s of ground-plane velocity it looks ahead for a rising surface
var landed_cooling := 1.5            ## cooling multiplier while landed

signal hard_landing(speed: float, severity: float)   ## severity 0..1 above safe_land_speed
signal overheated
signal rebooted

var move_input := Vector2.ZERO       ## x = strafe right, y = forward; length <= 1
var turn_input := 0.0                ## -1 left .. +1 right
var running := false
var thrust_input := false
var climb_input := 0.0               ## hover: -1 descend .. +1 climb (Ctrl / Space); bipeds ignore it (they thrust)
var fans_alive := 2                  ## hover: working lift fans (2 = all; step 2's fan damage drives it). working_fans()

var heat := 0.0                      ## 0..heat_cap
var shutdown := false                ## overheated: no control until rebooted
var thrusting := false               ## thrust applied this step (player or emergency burn)
var emergency := false               ## the thrust this step is the automatic burn
var last_impact := 0.0               ## m/s down at the last touchdown

## Co-op (docs/networking.md, mech snapshots): the crew peer whose machine drives this mech (0 = nobody's: labs, solo
## before MechSpawn sets it). A PUPPET is another machine's mech shown here: it runs no step() (no input, no physics);
## the game (scripts/mission/sync/mech_puppet.gd) writes its transform, velocity, heat and thrust state from the owner's
## snapshots, and `puppet_grounded` stands in for the floor test, so MechRig / ThrusterFx pose it as they pose your own.
var owner_peer := 0
var puppet := false
var puppet_grounded := true          ## a puppet's grounded(): the owner's, from its snapshot

var _climbing := false               ## rising over a ledge this step (counts as grounded)
var _reboot_t := 0.0
var _was_grounded := true
var _fall_speed := 0.0               ## m/s down, last airborne step
var _wedge_t := 0.0                  ## s of consecutive wedged steps (see _unstick)
var _wedge_nudge := 0.0              ## m nudged free in this wedge episode
var _burn_throttle := 1.0            ## share of thrust_accel the automatic burn uses this step (heat scales with it)
var _probe: SphereShape3D            ## the landing probe: the capsule's bottom (radius x PROBE_SHRINK); null = a ray
var _landed := true                  ## hover: on its legs (grounded()); a hover body starts landed
var _hold := 0.0                     ## hover: the height (m) it holds above the surface under it
var _hold_free := true               ## hover: the hold is not set (climbing, falling, no surface in range): take it anew
var _stuck_t := 0.0                  ## s pushing without moving, not into a plain wall (_stuck_guard)
var _stuck_tries := 0                ## stuck nudges tried in this push (STUCK_TRIES at most)
var unstuck_count := 0               ## stuck nudges that moved the body (diagnostics, tests)
var _stuck_normals: Array[Vector3] = []   ## the faces touched in this slow stretch (_stuck_guard)

const MAX_SPEED := 150.0             ## m/s backstop (a 3-deck free fall is ~80, a long thrust climb less)
const RECONCILE_SLACK := 0.5         ## m/s of vertical speed the achieved motion may lag before it is cut back
const WEDGE_MIN_SINK := 0.2          ## m/s down asked of the body before a step can count as wedged
const WEDGE_SINK_SHARE := 0.4        ## share of the asked sink a wedged step makes at most
const WEDGE_TIME := 0.25             ## s of wedged steps before the velocity is zeroed and the nudge starts
const WEDGE_NUDGE_SPEED := 3.0       ## m/s the nudge moves the body
const WEDGE_NUDGE_MAX := 6.0         ## m of nudge per wedge episode (a slot it cannot leave keeps it, at rest)
## Automatic landing burn: it starts when braking to auto_land_speed by the touchdown point needs AUTO_LAND_ON of the
## full braking (thrust_accel - gravity), then throttles to exactly the braking still needed (about 95 % thrust), and
## lets go if that need drops under AUTO_LAND_OFF (the ground fell away). The rest of the braking is the margin that
## absorbs step size, a ramp rising ahead and a roof edge appearing late.
const AUTO_LAND_ON := 0.9
const AUTO_LAND_OFF := 0.5
const PROBE_SHRINK := 0.9            ## landing probe radius / capsule radius (a narrower graze slides off, no floor)
const PROBE_AHEAD_PAD := 0.3         ## s added to the burn time when looking ahead along the ground-plane velocity
const PROBE_AHEAD_MAX := 3.0         ## s, cap of the look-ahead time
## Stuck guard (_stuck_guard, R2.25b) and the shared collision-checked nudge (_nudge).
const STUCK_SPEED := 0.5             ## m/s: moving slower than this while pushing counts as not moving
const STUCK_TIME := 1.0              ## s of pushing without moving before a nudge (and between nudges)
const STUCK_TRIES := 4               ## nudges per push before it gives up (until the input is released or it moves)
const STUCK_WALL_SPREAD := 0.5236    ## rad (30 deg): contacts this close to their mean are one face
const STUCK_HEAD_ON := 0.85          ## the wish into that face's normal beyond this (within ~32 deg) is a plain wall
const NUDGE_DIST := 0.6              ## m per stuck nudge
const NUDGE_MIN_SHARE := 0.5         ## a nudge direction counts when the capsule moves at least this share of it
## Hover branch.
const HOVER_FANS := 2               ## lift fans of a hover chassis (can_fly needs them all)
const HOVER_PROBE := 400.0           ## m: how far down the surface under a hover body is looked for (beyond: hold height)
const HOVER_LOOK_UP := 40.0          ## m above the feet the look-ahead sweeps from (capped under the deck above)
const HEADROOM_MAX := 500.0          ## m: headroom() in the open
const SWEEP_FINE := 0.03             ## m: the probes' refined precision (_sweep)
const CAST_CHECK := 8.0              ## m: _cast re-sweeps this far before its first estimate
const HEAD_MARGIN := 0.5            ## m: the hold stays this far under the slab above
const HOLD_GAIN := 2.0               ## 1/s: wanted vertical speed per metre of height error (small errors)
const HOLD_BRAKE := 0.5              ## share of climb_accel the height hold plans to brake with (no overshoot)
const LAND_EASE := 5.0               ## m: descending, the speed eases down below this height ...
const LAND_SLOW := 0.25              ## ... to this share of climb_rate at the touchdown (about 2 m/s)
const LANDED_SNAP := 0.5             ## m: floor snap while landed (0 in flight, so a scraped ramp never holds it)
const LANDED_PRESS := 1.0            ## m/s: the press into the floor that keeps a landed body on it


func net_fields() -> Dictionary:
	return {
		"ring": Net.SPAWN, "walk_speed": Net.SPAWN, "run_speed": Net.SPAWN, "strafe_scale": Net.SPAWN, "accel": Net.SPAWN,
		"turn_rate": Net.SPAWN, "gravity": Net.SPAWN, "max_step_up": Net.SPAWN, "climb_speed": Net.SPAWN,
		"thrust_accel": Net.SPAWN, "air_control": Net.SPAWN, "thrust_heat": Net.SPAWN, "auto_burn_heat": Net.SPAWN,
		"cooling": Net.SPAWN,
		"walk_heat": Net.SPAWN, "run_heat": Net.SPAWN,
		"heat_cap": Net.SPAWN, "reboot_heat": Net.SPAWN, "reboot_time": Net.SPAWN, "auto_burn": Net.SPAWN,
		"safe_land_speed": Net.SPAWN, "hard_land_speed": Net.SPAWN, "auto_land_speed": Net.SPAWN,
		"chassis_id": Net.SPAWN,
		"move_input": Net.PRIVATE, "turn_input": Net.PRIVATE, "running": Net.PRIVATE, "thrust_input": Net.PRIVATE,
		"heat": Net.OWNER, "shutdown": Net.OWNER, "thrusting": Net.OWNER, "emergency": Net.OWNER,
		"last_impact": Net.OWNER, "puppet_grounded": Net.OWNER,
		"owner_peer": Net.SPAWN, "puppet": Net.SPAWN,
		"_climbing": Net.PRIVATE, "_reboot_t": Net.PRIVATE, "_was_grounded": Net.PRIVATE, "_fall_speed": Net.PRIVATE,
		"_wedge_t": Net.PRIVATE, "_wedge_nudge": Net.PRIVATE, "_burn_throttle": Net.PRIVATE, "_probe": Net.LOCAL,
		# Hover: tunables fixed at spawn (apply_chassis); climb_input is input like move_input. fans_alive is the owner's
		# for now (step 2 drives it from the fan components, which the snapshot carries in the leg slots: a puppet will
		# derive it from them). The landed state reaches puppets as `grounded` (the snapshot's grounded flag).
		"hover_mode": Net.SPAWN, "climb_rate": Net.SPAWN, "climb_accel": Net.SPAWN, "hover_drag": Net.SPAWN,
		"hover_brake": Net.SPAWN, "hover_height": Net.SPAWN, "hover_ahead": Net.SPAWN, "landed_cooling": Net.SPAWN,
		"climb_input": Net.PRIVATE, "fans_alive": Net.PRIVATE,
		"_landed": Net.PRIVATE, "_hold": Net.PRIVATE, "_hold_free": Net.PRIVATE,
		"_stuck_t": Net.PRIVATE, "_stuck_tries": Net.PRIVATE, "unstuck_count": Net.PRIVATE, "_stuck_normals": Net.PRIVATE,
	}


func _ready() -> void:
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	floor_snap_length = 1.2
	floor_max_angle = deg_to_rad(50.0)
	floor_stop_on_slope = true
	floor_constant_speed = true


## Take chassis `id`'s movement numbers (MechCatalog.movement: speeds, turn, accel, thrust, heat, landing thresholds,
## heat_cap / cooling) and size the collision capsule (a CollisionShape3D child holding a CapsuleShape3D, its bottom at the
## feet) to the chassis' capsule_radius / capsule_height. Every machine applies it at spawn from the crew entry's chassis
## (MechSpawn.make), so puppets carry the same numbers and nothing extra is streamed.
## `drafts`: a MechCatalog.DRAFT_CHASSIS id is itself (the hover lab and its tests: the Wasp), else the Strider (the game:
## a draft is not playable). A hover chassis (entry "move" "hover") also takes its HOVER_KEYS and sets hover_mode.
func apply_chassis(id: String, drafts: bool = false) -> void:
	chassis_id = id if MechCatalog.CHASSIS.has(id) or (drafts and MechCatalog.DRAFT_CHASSIS.has(id)) else "strider"
	var mv := MechCatalog.movement(chassis_id, drafts)
	for k: String in MechCatalog.MOVEMENT_KEYS:
		set(k, float(mv[k]))
	heat_cap = float(mv["heat_cap"])
	cooling = float(mv["cooling"])
	hover_mode = str(MechCatalog.entry(chassis_id).get("move", "")) == "hover"
	if hover_mode:
		for k: String in MechCatalog.HOVER_KEYS:
			set(k, float(mv[k]))
	for c in get_children():
		if c is CollisionShape3D and (c as CollisionShape3D).shape is CapsuleShape3D:
			var cap := (c as CollisionShape3D).shape as CapsuleShape3D
			cap.radius = float(mv["capsule_radius"])
			cap.height = float(mv["capsule_height"])
			(c as CollisionShape3D).position = Vector3(0, cap.height * 0.5, 0)
			_probe = null   # the landing probe follows the capsule's radius
			break


func up() -> Vector3:
	return ring.up_at(global_position) if ring != null else Vector3.UP


func forward() -> Vector3:
	return -global_basis.z


## Speed along the local floor.
func ground_speed() -> float:
	var u := up()
	return (velocity - u * velocity.dot(u)).length()


## On the floor, or stepping up onto a ledge.
func grounded() -> bool:
	if puppet:
		return puppet_grounded
	if hover_mode:
		return _landed   # on its legs (a hover body skimming a floor in flight is not grounded)
	return is_on_floor() or _climbing


func _physics_process(delta: float) -> void:
	if puppet:
		return   # another machine's mech: posed from its snapshots, never simulated here
	if PerfProbe.on:   # bench instrumentation (tests/bench_bot_perf.gd), off in play
		var t0 := Time.get_ticks_usec()
		step(delta)
		PerfProbe.add("mech.ctrl.bot" if str(name).begins_with("Mech_bot") else "mech.ctrl.local", Time.get_ticks_usec() - t0)
		return
	step(delta)


## One physics step (public so tests can drive it).
func step(delta: float) -> void:
	if hover_mode:
		_step_hover(delta)
		return
	var u := up()
	up_direction = u
	var live := not shutdown
	# Keep the body upright to the local floor, keeping its heading, then turn about local up.
	var f := forward() - u * forward().dot(u)
	if f.length_squared() < 1e-8:
		f = (ring.basis_at(global_position) if ring != null else Basis.IDENTITY) * Vector3.FORWARD
	f = f.normalized().rotated(u, -(turn_input if live else 0.0) * turn_rate * delta)
	global_basis = Basis(f.cross(u), u, -f)
	# Wanted velocity along the floor.
	var mv := move_input if live else Vector2.ZERO
	var wish := f * mv.y + f.cross(u) * mv.x * strafe_scale
	if wish.length() > 1.0:
		wish = wish.normalized()
	var top := run_speed if running else walk_speed
	var vert := u * velocity.dot(u)
	var flat := velocity - vert
	var on_ground := grounded()
	flat = flat.move_toward(wish * top, accel * (1.0 if on_ground else air_control) * delta)
	# Thrust: the pilot's, or the automatic landing burn on a long fall (a late "suicide burn" down to auto_land_speed:
	# AUTO_LAND_ON / AUTO_LAND_OFF above).
	var vs := velocity.dot(u)
	var was_burning := emergency
	emergency = false
	_burn_throttle = 1.0
	if live and auto_burn and not on_ground and not thrust_input and -vs > auto_land_speed:
		var brake := maxf(thrust_accel - gravity, 0.1)
		var excess := vs * vs - auto_land_speed * auto_land_speed
		var start_dist := excess / (2.0 * brake * AUTO_LAND_ON)
		var ahead := clampf((-vs - auto_land_speed) / (brake * AUTO_LAND_ON) + PROBE_AHEAD_PAD, 0.0, PROBE_AHEAD_MAX)
		var d := landing_distance(start_dist * 2.5 + 4.0, flat * ahead)   # nothing in range: need < AUTO_LAND_OFF, no burn
		var need := excess / (2.0 * maxf(d, 0.01))   # m/s^2 of braking that reaches auto_land_speed at the touchdown
		if need >= brake * (AUTO_LAND_OFF if was_burning else AUTO_LAND_ON):
			emergency = true
			_burn_throttle = clampf((need + gravity) / maxf(thrust_accel, 0.1), 0.0, 1.0)
	thrusting = live and (thrust_input or emergency)
	if thrusting:
		vert += u * thrust_accel * (_burn_throttle if emergency else 1.0) * delta
		if on_ground:
			_climbing = false   # lift off: leave the floor this step
	if on_ground and not thrusting:
		vert = Vector3.ZERO
	else:
		vert -= u * gravity * delta
	velocity = flat + vert
	var want := flat
	var p0 := global_position
	var vs0 := velocity.dot(u)
	move_and_slide()
	var moved := global_position - p0
	_reconcile(u, moved, delta)
	_climbing = _step_up(u, want, delta)
	_unstick(u, vs0, moved, delta)
	_stuck_guard(u, wish if on_ground else Vector3.ZERO, global_position - p0, delta)
	velocity = velocity.limit_length(MAX_SPEED)
	_update_heat(delta)
	_check_landing(u)


## Velocity along local up must match the motion move_and_slide achieved. In grounded mode Godot only clears velocity on
## a floor (and slides it on a ceiling): against walls, or when the capsule is jammed into two faces it cannot depenetrate
## from, the motion is blocked but `velocity` keeps whatever gravity / thrust added, so it grew ~22 m/s every second while
## the mech stood still (5767 m/s seen on a bot run) and would fling it, or land it "hard", once free. With contacts this
## step, a vertical speed the body did not actually make is cut back to the achieved one (never past zero).
func _reconcile(u: Vector3, moved: Vector3, delta: float) -> void:
	if delta <= 0.0 or get_slide_collision_count() == 0:
		return
	var vs := velocity.dot(u)
	var real := moved.dot(u) / delta
	if vs < 0.0 and real > vs + RECONCILE_SLACK:
		velocity += u * (minf(real, 0.0) - vs)
	elif vs > 0.0 and real < vs - RECONCILE_SLACK:
		velocity += u * (maxf(real, 0.0) - vs)


## Wedged: airborne by our reckoning (not grounded, not thrusting), touching something, asked to sink (vs0 below
## -WEDGE_MIN_SINK) and making less than WEDGE_SINK_SHARE of it, every step for WEDGE_TIME. A free fall, a fall grazing a
## wall and a slide down any wall steeper than floor_max_angle all make most of their sink (sin^2 50 deg = 0.59), so only
## a body held up by faces it is not standing on counts (the capsule can jitter sideways there: Godot's depenetration
## pushes it back and forth). Its velocity is phantom (zeroed: no fling, no hard landing from it), and it is nudged free
## along the summed contact normals tilted up (straight up when they cancel, as between two faces), at WEDGE_NUDGE_SPEED,
## at most WEDGE_NUDGE_MAX m per episode. Deterministic; owner only (puppets run no step()).
func _unstick(u: Vector3, vs0: float, moved: Vector3, delta: float) -> void:
	var n := get_slide_collision_count()
	var blocked := not grounded() and not thrusting and n > 0 and delta > 0.0 and vs0 < -WEDGE_MIN_SINK \
		and moved.dot(u) / delta > vs0 * WEDGE_SINK_SHARE
	if not blocked:
		_wedge_t = 0.0
		_wedge_nudge = 0.0
		return
	_wedge_t += delta
	if _wedge_t < WEDGE_TIME:
		return
	velocity = Vector3.ZERO
	_fall_speed = 0.0
	if _wedge_nudge >= WEDGE_NUDGE_MAX:
		return
	var sum := Vector3.ZERO
	for i in n:
		sum += get_slide_collision(i).get_normal()
	var dir := (sum.normalized() + u).normalized() if sum.length() > 0.5 else u
	var stepd := minf(WEDGE_NUDGE_SPEED * delta, WEDGE_NUDGE_MAX - _wedge_nudge)
	_nudge([dir, u], stepd, 0.0)   # collision-checked (the one nudge path, shared with _stuck_guard)
	_wedge_nudge += stepd


## THE nudge (the airborne wedge guard and the stuck guard both use it): try `dirs` in order and move the body by `dist`
## along the first one it can actually move along, at least `min_share` of `dist` (0: any progress). Every move is
## move_and_collide, so the capsule only goes where it fits: it stops at the first contact and never passes through
## anything (the old wedge nudge set global_position directly). True if it moved.
func _nudge(dirs: Array, dist: float, min_share: float = NUDGE_MIN_SHARE) -> bool:
	for d: Vector3 in dirs:
		if d.length_squared() < 1e-6:
			continue
		var motion := d.normalized() * dist
		var test := move_and_collide(motion, true)
		var travel := dist if test == null else test.get_travel().length()
		if travel > 1e-4 and travel >= dist * min_share:
			move_and_collide(motion)
			return true
		if test != null and travel <= 1e-4 and _slides_free(motion):
			global_position += motion   # already jammed into faces: sliding along them, into nothing new (_slides_free)
			return true
	return false


## The capsule already overlaps something (spawned or pushed into faces it cannot leave: move_and_collide refuses every
## motion from there) and `motion` takes it only deeper into nothing: at the destination it overlaps no body it does not
## overlap now, and no deeper. So a jammed body can slide out along the faces it is caught in (up out of a slot) but
## never into or through anything else.
func _slides_free(motion: Vector3) -> bool:
	var now := _overlap(Vector3.ZERO)
	if now["ids"].is_empty():
		return false
	var then := _overlap(motion)
	for id: Variant in then["ids"]:
		if not id in now["ids"]:
			return false
	return float(then["depth"]) <= float(now["depth"]) + 0.01


## What the capsule overlaps moved by `offset`: {ids: collider instance ids, depth: the deepest contact, m}.
func _overlap(offset: Vector3) -> Dictionary:
	var out := {"ids": [], "depth": 0.0}
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	var node: CollisionShape3D = null
	for c in get_children():
		if c is CollisionShape3D and (c as CollisionShape3D).shape is CapsuleShape3D:
			node = c
			break
	if space == null or node == null:
		return out
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = node.shape
	q.transform = Transform3D(global_basis, global_position + offset) * node.transform
	q.exclude = [get_rid()]
	q.collision_mask = collision_mask
	q.margin = 0.0
	for hit: Dictionary in space.intersect_shape(q, 16):
		out["ids"].append(int(hit["collider_id"]))
	var pts := space.collide_shape(q, 32)
	for i in range(0, pts.size() - 1, 2):
		out["depth"] = maxf(float(out["depth"]), pts[i].distance_to(pts[i + 1]))
	return out


## R2.25b (playtest 2026-11-26): pushing without moving for about a second nudges the mech free. Owner only (step()),
## deterministic (no randomness: the candidates come in a fixed order from the contacts and the input).
## STUCK: the pilot asks to move (`wish`: the move input in the floor plane, for a hover body also climb_input along up;
## a walker only while grounded: in the air the wedge guard above has it) AND the body made under STUCK_SPEED this step
## AND it is not a plain wall: walking (or climbing) head-on into one flat face stops there, it is not stuck. A plain
## wall is every non-floor face touched during the slow stretch (collected over it: move_and_slide may report one face a
## step) facing within STUCK_WALL_SPREAD of their mean, and the wish pushing into that mean head-on (dot under
## -STUCK_HEAD_ON: within ~32 deg; at a shallower angle a free body slides along the face, so not moving there is a snag). Contacts on more than one side (a V, a doorway narrower than the capsule, a
## corner) or a contact that is not in the wish's way (a snag on a lip or an edge) count. STUCK_TIME of that in a row
## and one nudge of NUDGE_DIST is tried: away from the summed contact normals (in the floor plane for a walker), then
## sideways right / left of the wish, then up by the step height (max_step_up, at least NUDGE_DIST) followed by the wish,
## then straight back; the first that moves the body at least NUDGE_MIN_SHARE of NUDGE_DIST is taken. Then the count
## starts over (so attempts are STUCK_TIME apart: the cooldown); after STUCK_TRIES attempts in one push it gives up
## quietly until the input is released or the body moves freely again.
func _stuck_guard(u: Vector3, wish: Vector3, moved: Vector3, delta: float) -> void:
	if delta <= 0.0 or shutdown or wish.length() < 0.1:
		_stuck_t = 0.0
		_stuck_tries = 0
		_stuck_normals.clear()
		return
	var speed := moved.length() / delta
	if speed > STUCK_SPEED:
		_stuck_t = 0.0
		_stuck_normals.clear()
		if speed > STUCK_SPEED * 2.0:
			_stuck_tries = 0
		return
	var w := wish.normalized()
	var floor_cos := cos(floor_max_angle)
	# The faces touched over the whole slow stretch (move_and_slide often reports one face per step, alternating between
	# the two sides of a V), merged when within ~8 deg.
	for i in get_slide_collision_count():
		var n := get_slide_collision(i).get_normal()
		if n.dot(u) >= floor_cos:
			continue   # a floor
		if not hover_mode:
			n -= u * n.dot(u)   # a walker pushes along the floor: compare the faces in its plane
			if n.length_squared() < 1e-6:
				continue
		n = n.normalized()
		var known := false
		for k in _stuck_normals:
			known = known or k.dot(n) > 0.99
		if not known and _stuck_normals.size() < 8:
			_stuck_normals.append(n)
	var walls := _stuck_normals
	if _plain_wall(walls, w):
		_stuck_t = 0.0
		return
	_stuck_t += delta
	if _stuck_t < STUCK_TIME or _stuck_tries >= STUCK_TRIES:
		return
	_stuck_t = 0.0
	_stuck_tries += 1
	_stuck_normals = []   # fresh for the next stretch (the candidates below read `walls`, this stretch's faces)
	var away := Vector3.ZERO
	for n in walls:
		away += n
	var side := w.cross(u)
	if side.length_squared() < 1e-6:   # a hover body climbing straight up / down: sideways = its own right
		side = forward().cross(u)
	var lift := maxf(max_step_up, NUDGE_DIST)
	var moved_free := _nudge([away, side, -side], NUDGE_DIST)
	if not moved_free:
		var test := move_and_collide(u * lift, true)
		if test == null or test.get_travel().length() >= lift * NUDGE_MIN_SHARE:
			move_and_collide(u * lift)
			moved_free = _nudge([w - u * w.dot(u)], NUDGE_DIST)
			if not moved_free:
				move_and_collide(-u * lift)   # no way forward up there: back down where it was (collision-checked)
	if not moved_free:
		moved_free = _nudge([-w], NUDGE_DIST)
	if moved_free:
		unstuck_count += 1


## Every contact facing (within STUCK_WALL_SPREAD of) the same way, and `w` pushing into it head-on.
func _plain_wall(walls: Array[Vector3], w: Vector3) -> bool:
	if walls.is_empty():
		return false
	var mean := Vector3.ZERO
	for n in walls:
		mean += n
	if mean.length_squared() < 1e-6:
		return false
	mean = mean.normalized()
	var spread := cos(STUCK_WALL_SPREAD)
	for n in walls:
		if n.dot(mean) < spread:
			return false
	return mean.dot(w) < -STUCK_HEAD_ON


## VERB: heat from outside (weapons fire, flamers, a radiator's negative heat): pushes toward shutdown at heat_cap. Shut
## down, heat that lifts it over reboot_heat restarts the reboot countdown. Owner's machine only (the victim decides).
func add_heat(amount: float) -> void:
	heat = clampf(heat + amount, 0.0, heat_cap)
	if heat >= heat_cap and not shutdown:
		_overheat()
	elif shutdown and heat > reboot_heat:
		_reboot_t = 0.0


## VERB: back to cold (redeploy, revive, reset): heat 0; an active shutdown ends at once (its reboot countdown cleared)
## and `rebooted` fires for it. Owner's machine only.
func reset_heat() -> void:
	heat = 0.0
	_reboot_t = 0.0
	if shutdown:
		_reboot()


## Shut down and cooled to reboot_heat: the reboot countdown is running (the HUD's REBOOTING, the reboot spool sound).
func is_rebooting() -> bool:
	return shutdown and heat <= reboot_heat


## Reboot rule: shut down at heat_cap; the countdown runs only while heat is at or under reboot_heat, and any step over it
## restarts it, so control returns after reboot_time spent cool enough (never early, never at once when heat drops).
func _update_heat(delta: float) -> void:
	if thrusting:
		heat += (auto_burn_heat * _burn_throttle if emergency else thrust_heat) * delta
	heat += move_heat_rate() * delta
	heat = maxf(heat - cooling * (landed_cooling if hover_mode and _landed else 1.0) * delta, 0.0)
	if heat >= heat_cap and not shutdown:
		heat = heat_cap
		_overheat()
	elif shutdown:
		if heat <= reboot_heat:
			_reboot_t += delta
			if _reboot_t >= reboot_time:
				_reboot()
		else:
			_reboot_t = 0.0
	heat = minf(heat, heat_cap)


func _reboot() -> void:
	shutdown = false
	_reboot_t = 0.0
	rebooted.emit()


## Heat/s from walking / running now: from the actual ground speed, only on the ground, live, not thrusting and with
## move input (a knockback slide or a ride with no input adds nothing). Walk: walk_heat * v / walk_speed; above it lerps
## to run_heat at run_speed, clamped there. Owner only (a puppet runs no step()).
func move_heat_rate() -> float:
	if hover_mode:
		return _hover_heat_rate()
	if puppet or shutdown or thrusting or move_input.length_squared() < 1e-4 or not grounded():
		return 0.0
	var v := ground_speed()
	if v <= walk_speed:
		return walk_heat * v / maxf(walk_speed, 0.01)
	return lerpf(walk_heat, run_heat, clampf((v - walk_speed) / maxf(run_speed - walk_speed, 0.01), 0.0, 1.0))


func _overheat() -> void:
	shutdown = true
	_reboot_t = 0.0
	thrusting = false
	overheated.emit()


func _check_landing(u: Vector3) -> void:
	var g := grounded()
	if not g:
		_fall_speed = maxf(-velocity.dot(u), 0.0)
	elif not _was_grounded:
		last_impact = _fall_speed
		if _fall_speed > safe_land_speed:
			var sev := clampf((_fall_speed - safe_land_speed) / maxf(hard_land_speed - safe_land_speed, 0.1), 0.0, 1.0)
			hard_landing.emit(_fall_speed, sev)
		_fall_speed = 0.0
	_was_grounded = g


## Distance down along local gravity to where the feet would touch (up to `max_dist`; max_dist when nothing is there).
## Swept with the capsule's own bottom (a sphere of its radius x PROBE_SHRINK) from `from` (default: the feet), so a
## roof edge under the capsule but beside its centre counts, and a slope reads where the body meets it; a ray when the
## mech has no capsule.
func ground_distance(max_dist: float = 200.0, from: Variant = null) -> float:
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	if space == null:
		return max_dist
	var u := up()
	var p: Vector3 = global_position if from == null else from
	var probe := _landing_probe()
	if probe == null:
		var q := PhysicsRayQueryParameters3D.create(p + u * 0.2, p - u * max_dist)
		q.exclude = [get_rid()]
		q.collision_mask = collision_mask
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			return max_dist
		return maxf(((hit["position"] as Vector3) - p).dot(-u), 0.0)
	var lift := probe.radius + 0.2
	var sq := PhysicsShapeQueryParameters3D.new()
	sq.shape = probe
	sq.transform = Transform3D(Basis.IDENTITY, p + u * lift)
	sq.motion = -u * (max_dist + 0.2)
	sq.exclude = [get_rid()]
	sq.collision_mask = collision_mask
	var res := space.cast_motion(sq)
	if res.is_empty() or float(res[0]) >= 1.0:
		return max_dist
	return maxf(float(res[0]) * (max_dist + 0.2) - 0.2, 0.0)


## The nearest touchdown distance (ground_distance) under the feet and under where the mech will be along `ahead` (its
## ground-plane velocity x the look-ahead time): a lower roof it is about to pass over counts before it is underneath.
## The look-ahead stops at a wall in the way (swept at the probe's height), so it never probes from inside a building.
func landing_distance(max_dist: float, ahead: Vector3 = Vector3.ZERO) -> float:
	var d := ground_distance(max_dist)
	var probe := _landing_probe()
	if ahead.length() < 1.0 or probe == null or not is_inside_tree():
		return d
	var space := get_world_3d().direct_space_state
	var u := up()
	var sq := PhysicsShapeQueryParameters3D.new()
	sq.shape = probe
	sq.transform = Transform3D(Basis.IDENTITY, global_position + u * (probe.radius + 0.2))
	sq.motion = ahead
	sq.exclude = [get_rid()]
	sq.collision_mask = collision_mask
	var res := space.cast_motion(sq)
	var reach := ahead * (float(res[0]) if not res.is_empty() else 1.0)
	for k in [1.0 / 3.0, 2.0 / 3.0, 1.0]:
		d = minf(d, ground_distance(max_dist, global_position + reach * k))
	return d


func _landing_probe() -> SphereShape3D:
	if _probe == null:
		for c in get_children():
			if c is CollisionShape3D and (c as CollisionShape3D).shape is CapsuleShape3D:
				_probe = SphereShape3D.new()
				_probe.radius = ((c as CollisionShape3D).shape as CapsuleShape3D).radius * PROBE_SHRINK
				break
	return _probe


## After a blocked move: if what blocked it is an edge within max_step_up of the feet, rise and retry. True if it did.
func _step_up(u: Vector3, want: Vector3, delta: float) -> bool:
	if max_step_up <= 0.0 or want.length() < 0.2:
		return false
	var dir := want.normalized()
	var floor_cos := cos(floor_max_angle)
	var low_edge := false
	for i in get_slide_collision_count():
		var c := get_slide_collision(i)
		var n := c.get_normal()
		if n.dot(u) >= floor_cos or n.dot(dir) > -0.1:
			continue   # a floor, or not in the way
		var h := (c.get_position() - global_position).dot(u)
		if h > max_step_up:
			return false   # a wall
		if h > 0.02:
			low_edge = true
	if not low_edge:
		return false
	var rise := move_and_collide(u * climb_speed * delta)
	if rise != null and rise.get_travel().length() < 1e-4:
		return false   # no headroom
	move_and_collide(want * delta)
	velocity = want
	return true


# --- Hover branch (hover_mode: the Wasp; see the header) ---------------------------------------------------------

## Hover hook: the fans can hold it up (a hover chassis, all its fans working, not shut down). Always false on a biped.
## (Downed, PlayerTarget.disabled, joins this in step 2: a dead fan downs it, docs/design/wasp-hover.md.)
func can_fly() -> bool:
	return hover_mode and not shutdown and working_fans() == HOVER_FANS


## Hover hook: working lift fans, 0..2 (0 on a biped).
func working_fans() -> int:
	return clampi(fans_alive, 0, HOVER_FANS) if hover_mode else 0


## Hook (every chassis): metres from the feet down to the surface straight under it (the capsule's footprint swept down,
## like ground_distance, but refined: _sweep; about 0 standing or landed); HOVER_PROBE when nothing is in range. A physics
## query: works on puppets.
func altitude() -> float:
	return _drop(global_position, HOVER_PROBE)


## Hook (every chassis): metres of free air above the capsule's top, up to the slab of the deck above or the roof of an
## opening (the capsule's top swept up); HEADROOM_MAX in the open. A physics query: works on puppets.
func headroom() -> float:
	var cap := _capsule_shape()
	var probe := _landing_probe()
	if cap == null or probe == null or not is_inside_tree():
		return HEADROOM_MAX
	var d := _cast(probe, global_position + up() * (cap.height - cap.radius), up(), HEADROOM_MAX)
	if d >= HEADROOM_MAX:
		return HEADROOM_MAX
	return maxf(d - (cap.radius - probe.radius), 0.0)


## How far `shape` (unrotated) moves from `from` along `motion` before it touches anything (excluding this body), the
## motion's full length when nothing is in the way. Refined (a single cast_motion is only good to about 1/256 of its
## length: ~1.7 m over a 400 m probe): each pass re-casts from the last safe point across the uncertain span, until
## that span is under SWEEP_FINE.
func _sweep(shape: Shape3D, from: Vector3, motion: Vector3) -> float:
	var total := motion.length()
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	if space == null or total < 1e-6:
		return total
	var dir := motion / total
	var sq := PhysicsShapeQueryParameters3D.new()
	sq.shape = shape
	sq.exclude = [get_rid()]
	sq.collision_mask = collision_mask
	var start := 0.0
	var span := total
	for i in 6:
		sq.transform = Transform3D(Basis.IDENTITY, from + dir * start)
		sq.motion = dir * span
		var res := space.cast_motion(sq)
		if res.is_empty() or float(res[0]) >= 1.0:
			return total if i == 0 else start + span
		var safe := float(res[0]) * span
		var unsafe := float(res[1]) * span
		start += safe
		if unsafe - safe < SWEEP_FINE:
			return start
		span = unsafe - safe + SWEEP_FINE
	return start


## Metres from `from` down (local gravity) to where the capsule's bottom would touch (ground_distance's probe, refined by
## _sweep); `max_dist` when nothing is within it. Negative never (0 when already touching).
func _drop(from: Vector3, max_dist: float) -> float:
	var probe := _landing_probe()
	if probe == null:
		return ground_distance(max_dist, from)
	var u := up()
	var d := _cast(probe, from + u * (probe.radius + 0.2), -u, max_dist + 0.2)
	if d >= max_dist + 0.2 - 1e-4:
		return max_dist
	return maxf(d - 0.2, 0.0)


## How far sphere `shape` travels from `center` along unit `dir` (at most `length`) before touching anything, robustly: a
## long cast_motion can overshoot a thin floor by tens of metres (seen on the 1 m test floor from 70 m up), so the
## result is capped by a ray along the centre line (exact; the sphere meets that surface no later) and then re-swept
## over the last CAST_CHECK m before it (short casts are accurate), which finds the contact to SWEEP_FINE.
func _cast(shape: SphereShape3D, center: Vector3, dir: Vector3, length: float) -> float:
	var x := _sweep(shape, center, dir * length)
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	if space == null:
		return x
	var q := PhysicsRayQueryParameters3D.create(center, center + dir * (length + shape.radius))
	q.exclude = [get_rid()]
	q.collision_mask = collision_mask
	var hit := space.intersect_ray(q)
	if not hit.is_empty():
		x = minf(x, maxf(((hit["position"] as Vector3) - center).dot(dir) - shape.radius, 0.0))
	if x >= length - 1e-4:
		return length
	var a := maxf(x - CAST_CHECK, 0.0)
	var span := x - a + 0.3
	var x2 := _sweep(shape, center + dir * a, dir * span)
	return a + x2 if x2 < span - 1e-4 else x


## Placing a hover body (a lab, a test, later a respawn): on its legs (`on`) or flying, holding its height from the
## next step. Owner's machine only. No effect on a biped.
func set_landed(on: bool) -> void:
	if not hover_mode:
		return
	_landed = on
	_was_grounded = on
	_hold_free = true


func _capsule_shape() -> CapsuleShape3D:
	for c in get_children():
		if c is CollisionShape3D and (c as CollisionShape3D).shape is CapsuleShape3D:
			return (c as CollisionShape3D).shape as CapsuleShape3D
	return null


## One physics step of a hover body (step() calls it when hover_mode).
func _step_hover(delta: float) -> void:
	var u := up()
	up_direction = u
	var live := not shutdown
	var fly := can_fly()
	thrusting = false
	emergency = false
	_climbing = false
	_burn_throttle = 1.0
	# Heading: upright to the local floor, turned about local up (landed too).
	var f := forward() - u * forward().dot(u)
	if f.length_squared() < 1e-8:
		f = (ring.basis_at(global_position) if ring != null else Basis.IDENTITY) * Vector3.FORWARD
	f = f.normalized().rotated(u, -(turn_input if live else 0.0) * turn_rate * delta)
	global_basis = Basis(f.cross(u), u, -f)
	if _landed and fly and climb_input > 0.0:
		_landed = false   # lift off
		_hold_free = true
	if _landed:
		# On its legs: pressed onto the floor, no translation. The floor gone from under it: it flies on (or falls).
		floor_snap_length = LANDED_SNAP
		velocity = -u * LANDED_PRESS
		move_and_slide()
		velocity = Vector3.ZERO
		if not is_on_floor():
			var gap := _drop(global_position, LANDED_SNAP)
			if gap < LANDED_SNAP:
				move_and_collide(-u * (gap + 0.02))   # set down just above the floor (a placement, a small step): settle on it
			else:
				_landed = false   # the floor went away: it flies on (or falls)
				_hold_free = true
		_update_heat(delta)
		_check_landing(u)
		return
	floor_snap_length = 0.0
	var vs := velocity.dot(u)
	var flat := velocity - u * vs
	var push := Vector3.ZERO   # what the pilot asks for (the stuck guard)
	if fly:
		var mv := move_input if live else Vector2.ZERO
		var wish := f * mv.y + f.cross(u) * mv.x * strafe_scale
		if wish.length() > 1.0:
			wish = wish.normalized()
		push = wish + u * clampf(climb_input, -1.0, 1.0)
		var top := run_speed if running else walk_speed
		if wish.length_squared() > 1e-4:
			flat = flat.move_toward(wish * top, accel * delta)
		else:
			flat = flat.move_toward(Vector3.ZERO, (hover_drag * flat.length() + hover_brake) * delta)
		vs = move_toward(vs, _wanted_climb(u, flat, vs, wish * top), climb_accel * delta)
	else:
		# Fans stopped (shut down, a dead fan): it falls under gravity, its drift easing off.
		_hold_free = true
		flat = flat.move_toward(Vector3.ZERO, (hover_drag * flat.length() + hover_brake) * delta)
		vs -= gravity * delta
	velocity = flat + u * vs
	var p0 := global_position
	var vs0 := vs
	move_and_slide()
	var moved := global_position - p0
	_reconcile(u, moved, delta)
	_unstick(u, vs0, moved, delta)
	_stuck_guard(u, push, global_position - p0, delta)
	velocity = velocity.limit_length(MAX_SPEED)
	# Touchdown on a walkable floor: descending, falling, or an impact. Skimming a floor in flight does not land it.
	# Falling and wedged on edges it cannot stand on as a floor, the nudge spent (_unstick holds it at rest): it sits there.
	if (is_on_floor() and (not fly or climb_input < 0.0 or vs0 < -safe_land_speed)) \
			or (not fly and _wedge_t >= WEDGE_TIME and _wedge_nudge >= WEDGE_NUDGE_MAX):
		_landed = true
		velocity = Vector3.ZERO
		_wedge_t = 0.0
		_wedge_nudge = 0.0
	_update_heat(delta)
	_check_landing(u)


## The vertical speed a flying hover body wants now: the pilot's climb / descend, else the height hold (see the header).
func _wanted_climb(u: Vector3, flat: Vector3, vs: float, wish: Vector3 = Vector3.ZERO) -> float:
	var room := headroom()
	var alt := _surface_alt(u, flat, room, wish)
	if absf(climb_input) > 0.01:
		_hold_free = true
		var want := clampf(climb_input, -1.0, 1.0) * climb_rate
		if want < 0.0 and alt < INF:
			want *= clampf(alt / LAND_EASE, LAND_SLOW, 1.0)   # a gentle touchdown
		return want
	if alt == INF:
		_hold_free = true   # nothing under it in range: keep its height; the hold is taken when a surface shows
		return 0.0
	if _hold_free:
		_hold_free = false
		_hold = alt + vs * absf(vs) / (2.0 * maxf(climb_accel, 0.1))   # where braking now stops it
	_hold = maxf(_hold, hover_height)
	_hold = minf(_hold, alt + room - HEAD_MARGIN)   # never hold it into the slab above
	var e := _hold - alt
	return signf(e) * minf(climb_rate, minf(absf(e) * HOLD_GAIN, sqrt(2.0 * climb_accel * HOLD_BRAKE * absf(e))))


## Metres from the feet down to the highest surface under the capsule's footprint here and along `flat` x hover_ahead
## (negative: a roof ahead above the feet); INF when none is within HOVER_PROBE. The look-ahead is swept from as high
## as the deck above allows (HOVER_LOOK_UP at most) and stops at a wall, then probes down from three points along it.
## `wish` (the wanted ground-plane velocity) stands in for `flat` when it is longer: pressed against a tall wall the body
## barely moves, but it still looks over the wall it is trying to cross.
func _surface_alt(u: Vector3, flat: Vector3, room: float, wish: Vector3 = Vector3.ZERO) -> float:
	var d := _drop(global_position, HOVER_PROBE)
	var best := d if d < HOVER_PROBE else INF
	var ahead := (wish if wish.length() > flat.length() else flat) * hover_ahead
	var probe := _landing_probe()
	var cap := _capsule_shape()
	if ahead.length() < 1.0 or probe == null or cap == null or not is_inside_tree():
		return best
	var lift := clampf(cap.height + room - probe.radius - 0.3, probe.radius + 0.2, HOVER_LOOK_UP)
	var reach := ahead.normalized() * _cast(probe, global_position + u * lift, ahead.normalized(), ahead.length())
	var h0 := lift - probe.radius - 0.2   # _drop starts its sphere that far above `from`
	for k: float in [1.0 / 3.0, 2.0 / 3.0, 1.0]:
		var dd := _drop(global_position + reach * k + u * h0, h0 + HOVER_PROBE)
		if dd < h0 + HOVER_PROBE:
			best = minf(best, dd - h0)
	return best


## Heat/s of a hover body's flight now (move_heat_rate): nothing landed, shut down or hovering in place; moving like a
## walker (walk_heat at walk_speed, lerping to run_heat at run_speed, with move input), climbing up to run_heat at
## climb_rate (with climb input); the larger of the two. Owner only (a puppet runs no step()).
func _hover_heat_rate() -> float:
	if puppet or _landed or not can_fly():
		return 0.0
	var climb := 0.0
	var vs := velocity.dot(up())
	if climb_input > 0.01 and vs > 0.0:
		climb = run_heat * clampf(vs / maxf(climb_rate, 0.01), 0.0, 1.0)
	var move := 0.0
	if move_input.length_squared() >= 1e-4:
		var v := ground_speed()
		if v <= walk_speed:
			move = walk_heat * v / maxf(walk_speed, 0.01)
		else:
			move = lerpf(walk_heat, run_heat, clampf((v - walk_speed) / maxf(run_speed - walk_speed, 0.01), 0.0, 1.0))
	return maxf(move, climb)
