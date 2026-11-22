class_name SteamAvatar
extends RefCounted
## Small (32x32) Steam friend avatars as textures, for the HUD crew panel (docs/design/hud.md "Crew panel"). All Steam
## access stays here in scripts/net/ (test_net_contract): the UI asks `SteamAvatar.request(steam_id, done)` and never
## touches Steam itself.
##   var tex := SteamAvatar.request(id, func(sid: int, t: Texture2D) -> void: ...)
## Returns the cached ImageTexture now when it is known, else null. When Steam is still downloading the image, `done`
## is called later with (steam_id, texture) once `avatar_image_loaded` fires. Without Steam (ENet, offline, headless,
## tests), or for steam_id 0, it returns null and never calls back. Cosmetic only.

static var _cache := {}        ## steam_id -> ImageTexture
static var _waiting := {}      ## steam_id -> Array[Callable]
static var _wired_to: Object = null
static var _hub: _Hub = null       ## owns the signal hookup (an object method, not a static func, as the Callable)


class _Hub extends RefCounted:
	func on_loaded(avatar_id: int, _index: int = 0, _w: int = 0, _h: int = 0) -> void:
		SteamAvatar._on_image_loaded(avatar_id)


static func request(steam_id: int, done: Callable = Callable()) -> Texture2D:
	if steam_id == 0:
		return null
	if _cache.has(steam_id):
		return _cache[steam_id]
	var steam := SteamIdentity.steam()
	if steam == null:
		return null
	_wire(steam)
	var tex := _load(steam, steam_id)
	if tex != null:
		return tex
	if done.is_valid():
		var list: Array = _waiting.get(steam_id, [])
		list.append(done)
		_waiting[steam_id] = list
	return null


## The cached texture or null; never asks Steam.
static func cached(steam_id: int) -> Texture2D:
	return _cache.get(steam_id, null)


## Tests: forget every texture, pending callback and signal hookup.
static func reset_for_tests() -> void:
	_cache.clear()
	_waiting.clear()
	if _hub != null and _wired_to != null and is_instance_valid(_wired_to) \
			and _wired_to.is_connected("avatar_image_loaded", _hub.on_loaded):
		_wired_to.disconnect("avatar_image_loaded", _hub.on_loaded)
	_wired_to = null


## Try to build the texture from Steam's image cache. getSmallFriendAvatar: 0 = no avatar, -1 = still loading
## (avatar_image_loaded follows), otherwise an image handle.
static func _load(steam: Object, steam_id: int) -> Texture2D:
	if not steam.has_method("getSmallFriendAvatar"):
		return null
	var handle := int(steam.call("getSmallFriendAvatar", steam_id))
	if handle <= 0:
		return null
	var w := 0
	var h := 0
	var size_v: Variant = steam.call("getImageSize", handle)
	if size_v is Dictionary:
		w = int((size_v as Dictionary).get("width", 0))
		h = int((size_v as Dictionary).get("height", 0))
	elif size_v is Vector2 or size_v is Vector2i:
		w = int(size_v.x)
		h = int(size_v.y)
	var rgba_v: Variant = steam.call("getImageRGBA", handle)
	var buf := PackedByteArray()
	if rgba_v is Dictionary:
		if not bool((rgba_v as Dictionary).get("success", true)):
			return null
		buf = (rgba_v as Dictionary).get("buffer", PackedByteArray())
	elif rgba_v is PackedByteArray:
		buf = rgba_v
	if w <= 0 or h <= 0 or buf.size() < w * h * 4:
		return null
	var img := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, buf.slice(0, w * h * 4))
	var tex := ImageTexture.create_from_image(img)
	_cache[steam_id] = tex
	return tex


static func _wire(steam: Object) -> void:
	if _wired_to == steam or not steam.has_signal("avatar_image_loaded"):
		return
	if _hub == null:
		_hub = _Hub.new()
	steam.connect("avatar_image_loaded", _hub.on_loaded)
	_wired_to = steam


## GodotSteam: avatar_image_loaded(avatar_id, avatar_index, width, height); avatar_id is the user's steam id.
static func _on_image_loaded(avatar_id: int) -> void:
	if not _waiting.has(avatar_id) or _wired_to == null:
		return
	var tex := _load(_wired_to, avatar_id)
	if tex == null:
		return
	var list: Array = _waiting[avatar_id]
	_waiting.erase(avatar_id)
	for cb: Callable in list:
		if cb.is_valid():
			cb.call(avatar_id, tex)
