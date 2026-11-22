class_name ShotCheck
extends RefCounted
## Screenshot assertions for VISUAL tests (docs/testing.md): tests that declare `const VISUAL := true` and run only under
## `.\test_runner.ps1 -Visual`, in a real renderer with the window placed off screen. Headless runs have no pixels, so
## every helper here passes with a note when `available()` is false.
##
##   var sc := ShotCheck.new(self)
##   var img := await sc.grab("menu_main")             # saves test_logs/shots/menu_main.png
##   sc.not_blank(img, Rect2(0, 0, 1, 1), "menu")      # a region (fractions of the image) shows real detail
##   sc.differs(img, Rect2(0,0,.3,1), Rect2(.4,0,.6,1), "panel vs preview")

const SHOT_DIR := "res://test_logs/shots"

var t: TestCase


func _init(test: TestCase) -> void:
	t = test


## True when the display really renders (not --headless).
static func available() -> bool:
	return DisplayServer.get_name() != "headless"


## The current frame of the root viewport (after it is drawn), saved as test_logs/shots/<shot_name>.png.
func grab(shot_name: String) -> Image:
	if not available():
		return null
	await RenderingServer.frame_post_draw
	var img := t.get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	var path := ProjectSettings.globalize_path("%s/%s.png" % [SHOT_DIR, shot_name])
	img.save_png(path)
	print("shot %s" % path)
	return img


## Luminance mean / standard deviation and the number of distinct (coarsely quantized) colours in `frac` (a rect in
## 0..1 fractions of the image), sampled on a 64x64 grid.
static func stats(img: Image, frac: Rect2) -> Dictionary:
	var w := img.get_width()
	var h := img.get_height()
	var r := Rect2i(int(frac.position.x * w), int(frac.position.y * h), maxi(int(frac.size.x * w), 1), maxi(int(frac.size.y * h), 1))
	var sum := 0.0
	var sum2 := 0.0
	var n := 0
	var colours := {}
	for iy in 64:
		for ix in 64:
			var x := clampi(r.position.x + int((ix + 0.5) * r.size.x / 64.0), 0, w - 1)
			var y := clampi(r.position.y + int((iy + 0.5) * r.size.y / 64.0), 0, h - 1)
			var c := img.get_pixel(x, y)
			var l := c.get_luminance()
			sum += l
			sum2 += l * l
			n += 1
			colours[(int(c.r * 15) << 8) | (int(c.g * 15) << 4) | int(c.b * 15)] = true
	var mean := sum / n
	return {"mean": mean, "std": sqrt(maxf(sum2 / n - mean * mean, 0.0)), "colours": colours.size()}


## The region shows real detail: not one flat colour. It needs at least `min_colours` distinct colours, and either a
## luminance spread of `min_std` or `rich_colours` distinct colours (a dark, low-contrast scene full of detail, like the
## hangar bay, has a small spread but many colours; an empty fill or a collapsed panel has 1-3).
func not_blank(img: Image, frac: Rect2, what: String, min_std := 0.02, min_colours := 4, rich_colours := 10) -> bool:
	if img == null:
		print("ShotCheck: no renderer (headless), skipped: ", what)
		return true
	var s := stats(img, frac)
	var n := int(s["colours"])
	return t.check(n >= min_colours and (float(s["std"]) >= min_std or n >= rich_colours),
		"%s is not blank (luminance std %.3f, %d colours)" % [what, s["std"], s["colours"]])


## Two regions look different (mean luminance or colour count), e.g. a UI panel against the 3D view beside it.
func differs(img: Image, a: Rect2, b: Rect2, what: String, min_delta := 0.02) -> bool:
	if img == null:
		return true
	var sa := stats(img, a)
	var sb := stats(img, b)
	return t.check(absf(float(sa["mean"]) - float(sb["mean"])) >= min_delta or absi(int(sa["colours"]) - int(sb["colours"])) >= 4,
		"%s: the regions differ (mean %.3f vs %.3f)" % [what, sa["mean"], sb["mean"]])
