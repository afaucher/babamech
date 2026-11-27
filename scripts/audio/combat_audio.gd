class_name CombatAudio
extends Node
## Cosmetic combat, weapon, prop, player-damage, and enemy audio observer (docs/design/audio.md §3C-E, §4).
## Binds cleanly to CombatWorld, optional WeaponRack, optional CityProps, optional EnemySquad (group "enemy_squad"),
## and optional PlayerTarget (group "player_target") via signals only — never mutates gameplay state (Net LOCAL).
##
## Usage:
##   var ca := CombatAudio.new()
##   add_child(ca)
##   ca.bind(world, rack, props, "player1")
##   ca.bind_squad(squad)                 # optional (also auto-discovered via group "enemy_squad")
##   ca.bind_player_target(player_target) # optional (also auto-discovered via group "player_target")

const MORTAR_WHISTLE_LEAD := 1.3    ## s before impact to start the descending whistle telegraph
## ms an enemy counts as "hit by this machine's pilot" after local_shooter's hit on it: EnemySquad component_damaged /
## component_destroyed carry no shooter, so their 2D hit-confirm plays only within this window (covers a client's wait
## for the host's replay). A teammate's or bot's hit on the same enemy inside it is the accepted false positive.
const LOCAL_HIT_WINDOW_MS := 1500

var world: CombatWorld
var rack: WeaponRack
var props: Node
var squad: Node
var player_target: Node
var local_shooter := "player1"

var _hooked_targets: Dictionary = {}     ## target instance_id -> {target, hp_snap, was_dead}
var _hooked_mounts: Dictionary = {}      ## mount instance_id -> true
var _whistled_shells: Dictionary = {}    ## MortarShell instance_id -> true
var _enemy_fired_recent: Dictionary = {} ## enemy_id -> clock time (dedupes world.fired vs enemy_event)
var _was_trigger := false
var _scan_t := 0.0
var _slot_batch_t := -1.0
var _slot_batch_count := 0
var _slot_batch_last := 0
var _slot_batch_on := false
var _reveal_ping_t := 0.0
var _local_hits: Dictionary = {}         ## target_id -> Time.get_ticks_msec() of local_shooter's last hit on it
var _pending_marks: Array = []           ## [target_id, cue, db, pitch]: squad hit-confirms, played in step() if local


func net_fields() -> Dictionary:
	return {
		"world": Net.LOCAL, "rack": Net.LOCAL, "props": Net.LOCAL, "squad": Net.LOCAL, "player_target": Net.LOCAL,
		"local_shooter": Net.LOCAL, "_hooked_targets": Net.LOCAL, "_hooked_mounts": Net.LOCAL,
		"_whistled_shells": Net.LOCAL, "_enemy_fired_recent": Net.LOCAL, "_was_trigger": Net.LOCAL,
		"_scan_t": Net.LOCAL, "_slot_batch_t": Net.LOCAL, "_slot_batch_count": Net.LOCAL,
		"_slot_batch_last": Net.LOCAL, "_slot_batch_on": Net.LOCAL, "_reveal_ping_t": Net.LOCAL,
		"_local_hits": Net.LOCAL, "_pending_marks": Net.LOCAL,
	}


func bind(w: CombatWorld, r: WeaponRack = null, pr: Node = null, local_shooter_id: String = "player1") -> void:
	world = w
	rack = r
	local_shooter = local_shooter_id
	if world != null:
		if not world.fired.is_connected(_on_fired):
			world.fired.connect(_on_fired)
		if not world.hit_landed.is_connected(_on_hit_landed):
			world.hit_landed.connect(_on_hit_landed)
		if not world.remote_hit.is_connected(_on_remote_hit):
			world.remote_hit.connect(_on_remote_hit)
		# Prefer rich impact_spawned signal (added by Enemy/CombatWorld); fall back to shake when absent.
		if world.has_signal("impact_spawned"):
			if not world.is_connected("impact_spawned", _on_impact_spawned):
				world.connect("impact_spawned", _on_impact_spawned)
		elif not world.shake.is_connected(_on_shake_fallback):
			world.shake.connect(_on_shake_fallback)
		# W8 (Weapons, logged): repair drone launches (local and remote) are heard at the drone.
		if not world.drone_launched.is_connected(_on_drone_launched):
			world.drone_launched.connect(_on_drone_launched)
		_sync_targets()
	if rack != null:
		if not rack.slot_changed.is_connected(_on_slot_changed):
			rack.slot_changed.connect(_on_slot_changed)
		_sync_mounts()
	if pr != null:
		bind_props(pr)


