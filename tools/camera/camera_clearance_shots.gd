extends Node3D
## Before / after shots of the chase camera's clearance fit (CameraClearance): a Strider carrying a missile pod on the
## right shoulder (rest of the default loadout) on flat ground with targets ahead, the crosshair at screen centre and the
## MARGIN circle (7 % of screen height) round it. Each view is shot twice: before_<view> at the default offsets, after_<view>
## with the fitted offset (the same grid ChaseCamera reads). The camera is CameraClearance.pose (ChaseCamera without wall
## collision); the weapons are turned toward the aim point like WeaponMount does. Run it on the hidden desktop:
##   . .\hidden_desktop.ps1; Invoke-HiddenDesktop -Exe (Resolve-BabamechGodot) -Arguments "--path . --resolution 1600x900 -- --scene res://tools/camera/camera_clearance_shots.tscn --out docs/design/camera-clearance"
## Views: level (pitch -0.18), up (0.45), down (-0.6), steep (-1.0, pitch_min), zoomed (-0.18, RMB), yaw45 (-0.18, the
## body lagging 45 deg left of the camera's yaw). Options: --views a,b  --loadout shoulder_r=missiles,side_r=flak
## --chassis bulwark. Cosmetic tool only; quits when done.

const VIEWS := {
	"level": [-0.18, 0.0, 0.0], "up": [0.45, 0.0, 0.0], "down": [-0.6, 0.0, 0.0], "steep": [-1.0, 0.0, 0.0],
	"zoomed": [-0.18, 0.0, 1.0], "yaw45": [-0.18, 45.0, 0.0],
}
const TARGET_DIST := 45.0   ## m from the eye along the view ray: a red target ball sits there (what the crosshair is on)

var _out := "res://docs/design/camera-clearance"
var _views: Array = VIEWS.keys()
var _chassis := "strider"
var _loadout := {"shoulder_r": "missiles"}
var _cam: Camera3D
var _mech: MechModel
var _target: MeshInstance3D
var _label: Label
var _cfg: Dictionary
var _fit: Dictionary


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if Boot.arg_value(args, "--out") != "":
		_out = Boot.arg_value(args, "--out")
	if Boot.arg_value(args, "--views") != "":
		_views = Array(Boot.arg_value(args, "--views").split(","))
	if Boot.arg_value(args, "--chassis") != "":
		_chassis = Boot.arg_value(args, "--chassis")
	if Boot.arg_value(args, "--loadout") != "":
		_loadout = {}
		for kv: String in Boot.arg_value(args, "--loadout").split(","):
			var p := kv.split("=")
			_loadout[p[0]] = p[1] if p.size() > 1 else ""
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.55, 0.62, 0.7)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.65, 0.72)
	e.ambient_light_energy = 0.6
	var env := WorldEnvironment.new()
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.5, 0.0)
	sun.shadow_enabled = true
	add_child(sun)
	add_child(MechParts.box(Vector3(600, 0.1, 600), Color(0.3, 0.32, 0.34), Vector3(0, -0.05, 0)))
	var line := Color(0.4, 0.42, 0.45)
	for i in range(-60, 61):   # a 4 m grid
		add_child(MechParts.box(Vector3(480, 0.012, 0.05), line, Vector3(0, 0.005, float(i) * 4.0)))
		add_child(MechParts.box(Vector3(0.05, 0.012, 480), line, Vector3(float(i) * 4.0, 0.005, 0)))
	# Targets ahead: blocks (buildings) and posts at 30-150 m.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7   # looks only
	for i in 24:
		var h := rng.randf_range(6.0, 30.0)
		var w := rng.randf_range(6.0, 16.0)
		var pos := Vector3(rng.randf_range(-90.0, 90.0), h * 0.5, -rng.randf_range(40.0, 160.0))
		add_child(MechParts.box(Vector3(w, h, w), Color(0.5, 0.5, 0.48).lerp(Color(0.62, 0.55, 0.45), rng.randf()), pos))
	for i in 9:
		add_child(MechParts.box(Vector3(1.2, 10.0, 1.2), Color(0.85, 0.6, 0.15), Vector3(-24.0 + 6.0 * i, 5.0, -28.0)))
	_target = MechParts.sphere(1.1, Color(0.95, 0.12, 0.1), Vector3.ZERO, 16)
	add_child(_target)
	var lo := MechCatalog.sanitize_loadout(_chassis, {})
	lo.merge(_loadout, true)
	_mech = MechModel.new()
	_mech.configure("chicken", _chassis, lo)
	_mech.time_scale = 0.0
	var rig := MechRig.new()
	_mech.scale = Vector3.ONE * rig.mech_scale
	rig.free()
	add_child(_mech)
	var cc := ChaseCamera.new()
	_cfg = CameraClearance.config_of(cc)
	cc.free()
	_cam = Camera3D.new()
	_cam.far = 3000.0
	add_child(_cam)
	_cam.make_current()
	var hud := CanvasLayer.new()
	add_child(hud)
	var cross := Crosshair.new()
	hud.add_child(cross)
	cross.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_label = Label.new()
	_label.position = Vector2(16, 12)
	_label.add_theme_font_size_override("font_size", 22)
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 6)
	hud.add_child(_label)
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out) if _out.begins_with("res://") else _out)
	await RenderingServer.frame_post_draw
	var sil := CameraClearance.capture(_mech, _mech.global_transform.orthonormalized())
	_fit = CameraClearance.fit(sil, _cfg)
	print("camera_clearance_shots: %s %s fit dir %s max %.2f solved %s" % [_chassis, str(_mech.loadout), str(_fit["dir"]), _fit["max"], _fit["solved"]])
	for v: String in _views:
		var s: Array = VIEWS[v]
		for phase: String in ["before", "after"]:
			var x := Vector2.ZERO if phase == "before" else CameraClearance.extra_at(_fit, s[0], s[1])
			var cam := CameraClearance.pose(_cfg, s[0], s[1], s[2], x)
			var c := CameraClearance.pose_clearance(sil, cam)
			_place(cam, s[1])
			_label.text = "%s  %s  pitch %.2f  yaw lag %+.0f  zoom %.0f   extra shoulder %.2f m  height %.2f m   items %.3f  hull %.3f of screen height" % [
				phase.to_upper(), v, s[0], s[1], s[2], x.x, x.y, c.y, c.x]
			for i in 4:
				await RenderingServer.frame_post_draw
			var path := _out.path_join("%s_%s.png" % [phase, v])
			var err := get_viewport().get_texture().get_image().save_png(path)
			print("shot %s %s  items %.3f hull %.3f extra %s" % [path, "ok" if err == OK else "error %d" % err, c.y, c.x, str(x)])
	get_tree().quit()


