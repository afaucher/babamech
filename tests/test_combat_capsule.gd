extends TestCase
## Shots meet a mech through its PlayerTarget hit spheres, never its MechController capsule (CombatWorld.shot_ray excludes
## registered targets' bodies). The capsule (radius 2.2 m, 8 m tall) covers gaps between the hit spheres (the 2026-11-24
## refit: 43 body spheres, first the hull at 6.9 m), so before the fix an off-centre shot struck the capsule as world geometry and did
## no damage. Here, with world physics on and a wall 15 m behind the mech:
## 1. a ray 1.6 m off the axis under the shoulder pods (5.9 m, inside the capsule) hits the torso;
## 2. a ray through the capsule that misses every hit sphere passes through and stops at the wall;
## 3. a real enemy shell fired along ray 1 damages the torso; the same after the mech is unregistered hits the wall instead
##    of nothing (the exclude list follows register / unregister).

const DT := 1.0 / 60.0


func setup() -> void:
	var world := CombatWorld.new()
	add_child(world)
	var wall := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40, 20, 1)
	cs.shape = box
	wall.add_child(cs)
	wall.position = Vector3(0, 5, -15)
	add_child(wall)
	var mech := MechSpawn.make("chicken", "strider", {}, 1)
	mech.puppet = true                 # no physics motion: it stays at the origin
	add_child(mech)
	var pt := PlayerTarget.new()
	pt.auto_respawn_delay = -1.0
	add_child(pt)
	pt.bind(world, mech, MechSpawn.rig_of(mech).model, "player1", 1)
	world.register(pt)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var a1 := Vector3(-1.6, 5.9, 20)
	var b1 := Vector3(-1.6, 5.9, -30)
	var h1 := world.first_hit(a1, b1, 0.0, "enemy_x")
	check(not h1.is_empty() and h1["target"] == pt, "an off-centre chest shot hits the PlayerTarget, not the capsule (%s)" % str(h1))
	if not h1.is_empty() and h1["target"] == pt:
		eq(str(h1["component"]), "torso", "on the torso")
	var h2 := world.first_hit(Vector3(2.1, 5.0, 20), Vector3(2.1, 5.0, -30), 0.0, "enemy_x")
	check(not h2.is_empty() and h2["target"] == null and absf((h2["point"] as Vector3).z - (-14.5)) < 0.05,
		"a shot through the capsule missing every sphere hits the wall behind (%s)" % str(h2))

	var hp0 := float(pt.hp["torso"])
	var rec := Combat.fire_record("enemy_x", 1, "gun", "autocannon", a1, b1, world.now, 1, 0.0)
	rec["enemy"] = true
	rec["team"] = "enemy"
	world.fire(rec)
	for i in 90:
		await get_tree().physics_frame
		world.advance(DT)
	check(float(pt.hp["torso"]) < hp0, "the shell damaged the torso (%.0f -> %.0f)" % [hp0, float(pt.hp["torso"])])

	world.unregister(pt)
	var h3 := world.first_hit(a1, b1, 0.0, "enemy_x")
	check(not h3.is_empty() and h3["target"] == null, "unregistered: the capsule is world geometry again (%s)" % str(h3))
	if not h3.is_empty():
		check((h3["point"] as Vector3).z > 0.5, "it stops at the capsule, not the wall (z %.2f)" % (h3["point"] as Vector3).z)
	world.queue_free()
	pt.queue_free()
	mech.queue_free()
	wall.queue_free()
	await frames(1)
	finish()
