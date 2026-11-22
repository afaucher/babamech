class_name CrewPanel
extends Control
## The HUD crew panel (docs/design/hud.md "Crew panel"; pick 9 of docs/design/hud/grid_hud_crew_r1.png, "corner / both"):
## one card per TEAMMATE (never yourself, up to 3), stacked straight above the player's own status panel in the
## bottom-left corner, so the corner reads as one column of crew status. Same holo style as MechHud.
## Each card: the teammate's low-poly pilot head in a hexagon (rendered once per head id in a small SubViewport), a tiny
## Steam avatar badge on its corner (hidden without an avatar: ENet, offline), the name, a health bar, a thin heat bar,
## the status (healthy / overheated / disabled with a revive countdown ring) and an accent stripe matching the mech.
##
## Data, read-only:
##   roster   Session.crew() minus Session.local_id(); rebuilt on Session.roster_changed.
##   status   `status_source: Callable`, (peer: int) -> {hp: 0..1, heat: 0..1, state: "ok" | "overheat" | "disabled",
##            revive_t: seconds left to revive, revive_max: the full window (REVIVE_WINDOW)}. Missing keys take the
##            defaults (full hp, no heat, ok). Unset = everyone healthy, until mech sync / component HP wire it.
##   avatar   SteamAvatar.request(steam_id) (scripts/net/): null without Steam.
## `demo` shows three fixed teammates (layout tests, screenshots). Cosmetic: no gameplay state, nothing synced.

const CARD_W := 300.0             ## = MechHud.STATUS_SIZE.x: one column with the status panel
const CARD_H := 80.0
const CARD_MIN_H := 52.0          ## the cards shrink toward this when the screen is short
const CARD_GAP := 6.0
const HEADER_H := 18.0
const TOP_RESERVE := 64.0         ## kept clear at the top of the screen (the help line)
const MAX_CARDS := 3
const REVIVE_WINDOW := 20.0
const PORTRAIT_PX := 96
const BADGE := 20.0
const DEFAULT_STATUS := {"hp": 1.0, "heat": 0.0, "state": "ok", "revive_t": 0.0, "revive_max": REVIVE_WINDOW}


## One teammate's card (drawn by the panel; `badge` is the Steam avatar).
class Card extends Control:
	var peer := 0
	var entry: Dictionary = {}
	var portrait: Texture2D
	var badge: TextureRect
	var status: Dictionary = {}

	## What the card shows for its current status (the drawing follows this; tests read it):
	## {label, dimmed (portrait greyed), revive_ring (countdown), warning (amber glyph), heat_amber, revive_left}.
	func look() -> Dictionary:
		var state := str(status.get("state", "ok"))
		var down := state == "disabled"
		var hot := state == "overheat"
		return {"label": "NEEDS REVIVE" if down else ("OVERHEATED" if hot else "HEALTHY"), "dimmed": down,
			"revive_ring": down, "warning": hot, "heat_amber": hot or float(status.get("heat", 0.0)) >= 0.85,
			"revive_left": maxf(float(status.get("revive_t", 0.0)), 0.0) if down else 0.0}


var status_source: Callable       ## (peer: int) -> {hp, heat, state, revive_t, revive_max}
var demo := false:
	set(v):
		if demo != v:
			demo = v
			if is_inside_tree():
				refresh()
var bottom_gap := 24.0 + 260.0 + 8.0   ## screen bottom -> panel bottom (MechHud sets it from its status panel)

var cards: Array[Card] = []
var _key := ""
var _portraits := {}              ## head id -> SubViewport
var _font: Font
var _view := Vector2.ZERO


func _init() -> void:
	name = "CrewPanel"
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	_font = ThemeDB.fallback_font
	var s := _session()
	if s != null and s.has_signal("roster_changed"):
		s.connect("roster_changed", refresh)
	refresh()


func _exit_tree() -> void:
	var s := _session()
	if s != null and s.has_signal("roster_changed") and s.is_connected("roster_changed", refresh):
		s.disconnect("roster_changed", refresh)


func _process(_delta: float) -> void:
	var vs := get_viewport_rect().size
	if vs != _view:
		_layout()
	for c in cards:
		c.status = status(c.peer)
		c.queue_redraw()
	queue_redraw()


# --- Data -----------------------------------------------------------------------------------------------------------

## The teammates shown, sorted by seat: roster entries other than our own (demo: DEMO_CREW). At most MAX_CARDS.
func teammates() -> Array:
	if demo:
		return DEMO_CREW
	var out: Array = []
	var s := _session()
	if s == null:
		return out
	var me := int(s.call("local_id"))
	for e: Dictionary in s.call("crew"):
		if int(e.get("peer", 0)) != me:
			out.append(e)
	return out.slice(0, MAX_CARDS)


