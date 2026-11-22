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
