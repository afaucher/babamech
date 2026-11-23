class_name EnemyTroopSquad
extends RefCounted
## Host-only tactical fireteam controller for a variable-sized group (seeded 3-6) of individual EnemyTrooper units
## (docs/design/enemy-troop-squads.md). Each trooper is its own EnemyBase (own position, HP, hit sphere, death, wreck,
## target_id, EnemySync entry); this lightweight object coordinates them without attaching them together:
##   - Distinct per-trooper cover corner reservations (no two troopers stack on the same corner).
##   - Loose organic formation offsets & member separation vectors (never a rigid line).
##   - Staggered firing slots (at most MAX_CONCURRENT_SHOOTERS firing together with a ragged stagger gap).
##   - Shared squad alert relay & morale check (regroup / fall back when losses mount, overridden by deck hunt-out).

const MIN_GROUND_SIZE := 3
const MAX_GROUND_SIZE := 6
const MIN_ROOF_SIZE := 2
const MAX_ROOF_SIZE := 4
const COVER_MIN_SEP := 3.8        ## m min spacing between claimed cover corners in the same fireteam
const MIN_MEMBER_SEP := 3.4       ## m soft separation distance between moving squadmates
const MAX_CONCURRENT_SHOOTERS := 2
const FIRE_STAGGER_GAP := 0.35    ## s min stagger between squadmates starting telegraphs

var squad_id := ""
var deck := 0
var anchor_pos := Vector3.ZERO
var on_roof := false
var members: Array = []           ## Array[EnemyTrooper]
var claimed_covers: Dictionary = {}  ## trooper target_id -> Vector3
var morale_broken := false
var _initial_size := 0
var _fire_slots: Array[String] = []  ## target_ids currently telegraphing/firing
var _last_fire_start := -INF


func net_fields() -> Dictionary:
	return {
		"squad_id": Net.SPAWN, "deck": Net.SPAWN, "anchor_pos": Net.SPAWN, "on_roof": Net.SPAWN,
		"members": Net.LOCAL, "claimed_covers": Net.PRIVATE, "morale_broken": Net.PRIVATE,
		"_initial_size": Net.PRIVATE, "_fire_slots": Net.PRIVATE, "_last_fire_start": Net.PRIVATE,
	}


static func make(id: String, spawn_deck: int, anchor: Vector3, roof: bool = false) -> EnemyTroopSquad:
	var s := EnemyTroopSquad.new()
	s.squad_id = id
	s.deck = spawn_deck
	s.anchor_pos = anchor
	s.on_roof = roof
	return s


## Deterministic variable-sized mixed rifle/AT squad composition (seeded, never global RNG).
## Index 0 is always the fireteam leader (receives variant-0 helmet stripe on EnemyMeshes).
static func roll_composition(rng: RandomNumberGenerator, weight: String = "medium",
		roof: bool = false, max_units: int = MAX_GROUND_SIZE) -> Array[String]:
	var cap := maxi(max_units, 1)
	var count := 3
	if roof:
		var hi := mini(MAX_ROOF_SIZE, cap)
		var lo := mini(MIN_ROOF_SIZE, hi)
		count = rng.randi_range(lo, hi)
	else:
		var lo := MIN_GROUND_SIZE
		var hi := MAX_GROUND_SIZE
		match weight:
			"light":
				lo = 3
				hi = 4
			"medium":
				lo = 4
				hi = 5
			"heavy":
				lo = 5
				hi = 6
		hi = mini(hi, cap)
		lo = mini(lo, hi)
		count = rng.randi_range(lo, hi)
	var out: Array[String] = []
	if roof:
		# Rooftop fireteam: leader AT + mix of AT & rifle overwatch.
		for i in count:
			if i == 0:
				out.append("trooper_at")
			elif i == 1 and count >= 3:
				out.append("trooper_rifle")
			else:
				out.append("trooper_at" if rng.randf() < 0.65 else "trooper_rifle")
		return out
	# Ground squad: leader rifleman + mixed riflemen with 1-2 AT specialists in larger squads.
	var at_count := 0
	if count >= 5:
		at_count = 2 if rng.randf() < 0.55 else 1
	elif count >= 3:
		at_count = 1 if (weight != "light" or rng.randf() < 0.65) else 0
	for i in count:
		if i == 0:
			out.append("trooper_rifle")
		elif i >= count - at_count:
			out.append("trooper_at")
		else:
			out.append("trooper_rifle")
	return out


func add_member(t: EnemyBase) -> void:
	if t == null or t in members:
		return
	members.append(t)
	_initial_size = maxi(_initial_size, members.size())


func remove_member(t: EnemyBase) -> void:
	if t == null:
		return
	members.erase(t)
	claimed_covers.erase(t.target_id)
	_fire_slots.erase(t.target_id)


func alive_members() -> Array:
	var out: Array = []
	for m: Variant in members:
		if is_instance_valid(m) and not (m as EnemyBase).destroyed():
			out.append(m)
	return out


func alive_count() -> int:
	return alive_members().size()