## A teammate's status with every key filled (see the header).
func status(peer: int) -> Dictionary:
	var out := DEFAULT_STATUS.duplicate()
	var src: Variant = null
	if status_source.is_valid():
		src = status_source.call(peer)
	elif demo:
		src = DEMO_STATUS.get(peer, {})
	if src is Dictionary:
		out.merge(src, true)
	out["hp"] = clampf(float(out["hp"]), 0.0, 1.0)
	out["heat"] = clampf(float(out["heat"]), 0.0, 1.0)
	out["state"] = str(out["state"])
	return out


## Rebuild the cards when the teammates changed (roster_changed, demo toggled); cheap when nothing did.
func refresh() -> void:
	var mates := teammates()
	var key := ""
	for e: Dictionary in mates:
		key += "%d|%s|%s|%s|%d;" % [int(e.get("peer", 0)), e.get("name", ""), e.get("head", ""), e.get("accent", ""),
			int(e.get("steam_id", 0))]
	if key == _key and cards.size() == mates.size():
		visible = not cards.is_empty()
		return
	_key = key
	for c in cards:
		c.queue_free()
	cards.clear()
	for e: Dictionary in mates:
		cards.append(_make_card(e))
	visible = not cards.is_empty()
	_layout()


func _make_card(e: Dictionary) -> Card:
	var c := Card.new()
	c.peer = int(e.get("peer", 0))
	c.entry = e
	c.name = "Crew%d" % c.peer
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.status = status(c.peer)
	c.portrait = portrait(str(e.get("head", "")))
	c.draw.connect(_draw_card.bind(c))
	add_child(c)
	c.badge = TextureRect.new()
	c.badge.name = "Avatar"
	c.badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.badge.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	c.badge.stretch_mode = TextureRect.STRETCH_SCALE
	c.add_child(c.badge)
	var ref: WeakRef = weakref(c)
	var tex := SteamAvatar.request(int(e.get("steam_id", 0)), func(_sid: int, t: Texture2D) -> void:
		var card := ref.get_ref() as Card
		if card != null:
			card.badge.texture = t
			card.badge.visible = true)
	c.badge.texture = tex
	c.badge.visible = tex != null
	return c


## The pilot head for `head` id rendered once into a small transparent SubViewport (cached per head id).
func portrait(head: String) -> Texture2D:
	var id := head if PilotHead.REGISTRY.has(head) else PilotHead.FALLBACK
	if _portraits.has(id):
		return (_portraits[id] as SubViewport).get_texture()
	var vp := SubViewport.new()
	vp.name = "Portrait_" + id
	vp.size = Vector2i(PORTRAIT_PX, PORTRAIT_PX)
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_CLEAR_COLOR
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.75, 0.85, 0.95)
	env.environment.ambient_light_energy = 0.55
	vp.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.25
	vp.add_child(sun)
	sun.rotation_degrees = Vector3(-35.0, 155.0, 0.0)
	var rim := DirectionalLight3D.new()
	rim.light_energy = 0.5
	rim.light_color = Color(0.5, 0.9, 1.0)
	vp.add_child(rim)
	rim.rotation_degrees = Vector3(-10.0, -30.0, 0.0)
	var h := PilotHead.make(id, 0)
	h.set_process(false)
	vp.add_child(h)
	h.rotation_degrees = Vector3(0.0, -22.0, 0.0)
	var cam := Camera3D.new()
	cam.fov = 30.0
	vp.add_child(cam)
	cam.transform = Transform3D(Basis(), Vector3(0.0, 0.72, -2.85)).looking_at(Vector3(0.0, 0.6, 0.0))
	add_child(vp)
	# Render a few frames (the head settles, the MSAA target fills), then stop: a portrait is a still.
	get_tree().create_timer(0.25).timeout.connect(func() -> void:
		if is_instance_valid(vp):
			vp.render_target_update_mode = SubViewport.UPDATE_DISABLED)
	_portraits[id] = vp
	return vp.get_texture()


func _session() -> Node:
	return get_node_or_null("/root/Session") if is_inside_tree() else null


# --- Layout ---------------------------------------------------------------------------------------------------------

## The cards' height: CARD_H, shrunk (down to CARD_MIN_H) so every card fits between TOP_RESERVE and the status panel.
func card_height() -> float:
	var n := maxi(cards.size(), 1)
	var avail := get_viewport_rect().size.y - bottom_gap - TOP_RESERVE - HEADER_H - CARD_GAP * float(n - 1)
	return clampf(floorf(avail / float(n)), CARD_MIN_H, CARD_H)


