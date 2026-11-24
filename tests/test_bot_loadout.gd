extends TestCase
## BotLoadout (docs/design/hangar-bots.md §4): a hangar bot's mech from (mission seed, bot slot). The same inputs give the
## same mech; every pick is a valid, playable loadout for its chassis (sanitize_loadout and playable_loadout leave it
## unchanged), under the weight limit, with at least two weapons that fire; the bots of one mission play different
## archetypes and, over many seeds, the loadouts vary.


func setup() -> void:
	var sigs := {}
	for seed_value in range(1, 41):
		var archs := {}
		for slot in range(1, 4):
			var a := BotLoadout.pick(seed_value, slot)
			var b := BotLoadout.pick(seed_value, slot)
			eq(str(a), str(b), "seed %d slot %d: the same pick twice" % [seed_value, slot])
			var ch := str(a["chassis"])
			check(MechCatalog.CHASSIS_ORDER.has(ch), "seed %d slot %d: a hangar chassis (%s)" % [seed_value, slot, ch])
			var l: Dictionary = a["loadout"]
			eq(str(MechCatalog.sanitize_loadout(ch, l)), str(l), "seed %d slot %d: valid for %s" % [seed_value, slot, ch])
			eq(str(WeaponRegistry.playable_loadout(ch, l)["loadout"]), str(l), "seed %d slot %d: playable" % [seed_value, slot])
			var st := MechCatalog.loadout_stats(ch, l)
			check(not bool(st["overweight"]), "seed %d slot %d: under the weight limit (%.0f)" % [seed_value, slot, st["weight"]])
			var guns := 0
			for w: Variant in l.values():
				if str(w) != "" and not MechCatalog.is_equipment(str(w)):
					guns += 1
			check(guns >= 2, "seed %d slot %d: at least two weapons (%s)" % [seed_value, slot, str(l)])
			archs[str(a["archetype"])] = true
			sigs[str(l)] = true
		eq(archs.size(), 3, "seed %d: three bots, three archetypes" % seed_value)
	check(sigs.size() >= 8, "loadouts vary across seeds and slots (%d different)" % sigs.size())
	_brawlers()
	_accents()
	finish()


## A brawler-skill bot picks a close-range kit: CLOSE_ORDER archetypes, three bots three kits, no long-range weapon,
## at least one close-range one; still deterministic and valid.
func _brawlers() -> void:
	for seed_value in range(1, 31):
		var archs := {}
		for slot in range(1, 4):
			var a := BotLoadout.pick(seed_value, slot, "brawler")
			eq(str(a), str(BotLoadout.pick(seed_value, slot, "brawler")), "brawler seed %d slot %d: deterministic" % [seed_value, slot])
			check(BotLoadout.CLOSE_ORDER.has(a["archetype"]), "brawler seed %d slot %d: a close kit (%s)" % [seed_value, slot, a["archetype"]])
			var l: Dictionary = a["loadout"]
			eq(str(MechCatalog.sanitize_loadout(str(a["chassis"]), l)), str(l), "brawler seed %d slot %d: valid" % [seed_value, slot])
			var close := 0
			for w: Variant in l.values():
				check(not (str(w) in ["mortar", "railgun", "missiles", "laser"]), "brawler seed %d slot %d: no long-range %s" % [seed_value, slot, w])
				if str(w) in ["gatling", "flamer", "swivel", "rockets", "flak"]:
					close += 1
			check(close >= 2, "brawler seed %d slot %d: close-range weapons (%s)" % [seed_value, slot, str(l)])
			archs[str(a["archetype"])] = true
		eq(archs.size(), 3, "brawler seed %d: three bots, three kits" % seed_value)


## BotLoadout.accents: every bot a palette colour no other member wears (players keep theirs), the same twice, and the
## colours vary with the seed.
func _accents() -> void:
	var seen := {}
	for seed_value in range(1, 31):
		var crew := [{"peer": 1, "accent": "orange"}, {"peer": -1, "bot": true, "accent": ""},
			{"peer": 7, "accent": "blue"}, {"peer": -2, "bot": true, "accent": "blue"}]
		var a := BotLoadout.accents(seed_value, crew)
		eq(str(a), str(BotLoadout.accents(seed_value, crew)), "seed %d: the same accents twice" % seed_value)
		eq(a.size(), 2, "seed %d: an accent per bot" % seed_value)
		var all: Array = ["orange", "blue", a.get(-1, ""), a.get(-2, "")]
		for x: Variant in all:
			check(MechAccent.ORDER.has(x), "seed %d: %s is a palette accent" % [seed_value, str(x)])
			eq(all.count(x), 1, "seed %d: %s worn once (%s)" % [seed_value, str(x), str(all)])
		seen[str(a.get(-1, ""))] = true
	check(seen.size() >= 3, "the first bot's colour varies with the seed (%s)" % str(seen.keys()))
	var full := [{"peer": 1, "accent": "orange"}, {"peer": -1, "bot": true}, {"peer": -2, "bot": true}, {"peer": -3, "bot": true}]
	var fa := BotLoadout.accents(5, full)
	eq(fa.size(), 3, "three bots, three accents")
	check(fa[-1] != fa[-2] and fa[-2] != fa[-3] and fa[-1] != fa[-3] and not fa.values().has("orange"),
		"three bots and the host all differ (%s)" % str(fa))
