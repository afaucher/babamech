class_name MissionPortal
extends Node3D
## A charging frame in the extraction portal gate: SEGMENTS pairs of segments up both posts and along the lintel to its
## middle, the first `progress` of them lit, and an energy curtain across the opening: none below CURTAIN_FROM, then
## rising from the floor with a bright top edge, thin until 1.0, where it fills the opening and turns solid.

const SEGMENTS := 12
const CURTAIN_FROM := 0.15   ## progress below which there is no curtain
var half := 20.0
var gh := 14.0
var lit: Array[Node3D] = []
var curtain: MeshInstance3D
var curtain_mat: StandardMaterial3D
var edge: MeshInstance3D          ## the curtain's bright rising top edge

func build(d: CityDistrict, w: Dictionary, g: Dictionary) -> void:
	var layer := d.render_layer
	half = MissionProps.gate_half(g)
	gh = float(g["h"])
	transform = MissionProps.gate_frame(d, w, g)
	var off := CityGeo.new()
	var segs := _segments()
	for sg: Array in segs:
		off.box(sg[0], Vector3.ZERO, sg[1], MissionProps.c("m_portal_off"))
	add_child(MissionProps.mesh(off, "Frame", layer))
	for i in SEGMENTS:
		var n := Node3D.new()
		n.name = "Lit%d" % i
		var g2 := CityGeo.new()
		for sg: Array in [segs[i * 2], segs[i * 2 + 1]]:
			g2.box(sg[0], Vector3.ZERO, (sg[1] as Vector3) + Vector3(0.04, 0.04, 0.04), MissionProps.c("m_portal"))
		n.add_child(MissionProps.mesh(g2, "Mesh", layer, MissionProps.glow("m_portal", 4.0)))
		n.visible = false
		add_child(n)
		lit.append(n)
	var cg := CityGeo.new()           # one metre tall: pose() scales it up from the floor
	var x := half - 0.7
	cg.quad(Vector3(-x, 0.0, -0.6), Vector3(x, 0.0, -0.6), Vector3(x, 1.0, -0.6), Vector3(-x, 1.0, -0.6), MissionProps.c("m_portal"))
	curtain_mat = StandardMaterial3D.new()
	curtain_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	curtain_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	curtain_mat.albedo_color = MissionProps.c("m_portal")
	curtain_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	curtain = MissionProps.mesh(cg, "Curtain", layer, curtain_mat)
	curtain.visible = false
	add_child(curtain)
	var eg := CityGeo.new()
	eg.box(Transform3D.IDENTITY, Vector3(0, 0, -0.5), Vector3(x * 2.0, 0.3, 0.2), MissionProps.c("m_portal"))
	edge = MissionProps.mesh(eg, "Edge", layer, MissionProps.glow("m_portal", 5.0))
	edge.visible = false
	add_child(edge)

## [xf, size] of every segment, in pairs (left, right), bottom of the posts first, the lintel's middle last.
func _segments() -> Array:
	var out := []
	var post := gh - 0.6
	var top := half - 0.4
	var total := post + top
	var step := total / float(SEGMENTS)
	for i in SEGMENTS:
		var a := step * float(i) + 0.15
		var b := step * float(i + 1) - 0.15
		for k: float in [-1.0, 1.0]:
			if b <= post:
				out.append([Transform3D(Basis.IDENTITY, Vector3(k * (half - 0.35), 0.3 + (a + b) * 0.5, 1.0)), Vector3(0.7, b - a, 0.6)])
			elif a >= post:
				var u0 := half - 0.4 - (a - post)
				var u1 := half - 0.4 - (b - post)
				out.append([Transform3D(Basis.IDENTITY, Vector3(k * (u0 + u1) * 0.5, gh - 0.35, 1.0)), Vector3(absf(u0 - u1), 0.7, 0.6)])
			else:
				out.append([Transform3D(Basis.IDENTITY, Vector3(k * (half - 0.35), 0.3 + (a + post) * 0.5, 1.0)), Vector3(0.7, post - a, 0.6)])
	return out

func pose(progress: float) -> void:
	for i in lit.size():
		lit[i].visible = progress >= float(i + 1) / float(SEGMENTS) - 0.0001
	# The curtain: nothing below CURTAIN_FROM, then rising from the floor to the lintel as progress goes to 1, thin at
	# first and solid only at 1 (a bright edge on its top while it rises).
	var f := clampf((progress - CURTAIN_FROM) / (1.0 - CURTAIN_FROM), 0.0, 1.0)
	curtain.visible = f > 0.0
	edge.visible = f > 0.0 and f < 1.0
	var top := 0.1 + (gh - 0.5) * f
	curtain.scale = Vector3(1.0, maxf(top, 0.01), 1.0)
	edge.position.y = top
	var col := MissionProps.c("m_portal")
	col.a = 0.12 + 0.43 * f + (0.35 if f >= 1.0 else 0.0)
	curtain_mat.albedo_color = col

func world_point() -> Vector3:
	return global_transform * Vector3(0, gh * 0.5, 0) if is_inside_tree() else transform * Vector3(0, gh * 0.5, 0)
