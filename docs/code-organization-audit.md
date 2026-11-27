# Code organization audit (2026-11-26)

User: "Let's do a code organization audit, is code in the right classes or spread out?" A read-only review of all of
`scripts/` (280 files, about 97k lines) at commit `3dbbb31`. Line numbers refer to that commit. Nothing was changed by
the audit itself.

How it was done: a folder-level dependency graph built from `class_name` references (comments stripped), a scan for
functions with identical bodies in different files, four parallel area reviews (world; enemy + ai + bots; game + combat
+ net; ui + app + audio + pilot + mech + fx), and spot checks of their claims against the code.

**Owners:** many fixes below touch more than one session's files (table in `docs/coordination/antigravity.md`). Items
marked **[owners]** need the owning sessions (and the user, for folder layout) to agree first. Items marked **[cheap]**
are mechanical and safe for one session to do with a note in the coordination file.

## Verdict

The layering is mostly sound: dependencies point the right way and `net/` is clean. The problems are a dozen classes
that are really several classes, widespread reading of other classes' private members, and several things implemented
twice. One root cause runs through much of it: **folders follow which session owns the code, not which feature it
belongs to**, so a feature owned by several sessions ends up in several folders.

## What is healthy (keep it)

- **Dependency direction.** With comments stripped, few folder edges point backwards. `net/` has no code dependency on
  `game/` or `ui/` (the mentions are in comments). `enemy/` does not depend on `game/` or `ui/`; it only reads
  `PacingDirector` constants, and `EnemyLab`'s use of `PlayerBot` is lab-only. `scripts/ai/` has no typed reference into
  `game/`.
- **One hit path.** `Combat` (`combat.gd`) holds the rule numbers, fire records and seeded shot generators;
  `CombatWorld.resolve_hit` / `deliver` / `splash` / `armor_scaled` (`combat_world.gd:1021-1077`) are the only place a
  `Hit` is built. Projectile, rocket, rail slug, flame stream, laser, mortar and flak shells all call through it.
  `EnemyBase.apply_hit` overrides only for the per-component heat multiplier, which is legitimate.
- **Plans are pure data.** `CityPlan`, `SectionPlan`, `MissionPlan`, `LifePlan`, `BannerPlan`: seeded, checksummed
  `RefCounted`, `net_fields()` on every class. Gameplay and looks use separate seeded generators.
- **Net entities are split** into stream, codec, buffer and state (one set for mechs, one for enemies). Game code reaches
  the network only through `Net.session()` / the Session API.
- **Component patterns already exist** and are the model for the splits below: `EnemyGait`, `EnemyStaggerAnim`,
  `EnemyTelegraphFx`, `EnemyStatusBar`, `EnemyDebrisField`; `BotFit`, `BotLoadout`, `BotFireGuard`, `BotRoutePlanner`;
  `ChassisParts` (the single per-chassis art table); `MeshKit`; `EquipmentLook`.
- **Cosmetic code only observes.** `PilotCombatLink`, `PilotPuppetLink`, `CombatAudio`, `MechAudio` read gameplay and
  never write it. `CityLightRig` is separate from `CityPalette`; `CityQuality` changes only what this machine draws;
  `CityPropSim` motion is closed-form in time; `MissionWorld` doors are scheduled effects.
- **Rules are pure classes:** `PacingDirector`, `PilotIntensity`, `PacingStats`, `DownedRules`, `MissionRules`.
- `mech_controller.gd` is coherent and split well from rig, gait and IK. `LayoutCheck` / `ShotCheck` are small and
  focused. `CrewBot` is thin (105 lines).

## Problem 1: features scattered by owner [owners]

- **Mission code lives in three folders.**
  - `world/city/`: `MissionWorld` (1535), `MissionProps` (1577), `MissionSound`, `MissionLab`
  - `world/section/`: `MissionPlan`, `MissionRules`, `PacingDirector`
  - `game/`: `MissionFlow` (1070), `MissionDepots` (890), `PacingFacts`, `PacingStats`, `PilotIntensity`,
    `SupplyDepotView`
  - `PacingDirector` depends on `PilotIntensity` across folders (`pacing_director.gd:142`, `396`).