func bind_props(pr: Node) -> void:
	if pr == null or pr == props:
		return
	props = pr
	if props.has_signal("prop_moved") and not props.is_connected("prop_moved", _on_prop_moved):
		props.connect("prop_moved", _on_prop_moved)


## W8 (Weapons, logged): in the city stack every deck has its own CityProps; `props` is only the entry deck's. Connect
## prop_moved on every deck's props too (CombatWorld.city_stack / deck_props), re-checked on the 0.5 s scan.
func _bind_deck_props() -> void:
	if world == null or world.city_stack() == null:
		return
	var decks: Variant = world.city_stack().get("decks")
	if not (decks is Array):
		return
	for k in (decks as Array).size():
		var pr := world.deck_props(k)
		if pr != null and pr.has_signal("prop_moved") and not pr.is_connected("prop_moved", _on_prop_moved):
			pr.connect("prop_moved", _on_prop_moved)


func bind_squad(sq: Node) -> void:
	if sq == null or sq == squad:
		return
	squad = sq
	if squad.has_signal("enemy_event") and not squad.is_connected("enemy_event", _on_enemy_event):
		squad.connect("enemy_event", _on_enemy_event)


func bind_player_target(pt: Node) -> void:
	if pt == null or pt == player_target:
		return
	player_target = pt
	if pt.has_signal("damaged") and not pt.is_connected("damaged", _on_player_damaged):
		pt.connect("damaged", _on_player_damaged)
	if pt.has_signal("staggered_by") and not pt.is_connected("staggered_by", _on_player_staggered):
		pt.connect("staggered_by", _on_player_staggered)
	if pt.has_signal("player_component_destroyed") and not pt.is_connected("player_component_destroyed", _on_player_part_lost):
		pt.connect("player_component_destroyed", _on_player_part_lost)
	if pt.has_signal("player_disabled") and not pt.is_connected("player_disabled", _on_player_disabled):
		pt.connect("player_disabled", _on_player_disabled)


func _exit_tree() -> void:
	_stop_all_loops()


func _stop_all_loops() -> void:
	var a := AudioDirector.of(self)
	if a == null:
		return
	for i in 8:
		a.stop_loop(_charge_tag(i))
		a.stop_loop(_spin_tag(i))
	a.stop_loop(_lock_tag())


func _physics_process(delta: float) -> void:
	var pp0 := Time.get_ticks_usec() if PerfProbe.on else 0   # bench instrumentation (tests/bench_bot_perf.gd)
	step(delta)
	if PerfProbe.on:
		PerfProbe.add("main.combat_audio", Time.get_ticks_usec() - pp0)


## Public step so headless tests can drive weapon loops, mortar whistles, and group discovery deterministically.
func step(delta: float) -> void:
	if delta <= 0.0:
		return
	var a := AudioDirector.of(self)
	if a == null or a.skip_cues():   # headless: no sound, so no scanning for cues either (AudioDirector.silent)
		return
	_flush_slot_audio(a)
	_flush_hit_marks(a)
	_scan_t -= delta
	if _scan_t <= 0.0 and is_inside_tree():
		_scan_t = 0.5
		if props == null:
			bind_props(get_tree().get_first_node_in_group("city_props"))
		if squad == null:
			bind_squad(get_tree().get_first_node_in_group("enemy_squad"))
		if player_target == null:
			bind_player_target(get_tree().get_first_node_in_group("player_target"))
		_bind_deck_props()
	if world != null:
		_sync_targets()
		_step_mortar_whistles(a)
	if rack != null:
		_sync_mounts()
		_step_rack(a)
	_step_reveal_pings(a, delta)


# --- Weapons & Rack -------------------------------------------------------------------------------------

