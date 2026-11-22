class_name LayoutCheck
extends RefCounted
## Headless layout assertions (docs/testing.md). `--headless` has a dummy renderer, so nothing is drawn, but Controls
## still lay out against the root viewport (project size 1600x900): rects, visibility and clipping are all real. These
## helpers turn "the screen is empty / the panel collapsed / the button is off-screen" into failing checks.
##
##   var lc := LayoutCheck.new(self)          # self: a TestCase
##   lc.fills_screen(fe, "menu root")         # a full-screen Control really covers the viewport
##   lc.on_screen(fe.btn_play, "Play")        # visible in tree, non-zero, inside the viewport, not clipped away
##   lc.full_height(panel, "lab panel")       # a side panel spans the screen top to bottom
##   lc.all_controls_sane(fe, "menu")         # no visible Control has a NaN / negative size
## Each returns true when it holds and reports through the TestCase otherwise.

var t: TestCase
var tol := 1.0   ## pixels of slack


func _init(test: TestCase) -> void:
	t = test


## The viewport rect a Control lays out in (its canvas layer's viewport).
func screen(c: Control) -> Rect2:
	return c.get_viewport_rect()


## `c` covers the whole viewport.
func fills_screen(c: Control, what: String) -> bool:
	if not _alive(c, what):
		return false
	var s := screen(c)
	var r := c.get_global_rect()
	return t.check(r.position.distance_to(s.position) <= tol and r.size.distance_to(s.size) <= tol,
		"%s fills the %s screen (rect %s)" % [what, _v(s.size), r])


## `c` spans the viewport's full height (a left/right panel).
func full_height(c: Control, what: String) -> bool:
	if not _alive(c, what):
		return false
	var s := screen(c)
	var r := c.get_global_rect()
	return t.check(absf(r.position.y - s.position.y) <= tol and absf(r.size.y - s.size.y) <= tol,
		"%s spans the screen height %.0f (rect %s)" % [what, s.size.y, r])


## `c` is visible in the tree, has a real size, lies inside the viewport, and is not clipped away by a scrolling or
## clipping ancestor (at least `min_visible` of its area shows).
func on_screen(c: Control, what: String, min_size := Vector2(4, 4), min_visible := 0.5) -> bool:
	if not _alive(c, what):
		return false
	var r := c.get_global_rect()
	if not t.check(r.size.x >= min_size.x and r.size.y >= min_size.y, "%s has a real size (%s)" % [what, _v(r.size)]):
		return false
	var s := screen(c).grow(tol)
	if not t.check(s.encloses(r), "%s is inside the screen %s (rect %s)" % [what, _v(screen(c).size), r]):
		return false
	var shown := r
	var p := c.get_parent()
	while p is Control:
		var pc := p as Control
		if pc.clip_contents or pc is ScrollContainer:
			shown = shown.intersection(pc.get_global_rect())
		p = p.get_parent()
	var frac := shown.get_area() / maxf(r.get_area(), 1.0)
	return t.check(frac >= min_visible, "%s is not clipped away (%.0f%% shows)" % [what, frac * 100.0])


## `c` has at least this size (a panel that must not collapse to its margins).
func at_least(c: Control, min_size: Vector2, what: String) -> bool:
	if not _alive(c, what):
		return false
	var r := c.get_global_rect()
	return t.check(r.size.x + tol >= min_size.x and r.size.y + tol >= min_size.y,
		"%s is at least %s (is %s)" % [what, _v(min_size), _v(r.size)])


## Every visible Control under `root` has a finite, non-negative size.
func all_controls_sane(root: Node, what: String) -> bool:
	var bad: Array[String] = []
	for c in _controls(root):
		if not c.is_visible_in_tree():
			continue
		var sz := c.size
		if not (is_finite(sz.x) and is_finite(sz.y)) or sz.x < 0.0 or sz.y < 0.0:
			bad.append("%s %s" % [c.get_path(), sz])
	return t.check(bad.is_empty(), "%s: controls with broken sizes: %s" % [what, ", ".join(bad.slice(0, 5))])


## Every visible Button / BaseButton under `root` is on screen (scrolled-away ones fail: list those as `skip`).
func buttons_on_screen(root: Node, what: String, skip: Array = []) -> bool:
	var ok := true
	for c in _controls(root):
		if c is BaseButton and c.is_visible_in_tree() and not skip.has(c):
			var label := "%s button '%s'" % [what, (c as Button).text if c is Button else str(c.name)]
			ok = on_screen(c, label) and ok
	return ok


func _controls(root: Node) -> Array[Control]:
	var out: Array[Control] = []
	if root is Control:
		out.append(root)
	for ch in root.get_children():
		out.append_array(_controls(ch))
	return out


func _alive(c: Control, what: String) -> bool:
	if not t.check(c != null and is_instance_valid(c), "%s exists" % what):
		return false
	return t.check(c.is_visible_in_tree(), "%s is visible" % what)


func _v(v: Vector2) -> String:
	return "%.0fx%.0f" % [v.x, v.y]
