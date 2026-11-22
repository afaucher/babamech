class_name PlayerBotSquad
extends Node
## Coordinates 2–4 PlayerBot instances for Co-op Squad Balance testing (docs/design/player-ai.md §3.2).
## Strictly human-fair (no hive mind):
##   - Honest callout board: only enemies actually seen via a bot's real LOS are posted, and teammates receive the LKP
##     after `callout_delay` s (plus their own reaction delay, and still need personal LOS for direct-fire weapons).
##   - Target focus-fire weighting + per-bot flank sector offsets + soft teammate separation so bots don't clump inside
##     a single Siege Cannon splash radius.
##   - Friendly-line awareness: checks if a teammate sits between a bot and its aim point and yields a lateral sidestep.

const CONTACT_EXPIRE_S := 16.0
const FRIENDLY_RADIUS := 3.2      ## m clearance cylinder around teammate mechs for line-of-fire checks

# Config (Net.SPAWN)
var focus_fire_bias := 0.65       ## 0 = split fire freely, 1 = strong focus-fire onto primary callout
var callout_delay := 0.35         ## s voice-callout delay before teammates see a spotter's LKP
var sep_radius := 13.5            ## m comfortable teammate spacing on the street

# Scene references (Net.LOCAL)
var bots: Array[PlayerBot] = []
var world: CombatWorld

# Internal squad coordination state (Net.PRIVATE)
var contacts: Dictionary = {}     ## enemy_id -> {enemy, pos, seen_t, ready_t, spotter_id}
var primary_target_id := ""
var slot_angles: Dictionary = {}  ## bot_id -> float (rad flank offset)
var callouts_posted := 0


func net_fields() -> Dictionary:
	return {
		"focus_fire_bias": Net.SPAWN, "callout_delay": Net.SPAWN, "sep_radius": Net.SPAWN,
		"bots": Net.LOCAL, "world": Net.LOCAL,
		"contacts": Net.PRIVATE, "primary_target_id": Net.PRIVATE, "slot_angles": Net.PRIVATE,
		"callouts_posted": Net.PRIVATE,
	}


func setup(w: CombatWorld, bias: float = 0.65) -> void:
	world = w
	focus_fire_bias = clampf(bias, 0.0, 1.0)
	bots.clear()
	contacts.clear()
	primary_target_id = ""
	slot_angles.clear()
	callouts_posted = 0


func add_bot(bot: PlayerBot) -> void:
	if bot == null or bot in bots:
		return
	bots.append(bot)
	bot.bot_squad = self
	_assign_flank_angles()


func _assign_flank_angles() -> void:
	slot_angles.clear()
	var n := bots.size()
	if n <= 1:
		for b in bots:
			slot_angles[b.bot_id] = 0.0
		return
	var span := 0.9 if n == 2 else (1.4 if n == 3 else 1.7)
	for i in n:
		var frac := float(i) / float(n - 1) - 0.5   # -0.5 .. +0.5
		slot_angles[bots[i].bot_id] = frac * span


## Post an honest LOS sighting from `spotter` to the squad callout board.
func report_sighting(spotter: PlayerBot, enemy: EnemyBase, pos: Vector3, sim_t: float) -> void:
	if spotter == null or enemy == null or enemy.destroyed():
		return
	var eid := enemy.target_id
	if not contacts.has(eid):
		callouts_posted += 1
		contacts[eid] = {
			"enemy": enemy, "pos": pos, "seen_t": sim_t,
			"ready_t": sim_t + callout_delay, "spotter_id": spotter.bot_id,
		}
	else:
		var c: Dictionary = contacts[eid]
		c["pos"] = pos
		c["seen_t"] = sim_t
		c["spotter_id"] = spotter.bot_id


