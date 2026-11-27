extends TestCase
## Mission assets (docs/design/weapons.md §5 "Mission assets"): AssetTarget through MissionCombat.add_asset, single
## process, no physics. MissionCombat is used WITHOUT setup() (that needs a full MissionScene): the test gives it a
## CombatWorld (`world`) and a stand-in drive (`_drive`, a Node with a `mission` var holding a stub with damage_asset);
## add_asset's wiring is exactly what runs in the game. The MissionCombat is never added to the tree (its
## _physics_process steps a rack it doesn't have here); the test advances the world itself.
## 1. Enemy fire on the asset emits asset_damaged with the weapon's damage and reaches mission.damage_asset(id, amount).
## 2. A shell's direct hit counts once (its splash skips the struck target); splash alone near it counts once.
## 3. set_hp(0, max): not hittable, a shot passes through to what is behind it; hp_fraction mirrors set_hp.
## 4. A player shot: spared with friendly_fire off, damages with it on.
## 5. The repair drone's rule: repairable() false and heal() restores nothing.
## 6. A real catalog enemy (turret), no player around, acquires the asset and its fire reaches damage_asset.

const DT := 1.0 / 60.0
const ID := "relay"


class StubMission extends Node:
	var calls: Array = []          ## [id, amount]

	func damage_asset(id: String, amount: float) -> void:
		calls.append([id, amount])


class StubDrive extends Node:
	var mission: Node = null


var world: CombatWorld
var tdc: MissionCombat
var mission: StubMission
var drive: StubDrive
var site: Node3D
var asset: AssetTarget
var events: Array = []              ## [id, amount, src] from asset_damaged


func setup() -> void:
	world = CombatWorld.new()
	world.mission_seed = 5
	world.use_physics = false
	add_child(world)
	mission = StubMission.new()
	drive = StubDrive.new()
	drive.mission = mission
	add_child(drive)
	drive.add_child(mission)
	tdc = MissionCombat.new()
	tdc.world = world
	tdc._drive = drive
	site = Node3D.new()
	add_child(site)
	site.position = Vector3(10, 0, 0)
	asset = tdc.add_asset(ID, site, 2.5, 6.0)
	await frames(1)
	if not check(asset != null and asset.get_parent() == site, "add_asset makes the target under the node"):
		finish()
		return
	asset.asset_damaged.connect(func(id: String, amount: float, src: String) -> void: events.append([id, amount, src]))
	eq(asset.target_id, "asset_relay", "target id")
	eq(asset.team, "player", "team player")
	eq(asset.owner_peer, 0, "host-owned")
	check(asset in world.targets, "registered in the world")
	check(tdc.asset(ID) == asset, "asset(id) returns it")
	check(tdc.add_asset(ID, site) == asset, "add_asset again with the same node returns the same target")
	check(asset.is_hittable() and is_equal_approx(asset.hp_fraction(), 1.0), "hittable at full before the first set_hp")
	check(asset.hit_shapes.size() >= 1, "has hit spheres")
	near(float((asset.world_spheres()[0]["center"] as Vector3).y), 3.0, 0.01, "first sphere at mid-height (enemy aim centre)")

	_enemy_fire()
	_splash_once()
	_dead_passes()
	_friendly_fire()
	_drone()
	await _real_enemy()
	await _collision_body()
	tdc.remove_asset(ID)
	check(tdc.asset(ID) == null and not (asset in world.targets), "remove_asset unregisters it")
	tdc.free()
	finish()


func _enemy_rec(w: String, from: Vector3, to: Vector3, idx: int) -> Dictionary:
	var rec := Combat.fire_record("enemy_test", 1, w, w, from, to, world.now, idx, 0.0)
	rec["enemy"] = true
	rec["team"] = "enemy"
	return rec


func _run(n: int) -> void:
	for _i in n:
		world.advance(DT)


func _centre() -> Vector3:
	return site.global_position + Vector3(0, 3.0, 0)


