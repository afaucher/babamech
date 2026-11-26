extends TestCase
## MissionPlan (docs/design/mission-objectives.md §9): objectives, sources and wave pools derived from the section plan.
## Determinism and checksum; one primary per deck, bonus count and spacing, ids, sites inside the deck and outside the
## arrival bubble, needs (existing, acyclic), the one hold; sources inside the deck, clear of pillars and lift platforms,
## outside the bubble; pools (shares, sources, reserve order / objective groups, escalation); options. Swept over seeds 1..30 x decks 2, 3, 5 and
## SectionPlan settings extremes.

const TEST_TIMEOUT := 240
const SETTINGS := [
	{"arc": 300.0}, {"arc": 900.0}, {"width": 160.0}, {"width": 450.0}, {"radius": 150.0, "decks": 5.0},
	{"cell": 60.0}, {"cell": 140.0}, {"shafts": 0.0}, {"shafts": 3.0}, {"express": 0.0},
	{"decks": 5.0, "arc": 900.0, "width": 450.0, "cell": 60.0, "shafts": 3.0},
]
const STATES: Array[String] = ["sweep", "flag", "defend", "hold"]


func _init() -> void:
	timeout_sec = 220.0


func setup() -> void:
	_determinism()
	var count := 0
	var types := {}
	for decks in [2, 3, 5]:
		for seed_ in range(1, 31):
			var sec := SectionPlan.make({"seed": float(seed_), "decks": float(decks)})
			var mp := MissionPlan.make(sec)
			_check(sec, mp, "decks %d seed %d" % [decks, seed_])
			for o: Dictionary in mp.objectives:
				types[o["type"] + ":" + o["role"]] = int(types.get(o["type"] + ":" + o["role"], 0)) + 1
			count += 1
	for i in SETTINGS.size():
		for seed_ in [3, 11, 29]:
			var o: Dictionary = (SETTINGS[i] as Dictionary).duplicate()
			o["seed"] = float(seed_)
			var sec := SectionPlan.make(o)
			_check(sec, MissionPlan.make(sec), "settings %d seed %d" % [i, seed_])
			count += 1
	print("checked %d plans; objective types: %s" % [count, types])
	for t: String in ["sweep:primary", "flag:primary", "defend:primary", "flag:bonus", "defend:bonus", "hold:primary"]:
		check(types.has(t), "the sweep produces some %s" % t)
	_options()
	_report_seed1()
	_unchanged_checksums()
	_wave_counts()
	_flag_placement()

	_forced_primary()
	_forced_keeps_other_decks()
	_find_seed()
	_depots()
	finish()


# --- Forced primary type (for the bot), primary_types(), find_seed() --------------------------------------------

## Pinned checksums (re-recorded after round 2: wave counts 2 + 1 per two decks, cap 4; a sweep deck's free wave first;
## re-recorded 2026-11-23 when the section's road forms went live; again 2026-11-23 for the flag start waves, flag sites
## clear of sources and extra flag waves from the garrison; again 2026-11-23 for the PacingDirector reserve: groups
## {id, share, theme, source, for} without triggers, pacing-director.md 1.1): "" must leave every plan identical to no option.
## 5:4 and 5:22 re-recorded 2026-11-24: their sections gained a ramp under SectionPlan's hop-only rule (5:4 deck 2 -> 3,
## 5:22 deck 0 -> 1); the 3-deck pins' sections are unchanged (was 5:4 "97513cbdd2c08bda", 5:22 "2ec275507b53112e").
const BEFORE := {"3:1": "7c50148d2ab6a34f", "3:2": "463a332f40cc5f18", "3:7": "0fede49b4238169a",
	"3:15": "d3294ce386eb45f8", "3:30": "44490ab89480cf53", "5:1": "c829d1fd4826a04f", "5:4": "71800df7750d594f",
	"5:22": "35d47872a8323015"}
## The same plans WITH their supply depots (checksum(); added 2026-11-23, pacing-director.md §2). BEFORE above is now
## checksum(false): adding depots left every objective / source / pool byte-identical. Re-recorded 2026-11-24: depot sites
## moved into lots off the roads (MissionPlan.depot_site_for). Re-recorded 2026-11-24 (defend
## balance: depot n of a deck prefers 60-150 m from its anchor, MissionPlan.depot_anchors). 5:4 / 5:22 re-recorded
## 2026-11-24 with BEFORE (hop-only ramps; was "ed0f88b8ba815a52" / "6808e3bc45643958").
const WITH_DEPOTS := {"3:1": "85cac211b31e4330", "3:2": "d804528e94e4deec", "3:7": "18e384f470111f15",
	"3:15": "2a77ddc859ea2cde", "3:30": "4abb5fa7540b4e21", "5:1": "17baf79f24d01727", "5:4": "4c411395279f2293",
	"5:22": "24be21cd3d5fac3a"}


