# babamech

Co-op (up to 4) third-person mech combat in Godot 4.7 / GDScript: chicken-legged mechs with oversized cartoon pilots
(chicken, pickle, corn, dog), inside a rotating ring habitat. Design: `docs/design/decisions.md`. Agents: `AGENTS.md`.

**Status:** menus, settings, the hangar, the lab, the crew session (Steam lobbies + ENet) and the mission (objectives,
pacing director, supply depots, extraction, solo and in a crew) work.

## Run
```powershell
.\run.ps1                      # the game (menu)
.\run.ps1 -Crew 2              # a host + a joiner over ENet on this PC (each its own window and settings file)
.\run.ps1 -Crew 4 -Link coast  # four windows, simulated coast-to-coast link
.\lab.ps1                      # the lab: every scene with tunable params
.\test_runner.ps1 -TestAll     # all tests, headless
.\build.ps1                    # tests + Windows export (build\windows\babamech.exe)
```
Godot is found by `godot_env.ps1` (`$env:BABAMECH_GODOT`, `build\deps`, or the flap / cast / Hero-Reader copies).

## Menu
- **Play / Host**: opens a Steam lobby (alone, it is solo play). Without Steam: an ENet crew on port 24600.
- **Join**: the first open Steam lobby with this game key and build. Without Steam: ENet on 127.0.0.1:24600.
- Steam overlay invites work in both directions (Invite crew on the hangar; accepting one joins).
- **Settings**: pilot name, head, video, audio, simulated link (saved at once to `user://settings.cfg`).
- **Hangar** (after Play/Join): the crew with each pilot's name / head / chassis, your chassis and loadout
  (weapons with weight, passive heat, active heat), a 3D line-up of the crew's mechs. Launch is a stub.
- **The mission**: one mode (user 2026-11-25: "Cut the legacy modes."): the mission plan's objectives, the pacing
  director's waves, supply depots and the extraction hold, solo and in a crew, in the multi-deck section stack. No flag
  or setting selects another: `--objectives` is accepted and ignored, `--no-objectives` and the old "objectives" setting
  are gone, and so are the hangar's Objectives box and the single-district mode (`--district`). Tests of a narrow system may
  use a TEST-ONLY fixture instead (docs/testing.md "Fixtures"), never reachable from the game.
- **Lab**: placeholder mech (leg lengths, crouch, stance, walk, head, loadout) and the head gallery.

## Layout (code)
Folders follow features, not which session owns the code (`docs/refactor-plan.md`, approved 2026-11-26). Rules:
`world/` is the habitat, generated from a seed with no mission knowledge; `mission/` is anything that only exists in a
mission (`mission/world/` builds on the city); `bots/` is a pilot that works on any deck (lab, balance harness),
`bots/crew/` what a bot does in a mission; `art/` holds shared look helpers with no gameplay; runtime code never depends on
`test_support/`. Split a class only into independent units with a small, clean interface (no line cap).
- `scripts/app/`: `Boot` (entry, `--run-test`, flags), `GameSettings`, `GraphicsQuality`, `Lab` + `LabRegistry`,
  `FlowLog` / `HitchLog` / `PerfProbe`, `BuildVersion`, `CrewAuto`.
- `scripts/net/`: everything network and Steam (`NetSession` = the `Session` autoload, `NetMission` = `Session.mission`,
  `NetWire`, `NetClock`, `NetLink`, `NetSteamLink`, `NetTelemetry`, mech / enemy streams and codecs, `SteamLobby`,
  `SteamIdentity`, `Net`).
