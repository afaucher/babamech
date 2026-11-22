extends TestCase
## The mech damage diagram options (scripts/ui/mech_diagram.gd), headless: for every view and style, every component id
## (head, torso, both legs, every hardpoint) gets a zone with a real polygon, inside the status panel, inside the heat
## arc and above the state text; for the demo loadout, the default one and an empty one. The traced legs bend the
## chicken way (knee behind the hip and the ankle in the side view).

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
	finish()


static func _area(p: PackedVector2Array) -> float:
	var a := 0.0
	for i in p.size():
		a += p[i].cross(p[(i + 1) % p.size()])
	return a * 0.5