## Round 2: pools of waves_per_deck (2) + 1 per two decks of depth, at most 4; a defend has 2 waves on a pool of fewer
## than 4, else 3 (less only if the pool has no room left).
func _wave_counts() -> void:
	var hist := {}
	for decks in [2, 3, 5]:
		for seed_ in range(1, 31):
			var sec := SectionPlan.make({"seed": float(seed_), "decks": float(decks)})
			var mp := MissionPlan.make(sec)
			var tag := "wave counts decks %d seed %d" % [decks, seed_]
			for k in decks:
				@warning_ignore("integer_division")
				var want := 0 if mp.deck_sources(k).is_empty() else mini(2 + k / 2, 4)
				eq(mp.wave_count(k), want, tag + ": deck %d wave_count" % k)
				eq((mp.pool(k)["reserve"] as Array).size(), want + _extra(mp, k),
					tag + ": deck %d pool size = wave_count + its extra flag waves" % k)
				hist[want] = int(hist.get(want, 0)) + 1
			for o: Dictionary in mp.objectives:
				if o["type"] != "defend":
					continue
				var n := int(o["params"]["waves"])
				var pool_n := mp.wave_count(int(o["deck"]))
				check(n == 2 if pool_n < 4 else (n == 3 or n == 2), tag + ": %s has %d waves on a pool of %d" % [o["id"], n, pool_n])
	print("pool sizes (decks 2, 3, 5 x seeds 1-30): %s" % hist)


func _unchanged_checksums() -> void:
	for key: String in BEFORE:
		var parts := key.split(":")
		var sec := SectionPlan.make({"seed": float(parts[1]), "decks": float(parts[0])})
		eq(MissionPlan.make(sec).checksum(false), BEFORE[key], "decks %s seed %s: checksum as pinned" % [parts[0], parts[1]])
		eq(MissionPlan.make(sec, {"primary": ""}).checksum(false), BEFORE[key], "primary \"\": checksum unchanged (%s)" % key)
		eq(MissionPlan.make(sec, {"primary": "bogus"}).checksum(false), BEFORE[key], "unknown primary type ignored (%s)" % key)
		eq(MissionPlan.make(sec).checksum(), WITH_DEPOTS[key], "decks %s seed %s: checksum with depots as pinned" % [parts[0], parts[1]])
	var mp := MissionPlan.make(SectionPlan.make({"seed": 1.0, "decks": 3.0}))
	eq(mp.primary_types(), ["flag", "sweep", "defend"] as Array[String], "primary_types() of seed 1")


func _forced_primary() -> void:
	for forced: String in MissionPlan.PRIMARY_TYPES:
		var fell := 0
		var decks_n := 0
		var cases: Array = []
		for decks in [3, 5]:
			for seed_ in range(1, 31):
				cases.append({"seed": float(seed_), "decks": float(decks)})
		for st: Dictionary in SETTINGS:
			for seed_ in [3, 11, 29]:
				var c: Dictionary = st.duplicate()
				c["seed"] = float(seed_)
				cases.append(c)
		for c: Dictionary in cases:
			if true:
				var sec := SectionPlan.make(c)
				var decks := sec.deck_count
				var mp := MissionPlan.make(sec, {"primary": forced})
				var tag := "forced %s, %s" % [forced, c]
				_check(sec, mp, tag)
				eq(mp.checksum(), MissionPlan.make(sec, {"primary": forced}).checksum(), tag + ": deterministic")
				var types := mp.primary_types()
				eq(types.size(), decks, tag + ": one primary per deck")
				for k in decks:
					decks_n += 1
					if types[k] == forced:
						continue
					fell += 1
					# A fallback only where the deck cannot have the type.
					var site := MissionPlan._primary_site(sec.encounter_sites(k))
					var room := mp.wave_count(k) - (1 if k == int(sec.extraction["deck"]) and mp.wave_count(k) > 0 else 0)
					match forced:
						"sweep":
							var a := sec.arrival(k)
							var d := sec.departure(k)
							check(Vector2(float(d["x"]), float(d["s"])).distance_to(Vector2(float(a["x"]), float(a["s"])))
								< SectionPlan.SAFE_RADIUS, tag + ": deck %d fell back from sweep with its departure clear" % k)
						"flag":
							check(site.is_empty(), tag + ": deck %d fell back from flag with a site" % k)
						"defend":
							check(site.is_empty() or not mp._source_near(k, site) or room < 2,
								tag + ": deck %d fell back from defend while it allowed one" % k)
		print("forced primary %s: %d of %d decks fell back (decks 3 and 5 x seeds 1-30, + SETTINGS x 3 seeds)" % [forced,
			fell, decks_n])
		check(fell < decks_n / 2, "forced %s holds on most decks (%d fell back of %d)" % [forced, fell, decks_n])


## Audit 2026-11 (finding 3): forcing the primary type must not shift the generator for the other decks. Every deck whose
## primary type is the same forced and unforced has byte-identical objectives, reserve and depots in both plans, whatever
## was forced on the decks before it (before the fix, a flag forced over a rolled sweep drew the flag's defend-bonus coin
## and every later deck's bonuses and depots moved).
func _forced_keeps_other_decks() -> void:
	var shifted := 0
	var same_decks := 0
	for forced: String in MissionPlan.PRIMARY_TYPES:
		for decks in [3, 5]:
			for seed_ in range(1, 31):
				var sec := SectionPlan.make({"seed": float(seed_), "decks": float(decks)})
				var plain := MissionPlan.make(sec)
				var mp := MissionPlan.make(sec, {"primary": forced})
				var pt := plain.primary_types()
				var ft := mp.primary_types()
				for k in decks:
					if pt[k] != ft[k]:
						continue
					same_decks += 1
					if _deck_digest(plain, k) != _deck_digest(mp, k):
						shifted += 1
						check(false, "forced %s, decks %d seed %d: deck %d (%s either way) differs from the unforced plan" % [
							forced, decks, seed_, k, pt[k]])
	eq(shifted, 0, "forcing a primary leaves every deck of unchanged type identical (%d decks compared)" % same_decks)


