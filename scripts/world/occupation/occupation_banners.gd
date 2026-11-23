class_name OccupationBanners
extends Node3D
## The invaders' banners on every deck of the mission stack (docs/design/banners.md): placed from each deck's plan and
## the mission seed (BannerPlan), drawn (BannerMeshes) and registered as combat targets (BannerTarget) on every machine.
## A host-arbitrated world object (AGENTS rule 6, shape 3), like CityProps.
##
## USE (Engine wires it in test_drive after the stack is built and combat is set up):
##   var f := OccupationBanners.new(); add_child(f); f.setup(stack, combat_world)       # all at once, or
##   f.setup_begin(stack, combat_world); while not f.setup_step(budget_ms): await ...    # one deck per step
## Needs: the built CityStack in the tree (its decks' transforms and plans, section hooks; meshes go on
## CityStack.deck_layer(k), set before they enter the tree) and the CombatWorld (targets are registered there; its
## mission_seed seeds the placement unless a seed is passed). The stack must not move after setup.
##
## DESTRUCTION. Each banner's BannerTarget (owner_peer 0, team "enemy") loses HP only on the host (a client's hit comes
## through CombatNet's "combat.hit"). At 0 the host decides the tear, plays it, and sends ONE reliable event to the crew
##   host -> crew   "banner.torn" {deck, id, t}           t = the host's clock (Session.host_time) when it tore
##   host -> peer   "banner.sync" {torn: [[deck, id, t], ...]}   on Session.peer_joined, and once to all at mission_go
## through Session.send_event only (rule 5; the city_props.gd pattern). Every machine plays the same tear from t: the
## cloth drops and crumples to the foot of the facade with a few shreds (FALL s), then lies there as a heap; ragged strips
## stay on the cross-bar, which stays. A tear older than FALL arrives already settled. Torn banners take no hits.
## HP is never synced. Events that arrive before setup finishes are kept and applied at the end.
##
## SCORE: torn_count(deck) / banner_count(deck) (deck -1 = all) on every machine; `banner_torn(deck, id)` fires on every
## machine; a [Flow] "banner torn" line is logged.
##
## QUALITY (local presentation): each deck's banners follow that deck's visibility (CityStack hides far decks at LOW /
## MEDIUM); set_quality(LOW) turns the cloth's shadows off. The banner count never depends on quality: banners are
## gameplay targets and must be the same on every machine.

signal banner_torn(deck: int, id: int)

const TORN := "banner.torn"
const SYNC := "banner.sync"
const FALL := 1.1                 ## s: the cloth's drop to the ground
const SHRED_N := 5
const VIS_EVERY := 0.25           ## s between deck-visibility checks

var stack: CityStack
var world: CombatWorld
var seed_value := 0
var plans: Array = []             ## per deck: BannerPlan.make's list
var torn: Array = []              ## per deck: {id: t (host clock)}: the host decides, the crew receives it
var now := 0.0                    ## the banner clock: host_time() online, local seconds offline
var quality := CityQuality.HIGH
var _nodes: Array = []            ## per deck: [{root, anchor, cloth, fringe, heap, shreds: [MeshInstance3D], target, ground, len, seeds}]
var _holders: Array[Node3D] = []
var _anim: Dictionary = {}        ## Vector2i(deck, id) -> true while its tear plays
var _pending: Array = []          ## [kind, data] received before setup finished
var _bk := -1                     ## the next deck setup_step builds (-1: idle)
var _built := false
var _vis_in := 0.0
var _went := false                ## the host's mission_go sync went out
var _listening := false


func net_fields() -> Dictionary:
	return {"stack": Net.LOCAL, "world": Net.LOCAL, "seed_value": Net.SPAWN, "plans": Net.SPAWN,
		"torn": Net.OWNER,            # the host decides every tear; the crew gets banner.torn / banner.sync
		"now": Net.LOCAL, "quality": Net.LOCAL, "_nodes": Net.LOCAL, "_holders": Net.LOCAL, "_anim": Net.LOCAL,
		"_pending": Net.LOCAL, "_bk": Net.LOCAL, "_built": Net.LOCAL, "_vis_in": Net.LOCAL, "_went": Net.PRIVATE,
		"_listening": Net.LOCAL}


func _init() -> void:
	name = "OccupationBanners"


func _ready() -> void:
	var s := Net.session()
	if s != null and not _listening:
		_listening = true
		s.event_received.connect(_on_event)
		s.peer_joined.connect(_on_peer_joined)
		s.mission_go.connect(_on_mission_go)


