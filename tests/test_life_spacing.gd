extends TestCase
## Crowd spacing (docs/design/ambient-life.md "Crowd spacing"): people never stand, wait, sit, cower or lie on the same
## spot. Measured on the gameplay positions (LifeCrowd.pose: what shots hit), on several sites: the crowd lab district
## (130 x 130 m, 24 / 60 / 120 people), a full district and two section decks. Calm: the life clock sampled every 0.5 s for
## CALM_S s. Then a strength-3 threat and a blast (everyone outdoors within BLAST_R m killed) at the densest spot, and
## THREAT_S s of the panic sampled the same way. Per sample: pairs of visible people closer than BODY m (by situation:
## state and place), the closest pair of standing people (wait / sit / cower / wary), the largest group inside a 1 m
## disc, and walker pairs closer than COINCIDE m (the longest such stretch). No wall-clock timing.

const T0 := 900.0
const CALM_S := 240.0
const THREAT_S := 40.0
const DT := 0.5
const BODY := 0.6
const COINCIDE := 0.4
const BLAST_R := 4.0
## The guarantees (asserted)
const MIN_STANDING := 0.7       ## m between any two standing / waiting / sitting people, calm
const MAX_DISC := 3             ## people inside any 1 m disc, calm
## Walkers are not guaranteed apart (each walks its own closed-form route; two strangers on one lane at nearly one speed
## can overtake slowly): asserted rare instead, the longest such stretch is reported.
const MAX_COINCIDE_SHARE := 0.05  ## of walker samples, at most this share within COINCIDE m of another walker (measured 0.2-4 %)
const MIN_PANIC_STANDING := 0.6 ## m between any standing / cowering / wary people and bodies after a blast (feet points)

const STANDING := ["wait", "sit", "cower", "wary", "down"]


func _init() -> void:
	timeout_sec = 400.0


func setup() -> void:
	var lab := {"walls": 1.0, "size_x": 130.0, "size_s": 130.0}
	_site("lab seed 1, 24 people", CityPlan.make(lab.merged({"seed": 1})), 24)
	_site("lab seed 1, 60 people", CityPlan.make(lab.merged({"seed": 1})), 60)
	_site("lab seed 1, 120 people", CityPlan.make(lab.merged({"seed": 1})), 120)
	_site("lab seed 3, 60 people", CityPlan.make(lab.merged({"seed": 3})), 60)
	# the setup of docs/design/ambient-life/civ_c_crowd.gif (the clump the user saw): 160 people on 90 x 90 m
	# (18 x the game's densest deck: walkers crowd the sidewalks there, so their share is only reported)
	_site("lab seed 1, 90 m, 160 people", CityPlan.make({"walls": 1.0, "size_x": 90.0, "size_s": 90.0, "seed": 1}), 160, 1.0)
	_site("district seed 2, default", CityPlan.make({"seed": 2}), -1)
	var sec := SectionPlan.make({"seed": 1})
	_site("section seed 1 deck 0", CityPlan.for_deck(sec, 0), -1)
	_site("section seed 1 deck 1", CityPlan.for_deck(sec, 1), 60)
	finish()


func _place(lp: LifePlan, at: Vector2, places: Dictionary) -> String:
	for d: Dictionary in lp.doors:
		if (d["at"] as Vector2).distance_to(at) < 1.5:
			return "door"
	for b: Dictionary in lp.benches:
		if (b["at"] as Vector2).distance_to(at) < 2.5:
			return "bench"
	for n: int in places["corners"]:
		if lp.nodes[n].distance_to(at) < 4.0:
			return "corner"
	return "lane"


func _site(what: String, cp: CityPlan, people: int, walker_share: float = MAX_COINCIDE_SHARE) -> void:
	var lp := LifePlan.make(cp, people, 200)
	var crowd := LifeCrowd.new(lp)
	var corners := {}
	for ed: Array in lp.edges:
		if int(ed[2]) == LifePlan.CROSS:
			corners[int(ed[0])] = true
			corners[int(ed[1])] = true
	var places := {"corners": corners.keys()}
	var calm := _measure(lp, crowd, places, T0, T0 + CALM_S, false)
	# The densest spot of the calm run's last sample (else anyone outdoors): threat + blast there.
	var tb := T0 + CALM_S
	var at := Vector2(INF, INF)
	var best := -1
	var pts: Array = []
	for id in lp.total():
		var p := crowd.pose(id, tb)
		if p["visible"]:
			pts.append(Vector2(p["x"], p["s"]))
	for a: Vector2 in pts:
		var n := 0
		for b: Vector2 in pts:
			if a.distance_to(b) < BLAST_R:
				n += 1
		if n > best:
			best = n
			at = a
	if best < 0:
		check(false, "%s: someone outdoors to blast" % what)
		return
	crowd.apply_threat({"x": at.x, "s": at.y, "r": 30.0, "st": 3, "t": tb})
	var killed := 0
	for id in lp.total():
		var p := crowd.pose(id, tb)
		var q := Vector2(p["x"], p["s"])
		if p["visible"] and q.distance_to(at) <= BLAST_R and crowd.kill(id, tb, q - at, 0):
			killed += 1
	var panic := _measure(lp, crowd, places, tb, tb + THREAT_S, true)
	print("[spacing] %s: people %d" % [what, lp.count])
	print("  calm : %s" % _fmt(calm))
	print("  panic: %s  (blast at %s killed %d)" % [_fmt(panic), str(at.snapped(Vector2(0.1, 0.1))), killed])
	check(calm["samples"] > 0, "%s: sampled" % what)
	check(float(calm["min_standing"]) >= MIN_STANDING, "%s: calm standing people at least %.2f m apart (worst %.3f m, %s)"
			% [what, MIN_STANDING, calm["min_standing"], calm["min_standing_where"]])
	check(int(calm["max_disc_st"]) <= MAX_DISC, "%s: calm at most %d standing people in a 1 m disc (worst %d)"
			% [what, MAX_DISC, calm["max_disc_st"]])
	var share := float(calm["walk_close"]) / maxf(float(calm["walk_n"]), 1.0)
	print("  calm walkers within %.1f m of another: %.2f %% of %d walker samples" % [COINCIDE, share * 100.0, calm["walk_n"]])
	check(share <= walker_share, "%s: calm walkers within %.1f m of another in at most %.0f %% of samples (%.2f %%)"
			% [what, COINCIDE, walker_share * 100.0, share * 100.0])
	check(float(panic["min_standing"]) >= MIN_PANIC_STANDING, "%s: after a blast, cowering people and bodies at least %.2f m apart (worst %.3f m, %s)"
			% [what, MIN_PANIC_STANDING, panic["min_standing"], panic["min_standing_where"]])


