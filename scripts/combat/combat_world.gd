class_name CombatWorld
extends Node3D
## The combat container of a scene (weapons.md §5): owns the combat CLOCK, the mission seed, the registered targets and
## the live effects (shots, impacts), and is where hits are decided and delivered. One per scene; place it at the
## origin (effects draw in world space).
##
##   world.mission_seed = seed                    shot generators derive from it (Combat.shot_rng)
##   world.register(target)                       a CombatTarget becomes hittable
##   world.fire(record) -> CombatEffect           start a shot from a fire record (Combat.fire_record); a record older
##                                                than `now` is fast-forwarded by now - record.t (a late network event)
##   world.advance(dt)                            the scene calls this with ITS delta (× the lab's time scale): moves the
##                                                clock, steps targets this machine owns, advances every effect
##   world.stats(weapon_id)                       the weapon's catalog entry + the lab's `overrides`
##   world.launch_drone(record) -> RepairDrone    start a repair drone (back-equipment.md; a scheduled effect that
##                                                follows anchor_of(record.shooter): set_anchor(shooter, () -> Node3D))
##
## The clock is the shared session clock in a crew mission (set_clock(CombatNet.session_clock): now = Session.host_time,
## so fire records' `t` mean the same moment on every machine); offline (lab, tests, solo) it counts advance's deltas.
## HITS: an effect asks `first_hit` for its swept path, then calls `resolve_hit` / `splash`. Only a machine that
## `decides(target, record.peer)` builds a Hit; `deliver` applies it if this machine `owns(target)`, otherwise emits
## `remote_hit` (a client's hit on a host-owned target), which CombatNet carries to the host. A machine that doesn't
## decide still shows the impact. Fire records cross machines through CombatNet (scripts/combat/combat_net.gd).
##
## CITY PROPS (docs/design/city-props.md §5): `first_hit` also asks the props `first_hit(a, b, r)` and keeps the nearest
## of targets / world / props (a hit on a prop carries "prop": id and "prop_node": the CityProps it came from, target
## null); a direct hit calls `apply_impulse(id, dv, src)` on that node (`hit_prop`: dv = stats.knockback along the shot,
## no damage, no heat) and `splash` calls `blast(point, radius, dv, src)` (dv = stats.prop_blast, else
## splash_knockback). Props aren't CombatTargets: they are a host-arbitrated world object, so only the machine that
## decides the shot (the shooter's, as for host-owned targets) calls the verbs.
##   STACK (the mission, docs/design/city-ramps-and-stack.md): every deck has its own CityProps (ids are per deck; each
## node puts its own `deck` on its prop events, so the verbs take no deck). `stack` is the CityStack: TestDriveCombat sets
## it from td.stack, else it is found in group "city_stack" (looked up only while no props node is cached). With a
## stack, `first_hit` asks the props of every deck the swept sphere can touch (`deck_span`: stack.deck_at of the point
## nearest the shared axis and of the farthest, padded by r; one deck for almost every chord, so a shot dropping through
## a ceiling opening still meets the lower deck's props), `splash` blasts every deck within the radius of the point, and
## `hit_prop` calls the node the hit names. The ring for a point is the stack's (`ring_at` = stack.ring_at, `up_at` =
## stack.ring()). No stack (lab, district mode, single-process tests): the first node in group "city_props" (found once,
## cached) and `ring`, exactly as before.
##
## AMBIENT LIFE (docs/design/ambient-life.md §6): when a node in group "ambient_life" exists (AmbientLife; looked up
## lazily on the first call that needs it, at most every LIFE_RESCAN s of clock while missing, cached until freed), every
## shot path reports itself through `life_sweep(record, a, b, r)` -> `life.sweep(a, b, r, src)` (Projectile._sweep per
## chord, the laser's ray, each flame chunk's chord) and `splash` calls `life.blast(point, radius, src)`. Only the
## machine that decides the shot calls them (as props); src = `life_src(record)`: the shooter's peer, -1 for enemy fire.
## The kill count they return is ignored: civilians never stop or change a shot. No node: nothing is called.
##
## LIVE MUZZLES (cosmetic, local): a firer may `set_muzzle(shooter, hardpoint, callable)` returning the muzzle's world
## position now; a laser beam then follows the muzzle for its life (the hit is still resolved once at pulse start).

