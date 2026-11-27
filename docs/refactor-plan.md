# Refactor plan: audit item 7 + code organization audit (2026-11-26)

**Status: approved by the user 2026-11-26 (layout, picks: `scripts/bots/`, `mission/world/`, `combat/fx` + `combat/equipment`; revised split list). Executing tier by tier.**

Sources: `docs/code-audit-2026-11.md` (Organization: "Split the ten files over 1,200 lines", "Rename TestDrive") and
`docs/code-organization-audit.md` (problems 1-5, tiers). The user replaced the audit's "split every file over 1,200 lines" with a stricter test: split only into independent units with a clean interface (section 3). Both were taken at `3dbbb31`; this plan re-surveyed the code at
`9a103cb` + working tree, so the line ranges below are current. Already fixed since the audits, so not in this plan: the
merged enemy state machine and `EnemyFlier` (air duplicates mostly gone), the four rocket `spawn()` copies (now param rows
in `weapon_registry.gd`), `RailSlug.ribbon_material()`.

**The one rule: behaviour stays identical.** No tuning, no bug fixes, no output changes. Every checksum and pinned golden
(city / section / mission / life / stack / air-door / collision hashes in about 35 tests) must match before and after. If
only a file's location or a byte layout moved, the change is proven with a before/after hash dump, not by re-pinning.

## 1. Proposed folder layout (needs approval)

The root cause both audits name: folders follow which session owns the code, not which feature it belongs to. The layout
below groups by feature. `game/`, `ai/`, `fx/` and `world/depot/` disappear.

```
scripts/
  app/          entry, settings, lab, logs, perf probe, version              (Engine)
  net/          transport, session, wire, streams: unchanged                  (Engine)
  mission/      the mission layer: scene, flow, rules, plan, mission combat   (Missions / Engine)
    pacing/     pacing director, facts, stats, intensity, combat log          (Missions)
    depots/     depot arbitration, site fit, depot target, kiosk art, lab     (Missions / Environment art)
    downed/     downed crew + rules                                           (Engine)
    sync/       net bridges: crew sync, enemy sync, puppets, spawn, CombatNet (Engine / Weapons)
    world/      mission world objects: gates, lifts, flags, relay, portal,    (Environment)
                air doors, walls, sound, mission lab, asset target
  bots/         deck-agnostic combat pilot (PlayerBot, navigator, profile)    (Engine)
    crew/       crew bots in a mission (MissionBot + parts, CrewBot, fit...)  (Engine)
    balance/    balance harness (scenarios, verdict, metrics)                 (Engine)
  camera/       chase camera, camera clearance                                (main session)
  combat/       hit core, targets, heat, knockback                            (Weapons)
    weapons/    behaviours + projectiles (as today)                           (Weapons)
    fx/         impact, muzzle, burn, charge glow, flamer fx, combat meshes   (Weapons)
    equipment/  repair drone (+ look), equipment look                         (Weapons)
  enemy/        catalog, spawner, lab                                         (Missions / antigravity)
    units/      EnemyBase (+ parts), EnemyFlier and the unit classes
    squad/      EnemySquad (+ nav, waves, hearing), bay formation
    looks/      meshes, debris, gait, stagger, status bar, telegraph fx
  mech/         catalog, model, accent                                        (Mech)
    motion/     controller, rig, gait, IK, thrusters, ring-walk / thruster labs
    meshes/     Strider / Bulwark / Wasp builders, chassis parts, galleries
  art/          shared low-poly kit: MeshKit, palette, materials, part cache, (Mech, shared)
                LowPolyFlame
  pilot/        unchanged                                                     (Pilots)
  audio/        unchanged                                                     (Weapons)
  ui/
    menu/       front end, menu backdrop, mech stage, loading screen          (Engine)
    hangar/     hangar bay, airlock, egress, handoff, mech diagram            (Engine)
    hud/        mech HUD, mission HUD, crew panel, world aim markers          (Engine)
  world/        ring frame                                                    (Environment)
    city/       city generator only (mission files leave)                     (Environment)
    section/    section plan, map, lab (mission plan / rules / pacing leave)  (Missions)
    life/       unchanged                                                     (Environment)
    occupation/ unchanged                                                     (Environment)
  test_support/ minus PerfProbe                                               (Engine)
scenes/mission.tscn   (was test_drive.tscn)
```

