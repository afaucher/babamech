class_name SoundBank
extends RefCounted
## Declarative catalog & deterministic AudioStreamWAV cache (docs/design/audio.md §2).
## Two-tier lookup: loads res://assets/audio/<id>.res if pre-baked, else synthesizes lazily via AudioSynth and caches
## in memory. Supports incremental frame-budgeted prewarming (`prewarm_step`) so runtime has zero first-shot hitches
## and zero binary bloat in git. Strictly cosmetic (Net LOCAL), zero global randomness.

const BAKED_DIR := "res://assets/audio/"

## Cue metadata:
##   bus: AudioServer bus name
##   db: nominal gain offset (dB)
##   jitter: pitch random jitter +/- fraction (drawn from AudioDirector.looks_rng)
##   priority: 0 prop/foley | 1 weapon/impact/step | 2 local player/heavy blast | 3 telegraph/alarm
##   cooldown_ms: minimum ms between plays of this cue
##   max_voices: maximum simultaneous voices of this cue
##   profile: 3D attenuation profile ("foley"|"local_mech"|"weapon"|"explosion"|"telegraph"|"2d")
##   loop: true for continuous looping beds/stems
const SPECS := {
	# --- Mech locomotion & physics ---
	"mech.step.concrete": {"bus": "SFX_Player", "db": -3.0, "jitter": 0.08, "priority": 1, "cooldown_ms": 60, "max_voices": 4, "profile": "local_mech", "loop": false},
	"mech.step.grass": {"bus": "SFX_Player", "db": -4.0, "jitter": 0.09, "priority": 1, "cooldown_ms": 60, "max_voices": 4, "profile": "local_mech", "loop": false},
	"mech.step.rooftop": {"bus": "SFX_Player", "db": -2.5, "jitter": 0.07, "priority": 1, "cooldown_ms": 60, "max_voices": 4, "profile": "local_mech", "loop": false},
	"mech.servo.step": {"bus": "SFX_Player", "db": -14.0, "jitter": 0.10, "priority": 0, "cooldown_ms": 110, "max_voices": 3, "profile": "local_mech", "loop": false},
	"mech.servo.turn": {"bus": "SFX_Player", "db": -16.0, "jitter": 0.06, "priority": 0, "cooldown_ms": 220, "max_voices": 2, "profile": "local_mech", "loop": false},
	"mech.thrust.ignite": {"bus": "SFX_Player", "db": -2.0, "jitter": 0.05, "priority": 2, "cooldown_ms": 120, "max_voices": 3, "profile": "local_mech", "loop": false},
	"mech.thrust.loop": {"bus": "SFX_Player", "db": -5.0, "jitter": 0.0, "priority": 2, "cooldown_ms": 0, "max_voices": 4, "profile": "local_mech", "loop": true},
	"mech.thrust.emergency": {"bus": "SFX_Telegraph", "db": -2.0, "jitter": 0.0, "priority": 3, "cooldown_ms": 300, "max_voices": 2, "profile": "2d", "loop": false},
	"mech.land.soft": {"bus": "SFX_Player", "db": -4.0, "jitter": 0.06, "priority": 1, "cooldown_ms": 120, "max_voices": 3, "profile": "local_mech", "loop": false},
	"mech.land.hard": {"bus": "SFX_Player", "db": 0.0, "jitter": 0.05, "priority": 2, "cooldown_ms": 120, "max_voices": 3, "profile": "local_mech", "loop": false},

	# --- Heat & shutdown ---
	"mech.heat.loop": {"bus": "SFX_Player", "db": -8.0, "jitter": 0.0, "priority": 2, "cooldown_ms": 0, "max_voices": 2, "profile": "2d", "loop": true},
	"mech.heat.tick": {"bus": "SFX_Telegraph", "db": -5.0, "jitter": 0.0, "priority": 3, "cooldown_ms": 90, "max_voices": 2, "profile": "2d", "loop": false},
	"mech.heat.shutdown": {"bus": "SFX_Telegraph", "db": -1.0, "jitter": 0.0, "priority": 3, "cooldown_ms": 250, "max_voices": 2, "profile": "2d", "loop": false},
	"mech.heat.reboot_spool": {"bus": "SFX_Player", "db": -4.0, "jitter": 0.0, "priority": 2, "cooldown_ms": 250, "max_voices": 2, "profile": "2d", "loop": false},
	"mech.heat.reboot_ok": {"bus": "SFX_Player", "db": -2.0, "jitter": 0.0, "priority": 2, "cooldown_ms": 200, "max_voices": 2, "profile": "2d", "loop": false},

	# --- Subtle deadpan pilot cues (radio bandpass 600-2200 Hz, -10 dB) ---
	"pilot.chicken": {"bus": "SFX_Player", "db": -10.0, "jitter": 0.04, "priority": 2, "cooldown_ms": 1500, "max_voices": 1, "profile": "2d", "loop": false},
	"pilot.pickle": {"bus": "SFX_Player", "db": -10.0, "jitter": 0.04, "priority": 2, "cooldown_ms": 1500, "max_voices": 1, "profile": "2d", "loop": false},
	"pilot.corn": {"bus": "SFX_Player", "db": -10.0, "jitter": 0.04, "priority": 2, "cooldown_ms": 1500, "max_voices": 1, "profile": "2d", "loop": false},
	"pilot.dog": {"bus": "SFX_Player", "db": -10.0, "jitter": 0.04, "priority": 2, "cooldown_ms": 1500, "max_voices": 1, "profile": "2d", "loop": false},

	# --- Active weapons ---
	"wpn.laser.charge": {"bus": "SFX_Player", "db": -6.0, "jitter": 0.02, "priority": 2, "cooldown_ms": 0, "max_voices": 4, "profile": "weapon", "loop": true},
	"wpn.laser.fire": {"bus": "SFX_Player", "db": -1.5, "jitter": 0.05, "priority": 2, "cooldown_ms": 50, "max_voices": 4, "profile": "weapon", "loop": false},
	"wpn.autocannon.fire": {"bus": "SFX_Player", "db": -1.0, "jitter": 0.06, "priority": 2, "cooldown_ms": 55, "max_voices": 5, "profile": "weapon", "loop": false},
	"wpn.gatling.spin_loop": {"bus": "SFX_Player", "db": -9.0, "jitter": 0.0, "priority": 1, "cooldown_ms": 0, "max_voices": 4, "profile": "weapon", "loop": true},
	"wpn.gatling.fire": {"bus": "SFX_Player", "db": -4.0, "jitter": 0.08, "priority": 1, "cooldown_ms": 65, "max_voices": 4, "profile": "weapon", "loop": false},
	"wpn.rockets.fire": {"bus": "SFX_Player", "db": -2.5, "jitter": 0.05, "priority": 1, "cooldown_ms": 55, "max_voices": 4, "profile": "weapon", "loop": false},
	"wpn.mortar.fire": {"bus": "SFX_Player", "db": -1.0, "jitter": 0.04, "priority": 2, "cooldown_ms": 120, "max_voices": 4, "profile": "weapon", "loop": false},
	"wpn.mortar.whistle": {"bus": "SFX_Telegraph", "db": -2.0, "jitter": 0.02, "priority": 3, "cooldown_ms": 120, "max_voices": 4, "profile": "telegraph", "loop": false},

	# --- Paused weapons (placeholder-ready) ---
	"wpn.flamer.ignite": {"bus": "SFX_Player", "db": -4.0, "jitter": 0.06, "priority": 1, "cooldown_ms": 100, "max_voices": 3, "profile": "weapon", "loop": false},
	"wpn.flamer.loop": {"bus": "SFX_Player", "db": -6.0, "jitter": 0.0, "priority": 1, "cooldown_ms": 0, "max_voices": 3, "profile": "weapon", "loop": true},
	"wpn.missiles.fire": {"bus": "SFX_Player", "db": -2.0, "jitter": 0.05, "priority": 1, "cooldown_ms": 60, "max_voices": 4, "profile": "weapon", "loop": false},
	"wpn.missiles.lock": {"bus": "SFX_Player", "db": -9.0, "jitter": 0.0, "priority": 1, "cooldown_ms": 0, "max_voices": 2, "profile": "2d", "loop": true},
	"wpn.railgun.charge": {"bus": "SFX_Player", "db": -4.0, "jitter": 0.0, "priority": 2, "cooldown_ms": 0, "max_voices": 2, "profile": "weapon", "loop": false},
	"wpn.railgun.fire": {"bus": "SFX_Player", "db": 0.0, "jitter": 0.03, "priority": 2, "cooldown_ms": 150, "max_voices": 3, "profile": "explosion", "loop": false},
	"wpn.swivel.fire": {"bus": "SFX_Player", "db": -3.0, "jitter": 0.07, "priority": 1, "cooldown_ms": 55, "max_voices": 4, "profile": "weapon", "loop": false},

	# --- Combat hit-confirms, target feedback & impacts ---
	"combat.hit.tick": {"bus": "SFX_Player", "db": -5.0, "jitter": 0.05, "priority": 2, "cooldown_ms": 40, "max_voices": 3, "profile": "2d", "loop": false},
	"combat.hit.weak": {"bus": "SFX_Player", "db": -3.0, "jitter": 0.04, "priority": 2, "cooldown_ms": 45, "max_voices": 3, "profile": "2d", "loop": false},
	"combat.hit.break": {"bus": "SFX_Player", "db": -1.5, "jitter": 0.04, "priority": 2, "cooldown_ms": 70, "max_voices": 3, "profile": "weapon", "loop": false},
	"combat.stagger": {"bus": "SFX_World", "db": -1.0, "jitter": 0.05, "priority": 2, "cooldown_ms": 100, "max_voices": 4, "profile": "weapon", "loop": false},
	"combat.wall_slam": {"bus": "SFX_World", "db": 0.0, "jitter": 0.06, "priority": 2, "cooldown_ms": 80, "max_voices": 4, "profile": "weapon", "loop": false},
	"combat.kill": {"bus": "SFX_World", "db": 0.0, "jitter": 0.05, "priority": 2, "cooldown_ms": 90, "max_voices": 4, "profile": "explosion", "loop": false},
	"combat.player.damaged": {"bus": "SFX_Player", "db": -2.0, "jitter": 0.06, "priority": 2, "cooldown_ms": 90, "max_voices": 3, "profile": "2d", "loop": false},
	"combat.player.part_lost": {"bus": "SFX_Telegraph", "db": 0.0, "jitter": 0.0, "priority": 3, "cooldown_ms": 200, "max_voices": 2, "profile": "2d", "loop": false},
	"combat.player.disabled": {"bus": "SFX_Telegraph", "db": 0.0, "jitter": 0.0, "priority": 3, "cooldown_ms": 300, "max_voices": 1, "profile": "2d", "loop": false},
	"impact.small": {"bus": "SFX_World", "db": -5.0, "jitter": 0.12, "priority": 1, "cooldown_ms": 40, "max_voices": 6, "profile": "weapon", "loop": false},
	"impact.medium": {"bus": "SFX_World", "db": -3.0, "jitter": 0.09, "priority": 1, "cooldown_ms": 40, "max_voices": 6, "profile": "weapon", "loop": false},
	"impact.energy": {"bus": "SFX_World", "db": -2.5, "jitter": 0.08, "priority": 1, "cooldown_ms": 45, "max_voices": 5, "profile": "weapon", "loop": false},
	"impact.explosive.med": {"bus": "SFX_World", "db": -1.0, "jitter": 0.08, "priority": 2, "cooldown_ms": 50, "max_voices": 5, "profile": "explosion", "loop": false},
	"impact.explosive.large": {"bus": "SFX_World", "db": 0.5, "jitter": 0.05, "priority": 2, "cooldown_ms": 80, "max_voices": 4, "profile": "explosion", "loop": false},

	# --- Destructible street props ---
	"prop.tree.topple": {"bus": "SFX_World", "db": -4.0, "jitter": 0.10, "priority": 0, "cooldown_ms": 50, "max_voices": 4, "profile": "foley", "loop": false},
	"prop.tree.shove": {"bus": "SFX_World", "db": -7.0, "jitter": 0.10, "priority": 0, "cooldown_ms": 60, "max_voices": 3, "profile": "foley", "loop": false},
	"prop.metal.topple": {"bus": "SFX_World", "db": -4.0, "jitter": 0.10, "priority": 0, "cooldown_ms": 50, "max_voices": 4, "profile": "foley", "loop": false},
	"prop.metal.shove": {"bus": "SFX_World", "db": -7.0, "jitter": 0.12, "priority": 0, "cooldown_ms": 60, "max_voices": 3, "profile": "foley", "loop": false},
	"prop.bench.topple": {"bus": "SFX_World", "db": -5.0, "jitter": 0.10, "priority": 0, "cooldown_ms": 50, "max_voices": 4, "profile": "foley", "loop": false},
	"prop.bench.shove": {"bus": "SFX_World", "db": -8.0, "jitter": 0.10, "priority": 0, "cooldown_ms": 60, "max_voices": 3, "profile": "foley", "loop": false},
	"prop.bin.topple": {"bus": "SFX_World", "db": -5.0, "jitter": 0.14, "priority": 0, "cooldown_ms": 50, "max_voices": 4, "profile": "foley", "loop": false},
	"prop.bin.shove": {"bus": "SFX_World", "db": -7.0, "jitter": 0.14, "priority": 0, "cooldown_ms": 55, "max_voices": 4, "profile": "foley", "loop": false},

	# --- Enemy audio & >=0.3s telegraphs ---
	"enemy.telegraph.beam": {"bus": "SFX_Telegraph", "db": 0.0, "jitter": 0.02, "priority": 3, "cooldown_ms": 40, "max_voices": 6, "profile": "telegraph", "loop": false},
	"enemy.telegraph.cannon": {"bus": "SFX_Telegraph", "db": 0.0, "jitter": 0.02, "priority": 3, "cooldown_ms": 40, "max_voices": 6, "profile": "telegraph", "loop": false},
	"enemy.telegraph.mortar": {"bus": "SFX_Telegraph", "db": 0.0, "jitter": 0.02, "priority": 3, "cooldown_ms": 40, "max_voices": 6, "profile": "telegraph", "loop": false},
	"enemy.telegraph.pulse": {"bus": "SFX_Telegraph", "db": 0.0, "jitter": 0.02, "priority": 3, "cooldown_ms": 40, "max_voices": 6, "profile": "telegraph", "loop": false},
	"enemy.telegraph.rush": {"bus": "SFX_Telegraph", "db": 0.0, "jitter": 0.02, "priority": 3, "cooldown_ms": 40, "max_voices": 6, "profile": "telegraph", "loop": false},
	"enemy.telegraph.generic": {"bus": "SFX_Telegraph", "db": 0.0, "jitter": 0.02, "priority": 3, "cooldown_ms": 40, "max_voices": 6, "profile": "telegraph", "loop": false},
	"enemy.fire.accent": {"bus": "SFX_World", "db": -4.0, "jitter": 0.06, "priority": 1, "cooldown_ms": 50, "max_voices": 5, "profile": "weapon", "loop": false},
	"enemy.alert.spotted": {"bus": "SFX_Telegraph", "db": -3.0, "jitter": 0.03, "priority": 3, "cooldown_ms": 180, "max_voices": 3, "profile": "telegraph", "loop": false},
	"enemy.alert.relay": {"bus": "SFX_World", "db": -4.0, "jitter": 0.04, "priority": 2, "cooldown_ms": 180, "max_voices": 3, "profile": "weapon", "loop": false},
	"enemy.alert.search": {"bus": "SFX_World", "db": -7.0, "jitter": 0.04, "priority": 1, "cooldown_ms": 300, "max_voices": 2, "profile": "weapon", "loop": false},
	"enemy.alert.lost": {"bus": "SFX_World", "db": -8.0, "jitter": 0.04, "priority": 1, "cooldown_ms": 300, "max_voices": 2, "profile": "weapon", "loop": false},
	"enemy.step": {"bus": "SFX_World", "db": -6.0, "jitter": 0.10, "priority": 0, "cooldown_ms": 80, "max_voices": 5, "profile": "foley", "loop": false},
	"enemy.overheat": {"bus": "SFX_World", "db": -2.0, "jitter": 0.04, "priority": 2, "cooldown_ms": 150, "max_voices": 3, "profile": "weapon", "loop": false},
	"enemy.reboot": {"bus": "SFX_World", "db": -4.0, "jitter": 0.04, "priority": 1, "cooldown_ms": 150, "max_voices": 3, "profile": "weapon", "loop": false},
	"enemy.destroyed": {"bus": "SFX_World", "db": 0.0, "jitter": 0.05, "priority": 2, "cooldown_ms": 80, "max_voices": 4, "profile": "explosion", "loop": false},

	# --- UI & Hangar ---
	"ui.hover": {"bus": "SFX_UI", "db": -12.0, "jitter": 0.02, "priority": 1, "cooldown_ms": 35, "max_voices": 2, "profile": "2d", "loop": false},
	"ui.click": {"bus": "SFX_UI", "db": -4.0, "jitter": 0.02, "priority": 2, "cooldown_ms": 35, "max_voices": 3, "profile": "2d", "loop": false},
	"ui.back": {"bus": "SFX_UI", "db": -5.0, "jitter": 0.02, "priority": 2, "cooldown_ms": 35, "max_voices": 2, "profile": "2d", "loop": false},
	"ui.slider": {"bus": "SFX_UI", "db": -10.0, "jitter": 0.02, "priority": 1, "cooldown_ms": 60, "max_voices": 2, "profile": "2d", "loop": false},
	"ui.hangar.mount": {"bus": "SFX_UI", "db": -2.0, "jitter": 0.03, "priority": 2, "cooldown_ms": 60, "max_voices": 2, "profile": "2d", "loop": false},
	"ui.hangar.unmount": {"bus": "SFX_UI", "db": -4.0, "jitter": 0.03, "priority": 2, "cooldown_ms": 60, "max_voices": 2, "profile": "2d", "loop": false},
	"ui.hangar.alert": {"bus": "SFX_Telegraph", "db": -2.0, "jitter": 0.0, "priority": 3, "cooldown_ms": 200, "max_voices": 2, "profile": "2d", "loop": false},
	"ui.slot.on": {"bus": "SFX_UI", "db": -4.0, "jitter": 0.0, "priority": 2, "cooldown_ms": 30, "max_voices": 3, "profile": "2d", "loop": false},
	"ui.slot.off": {"bus": "SFX_UI", "db": -5.0, "jitter": 0.0, "priority": 2, "cooldown_ms": 30, "max_voices": 3, "profile": "2d", "loop": false},
	"ui.slot.solo": {"bus": "SFX_UI", "db": -3.0, "jitter": 0.0, "priority": 2, "cooldown_ms": 40, "max_voices": 2, "profile": "2d", "loop": false},
	"ui.weapon.dry": {"bus": "SFX_UI", "db": -4.0, "jitter": 0.05, "priority": 1, "cooldown_ms": 250, "max_voices": 2, "profile": "2d", "loop": false},

	# --- Habitat ambience & adaptive music ---
	"amb.city.bed": {"bus": "Ambience", "db": -12.0, "jitter": 0.0, "priority": 1, "cooldown_ms": 0, "max_voices": 1, "profile": "2d", "loop": true},
	"amb.hangar.bed": {"bus": "Ambience", "db": -11.0, "jitter": 0.0, "priority": 1, "cooldown_ms": 0, "max_voices": 1, "profile": "2d", "loop": true},
	"amb.city.pa_chime": {"bus": "Ambience", "db": -13.0, "jitter": 0.02, "priority": 0, "cooldown_ms": 4000, "max_voices": 1, "profile": "2d", "loop": false},
	"amb.city.creak": {"bus": "Ambience", "db": -15.0, "jitter": 0.08, "priority": 0, "cooldown_ms": 4000, "max_voices": 1, "profile": "2d", "loop": false},
	"amb.city.breeze": {"bus": "Ambience", "db": -14.0, "jitter": 0.08, "priority": 0, "cooldown_ms": 3000, "max_voices": 1, "profile": "2d", "loop": false},
	"music.hangar": {"bus": "Music", "db": -7.0, "jitter": 0.0, "priority": 1, "cooldown_ms": 0, "max_voices": 1, "profile": "2d", "loop": true},
	"music.calm": {"bus": "Music", "db": -7.0, "jitter": 0.0, "priority": 1, "cooldown_ms": 0, "max_voices": 1, "profile": "2d", "loop": true},
	"music.combat": {"bus": "Music", "db": -6.0, "jitter": 0.0, "priority": 1, "cooldown_ms": 0, "max_voices": 1, "profile": "2d", "loop": true},
}

