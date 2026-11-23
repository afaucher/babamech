class_name CombatWorld
extends Node3D
## The combat container of a scene (weapons.md Â§5): owns the combat CLOCK, the mission seed, the registered targets and
## the live effects (shots, impacts), and is where hits are decided and delivered. One per scene; place it at the
## origin (effects draw in world space).
##
##   world.mission_seed = seed                    shot generators derive from it (Combat.shot_rng)
##   world.register(target)                       a CombatTarget becomes hittable
##   world.fire(record) -> CombatEffect           start a shot from a fire record (Combat.fire_record); a record older
##                                                than `now` is fast-forwarded by now - record.t (a late network event)
##   world.advance(dt)                            the scene calls this with ITS delta (Ã— the lab's time scale): moves the
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
## CITY PROPS (docs/design/city-props.md Â§5): `first_hit` also asks the props `first_hit(a, b, r)` and keeps the nearest
## of targets / world / props (a hit on a prop carries "prop": id and "prop_node": the CityProps it came from, target
## null); a direct hit calls `apply_impulse(id, dv, src)` on that node (`hit_prop`: dv = stats.knockback along the shot,
## no damage, no heat) and `splash` calls `blast(point, radius, dv, src)` (dv = stats.prop_blast, else
## splash_knockback). Props aren't CombatTargets: they are a host-arbitrated world object, so only the machine that
## decides the shot (the shooter's, as for host-owned targets) calls the verbs. A shot that punches through props (the
## railgun slug) sets `skip_props` while it sweeps, so first_hit leaves props out, and knocks every prop
## `props_on_segment(a, b, r)` lists along what it flew, each through `hit_prop` (the same arbitration).
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
## AMBIENT LIFE (docs/design/ambient-life.md Â§6): when a node in group "ambient_life" exists (AmbientLife; looked up
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
## A shot's impact at `point` with its splash radius (0 for a plain round), with the fire record it came from: emitted by
## `splash` on every machine that runs the shot (EnemySquad's hearing listens on the host).
signal impact_from(record: Dictionary, point: Vector3, radius: float)
signal advanced(dt: float, space: PhysicsDirectSpaceState3D)
## A repair drone started here (launch_drone): the launcher's own (CombatNet broadcasts it) or a remote one.
signal drone_launched(record: Dictionary, drone: RepairDrone)

const PROP_COLOR := Color(0.42, 0.4, 0.36)    ## debris colour of a prop that names none
const PROPS_PER_SEGMENT := 64     ## props_on_segment: at most this many props per props node on one segment
const PROP_STEP := 0.25           ## m props_on_segment steps on when its query meets a prop it already listed
const LIFE_RESCAN := 0.5          ## s of clock between "ambient_life" group lookups while the node is missing
const WALL_PROBE := 0.3           ## m each way along an impact's normal that wall_at looks for the static surface it hit

## DEV ONLY: damage multiplier on hits against team "enemy" (TestDrive sets it for `--dev-fast-clear`, so a bot run
## clears decks quickly without skipping any transition). 1 = normal play.
static var dev_enemy_damage := 1.0
## PROFILING (tests/bench_combat_fx.gd, tools/fx_bench): while `profiling` is true, advance times every effect by script
## and a few hot calls into `prof` (key -> usec, "n:" + key -> count); off (the default) costs one bool test per call.
static var profiling := false
static var prof: Dictionary = {}
## key -> PackedInt32Array of usec per single call (prof_add with n = 1), while profiling: per-call medians in the bench.
static var prof_samples: Dictionary = {}


static func prof_add(key: String, us: int, n: int = 1) -> void:
	prof[key] = int(prof.get(key, 0)) + us
	prof["n:" + key] = int(prof.get("n:" + key, 0)) + n
	if n == 1:
		var s: PackedInt32Array = prof_samples.get(key, PackedInt32Array())
		s.append(us)
		prof_samples[key] = s