Folder rules to add to `AGENTS.md` Layout (through the user): `bots/` = a pilot that works on any deck (lab, balance
harness, crew bots build on it); `bots/crew/` = what a bot does in a mission; `mission/` = anything that only exists in a
mission; `world/` = the habitat, generated from a seed, with no mission knowledge (except `mission/world/`, which builds
on it); `art/` = shared look helpers with no gameplay; runtime code never depends on `test_support/`.

Choices the user may want to change: (a) `bots/` vs keeping `ai/` + `game/bots/`; (b) `mission/world/` vs
`world/mission/`; (c) whether `combat/` gets subfolders at all (smallest churn: only `fx/` and `equipment/`).

## 2. Move map (old path → new path, owner)

Only files that move are listed; everything else stays. `.gd.uid` files move with their `.gd`. Class renames in bold.

| Old | New | Owner |
|---|---|---|
| `test_support/perf_probe.gd` | `app/perf_probe.gd` | Engine |
| `ui/build_version.gd` | `app/build_version.gd` | Engine |
| `ui/crew_auto.gd` | `app/crew_auto.gd` | Engine |
| `game/test_drive.gd` (**TestDrive → MissionScene**) | `mission/mission_scene.gd` | Engine |
| `scenes/test_drive.tscn` | `scenes/mission.tscn` | Engine |
| `combat/test_drive_combat.gd` (**TestDriveCombat → MissionCombat**) | `mission/mission_combat.gd` | Weapons |
| `game/mission_flow.gd` | `mission/mission_flow.gd` | Missions |
| `world/section/mission_plan.gd`, `mission_rules.gd` | `mission/` | Missions |
| `app/shader_warmup.gd` | `mission/shader_warmup.gd` | Engine |
| `world/section/pacing_director.gd` | `mission/pacing/` | Missions |
| `game/pacing_facts.gd`, `pacing_stats.gd`, `pilot_intensity.gd`, `pilot_track.gd`, `combat_log.gd` | `mission/pacing/` | Missions / Engine |
| `game/mission_depots.gd`, `supply_depot.gd`, `supply_depot_view.gd`, `depot_target.gd` | `mission/depots/` | Missions |
| `world/depot/depot_kiosk.gd`, `depot_meshes.gd`, `depot_lab.gd` | `mission/depots/` | Environment |
| `game/downed_crew.gd`, `downed_rules.gd` | `mission/downed/` | Engine |
| `game/crew_sync.gd`, `enemy_sync.gd`, `mech_puppet.gd`, `mech_spawn.gd` | `mission/sync/` | Engine |
| `combat/combat_net.gd` | `mission/sync/combat_net.gd` | Weapons |
| `world/city/mission_world.gd`, `mission_props.gd` (split, §3), `mission_sound.gd`, `mission_lab.gd` | `mission/world/` | Environment |
| `combat/asset_target.gd` | `mission/world/asset_target.gd` | Weapons |
| `ai/player_bot.gd`, `player_bot_squad.gd`, `bot_navigator.gd`, `bot_profile.gd`, `hover_route.gd` | `bots/` | Engine |
| `game/mission_bot.gd`, `crew_bot.gd`, `bot_fire_guard.gd`, `bot_fit.gd`, `bot_loadout.gd`, `bot_route_planner.gd` | `bots/crew/` | Engine |
| `ai/test_drive_bot_pilot.gd` (**TestDriveBotPilot → MissionBotPilot**) | `bots/crew/mission_bot_pilot.gd` | Engine |
| `ai/balance_scenarios.gd`, `balance_verdict.gd`, `bot_metrics.gd` | `bots/balance/` | Engine |
| `game/chase_camera.gd`, `camera_clearance.gd` | `camera/` | main session |
| `combat/burn_fx.gd`, `charge_glow.gd`, `flamer_fx.gd`, `impact_fx.gd`, `muzzle_flash.gd`, `missile_laser.gd`, `combat_meshes.gd` | `combat/fx/` | Weapons |
| `combat/repair_drone.gd`, `equipment_look.gd` | `combat/equipment/` | Weapons |
| `enemy/enemy_base.gd`, `enemy_flier.gd`, `enemy_drone.gd`, `enemy_drop_drone.gd`, `enemy_gunship.gd`, `enemy_strider.gd`, `enemy_tank.gd`, `enemy_trooper.gd`, `enemy_turret.gd`, `enemy_troop_squad.gd` | `enemy/units/` | Missions / antigravity |
| `enemy/enemy_squad.gd`, `bay_formation.gd` | `enemy/squad/` | Missions / antigravity |
| `enemy/enemy_meshes.gd`, `enemy_debris.gd`, `enemy_debris_field.gd`, `enemy_gait.gd`, `enemy_stagger_anim.gd`, `enemy_status_bar.gd`, `enemy_telegraph_fx.gd` | `enemy/looks/` | Missions / antigravity |
| `ui/mech_accent.gd` | `mech/mech_accent.gd` | Engine → Mech |
| `mech/mech_controller.gd`, `mech_rig.gd`, `gait.gd`, `leg_ik.gd`, `thruster_fx.gd` | `mech/motion/` | Mech |
| `world/thruster_lab.gd`, `world/ring_walk_lab.gd` | `mech/motion/` | main session → Mech |
| `mech/mech_meshes.gd` (split), `bulwark_meshes.gd`, `wasp_meshes.gd`, `chassis_parts.gd`, `mech_parts.gd`, `mech_head_meshes.gd`, `mech_part_gallery.gd`, `head_gallery.gd` | `mech/meshes/` | Mech (heads: Pilots) |
| `mech/mesh_kit.gd`, `fx/low_poly_flame.gd` | `art/` | Mech / main session |
| `ui/front_end.gd`, `menu_backdrop.gd`, `mech_stage.gd`, `loading_screen.gd` | `ui/menu/` | Engine |
| `ui/hangar_bay.gd`, `hangar_airlock.gd`, `hangar_egress.gd`, `hangar_handoff.gd`, `mech_diagram.gd` | `ui/hangar/` | Engine |
| `ui/mech_hud.gd`, `mission_hud.gd`, `crew_panel.gd`, `world_aim_markers.gd` | `ui/hud/` | Engine (aim markers: antigravity) |