## Everything deck k of a plan rolled or derived: its objectives, its pool, its depots.
func _deck_digest(mp: MissionPlan, k: int) -> String:
	return var_to_str([mp.deck_objectives(k), mp.pool(k), mp.deck_depots(k)])


func _find_seed() -> void:
	for type: String in MissionPlan.PRIMARY_TYPES:
		var s := MissionPlan.find_seed(type)
		print("find_seed(%s) = %d" % [type, s])
		if check(s >= 1, "find_seed(%s) finds a seed" % type):
			check(MissionPlan.make(SectionPlan.make({"seed": float(s)})).primary_types().has(type),
				"find_seed(%s): seed %d's unforced plan has one" % [type, s])
			for earlier in range(1, s):
				check(not MissionPlan.make(SectionPlan.make({"seed": float(earlier)})).primary_types().has(type),
					"find_seed(%s): the first such seed (not %d)" % [type, earlier])
			eq(MissionPlan.find_seed(type), s, "find_seed(%s) deterministic" % type)
		var s5 := MissionPlan.find_seed(type, {"decks": 5.0, "primary": "sweep", "bonus_max": 0}, 10)
		print("find_seed(%s, decks 5, from 10) = %d" % [type, s5])
		if check(s5 >= 10, "find_seed(%s, decks 5) from 10" % type):
			check(MissionPlan.make(SectionPlan.make({"seed": float(s5), "decks": 5.0}), {"bonus_max": 0}).primary_types().has(type),
				"find_seed(%s, decks 5): unforced (primary option dropped), plan has one" % type)
	eq(MissionPlan.find_seed("hold"), -1, "no deck primary is a hold: -1")
	eq(MissionPlan.find_seed("flag", {}, 1, 0), -1, "no tries: -1")


func _determinism() -> void:
	var a := MissionPlan.make(SectionPlan.make({"seed": 7.0}))
	var b := MissionPlan.make(SectionPlan.make({"seed": 7.0}))
	eq(a.checksum(), b.checksum(), "same seed, same checksum")
	eq(str(a.objectives), str(b.objectives), "same seed, same objectives")
	eq(str(a.sources), str(b.sources), "same seed, same sources")
	eq(str(a.pools), str(b.pools), "same seed, same pools")
	var seen := {}
	for s in range(1, 21):
		seen[MissionPlan.make(SectionPlan.make({"seed": float(s)})).checksum()] = true
	eq(seen.size(), 20, "20 seeds, 20 checksums")
	var sec := SectionPlan.make({"seed": 7.0})
	var before := sec.checksum()
	MissionPlan.make(sec)
	eq(sec.checksum(), before, "making a mission does not change the section")
	check(MissionPlan.make(sec, {"hold": 30.0}).checksum() != a.checksum(), "options change the checksum")
	check(MissionPlan.make(sec, {"bonus_max": 0}).checksum() != a.checksum() or a.objectives.size() == a.deck_count + 1,
			"bonus_max changes the checksum")