func _fmt(m: Dictionary) -> String:
	var keys: Array = (m["close"] as Dictionary).keys()
	keys.sort()
	var parts: Array = []
	for k: String in keys:
		parts.append("%s %d" % [k, m["close"][k]])
	return "%d samples, pairs < %.1f m: %d (%s); closest standing %.3f m (%s); largest 1 m group %d (%s), of standing people %d; walkers < %.1f m longest %.1f s (%s)" % [
			m["samples"], BODY, m["pairs"], ", ".join(parts), m["min_standing"], m["min_standing_where"], m["max_disc"],
			m["max_disc_where"], m["max_disc_st"], COINCIDE, m["walk_run_s"], m["walk_run_where"]]


func _measure(lp: LifePlan, crowd: LifeCrowd, places: Dictionary, t0: float, t1: float, panic: bool) -> Dictionary:
	var out := {"samples": 0, "pairs": 0, "close": {}, "min_standing": INF, "min_standing_where": "-", "max_disc": 0,
			"max_disc_where": "-", "walk_run_s": 0.0, "max_disc_st": 1, "walk_run_where": "-", "walk_n": 0, "walk_close": 0}
	var runs := {}           # Vector2i(a, b) -> seconds the two walkers have been within COINCIDE m
	var t := t0
	while t < t1 - 1e-6:
		t += DT
		out["samples"] = int(out["samples"]) + 1
		var ids: Array[int] = []
		var at: Array[Vector2] = []
		var mode: Array[String] = []
		var grid := {}
		for id in lp.total():
			var p := crowd.pose(id, t)
			if not p["visible"]:
				continue
			var q := Vector2(p["x"], p["s"])
			var m := str(p["mode"])
			ids.append(id)
			at.append(q)
			mode.append(m)
			var c := Vector2i(floori(q.x), floori(q.y))
			if not grid.has(c):
				grid[c] = []
			(grid[c] as Array).append(ids.size() - 1)
		var seen := {}
		var close_walker := {}
		for i in ids.size():
			var c := Vector2i(floori(at[i].x), floori(at[i].y))
			var disc_best := 0
			if not (mode[i] in STANDING):
				out["walk_n"] = int(out["walk_n"]) + 1
			for dx in range(-1, 2):
				for ds in range(-1, 2):
					for j: int in grid.get(c + Vector2i(dx, ds), []):
						if j == i:
							continue
						var d := at[i].distance_to(at[j])
						# the largest 1 m disc group: centred on a person or on the midpoint of a close pair
						if j > i and d < 1.0:
							var mid := (at[i] + at[j]) * 0.5
							var n := 0
							var n_st := 0
							for ex in range(-1, 2):
								for es in range(-1, 2):
									for k: int in grid.get(Vector2i(floori(mid.x), floori(mid.y)) + Vector2i(ex, es), []):
										if at[k].distance_to(mid) <= 0.5 + 1e-4:
											n += 1
											if mode[k] in STANDING:
												n_st += 1
							disc_best = maxi(disc_best, n)
							if n_st > int(out["max_disc_st"]):
								out["max_disc_st"] = n_st
						if j <= i:
							continue
						var sa := mode[i] in STANDING
						var sb := mode[j] in STANDING
						if sa and sb and d < float(out["min_standing"]):
							out["min_standing"] = d
							out["min_standing_where"] = "%s/%s at %s, ids %d %d, t %.1f" % [mode[i], mode[j],
									_place(lp, at[i], places), ids[i], ids[j], t]
						if d < BODY:
							out["pairs"] = int(out["pairs"]) + 1
							var key := "%s+%s@%s" % [mode[i] if mode[i] < mode[j] else mode[j],
									mode[j] if mode[i] < mode[j] else mode[i], _place(lp, at[i], places)]
							out["close"][key] = int(out["close"].get(key, 0)) + 1
						if d < COINCIDE and not sa and not sb and not panic:
							close_walker[i] = true
							close_walker[j] = true
							var pk := Vector2i(ids[i], ids[j])
							seen[pk] = true
							runs[pk] = float(runs.get(pk, 0.0)) + DT
							if float(runs[pk]) - DT > float(out["walk_run_s"]):
								out["walk_run_s"] = float(runs[pk]) - DT
								out["walk_run_where"] = "ids %d %d %s/%s at %s, t %.1f, %.2f m" % [ids[i], ids[j], mode[i], mode[j],
										_place(lp, at[i], places), t, d]
			if disc_best > int(out["max_disc"]):
				out["max_disc"] = disc_best
				out["max_disc_where"] = "%s at %s, t %.1f" % [mode[i], _place(lp, at[i], places), t]
		out["walk_close"] = int(out["walk_close"]) + close_walker.size()
		for pk: Vector2i in runs.keys():
			if not seen.has(pk):
				runs.erase(pk)
	return out