var now := 0.0
var mission_seed := 0
## FRIENDLY FIRE (weapons.md Â§4.6): true (the default) = a team "player" shot hits other team "player" targets exactly
## like enemies (direct hits stop at them, splash reaches them); false = it passes through them as before. A mission
## parameter every machine sets the same (TestDriveCombat from the crew's launch params). Other same-team pairs (enemy
## on enemy) are spared either way, and a shot never hits its own shooter (`spares`).
var friendly_fire := true
var ring: RingFrame = null        ## optional RingFrame on curved city decks (for surface-aligned impacts)
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
## True while a shot that punches through props sweeps (RailSlug._sweep sets it around Projectile._sweep): first_hit
## then leaves props out (they never stop or shorten that shot; it knocks them through props_on_segment instead).
var skip_props := false
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
## MESH POOL (cosmetic, local): hidden top-level MeshInstance3D nodes that ImpactFx parts and rocket smoke puffs borrow
## (take_mesh) and hand back when their effect leaves (give_mesh), instead of a new node + queue_free per part. The
## borrower sets only mesh, global_transform and visible, so a reused node draws exactly like a new one.
var _mesh_pool: Array[MeshInstance3D] = []   ## pooled nodes without a mesh (prewarmed)
var _mesh_pool_by: Dictionary = {}            ## Mesh -> Array of pooled nodes last showing it
var _mesh_pool_n := 0                         ## nodes in the pool, all lists
var _pool_root: Node3D = null
const MESH_POOL_MAX := 4096        ## hidden nodes kept at most (past it a returned node is freed)
## PACKED TARGET BOUNDS (first_hit's broad phase while advance steps the effects): every target with hit spheres, in
## `targets` order, with its world bounding sphere (CombatTarget.wc_bound_c / wc_bound_r) copied into packed arrays, so
## the per-chord loop touches no target Node until a cheap test against the chord's own bounding sphere passes; a target
## that passes then goes through exactly the old per-target code (live transform, cache refresh, exact bound test,
## spheres). THE RULE that makes it exact: during advance's effect step (after the owned targets ticked and `advanced`
## was emitted, until the last effect stepped) no target moves: targets move in their own tick (CombatWorld.advance's
## target step, or their scene's own process), puppets when their snapshot is applied (outside advance), never from a
## hit (apply_hit / apply_impulse only change velocity; position changes in the next tick). So bounds packed once inside
## that window are the bounds the old code read at every query in it. Repacked when a target registers / unregisters
## (_tb_dirty) or any target gains a sphere (CombatTarget.shapes_epoch); outside the window first_hit is unchanged.
## `verify_bounds` (env BABAMECH_VERIFY_BOUNDS, tests) re-checks every packed reject against the live target.
var _tb_on := false               ## inside advance's effect step: packed bounds may be used
var _tb_dirty := true             ## pack again before the next packed query (a target registered / unregistered)
var _tb_fresh := false            ## the packed bounds were read this effect step (else _refresh_bounds first)
var _tb_epoch := -1               ## CombatTarget.shapes_epoch when packed
var _tb_n := -1                   ## targets.size() when packed (a change packs again)
var _tb_t: Array[CombatTarget] = []
var _tb_c := PackedVector3Array()
var _tb_r := PackedFloat64Array()
## Also fixed for the effect step: the space state advance looked up, and deck_span's shared-axis ring + its axis point
## (the stack never moves or rebuilds inside advance).
var _tb_space: PhysicsDirectSpaceState3D = null
var _tb_rg: RingFrame = null
var _tb_ax := Vector3.ZERO
var _tb_st: Node = null
var _tb_st_ok := false
var _tb_dp: Dictionary = {}       ## deck k -> deck_props(k) this effect step
static var verify_bounds := OS.has_environment("BABAMECH_VERIFY_BOUNDS")
static var bounds_violations := 0  ## packed rejects the live target would not have rejected (verify_bounds only; must stay 0)


func _init() -> void:
	looks_rng.seed = 0x10C5      # looks only: never used for gameplay


func net_fields() -> Dictionary:
	return {"now": Net.LOCAL, "mission_seed": Net.SPAWN, "friendly_fire": Net.SPAWN, "ring": Net.SPAWN, "targets": Net.LOCAL, "effects": Net.LOCAL, "overrides": Net.LOCAL,
		"designators": Net.LOCAL, "use_physics": Net.LOCAL, "looks_rng": Net.LOCAL,
		"muzzles": Net.LOCAL, "_shooter_teams": Net.LOCAL, "stack": Net.LOCAL, "_props": Net.LOCAL, "_props_scan": Net.LOCAL,
		"skip_props": Net.LOCAL, "_life": Net.LOCAL, "_life_scan": Net.LOCAL, "clock": Net.LOCAL, "anchors": Net.LOCAL, "equipment_look": Net.LOCAL,
		"fire_gate": Net.LOCAL, "stepping_targets": Net.LOCAL, "_ray_exclude": Net.LOCAL, "_exclude_bodies": Net.LOCAL,
		"_exclude_dirty": Net.LOCAL, "_shot_query": Net.LOCAL, "_mesh_pool": Net.LOCAL, "_pool_root": Net.LOCAL,
		"_mesh_pool_by": Net.LOCAL, "_mesh_pool_n": Net.LOCAL, "_tb_on": Net.LOCAL, "_tb_dirty": Net.LOCAL, "_tb_fresh": Net.LOCAL, "_tb_epoch": Net.LOCAL, "_tb_n": Net.LOCAL,
		"_tb_t": Net.LOCAL, "_tb_c": Net.LOCAL, "_tb_r": Net.LOCAL, "_tb_space": Net.LOCAL, "_tb_rg": Net.LOCAL, "_tb_ax": Net.LOCAL, "_tb_st": Net.LOCAL, "_tb_st_ok": Net.LOCAL, "_tb_dp": Net.LOCAL}


