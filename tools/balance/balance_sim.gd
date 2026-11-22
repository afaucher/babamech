extends Node
## Headless CLI entry point for the babamech Combat Balance Simulator (docs/design/player-ai.md §6.1).
## Invoked via tools/balance/run_balance.ps1 (--headless -- --scene res://tools/balance/balance_sim.tscn [args]).


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	var args := OS.get_cmdline_user_args()
	var suite := _arg(args, "--suite", "quick")
	var profiles := _parse_csv(args, "--profile")
	var seeds := _parse_seeds(_arg(args, "--seeds", ""))
	var loadout := _arg(args, "--loadout", "")
	var overrides := BalanceScenarios.parse_overrides(_arg(args, "--override", ""))
	var baseline_path := _arg(args, "--baseline", "")
	var save_baseline := _arg(args, "--save-baseline", "")
	var out_dir := _arg(args, "--out-dir", ProjectSettings.globalize_path("res://test_logs/balance"))
	var shard_str := _arg(args, "--shard", "")
	var shard_out := _arg(args, "--shard-out", "")
	var merge_dir := _arg(args, "--merge-dir", "")
	var elapsed_override := float(_arg(args, "--elapsed", "-1"))

	var raw_runs: Array[Dictionary] = []
	if merge_dir != "":
		var files := DirAccess.get_files_at(merge_dir)
		files.sort()
		for fn: String in files:
			if not fn.ends_with(".json"):
				continue
			var txt := FileAccess.get_file_as_string(merge_dir.path_join(fn))
			var parsed: Variant = JSON.parse_string(txt)
			if parsed is Dictionary:
				for item: Variant in (parsed as Dictionary).get("runs", []):
					if item is Dictionary:
						raw_runs.append(item as Dictionary)
	else:
		var specs := BalanceScenarios.build_suite(suite, profiles, seeds, loadout, overrides)
		if shard_str != "":
			var parts := shard_str.split("/")
			if parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int():
				var idx := int(parts[0])
				var tot := maxi(int(parts[1]), 1)
				var mine: Array[Dictionary] = []
				for i in specs.size():
					if i % tot == idx:
						mine.append(specs[i])
				specs = mine

		for sp: Dictionary in specs:
			var res := await BalanceScenarios.run_scenario(self, sp)
			raw_runs.append(res)

		if shard_out != "":
			DirAccess.make_dir_recursive_absolute(shard_out.get_base_dir())
			var f := FileAccess.open(shard_out, FileAccess.WRITE)
			if f != null:
				f.store_string(JSON.stringify({"runs": raw_runs}, "  "))
				f.close()
			get_tree().quit(0)
			return

	var rows := _collapse_rows(raw_runs)
	for r: Dictionary in rows:
		r["verdict"] = BalanceVerdict.evaluate_row(r)
	var cross_checks := BalanceVerdict.evaluate_cross_checks(rows)
	var elapsed_s := elapsed_override if elapsed_override >= 0.0 else (float(Time.get_ticks_msec() - t0) / 1000.0)
	var baseline_map := BalanceVerdict.load_baseline(baseline_path)

	var md := BalanceVerdict.format_markdown(rows, cross_checks, elapsed_s, suite, baseline_map)
	var csv := BalanceVerdict.format_csv(rows)
	var json_str := JSON.stringify(BalanceVerdict.to_json_dict(rows, cross_checks, {
		"suite": suite, "runs": raw_runs.size(), "elapsed_s": elapsed_s, "overrides": overrides, "loadout": loadout,
	}), "  ")

	DirAccess.make_dir_recursive_absolute(out_dir)
	var gdignore := out_dir.get_base_dir().path_join(".gdignore")
	if not FileAccess.file_exists(gdignore):
		var ig := FileAccess.open(gdignore, FileAccess.WRITE)
		if ig != null:
			ig.close()

	_write_text(out_dir.path_join("latest.md"), md + "\n")
	_write_text(out_dir.path_join("latest.csv"), csv + "\n")
	_write_text(out_dir.path_join("latest.json"), json_str + "\n")
	if save_baseline != "":
		DirAccess.make_dir_recursive_absolute(save_baseline.get_base_dir())
		_write_text(save_baseline, json_str + "\n")

	print(md)
	print("")
	print("Artifacts: %s | %s | %s" % [
		out_dir.path_join("latest.md"), out_dir.path_join("latest.csv"), out_dir.path_join("latest.json")])
	get_tree().quit(0)


static func _collapse_rows(raw_runs: Array[Dictionary]) -> Array[Dictionary]:
	# Group multi-seed city runs by (scenario, profile); keep duels & pockets as single rows.
	var groups: Dictionary = {}
	var order: Array[String] = []
	for r: Dictionary in raw_runs:
		var k := "%s:%s" % [str(r["scenario"]), str(r["profile"])]
		if not groups.has(k):
			groups[k] = []
			order.append(k)
		(groups[k] as Array).append(r)
	var out: Array[Dictionary] = []
	for k in order:
		var arr: Array[Dictionary] = []
		for item: Variant in groups[k]:
			arr.append(item as Dictionary)
		if arr.size() == 1:
			out.append(arr[0])
		else:
			var sc := str(arr[0]["scenario"])
			var s_min := int(arr[0]["seed"])
			var s_max := int(arr[0]["seed"])
			for r in arr:
				s_min = mini(s_min, int(r["seed"]))
				s_max = maxi(s_max, int(r["seed"]))
			var lbl := "%s (s%d..s%d)" % [sc, s_min, s_max]
			out.append(BotMetrics.aggregate(arr, lbl))
	var sc_order := BalanceScenarios.DUEL_IDS + BalanceScenarios.POCKET_IDS + BalanceScenarios.CITY_IDS + BalanceScenarios.COOP_IDS
	var prof_order := ["rookie", "average", "mixed", "veteran", "brawler"]
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var sa := str(a["scenario"]).split(" ")[0]
		var sb := str(b["scenario"]).split(" ")[0]
		var ia := sc_order.find(sa)
		var ib := sc_order.find(sb)
		if ia != ib:
			return ia < ib
		return prof_order.find(str(a["profile"])) < prof_order.find(str(b["profile"])))
	return out


static func _arg(args: PackedStringArray, key: String, fallback: String) -> String:
	var i := args.find(key)
	if i >= 0 and i + 1 < args.size():
		return args[i + 1]
	return fallback


static func _parse_csv(args: PackedStringArray, key: String) -> Array[String]:
	var raw := _arg(args, key, "")
	var out: Array[String] = []
	if raw.strip_edges() == "":
		return out
	for tok: String in raw.split(","):
		var s := tok.strip_edges()
		if s != "":
			out.append(s)
	return out


static func _parse_seeds(raw: String) -> Array[int]:
	var out: Array[int] = []
	var s := raw.strip_edges()
	if s == "":
		return out
	if s.contains(".."):
		var p := s.split("..")
		if p.size() == 2 and p[0].is_valid_int() and p[1].is_valid_int():
			var a := int(p[0])
			var b := int(p[1])
			for i in range(a, b + 1):
				out.append(i)
			return out
	for tok: String in s.split(","):
		var t := tok.strip_edges()
		if t.is_valid_int():
			out.append(int(t))
	return out


static func _write_text(path: String, content: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(content)
		f.close()
