class_name BotFireGuard
extends RefCounted
## The AI pilots' friendly-fire guard (docs/design/hangar-bots.md §6; playtest: hangar bots hit the host with
## autocannon shells and missiles). MissionBot calls apply() every physics frame, after PlayerBot chose its slots and
## trigger and before the rack steps, for the local `--bot` mech and for every hangar bot. Pure geometry, no state.
##
## A slot fires only if its shot can't reach a crew mech (TestDrive.mechs: players' puppets, the host's own mech, other
## bots, on any machine), else it is disabled for this frame (PlayerBot sets the slots again next frame); no slot left:
## the trigger is released. Friendly mission ASSETS count too (asset_states: team "player" targets that aren't mechs, e.g.
## the defend relay, as a capsule from their hit spheres). A crew mech is a vertical capsule (HULL_R around its up axis, HULL_LO..HULL_HI m) moved
## along its velocity for the shot's travel time (at most PREDICT_MAX s).
##   direct fire (shell, bullet, slug, beam, rocket, flak, flame, missile): the line from the slot's REAL muzzle along
##     the aim, out to the weapon's full range (a miss flies on past the aim point; the railgun pierces), cut only by
##     static world geometry. Clearance: HULL_R + MARGIN + the spread cone at that distance (spread_max for blooming
##     weapons, rockets' wobble) + splash_radius (a shot may burst on anything near the line) + flak's fuse_radius +
##     MISSILE_SIDE for homing missiles (they curve onto the aim point).
##   arc (mortar): the landing point (the aim point) with splash_radius + scatter_max + MARGIN, crew moved for the
##     flight time (flight_base + flight_per_100 per 100 m), and the last stretch of the descent.
##   missiles already flying steer onto the shooter's live aim point: when one of this shooter's missiles would be led
##     into a crew mech (its path to the aim, or the aim's splash), the aim point is lifted straight up over the missile
##     (it climbs away and bursts at its lifetime) and the trigger released (missile_abort).
## Skipped when friendly fire is off (shots pass teammates).

const MARGIN := 2.0          ## m of clearance beyond a mech's hull
const HULL_R := 2.2          ## m: the least crew radius (crew mechs use PlayerTarget.body_extent: the Strider 3.63)
const HULL_LO := 0.3         ## m above its feet...
const HULL_HI := 7.8         ## ...to the least top (crew mechs: body_extent's, the Strider 11.35)
const PREDICT_MAX := 2.5     ## s: crew motion is extrapolated at most this far
const MISSILE_SIDE := 5.0    ## m: extra side clearance for a homing missile's curve
const MORTAR_DESCENT := 14.0 ## m: the mortar's last stretch checked as a line (down onto the landing point)
const ABORT_UP := 80.0       ## m: a missile abort's aim point above the missile


## Hold every slot of `rack` whose shot could reach a crew mech in `crew` (MechControllers other than `me`).
## Returns how many slots were held (0 = nothing to do). `space` (may be null) cuts lines at static geometry.
static func apply(rack: WeaponRack, world: CombatWorld, me: MechController, crew: Array, space: PhysicsDirectSpaceState3D) -> int:
	if not PerfProbe.on:
		return _apply(rack, world, me, crew, space)
	var t0 := Time.get_ticks_usec()   # bench instrumentation (tests/bench_bot_perf.gd), off in play
	var n := _apply(rack, world, me, crew, space)
	PerfProbe.add("bot.fire_guard", Time.get_ticks_usec() - t0)
	return n


static func _apply(rack: WeaponRack, world: CombatWorld, me: MechController, crew: Array, space: PhysicsDirectSpaceState3D) -> int:
	if rack == null or world == null or me == null or not world.friendly_fire:
		return 0
	var mates := crew_states(crew, me) + asset_states(world)
	if mates.is_empty():
		return 0
	var up := me.up()
	var held := 0
	var abort := missile_abort(world, rack.shooter, rack.aim_point, mates, up)
	if abort != Vector3.INF:
		rack.aim_point = abort
		rack.set_trigger(false)
		held += 1
	if not rack.trigger:
		return held
	var exclude: Array[RID] = [me.get_rid()]
	for m: Variant in crew:
		if m is CollisionObject3D and is_instance_valid(m):
			exclude.append((m as CollisionObject3D).get_rid())
	var live := 0
	for s: Dictionary in rack.slots():
		var w := str(s["weapon"])
		if not bool(s["enabled"]) or w == "" or MechCatalog.is_equipment(w):
			continue
		if slot_safe(world, w, s["muzzle"] as Vector3, rack.aim_point, mates, up, space, exclude):
			live += 1
		else:
			rack.set_enabled(int(s["slot"]), false)
			held += 1
	if live == 0 and held > 0:
		rack.set_trigger(false)
	return held