func register(t: CombatTarget) -> void:
	if not t in targets:
		targets.append(t)
		_exclude_dirty = true
		_tb_dirty = true
		if not _plain_by_script.has(t.get_script()):
			_plain_script(t.get_script())     # once per script (splash's broad phase), here rather than mid-fight
	if t.target_id != "" and t.team != "":
		_shooter_teams[t.target_id] = t.team


func unregister(t: CombatTarget) -> void:
	targets.erase(t)
	_exclude_dirty = true
	_tb_dirty = true


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
	if profiling:
		var t := Time.get_ticks_usec()
		var h := sp.intersect_ray(_shot_query)
		prof_add("shot_ray", Time.get_ticks_usec() - t)
		return h
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
	var f0 := Time.get_ticks_usec() if profiling else 0
	var e := b.spawn(self, record, stats(str(record["weapon"])))
	if e == null:
		return null
	_add_effect(e)
	var f1 := Time.get_ticks_usec() if profiling else 0
	e.advance_to(now)
	var f2 := Time.get_ticks_usec() if profiling else 0
	if e is Projectile and now - float(record.get("t", now)) < MuzzleFlash.LIFE:
		var p := e as Projectile
		var mf := MuzzleFlash.new()
		_add_effect(mf)
		mf.setup(self, p.flight_pos(0.0), p.flight_dir(0.0), MuzzleFlash.size_for(p.stats), float(record.get("t", now)))
	var f3 := Time.get_ticks_usec() if profiling else 0
	fired.emit(record)
	if profiling:
		prof_add("fire.spawn", f1 - f0)
		prof_add("fire.advance", f2 - f1)
		prof_add("fire.flash", f3 - f2)
		prof_add("fire.emit", Time.get_ticks_usec() - f3)
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


## A hidden, top-level MeshInstance3D showing `m` (shadows off, as CombatMeshes.instance), from the pool, or null when
## this world isn't in the tree (the caller then makes its own). Hand it back with give_mesh. A node last used with the
## same mesh is preferred (no mesh swap: MeshInstance3D.set_mesh is not free), then any pooled node, then a new one.
func take_mesh(m: Mesh) -> MeshInstance3D:
	if not is_inside_tree():
		return null
	if _pool_root == null or not is_instance_valid(_pool_root):
		_pool_root = Node3D.new()
		_pool_root.name = "MeshPool"
		add_child(_pool_root)
		_mesh_pool.clear()
		_mesh_pool_by.clear()
		_mesh_pool_n = 0
	var mi: MeshInstance3D = null
	var same: Variant = _mesh_pool_by.get(m) if m != null else null
	while mi == null and same != null and not (same as Array).is_empty():
		mi = (same as Array).pop_back()
		_mesh_pool_n -= 1
		if not is_instance_valid(mi):
			mi = null
	if mi != null:
		return mi
	while mi == null and not _mesh_pool.is_empty():
		mi = _mesh_pool.pop_back()
		_mesh_pool_n -= 1
		if not is_instance_valid(mi):
			mi = null
	if mi == null and _mesh_pool_n > 0:
		# No node with this mesh and none blank: re-mesh an idle node showing another mesh (cheaper than a new node).
		for arr: Array in _mesh_pool_by.values():
			while mi == null and not arr.is_empty():
				mi = arr.pop_back()
				_mesh_pool_n -= 1
				if not is_instance_valid(mi):
					mi = null
			if mi != null:
				break
	if mi == null:
		mi = CombatMeshes.instance(m)
		mi.top_level = true
		mi.visible = false
		_pool_root.add_child(mi)
	elif mi.mesh != m:
		mi.mesh = m
	return mi


func _prewarm_later(n: int, plan: Array) -> void:
	prewarm_mesh_pool.call_deferred(n, plan)


## Return a node from take_mesh: hidden at once, kept (by its mesh) for the next borrower.
func give_mesh(mi: MeshInstance3D) -> void:
	if mi == null or not is_instance_valid(mi):
		return
	mi.visible = false
	if _mesh_pool_n < MESH_POOL_MAX and _pool_root != null and mi.get_parent() == _pool_root:
		_mesh_pool_n += 1
		var m := mi.mesh
		if m == null:
			_mesh_pool.append(mi)
		else:
			var arr: Variant = _mesh_pool_by.get(m)
			if arr == null:
				arr = []
				_mesh_pool_by[m] = arr
			(arr as Array).append(mi)
	else:
		mi.queue_free()


