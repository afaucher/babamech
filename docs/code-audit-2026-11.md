# babamech code audit (independent, not authoritative)

Source: the claude.ai doc "babamech code audit" (https://claude.ai/artifact/ELGn461FKuUPzCJmjmQs6b), reviewed at commit 3dbbb31, copied here 2026-11-25 for the next milestone. Not verified: the test suite was not run for the review.

· 

### Summary

babamech has strong guardrails (a networking lint, deterministic seeded plans, multi-process co-op tests), but copy-pasted logic and very large files are where its bugs are breeding. The test suite was not run for this review, so every bug below comes from reading the code.

The top items, in order:
- **Fix the leaver decoy.** A player who drops mid-mission leaves a frozen mech that enemies keep shooting and that can never die (`crew_sync.gd:39-56`; nothing outside `scripts/net/` handles `peer_left`).
- **Fix enemy alert state.** Staggered or overheated enemies re-alert on every hit, then forget they were fighting (`enemy_base.gd:441`).
- **Check the mortar on curved decks.** It uses world up for its arc, knockback and range on a ring where up changes over its 250 m reach (`mortar_shell.gd:97-150`).
- **Drop remote shot copies after a hit.** `CombatWorld.remove_shot` is only called by tests, so one shot can land twice in co-op.
- **Merge the three copies of the enemy AI state machine** and add a flier base class. Bugs 2, 5 and the gunship jitter all spread through these copies.
- **Delete the dead paths.** The spawn-wave stub, the closed-source pacing path and about 28 unreferenced functions can go now. Then decide whether the old clear-and-extract and district modes stay, since most headless tests still run the non-default mode. *(Decided 2026-11-25, "Cut the legacy modes."; mission side done 2026-11-26: see the legacy-modes entry below.)*
- **Split the ten files over 1,200 lines**, starting with `city_plan.gd` (3,042) and `enemy_base.gd` (2,815), and rename the production `TestDrive` scene.
- **Fix the 42 tests whose timeout never applies** (`test_case.gd:14-24`), then add a headless CI run.

### Repo map

babamech is a Godot 4.7 GDScript game of about 97,000 lines in 242 scripts, with 55,000 more lines of tests. It was reviewed at commit 3dbbb31 (Nov 24, 2026), statically: the test suite was not run.
- **Entry:** `scenes/boot.tscn` runs `scripts/app/boot.gd`. Autoloads are `Session` (`scripts/net/net_session.gd`) and `Audio` (`scripts/audio/audio_director.gd`). The four scenes are thin; all UI is built in code.
- **Tooling:** PowerShell at the root (`run.ps1`, `lab.ps1`, `build.ps1`, `test_runner.ps1`, `godot_env.ps1`, `hidden_desktop.ps1`), so builds and tests are Windows-only. `tools/` holds 15 probe and benchmark folders.
- **Tests:** 253 test scripts in one flat `tests/` folder, including multi-process ENet co-op tests and a lint (`tests/test_net_contract.gd`) that enforces the networking rules and bans global randomness. No global `randf`/`randi` calls were found in `scripts/`.
- **History:** 8 commits over Nov 21 to 24, each touching 49 to 823 files.
| Area | Files | Lines |
| scripts/world (city, life, section, occupation, depot) | 50 | 32,400 |
| scripts/combat + mech + pilot | 80 | 18,600 |
| scripts/enemy + ai | 29 | 17,500 |
| scripts/game | 25 | 11,500 |
| scripts/ui + app + test_support | 26 | 8,200 |
| scripts/net | 19 | 4,300 |
| scripts/audio + fx | 8 | 3,800 |

### Bugs

The worst bugs are in co-op and enemy AI: a player who drops leaves an unkillable decoy, and staggered enemies forget they were fighting. Confirmed means the path was traced through the code and its callers. Plausible means the code reads wrong but the outcome depends on runtime state that wasn't exercised.

#### High impact
- **A player who leaves mid-mission becomes an invulnerable decoy.** Confirmed. `scripts/game/crew_sync.gd:39-56` registers a `PlayerTarget` for every launch member, and nothing outside `scripts/net/` listens to `Session.peer_left`. The puppet freezes on its last snapshot (`net_mech_stream.gd:195`) and enemies keep targeting it (`enemy_base.gd:1858`). Hits go to an owner who is gone, so it never goes down and soaks fire for the rest of the mission. Fix: on `peer_left`, unregister the target and free the puppet.
- **Staggered or overheated enemies re-alert on every hit, then forget they were fighting.** Confirmed. `is_alerted()` (`enemy_base.gd:441`) leaves out STAGGERED and OVERHEATED. Each hit on such a unit re-runs `_enter_alert` (`:1237`), sending another reliable net message and music bump. When it recovers, `_acquire_target` (`:1845`) treats it as unalerted, so it drops to the short notice cone and has to re-notice the crew. The drone has the same check (`enemy_drone.gd:292`).
- **The mortar assumes world +Y is up on a curved ring deck.** Plausible, high impact. The arc and heading add `Vector3.UP` (`weapons/mortar_shell.gd:97, 102`), direct-hit knockback zeroes `.y` (`:146-150`) and the range gate measures XZ distance (`weapons/mortar.gd:145`). The deck radius is 300 m or more and the mortar reaches 250 m, so the deck tilts a lot between muzzle and target. `CombatWorld._splash` already uses the target's own up (`combat_world.gd:1136`), so splash and direct hits push in different directions.
- **Other machines never drop their copy of a shot after it hits.** The missing call is confirmed; the double hit is plausible. `CombatWorld.remove_shot` (`combat_world.gd:533`) is only called from tests. If A's shell hits an enemy on A's machine but flies on and hits B's mech on B's machine, the same shot lands twice.
- **A trooper firing from cover cancels its own telegraph every tick.** Confirmed logic. `enemy_trooper.gd:560` allows fire with peek line of sight while `_has_los` is false, and the base `_step_telegraph` (`enemy_base.gd:1666`) cancels on `not _has_los`. No cooldown is set, so the trooper loops telegraph-started / cancelled events with no shot.
- **A pruned attack slot leaves the unit thinking it still holds one.** Confirmed. `prune_attack_slots` (`enemy_squad.gd:1463-1477`) erases the slot but never clears `EnemyBase._has_slot`, and `_request_slot` (`enemy_base.gd:1788`) returns true when it's set. A unit whose deck slept and woke fires on top of the `max_attackers` limit.
- **Dropship troopers can hunt the defend relay.** Confirmed. `enemy_drop_drone.gd:790-799` picks the nearest `team == "player"` target without excluding `AssetTarget`, then calls `hear_fire` and `begin_hunt_pursuit` on it (`:826-828`). `EnemySquad._nearest_player_on_deck` (`enemy_squad.gd:497`) already does it right; call that instead.
- **Mission pacing scales from the live roster, not the launch crew.** Plausible. `mission_flow.gd:232` and `asset_max_hp()` (`:792`) use `crew_size()` (`:767`), which reads the current roster at a different moment on each machine. Garrisons and depots use the launch crew. If a slow peer is kicked during load, the director scales for 3 while garrisons spawned for 4, and host and clients can disagree on relay HP.
- **About 42 tests silently keep the 60 s timeout.** Confirmed. `test_case.gd:14-24` starts the Timer before `setup()` runs, so tests that set `timeout_sec` inside `setup()` (for example `test_city_stack.gd:12`, `test_mission_world.gd:18`) are still killed at 60 s, and the failure message prints the new value. Start the timer after `setup()` begins or read the value in `_init`.
- **Two gameplay layouts are outside the load checksum.** Confirmed gap. Prop layout comes from `cosmetic_seed()` (`city_props.gd:125`), yet props are host-arbitrated by index and block shots; `layout_checksum` (`:214`) is only called from tests. Air-door placement depends on the cosmetic `CitySigns` (`mission_world.gd:215, 347-351`). Tweaking a sign constant moves wall cuts and enemy entry points with no checksum change.

#### Medium and low
| Bug | Where | Confidence |
| Destroyed hardpoint keeps its hit sphere and absorbs side shots for 0 damage | `player_target.gd:282-286, 323-326` | Confirmed |
| Join picks a lobby already on a mission, then gives up | `net_session.gd:1060-1074` | Confirmed |
| Settings restart drops args after `--` (settings file, name) | `graphics_quality.gd:313-315` | Confirmed |
| Release export ships `tests/` (not in exclude_filter) | `export_presets.cfg:15` | Confirmed |
| `build.ps1` kills every running babamech, including other sessions | `build.ps1:203` | Confirmed |
| `damaged` signal reports requested damage, not dealt; inflates logs and bot metrics | `combat_target.gd:182`, `player_target.gd:325` | Confirmed |
| Fall-damage cap uses Strider leg HP for every chassis | `player_target.gd:339` | Confirmed |
| Reboot timer doesn't restart when heat climbs again during shutdown | `mech_controller.gd:326-330` | Confirmed |
| `PlayerTarget` writes mech heat/shutdown directly; `rebooted` never fires | `player_target.gd:398, 539` | Confirmed |
| Bot never dodges a restarted telegraph; seen-sets grow forever | `player_bot.gd:407, 153` | Confirmed |
| Gunship still uses the obstacle push the drone fixed for corner jitter | `enemy_gunship.gd:668-684` | Plausible |
| Forcing a primary shifts the RNG for later decks, against the doc | `mission_plan.gd:398` | Confirmed |
| Queued scout calls never expire and suppress arrival rest | `pacing_director.gd:486-500` | Plausible |
| Wrecked pod miscounts riders still exiting; riders respawn | `life_fleet.gd:408, 580-584` | Confirmed |
| Only 8 loop voices, no stealing; extra loops go silent | `audio_director.gd:337` | Plausible |
| Rocket can detonate twice at exactly max range | `rocket.gd:118-121` | Plausible |
| Pillar-block alley move compares off-grid floats with ==, so it almost always fails | `city_plan.gd:2279` | Plausible |
| Ghost Steam lobby if creation lands after the open timeout | `steam_lobby.gd:156-166` | Plausible |
| Invites auto-accept; the documented ask-first flow is unused | `front_end.gd:504-506` | Confirmed |
| Peer-supplied prop count is unbounded on restore | `city_props.gd:719` | Confirmed |

### Dead code

About 28 functions have no reference anywhere, and two whole fallback paths can no longer run. Every name below was searched across `scripts/`, `tests/`, `tools/`, `scenes/` and string calls; none is built from concatenated strings. About 100 more functions are only called by tests, which is mostly deliberate test seams and not listed here.

#### Paths that can no longer run (remove first)
- **The spawn-wave stub in MissionFlow.** `EnemySpawner.spawn_wave` now exists (`enemy_spawner.gd:454`), so the `load(SPAWNER)` / `_has_static` fallback, the `unspawned` list and the stale `TODO(antigravity)` comments (`mission_flow.gd:40-42, 82, 118, 613-614, 696-705`) are dead. Loading the spawner by path string also hides the dependency from the parser. Call `EnemySpawner.spawn_wave` directly.
- **The closed-source path in PacingDirector.** MissionFlow always passes `"closed": []` (`mission_flow.gd:506`), so the `closed` parsing (`pacing_director.gd:374`), the `dropped` flag (`:437, 450, 976`) and the `closed` parameters through `_try_release` / `_pick_*` never do anything. No test sets it.
- **Unreachable branches:** the fixed-arc `else` in `WeaponMount._check_fixed_arc` (`weapon_mount.gd:207-208`), which makes `Combat.in_fixed_arc` and `FIXED_ARC_YAW/PITCH_*` dead in practice; the `drive.mechs` fallback in `_pilot` (`mission_depots.gd:753-761`); the else branch of `patrol_allowance()` (`pacing_director.gd:281`).
- **Stand-in mission plan.** `MissionLab.make_plan` finds `MissionPlan` by reflection (`mission_lab.gd:61-72`) and falls back to `MissionWorld.stand_in_plan` (`mission_world.gd:1478`, about 46 lines) plus duck-typed `field(plan, ...)` access to support both shapes. `MissionPlan` exists now.

#### Legacy modes: decide keep or cut

The old clear-and-extract mode (`--no-objectives`) and the district mode (`MODE_DISTRICT`) are both still live. Objectives is the shipped default, but `TestDrive.objectives` defaults to `false` (`test_drive.gd:86`) and only takes the setting when the scene is current (`:207`). Only about 20 of 65 test files that build a TestDrive turn objectives on, so most of the headless suite exercises the non-default mode. Either delete the old modes (roughly 300 lines across `mission_flow.gd:302-313`, `mission_bot.gd:849-863, 978-1008` and the district branches) or make the TestDrive default match settings and test the old modes explicitly. **Status 2026-11-26 (mission side done, user 2026-11-25 "Cut the legacy modes.")**: MissionRules has one mode (the plan; a section always has one), MissionFlow always runs a plan for a TestDrive with objectives on, `--no-objectives` and the objectives setting are gone (`--objectives` a no-op, `objectives_wanted()` always true), and every mission-side and narrow test now runs the objectives mode or the TEST-ONLY QuietSectionFixture (docs/testing.md "Fixtures"). The old evaluator survives only as the transitional `LegacyClearRules` for TestDrive's `objectives = false` default; the Engine session's pass removes `TestDrive.objectives` / `Session.objectives` / the hangar box / `MODE_DISTRICT` and `--district` and MissionBot's non-plan branches, then deletes that shim.

#### Functions and constants with no references
| Area | Unused |
| net | `NetSession.set_members`, `NetMechStream.is_puppet`, `owned_ids`, `NetEnemyCodec.entry_size` |
| enemy, ai | `EnemySquad.staged_waves`, `in_floor_cut`; `EnemyBase.rolling_out`; `EnemyDropDrone._drop_height`, `_exfil_target_world`; `EnemyGunship.ALT_CRUISE`; `PlayerBotSquad.all_disabled`, `bot_index_of` |
| combat, mech | `FlameChunk.hit_something`, `PlayerTarget.hardpoint_center`, `Gatling.barrel_speed`, `CombatNet.remote_charges`, `MechMeshes.build_torso`, `BulwarkMeshes.pod_shell`, `PilotExpressions.MOOD_ORDER` |
| game, audio | `MissionBot.FF_CLEAR`, `FF_SPLASH`; `DownedRules.RESPAWN_NEAR_OBJECTIVE`; `SoundBank.is_cached`; `TestDrive._load_label` and its 11-line build |
| world | `LifeTraffic.rejoin_time`, `gap_behind`; `AmbientLife.set_people`, `tram_state`; `LifeTram.extent_of`, `restart_time`; `SectionPlan.s_of`, `theta_of`; `PacingDirector.source_of`, `REVEAL`, `STATES`; `OccupationBanners.reset_all`; `MissionWorld.GATE_OPEN`, `LIFT_POINT` |
| ui | `MechDiagram.VIEW_LABEL`, `STYLE_LABEL` |

#### Signals and state nobody reads
- **Signals emitted, never connected:** `Session.peer_left` and `link_changed` outside `scripts/net/` (the first is bug 1), `TestDrive.mission_loaded`, `PlayerTarget.redeploy_started`, `CombatNet.host_hit_applied`.
- **Written, never read:** trooper `_stomped` and `_shots_fired` (`enemy_trooper.gd:102-104`), `EnemyTroopSquad.squad_id`, `BotMetrics._total_player_hits`, `CitySite.fixed`, `NetSession.host_unix_epoch` (its comment says tests use it; none do).
- **Overwritten defaults:** `DECK_CAP` and `DEFEND_EVERY` go into options and are replaced at once by the `*_BY_CREW` tables (`pacing_director.gd:205-213`).

#### Leftover files and content
- Five orphan `.uid` files with no script: `tests/test_combat_tmpdebug`, `test_mech_facing`, `test_tmp_jets`, `test_tmp_prof`, `tmp_perfsplit`.
- `life_pod_variants.gd` (585 lines) keeps 9 candidate pod meshes, but the game only calls `adopted()` (`:79`) since the Nov 22 pick; the other 8 only feed the lab gallery.
- The 7 look-only enemy weapon files plus `autocannon` share near-identical `spawn` bodies (see Maintainability).

### Maintainability

The biggest maintainability cost is copy-pasted logic: several of the bugs above exist because a fix landed in one copy and not the others. Ranked by how much each would prevent future bugs.
- **Give the enemy AI one state machine with hooks.** The base `_step_ai` (`enemy_base.gd:1474-1583`), the trooper (`enemy_trooper.gd:445-576`) and the gunship (`enemy_gunship.gd:229-362`) repeat the timers, stagger/overheat handling, no-target block and line-of-sight bookkeeping line for line. `_step_firing` / `_fire_one_round` are also copied (`enemy_base.gd:1727-1740` vs `enemy_trooper.gd:578-595`). Override hooks like `_on_no_target`, `_movement` and `_try_attack` instead. Bugs 2 and 5 both spread through these copies.
- **Add an ****`EnemyFlyer`**** base for drone and gunship.** `_fly_toward` is about 70% identical (`enemy_drone.gd:572-716` vs `enemy_gunship.gd:500-632`), along with `_air_ray_hit`, `_arc_to_world_alt`, two different `_arc_dir_to_world`s and six `_air_*` fields. The gunship's stale obstacle push is a direct result.
- **Type your references instead of duck-typing them.** `EnemyBase.squad` is a plain `Node` (`enemy_base.gd:84`), so the enemy code calls `has_method` about 74 times. MissionFlow and MissionDepots check `has_method` or `"x" in drive` for members that exist (`mission_flow.gd:520, 597, 630, 732, 754, 769, 771, 826`; `mission_depots.gd:541, 586, 614, 880`). Typed references let the parser catch renames.
- **Stop reaching into other classes' private members.** `ShaderWarmup` reads five private caches (`CombatMeshes._cache`, `ImpactFx._meshes`, `LowPolyFlame._cache`, `EnemyMeshes._cache`, `RailSlug._ribbon_shader`); give each a public `warmup()`. Others: `NetEnemyStream` uses `NetMechCodec._put_i24`, `MissionFlow` and `MissionBot` read `drive._held`, `combat_log.gd:228` reads `mf._sent`, `BulwarkMeshes` calls `MechMeshes._cap` and `_bolt_ring`.
- **Pick one heat gauge.** `Heat` (`heat.gd`, no reboot timer) and `MechController` (`mech_controller.gd:312-331`, with `reboot_time`) are bridged by `WeaponRack.MechHeat` and a fork in `PlayerTarget.apply_heat` (`:369-375`). A player's `PlayerTarget.heat` is declared OWNER state but never ticked.
- **Make the determinism contract auditable.** About nine seed-mixing formulas use different primes (`city_plan.gd:145, 229, 1120, 1567, 1757, 2237, 2382, 2498`, `city_buildings.gd:51`), and the depot "own generator" reuses SectionPlan's exact seed (`mission_plan.gd:663` vs `section_plan.gd:334`). One `_sub_seed(tag, deck, index)` helper would make collisions and gameplay-versus-looks intent visible. Rename or split `cosmetic_seed()` since it drives gameplay props, and add props and air doors to `CityStack.checksum()` (bug 10).
- **Replace position-indexed and duplicated mission state.** PacingDirector parses MissionRules' `objs` arrays `[state, progress, total]` by position (`pacing_director.gd:650, 984`). Snapped sites are stored in both MissionRules and PacingDirector (`mission_rules.gd:214`, `pacing_director.gd:292`) and kept in step by hand (`mission_flow.gd:245-246`). `_last[k]` holds an index into `_groups` that `_unmake_patrol` erases from (`:722, 827`). Use small typed records or ids, and keep sites on MissionPlan.
- **Pull profiling out of the hot paths.** `CombatWorld.advance` and `_advance_profiled` duplicate the same steps (`combat_world.gd:459-487` vs `490-522`), `if profiling` forks run through eight more functions, and `CombatWorld.profiling` appears 18 times in `enemy_base.gd`. A scoped timer helper removes both.
- **Fold small duplicates into shared helpers.**
- The palette one-liner `c()` has five private copies (`city_buildings.gd:108`, `city_signs.gd:77`, `city_streets.gd:37`, `mission_props.gd:14`, plus `CityPalette.c`).
- The chunked build-queue runner is written three times (`city_district.gd:67-121`, `city_stack.gd:123-200`, `mission_world.gd:122-170`).
- `_carve` and `_carve_geom` are near copies (`city_plan.gd:590-635`, `1202-1249`).
- `MissionPlan.make(...)` is built three times (`test_drive.gd:468, 831`, `mission_flow.gd:230`).
- Audio pool loops repeat six times in `audio_director.gd`; jitter-buffer targeting is shared logic in `net_puppet_buffer.gd:381` and `net_enemy_buffer.gd:176`.
- Repeated constants: Strider radius 2.2 in four files, `LAUNCH_ALERT_TIME` copies `NetMission.LAUNCH_LEAD`, default head/chassis in both `NetSession` and `GameSettings`, the link presets list in `front_end.gd:255`.
- **Break up the longest functions.**
| Function | Lines | Split along |
| `SoundBank.synthesize` (`sound_bank.gd:309`) | 664 | one recipe function per sound in a dictionary |
| `PacingDirector.tick` (`pacing_director.gd:362`) | 232 | ingest, follow-ups, scouts, deck state, quiet cap, build |
| `CityLab._apply_view` (`city_lab.gd`) | 208 | one function per view |
| `TestDrive._finish_setup` | 145 | city, combat, crew, life |
| `EnemyBase._steer_toward` (`enemy_base.gd:2251`) | 145 | avoidance, unstick, final velocity |
| `PilotHead.advance` (`pilot_head.gd:397`) | 133 | expression, gaze, physics |
| `MenuBackdrop._hall_mesh` (`menu_backdrop.gd:664`) | 128 | per mesh section |
- **Clean up text a tool corrupted.** About 14 lines had `\` line continuations turned into tabs (for example `front_end.gd:280`, `pacing_director.gd:807, 1083`, `enemy_sync.gd:430`). Two strings had `\n` turned into a literal newline (`front_end.gd:277`, `weapon_range_lab.gd:408`), and `test_runner.ps1:16` reads `tests<tab>est_visual_coop.gd`. They still work, but they read as broken and the next edit may break them. `combat_world.gd:589, 1019, 1067` have mojibake.
- **Follow your own rules consistently.** `set_anchors_preset` is still used on in-tree Controls (`front_end.gd:102`, `lab.gd:300, 359`, `build_version.gd:156`), which AGENTS.md calls out as the empty-screen bug. Static mutable state (`CityBuildings._vr`, `_corner`, `CitySigns.style`, `Combat.FIXED_ARC_ENABLED`) hides inputs and leaks across scenes. Settings are saved and broadcast on every keystroke and slider tick (`front_end.gd:224`); debounce them.

### Organization

The folder layout by system is sound, but ten files have grown past 1,200 lines, the docs no longer describe the code, and the repo is a 1.2 GB clone. Ranked by payoff.
- **Split the ten largest files along the seams they already have.** Each already groups its functions by section, so these are mostly moves.
| File | Lines | Proposed split |
| `world/city/city_plan.gd` | 3,042 | `CityDowntown` (`:1073-2208`, already on its own generators), `CityVariety` (alleys and road forms, `:2209-2694`), `CityGraph` (road and walk graphs, `:2695-2962`), `CityRamps` (`:298-430`); keep grid, lots, roofs, checksum |
| `enemy/enemy_base.gd` | 2,815 | wreck effects (`:801-1230`), perception (`:1806-2030`), steering and unstick (`:2031-2510`), deck transit (`:531-610`) |
| `game/mission_bot.gd` | 2,345 | helpers with their own state for depot (`:317-413`), revive (`:416-583`), perch/roof, dev travel, zone hold; today about 120 vars share one `net_fields` |
| `world/life/ambient_life.gd` | 2,247 | stack router, net layer (snapshot, restore, events), hit tests, per-deck drawing |
| `world/section/section_plan.gd` | 2,004 | grid and pillars, connectors and walk repair, road forms, encounter sites |
| `enemy/enemy_squad.gd` | 1,996 | waves (`:275-480`), hearing (`:1297-1435`), slots, dropship and air doors (`:920-1158`), nav/A* (`:1507-1996`) |
| `mech/mech_meshes.gd` | 1,621 | a palette/materials module (41 files outside `scripts/mech` use `MechMeshes.GREY` etc.), a shared part cache, separate builders |
| `net/net_session.gd` | 1,575 | handshake, roster and bots, dev flags and Steam probe; drop the forwarding layer to NetMission (`:607-680`) |
| `game/combat_log.gd` | 1,379 | shot pairing, line-of-sight and threat, deck summaries |
| `combat/combat_world.gd` | 1,242 | prop and deck queries and the mesh pool out of the hit core |
- **Rename TestDrive and give mission logic one home.** The production mission scene is still `TestDrive`, and it holds mission logic: the garrison share (`test_drive.gd:831-837`) and 4 Hz polling of `mission.rules.state()` that MissionFlow could emit as signals (`:616`). The end flow is split three ways (`_tick_end`, `finished`, `Session.mission_ended`). Move mission rules into MissionFlow, its HUD model (`mission_flow.gd:954-1071`) into its own class, and rename the scene.
- **Make look-only weapons data, not files.** The real behaviours (gatling, laser, railgun, mortar, flamer, missiles, flak) earn their own files. The 7 look-only `enemy_*` weapons and `autocannon` repeat one `spawn` body, and the three enemy rocket files skip `Rocket.prewarm_rocket`, so their first shot builds meshes mid-fight. Catalog keys like `look` and `flight: projectile | rocket | mortar` with one generic behaviour would replace them. Laser and railgun charge logic (`laser.gd:143-166`, `railgun.gd:91-119`) could share a base.
- **Get images out of git history.** A clone is 1.2 GB: 667 MB of `.git` and 574 MB under `docs/`, mostly concept-art PNGs up to 15 MB (`docs/design/city-downtown/grid_downtown.png`). Move renders to Git LFS or out of the repo before history grows further. The 8 commits each touch 49 to 823 files, which makes `git bisect` and review nearly useless; smaller commits per feature would help.
- **Bring the docs back in line with the code.**
- README says "Status: scaffold... There is no mission yet" while describing objectives, depots and the pacing director.
- AGENTS.md says "Nothing in gameplay is synced yet", and its Layout section covers 6 of the 15 script folders (no `enemy/`, `game/`, `combat/`, `ai/`, `world/life`, `world/section`).
- The `build.ps1` header says it copies the GodotSteam DLLs (it copies only `steam_appid.txt`), and `build_version.gd` still mentions `Cast.pck`.
- `docs/coordination/antigravity.md` is a 1,164-line running log; archive old entries so agents read only what's current.
- **Group the tests.** `tests/` is one flat folder of 253 scripts plus their `.uid` files, with families like `test_net_*` (50) and `test_visual_*` (25). `test_runner.ps1` globs only `tests\test_*.gd` (`:53, 249`), so subfolders need a recursive glob first.
- **Add a CI run.** There's no `.github/` workflow, and all tooling is PowerShell on Windows. Godot 4.7 has an official Linux build, and the suite is headless by design, so a GitHub Actions job running the headless tests on each push would catch regressions like bug 9 without tying up the shared GPU.
- **Exclude test and tool code from release builds.** `export_presets.cfg:15` excludes `build/`, `test_logs/`, `docs/`, `art/` and `tools/` but not `tests/`.

#### What's already good

The networking contract lint (`tests/test_net_contract.gd`) enforces ownership rules and bans global randomness, and no violations were found. Seeded plans are carefully deterministic, with sorted iteration and millimetre-rounded checksums. Multi-process ENet tests, headless layout checks and the lab registry give this codebase stronger guardrails than most hobby projects; the recommendations above build on them.
