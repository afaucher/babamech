# Next milestone backlog

Feedback the user has given but said **not to start yet**, plus the independent code audit. When the user says go,
route each item to its owner and move it out of here. Newest batch first.

## 2026-11-25, round 2 (collected, not started)
| # | Feedback | Likely owner |
|---|---|---|
| R2.1 | The repair drone doesn't repair destroyed weapons. | Weapons (repair_drone) |
| R2.18 | Bulwark balance against gunships and snipers (from bot runs, 2026-11-26). A Bulwark bot wins seed 22's defend, but the full mission times out at 950 s; deck 2's sweep took 600 s with 5 deaths. Damage taken: gunships 2177, snipers 1805, breachers 494, tanks 463. Possibly made worse by antigravity's new enemy anti-air (gunships now altitude-match). Also from Missions: a defend relay can sit in an 8 m alley, too tight for wide mechs. | Missions (enemy tuning) + Mech (Bulwark) |
| R2.19 | Survey other low box corners (props, depots, plinths) for the hidden-collision pinning flaw found at a seed 9 ramp end (now fixed there): a read-only sweep with the `test_ramp_stuck` harness, fixes proposed afterwards. | Environment |
| R2.17 | A deck ramp ends in the middle of an intersection: its parapets end inside a junction on the spine, next to the tracks. Screenshot: `C:\Users\alexa\AppData\Local\Temp\claude\90b5a00aafa79186\14f6db35-c9b4-4539-a32f-21058a6abbc4\images\3.webp`. Move it about 6 m (20 ft) so it ends clear of the intersection and its crosswalks. Check every ramp end against junctions across seeds, and fold it into the spine rethink (R2.11). | Environment + Missions (section plan ramp placement) |
| R2.2 | Sending one repair drone blocks both drone slots, even when you have two. | Weapons (back equipment) |
| R2.9 | Self-revive: when you're downed with a charged repair drone, one of them (only one) auto-launches and revives you. It's a normal downing and a normal repair; it just happens to be your drone. You can still redeploy if you want (no change to the prompt). Reverses the "a drone never revives its launcher" rule. Bots get it too. | Weapons (+ Missions downed rules, Engine bots) |
| R2.13 | The objective panel still doesn't work. The user's layout, one section per deck, all decks always listed:<br>`Deck 1:` / `  Clear hostiles, waves 2/3` / `  Raise the flag: 0%`<br>`Deck 2:` / `  Proceed to deck 2` (all an unvisited deck shows)<br>`Deck 3:` / `  Proceed to deck 3`<br>After going down early, deck 1 keeps its objectives where you left them (`Raise the flag: 23%`), deck 2 now lists its objectives because you've visited it, and deck 3 stays "Proceed to deck 3". Show the current deck without a separate "DECK X OF Y" line, e.g. highlight the current deck's header and dim the others, or a ▶ marker. Replaces the current "PROCEED TO DECK N (dim, last)" design. | Missions (objective panel) |
| R2.14 | Damage HUD (mech diagram): remove the red X on destroyed parts, since black already says destroyed. Remove the "0 / 130" line under the diagram: it's heat in raw units (heat / cap, `mech_diagram.gd:689`, `mech_hud.gd:424`), a duplicate of the heat %. | Engine / Weapons (mech_hud, mech_diagram) |
| R2.15 | Debrief screen after combat, with scores. Today a won mission shows "Mission complete" and drops back to the hangar. Proposal: a debrief before the hangar. Mission outcome and time, objectives done (primary and bonus), then a row per pilot (bots included): kills (by type), damage dealt and taken, accuracy, revives given, downs, depot cores used, lowest HP. A few crew awards (most damage, most revives, closest call), then Continue → hangar. Same data on every machine (host-collected); the combat log already has most of it. | Missions (data) + Engine (UI) |
| R2.15a | Debrief layout (user, refines R2.15): shown in the hangar itself, not a separate screen. Pilot names across the top row, one stat per row. Model it on bridge-to-friendship's between-rounds board: `C:\Users\alexa\.gemini\antigravity\scratch\bridge-to-friendship\implementation_plans\m19_stats_and_scoreboard.md` and `scripts/sim/world/stat_registry.gd`. It has host-authoritative replicated counters, a stat registry, every hit carrying its source, ranking kept separate from stats, and ties shown as joint ranks. "Next" returns to loadout selection for the next mission, still in the hangar. | Engine (hangar UI) + Missions (counters) |
| R2.16 | Settings: add a screen resolution option. Review font sizes and how densely information is packed in the lobby (hangar) menu. | Engine (FrontEnd / GameSettings) |
| R2.12 | Redeploying brings you back fully healed and rearmed (all components, ammo, heat cleared). Confirmed by the user; today it is 50% structure with ammo unchanged (downed_rules.gd RESPAWN_STRUCTURE). | Missions (downed / redeploy) + Weapons (ammo) |
| R2.10 | Extraction (agreed design, not started): a third party opens the exit road door. Once you're in the zone it takes 30 s; waves try to stop you. HUD progress only, no station lamps. The door then opens normally and you walk out. | Missions |
| R2.11 | Spine, tram and bulkhead rethink (design note only, in progress): sealable section doors (open normally, shut in a boarding), mechs in one road door and out another, the train on a single track and level with a small station and its own door (it runs only while that door is open), the road door locked down for now, no blue curtain, the central highway cut down, all lane directions consistent. | Environment + Missions |
| R2.3 | The Bulwark's thruster heat is a bit too much: dial it back 20% (80 → 64 heat/s). | Mech |
| R2.4 | An enemy got stuck in a gate when it closed, so the wave's last enemy was behind a locked door (it blocks a sweep or clear). The door must not close until every staged unit is out, and a unit left inside must be pushed out or counted as gone. | Missions (staging / pacing) + Environment (gate doors) |
| R2.5 | A strange diagonal shadow band, seen in a few spots: in the user's shot (deck 03, a wall gate) it falls across the bunker frame, the door and the wall, with no obvious caster. The user suspects a ceiling strip. Likely a directional key light catching overhead structure (ceiling light strips, the deck above, a spine or pillar beam). Find the caster; fix it by making that geometry not cast shadows, or by moving the light. Don't change the overall look without a before/after. Second example: deck 03, on a pillar core with a lift (sign "DECK 03" above the door), the same shadow band from the ceiling across the tower face. Screenshot: `C:\Users\alexa\AppData\Local\Temp\claude\90b5a00aafa79186\14f6db35-c9b4-4539-a32f-21058a6abbc4\images\2.webp`. | Environment (CityLightRig) |
| R2.7 | Aim circles: the blue aim circles turn orange when the aim point is beyond the selected weapon's effective range (e.g. the laser). A hint only: firing still works. | Weapons (crosshair / HUD) |
| R2.8 | Door language (proposed, waiting on the user): barricades only on doors that never open; wave bays visibly marked; sealing a bay as an earnable objective. Background: blast doors, wave bays, portals, the former rubble gate, air doors and lift doors as catalogued 2026-11-25. Today's cordon blocks sit in front of wave bays too, and the mission-section.md fiction is stale. | Missions + Environment, once decided |
| R2.6 | Bot teammates don't wait for help. A hurt bot doesn't hold still or stay near a crewmate's repair drone, and a downed bot redeploys instead of waiting for a revive when a crewmate with a drone can reach it. | Engine (MissionBot) |

