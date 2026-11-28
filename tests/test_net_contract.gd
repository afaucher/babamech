extends TestCase
## The co-op contract lint (ported from cast's test_net_contract, its sections 1-3; docs/networking.md). Keeps new code
## from quietly breaking the owner-authority plan. Cast's carriers / packet budget / area-verb / late-join sections come
## back with the systems they check (mech snapshots, the host's world, combat).
##
## 1. Declarations: every script that defines net_fields() (and every script listed in NET_SCRIPTS) classifies EVERY
##    script var it has as Net.SPAWN / OWNER / PRIVATE / LOCAL, and names no var that doesn't exist.
## 2. Lint: source patterns that break the plan (RULES). An allowlist entry needs a reason, and adding one is a design
##    decision to report, not a way to make the test pass. Most rules apply outside scripts/net/; the transport rules (no
##    unreliable_ordered, no high-level sync) apply everywhere, and NET_RULES hold scripts/net/ itself to the wire contract.
## 3. The lint is run against lines that must fail (LINT_SAMPLES) and lines it must leave alone (LINT_CLEAN), so a broken
##    regex can't pass silently.
## 4. Carriers (cast's section 4, for mech snapshots): every var NetMechCodec.MECH_FIELDS streams is OWNER on its class (a
##    codec must never stream SPAWN / PRIVATE / LOCAL state), and every OWNER var of those classes is carried.
##    NetMechCodec.PARTIAL_FIELDS (PlayerTarget's damage state, WeaponMount's barrel pose) get only the first half: what
##    they carry must be OWNER; their other OWNER state stays with the owner (reasons written in the codec).
##    The same first half for the host's enemy stream (W4): every var NetEnemyCodec.ENEMY_FIELDS carries is OWNER.
## 5. Crew scaling is the host's (AGENTS.md rule 8): gameplay code in SCALE_SCOPE never sizes anything from a crew count
##    (Session.crew().size(), roster sizes, spawn_order.size(), crew_members().size(), crew_bots.size(), bot_ids().size(),
##    or .size() on a local assigned from one of them in the same function). The one read is SCALE_PATH (the host decides
##    in HOST_SCALE_PATH and replicates it); scripts/net/ is out of scope. SCALE_ALLOW lists the other functions that
##    count the crew for something that is not a scaled gameplay value, each with its reason; entries marked
##    SCALE_PENDING are scaling reads that move to SCALE_PATH (Missions), and come out of the list when they do.

## Gameplay classes that must declare net_fields() even before they define it (none yet: mechs, enemies and pickups go here
## when they exist, unless they define net_fields() themselves).
const NET_SCRIPTS: Array[String] = []

## Lint rules: [id, regex, message, {path: reason} allowlist, scope]. Scope "outside_net" (the default) skips
## scripts/net/; "everywhere" includes it.
var RULES := [
	["unreliable_ordered", "unreliable_ordered|TRANSFER_MODE_UNRELIABLE_ORDERED",
		"GodotSteam sends unreliable_ordered as RELIABLE. Use unreliable + our own sequence numbers.", {}, "everywhere"],
	["net_calls", "@rpc|\\brpc(_id)?\\(|send_bytes\\(|multiplayer_peer|ENetMultiplayerPeer",
		"Network calls live in scripts/net/ only.", {}],
	["steam_api", "get_singleton\\(\\s*\"Steam\"|ClassDB\\.\\w+\\(\\s*\"Steam|\\bSteam\\.\\w+\\(|SteamMultiplayerPeer",
		"Steam is reached only from scripts/net/ (SteamIdentity, SteamLobby, NetSession). Ask Session instead.", {}],
	["high_level_sync", "MultiplayerSynchronizer|MultiplayerSpawner",
		"No MultiplayerSynchronizer/Spawner: we pack our own snapshots (networking.md).", {}, "everywhere"],
	["global_random", "(?<![\\w.])(randf|randi|randf_range|randi_range|randfn|randomize)\\(",
		"No global randomness: gameplay rolls use a generator seeded from the mission (every machine builds the same), looks their own.", {}],
]