## Make up to `n` pooled nodes ahead of time (at scene load: TestDriveCombat.setup), so the first seconds of a fight
## don't pay for new nodes. `plan` [[mesh, count], ...] gives that many of them their mesh already (ImpactFx.pool_plan,
## Rocket.pool_plan), so a borrower of that mesh needs no mesh swap; the rest have none. Hidden: nothing to draw.
func prewarm_mesh_pool(n: int, plan: Array = []) -> void:
	if not is_inside_tree():      # not in the scene yet (TestDriveCombat.setup before the drive enters): once it is
		if not tree_entered.is_connected(_prewarm_later):
			tree_entered.connect(_prewarm_later.bind(n, plan), CONNECT_ONE_SHOT)
		return
	var ms: Array[MeshInstance3D] = []
	for e: Array in plan:
		for i in int(e[1]):
			if ms.size() >= n:
				break
			var mi := take_mesh(null)
			mi.mesh = e[0]
			ms.append(mi)
	while ms.size() < n:
		ms.append(take_mesh(null))
	for mi in ms:
		give_mesh(mi)


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
	if profiling:
		_advance_profiled(dt, sp)
		return
	stepping_targets = true
	for t in targets.duplicate():
		if is_instance_valid(t) and owns(t):
			t.tick(dt, sp)
	stepping_targets = false
	advanced.emit(dt, sp)
	_tb_on = true            # targets stay put until the effects are stepped: first_hit may use packed bounds (see _tb_*)
	_tb_fresh = false
	_tb_space = sp
	_tb_rg = null
	_tb_st_ok = false
	_tb_dp.clear()
	for e in effects.duplicate():
		e.advance_to(now)
		if e.finished():
			remove_effect(e)
	_tb_on = false
	equipment_look.step(self)


## advance's body with timings into `prof` (profiling only; the same steps in the same order).
func _advance_profiled(dt: float, sp: PhysicsDirectSpaceState3D) -> void:
	var t0 := Time.get_ticks_usec()
	stepping_targets = true
	for t in targets.duplicate():
		if is_instance_valid(t) and owns(t):
			t.tick(dt, sp)
	stepping_targets = false
	var t1 := Time.get_ticks_usec()
	prof_add("targets.tick", t1 - t0)
	advanced.emit(dt, sp)
	var t2 := Time.get_ticks_usec()
	prof_add("advanced.emit", t2 - t1)
	_tb_on = true
	_tb_fresh = false
	_tb_space = sp
	_tb_rg = null
	_tb_st_ok = false
	_tb_dp.clear()
	for e in effects.duplicate():
		var s: Script = e.get_script()
		var k := "fx:" + (str(s.get_global_name()) if s != null else "?")
		var a := Time.get_ticks_usec()
		e.advance_to(now)
		var fin: bool = e.finished()
		var b := Time.get_ticks_usec()
		prof_add(k, b - a)
		if fin:
			remove_effect(e)
			prof_add("remove_effect", Time.get_ticks_usec() - b)
	_tb_on = false
	var t3 := Time.get_ticks_usec()
	equipment_look.step(self)
	prof_add("equipment_look", Time.get_ticks_usec() - t3)


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
	if _tb_on:
		return _tb_space     # advance's own lookup, for the whole effect step (the same object)
	if not use_physics or not is_inside_tree():
		return null
	return get_world_3d().direct_space_state


func _team_of(shooter: String, fallback: String = "") -> String:
	if fallback != "":
		return fallback
	if shooter == "":
		return ""
	return str(_shooter_teams.get(shooter, ""))


## THE friendly-fire rule (weapons.md Â§4.6), asked by every shot path (first_hit, splash): true = a shot from
## `shooter_id` (team `shooter_team`) passes `t` by. A shot never touches its own shooter. Same non-empty team: a
## "player" shot hits a "player" target while `friendly_fire` is on, every other same-team pair (enemy on enemy) is
## always spared. Different or empty teams: never spared. Who then DECIDES the hit is unchanged (`decides`: the
## victim's machine for a mech).
func spares(shooter_team: String, t: CombatTarget, shooter_id: String) -> bool:
	if shooter_id != "" and t.target_id == shooter_id:
		return true
	if shooter_team == "" or t.team != shooter_team:
		return false
	return not (friendly_fire and shooter_team == "player")


## The first thing on segment a -> b: a target hit sphere (inflated by `r`, skipping `shooter`, ids in `skip` and the
## targets `spares` passes by) or world geometry or a city prop. {} or {target (null = world / prop), component, point,
## normal, frac, color} (+ "prop": id for a prop). `query` true: a look along the line, not a shot (the camera's aim
## pull-in): same-team targets are always passed by, whatever `friendly_fire` says.
func first_hit(a: Vector3, b: Vector3, r: float, shooter: String = "", skip: Array = [], query: bool = false) -> Dictionary:
	if not profiling:
		return _first_hit(a, b, r, shooter, skip, query)
	var t := Time.get_ticks_usec()
	var h := _first_hit(a, b, r, shooter, skip, query)
	prof_add("first_hit", Time.get_ticks_usec() - t)
	return h


