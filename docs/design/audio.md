# Audio System

Status: **implemented**, 2026-11-21. Parent: [game-design.md](game-design.md) §11, §13; [weapons.md](weapons.md);
[city-props.md](city-props.md). Net rules: `AGENTS.md`, [../networking.md](../networking.md).
Tunable live in the `audio` lab subject (`scripts/audio/audio_lab.gd`).

## 1. Sonic Identity

**Deadpan civil-defense industrial vs. sterile alien control.**

- **Played completely straight:** 8 m chicken-legged rescue walkers sound genuinely heavy, pneumatic, and devastating
  (damped ceramic-steel footsteps, reverse-joint servos, combustion thrusters, breech-clanking autocannons, deep mortar
  columns) so the stern oversized cartoon pilots read as dry comedy rather than wacky slapstick.
- **Stylized low-poly timbre:** Crisp, sculpted transients—layered sub-bass, state-variable filtered noise envelopes,
  2-operator FM mechanicals, and soft-clipped punch—avoiding muddy reverb tails or harsh raw square beeps.
- **Faction readability:** Player civil-defense gear uses warm mechanical/pneumatic low-mids and clean analog cockpit
  chimes. Hijacked alien-controlled robots carry cold, glassy harmonic FM carriers and synthetic lock-on chirps so
  off-screen threats cut straight through 4-player combat.
- **Subtle deadpan pilot cues:** On rare major player events (overheat shutdown, severe hard landing `severity >= 0.55`),
  a very restrained, narrow radio-bandpass (`600–2200 Hz`, `-10 dB`) intercom cue keyed to `head_id` (`chicken`,
  `pickle`, `corn`, `dog`). Toggleable via `Audio.pilot_cues_enabled` and in the `audio` lab.

## 2. Asset Pipeline (Zero-Binary Procedural Synthesis)

- `scripts/audio/audio_synth.gd` (`AudioSynth`): pure-GDScript deterministic DSP synthesizer outputting 16-bit PCM
  `AudioStreamWAV` streams (`22050 Hz` default, `44100 Hz` for crisp UI ticks), peak-limited to `<= -0.5 dBFS`, zero
  global randomness (every recipe seeds its own `RandomNumberGenerator`).
- `scripts/audio/sound_bank.gd` (`SoundBank`): declarative catalog of all cue IDs, mix metadata (bus, gain, pitch
  jitter, priority, cooldown, max voices, 3D profile, loop flag), two-tier loader (loads `res://assets/audio/<id>.res`
  if pre-baked, otherwise synthesizes lazily and caches in memory), and frame-budgeted incremental prewarming
  (`prewarm_step`).
- `tools/audio/gen_audio.gd` + `tools/audio/gen_audio.ps1`: CLI exporter that writes every synthesized cue as `.wav` to
  `test_logs/audio/` for offline auditioning (or `--bake` to `assets/audio/*.res`), printing duration, RMS, peak, and
  SHA-256 hash.
- **Headless safety (`--headless`):** Voice pool reclamation tracks explicit `expires_at` timestamps on `AudioDirector`'s
  clock rather than relying on Godot's `Dummy` audio driver firing `finished` signals, keeping voice stealing, cooldowns,
  and tests 100% deterministic headlessly.

## 3. Co-op Mix Architecture (4 Players × 5 Weapons)

### Bus Tree (`AudioServer`)
```
Master                 [AudioEffectLimiter: ceiling -0.5 dB, threshold -1.0 dB]
├── Music              (GameSettings["music"])
├── Ambience           (GameSettings["sfx"] × 0.70 trim)
└── SFX                (GameSettings["sfx"]) [AudioEffectCompressor: 2.5:1, -10 dB, 10ms/120ms]
    ├── SFX_Player     (0.0 dB; local mech locomotion, heat, own weapons, 2D hit-confirms)
    ├── SFX_World      (-2.0 dB; remote players, explosions, props, enemy foley/fire; 3D)
    ├── SFX_Telegraph  (+2.0 dB; enemy >=0.3 s wind-ups, mortar whistle, emergency burn, shutdown; NEVER ducked)
    └── SFX_UI         (-1.0 dB; menus, hangar mounts, slot toggles, dry clicks)
```

### Voice Pools, Priority Stealing & Ducking
- **Pools:** `12` 2D voices (`AudioStreamPlayer`), `32` 3D voices (`AudioStreamPlayer3D`), `8` managed loop handles.
- **Priorities:** `0` prop/distant foley, `1` standard weapon/impact/step, `2` local player/heavy blast, `3` telegraph/alarm.
  When full, steal lowest priority (tie-break: farthest from listener, then oldest); never steal priority `3` for lower.
- **Rate limits:** Per-cue `cooldown_ms` and `max_voices` (e.g., `wpn.gatling.fire`: `65 ms`, max `4`; `wpn.rockets.fire`:
  `55 ms`, max `4`; `impact.small`/`medium`: `40 ms`, max `6`; `prop.*`: `50 ms`, max `4`).