New files from splits (§3) are born in their final folder. `tests/` stays flat (grouping it needs a recursive glob in
`test_runner.ps1`; out of scope).

**What a move touches.** `class_name` is global, so most code needs nothing. Path strings do: 85 `res://scripts/...`
strings in 18 files (`LabRegistry.SUBJECTS`, `WeaponRegistry`, `PilotHead` head table, `supply_depot.gd`,
`net_mission.gd`, `TestDrive.SCENE`), `scenes/*.tscn`, `project.godot` autoloads (unchanged: `net/` and `audio/` stay),
`run.ps1 -TestDrive`, and tests that read sources by path (`test_net_contract` `SCALE_FILE` / `SCALE_SCOPE` /
`SCALE_ALLOW` / codec carrier paths, `test_objectives_only`, `test_mission_flow`, `test_weapon_looks`, `test_combat_life`,
`test_tram_portal`), plus docs. The runner's import step refreshes the class cache. Moves use plain `mv` (no `git mv`:
the index stays the user's).

## 3. Splits (tier 2): only where a unit is independent

**Criterion (user, 2026-11-26): no line cap.** A file splits only where part of it is a genuinely independent
responsibility with a small, clean interface, and the result is simpler to read and change. A large but cohesive file
stays whole. Not allowed: forwarder layers (callers are retargeted in the same step), components that reach back into
their owner's state, and splits that scatter one algorithm across files. File length alone is never the reason.

Each kept split names what the new unit owns, its interface, and why the result is simpler. Vars move with their
`net_fields()` entries in the same step; a unit with gameplay state gets its own `net_fields()`. Splits happen in place;
tier 3 moves them.

### Kept