## Prewarm order: short frequently-used gameplay SFX first; long music/ambience stems synthesize when requested.
const PREWARM_PRIORITY := [
	"ui.hover", "ui.click", "ui.back", "ui.hangar.mount", "ui.hangar.unmount", "ui.slot.on", "ui.slot.off", "ui.weapon.dry",
	"mech.step.concrete", "mech.step.grass", "mech.step.rooftop", "mech.servo.step", "mech.thrust.ignite", "mech.thrust.loop",
	"mech.land.soft", "mech.land.hard", "mech.heat.tick", "mech.heat.shutdown", "mech.heat.reboot_ok",
	"wpn.autocannon.fire", "wpn.laser.fire", "wpn.gatling.fire", "wpn.rockets.fire", "wpn.mortar.fire",
	"combat.hit.tick", "combat.hit.break", "combat.stagger", "combat.wall_slam", "combat.kill",
	"impact.small", "impact.medium", "impact.energy", "impact.explosive.med", "impact.explosive.large",
	"enemy.telegraph.beam", "enemy.telegraph.cannon", "enemy.telegraph.mortar", "enemy.telegraph.pulse",
	"enemy.alert.spotted", "enemy.alert.relay", "enemy.destroyed",
]

var _cache: Dictionary = {}         ## cue_id -> AudioStreamWAV
var _prewarm_idx := 0
var _async_mutex := Mutex.new()
var _async_ready: Dictionary = {}   ## worker-synthesized streams waiting for main-thread drain
var _async_tasks: Array[int] = []
var _async_started := false
var _async_stop := false


