extends TestCase
## Pilot head effects (PilotFx, scripts/pilot/pilot_fx.gd): every head gets them without the caller doing anything; each
## kind spawns nodes that end and are freed within their lifetime; the continuous kinds (stars, smoke) run while on and
## stop on strength 0; the flash tints the face and clears; the same seed gives the same particles; the pool stays bounded
## under spam; effects never count toward the face budget; fx_enabled false spawns nothing.

const DT := 1.0 / 60.0


func setup() -> void:
	for id: String in PilotHead.ids():
		await _check_kinds(id)
	_check_continuous()
	_check_flash()
	_check_determinism()
	await _check_pool()
	_check_wiring()
	finish()


func _head(id: String, head_seed: int = 0) -> PilotHead:
	var h := PilotHead.make(id, head_seed)
	h.idle_enabled = false
	add_child(h)
	h.set_process(false)
	return h


func _run(h: PilotHead, seconds: float) -> void:
	for i in roundi(seconds / DT):
		h.advance(DT)


func _check_kinds(id: String) -> void:
	var h := _head(id)
	check(h.fx_node != null and h.fx_node.get_parent() == h, "%s: the head made its own PilotFx" % id)
	var faces := h.face_count()
	for k: String in ["steam", "sweat", "chips"]:
		h.fx.emit(k, 1.0)
		check(h.fx_node.live_count() > 0, "%s: %s spawns particles" % [id, k])
		_run(h, 0.2)
		eq(h.face_count(), faces, "%s: %s particles don't count toward the face budget" % [id, k])
		_run(h, 1.3)
		eq(h.fx_node.live_count(), 0, "%s: %s particles end within their lifetime" % [id, k])
	await frames(2)
	eq(h.fx_node.get_child_count(), 0, "%s: ended particles are freed" % id)
	h.queue_free()


func _check_continuous() -> void:
	var h := _head("chicken")
	h.fx.emit("stars", 1.0)
	_run(h, 3.0)
	eq(int(h.fx_node.live_kinds().get("star", 0)), PilotFx.STAR_COUNT, "stars: %d orbit while on" % PilotFx.STAR_COUNT)
	# They orbit above the head.
	var top := h.fx_node.top.y
	for c in h.fx_node.get_children():
		check((c as Node3D).position.y > top, "a star rides above the head (%.2f > %.2f)" % [(c as Node3D).position.y, top])
	h.fx.emit("stars", 0.0)
	_run(h, PilotFx.STAR_SCATTER + 0.1)
	eq(h.fx_node.live_count(), 0, "stars: strength 0 scatters them away")
	h.fx.emit("smoke", 1.0)
	_run(h, 3.0)
	var n := int(h.fx_node.live_kinds().get("smoke", 0))
	check(n >= 3, "smoke: puffs keep coming while on (%d live)" % n)
	h.fx.emit("smoke", 0.0)
	_run(h, PilotFx.SMOKE_LIFE + 0.1)
	eq(h.fx_node.live_count(), 0, "smoke: stops on strength 0 and the last puffs die out")
	# Dazed from the head's own mood: stars on shutdown, smoke when disabled, both gone after.
	for i in 30:
		h.feed(DT, {"shutdown": true})
	check(h.fx_node.stars_on, "a shutdown (dazed) head shows stars")
	for i in 120:
		h.feed(DT, {})
	check(not h.fx_node.stars_on and h.fx_node.live_count() == 0, "stars go when the head recovers")
	for i in 30:
		h.feed(DT, {"disabled": true})
	check(h.fx_node.smoke_on, "a disabled head smokes")
	h.queue_free()


func _check_flash() -> void:
	var h := _head("chicken")
	h.fx.emit("flash", 1.0)
	check(h.face.material.emission_enabled and h.face.material.emission.v > 0.5, "flash whitens the facets")
	_run(h, 0.2)
	check(not h.face.material.emission_enabled, "the flash clears within a few frames")
	# Flash on top of the flush, and the flush back after.
	h.set_mood("overheated")
	_run(h, 1.0)
	var red := h.face.material.albedo_color
	check(red.g < 0.8, "overheated flushes red (albedo %s)" % red)
	h.fx.emit("flash", 1.0)
	_run(h, 0.2)
	check(h.face.material.albedo_color.is_equal_approx(red), "the flash leaves the flush as it was")
	h.face.set_tint_enabled(false)
	check(h.face.material.albedo_color.is_equal_approx(Color.WHITE), "tint off: no flush")
	h.queue_free()


func _positions(h: PilotHead) -> Array:
	var out := []
	for c in h.fx_node.get_children():
		if not c.is_queued_for_deletion():
			out.append((c as Node3D).position)
	return out


func _check_determinism() -> void:
	var a := _head("chicken", 5)
	var b := _head("chicken", 5)
	var c := _head("chicken", 6)
	for h: PilotHead in [a, b, c]:
		h.fx.emit("chips", 1.0)
		h.fx.emit("sweat", 1.0)
		_run(h, 0.3)
	eq(_positions(a), _positions(b), "same seed, same particles")
	check(_positions(a) != _positions(c), "another seed flies differently")
	for h: PilotHead in [a, b, c]:
		h.queue_free()


func _check_pool() -> void:
	var h := _head("chicken")
	for i in 200:
		h.fx.emit(["steam", "chips", "sweat"][i % 3], 1.0)
		h.advance(DT * 0.25)
	check(h.fx_node.live_count() <= PilotFx.MAX_LIVE, "spam stays bounded (%d <= %d)" % [h.fx_node.live_count(), PilotFx.MAX_LIVE])
	await frames(2)
	check(h.fx_node.get_child_count() <= PilotFx.MAX_LIVE, "dropped particles are freed (%d nodes)" % h.fx_node.get_child_count())
	_run(h, 1.5)
	eq(h.fx_node.live_count(), 0, "everything ends after spam")
	h.queue_free()


func _check_wiring() -> void:
	var h := _head("chicken")
	h.react("pain")
	check(int(h.fx_node.live_kinds().get("chip", 0)) >= 2, "a pain reaction throws chips through the head's own fx")
	h.fx_node.clear()
	h.fx_enabled = false
	h.react("pain")
	eq(h.fx_node.live_count(), 0, "fx_enabled false spawns nothing")
	h.queue_free()
