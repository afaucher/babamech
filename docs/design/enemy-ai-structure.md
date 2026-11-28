# Enemy AI structure (scripts/enemy/)

As built 2026-11-26 (behaviour-preserving refactor; characterisation traces identical before / after).

## Classes
- `EnemyBase` (enemy_base.gd): everything every enemy has (HP / components, wreck, perception `_acquire_target`, steering,
  transit, staging, attack slots, puppets) and **the one AI state machine**, `_step_ai`, a template method.
- `EnemyStrider`, `EnemyTank`, `EnemyTurret`: no AI code of their own; only `_track_aim` / `_sensor_yaw` / visuals.
- `EnemyTrooper`: the trooper's hooks (peek pose, fire token, fireteam alert, its engage step: cover, scatter, jump pack).
- `EnemyFlier` (enemy_flier.gd, extends EnemyBase): what the fliers share: hover plane, knockback damping, aerial
  wreck, the free flight step `_fly_toward` (altitude floor / ceiling with the low-exit rule, ramp / roof climb,
  `edge_repulsion`, side-keeping sidestep, keep-in and goal hooks), `_hover_station`, `_fly_hunt_path`,
  `_tall_line_blocked`, `has_art_mesh`, and **contact memory** (`contact_memory` s; `_contact_held`).
- `EnemyDrone`, `EnemyGunship`, `EnemyDropDrone` extend `EnemyFlier`. The drone and the dropship replace `_ai_live`
  (beacon / standoff orbit; drop flight phases); the gunship uses the base live step with its own hooks.

## One tick (`EnemyBase._step_ai`)
`_ai_timers` -> ai_mode idle (`_ai_idle_pose`) | overheat / shutdown / stagger (`_hold_disabled`, `_on_ai_disabled`) ->
`_resume_from_disabled` -> `_ai_live`. Base `_ai_live`: ramp transit -> `_ai_perceive` -> no target: `_ai_no_target`
(`_on_target_dropped`, then `_ai_search` or `_ai_wander`) -> `_ai_note_target` -> IDLE / PATROL: `_enter_alert` +
`_on_spotted` | ALERT: delay + `_track_aim` | TELEGRAPH: `_ai_telegraph` | FIRE: `_ai_fire` | else `_ai_engage`.
Fire: `_step_firing` with `_burst_interval`, `_burst_cooldown`, `_on_burst_done`; `_fire_one_round` with
`_extra_spread`, `_pellets`. Others: `_choose_weapon`, `_telegraph_has_line`, `_sensor_yaw`, `_track_aim`.
Flight (`EnemyFlier._fly_toward`): `_air_fly_timers`, `_air_steer_goal`, `_air_keep_in`, `_on_air_wall`,
`_air_after_move`, and tuning `_air_alt_min`, `_air_low_floor`, `_air_descend_rate`, `_air_repel_weight`,
`_repel_min_h`, `_air_turn_default`, `_air_speed_default`, `_air_knock_damp`, `_air_timers`, `_arc_dir_to_world`.

## Adding a behaviour (e.g. anti-air)
- Never override `_step_ai`. Pick the narrowest hook: who is seen (`_ai_perceive`, or `_acquire_target`'s target filter),
  what to do when engaged (`_ai_engage`), the wind-up / burst (`_ai_telegraph`, `_ai_fire`), the weapon pick
  (`_choose_weapon`), aim (`_track_aim`: return the aim error; pitch limits live there), the telegraph's line rule
  (`_telegraph_has_line`). Call `super` when you add to a hook rather than replace it.
- A flier behaviour that every flier needs goes in `EnemyFlier`; tune per class through the `_air_*` hooks.
- New vars go in the class's `net_fields()` (test_net_contract). Telegraphs stay >= 0.3 s; seeded RNG only.
- Prove a refactor with traces (state, target, position, telegraph / fire / alert events, puppet_state per tick);
  the 2026-11-26 harness was temporary (see docs/coordination/antigravity.md for how it was built).

## Overheat look (R2.27, 2026-11-26; presentation only)
- Nothing floats over an enemy but the HP bar (`EnemyStatusBar.refresh(hp_ratio, dead)`, R2.26). Overheat reads from the
  unit, like the player mech (radiator glow, MechRig sag).
- `EnemyGlow`: every enemy mesh's lit surface is ONE shared ShaderMaterial (`EnemyMeshes` commits with
  `EnemyGlow.materials()`), driven per MeshInstance3D by instance uniforms: `vent_heat` (-1 = the old constant look;
  0..1 = the VENT_GLOW fins from a dim ember through orange to white-hot), `lights` (optics / lamps, every other lit
  face), `optic_heat` (troopers: the visor carries the heat ramp, their fins are only on jump packs). Fins are found by
  vertex colour; `vent_color(h)` mirrors the shader for tests. No per-unit material, so batching is unchanged.
- `EnemyHeatLook` (`e.heat_look`, Net.LOCAL): stepped first in `_update_visuals` (`_step_heat_look`; the drone and the
  dropship call it themselves). Shut state from the unit's own `overheated` / `rebooted` signals: the host's
  heat.shutdown edge in `tick`, and on a client EnemySync's replay of the host's reliable heat event; the same moments
  the squad's "overheated" / "rebooted" events fire, which CombatAudio plays (`enemy.overheat` / `enemy.reboot`), so
  look and sound line up on every machine. If the replicated `heat.shutdown` disagrees for 0.5 s it is adopted silently.
  Fin glow = heat fraction (host gauge; puppet: the stream's u8), quantised to 1/24, written at 10 Hz when it moves.
- Timing from the moment: shutdown: lights stutter out in 0.25 s, `slump` 0 -> 1 on an underdamped spring (~0.6 s,
  ~20 % overshoot), steam every 0.22 s while the fins are above half heat. Reboot: lights flicker back over 0.7 s, the
  body rises from +0.3 s (settled by ~0.9 s).
- Units read `heat_look.slump` on VISUAL pivots only (hit spheres follow the root): strider hips -0.55 m (knees bend over
  planted feet), torso -22 deg and a small list, sensor nods; trooper crouches and slumps forward 0.35 rad; turret gun
  -24 deg; tank barrel -12 deg; drone / gunship / dropship (`flier_offsets`, x1 / x0.8 / x0.6): the bob dies, nose down
  0.3 rad, sink 0.25 m (inside the bob envelope), roll wobble 0.12 rad at 5.5 rad/s. A wreck goes back to the plain look.
- Most fins sit at the rear (turret, strider, tank): from the front the shutdown reads from the dark optics, the slump
  and the steam above the unit; the glow ramp reads from the side / rear.

## Open
- Gunship contact memory is wired but OFF (`contact_memory = 0.0`). With the drone's 8 s the corner wiggle fell from
  194.5 s to 47.0 s over 52 corner runs (seeds 4, 1, 403112; 20 s each, the strict 6 s / > 20 m / < 6 m / >= 6
  reversals metric), but test_wave_pursuit failed (seed 1 deck 1 shaft gunship min 69.1 m > its 68 m contact range):
  backed out. Next try: a shorter memory, or strafing toward the target rather than round the last seen point.
- Two arc-to-world direction rules remain (flier: x / tangent basis; gunship: arc offset through the ring) and two
  keep-in rules (drone: straight back across the edge, orbit flip with cooldown; gunship: toward the deck centre, flip
  every tick). Unifying them changes behaviour: a design decision, not a refactor.