func _layout() -> void:
	if not is_inside_tree():
		return
	_view = get_viewport_rect().size
	var ch := card_height()
	var n := cards.size()
	var h := HEADER_H + n * ch + maxf(n - 1, 0) * CARD_GAP
	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	offset_left = MechHud.MARGIN
	offset_right = MechHud.MARGIN + CARD_W
	offset_bottom = -bottom_gap
	offset_top = -bottom_gap - h
	for i in n:
		var c := cards[i]
		c.position = Vector2(0.0, HEADER_H + i * (ch + CARD_GAP))
		c.size = Vector2(CARD_W, ch)
		var hx := _hex_geom(c.size)
		var centre: Vector2 = hx[0]
		var r: float = hx[1]
		c.badge.size = Vector2(BADGE, BADGE)
		c.badge.position = centre + Vector2(r * 0.866 - BADGE * 0.55, r * 0.5 - BADGE * 0.35)


## [centre, radius] of the portrait hexagon in a card of size `sz`.
static func _hex_geom(sz: Vector2) -> Array:
	var r := (sz.y - 12.0) * 0.5
	return [Vector2(12.0 + r * 0.866, sz.y * 0.5), r]


static func _hex(centre: Vector2, r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for k in 6:
		var a := deg_to_rad(-90.0 + 60.0 * k)
		pts.append(centre + Vector2(cos(a), sin(a)) * r)
	return pts


# --- Drawing --------------------------------------------------------------------------------------------------------

func _draw() -> void:
	if cards.is_empty():
		return
	# The header sits on its own dark glass tab, like the cards: world markers and bright scenery behind it (3D aim rings
	# on the street, the sky) must not wash the label out.
	draw_rect(Rect2(0, 0, 44, HEADER_H - 2.0), Color(MechHud.GLASS, 0.85), true)
	draw_rect(Rect2(0, 0, 44, HEADER_H - 2.0), Color(MechHud.EDGE, MechHud.EDGE.a), false, 1.0)
	draw_string(_font, Vector2(5, 12), "CREW", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, MechHud.WHITE)
	draw_line(Vector2(48, 7), Vector2(CARD_W, 7), Color(MechHud.CYAN, 0.35), 1.0)


func _draw_card(c: Card) -> void:
	var sz := c.size
	var st := c.status
	var lk := c.look()
	var down: bool = lk["dimmed"]
	var hot: bool = lk["warning"]
	var hp := float(st["hp"])
	var a := 0.6 if down else 1.0
	MechHud.draw_glass(c, Rect2(Vector2.ZERO, sz), 1.0)
	# Accent stripe: ties the card to the teammate's mech in the world.
	c.draw_rect(Rect2(3, 4, 3, sz.y - 8), MechAccent.color(str(c.entry.get("accent", ""))), true)
	# Portrait: the pilot head clipped to a hexagon (dimmed and crossed out while disabled).
	var hx := _hex_geom(sz)
	var centre: Vector2 = hx[0]
	var r: float = hx[1]
	var hexp := _hex(centre, r)
	c.draw_colored_polygon(hexp, Color(0.02, 0.07, 0.1, 0.85))
	if c.portrait != null:
		var uvs := PackedVector2Array()
		for p in hexp:
			uvs.append(Vector2(0.5, 0.5) + (p - centre) / (2.0 * r))
		var tint := Color(0.42, 0.42, 0.48, 0.8) if down else Color.WHITE
		c.draw_colored_polygon(hexp, tint, uvs, c.portrait)
	var closed := hexp.duplicate()
	closed.append(hexp[0])
	c.draw_polyline(closed, Color(MechHud.RED if down else MechHud.CYAN, 0.9), 1.5, true)
	if c.badge != null and c.badge.visible:
		var br := Rect2(c.badge.position, c.badge.size).grow(1.5)
		c.draw_rect(br, MechHud.GLASS, true)
		c.draw_rect(br, Color(MechHud.WHITE, 0.85), false, 1.0)
	# Name.
	var x := centre.x + r * 0.866 + 12.0
	var w := sz.x - x - 12.0
	var s := sz.y / CARD_H
	var nm := str(c.entry.get("name", "Pilot")).to_upper()
	if nm.length() > 16:
		nm = nm.left(15) + "."
	var fs := roundi(lerpf(12.0, 14.0, clampf((s - 0.65) / 0.35, 0.0, 1.0)))
	c.draw_string(_font, Vector2(x, sz.y * 0.27), nm, HORIZONTAL_ALIGNMENT_LEFT, w - 40.0, fs, Color(MechHud.WHITE, a))
	c.draw_string(_font, Vector2(x + w - 40.0, sz.y * 0.27), "%d%%" % roundi(hp * 100.0), HORIZONTAL_ALIGNMENT_RIGHT,
		40.0, 11, Color(_hp_col(hp, down), a))
	# Health bar, heat bar under it.
	var bar := Rect2(x, sz.y * 0.37, w, maxf(6.0 * s, 5.0))
	c.draw_rect(bar, Color(MechHud.CYAN, 0.12), true)
	if hp > 0.0:
		c.draw_rect(Rect2(bar.position, Vector2(bar.size.x * hp, bar.size.y)), Color(_hp_col(hp, down), a), true)
	c.draw_rect(bar, Color(MechHud.CYAN, 0.45 * a), false, 1.0)
	var heat := float(st["heat"])
	var hbar := Rect2(x, bar.end.y + 3.0, w, 3.0)
	c.draw_rect(hbar, Color(MechHud.CYAN, 0.1), true)
	var hc := MechHud.AMBER if bool(lk["heat_amber"]) else Color(MechHud.CYAN, 0.75)
	if heat > 0.0:
		c.draw_rect(Rect2(hbar.position, Vector2(hbar.size.x * heat, hbar.size.y)), Color(hc, a), true)
	# Status line: glyph + text (+ the revive countdown ring at the right).
	var gy := sz.y * 0.78
	var g := Vector2(x + 6.0, gy - 4.0)
	var label: String = lk["label"]
	var lc := MechHud.CYAN
	if down:
		lc = MechHud.RED
		c.draw_arc(g, 6.0, 0.0, TAU, 16, MechHud.RED, 1.5, true)
		c.draw_line(g + Vector2(-3, -3), g + Vector2(3, 3), MechHud.RED, 1.5, true)
		c.draw_line(g + Vector2(3, -3), g + Vector2(-3, 3), MechHud.RED, 1.5, true)
		var left: float = lk["revive_left"]
		var full := maxf(float(st["revive_max"]), 0.001)
		var rc := Vector2(sz.x - 22.0, gy - 4.0)
		var rr := minf(11.0, sz.y * 0.16)
		c.draw_arc(rc, rr, 0.0, TAU, 28, Color(MechHud.RED, 0.25), 2.5, true)
		if left > 0.0:
			c.draw_arc(rc, rr, -PI * 0.5, -PI * 0.5 + TAU * clampf(left / full, 0.0, 1.0), 28, MechHud.RED, 2.5, true)
		c.draw_string(_font, rc + Vector2(-rr, 4.0), str(ceili(left)), HORIZONTAL_ALIGNMENT_CENTER, rr * 2.0, 10,
			MechHud.WHITE)
	elif hot:
		lc = MechHud.AMBER
		var tri := PackedVector2Array([g + Vector2(0, -6), g + Vector2(6.5, 5), g + Vector2(-6.5, 5), g + Vector2(0, -6)])
		c.draw_polyline(tri, MechHud.AMBER, 1.5, true)
		c.draw_line(g + Vector2(0, -2), g + Vector2(0, 1.5), MechHud.AMBER, 1.5)
		c.draw_circle(g + Vector2(0, 3.3), 0.9, MechHud.AMBER)
	else:
		c.draw_circle(g, 3.0, Color(MechHud.CYAN, 0.9))
	c.draw_string(_font, Vector2(x + 16.0, gy), label, HORIZONTAL_ALIGNMENT_LEFT, w - 40.0, 11, lc)


static func _hp_col(v: float, down: bool) -> Color:
	if down or v <= 0.0:
		return MechHud.GREY
	if v < 0.34:
		return MechHud.RED
	if v < 0.67:
		return MechHud.AMBER
	return MechHud.CYAN


# --- Demo -----------------------------------------------------------------------------------------------------------

const DEMO_CREW := [
	{"peer": 2, "seat": 2, "name": "Henrietta", "head": "chicken", "chassis": "strider", "accent": "blue", "steam_id": 0},
	{"peer": 3, "seat": 3, "name": "Dill", "head": "pickle", "chassis": "strider", "accent": "green", "steam_id": 0},
	{"peer": 4, "seat": 4, "name": "Rex", "head": "dog", "chassis": "strider", "accent": "purple", "steam_id": 0},
]
const DEMO_STATUS := {
	2: {"hp": 0.86, "heat": 0.24, "state": "ok"},
	3: {"hp": 0.58, "heat": 0.96, "state": "overheat"},
	4: {"hp": 0.0, "heat": 0.1, "state": "disabled", "revive_t": 12.0, "revive_max": REVIVE_WINDOW},
}