signal hit_landed(target: CombatTarget, hit: Hit)
## A hit this machine decided on a target another machine owns (a client's shot on a host-owned target): CombatNet
## sends it to the host, which applies it.
signal remote_hit(target_id: String, hit: Hit)
signal fired(record: Dictionary)
signal shake(strength: float, point: Vector3)
signal impact_spawned(point: Vector3, radius: float, explosive: bool, is_energy: bool)
signal advanced(dt: float, space: PhysicsDirectSpaceState3D)
## A repair drone started here (launch_drone): the launcher's own (CombatNet broadcasts it) or a remote one.
signal drone_launched(record: Dictionary, drone: RepairDrone)

const PROP_COLOR := Color(0.42, 0.4, 0.36)    ## debris colour of a prop that names none
const LIFE_RESCAN := 0.5          ## s of clock between "ambient_life" group lookups while the node is missing

var now := 0.0
var mission_seed := 0
var ring: RingFrame = null         ## optional RingFrame on curved city decks (for surface-aligned impacts)
var targets: Array[CombatTarget] = []
var effects: Array[CombatEffect] = []
## Weapon id -> {stat: value} laid over MechCatalog.WEAPONS (the lab's session tuning; empty in the game).
var overrides: Dictionary = {}
## Shooter id -> {"on": bool, "dot": Vector3}: each shooter's guided track (OWNER state of the shooter's mech, mirrored
## here for missiles to read): the local WeaponRack writes its own each step; CombatNet writes each crew puppet's from
## its owner's mech snapshot (aim point + designator flag).
var designators: Dictionary = {}
var use_physics := true           ## false: ignore world geometry (pure tests)
var looks_rng := RandomNumberGenerator.new()
## "shooter/hardpoint" -> Callable() -> Vector3: live muzzle positions on this machine (cosmetic: beams follow them).
var muzzles: Dictionary = {}
var _shooter_teams: Dictionary = {} ## shooter_id -> team string (cached from register/fire so shots skip same-team)
## The mission's CityStack, or null (no stack: one CityProps / `ring`). Duck-typed so tests can stand one in: `decks`
## (each with `props`), deck_at(p), ring(), ring_at(p). Set by TestDriveCombat; else found in group "city_stack".
var stack: Node = null
var _props: Node = null           ## the CityProps node (group "city_props"), cached (no stack only)
var _props_scan := -1.0           ## clock time of the last group lookup (at most one per step while it is missing)
var _life: Node = null            ## the AmbientLife node (group "ambient_life"), cached
var _life_scan := -INF            ## clock time of the last "ambient_life" lookup
## The shared clock (set_clock): () -> float seconds, or a negative value when there is none. Invalid (the default: the
## lab, single-process tests, the solo drive) = `now` counts the deltas given to advance.
var clock := Callable()
## Shooter id -> Callable() -> Node3D: where that shooter's mech is on this machine (its own MechController, a crew
## puppet's, the lab model). Scheduled effects that follow their launcher (the repair drone) read it. Cosmetic / local.
var anchors: Dictionary = {}
## Back-mount equipment looks on the mechs (cradle swap while a drone is out, radiator glow): cosmetic, stepped at the
## end of advance (EquipmentLook).
var equipment_look := EquipmentLook.new()
## Optional (record: Dictionary) -> bool asked by fire() first; false = the record is refused (fire returns null, nothing
## emitted). CombatNet installs one in a crew mission (enemy records on a client: host's only, no duplicates).
var fire_gate := Callable()
## True while advance() steps the targets this machine owns (an enemy's AI firing happens inside it).
var stepping_targets := false
var _ray_exclude: Array[RID] = [] ## registered targets' physics bodies (mech capsules): shot rays ignore them
var _exclude_bodies: Array = []   ## the bodies behind _ray_exclude (to notice one freed)
var _exclude_dirty := true
var _shot_query := PhysicsRayQueryParameters3D.new()