func _exit_tree() -> void:
	var s := Net.session()
	if s != null and _listening:
		_listening = false
		if s.event_received.is_connected(_on_event):
			s.event_received.disconnect(_on_event)
		if s.peer_joined.is_connected(_on_peer_joined):
			s.peer_joined.disconnect(_on_peer_joined)
		if s.mission_go.is_connected(_on_mission_go):
			s.mission_go.disconnect(_on_mission_go)
	_unregister()


# --- Setup ------------------------------------------------------------------------------------------------

func setup(st: CityStack, w: CombatWorld, seed: int = -1) -> void:
	setup_begin(st, w, seed)
	while not setup_step(INF):
		pass


func setup_begin(st: CityStack, w: CombatWorld, seed: int = -1) -> void:
	_clear()
	stack = st
	world = w
	seed_value = seed if seed >= 0 else (w.mission_seed if w != null else 0)
	_bk = 0


## Builds one deck per call (placement + nodes + targets); true once every deck is done.
func setup_step(_budget_ms: float = 8.0) -> bool:
	if _built:
		return true
	if stack == null or _bk < 0:
		return false
	if _bk < stack.decks.size():
		_build_deck(_bk)
		_bk += 1
	if _bk >= stack.decks.size():
		_bk = -1
		_built = true
		now = _clock()
		for p: Array in _pending:
			_receive(str(p[0]), p[1])
		_pending.clear()
		return true
	return false


func setup_done() -> bool:
	return _built


func _clear() -> void:
	_unregister()
	for h in _holders:
		if is_instance_valid(h):
			h.queue_free()
	_holders.clear()
	_nodes.clear()
	plans.clear()
	torn.clear()
	_anim.clear()
	_built = false
	_bk = -1
	_went = false


func _unregister() -> void:
	if world == null or not is_instance_valid(world):
		return
	for dn: Array in _nodes:
		for n: Dictionary in dn:
			var t: BannerTarget = n["target"]
			if is_instance_valid(t):
				world.unregister(t)


func _build_deck(k: int) -> void:
	var d: CityDistrict = stack.decks[k]
	var list := BannerPlan.make(d.plan, seed_value)
	plans.append(list)
	torn.append({})
	var layer := CityStack.deck_layer(k)
	var holder := Node3D.new()
	holder.name = "Deck%d" % k
	holder.transform = (global_transform.affine_inverse() * d.global_transform) if is_inside_tree() and d.is_inside_tree() \
			else d.transform
	var nodes: Array = []
	for b: Dictionary in list:
		nodes.append(_make_banner(holder, d.ring, k, b, layer))
	add_child(holder)
	_holders.append(holder)
	_nodes.append(nodes)
	if world != null:
		for n: Dictionary in nodes:
			world.register(n["target"])
	for n: Dictionary in nodes:
		(n["target"] as BannerTarget).cloth_down.connect(_on_cloth_down)


