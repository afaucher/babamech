# Hangar bots: AI pilots in a crew seat

User request (2026-11-23): "Add a function to add bots to your game from the hangar. Only the host. The bot picks its own
loadout." Engine owns this (scripts/net/, test_drive, mission_bot, front end). Status: built (uncommitted); docs/networking.md "Hangar bots" has the wire summary.

## 1. Shape (AGENTS rule 6)
A bot's mech is an **owned actor whose owner is the host machine**. The host streams it exactly the way a player's
machine streams its own mech (NetMechStream, T_SNAP, NetMechCodec entry, puppets on the other machines). Nothing new
travels for the mech itself; the bot's *roster entry* is host state carried in the existing `sys.roster`.
It is not host-arbitrated world state (enemies): it has a crew seat, a PlayerTarget, a WeaponRack and fire records like a
pilot, so every pilot path applies to it unchanged, with "owner peer" read as "the machine that runs it" (= 1).

## 2. Identity: the pilot id
- Every crew member has a **pilot id**. A player's pilot id is its peer id (positive, as today). A bot's pilot id is
  **negative: -1, -2, -3** (its bot slot; never a valid peer id on ENet or Steam, so it can't collide).
- `Session.crew()` lists players AND bots by seat. A bot entry is a roster entry with `"bot": true`:
  `{peer: <pilot id, negative>, seat, name, head, chassis, accent, loadout, bot: true, skill}`. Use `peer` exactly as
  today (crew lists, `TestDrive.mechs`, `spawn_order`, `_seats`, `MissionFlow.crew_facts()`, `"player%d" % id` target
  / shooter ids -> "player-1").
- `Session.roster` stays **players only** (peer -> entry). Everything that talks to the transport (sends, silence
  watchdogs, telemetry rows, kicks, hello / profile, `Net.crewed()`, `mission.members()`, the load barrier) keeps
  iterating `roster` and so never sees a bot. Bots live in `Session.bots` (pilot id -> entry).
- Helpers (NetSession): `is_bot_id(id)` (static, id < 0), `is_bot(id)`, `has_member(id)` (roster or bots: use it where
  code asked `roster.has(p)` about a crew mech), `machine_of(id)` (the peer whose machine runs that pilot: itself, 1 for a
  bot), `bot_ids()`.
- **Authority fields:** a bot mech's `MechController.owner_peer` and its PlayerTarget's `owner_peer` are **1** (the
  machine), on every machine, so `CombatWorld.owns / decides`, `CityProps._owns`, `AmbientLife._owns` all put it on the
  host (PlayerTarget.bind already clamps owner_peer to >= 1). The pilot id is in `MechSpawn.owner_of(m)` (the
  "owner_peer" meta) and in the target id.
- **For Missions (PacingDirector, CREW_SCALE, combat log):** bots are pilots. Count `Session.crew()` (or
  `TestDrive.spawn_order`, which already holds bots) for crew size; take per-pilot facts from
  `TestDrive.crew_members()` -> `[{peer: pilot id, mech, downed, bot}]` (local mech, host-run bots, puppets of members
  still in the crew), which MissionFlow.crew_facts() uses. Per-pilot intensity is the host's (it runs the bots).
  The combat log prints this machine's player only; a bot's lines would be keyed by its pilot id (open item 4).

## 3. Roster, hello, profile
- Host only, crew state "lobby": `Session.add_bot(skill)` takes the lowest free bot slot and the lowest free seat, names
  it from a fixed list by slot ("Rook", "Vesper", "Kestrel"), gives it a head by slot (HEAD_ORDER offset) and an accent by
  slot; `remove_bot(id)`; `set_bot_skill(skill)` (every bot). Each sends `sys.roster` (bot entries included, flagged)
  and fires `roster_changed`. Refused on a client, offline, when the crew is full (players + bots = MAX_CREW 4) or on a
  mission.
- A joiner is refused "Crew is full" when players + bots = 4; seats skip bot seats. Bots never say hello and have no
  sys.profile. `_set_roster` on a client files flagged entries under `bots`. A session's end clears the bots.
- Solo (offline): no bots in this pass (open item 1). Host a crew (alone is fine) to add bots.

## 4. Loadout (rule 4)
`BotLoadout.pick(mission_seed, slot) -> {chassis, loadout}` (scripts/game/bot_loadout.gd, pure): a generator seeded
`hash(["bot_loadout", seed, slot])`; chassis from `MechCatalog.CHASSIS_ORDER`; an archetype per bot (gunner, brawler,
artillery, support), the slot offsetting the first pick so up to three bots get three different archetypes; each hardpoint
filled from that archetype's preferences among `MechCatalog.items_for(hp)` that are built (`WeaponRegistry.built` or
equipment), kept under the chassis weight limit; then `WeaponRegistry.playable_loadout`. **Every machine derives it** in
`TestDrive._spawn_crew` from the launch seed and the bot slot (the entry's loadout is ignored), so nothing about the
loadout travels. The hangar shows the bot's name and head and "picks its mech at launch" (the seed isn't rolled until
Launch). Colour: `BotLoadout.accents(seed, crew)`: the players keep theirs; each bot (by slot) draws from
hash(["bot_accent", seed, slot]) among the MechAccent palette colours nobody else wears; the host also writes it into the
bot's crew entry (set_bot_fields) so crew panels show it.