| New unit (from) | Owns | Interface | Why simpler |
|---|---|---|---|
| `SiteFit` (`mission_props.gd` 1140-1577 + `mission_depots.gd` site placement 180-718) | The "can the widest mech stand / walk round / reach this spot" rule: fit mask, fit query, snapping, depot site placement | `SiteFit.mask(plan)`, `snap(plan, p, r)`, `clear_at(...)`, `place_depots(stack, plan)` | A gameplay rule leaves a file whose header says "presentation only"; depot, downed and mission-world callers share one rule instead of two halves in two files. Pure: reads the plan, owns no game state. |
| `MissionGateDoor`, `MissionLiftDoor`, `MissionFlagMast`, `MissionRelayAsset`, `MissionPortal` (inner classes of `mission_props.gd`) | One world object each (mesh, animation) | Unchanged: they already have their own API; `MissionProps.GateDoor` → `MissionGateDoor` at the 31 call sites (retargeted, no alias) | Already independent classes; one file per world object. The small geometry helpers (`extrude`, `clip_rect`, `stripes`, `convex_shape`) go to `CityGeo` with the rest. |
| `MissionAirDoors` (`mission_world.gd` 277-427) | Air-door layout: config, door list, spots, checksum | `config(plan)`, `doors(plan)`, `spot(...)`, `checksum(plan)`: static | Already a pure function of the plan that feeds `CityStack.checksum`; inside the Node that runs the doors it looks like runtime state. |
| `EnemyWreckFx` (`enemy_base.gd` 839-1258) | Death presentation: flames, core glow and cooling, smoke, charred hulk; all its vars are `Net.LOCAL` | `start(cause)`, `step(dt)`, `has_active_flame()`, `active_flame_streams()`, `has_charred_hulk()`; reads the enemy's transform and visuals only | Same pattern as `EnemyTelegraphFx` / `EnemyDebrisField`. ~420 lines of looks leave the AI class; no gameplay write crosses the boundary. |
| Aerial crash → `EnemyFlier` (`enemy_base.gd` 1097-1184) | The falling-wreck physics of the three fliers | None new: an override of the existing wreck hook | Code only fliers use moves to the flier base; the ground base loses an aerial branch. |
| `EnemyNav` (`enemy_squad.gd` 1501-2001) | Per-deck path graphs, occluders, cut rects, A*, separation | `build(deck, plan)`, `path(deck, from, to)`, `seg_crosses_cuts(...)`, `cover_near(...)` | A self-contained pathfinding service with its own caches; the squad only asks it for paths. |
| `AmbientLife` + `LifeDeck` (`ambient_life.gd`) | `AmbientLife`: stack router, Session events, snapshot/restore, id routing. `LifeDeck`: one deck's people and vehicles (sampling, drawing, weapons, threats, pushers) | Router → deck: `setup(...)`, `step(dt, viewers)`, the query/weapon calls it already routes by id; deck → router: signals | Today one class plays both roles: `unit(k)` returns another `AmbientLife`, and 58 lines branch on `units.is_empty()`. Two classes remove those branches. Highest-risk item (about 75 `net_fields` entries to divide): done last. |
| `CombatThreatProbe` (`combat_log.gd` 801-1166) | Threat model: LOS rays, per-pilot `PilotIntensity`, deck threat stats | `step(dt)`, `intensity(pilot)`, `deck_stats(k)` | A pacing input living inside a logger; the logger keeps logging and asks the probe. Log text unchanged. |
| `MissionHudModel` (`mission_flow.gd` 1105-1219) | Turning mission state into the HUD's objective lines | `build(flow) -> Dictionary` (static, read-only) | Presentation out of the rules class through one read-only call. |
| `MissionLoader` (`test_drive.gd` 163-381) | Loading: staged build, loading screen, keep-alive | `start(params)`, signal `loaded` | Loading is a phase with a start and an end; the scene keeps play. |
| `LowPolyPalette` + `LowPolyMaterials` + `PartCache` (`mech_meshes.gd` 1-219) | Shared colours, materials and accent recolouring; the part mesh cache | Palette constants; `materials()`, `apply_accent(node, c)`; `PartCache.mesh(dir, part, builder)` | 42 files outside `mech/` use the palette for things that aren't mechs; three cache copies (mech, bulwark, enemy meshes) become one. Callers retargeted, no alias constants. |
| `MechWeaponMeshes` (`mech_meshes.gd` 1117-1621: weapons + back equipment) | Weapon and equipment meshes | Builders found through the existing part registry | Shared by every chassis, so they don't belong in the Strider file. Strider body and legs stay in `mech_meshes.gd`; `_cap` / `_bolt_ring` / `_foot` / `_spur` / `_toe` (used by Bulwark and Wasp) become public `MeshKit` helpers in tier 1. |
| `CityGraphs` (`city_plan.gd` 2710-2977) | Road and walk graphs derived from a finished plan | `road_graph(plan)`, `walk_graph(plan)`, `court_open(...)` | Read-only views built after generation; they draw nothing from the seed. |
| `SectionEncounters` (`section_plan.gd` 1775-1934) | Arrival, departure and encounter sites derived from a finished plan | `arrival(plan, k)`, `departure(plan, k)`, `sites(plan, k)` | Read-only, used by four other classes (mission plan, spawner, downed, bot); draws no RNG. |
| `CityWalls` (`city_streets.gd` 1113-1649) | Boundary walls, air holes, farm walls, gates | `build(plan, deck, doors, air)` | Lands with the tier 3 fix that passes the mission's doors / air explicitly instead of through `set_meta`, so the openings get one owner. |
| Mission facade removed from `net_session.gd` (610-732) | Nothing new: callers use `Session.mission` (`NetMission`) directly | Existing `NetMission` API | Removes a forwarding layer. `Session` signals stay. |
| TestDrive → `MissionScene` rename | | | The production scene stops being called a test drive. |

