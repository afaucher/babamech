extends TestCase
## The HUD crew panel (scripts/ui/crew_panel.gd, docs/design/hud.md "Crew panel"), headless: no teammates = hidden and
## empty; the roster minus yourself makes the cards; status_source drives each card's look (healthy / overheated /
## disabled with the revive ring); the Steam avatar badge stays hidden without Steam and shows with an avatar
## (SteamAvatar against a fake Steam object); portraits are cached per head id.


class FakeSteam extends Object:
	signal avatar_image_loaded(avatar_id: int, avatar_index: int, width: int, height: int)
	# What SteamLobby wires and pumps once any Steam object is up (unused here).
	signal lobby_created(result: int, id: int)
	signal lobby_joined(lobby: int, permissions: int, locked: bool, response: int)
	signal lobby_match_list(lobbies: Array)
	signal join_requested(lobby: int, friend: int)
	var ready_ids := {}            ## steam id -> true once the "download" finished

	func run_callbacks() -> void:
		pass

	func getPersonaName() -> String:
		return "Fake"

	func getSmallFriendAvatar(steam_id: int) -> int:
		return 7 if ready_ids.has(steam_id) else -1

	func getImageSize(_handle: int) -> Dictionary:
		return {"width": 2, "height": 2, "success": true}

	func getImageRGBA(_handle: int) -> Dictionary:
		var b := PackedByteArray()
		for i in 4:
			b.append_array(PackedByteArray([255, 128, 0, 255]))
		return {"buffer": b, "success": true}


func setup() -> void:
	await _empty()
	await _demo_and_status()
	await _roster_and_avatar()
	finish()


func _empty() -> void:
	Session.roster = {}
	var cp := CrewPanel.new()
	add_child(cp)
	await frames(2)
	eq(cp.cards.size(), 0, "no teammates: no cards")
	check(not cp.visible, "no teammates: the panel is hidden")
	# Inside the HUD too (solo play): the panel exists but stays hidden.
	var hud := MechHud.new()
	add_child(hud)
	await frames(2)
	check(hud.crew_panel != null and not hud.crew_panel.visible, "solo HUD: crew panel hidden")
	hud.queue_free()
	cp.queue_free()
	await frames(1)


func _demo_and_status() -> void:
	var cp := CrewPanel.new()
	cp.demo = true
	add_child(cp)
	await frames(2)
	eq(cp.cards.size(), 3, "demo: three teammates")
	check(cp.visible, "demo: the panel shows")
	var looks := []
	for c: CrewPanel.Card in cp.cards:
		looks.append(c.look())
		check(c.portrait != null, "card %d has a portrait texture" % c.peer)
		check(not c.badge.visible, "card %d: no avatar badge without Steam" % c.peer)
	eq(looks[0]["label"], "HEALTHY", "demo chicken healthy")
	check(looks[1]["warning"] and looks[1]["heat_amber"], "demo pickle overheated: warning glyph, amber heat")
	check(looks[2]["dimmed"] and looks[2]["revive_ring"], "demo dog disabled: dimmed, revive ring")
	near(looks[2]["revive_left"], 12.0, 0.01, "demo dog revive countdown")
	check(not looks[0]["revive_ring"] and not looks[0]["dimmed"], "healthy: no ring, not dimmed")
	# status_source overrides the demo status; missing keys default to healthy.
	var states := {2: {"state": "disabled", "hp": 0.0, "revive_t": 5.0}, 3: {"hp": 0.3}, 4: {"state": "overheat", "heat": 1.0}}
	cp.status_source = func(peer: int) -> Dictionary: return states.get(peer, {})
	await frames(2)
	var c2: CrewPanel.Card = cp.cards[0]
	check(c2.look()["revive_ring"] and c2.look()["dimmed"], "source: disabled shows the revive ring and dims")
	near(c2.look()["revive_left"], 5.0, 0.01, "source: revive countdown read")
	var c3: CrewPanel.Card = cp.cards[1]
	eq(c3.look()["label"], "HEALTHY", "source: missing state = ok")
	near(float(c3.status["hp"]), 0.3, 0.001, "source: hp read")
	near(float(c3.status["heat"]), 0.0, 0.001, "source: missing heat = 0")
	check(cp.cards[2].look()["warning"], "source: overheat shows the warning")
	states[2] = {"state": "ok"}
	await frames(1)
	check(not c2.look()["revive_ring"], "source: a revived teammate drops the ring")
	# Portraits are cached per head id: the same head twice = one SubViewport.
	var vp_count := 0
	for ch in cp.get_children():
		if ch is SubViewport:
			vp_count += 1
	eq(vp_count, 3, "one portrait viewport per head id")
	cp.portrait("chicken")
	var again := 0
	for ch in cp.get_children():
		if ch is SubViewport:
			again += 1
	eq(again, 3, "a repeated head reuses its portrait")
	cp.demo = false
	await frames(1)
	eq(cp.cards.size(), 0, "demo off, offline: no cards")
	cp.queue_free()
	await frames(1)


func _roster_and_avatar() -> void:
	check(SteamAvatar.request(123) == null, "no Steam: no avatar")
	var fake := FakeSteam.new()
	SteamIdentity.use_for_tests(fake)
	SteamAvatar.reset_for_tests()
	var cp := CrewPanel.new()
	add_child(cp)
	await frames(1)
	# Offline local_id() is 0, so every roster entry is a teammate here.
	Session.roster = {5: {"peer": 5, "seat": 2, "name": "Mate", "head": "corn", "chassis": "strider", "accent": "red",
		"steam_id": 123}, 6: {"peer": 6, "seat": 3, "name": "Enet", "head": "duck", "chassis": "strider", "accent": "blue",
		"steam_id": 0}}
	Session.roster_changed.emit()
	await frames(1)
	eq(cp.cards.size(), 2, "roster: a card per teammate")
	var mate: CrewPanel.Card = cp.cards[0]
	eq(mate.peer, 5, "sorted by seat")
	check(not mate.badge.visible, "avatar still downloading: badge hidden")
	fake.ready_ids[123] = true
	fake.avatar_image_loaded.emit(123, 0, 2, 2)
	check(mate.badge.visible and mate.badge.texture != null, "avatar loaded: badge shows")
	eq(mate.badge.texture.get_width(), 2, "the avatar texture has Steam's image size")
	check(not (cp.cards[1] as CrewPanel.Card).badge.visible, "steam_id 0 (ENet): no badge")
	check(SteamAvatar.cached(123) != null, "the avatar is cached")
	Session.roster = {}
	Session.roster_changed.emit()
	await frames(1)
	eq(cp.cards.size(), 0, "roster emptied: no cards")
	check(not cp.visible, "roster emptied: hidden")
	cp.queue_free()
	SteamAvatar.reset_for_tests()
	SteamIdentity.reset_for_tests()
	fake.free()
	await frames(1)