## 5. What streams, and who runs what
- Host: each bot is a real `MechController` (not a puppet) + `PlayerTarget` ("player<id>", owner 1, auto-respawn to its
  slot, registered in the host's CombatWorld, ticked there) + `WeaponRack` (shooter "player<id>", peer 1, no camera, no
  input) + a `MissionBot` with its own PlayerBot (`TestDriveBotPilot` given a body). Node: `CrewBot`
  (scripts/game/crew_bot.gd), built by TestDrive after combat. Its MissionBot starts at mission_go.
- `NetMechStream.begin(local, seats, owned)`: `owned` = pilot ids this machine streams besides its own mech (the host's
  bots). `feed_owned(id, state, delta)` stamps each with its own teleport counter and step clock. The host's packet to
  each client carries its own mech, its bots and the other clients' mechs (never the receiver's): at most 3 entries in a
  full crew = 155 B, inside MAX_PACKET 160. A client never owns a bot; the host refuses an entry a client sends for
  anyone but itself (unchanged).
- Clients: a bot is a puppet like any teammate (MechPuppet, CrewSync PlayerTarget with owner 1, PilotPuppetLink).
- **Fire records:** CombatNet sends each host bot's records as `combat.fire {r, b: <bot id>}` from the host (peer 1,
  shooter rebuilt as "player<b>" on receipt; accepted only from the host and only for a bot in `Session.bots`). Drone
  launches (`combat.drone {t, hp, b}`) and railgun charge glows (`combat.charge {hp, t, on, b}`) the same way.

## 6. Damage, friendly fire, revive (rules 2-3)
- Victim decides: a bot's PlayerTarget is owned by the host, so every hit on a bot (enemy fire, a client's shot, splash,
  fall damage) is decided and applied on the host only; clients show the impact and mirror HP from the snapshot.