- **Priority ducking:** Active `SFX_Telegraph` or local heat `> 85%` / shutdown ducks `SFX_World` by `-3.5 dB` and `Music`
  by `-2.5 dB` (40 ms attack, 250 ms release). Nearby large blasts (`r >= 5.0` within `30 m`) briefly duck `Music` /
  `Ambience` by `-2.0 dB` for `0.4 s`.

### 3D Attenuation Profiles (200 m Curved Ring District)
| Profile | `unit_size` | `max_distance` | `attenuation_filter_cutoff_hz` | Role |
|---|---:|---:|---:|---|
| `foley` | 8 m | 55 m | 3500 Hz | Remote footsteps, servos, street props |
| `local_mech` | 22 m | 80 m | 9000 Hz | Local mech (compensates for 16 m `ChaseCamera` offset) |
| `weapon` | 18 m | 160 m | 4500 Hz | Remote/enemy weapons, small/med impacts |
| `explosion` | 30 m | 240 m | 2500 Hz | Rockets, mortar columns, kills |
| `telegraph` | 24 m | 140 m | 8000 Hz | Enemy telegraphs, mortar descent whistle |

## 4. Enemy ↔ Audio Signal Contract

`CombatAudio` (`scripts/audio/combat_audio.gd`) supports explicit binding (`bind_squad`, `bind_player_target`) and
automatic scene-group discovery (`"enemy_squad"`, `"player_target"`, `"city_props"`):

1. **`CombatWorld`** (`scripts/combat/combat_world.gd`):
   - `impact_spawned(point: Vector3, radius: float, explosive: bool, is_energy: bool)` (falls back to `shake` if absent).
   - Enemy fire records carry `"enemy": true` / `"team": "enemy"`, causing `CombatAudio` to layer `enemy.fire.accent`.
2. **`EnemySquad`** (group `"enemy_squad"`):
   - `enemy_event(kind: String, enemy: Node, payload: Dictionary)`:
     - `"telegraph_started"`: `{id, weapon, kind ("beam"|"cannon"|"mortar"|"pulse"), pos, target_pos, duration >= 0.3}`
     - `"telegraph_cancelled"`: `{id, reason}`
     - `"alerted"`: `{id, state ("spotted"|"relay"|"search"|"lost"), pos}`
     - `"weapon_fired"`: `{id, weapon, pos, aim_point}`
     - `"component_damaged"`: `{id, component, hp_ratio, weak_point, pos}`
     - `"component_destroyed"`: `{id, component, pos}`
     - `"overheated"` / `"rebooted"`: `{id, pos}`. The unit itself is heard (R2.27; no UI beep, nothing 2D):
       `enemy.overheat` is a power-down whine, 1.05 s: a sine falling 1400 -> 180 Hz (plus a triangle an octave down)
       whose level fades over ~0.95 s, turbine FM and band-passed servo grit under it, ending in a soft 72 -> 38 Hz thunk.
       `enemy.reboot` is a spin-up, 0.80 s: 220 -> 1250 Hz over 0.58 s with servo grit, then a short steady 1250 Hz hold.
       Both are 3D at the unit on `SFX_World` with the `weapon` profile (as `enemy.fire.accent`: 160 m), cue level
       -7 / -9 dB (clearly under gunfire), priority 1 (never takes a weapon voice; one-shots never touch the loop
       pool), cooldown 60 ms, prewarmed. Pitch follows the unit's size: `(4 / explosion_radius)^0.3`, clamped
       0.85..1.2 (a tank is lower than a trooper). On the host a unit reports the transition twice (its `Heat` signal
       and this squad event); on a client only the event arrives (EnemySync replays the host's `heat` event).
       `CombatAudio._play_unit_heat` plays one cue per transition per unit id.
     - `"destroyed"`: `{id, cause, pos, radius}`
     - `"footstep"`: `{id, pos}`
3. **`PlayerTarget`** (group `"player_target"`):
   - `damaged`, `staggered_by`, `player_component_destroyed(component: String)`, `player_disabled(cause: String)`.
4. **Direct Facade (`Audio` autoload):**
   - `Audio.play_enemy_telegraph(owner_id, kind, world_pos, duration)` / `Audio.cancel_enemy_telegraph(owner_id)` /
     `Audio.play_enemy_alert(state, world_pos)`.

## 5. Networking Contract Compliance

All audio state is strictly **cosmetic (`Net.LOCAL`)**:
- Zero gameplay state is written by any audio script.
- Every random variation (pitch/gain jitter, ambient scheduling, noise synthesis) uses a dedicated seeded
  `RandomNumberGenerator` (`looks_rng` or recipe seed), never global `randf()`/`randi()`.
- Zero network or Steam API calls exist in `scripts/audio/`.
