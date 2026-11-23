extends TestCase
## MissionPlan (docs/design/mission-objectives.md §9): objectives, sources and wave pools derived from the section plan.
## Determinism and checksum; one primary per deck, bonus count and spacing, ids, sites inside the deck and outside the
## arrival bubble, needs (existing, acyclic), the one hold; sources inside the deck, clear of pillars and lift platforms,
## outside the bubble; pools (shares, sources, triggers, escalation); options. Swept over seeds 1..30 x decks 2, 3, 5 and
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
	_forced_primary()
	_find_seed()
	finish()


# --- Forced primary type (for the bot), primary_types(), find_seed() --------------------------------------------

## Pinned checksums (re-recorded after round 2: wave counts 2 + 1 per two decks, cap 4; a sweep deck's free wave first;
## re-recorded 2026-11-23 when the section's road forms went live): "" must leave every plan identical to no option.
const BEFORE := {"3:1": "9fd1d1211ed87916", "3:2": "66fe704827fcc8d6", "3:7": "e4118ba1010984a4",
	"3:15": "23a0aa892e3ad6c9", "3:30": "e3985a73c00de43c", "5:1": "676383d1ed4b412b", "5:4": "b5870be92428d5c2",
	"5:22": "20424ab95bd86de7"}


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
				eq((mp.pool(k)["waves"] as Array).size(), want, tag + ": deck %d pool size" % k)
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
		eq(MissionPlan.make(sec).checksum(), BEFORE[key], "decks %s seed %s: checksum as pinned" % [parts[0], parts[1]])
		eq(MissionPlan.make(sec, {"primary": ""}).checksum(), BEFORE[key], "primary \"\": checksum unchanged (%s)" % key)
		eq(MissionPlan.make(sec, {"primary": "bogus"}).checksum(), BEFORE[key], "unknown primary type ignored (%s)" % key)
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
		var waves: Array = pl["waves"]
		if mp.deck_sources(k).is_empty():
			check(waves.is_empty() and float(pl["garrison"]) == 1.0, tag + ": no sources, no waves, garrison 1.0")
			continue
		near(float(pl["garrison"]), 0.5, 0.001, tag + ": garrison half")
		check(waves.size() >= prev, tag + ": deeper decks have at least as many waves")
		check(waves.size() <= 5, tag + ": at most 5 waves")
		prev = waves.size()
		# A sweep ends on a fight: its deck's pool always holds a free wave of its own (round 2 decision).
		if not waves.is_empty() and str(mp.primary(k).get("type", "")) == "sweep":
			var free := 0
			for w: Dictionary in waves:
				free += 1 if w["trigger"]["kind"] == "garrison_low" else 0
			if check(free >= 1, tag + ": sweep deck %d has a garrison_low wave" % k):
				eq(waves[0]["trigger"]["kind"], "garrison_low", tag + ": sweep deck %d: the first slot is the free wave" % k)
			if k == int(sec.extraction["deck"]):
				eq(waves[-1]["trigger"].get("id", ""), "hold", tag + ": sweep extraction deck keeps the hold's wave")
		var sum := 0.0
		var last_share := 0.0
		var lingers := 0
		var wids := {}
		for w: Dictionary in waves:
			sum += float(w["share"])
			check(float(w["share"]) > last_share, tag + ": shares rise")
			last_share = float(w["share"])
			check(not wids.has(w["id"]), tag + ": unique wave id")
			wids[w["id"]] = true
			var s := mp.source(w["source"])
			check(not s.is_empty() and int(s["deck"]) == k, tag + ": wave %s source on its deck" % w["id"])
			check(str(w["theme"]) in ["light", "mixed", "heavy"], tag + ": theme")
			var tr: Dictionary = w["trigger"]
			match str(tr["kind"]):
				"objective":
					check(ids.has(str(tr["id"])) and str(tr["step"]) in ["start", "done"], tag + ": trigger names an objective")
					check(int(ids[str(tr["id"])]["deck"]) == k, tag + ": trigger's objective on the deck")
					var want := "done" if ids[str(tr["id"])]["type"] == "flag" else "start"
					eq(str(tr["step"]), want, tag + ": %s wave on step %s" % [ids[str(tr["id"])]["type"], want])
				"linger":
					lingers += 1
					near(float(tr["after"]), 360.0, 0.001, tag + ": linger after")
				"garrison_low":
					pass
				_:
					check(false, tag + ": unknown trigger " + str(tr["kind"]))
		near(sum, 1.0, 0.0001, tag + ": shares sum to 1")
		if mp.primary(k)["type"] == "sweep":
			eq(lingers, 0, tag + ": a sweep deck has no linger wave")
		check(lingers <= 1, tag + ": at most one linger wave")
		eq(waves[0]["theme"], "light", tag + ": the first wave is light")
		# Defend objectives own params.waves waves, consecutive.
		for o: Dictionary in mp.deck_objectives(k):
			if o["type"] != "defend":
				continue
			var idx: Array = []
			for i in waves.size():
				if waves[i]["trigger"].get("id", "") == o["id"]:
					idx.append(i)
			eq(idx.size(), int(o["params"]["waves"]), tag + ": %s owns its waves" % o["id"])
			if idx.size() > 0:
				eq(int(idx[-1]) - int(idx[0]) + 1, idx.size(), tag + ": %s waves consecutive" % o["id"])
		if k == int(sec.extraction["deck"]):
			var tr: Dictionary = waves[-1]["trigger"]
			check(tr["kind"] == "objective" and tr["id"] == "hold", tag + ": the extraction deck's last wave is the hold's")


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
		var h := MissionPlan.make(sec, {"hold": 30.0, "linger": 100.0, "waves_per_deck": 3})
		near(float(h.objective("hold")["params"]["hold"]), 30.0, 0.001, "hold option")
		for pl: Dictionary in h.pools:
			@warning_ignore("integer_division")
			var want := mini(3 + int(pl["deck"]) / 2, MissionPlan.WAVES_CAP)
			check((pl["waves"] as Array).size() <= want, "waves_per_deck option")
			for w: Dictionary in pl["waves"]:
				if w["trigger"]["kind"] == "linger":
					near(float(w["trigger"]["after"]), 100.0, 0.001, "linger option")


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
		for w: Dictionary in mp.pool(k)["waves"]:
			print("    %s share %.2f %s from %s trigger %s" % [w["id"], float(w["share"]), w["theme"], w["source"], w["trigger"]])