## Crew mechs as {pos, vel, up} (valid ones, never `me`).
static func crew_states(crew: Array, me: Node3D = null) -> Array:
	var out: Array = []
	for m: Variant in crew:
		if m == null or not is_instance_valid(m) or m == me or not (m is MechController):
			continue
		var mc := m as MechController
		var st := {"pos": mc.global_position, "vel": mc.velocity, "up": mc.up()}
		# Every chassis' capsule from its hit spheres (the Strider: r 3.63, top 11.35 m since its 2026-11-24 refit, which
		# outgrew HULL_R / HULL_HI; the Bulwark: r 5.1, top 8.9 m).
		var ext := PlayerTarget.body_extent(mc.chassis_id)
		st["r"] = maxf(float(ext["r"]), HULL_R)
		st["hi"] = maxf(float(ext["hi"]), HULL_HI)
		out.append(st)
	return out


## Friendly mission assets (team "player" targets that aren't mechs: the defend relays, AssetTarget) as capsules
## {pos, vel 0, up, r, lo, hi} from their hit spheres (the radius, the lowest / highest sphere's extent), so a bot never
## shoots the relay it defends.
static func asset_states(world: CombatWorld) -> Array:
	var out: Array = []
	if world == null:
		return out
	for t: Variant in world.targets:
		if t == null or not is_instance_valid(t) or t is PlayerTarget or (t as CombatTarget).mass_class == "mech":
			continue   # mechs are the crew list's
		var ct := t as CombatTarget
		if ct.team != "player" or ct.hit_shapes.is_empty() or not ct.is_inside_tree():
			continue
		var r := 0.0
		var lo := INF
		var hi := -INF
		var u := ct.up
		for sh: Variant in ct.hit_shapes:
			var d := sh as Dictionary
			var c: Vector3 = d.get("center", Vector3.ZERO)
			var rr := float(d.get("radius", 0.0))
			r = maxf(r, rr)
			lo = minf(lo, c.dot(u) - rr)
			hi = maxf(hi, c.dot(u) + rr)
		out.append({"pos": ct.global_position, "vel": Vector3.ZERO, "up": u, "r": r, "lo": lo, "hi": hi})
	return out


## True when weapon `w` fired from `muzzle` at `aim` can't reach any of `mates` ({pos, vel, up}; optional r / lo / hi:
## a capsule other than a mech's, for assets).
static func slot_safe(world: CombatWorld, w: String, muzzle: Vector3, aim: Vector3, mates: Array, up: Vector3,
		space: PhysicsDirectSpaceState3D = null, exclude: Array[RID] = []) -> bool:
	var st := world.stats(w) if world != null else MechCatalog.weapon(w)
	if st.is_empty():
		return true
	var kind := str(st.get("kind", ""))
	var splash := float(st.get("splash_radius", 0.0))
	if kind == "arc":
		return _arc_safe(st, muzzle, aim, mates, up, splash)
	var to := aim - muzzle
	if to.length_squared() < 1e-6:
		return true
	var dir := to.normalized()
	var reach := float(st.get("range", 200.0))
	var end := muzzle + dir * reach
	if space != null:
		var q := PhysicsRayQueryParameters3D.create(muzzle, end)
		q.exclude = exclude
		var hit := space.intersect_ray(q)
		if not hit.is_empty() and hit.get("collider") is StaticBody3D:
			end = hit["position"]
	var speed := float(st.get("speed", 0.0))
	if kind == "missile":
		speed = 0.5 * (speed + float(st.get("speed_max", speed)))
	var spread := maxf(float(st.get("spread", 0.0)), float(st.get("spread_max", 0.0)))
	spread += float(st.get("wobble", 0.0))
	var extra := splash + float(st.get("fuse_radius", 0.0)) + (MISSILE_SIDE if kind == "missile" else 0.0)
	for c: Dictionary in mates:
		if not _line_clear(muzzle, end, speed, spread, extra, c):
			return false
	return true


