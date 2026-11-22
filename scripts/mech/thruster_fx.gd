class_name ThrusterFx
extends Node3D
## Low-poly thruster flames: two LowPolyFlame.Stream jets (the game's one flame look; the flamer drives the same stream)
## from jetpack nozzles just behind and below the hips, pointing down along local gravity and leaning back by TILT (and
## splayed a little outward), so they clear the legs and read from the chase camera. Each jet is a steady hot cone at the
## nozzle plus rigid tongues pouring out of it; an emergency burn reaches further.
## A child of the MechController; reads `thrusting` / `emergency` from it, poses itself off the rig's model.
##
## The nozzles hang off the hips AS POSED (MechModel.leg_points), not the standing hip_local: the rig moves the body
## (the pelvis dips toward the feet, and in the air the feet reach for the ground far below), so a standing-pose anchor
## left the flames metres above the visible body.
##
## Cosmetic (Net LOCAL): every machine shows it from the mech's synced thrust state.

const TILT := 0.45                 ## radians the jets lean back from straight down
const SPLAY := 0.12                ## radians each jet leans outward, so the pair reads as two from behind
## Nozzle offset from the posed hip, model units (times mech_scale): x outward, under the torso (y), behind the pelvis (z).
const NOZZLE := Vector3(0.15, -0.1, 0.8)
const LENGTH := 3.4                ## stream reach at full thrust, m per unit of mech_scale
const WIDTH := 1.0                 ## tongue peak width, m per unit of mech_scale
const SPEED := 10.0                ## tongue speed, m/s per unit of mech_scale

var level := 0.0                   ## 0..1, eased toward the thrust state (holds through the hover bot's short gaps)
var _jets: Array[Node3D] = []
var _streams: Array = []           ## LowPolyFlame.Stream per jet
var _body: MechController


func _ready() -> void:
	_body = get_parent() as MechController
	for side: float in [-1.0, 1.0]:
		var j := Node3D.new()
		j.name = "Jet_%s" % ("l" if side < 0.0 else "r")
		var st := LowPolyFlame.Stream.new()
		st.name = "Stream"
		st.count = 9
		st.spread = 0.06
		st.tumble = 0.25
		st.root = 0.55
		st.jitter_seed = 11 if side < 0.0 else 23
		j.add_child(st)
		add_child(j)
		_jets.append(j)
		_streams.append(st)
		j.set_meta("side", side)
		j.visible = false


## Jet `side` (-1 left, +1 right): its origin is the nozzle, its -Y the flame direction (unscaled basis).
func jet(side: float) -> Node3D:
	return _jets[0 if side < 0.0 else 1]


## The flame stream of jet `side`.
func stream(side: float) -> LowPolyFlame.Stream:
	return _streams[0 if side < 0.0 else 1]


## Where nozzle `side` sits, in the global frame: behind and below that hip as the rig last posed it.
func nozzle(side: float) -> Vector3:
	var rig := _body.get_node_or_null("Rig") as MechRig if _body != null else null
	if rig == null or rig.model == null:
		return global_position
	var model := rig.model
	var pts := model.leg_points(0 if side < 0.0 else 1)
	var hip: Vector3 = pts["hip"] if pts.has("hip") else model.hip_local(side)
	return model.to_global(hip + Vector3(side * NOZZLE.x, NOZZLE.y, NOZZLE.z))


func _process(delta: float) -> void:
	if _body == null:
		return
	var want := 1.0 if _body.thrusting else 0.0
	level = move_toward(level, want, delta * (8.0 if want > level else 4.0))
	var rig := _body.get_node_or_null("Rig") as MechRig
	var s := rig.mech_scale if rig != null else 2.0
	for k in _jets.size():
		var j := _jets[k]
		var st: LowPolyFlame.Stream = _streams[k]
		var side := float(j.get_meta("side"))
		# The stream spawns tongues while the level is up, so a brief gap in the thrust doesn't punch holes in it.
		st.emitting = level > 0.3
		st.length = s * LENGTH * (0.6 + 0.4 * level) * (1.25 if _body.emergency else 1.0)
		st.width = s * WIDTH
		st.speed = s * SPEED * (1.25 if _body.emergency else 1.0)
		j.visible = st.emitting or st.active()
		if not j.visible:
			continue
		# The stream flies along -Y. In the mech's frame (+Y up, -Z forward): lean the jet outward about +Z (back),
		# then back about +X: rotating -Y by -TILT about X gives (0, -cos, +sin), i.e. down and toward +Z, behind.
		var b := _body.global_basis.orthonormalized() * Basis(Vector3.BACK, side * SPLAY) * Basis(Vector3.RIGHT, -TILT)
		j.global_transform = Transform3D(b, nozzle(side))