- **World-object combat targets are filed three ways:** `DepotTarget`, `SupplyDepot`, `SupplyDepotView` in `game/`;
  `AssetTarget` in `combat/`; `BannerTarget` in `world/occupation/`. `DepotKiosk` (depot art) is in `world/depot/`.
- **`game/` is a catch-all:** cameras (`chase_camera` + `camera_clearance`, about 1050 lines), net bridges (`crew_sync`,
  `enemy_sync`, `mech_puppet`, `mech_spawn`), mission code (`mission_flow`, `mission_depots`, `downed_crew`,
  `downed_rules`), pacing stats, depots, bots and the combat log.
- **Misfiled single files:**
  - `combat/test_drive_combat.gd` is TestDrive's combat wiring (`setup(td: TestDrive)`, `MechHud`, `GameSettings`,
    `EnemySquad`): belongs in `game/`.
  - `ai/test_drive_bot_pilot.gd` is the TestDrive bridge; it reads TestDrive by string (`drive.get("mech")`,
    `drive.set("drive_override")`, lines 81-140) and its stated reason for living in `ai/` is avoiding edit clashes
    (line 15). `MissionBot` reaches through it via `pilot.bot` 8 times. Belongs in `game/`, typed.
  - `world/thruster_lab.gd`, `world/ring_walk_lab.gd` test mech motion (users: `mech_audio.gd`, mech tests): fit
    `mech/` better.
  - `test_support/perf_probe.gd` is called from 12 runtime files (`mech_controller`, `mech_rig`, `mech_model`,
    `combat_audio`, `crew_sync`, `city_props`, ...): belongs in `app/` next to `HitchLog` / `FlowLog`. **[cheap]**
  - `ui/mech_accent.gd` is accent-id data used by `net_session`, `game_settings` (`game_settings.gd:68`), `mech_spawn`,
    `bot_loadout`: belongs in `mech/` beside `MechCatalog`. **[cheap]**
  - `ui/crew_auto.gd` is crew/session automation, not UI.
  - `app/shader_warmup.gd` is a mission-scene node that knows `LoadingScreen`: fits `game/`.
  - `app/graphics_quality.gd` takes its level enum from `CityQuality` (`graphics_quality.gd:45-59, 127`), so an
    app-level setting depends on `world/city`: reverse it.
- **`AGENTS.md` Layout** does not mention `ai/`, `enemy/`, `game/`, `combat/`, `audio/`, `pilot/`. The `ai/` vs `game/`
  rule the code actually follows (`ai/` = a deck-agnostic combat pilot reused by the lab and balance harness; `game/` =
  the mission layer) is written down nowhere.

**Proposal (needs a decision):** `scripts/mission/` for mission and pacing logic, `scripts/world/mission/` for its world
pieces (one file per piece), and subfolders in `game/` (`sync/` with `CombatNet`, `bots/`, a `scripts/camera/`). Put
each world-object target beside its world object. Add the folder rules to `AGENTS.md` (through the user).

## Problem 2: classes that are really several classes

Most already have clean seams. Ranges are approximate.

### `game/mission_bot.gd` (2345 lines, 123 vars) [owners]
Setup 250-336; depot goal 337-440; revive goal 447-586; step / goal / plan-mode objectives 678-1186; zone hold, cover,
threats 1186-1440; route following, stuck recovery, floor-cut veto 1439-1800; fight / vantage 1802-1950; input output
1949-1985; dev travel jumps 2048-2160; roof escape / perch 2170-2345.
It also rebuilds things `BotNavigator` / `PlayerBot` already do (Problem 4).
**Split:** `MissionBotRoute` (route, stuck, veto, `_plan_local`, about 450 lines); goal providers `BotDepotGoal`,
`BotReviveGoal`, `BotObjectiveGoal`; `BotDevTravel`. Move perch/roof handling into `BotNavigator` behind a public API.

