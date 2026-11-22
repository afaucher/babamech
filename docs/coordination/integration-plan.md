# Integration plan: everything in the game, everything in co-op

User goal (2026-11-22): "integrate all our outstanding work and get working coop across all the features."

Definition of done: a 2-4 player session (Steam or ENet) launches from the menu into the **multi-deck city stack**
from the host's random seed; every machine sees every mech, every shot, every enemy, every prop and every civilian /
vehicle consistently; damage, downed / revive and mission end work for everyone; each feature has a net test
(`PEERS 2-4`, `LINKS off/coast`); `-TestAll` green. Also playable solo (host alone).

Rules: read `docs/coordination/antigravity.md` + `git status` before each step, log files there, Opus subagents
implement, net code only in `scripts/net/`, no commits unless the user asks. **`scripts/game/test_drive.gd` (the mission
scene) has one writer at a time: Engine.** Others expose an API and ask Engine to wire it, or coordinate a short
hand-off in the coordination file.

## Workstreams (owner, depends on)

| # | Work | Owner | Depends on |
|---|---|---|---|
| W1 | Co-op combat: shared clock, fired records broadcast, remote_hit to owner, remote missiles follow puppet aim | Weapons | in flight |
| W2 | Stack in the game: `--stack` path on the test drive, then default. Host seed random, `SectionPlan` from seed, `CityStack.build`, spawn at `entry_transform()` with crew offsets, `stack.ring()`, barrier on `stack.checksum()`, `stack.follow(camera)` per machine, fall-out uses lowest deck, `td.city` kept meaningful for old callers | Engine (scene + net) with Environment (city API, light layer 20, ramp walk test, perf + far-deck LOD) | - |
| W3 | Per-deck world systems: CombatWorld props via `stack.props_at(point)`; audio binds every deck's props and footsteps read `stack.deck_at` | Weapons (combat), Environment (props API) | W2 |
| W4 | Enemies in co-op (host-owned world, cast M3): enemies spawn and think on the host only; host streams pose / state / telegraph / HP; clients render puppets; enemy fire becomes broadcast fire records (so client mechs take enemy damage); wrecks / destruction as events; per-deck spawn and navigation (first step: enemies stay on their deck) | Engine (stream, in `scripts/net/`) + Weapons (enemy fire records), minimal edits in `scripts/enemy/` logged for antigravity | W1, W2 |
| W5 | Ambient life in the game: stack version (one `AmbientLife` across decks, tram, pods, carts), added to the mission scene, host-arbitrated as already built, weapons hooks live | Environment | W2 |
| W6 | Downed / revive / mission end: revive verb on `PlayerTarget` (owner applies), downed state replaces auto-respawn, crew panel shows downed + revive timer, win (all enemies down) / lose (crew wiped) as a host event, return to hangar | Weapons (verb), Engine (HUD, flow), Missions (objective definition) | W1, W4 |
| W7 | Pilot heads on puppets: teammates' heads react (damage, heat, fear, firing) from snapshot / event state; accent colour and head from profile | Pilots | W1 |
| W8 | Audio for remote events: CombatAudio already listens to `fired` / `remote_hit`; verify remote shots, hits, enemy events, civilians and footsteps of puppets play positionally | Weapons + Environment hooks; antigravity owns `scripts/audio/` (minimal logged edits if it stays away) | W1, W4, W5 |
| W9 | End-to-end co-op test: a 2-4 peer headless test that launches a mission in the stack, walks, fires, kills an enemy, knocks a prop, downs and revives a teammate, ends the mission; plus a perf budget run with 4 mechs in the stack | headless-tests | all |
| W10 | Pending art picks wired in: damage diagram (Engine grid), pod model (Environment grid), back equipment (Weapons + Mech) | per owner | user picks |

## Order
1. Now, in parallel: W1 (Weapons), W2 (Engine + Environment), W5 stack version of ambient life (Environment), W7 design (Pilots).
2. After W1 + W2: W3, W4.
3. After W4: W6, W8.
4. W9 last, but headless-tests can start the scaffolding (a multi-peer mission harness) now.

## Antigravity
Antigravity owns `scripts/enemy/`, `scripts/audio/` and player AI, but has been silent since 2026-11-21 22:48 with three
open questions from Environment. To keep co-op moving, W4 and W8 make the smallest possible edits in those folders, each
logged in `antigravity.md`. If antigravity returns, it reviews those edits and takes the areas back.