## scripts/net/ only: [id, trigger regex, required regex, message]. A line matching the trigger must also match the requirement.
var NET_RULES := [
	["send_bytes_mode", "send_bytes\\(", "TRANSFER_MODE_UNRELIABLE\\b(?!_ORDERED)",
		"send_bytes is for unreliable, sequence-numbered packets: name TRANSFER_MODE_UNRELIABLE (its default is reliable). Events use the reliable RPC."],
	["rpc_reliable", "@rpc\\(", "\"reliable\"",
		"An @rpc is a reliable event; motion goes through send_bytes (NetWire)."],
]

## 5. Crew scaling. Function names are constants so a rename is one edit.
const SCALE_FILE := "res://scripts/mission/mission_flow.gd"
const SCALE_PATH := "crew_scale"              ## MissionFlow.crew_scale(): the one read of the crew scale
const HOST_SCALE_PATH := "host_crew_scale"    ## MissionFlow.host_crew_scale(): the host's decision (recomputed on a retire)
## Tier-3 folder moves (docs/refactor-plan.md §2): the old scope was game/, world/section/, enemy/, combat/. Those files
## now live in mission/ (and its pacing/, depots/, downed/, sync/, world/), bots/crew/, camera/, plus what stayed in
## world/section/, enemy/ (now with units/, squad/, looks/) and combat/ (now with fx/, equipment/). The new folders also
## hold a few files that moved in from outside the old scope (mission/shader_warmup.gd, the mission_* world pieces and
## site_fit from world/city/, the depot kiosk / meshes / lab from world/depot/, bots/crew/mission_bot_pilot.gd from ai/):
## all mission gameplay code, so the scope covers whole folders rather than a file list.
const SCALE_SCOPE := ["res://scripts/mission/", "res://scripts/bots/crew/", "res://scripts/camera/", "res://scripts/world/section/",
	"res://scripts/enemy/", "res://scripts/combat/"]
const SCALE_PENDING := "pending Missions crew_scale"
## Direct crew counts.
const SCALE_COUNT := "\\.crew\\(\\)\\.size\\(\\)|\\broster\\.(size|keys|values)\\(|\\bspawn_order\\.size\\(\\)|crew_members\\(\\)\\.size\\(\\)|\\bcrew_bots\\.size\\(\\)|bot_ids\\(\\)\\.size\\(\\)"
## A local assigned from a crew list (its .size() later in the same function counts too).
const SCALE_SOURCE := "^\\s*var\\s+(\\w+)\\s*(?::[^=]*)?=.*(\\.crew\\(\\)|\\broster\\b|\\bspawn_order\\b|crew_members\\(\\)|\\bcrew_bots\\b|bot_ids\\(\\))"
## "file:function" -> reason. Not scaling (counts for bookkeeping, spawn slots, logs) or SCALE_PENDING.
const SCALE_ALLOW := {
	"res://scripts/mission/mission_flow.gd:_pacing_facts": "pairs each pilot with its facts by index (PacingFacts per-pilot intensity): no value is sized by the count",
	"res://scripts/mission/mission_scene.gd:spawn_enemies": "the pre-play garrison, built from the seed + launch crew before play on the host and checksummed",
	"res://scripts/mission/mission_scene.gd:place_crew": "spawning the mechs: one entry slot per launch-crew mech (spawn layout, not a gameplay value; moved out of build_city)",
	"res://scripts/mission/mission_scene.gd:_spawn_crew": "spawning the mechs: a seat fallback for a launch entry without one",
	"res://scripts/bots/crew/mission_bot.gd:_dev_jump_arrival": "DEV jump to this mech's entry slot (spawn layout, dev only)",
}
## [code, function, expected hit?] for the scan's own regexes.
const SCALE_SAMPLES := [
	["var n := Session.crew().size()", true],
	["hp *= sess.roster.size()", true],
	["var k := drive.spawn_order.size()", true],
	["for i in td.crew_members().size():", true],
	["var b := crew_bots.size() * 2", true],
	["var n := s.bot_ids().size()", true],
	["for c in drive.crew_members():", false],
	["var i := drive.spawn_order.find(me)", false],
	["var n := bots.size()", false],
	["var x := enemies.size()", false],
]