func _init() -> void:
	looks_rng.seed = 0x10C5      # looks only: never used for gameplay


func net_fields() -> Dictionary:
	return {"now": Net.LOCAL, "mission_seed": Net.SPAWN, "ring": Net.SPAWN, "targets": Net.LOCAL, "effects": Net.LOCAL, "overrides": Net.LOCAL,
		"designators": Net.LOCAL, "use_physics": Net.LOCAL, "looks_rng": Net.LOCAL,
		"muzzles": Net.LOCAL, "_shooter_teams": Net.LOCAL, "stack": Net.LOCAL, "_props": Net.LOCAL, "_props_scan": Net.LOCAL,
		"_life": Net.LOCAL, "_life_scan": Net.LOCAL, "clock": Net.LOCAL, "anchors": Net.LOCAL, "equipment_look": Net.LOCAL,
		"fire_gate": Net.LOCAL, "stepping_targets": Net.LOCAL, "_ray_exclude": Net.LOCAL, "_exclude_bodies": Net.LOCAL,
		"_exclude_dirty": Net.LOCAL, "_shot_query": Net.LOCAL}


func register(t: CombatTarget) -> void:
	if not t in targets:
		targets.append(t)
		_exclude_dirty = true
	if t.target_id != "" and t.team != "":
		_shooter_teams[t.target_id] = t.team


func unregister(t: CombatTarget) -> void:
	targets.erase(t)
	_exclude_dirty = true


## Physics bodies of registered targets (a PlayerTarget's MechController capsule, local or a crew puppet's): shots meet
## targets through their hit spheres only, so the world-geometry rays of shots ignore these bodies. Rebuilt lazily after
## register / unregister (and whenever a body is gone), never per ray.
func _body_excludes() -> Array[RID]:
	if _exclude_dirty:
		_exclude_dirty = false
		_ray_exclude.clear()
		_exclude_bodies.clear()
		for t in targets:
			if not is_instance_valid(t):
				continue
			var b: Variant = t.get("mech") if "mech" in t else null
			if b is CollisionObject3D and is_instance_valid(b):
				_ray_exclude.append((b as CollisionObject3D).get_rid())
				_exclude_bodies.append(b)
		_shot_query.exclude = _ray_exclude
	else:
		for b: Variant in _exclude_bodies:
			if not is_instance_valid(b):
				_exclude_dirty = true
				return _body_excludes()
	return _ray_exclude