static func all_ids() -> Array[String]:
	var out: Array[String] = []
	for k: String in SPECS.keys():
		out.append(k)
	out.sort()
	return out


static func has_cue(cue_id: String) -> bool:
	return SPECS.has(cue_id)


static func spec(cue_id: String) -> Dictionary:
	return SPECS.get(cue_id, {})


func clear_cache() -> void:
	_cache.clear()
	_prewarm_idx = 0


## Two-tier lookup: baked res://assets/audio/<id>.res if present, else cached runtime AudioSynth stream.
func get_stream(cue_id: String) -> AudioStreamWAV:
	if _cache.has(cue_id):
		return _cache[cue_id]
	if not SPECS.has(cue_id):
		return null
	var baked := BAKED_DIR + cue_id.replace(".", "_") + ".res"
	if ResourceLoader.exists(baked):
		var res := load(baked) as AudioStreamWAV
		if res != null:
			_cache[cue_id] = res
			return res
	var wav := synthesize(cue_id)
	_cache[cue_id] = wav
	return wav


## Synthesize one cue per frame up to `budget_ms` (sync helper used by tests).
func prewarm_step(budget_ms: float = 2.0) -> int:
	if _prewarm_idx >= PREWARM_PRIORITY.size():
		return 0
	var t0 := Time.get_ticks_usec()
	var built := 0
	while _prewarm_idx < PREWARM_PRIORITY.size():
		var cid: String = PREWARM_PRIORITY[_prewarm_idx]
		_prewarm_idx += 1
		if not _cache.has(cid):
			get_stream(cid)
			built += 1
		if float(Time.get_ticks_usec() - t0) / 1000.0 >= budget_ms:
			break
	return built


## True while the async prewarm (start_async_prewarm) has been launched and not stopped.
func is_async_started() -> bool:
	return _async_started


## Launch parallel WorkerThreadPool tasks to synthesize every cue off the main thread (~0.35 s wall, 0.0 ms hitch).
func start_async_prewarm(workers: int = 4) -> void:
	if _async_started:
		return
	_async_started = true
	_async_stop = false
	var ordered: Array[String] = []
	var seen := {}
	for cid: String in PREWARM_PRIORITY:
		if SPECS.has(cid) and not _cache.has(cid) and not seen.has(cid):
			ordered.append(cid)
			seen[cid] = true
	for cid: String in ["amb.city.bed", "music.calm", "music.combat", "amb.hangar.bed", "music.hangar"]:
		if SPECS.has(cid) and not _cache.has(cid) and not seen.has(cid):
			ordered.append(cid)
			seen[cid] = true
	for cid: String in all_ids():
		if not _cache.has(cid) and not seen.has(cid):
			ordered.append(cid)
			seen[cid] = true
	if ordered.is_empty():
		return
	var n := clampi(workers, 1, 6)
	var buckets: Array = []
	for _i in n:
		buckets.append([] as Array[String])
	for i in ordered.size():
		(buckets[i % n] as Array[String]).append(ordered[i])
	for b: Array[String] in buckets:
		if b.is_empty():
			continue
		var tid := WorkerThreadPool.add_task(_worker_build.bind(b), false, "SoundBankPrewarm")
		_async_tasks.append(tid)


func _worker_build(ids: Array[String]) -> void:
	for cid: String in ids:
		if _async_stop:
			return
		var wav := synthesize(cid)
		if wav == null:
			continue
		_async_mutex.lock()
		_async_ready[cid] = wav
		_async_mutex.unlock()


## Non-blocking main-thread drain of worker-finished streams (< 0.01 ms).
func drain_async() -> int:
	if not _async_started:
		return 0
	var moved := 0
	if _async_mutex.try_lock():
		if not _async_ready.is_empty():
			for cid: String in _async_ready.keys():
				_cache[cid] = _async_ready[cid]
				moved += 1
			_async_ready.clear()
		_async_mutex.unlock()
	var i := _async_tasks.size() - 1
	while i >= 0:
		if WorkerThreadPool.is_task_completed(_async_tasks[i]):
			WorkerThreadPool.wait_for_task_completion(_async_tasks[i])
			_async_tasks.remove_at(i)
		i -= 1
	return moved


## Non-blocking stream lookup for live gameplay: returns cached/baked stream or null if background worker is still building it.
func get_stream_nonblocking(cue_id: String) -> AudioStreamWAV:
	if _cache.has(cue_id):
		return _cache[cue_id]
	drain_async()
	if _cache.has(cue_id):
		return _cache[cue_id]
	if not SPECS.has(cue_id):
		return null
	var baked := BAKED_DIR + cue_id.replace(".", "_") + ".res"
	if ResourceLoader.exists(baked):
		var res := load(baked) as AudioStreamWAV
		if res != null:
			_cache[cue_id] = res
			return res
	if _async_started and not _async_tasks.is_empty():
		return null   # never freeze the main thread: worker task will populate _cache in milliseconds
	return get_stream(cue_id)


func shutdown_async() -> void:
	_async_stop = true
	for tid: int in _async_tasks:
		WorkerThreadPool.wait_for_task_completion(tid)
	_async_tasks.clear()
	drain_async()
	_async_started = false