func _sync_mounts() -> void:
	for m: Variant in rack.mounts:
		if m == null:
			continue
		var mid := (m as Object).get_instance_id()
		if not _hooked_mounts.has(mid):
			_hooked_mounts[mid] = true
			if not (m as WeaponMount).dry.is_connected(_on_weapon_dry):
				(m as WeaponMount).dry.connect(_on_weapon_dry)


func _step_rack(a: AudioDirector) -> void:
	var fresh_press := rack.trigger and not _was_trigger
	_was_trigger = rack.trigger
	var bus := AudioDirector.BUS_SFX_PLAYER
	for i in rack.slot_count():
		var m: WeaponMount = rack.mounts[i]
		var w := rack.weapons[i]
		var enabled := rack.enabled[i]
		var pos := rack.muzzle(i + 1)
		# Laser / Railgun charge whine
		var c_tag := _charge_tag(i)
		if m != null and enabled and float(m.stats.get("charge", 0.0)) > 0.0:
			var f := ChargeGlow.fraction(m)
			if f > 0.01:
				a.start_loop(c_tag, "wpn.laser.charge", true, pos, lerpf(-10.0, 0.0, f), lerpf(0.75, 1.65, f), bus, "local_mech")
			elif a.has_loop(c_tag):
				a.stop_loop(c_tag)
		elif a.has_loop(c_tag):
			a.stop_loop(c_tag)
		# Gatling barrel spin-up / hold / spin-down loop
		var s_tag := _spin_tag(i)
		if m != null and w == "gatling":
			var spd := clampf(m.spin, 0.0, 1.0)
			if spd > 0.02:
				a.start_loop(s_tag, "wpn.gatling.spin_loop", true, pos, lerpf(-16.0, -2.0, spd), lerpf(0.55, 1.32, spd), bus, "local_mech")
			elif a.has_loop(s_tag):
				a.stop_loop(s_tag)
		elif a.has_loop(s_tag):
			a.stop_loop(s_tag)
		# Dry / range-hold click on fresh trigger pull (e.g. mortar inside min_range)
		if fresh_press and m != null and enabled and m.hold_reason != "":
			a.play_ui("ui.weapon.dry")
	# Guided missile laser designator lock tone
	var l_tag := _lock_tag()
	if rack.designator_on():
		a.start_loop(l_tag, "wpn.missiles.lock", false, Vector3.ZERO, 0.0, 1.0, bus)
	elif a.has_loop(l_tag):
		a.stop_loop(l_tag)


func _on_slot_changed(slot: int) -> void:
	if rack == null:
		return
	var idx := slot - 1
	if idx < 0 or idx >= rack.enabled.size():
		return
	var now_s := Time.get_ticks_msec() / 1000.0
	if _slot_batch_t < 0.0 or now_s - _slot_batch_t > 0.04:
		_slot_batch_t = now_s
		_slot_batch_count = 1
	else:
		_slot_batch_count += 1
	_slot_batch_last = slot
	_slot_batch_on = rack.enabled[idx]


func _flush_slot_audio(a: AudioDirector) -> void:
	if _slot_batch_count <= 0:
		return
	if _slot_batch_count >= 2:
		a.play_ui("ui.slot.solo")
	else:
		a.play_ui("ui.slot.on" if _slot_batch_on else "ui.slot.off")
	_slot_batch_count = 0
	_slot_batch_t = -1.0


func _on_weapon_dry() -> void:
	var a := AudioDirector.of(self)
	if a != null:
		a.play_ui("ui.weapon.dry")