func _check(sec: SectionPlan, mp: MissionPlan, tag: String) -> void:
	var n := sec.deck_count
	var ids := {}
	var holds := 0
	var primaries: Array = []
	for o: Dictionary in mp.objectives:
		var id: String = o["id"]
		check(not ids.has(id), tag + ": unique objective id " + id)
		ids[id] = o
		check(STATES.has(str(o["type"])), tag + ": known type " + str(o["type"]))
		for key in ["id", "type", "deck", "role", "site", "radius", "snap", "needs", "params"]:
			check(o.has(key), tag + ": %s has %s" % [id, key])
		near(float(o.get("snap", -1.0)), 45.0 if str(o["type"]) in ["flag", "defend"] else 0.0, 0.0001,
				tag + ": %s snap" % id)
		if o["type"] == "hold":
			holds += 1
		elif o["role"] == "primary":
			primaries.append(id)
	eq(holds, 1, tag + ": exactly one hold")
	var hold: Dictionary = mp.objectives[-1]
	eq(hold["id"], "hold", tag + ": the hold is last")
	var hn: Array = hold["needs"].duplicate()
	hn.sort()
	primaries.sort()
	eq(hn, primaries, tag + ": the hold needs every other primary")
	eq(int(hold["deck"]), int(sec.extraction["deck"]), tag + ": hold on the extraction deck")
	check(hold["params"]["zone"] is Rect2, tag + ": hold zone")
	near(float(hold["params"]["hold"]), 60.0, 0.001, tag + ": hold seconds")
	for k in n:
		var ext := MissionPlan._extent(sec, k).grow(0.01)
		var arr := sec.arrival(k)
		var av := Vector2(float(arr["x"]), float(arr["s"]))
		var objs := mp.deck_objectives(k)
		var prim := 0
		var bon: Array[Vector2] = []
		var p_at := Vector2.ZERO
		for o: Dictionary in objs:
			var at := Vector2(float(o["site"]["x"]), float(o["site"]["s"]))
			check(ext.has_point(at), tag + ": %s site inside deck %d" % [o["id"], k])
			if o["type"] != "hold":
				check(at.distance_to(av) >= SectionPlan.SAFE_RADIUS - 0.01,
						tag + ": %s outside the arrival bubble (%.1f m)" % [o["id"], at.distance_to(av)])
			if o["role"] == "primary" and o["type"] != "hold":
				prim += 1
				p_at = at
				eq(o["id"], "d%d_p" % k, tag + ": primary id")
				if o["type"] == "sweep":
					near(float(o["radius"]), 0.0, 0.001, tag + ": sweep radius 0")
					var dep := sec.departure(k)
					near(at.x, float(dep["x"]), 0.01, tag + ": sweep site is the departure")
				if k == 0 and mp.options["primary"] != "defend":   # a forced defend ignores the first-deck rule
					check(o["type"] != "defend", tag + ": the first deck's primary is not a defend")
			match str(o["type"]):
				"flag":
					near(float(o["radius"]), 14.0, 0.001, tag)
					near(float(o["params"]["hold"]), 20.0, 0.001, tag)
				"defend":
					near(float(o["radius"]), 30.0, 0.001, tag)
					check(int(o["params"]["waves"]) >= 2 and int(o["params"]["waves"]) <= 3, tag + ": defend waves 2..3")
					var near_src := false
					for s: Dictionary in mp.deck_sources(k):
						near_src = near_src or at.distance_to(Vector2(float(s["x"]), float(s["s"]))) <= 250.0
					check(near_src, tag + ": a defend has a source within 250 m")
		eq(prim, 1, tag + ": deck %d has exactly one primary" % k)
		var nb := 0
		for o: Dictionary in objs:
			if o["role"] != "bonus":
				continue
			nb += 1
			var at := Vector2(float(o["site"]["x"]), float(o["site"]["s"]))
			check(str(o["id"]).begins_with("d%d_b" % k), tag + ": bonus id " + str(o["id"]))
			if o["type"] == "defend":
				check(o["needs"] == ["d%d_p" % k] and ids["d%d_p" % k]["type"] == "flag",
						tag + ": a bonus defend follows the deck's flag")
				continue
			eq(o["type"], "flag", tag + ": a free bonus is a flag")
			check(at.distance_to(p_at) >= MissionPlan.BONUS_GAP - 0.01, tag + ": bonus 125 m from the primary")
			for b in bon:
				check(at.distance_to(b) >= MissionPlan.BONUS_GAP - 0.01, tag + ": bonuses 125 m apart")
			bon.append(at)
		check(nb <= 2, tag + ": deck %d bonuses <= bonus_max (%d)" % [k, nb])
	# needs: existing ids, no cycles (needs only point to earlier objectives).
	var seen := {}
	for o: Dictionary in mp.objectives:
		for nd: Variant in o["needs"]:
			check(ids.has(str(nd)), tag + ": %s needs an existing id %s" % [o["id"], nd])
			check(seen.has(str(nd)), tag + ": %s needs only earlier objectives (no cycle)" % o["id"])
		seen[o["id"]] = true
	_check_sources(sec, mp, tag)
	_check_pools(sec, mp, ids, tag)


func _check_sources(sec: SectionPlan, mp: MissionPlan, tag: String) -> void:
	var ids := {}
	for s: Dictionary in mp.sources:
		var id: String = s["id"]
		check(not ids.has(id), tag + ": unique source id " + id)
		ids[id] = true
		var k := int(s["deck"])
		var ext := MissionPlan._extent(sec, k)
		var at := Vector2(float(s["x"]), float(s["s"]))
		var tw := Vector2(float(s["toward"]["x"]), float(s["toward"]["s"]))
		check(ext.grow(0.01).has_point(at), tag + ": source %s inside the deck" % id)
		check(ext.grow(0.01).has_point(tw), tag + ": source %s toward inside the deck" % id)
		check(tw.distance_to(at) > 1.0, tag + ": source %s toward is a point away from the door" % id)
		var arr := sec.arrival(k)
		check(at.distance_to(Vector2(float(arr["x"]), float(arr["s"]))) >= SectionPlan.SAFE_RADIUS,
				tag + ": source %s outside the arrival bubble" % id)
		eq(int(s["load"]), int(MissionPlan.LOAD[s["kind"]]), tag + ": load")
		for q: Dictionary in sec.pillars:
			var pid := int(q["id"])
			var pp := sec.pillar_point(k, pid)
			var h := sec.pillar_radius(k, pid)
			check(not Rect2(pp.x - h, pp.y - h, h * 2.0, h * 2.0).has_point(at), tag + ": source %s not in pillar %d" % [id, pid])
		match str(s["kind"]):
			"gate":
				check(str(s["edge"]) in ["s0", "s1", "x0", "x1"] and int(s["connector"]) == -1, tag + ": gate fields")
			"lift":
				var ci := int(s["connector"])
				check(sec.connectors[ci]["kind"] == "lift" and (sec.connectors[ci]["stops"] as Array).has(k), tag + ": lift stop")
				check(not sec.connector_rect(ci, k).has_point(at), tag + ": lift source %s off the platform" % id)
			"ramp":
				check(sec.connectors[int(s["connector"])]["kind"] == "ramp", tag + ": ramp connector")
			"shaft":
				check(int(sec.connectors[int(s["connector"])]["to"]) == k, tag + ": shaft landing below")
	# Every blast door outside the bubble is a source.
	for b: Dictionary in sec.boundaries:
		for g: Dictionary in b["gates"]:
			if g["kind"] == "blast_door":
				var id := "d%d_gate_%s_%d" % [int(b["deck"]), b["edge"], int(g["line"])]
				var s := mp.source(id)
				if s.is_empty():
					var k := int(b["deck"])
					var arr := sec.arrival(k)
					var gx := float(g["x"])
					check(Vector2(gx, float(g["s"])).distance_to(Vector2(float(arr["x"]), float(arr["s"]))) < SectionPlan.SAFE_RADIUS + 20.0,
							tag + ": gate %s missing only when near the arrival" % id)