## Advance squad target assignments once per step (before stepping bots).
func step_coordination(sim_t: float) -> void:
	for eid: String in contacts.keys():
		var c: Dictionary = contacts[eid]
		var e: Variant = c.get("enemy")
		if e == null or not is_instance_valid(e) or (e as EnemyBase).destroyed() or sim_t - float(c["seen_t"]) > CONTACT_EXPIRE_S:
			contacts.erase(eid)

	# Compute squad centroid for threat prioritization.
	var centroid := Vector3.ZERO
	var alive_n := 0
	for b in bots:
		if _bot_alive(b):
			centroid += b.mech.global_position
			alive_n += 1
	if alive_n > 0:
		centroid /= float(alive_n)

	var best_id := ""
	var best_score := -INF
	for eid: String in contacts:
		var c: Dictionary = contacts[eid]
		if sim_t < float(c["ready_t"]):
			continue
		var e: EnemyBase = c["enemy"]
		var d := centroid.distance_to(c["pos"] as Vector3)
		var score := 120.0 - d
		if e.enemy_type == "tank":
			score += 24.0
		elif e.enemy_type == "turret":
			score += 18.0
		if e.ai_state == EnemyBase.STATE_TELEGRAPH:
			score += 15.0
		if eid == primary_target_id:
			score += 20.0   # hysteresis so the squad finishes a called target cleanly
		if score > best_score:
			best_score = score
			best_id = eid
	primary_target_id = best_id


## Contacts ready for `bot` (after voice-callout delay).
func shared_contacts_for(bot: PlayerBot, sim_t: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for eid: String in contacts:
		var c: Dictionary = contacts[eid]
		if str(c["spotter_id"]) == bot.bot_id:
			continue
		if sim_t >= float(c["ready_t"]):
			var e: Variant = c.get("enemy")
			if e != null and is_instance_valid(e) and not (e as EnemyBase).destroyed():
				out.append(c)
	return out


func flank_angle_for(bot: PlayerBot) -> float:
	return float(slot_angles.get(bot.bot_id, 0.0))


func bot_index_of(bot: PlayerBot) -> int:
	return bots.find(bot)


## Soft horizontal separation vector away from nearby alive teammates (prevents splash clumping).
func separation_vector(self_bot: PlayerBot, up: Vector3) -> Vector3:
	if self_bot == null or self_bot.mech == null or not self_bot.mech.is_inside_tree():
		return Vector3.ZERO
	var p := self_bot.mech.global_position
	var acc := Vector3.ZERO
	for other in bots:
		if other == self_bot or not _bot_alive(other):
			continue
		var diff := p - other.mech.global_position
		diff -= up * diff.dot(up)
		var d := diff.length()
		if d > 0.05 and d < sep_radius:
			acc += diff.normalized() * ((sep_radius - d) / sep_radius)
	return acc


## Check if any alive teammate stands directly along the direct-fire line `origin -> aim_pt`.
## Returns {"blocked": bool, "sidestep": Vector3 (unit in local floor plane)}.
func friendly_in_line_of_fire(self_bot: PlayerBot, origin: Vector3, aim_pt: Vector3, up: Vector3) -> Dictionary:
	var seg := aim_pt - origin
	var seg_len := seg.length()
	if seg_len < 4.0:
		return {"blocked": false, "sidestep": Vector3.ZERO}
	var seg_dir := seg / seg_len
	for other in bots:
		if other == self_bot or not _bot_alive(other):
			continue
		var center := other.mech.global_position + up * 4.2
		var rel := center - origin
		var along := rel.dot(seg_dir)
		if along <= 1.5 or along >= seg_len - 2.5:
			continue
		var closest := origin + seg_dir * along
		var off := closest - center
		var perp := off - up * off.dot(up)
		if perp.length() < FRIENDLY_RADIUS:
			var side := seg_dir.cross(up).normalized()
			if perp.length_squared() > 0.01 and side.dot(perp) < 0.0:
				side = -side
			elif flank_angle_for(self_bot) < 0.0:
				side = -side
			return {"blocked": true, "sidestep": side}
	return {"blocked": false, "sidestep": Vector3.ZERO}


func alive_count() -> int:
	var n := 0
	for b in bots:
		if _bot_alive(b):
			n += 1
	return n


func total_count() -> int:
	return bots.size()


func all_disabled() -> bool:
	return alive_count() == 0


func _bot_alive(b: PlayerBot) -> bool:
	return b != null and is_instance_valid(b) and b.mech != null and is_instance_valid(b.mech) \
		and b.mech.is_inside_tree() and (b.target == null or not b.target.disabled)
