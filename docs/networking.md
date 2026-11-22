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
| Pilot profile in the handshake: `name`, `head`, `chassis` in `sys.hello`; changes later via `sys.profile` | `net_session.gd` | new (cast carried `character`) |
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
joiner -> host   sys.hello    {protocol, build, name, head, chassis, steam_id}
host -> joiner   sys.welcome  {seat, peer, entries, host_unix, link}   |  sys.refuse {reason}
host -> all      sys.roster   {entries}          after every join / leave / profile change
joiner -> host   sys.profile  {name, head, chassis}
host -> all      sys.link {preset}, sys.bye {reason}
```
Refusals: "Crew is full" (5th player), "Different build", "That crew is on a mission" (mid-mission join is not built:
cast's M6 seat handover is the model).

## Next (in cast's build-plan order)
1. Mech snapshots (cast M2): the owner streams its mech on `NetWire.T_SNAP` at 30 Hz, packed by hand under ~1.2 KB;
   others interpolate ~100 ms behind (cast's `NetInterp`, `NetSnapshot`, `NetCodec`).
2. The shared mission (M1): seed from the host, every machine builds the deck section behind a load barrier with a checksum.
3. Host-owned world (M3): enemies streamed after the mechs; pickups / vehicles as host-arbitrated objects.
4. Combat across owners (M4): weapon fire as events with a short lead; hits resolved by the victim; heat stays the owner's.
5. Late join (M6), then polish (M7 is partly in already: link sim, invites).