### Dropped, and why

| Proposed before | Why not |
|---|---|
| `CityDowntown`, `CityAlleys` | Their fill loops call back into the plan's `_add_lot` / `_add_building` and shared `_rng`: splitting scatters one generator and its draw order across files. |
| `CityRoadForms` as a split | Kept only as the tier 3 dedupe (one `RoadForms` for city + section), if checksums stay byte-identical. |
| `EnemyGroundMover`, `EnemyPerception` | Interleaved with the state machine and overridden by subclass hooks; a component would read and write most of the enemy's state. The outside reach-ins get accessors in tier 1 instead. |
| `EnemyWaves`, `EnemyHearing` | Share the roster, signals and hunt state with the rest of the squad. |
| `MissionBotRoute` | Would be a third route class beside `BotNavigator` and `BotRoutePlanner`; the real fix is merging them (out of scope). |
| `BotDepotGoal`, `BotReviveGoal`, `BotDevTravel` | Each reads and writes the bot's position, route and fight state: many back-references for a small gain. |
| `LifeGraph`, `LifeSlots`, `LifeRoutes` | The graph build writes into the plan; slots and routes are cohesive with it. |
| `CityRamps` | Cohesive static builders with no interface problem. |
| `StriderBody`, `StriderLegs`, `MechEquipmentMeshes` | The Strider stays one file; equipment goes with weapons. |
| `NetBots` | 80 lines, cohesive with the roster. |
| `MissionWalls`, `MissionDoorSchedule` | Walls: replaced by `CityWalls` + explicit openings (tier 3). Schedule: small, part of the doors. |
| `ShotMatcher`, `LogFmt` as a split | `LogFmt` survives only as the `_times` dedupe with `PacingStats` (tier 1). |
| `CombatMeshPool`, `CombatTerrain` | `combat_world.gd` is a cohesive hit core; the pool is 90 lines, and the terrain adapter would carry about eight calls. |
| `MissionAssets`, `MissionWaves` | Small and part of the director tick. |
| `CrewSpawner`, `FlowWatch` | Touch most of the scene's fields. |

Left whole: `mission_bot.gd`, `life_plan.gd`, `combat_world.gd`, `enemy_meshes.gd`, `pacing_director.gd`; `enemy_base.gd`,
`enemy_squad.gd`, `section_plan.gd`, `city_plan.gd`, `net_session.gd` apart from the units above.

## 4. Tier 1: cheap and mechanical (no moves, no splits)