## Pure deterministic synthesis for `cue_id` (ignores cache; used by tests and tools/audio/gen_audio.gd).
static func synthesize(cue_id: String) -> AudioStreamWAV:
	var sr := AudioSynth.SR_CRISP if cue_id.begins_with("ui.") else AudioSynth.SR_DEFAULT
	var rng := AudioSynth.make_rng(hash("babamech_sfx|" + cue_id) & 0x7FFFFFFF)
	match cue_id:
		# --- Mech footsteps & servos ---
		"mech.step.concrete":
			var b := AudioSynth.buf(0.24, sr)
			AudioSynth.add_tone(b, sr, 0.0, 0.16, 72.0, 28.0, "sub", 0.9, 0.002, 0.12)
			AudioSynth.add_noise(b, sr, 0.0, 0.07, rng, 0.55, 0.002, 0.05, "bp", 900.0, 320.0, 1.4)
			AudioSynth.add_fm(b, sr, 0.005, 0.08, 190.0, 110.0, 2.3, 3.0, 0.4, 0.35, 0.002, 0.06)
			AudioSynth.add_click(b, sr, 0.0, 0.35, 1600.0)
			AudioSynth.saturate(b, 1.5)
			AudioSynth.normalize(b, 0.92)
			return AudioSynth.to_wav(b, sr)
		"mech.step.grass":
			var b := AudioSynth.buf(0.26, sr)
			AudioSynth.add_tone(b, sr, 0.0, 0.15, 58.0, 24.0, "sine", 0.85, 0.004, 0.11)
			AudioSynth.add_noise(b, sr, 0.0, 0.14, rng, 0.48, 0.006, 0.10, "bp", 2200.0, 900.0, 0.9)
			AudioSynth.add_noise(b, sr, 0.0, 0.10, rng, 0.45, 0.003, 0.08, "lp", 360.0, 160.0, 1.1)
			AudioSynth.normalize(b, 0.88)
			return AudioSynth.to_wav(b, sr)
		"mech.step.rooftop":
			var b := AudioSynth.buf(0.28, sr)
			AudioSynth.add_tone(b, sr, 0.0, 0.18, 68.0, 26.0, "sub", 0.85, 0.002, 0.13)
			AudioSynth.add_fm(b, sr, 0.0, 0.22, 145.0, 132.0, 1.62, 2.8, 0.5, 0.48, 0.002, 0.18)
			AudioSynth.add_noise(b, sr, 0.0, 0.06, rng, 0.35, 0.002, 0.04, "hp", 1800.0, 900.0, 1.2)
			AudioSynth.saturate(b, 1.4)
			AudioSynth.normalize(b, 0.92)
			return AudioSynth.to_wav(b, sr)
		"mech.servo.step":
			var b := AudioSynth.buf(0.16, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.14, 340.0, 520.0, 1.5, 1.4, 0.6, 0.4, 0.015, 0.06)
			AudioSynth.add_noise(b, sr, 0.01, 0.11, rng, 0.25, 0.015, 0.06, "bp", 2400.0, 3200.0, 3.0)
			AudioSynth.normalize(b, 0.82)
			return AudioSynth.to_wav(b, sr)
		"mech.servo.turn":
			var b := AudioSynth.buf(0.24, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.22, 220.0, 290.0, 2.0, 1.2, 0.5, 0.45, 0.03, 0.08)
			AudioSynth.add_noise(b, sr, 0.0, 0.20, rng, 0.22, 0.03, 0.08, "bp", 1500.0, 1900.0, 2.5)
			AudioSynth.normalize(b, 0.80)
			return AudioSynth.to_wav(b, sr)

		# --- Thrusters & landings ---
		"mech.thrust.ignite":
			var b := AudioSynth.buf(0.32, sr)
			AudioSynth.add_tone(b, sr, 0.0, 0.18, 120.0, 38.0, "sub", 0.85, 0.003, 0.12)
			AudioSynth.add_noise(b, sr, 0.0, 0.28, rng, 0.75, 0.004, 0.18, "bp", 1800.0, 520.0, 1.0)
			AudioSynth.add_noise(b, sr, 0.0, 0.24, rng, 0.50, 0.005, 0.15, "lp", 480.0, 220.0, 1.2)
			AudioSynth.saturate(b, 1.7)
			AudioSynth.normalize(b, 0.92)
			return AudioSynth.to_wav(b, sr)
		"mech.thrust.loop":
			var raw := AudioSynth.buf(1.4, sr)
			AudioSynth.add_noise(raw, sr, 0.0, 1.4, rng, 0.65, 0.02, 0.02, "lp", 420.0, 420.0, 1.1)
			AudioSynth.add_noise(raw, sr, 0.0, 1.4, rng, 0.40, 0.02, 0.02, "bp", 1350.0, 1350.0, 0.9)
			AudioSynth.add_tone(raw, sr, 0.0, 1.4, 82.0, 82.0, "saw", 0.22, 0.02, 0.02, false)
			AudioSynth.add_tone(raw, sr, 0.0, 1.4, 164.0, 164.0, "tri", 0.14, 0.02, 0.02, false)
			var loop_b := AudioSynth.make_seamless(raw, sr, 0.2)
			AudioSynth.saturate(loop_b, 1.35)
			AudioSynth.normalize(loop_b, 0.86)
			return AudioSynth.to_wav(loop_b, sr, true)
		"mech.thrust.emergency":
			var b := AudioSynth.buf(0.46, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.13, 880.0, 880.0, 1.5, 0.9, 0.3, 0.6, 0.004, 0.03, false)
			AudioSynth.add_fm(b, sr, 0.16, 0.14, 1175.0, 1175.0, 1.5, 0.9, 0.3, 0.65, 0.004, 0.04, false)
			AudioSynth.add_noise(b, sr, 0.0, 0.42, rng, 0.45, 0.01, 0.22, "bp", 2200.0, 900.0, 1.2)
			AudioSynth.normalize(b, 0.92)
			return AudioSynth.to_wav(b, sr)
		"mech.land.soft":
			var b := AudioSynth.buf(0.28, sr)
			AudioSynth.add_tone(b, sr, 0.0, 0.16, 68.0, 26.0, "sub", 0.8, 0.003, 0.12)
			AudioSynth.add_tone(b, sr, 0.04, 0.16, 62.0, 24.0, "sub", 0.65, 0.003, 0.12)
			AudioSynth.add_noise(b, sr, 0.0, 0.12, rng, 0.45, 0.004, 0.08, "lp", 700.0, 240.0, 1.1)
			AudioSynth.normalize(b, 0.90)
			return AudioSynth.to_wav(b, sr)
		"mech.land.hard":
			var b := AudioSynth.buf(0.55, sr)
			AudioSynth.add_tone(b, sr, 0.0, 0.32, 85.0, 22.0, "sub", 1.0, 0.002, 0.24)
			AudioSynth.add_fm(b, sr, 0.0, 0.28, 210.0, 75.0, 2.71, 5.0, 0.8, 0.65, 0.002, 0.20)
			AudioSynth.add_noise(b, sr, 0.0, 0.38, rng, 0.72, 0.002, 0.26, "bp", 1600.0, 280.0, 1.2)
			AudioSynth.add_fm(b, sr, 0.09, 0.18, 420.0, 260.0, 1.85, 3.0, 0.6, 0.30, 0.003, 0.14)
			AudioSynth.saturate(b, 2.0)
			AudioSynth.normalize(b, 0.94)
			return AudioSynth.to_wav(b, sr)

		# --- Heat & shutdown ---
		"mech.heat.loop":
			var raw := AudioSynth.buf(1.2, sr)
			AudioSynth.add_tone(raw, sr, 0.0, 1.2, 110.0, 110.0, "saw", 0.32, 0.02, 0.02, false)
			AudioSynth.add_fm(raw, sr, 0.0, 1.2, 220.0, 220.0, 2.0, 0.9, 0.9, 0.35, 0.02, 0.02, false)
			AudioSynth.add_noise(raw, sr, 0.0, 1.2, rng, 0.22, 0.02, 0.02, "bp", 900.0, 900.0, 2.5)
			var loop_b := AudioSynth.make_seamless(raw, sr, 0.18)
			AudioSynth.normalize(loop_b, 0.85)
			return AudioSynth.to_wav(loop_b, sr, true)
		"mech.heat.tick":
			var b := AudioSynth.buf(0.085, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.075, 1380.0, 1320.0, 1.5, 0.6, 0.1, 0.75, 0.002, 0.05)
			AudioSynth.add_click(b, sr, 0.0, 0.30, 3200.0)
			AudioSynth.normalize(b, 0.90)
			return AudioSynth.to_wav(b, sr)
		"mech.heat.shutdown":
			var b := AudioSynth.buf(1.15, sr)
			AudioSynth.add_click(b, sr, 0.0, 0.65, 900.0)
			AudioSynth.add_tone(b, sr, 0.0, 0.95, 480.0, 52.0, "saw", 0.55, 0.005, 0.28, true)
			AudioSynth.add_fm(b, sr, 0.0, 0.85, 320.0, 48.0, 1.5, 2.2, 0.2, 0.45, 0.005, 0.25, true)
			AudioSynth.add_noise(b, sr, 0.08, 0.95, rng, 0.62, 0.03, 0.45, "hp", 2800.0, 1100.0, 1.3)
			AudioSynth.saturate(b, 1.5)
			AudioSynth.normalize(b, 0.92)
			return AudioSynth.to_wav(b, sr)
		"mech.heat.reboot_spool":
			var b := AudioSynth.buf(1.15, sr)
			AudioSynth.add_tone(b, sr, 0.0, 1.10, 75.0, 440.0, "saw", 0.42, 0.05, 0.08, true)
			AudioSynth.add_fm(b, sr, 0.05, 1.05, 150.0, 660.0, 2.0, 0.5, 1.8, 0.38, 0.05, 0.08, true)
			AudioSynth.add_noise(b, sr, 0.0, 1.0, rng, 0.24, 0.08, 0.12, "bp", 400.0, 2200.0, 2.2)
			AudioSynth.normalize(b, 0.88)
			return AudioSynth.to_wav(b, sr)
		"mech.heat.reboot_ok":
			var b := AudioSynth.buf(0.36, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.14, 523.25, 523.25, 2.0, 0.6, 0.1, 0.6, 0.003, 0.07, false)
			AudioSynth.add_fm(b, sr, 0.11, 0.23, 783.99, 783.99, 2.0, 0.7, 0.1, 0.7, 0.003, 0.14, false)
			AudioSynth.normalize(b, 0.90)
			return AudioSynth.to_wav(b, sr)

		# --- Subtle deadpan pilot cues (narrow radio bandpass 600-2200 Hz) ---
		"pilot.chicken":
			var b := AudioSynth.buf(0.24, sr)
			AudioSynth.add_fm(b, sr, 0.01, 0.07, 740.0, 520.0, 1.45, 2.8, 0.9, 0.65, 0.004, 0.03)
			AudioSynth.add_fm(b, sr, 0.10, 0.09, 640.0, 410.0, 1.38, 2.2, 0.6, 0.55, 0.004, 0.04)
			AudioSynth.add_noise(b, sr, 0.0, 0.22, rng, 0.12, 0.01, 0.04, "bp", 1300.0, 1100.0, 2.0)
			AudioSynth.bandpass_radio(b, sr, 600.0, 2200.0)
			AudioSynth.normalize(b, 0.85)
			return AudioSynth.to_wav(b, sr)
		"pilot.pickle":
			var b := AudioSynth.buf(0.22, sr)
			AudioSynth.add_tone(b, sr, 0.01, 0.06, 980.0, 1480.0, "sine", 0.55, 0.003, 0.03)
			AudioSynth.add_noise(b, sr, 0.05, 0.09, rng, 0.60, 0.004, 0.05, "bp", 1700.0, 950.0, 2.6)
			AudioSynth.add_click(b, sr, 0.06, 0.45, 1900.0)
			AudioSynth.bandpass_radio(b, sr, 600.0, 2200.0)
			AudioSynth.normalize(b, 0.85)
			return AudioSynth.to_wav(b, sr)
		"pilot.corn":
			var b := AudioSynth.buf(0.24, sr)
			AudioSynth.add_tone(b, sr, 0.02, 0.045, 620.0, 1280.0, "tri", 0.6, 0.002, 0.025)
			AudioSynth.add_tone(b, sr, 0.09, 0.05, 720.0, 1420.0, "tri", 0.55, 0.002, 0.025)
			AudioSynth.add_noise(b, sr, 0.01, 0.16, rng, 0.30, 0.005, 0.08, "bp", 1800.0, 1200.0, 2.0)
			AudioSynth.bandpass_radio(b, sr, 600.0, 2200.0)
			AudioSynth.normalize(b, 0.85)
			return AudioSynth.to_wav(b, sr)
		"pilot.dog":
			var b := AudioSynth.buf(0.24, sr)
			AudioSynth.add_fm(b, sr, 0.01, 0.15, 290.0, 190.0, 2.15, 3.2, 1.0, 0.72, 0.006, 0.06)
			AudioSynth.add_noise(b, sr, 0.01, 0.14, rng, 0.35, 0.005, 0.06, "bp", 950.0, 680.0, 1.8)
			AudioSynth.bandpass_radio(b, sr, 600.0, 2200.0)
			AudioSynth.normalize(b, 0.85)
			return AudioSynth.to_wav(b, sr)

		# --- Active weapons ---
		"wpn.laser.charge":
			var raw := AudioSynth.buf(0.8, sr)
			AudioSynth.add_fm(raw, sr, 0.0, 0.8, 520.0, 520.0, 2.5, 1.8, 1.8, 0.5, 0.02, 0.02, false)
			AudioSynth.add_tone(raw, sr, 0.0, 0.8, 1040.0, 1040.0, "tri", 0.32, 0.02, 0.02, false)
			var loop_b := AudioSynth.make_seamless(raw, sr, 0.12)
			AudioSynth.normalize(loop_b, 0.86)
			return AudioSynth.to_wav(loop_b, sr, true)
		"wpn.laser.fire":
			var b := AudioSynth.buf(0.36, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.28, 1850.0, 240.0, 2.41, 4.5, 0.6, 0.72, 0.002, 0.18)
			AudioSynth.add_tone(b, sr, 0.0, 0.16, 150.0, 44.0, "sub", 0.78, 0.002, 0.12)
			AudioSynth.add_noise(b, sr, 0.0, 0.14, rng, 0.50, 0.002, 0.10, "hp", 3200.0, 1200.0, 1.5)
			AudioSynth.saturate(b, 1.8)
			AudioSynth.normalize(b, 0.93)
			return AudioSynth.to_wav(b, sr)
		"wpn.autocannon.fire":
			var b := AudioSynth.buf(0.34, sr)
			AudioSynth.add_tone(b, sr, 0.0, 0.20, 130.0, 32.0, "sub", 0.95, 0.002, 0.15)
			AudioSynth.add_noise(b, sr, 0.0, 0.18, rng, 0.85, 0.002, 0.13, "bp", 1400.0, 260.0, 1.0)
			AudioSynth.add_fm(b, sr, 0.035, 0.14, 620.0, 480.0, 2.83, 3.2, 0.4, 0.38, 0.002, 0.10)
			AudioSynth.add_click(b, sr, 0.0, 0.45, 2200.0)
			AudioSynth.saturate(b, 2.1)
			AudioSynth.normalize(b, 0.94)
			return AudioSynth.to_wav(b, sr)
		"wpn.gatling.spin_loop":
			var raw := AudioSynth.buf(0.8, sr)
			AudioSynth.add_tone(raw, sr, 0.0, 0.8, 140.0, 140.0, "saw", 0.35, 0.02, 0.02, false)
			AudioSynth.add_fm(raw, sr, 0.0, 0.8, 280.0, 280.0, 3.0, 1.4, 1.4, 0.35, 0.02, 0.02, false)
			AudioSynth.add_noise(raw, sr, 0.0, 0.8, rng, 0.22, 0.02, 0.02, "bp", 1800.0, 1800.0, 2.2)
			var loop_b := AudioSynth.make_seamless(raw, sr, 0.12)
			AudioSynth.normalize(loop_b, 0.85)
			return AudioSynth.to_wav(loop_b, sr, true)
		"wpn.gatling.fire":
			var b := AudioSynth.buf(0.11, sr)
			AudioSynth.add_tone(b, sr, 0.0, 0.075, 195.0, 58.0, "sub", 0.82, 0.001, 0.055)
			AudioSynth.add_noise(b, sr, 0.0, 0.08, rng, 0.82, 0.001, 0.06, "bp", 2600.0, 650.0, 1.2)
			AudioSynth.add_fm(b, sr, 0.0, 0.05, 860.0, 420.0, 2.1, 2.2, 0.3, 0.36, 0.001, 0.04)
			AudioSynth.saturate(b, 2.0)
			AudioSynth.normalize(b, 0.92)
			return AudioSynth.to_wav(b, sr)
		"wpn.rockets.fire":
			var b := AudioSynth.buf(0.42, sr)
			AudioSynth.add_tone(b, sr, 0.0, 0.08, 165.0, 62.0, "tri", 0.72, 0.002, 0.06)
			AudioSynth.add_noise(b, sr, 0.01, 0.38, rng, 0.78, 0.015, 0.24, "bp", 2400.0, 750.0, 0.9)
			AudioSynth.add_noise(b, sr, 0.03, 0.32, rng, 0.45, 0.01, 0.18, "hp", 3400.0, 1800.0, 1.3)
			AudioSynth.saturate(b, 1.5)
			AudioSynth.normalize(b, 0.92)
			return AudioSynth.to_wav(b, sr)
		"wpn.mortar.fire":
			var b := AudioSynth.buf(0.46, sr)
			AudioSynth.add_tone(b, sr, 0.0, 0.28, 118.0, 34.0, "sub", 0.95, 0.004, 0.20)
			AudioSynth.add_fm(b, sr, 0.0, 0.24, 240.0, 145.0, 1.5, 2.0, 0.4, 0.48, 0.004, 0.16)
			AudioSynth.add_noise(b, sr, 0.01, 0.34, rng, 0.55, 0.01, 0.25, "lp", 680.0, 180.0, 1.5)
			AudioSynth.saturate(b, 1.6)
			AudioSynth.normalize(b, 0.93)
			return AudioSynth.to_wav(b, sr)
		"wpn.mortar.whistle":
			var b := AudioSynth.buf(1.25, sr)
			AudioSynth.add_tone(b, sr, 0.0, 1.22, 1320.0, 420.0, "sine", 0.65, 0.08, 0.08, true)
			AudioSynth.add_tone(b, sr, 0.0, 1.22, 2640.0, 840.0, "tri", 0.22, 0.08, 0.08, true)
			AudioSynth.add_noise(b, sr, 0.0, 1.22, rng, 0.30, 0.10, 0.08, "bp", 2000.0, 750.0, 3.2)
			AudioSynth.normalize(b, 0.90)
			return AudioSynth.to_wav(b, sr)

		# --- Paused weapons (placeholder-ready) ---
		"wpn.flamer.ignite":
			var b := AudioSynth.buf(0.22, sr)
			AudioSynth.add_click(b, sr, 0.0, 0.6, 2800.0)
			AudioSynth.add_noise(b, sr, 0.02, 0.18, rng, 0.72, 0.01, 0.10, "lp", 1100.0, 420.0, 1.2)
			AudioSynth.normalize(b, 0.90)
			return AudioSynth.to_wav(b, sr)
		"wpn.flamer.loop":
			var raw := AudioSynth.buf(1.2, sr)
			AudioSynth.add_noise(raw, sr, 0.0, 1.2, rng, 0.78, 0.02, 0.02, "lp", 620.0, 620.0, 1.0)
			AudioSynth.add_noise(raw, sr, 0.0, 1.2, rng, 0.40, 0.02, 0.02, "bp", 1500.0, 1500.0, 0.9)
			var loop_b := AudioSynth.make_seamless(raw, sr, 0.18)
			AudioSynth.saturate(loop_b, 1.4)
			AudioSynth.normalize(loop_b, 0.86)
			return AudioSynth.to_wav(loop_b, sr, true)
		"wpn.missiles.fire":
			var b := AudioSynth.buf(0.38, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.24, 920.0, 1680.0, 1.75, 1.6, 0.4, 0.45, 0.005, 0.15)
			AudioSynth.add_noise(b, sr, 0.0, 0.35, rng, 0.70, 0.01, 0.22, "bp", 3100.0, 1100.0, 1.1)
			AudioSynth.normalize(b, 0.92)
			return AudioSynth.to_wav(b, sr)
		"wpn.missiles.lock":
			var raw := AudioSynth.buf(0.5, sr)
			AudioSynth.add_tone(raw, sr, 0.0, 0.12, 1320.0, 1320.0, "sine", 0.5, 0.005, 0.04, false)
			AudioSynth.add_tone(raw, sr, 0.25, 0.12, 1320.0, 1320.0, "sine", 0.5, 0.005, 0.04, false)
			AudioSynth.normalize(raw, 0.82)
			return AudioSynth.to_wav(raw, sr, true)
		"wpn.railgun.charge":
			var b := AudioSynth.buf(1.0, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.98, 180.0, 1480.0, 2.0, 0.8, 3.6, 0.65, 0.04, 0.04, true)
			for step in 4:
				var st := float(step) * 0.22
				AudioSynth.add_tone(b, sr, st, 0.09, 440.0 * pow(1.26, float(step)), 440.0 * pow(1.26, float(step)), "tri", 0.35, 0.005, 0.05, false)
			AudioSynth.normalize(b, 0.90)
			return AudioSynth.to_wav(b, sr)
		"wpn.railgun.fire":
			var b := AudioSynth.buf(0.62, sr)
			AudioSynth.add_tone(b, sr, 0.0, 0.36, 220.0, 28.0, "sub", 1.0, 0.001, 0.28)
			AudioSynth.add_fm(b, sr, 0.0, 0.42, 2400.0, 160.0, 3.14, 6.0, 0.6, 0.78, 0.001, 0.30)
			AudioSynth.add_noise(b, sr, 0.0, 0.48, rng, 0.75, 0.001, 0.35, "hp", 2600.0, 500.0, 1.1)
			AudioSynth.saturate(b, 2.3)
			AudioSynth.normalize(b, 0.94)
			return AudioSynth.to_wav(b, sr)
		"wpn.swivel.fire":
			var b := AudioSynth.buf(0.18, sr)
			AudioSynth.add_tone(b, sr, 0.0, 0.09, 175.0, 48.0, "sub", 0.82, 0.002, 0.07)
			AudioSynth.add_noise(b, sr, 0.0, 0.12, rng, 0.75, 0.002, 0.08, "bp", 2200.0, 520.0, 1.3)
			AudioSynth.add_click(b, sr, 0.015, 0.45, 2400.0)
			AudioSynth.saturate(b, 1.8)
			AudioSynth.normalize(b, 0.92)
			return AudioSynth.to_wav(b, sr)

		# --- Combat confirms, targets & impacts ---
		"combat.hit.tick":
			var b := AudioSynth.buf(0.045, sr)
			AudioSynth.add_click(b, sr, 0.0, 0.75, 2800.0)
			AudioSynth.add_tone(b, sr, 0.0, 0.038, 1750.0, 1200.0, "tri", 0.55, 0.001, 0.03)
			AudioSynth.normalize(b, 0.90)
			return AudioSynth.to_wav(b, sr)
		"combat.hit.weak":
			var b := AudioSynth.buf(0.085, sr)
			AudioSynth.add_click(b, sr, 0.0, 0.70, 3400.0)
			AudioSynth.add_fm(b, sr, 0.0, 0.075, 1980.0, 2420.0, 1.5, 1.1, 0.2, 0.65, 0.001, 0.05)
			AudioSynth.normalize(b, 0.92)
			return AudioSynth.to_wav(b, sr)
		"combat.hit.break":
			var b := AudioSynth.buf(0.32, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.26, 680.0, 210.0, 2.93, 4.5, 0.8, 0.72, 0.002, 0.18)
			AudioSynth.add_noise(b, sr, 0.0, 0.20, rng, 0.62, 0.002, 0.14, "bp", 2400.0, 700.0, 1.4)
			AudioSynth.add_tone(b, sr, 0.02, 0.18, 1320.0, 1320.0, "sine", 0.35, 0.003, 0.14, false)
			AudioSynth.saturate(b, 1.7)
			AudioSynth.normalize(b, 0.93)
			return AudioSynth.to_wav(b, sr)
		"combat.stagger":
			var b := AudioSynth.buf(0.45, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.38, 260.0, 115.0, 2.37, 4.2, 0.9, 0.75, 0.004, 0.26)
			AudioSynth.add_tone(b, sr, 0.0, 0.24, 92.0, 36.0, "sub", 0.70, 0.003, 0.18)
			AudioSynth.add_noise(b, sr, 0.04, 0.32, rng, 0.45, 0.01, 0.22, "hp", 2200.0, 900.0, 1.3)
			AudioSynth.saturate(b, 1.6)
			AudioSynth.normalize(b, 0.92)
			return AudioSynth.to_wav(b, sr)
		"combat.wall_slam":
			var b := AudioSynth.buf(0.48, sr)
			AudioSynth.add_tone(b, sr, 0.0, 0.30, 98.0, 24.0, "sub", 0.98, 0.002, 0.22)
			AudioSynth.add_noise(b, sr, 0.0, 0.40, rng, 0.82, 0.002, 0.28, "bp", 1200.0, 220.0, 1.1)
			AudioSynth.add_fm(b, sr, 0.0, 0.26, 340.0, 120.0, 2.61, 4.8, 1.0, 0.55, 0.002, 0.20)
			AudioSynth.saturate(b, 2.1)
			AudioSynth.normalize(b, 0.94)
			return AudioSynth.to_wav(b, sr)
		"combat.kill":
			var b := AudioSynth.buf(0.68, sr)
			AudioSynth.add_tone(b, sr, 0.0, 0.45, 130.0, 22.0, "sub", 0.95, 0.002, 0.34)
			AudioSynth.add_fm(b, sr, 0.0, 0.22, 920.0, 280.0, 2.1, 3.6, 0.6, 0.58, 0.002, 0.16)
			AudioSynth.add_noise(b, sr, 0.02, 0.58, rng, 0.80, 0.005, 0.40, "lp", 1600.0, 240.0, 1.0)
			AudioSynth.saturate(b, 2.0)
			AudioSynth.normalize(b, 0.94)
			return AudioSynth.to_wav(b, sr)
		"combat.player.damaged":
			var b := AudioSynth.buf(0.24, sr)
			AudioSynth.add_tone(b, sr, 0.0, 0.16, 110.0, 38.0, "sub", 0.85, 0.002, 0.11)
			AudioSynth.add_fm(b, sr, 0.0, 0.18, 420.0, 190.0, 2.75, 4.0, 0.7, 0.60, 0.002, 0.12)
			AudioSynth.add_noise(b, sr, 0.0, 0.14, rng, 0.52, 0.002, 0.09, "bp", 1500.0, 450.0, 1.2)
			AudioSynth.saturate(b, 1.8)
			AudioSynth.normalize(b, 0.92)
			return AudioSynth.to_wav(b, sr)
		"combat.player.part_lost":
			var b := AudioSynth.buf(0.52, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.24, 520.0, 180.0, 3.1, 5.0, 0.8, 0.65, 0.002, 0.16)
			AudioSynth.add_fm(b, sr, 0.12, 0.14, 740.0, 560.0, 1.5, 1.2, 0.4, 0.55, 0.003, 0.06)
			AudioSynth.add_fm(b, sr, 0.28, 0.18, 560.0, 420.0, 1.5, 1.2, 0.4, 0.55, 0.003, 0.08)
			AudioSynth.saturate(b, 1.6)
			AudioSynth.normalize(b, 0.93)
			return AudioSynth.to_wav(b, sr)
		"combat.player.disabled":
			var b := AudioSynth.buf(0.95, sr)
			AudioSynth.add_tone(b, sr, 0.0, 0.85, 420.0, 42.0, "saw", 0.65, 0.005, 0.30, true)
			AudioSynth.add_tone(b, sr, 0.0, 0.50, 110.0, 24.0, "sub", 0.90, 0.003, 0.35)
			AudioSynth.add_noise(b, sr, 0.05, 0.75, rng, 0.60, 0.01, 0.45, "lp", 1800.0, 260.0, 1.2)
			AudioSynth.saturate(b, 1.8)
			AudioSynth.normalize(b, 0.94)
			return AudioSynth.to_wav(b, sr)
		"impact.small":
			var b := AudioSynth.buf(0.14, sr)
			AudioSynth.add_noise(b, sr, 0.0, 0.11, rng, 0.72, 0.001, 0.08, "bp", 2800.0, 750.0, 1.2)
			AudioSynth.add_tone(b, sr, 0.0, 0.07, 210.0, 75.0, "tri", 0.52, 0.001, 0.05)
			AudioSynth.saturate(b, 1.6)
			AudioSynth.normalize(b, 0.90)
			return AudioSynth.to_wav(b, sr)
		"impact.medium":
			var b := AudioSynth.buf(0.28, sr)
			AudioSynth.add_tone(b, sr, 0.0, 0.18, 125.0, 36.0, "sub", 0.85, 0.002, 0.13)
			AudioSynth.add_noise(b, sr, 0.0, 0.24, rng, 0.78, 0.002, 0.17, "bp", 1800.0, 360.0, 1.1)
			AudioSynth.add_fm(b, sr, 0.0, 0.14, 480.0, 190.0, 2.4, 3.0, 0.5, 0.42, 0.002, 0.10)
			AudioSynth.saturate(b, 1.9)
			AudioSynth.normalize(b, 0.92)
			return AudioSynth.to_wav(b, sr)
		"impact.energy":
			var b := AudioSynth.buf(0.32, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.26, 1400.0, 320.0, 2.75, 4.2, 0.7, 0.68, 0.002, 0.18)
			AudioSynth.add_noise(b, sr, 0.0, 0.25, rng, 0.60, 0.002, 0.18, "hp", 3600.0, 1200.0, 1.5)
			AudioSynth.add_tone(b, sr, 0.0, 0.14, 140.0, 48.0, "sub", 0.65, 0.002, 0.10)
			AudioSynth.saturate(b, 1.7)
			AudioSynth.normalize(b, 0.92)
			return AudioSynth.to_wav(b, sr)
		"impact.explosive.med":
			var b := AudioSynth.buf(0.65, sr)
			AudioSynth.add_tone(b, sr, 0.0, 0.42, 115.0, 24.0, "sub", 1.0, 0.002, 0.30)
			AudioSynth.add_noise(b, sr, 0.0, 0.55, rng, 0.88, 0.003, 0.38, "lp", 1900.0, 240.0, 1.0)
			AudioSynth.add_noise(b, sr, 0.04, 0.42, rng, 0.48, 0.008, 0.28, "bp", 2600.0, 620.0, 1.3)
			AudioSynth.saturate(b, 2.2)
			AudioSynth.normalize(b, 0.94)
			return AudioSynth.to_wav(b, sr)
		"impact.explosive.large":
			var b := AudioSynth.buf(1.25, sr)
			AudioSynth.add_tone(b, sr, 0.0, 0.82, 92.0, 19.0, "sub", 1.0, 0.003, 0.62)
			AudioSynth.add_noise(b, sr, 0.0, 1.05, rng, 0.92, 0.004, 0.72, "lp", 1500.0, 150.0, 1.1)
			AudioSynth.add_noise(b, sr, 0.08, 0.78, rng, 0.52, 0.02, 0.52, "bp", 2200.0, 420.0, 1.2)
			AudioSynth.add_tone(b, sr, 0.18, 0.65, 58.0, 22.0, "tri", 0.48, 0.04, 0.45)
			AudioSynth.saturate(b, 2.3)
			AudioSynth.normalize(b, 0.94)
			return AudioSynth.to_wav(b, sr)

		# --- Destructible street props ---
		"prop.tree.topple":
			var b := AudioSynth.buf(0.68, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.14, 320.0, 140.0, 2.4, 3.8, 0.6, 0.65, 0.002, 0.09)
			AudioSynth.add_noise(b, sr, 0.04, 0.56, rng, 0.60, 0.05, 0.30, "bp", 1900.0, 700.0, 0.9)
			AudioSynth.add_tone(b, sr, 0.36, 0.24, 72.0, 28.0, "sub", 0.72, 0.004, 0.16)
			AudioSynth.normalize(b, 0.90)
			return AudioSynth.to_wav(b, sr)
		"prop.tree.shove":
			var b := AudioSynth.buf(0.30, sr)
			AudioSynth.add_noise(b, sr, 0.0, 0.28, rng, 0.65, 0.015, 0.16, "bp", 1500.0, 620.0, 1.0)
			AudioSynth.add_tone(b, sr, 0.0, 0.16, 85.0, 42.0, "tri", 0.40, 0.006, 0.10)
			AudioSynth.normalize(b, 0.85)
			return AudioSynth.to_wav(b, sr)
		"prop.metal.topple":
			var b := AudioSynth.buf(0.62, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.28, 480.0, 290.0, 2.76, 4.5, 0.8, 0.65, 0.002, 0.20)
			AudioSynth.add_fm(b, sr, 0.28, 0.30, 360.0, 210.0, 2.41, 4.0, 0.6, 0.62, 0.002, 0.22)
			AudioSynth.add_noise(b, sr, 0.28, 0.16, rng, 0.42, 0.003, 0.10, "hp", 2000.0, 900.0, 1.2)
			AudioSynth.saturate(b, 1.5)
			AudioSynth.normalize(b, 0.92)
			return AudioSynth.to_wav(b, sr)
		"prop.metal.shove":
			var b := AudioSynth.buf(0.28, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.24, 540.0, 380.0, 3.12, 3.0, 0.8, 0.50, 0.004, 0.16)
			AudioSynth.add_noise(b, sr, 0.0, 0.24, rng, 0.48, 0.008, 0.14, "bp", 2600.0, 1200.0, 1.8)
			AudioSynth.normalize(b, 0.88)
			return AudioSynth.to_wav(b, sr)
		"prop.bench.topple":
			var b := AudioSynth.buf(0.38, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.22, 290.0, 160.0, 2.2, 3.2, 0.5, 0.62, 0.003, 0.14)
			AudioSynth.add_tone(b, sr, 0.14, 0.18, 95.0, 42.0, "sub", 0.65, 0.003, 0.12)
			AudioSynth.add_noise(b, sr, 0.0, 0.26, rng, 0.42, 0.004, 0.16, "bp", 1200.0, 480.0, 1.1)
			AudioSynth.normalize(b, 0.90)
			return AudioSynth.to_wav(b, sr)
		"prop.bench.shove":
			var b := AudioSynth.buf(0.24, sr)
			AudioSynth.add_noise(b, sr, 0.0, 0.22, rng, 0.55, 0.008, 0.14, "bp", 1100.0, 460.0, 1.3)
			AudioSynth.add_fm(b, sr, 0.0, 0.16, 260.0, 190.0, 2.1, 2.0, 0.4, 0.38, 0.004, 0.10)
			AudioSynth.normalize(b, 0.85)
			return AudioSynth.to_wav(b, sr)
		"prop.bin.topple":
			var b := AudioSynth.buf(0.32, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.18, 690.0, 520.0, 2.91, 3.8, 0.7, 0.65, 0.002, 0.12)
			AudioSynth.add_fm(b, sr, 0.13, 0.16, 610.0, 480.0, 2.85, 3.0, 0.5, 0.50, 0.002, 0.11)
			AudioSynth.normalize(b, 0.90)
			return AudioSynth.to_wav(b, sr)
		"prop.bin.shove":
			var b := AudioSynth.buf(0.26, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.10, 740.0, 620.0, 3.05, 3.2, 0.6, 0.55, 0.002, 0.07)
			AudioSynth.add_fm(b, sr, 0.09, 0.14, 680.0, 560.0, 2.95, 2.6, 0.5, 0.48, 0.002, 0.09)
			AudioSynth.add_noise(b, sr, 0.0, 0.22, rng, 0.32, 0.005, 0.12, "hp", 2400.0, 1400.0, 1.5)
			AudioSynth.normalize(b, 0.88)
			return AudioSynth.to_wav(b, sr)

		# --- Enemy audio & >= 0.3s alien-robot telegraphs ---
		"enemy.telegraph.beam":
			# 0.6 s reference duration (stretched via pitch_scale to match live duration >= 0.3 s); glassy rising FM + sharp pre-fire pip
			var b := AudioSynth.buf(0.60, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.52, 420.0, 1680.0, 2.71, 1.2, 4.2, 0.62, 0.02, 0.04, true)
			AudioSynth.add_tone(b, sr, 0.0, 0.52, 840.0, 2520.0, "sine", 0.30, 0.02, 0.04, true)
			AudioSynth.add_fm(b, sr, 0.51, 0.085, 2240.0, 1920.0, 1.5, 1.4, 0.2, 0.82, 0.002, 0.05)
			AudioSynth.normalize(b, 0.93)
			return AudioSynth.to_wav(b, sr)
		"enemy.telegraph.cannon":
			var b := AudioSynth.buf(0.55, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.45, 280.0, 780.0, 1.62, 1.6, 3.4, 0.62, 0.015, 0.05, true)
			AudioSynth.add_click(b, sr, 0.0, 0.45, 1800.0)
			AudioSynth.add_fm(b, sr, 0.44, 0.10, 1240.0, 980.0, 2.0, 1.8, 0.3, 0.82, 0.002, 0.06)
			AudioSynth.normalize(b, 0.93)
			return AudioSynth.to_wav(b, sr)
		"enemy.telegraph.mortar":
			var b := AudioSynth.buf(0.75, sr)
			for i in 3:
				var st := float(i) * 0.21
				var hz := 520.0 * pow(1.22, float(i))
				AudioSynth.add_fm(b, sr, st, 0.16, hz, hz * 1.15, 2.35, 1.5, 0.4, 0.65, 0.004, 0.06)
			AudioSynth.add_tone(b, sr, 0.0, 0.72, 140.0, 280.0, "saw", 0.28, 0.04, 0.08, true)
			AudioSynth.normalize(b, 0.93)
			return AudioSynth.to_wav(b, sr)
		"enemy.telegraph.pulse":
			var b := AudioSynth.buf(0.50, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.42, 620.0, 1480.0, 3.14, 1.0, 3.8, 0.62, 0.015, 0.04, true)
			AudioSynth.add_fm(b, sr, 0.41, 0.085, 1960.0, 1640.0, 1.62, 1.6, 0.2, 0.80, 0.002, 0.05)
			AudioSynth.normalize(b, 0.93)
			return AudioSynth.to_wav(b, sr)
		"enemy.telegraph.rush":
			var b := AudioSynth.buf(0.55, sr)
			AudioSynth.add_tone(b, sr, 0.0, 0.48, 160.0, 640.0, "saw", 0.55, 0.02, 0.06, true)
			AudioSynth.add_fm(b, sr, 0.0, 0.48, 320.0, 1280.0, 2.5, 2.2, 3.5, 0.52, 0.02, 0.06, true)
			AudioSynth.add_fm(b, sr, 0.46, 0.085, 1520.0, 1220.0, 1.5, 1.4, 0.3, 0.78, 0.002, 0.05)
			AudioSynth.normalize(b, 0.93)
			return AudioSynth.to_wav(b, sr)
		"enemy.telegraph.generic":
			var b := AudioSynth.buf(0.55, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.45, 480.0, 1260.0, 2.41, 1.4, 3.2, 0.62, 0.015, 0.05, true)
			AudioSynth.add_fm(b, sr, 0.45, 0.095, 1760.0, 1480.0, 1.5, 1.2, 0.2, 0.80, 0.002, 0.05)
			AudioSynth.normalize(b, 0.93)
			return AudioSynth.to_wav(b, sr)
		"enemy.fire.accent":
			var b := AudioSynth.buf(0.20, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.18, 1180.0, 380.0, 2.71, 3.6, 0.5, 0.72, 0.002, 0.12)
			AudioSynth.normalize(b, 0.90)
			return AudioSynth.to_wav(b, sr)
		"enemy.alert.spotted":
			var b := AudioSynth.buf(0.32, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.11, 1040.0, 1380.0, 2.41, 1.8, 0.6, 0.68, 0.003, 0.04)
			AudioSynth.add_fm(b, sr, 0.13, 0.16, 1560.0, 1880.0, 2.41, 2.2, 0.5, 0.72, 0.003, 0.08)
			AudioSynth.normalize(b, 0.92)
			return AudioSynth.to_wav(b, sr)
		"enemy.alert.relay":
			var b := AudioSynth.buf(0.36, sr)
			var freqs: Array[float] = [1280.0, 1620.0, 1420.0, 1940.0]
			for i in 4:
				var st := float(i) * 0.075
				var f := freqs[i]
				AudioSynth.add_fm(b, sr, st, 0.065, f, f * 0.92, 2.71, 2.0, 0.5, 0.62, 0.002, 0.03)
			AudioSynth.normalize(b, 0.90)
			return AudioSynth.to_wav(b, sr)
		"enemy.alert.search":
			var b := AudioSynth.buf(0.28, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.25, 760.0, 920.0, 2.1, 1.2, 0.4, 0.58, 0.01, 0.12)
			AudioSynth.normalize(b, 0.86)
			return AudioSynth.to_wav(b, sr)
		"enemy.alert.lost":
			var b := AudioSynth.buf(0.32, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.28, 840.0, 420.0, 2.1, 1.4, 0.3, 0.58, 0.01, 0.14)
			AudioSynth.normalize(b, 0.86)
			return AudioSynth.to_wav(b, sr)
		"enemy.step":
			var b := AudioSynth.buf(0.20, sr)
			AudioSynth.add_tone(b, sr, 0.0, 0.12, 82.0, 34.0, "sub", 0.72, 0.002, 0.09)
			AudioSynth.add_fm(b, sr, 0.0, 0.10, 340.0, 220.0, 2.6, 2.4, 0.4, 0.45, 0.002, 0.07)
			AudioSynth.normalize(b, 0.88)
			return AudioSynth.to_wav(b, sr)
		"enemy.overheat":
			var b := AudioSynth.buf(0.65, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.55, 920.0, 140.0, 2.71, 3.8, 0.4, 0.68, 0.005, 0.22)
			AudioSynth.add_noise(b, sr, 0.05, 0.55, rng, 0.55, 0.02, 0.30, "hp", 2600.0, 1000.0, 1.4)
			AudioSynth.normalize(b, 0.92)
			return AudioSynth.to_wav(b, sr)
		"enemy.reboot":
			var b := AudioSynth.buf(0.45, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.42, 240.0, 1180.0, 2.41, 1.2, 2.6, 0.62, 0.02, 0.10, true)
			AudioSynth.normalize(b, 0.90)
			return AudioSynth.to_wav(b, sr)
		"enemy.destroyed":
			var b := AudioSynth.buf(0.85, sr)
			AudioSynth.add_tone(b, sr, 0.0, 0.55, 115.0, 20.0, "sub", 0.98, 0.002, 0.40)
			AudioSynth.add_fm(b, sr, 0.0, 0.48, 1280.0, 110.0, 2.71, 5.2, 0.6, 0.65, 0.002, 0.30)
			AudioSynth.add_noise(b, sr, 0.02, 0.75, rng, 0.85, 0.004, 0.52, "lp", 1800.0, 200.0, 1.1)
			AudioSynth.saturate(b, 2.1)
			AudioSynth.normalize(b, 0.94)
			return AudioSynth.to_wav(b, sr)

		# --- UI & Hangar ---
		"ui.hover":
			var b := AudioSynth.buf(0.028, sr)
			AudioSynth.add_click(b, sr, 0.0, 0.55, 3400.0)
			AudioSynth.add_tone(b, sr, 0.0, 0.024, 1620.0, 1480.0, "sine", 0.38, 0.001, 0.018)
			AudioSynth.normalize(b, 0.82)
			return AudioSynth.to_wav(b, sr)
		"ui.click":
			var b := AudioSynth.buf(0.065, sr)
			AudioSynth.add_click(b, sr, 0.0, 0.72, 2400.0)
			AudioSynth.add_fm(b, sr, 0.004, 0.055, 760.0, 520.0, 1.5, 0.9, 0.1, 0.58, 0.001, 0.04)
			AudioSynth.normalize(b, 0.90)
			return AudioSynth.to_wav(b, sr)
		"ui.back":
			var b := AudioSynth.buf(0.075, sr)
			AudioSynth.add_click(b, sr, 0.0, 0.55, 1600.0)
			AudioSynth.add_fm(b, sr, 0.004, 0.065, 520.0, 310.0, 1.5, 0.8, 0.1, 0.58, 0.001, 0.045)
			AudioSynth.normalize(b, 0.88)
			return AudioSynth.to_wav(b, sr)
		"ui.slider":
			var b := AudioSynth.buf(0.024, sr)
			AudioSynth.add_click(b, sr, 0.0, 0.65, 2900.0)
			AudioSynth.normalize(b, 0.82)
			return AudioSynth.to_wav(b, sr)
		"ui.hangar.mount":
			var b := AudioSynth.buf(0.32, sr)
			AudioSynth.add_tone(b, sr, 0.0, 0.12, 110.0, 42.0, "sub", 0.82, 0.002, 0.08)
			AudioSynth.add_fm(b, sr, 0.0, 0.14, 340.0, 190.0, 2.4, 3.2, 0.5, 0.58, 0.002, 0.09)
			AudioSynth.add_click(b, sr, 0.09, 0.60, 1900.0)
			AudioSynth.add_fm(b, sr, 0.13, 0.15, 620.0, 740.0, 2.0, 1.4, 0.3, 0.45, 0.002, 0.09)
			AudioSynth.saturate(b, 1.5)
			AudioSynth.normalize(b, 0.92)
			return AudioSynth.to_wav(b, sr)
		"ui.hangar.unmount":
			var b := AudioSynth.buf(0.26, sr)
			AudioSynth.add_click(b, sr, 0.0, 0.55, 2100.0)
			AudioSynth.add_noise(b, sr, 0.02, 0.20, rng, 0.55, 0.008, 0.12, "hp", 2600.0, 1200.0, 1.4)
			AudioSynth.add_fm(b, sr, 0.03, 0.15, 420.0, 220.0, 1.8, 1.8, 0.4, 0.42, 0.003, 0.10)
			AudioSynth.normalize(b, 0.88)
			return AudioSynth.to_wav(b, sr)
		"ui.hangar.alert":
			var b := AudioSynth.buf(1.10, sr)
			# Assault boat breach klaxon (two heavy pulses) + hydraulic cradle-clamp hiss
			AudioSynth.add_fm(b, sr, 0.0, 0.36, 440.0, 392.0, 1.5, 1.8, 1.2, 0.68, 0.015, 0.06, false)
			AudioSynth.add_fm(b, sr, 0.50, 0.36, 440.0, 392.0, 1.5, 1.8, 1.2, 0.68, 0.015, 0.08, false)
			AudioSynth.add_noise(b, sr, 0.10, 0.85, rng, 0.48, 0.04, 0.35, "bp", 2200.0, 850.0, 1.3)
			AudioSynth.add_tone(b, sr, 0.08, 0.18, 95.0, 36.0, "sub", 0.65, 0.005, 0.12)
			AudioSynth.saturate(b, 1.5)
			AudioSynth.normalize(b, 0.92)
			return AudioSynth.to_wav(b, sr)
		"ui.slot.on":
			var b := AudioSynth.buf(0.075, sr)
			AudioSynth.add_click(b, sr, 0.0, 0.55, 2600.0)
			AudioSynth.add_tone(b, sr, 0.005, 0.06, 680.0, 960.0, "tri", 0.62, 0.002, 0.04)
			AudioSynth.normalize(b, 0.88)
			return AudioSynth.to_wav(b, sr)
		"ui.slot.off":
			var b := AudioSynth.buf(0.075, sr)
			AudioSynth.add_click(b, sr, 0.0, 0.50, 1900.0)
			AudioSynth.add_tone(b, sr, 0.005, 0.06, 720.0, 440.0, "tri", 0.62, 0.002, 0.04)
			AudioSynth.normalize(b, 0.88)
			return AudioSynth.to_wav(b, sr)
		"ui.slot.solo":
			var b := AudioSynth.buf(0.13, sr)
			AudioSynth.add_tone(b, sr, 0.0, 0.05, 820.0, 980.0, "tri", 0.58, 0.002, 0.03)
			AudioSynth.add_tone(b, sr, 0.055, 0.065, 1180.0, 1360.0, "tri", 0.68, 0.002, 0.04)
			AudioSynth.normalize(b, 0.90)
			return AudioSynth.to_wav(b, sr)
		"ui.weapon.dry":
			var b := AudioSynth.buf(0.09, sr)
			AudioSynth.add_click(b, sr, 0.0, 0.72, 1850.0)
			AudioSynth.add_fm(b, sr, 0.0, 0.065, 380.0, 260.0, 2.7, 2.5, 0.4, 0.55, 0.001, 0.045)
			AudioSynth.normalize(b, 0.88)
			return AudioSynth.to_wav(b, sr)

		# --- Habitat ambience ---
		"amb.city.bed":
			var raw := AudioSynth.buf(3.6, sr)
			AudioSynth.add_tone(raw, sr, 0.0, 3.6, 55.0, 55.0, "sine", 0.28, 0.05, 0.05, false)
			AudioSynth.add_tone(raw, sr, 0.0, 3.6, 110.0, 110.0, "tri", 0.14, 0.05, 0.05, false)
			AudioSynth.add_noise(raw, sr, 0.0, 3.6, rng, 0.42, 0.05, 0.05, "lp", 320.0, 320.0, 0.9)
			AudioSynth.add_noise(raw, sr, 0.0, 3.6, rng, 0.18, 0.05, 0.05, "bp", 950.0, 1150.0, 1.4)
			var loop_b := AudioSynth.make_seamless(raw, sr, 0.4)
			AudioSynth.normalize(loop_b, 0.78)
			return AudioSynth.to_wav(loop_b, sr, true)
		"amb.hangar.bed":
			var raw := AudioSynth.buf(3.2, sr)
			AudioSynth.add_tone(raw, sr, 0.0, 3.2, 60.0, 60.0, "sub", 0.36, 0.05, 0.05, false)
			AudioSynth.add_tone(raw, sr, 0.0, 3.2, 120.0, 120.0, "saw", 0.12, 0.05, 0.05, false)
			AudioSynth.add_noise(raw, sr, 0.0, 3.2, rng, 0.34, 0.05, 0.05, "lp", 260.0, 260.0, 1.2)
			var loop_b := AudioSynth.make_seamless(raw, sr, 0.35)
			AudioSynth.normalize(loop_b, 0.78)
			return AudioSynth.to_wav(loop_b, sr, true)
		"amb.city.pa_chime":
			var b := AudioSynth.buf(1.6, sr)
			AudioSynth.add_fm(b, sr, 0.0, 0.72, 659.25, 659.25, 2.0, 0.5, 0.1, 0.55, 0.02, 0.45, false)
			AudioSynth.add_fm(b, sr, 0.55, 0.95, 523.25, 523.25, 2.0, 0.5, 0.1, 0.50, 0.02, 0.65, false)
			AudioSynth.bandpass_radio(b, sr, 420.0, 2100.0)
			AudioSynth.normalize(b, 0.80)
			return AudioSynth.to_wav(b, sr)
		"amb.city.creak":
			var b := AudioSynth.buf(1.1, sr)
			AudioSynth.add_fm(b, sr, 0.0, 1.0, 130.0, 92.0, 1.85, 2.4, 0.7, 0.55, 0.15, 0.45)
			AudioSynth.add_noise(b, sr, 0.05, 0.9, rng, 0.22, 0.12, 0.35, "bp", 420.0, 240.0, 2.4)
			AudioSynth.normalize(b, 0.76)
			return AudioSynth.to_wav(b, sr)
		"amb.city.breeze":
			var b := AudioSynth.buf(1.5, sr)
			AudioSynth.add_noise(b, sr, 0.0, 1.45, rng, 0.65, 0.40, 0.55, "bp", 680.0, 1180.0, 1.6)
			AudioSynth.normalize(b, 0.75)
			return AudioSynth.to_wav(b, sr)

		# --- Adaptive music stems (112 BPM, exact 4-bar / 16-beat = 189000 samples @ 22050 Hz) ---
		"music.hangar":
			return _build_music_hangar(sr, rng)
		"music.calm":
			return _build_music_calm(sr, rng)
		"music.combat":
			return _build_music_combat(sr, rng)
		_:
			var fallback := AudioSynth.buf(0.1, sr)
			AudioSynth.add_tone(fallback, sr, 0.0, 0.08, 440.0, 440.0, "sine", 0.4, 0.005, 0.04, false)
			return AudioSynth.to_wav(fallback, sr)