## Put the mech (body yawed `yaw_lag` deg left of the camera's look) and the camera (the pose, mech frame) in the world;
## turn the weapons toward the aim point; put the red ball on the view ray TARGET_DIST m out.
func _place(cam: Dictionary, yaw_lag: float) -> void:
	var a := deg_to_rad(yaw_lag)
	# In the mech frame the camera looks along (sin a, 0, -cos a); turn the mech so that is world -Z.
	var body := Basis(Vector3.UP, a)
	_mech.transform = Transform3D(body.scaled(Vector3.ONE * _mech.scale.x), Vector3.ZERO)
	_mech.scale = _mech.scale   # keep the scale explicit
	var frame := Transform3D(body, Vector3.ZERO)
	var view: Vector3 = frame.basis * (cam["view"] as Vector3)
	var eye: Vector3 = frame * (cam["o"] as Vector3)
	_cam.global_transform = Transform3D(Basis.looking_at(view, Vector3.UP), eye)
	_cam.fov = rad_to_deg(atan(float(cam["tan"])) * 2.0)
	_target.global_position = eye + view * TARGET_DIST
	var aim: Vector3 = frame * ((cam["pivot"] as Vector3) + (cam["view"] as Vector3) * CameraClearance.AIM_DIST)
	for hp: Dictionary in MechCatalog.chassis(_chassis)["hardpoints"]:
		var id := str(hp["id"])
		var w := str(_mech.loadout.get(id, ""))
		var st := MechCatalog.weapon(w)
		if w == "" or MechCatalog.is_equipment(w) or str(st.get("kind", "")) == "arc":
			continue
		var node := _mech.find_child("HP_" + id, true, false) as Node3D
		var d := body.inverse() * (aim - node.global_position).normalized()
		var yaw := clampf(rad_to_deg(atan2(d.x, -d.z)), -float(st.get("yaw_arc", Combat.PIVOT_YAW)), float(st.get("yaw_arc", Combat.PIVOT_YAW)))
		var pitch := clampf(rad_to_deg(asin(clampf(d.y, -1.0, 1.0))), -float(st.get("pitch_down", Combat.PIVOT_PITCH_DOWN)), float(st.get("pitch_up", Combat.PIVOT_PITCH_UP)))
		WeaponPose.apply(node, w, yaw, pitch)


## The crosshair (screen centre) and the clearance margin circle.
class Crosshair:
	extends Control

	func _draw() -> void:
		var c := size * 0.5
		var r := size.y * CameraClearance.MARGIN
		draw_arc(c, r, 0.0, TAU, 64, Color(1, 1, 1, 0.55), 2.0, true)
		for d: Vector2 in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
			draw_line(c + d * 6.0, c + d * 18.0, Color(0.1, 1.0, 0.3), 3.0, true)
		draw_circle(c, 2.5, Color(0.1, 1.0, 0.3))