1. Public API for the reach-ins (owners keep the private var, add the getter/verb, callers switch):
   `EnemyBase.engaged_target()` (replaces the twice-written engaged rule in `combat_log` / `pacing_facts`),
   `telegraph_info()` (`player_bot`), `despawn(cause)` + `step_hunt(...)` (`enemy_squad` writes), `skip_visuals` on
   `configure` (`enemy_spawner`); `PlayerBot.current_target()`, `MissionRules.total()`, `BotNavigator.roofs()`;
   `CombatWorld.add_effect()` / `team_of()`; `TestDrive.held` / `hud` / `spawn_mech()`; `MissionFlow.sent`;
   `cached_meshes()` on `CombatMeshes` / `ImpactFx` / `LowPolyFlame` / `EnemyMeshes` + `RailSlug.set_ribbon_shader`;
   `MechHeadMeshes` head colours public; `MechMeshes._cap` / `_bolt_ring` / `_foot` / `_spur` / `_toe` / `_weapon_mortar` (used by Bulwark, Wasp, `WeaponPose`) become public `MeshKit` helpers; `MusicDirector` / `SoundBank` privates public; `MissionWorld` lab accessors;
   `LifePlan` `junction_near` / `foot` / `cuts`; `NetWire.put_i24` / `get_i24` / `unwrap_stamp` (codecs and streams).
2. Type `EnemyBase.squad` as `EnemySquad` (verify the old cyclic-preload concern is gone in 4.7; if not, leave it).
3. `RingFrame.flat()` + static `world_to_arc2` / `arc2_to_world`; replace the copied fallbacks (`bot_navigator.gd:83/90`,
   `enemy_base` 2788/2795, `enemy_drop_drone._arc2`, `enemy_flier` 424, `enemy_spawner` 307). The ~70 `ring != null`
   branches stay (tier 3).
4. `PilotFace`: `_lerp_sec`, `_tic_age`, `_face_r` once.
5. `MechCatalog.loadout_stats` includes the radiator cooling bonus (front end + weapon rack read it); `MechController.rebooting`.
6. Shared helpers: `AudioDirector.of(node)`, one `_canvas`, `LabRegistry.param_rows`, one `PlanHash.put` for the three
   checksum `_put` copies (bytes identical), palette `c()` → `CityPalette.c` (9 copies), `_make_part_instance` once
   (gunship / drop drone), `CityPlan._reset()` for the repeated reset block in `generate()` / `generate_deck()`.
7. Clean the tool-corrupted text (tab-for-backslash continuations, literal newlines in strings, mojibake comments).

## 5. Tier 3: folder moves, coupling fixes, dedupes

1. **Moves** (section 2), one owner group at a time (pause → move → path fixes → suite → release): mission + pacing +
   depots + downed + sync; bots; enemy; mech + art; ui; combat; app / camera.
2. **Couplings** (org audit problem 5): replace the `set_meta("mission_doors" / "mission_air")` side channel with explicit
   args to `CityWalls.build(...)` / `CityDistrict.rebuild_walls(doors, air)`; the `SiteFit` mask cache becomes an
   explicit field; `CityDims` takes the gameplay constants out of `CityStreets` (`HOLE_CURB`, `EDGE`, `RIM`,
   `DROP_PANEL`, `ceiling_opening`); `CityProps.layout` moves off the Node into a `RefCounted` `CityPropLayout` (same
   function, callable without the Node); `BannerPlan` gets relief data without calling `CityBuildings`;
   `GraphicsQuality` owns the level enum and `CityQuality` reads it.
3. **Class splits, same test as tier 2.** Kept: `RepairDroneLook` (looks 357-794 of `repair_drone.gd`; interface
   `update(state)`, the `EquipmentLook` pattern). `MissionDepots` bot core-seeking (`needs_core`, `_bot_tick`, the string
   `drive.get("crew_bots")`) moves to `MissionBot`, which asks `MissionDepots.nearest_with_cores()`: the arbitration side
   stops knowing about bots. Dropped: `MenuHabitat` / `MenuHall` (the backdrop is one cohesive scene builder; only its
   private SurfaceTool helpers are replaced by `MeshKit` / `CityGeo`).
4. **Dedupes**: shared `RoadForms` for city plan + section plan (`seg_key`, union-find, `LANE_W` → `SectionPlan.FORM_WIDTH`)
   **only if the city and section checksums stay byte-identical**, else skipped and reported; one chunked build-queue
   runner only where the copies really have the same shape; `Net` helpers for the host-arbitrated scaffolding (`_clock`,
   `_owns`) in `CityProps` / `AmbientLife` / `OccupationBanners`; hand-copied constants reference their source
   (`PacingDirector.REVEAL`, `CitySigns.GATE_CLEAR_PIER`, extraction depth 40); typed refs instead of string `get()`
   wiring where the type is now reachable.
