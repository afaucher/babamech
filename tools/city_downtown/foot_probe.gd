extends SceneTree
## Ramp-foot segments (SectionPlan segments with blocked == "foot") against the BUILT collision: for each one, sweep the
## mech capsule (radius 2.2, 8 m) along the cross road from crossing to crossing on parallel lines across the road
## (every 1 m), and report whether any line is clear of the deck's static collision (open) or every line hits (blocked).
## Headless:  godot --path . --headless --script res://tools/city_downtown/foot_probe.gd [-- --seeds 1-20]
## Uses the section road-form mix of tests/test_city_variety.gd (f_lane 0.20, f_pedestrian 0.10, f_none 0.08).

const MECH_R := 2.2
const MECH_H := 8.0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var lo := 1
	var hi := 20
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--seeds" and i + 1 < args.size():
			var parts: PackedStringArray = args[i + 1].split("-")
			lo = int(parts[0])
			hi = int(parts[-1])
	var shape := CapsuleShape3D.new()
	shape.radius = MECH_R
	shape.height = MECH_H
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	var open := []
	var blocked := []
	for s in range(lo, hi + 1):
		var sec := SectionPlan.make({"seed": s, "f_lane": 0.20, "f_pedestrian": 0.10, "f_none": 0.08})
		for k in sec.deck_count:
			var feet: Array[Dictionary] = []
			var all := sec.segments(k)
			for sg: Dictionary in all:
				if str(sg["blocked"]) == "foot":
					feet.append(sg)
			if args.has("--control"):
				# Sanity: the same segment index two cross lines away (an ordinary crossing), reported the same way.
				var ctrl: Array[Dictionary] = []
				for f in feet:
					for sg: Dictionary in all:
						if sg["axis"] == f["axis"] and int(sg["index"]) == int(f["index"]) and absi(int(sg["line"]) - int(f["line"])) == 2 \
								and str(sg["blocked"]) == "" and str(sg["form"]) == "street":
							ctrl.append(sg)
							break
				feet = ctrl
			if feet.is_empty():
				continue
			var d := CityDistrict.new()
			d.with_rig = false
			root.add_child(d)
			d.build_deck(sec, k)
			await physics_frame
			await physics_frame
			var space := d.get_world_3d().direct_space_state
			for sg in feet:
				var r: Rect2 = sg["rect"]
				# A cross segment runs along x between two crossing centres; the road is the rect's s extent.
				var along := 0 if r.size.x >= r.size.y else 1
				var width: float = sec.line_width("x", int(sg["line"])) if along == 0 else sec.line_width("s", int(sg["line"]))
				var mid := r.get_center()[1 - along]
				# Only where the segment crosses a ramp lane on this deck (+-3 m): the question is the ramp body, not
				# whatever stands at the crossings (walls, gates).
				var t0 := r.position[along]
				var t1 := r.end[along]
				for rp: Dictionary in d.plan.ramps:
					if float(rp["x1"]) > r.position.x and float(rp["x0"]) < r.end.x:
						t0 = float(rp["x0"]) - 3.0
						t1 = float(rp["x1"]) + 3.0
				var clear_lines: Array[float] = []
				var off := -width * 0.5 + MECH_R
				while off <= width * 0.5 - MECH_R + 0.001:
					var hit := false
					var t := t0
					while t <= t1 + 0.001:
						var p := Vector2.ZERO
						p[along] = t
						p[1 - along] = mid + off
						var h := CityPlan.CURB_H + 0.3 + MECH_H * 0.5
						q.transform = d.global_transform * Transform3D(CityGeo.frame_basis(d.ring, p.y), d.ring.arc_to_world(p.x, p.y, h))
						for res: Dictionary in space.intersect_shape(q, 8):
							if res["collider"] is StaticBody3D:
								hit = true
						if hit:
							break
						t += 1.0
					if not hit:
						clear_lines.append(off)
					off += 1.0
				var tag := "s%d d%d seg %s line %d index %d (a %d b %d) s %.1f" % [s, k, sg["axis"], int(sg["line"]), int(sg["index"]), int(sg["a"]), int(sg["b"]), mid]
				if clear_lines.is_empty():
					blocked.append(tag)
				else:
					open.append(tag + " clear at offsets %s (road %.0f m)" % [clear_lines, width])
			root.remove_child(d)
			d.free()
	print("[foot] blocked %d:" % blocked.size())
	for l: String in blocked:
		print("[foot]   " + l)
	print("[foot] OPEN %d:" % open.size())
	for l: String in open:
		print("[foot]   " + l)
	quit()
