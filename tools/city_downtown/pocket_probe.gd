extends SceneTree
## Ground pockets a mech cannot walk into: a 2D flood fill on a 1 m grid over each section deck from the streets, with
## everything that stands from the ground past knee height (tiers with y0 <= 0.5, solids, pillar cores, floor cuts)
## grown by the mech's radius (2.2 m). Reports open lots / plaza paving the fill never reaches, and a point's status.
##   godot --path . --headless --script res://tools/city_downtown/pocket_probe.gd -- --seeds 1-12 [--at 9,1,85,-266]

const R := 2.2


func _initialize() -> void:
	var lo := 1
	var hi := 12
	var at := []
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--seeds":
			var parts: PackedStringArray = args[i + 1].split("-")
			lo = int(parts[0])
			hi = int(parts[-1])
		if args[i] == "--at":
			at = Array(args[i + 1].split(",")).map(func(v: String) -> float: return float(v))
	var total := 0
	for s in range(lo, hi + 1):
		var sec := SectionPlan.make({"seed": s})
		for k in sec.deck_count:
			if not at.is_empty() and (int(at[0]) != s or int(at[1]) != k):
				continue
			var plan := CityPlan.for_deck(sec, k)
			var e := plan.extent
			var nx := int(e.size.x) + 1
			var ns := int(e.size.y) + 1
			var solid := PackedByteArray()
			solid.resize(nx * ns)
			var block_rects: Array[Rect2] = []
			for i in plan.buildings.size():
				var b: Dictionary = plan.buildings[i]
				for t: Dictionary in b["tiers"]:
					if float(t["y0"]) <= 0.5:
						block_rects.append(plan.tier_rect(i, t))
				for so: Dictionary in b.get("solids", []):
					if float(so["y0"]) <= 0.5:
						var sz: Vector2 = so["size"]
						block_rects.append(Rect2((b["center"] as Vector2) + (so["off"] as Vector2) - sz * 0.5, sz))
				if b["pillar"]:
					var cs: Vector2 = b["core"]["size"]
					block_rects.append(Rect2(Vector2(b["core"]["x"], b["core"]["s"]) - cs * 0.5, cs))
			block_rects.append_array(plan.floor_cuts())
			for c: Dictionary in plan.columns:
				var h := float(c.get("ring_r", c["half"]))
				block_rects.append(Rect2(float(c["x"]) - h, float(c["s"]) - h, h * 2.0, h * 2.0))
			for r in block_rects:
				var g := r.grow(R)
				for ix in range(maxi(int(g.position.x - e.position.x), 0), mini(int(g.end.x - e.position.x) + 1, nx)):
					for js in range(maxi(int(g.position.y - e.position.y), 0), mini(int(g.end.y - e.position.y) + 1, ns)):
						var p := Vector2(e.position.x + ix, e.position.y + js)
						if g.has_point(p):
							solid[ix * ns + js] = 1
			# Seeds: every crossing centre.
			var seen := PackedByteArray()
			seen.resize(nx * ns)
			var stack: Array[int] = []
			for n: Vector2 in plan.road_graph()["nodes"]:
				var ix := int(n.x - e.position.x)
				var js := int(n.y - e.position.y)
				if ix >= 0 and ix < nx and js >= 0 and js < ns and solid[ix * ns + js] == 0:
					seen[ix * ns + js] = 1
					stack.append(ix * ns + js)
			while not stack.is_empty():
				var c: int = stack.pop_back()
				var ix: int = c / ns
				var js: int = c % ns
				for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var x2: int = ix + d.x
					var j2: int = js + d.y
					if x2 < 0 or x2 >= nx or j2 < 0 or j2 >= ns:
						continue
					var c2: int = x2 * ns + j2
					if seen[c2] == 0 and solid[c2] == 0:
						seen[c2] = 1
						stack.append(c2)
			if not at.is_empty():
				var ix := int(float(at[2]) - e.position.x)
				var js := int(float(at[3]) - e.position.y)
				print("[pocket] s%d d%d point (%.0f, %.0f): solid %d, reached %d" % [s, k, at[2], at[3], solid[ix * ns + js], seen[ix * ns + js]])
				for li in plan.lots.size():
					var l: Dictionary = plan.lots[li]
					if (l["rect"] as Rect2).grow(6.0).has_point(Vector2(at[2], at[3])):
						var bs := "-"
						if int(l["building"]) >= 0:
							var b: Dictionary = plan.buildings[int(l["building"])]
							bs = "%s %s%s" % [b["style"], b.get("base", ""), " wing" if b.get("wing", false) else ""]
						print("[pocket]   lot %d %s open '%s' bld %s block %d" % [li, l["rect"], l["open"], bs, int(l["block"])])
			# Open lots (plaza etc.) with a free cell the fill never reached.
			for li in plan.lots.size():
				var l: Dictionary = plan.lots[li]
				if l["open"] == "" or l["open"] == "park":
					continue
				var r: Rect2 = l["rect"]
				var free := 0
				var reached := 0
				for ix in range(maxi(int(r.position.x - e.position.x), 0), mini(int(r.end.x - e.position.x) + 1, nx)):
					for js in range(maxi(int(r.position.y - e.position.y), 0), mini(int(r.end.y - e.position.y) + 1, ns)):
						if solid[ix * ns + js] == 0:
							free += 1
							reached += seen[ix * ns + js]
				if free >= 4 and reached == 0:
					total += 1
					var dt: bool = plan.blocks[int(l["block"])].get("downtown", false)
					var al := plan.alleys.any(func(a: Dictionary) -> bool: return int(a["block"]) == int(l["block"]))
					print("[pocket] s%d d%d lot %d %s open '%s' block %d%s: %d free cells, none reached" % [s, k, li, r, l["open"], int(l["block"]), (" (downtown)" if dt else "") + (" (alley block)" if al else ""), free])
	print("[pocket] sealed open lots: %d" % total)
	quit()