func _check_pools(sec: SectionPlan, mp: MissionPlan, ids: Dictionary, tag: String) -> void:
	eq(mp.pools.size(), sec.deck_count, tag + ": one pool per deck")
	var prev := -1
	for k in sec.deck_count:
		var pl := mp.pool(k)
		var waves: Array = pl["reserve"]
		if mp.deck_sources(k).is_empty():
			check(waves.is_empty() and float(pl["garrison"]) == 1.0, tag + ": no sources, no waves, garrison 1.0")
			continue
		var extra := _extra(mp, k)
		if extra == 0:
			near(float(pl["garrison"]), 0.5, 0.001, tag + ": garrison half")
		else:
			# Extra flag waves come out of the garrison: less than half, never below GARRISON_MIN.
			check(float(pl["garrison"]) < 0.5 and float(pl["garrison"]) >= MissionPlan.GARRISON_MIN - 0.0001,
				tag + ": deck %d garrison %.3f with %d extra flag wave(s)" % [k, float(pl["garrison"]), extra])
		eq(waves.size(), mp.wave_count(k) + extra, tag + ": pool = wave_count + extra flag waves")
		check(mp.wave_count(k) >= prev, tag + ": deeper decks have at least as many waves")
		check(waves.size() <= MissionPlan.WAVES_CAP + extra, tag + ": at most WAVES_CAP waves + extra flag waves")
		prev = mp.wave_count(k)
		# Every flag objective has exactly one group (`for` its id: the director orders it when the capture starts).
		for o: Dictionary in mp.deck_objectives(k):
			if o["type"] != "flag":
				continue
			var fw: Array = []
			for w: Dictionary in waves:
				if str(w["for"]) == o["id"]:
					fw.append(w)
			if eq(fw.size(), 1, tag + ": flag %s has one group" % o["id"]):
				var at := Vector2(float(o["site"]["x"]), float(o["site"]["s"]))
				var src := mp.source(fw[0]["source"])
				var d := at.distance_to(Vector2(float(src["x"]), float(src["s"])))
				var far := 0.0
				for s: Dictionary in mp.deck_sources(k):
					far = maxf(far, at.distance_to(Vector2(float(s["x"]), float(s["s"]))))
				check(d >= MissionPlan.FLAG_SOURCE_GAP - 0.01 or absf(d - far) < 0.01,
					tag + ": flag %s's wave source %.0f m away (>= 60 m, or the farthest: %.0f)" % [o["id"], d, far])
		# A sweep ends on a fight: its deck's pool always holds a free group of its own (round 2 decision).
		if not waves.is_empty() and str(mp.primary(k).get("type", "")) == "sweep":
			var free := 0
			for w: Dictionary in waves:
				free += 1 if str(w["for"]) == "" else 0
			if check(free >= 1, tag + ": sweep deck %d has a free group" % k):
				eq(str(waves[0]["for"]), "", tag + ": sweep deck %d: the first slot is the free group" % k)
			if k == int(sec.extraction["deck"]):
				eq(str(waves[-1]["for"]), "hold", tag + ": sweep extraction deck keeps the hold's group")
		var sum := 0.0
		var last_share := 0.0
		var wids := {}
		var seen_tied := false
		for w: Dictionary in waves:
			sum += float(w["share"])
			check(float(w["share"]) > last_share, tag + ": shares rise")
			last_share = float(w["share"])
			check(not wids.has(w["id"]), tag + ": unique wave id")
			wids[w["id"]] = true
			var s := mp.source(w["source"])
			check(not s.is_empty() and int(s["deck"]) == k, tag + ": wave %s source on its deck" % w["id"])
			check(str(w["theme"]) in ["light", "mixed", "heavy"], tag + ": theme")
			check(not w.has("trigger"), tag + ": reserve groups carry no trigger (the director decides)")
			var fo := str(w["for"])
			if fo != "":
				seen_tied = true
				check(ids.has(fo), tag + ": %s's group names an objective" % fo)
				check(ids.has(fo) and int(ids[fo]["deck"]) == k, tag + ": the group's objective on the deck")
			else:
				check(not seen_tied, tag + ": free groups come before the objective groups")
		near(sum, 1.0, 0.0001, tag + ": shares sum to 1")
		eq(waves[0]["theme"], "light", tag + ": the first group is light")
		# Defend objectives own params.waves waves, consecutive.
		for o: Dictionary in mp.deck_objectives(k):
			if o["type"] != "defend":
				continue
			var idx: Array = []
			for i in waves.size():
				if str(waves[i]["for"]) == o["id"]:
					idx.append(i)
			eq(idx.size(), int(o["params"]["waves"]), tag + ": %s owns its groups" % o["id"])
			if idx.size() > 0:
				eq(int(idx[-1]) - int(idx[0]) + 1, idx.size(), tag + ": %s waves consecutive" % o["id"])
		if k == int(sec.extraction["deck"]):
			eq(str(waves[-1]["for"]), "hold", tag + ": the extraction deck's last group is the hold's")