func _enemy_fire() -> void:
	events.clear()
	mission.calls.clear()
	var w := str(EnemyCatalog.unit("turret")["primary_weapon"])
	var dmg := float(world.stats(w).get("damage", 0.0))
	world.fire(_enemy_rec(w, _centre() + Vector3(0, 0, 20), _centre(), 100))
	_run(120)
	eq(events.size(), 1, "enemy fire on the asset emits asset_damaged once")
	if events.size() == 1:
		eq(str(events[0][0]), ID, "with the asset id")
		near(float(events[0][1]), dmg, 0.01, "with the weapon's damage (%s)" % w)
		eq(str(events[0][2]), "enemy_test", "with the shooter as src")
	eq(mission.calls.size(), 1, "mission.damage_asset called once")
	if mission.calls.size() == 1:
		eq(str(mission.calls[0][0]), ID, "damage_asset id")
		near(float(mission.calls[0][1]), dmg, 0.01, "damage_asset amount")
	check(not asset.destroyed() and asset.is_hittable(), "combat never destroys it")


func _splash_once() -> void:
	# A siege shell striking it: direct hit only (CombatWorld.splash excludes the struck target).
	events.clear()
	mission.calls.clear()
	var w := "enemy_siege_shell"
	var st := world.stats(w)
	world.fire(_enemy_rec(w, _centre() + Vector3(0, 0, 20), _centre(), 200))
	_run(120)
	eq(events.size(), 1, "a splash shell's direct hit counts once")
	if events.size() == 1:
		near(float(events[0][1]), float(st["damage"]), 0.01, "direct hit damage, no splash on top")
	# Splash alone, 2 m outside the nearest sphere: one hit, scaled by distance.
	events.clear()
	mission.calls.clear()
	var rec := _enemy_rec(w, _centre() + Vector3(0, 0, 20), _centre(), 201)
	world.splash(rec, st, _centre() + Vector3(0, 0, 4.5))
	eq(events.size(), 1, "splash near the asset counts once (several spheres, one hit)")
	eq(mission.calls.size(), 1, "and reaches damage_asset once")
	if events.size() == 1:
		var r := float(st["splash_radius"])
		near(float(events[0][1]), float(st["splash_damage"]) * (1.0 - 2.0 / r), 0.05, "splash damage by distance")


func _dead_passes() -> void:
	asset.set_hp(300.0, 600.0)
	near(asset.hp_fraction(), 0.5, 1e-4, "hp_fraction mirrors set_hp")
	check(asset.is_hittable(), "hittable above 0")
	asset.set_hp(0.0, 600.0)
	check(not asset.is_hittable(), "set_hp(0, max): not hittable")
	near(asset.hp_fraction(), 0.0, 1e-4, "hp_fraction 0")
	var behind := CombatTarget.new()
	behind.target_id = "behind"
	behind.owner_peer = 0
	behind.set_max_hp({"body": 1000.0})
	behind.add_hit_sphere("body", Vector3(0, 3.0, 0), 1.5)
	add_child(behind)
	behind.global_position = site.global_position + Vector3(0, 0, -6)
	world.register(behind)
	events.clear()
	mission.calls.clear()
	var w := str(EnemyCatalog.unit("turret")["primary_weapon"])
	world.fire(_enemy_rec(w, _centre() + Vector3(0, 0, 20), _centre() + Vector3(0, 0, -6), 300))
	_run(120)
	eq(events.size(), 0, "a dead asset takes no hit")
	eq(mission.calls.size(), 0, "and reports nothing")
	check(behind.total_hp() < 1000.0, "the shot passed through to the target behind (%.0f)" % behind.total_hp())
	world.unregister(behind)
	behind.queue_free()
	asset.set_hp(600.0, 600.0)
	check(asset.is_hittable(), "hittable again once the host's HP is back")
	# Dormant (its objective not active yet): full HP, yet nothing meets it.
	asset.set_live(false)
	check(not asset.is_hittable(), "set_live(false): not hittable at full HP")
	events.clear()
	mission.calls.clear()
	world.fire(_enemy_rec(w, _centre() + Vector3(0, 0, 20), _centre() + Vector3(0, 0, -6), 301))
	_run(120)
	eq(events.size(), 0, "a dormant asset takes no hit")
	eq(mission.calls.size(), 0, "and reports nothing while dormant")
	asset.apply_damage(50.0, "body", "x")
	eq(events.size(), 0, "apply_damage on a dormant asset reports nothing")
	asset.set_live(true)
	check(asset.is_hittable(), "hittable again once live")