## The segment a -> b (a shot at `speed` m/s, 0 = instant; cone `spread_deg`; extra clearance `extra`) passes no closer
## than the clearance to mate `c` moved along its velocity for the time the shot takes to get there.
static func _line_clear(a: Vector3, b: Vector3, speed: float, spread_deg: float, extra: float, c: Dictionary) -> bool:
	var cu: Vector3 = c["up"]
	var vel: Vector3 = c["vel"]
	var p: Vector3 = c["pos"]
	var lo := float(c.get("lo", HULL_LO))
	var hi := float(c.get("hi", HULL_HI))
	var hr := float(c.get("r", HULL_R))
	# Twice: where the line passes the mate now, then the mate moved for the shot's time to that spot.
	for i in 2:
		var pts := Geometry3D.get_closest_points_between_segments(a, b, p + cu * lo, p + cu * hi)
		var along := a.distance_to(pts[0])
		var t := clampf(along / speed, 0.0, PREDICT_MAX) if speed > 0.0 else 0.0
		var pp: Vector3 = (c["pos"] as Vector3) + vel * t
		var pts2 := Geometry3D.get_closest_points_between_segments(a, b, pp + cu * lo, pp + cu * hi)
		var d := (pts2[0] as Vector3).distance_to(pts2[1])
		var clear := hr + MARGIN + extra + a.distance_to(pts2[0]) * tan(deg_to_rad(spread_deg))
		if d < clear:
			return false
		p = pp
	return true


static func _arc_safe(st: Dictionary, muzzle: Vector3, land: Vector3, mates: Array, up: Vector3, splash: float) -> bool:
	var d := muzzle.distance_to(land)
	var flight := float(st.get("flight_base", 2.0)) + float(st.get("flight_per_100", 1.0)) * d / 100.0
	var r := splash + float(st.get("scatter_max", 0.0)) + MARGIN
	var flat := land - muzzle
	flat -= up * flat.dot(up)
	var back := flat.normalized() * MORTAR_DESCENT * 0.5 if flat.length_squared() > 1e-4 else Vector3.ZERO
	var top := land - back + up * MORTAR_DESCENT
	for c: Dictionary in mates:
		var cu: Vector3 = c["up"]
		var lo := float(c.get("lo", HULL_LO))
		var hi := float(c.get("hi", HULL_HI))
		var hr := float(c.get("r", HULL_R))
		var pp: Vector3 = (c["pos"] as Vector3) + (c["vel"] as Vector3) * minf(flight, PREDICT_MAX)
		var q := Geometry3D.get_closest_point_to_segment(land, pp + cu * lo, pp + cu * hi)
		if q.distance_to(land) < r + hr:
			return false
		var pts := Geometry3D.get_closest_points_between_segments(top, land, pp + cu * lo, pp + cu * hi)
		if (pts[0] as Vector3).distance_to(pts[1]) < hr + MARGIN:
			return false
	return true


## This shooter's guided missiles in flight: if one would be led into a mate (its line to `aim`, or `aim`'s splash), the
## aim point that leads it away (straight up over that missile), else Vector3.INF.
static func missile_abort(world: CombatWorld, shooter: String, aim: Vector3, mates: Array, up: Vector3) -> Vector3:
	if world == null or mates.is_empty():
		return Vector3.INF
	var st := world.stats("missiles")
	var splash := float(st.get("splash_radius", 5.0))
	var speed := float(st.get("speed_max", 55.0))
	for e: Variant in world.effects:
		if not (e is Missile) or not is_instance_valid(e) or (e as Missile).finished():
			continue
		var m := e as Missile
		if m.end_time >= 0.0:
			continue   # already burst
		if str(m.record.get("shooter", "")) != shooter:
			continue
		var at := m.flight_pos(world.now - m.t0)
		for c: Dictionary in mates:
			if not _line_clear(at, aim, speed, 0.0, splash + MISSILE_SIDE, c):
				return at + up * ABORT_UP
	return Vector3.INF