## A world-geometry ray a -> b for shots and impacts: the first collider that isn't a registered target's body (see
## _body_excludes), or {}. One reused query object (no per-ray allocation).
func shot_ray(sp: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> Dictionary:
	_body_excludes()
	_shot_query.from = a
	_shot_query.to = b
	return sp.intersect_ray(_shot_query)


func stats(weapon_id: String) -> Dictionary:
	var base := MechCatalog.weapon(weapon_id)
	if base.is_empty():
		base = EnemyCatalog.weapon(weapon_id)
	var s := base.duplicate()
	s.merge(overrides.get(weapon_id, {}), true)
	return s


## Start a shot. Null when the weapon has no behaviour yet (WeaponRegistry).
func fire(record: Dictionary) -> CombatEffect:
	if fire_gate.is_valid() and not bool(fire_gate.call(record)):
		return null
	var sh := str(record.get("shooter", ""))
	var tm := str(record.get("team", ""))
	if sh != "" and tm != "":
		_shooter_teams[sh] = tm
	var b := WeaponRegistry.behaviour(str(record.get("weapon", "")))
	if b == null:
		return null
	var e := b.spawn(self, record, stats(str(record["weapon"])))
	if e == null:
		return null
	_add_effect(e)
	e.advance_to(now)
	if e is Projectile and now - float(record.get("t", now)) < MuzzleFlash.LIFE:
		var p := e as Projectile
		var mf := MuzzleFlash.new()
		_add_effect(mf)
		mf.setup(self, p.flight_pos(0.0), p.flight_dir(0.0), MuzzleFlash.size_for(p.stats), float(record.get("t", now)))
	fired.emit(record)
	return e


## Register a live muzzle for (shooter, hardpoint): `f` returns its world position now. An invalid Callable removes it.
func set_muzzle(shooter: String, hardpoint: String, f: Callable) -> void:
	var k := "%s/%s" % [shooter, hardpoint]
	if f.is_valid():
		muzzles[k] = f
	else:
		muzzles.erase(k)


## The live muzzle Callable for a fire record's shooter + hardpoint, or an invalid Callable.
func muzzle_of(record: Dictionary) -> Callable:
	var f: Variant = muzzles.get("%s/%s" % [record.get("shooter", ""), record.get("hardpoint", "")])
	return f if f is Callable and (f as Callable).is_valid() else Callable()


## Register where `shooter`'s mech is on this machine: `f` returns its Node3D. An invalid Callable removes it.
func set_anchor(shooter: String, f: Callable) -> void:
	if f.is_valid():
		anchors[shooter] = f
	else:
		anchors.erase(shooter)


func anchor_of(shooter: String) -> Callable:
	var f: Variant = anchors.get(shooter)
	return f if f is Callable and (f as Callable).is_valid() else Callable()


## Start a repair drone (back-equipment.md) from its launch record {shooter, peer, hardpoint, weapon, t}: a scheduled
## effect, fast-forwarded when t is in the past. One drone per shooter: a newer launch replaces a live one. Null when the
## record is already past the drone's life. Emits drone_launched (CombatNet sends the local launcher's).
func launch_drone(record: Dictionary) -> RepairDrone:
	var st := stats(str(record.get("weapon", "repair_drone")))
	if st.is_empty():
		st = stats("repair_drone")
	var t := float(record.get("t", now))
	if now - t >= float(st.get("life", 60.0)):
		return null
	var old := drone_of(str(record.get("shooter", "")))
	if old != null:
		remove_effect(old)
	var d := RepairDrone.new()
	d.start(self, record, st)
	_add_effect(d)
	d.advance_to(now)
	equipment_look.on_launch(self, record)
	drone_launched.emit(record, d)
	return d


## `shooter`'s live repair drone here, or null.
func drone_of(shooter: String) -> RepairDrone:
	for e in effects:
		if e is RepairDrone and is_instance_valid(e) and not e.finished() and (e as RepairDrone).shooter() == shooter:
			return e as RepairDrone
	return null


func _add_effect(e: CombatEffect) -> void:
	add_child(e)
	effects.append(e)


## Run `now` on a shared clock `f` (() -> seconds, negative = none right now; CombatNet.session_clock in a crew mission):
## advance then sets now = f() instead of adding its delta, never going backwards; while f() is negative (the session
## ended) it counts deltas again. An invalid Callable goes back to the local clock.
func set_clock(f: Callable) -> void:
	clock = f
	if f.is_valid():
		var c := float(f.call())
		if c > 0.0:
			now = maxf(now, c)


func advance(dt: float) -> void:
	if dt <= 0.0:
		return
	var c := float(clock.call()) if clock.is_valid() else -1.0
	now = maxf(now, c) if c > 0.0 else now + dt
	props()      # (re)find the city props node while it is missing
	var sp := space()
	stepping_targets = true
	for t in targets.duplicate():
		if is_instance_valid(t) and owns(t):
			t.tick(dt, sp)
	stepping_targets = false
	advanced.emit(dt, sp)
	for e in effects.duplicate():
		e.advance_to(now)
		if e.finished():
			remove_effect(e)
	equipment_look.step(self)


func remove_effect(e: CombatEffect) -> void:
	effects.erase(e)
	if e.get_parent() == self:
		remove_child(e)
	e.queue_free()


## Drop a shot by key (a hit another machine decided arrives as an event).
func remove_shot(key: String) -> void:
	for e in effects.duplicate():
		if e.key() == key:
			remove_effect(e)


func live_shots() -> int:
	var n := 0
	for e in effects:
		if e is Projectile:
			n += 1
	return n


# --- Authority ---------------------------------------------------------------------------------------

## This machine decides the shot's effect on host-arbitrated things (props): the shooter's machine.
func decides_shot(record: Dictionary) -> bool:
	return int(record.get("peer", 1)) == local_peer()


## This machine's peer id (1 offline: solo is hosting).
static func local_peer() -> int:
	var s := Net.session()
	return s.local_id() if s != null and s.online() else 1


## This machine applies verbs to `t` (it owns it).
func owns(t: CombatTarget) -> bool:
	return (t.owner_peer if t.owner_peer > 0 else 1) == local_peer()


## This machine decides hits on `t` from a shooter owned by `shooter_peer`: the victim decides about its own mech, the
## attacker's machine about host-owned targets.
func decides(t: CombatTarget, shooter_peer: int) -> bool:
	return (t.owner_peer if t.owner_peer > 0 else shooter_peer) == local_peer()


# --- Queries -----------------------------------------------------------------------------------------

func space() -> PhysicsDirectSpaceState3D:
	if not use_physics or not is_inside_tree():
		return null
	return get_world_3d().direct_space_state


func _team_of(shooter: String, fallback: String = "") -> String:
	if fallback != "":
		return fallback
	if shooter == "":
		return ""
	return str(_shooter_teams.get(shooter, ""))


## The first thing on segment a -> b: a target hit sphere (inflated by `r`, skipping `shooter` and ids in `skip`) or
## world geometry or a city prop. {} or {target (null = world / prop), component, point, normal, frac, color} (+ "prop": id
## for a prop).
func first_hit(a: Vector3, b: Vector3, r: float, shooter: String = "", skip: Array = []) -> Dictionary:
	var best := {}
	var best_f := 2.0
	var sh_team := _team_of(shooter)
	for t in targets:
		if not is_instance_valid(t) or not t.is_hittable() or t.target_id == shooter or t.target_id in skip:
			continue
		if sh_team != "" and t.team == sh_team:
			continue
		# CombatTarget.world_spheres() inlined (same maths, no per-call arrays): this runs for every target on every chord of
		# every shot. Keep the two in step.
		var xf := t.global_transform
		var sc := xf.basis.get_scale().x
		for hs: Dictionary in t.hit_shapes:
			var c: Vector3 = xf * (hs["center"] as Vector3)
			var f := Combat.segment_sphere(a, b, c, float(hs["radius"]) * sc + r)
			if f >= 0.0 and f < best_f:
				var p := a.lerp(b, f)
				best_f = f
				best = {"target": t, "component": hs["component"], "point": p, "normal": (p - c).normalized(),
					"frac": f, "color": MechMeshes.GREY}
	var sp := space()
	if sp != null and a.distance_squared_to(b) > 1e-10:
		var h := shot_ray(sp, a, b)        # mech capsules ignored: targets are hit through their spheres above
		if not h.is_empty():
			var f := a.distance_to(h["position"]) / a.distance_to(b)
			if f < best_f:
				var col: Color = MechMeshes.GREY
				var c: Object = h.get("collider")
				if c != null and c.has_meta("surface_color"):
					col = c.get_meta("surface_color")
				best = {"target": null, "component": "", "point": h["position"], "normal": h["normal"], "frac": f, "color": col}
				best_f = f
	if a.distance_squared_to(b) <= 1e-10:
		return best
	var st := city_stack()
	if st == null:
		var pr := props()
		if pr != null:
			var ph: Dictionary = pr.first_hit(a, b, r)
			if not ph.is_empty() and float(ph["frac"]) < best_f:
				best = _prop_hit(ph, pr)
		return best
	var span := deck_span(a, b, r)
	for k in range(span.x, span.y + 1):
		var dp := deck_props(k)
		if dp == null:
			continue
		var ph: Dictionary = dp.first_hit(a, b, r)
		if not ph.is_empty() and float(ph["frac"]) < best_f:
			best = _prop_hit(ph, dp)
			best_f = float(ph["frac"])
	return best


func _prop_hit(ph: Dictionary, node: Node) -> Dictionary:
	return {"target": null, "prop": ph["id"], "prop_node": node, "component": "", "point": ph["point"],
		"normal": ph["normal"], "frac": float(ph["frac"]), "color": ph.get("color", PROP_COLOR)}


## The scene's CityProps node (group "city_props") when there is no stack, or null. Looked up (once per clock step while
## missing; the same scan adopts a node in group "city_stack" when none was set), then cached until freed. With a stack
## it is null: ask deck_props / props_at.
func props() -> Node:
	if _props != null and not is_instance_valid(_props):
		_props = null
	if _props == null and is_inside_tree() and _props_scan != now:
		_props_scan = now
		if stack == null:
			stack = get_tree().get_first_node_in_group("city_stack")
		if city_stack() == null:
			_props = get_tree().get_first_node_in_group("city_props")
	return _props if city_stack() == null else null


## The stack when there is one with built decks, else null (a freed stack is forgotten).
func city_stack() -> Node:
	if stack == null:
		return null
	if not is_instance_valid(stack):
		stack = null
		return null
	var decks: Variant = stack.get("decks")
	return stack if decks is Array and not (decks as Array).is_empty() else null


## Deck k's CityProps in the stack (read from the deck each time: right after a rebuild), or null.
func deck_props(k: int) -> Node:
	var decks: Variant = stack.get("decks") if stack != null and is_instance_valid(stack) else null
	if not (decks is Array) or k < 0 or k >= (decks as Array).size():
		return null
	var d: Variant = (decks as Array)[k]
	if not is_instance_valid(d):
		return null
	var pr: Variant = (d as Object).get("props")
	return pr as Node if is_instance_valid(pr) and pr is Node else null


## The CityProps for world point p: the stack deck's under it, else the single props node (props()).
func props_at(p: Vector3) -> Node:
	var st := city_stack()
	return deck_props(int(st.deck_at(p))) if st != null else props()


## The decks (first, last; numbered from the axis out) a sphere of radius r moving a -> b can touch: stack.deck_at of the
## segment's point nearest the shared axis moved r toward it, and of the farther end moved r away. Needs city_stack().
func deck_span(a: Vector3, b: Vector3, r: float) -> Vector2i:
	var rg: RingFrame = stack.ring()
	var ax := rg.axis_point()
	var a2 := Vector2(a.y - ax.y, a.z - ax.z)    # the axis is parallel to X: distances to it live in the YZ plane
	var b2 := Vector2(b.y - ax.y, b.z - ax.z)
	var ab := b2 - a2
	var l2 := ab.length_squared()
	var near := a.lerp(b, clampf(-a2.dot(ab) / l2, 0.0, 1.0)) if l2 > 1e-12 else a
	var far := a if a2.length_squared() >= b2.length_squared() else b
	var k0 := int(stack.deck_at(near + rg.up_at(near) * r))
	var k1 := int(stack.deck_at(far - rg.up_at(far) * r))
	return Vector2i(mini(k0, k1), maxi(k0, k1))


## The RingFrame for world point p: the stack's deck_ring of the deck under it (world positions, that deck's floor),
## else `ring` (may be null).
func ring_at(p: Vector3) -> RingFrame:
	var st := city_stack()
	return st.ring_at(p) if st != null else ring


## Local up at p: the stack's shared axis (stack.ring()), else `ring`, else world +Y.
func up_at(p: Vector3) -> Vector3:
	var st := city_stack()
	var rg: RingFrame = st.ring() if st != null else ring
	return rg.up_at(p) if rg != null else Vector3.UP


## The scene's AmbientLife node (group "ambient_life"), or null. Looked up only when asked, at most once per LIFE_RESCAN
## s of clock while missing (so a scene without one pays a lookup twice a second while shots fly, nothing otherwise),
## then cached until freed.
func life() -> Node:
	if _life != null and not is_instance_valid(_life):
		_life = null
		_life_scan = -INF
	if _life == null and is_inside_tree() and (now - _life_scan >= LIFE_RESCAN or now < _life_scan):
		_life_scan = now
		_life = get_tree().get_first_node_in_group("ambient_life")
	return _life


## The `src` ambient life is told for a shot: -1 for enemy fire (the record says "enemy", or its team is "enemy"), else
## the shooter's peer id (1 offline).
static func life_src(record: Dictionary) -> int:
	if bool(record.get("enemy", false)) or str(record.get("team", "")) == "enemy":
		return -1
	return int(record.get("peer", 1))


## A stretch a -> b of a shot's path with hit radius r: tells ambient life, on the machine that decides the shot. The
## kill count is ignored (a civilian never stops a shot).
func life_sweep(record: Dictionary, a: Vector3, b: Vector3, r: float) -> void:
	var lf := life()
	if lf != null and lf.has_method("sweep") and decides_shot(record):
		lf.sweep(a, b, r, life_src(record))


## A direct hit `h` (a first_hit result) on a city prop: its verb with dv = stats.knockback along `dir` (no damage, no
## heat), on the machine that decides the shot. False when `h` isn't a prop hit.
func hit_prop(record: Dictionary, st: Dictionary, h: Dictionary, dir: Vector3) -> bool:
	if not h.has("prop"):
		return false
	var pn: Variant = h.get("prop_node")
	var pr: Node = pn as Node if is_instance_valid(pn) and pn is Node else props_at(h.get("point", Vector3.ZERO))
	if pr != null and decides_shot(record):
		pr.apply_impulse(h["prop"], dir.normalized() * float(st.get("knockback", 0.0)), str(record.get("shooter", "")))
	return true


## Ground height under `p` within `depth` m, or NAN.
func ground_below(p: Vector3, depth: float) -> float:
	var sp := space()
	if sp == null:
		return NAN
	var h := shot_ray(sp, p + Vector3.UP * 0.05, p + Vector3.DOWN * depth)
	return float((h["position"] as Vector3).y) if not h.is_empty() else NAN


## Surface (point + normal) along `-up_dir` below `p` within `depth` m, or {}.
func surface_below(p: Vector3, up_dir: Vector3, depth: float) -> Dictionary:
	var u := up_dir.normalized() if up_dir.length_squared() > 1e-6 else Vector3.UP
	var sp := space()
	if sp != null:
		var h := shot_ray(sp, p + u * 0.15, p - u * depth)
		if not h.is_empty():
			return {"point": h["position"] as Vector3, "normal": (h["normal"] as Vector3).normalized()}
		return {}
	var rg := ring_at(p)
	if rg != null:
		var rh := rg.height(p)
		if rh >= -0.5 and rh <= depth:
			return {"point": p - u * rh, "normal": u}
	return {}


# --- Hits --------------------------------------------------------------------------------------------

## A direct hit: builds the Hit (damage, Δv = stats.knockback along `dir`, heat = stats.target_heat) and delivers it,
## if this machine decides hits on `target`. Returns the Hit or null.
func resolve_hit(record: Dictionary, st: Dictionary, target: CombatTarget, component: String, point: Vector3, normal: Vector3,
		dir: Vector3, damage: float) -> Hit:
	if not decides(target, int(record.get("peer", 1))):
		return null
	var h := Hit.new()
	h.damage = damage
	h.impulse = dir.normalized() * float(st.get("knockback", 0.0))
	h.heat = float(st.get("target_heat", 0.0))
	h.point = point
	h.normal = normal
	h.component = component
	h.weapon = str(record.get("weapon", ""))
	h.shooter = str(record.get("shooter", ""))
	h.shot = Combat.shot_key(record)
	deliver(target, h)
	return h


func deliver(target: CombatTarget, h: Hit) -> void:
	if owns(target):
		target.apply_hit(h)
		hit_landed.emit(target, h)
	else:
		remote_hit.emit(target.target_id, h)


## Splash at `point`: every other target whose nearest hit sphere is within stats.splash_radius takes
## splash_damage × (1 - d / R) and a radial Δv of splash_knockback (+ splash_lift up) scaled the same way.
func splash(record: Dictionary, st: Dictionary, point: Vector3, exclude: CombatTarget = null) -> void:
	var rad := float(st.get("splash_radius", 0.0))
	var dmg := float(st.get("splash_damage", 0.0))
	var pdv := float(st.get("prop_blast", st.get("splash_knockback", 0.0)))
	if rad > 0.0 and pdv > 0.0 and decides_shot(record):
		var st_ := city_stack()
		if st_ == null:
			var pr := props()
			if pr != null:
				pr.blast(point, rad, pdv, str(record.get("shooter", "")))
		else:
			var span := deck_span(point, point, rad)
			for k in range(span.x, span.y + 1):
				var dp := deck_props(k)
				if dp != null:
					dp.blast(point, rad, pdv, str(record.get("shooter", "")))
	if rad > 0.0:
		var lf := life()
		if lf != null and lf.has_method("blast") and decides_shot(record):
			lf.blast(point, rad, life_src(record))
	if rad <= 0.0 or (dmg <= 0.0 and float(st.get("splash_knockback", 0.0)) <= 0.0):
		return
	var sh_team := _team_of(str(record.get("shooter", "")), str(record.get("team", "")))
	for t in targets.duplicate():
		if t == exclude or not is_instance_valid(t) or not t.is_hittable():
			continue
		if sh_team != "" and t.team == sh_team:
			continue
		var best := INF
		var comp := ""
		var centre: Vector3 = t.global_position
		for s: Dictionary in t.world_spheres():
			var d := maxf(point.distance_to(s["center"]) - float(s["radius"]), 0.0)
			if d < best:
				best = d
				comp = s["component"]
				centre = s["center"]
		if best > rad or not decides(t, int(record.get("peer", 1))):
			continue
		var k := 1.0 - best / rad
		var h := Hit.new()
		h.damage = dmg * k
		var out: Vector3 = centre - point
		out -= t.up * out.dot(t.up)
		h.impulse = (out.normalized() * float(st.get("splash_knockback", 0.0)) + t.up * float(st.get("splash_lift", 0.0))) * k
		h.point = point
		h.component = comp
		h.weapon = str(record.get("weapon", ""))
		h.shooter = str(record.get("shooter", ""))
		h.shot = Combat.shot_key(record)
		deliver(t, h)


## A cosmetic impact of radius r (ImpactFx) and a shake signal. `flash_color`: the flash ball's colour (default the flame
## core; the laser's is teal).
func spawn_impact(point: Vector3, normal: Vector3, r: float, surface: Color = MechMeshes.GREY, explosive: bool = false,
		flash_color: Color = LowPolyFlame.CORE, is_energy: bool = false) -> ImpactFx:
	if r <= 0.0:
		return null
	var local_up := up_at(point)
	var surf := surface_below(point, local_up, r * 1.5)
	var gy := float((surf["point"] as Vector3).y) if not surf.is_empty() else NAN
	var fx := ImpactFx.new()
	_add_effect(fx)
	fx.setup(self, point, normal, r, surface, gy, explosive, flash_color, surf, local_up)
	shake.emit(r, point)
	impact_spawned.emit(point, r, explosive, is_energy or not flash_color.is_equal_approx(LowPolyFlame.CORE))
	return fx
