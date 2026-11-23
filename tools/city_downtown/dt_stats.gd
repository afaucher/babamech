extends SceneTree
## Downtown / alley statistics over section seeds (docs/design/city-downtown.md section 6, city-variety.md section 4).
## Headless:  godot --path . --headless --script res://tools/city_downtown/dt_stats.gd [-- --seeds 1-12]
## Prints per deck: zone blocks / deck blocks, shafts per zone block, slab share, alleys, and why eligible blocks fail.


func _init() -> void:
	var lo := 1
	var hi := 12
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--seeds" and i + 1 < args.size():
			var parts: PackedStringArray = args[i + 1].split("-")
			lo = int(parts[0])
			hi = int(parts[-1])
	var zone_rows := []
	var shafts_hist := {}
	var slabs := 0
	var points := 0
	var why := {}
	var alley_hist := []
	var pillar_in_zone := 0
	var pillar_blocks_eligible := 0
	var pillar_alley := 0
	for seed_ in range(lo, hi + 1):
		var sec := SectionPlan.make({"seed": seed_})
		for k in sec.deck_count:
			var plan := CityPlan.for_deck(sec, k)
			var zone := plan.downtown_blocks()
			var by_block := {}
			for q: Dictionary in plan.site.pillars:
				var bi := int(q["col"]) * sec.rows + int(q["row"])
				if not by_block.has(bi):
					by_block[bi] = []
				by_block[bi].append(q)
			var line := "s%d d%d: zone %d / %d blocks" % [seed_, k, zone.size(), plan.blocks.size()]
			var per := []
			for bi in zone:
				var n := 0
				for i in plan.buildings_in(bi):
					for t: Dictionary in plan.buildings[i]["tiers"]:
						if str(t.get("kind", "")) == "tower":
							n += 1
							if str(t.get("tower", "")) == "slab":
								slabs += 1
							else:
								points += 1
					if plan.buildings[i]["pillar"]:
						n += 1
						pillar_in_zone += 1
				per.append(n)
				shafts_hist[n] = int(shafts_hist.get(n, 0)) + 1
			line += " shafts %s" % [per]
			if not zone.is_empty():
				zone_rows.append(float(zone.size()) / float(plan.blocks.size()))
			# Why eligible blocks are not in the zone.
			for bi in plan.blocks.size():
				var z := str(plan.blocks[bi]["zone"])
				if (z != "urban" and z != "industrial"):
					continue
				if by_block.has(bi):
					pillar_blocks_eligible += 1
				if zone.has(bi):
					continue
				var d: Dictionary = plan._dt_design(bi, by_block.get(bi, []))
				var key := ("pillar " if by_block.has(bi) else "plain ") + (str(d.get("why", "ok (not reached)")))
				if args.has("--why") and not bool(d["ok"]):
					var zr: Rect2 = (plan.blocks[bi]["rect"] as Rect2).grow(-CityPlan.SIDEWALK)
					print("  block %d z %s pillars %s: %s" % [bi, zr, by_block.get(bi, []).map(func(q: Dictionary) -> String: return "(%.1f,%.1f h%.1f %s)" % [q["x"], q["s"], q["half"], q["kind"]]), d.get("why", "")])
					for u: Dictionary in d.get("units", []):
						print("    %s %s room %s opts %s" % [u["kind"], u["rect"], u.get("room", "-"), u.get("opts", "-")])
				why[key] = int(why.get(key, 0)) + 1
			var urban := 0
			for bi in plan.blocks.size():
				var z := str(plan.blocks[bi]["zone"])
				if z == "urban" or z == "industrial":
					urban += 1
			for a: Dictionary in plan.alleys:
				if by_block.has(int(a["block"])):
					pillar_alley += 1
			alley_hist.append(plan.alleys.size())
			line += " alleys %d (urban blocks %d)" % [plan.alleys.size(), urban]
			print(line)
			if args.has("--map"):
				# One row per section row: D zone, o ok design, x failing design, . not eligible; | the spine.
				for r in sec.rows:
					var row := "    "
					for c in sec.cols:
						if c == sec.spine_line:
							row += "|"
						var bi := c * sec.rows + r
						var z := str(plan.blocks[bi]["zone"])
						var ch := "."
						if zone.has(bi):
							ch = "D"
						elif z == "urban" or z == "industrial":
							ch = "o" if bool(plan._dt_design(bi, by_block.get(bi, []))["ok"]) else "x"
						row += ch + ("p" if by_block.has(bi) else " ")
					print(row)
	zone_rows.sort()
	print("zone share on zoned decks (sorted): ", zone_rows.map(func(v: float) -> String: return "%.2f" % v))
	print("shafts per zone block: ", shafts_hist)
	print("slab share: %d slabs / %d shafts = %.2f" % [slabs, slabs + points, float(slabs) / maxf(float(slabs + points), 1.0)])
	print("pillars in zone: %d; eligible pillar blocks: %d" % [pillar_in_zone, pillar_blocks_eligible])
	print("not in zone, why: ", why)
	var tot := 0
	for a: int in alley_hist:
		tot += a
	print("alleys per deck: %s total %d over %d decks; in pillar blocks %d" % [alley_hist, tot, alley_hist.size(), pillar_alley])
	quit()
