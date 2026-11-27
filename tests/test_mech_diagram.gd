extends TestCase
## The mech damage diagram options (scripts/ui/hangar/mech_diagram.gd), headless: for every view and style, every component id
## (head, torso, both legs, every hardpoint) gets a zone with a real polygon, inside the status panel, inside the heat
## arc and above the state text; for the demo loadout, the default one and an empty one. The traced legs bend the
## chicken way (knee behind the hip and the ankle in the side view). MechHud draws pick 3 (front / schematic) with
## zones for the actual loadout and pilot head: in demo, and bound to a mech through for_drive.


class FakeDrive extends Node:
	var mech: MechController
	var cam: Camera3D
	var combat: Node

const LOADOUTS := [
	{"side_l": "laser", "side_r": "autocannon", "shoulder_l": "rockets", "shoulder_r": "missiles", "back": "mortar"},
	{},
	{"side_l": "", "side_r": "", "shoulder_l": "", "shoulder_r": "", "back": ""},
]


func setup() -> void:
	var panel := MechHud.STATUS_SIZE
	var rect := Rect2(Vector2.ZERO, panel)
	var ar := MechDiagram.area(panel)
	check(ar.end.y <= panel.y - 50.0 - 13.0, "diagram area ends above the state text")
	for loadout: Dictionary in LOADOUTS:
		for v: String in MechDiagram.VIEWS:
			for s: String in MechDiagram.STYLES:
				var z := MechDiagram.zones(v, s, loadout, panel)
				var tag := "%s/%s %s" % [v, s, str(loadout)]
				for id: String in MechDiagram.component_ids(loadout):
					if not check(z.has(id) and not (z[id] as Array).is_empty(), "%s: zone for %s" % [tag, id]):
						continue
					var ok_poly := false
					var inside := true
					var above := true
					for p: PackedVector2Array in z[id]:
						if p.size() >= 3 and absf(_area(p)) > 1.0:
							ok_poly = true
						for q in p:
							inside = inside and rect.grow(-1.0).has_point(q)
							above = above and q.y <= ar.end.y + 0.5
					check(ok_poly, "%s: %s has a non-empty polygon" % [tag, id])
					check(inside, "%s: %s inside the panel" % [tag, id])
					check(above, "%s: %s above the state text" % [tag, id])
	# Chicken legs: in the side view (nose to the right) the knee sits behind (left of) both hip and ankle.
	var g := MechDiagram.geometry("side", {})
	var pts := {}
	for j: Dictionary in g["joints"]:
		pts["%s_%s" % [j["id"], j["kind"]]] = j["pos"]
	for leg: String in ["leg_l", "leg_r"]:
		var knee: Vector2 = pts[leg + "_knee"]
		var ankle: Vector2 = pts[leg + "_ankle"]
		check(knee.x < ankle.x, "%s: the knee points back (behind the ankle)" % leg)
	var nose_x := -INF
	var head_x := 0.0
	for c: Dictionary in g["comps"]:
		if c["id"] == "head":
			head_x = MechDiagram._bounds(c["union"]).get_center().x
	for c: Dictionary in g["comps"]:
		if c["id"] == "torso":
			nose_x = MechDiagram._bounds(c["union"]).get_center().x
	check(head_x > nose_x, "side view: the head sits forward of the hull's centre")
	await _hud_demo()
	await _hud_drive()
	finish()


func _hud_demo() -> void:
	var hud := MechHud.new()
	hud.demo = true
	add_child(hud)
	await frames(2)
	var d := hud.status_diagram
	check(d != null and d.get_parent() == hud.status_panel, "the HUD's status panel holds a MechDiagram")
	eq(d.view, "front", "HUD diagram view")
	eq(d.style, "schematic", "HUD diagram style")
	var want := {}
	for s: Dictionary in MechHud.DEMO_SLOTS:
		want[str(s["hardpoint"])] = str(s["weapon"])
	eq(d.mounted, want, "demo: the diagram shows the demo loadout")
	eq(int(d.slot_of["back"]), 5, "demo: the back badge is slot 5 like its weapon row")
	near(float(d.health["leg_l"]), 0.45, 0.001, "demo: component health reaches the diagram")
	_zones_ok(d, hud.status_panel.size, "demo")
	hud.queue_free()
	await frames(1)


func _hud_drive() -> void:
	var loadout := {"side_l": "gatling", "side_r": "", "shoulder_l": "railgun", "shoulder_r": "", "back": "mortar"}
	var td := FakeDrive.new()
	add_child(td)
	var m := MechSpawn.make("pickle", "strider", loadout)
	td.add_child(m)
	td.mech = m
	var hud := MechHud.for_drive(td)
	add_child(hud)
	await frames(3)
	var d := hud.status_diagram
	eq(d.view + "/" + d.style, "front/schematic", "for_drive: front / schematic")
	eq(d.head, "pickle", "for_drive: the bound mech's pilot head")
	eq(str(d.mounted.get("shoulder_l", "")), "railgun", "for_drive: the bound mech's loadout")
	eq(str(d.mounted.get("side_r", "x")), "", "for_drive: an empty hardpoint stays empty")
	_zones_ok(d, hud.status_panel.size, "drive")
	hud.queue_free()
	td.queue_free()
	await frames(1)


func _zones_ok(d: MechDiagram, panel: Vector2, tag: String) -> void:
	check(panel.x > 0.0 and panel.y > 0.0, "%s: status panel has a size" % tag)
	var z := MechDiagram.zones(d.view, d.style, d.mounted, panel, d.head)
	for id: String in MechDiagram.component_ids(d.mounted):
		check(z.has(id) and not (z[id] as Array).is_empty(), "%s: HUD zone for %s" % [tag, id])


static func _area(p: PackedVector2Array) -> float:
	var a := 0.0
	for i in p.size():
		a += p[i].cross(p[(i + 1) % p.size()])
	return a * 0.5
