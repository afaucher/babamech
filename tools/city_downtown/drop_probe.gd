extends SceneTree
## Which dropship drop zones (tests/test_enemy_dropship.gd's multi-seed check) have no road path, and is the deck's
## CityPlan.road_graph() one connected component? Headless:
##   godot --path . --headless --script res://tools/city_downtown/drop_probe.gd


func _initialize() -> void:
	_run.call_deferred()


static func components(g: Dictionary) -> Array:
	var n: int = (g["nodes"] as Array).size()
	var adj := []
	for i in n:
		adj.append([])
	var used := {}
	for ed: Array in g["edges"]:
		adj[int(ed[0])].append(int(ed[1]))
		adj[int(ed[1])].append(int(ed[0]))
		used[int(ed[0])] = true
		used[int(ed[1])] = true
	var comp := []
	var seen := {}
	for i in n:
		if seen.has(i) or not used.has(i):
			continue
		var c := [i]
		seen[i] = true
		var k := 0
		while k < c.size():
			for j: int in adj[c[k]]:
				if not seen.has(j):
					seen[j] = true
					c.append(j)
			k += 1
		comp.append(c)
	return comp


func _run() -> void:
	var w := CombatWorld.new()
	w.mission_seed = 66
	w.use_physics = false
	root.add_child(w)
	var sq := EnemySquad.new()
	root.add_child(sq)
	sq.setup(w)
	for s in range(1, 9):
		var sec := SectionPlan.make({"seed": float(s)})
		var plans: Array[CityPlan] = []
		var rings: Array[RingFrame] = []
		for k in sec.deck_count:
			var dp := CityPlan.for_deck(sec, k)
			plans.append(dp)
			rings.append(RingFrame.new(sec.radius_of(k)))
			sq.add_deck_nav(k, dp)
			var comps := components(dp.road_graph())
			if comps.size() != 1:
				print("[drop] s%d d%d road graph has %d components: sizes %s" % [s, k, comps.size(), comps.map(func(c: Array) -> int: return c.size())])
		for k in sec.deck_count:
			var dp := plans[k]
			var dr := rings[k]
			var lane := (dp.avenue_x().x + dp.avenue_x().y) * 0.5
			var samples: Array[Vector2] = [Vector2(lane, dp.extent.position.y + 28.0), Vector2(lane, 0.0)]
			var arr: Dictionary = sec.arrival(k)
			if arr.has("x") and arr.has("s"):
				samples[0] = Vector2(float(arr["x"]), float(arr["s"]))
			for si in samples.size():
				var sp_arc := samples[si]
				sq._drop_seq += 1
				var zone := sq._pick_drop_zone(dp, dr, dr.arc_to_world(sp_arc.x, sp_arc.y, CityPlan.CURB_H), k)
				if zone.is_empty():
					print("[drop] s%d d%d sample %d: empty zone" % [s, k, si])
					continue
				var da3 := dr.world_to_arc(zone["drop"] as Vector3)
				var drop_arc := Vector2(da3.x, da3.y)
				var path := sq.find_arc_path(sp_arc, drop_arc, k)
				if path.is_empty():
					# Which block / lot is the drop in, which road nodes are nearest.
					var where := "street"
					for bi in dp.blocks.size():
						if (dp.blocks[bi]["rect"] as Rect2).has_point(drop_arc):
							where = "block %d (%s%s%s)" % [bi, dp.blocks[bi]["zone"], ", downtown" if dp.blocks[bi].get("downtown", false) else "",
									", alley" if dp.alleys.any(func(a: Dictionary) -> bool: return int(a["block"]) == bi) else ""]
					print("[drop] s%d d%d sample %d at (%.1f, %.1f): NO PATH to drop (%.1f, %.1f) in %s" % [s, k, si, sp_arc.x, sp_arc.y, drop_arc.x, drop_arc.y, where])
					for a: Dictionary in dp.alleys:
						if (a["rect"] as Rect2).grow(0.01).has_point(drop_arc):
							print("[drop]     the drop is IN the alley %s (block %d)" % [a["rect"], a["block"]])
					for l: Dictionary in dp.lots:
						if (l["rect"] as Rect2).has_point(drop_arc):
							print("[drop]     in lot %s open '%s' building %d" % [l["rect"], l["open"], int(l["building"])])
					# What find_arc_path does: nearest navigable crossing at each end (EnemySquad, read only).
					var keep_n = sq._graph_nodes
					var keep_a = sq._graph_adj
					sq._graph_nodes = sq._deck_graphs[k][0]
					sq._graph_adj = sq._deck_graphs[k][1]
					var rects: Array[Rect2] = sq._deck_occ_rects(k)
					var cuts: Array[Rect2] = sq.deck_cuts(k)
					var sn: int = sq._nearest_nav_node(sp_arc, rects, PackedByteArray(), cuts)
					var gn: int = sq._nearest_nav_node(drop_arc, rects, PackedByteArray(), cuts)
					print("[drop]     start node %d %s, goal node %d %s, straight %.1f m%s" % [sn, sq._graph_nodes[sn], gn, sq._graph_nodes[gn],
							sp_arc.distance_to(drop_arc), " (SAME NODE: find_arc_path returns [] by design)" if sn == gn else ""])
					if sn != gn:
						print("[drop]     A* from start node: %d waypoints" % sq._astar_arc(sp_arc, sn, gn, rects, cuts).size())
					sq._graph_nodes = keep_n
					sq._graph_adj = keep_a
					var g := dp.road_graph()
					var best := -1
					var bd := INF
					for ni in (g["nodes"] as Array).size():
						var dd := (g["nodes"][ni] as Vector2).distance_to(drop_arc)
						if dd < bd:
							bd = dd
							best = ni
					var near: Vector2 = g["nodes"][best]
					print("[drop]     start -> nearest crossing (%.1f, %.1f): %d waypoints; that crossing -> drop: %d"
							% [near.x, near.y, sq.find_arc_path(sp_arc, near, k).size(), sq.find_arc_path(near, drop_arc, k).size()])
	print("[drop] done")
	quit()