func _first_hit(a: Vector3, b: Vector3, r: float, shooter: String, skip: Array, query: bool) -> Dictionary:
	var best := {}
	var best_f := 2.0
	var sh_team := _team_of(shooter)
	if _tb_on:
		# Inside advance's effect step: the packed bounds (see _tb_*) reject every target the chord's bounding sphere
		# can't reach without touching it; the rest go through _target_hit exactly as below, in the same order.
		if _tb_dirty or _tb_epoch != CombatTarget.shapes_epoch or _tb_n != targets.size():
			_pack_bounds()
		elif not _tb_fresh:
			_refresh_bounds()
		var mid := (a + b) * 0.5
		var reach0 := a.distance_to(b) * 0.5 + r
		var tc := _tb_c
		var tr := _tb_r
		var vb := verify_bounds
		for i in tc.size():
			# |c - mid| > half + r + R  =>  the chord is farther than r + R from c: the exact test below would reject too
			# (slack keeps rounding on the safe side; a pass only costs the exact test).
			var c := tc[i]
			var q := (reach0 + tr[i]) * 1.00001 + 1e-4
			if c.distance_squared_to(mid) > q * q:
				if vb:
					_verify_reject(_tb_t[i], a, b, r)
				continue
			# _target_hit's own exact bound test, on the packed copy of the same bound (equal by THE RULE): no Node yet.
			var reach := tr[i] + r
			if c.distance_squared_to(Geometry3D.get_closest_point_to_segment(c, a, b)) > reach * reach:
				if vb:
					_verify_reject(_tb_t[i], a, b, r)
				continue
			var t := _tb_t[i]
			if not is_instance_valid(t):
				continue
			var h := _target_hit(t, a, b, r, shooter, skip, query, sh_team, best_f)
			if not h.is_empty():
				best = h
				best_f = float(h["frac"])
	else:
		for t in targets:
			if not is_instance_valid(t):
				continue
			var h := _target_hit(t, a, b, r, shooter, skip, query, sh_team, best_f)
			if not h.is_empty():
				best = h
				best_f = float(h["frac"])
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
	if a.distance_squared_to(b) <= 1e-10 or skip_props:
		return best
	var st := _tb_stack() if _tb_on else city_stack()
	if st == null:
		var pr := props()
		if pr != null:
			var ph: Dictionary = pr.first_hit(a, b, r)
			if not ph.is_empty() and float(ph["frac"]) < best_f:
				best = _prop_hit(ph, pr)
		return best
	var span := deck_span(a, b, r)
	for k in range(span.x, span.y + 1):
		var dp := _tb_deck_props(k) if _tb_on else deck_props(k)
		if dp == null:
			continue
		var ph: Dictionary = dp.first_hit(a, b, r)
		if not ph.is_empty() and float(ph["frac"]) < best_f:
			best = _prop_hit(ph, dp)
			best_f = float(ph["frac"])
	return best


## first_hit's per-target test: target `t`'s nearest sphere the chord a -> b (inflated by r) meets before `best_f`, as a
## first_hit result, or {} (also for a target it passes by). World spheres come from a cache on the target, rebuilt when
## its transform or shapes changed (CombatTarget.refresh_world_cache: world_spheres()' exact maths), behind an exact
## bounding-sphere reject: same hits as testing every sphere, a fraction of the work.
func _target_hit(t: CombatTarget, a: Vector3, b: Vector3, r: float, shooter: String, skip: Array, query: bool,
		sh_team: String, best_f: float) -> Dictionary:
	var xf := t.global_transform
	if t.wc_xf != xf or t.wc_rev != t.shapes_rev or t.wc_n != t.hit_shapes.size():
		t.refresh_world_cache(xf)
	if t.wc_bound_r < 0.0:
		return {}
	var reach := t.wc_bound_r + r
	if t.wc_bound_c.distance_squared_to(Geometry3D.get_closest_point_to_segment(t.wc_bound_c, a, b)) > reach * reach:
		return {}
	if not t.is_hittable() or t.target_id == shooter or t.target_id in skip:
		return {}
	if (sh_team != "" and t.team == sh_team) if query else spares(sh_team, t, shooter):
		return {}
	var best := {}
	var cs := t.wc_centers
	var rs := t.wc_radii
	for i in cs.size():
		var c := cs[i]
		var f := Combat.segment_sphere(a, b, c, rs[i] + r)
		if f >= 0.0 and f < best_f:
			var p := a.lerp(b, f)
			best_f = f
			best = {"target": t, "component": t.wc_comps[i], "point": p, "normal": (p - c).normalized(),
				"frac": f, "color": MechMeshes.GREY}
	return best


