extends SceneTree
## Paper numbers for the Bulwark effectiveness options (docs/design/bulwark-effectiveness.md, Part 2): today, A (belly
## turret prototype, read from the catalog), B (back saddles take shoulder weapons), C (heat 160 / +4 cooling; braced
## +25 % fire rate). Headless, prints a markdown table:
##   <godot> --path . --headless --script res://tools/balance/chassis_options_paper.gd
const Paper := preload("res://tools/balance/chassis_paper.gd")
func _row(label: String, cid: String, l: Dictionary, o: Dictionary) -> void:
	var r := Paper.evaluate(cid, l, o)
	var r80 := Paper.evaluate(cid, l, _w(o, {"range_m": 80.0}))
	print("| %s | %s | %.0f | %.0f | %.1f | %.1f | %.1f | %.0f |" % [label, str(l.values()), r["weight"], r["burst5"], r["dps30"], r["dps120"], r80["dps120"], r["ammo_total"]])
func _w(a: Dictionary, b: Dictionary) -> Dictionary:
	var o := a.duplicate(); o.merge(b, true); return o
func _best(label: String, cid: String, o: Dictionary, need_mortar: bool) -> void:
	var o80 := _w(o, {"range_m": 80.0})
	var best := {}; var bs := -1.0
	for l: Dictionary in Paper.legal_loadouts(cid, o80):
		if need_mortar and not l.values().has("mortar"): continue
		var s := float(Paper.evaluate(cid, l, o80)["dmg30"])
		if s > bs: bs = s; best = l
	_row(label, cid, best, o)
func _init() -> void:
	var nb := {"skip_hardpoints": ["belly"]}
	var b_back := {"skip_hardpoints": ["belly", "back_l", "back_r"], "extra_hardpoints": [
		{"id": "back_l", "mount": "back", "mounts": ["back", "shoulder"]}, {"id": "back_r", "mount": "back", "mounts": ["back", "shoulder"]}]}
	var c_heat := _w(nb, {"heat_cap_mult": 160.0 / 130.0, "cooling_add": 4.0})
	var c_brace := _w(nb, {"fire_rate_mult": 1.25})
	var dflt := {"side_l": "autocannon", "side_r": "rockets", "back_l": "mortar", "back_r": "radiator"}
	print("| option | loadout | wt | burst5 | dps30 | dps120 | dps120@80 | ammo dmg |")
	_row("strider default", "strider", MechCatalog.sanitize_loadout("strider", {}), {})
	_best("strider best (mortar)", "strider", {}, true)
	_row("bulwark today default", "bulwark", dflt, nb)
	_best("bulwark today best (mortar)", "bulwark", nb, true)
	_row("A belly default (+gatling)", "bulwark", _w(dflt, {"belly": "gatling"}), {})
	_best("A belly best (mortar)", "bulwark", {}, true)
	_row("B back shoulder: AC/rockets/mortar/rockets", "bulwark", {"side_l": "autocannon", "side_r": "rockets", "back_l": "mortar", "back_r": "rockets"}, b_back)
	_best("B back shoulder best (mortar)", "bulwark", b_back, true)
	_row("C heat 160/16 default", "bulwark", dflt, c_heat)
	_best("C heat best (mortar)", "bulwark", c_heat, true)
	_row("C braced +25% rate default", "bulwark", dflt, c_brace)
	_best("C braced best (mortar)", "bulwark", c_brace, true)
	_row("A+C heat default", "bulwark", _w(dflt, {"belly": "gatling"}), {"heat_cap_mult": 160.0 / 130.0, "cooling_add": 4.0})
	quit()
