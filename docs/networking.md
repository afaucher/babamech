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
| Mech snapshots (co-op step 2): the owner streams its mech on `T_SNAP` at 30 Hz, the host forwards; puppets interpolated ~100 ms behind the shared clock | `net_mech_stream.gd` (child "Mechs" of Session), `net_mech_codec.gd`, `net_puppet_buffer.gd`, `net_mech_state.gd`; game side `scripts/game/crew_sync.gd`, `mech_puppet.gd` | cast's M2 (`NetSnapshot`, `NetCodec`, `NetInterp`) |
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
host -> crew     mission.launch {seed, start_t, crew}   Session.start_mission(seed): start_t = host_time() + 2.5 s
client -> host   mission.ready  {sum}                   Session.report_mission_built(CityPlan.checksum())
host -> crew     mission.go     {start_at}              every remaining member reported the host's sum; start_at = +0.5 s
host -> crew     mission.end    {reason}                the host left the mission (Esc): Session.end_mission()
```
- Only the host's Launch counts (a client's button reads "Waiting for the host to launch"). Every machine, the host too,
  gets `Session.mission_started(params)`, plays the bay alert until `start_t` on the shared clock, then loads the test
  drive. `crew` is the roster by seat at launch: `{peer, seat, name, head, chassis, accent, loadout}`. The crew state is
  "mission" from the launch to the end (joiners refused).
- Each machine builds the city from `params.seed`, spawns one mech per crew entry at `TestDrive.spawn_point(i, n)` (seat
  order: two columns 8 m apart, rows 10 m apart on the avenue), holds its own still, and reports `CityPlan.checksum()`.
  The host compares with its own: a mismatch is printed (`[Net] DESYNC ...`), noted in telemetry (`NetTelemetry.note`, a
  `.notes.txt` beside the CSV), kept in `Session.mission.desyncs`, and that pilot is sent out. A member silent for 45 s
  after `start_t` is sent out too. Then `mission.go`; `Session.mission_go(elapsed)` fires everywhere at `start_at` and
  the mechs are released.
- Ownership: each mech carries its owner peer (`MechSpawn.owner_of(m)`, the "owner_peer" meta). `TestDrive.mechs` is
  peer -> mech, `TestDrive.mech_of(peer)` finds one, `spawn_order` is the seat order; `TestDrive.mech` is the local one
  (input, camera, HUD, combat). Remote mechs are puppets of their owners' snapshots (below).
- Solo (offline) is unchanged: the hangar loads the test drive itself, seed from `--seed` (default 1; the host's Launch
  uses the same flag). A client leaving the mission (Esc) leaves only on its own machine; the host leaving ends it for
  the crew (`mission_ended` on the clients, back to the hangar).
- Tests: `test_net_mission` (2), `test_net_mission_4` (full crew), `test_net_mission_desync` (3; one client perturbs
  its checksum with `Session.mission.checksum_salt`, is sent out, and is refused when it tries to come back).

## Mech snapshots (co-op step 2)
```
client -> host   T_SNAP  its own mech (37 bytes)                          30 Hz, unreliable, sequenced (newest wins)
host -> client   T_SNAP  the host's mech + the other clients' (<= 95 B)   each forwarded sample once, with its age
```
- **Entry (29 bytes, `NetMechCodec`)**: seat (3 bits) + teleport counter (4 bits); flags grounded / thrusting / emergency /
  shutdown / hover / designator; age (2 ms units: a forwarded sample keeps its moment on the shared clock); position
  (i24 mm x3); velocity (i16 cm/s x3); yaw in the ring frame (u16); hip twist `leg_yaw` (i8); heat (u8 of heat_cap); last
  touchdown speed (u8, the landing dip); aim point relative to the mech (i16 x3, 1/4 m). Packet = 7 (NetWire header) + 1
  (count) + 29 per mech: 37 B up, 95 B down in a full crew (budget `MAX_PACKET` 100). Crouch is not runtime state (a
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
  extrapolation up to 150 ms then hold, a teleport (or a jump over 6 m in one frame) re-plants the feet.
- **Combat hooks**: each puppet is a `PlayerTarget` (`CrewSync.targets`) with `owner_peer` = its owner, carried along by
  its MechPuppet (only the owner's machine ticks a target). `MechPuppet.aim_point` / `designator` hold the owner's
  aim and guided-missile track for co-op step 3; nothing crosses owners yet (hits on a puppet are not applied here).
- **Crew panel**: `hud.crew_panel.status_source = CrewSync.status`: heat and overheat from the snapshots, hp 1.
- **Contract**: `NetMechCodec.MECH_FIELDS` lists the vars the snapshot carries; `test_net_contract` checks each is OWNER
  and every OWNER var of MechController / MechRig is carried.
- **Tests**: `test_net_snap` (2), `test_net_snap_4` (full crew), scenario `tests/net_snap_case.gd`: each machine drives its
  mech through the same script (walk, thrust hop, diagonal strafe, turn in place, stand, forced overheat); the host checks
  every puppet against its owner's true position at the puppet's render time (max < 0.5 m off, < 0.8 m coast; mean
  under a quarter of that; measured max 0.1-0.35 m, mean 0.01-0.08 m), heading (< 0.12 rad), final spot (< 0.3 m), heat /
  thrust / overheat crossing, the crew panel's state, PlayerTarget owners, and the packet budget.

## Next (in cast's build-plan order)
1. (Done: mech snapshots, above.)
2. (Done: the shared mission start, above. Still open: enemies are spawned per machine from the local mech's position.)
3. Host-owned world (M3): enemies streamed after the mechs; pickups / vehicles as host-arbitrated objects.
4. Combat across owners (M4): weapon fire as events with a short lead; hits resolved by the victim; heat stays the owner's.
5. Late join (M6), then polish (M7 is partly in already: link sim, invites).