## Copy every registered target with hit spheres (targets order) and its world bounding sphere into _tb_* (refreshing
## its sphere cache from its live transform, as first_hit would). Only inside advance's effect step (_tb_on).
func _pack_bounds() -> void:
	_tb_dirty = false
	_tb_fresh = true
	_tb_epoch = CombatTarget.shapes_epoch
	_tb_n = targets.size()
	_tb_t.clear()
	_tb_c.clear()
	_tb_r.clear()
	for t in targets:
		if not is_instance_valid(t):
			continue
		var xf := t.global_transform
		if t.wc_xf != xf or t.wc_rev != t.shapes_rev or t.wc_n != t.hit_shapes.size():
			t.refresh_world_cache(xf)
		if t.wc_bound_r < 0.0:
			continue          # no spheres: nothing to hit (a sphere added later bumps shapes_epoch: packed again)
		_tb_t.append(t)
		_tb_c.append(t.wc_bound_c)
		_tb_r.append(t.wc_bound_r)


## The same targets as the last _pack_bounds (none registered / unregistered, no sphere added since): read each packed
## target's live transform again, refresh its cache if it moved, copy its bound in place. A target whose spheres were
## only removed keeps its larger (still holding) packed bound; one freed is skipped by first_hit's validity check.
func _refresh_bounds() -> void:
	_tb_fresh = true
	for i in _tb_t.size():
		var t := _tb_t[i]
		if not is_instance_valid(t):
			continue
		var xf := t.global_transform
		if t.wc_xf != xf:
			t.refresh_world_cache(xf)
		if t.wc_bound_r >= 0.0:      # (always copied: another caller may have refreshed the cache since the pack)
			_tb_c[i] = t.wc_bound_c
			_tb_r[i] = t.wc_bound_r


## verify_bounds only: a packed reject of `t` must also be a reject by the live target's exact bound (else THE RULE in
## the _tb_* header was broken: something moved a target inside advance's effect step). Counts and reports it.
func _verify_reject(t: CombatTarget, a: Vector3, b: Vector3, r: float) -> void:
	if not is_instance_valid(t):
		return
	var xf := t.global_transform
	if t.wc_xf != xf or t.wc_rev != t.shapes_rev or t.wc_n != t.hit_shapes.size():
		t.refresh_world_cache(xf)
	if t.wc_bound_r < 0.0:
		return
	var reach := t.wc_bound_r + r
	if t.wc_bound_c.distance_squared_to(Geometry3D.get_closest_point_to_segment(t.wc_bound_c, a, b)) <= reach * reach:
		bounds_violations += 1
		push_error("CombatWorld: packed bounds stale for target %s (moved inside advance's effect step)" % t.target_id)


func _prop_hit(ph: Dictionary, node: Node) -> Dictionary:
	return {"target": null, "prop": ph["id"], "prop_node": node, "component": "", "point": ph["point"],
		"normal": ph["normal"], "frac": float(ph["frac"]), "color": ph.get("color", PROP_COLOR)}


## EVERY city prop a sphere of radius `r` meets moving a -> b, nearest first, as first_hit prop results ({target: null,
## prop, prop_node, component, point, normal, frac (along a -> b), color}): what a shot that punches through props (the
## railgun slug) knocks. Asks the same props first_hit has (the one props node, or every deck deck_span gives in the
## stack). Built on CityProps.first_hit alone, which returns only the nearest prop: after each prop the query restarts
## where the sphere leaves it (`_prop_exit`), at most PROPS_PER_SEGMENT props per node. Reads only; knocks nothing.
func props_on_segment(a: Vector3, b: Vector3, r: float) -> Array:
	var out: Array = []
	if a.distance_squared_to(b) <= 1e-10:
		return out
	var nodes: Array[Node] = []
	if city_stack() == null:
		var pr := props()
		if pr != null:
			nodes.append(pr)
	else:
		var span := deck_span(a, b, r)
		for k in range(span.x, span.y + 1):
			var dp := deck_props(k)
			if dp != null:
				nodes.append(dp)
	var step := PROP_STEP / a.distance_to(b)
	for node in nodes:
		var f0 := 0.0
		var seen := {}
		for i in PROPS_PER_SEGMENT:
			var ph: Dictionary = node.first_hit(a.lerp(b, f0), b, r)
			if ph.is_empty():
				break
			var id := int(ph["id"])
			var fe := f0 + float(ph["frac"]) * (1.0 - f0)
			if seen.has(id):
				f0 = fe + step       # met again (the restart was still inside it by its own maths): step on past it
			else:
				seen[id] = true
				var h := _prop_hit(ph, node)
				h["frac"] = fe
				out.append(h)
				f0 = _prop_exit(node, id, a, b, r, fe) + step * 0.04
			if f0 >= 1.0:
				break
	if nodes.size() > 1:
		out.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return float(x["frac"]) < float(y["frac"]))
	return out


