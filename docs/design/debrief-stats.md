# Debrief stats (playtest R2.15 / R2.15a, Missions' half)

The hangar's debrief board (Engine: `DebriefStats`, `DebriefBoard`, `NetMission.last_debrief`) shows numbers the HOST
counted during the mission. This is where they come from. Code: `scripts/mission/pacing/mission_stats.gd`
(`MissionStats`), wired by `MissionFlow`. Tests: `tests/test_mission_stats.gd`, `tests/test_net_stats.gd`.

## Design (after bridge-to-friendship's M19 stat registry)
- **Host-authoritative, clients never compute.** `MissionFlow.rebuild` makes a `MissionStats` child only on the
  deciding machine (host, or solo). Fresh per mission (= reset at mission start).
- **Registry of named counters per pilot.** Rows keyed by the pilot id as a STRING (`"1"`, `"2"`, `"-1"`: hangar bots are
  negative), every launch-crew pilot gets every key at its start value. `add(pilot, stat, n)` and `lower(pilot, stat, v)`
  (for `hp_min`) are the only writers.
- **Every hit carries its source.** `Hit.shooter` (`"player<id>"`, bots `"player-1"`) is already on every hit and every
  fire record; the host maps it to a pilot id (cached).
- **One payload, once, at the outcome.** `MissionFlow._check_outcome` (host / solo) calls `stats.finish(outcome,
  end_reason())`: the counters freeze and the payload is kept in `MissionFlow.debrief`; `_tick_end` hands it to
  `Session.mission.end(end_reason(), debrief)` (host: rides `mission.end` to every client; solo: NetMission keeps it).
- **Ranking is not here.** The board ranks and marks leaders (joint ties); stats never reorder pilots.
- Differences from M19: no per-round reset (one mission), one host-side `MissionStats` node instead of a GameWorld field,
  a few stats are derived rather than counted at a line (client damage taken: below), and `left` pilots are kept.

## Payload (NetMission DEBRIEF v1)
`{v: 1, outcome: "won"|"lost", reason: end_reason(), time: mission s since release, pilots: [{id, name, bot, left?}] in
seat order (the LAUNCH crew: Session.crew() as launched, bots by name), stats: {"<id>": {key: number}}, labels: {extra key:
"Text"}}`. Stats are flat numbers only (no nested dicts). Extra keys (beyond the board's nine): `kills_<kind>` (only kinds
someone killed; 0 for the others), `self_revives`, `redeploys`, `time_down`.
KEY ORDER (`MissionStats.key_order()`): every pilot's row lists the board's nine, then `kills_<kind>` in the fixed order
trooper, strider, tank, gunship, drone, turret (other last; only kinds present), then `self_revives`, `redeploys`,
`time_down`; `labels` lists those extras in the same order, and the board orders its extra rows by `labels`' keys. The
order survives the wire: Godot Dictionaries keep insertion order, the event rides an RPC (Variant encoding, not JSON) and
`NetMission.clean_debrief` rebuilds rows and labels by iterating in order. Only `JSON.stringify` (sort_keys defaults to
true) sorts keys: a printed payload looks alphabetical, the real one is not. Asserted as built (test_mission_stats) and as
received on a client (test_net_stats).

