extends TestCase
## VISUAL: the invader banners (docs/design/banners.md). Shots in test_logs/shots/:
##   banners_lab_close     the lab subject straight on from 12 m (compare art/renders/enemy_colour_r3/F2c3_banner_close.png)
##   banners_lab_torn      the same after the tear: fringe on the bar, heap at the foot
##   banners_stack_chase   a live solo stack drive (seed 3) with the field wired by this test: a mech on the entry deck
##                         ~20 m from a facade banner, seen from chase-camera distance
##   banners_stack_close   the same banner close, before the tear
##   banners_stack_mid     ~0.4 s into the tear (the host's decision: solo)
##   banners_stack_torn    after it settled
## Runs only under `.\test_runner.ps1 -Visual` (hidden desktop, takes the GPU lock).

const VISUAL := true

var sc: ShotCheck
var cam: Camera3D


func setup() -> void:
	timeout_sec = 240.0
	sc = ShotCheck.new(self)
	if not ShotCheck.available():
		print("test_visual_banners needs a renderer: run .\\test_runner.ps1 -Visual")
		finish()
		return
	await _lab()
	await _stack()
	finish()


func _lab() -> void:
	var lab: Node3D = LabRegistry.make("banners")
	add_child(lab)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.62, 0.68, 0.74)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.75, 0.75, 0.78)
	e.ambient_light_energy = 0.6
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.shadow_enabled = true
	add_child(sun)
	cam = Camera3D.new()
	cam.fov = 50.0
	add_child(cam)
	cam.make_current()
	var focus := Vector3(-2.5, 10.6 - BannerMeshes.H * 0.5, BannerPlan.OUT)
	cam.look_at_from_position(focus + Vector3(0, 0, 12.0), focus)
	await frames(6)
	var a := await sc.grab("banners_lab_close")
	sc.not_blank(a, Rect2(0.35, 0.2, 0.3, 0.6), "the banner close up")
	lab.call("set_lab_param", "tear_t", 1.6)
	cam.look_at_from_position(Vector3(-2.5, 6.0, 15.0), Vector3(-2.5, 4.5, 0.0))
	await frames(4)
	var b := await sc.grab("banners_lab_torn")
	sc.not_blank(b, Rect2(0.3, 0.6, 0.4, 0.35), "the heap")
	lab.queue_free()
	env.queue_free()
	sun.queue_free()
	await frames(2)


func _stack() -> void:
	var td := (load(TestDrive.SCENE) as PackedScene).instantiate() as TestDrive
	td.city_mode = TestDrive.MODE_STACK
	td.seed_value = 3
	add_child(td)
	await frames(10)
	if not check(td.stack != null and td.combat != null, "a stack drive"):
		td.queue_free()
		return
	for en in td.combat.squad.enemies:
		en.ai_mode = "idle"
	td.drive_override = true
	td.mech.move_input = Vector2.ZERO
	var f := td.banners   # Engine wires them into TestDrive
	if f == null:
		f = OccupationBanners.new()
		td.add_child(f)
		f.setup(td.stack, td.combat.world)
	var k := int(td.stack.section.entry["deck"])
	print("banners: %d on the entry deck %d, %d in all" % [f.banner_count(k), k, f.banner_count()])
	# The wall banner nearest the mech's start.
	var best := -1
	var best_d := INF
	for b: Dictionary in f.plans[k]:
		if str(b["kind"]) != "wall":
			continue
		var d := (f.parts(k, int(b["id"]))["anchor"] as Node3D).global_position.distance_to(td.mech.global_position)
		if d < best_d:
			best_d = d
			best = int(b["id"])
	if not check(best >= 0, "a wall banner on the entry deck"):
		td.queue_free()
		return
	var p := f.parts(k, best)
	var anchor: Node3D = p["anchor"]
	var ax := anchor.global_transform
	var out := ax.basis.z.normalized()
	var up := ax.basis.y.normalized()
	var clen := float(p["len"])
	var foot := ax.origin - up * float(p["ground"])
	# The mech on the road facing the banner; the drive's own chase camera behind it.
	td.mech.global_position = foot + out * 18.0 + up * 0.5
	td.mech.global_basis = Basis(up.cross(out).normalized(), up, out)
	td.mech.velocity = Vector3.ZERO
	td.stack.set_active_deck(k)
	td.cam.reset_behind()
	td.cam.make_current()
	await frames(60)
	var chase := await sc.grab("banners_stack_chase")
	sc.not_blank(chase, Rect2(0.25, 0.15, 0.5, 0.6), "the street with the banner")
	cam = Camera3D.new()
	cam.fov = 60.0
	td.add_child(cam)
	cam.make_current()
	var mid := ax.origin - up * clen * 0.5
	# The close views look from across the street: a street tree can stand in the line, so the deck's loose props are
	# hidden for them (the chase shot above keeps them).
	td.stack.decks[k].props.visible = false
	cam.look_at_from_position(mid + out * 13.0 - up * 1.5, mid, up)
	await frames(10)
	var before := await sc.grab("banners_stack_close")
	sc.not_blank(before, Rect2(0.3, 0.2, 0.4, 0.6), "the banner on its facade")
	await _apartment_shot(f, td)
	cam.make_current()
	(p["target"] as BannerTarget).apply_damage(BannerTarget.MAX_HP, "", "test")
	check(f.is_torn(k, best), "the banner tears")
	await frames(24)
	cam.look_at_from_position(mid + out * 16.0 - up * 3.0, ax.origin - up * float(p["ground"]) * 0.55, up)
	await sc.grab("banners_stack_mid")
	await frames(150)
	var after := await sc.grab("banners_stack_torn")
	cam.look_at_from_position(mid + out * 13.0 - up * 1.5, mid, up)
	await frames(4)
	var after_same := await sc.grab("banners_stack_torn_same_view")
	if before != null and after_same != null:
		var diff := _diff(before, after_same, Rect2(0.35, 0.2, 0.3, 0.6))
		check(diff > 0.05, "the banner region changes after the tear (mean diff %.3f)" % diff)
	td.queue_free()
	await frames(2)


