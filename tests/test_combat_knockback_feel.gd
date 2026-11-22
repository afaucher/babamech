extends TestCase
## Knockback that is felt (weapons.md §2, §3): each weapon's real catalog numbers, fired by a WeaponMount from a muzzle
## 25 m from a TargetDummy on open flat ground (no walls; the aim point follows the dummy's chest, as in the
## weapon_range lab), run until the dummy comes to rest. Outcomes asserted:
##   gatling, 2 s stream (trigger held spin-up + 2 s): light slides >= 6 m and is staggered within 1 s of the first
##     round; mech >= 2 m
##   laser, one pulse: light >= 3 m and staggered; mech >= 1 m
##   autocannon, one shell: light >= 0.6 m; a 2 s burst moves mech >= 1.5 m
##   rockets, a full salvo: light < 2 m
##   every weapon: heavy moves less than mech; static doesn't move.

const DT := 1.0 / 60.0
const DIST := 25.0
const FROM := Vector3(0, 1.9, 0)


func setup() -> void:
	var gat_hold := float(MechCatalog.weapon("gatling")["spin_up"]) + 2.0
	var res := {}
	for w: String in ["gatling", "laser", "autocannon", "autocannon_burst", "rockets"]:
		res[w] = {}
		for m: String in Combat.MASS_ORDER:
			match w:
				"gatling": res[w][m] = await _run("gatling", m, gat_hold, -1)
				"laser": res[w][m] = await _run("laser", m, 2.0, 1)
				"autocannon": res[w][m] = await _run("autocannon", m, 2.0, 1)
				"autocannon_burst": res[w][m] = await _run("autocannon", m, 2.0, -1)
				"rockets": res[w][m] = await _run("rockets", m, 0.1, -1)
			var r: Dictionary = res[w][m]
			print("knockback %-16s %-6s slid %6.2f m  hits %2d  stagger %s" % [w, m, r["slid"], r["hits"],
				"-" if r["stagger"] < 0.0 else "%.2f s" % r["stagger"]])
	var g: Dictionary = res["gatling"]
	check(g["light"]["slid"] >= 6.0, "gatling 2 s stream slides a light dummy >= 6 m (%.2f)" % g["light"]["slid"])
	check(g["mech"]["slid"] >= 2.0, "gatling 2 s stream slides a mech-class dummy >= 2 m (%.2f)" % g["mech"]["slid"])
	check(g["light"]["stagger"] >= 0.0 and g["light"]["stagger"] <= 1.0, "gatling staggers a light dummy within 1 s (%.2f)" % g["light"]["stagger"])
	var l: Dictionary = res["laser"]
	check(l["light"]["slid"] >= 3.0, "one laser pulse slides a light dummy >= 3 m (%.2f)" % l["light"]["slid"])
	check(l["light"]["stagger"] >= 0.0, "one laser pulse staggers a light dummy")
	check(l["mech"]["slid"] >= 1.0, "one laser pulse slides a mech-class dummy >= 1 m (%.2f)" % l["mech"]["slid"])
	var a: Dictionary = res["autocannon"]
	check(a["light"]["hits"] == 1 and a["light"]["slid"] >= 0.6, "one autocannon shell slides a light dummy >= 0.6 m (%.2f)" % a["light"]["slid"])
	var ab: Dictionary = res["autocannon_burst"]
	check(ab["mech"]["slid"] >= 1.5, "a 2 s autocannon burst slides a mech-class dummy >= 1.5 m (%.2f)" % ab["mech"]["slid"])
	var rk: Dictionary = res["rockets"]
	check(rk["light"]["hits"] >= 3, "the salvo lands on the dummy (%d direct / splash hits)" % rk["light"]["hits"])
	check(rk["light"]["slid"] < 2.0, "a full rocket salvo moves a light dummy < 2 m (%.2f)" % rk["light"]["slid"])
	for w: String in res:
		var r: Dictionary = res[w]
		if r["mech"]["slid"] > 0.05:
			check(r["heavy"]["slid"] < r["mech"]["slid"] * 0.8, "%s: heavy moves visibly less than mech (%.2f vs %.2f)" % [w, r["heavy"]["slid"], r["mech"]["slid"]])
		check(r["static"]["slid"] < 1e-4, "%s: a static target doesn't move" % w)
	finish()


## Fire `weapon` at a `mass` dummy 25 m out: trigger held `hold` s, or until `shots` fire records left (-1 = no limit).
## Then run until shots are gone and the dummy rests. {slid (m), hits, stagger (s from the first hit, -1 = none)}.
func _run(weapon: String, mass: String, hold: float, shots: int) -> Dictionary:
	var w := CombatWorld.new()
	w.mission_seed = 5
	w.use_physics = false
	add_child(w)
	var d := TargetDummy.new()
	d.target_id = "d"
	d.mass_class = mass
	d.position = Vector3(0, 0, -DIST)
	add_child(d)
	w.register(d)
	await frames(1)
	var home := d.global_position
	var m := WeaponMount.new()
	m.setup(weapon, "side_r", "me", 1, w.stats(weapon))
	var out := {"slid": 0.0, "hits": 0, "stagger": -1.0}
	var first := [-1.0]
	w.hit_landed.connect(func(_t: CombatTarget, _h: Hit) -> void:
		out["hits"] += 1
		if first[0] < 0.0:
			first[0] = w.now)
	var stag := [-1.0]
	d.staggered_by.connect(func(_s: String) -> void:
		if stag[0] < 0.0:
			stag[0] = w.now)
	var fired := 0
	var t := 0.0
	var guard := 0
	while guard < 1200:
		guard += 1
		var trig := t < hold and (shots < 0 or fired < shots)
		for r in m.update(DT, trig, null, w.now, FROM, d.global_position + Vector3(0, 1.9, 0)):
			w.fire(r)
			fired += 1
		w.advance(DT)
		t += DT
		if t >= hold and m.salvo_left <= 0 and w.live_shots() == 0 and not d.knock.moving() and t > 0.5:
			break
	out["slid"] = d.global_position.distance_to(home)
	if stag[0] >= 0.0:
		out["stagger"] = stag[0] - first[0]
	d.free()
	w.free()
	await frames(1)
	return out
