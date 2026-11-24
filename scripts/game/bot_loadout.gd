class_name BotLoadout
extends RefCounted
## A hangar bot picks its own mech (docs/design/hangar-bots.md §4): pure data, no nodes, no global random.
##   BotLoadout.pick(mission_seed, slot) -> {"chassis": id, "loadout": {hardpoint: item}, "archetype": name}
## Every machine calls it with the launch seed and the bot's slot (1..3, = -pilot id) and gets the same mech, so nothing
## about a bot's loadout travels. Generators: hash(["bot_loadout", seed]) for the mission's first archetype, hash(["bot_loadout",
## seed, slot]) for the bot's own choices (AGENTS rule 4).
## VARIETY: each bot plays an ARCHETYPE (gunner, brawler, artillery, support: preferred items per mount kind); the first
## archetype comes from the seed and each slot steps one further, so up to four bots never share one. Each hardpoint takes
## the first preference that fits it, is built (WeaponRegistry: a playable weapon, or back equipment) and keeps the
## weapons under the chassis' max_weight, with a seeded chance to take the next preference instead; then
## WeaponRegistry.playable_loadout (paused weapons swapped) as for any pilot.
## COLOUR: accents(seed, crew) gives each bot of a launch crew a MechAccent (MechAccent.ORDER, the players' palette)
## no other member wears: the players' accents are taken first, then bots by slot, each from hash(["bot_accent", seed,
## slot]) among those left (when all six are taken, any but its own predecessor's). Also derived on every machine.

const ARCHETYPES := {
	"gunner": {"side": ["autocannon", "laser", "flak"], "shoulder": ["missiles", "autocannon", "rockets"],
		"back": ["radiator", "mortar"]},
	"brawler": {"side": ["gatling", "flamer", "swivel"], "shoulder": ["rockets", "flamer", "flak"],
		"back": ["repair_drone", "ammo_bin"]},
	"artillery": {"side": ["laser", "autocannon"], "shoulder": ["railgun", "missiles", "rockets"],
		"back": ["mortar", "radiator"]},
	"support": {"side": ["autocannon", "swivel", "laser"], "shoulder": ["rockets", "missiles"],
		"back": ["repair_drone", "mortar"]},
	# Close-range kits, played only by brawler-skill bots (CLOSE_ORDER).
	"skirmisher": {"side": ["swivel", "gatling"], "shoulder": ["rockets", "flak"], "back": ["ammo_bin", "repair_drone"]},
	"torch": {"side": ["flamer", "gatling"], "shoulder": ["flamer", "rockets"], "back": ["radiator", "ammo_bin"]},
}
const ARCHETYPE_ORDER := ["gunner", "brawler", "artillery", "support"]
## A brawler-skill bot picks among these instead (gatling, flamer, the twin-slug swivel, rockets, flak): still a first
## archetype from the seed and one step per slot, so up to three brawler bots never share one.
const CLOSE_ORDER := ["brawler", "skirmisher", "torch"]
const SWAP_CHANCE := 0.3   ## chance a hardpoint skips its first fitting preference (variety between missions)


## `skill` (the bot's BotProfile id): "brawler" picks a close-range kit (CLOSE_ORDER); any other the full variety.
static func pick(mission_seed: int, slot: int, skill: String = "") -> Dictionary:
	var order: Array = CLOSE_ORDER if skill == "brawler" else ARCHETYPE_ORDER
	var crew_rng := RandomNumberGenerator.new()   # the mission's first archetype: the same for every slot
	crew_rng.seed = hash(["bot_loadout", mission_seed])
	var first := crew_rng.randi_range(0, order.size() - 1)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(["bot_loadout", mission_seed, slot])
	var arch := str(order[(first + maxi(slot, 1) - 1) % order.size()])
	var chassis := str(MechCatalog.BOT_CHASSIS_ORDER[rng.randi_range(0, MechCatalog.BOT_CHASSIS_ORDER.size() - 1)])   # bots: Strider only for now
	var c := MechCatalog.chassis(chassis)
	var prefs: Dictionary = ARCHETYPES[arch]
	var budget := float(c["max_weight"])
	var weight := 0.0
	var out := {}
	for hp: Dictionary in c["hardpoints"]:
		var id := str(hp["id"])
		var cands: Array[String] = []
		for m: Variant in MechCatalog.hardpoint_mounts(hp):
			for w: Variant in prefs.get(str(m), []) as Array:
				if not cands.has(str(w)):
					cands.append(str(w))
		var ok: Array[String] = []
		for w in cands:
			if _usable(hp, w, out) and weight + float(MechCatalog.weapon(w).get("weight", 0.0)) <= budget:
				ok.append(w)
		var chosen := ""
		if not ok.is_empty():
			chosen = ok[1] if ok.size() > 1 and rng.randf() < SWAP_CHANCE else ok[0]
		out[id] = chosen
		weight += float(MechCatalog.weapon(chosen).get("weight", 0.0)) if chosen != "" else 0.0
	var play := WeaponRegistry.playable_loadout(chassis, out)
	return {"chassis": chassis, "loadout": play["loadout"], "archetype": arch}


static func _usable(hp: Dictionary, w: String, so_far: Dictionary) -> bool:
	if not MechCatalog.fits(hp, w):
		return false
	if not (WeaponRegistry.built(w) or MechCatalog.is_equipment(w)):
		return false
	var cap := int(MechCatalog.weapon(w).get("max_per_mech", 0))
	return cap <= 0 or so_far.values().count(w) < cap


## Each bot's accent for a launch crew ([{peer, accent, bot}...]): pilot id -> MechAccent id, distinct from every other
## member's while the palette lasts (players keep theirs; bots in slot order).
static func accents(mission_seed: int, crew: Array) -> Dictionary:
	var taken: Array[String] = []
	var bots: Array[int] = []
	for e: Variant in crew:
		var d := e as Dictionary
		var id := int(d.get("peer", 0))
		if bool(d.get("bot", false)) and id < 0:
			bots.append(id)
		else:
			var a := str(d.get("accent", ""))
			taken.append(a if a != "" else MechAccent.DEFAULT)
	bots.sort()
	bots.reverse()   # -1 (slot 1) first
	var out := {}
	for id in bots:
		var free: Array[String] = []
		for a: String in MechAccent.ORDER:
			if not taken.has(a):
				free.append(a)
		if free.is_empty():
			free.assign(MechAccent.ORDER)
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(["bot_accent", mission_seed, -id])
		var pick := free[rng.randi_range(0, free.size() - 1)]
		out[id] = pick
		taken.append(pick)
	return out