## Flag waves this deck holds beyond wave_count (taken from the garrison).
func _extra(mp: MissionPlan, k: int) -> int:
	return maxi((mp.pool(k)["reserve"] as Array).size() - mp.wave_count(k), 0)


## Flag sites sit >= FLAG_SOURCE_GAP (60 m) from every source on their deck where the deck has such a site: a primary
## flag falls back (to the site farthest from its nearest source) only when no eligible site is clear; counted over
## seeds 1-40 (3 decks) with how often the fallback happens.
func _flag_placement() -> void:
	var flags := 0
	var close := 0
	var close_primary := 0
	var wave_close := 0
	var extras := 0
	for seed_ in range(1, 41):
		var sec := SectionPlan.make({"seed": float(seed_)})
		var mp := MissionPlan.make(sec)
		for k in sec.deck_count:
			extras += _extra(mp, k)
		for o: Dictionary in mp.objectives:
			if o["type"] != "flag":
				continue
			flags += 1
			var k := int(o["deck"])
			var at := Vector2(float(o["site"]["x"]), float(o["site"]["s"]))
			var c := mp.source_clearance(k, at)
			if c < MissionPlan.FLAG_SOURCE_GAP:
				close += 1
				if o["role"] == "bonus":
					# A fallback only: no off-route candidate clear of every source fits BONUS_GAP from the primary
					# and the deck's other free bonuses.
					var others: Array[Vector2] = [Vector2(float(mp.primary(k)["site"]["x"]), float(mp.primary(k)["site"]["s"]))]
					for b: Dictionary in mp.deck_objectives(k):
						if b["role"] == "bonus" and b["type"] == "flag" and b["id"] != o["id"]:
							others.append(Vector2(float(b["site"]["x"]), float(b["site"]["s"])))
					for st: Dictionary in MissionPlan._off_route(sec.encounter_sites(k), sec, k):
						var sp := Vector2(float(st["x"]), float(st["s"]))
						if mp.source_clearance(k, sp) < MissionPlan.FLAG_SOURCE_GAP:
							continue
						var fits := true
						for u in others:
							fits = fits and sp.distance_to(u) >= MissionPlan.BONUS_GAP
						check(not fits, "seed %d %s: a bonus flag %.0f m from a source while a clear site (%.0f, %.0f) fitted"
							% [seed_, o["id"], c, sp.x, sp.y])

				if o["role"] == "primary":
					close_primary += 1
					var best := 0.0
					for st: Dictionary in sec.encounter_sites(k):
						if st["safe"] or str(st["kind"]) in ["departure", "extraction"]:
							continue
						best = maxf(best, mp.source_clearance(k, Vector2(float(st["x"]), float(st["s"]))))
					near(c, best, 0.01, "seed %d %s: a close primary flag is the farthest site there is" % [seed_, o["id"]])
			for w: Dictionary in mp.pool(k)["reserve"]:
				if str(w["for"]) == o["id"]:
					var s := mp.source(w["source"])
					if at.distance_to(Vector2(float(s["x"]), float(s["s"]))) < MissionPlan.FLAG_SOURCE_GAP:
						wave_close += 1
	print("flag placement (seeds 1-40, 3 decks): %d flags, %d closer than 60 m to a source (%d primary, fallback), %d start waves from a source < 60 m, %d extra flag waves from garrisons"
		% [flags, close, close_primary, wave_close, extras])
	eq(wave_close, 0, "no flag's start wave is planned from a source closer than 60 m")


func _options() -> void:
	for seed_ in range(1, 11):
		var sec := SectionPlan.make({"seed": float(seed_), "decks": 3.0})
		var sw := MissionPlan.make(sec, {"types": ["sweep"]})
		for o: Dictionary in sw.objectives:
			check(o["type"] == "sweep" or o["type"] == "hold", "types [sweep]: only sweeps (+ hold), got " + str(o["type"]))
		var nb := MissionPlan.make(sec, {"bonus_max": 0})
		for o: Dictionary in nb.objectives:
			check(o["role"] == "primary", "bonus_max 0: no bonuses")
		var one := MissionPlan.make(sec, {"bonus_max": 1})
		for k in sec.deck_count:
			var c := 0
			for o: Dictionary in one.deck_objectives(k):
				c += 1 if o["role"] == "bonus" else 0
			check(c <= 1, "bonus_max 1")
		var fl := MissionPlan.make(sec, {"types": ["flag"]})
		for o: Dictionary in fl.objectives:
			check(o["type"] != "defend", "types [flag]: no defend")
		var h := MissionPlan.make(sec, {"hold": 30.0, "waves_per_deck": 3})
		near(float(h.objective("hold")["params"]["hold"]), 30.0, 0.001, "hold option")
		for pl: Dictionary in h.pools:
			@warning_ignore("integer_division")
			var want := mini(3 + int(pl["deck"]) / 2, MissionPlan.WAVES_CAP)
			check((pl["reserve"] as Array).size() <= want + _extra(h, int(pl["deck"])), "waves_per_deck option (+ extra flag groups)")


