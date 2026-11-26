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

## Open
- Gunship contact memory is wired but OFF (`contact_memory = 0.0`). With the drone's 8 s the corner wiggle fell from
  194.5 s to 47.0 s over 52 corner runs (seeds 4, 1, 403112; 20 s each, the strict 6 s / > 20 m / < 6 m / >= 6
  reversals metric), but test_wave_pursuit failed (seed 1 deck 1 shaft gunship min 69.1 m > its 68 m contact range):
  backed out. Next try: a shorter memory, or strafing toward the target rather than round the last seen point.
- Two arc-to-world direction rules remain (flier: x / tangent basis; gunship: arc offset through the ring) and two
  keep-in rules (drone: straight back across the edge, orbit flip with cooldown; gunship: toward the deck centre, flip
  every tick). Unifying them changes behaviour: a design decision, not a refactor.