## banners_apartment: a wall banner on an apartment face with balconies (docs/design/banners.md "Clear of the facade"),
## seen at an angle from across the street, so the balconies beside it show; it must hang clear of them.
func _apartment_shot(f: OccupationBanners, td: TestDrive) -> void:
	var pick := Vector2i(-1, -1)
	var best := -1      # 1: its face has relief (balconies), 0: an apartment banner on a plain side
	for k in f.plans.size():
		var plan: CityPlan = td.stack.decks[k].plan
		for b: Dictionary in f.plans[k]:
			if str(b["kind"]) != "wall" or str(plan.buildings[int(b["bi"])]["style"]) != "apartment":
				continue
			var score := 0 if CityBuildings.relief(plan, int(b["bi"]), 0)[CityPlan.SIDE_N.find(b["n"])].is_empty() else 1
			if score > best:
				best = score
				pick = Vector2i(k, int(b["id"]))
	if not check(pick.x >= 0, "a wall banner on an apartment"):
		return
	td.stack.set_active_deck(pick.x)
	var p := f.parts(pick.x, pick.y)
	var ax := (p["anchor"] as Node3D).global_transform
	var out := ax.basis.z.normalized()
	var up := ax.basis.y.normalized()
	var side_dir := ax.basis.x.normalized()
	var mid := ax.origin - up * float(p["len"]) * 0.5
	cam.make_current()
	cam.look_at_from_position(mid + out * 17.0 + side_dir * 11.0 - up * 2.0, mid + side_dir * 1.5, up)
	await frames(10)
	var img := await sc.grab("banners_apartment")
	sc.not_blank(img, Rect2(0.3, 0.2, 0.4, 0.6), "the banner on the apartment")
	print("banners_apartment: deck %d banner %d %s" % [pick.x, pick.y, str(f.plans[pick.x][pick.y])])
	td.stack.set_active_deck(int(td.stack.section.entry["deck"]))


func _diff(a: Image, b: Image, frac: Rect2) -> float:
	var w := a.get_width()
	var h := a.get_height()
	var x0 := int(frac.position.x * w)
	var y0 := int(frac.position.y * h)
	var x1 := int(frac.end.x * w)
	var y1 := int(frac.end.y * h)
	var s := 0.0
	var n := 0
	for y in range(y0, y1, 4):
		for x in range(x0, x1, 4):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			s += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
			n += 1
	return s / maxf(float(n) * 3.0, 1.0)