const LINT_SAMPLES := [
	["res://scripts/ui/x.gd", "var s: Object = Engine.get_singleton(\"Steam\")", "steam_api"],
	["res://scripts/ui/x.gd", "var p := ClassDB.instantiate(\"SteamMultiplayerPeer\")", "steam_api"],
	["res://scripts/ui/x.gd", "Steam.run_callbacks()", "steam_api"],
	["res://scripts/ui/x.gd", "foo.rpc_id(1, 2)", "net_calls"],
	["res://scripts/mech/x.gd", "var e := ENetMultiplayerPeer.new()", "net_calls"],
	["res://scripts/mech/x.gd", "var r := randf()", "global_random"],
	["res://scripts/net/x.gd", "@rpc(\"any_peer\", \"unreliable_ordered\")", "unreliable_ordered"],
	["res://scripts/net/x.gd", "@rpc(\"any_peer\", \"unreliable\")", "rpc_reliable"],
	["res://scripts/net/x.gd", "var n := MultiplayerSynchronizer.new()", "high_level_sync"],
	["res://scripts/net/x.gd", "mp.send_bytes(b, 1)", "send_bytes_mode"],
	["res://scripts/net/x.gd", "mp.send_bytes(b, 1, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED)", "send_bytes_mode"],
]
const LINT_CLEAN := [
	["res://scripts/net/x.gd", "mp.send_bytes(b, 1, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE, 2)"],
	["res://scripts/net/x.gd", "@rpc(\"any_peer\", \"call_remote\", \"reliable\", 1)"],
	["res://scripts/net/x.gd", "var s: Object = Engine.get_singleton(\"Steam\")"],
	["res://scripts/ui/x.gd", "label.text = \"Steam not running\""],
	["res://scripts/mech/x.gd", "var r := rng.randf()"],
]


func setup() -> void:
	var scripts := _all_scripts("res://scripts/")
	check(scripts.size() > 10, "found the scripts (%d)" % scripts.size())
	_check_declarations(scripts)
	_check_lint(scripts)
	_check_lint_samples()
	_check_carriers()
	_check_scale(scripts)
	finish()


func _check_declarations(paths: Array[String]) -> void:
	for p in NET_SCRIPTS:
		check(p in paths, "NET_SCRIPTS names a missing file: " + p)
	for p in paths:
		if p in NET_SCRIPTS or FileAccess.get_file_as_string(p).contains("func net_fields("):
			_check_script(p)