func leader() -> EnemyBase:
	var live := alive_members()
	return live[0] as EnemyBase if not live.is_empty() else null


func claim_cover(trooper_id: String, pos: Vector3) -> void:
	claimed_covers[trooper_id] = pos


func release_cover(trooper_id: String) -> void:
	claimed_covers.erase(trooper_id)


func is_cover_taken(pos: Vector3, exclude_id: String, min_sep: float = COVER_MIN_SEP) -> bool:
	var sep_sq := min_sep * min_sep
	for tid: String in claimed_covers.keys():
		if tid == exclude_id:
			continue
		var c: Vector3 = claimed_covers[tid]
		if c.distance_squared_to(pos) < sep_sq:
			return true
	return false


func can_claim_fire(trooper_id: String, now: float) -> bool:
	_prune_fire_slots()
	if trooper_id in _fire_slots:
		return true
	if _fire_slots.size() >= MAX_CONCURRENT_SHOOTERS:
		return false
	return now - _last_fire_start >= FIRE_STAGGER_GAP


func claim_fire(trooper_id: String, now: float) -> void:
	_prune_fire_slots()
	if not (trooper_id in _fire_slots):
		_fire_slots.append(trooper_id)
	_last_fire_start = now


func release_fire(trooper_id: String) -> void:
	_fire_slots.erase(trooper_id)


func _prune_fire_slots() -> void:
	var live_ids := {}
	for m: Variant in members:
		if is_instance_valid(m) and not (m as EnemyBase).destroyed():
			live_ids[(m as EnemyBase).target_id] = true
	var keep: Array[String] = []
	for tid in _fire_slots:
		if live_ids.has(tid):
			keep.append(tid)
	_fire_slots = keep


## Relay a sighting across the fireteam so buddies react with their own per-trooper jitter.
func share_alert(from_trooper: EnemyBase, target: CombatTarget, target_pos: Vector3) -> void:
	if target == null or not is_instance_valid(target):
		return
	for m: Variant in members:
		if not is_instance_valid(m) or m == from_trooper:
			continue
		var tr := m as EnemyBase
		if tr.destroyed():
			continue
		if tr.has_method("receive_fireteam_alert"):
			tr.call("receive_fireteam_alert", target, target_pos)


## Called when a member dies: frees its reservations, updates morale, and alerts/startles survivors.
func on_member_killed(dead_trooper: EnemyBase, threat_pos: Vector3) -> void:
	claimed_covers.erase(dead_trooper.target_id)
	_fire_slots.erase(dead_trooper.target_id)
	var live := alive_members()
	var losses := maxi(_initial_size - live.size(), 0)
	if _initial_size >= 3 and losses >= 2 and live.size() <= maxi(1, _initial_size / 2):
		morale_broken = true
	for m: Variant in live:
		var tr := m as EnemyBase
		if tr.has_method("on_squadmate_down"):
			tr.call("on_squadmate_down", dead_trooper, threat_pos, morale_broken)


## Soft horizontal separation vector away from living squadmates closer than MIN_MEMBER_SEP.
func separation_vector(self_trooper: EnemyBase, up: Vector3) -> Vector3:
	if self_trooper == null or not is_instance_valid(self_trooper):
		return Vector3.ZERO
	var p := self_trooper.global_position if self_trooper.is_inside_tree() else self_trooper.position
	var push := Vector3.ZERO
	for m: Variant in members:
		if not is_instance_valid(m) or m == self_trooper:
			continue
		var other := m as EnemyBase
		if other.destroyed():
			continue
		var op := other.global_position if other.is_inside_tree() else other.position
		var diff := p - op
		diff -= up * diff.dot(up)
		var d := diff.length()
		if d > 0.01 and d < MIN_MEMBER_SEP:
			push += (diff / d) * ((MIN_MEMBER_SEP - d) / MIN_MEMBER_SEP)
	return push


## Compute loose organic 2D arc offsets around a squad anchor (seeded, never a rigid line).
static func member_arc_offsets(rng: RandomNumberGenerator, count: int, roof: bool = false,
		half_span: float = 7.0) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if count <= 0:
		return out
	if roof:
		var span := clampf(half_span - 1.1, 2.0, 7.5)
		for i in count:
			var frac := (float(i) / float(maxi(count - 1, 1)) - 0.5) * 2.0 if count > 1 else 0.0
			var jx := rng.randf_range(-0.65, 0.65)
			var js := rng.randf_range(-0.8, 0.8)
			out.append(Vector2(clampf(frac * span + jx, -span, span), js))
		return out
	var base_ang := rng.randf_range(0.0, TAU)
	for i in count:
		if i == 0:
			out.append(Vector2(rng.randf_range(-1.4, 1.4), rng.randf_range(-1.4, 1.4)))
		else:
			var ang := base_ang + (TAU * float(i - 1) / float(maxi(count - 1, 1))) + rng.randf_range(-0.42, 0.42)
			var rad := rng.randf_range(4.2, 8.8)
			out.append(Vector2(cos(ang) * rad, sin(ang) * rad))
	return out