## 112 BPM -> 16 beats = 15/28 * 16 = 8.57142857 s = 189000 samples at 22050 Hz (phase-locked across stems).
static func _music_buf(sr: int) -> PackedFloat32Array:
	var n := int(round(float(sr) * (16.0 * 15.0 / 28.0)))
	var b := PackedFloat32Array()
	b.resize(n)
	return b


static func _build_music_hangar(sr: int, rng: RandomNumberGenerator) -> AudioStreamWAV:
	var beat := 15.0 / 28.0
	var b := _music_buf(sr)
	# Steady tactical D-minor prep pulse
	var bass_notes := [73.42, 73.42, 73.42, 65.41, 73.42, 73.42, 87.31, 82.41]
	for i in 16:
		var t := float(i) * beat
		var f: float = bass_notes[i % bass_notes.size()]
		AudioSynth.add_tone(b, sr, t, beat * 0.65, f, f, "sub", 0.42, 0.008, 0.14, false)
		if i % 2 == 0:
			AudioSynth.add_noise(b, sr, t, 0.04, rng, 0.14, 0.002, 0.03, "hp", 3600.0, 2400.0, 1.5)
	AudioSynth.add_chord(b, sr, 0.0, beat * 7.8, [293.66, 349.23, 440.0], "tri", 0.22, 0.18, 0.6)
	AudioSynth.add_chord(b, sr, beat * 8.0, beat * 7.8, [261.63, 329.63, 392.0], "tri", 0.22, 0.18, 0.6)
	AudioSynth.normalize(b, 0.80)
	return AudioSynth.to_wav(b, sr, true)


