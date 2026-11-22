class_name MissileLaser
extends CombatEffect
## The guided missiles' laser line (weapons.md §3.6), cosmetic: a red 3-sided faceted line (9 cm, growing with distance) (Beam, no shell) from
## the launcher muzzle to the shooter's live aim point, ending in a small faceted red dot. One per shooter + hardpoint,
## not per missile: the first live Missile creates it (Missile._ensure_laser, named node_name(record) under the
## CombatWorld so the next missiles find it), and it finishes once no missile of that shooter + hardpoint is in flight.
## Shown only while the track is on (world.designators[shooter].on); drawn on every machine (everyone sees the line).
## The start is the live muzzle (CombatWorld.muzzle_of) when registered, else the newest missile's record origin.
## No heat (open design question, weapons.md §7).

## 9 cm wide at the launcher, growing to 30 cm at 150 m so it still reads from far away.
const LOOK := {"core": CombatMeshes.RED, "sides": 3, "w0": 0.09, "w1": 0.3, "w_full": 150.0, "core_share": 1.0,
	"has_shell": false, "flash": false}
const DOT_SIZE := 0.35           ## m: the dot's radius at the launcher...
const DOT_GROWTH := 0.003        ## ...plus this much per m of line (0.65 m at 100 m: clear, not hiding the target)

var shooter := ""
var hardpoint := ""
var origin := Vector3.ZERO        ## fallback start: the newest missile's record origin
var shown := false                ## the line is drawn this step (track on and a missile flying)
var _done := false
var _beam: Beam
var _dot: MeshInstance3D


func net_fields() -> Dictionary:
	var f := super.net_fields()
	f.merge({"shooter": Net.SPAWN, "hardpoint": Net.SPAWN, "origin": Net.LOCAL, "shown": Net.LOCAL, "_done": Net.LOCAL,
		"_beam": Net.LOCAL, "_dot": Net.LOCAL})
	return f


static func node_name(rec: Dictionary) -> String:
	return ("MissileLaser_%s_%s" % [rec.get("shooter", ""), rec.get("hardpoint", "")]).validate_node_name()


func setup(w: CombatWorld, rec: Dictionary) -> void:
	world = w
	shooter = str(rec.get("shooter", ""))
	hardpoint = str(rec.get("hardpoint", ""))
	record = {"shooter": shooter, "hardpoint": hardpoint}
	origin = rec.get("origin", Vector3.ZERO)
	t0 = w.now
	name = node_name(rec)
	top_level = true          # world-space points, wherever the CombatWorld sits
	_beam = Beam.new()
	_beam.look = LOOK
	add_child(_beam)
	_beam.setup_cosmetic(w, origin, origin + Vector3.FORWARD, -1.0)
	_dot = CombatMeshes.instance(CombatMeshes.ico(CombatMeshes.RED, true))
	add_child(_dot)
	_show(false)


func advance_to(_now: float) -> void:
	if _done:
		return
	var newest: Missile = null
	for e in world.effects:
		if e is Missile and (e as Missile).end_time < 0.0 and str(e.record.get("shooter", "")) == shooter \
				and str(e.record.get("hardpoint", "")) == hardpoint:
			if newest == null or e.t0 > newest.t0:
				newest = e
	if newest == null:
		_done = true
		_show(false)
		return
	origin = newest.origin
	var d: Dictionary = world.designators.get(shooter, {})
	var on := bool(d.get("on", false)) and d.get("dot") is Vector3
	_show(on)
	if not on:
		return
	var dot: Vector3 = d["dot"]
	var from := origin
	var m := world.muzzle_of(record)
	if m.is_valid():
		var p: Variant = m.call()
		if p is Vector3:
			from = p
	_beam.set_points(from, dot)
	_dot.transform = Transform3D(Basis.from_scale(Vector3.ONE * dot_radius(from.distance_to(dot))), dot)


## The dot's radius at the end of a line `length` m long.
static func dot_radius(length: float) -> float:
	return DOT_SIZE + DOT_GROWTH * length


func finished() -> bool:
	return _done


## The line's two ends while shown: [from, to].
func points() -> Array:
	return [_beam.a, _beam.b]


func _show(on: bool) -> void:
	shown = on
	_beam.visible = on
	_dot.visible = on