## Queued next for Mech (after its playtest batch)
- **Wasp (drone-style hover chassis):** iterate on the body and the idea until the user is happy: 3x3 grids, user
  picks, in-engine reviews. Hover movement, networking and AI are designed with Engine and Missions before gameplay
  is built (chassis-rules.md).

## Code organization audit (2026-11-26; queued, not started)
A second, read-only review by a cloud session, about whether code is in the right classes and folders. It's on remote
branch `origin/ccr-8e014eac-5544o3` (commit 18666a3) as `docs/code-organization-audit.md`, not merged here. Read it with
`git show origin/ccr-8e014eac-5544o3:docs/code-organization-audit.md`. Its verdict: the layering is sound and net/ is
clean, but a dozen classes are really several classes, private members are read widely, several things are
implemented twice, and folders follow session ownership rather than features (mission code is spread over three
folders, `game/` is a catch-all). It proposes a tiered plan; items marked [owners] need the owning sessions and the
user (folder layout) to agree first, items marked [cheap] are mechanical. Line numbers refer to 3dbbb31, so expect
drift: a lot changed since (enemy AI merge, legacy-mode cut). Pick it up after the current milestone, together with
the large-file splits (audit 1, item 7).
**User, 2026-11-26:** "Once everything is stable, let's do 7 + the new code audit in one sweep." Sequence: a clean full
run → commit → the sweep (folder layout needs the user's agreement first).

## Code audit (2026-11-25; independent, not authoritative; everything in it is worth checking)
Full text: [code-audit-2026-11.md](code-audit-2026-11.md). It was reviewed statically at 3dbbb31, without running the
tests, so verify each finding before fixing it. The audit's top items, in its order:
1. **The leaver decoy:** a player who drops mid-mission leaves a frozen, unkillable mech that enemies keep shooting.
   Nothing outside `scripts/net/` handles `peer_left` (`crew_sync.gd:39-56`). Engine.
2. **Enemy alert state:** staggered or overheated enemies re-alert on every hit, then forget they were fighting
   (`enemy_base.gd:441`). Missions (enemy AI).
3. **Mortar on curved decks:** the mortar uses world up for its arc, knockback and range (`mortar_shell.gd:97-150`).
   Weapons.
4. **Remote shot copies:** `CombatWorld.remove_shot` is only called by tests, so one shot can land twice in co-op.
   Weapons.
5. **Duplicated enemy AI:** merge the three copies of the enemy AI state machine and add a flier base class.
   Missions.
6. **Dead paths:** delete the spawn-wave stub, the closed-source pacing path and about 28 unreferenced functions.
   Decide whether the old clear-and-extract and district modes stay (most headless tests still run the non-default
   mode). Your decision, then owners. **Decided 2026-11-25 ("Cut the legacy modes."); mission side DONE 2026-11-26**:
   MissionRules has one mode (a section always has a plan), `--no-objectives` and the objectives setting are gone
   (`--objectives` a no-op), every mission-side and narrow test runs the objectives mode or the TEST-ONLY
   QuietSectionFixture (docs/testing.md "Fixtures"). **Engine side DONE 2026-11-26** (uncommitted): TestDrive
   objectives / MODE_DISTRICT / district branches, Session.objectives, the hangar box, MissionBot's non-plan paths
   and all 8 shims (incl. `legacy_clear_rules.gd`) removed. Bot tests run objectives mode with a forced all-sweep
   plan. Item 5 (enemy AI merge plus flier base) also DONE 2026-11-26.
7. **Large files:** split the ten files over 1,200 lines, starting with `city_plan.gd` (3,042) and `enemy_base.gd`
   (2,815), and rename the production TestDrive scene. Owners per file.
8. **Test timeouts:** fix the 42 tests whose timeout never applies (`test_case.gd:14-24`). No GitHub CI (user, 2026-11-25).
   Engine.

Also high impact in the audit:
- a trooper firing from cover cancels its own telegraph;
- pruned attack slots are never cleared;
- drop-ship troopers can hunt the defend relay;
- pacing scales from the live roster, not the launch crew;
- props and air doors are outside the load checksum.

There are also about 20 medium and low bugs, including:
- destroyed hardpoints still absorbing shots;
- the release export shipping `tests/`;
- `build.ps1` killing every running babamech;
- the fall-damage cap using Strider leg HP for every chassis.

Plus the dead-code, maintainability and organization sections.

## 2026-11-25 (collected, not started)
| # | Feedback (user's words, lightly edited) | Likely owner |
|---|---|---|
| 1 | The legs can get in sync so you wind up hopping instead of walking. A normal walk should be one foot planted, one moving. | Mech (Gait) |
| 2 | Just one sign above doors, not 3. No hanging signs above holes (shafts / ceiling openings). Normal traffic takes the ramp, so that's where the sign goes. | Environment (CitySigns) |
| 3 | Mission menu: "v1" / "v2" aren't clear. Maybe objectives on decks you haven't visited yet read "Proceed to deck 2", and once you get there the other objectives open up. | Missions (objective panel) |
| 4 | The artificial limit on the Bulwark's jump height doesn't make sense. Instead, its thrusters build heat much faster, so you're more limited but can still push it. | Mech (chassis / thrusters) |
| 5 | The hangar needs a rework: higher detail, and a more logical story for how the mechs get out. | Engine (hangar UI / MechStage); look needs a 3x3 grid |
| 6 | The Bulwark has tiny arms that come down in the hangar, and it's unclear what's happening. Is it a brace for boarding? Make it read, or rethink it. Those arms also z-fight in the hangar scene. | Mech (Bulwark model / hangar pose) |
| 7 | The Bulwark is less combat-effective than intended: it lost shoulder and arm hardpoints, and its back slots don't make up for it. Reconsider; maybe a 3rd hardpoint under the body. | Mech (chassis rules) + Weapons (balance) |
| 8 | Mortar ammo is too limited ("3 shots is just too few"), which also hurts the Bulwark's back-slot trade-off. Double mortar ammo for everyone. | Weapons |
| 9 | Main menu: the backdrop is good, but a player mech on a rotating pedestal makes no sense in that scene. Place the mech in a way that fits it. | Engine (menu backdrop / MechStage) |
| 10 | Main menu: the stars seem to bleed through the wall. Checked with a menu shot (main session, nothing changed): faint dots do show over the dark wall panels. The stars are opaque, depth-tested and 1500 m out, so they shouldn't bleed. The dots are most likely the in-room dust motes (additive, `menu_backdrop.gd` `_dust`) drifting in front of the wall. Confirm by rendering with dust off, then decide: keep the dust out of the wall's screen area, dim it, or limit it to the window's light shaft. | Engine (menu backdrop) |
| 11 | Disable audio in headless mode (tests, headless bots): no audio driver and no sound playback when `--headless`. | Engine (Boot / test runner) |