static func _build_music_calm(sr: int, rng: RandomNumberGenerator) -> AudioStreamWAV:
	var beat := 15.0 / 28.0
	var b := _music_buf(sr)
	# Orderly, slightly eerie sunlit occupation ostinato (D Dorian)
	var arp := [293.66, 349.23, 440.0, 392.0, 293.66, 329.63, 440.0, 493.88,
		261.63, 329.63, 392.0, 440.0, 293.66, 349.23, 329.63, 293.66]
	for i in 16:
		var t := float(i) * beat
		var note: float = arp[i]
		AudioSynth.add_fm(b, sr, t, beat * 0.72, note, note, 2.0, 0.45, 0.05, 0.34, 0.006, 0.22, false)
		if i % 4 == 0:
			var root := 73.42 if i < 8 else (65.41 if i < 12 else 73.42)
			AudioSynth.add_tone(b, sr, t, beat * 3.6, root, root, "sine", 0.38, 0.06, 0.40, false)
		if i % 2 == 1:
			AudioSynth.add_noise(b, sr, t, 0.035, rng, 0.10, 0.002, 0.025, "bp", 4200.0, 3200.0, 2.0)
	AudioSynth.normalize(b, 0.78)
	return AudioSynth.to_wav(b, sr, true)


static func _build_music_combat(sr: int, rng: RandomNumberGenerator) -> AudioStreamWAV:
	var beat := 15.0 / 28.0
	var b := _music_buf(sr)
	# Phase-locked 112 BPM industrial mech combat layer: punchy kick/snare + driving FM bass + stabs
	var bass_pat := [73.42, 73.42, 87.31, 73.42, 65.41, 65.41, 82.41, 73.42]
	for i in 16:
		var t := float(i) * beat
		# Kick on 1, 3 (and syncopated &)
		if i % 2 == 0:
			AudioSynth.add_tone(b, sr, t, 0.16, 118.0, 36.0, "sub", 0.68, 0.002, 0.12)
		if i % 4 == 3:
			AudioSynth.add_tone(b, sr, t + beat * 0.5, 0.14, 112.0, 38.0, "sub", 0.52, 0.002, 0.10)
		# Crisp industrial snare on 2 and 4
		if i % 2 == 1:
			AudioSynth.add_noise(b, sr, t, 0.14, rng, 0.45, 0.002, 0.10, "bp", 2200.0, 900.0, 1.1)
			AudioSynth.add_tone(b, sr, t, 0.08, 195.0, 110.0, "tri", 0.32, 0.002, 0.06)
		# Driving 8th-note FM bassline
		var bf: float = bass_pat[(i / 2) % bass_pat.size()]
		AudioSynth.add_fm(b, sr, t, beat * 0.42, bf, bf, 2.0, 1.8, 0.3, 0.40, 0.004, 0.08, false)
		AudioSynth.add_fm(b, sr, t + beat * 0.5, beat * 0.42, bf * 2.0, bf * 2.0, 1.5, 1.2, 0.2, 0.28, 0.004, 0.08, false)
		# Rhythmic metallic hat
		AudioSynth.add_noise(b, sr, t + beat * 0.5, 0.03, rng, 0.18, 0.001, 0.02, "hp", 5200.0, 3800.0, 1.4)
		# Brass-like combat stab every 4 beats
		if i % 4 == 0:
			var root := 293.66 if i < 8 else (261.63 if i < 12 else 329.63)
			AudioSynth.add_fm(b, sr, t, beat * 0.55, root, root, 1.0, 2.2, 0.6, 0.32, 0.008, 0.14, false)
			AudioSynth.add_fm(b, sr, t, beat * 0.55, root * 1.5, root * 1.5, 1.0, 1.8, 0.4, 0.22, 0.008, 0.14, false)
	AudioSynth.saturate(b, 1.35)
	AudioSynth.normalize(b, 0.84)
	return AudioSynth.to_wav(b, sr, true)