## Where (frac along a -> b, from `fe` where it entered) a sphere of radius r leaves prop `id` of `node`: bisection on
## the node's own first_hit (inside = the query from there meets that prop at once), so the restart never meets it again.
func _prop_exit(node: Node, id: int, a: Vector3, b: Vector3, r: float, fe: float) -> float:
	var lo := fe
	var hi := 1.0
	for i in 18:
		var mid := (lo + hi) * 0.5
		var ph: Dictionary = node.first_hit(a.lerp(b, mid), b, r)
		if not ph.is_empty() and int(ph["id"]) == id and float(ph["frac"]) <= 1e-6:
			lo = mid
		else:
			hi = mid
	return hi


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


## city_stack() / deck_props(k) looked up once per advance effect step (the stack doesn't change inside it): first_hit.
func _tb_stack() -> Node:
	if not _tb_st_ok:
		_tb_st_ok = true
		_tb_st = city_stack()
	return _tb_st


func _tb_deck_props(k: int) -> Node:
	if _tb_dp.has(k):
		return _tb_dp[k]
	var dp := deck_props(k)
	_tb_dp[k] = dp
	return dp


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
	var rg: RingFrame = _tb_rg
	var ax := _tb_ax
	if rg == null or not _tb_on:
		rg = stack.ring()
		ax = rg.axis_point()
		if _tb_on:
			_tb_rg = rg
			_tb_ax = ax
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
		if profiling:
			var t := Time.get_ticks_usec()
			lf.sweep(a, b, r, life_src(record))
			prof_add("life_sweep", Time.get_ticks_usec() - t)
			return
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
			return {"point": h["position"] as Vector3, "normal": (h["normal"] as Vector3).normalized(),
				"collider": h.get("collider")}
		return {}
	var rg := ring_at(p)
	if rg != null:
		var rh := rg.height(p)
		if rh >= -0.5 and rh <= depth:
			return {"point": p - u * rh, "normal": u}
	return {}


# --- Hits --------------------------------------------------------------------------------------------

## A direct hit: builds the Hit (damage, Î”v = stats.knockback along `dir`, heat = stats.target_heat) and delivers it,
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
	if dev_enemy_damage != 1.0 and target.team == "enemy":
		h.damage *= dev_enemy_damage   # DEV ONLY (--dev-fast-clear): scaled where the hit is decided, before it travels
	if owns(target):
		if profiling:
			var t0 := Time.get_ticks_usec()
			target.apply_hit(h)
			var t1 := Time.get_ticks_usec()
			hit_landed.emit(target, h)
			prof_add("apply_hit", t1 - t0)
			prof_add("hit_landed.emit", Time.get_ticks_usec() - t1)
		else:
			target.apply_hit(h)
			hit_landed.emit(target, h)
	else:
		remote_hit.emit(target.target_id, h)


## Splash at `point`: every other target whose nearest hit sphere is within stats.splash_radius takes
## splash_damage Ã— (1 - d / R) and a radial Î”v of splash_knockback (+ splash_lift up) scaled the same way.
func splash(record: Dictionary, st: Dictionary, point: Vector3, exclude: CombatTarget = null) -> void:
	if not profiling:
		_splash(record, st, point, exclude)
		return
	var t := Time.get_ticks_usec()
	_splash(record, st, point, exclude)
	prof_add("splash", Time.get_ticks_usec() - t)


func _splash(record: Dictionary, st: Dictionary, point: Vector3, exclude: CombatTarget) -> void:
	var rad := float(st.get("splash_radius", 0.0))
	if profiling:
		var t := Time.get_ticks_usec()
		impact_from.emit(record, point, rad)
		prof_add("impact_from.emit", Time.get_ticks_usec() - t)
	else:
		impact_from.emit(record, point, rad)
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
	var sh := str(record.get("shooter", ""))
	var sh_team := _team_of(sh, str(record.get("team", "")))
	for t in targets.duplicate():
		if t == exclude or not is_instance_valid(t) or not t.is_hittable():
			continue
		if spares(sh_team, t, sh):     # never the shooter; teammates only with friendly fire on
			continue
		if _plain_spheres(t):
			# Broad phase from first_hit's sphere cache (same spheres as world_spheres()): every sphere is at least
			# |point - bound centre| - bound radius away, so past rad + slack none can be within rad (the test below would skip
			# it too). Only for targets whose world_spheres() is CombatTarget's own (EnemyTrooper overrides it).
			var xf: Transform3D = t.global_transform
			if t.wc_xf != xf or t.wc_rev != t.shapes_rev or t.wc_n != t.hit_shapes.size():
				t.refresh_world_cache(xf)
			if t.wc_bound_r < 0.0 or point.distance_to(t.wc_bound_c) - t.wc_bound_r > rad * 1.00001 + 1e-4:
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