func _friendly_fire() -> void:
	var me := CombatTarget.new()
	me.target_id = "player1"
	me.owner_peer = 1
	me.team = "player"
	me.set_max_hp({"body": 1000.0})
	me.add_hit_sphere("body", Vector3(0, 3.0, 0), 1.0)
	add_child(me)
	me.global_position = site.global_position + Vector3(30, 0, 30)    # off the firing line
	world.register(me)
	var w := "autocannon"
	var dmg := float(world.stats(w).get("damage", 0.0))
	check(dmg > 0.0, "player weapon has damage")
	for ff: bool in [false, true]:
		world.friendly_fire = ff
		events.clear()
		mission.calls.clear()
		var rec := Combat.fire_record("player1", 1, "side_r", w, _centre() + Vector3(0, 0, 25), _centre(), world.now,
			400 + int(ff), 0.0)
		world.fire(rec)
		_run(150)
		if ff:
			check(events.size() >= 1, "friendly fire on: the player shot damages the asset")
			check(mission.calls.size() == events.size(), "and reaches damage_asset per hit")
		else:
			eq(events.size(), 0, "friendly fire off: the player shot is spared")
			eq(mission.calls.size(), 0, "nothing reported")
	world.friendly_fire = true
	world.unregister(me)
	me.queue_free()


func _drone() -> void:
	check(not RepairDrone.repairable(asset), "RepairDrone.repairable is false for the asset")
	asset.set_hp(100.0, 600.0)
	check(not RepairDrone.repairable(asset), "still false while damaged")
	near(asset.heal(500.0, "player1"), 0.0, 1e-6, "heal restores nothing")
	near(asset.hp_fraction(), 100.0 / 600.0, 1e-4, "the mirrored HP is untouched by heal")
	asset.set_hp(600.0, 600.0)


func _real_enemy() -> void:
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(world)
	events.clear()
	mission.calls.clear()
	var fired: Array = []
	world.fired.connect(func(rec: Dictionary) -> void:
		if str(rec.get("shooter", "")) == "turret_asset":
			fired.append(rec))
	# The turret faces -Z from the origin of its node: put it 40 m in front of the asset (+Z of the site).
	var t := EnemyTurret.new()
	t.configure("turret", "turret_asset", world, sq, null, 1)
	t.position = site.global_position + Vector3(0, 0, 40)
	sq.add_enemy(t)
	await frames(1)
	var acquired := ""
	for _i in 300:
		world.advance(DT)
		if acquired == "" and t._target_id != "":
			acquired = t._target_id
		if not mission.calls.is_empty():
			break
	eq(acquired, "asset_relay", "a catalog turret with no player around acquires the asset")
	check(not fired.is_empty(), "the turret fires at it")
	check(not events.is_empty(), "its fire hits the asset")
	check(not mission.calls.is_empty() and str(mission.calls[0][0]) == ID, "and reaches mission.damage_asset")
	sq.queue_free()
	await frames(1)


static func _box_body(at: Vector3, size: Vector3) -> StaticBody3D:
	var b := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.position = Vector3(0, size.y * 0.5, 0)     # origin at the base, like MissionWorld's relay body
	b.add_child(cs)
	b.position = at
	return b


func _calls_for(id: String) -> int:
	var n := 0
	for c: Array in mission.calls:
		if str(c[0]) == id:
			n += 1
	return n


func _scorches_near(p: Vector3, r: float) -> int:
	var n := 0
	for e in world.effects:
		if e is ImpactFx and (e as ImpactFx).point.distance_to(p) <= r:
			for part: Dictionary in (e as ImpactFx)._parts:
				if str(part["kind"]) == "scorch":
					n += 1
	return n