- A bot's shot at a client's mech is decided on that client (record peer 1, victim decides), at a host-owned enemy on
  the host (shooter's machine = host).
- Friendly fire: the crew option applies to bots (team "player"). `MissionBot._ff_guard` runs `BotFireGuard.apply`
  LAST every physics frame (after PlayerBot and MissionBot chose the trigger, before the rack steps) for every bot (local
  `--bot` and hangar bots), against **every other crew mech** in `TestDrive.mechs`. Per enabled slot: the line from the
  slot's real muzzle along the aim over the weapon's FULL range (a miss flies past the aim point; railgun pierce), cut
  only by static geometry, with clearance hull 2.2 + margin 2 + spread cone (spread_max, rocket wobble) + splash radius
  + flak fuse + 5 m for a homing missile's curve, against each mate moved along its velocity for the shot's travel time
  (<= 2.5 s); the mortar: its landing point (splash + scatter + margin, mate moved for the flight time) and its last
  14 m of descent. Unsafe slots are disabled for the frame; none left: trigger off. A flying missile of this shooter that
  would be led into a mate: the aim point is lifted 80 m over it (it climbs away) and the trigger released. Playtest
  causes this closes: the old guard only checked eye -> aim point (not the muzzle, not past the aim, no spread / splash /
  travel time, mortar and missiles in flight unguarded). Limit: a salvo already started (rockets 6, missiles 3) finishes.
- Revive (Missions' DownedCrew, pacing-director.md §4): a downed bot waits for a crewmate's drone (auto_redeploy after
  DownedRules.bot_wait); MissionBot revives downed crewmates with its own drone (player-ai.md §9.7 "Revive").

## 7. Load barrier, launch, telemetry
- `mission.launch.crew` = `Session.crew()` (bots included, flagged). `NetMission.members()` reads `roster`, so the
  barrier, `mission.ready` / `wait` and load timeouts never wait for or kick a bot. The loading screen lists bots as ready.
- Telemetry rows, silence clocks, CrewAuto's crew count: players only (roster).
- Enemy scaling (`spawn_order.size()`): counts bots.

## 8. UI (hangar, crew line-up)
Host (online, lobby) under the crew list: "Add bot" (disabled when 4 seats are taken), a skill picker (rookie / average /
veteran / brawler, `BotProfile.PROFILE_ORDER`; hidden when `FrontEnd.SHOW_BOT_SKILL` is false), and a "Remove" button on
each bot's line. Joiners see bot lines (name, head, "bot, <skill>") but no controls. The hangar stage shows bots like any
pilot.

## 9. Test plan
- `tests/test_net_hangar_bots.gd` (PEERS 2): the host adds a bot before the client joins; the client sees it (flag, name,
  head, seat 2, seats left); a second bot is added and removed; the mission launches; both machines spawn three mechs
  with the same derived bot chassis / loadout; the barrier doesn't wait for the bot; the bot's mech moves on the host and
  its puppet follows on the client; a client shot at the bot is not applied on the client and its HP drop arrives from
  the host's snapshot; enemy / host damage to the bot is applied on the host.
- `tests/test_bot_loadout.gd` (solo): deterministic per (seed, slot), valid / playable for the chassis, variety between
  slots.
- `tests/test_layout.gd`: host hangar shows Add bot / skill / Remove on screen; joiner hangar shows none.
- test_net_contract: every new var declared.

## 10. Open questions
1. Solo bots (offline, no session): would need the offline crew path to spawn real host-run mechs; not in this pass.
2. Skill picker: one crew-wide value (all bots) for now; per-bot if the measurement shows profiles matter.
3. Hangar preview of a bot's chassis / loadout before Launch (the seed is rolled at Launch).
4. Combat log / pacing for bots: Missions' files; bots are pilots with negative ids (section 2).
5. Pilot-head reactions for bots on the host (cosmetic). (Railgun charge glows: sent, CombatNet.add_bot(id, rack).)
6. Supply depots: MissionDepots claims for host bots (needs_core); MissionBot walks to the nearest depot with cores
   when hurt past its profile or disarmed (MissionBot "SUPPLY DEPOTS").
7. Guard limits: a salvo already started finishes; enemies standing next to a mate block shots that could splash it
   (by design: hold fire). The user's playtest log was rotated out of user://logs by test runs before it was read (tests
   share the app's log folder), so the exact circumstances weren't checked.
8. Bot colour: derived at launch (the hangar shows the previous mission's colour, or the default before the first).