func _on_fired(record: Dictionary) -> void:
	var a := AudioDirector.of(self)
	if a == null:
		return
	var w := str(record.get("weapon", ""))
	var shooter := str(record.get("shooter", ""))
	var origin: Vector3 = record.get("origin", Vector3.ZERO)
	var is_enemy := bool(record.get("enemy", false)) or str(record.get("team", "")) == "enemy" or shooter.begins_with("enemy")
	var is_local := (not is_enemy) and shooter == local_shooter
	var bus := AudioDirector.BUS_SFX_PLAYER if is_local else AudioDirector.BUS_SFX_WORLD
	var prof := "local_mech" if is_local else "weapon"
	var cue := _weapon_fire_cue(w)
	var pitch := 1.0
	if w == "rockets" or w == "enemy_rockets" or w == "enemy_gunship_rockets":
		# Walk pitch slightly across tubes so salvos ripple cleanly.
		var tube := posmod(int(record.get("shot_index", 0)), 6)
		pitch = 0.94 + float(tube) * 0.025
	elif w == "enemy_lance":
		pitch = 1.18
	elif w == "enemy_scatter":
		pitch = 0.82
	elif w == "enemy_troop_rifle":
		pitch = 1.28
	elif w == "enemy_troop_at":
		pitch = 1.08
	a.play_3d(cue, origin, 0.0, pitch, prof, bus)
	if is_enemy:
		a.play_3d("enemy.fire.accent", origin, -2.0, 1.0, "weapon", AudioDirector.BUS_SFX_WORLD)
		_enemy_fired_recent[shooter] = world.now if world != null else 0.0
	if a.music != null:
		a.music.bump_combat(0.08 if w == "gatling" else 0.16)


func _step_mortar_whistles(a: AudioDirector) -> void:
	var alive := {}
	for e: CombatEffect in world.effects:
		if not (e is MortarShell):
			continue
		var ms := e as MortarShell
		var id := ms.get_instance_id()
		alive[id] = true
		if ms.end_time >= 0.0 or _whistled_shells.has(id):
			continue
		var rem := ms.flight_time - ms.elapsed
		if rem <= MORTAR_WHISTLE_LEAD and rem > 0.1:
			_whistled_shells[id] = true
			var land := Vector3(ms.landing.x, ms.ring_y, ms.landing.z)
			a.play_3d("wpn.mortar.whistle", land, 0.0, clampf(1.25 / maxf(rem, 0.4), 0.8, 1.8), "telegraph", AudioDirector.BUS_SFX_TELEGRAPH)
	for id: int in _whistled_shells.keys():
		if not alive.has(id):
			_whistled_shells.erase(id)


# --- Impacts, Hits & Target States ----------------------------------------------------------------------

func _on_impact_spawned(point: Vector3, radius: float, explosive: bool, is_energy: bool) -> void:
	var a := AudioDirector.of(self)
	if a == null:
		return
	if is_energy:
		a.play_3d("impact.energy", point, 0.0, clampf(2.0 / maxf(radius, 0.5), 0.75, 1.3))
		return
	if explosive:
		if radius >= 4.5:
			a.play_3d("impact.explosive.large", point, clampf((radius - 6.0) * 0.5, -2.0, 3.0), clampf(6.0 / maxf(radius, 3.0), 0.75, 1.15))
			a.trigger_blast_duck(radius, point)
		else:
			a.play_3d("impact.explosive.med", point, 0.0, clampf(2.5 / maxf(radius, 1.2), 0.8, 1.25))
		return
	if radius < 1.3:
		a.play_3d("impact.small", point)
	else:
		a.play_3d("impact.medium", point, 0.0, clampf(1.6 / maxf(radius, 0.8), 0.8, 1.25))


## Fallback when CombatWorld.impact_spawned is not present yet (builds in parallel with Enemy subagent).
func _on_shake_fallback(strength: float, point: Vector3) -> void:
	if strength >= 4.5:
		_on_impact_spawned(point, strength, true, false)
	elif strength >= 2.2:
		_on_impact_spawned(point, strength, true, false)
	else:
		_on_impact_spawned(point, strength, false, false)


func _on_hit_landed(target: CombatTarget, hit: Hit) -> void:
	var a := AudioDirector.of(self)
	if a == null or hit == null:
		return
	if hit.shooter == local_shooter:
		var pt := clampf(0.95 + hit.damage * 0.004, 0.92, 1.25)
		a.play_2d("combat.hit.tick", 0.0, pt, AudioDirector.BUS_SFX_PLAYER)
		if target != null and is_instance_valid(target):
			_local_hits[target.target_id] = Time.get_ticks_msec()
	if target != null and is_instance_valid(target):
		_check_target_transitions(a, target, hit)


func _on_remote_hit(target_id: String, hit: Hit) -> void:
	var a := AudioDirector.of(self)
	if a != null and hit != null and hit.shooter == local_shooter:
		a.play_2d("combat.hit.tick", 0.0, 1.0, AudioDirector.BUS_SFX_PLAYER)
		_local_hits[target_id] = Time.get_ticks_msec()