func _impacts_near(p: Vector3, r: float) -> int:
	var n := 0
	for e in world.effects:
		if e is ImpactFx and (e as ImpactFx).point.distance_to(p) <= r:
			n += 1
	return n


## 7. The node is the asset's COLLISION BODY (MissionWorld's relay StaticBody3D), physics on: the body is excluded from
## shot rays like a mech capsule (AssetTarget.mech), so a shot meets the hit spheres even though the box is wider than
## them, and the impact leaves no wall scorch on the body. Control: the same shot on an unregistered box scorches it.
func _collision_body() -> void:
	world.use_physics = true
	var at := Vector3(80, 0, 0)
	var body := _box_body(at, Vector3(6.0, 6.0, 6.0))    # half-width 3 m > the 2.5 m spheres
	add_child(body)
	var t := tdc.add_asset("relay_b", body, 2.5, 6.0)
	var wall := _box_body(Vector3(-80, 0, 0), Vector3(6.0, 6.0, 6.0))
	add_child(wall)
	await frames(3)
	check(t != null and t.mech == body, "the AssetTarget takes its parent collision body as the excluded body")
	near(float((t.world_spheres()[0]["center"] as Vector3).y), 3.0, 0.01, "spheres stack up from the body's origin")
	events.clear()
	mission.calls.clear()
	var got: Array = []
	t.asset_damaged.connect(func(id: String, amount: float, _s: String) -> void: got.append([id, amount]))
	var w := str(EnemyCatalog.unit("turret")["primary_weapon"])
	var c := at + Vector3(0, 3.0, 0)
	world.fire(_enemy_rec(w, c + Vector3(0, 0, 25), c, 700))
	var impacts := 0
	var scorches := 0
	for _i in 120:
		world.advance(DT)
		impacts = maxi(impacts, _impacts_near(c, 4.0))
		scorches = maxi(scorches, _scorches_near(c, 4.0))
	eq(got.size(), 1, "physics on: the shot reaches the asset's hit spheres through its own body")
	eq(_calls_for("relay_b"), 1, "and damage_asset once")
	check(impacts >= 1, "the hit made an impact burst")
	eq(scorches, 0, "no wall scorch on the asset's body")
	# Control: an unregistered box takes the same shot as world geometry, and gets a wall scorch.
	var wc := Vector3(-80, 3.0, 0)
	world.fire(_enemy_rec(w, wc + Vector3(0, 0, 25), wc, 701))
	var wall_scorch := 0
	for _i in 120:
		world.advance(DT)
		wall_scorch = maxi(wall_scorch, _scorches_near(wc, 5.0))
	check(wall_scorch >= 1, "control: a plain static box hit by the same shot gets a wall scorch")
	# EnemyBase._check_los does not exclude the target's body: with MissionWorld's relay box (4.2 x 5.4 x 4.2) seen
	# face-on, the ray stops 2.1 m short of the aim centre, inside its 2.6 m tolerance.
	tdc.remove_asset("relay_b")
	body.queue_free()
	wall.queue_free()
	await frames(1)
	var relay := _box_body(at, Vector3(4.2, 5.4, 4.2))
	add_child(relay)
	tdc.add_asset("relay_c", relay, 2.5, 6.0)
	await frames(3)
	var sq := EnemySquad.new()
	add_child(sq)
	sq.setup(world)
	mission.calls.clear()
	var tr := EnemyTurret.new()
	tr.configure("turret", "turret_los", world, sq, null, 1)
	tr.position = at + Vector3(0, 0, 40)
	sq.add_enemy(tr)
	await frames(1)
	var acquired := ""
	for _i in 300:
		world.advance(DT)
		if acquired == "" and tr._target_id != "":
			acquired = tr._target_id
		if _calls_for("relay_c") > 0:
			break
	eq(acquired, "asset_relay_c", "physics on, relay-sized body seen face-on: a turret acquires it (LOS)")
	check(_calls_for("relay_c") >= 1, "and its fire reaches damage_asset")
	sq.queue_free()
	tdc.remove_asset("relay_c")
	relay.queue_free()
	world.use_physics = false
	await frames(1)