## The nodes of one banner under `parent` (not yet in the tree, or in it: every mesh gets `layer` before it is added).
## Returns {root, anchor, cloth, fringe, heap, shreds, target, ground, len}.
func _make_banner(parent: Node3D, ring: RingFrame, k: int, b: Dictionary, layer: int) -> Dictionary:
	var n2: Vector2 = b["n"]
	var z := Vector3(n2.x, 0.0, n2.y)
	var lb := Basis(Vector3.UP.cross(z), Vector3.UP, z)
	var wall := str(b["kind"]) == "wall"
	var h := float(b["top"]) + CityPlan.CURB_H if wall else CityPlan.CURB_H
	var root := Node3D.new()
	root.name = "Banner%d" % int(b["id"])
	root.transform = Transform3D(CityGeo.frame_basis(ring, float(b["s"])) * lb, ring.arc_to_world(float(b["x"]), float(b["s"]), h))
	var anchor := Node3D.new()
	anchor.name = "Anchor"
	var ground := float(b["top"])
	if wall:
		root.add_child(_mi("Bar", BannerMeshes.bar(), layer, true))
	else:
		root.add_child(_mi("Pole", BannerMeshes.pole(), layer, true))
		anchor.position = Vector3(BannerMeshes.ARM_X, BannerMeshes.ARM_H, 0.12)
		ground = BannerMeshes.ARM_H
	root.add_child(anchor)
	var parts := make_parts(anchor, k, int(b["id"]), float(b["len"]), ground, layer)
	parts["root"] = root
	parent.add_child(root)
	if quality <= CityQuality.LOW:
		(parts["cloth"] as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return parts


## The cloth, its torn states and its target under `anchor` (the cross-bar point; ground = how far below it the ground
## is). Shared with the lab. Every mesh gets `layer` before it enters the tree.
static func make_parts(anchor: Node3D, k: int, id: int, length: float, ground: float, layer: int) -> Dictionary:
	var cloth := _mi("Cloth", BannerMeshes.cloth(length), layer, true)
	anchor.add_child(cloth)
	var fringe := _mi("Fringe", BannerMeshes.fringe(), layer, false)
	fringe.visible = false
	anchor.add_child(fringe)
	var heap := _mi("Heap", BannerMeshes.heap(), layer, false)
	heap.position = Vector3(0.0, -ground + 0.02, 1.2)
	heap.scale = Vector3(1.3, 1.5, 1.3)       # reads at chase-camera distance
	heap.visible = false
	anchor.add_child(heap)
	var shreds: Array = []
	for i in SHRED_N:
		var sh := _mi("Shred%d" % i, BannerMeshes.shred(), layer, false)
		sh.visible = false
		anchor.add_child(sh)
		shreds.append(sh)
	var t := BannerTarget.new(k, id, length)
	anchor.add_child(t)
	return {"anchor": anchor, "cloth": cloth, "fringe": fringe, "heap": heap, "shreds": shreds, "target": t,
		"ground": ground, "len": length}


static func _mi(nm: String, mesh: Mesh, layer: int, shadows: bool) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = mesh
	mi.layers = layer          # before it enters the tree
	if not shadows:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


# --- Queries ----------------------------------------------------------------------------------------------

func banner_count(deck: int = -1) -> int:
	var c := 0
	for k in plans.size():
		if deck < 0 or k == deck:
			c += (plans[k] as Array).size()
	return c


func torn_count(deck: int = -1) -> int:
	var c := 0
	for k in torn.size():
		if deck < 0 or k == deck:
			c += (torn[k] as Dictionary).size()
	return c


func is_torn(deck: int, id: int) -> bool:
	return deck >= 0 and deck < torn.size() and (torn[deck] as Dictionary).has(id)


func target(deck: int, id: int) -> BannerTarget:
	if deck < 0 or deck >= _nodes.size() or id < 0 or id >= (_nodes[deck] as Array).size():
		return null
	return _nodes[deck][id]["target"]


func parts(deck: int, id: int) -> Dictionary:
	if deck < 0 or deck >= _nodes.size() or id < 0 or id >= (_nodes[deck] as Array).size():
		return {}
	return _nodes[deck][id]


## [[deck, id, t], ...] for every torn banner.
func torn_list() -> Array:
	var out: Array = []
	for k in torn.size():
		var ids: Array = (torn[k] as Dictionary).keys()
		ids.sort()
		for id: int in ids:
			out.append([k, id, float(torn[k][id])])
	return out


## The placement of every deck in one hash (tests).
func checksum() -> String:
	var s := ""
	for l: Array in plans:
		s += BannerPlan.checksum(l)
	return s.sha256_text().substr(0, 16)


# --- Destruction ------------------------------------------------------------------------------------------

func _clock() -> float:
	var s := Net.session()
	return s.host_time() if s != null and s.online() else now


## The host (or solo): a banner's HP reached 0. Decide the tear once, play it, tell the crew.
func _on_cloth_down(deck: int, id: int) -> void:
	if is_torn(deck, id):
		return
	var s := Net.session()
	if s != null and s.is_client():
		return       # never: a client owns no banner (owner_peer 0)
	now = _clock()
	tear(deck, id, now)
	if s != null and s.online():
		s.send_event(0, TORN, {"deck": deck, "id": id, "t": now})


## Play banner (deck, id)'s tear from host time t0 (an old t0 lands it settled). Every machine; idempotent.
func tear(deck: int, id: int, t0: float) -> void:
	var n := parts(deck, id)
	if n.is_empty() or is_torn(deck, id):
		return
	torn[deck][id] = t0
	(n["target"] as BannerTarget).torn = true
	(n["fringe"] as MeshInstance3D).visible = true
	var e := now - t0
	if e >= FALL * 1.3:
		pose_tear(n, INF, deck, id)
	else:
		_anim[Vector2i(deck, id)] = true
		pose_tear(n, maxf(e, 0.0), deck, id)
	FlowLog.say("banner torn", "deck %d banner %d (%d of %d torn)" % [deck, id, torn_count(), banner_count()])
	banner_torn.emit(deck, id)


## The tear's look `e` s after it began (INF = settled): the cloth drops, tips out and crumples, shreds flutter down,
## then the heap lies at the foot. Pure presentation; also scrubbed by the lab.
static func pose_tear(n: Dictionary, e: float, deck: int = 0, id: int = 0) -> void:
	var cloth: MeshInstance3D = n["cloth"]
	var heap: MeshInstance3D = n["heap"]
	var ground := float(n["ground"])
	var length := float(n["len"])
	var f := clampf(e / FALL, 0.0, 1.0)
	cloth.visible = f < 1.0
	heap.visible = f >= 1.0
	if f < 1.0:
		var sq := 0.35 + 0.65 * (1.0 - f)
		cloth.transform = Transform3D(Basis(Vector3.RIGHT, -1.15 * f).scaled(Vector3(1.0 - 0.2 * f, sq, 1.0)),
			Vector3(0.0, -(ground - length * 0.35) * f * f, 0.5 * f))
	else:
		cloth.transform = Transform3D.IDENTITY
	var rng := RandomNumberGenerator.new()     # looks only: its own generator, seeded per banner
	rng.seed = deck * 7349 + id * 131 + 17
	for sh: MeshInstance3D in n["shreds"]:
		var sx := rng.randf_range(-1.7, 1.7)
		var sy := -rng.randf_range(0.6, length - 0.6)
		var dur := FALL * rng.randf_range(0.8, 1.3)
		var drift := Vector3(rng.randf_range(-1.2, 1.2), 0.0, rng.randf_range(0.4, 2.0))
		var spin := rng.randf_range(4.0, 9.0)
		var g := clampf(e / dur, 0.0, 1.0)
		sh.visible = e > 0.0 and g < 1.0
		if sh.visible:
			var p := Vector3(sx, sy + (-ground - sy + 0.1) * g * g, 0.05) + drift * g
			sh.transform = Transform3D(Basis(Vector3(0.3, 1.0, 0.5).normalized(), spin * e), p)


## Back to whole (lab / tests only: tears are never undone in play).
func reset_all() -> void:
	for k in torn.size():
		for id: int in (torn[k] as Dictionary).keys():
			var n := parts(k, id)
			(n["target"] as BannerTarget).torn = false
			(n["target"] as BannerTarget).reset_state()
			(n["fringe"] as MeshInstance3D).visible = false
			pose_tear(n, 0.0, k, id)
		torn[k] = {}
	_anim.clear()


func _process(delta: float) -> void:
	var s := Net.session()
	now = s.host_time() if s != null and s.online() else now + delta
	if not _anim.is_empty():
		for key: Vector2i in _anim.keys():
			var n := parts(key.x, key.y)
			var e := now - float(torn[key.x][key.y])
			if n.is_empty() or e >= FALL * 1.3:
				if not n.is_empty():
					pose_tear(n, INF, key.x, key.y)
				_anim.erase(key)
			else:
				pose_tear(n, e, key.x, key.y)
	_vis_in -= delta
	if _vis_in <= 0.0 and stack != null and is_instance_valid(stack):
		_vis_in = VIS_EVERY
		for k in mini(_holders.size(), stack.decks.size()):
			var v := stack.decks[k].visible
			if _holders[k].visible != v:
				_holders[k].visible = v


## Local presentation (Settings > Graphics quality): LOW drops the cloth's shadows. Never changes the banners.
func set_quality(q: int) -> void:
	quality = q
	for dn: Array in _nodes:
		for n: Dictionary in dn:
			(n["cloth"] as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF \
					if q <= CityQuality.LOW else GeometryInstance3D.SHADOW_CASTING_SETTING_ON


# --- Wire (through Session only) --------------------------------------------------------------------------

func _on_event(from: int, kind: String, data: Dictionary, _stamp: float) -> void:
	if not kind.begins_with("banner."):
		return
	var s := Net.session()
	if s == null or not s.is_client() or from != 1:
		return        # only the host decides; it hears nothing back
	if not _built:
		_pending.append([kind, data])
		return
	_receive(kind, data)


func _receive(kind: String, data: Dictionary) -> void:
	match kind:
		TORN:
			tear(int(data.get("deck", -1)), int(data.get("id", -1)), float(data.get("t", now)))
		SYNC:
			for e: Variant in data.get("torn", []):
				if e is Array and (e as Array).size() >= 3:
					tear(int(e[0]), int(e[1]), float(e[2]))


func _on_peer_joined(peer: int) -> void:
	var s := Net.session()
	if s != null and s.is_host() and _built and torn_count() > 0:
		s.send_event(peer, SYNC, {"torn": torn_list()})


func _on_mission_go(_elapsed: float) -> void:
	var s := Net.session()
	if s != null and s.is_host() and not _went:
		_went = true
		if torn_count() > 0:
			s.send_event(0, SYNC, {"torn": torn_list()})