## Squad hit-confirms (component_damaged / component_destroyed) are cockpit cues for this machine's pilot only: played
## when local_shooter hit that enemy within LOCAL_HIT_WINDOW_MS. Deferred to step() because the host's squad event fires
## inside apply_hit, before hit_landed tells us who shot.
func _flush_hit_marks(a: AudioDirector) -> void:
	if _pending_marks.is_empty():
		return
	var now := Time.get_ticks_msec()
	for m: Array in _pending_marks:
		var id := str(m[0])
		if _local_hits.has(id) and now - int(_local_hits[id]) <= LOCAL_HIT_WINDOW_MS:
			a.play_2d(str(m[1]), float(m[2]), float(m[3]), AudioDirector.BUS_SFX_PLAYER)
	_pending_marks.clear()
	for id: String in _local_hits.keys():
		if now - int(_local_hits[id]) > LOCAL_HIT_WINDOW_MS:
			_local_hits.erase(id)


func _queue_hit_mark(target_id: String, cue: String, db: float, pitch: float) -> void:
	if _pending_marks.size() < 32:
		_pending_marks.append([target_id, cue, db, pitch])


func _sync_targets() -> void:
	for t: CombatTarget in world.targets:
		if not is_instance_valid(t):
			continue
		var tid := t.get_instance_id()
		if _hooked_targets.has(tid):
			continue
		_hooked_targets[tid] = {"target": t, "hp": t.hp.duplicate(), "dead": t.destroyed()}
		if not t.staggered_by.is_connected(_on_target_staggered.bind(t)):
			t.staggered_by.connect(_on_target_staggered.bind(t))
		if not t.slammed.is_connected(_on_target_slammed.bind(t)):
			t.slammed.connect(_on_target_slammed.bind(t))
		if t.heat != null:
			if not t.heat.overheated.is_connected(_on_target_overheated.bind(t)):
				t.heat.overheated.connect(_on_target_overheated.bind(t))
			if not t.heat.rebooted.is_connected(_on_target_rebooted.bind(t)):
				t.heat.rebooted.connect(_on_target_rebooted.bind(t))
	for tid: int in _hooked_targets.keys():
		if not is_instance_valid(_hooked_targets[tid]["target"]):
			_hooked_targets.erase(tid)


func _check_target_transitions(a: AudioDirector, t: CombatTarget, hit: Hit) -> void:
	var tid := t.get_instance_id()
	if not _hooked_targets.has(tid):
		_sync_targets()
	var rec: Dictionary = _hooked_targets.get(tid, {})
	if rec.is_empty():
		return
	var prev_hp: Dictionary = rec["hp"]
	var comp := hit.component if t.hp.has(hit.component) else (str(t.hp.keys()[0]) if not t.hp.is_empty() else "")
	if comp != "" and float(prev_hp.get(comp, 0.0)) > 0.0 and float(t.hp.get(comp, 0.0)) <= 0.0:
		a.play_3d("combat.hit.break", hit.point)
		if hit.shooter == local_shooter:
			a.play_2d("combat.hit.break", -3.0, 1.05, AudioDirector.BUS_SFX_PLAYER)
	var now_dead := t.destroyed()
	if now_dead and not bool(rec["dead"]):
		a.play_3d("combat.kill", t.global_position)
		if hit.shooter == local_shooter:
			a.play_2d("combat.hit.weak", 1.0, 0.85, AudioDirector.BUS_SFX_PLAYER)
	rec["hp"] = t.hp.duplicate()
	rec["dead"] = now_dead


## W8 (Weapons, logged): a repair drone launch, the launcher's own or a crew member's (CombatNet replays it here).
func _on_drone_launched(_record: Dictionary, d: RepairDrone) -> void:
	var a := AudioDirector.of(self)
	if a == null or d == null:
		return
	a.play_3d("mech.thrust.ignite", d.pos, 0.0, 1.35, "weapon", AudioDirector.BUS_SFX_WORLD)


func _on_target_staggered(_src: String, t: CombatTarget) -> void:
	var a := AudioDirector.of(self)
	if a != null and is_instance_valid(t):
		a.play_3d("combat.stagger", t.global_position)