## Sources (all on the host)
| stat | where the host learns it | exact? |
|---|---|---|
| kills | `EnemyBase.destroyed_enemy`, credited to the pilot whose damage (`EnemyBase.damaged` src) was the last applied to it in the same physics frame ("shock" overflow keeps the breaker's credit) | exact for hits and burns; a kill with no pilot damage that frame (fall-out, timeout, a trooper crushed underfoot, enemy fire) credits nobody |
| kills_&lt;kind&gt; | same, by `enemy_type` family: trooper, strider, tank, gunship, drone (+ dropship), turret | exact |
| damage_dealt | `EnemyBase.damaged` (HP actually removed, no overkill) by src pilot; client hits are applied on the host (CombatNet) so the amount is true | exact; enemies only (relays, depots, banners, crewmates excluded) |
| shots | `CombatWorld.fired`: one fire record = one shot (round, rocket, laser pulse, flamer chunk; CombatLog's rule). The host fires every pilot's records: its own, its bots', clients' (CombatNet relay) | exact for everyone (a client's misses DO reach the host as records; a hangar bot's rack fires "player-1" records on the host's world: verified live in test_net_stats) |
| hits | `CombatWorld.hit_landed` on an `EnemyBase`, once per shot key (a splash on two enemies is one hit); client hits are applied on the host, which emits hit_landed | exact. A hit counts only for a shot key already counted as a shot (a client hit that overtakes its batched record waits for it), so hits <= shots always; a hit with no record (a staged test hit, a record the host refused) never counts; splash shares its shot's key; burn ticks are damage, not hits (shot keys kept up to 4096) |
| damage_taken | host-owned pilots (host's mech, bots): `PlayerTarget.damaged`. Client pilots: sum of HP decreases between consecutive snapshots of the owner's stream (`Session.mechs.newest`, 30 Hz, u8 per component); increases (repair drone, core, revive, redeploy rebuild) never subtract | host-owned exact; clients: see bound below |
| hp_min | lowest total structure % (sum hp / sum max), same source as damage_taken; a downed pilot keeps what the killing hit left (a destroyed core does not force 0) | as damage_taken |
| downs | host-owned: `player_disabled`; clients: the snapshot's `disabled` edge | exact |
| redeploys / time_down | host-owned: `player_respawned`; clients: `redeploying` seen during the down. time_down = mission s down (open downs counted to the outcome) | exact (time_down: +- one snapshot) |
| revives | host-owned victim: `player_revived(by)`, credited to by's pilot. Client victim: stand-up without a redeploy, credited to the pilot whose drone the host saw beaming it (`RepairDrone.beamed()`, drones are scheduled effects run on the host) within 2 s | exact for host-owned; clients: no beam seen = nobody (`unknown_revives`) |
| self_revives | `by` = the mech's own target id (R2.9), or a client beamed by its own drone; never a revive given | as revives |
| cores | `MissionDepots.core_granted` (new signal, emitted once per grant by seq at `_take_grant`) | exact |

Not counted (no honest per-pilot source): assists, objectives, friendly fire (victim-decided: a client victim's damage
can't be attributed on the host), distance.

## Client damage taken: error bound
Each snapshot is a u8 per component (max/254, about 1.6 HP on a 400 HP torso), so each change is off by at most one
quantum (rounding errors mostly cancel over a run). Damage and healing inside the same 33 ms snapshot step net out, so
damage taken under a repair drone is UNDER-counted by the heal received in steps that also had a hit (heal_rate 1 % of
total HP per s: about 0.3 % of total per step at most). Damage in the last ~0.1 s before the outcome (stream latency)
can be missed. Measured (`tests/test_net_stats.gd`, 70 small hits on a client, 40 of them under a crewmate's drone):
host-derived 480.9 / 483.8 vs exact 488.3 (coast / off links): -1.5 % / -0.9 %. The test bound is 3 % + 6 HP.
Better (if wanted): a reliable end-of-mission report from each owner with its own exact totals, folded in by the host
before `finish()` (one message per pilot at the outcome, in the mission message pattern; Engine owns scripts/net/).

## Leavers, quitting
A pilot who left mid-mission keeps its column: `left: true`, its row frozen when `MissionScene.crew_member_left` fired
(or, at the latest, absent from the crew at the outcome). The crew quitting before an outcome (host Esc) ends with no
debrief.

## Log
Host / solo print one `[Flow] ... debrief outcome= time= pilots= <id>=k:v,...` line at the outcome
(`CombatLog.note_debrief`; docs/testing.md "Combat log").
