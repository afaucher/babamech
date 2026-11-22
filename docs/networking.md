# Networking in babamech

The model is cast's (`..\cast\docs\design\networking.md`, option A, and `networking-build-plan.md`): **owner authority**.
Read cast's doc for the reasoning (Bridge to Friendship's post-mortem, the options table); this page says what babamech
took, what it changed, and what is still to build.

## Model
- Each player's machine owns that player's mech: position, heat, components, weapons. Nobody corrects it.
- The host owns everything else: enemies (coordinated AI, host-only), civilians and vehicles, pickups, the mission.
- Cross-owner effects are messages: **the victim decides** about its own mech; **the attacker's machine decides** about
  host-owned targets and sends the hit to the host. A support action (revive) targets an id.
- One-shot decisions go reliably (events); continuous motion goes unreliably (sequenced packets, newest wins).
- Layouts are procedural from a seed, built by every machine and checksum-verified.
- Friends only: no anti-cheat.

## Built (scaffold)
| Piece | File | From cast |
|---|---|---|
| Session autoload: ENet + Steam transports, hello handshake, roster (max **4**), refusals, leave / host left, kick, set_members | `scripts/net/net_session.gd` | ported, cut down (no shared run, seats, snapshots, world, objects, casts, orders yet) |
| Pilot profile in the handshake: `name`, `head`, `chassis`, `accent`, `loadout` in `sys.hello`; changes later via `sys.profile`; the host makes each loadout valid for its chassis (`NetSession.clean_loadout`) | `net_session.gd` | new (cast carried `character`) |
| Shared mission start (co-op step 1): host Launch, load barrier on the city checksum, desync / slow-load send-out, one mech per crew member | `net_mission.gd` (child "Mission" of Session), `scripts/game/test_drive.gd`, `scripts/game/mech_spawn.gd` | cast's M1 (`crew_flow.gd`), cut down to launch + barrier |
| The city stack in the mission (W2): the launch carries `mode` (`stack`, the default, or `district`); every machine builds the multi-deck section (`SectionPlan` + `CityStack`) from the seed, the barrier compares `CityStack.checksum()`, the crew spawns on the entry road | `net_mission.gd`, `scripts/game/test_drive.gd` | new |
| Relayed broadcast: `Session.broadcast_event(kind, data)` (a client's goes through the host, the others hear the real sender and stamp) | `net_session.gd` | new |
| Mech snapshots (co-op step 2): the owner streams its mech on `T_SNAP` at 30 Hz, the host forwards; puppets interpolated ~100 ms behind the shared clock | `net_mech_stream.gd` (child "Mechs" of Session), `net_mech_codec.gd`, `net_puppet_buffer.gd`, `net_mech_state.gd`; game side `scripts/game/crew_sync.gd`, `mech_puppet.gd` | cast's M2 (`NetSnapshot`, `NetCodec`, `NetInterp`) |
| Enemies in co-op (W4): host-only spawn and AI, manifest + T_ENEMY stream + reliable "enemy.*" events, client puppets, enemy fire records on every machine | `net_enemy_stream.gd` (child "Enemies" of Session), `net_enemy_codec.gd`, `net_enemy_buffer.gd`, `net_enemy_state.gd`; game side `scripts/game/enemy_sync.gd` | cast's M3 (host-owned actors) |
| Reliable events + unreliable sequenced packets (7-byte header, stale drop, u16 wrap) | `net_wire.gd` | verbatim |
| Shared clock (NTP-style bounds, slewed) | `net_clock.gd` | verbatim |
| Link simulator (off / coast / rough) on ENet; Steam FakePacket config | `net_link.gd`, `net_steam_link.gd` | verbatim |
| Telemetry, one CSV row per second per machine, clients' rows filed on the host | `net_telemetry.gd` | ported, without the casts / hits sheets |
| Steam init, lobbies (game key `babamech_ringdeck_coop`, build-matched), first-open Join, overlay invites, `+connect_lobby` | `steam_identity.gd`, `steam_lobby.gd` | ported |
| Authority kinds + facade (`Net.is_host`, `online`, `crewed`) | `net.gd` | cut down |
| Multi-process test harness (`NetTest`, `const PEERS`, `const LINKS`), `run.ps1 -Crew N -Link L` | `scripts/test_support/net_test.gd`, `test_runner.ps1`, `run.ps1` | ported, crew 3 -> 4 |
| Contract lint (no net/Steam code outside `scripts/net/`, no `unreliable_ordered`, no high-level sync, no global random, net_fields declarations) | `tests/test_net_contract.gd` | sections 1-3 of cast's |

Steam app id 480 (Spacewar) in `steam_appid.txt` until babamech has its own; the lobby's `game` key keeps other Spacewar
projects out, `version` keeps different builds apart.

## Handshake
```
host -> joiner   sys.ask      {protocol, build}
joiner -> host   sys.hello    {protocol, build, name, head, chassis, accent, loadout, steam_id}
host -> joiner   sys.welcome  {seat, peer, entries, host_unix, link}   |  sys.refuse {reason}
host -> all      sys.roster   {entries}          after every join / leave / profile change
joiner -> host   sys.profile  {name, head, chassis, accent, loadout}
host -> all      sys.link {preset}, sys.bye {reason}
```
Refusals: "Crew is full" (5th player), "Different build", "That crew is on a mission" (from the host's Launch until the
mission ends; mid-mission join is not built: cast's M6 seat handover is the model), and at the load barrier
"Desync: different city" / "Didn't load the mission in time" (Session.kick).

## Mission (co-op step 1)
```
host -> crew     mission.launch {seed, mode, start_t, crew}  Session.start_mission(seed, mode): start_t = host_time() + 2.5 s
client -> host   mission.loading {}                     Session.report_mission_loading(): right before the (blocking) build
client -> host   mission.ready  {sum, ms}               Session.report_mission_built(TestDrive.mission_checksum(), build ms)
host -> crew     mission.go     {start_at}              every remaining member reported the host's sum; start_at = +0.5 s
host -> crew     mission.state  {state}                 the mission's progress changed (W6, below): Session.send_mission_state
host -> crew     mission.end    {reason}                the host left the mission (Esc), or the outcome's hold ended: Session.end_mission()
```
- Only the host's Launch counts (a client's button reads "Waiting for the host to launch"). Every machine, the host too,
  gets `Session.mission_started(params)`, plays the bay alert until `start_t` on the shared clock, then loads the test
  drive. `crew` is the roster by seat at launch: `{peer, seat, name, head, chassis, accent, loadout}`. The crew state is
  "mission" from the launch to the end (joiners refused).
- **The city** (`params.mode`): `stack` (the default) builds the multi-deck mission section, `SectionPlan.make({seed})`
  then `CityStack.build`; `district` builds one `CityDistrict` (the pre-stack test drive). A launch without a mode is
  read as `district`. The stack is placed with the ENTRY deck's floor through the world origin, and `td.city` is that
  deck, so the systems that still read one district (combat, enemy spawner, audio, player AI) work in world space on the
  entry deck (per-deck work is W3). Every mech's ring is the entry deck's frame (shared axis: up / gravity right on every
  deck); `stack.follow(camera)` lights the camera's deck on each machine; falling 25 m below the LOWEST deck's floor
  respawns (`CityStack.fell_out`). Every deck's props are networked (prop events carry the deck); each mech's MechAudio
  reads footstep surfaces from the deck it is on.
- Each machine builds the city from `params.seed` + `mode`, spawns one mech per crew entry (seat order: two columns 8 m
  apart, rows 10 m apart: `TestDrive.entry_spawn(entry, deck, i, n)` around `CityStack.entry_transform()` on the entry
  road, or `TestDrive.spawn_point(i, n)` on the district's avenue), holds its own still, and reports
  `TestDrive.mission_checksum()` (`CityStack.checksum()`, or `CityPlan.checksum()` for a district).
  The host compares with its own: a mismatch is printed (`[Net] DESYNC ...`), noted in telemetry (`NetTelemetry.note`, a
  `.notes.txt` beside the CSV), kept in `Session.mission.desyncs`, and that pilot is sent out. A member silent for 45 s
  after `start_t` is sent out too. Then `mission.go`; `Session.mission_go(elapsed)` fires everywhere at `start_at` and
  the mechs are released.
- Ownership: each mech carries its owner peer (`MechSpawn.owner_of(m)`, the "owner_peer" meta). `TestDrive.mechs` is
  peer -> mech, `TestDrive.mech_of(peer)` finds one, `spawn_order` is the seat order; `TestDrive.mech` is the local one
  (input, camera, HUD, combat). Remote mechs are puppets of their owners' snapshots (below).
- **Seed**: the Launch (host or solo) rolls a fresh seed from a launch-only generator seeded by the clock (not a gameplay
  roll; it is broadcast), unless `--seed N` forces it. Solo, the hangar hands `{seed, mode}` to the test drive itself
  (`TestDrive.solo_launch`); the plain test drive (`run.ps1 -TestDrive`, tests) uses `--seed` (default 1). Flags:
  `--stack` / `--district` (`TestDrive.launch_mode`); tests force a mode with `td.city_mode` before adding the scene. N
  (new city) is solo only. A client leaving the mission (Esc) leaves only on its own machine; the host leaving ends it for
  the crew (`mission_ended` on the clients, back to the hangar).
- Tests: `test_net_mission` (2), `test_net_mission_4` (full crew), `test_net_mission_desync` (3, launched as a district;
  one client perturbs its checksum with `Session.mission.checksum_salt`, is sent out, and is refused when it tries to
  come back); `test_net_stack` (2) / `test_net_stack_3` (3), scenario `tests/net_stack_case.gd`: same seed, mode and
  stack checksum everywhere, each mech in its entry slot on the entry deck's floor, no two overlapping, and
  `broadcast_event` heard once from each real sender; solo `test_stack_drive`.

## Timeouts (who decides a member is gone)
The session's own watchdogs decide; the transports' timeouts are wide so they never decide first.

| What | Before | Now |
|---|---|---|
| ENet peer timeout (`ENetPacketPeer.set_timeout`, both sides, `_tune_enet` as soon as the peer exists) | ENet default: limit 32, min 5000 ms, max 30000 ms | limit 32, min 30000 ms, max 60000 ms (`ENET_TIMEOUT_*`) |
| Steam connected timeout (`k_ESteamNetworkingConfig_TimeoutConnected` = 25, global, before the SteamMultiplayerPeer opens: `NetSteamLink.apply_timeouts`) | Steam default 10000 ms | 60000 ms (Steam answers keepalives on its own thread, so a blocked main thread alone doesn't trip it) |
| Host drops a silent client | `CLIENT_SILENCE` 10 s | 10 s; while that member is loading (launch until its mission.ready): `Session.mission.load_allowance()` = load timeout + 2.5 + 5 s (52.5 s) |
| Client ends a silent session | `HOST_SILENCE` 6 s, reason "The host left" | 6 s, reason `HOST_SILENT` "Lost the host (no answer)"; while loading (launch until mission.go): `load_allowance()`, reason `HOST_LOST_LOADING` "Lost the host while loading" |
| Load barrier | `LOAD_TIMEOUT` 45 s after start_t, kick `LOAD_SLOW` | the same, overridable per machine: `Session.mission.load_timeout` (tests: 4 s) |
| This machine's own stall | counted as the other side's silence | a frame longer than `STALL_GRACE` (0.5 s) moves every silence clock forward by the stall (`_pause_silence`; logged, telemetry note) |

**Why** (LAN bug, UHD 620 client): `CityStack.build` blocked the laptop's main thread 7.76 s in one frame. No ENet
service, so no acks; the host's reliable resends (events, roster) hit ENet's limit and its 5 s minimum, and the HOST's
ENet dropped the client at ~5.8 s of silence (crew 2 -> 1). The host's ENet resets a timed-out peer silently, so the
client, back from its stall, heard nothing and ended 6 s later with "The host left". Reproduced by
`test_net_load_stall` with ENet's default timeouts (host: "c1 dropped: lost the link while loading").

- **Stepped load (the game's crew mission in the stack):** `TestDrive._load_stepped` runs `CityStack.build_step(8 ms)`
  once per frame ("Building the station... N%" in the middle of the screen; mechs not simulated), then sets up the
  scene, then `AmbientLife.setup_step(8 ms)` once per frame, and only then reports `mission.ready` (so `mission.go` waits
  for every machine's whole load). `TestDrive.loading` is true meanwhile (no input, no physics). Events that arrive
  during the load are dispatched as usual: EnemySync pulls its manifest after setup, life replays what it heard while
  setting up, and nothing gameplay is sent before `mission.go`. Measured here (desktop, headless): 143 chunks, longest
  25 ms, 1.26 s of build. Crew TESTS load in `_ready` (`TestDrive.stepped_load = false`, set by NetTest) because they
  check the scene two frames after adding it; `test_net_load_stall*` run the stepped load.
- **Keep-alive inside a blocking load** (the unstepped path, and any long frame): `Session.service_transport()` polls
  the transport (ENet acks and pings, Steam takes its messages) and flushes, WITHOUT dispatching: what arrives waits in
  the peer's queue for the next SceneMultiplayer poll. The unstepped crew load builds the stack with `build_step(40 ms)`
  chunks in one frame and services the link between chunks and setup steps.
- **Kicks:** a member sent out (`Session.kick`: DESYNC, LOAD_SLOW) is disconnected `REFUSE_GRACE` after it is HEARD
  again (so it has had the refusal; an ENet disconnect in the same receive batch would discard it), or `KICK_WAIT`
  (30 s) at the latest. Refused joiners keep the plain 1 s grace.
- **Reasons on screen:** a client's `Session.last_reason` (the menu shows it) is `LOAD_SLOW`, `DESYNC`,
  `HOST_LOST_LOADING`, `HOST_SILENT` or `HOST_LEFT` (the host said bye or closed). The host's `Session.crew_note(text)`
  ("c1 dropped: went silent while loading", "c1 dropped: lost the link while loading", "c1 dropped: was sent out:
  Didn't load the mission in time") shows under the test drive's help line for 8 s and is a telemetry note.
- Tests: `test_net_load_stall` (a client blocks its main thread 12 s in the mission load while the host keeps sending
  reliable events: it lands in the mission, the crew stays 2), `test_net_load_stall_slow` (load timeout 4 s, the same
  stall: kicked with LOAD_SLOW, both sides say why). Hook: `TestDrive.test_stall_ms` (client only).

## LAN soak (bots, automation, [Flow] logs)
Every transition prints one `[Flow] t=<host_time> peer=<id> <role> <what>: <detail>` line (`FlowLog.say`): session
hosting / joined / refused / ended, crew joined / dropped, hangar entered, launch / launch received / relaunch, load
start / done, checksum ok / mismatch, mission_go, first enemy contact, enemy killed, deck cleared, extraction reached,
mission won, mission_ended, back in hangar. A hands-off two-mission run (scratch export, ENet):
`host: --net-host --net-port P --bot --dev-fast-clear --dev-bot-travel --auto-launch 2 --auto-relaunch --auto-quit`,
`client: --net-join 127.0.0.1:P --bot --dev-fast-clear --dev-bot-travel --auto-quit`. `--bot` = MissionBot
(scripts/game/mission_bot.gd); DEV ONLY: `--dev-fast-clear` (enemies take 10x, on the machine deciding the hit: pass it to
every instance), `--dev-bot-travel` (the bot jumps where its walk can't get it; logged "dev travel"). CrewAuto
(scripts/ui/crew_auto.gd) launches when every client's "crew.hangar" heartbeat shows it back in the hangar. Verified
2026-11-22, seeds 4 (ramps) and 9 (lifts): two full missions each, both instances quit. Test: `test_net_bot_mission`.

## Mission progress (W6, win side)
```
host -> crew     mission.state  {state}      reliable, on every change: MissionRules.state() {outcome, reason, done, left, current}
host -> crew     mission.go     {start_at, state?}   carries the latest state (if any) for a member that reaches the barrier late
```
- Every machine builds the same `MissionRules.make(section)` (no overrides: extraction on, crew-wipe loss off) in
  `MissionFlow` (`scripts/game/mission_flow.gd`, child "MissionFlow" of the test drive, stack mode only; a district has
  no section, so no objective). Objectives: clear every deck, then reach the extraction zone (docs/design/mission-section.md §14).
- **The host decides** (a host alone too): about 4 times a second (`EVAL_INTERVAL` 0.25 s) it feeds
  `{"t": Session.host_time(), "enemies": td.enemies_alive_per_deck(), "crew": [{peer, downed, deck, x, s}]}` to
  `rules.evaluate()`; deck / x / s from `CityStack.to_deck_arc(pos)` of its own mech and of each puppet still in the
  roster, downed = the local `PlayerTarget.disabled` / the puppet's streamed `disabled` (a disabled mech doesn't
  extract). When it returns true, `Session.send_mission_state(rules.state())` (NetMission keeps it in `state`).
  Evaluation is **gated** until `mission_go` fired AND the host spawned the enemies (`td.enemies_spawned`): a clear
  objective latches the first time its deck counts 0 alive. Decks without enemies complete at the first evaluation
  (today enemies spawn on the entry deck only, so the HUD goes from "Clear deck N" straight to "Reach the extraction portal").
- **Clients never evaluate**: `Session.mission_state_changed(state)` -> `rules.apply_state(state)`. Everyone reads
  `rules.text()` / `marker()` / `outcome` (the HUD: MissionHud, docs/design/hud.md "Mission objective").
- **End**: on the outcome every machine shows the banner ("MISSION COMPLETE" + the reason) for `MissionFlow.END_HOLD`
  (4 s); then the host calls `Session.end_mission("Mission complete")`: `mission.end` to the crew, `mission_ended` on
  each client, everyone back to the hangar (the menu opens on the hangar online). A client that hears no `mission.end`
  leaves on its own `CLIENT_GRACE` (6 s) later. Esc still leaves as before.
- **Solo** (offline): the same rules evaluated locally (local seconds for t), the same banner, then back to the menu on
  its hangar (`FrontEnd.next_screen = "hangar"`). Solo mechs keep their auto-respawn; no downed / revive and no
  crew-wipe loss yet (user decision, 2026-11-22): `MissionRules` "wipe" stays off, so the outcome is only ever "won".
- Tests: `test_net_mission_flow` (2) / `test_net_mission_flow_3` (3), scenario `tests/net_mission_flow_case.gd`: no
  clear latched right after go while enemies live, clients mirror the host's state and objective line, the host's kills
  turn every machine to extraction (waypoint on every HUD), the last client's mech in the zone gives "won" everywhere
  with the banner, then mission.end reaches every client and the crew stays together; solo `test_mission_flow`.

## Mech snapshots (co-op step 2)
```
client -> host   T_SNAP  its own mech (57 bytes)                          30 Hz, unreliable, sequenced (newest wins)
host -> client   T_SNAP  the host's mech + the other clients' (<= 155 B)  each forwarded sample once, with its age
```
- **Entry (49 bytes, `NetMechCodec`)**: seat (3 bits) + teleport counter (4 bits); flags grounded / thrusting / emergency /
  shutdown / hover / designator / disabled; age (2 ms units: a forwarded sample keeps its moment on the shared clock); position
  (i24 mm x3); velocity (i16 cm/s x3); yaw in the ring frame (u16); hip twist `leg_yaw` (i8); heat (u8 of heat_cap); last
  touchdown speed (u8, the landing dip); aim point relative to the mech (i16 x3, 1/4 m); PlayerTarget component HP (u8 x 9,
  `NetMechCodec.COMPONENTS`: torso (the hull), head, leg_l, leg_r, side_l, side_r, shoulder_l, shoulder_r, back; 255 =
  absent); `disable_cause` (u8: 0 none, else 1 + index in COMPONENTS); WeaponMount `aim_yaw` / `aim_pitch` per hardpoint
  (i8 x 10, 1.5 deg steps, `NetMechCodec.MOUNTS`). Packet = 7 (NetWire header) + 1 (count) + 49 per mech: 57 B up, 155 B
  down in a full crew (budget `MAX_PACKET` 160, raised from 100 for the damage and mount fields; the unreliable MTU is
  ~1200 B). Crouch is not runtime state (a
  model parameter, SPAWN), so it isn't sent.
- **Owner side**: `CrewSync` (test drive, crew mission) feeds the local mech every physics step (after its rig posed it):
  `Session.mechs.feed(state, delta)`. Velocity is taken from the motion over the step; the sample time runs on a step
  clock eased toward `host_time()`, so a frame hitch (several physics steps back to back) doesn't squeeze motion into a
  few ms. A jump of more than 6 m between feeds is a teleport (counter + 1).
- **Puppets**: every other crew mech has `MechController.puppet` on (no `step()`: no input, no physics) and a
  `MechPuppet` child that, before the rig poses it, writes `Session.mechs.pose(peer)` into the mech (transform,
  velocity, `puppet_grounded`, heat, thrust / emergency / shutdown, last_impact, `MechRig.twist_override` = the owner's
  `leg_yaw`). Rig, gait (feet plant against this machine's ground), ThrusterFx, pilot head and audio then run as for your
  own mech. `NetPuppetBuffer` (cast's NetInterp): render time `host_time() - delay`, delay 100 ms adaptive up to 400 ms
  (p90 of arrival lag + 30 ms; a forwarded mech settles near 190-210 ms under coast), Hermite on position + velocity,
  extrapolation (velocity and turn rate) up to 150 ms then hold, a teleport (or a jump over 6 m in one frame) re-plants the feet.
- **Combat hooks**: each puppet is a `PlayerTarget` (`CrewSync.targets`) with `owner_peer` = its owner, carried along by
  its MechPuppet (only the owner's machine ticks a target). `MechPuppet.aim_point` / `designator` hold the owner's
  aim and guided-missile track for co-op step 3; nothing crosses owners yet (hits on a puppet are not applied here).
- **Damage and mounts**: `MechPuppet.components` {name: 0..1}, `hull` (torso fraction), `downed` (the owner's
  `PlayerTarget.disabled`), `disable_cause`; copied every frame onto the puppet's PlayerTarget (`hp`, `disabled`,
  `disable_cause`: a read-only mirror, the owner decides). Each weapon model on a puppet turns to the owner's
  `aim_yaw` / `aim_pitch` (`WeaponPose.apply`). Owner side: `CrewSync.component_fractions(pt)`, `CrewSync.mount_aims(rack)`.
- **Crew panel**: `hud.crew_panel.status_source = CrewSync.status`: hp = the hull, heat, state "disabled" (downed) /
  "overheat" / "ok" from the snapshots.
- **Contract**: `NetMechCodec.MECH_FIELDS` lists the vars the snapshot carries; `test_net_contract` checks each is OWNER
  and every OWNER var of MechController / MechRig is carried. `PARTIAL_FIELDS` (PlayerTarget hp / disabled /
  disable_cause, WeaponMount aim_yaw / aim_pitch) only get the first check: the rest of their owner state stays with the
  owner (written reasons in the codec).
- **Tests**: `test_net_snap` (2), `test_net_snap_4` (full crew), scenario `tests/net_snap_case.gd`: each machine drives its
  mech through the same script (walk, thrust hop, diagonal strafe, turn in place, stand, forced overheat); the host checks
  every puppet against its owner's true position at the puppet's render time (max < 0.5 m off, < 0.8 m coast; mean
  under a quarter of that; measured max 0.1-0.35 m, mean 0.01-0.08 m), heading (< 0.12 rad), final spot (< 0.3 m), heat /
  thrust / overheat crossing, the crew panel's state, PlayerTarget owners, and the packet budget; then hull damage, the
  downed state + cause (and their PlayerTarget mirror, crew panel "disabled") and the largest barrel yaw (within 3 deg).

## Enemies (W4, the host-owned world)
```
client -> host   enemy.req    {}                                     until the manifest arrives (every 0.75 s)
host -> client   enemy.spawn  {e: [[n, id, type, deck, xform, dead, broken, hp]...]}   the manifest, as things are now
host -> client   T_ENEMY      the enemies due (28 B + 1 per component each)  20 Hz while changed, 2 Hz keep-alive
host -> crew     enemy.ev     {l: [[kind, n, data]...]}               one reliable batch per physics frame, in order
```
- **Spawn and AI on the host only.** `TestDrive.spawn_enemies` (TestDriveCombat.rebuild_encounters asks it): solo, as
  before; in a crew mission the HOST runs `EnemySpawner` from the mission seed around `TestDrive.encounter_origin()`
  (the stack's entry, or the district's first slot: the same whatever seat the host has), scaled to the crew size, and
  tags each enemy with `spawn_deck` (`CityStack.deck_at`); a client spawns none. EnemySpawner now lays the encounter out
  from the plan's avenue lane (`CityPlan.avenue_x()`: x = 0 in a district, the entry's lane on a stack deck) and refuses
  floor holes, so it lands in front of the entry on the stack.
- **Every deck** (stack): the host spawns one encounter per deck k (`stack.decks[k].plan`, `stack.deck_ring(k)`, laid out
  from the entry's arc spot on that deck; its plan comes from the mission seed and k, so the layout is per deck and
  deterministic), `spawn_deck = k`, target ids prefixed `d<k>_` off the entry deck (unique across decks). Enemies stay on
  their deck: they path on its road graph (`EnemySquad.add_deck_nav` / `find_arc_path(.., deck)`), engage and hear about
  (target board, relay) only targets on it (`EnemySquad.deck_of` = `CityStack.deck_at`), and SLEEP (no AI) while no crew
  mech is on their deck (`EnemySquad.deck_awake`), which keeps three decks of encounters inside the frame budget. Seed 11:
  6 / 7 / 7 enemies on decks 0 / 1 / 2. Client puppets use their deck's ring.
- **Puppets.** `EnemySync` (child "EnemySync" of the test drive, crew missions only) gives each host enemy a net id
  (`EnemyBase.net_id`, manifest order). A client builds the same class from each manifest entry with `EnemyBase.puppet`
  on: same meshes and hit spheres (its own shots hit it; CombatNet's `combat.hit` reaches the host's enemy by target id),
  never ticked by CombatWorld there (owner_peer 0 = the host), so no AI runs. Every physics frame it writes
  `Session.enemies.pose(n)` into the puppet (transform from position + ring-frame yaw; `EnemyBase.puppet_apply`: AI state,
  aim, heat, stagger, kick, telegraph lock, HP, with a hit flash when HP drops; move / slew derived from the motion for
  the stride and audio) and runs `EnemyBase.puppet_tick` (flashes, telegraph FX, status bar, stride, wreck FX).
- **Stream (`NetEnemyCodec`, T_ENEMY = 17).** Entry: u16 net id, u8 AI state (index in `STATES`), u8 flags
  (shutdown / staggered / dead), i24 x3 mm position, u16 hull yaw (ring frame), i16 x2 aim (turret / torso yaw, pitch),
  u8 heat, u8 aim kick, i16 x3 lock point (1/16 m, relative), u8 component count + u8 HP per component
  (`EnemyBase.comp_order()`). 31-33 B per enemy; up to 32 per packet (~1.1 KB, inside the MTU); more go in more packets.
  An enemy streams at `ACTIVE_RATE` (20 Hz) while its sample changes and for `SETTLE` (0.25 s) after, else at
  `IDLE_RATE` (2 Hz); a dead one not at all. `NetEnemyBuffer` renders `delay` (100 ms, adaptive to 400 ms) behind
  host_time: linear position, short-way yaw / aim, the earlier sample's state / flags / HP, at most 150 ms extrapolation.
- **Events (`enemy.ev` kinds).** `add` (an entry spawned later), `gone` (removed: wreck cleanup, `clear_enemies`),
  `alert {state}`, `tele {w, k, t0, dur, lock}` (telegraph start on the shared clock: the client shows it from t0, so it
  never lags the stream; rule 7's 0.3 s floor holds at arrival, measured 0.56-0.64 s lead), `tele_x {reason}`,
  `dmg {c, r, wk}` (audio tick), `comp {c}` (component destroyed: same pop-off debris, flames, impact via
  `EnemyBase.puppet_break`), `dead {cause, r}` (destroyed: explosion, debris from the looks generator, wreck via
  `puppet_kill`), `heat {on}` (overheat / reboot), `fire {rec}`. Alert / telegraph / damage / heat are replayed through
  `EnemySquad.enemy_event`, so CombatAudio plays them on clients.
- **Enemy fire.** The host forwards every enemy fire record its CombatWorld fires (`rec.enemy`) as `fire`; each client
  fires it on its own CombatWorld (peer 1, team enemy), so every machine sees the shot, and only the victim's machine
  builds the Hit on its own mech (`CombatWorld.decides`); the host shows the impact on the puppet.
- **Targeting.** Host enemies already see every crew mech: CrewSync registers each puppet as a PlayerTarget (team
  "player", the owner's peer), and enemies lead it from its puppet's streamed velocity.
- **Missions.** `TestDrive.enemies_alive_per_deck() -> Array[int]` (`EnemySync.alive_per_deck(enemies, decks)`): alive
  enemies by `spawn_deck`, one entry per deck (MissionRules.evaluate's "enemies"). Authoritative on the host; a client's
  puppets follow the host's `dead` events.
- **Contract.** `NetEnemyCodec.ENEMY_FIELDS` (EnemyBase ai_state / _dead / _locked_aim / hp / heat / aim_kick, the
  turret's _yaw / _pitch, the tank's _turret_yaw, the skirmisher's _aim_yaw) must be OWNER (test_net_contract).
- **Tests**: `test_net_enemy` (2), `test_net_enemy_3` (3), scenario `tests/net_enemy_case.gd`: the same enemies (net id,
  id, type, deck, spot) everywhere, puppets with no AI; a skirmisher driven by the host followed by every puppet (max
  0.33-0.45 m, mean 0.04 m) and a turret's aim; a client's damage then kill shown on every machine with the wreck and
  the per-deck count; a host enemy bolt decided and taken on the victim's machine only; a telegraph targeting a
  client's puppet arriving >= 0.3 s ahead.

## Next (in cast's build-plan order)
1. (Done: mech snapshots, above.)
2. (Done: the shared mission start, above.)
3. Host-owned world (M3): enemies done (above; per-deck spawns and navigation beyond the entry deck still open); pickups /
   vehicles as host-arbitrated objects.
4. Combat across owners (M4): see `docs/design/weapons.md` section 5.1 (CombatNet: fire records, remote hits to the owner).
5. Late join (M6), then polish (M7 is partly in already: link sim, invites).