static var _plain_by_script: Dictionary = {}   ## Script -> true when its world_spheres() is CombatTarget's own


## True when `t`'s world_spheres() is CombatTarget's (its hit_shapes in world space, what first_hit's cache holds), false
## when its script (or a base below CombatTarget) overrides it. A GDScript's method list repeats a method once per
## script in the chain that defines it, so an override shows world_spheres twice. Cached per script.
## Reading a script's method list costs ~0.5 ms (EnemyBase), so it happens at load: warm_target_scripts() for every
## named class deriving from CombatTarget, and register() for any other script.
static func _plain_spheres(t: CombatTarget) -> bool:
	var s: Script = t.get_script()
	var v: Variant = _plain_by_script.get(s)
	return bool(v) if v != null else _plain_script(s)


static func _plain_script(s: Script) -> bool:
	var n := 0
	if s != null:
		for m: Dictionary in s.get_script_method_list():
			if StringName(m["name"]) == &"world_spheres":
				n += 1
	_plain_by_script[s] = n == 1
	return n == 1


## Fill _plain_spheres' cache for every named class deriving from CombatTarget (at scene load: TestDriveCombat.setup), so
## no splash pays for a method list mid-fight.
static func warm_target_scripts() -> void:
	var base_of: Dictionary = {}
	var path_of: Dictionary = {}
	for c: Dictionary in ProjectSettings.get_global_class_list():
		base_of[StringName(c["class"])] = StringName(c["base"])
		path_of[StringName(c["class"])] = str(c["path"])
	for cls: StringName in base_of:
		var b: StringName = cls
		var hops := 0
		while b != &"" and b != &"CombatTarget" and base_of.has(b) and hops < 32:
			b = base_of[b]
			hops += 1
		if b == &"CombatTarget":
			var s := load(path_of[cls]) as Script
			if s != null and not _plain_by_script.has(s):
				_plain_script(s)


## A cosmetic impact of radius r (ImpactFx) and a shake signal. `flash_color`: the flash ball's colour (default the flame
## core; the laser's is teal).
func spawn_impact(point: Vector3, normal: Vector3, r: float, surface: Color = MechMeshes.GREY, explosive: bool = false,
		flash_color: Color = LowPolyFlame.CORE, is_energy: bool = false) -> ImpactFx:
	if r <= 0.0:
		return null
	var pt := Time.get_ticks_usec() if profiling else 0
	var local_up := up_at(point)
	var surf := surface_below(point, local_up, r * 1.5)
	if surf.has("collider") and not is_static_world(surf["collider"]):
		surf = {}                  # a tram roof or an unregistered mech is not ground: no crater on a moving thing
	var gy := float((surf["point"] as Vector3).y) if not surf.is_empty() else NAN
	var p1 := Time.get_ticks_usec() if profiling else 0
	var wall := wall_at(point, normal)
	var p2 := Time.get_ticks_usec() if profiling else 0
	var fx := ImpactFx.new()
	_add_effect(fx)
	fx.setup(self, point, normal, r, surface, gy, explosive, flash_color, surf, local_up, wall)
	if profiling:
		prof_add("si.surface", p1 - pt)
		prof_add("si.wall", p2 - p1)
		prof_add("si.setup", Time.get_ticks_usec() - p2)
	shake.emit(r, point)
	impact_spawned.emit(point, r, explosive, is_energy or not flash_color.is_equal_approx(LowPolyFlame.CORE))
	if profiling:
		prof_add("spawn_impact", Time.get_ticks_usec() - pt)
	return fx


## The static world surface an impact at `point` with normal `n` sits on: a short world ray along the normal through the
## point (WALL_PROBE m each way; shot_ray already ignores registered targets' bodies) that meets static geometry facing
## the same way, as {point, normal}, or {} (a hit on a target's hull, a blast in open air, a moving body, no physics).
## Decides where ImpactFx may lay its wall scorch: decals go on static world surfaces only, never on a target or in the air.
func wall_at(point: Vector3, n: Vector3) -> Dictionary:
	if n.length_squared() < 1e-6:
		return {}
	var sp := space()
	if sp == null:
		return {}
	var u := n.normalized()
	var h := shot_ray(sp, point + u * WALL_PROBE, point - u * WALL_PROBE)
	if h.is_empty() or not is_static_world(h.get("collider")):
		return {}
	var hn := (h["normal"] as Vector3).normalized()
	if hn.dot(u) < 0.5:
		return {}
	return {"point": h["position"] as Vector3, "normal": hn}


## True for static world geometry (a StaticBody3D that isn't kinematic: the district, a lab's slabs), false for a mech's
## CharacterBody3D, a tram's AnimatableBody3D, a RigidBody3D or nothing.
static func is_static_world(c: Variant) -> bool:
	return is_instance_valid(c) and c is StaticBody3D and not (c is AnimatableBody3D)