### `enemy/enemy_base.gd` (2815 lines, 132 vars)
Damage 646-800; wreck / death effects 801-1215 (about 410); perception 1246-1320 and 1806-2030; AI state machine
1474-1806; ground movement and cover 2031-2510 (about 480); ramp transit 533-612; aerial crash 1061-1149; visuals
2532-2600; co-op puppet 2704+.
4 of 7 subclasses (drone, drop drone, gunship, trooper) override `_step_ai` entirely, so the base AI and ground mover
really serve only tank, strider and turret (and the turret doesn't move). The aerial crash serves only the three air
units. The trooper adds its own cover search (`_find_independent_cover`, `enemy_trooper.gd:732`) beside the base
`_pick_peek_point`.
**Split:** `EnemyWreckFx` (801-1215), `EnemyGroundMover` (2031-2510 plus transit), `EnemyPerception`, and an
`EnemyAir extends EnemyBase` (Problem 4).

### `enemy/enemy_squad.gd` (1996 lines)
Waves 270-760; hunt / reveal 761-860; target board, relay, dropship and air doors 864-1290; hearing 1288-1436;
pathfinding 1488-1996. **Split:** `EnemyNav` (pathfinding), `EnemyWaves`.

### `world/city/city_plan.gd` (3042 lines) [owners: Environment]
Generation core 1-432; streets, lots, massing 433-923; roofs 924-1072; downtown 1073-2208 (about 1130, all `_dt_`);
alleys 2209-2421; road forms 2422-2694; graphs 2695-2962. `generate()` and `generate_deck()` (126-296) repeat the same
reset block. **Split:** static helpers `CityDowntown`, `CityRoadForms`, `CityGraphs` that take the plan; the plan stays
the data holder.

### `world/life/ambient_life.gd` (2247 lines)
One class is both the stack router and the per-deck unit: `unit(k)` returns another `AmbientLife`, with `_root` and
`ID_STRIDE` (403-478, 692), so many methods branch on `units.is_empty()`. Also: viewer culling / LOD 601-737; sampling
and drawing 838-1328; audio throttling 1372-1426; debug 1531-1657; weapons 1754-1962; pushers 1963-2099; net
2130-2247. **Split:** router (`AmbientLife`), a `LifeDeck` unit, an LOD helper.

### `world/city/mission_props.gd` (1577 lines)
The header says "Presentation only: no clock, no state, no network", but the file holds:
- general geometry helpers `extrude`, `clip_rect`, `stripes`, `convex_shape` (92-175): belong in `CityGeo`;
- five piece classes `GateDoor` (191-631), `LiftDoor`, `FlagMast`, `RelayAsset`, `Portal`: one file each;
- site snapping and the reachability rule (`snap_site_fit`, `FitMask`, `FitQuery`, 1140-1577): **gameplay**, used by
  `supply_depot.gd` and `downed_rules.gd`. Should be a `SiteFit` class. It caches its `FitMask` on the plan through
  `set_meta` (1274-1279).

### `world/city/mission_world.gd` (1535 lines)
Also cuts and rebuilds `CityDistrict`'s walls (552-716) and hands the result over through metadata (Problem 5).

### `world/section/section_plan.gd` (2004 lines)
Encounters (1783-1942) and `deck_view` could move out. Lower priority.

### `game/combat_log.gd` (1379 lines)
A logger that grew a threat and pacing model: damage accounting 363-712; shot-to-hit matching 713-793; threat, LOS
raycasts and per-pilot `PilotIntensity` 794-1138; deck stats 1139-1164; static note API 1165-1216 (sets
`c._pace_api` on the live instance, 1198); line formatting 1217-1379. Reads `mf._sent` (229).
**Split:** a damage log and a threat probe; a shared `Engagement` tracker with `PacingFacts` (Problem 4); a static
`LogFmt` also used by `PacingStats` (`_times` is identical at `pacing_stats.gd:153` and `combat_log.gd:1373`).

### `game/test_drive.gd` (1188 lines)
Load and loading screen 177-400; setup 401-545; [Flow] log watch 591-638; city, life, banners 639-793; enemy spawn and
checksum 794-876; crew and bot spawning 885-1000; input and downed controls 1031-1146. Others touch its privates:
`td._hud` (`downed_crew.gd:87`), `drive._spawn` (`downed_crew.gd:403`), `td._held` (`mission_flow.gd:178`;
`mission_bot.gd:695, 716, 1334`). **Split:** `MissionLoader`, `CrewSpawner`, `FlowWatch`; make those vars public API.

### `game/mission_flow.gd` (1070) and `game/mission_depots.gd` (890)
`MissionFlow`: rule evaluation 260-400; director tick 401-627; air doors and waves 628-770; assets 784-842 (a
`MissionAssets` sibling, like `MissionDepots`); presentation 843-944; HUD model 944-1070 (`MissionHudModel`).
`MissionDepots`: site placement 142-486 is pure plan geometry (belongs with `SiteFit`); bot core-seeking 535-620
(`needs_core`, `_bot_tick`, `drive.get("crew_bots")`) belongs with the bots; arbitration 691-868 is fine.

### `combat/combat_world.gd` (1242 lines)
The core (register, fire, advance, authority, raycasts, hits, 1017-1190) is sound. Move out: the mesh pool 353-443
(`CombatMeshPool`) and the city / prop / life lookups 783-1016 (scene-tree group searches, duck-typed
`stack.get("decks")`) into a `CombatTerrain` adapter.

### `combat/repair_drone.gd` (794 lines)
Scheduled effect and repair logic 1-356; look 357-794 (scan fitting 520-744). Split out `RepairDroneLook`, like
`EquipmentLook`.

### `mech/mech_meshes.gd` (1621 lines) [owners: Mech]
Part registry, cache, materials, accent recolouring 1-220; body 220-858; legs 858-1117; weapons 1117-1437; back
equipment 1437-1621. It splits along its own `# ---` headers. It is also the whole game's art kit: about 25 files
outside `mech/` use its palette or `materials()` (combat, enemy, depot, occupation, pilot, `city_palette.gd`), and
`MechParts.box/mat` is a general primitives kit for `hangar_bay.gd:609-614`, `shader_warmup.gd:267-269` and four labs.
**Split:** `scripts/art/` (or `mech/art/`) with `LowPolyPalette`, `LowPolyMaterials` and a
`PartCache.mesh(dir, part, builder)`; then `StriderBody`, `StriderLegs`, `MechWeaponMeshes`, `MechEquipmentMeshes`
(weapons and equipment are shared by both chassis and shouldn't sit in the Strider file).

### Others worth noting
- `ui/menu_backdrop.gd` (1071): lights 118-228; node/material helpers 228-293; habitat ring and shuttle 293-641; hall,
  props, holo, dust, stars 641-914; its own SurfaceTool helpers 914-1013 that repeat `MeshKit` / `CityGeo`. Judgment:
  `MenuHabitat` + `MenuHall` on `MeshKit`, moved with `hangar_bay.gd` to a `sets/` folder.
- `audio/sound_bank.gd`: `synthesize` is one 660-line `match` (309-973). Judgment: split recipes by family; keep
  `SoundBank` as cache and prewarm.
- `net/net_session.gd` (1575, about 250 of them header): the transport / roster / watchdog core is coherent. Bots
  (787-864) and the mission/depot facade (607-680) could move out. Low priority.
- `enemy/enemy_meshes.gd` (1458) is long but single-purpose; `enemy/enemy_spawner.gd` is focused apart from the long
  `plan_encounters` (50-242). Not urgent.
- `world/city/city_streets.gd` (1723) is already sectioned by piece; walls / farm walls (1113-1650) could be their own
  file if they grow.

## Problem 3: classes reading each other's private members

The most widespread problem. Each case wants a small public method on the owner.

| Reader | Reads | Fix |
|---|---|---|
| `enemy_squad.gd:785-838` | writes `e._hunting`, `_hunt_t`, `_revealed_idle_t`; calls `e._kill` (614, 641, 838); reads `e._target_aim_center`, `_cfg`, `_is_awake` | public verbs `despawn(cause)`, `step_hunt(...)` |
| `enemy_base.gd:84` | `squad: Node` ("to avoid cyclic preload issues"), so about 30 string `has_method` calls in the base, about 73 across `enemy/` | type it `EnemySquad` |
| `enemy_spawner.gd:313` | writes `e._built_visuals` | `skip_visuals` argument on `configure` |
| `mission_bot.gd:984` | `pb._current_enemy` | `PlayerBot.current_target()` + a target-hint setter |
| `mission_bot.gd:2257` | `nav._roofs` | perch API on `BotNavigator` |
| `mission_bot.gd:1045` | `rules._tot` | accessor |
| `player_bot.gd:407-416` | `e._shot_index`, `e._active_weapon` | `EnemyBase.telegraph_info()` |
| `combat_log.gd:879-891`, `pacing_facts.gd:~84-93` | `e._target_id`, `e._is_awake()`, `_has_los` | `EnemyBase.engaged_target()` |
| `missile.gd`, `flamer_fx.gd`, `flak_shell.gd` | `world._add_effect`, `world._team_of` | make public |
| `shader_warmup.gd:282` | `CombatMeshes._cache`, `ImpactFx._meshes`, `LowPolyFlame._cache`, `EnemyMeshes._cache`; writes `RailSlug._ribbon_shader` (327-331) | `cached_meshes()`, `ribbon_material()` |
| `pilot_head_corn.gd:165`, `pilot_head_duck.gd:54`, `pilot_head_pickle.gd:182` | `MechHeadMeshes._corn_colour`, `_duck_green`, `_pickle_colour` | make public (or see Problem 4) |
| `bulwark_meshes.gd:171, 726, 767` | `MechMeshes._cap`, `_bolt_ring` | public `MeshKit` helpers |
| `music_director.gd` | `_director._fetch_stream` (4 times); the director reads `bank._async_started` | make public |
| `mission_lab.gd:51-218` | `mw._doors`, `_flags`, `_assets`, `_sources`, `_portal`, `_deck()` | accessors |
| `life_traffic.gd:97, 279`; `life_crowd.gd:431, 435`; `ambient_life.gd:1407` | `lp._junction_near`; `lp._foot`, `lp._cuts`; `fleet._anchor_at` | accessors |
| `net_enemy_stream.gd:118`; `net_enemy_codec.gd:86, 122` | `NetMechStream._unwrap_stamp`; `NetMechCodec._put_i24/_get_i24` | move into `NetWire` (or a `NetBytes` helper) |
| `mech_diagram.gd` (280-512) | calls `m._process(0.25)` on a `MechModel` | judgment: a `MechSilhouette` class in `mech/` |

**String-typed wiring** with the same effect: `mech_hud.gd:213-226` (`_find_sources` chains
`drive.get("combat").get("rack")`); `"Rig"` looked up by node name in `mech_hud.gd:269`, `chase_camera`, `mech_audio`,
`thruster_fx` (give `MechController` `rig()` / `model()` accessors and have TestDrive call `bind()`); `CombatNet`
`drive.get("crew_sync")` (`combat_net.gd:317-323, 355, 560-562`); `WeaponRack` depends on `ChaseCamera` only for
`aim_point()` (`weapon_rack.gd:106, 169, 577-581`; pass an aim callable).

## Problem 4: the same job done more than once

- **Bot navigation (four pathfinders).** `MissionBot._plan_local` (a BFS over a physics grid, `mission_bot.gd:873-969`),
  `BotNavigator` A* (`bot_navigator.gd:213`), `BotRoutePlanner`, and `EnemySquad` A* (`enemy_squad.gd:1488-1996`).
  Also two stuck recoveries (`mission_bot.gd:1680` `_stuck_tick` vs `BotNavigator.reset_stuck` + sidesteps) and two
  cover / vantage pickers (`mission_bot.gd:1298, 1892` vs `bot_navigator.gd:427, 359`). **[owners]**
- **"Engaged" rule** written twice: `combat_log.gd:879-891` and `pacing_facts.gd:~84-93`.
- **Road forms** rolled and repaired twice: `city_plan.gd:2482-2694` (stand-alone mode) and `section_plan.gd:1247-1455`,
  with `seg_key` (city 2439, section 1025), `_uf_find` / `_uf_join` (city 2650, section 1311), and `LANE_W` copying
  `SectionPlan.FORM_WIDTH`. One `RoadForms` helper over a segment list.
- **Checksum `_put`** three times (`city_plan.gd:3036`, `section_plan.gd:2002`, `mission_plan.gd:823`); **seed hash
  mix** twice (`city_site.gd:149`, `life_plan.gd:152`). **[cheap]**
- **Ring math:**
  - The flat "no ring" fallback is copied: `world_to_arc2` at `bot_navigator.gd:83`, `enemy_base.gd:2603`,
    `enemy_drop_drone.gd:432` (`_arc2`); arc-to-world at `enemy_base.gd:2610`, `enemy_drone.gd:769`,
    `enemy_gunship.gd:687`, inline at `enemy_spawner.gd:306`. About 68 `ring != null` branches across `enemy/` and
    `ai/`. Fix: a flat mode on `RingFrame` (or a `FlatFrame` subclass) plus `world_to_arc2` / `arc2_to_world`, so `ring`
    is never null. **[cheap]**
  - Two basis conventions: `RingFrame.basis_at_arc` points local -Z along +s; `CityGeo.frame_basis`
    (`city_geo.gd:163`) points +Z along +s and is the de facto standard (`city_district.gd:395, 407`,
    `city_props.gd:883`, `ambient_life.gd:1880`). `crowd_lab.gd:532, 670` build frames by hand.
  - `SectionPlan.to_world` / `polar_to_world` (201-207) re-derive `arc_to_world` plus the deck offset; `CityStack`
    defines an inner `RingFrame` subclass with an origin offset (`city_stack.gd:~95-111`). One deck-aware frame.
  - Two `ground_h` that disagree: `MissionProps.ground_h` (1069) is a step, `LifePlan.ground_h` (683) is a ramp.
    `CityPlan` should own the one answer.
- **Host relay.** `CombatNet` works out the sender from an `"o"` field and loops the host over `s.roster` with
  `send_event` (`combat_net.gd:471-491`): the same job as `Session.broadcast_event` (`net_session.gd:577`, 1137-1151),
  which nothing outside `net/` calls. It passes `test_net_contract` because the lint checks syntax, not behaviour. It
  also validates bot `"b"` records and counts refusals, so check whether `broadcast_event` can carry that before
  switching. Related: `CombatNet._host_hit` applies hits by hand (`t.apply_hit` + `world.hit_landed.emit`,
  `combat_net.gd:591-592`), duplicating `CombatWorld.deliver` (1048); add `world.apply_owned(t, h)`. **[owners]**
- **Message ownership is inconsistent.** Depot messages live in the net layer (`NetMission.client_depot_claim` /
  `host_depot_grant` / `_on_depot_event`, `net_mission.gd:263-312`, plus facades `net_session.gd:113-117, 653-666`),
  while `CombatNet`, `EnemySync` and `CityProps` own their own kinds. Pick the second convention and move `depot.*`
  into `MissionDepots`, so `net/` stays free of game knowledge.
- **Host-arbitrated object scaffolding** copied across `CityProps`, `AmbientLife`, `OccupationBanners`: `_clock`
  (`city_props.gd:592`, `ambient_life.gd:741`, `occupation_banners.gd:297`), `_owns` (identical, `city_props.gd:927`,
  `ambient_life.gd:2027`), and the `event_received` / `peer_joined` connect / disconnect / join-sync code. Put them on
  `Net` / `Session` (e.g. `world_time(now)`, `moves(body)`).
- **Game rules in two places:** the radiator cooling bonus in `front_end.gd:601-610` (`hangar_stats`) and
  `weapon_rack.gd:196-200`, because `MechCatalog.loadout_stats` leaves it out (fold it in) **[cheap]**; "rebooting"
  (`heat <= reboot_heat`) in `mech_hud.gd:257-262` and `mech_audio.gd:245` (a `MechController.rebooting` getter).
- **Launch policy in the UI:** `mission_seed` (`front_end.gd:415`, also called by `crew_auto.gd:100`), `_on_launch`
  building `TestDrive.solo_launch` (399), the Steam-then-LAN fallback in `_on_play` / `_on_join` (366-389). Move to a
  `MissionLaunch` in `game/` and a `Session.host_any()`.
- **Air enemies.** `_fly_toward` (`enemy_drone.gd:572`, 145 lines; `enemy_gunship.gd:500`, 133 lines) share about 100
  lines. Identical: `_air_ray_hit` (drone 717, gunship 633), `_arc_to_world_alt` (drone 769, gunship 687),
  `has_art_mesh` (gunship 89, drop drone 160), `_make_part_instance` (gunship 176, drop drone 227), `_is_aerial_wreck`
  (all three). Also shared: `_tall_obstacle_repulsion`, `_arc_dir_to_world`. Fix: `EnemyAir extends EnemyBase` with
  flight, aerial crash and wreck-pivot hooks; art-mesh deferral into `EnemyMeshes.instance_or_placeholder()`.
- **Two head systems.** The game uses `PilotHead` / `PilotFace`; `MechHeadMeshes` survives only for the placeholder
  path (`MechParts.head`, `mech_model.gd:277`), `HeadGallery` (header still says "four placeholder heads") and the part
  gallery. The dog's sections are copied literally (`pilot_head_dog.gd:18`, `mech_head_meshes.gd:146`). Keep each
  head's shape data in its pilot head file; derive or retire `MechHeadMeshes` (retiring is a judgment call).
- **Head helpers** copied in every head (all extend `PilotFace`): `_lerp_sec` in all 5 (chicken 109, corn 172, dog 169,
  duck 118, pickle 189), `_tic_age` in 3 (corn 146, dog 155, pickle 162), `_face_r` in 2 (corn 155, pickle 172). Move
  to `PilotFace`. **[cheap]**
- **Mesh cache helpers:** `mesh()` / `instance()` identical in `mech_meshes.gd:115, 128` and `bulwark_meshes.gd:136,
  148`; `instance()` again in `enemy_meshes.gd:85`. One `PartCache`.
- **Rocket weapons:** `spawn()` identical in `rockets.gd:12`, `enemy_rockets.gd:10`, `enemy_gunship_rockets.gd:10`,
  `enemy_troop_at.gd:10`, and the three enemy ones skip `prewarm`. A `RocketBehaviour` base where each file overrides
  only `look()`. **[cheap]**
- **Net buffers:** `_ready` identical in `net_enemy_stream.gd:32` and `net_mech_stream.gd:50`; `NetEnemyBuffer` and
  `NetPuppetBuffer` duplicate the adaptive delay (`DELAY` / `DELAY_MAX` / `MARGIN` / `LAG_WINDOW`, `step_delay`). A
  shared delay class. Low priority (copied from cast).
- **Small helpers:** `_audio()` lookup identical in `front_end.gd:883`, `combat_audio.gd:633`, `mech_audio.gd:351`,
  `audio_lab.gd:300` (plus `game_settings.gd:114`): one static `AudioDirector.of(node)`. `_canvas` identical in
  `mech_hud.gd:144` and `mission_hud.gd:239`. `lab_params` identical in `thruster_lab`, `ring_walk_lab`, `pilot_lab`,
  `head_gallery`, `mech_part_gallery`, `city_lab`, `crowd_lab`, `life_lab`: the subjects extend different node types,
  so a static `LabRegistry.param_rows(PARAMS, params)` rather than a base class. **[cheap]**
- **Hand-copied constants:** `PacingDirector.REVEAL` (`pacing_director.gd:53`) repeats `MissionWorld.OPENING` and
  `LIFT_OPEN`; `CitySigns.GATE_CLEAR_PIER = 11.6` (`city_signs.gd:25-30`) was worked out by hand from `GateDoor`
  constants (`mission_props.gd:201-207`); extraction depth `40.0` hard-coded at `mission_world.gd:803, 1519` and in
  `MissionRules.DEFAULTS["zone_depth"]`. Reference the source constant.
- **Trooper cover search** (`enemy_trooper.gd:732`) beside the base `_pick_peek_point`.
- `mission_sound.gd:9` hard-codes `"SFX_World"` and builds its klaxon straight from `AudioSynth`, bypassing `SoundBank`
  and the voice pools. At minimum use `AudioDirector.BUS_SFX_WORLD`. Also: `MechAudio`'s node is named `"Audio"`, the
  same as the autoload.

## Problem 5: gameplay depends on presentation

Risk: changing how something is drawn can change the checksummed layout, and some state is invisible to `net_fields()`.

- `CityPlan` (checksummed) reads `CityStreets` (mesh builder) constants and a function: `HOLE_CURB`
  (`city_plan.gd:425, 1322, 2359, 2829`), `ceiling_opening`, `RIM`, `DROP_PANEL` (1379, 2190). Move the gameplay
  dimensions onto `CityPlan` or a `CityDims`.
- `LifePlan` / `LifeTraffic` call `CityProps.layout` (`life_plan.gd:302`, `life_traffic.gd:435`), a static function on a
  `Node3D`, and read `CityStreets.EDGE` (`life_plan.gd:690`). Move `CityProps.layout` and helpers
  (`city_props.gd:118-380`) into a `RefCounted` `CityPropLayout`.
- `BannerPlan` calls `CityBuildings.relief` / `face_coords` (`banner_plan.gd:187, 233`).
- **Metadata side channel:** `MissionWorld` writes `"mission_doors"` / `"mission_air"` onto `CityPlan` with `set_meta`
  (`mission_world.gd:685-687`); `CityStreets` (1198, 1214) and `CitySigns` (636) read it. Pass the openings explicitly
  (e.g. `CityDistrict.rebuild_walls(doors, air)`).
- `MissionProps` holds the `SiteFit` gameplay rule under a "presentation only" header (Problem 2).

## Wrong-way dependencies (from the graph)

Few, with comments stripped:
- `combat/` → `game/`: `combat_net.gd` → `CrewSync`, `MechPuppet`; `player_target.gd` → `DownedRules`.
- `combat/` → `ui/`: `test_drive_combat.gd` → `MechHud` (goes away when it moves to `game/`).
- runtime → `test_support/`: `PerfProbe` (12 files).
- `net/` → `ui/`: `steam_lobby.gd:50` → `BuildVersion` (a version helper; fits `app/`).
- `app/` → `world/city`: `GraphicsQuality` → `CityQuality`.
- `world/section` → `game/`: `pacing_director.gd` → `PilotIntensity`.
- `net/` codecs know gameplay classes (`net_mech_codec.gd` → `PlayerTarget`, `WeaponMount`; `net_enemy_codec.gd` →
  `EnemyBase` subclasses). Acceptable: codecs are the bridge.
- `world/city` → `world/section` (8 edges) is by design: the city is built from the section plan.

## Suggested order

**Tier 1: cheap and mechanical** (one session, low risk, note in the coordination file):
1. `RingFrame` flat mode + `world_to_arc2` / `arc2_to_world`; drop the copied fallbacks.
2. `_lerp_sec` / `_tic_age` / `_face_r` into `PilotFace`; make the head colour functions public.
3. Public accessors for the Problem 3 table (`EnemyBase.engaged_target()`, `telegraph_info()`,
   `PlayerBot.current_target()`, `CombatWorld.add_effect()` / `team_of()`, `cached_meshes()`, ...).
4. Type `EnemyBase.squad` as `EnemySquad` (check the cyclic-preload concern still applies in 4.7).
5. Fold the cooling bonus into `MechCatalog.loadout_stats`; add `MechController.rebooting`.
6. Shared helpers: `AudioDirector.of()`, one `_canvas`, `LabRegistry.param_rows`, `RocketBehaviour`, one checksum
   `_put` and seed hash.
7. Moves: `PerfProbe` → `app/`, `MechAccent` → `mech/`, `BuildVersion` → `app/`, `test_drive_combat` and
   `test_drive_bot_pilot` → `game/`.

**Tier 2: fix the risky couplings.**
1. Replace the `set_meta` side channel with explicit arguments.
2. Move gameplay dimensions out of `CityStreets`; `CityPropLayout` out of `CityProps`.
3. Extract `SiteFit` from `MissionProps` (and `MissionDepots` site placement into it).
4. Decide the `CombatNet` relay and `apply_owned`; move `depot.*` messages out of `net/`.
5. One basis convention and one `ground_h`.

**Tier 3: split along the existing seams.** `EnemyAir`, `EnemyWreckFx`, `EnemyGroundMover`, `EnemyPerception`;
`EnemyNav` / `EnemyWaves`; `MissionBotRoute` and goal providers; `CityDowntown` / `CityRoadForms` / `CityGraphs`;
`MechMeshes` per section plus a shared art kit; `CombatLog` with a shared `Engagement` tracker; `MissionFlow` →
`MissionAssets` + `MissionHudModel`; `TestDrive` → `MissionLoader` / `CrewSpawner` / `FlowWatch`; `AmbientLife` router
+ `LifeDeck`; `CombatWorld` → `CombatMeshPool` + `CombatTerrain`; `RepairDroneLook`; `RoadForms`.

**Decisions for the user and owners:** a `scripts/mission/` folder; `game/` subfolders; whether to merge the bot
navigation stacks (`MissionBot` / `BotNavigator` / `EnemySquad` pathfinding); retiring `MechHeadMeshes`; folder rules
in `AGENTS.md`.

Every split must keep `tests/test_net_contract.gd` green: a new class with gameplay state needs `net_fields()`, and
moved vars move their declarations with them. Run `.\test_runner.ps1 -TestAll` after each step.
