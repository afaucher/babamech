class_name RoadForms
## The pieces of the road segment forms (docs/design/city-variety.md) that CityPlan (a district on its own) and SectionPlan
## (a mission section) share: the segment key, the lane width and the union-find their repairs use. The rolls and repairs
## themselves differ (rules, generators) and stay in each plan.

const LANE_W := 8.0              ## a lane's carriageway (SectionPlan.FORM_WIDTH["lane"])


## Key of a segment within its deck: axis bit * 65536 + line * 256 + index (axis "s" = along the arc, "x" = across).
static func seg_key(axis: String, line: int, index: int) -> int:
	return (65536 if axis == "x" else 0) + line * 256 + index


## Union-find root of node a (path halving).
static func uf_find(parent: PackedInt32Array, a: int) -> int:
	while parent[a] != a:
		parent[a] = parent[parent[a]]
		a = parent[a]
	return a


## Joins the sets of a and b; the lower root wins.
static func uf_join(parent: PackedInt32Array, a: int, b: int) -> void:
	var ra := uf_find(parent, a)
	var rb := uf_find(parent, b)
	if ra != rb:
		parent[maxi(ra, rb)] = mini(ra, rb)