func _check_script(path: String) -> void:
	var script := load(path) as GDScript
	if not check(script != null and script.can_instantiate(), path + ": can't instantiate"):
		return
	var obj: Object = script.new()
	if not check(obj.has_method("net_fields"), path + ": no net_fields(). Declare who writes each var (see Net)."):
		_free(obj)
		return
	var fields: Dictionary = obj.net_fields()
	var vars := {}
	for prop in obj.get_property_list():
		if prop["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE:
			vars[prop["name"]] = true
	for v in vars:
		check(fields.has(v), "%s: var `%s` has no authority class. Add it to net_fields() (SPAWN/OWNER/PRIVATE/LOCAL, see Net)." % [path, v])
	for f in fields:
		check(vars.has(f), "%s: net_fields() names `%s`, which isn't a var (stale?)" % [path, f])
		check(Net.is_kind(fields[f]), "%s: `%s` is not a Net kind" % [path, f])
	_free(obj)


## Class name -> script, for the carrier check.
const CARRIER_SCRIPTS := {
	"MechController": "res://scripts/mech/motion/mech_controller.gd",
	"MechRig": "res://scripts/mech/motion/mech_rig.gd",
	"PlayerTarget": "res://scripts/combat/player_target.gd",
	"WeaponMount": "res://scripts/combat/weapon_mount.gd",
}

## Enemy classes the host's stream carries state of (W4): each var NetEnemyCodec.ENEMY_FIELDS names must be OWNER.
const ENEMY_SCRIPTS := {
	"EnemyBase": "res://scripts/enemy/units/enemy_base.gd",
	"EnemyTurret": "res://scripts/enemy/units/enemy_turret.gd",
	"EnemyTank": "res://scripts/enemy/units/enemy_tank.gd",
	"EnemyStrider": "res://scripts/enemy/units/enemy_strider.gd",
}


func _check_carriers() -> void:
	for cls: String in NetMechCodec.MECH_FIELDS:
		if not check(CARRIER_SCRIPTS.has(cls), "NetMechCodec.MECH_FIELDS names %s: add its script to CARRIER_SCRIPTS" % cls):
			continue
		var obj: Object = (load(CARRIER_SCRIPTS[cls]) as GDScript).new()
		var fields: Dictionary = obj.net_fields()
		var carried: Dictionary = NetMechCodec.MECH_FIELDS[cls]
		for v: String in carried:
			check(fields.get(v, -1) == Net.OWNER, "%s.%s is streamed by NetMechCodec but is not Net.OWNER" % [cls, v])
		for v: String in fields:
			if fields[v] == Net.OWNER:
				check(carried.has(v), "%s.%s is Net.OWNER but no snapshot carries it (NetMechCodec.MECH_FIELDS)" % [cls, v])
		_free(obj)


	for cls: String in NetEnemyCodec.ENEMY_FIELDS:
		if not check(ENEMY_SCRIPTS.has(cls), "NetEnemyCodec.ENEMY_FIELDS names %s: add its script to ENEMY_SCRIPTS" % cls):
			continue
		var eobj: Object = (load(ENEMY_SCRIPTS[cls]) as GDScript).new()
		var efields: Dictionary = eobj.net_fields()
		for v: String in NetEnemyCodec.ENEMY_FIELDS[cls]:
			check(efields.get(v, -1) == Net.OWNER, "%s.%s is streamed by NetEnemyCodec but is not Net.OWNER" % [cls, v])
		_free(eobj)

	for cls: String in NetMechCodec.PARTIAL_FIELDS:
		if not check(CARRIER_SCRIPTS.has(cls), "NetMechCodec.PARTIAL_FIELDS names %s: add its script to CARRIER_SCRIPTS" % cls):
			continue
		var obj: Object = (load(CARRIER_SCRIPTS[cls]) as GDScript).new()
		var fields: Dictionary = obj.net_fields()
		for v: String in NetMechCodec.PARTIAL_FIELDS[cls]:
			check(fields.get(v, -1) == Net.OWNER, "%s.%s is streamed by NetMechCodec but is not Net.OWNER" % [cls, v])
		_free(obj)


func _free(obj: Object) -> void:
	if obj is Node:
		obj.free()


func _compiled() -> Array:
	var out := []
	for r: Array in RULES:
		out.append([r[0], RegEx.create_from_string(r[1]), r[2], r[3], r[4] if r.size() > 4 else "outside_net"])
	return out


func _compiled_net() -> Array:
	var out := []
	for r: Array in NET_RULES:
		out.append([r[0], RegEx.create_from_string(r[1]), RegEx.create_from_string(r[2]), r[3]])
	return out


func _violations(p: String, code: String, compiled: Array, compiled_net: Array) -> Array[String]:
	var out: Array[String] = []
	var in_net := p.begins_with("res://scripts/net/")
	for rule: Array in compiled:
		if in_net and rule[4] != "everywhere":
			continue
		if (rule[1] as RegEx).search(code) != null and not (rule[3] as Dictionary).has(p):
			out.append(rule[0])
	if in_net:
		for rule: Array in compiled_net:
			if (rule[1] as RegEx).search(code) != null and (rule[2] as RegEx).search(code) == null:
				out.append(rule[0])
	return out


func _check_lint(paths: Array[String]) -> void:
	var compiled := _compiled()
	var compiled_net := _compiled_net()
	var messages := {}
	for rule: Array in compiled:
		messages[rule[0]] = rule[2]
		for p: String in rule[3]:
			check(p in paths, "rule %s allowlists a missing file: %s" % [rule[0], p])
	for rule: Array in compiled_net:
		messages[rule[0]] = rule[3]
	for p in paths:
		var lines := FileAccess.get_file_as_string(p).split("\n")
		for i in lines.size():
			var code := _strip_comment(lines[i])
			if code.strip_edges() == "":
				continue
			for id: String in _violations(p, code, compiled, compiled_net):
				_fail("%s:%d [%s] %s" % [p, i + 1, id, messages[id]])


func _check_lint_samples() -> void:
	var compiled := _compiled()
	var compiled_net := _compiled_net()
	for smp: Array in LINT_SAMPLES:
		check(_violations(smp[0], smp[1], compiled, compiled_net).has(smp[2]), "the lint flags `%s` in %s as %s" % [smp[1], smp[0], smp[2]])
	for smp: Array in LINT_CLEAN:
		var v := _violations(smp[0], smp[1], compiled, compiled_net)
		check(v.is_empty(), "the lint leaves `%s` in %s alone (got %s)" % [smp[1], smp[0], str(v)])


## 5. Crew scaling: every crew count in SCALE_SCOPE outside the scale path is in SCALE_ALLOW (and every entry still hits).
func _check_scale(paths: Array[String]) -> void:
	var count := RegEx.create_from_string(SCALE_COUNT)
	var source := RegEx.create_from_string(SCALE_SOURCE)
	for smp: Array in SCALE_SAMPLES:
		eq(count.search(str(smp[0])) != null, bool(smp[1]), "the crew-count scan on `%s`" % smp[0])
	var two := _scale_hits("res://x.gd", "func f() -> void:\n\tvar m := drive.crew_members()\n\tvar n := m.size()\n", count, source)
	eq(two.size(), 1, "the scan follows a local assigned from crew_members() to its .size()")
	var used := {}
	for p in paths:
		if not SCALE_SCOPE.any(func(d: String) -> bool: return p.begins_with(d)):
			continue
		for h: Dictionary in _scale_hits(p, FileAccess.get_file_as_string(p), count, source):
			var key := "%s:%s" % [p, h["func"]]
			if p == SCALE_FILE and str(h["func"]) in [SCALE_PATH, HOST_SCALE_PATH]:
				continue
			if SCALE_ALLOW.has(key):
				used[key] = true
				continue
			_fail("%s:%d [crew_scale] `%s`: crew-scaled values come only from %s.%s() (the host's scale, replicated): AGENTS.md rule 8. Not scaling? Allowlist %s with a reason (a design decision to report)." % [
				p, int(h["line"]), str(h["code"]).strip_edges(), "MissionFlow", SCALE_PATH, key])
	for key: String in SCALE_ALLOW:
		check(used.has(key), "SCALE_ALLOW entry %s no longer counts the crew: remove it" % key)


## Crew counts in one script: [{func, line, code}]. Tracks the enclosing func and locals assigned from a crew list.
func _scale_hits(path: String, text: String, count: RegEx, source: RegEx) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var fn := ""
	var locals: Array[String] = []
	var func_re := RegEx.create_from_string("^(?:static\\s+)?func\\s+(\\w+)")
	var lines := text.split("
")
	for i in lines.size():
		var code := _strip_comment(lines[i])
		var fm := func_re.search(code)
		if fm != null:
			fn = fm.get_string(1)
			locals.clear()
			continue
		if code.strip_edges() == "":
			continue
		var hit := count.search(code) != null
		for l in locals:
			if RegEx.create_from_string("\\b%s\\.size\\(\\)" % l).search(code) != null:
				hit = true
		var sm := source.search(code)
		if sm != null:
			locals.append(sm.get_string(1))
		if hit:
			out.append({"func": fn, "line": i + 1, "code": code})
	return out


## The line without its # comment (a # inside a string literal is kept).
static func _strip_comment(line: String) -> String:
	var quote := ""
	var i := 0
	while i < line.length():
		var ch := line[i]
		if quote != "":
			if ch == "\\":
				i += 1
			elif ch == quote:
				quote = ""
		elif ch == "\"" or ch == "'":
			quote = ch
		elif ch == "#":
			return line.substr(0, i)
		i += 1
	return line


func _all_scripts(dir: String) -> Array[String]:
	var out: Array[String] = []
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir + f)
	for d in DirAccess.get_directories_at(dir):
		out.append_array(_all_scripts(dir + d + "/"))
	return out