5. Docs: README layout section, AGENTS.md Layout (+ folder rules), `docs/coordination/antigravity.md` owner table.

## 6. Out of scope (behaviour change or a design decision; listed, not done)

Merging the four bot pathfinders and the two stuck recoveries; `CombatNet` relay → `Session.broadcast_event` and
`apply_owned`; moving `depot.*` messages out of `net/`; one `ground_h` (the two disagree: step vs ramp); one basis
convention; one seed-mix helper (the two are different algorithms; merging changes output); retiring `MechHeadMeshes`;
trooper cover search vs base peek point; merging the `NetEnemyBuffer` / `NetPuppetBuffer` delay logic (copied from cast); position-indexed mission state; the heat-gauge merge; profiling out of hot
paths; `tests/` subfolders; git LFS; `set_anchors_preset` fixes; the bugs in the code audit.

## 7. Risks

- **Other sessions editing the same files.** Each split/move waits for the owner's pause (asked through the main session;
  antigravity via the main session for `scripts/enemy/`) and is logged in the coordination file. A move window is short:
  pause, move, fix paths, run the suite, release.
- **RNG order.** Splitting a seeded generator can reorder draws. Guard: draw order stays in the owner; moved code takes
  its local RNGs with the seed formulas verbatim; all checksum pins must hold without re-pinning.
- **Net contract.** Moving vars out of a class with `net_fields()` must move their entries; `NetEnemyCodec` /
  `NetMechCodec` field lists pin vars to `EnemyBase` / `MechController`; `SCALE_*` paths and keys follow moves (renamed,
  never widened).
- **Duck typing.** About 75 `has_method` calls into `EnemySquad` and many `drive.get("...")` string reads fail silently
  on a rename. Guard: no forwarders, so every moved or renamed name is grepped for string uses and retargeted in the same
  step; typing `EnemyBase.squad` (tier 1) lets the parser catch the rest.
- **Class cache.** A moved file is picked up by the runner's import step; a stale `.godot/` cache shows up as "class not
  found" and is fixed by the import, not by code.
- **Log text.** Bot and pacing tests parse `[Flow]` / combat log lines: format helpers must produce identical strings.
- **Suite noise.** Known flakes (load-sensitive perf / net) are rerun alone before anything is blamed on the refactor.
- **Size.** About 110 file moves and ~20 new files. Tiers are independent; the user can stop after any of them.

## 8. Outcome (2026-11-26)

Executed. Full suite green after every tier (268/268); checksums and pins never re-pinned (before/after dumps for
PlanHash, the tier-2 world splits, the tier-3 couplings and RoadForms). Tiers 1-2 committed as `eb82019`; tier 3 is in
the working tree. Done as planned, except:
- Tier 1: `EnemyBase.squad` stays untyped (a test stub assigns a plain Node); the two "engaged" rules differ, so each
  keeps its formula behind accessors; WeaponRack cooling is a different rule from the catalog's; `_arc_to_world_pos`
  uses CURB_H.
- Tier 2: `MissionLoader` not split (the loading phase writes about 20 scene fields); the EnemyMeshes cache stays its
  own (different body). Extra units the work turned up: `CityFacade` (relief / face geometry shared by buildings and
  banners), `CityDims`, `CityPropLayout`.
- Tier 3: depot bot core-seeking stays in `MissionDepots` (bots without a MissionBot use it, and moving it shifts the
  physics order by a frame; a `ticked(dt)` signal + pilot-locator design is possible but is a design change);
  MenuBackdrop helpers kept (no shared helper gives identical vertices); one build-queue runner skipped (four different
  shapes); RoadForms shares only the identical pieces (seg_key, union-find, LANE_W), not the roll / repair; the
  `"Rig"` name lookups and stand-in-friendly duck typing kept where tests pass stand-ins.
- `SCALE_SCOPE` in test_net_contract now covers `mission/`, `bots/crew/`, `camera/`, `world/section/`, `enemy/`,
  `combat/`: slightly wider than before (stricter), reason in the test.