func _on_target_slammed(speed: float, _dmg: float, t: CombatTarget) -> void:
	var a := AudioDirector.of(self)
	if a != null and is_instance_valid(t):
		var db := clampf((speed - 5.0) * 0.4, -2.0, 3.0)
		a.play_3d("combat.wall_slam", t.global_position, db)


func _on_target_overheated(t: CombatTarget) -> void:
	var a := AudioDirector.of(self)
	if a != null and is_instance_valid(t):
		a.play_3d("enemy.overheat", t.global_position)


func _on_target_rebooted(t: CombatTarget) -> void:
	var a := AudioDirector.of(self)
	if a != null and is_instance_valid(t):
		a.play_3d("enemy.reboot", t.global_position)


# --- Street Props ---------------------------------------------------------------------------------------

func _on_prop_moved(_id: int, type: String, kind: int, world_pos: Vector3, speed: float) -> void:
	var a := AudioDirector.of(self)
	if a == null:
		return
	var mat := "metal"
	match type:
		"tree": mat = "tree"
		"bench": mat = "bench"
		"bin": mat = "bin"
	var action := "topple" if kind == CityPropSim.TOPPLE else "shove"
	var db := clampf((speed - 2.0) * 1.2, -4.0, 2.0) if action == "shove" else 0.0
	a.play_3d("prop.%s.%s" % [mat, action], world_pos, db)


# --- EnemySquad & PlayerTarget Contract (docs/design/audio.md §4) ---------------------------------------

func _on_enemy_event(kind: String, _enemy: Node, payload: Dictionary) -> void:
	var a := AudioDirector.of(self)
	if a == null:
		return
	var id := str(payload.get("id", ""))
	var pos: Vector3 = payload.get("pos", Vector3.ZERO)
	match kind:
		"telegraph_started":
			var tk := str(payload.get("kind", "generic"))
			var dur := float(payload.get("duration", 0.55))
			# Diegetic-only rule: play physical weapon charge-up sounds (beam/lance/cannon/pulse) and the Scout
			# Drone's real Alert Beacon support siren; skip non-diegetic warning beeps on ballistic/rocket/rifle fire.
			if tk == "beacon":
				a.play_enemy_telegraph(id, _telegraph_audio_kind(tk), pos, dur)
				a.play_enemy_alert("relay", pos)
			elif tk in ["beam", "lance", "cannon", "pulse"]:
				a.play_enemy_telegraph(id, _telegraph_audio_kind(tk), pos, dur)
			if a.music != null:
				a.music.bump_combat(0.20)
		"telegraph_cancelled":
			a.cancel_enemy_telegraph(id)
		"alerted":
			var st := str(payload.get("state", "spotted"))
			if st.begins_with("deck:"):
				return
			if st == "revealed":
				# Subtle 3D physical signal-flare pop from the straggler's own location (no 2D HUD alarm beep).
				a.play_3d("wpn.mortar.fire", pos, -10.0, 1.75, "weapon", AudioDirector.BUS_SFX_WORLD)
				_reveal_ping_t = EnemyTelegraphFx.FLARE_INTERVAL
			if a.music != null and (st == "spotted" or st == "relay"):
				a.music.bump_combat(0.25)
		"weapon_fired":
			# Deduplicate if world.fired already handled this enemy's shot this step.
			var now_t := world.now if world != null else 0.0
			if _enemy_fired_recent.has(id) and absf(now_t - float(_enemy_fired_recent[id])) < 0.05:
				return
			var w := str(payload.get("weapon", "autocannon"))
			var cue := _weapon_fire_cue(w)
			a.play_3d(cue, pos, 0.0, 1.0, "weapon", AudioDirector.BUS_SFX_WORLD)
			a.play_3d("enemy.fire.accent", pos, -2.0, 1.0, "weapon", AudioDirector.BUS_SFX_WORLD)
			if a.music != null:
				a.music.bump_combat(0.16)
		"component_damaged":
			var weak := bool(payload.get("weak_point", false))
			_queue_hit_mark(id, "combat.hit.weak" if weak else "combat.hit.tick", 0.0, 1.0)
		"component_destroyed":
			a.play_3d("combat.hit.break", pos)
			_queue_hit_mark(id, "combat.hit.break", -3.0, 1.05)
		"overheated":
			a.play_3d("enemy.overheat", pos)
		"rebooted":
			a.play_3d("enemy.reboot", pos)
		"destroyed":
			var rad := float(payload.get("radius", 3.5))
			a.play_3d("enemy.destroyed", pos)
			if rad >= 4.5:
				a.trigger_blast_duck(rad, pos)
		"footstep":
			a.play_3d("enemy.step", pos)