func _report_seed1() -> void:
	var sec := SectionPlan.make({"seed": 1.0})
	var mp := MissionPlan.make(sec)
	print("seed 1 (3 decks) checksum %s" % mp.checksum())
	for o: Dictionary in mp.objectives:
		print("  %s %s %s deck %d site (%.0f, %.0f) r %.0f needs %s params %s" % [o["id"], o["type"], o["role"],
				int(o["deck"]), float(o["site"]["x"]), float(o["site"]["s"]), float(o["radius"]), o["needs"], o["params"]])
	for k in sec.deck_count:
		var by := {}
		for s: Dictionary in mp.deck_sources(k):
			by[s["kind"]] = int(by.get(s["kind"], 0)) + 1
		print("  deck %d sources %s" % [k, by])
		for w: Dictionary in mp.pool(k)["reserve"]:
			print("    %s share %.2f %s from %s for %s" % [w["id"], float(w["share"]), w["theme"], w["source"], w["for"]])


# --- Supply depots (pacing-director.md §2) ------------------------------------------------------------------------

## 1 or 2 per deck (2 with a defend or the extraction), at a non-safe encounter site, clear of the sources (and of the
## deck's objective sites) where the deck allows it, two of a deck on different sites; ids, cores; deterministic.
func _depots() -> void:
	var hist := {}
	var src_miss := 0
	var obj_miss := 0
	var near_n := 0      # anchored depots (defend / hold) placed 60-150 m from their anchor
	var near_all := 0
	var near_possible := 0
	for decks in [2, 3, 5]:
		for seed_ in range(1, 41):
			var sec := SectionPlan.make({"seed": float(seed_), "decks": float(decks)})
			var mp := MissionPlan.make(sec)
			var tag := "depots decks %d seed %d" % [decks, seed_]
			var again := MissionPlan.make(sec)
			eq(str(again.depots), str(mp.depots), tag + ": deterministic")
			eq(again.checksum(), mp.checksum(), tag + ": same checksum")
			var ids := {}
			for k in decks:
				var list := mp.deck_depots(k)
				# The candidates as the plan sees them: each non-safe encounter site moved into its nearest lot (off the roads).
				var cands: Array[Dictionary] = []
				var arr0 := sec.arrival(k)
				for st: Dictionary in sec.encounter_sites(k):
					if bool(st["safe"]):
						continue
					var lot := MissionPlan.depot_site_for(sec, k, Vector2(float(st["x"]), float(st["s"])))
					if lot.distance_to(Vector2(float(arr0["x"]), float(arr0["s"]))) < SectionPlan.SAFE_RADIUS:
						continue
					var c := st.duplicate()
					c["x"] = lot.x
					c["s"] = lot.y
					cands.append(c)
				var two: bool = k == int(sec.extraction["deck"])
				for o: Dictionary in mp.deck_objectives(k):
					two = two or str(o["type"]) == "defend"
				hist[list.size()] = int(hist.get(list.size(), 0)) + 1
				if cands.is_empty():
					eq(list.size(), 0, tag + ": deck %d has no site for a depot" % k)
					continue
				check(list.size() >= 1 and list.size() <= 2, tag + ": deck %d has 1 or 2 depots (%d)" % [k, list.size()])
				var clear := 0     # sites clear of every source: a second depot needs one
				for st: Dictionary in cands:
					if mp.source_clearance(k, Vector2(float(st["x"]), float(st["s"]))) >= MissionPlan.DEPOT_SOURCE_GAP:
						clear += 1
				if two:
					eq(list.size(), 2 if clear >= 2 else 1, tag + ": deck %d (defend / extraction) has 2 depots where 2 sites are clear of the sources" % k)
				elif clear < 2:
					eq(list.size(), 1, tag + ": deck %d without two clear sites has 1 depot" % k)
				var best_src := 0.0
				for st: Dictionary in cands:
					best_src = maxf(best_src, mp.source_clearance(k, Vector2(float(st["x"]), float(st["s"]))))
				var ok_both := false     # some site clear of both the sources and the objectives
				for st: Dictionary in cands:
					var at := Vector2(float(st["x"]), float(st["s"]))
					if mp.source_clearance(k, at) >= MissionPlan.DEPOT_SOURCE_GAP and _obj_gap(mp, k, at) >= MissionPlan.DEPOT_OBJECTIVE_GAP:
						ok_both = true
				var arr := sec.arrival(k)
				var prev := Vector2(INF, INF)
				for i in list.size():
					var d: Dictionary = list[i]
					var at := Vector2(float(d["site"]["x"]), float(d["site"]["s"]))
					var dt := tag + " " + str(d["id"])
					eq(str(d["id"]), "d%d_depot%d" % [k, i], dt + ": id")
					check(not ids.has(d["id"]), dt + ": unique id")
					ids[d["id"]] = true
					eq(int(d["cores"]), MissionPlan.DEPOT_CORES, dt + ": cores per pilot (MissionDepots: at least DEPOT_CORES_MIN per depot)")
					var on_site := false
					for st: Dictionary in cands:
						on_site = on_site or at.is_equal_approx(Vector2(float(st["x"]), float(st["s"])))
					check(on_site, dt + ": at a non-safe encounter site's lot")
					for sg: Dictionary in sec.segments(k):
						if (sg["rect"] as Rect2).grow(MissionPlan.DEPOT_LOT_INSET - 0.05).has_point(at):
							check(false, dt + ": off road segment %s %d/%d (%s), by the footprint + margin" % [sg["axis"],
								int(sg["line"]), int(sg["index"]), str(sg["form"])])
					check(at.distance_to(Vector2(float(arr["x"]), float(arr["s"]))) >= SectionPlan.SAFE_RADIUS,
						dt + ": outside the arrival's SAFE_RADIUS")
					var sc := mp.source_clearance(k, at)
					if best_src >= MissionPlan.DEPOT_SOURCE_GAP:
						check(sc >= MissionPlan.DEPOT_SOURCE_GAP, dt + ": >= 60 m from every source (%.0f)" % sc)
					else:
						src_miss += 1
						if i == 0:
							# No candidate clears the source gap: the farthest from the sources among the candidates of
							# the best tier, ranked like MissionPlan's documented rule order (source gap 8, depot gap 4,
							# objective gap 2, anchor band 1; no depot chosen yet, so no depot-gap term for the first).
							var anchors0 := mp.depot_anchors(k)
							var best_tier := 99
							var far := -1.0
							for st: Dictionary in cands:
								var p := Vector2(float(st["x"]), float(st["s"]))
								var tier := 8 if mp.source_clearance(k, p) < MissionPlan.DEPOT_SOURCE_GAP else 0
								if _obj_gap(mp, k, p) < MissionPlan.DEPOT_OBJECTIVE_GAP:
									tier += 2
								if not anchors0.is_empty():
									var da0 := p.distance_to(anchors0[0])
									if da0 < MissionPlan.DEPOT_NEAR_MIN or da0 > MissionPlan.DEPOT_NEAR_MAX:
										tier += 1
								var c := mp.source_clearance(k, p)
								if tier < best_tier:
									best_tier = tier
									far = c
								elif tier == best_tier:
									far = maxf(far, c)
							near(sc, far, 0.01, dt + ": no site clear of the sources: the farthest one of the best tier")
					if i == 0 and ok_both:
						check(_obj_gap(mp, k, at) >= MissionPlan.DEPOT_OBJECTIVE_GAP, dt + ": >= 60 m from the objective sites (possible here)")
					elif _obj_gap(mp, k, at) < MissionPlan.DEPOT_OBJECTIVE_GAP:
						obj_miss += 1
					if i == 1:
						check(at.distance_to(prev) >= MissionPlan.DEPOT_SAME - 0.01, dt + ": a different site from the first depot")
					prev = at
					# Near its anchor (defend balance 2026-11-24): depot i of a deck with anchors sits 60-150 m from anchor i
					# whenever a site satisfying every stronger rule (sources, depot gap, objective gap) is in that band.
					var anchors := mp.depot_anchors(k)
					if i < anchors.size():
						near_all += 1
						var da := at.distance_to(anchors[i])
						var in_band := da >= MissionPlan.DEPOT_NEAR_MIN and da <= MissionPlan.DEPOT_NEAR_MAX
						near_n += 1 if in_band else 0
						var possible := false
						for st: Dictionary in cands:
							var p := Vector2(float(st["x"]), float(st["s"]))
							var dp := p.distance_to(anchors[i])
							var ok := dp >= MissionPlan.DEPOT_NEAR_MIN and dp <= MissionPlan.DEPOT_NEAR_MAX
							ok = ok and (mp.source_clearance(k, p) >= MissionPlan.DEPOT_SOURCE_GAP or sc < MissionPlan.DEPOT_SOURCE_GAP)
							ok = ok and (_obj_gap(mp, k, p) >= MissionPlan.DEPOT_OBJECTIVE_GAP or _obj_gap(mp, k, at) < MissionPlan.DEPOT_OBJECTIVE_GAP)
							for j in i:
								var q: Dictionary = list[j]
								ok = ok and (p.distance_to(Vector2(float(q["site"]["x"]), float(q["site"]["s"]))) >= MissionPlan.DEPOT_GAP
									or at.distance_to(Vector2(float(q["site"]["x"]), float(q["site"]["s"]))) < MissionPlan.DEPOT_GAP)
							possible = possible or ok
						if possible:
							near_possible += 1
							check(in_band, dt + ": 60-150 m from its anchor (%.0f m) where a site allows it" % da)
	print("depots per deck (decks 2, 3, 5 x seeds 1-40): %s; depots near a source (no clear site): %d, near an objective: %d"
		% [hist, src_miss, obj_miss])
	print("anchored depots (defend sites, the hold): %d of %d within 60-150 m of their anchor (%d had such a site)" % [near_n,
		near_all, near_possible])
	var mp1 := MissionPlan.make(SectionPlan.make({"seed": 1.0, "decks": 3.0}))
	var bare := mp1.checksum(false)
	mp1.depots = []
	eq(mp1.checksum(), bare, "checksum(false) is the plan's checksum without depots")
	check(MissionPlan.make(SectionPlan.make({"seed": 1.0, "decks": 3.0})).checksum() != bare, "depots join the checksum")


func _obj_gap(mp: MissionPlan, k: int, at: Vector2) -> float:
	var best := INF
	for o: Dictionary in mp.deck_objectives(k):
		if str(o["type"]) != "sweep":
			best = minf(best, at.distance_to(Vector2(float(o["site"]["x"]), float(o["site"]["s"]))))
	return best
