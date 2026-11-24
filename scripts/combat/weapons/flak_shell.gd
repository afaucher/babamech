class_name FlakShell
extends Projectile
## A flak shell (weapons.md §3.10): a fast straight Projectile with a PROXIMITY FUSE. It bursts (splash + an explosive
## impact) at the first of:
##   - a direct hit (target, world geometry, city prop: Projectile's swept first_hit, armed or not). A struck target takes
##     ONE Hit: direct damage + its splash share (so a client's hit on a host-owned target is one combat.hit, never split
##     into two the host would drop as a repeat); everyone else in the radius takes the normal splash;
##   - the FUSE, once armed (arm_distance m from the muzzle): the shell's path passes within fuse_radius m of a hit sphere
##     of any target CombatWorld.spares does NOT spare for this shooter (enemies always, teammates only with friendly fire
##     on, never the shooter). Swept per chord, not per frame: for each hit sphere (centre c, radius r) the flight time of
##     closest approach e* = (c - origin) . dir / speed; the shell bursts at e_b = clamp(e*, max(chord start, arm time),
##     chord end) when e* <= chord end (the closest approach has been reached) and the distance from flight_pos(e_b) to
##     the sphere is <= fuse_radius. So the burst point is the CLOSEST-APPROACH point on the path (or the arming point,
##     when the closest approach came before arming and the shell is still inside the radius there), the same at any frame
##     step for a still target. Damage then goes through CombatWorld.splash (no exclusion: the fused target takes its
##     share by the linear falloff, decided on the usual machine);
##   - the end of its range: an air burst (splash + impact), like the rocket's.
## Every machine runs the fuse against its own view of the targets; only the deciding machine's splash counts (the same
## accepted gap as a missile's detonation: the burst point may differ slightly between machines). No new message.
## The proximity scan reads world.targets (hit spheres via world_spheres) and never damages anything itself.
## ARMOUR (§3.10): stats.armor_mult (0.35) on an armoured target is applied by CombatWorld (armor_scaled, in resolve_hit
## and splash), so the struck target's combined Hit and every splash share are scaled once there, not here.

const BURST_NONE := ""
const BURST_DIRECT := "direct"       ## struck a target
const BURST_CONTACT := "contact"     ## struck world geometry or a prop
const BURST_FUSE := "fuse"           ## proximity fuse
const BURST_RANGE := "range"         ## end of range air burst

var fuse_radius := 6.0
var arm_time := 0.0                  ## flight time at which the fuse arms (arm_distance / speed)
var burst := BURST_NONE              ## how it ended (tests, the lab readout)
var burst_point := Vector3.INF       ## where it burst
var fused_by := ""                   ## the target id the fuse fired on ("" otherwise)


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({"fuse_radius": Net.SPAWN, "arm_time": Net.SPAWN, "burst": Net.LOCAL, "burst_point": Net.LOCAL, "fused_by": Net.LOCAL})
	return f


func start(w: CombatWorld, rec: Dictionary, st: Dictionary) -> void:
	super.start(w, rec, st)
	fuse_radius = maxf(float(st.get("fuse_radius", 6.0)), 0.0)
	arm_time = maxf(float(st.get("arm_distance", 12.0)), 0.0) / speed


## The fuse over flight times ea -> eb: {"e": burst flight time, "target": id} for the earliest qualifying hit sphere,
## or {}. Read-only over world.targets.
func fuse_check(ea: float, eb: float) -> Dictionary:
	var lo := maxf(ea, arm_time)
	if eb < lo or fuse_radius <= 0.0:
		return {}
	var sh := str(record.get("shooter", ""))
	var team := world._team_of(sh, str(record.get("team", "")))
	var best_e := INF
	var best_id := ""
	for t in world.targets:
		if not is_instance_valid(t) or not t.is_hittable() or world.spares(team, t, sh):
			continue
		for s: Dictionary in t.world_spheres():
			var c: Vector3 = s["center"]
			var es := (c - origin).dot(dir) / speed
			if es > eb:
				continue            # still closing: the closest approach is in a later chord
			var e := clampf(es, lo, eb)
			if e >= best_e:
				continue
			if flight_pos(e).distance_to(c) - float(s["radius"]) <= fuse_radius:
				best_e = e
				best_id = t.target_id
	if best_e == INF:
		return {}
	return {"e": best_e, "target": best_id}


func _sweep(e0: float, e1: float) -> void:
	var fz := fuse_check(e0, e1)
	if fz.is_empty():
		super._sweep(e0, e1)
		return
	var ef := float(fz["e"])
	if ef > e0 + 1e-9:
		super._sweep(e0, ef)        # a direct hit, wall or prop before the fuse point wins
	if end_time >= 0.0:
		return
	end_time = ef
	_swept = ef
	fused_by = str(fz["target"])
	_burst(BURST_FUSE, flight_pos(ef), -dir, null, MechMeshes.GREY)


func on_hit(h: Dictionary, e: float) -> bool:
	var target: CombatTarget = h["target"]
	var fdir := flight_dir(e)
	var point: Vector3 = h["point"]
	if target != null:
		pierced.append(target.target_id)
		var dmg := float(stats.get("damage", 0.0)) * Combat.falloff(stats, flight_dist(e)) + splash_share(target, point)
		world.resolve_hit(record, stats, target, str(h["component"]), point, h["normal"], fdir, dmg)
	world.hit_prop(record, stats, h, fdir)
	_burst(BURST_DIRECT if target != null else BURST_CONTACT, point, h["normal"], target, h.get("color", MechMeshes.GREY))
	return true


func reach_range() -> void:
	end_time = max_time
	_burst(BURST_RANGE, flight_pos(max_time), -dir, null, MechMeshes.GREY)


## The splash damage `t` would take from a burst at `point` (CombatWorld.splash's rule: splash_damage × (1 - d / R), d =
## the distance to its nearest hit sphere's surface), for the struck target's single combined Hit.
func splash_share(t: CombatTarget, point: Vector3) -> float:
	var rad := float(stats.get("splash_radius", 0.0))
	if rad <= 0.0:
		return 0.0
	var best := INF
	for s: Dictionary in t.world_spheres():
		best = minf(best, maxf(point.distance_to(s["center"]) - float(s["radius"]), 0.0))
	if best > rad:
		return 0.0
	return float(stats.get("splash_damage", 0.0)) * (1.0 - best / rad)


## Splash on everyone else in range (the struck target excluded: it took its share in its Hit) and the explosive impact.
func _burst(kind: String, point: Vector3, normal: Vector3, struck: CombatTarget, surface: Color) -> void:
	burst = kind
	burst_point = point
	world.splash(record, stats, point, struck)
	world.spawn_impact(point, normal, float(stats.get("impact_radius", 1.0)), surface, bool(stats.get("explosive", true)))