func _on_player_damaged(amount: float, _component: String, _src: String) -> void:
	var a := AudioDirector.of(self)
	if a != null:
		var db := clampf((amount - 15.0) * 0.08, -3.0, 2.5)
		a.play_2d("combat.player.damaged", db, 1.0, AudioDirector.BUS_SFX_PLAYER)
		if a.music != null:
			a.music.bump_combat(0.22)


func _on_player_staggered(_src: String) -> void:
	var a := AudioDirector.of(self)
	if a != null:
		a.play_2d("combat.stagger", 0.0, 0.92, AudioDirector.BUS_SFX_PLAYER)


func _on_player_part_lost(_component: String) -> void:
	var a := AudioDirector.of(self)
	if a != null:
		a.play_2d("combat.player.part_lost", 0.0, 1.0, AudioDirector.BUS_SFX_TELEGRAPH)


func _on_player_disabled(_cause: String) -> void:
	var a := AudioDirector.of(self)
	if a != null:
		a.play_2d("combat.player.disabled", 0.0, 1.0, AudioDirector.BUS_SFX_TELEGRAPH)


func _step_reveal_pings(a: AudioDirector, delta: float) -> void:
	if squad == null or not is_instance_valid(squad):
		return
	_reveal_ping_t -= delta
	if _reveal_ping_t > 0.0:
		return
	var list: Variant = squad.get("enemies")
	if not (list is Array):
		_reveal_ping_t = 0.5
		return
	var any_rev := false
	var nearest_pos := Vector3.ZERO
	var best_d2 := INF
	var ref_p := Vector3.ZERO
	if player_target != null and is_instance_valid(player_target) and player_target is Node3D and (player_target as Node3D).is_inside_tree():
		ref_p = (player_target as Node3D).global_position
	for e: Variant in list:
		if e is EnemyBase and is_instance_valid(e) and not (e as EnemyBase).destroyed() and (e as EnemyBase).revealed:
			any_rev = true
			var ep := (e as EnemyBase).global_position if (e as EnemyBase).is_inside_tree() else (e as EnemyBase).position
			var d2 := ref_p.distance_squared_to(ep)
			if d2 < best_d2:
				best_d2 = d2
				nearest_pos = ep
	if not any_rev:
		_reveal_ping_t = 0.5
		return
	_reveal_ping_t = EnemyTelegraphFx.FLARE_INTERVAL
	# Subtle 3D physical flare launch pop from the nearest revealed straggler (no radar chime).
	a.play_3d("wpn.mortar.fire", nearest_pos, -11.0, 1.75, "weapon", AudioDirector.BUS_SFX_WORLD)


func _charge_tag(slot_idx: int) -> String:
	return "wpn.charge.%d.%d" % [get_instance_id(), slot_idx]


func _spin_tag(slot_idx: int) -> String:
	return "wpn.spin.%d.%d" % [get_instance_id(), slot_idx]


func _lock_tag() -> String:
	return "wpn.lock.%d" % get_instance_id()


func _weapon_fire_cue(w: String) -> String:
	match w:
		"enemy_lance": return "wpn.railgun.fire"
		"enemy_rockets", "enemy_troop_at", "enemy_gunship_rockets": return "wpn.rockets.fire"
		"enemy_scatter", "enemy_troop_rifle": return "wpn.autocannon.fire"
	var cue := "wpn." + w + ".fire"
	return cue if SoundBank.has_cue(cue) else "wpn.autocannon.fire"


func _telegraph_audio_kind(tk: String) -> String:
	match tk:
		"lance": return "beam"
		"salvo", "troop_at", "gunship_salvo": return "mortar"
		"scatter", "troop_rifle": return "rush"
		"beacon", "dropship": return "pulse"
	return tk