- `scripts/mission/`: `MissionScene` (the mission scene, `scenes/mission.tscn`), `MissionFlow` (rules, director tick,
  crew scale), `MissionHudModel`, `MissionPlan`, `MissionRules`, `MissionCombat` (the scene's combat wiring),
  `ShaderWarmup`.
  - `pacing/`: `PacingDirector`, `PacingFacts`, `PacingStats`, `PilotIntensity`, `PilotTrack`, `CombatLog`,
    `CombatThreatProbe`.
  - `depots/`: `MissionDepots` (arbitration), `SupplyDepot`, `SupplyDepotView`, `DepotTarget`, `DepotKiosk` /
    `DepotMeshes`, `DepotLab`.
  - `downed/`: `DownedCrew`, `DownedRules`. `sync/`: `CrewSync`, `EnemySync`, `MechPuppet`, `MechSpawn`, `CombatNet`.
  - `world/`: `MissionWorld` (doors, lifts, flags, zones on the city), `MissionGateDoor`, `MissionLiftDoor`,
    `MissionFlagMast`, `MissionRelayAsset`, `MissionPortal`, `MissionAirDoors`, `SiteFit` (where the widest mech fits),
    `MissionProps`, `MissionSound`, `AssetTarget`, `MissionLab`.
- `scripts/bots/`: `PlayerBot`, `PlayerBotSquad`, `BotNavigator`, `BotProfile`, `HoverRoute`. `crew/`: `MissionBot`,
  `MissionBotPilot`, `CrewBot`, `BotFireGuard`, `BotFit`, `BotLoadout`, `BotRoutePlanner`. `balance/`: the balance harness.
- `scripts/camera/`: `ChaseCamera`, `CameraClearance`.
- `scripts/combat/`: `Combat` (rules), `CombatWorld` (the one hit path), targets, `Heat`, `Knockback`, `WeaponRack`,
  `WeaponMount`, `WeaponRegistry`, projectiles. `weapons/`: weapon behaviours. `fx/`: impact, muzzle, burn, flamer fx,
  `CombatMeshes`. `equipment/`: `RepairDrone`, `EquipmentLook`.
- `scripts/enemy/`: `EnemyCatalog`, `EnemySpawner`, `EnemyLab`. `units/`: `EnemyBase` (one state machine),
  `EnemyFlier` and the unit classes. `squad/`: `EnemySquad`, `EnemyNav` (paths), `BayFormation`. `looks/`: `EnemyMeshes`,
  `EnemyWreckFx`, debris, gait, stagger, status bar, telegraph fx.
- `scripts/mech/`: `MechCatalog` (heads, chassis, weapons), `MechModel`, `MechAccent`. `motion/`: `MechController`,
  `MechRig`, `Gait`, `LegIK`, thrusters, ring-walk / thruster labs. `meshes/`: `MechMeshes` (Strider),
  `MechWeaponMeshes`, `BulwarkMeshes`, `WaspMeshes`, `ChassisParts`, `MechParts`, galleries.
- `scripts/art/`: `MeshKit`, `LowPolyPalette` (every colour), `LowPolyMaterials`, `PartCache`, `LowPolyFlame`.
- `scripts/pilot/`: `PilotHead` / `PilotFace` and the heads. `scripts/audio/`: `AudioDirector` (`Audio`), `SoundBank`,
  music, combat / mech audio.
- `scripts/ui/`: `menu/` (`FrontEnd`, `MenuBackdrop`, `MechStage`, `LoadingScreen`), `hangar/`, `hud/` (`MechHud`,
  `MissionHud`, `CrewPanel`, `WorldAimMarkers`).
- `scripts/world/`: `RingFrame`, `PlanHash`, `RoadForms` (road-form pieces shared by city and section). `city/`: the seeded urban district (`docs/design/city-styles.md`): `CitySite`,
  `CityPlan` (layout as data, checksummed), `CityGraphs`, `CityDims` / `CityFacade` / `CityPropLayout` (plan-side
  dimensions, facade relief and the props layout: plans read these, never a mesher), `CityBuildings` / `CityStreets` /
  `CityWalls` (flat-colour meshes via `CityGeo`, colours from `CityPalette`), `CityLightRig`, `CityDistrict` (nodes +
  collision), `CityStack`, `CityProps`, `CityLab`. `section/`: `SectionPlan`, `SectionEncounters`, `SectionMap`, `SectionLab`. `life/`:
  `AmbientLife` (router) + `LifeDeck` per deck, `LifePlan`, crowds, traffic, tram. `occupation/`: banners.
- `scripts/test_support/`: `TestCase`, `NetTest`, `LayoutCheck`, `ShotCheck`, fixtures (tests only).
- `scenes/`: `boot.tscn`, `menu.tscn`, `lab.tscn`, `mission.tscn` (thin: a root node and its script).

## Not committed
- `addons/godotsteam/win64/*.dll`: copy from `..\cast\addons\godotsteam\win64` (GodotSteam 4.17.1). Without them the game
  runs without Steam.
- `build/`, `test_logs/`, `version.txt`.
