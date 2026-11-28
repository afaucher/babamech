# Pacing director, supply depots, threat log

Design for the three decisions the user took on `pacing-research.md` section 8 (2026-11-23). Research and sources are
there; this file is what gets built. It is the mission plan's ("objectives") behaviour, the default mode since
2026-11-23 (user: "make the objectives the default") and the ONLY mode since 2026-11-25 (user: "Cut the legacy modes.":
the old clear-and-extract mission, the single-district mode, `--no-objectives`, the objectives setting and the hangar's
Objectives box are gone; `--objectives` is accepted and ignored). Tests of a narrow system that must not see the director use the TEST-ONLY
QuietSectionFixture (docs/testing.md "Fixtures").

User decisions recorded here (not in decisions.md):
- "replace fixed waves": the director decides when groups are released; the plan no longer fixes wave triggers.
- Quiet cap: "45s is good, let's take one swing at adjusting".
- Co-op scaling: more enemies, not tougher ones, about x1.0 / 1.0 / 1.6 / 2.2 for 1 to 4 pilots, for now.
- Scouts may complete their alarm call; more dropships is intended.
- Resupply: "lets have them be military supply depos in world"; damage carries over between decks, no free refill.
- Threat must be visible over time: who fires, who takes damage, who sees whom.

## 1. Pacing director

### 1.1 What it replaces
`WaveDirector` released each planned wave on its own trigger (objective start / done, garrison low, linger). The
`PacingDirector` (same file family, `scripts/world/section/pacing_director.gd`, pure class, host-run) keeps the physical
side unchanged (a release is still an order `{wave, deck, source, open_at, max_units, reason}` delivered through a gate,
lift, ramp or shaft with its door telegraph) and replaces the *when*. WaveDirector and its test are gone (as built):

- `MissionPlan.pools[k]` keeps the deck's **garrison share** and a **reserve**: an ordered list of groups
  `{id, share, theme, source, for}` (light first; free groups `for: ""` first, then the objective groups in plan order,
  the extraction deck's hold group last). Groups have no trigger any more. `source` is only the planned one: the
  director picks the real source at release.
- The director releases the next group when its state machine says so (1.3), when the quiet cap fires (1.4), when an
  objective spikes (1.5) or when a scout completes a call (1.6). When a deck's reserve is empty, the cap and scout calls
  release a **patrol** (1 to 2 light units) from a per-deck patrol allowance (`PATROLS` 3 solo, +1 per extra pilot);
  when that is empty too nothing more comes: a deck is finite and a sweep can end.
- Caps, as built: the deck cap (`DECK_CAP_BY_CREW` [14, 16, 20, 24] by crew size since 1.5b; was 24 for everyone) /
  `SECTION_CAP` 40 count enemies **in play** (every wave unit, staged ones included:
  they exist; garrison units that are alerted or within 150 m of a standing mech; only on a deck with a standing pilot)
  plus groups in flight, so a sleeping
  garrison far from the crew no longer starves reinforcements (playtest: "cap room 1" twice); hard ceilings on
  everything alive: `DECK_ALIVE_MAX` 36, `SECTION_ALIVE_MAX` 60. **Half rule**: a group is never released when the room
  under any cap is under half the group, and never as a 1-unit release unless the group is 1 unit: it is held (the cap
  path then tries a 2-unit patrol). Follow-up loads of a partial release are the exception.
- Source choice: quick-response releases (build, cap, scout, patrol) only from sources that make contact in time
  (measured, see 1.4): ramps at any distance, gates 80 to 200 m, shafts within 200 m, lifts within 120 m, measured by
  **walk route** from the crew's centre (MissionFlow measures EnemySquad.find_arc_path to every source of the deck every
  2 s), straight line when no route is known; >= 60 m from every standing mech; with 3+ pilots consecutive quick
  releases come from two directions (the previous source is avoided when another quick one exists). Objective groups
  may use any source (flags 80 to 200 m from the snapped site; defend / hold measured from the site).

### 1.2 Intensity (host)
Per pilot `I` in 0..100, computed on the host from state it already has; no new messages from clients.

| Input (host side) | Change |
|---|---|
| Structure lost, from the pilot's replicated component HP between host ticks | +1 per 1 % of total structure |
| Component newly destroyed | +15 |
| Mech disabled | +40 |
| Heat at or past shutdown (replicated) | +5 per second |
| Host-owned enemy killed within 40 m of the pilot | +4 x (1 - dist / 40) |
| Decay | -4 per second, only while the pilot is **not engaged** |

**Engaged** (per pilot): a host-owned enemy fired at the pilot, or was awake within 60 m with the pilot as target,
during the last 4 s. Fall damage shows up as structure lost (no separate term). Repairs never lower `I`.

Crew intensity of a deck = max over standing pilots on that deck. A deck with no pilot has no director activity
except objective groups already ordered.

### 1.3 States (per deck)

| State | Ends when | Releases |
|---|---|---|
| `build` | crew `I` >= 70, or 90 s in the state | next reserve group whenever fewer than `ENGAGE_TARGET` enemies are engaging the crew and the previous group is beaten (<= 25 % alive) or 20 s old; first release after `rest` is the lightest group left |
| `peak` | 6 s | whatever is already ordered keeps coming; no new order |
| `fade` | crew `I` < 35 and nobody engaged for 5 s | none |
| `rest` | 25 s on the first deck down to 15 s on the last | none; garrison stays put |

`ENGAGE_TARGET` (enemies engaging the crew at a peak): 5 solo, scaled by crew (1.7). As built, build's "20 s old" gap
is `BUILD_GAP / CREW_SCALE` (20 s solo and 2 pilots, 12.5 s for 3, 9 s for 4: bigger crews kill faster).
A deck starts in `rest` for 10 s after the crew arrives (the arrival is safe: `SAFE_RADIUS`), then `build`.

### 1.4 Quiet cap
If no pilot on the deck has been engaged for **45 s** (`QUIET_CAP`, one named constant: the user will adjust it once),
whatever the state, the director releases the next group (reserve, else a patrol) from the nearest valid source and
goes to `build`. Counted only while a pilot stands on the deck and the mission is running; reset by any engagement.
The log records every quiet stretch over 30 s so the cap can be checked.

As built (2026-11-23):
- **The cap runs from order to contact.** Measured order -> first shot (810 groups, median / p90): doors 60-80 m
  6.0 / 17.1 s, 80-120 m 7.0 / 19.6, 120-200 m 9.7 / 24.0, 200-300 m 21.4 / 36.5, > 300 m 32.6 / never; ramps p90 18 s at
  any distance; crew in cover or parked on a site about double. So the director orders `ORDER_LEAD` before the cap: at
  20 s of quiet from a quick source within 200 m by route (`ORDER_LEAD` 25 s, a per-kind table), at 10 s when the best
  source is 200-300 m (`ORDER_LEAD_FAR` 35), at 5 s beyond (`ORDER_LEAD_FARTHEST` 40).
- **Quiet belongs to the pilot**, not the deck: a deck's quiet is the time since any standing pilot on it was last
  engaged, wherever that was. A pilot on a ramp belongs to the deck it is walking onto; arriving brings its quiet along,
  so the 10 s arrival rest never stacks on top (playtest: 63 s quiet between decks 1 and 2 with nothing ordered).
- One cap release per quiet stretch; another only after a whole `QUIET_CAP` without contact.
- When no group can make contact in time (reserve and patrols spent, no room, no source), the cap sends the
  `HUNT_UNITS` (3) mobile garrison units of the deck nearest the crew hunting (`EnemySquad.send_garrison_hunt`, the
  existing `begin_hunt_pursuit`: measured as the fastest reliable contact; garrison left to notice the crew mostly never
  does) and counts that as the release.

### 1.5 Objectives spike the pressure
Objective groups ignore state and intensity:

| Objective | On start | During | On finish |
|---|---|---|---|
| Flag | force `build`; its group ordered at once (door 80 to 200 m from the flag) | a second group at 50 % progress if the reserve has one; no `rest` while raising | `fade` |
| Defend | force `build`; first group at once | a group every 45 / 38 / 30 / 30 s for 1 / 2 / 3 / 4 pilots (the asset is the clock; 1.5a); `rest` capped at 15 s | full `rest` |
| Sweep | nothing | the cap keeps it moving; the sweep is done when garrison and reserve are gone and nothing is alive (patrol allowance does not hold a sweep open) | `rest` |
| Extraction hold (30 s, R2.10) | force `build`; two sources at once | a beat of up to 2 groups (two sources) every 12 / 10 / 9 / 8 s for 1 / 2 / 3 / 4 pilots, quick-response sources only; no `rest`, no `fade` | the exit door opens; the beats go on through the walk-out until the win |

### 1.5a Defend balance (2026-11-24)
Rule: a SOLO veteran should usually win a defend (bot win rate >= 80 %) without making 3-4 pilot crews easier. Evidence:
the lone veteran bot lost 6 of the 6 defends it reached (seeds 7, 2, 10, 16, 32 lost the relay 40-110 s after it went
active, mostly with the bot still above 85 % structure; seed 22 won with the relay at 16 %). As built:
- `DEFEND_EVERY_BY_CREW` [45, 38, 30, 30] s (was 30 for everyone).
- `DEFEND_UNITS_MAX` [4, 5, -, -]: a defend group is capped at 4 units solo, 5 for two (the plan's size for 3-4).
- Solo defend groups come lighter: the first `light`, the rest `mixed` (2+ pilots keep the plan's themes).
- `DEFEND_BUILD_MIN_CREW` 3: on a deck whose primary is a defend not yet finished, or while any defend is active, build
  releases no free groups for 1-2 pilots (seed 7: an 8-unit build group with two tanks arrived just before the defend
  started). The quiet cap still runs.
- Stragglers: a defend group with at most 2 units (`DEFEND_STRAGGLERS`) or a quarter of it alive, 40 s
  (`DEFEND_STRAGGLE`) after its door, no longer holds the defend open (seed 22: a drone circling and one trooper in cover
  kept a won defend running for 4 minutes); they keep fighting.
- Relay durability by crew: `MissionFlow.ASSET_HP_SCALE` [1.75, 1.35, 1.0, 1.0] x `ASSET_MAX_HP` 600 (hits are taken
  against the scaled HP; AssetTarget itself is unchanged, it mirrors the fraction).
- Only the defend's own groups may target the relay: `EnemyBase._can_target_asset` (unchanged, checked): a unit with
  `defend_target_id` targets only that relay; any other wave unit never; garrison never in a mission.
- Depots: at least `MissionPlan.DEPOT_CORES_MIN` 2 cores per depot (cores per pilot otherwise: solo 2, two 2, three 3,
  four 4), and depot n of a deck prefers a site 60-150 m (straight line) from its anchor n (`depot_anchors`: the defend
  sites, then the hold zone), the one nearest 100 m, after the source / depot-gap / objective-gap rules.
- Re-measured 2026-11-25 (solo veteran bot, bonuses off, first primary defend of seeds 2 / 7 / 10 / 16 / 22 / 32):
  Strider 6 of 6 won (relay end 0.14-0.92); Bulwark 4 won, seed 16 lost (3 downs to the defend's own trooper group,
  which also did most of the relay damage while the bot stood), seed 22 never reached its defend (downed by garrison
  snipers on the way). Relay damage taken while the only pilot was down: 0-15 % of the relay; respawn 75 m from the
  site, back in its zone in about 4 s. No director change (the 80 % rule holds on the decided defends);
  `test_bot_bulwark_mission` won 5 of 5 identical runs (488 s, relay min 0.61).
- "In play" (the caps) now counts only units on a deck with a standing pilot: wave units stranded on a deck the crew left
  (17 of them on seed 7's deck 0, an enemy transit bug) no longer hold back the crew's deck.

### 1.5b Bounded decks (2026-11-24)
A 2-bot crew's flag deck reached 28 alive (garrison + groups + dropship troops + wave units walking down from the decks
above) and the crew sat at intensity 100 for 200 s. As built:
- `DECK_CAP_BY_CREW` [14, 16, 20, 24] enemies in play per deck (was 24 for everyone): the director releases nothing
  more while a deck holds that many in play (dropship troops and arriving wave units count). The alive ceilings stay.
- Scout calls: none while the crew's deck already has `ENGAGE_TARGET` enemies engaging it, and at most `SCOUT_RELEASES`
  2 (+1 per extra pilot) scout releases per deck.
- The extraction hold's beats wait while the crew is at `ENGAGE_TARGET` (and while one of the deck's groups is still due); beyond the patrol allowance it may add only
  `HOLD_PATROLS` 3 (+1 per extra pilot) patrols (was unbounded).
- What the director can ever field on a deck is finite: `deck_ceiling(k, sizes)` = the reserve + 2 x the patrol
  allowance (+ 2 x hold_patrols on the extraction deck). Per crew size, mean deck: reserve 16.6 / 16.6 / 25.9 / 31.7
  units, patrols 6 / 8 / 10 / 12, hold extras 6 / 8 / 10 / 12; the garrison is deck_budget x share (about 5-11) and
  dropships are EnemySquad's own cap (`max_drops_per_deck` 1, one ship a call). Lent bonus groups come out of that reserve.

### 1.5c Extraction hold retune (R2.10, 2026-11-27)
The hold went 60 s -> 30 s ("waves will try to stop you"). As built (`PacingDirector`):
- Start: force `build`, the hold's own group plus the next free group (else a patrol, else a hold patrol) from another
  source (unchanged). Then a BEAT every `HOLD_EVERY_BY_CREW` [12, 10, 9, 8] s (was `HOLD_EVERY` 20 for everyone) of up
  to `HOLD_BEAT` 2 groups, the second from another source. The beat clock counts from the last hold group that actually
  went out; it waits while the crew's deck is at `ENGAGE_TARGET` and while any group of the deck is still due (held by
  the caps), so a held beat never comes out later as a burst. Every group respects the half rule and every cap.
- Quick-response sources only where the deck has them (`is_quick` from the zone: ramps, gates 80-200 m, shafts within
  200 m, lifts within 120 m; `_try_release(..., quick_src)`); the hold's groups used to take the nearest source (often a
  gate on the zone's own wall).
- Late orders: kept. Order-to-contact is 7-10 s, so a group ordered after ~20 s arrives during the walk-out; the beats go
  on while the exit is open (rules state `exit` >= 0) until the win, bounded by the same caps, ceiling and allowance. A
  crew that walks out promptly sees little of them; one that lingers keeps fighting.
- Measured (solo veteran bot, Strider, bonuses off, DEV travel + fast clear until the hold shows, then full strength and a
  repaired mech; damage / lowest core component / downs during the hold; "near" = a group's first unit within 80 m):

| Seed | Before: 60 s hold, 1 group / 20 s | After: 30 s hold, beats 12 s solo |
|---|---|---|
| 403112 | 59.7 s, 5 groups (all near before done), damage 207, lowest 0.66, 0 downs, engaging 1-9 | 29.9 s, 2 groups (1 near before done; the deck was at its cap, engaging 4-10), damage 47, lowest 0.92; won 35.2 s after the hold started |
| 1 | 59.7 s, 4 groups (3 near), damage 169, lowest 0.58, 0 downs, engaging 1-10 | 29.9 s, 4 orders (4 near), damage 98, lowest 0.76, 0 downs, engaging 4-6; won at +35.5 s |
| 3 | 85.3 s (left the zone), 4 groups (4 near), damage 678, lowest 0.06, 0 downs | 29.9 s, 3 groups (2 near), damage 136, lowest 0.72, 0 downs, engaging 4-8; won at +35.2 s |

  The first pass (10 s solo beats, beat clock from the last beat attempt) piled held groups into bursts: seed 1 took
  102 s, lowest core 0.00, one down, and the bot was downed walking into the door and redeployed 400 m away (now: the
  hold counts as active for the respawn rule through the walk-out, `DownedCrew.active_objective`). One tuning pass: no
  backlog, beat clock from the last release, solo 12 s.

### 1.6 Scout calls
A scout drone that completes its beacon (>= 2 s visible tell on the drone itself, no HUD marker) reports
`scout_call(deck, position)` to the director on the host (enemies are host-owned: a direct call, no message). The
director releases the next group now, `rest` or not, toward that position: by dropship when the deck has an air gate,
else from the nearest door. Limits: one call per scout per 45 s, one call-release per deck per 30 s, and calls obey the
caps. Killing the scout during the tell cancels the call. With the reserve and patrol allowance empty a call brings
nothing.

As built: the drone's `EnemyBase.comms_relayed` fires only when the beacon completes (`EnemyDrone._complete_beacon`), so
a scout killed during its tell never reaches the director; `PacingFacts` turns it into `scout_call(deck, x, s, id)` on the
host. A call over a limit (per scout, per deck, the engage ceiling, the scout budget, nothing left) is dropped at once. A
call that only lacks room under the caps or a source waits, but at most `SCOUT_CALL_TTL` 20 s (audit 2026-11: before, it
waited forever and fired minutes later out of context); it also lapses once nobody stands on its deck, and at most
`SCOUT_CALL_MAX` 8 wait (the oldest lapses first). A lapse is logged as `scout ... expired`.

### 1.6a Gate alarm (user, 2026-11-23; timing corrected the same day: "the siren is the door opening signal")
A gate's siren and lamps run while its leaves open: `open_at` is the moment the leaves START to move and the siren
starts; the opening takes `MissionWorld.OPENING` (3 s) and the door is passable at `open_at + 3` (`source_state(id)
.passable` / `passable_at`, `MissionWorld.passable_after(kind)`; a lift 1.5 s). In-world sound and light only: never a
HUD beep or icon. The director's gate telegraph (`TELEGRAPH.gate`) is order -> `open_at` = 2 s, so the staged units
exist on every machine before the reveal: order -> first unit moving about 5 s. Lifts keep 5 s, ramps and shafts 3 s.
A scheduled effect: every machine starts it from the `mission.wave` order on the shared clock (no extra message).

### 1.6b Staging in gate bays (user: "the door opens to reveal the enemies ... ready to roll out")
Every wave gate has a sealed staging bay behind its door (`MissionWorld.source_bay(id)`: usable floor 20 m x 16 m,
8..24 m behind the wall plane; door 12.8 x 9 m on lane gates, 48.8 x 14 m on avenue gates). A group ordered from a gate
is spawned **at the order**, inside the bay (`BayFormation`): a seeded loose formation facing the deck, greedy
front-first packing with the heaviest unit at the front centre, spacing from each kind's clearance radius + 1 m + 2 x
0.4 m jitter (no overlaps), a seeded 0..1.5 m start depth per unit (never a straight line), at most 2 heavies and the
gate's `load` (6) per opening; what does not fit is the follow-up load. Fliers hover 4 m low (under the lintel). The
mission-seed RNG is drawn in a fixed order (types, then per unit depth / jitter), so the layout never depends on frame
timing. The units are **staged** (`EnemyBase.staged`: no AI, no fire, not hittable, not awake, not engaging) until the
door is passable; they count toward the caps from staging (they exist). Then `EnemySquad.roll_out_wave` wakes them:
row by row (0.8 s apart, 0.25 s within a row) each walks / flies kinematically to its lane inside the door opening
(inside `door_w` minus its radius), 6 m past the door, then fans out toward the bay's street exit, fliers climbing to
cruise height only outside, and the AI takes over hunting. MissionFlow holds the door open 15 s from the roll-out
(measured roll-out about 3 s). A staged unit refuses every hit on the host (a client's copy has no `staged` flag).

**Nobody is shut in (playtest R2.4, 2026-11-27; `MissionBays`, host).** Every door a staged group rolled out of is watched
(4 Hz) until it is shut with nobody inside: (1) while ANY live unit is inside its bay or in the doorway
(`MissionWorld.bay_contains` when Environment lands it, else the bay frame: |x| <= half_width + 1 m, 0..26 m behind the
door plane; doorway 1.5 m either side, inside the jambs) the door is held open at least 4 s ahead, up to 30 s past its
normal close; (2) then every unit still inside is PUSHED out kinematically along the door line to the exit (the door
held, at most 10 s); (3) what is still inside after that, or inside a door that is closing / shut / sealed anyway, is
WITHDRAWN (`EnemySquad.withdraw`: no death, no wreck, no kill credit, a `[mission] bay` line and a CombatLog `source`
note): it leaves the squad, so a sweep and "group beaten" never wait on it (a unit within 3 m of a closing door's plane is
pushed out instead); wrecks inside a shut bay are cleared; (4) a unit that is out and walks back into an open bay is
walked out at once, unless it is after a crew mech standing in that bay; (5) a staged group whose door gets sealed, or is
still not passable 20 s after its open_at, is withdrawn (never left dormant), and nobody rolls out through a sealed door.
Holds are REPLICATED: `MissionFlow.hold_door` sends a "hold" order (mission.wave, `hold_only`, the door's own open_at, a
growing hold; NetMission dedups on wave + source + open_at + hold) and every machine calls `hold_source` (before this the
roll-out hold was the host's alone and a client's door shut about 3 s early). A wave order whose open_at falls within
WARN + CLOSE after a still-open door's close extends that schedule instead of re-scheduling it (`MissionFlow._no_snap`:
MissionWorld would snap the leaves shut into "warn" mid-hold), unless the host ordered it at or after that close
(`order_t` on every director order): a door already closing / shut is never popped back open, it runs a new cycle.

**Lift cars (R2.22, as built 2026-11-27).** Every lift has Environment's car (usable 14 x 16 x 9.6 m, doorway 10 x 9 m;
`source_bay(lift).ok` on every lift of seeds 1..200) and lift groups stage in it exactly like a gate bay: at the order,
dormant, in a seeded loose formation from 1.5 m behind the door plane (`depth_from`; the formation's own floor,
`LIFT_DOOR_MARGIN` 1 m, is below it), rolled out through the doorway once passable (open_at + 1.5 s), under the same
`MissionBays` hold / push / withdraw rules. The car holds 4 striders or 4 breachers (any seed), 7-9 exo-troopers; the plan's
lift `load` stays 4 (it is in the plan checksum): 39 of 40 rolled lift groups stage all 4, the rest is the follow-up load
(BayFormation leaves what does not fit pending: that is the staging-time clamp). Lift groups still roll no tank and no
flier; a tank would fit (with 2 striders, or a strider and 3 troopers), not enabled. The roll-out path is kinematic from
the car to 6 m past the door, then the street exit: the nav graph never enters the core, the deck cull and re-homing skip
units on a path, and after it the unit is on the walk graph outside (tested on all 16 lifts of seeds 1, 4, 7, 22, 403112:
out in 0.5-2.7 s from passable, none inside at the close, none back in or stuck at the door). A core too small for a car
(none in the seed range) answers `ok = false` and its groups step out of the opening doors from behind the leaves.

**Crew never shut in (`MissionBays` rule 5, host; R2.4 for pilots).** A door with an interior (a wave gate with a bay, a
lift with a car; never a sealed door; the entry / exit road doors follow the extraction rules) is never closed on a crew
mech: while any crew mech (standing, downed or redeploying: `MissionScene.crew_members`) is inside its bay / car or in its
doorway (`MissionBays.crew_inside(id)`: `bay_contains` inside or doorway, usable for any door id), the door is held open
`KEEP` s ahead through the replicated hold orders, with NO limit (a pilot is never pushed or withdrawn); a door that is
closing or shut with a crew mech inside is opened again (`MissionFlow.reopen_door`: a "hold" order with `reopen`, every
machine calls `open_source` 1 s ahead; a closing door finishes closing first). The director gets those doors as
`busy_sources`: no release picks one (another source, or the group waits) and a follow-up load from one waits, so a group
is never staged onto a pilot.

### 1.6c Where enemies come from (playtest R2.24, 2026-11-27: "no unit ever appears in the open with no visible source")
| Path | Visible source |
| --- | --- |
| Garrison (mission start) | pre-play, allowed |
| Gate group | staged in the bay, rolls out through the opening door |
| Lift group | staged inside the lift car like a gate bay, rolls out through the opening doors (1.6b "Lift cars"); a lift without a car (none built so far) steps out from just behind the leaves |
| Ramp group | starts on the ramp itself, 18 m up it from this deck's end (ranks 4.5 m further up, never past the far lip), in its lane, and walks down / up onto this deck (kinematic, then the AI) |
| Shaft group | starts inside the shaft opening under the upper floor and descends to the landing |
| Patrol / scout-call / cap group | one of the above (a director release through a source) |
| Garrison hunt | existing units |
| Dropship | only through a usable air door (created hidden in its recess, dormant until passable); a deck with no usable air door gets no dropship (the call is dropped; the director's scout release still uses a ground source); a door that never opens: the ship is removed inside its recess. No in-deck appear point any more |
| Dropship troops | created in the ship's own bay (wherever it hovers), jump-jet down |
The 25 m / 8 s crew-clearance hold still applies to lift / ramp / shaft groups (for a ramp also at its far-deck start).
The INBOUND marker sits on the real opening: a gate's or lift's door opening (its door node), a ramp / shaft mouth, or
an air door's `out` point for a dropship ("Dropship, north air door": `"air"` orders that bring a ship add the alert).

### 1.7 Co-op scaling
More enemies, same enemies. One factor `CREW_SCALE = [1.0, 1.0, 1.6, 2.2]` (index = pilots - 1) multiplies the reserve
size and `ENGAGE_TARGET`; garrison keeps its existing crew scaling. No HP, damage or accuracy change. A disabled pilot
does not attract new non-objective releases aimed at their position.

**Which crew size: the host's crew scale (user, 2026-11-25: "Run it from the host, enforce this! And ease off when a
player leaves."; as built).** Every crew-sized number of a mission reads one value, `MissionFlow.crew_scale()` (1..4), and
only the host derives it (`MissionFlow.host_crew_scale`): at the launch from the launch crew, hangar bots included, sent as
`mission.launch` `scale`; 1 solo. Readers: `PacingDirector.make(..., crew_scale())` (`crew_n`: `CREW_SCALE`,
`ENGAGE_TARGET`, `DECK_CAP_BY_CREW`, `DEFEND_EVERY_BY_CREW`, `DEFEND_UNITS_MAX`, the solo defend themes,
`DEFEND_BUILD_MIN_CREW`, the 3+ two-direction rule, `BUILD_GAP / CREW_SCALE`, patrol / scout / hold allowances), the
reserve's unit budget and group sizes (`MissionFlow.wave_sizes`, the spawn ctx), the relay's HP (`MissionFlow.asset_max_hp`,
`ASSET_HP_SCALE`), the depot cores (`MissionDepots.setup`). A client never sizes anything from its own crew list. The
garrison (`TestDrive.spawn_enemies`) stays as it was: built pre-play from the seed and the launch crew, checksummed.
Enforced by `test_net_contract` section 5 (AGENTS.md rule 8); the wire: docs/networking.md "Crew scale".

**A pilot leaves (ease off).** On the host's leaver hook (`MissionFlow.on_member_retired`, a player or a hangar bot
alike) the host recomputes the scale from the members still in the crew (at least 1); if it changed, every machine
switches at the same shared-clock moment `at` = now + `SCALE_LEAD` 1 s (`mission.scale {n, at}`; before the release the
start value just changes). Scale only goes down mid-mission (a higher value is accepted with a warning). At `at`:
- Director (`PacingDirector.rescale`): `crew_n` changes; the by-crew options (deck cap, defend cadence), `ENGAGE_TARGET`,
  the defend unit cap and solo themes, `DEFEND_BUILD_MIN_CREW`, the two-source rule and `BUILD_GAP / CREW_SCALE` follow at
  once. Unreleased reserve groups resize (their size is read at the new scale); released, staged and in-flight groups keep
  the scale they were released at (`release_crew`: spawn ctx, size, defend cap, theme). Nobody is despawned.
- Allowances: used counts stay counted. Patrols left per deck = max(0, new allowance - patrols already taken); scout
  releases and hold patrols compare their used counts with the new budgets (remaining = max(0, new - used)).
- A defend in progress keeps its clock: its next group is due `defend_every` (the new cadence) after its LAST group, with
  the new size cap and theme; the groups already released are untouched.
- The extraction hold's beat follows `HOLD_EVERY_BY_CREW[n - 1]`; its extra patrol allowance becomes `HOLD_PATROLS + n - 1` minus those already
  added, and the engage ceiling it waits under is the new `ENGAGE_TARGET`. Its two-source start already happened.
- Relay: max HP = `ASSET_MAX_HP x ASSET_HP_SCALE[n - 1]`, keeping the current HP fraction (`asset_hp` is the fraction,
  the host's; destroyed stays destroyed). The AssetTarget mirror gets the new max.
- Depots: cores already placed stay (no socket removed). Garrison and everything alive: untouched.
- The leaver's per-pilot entries go (host: director intensity / engagement, PacingFacts, depot claim bookkeeping);
  `TestDrive.crew_members()` already no longer lists it, so crew facts and intensity follow.
- Logged on every machine: `[mission] scale a -> b` and the combat log's `scale` record (from, to, reason, pilot, at).

What follows the LIVE state stays live: who stands, is downed or redeploying, which deck each pilot is on, each pilot's
intensity and engagement (crew facts every evaluation).

**Overrides:** `PacingDirector.make(plan, overrides, crew)` takes any key of its `options`. The by-crew options
(`BY_CREW`: `deck_cap`, `defend_every`) default to their tables; an override wins, as a number (every crew size) or a
4-entry array (index = pilots - 1). There are no scalar `DECK_CAP` / `DEFEND_EVERY` constants any more.

### 1.8 Networking
Shape: **host-arbitrated world system that spawns host-owned actors** (AGENTS.md rule 6).
- Only the host runs `PacingDirector.tick(t, facts)`. Facts come from host state: replicated pilot HP / heat / position
  (owner streams), host-owned enemy state (alive, target, last fired, awake), `MissionRules` state.
- Randomness: the mission-seed generator, drawn in a fixed order per release (rule 4). Because release *times* depend
  on play, the director is not replayed on clients: clients never run it.
- Replication: the existing `mission.wave` order (unchanged shape plus `reason: build | cap | objective | scout |
  patrol`) and `mission.state` "dir", which gains `pace: {"<deck>": [state, s in state, quiet s, last reason]}` and
  `intensity: {"<pilot id>": I}` (small ints, pilot ids as strings, negative for hangar bots, at the existing ~4 Hz).
  Clients `apply_state` for the HUD-free uses: logs (CombatLog prints `src=host` intensity), and door telegraphs at
  `open_at` on the shared clock as today. No new message for pacing itself; the dictionaries ride the existing ones. The
  crew scale (1.7) has its own: `mission.scale {n, at}` (2026-11-25), plus `scale` in the launch and the state.
- Late join / host loss: state is in `mission.state`; as built, host migration is not implemented (as with the
  old waves: a client's mirror only has counters, not the reserve cursor).
- Spawned units are ordinary `EnemySync` actors; nothing new on the wire for them.

### 1.9 First tuning
The targets are `pacing-research.md` 8.2. The bot measures (time engaged 60 to 75 % solo, 3 to 4 peaks per deck,
longest quiet <= 45 s, lowest structure under 25 % once a mission); the user's runs calibrate. All numbers above are
named constants in `PacingDirector`.

**Evidence the first build was tuned against (2026-11-23):**
- User's 2-crew playtest with a bot, seed 747612 (test_logs/playtest/): lowest structure 64 % (host) / 59 % (bot),
  damage taken : dealt about 1 : 8, a 63 s quiet between decks 1 and 2 with nothing ordered, door-to-first-hit
  1.5-19 s (median ~7.5), two waves cut to 1 unit by the 24-per-deck cap ("cap room 1").
- The user's 4-crew rounds with 3 hangar bots (seeds 297535, 295676): lowest 91 %, engaged 71 %, longest quiet 59 s,
  kill interval 3.3 s, 0 peaks ("still too easy"); then one death, engaged 94 %, quiet 51 s, kill interval 4.0 s, 1 peak.
- Order -> contact latency (810 measured groups): see 1.4.
- Mission bot, solo, seeds 403112 / 747612 / 1 / 3, before (WaveDirector) and after: the build report's table.

**Tuning pass (one, 2026-11-23):** `ENGAGE_TARGET` 5 -> 6; `RESERVE_SCALE` 1.5 (the reserve is sized from the solo
deck budget x CREW_SCALE x 1.5: solo groups 3-8 units, mean 5.7, where the old waves averaged 3.7; 3 pilots mean 8.9,
4 pilots 10.9); `FADE_MAX` 15 s (a crew kept engaged by the garrison at low intensity never got its 5 quiet seconds
and the deck stayed in fade with no build releases); an unstarted bonus flag's group may be lent to build / the cap
once the free groups are gone (most pools held one free group and the rest tied to bonuses nobody finds, so a deck ran
dry at once); `ORDER_LEAD` from the measured latencies (1.4); `BUILD_GAP / CREW_SCALE` for bigger crews.

**Result after the pass (mission bot, solo, 2x, seeds 403112 / 747612 / 1 / 3):** longest quiet per deck 0-36 s (before:
up to 204 s and 697 s, 900 s on a stalled bot run), none over 45 s; engaged 57-100 % of deck time (target 60-75 %:
mostly above, the garrison keeps the bot busy); lowest structure per mission 42-47 % (before 49-77 %); 0-1 peaks per
deck (target 3-4: still off); damage in : out per deck 1:2 to 1:24 (still far too easy where the bot fights garrison
at range); 3 of 4 missions won, seed 747612 lost its deck-3 defend (the relay destroyed). Still off target: peaks per
deck, the close call (< 25 %), damage ratio.

### 1.10 Perception (2026-11-24; playtest "I am a block away and they still can't see me")
Quiet comes from the director's `rest` and from cover, not from blind enemies. An 8 m mech is loud: a unit with a clear
line to it inside a block notices it within about a second in front, a few seconds anywhere else, then alerts and fires
through the usual telegraph (>= 0.3 s). Code: `EnemyBase` header "Perception", numbers in `EnemyCatalog` (`notice_range`,
`sight_range`, `fov_deg`); test `tests/test_enemy_perception.gd`.

- **Notice (un-alerted)**: a clear line (torso; else head or legs when low cover near either end blocks the torso: a
  trooper sees an 8 m mech over a 2.4 m wall and aims at what it sees) inside `notice_range` and inside the forward cone
  (150 deg around the sensor: turret gun / tank turret / strider torso / trooper helmet, not the hull), or in any
  direction inside 60 m (90 m while the mech walks, the whole notice range for 2.5 s after it fires).
- **Notice time**: instant in the cone inside 55 m (as before), else 0.5 s to 1.5 s scaled by distance; the sensor turns
  to look at what it is noticing (a visible tell, nothing on the HUD); then ALERT_DELAY 0.35 s and the weapon's telegraph.
- **Idle glance**: a unit with nothing to do swivels its sensor through front / +120 / -120 deg (1.6 s each; +-57 deg
  while walking a patrol), so a cone sweeps the whole block in about 5 s.
- **Alerted**: tracks with a clear line inside `sight_range` in any direction (unchanged rule). Relay to squadmates
  within 60 m (was 52) after 0.45 s (kept: faster than the proposed 1 s, and killing the spotter still cuts it).
- **Cost**: un-alerted units look at 5 Hz (was 12.5), staggered, distance-gated before any ray; the extra head / legs
  rays only when the torso ray was stopped near either end. Garrisons on a deck nobody stands on still do not tick.

| type | notice range (was, un-alerted) | sight range alerted (was) | cone (was) | weapon range |
|---|---|---|---|---|
| trooper_rifle | 120 m (76) | 150 (150) | 150 (135, body) | 150 |
| trooper_at | 130 (82) | 185 (185) | 150 (140, body) | 190 |
| strider | 140 (62) | 140 (125) | 150 (100, body) | 115 (moves in) |
| strider_breacher | 140 (64) | 140 (135) | 150 (105, body) | 68 (moves in) |
| tank | 160 (70) | 160 (145) | 150 (105, hull) | 180 |
| turret | 160 (68) | 160 (135) | 150 (115, base) | 160 |
| turret_sniper | 215 (105) | 220 (215) | 150 (110, base) | 215 |
| turret_missile | 180 (92) | 195 (195) | 150 (120, base) | 190 |
| gunship | 180 (82) | 180 (165) | 150 (135) | 88 (flies in; no idle glance) |
| drone | unchanged (115 / 175, 160 deg, own code) | | | unarmed |

Measured (flat open arena, clear line, idle unit, worst of seeds 297535 / 1; notice / first shot in s; before: "never"
outside the cone or beyond the old notice range, e.g. every type at 80 m beside or behind, and at 80-100 m in front for
all but the AT trooper, sniper, salvo turret and gunship):

| type | front 80 m | beside 80 m | behind 80 m | front 100 m | walking, beside 80 m | firing elsewhere, behind 80 m |
|---|---|---|---|---|---|---|
| trooper_rifle | 1.2 / 2.3 | 3.2 / 4.3 | 1.6 / 2.8 | 1.4 / 2.5 | 1.4 / 2.5 | 1.2 / 2.3 |
| strider | 1.1 / 2.0 | 3.3 / 4.2 | 1.6 / 2.5 | 1.2 / 2.2 | 1.4 / 2.3 | 1.1 / 2.0 |
| tank | 1.0 / 2.5 | 3.7 / 5.1 | 2.4 / 3.8 | 1.1 / 2.6 | 1.1 / 2.5 | 1.0 / 3.1 |
| turret | 1.0 / 2.1 | 3.2 / 4.3 | 1.9 / 3.0 | 1.1 / 2.2 | 1.1 / 2.1 | 1.0 / 2.1 |
| turret_sniper | 0.9 / 2.2 | 3.4 / 4.7 | 1.9 / 3.2 | 1.0 / 2.4 | 1.0 / 2.4 | 0.9 / 2.4 |

Behind a building, or beyond the notice range, nothing notices (still, walking or firing away). Attack slots and the
fireteam's 2 shooters still decide who fires once alerted (director side).

## 2. Supply depots

### 2.1 Rules
- Damage, destroyed components, spent ammo persist for the whole mission: no refill between decks.
- Each deck has **1 or 2 depots** (seeded; 2 on decks with a defend or the extraction). A depot holds **power cores**:
  one per pilot in the crew at mission start, bots included (so every pilot can take one from each depot, or one pilot
  can take several if the crew agrees). Finite: an empty depot stays empty. *Built:* a second depot only goes on a site
  >= 60 m from every source, so a deck without two such sites has one (defend / extraction decks too); a deck with no
  non-safe encounter site would have none (none in seeds 1-40 x 2 / 3 / 5 decks: 129 decks with 1, 271 with 2).
- Taking a core: stand within 6 m of the depot's footprint for 2 s without a break (the mech must not be disabled, the
  depot must not be destroyed); one grant per pilot per 5 s.
- **Proposed effect of one core** (to confirm with the user):
  - structure: every surviving component +50 % of its missing structure;
  - destroyed components: rebuilt at 30 %, weapons mounted on them work again;
  - ammo: all weapons refilled;
  - heat: vented to zero, shutdown cleared.
  A core does not revive a disabled mech (that stays the revive rule, deferred). *Built* with these numbers as named
  constants in `MissionDepots` (`CORE_REPAIR` 0.5, `CORE_REBUILD` 0.3, `CORE_REFILL`, `CORE_VENT`); the refill also
  restores the repair drone's charges.
  This also answers the disarmed-mech gap found with the bot: a mech with no working weapon has a place to go.
- Depots are guarded: placed at an encounter site, never inside `SAFE_RADIUS` of the arrival, at least 60 m from wave
  doors. They are military objects and can be shot: a destroyed depot loses its remaining cores (enemies do not target
  them; crew fire and stray shots can).

### 2.2 Data and networking
Shape: **host-arbitrated world object**.
- `MissionPlan.depots`: `{id, deck, site {x, s}, cores, snap}` (`cores` = per pilot), seeded from a generator of their
  own drawn last (objectives / sources / pools unchanged: `checksum(false)`), part of the plan checksum (so every
  machine has the same depots). Sites snap to open ground like flag sites (`MissionProps.snap_site`, reach 25 m, clear
  of the snapped masts / relays) when MissionFlow builds `MissionDepots` (scripts/game/mission_depots.gd).
- State on the host: `cores_left` and `alive` per depot, in `mission.state` (`depots: {id: [cores_left, alive 0|1]}`).
- Claim: the pilot's machine sends `depot.claim {depot}` to the host when its own mech has stood in range for 2 s. The
  host checks range (from the replicated position, + 4 m slack), `cores_left > 0`, one grant per pilot per 5 s,
  decrements, and answers `depot.grant {depot, peer, seq, cores_left}` to everyone (or `depot.deny {depot, reason, n}`
  to the asker). The claim carries the pilot's claim counter `n` (`depot.claim {depot, n}`): a re-sent claim gets the
  same answer again, never a second core. Pilot ids are keys (bots' are negative); a host-owned bot claims through
  `MissionDepots.claim_for(pilot_id, depot)` on the host and its effect is applied by the host on `bot_core_granted`. **The effect is
  applied by the owner of the mech** on receiving its grant (rule 2: the owner changes its own mech). One core can
  never be spent twice: only the host decrements, grants carry a sequence number, a duplicate grant is ignored.
- Host loss: `cores_left` is in `mission.state`; an in-flight claim is re-sent by the pilot to the new host after
  1 s without an answer.
- All message code lives in `scripts/net/` (rule 5); the depot object itself is gameplay code with `net_fields()`.

### 2.3 Look
Picked B2 (supply-depot.md). The art model `res://scenes/props/supply_depot_kiosk.tscn` (DepotKiosk) is loaded from
`SupplyDepot.VIEW_SCENE`; the placeholder `scripts/game/supply_depot_view.gd` (`VIEW_SCRIPT`) is the fallback when the
scene is missing. Both sit behind the view interface `set_cores(stocked, capacity)`, `core_taken(index)`,
`set_destroyed(dead)`, `socket_point(index)` (+ `set_render_layers(mask)` before entering the tree). The whole depot is
turned so its socket wall (local +Z) faces the side with the longest run of clear ground (`MissionDepots.open_face`,
probes with the snap rule: plan data only, the same on every machine); the 6 m claim range and placement's walk-round
ring are measured from the turned footprint `SupplyDepot.footprint_half` (6.6 x 4.7 m since R2.23, was 6 x 4: the box
round the collision; depots may sit a little differently, no plan checksum involved). The collision and the DepotTarget
(250 HP, team "": enemies never acquire it, every shot can hit it) belong to `SupplyDepot`.
**Collision (R2.23, 2026-11-27)**: the old 6 x 4.35 x 4 box trapped mechs: a capsule walking into a vertical box
corner whose top lies inside its straight side (Strider 2.2-5.8 m above the feet, Bulwark 3.6-4.4) sinks into the
corner and cannot move any way (reproduced on seeds 7 / 2 / 22 / 1: 17 traps in 3700 approaches; the user's
screenshot). Now one convex shape (`SupplyDepot.collision_shape`): the kiosk's visible footprint incl. the roof
overhang (6.6 x 4.5 m, z -2.15 .. +2.35), vertical walls to `WALL_H` 6.2 m along the ring's local up at each corner,
a flat top with no rim (a mech that lands on it walks off any side; it stands 1.85 m above the visible roof: the trade,
a steep cap perched mechs higher). 0 traps in 9100 approaches / drops / thrust landings; tests/test_supply_depot.gd G.
The mast has no collision; the DepotTarget's hit spheres are not physics shapes and shots skip the body. The pilot taking a core sees "Taking power core: 60%" as a line of the objective panel.

## 3. Threat log and timeline

Extends the combat log (`docs/testing.md`, "Combat log"); same `[Flow]` line format.

| Record | Fields | Who logs |
|---|---|---|
| `shot` | shooter id/kind, target id/kind, weapon, `hit=0|1`, distance | each machine for its own pilot's shots; the host for enemy shots (coalesced per shooter + weapon + target per 1 s: `n`, `hits`) |
| `threat` (1 Hz per pilot) | intensity, engaged 0/1, enemies engaging, enemies within 200 m, `sees` (awake enemies within 200 m the pilot has line of sight to), `seen_by` (those that have line of sight to the pilot / have it as target), nearest distance | the pilot's machine; `seen_by` and `engaging` are exact on the host and from replicated enemy state on clients (marked `est=1`) |
| `los` (1 Hz, optional detail) | per enemy id: `p>e`, `e>p` | as above; capped at the 12 nearest |
| `pace` | deck, old state, new state, crew intensity, reason | host (clients log the replicated change) |
| `release` | wave id, deck, source, size, kinds, reason | host |
| `scout` | started / cancelled / completed, drone id | host |
| `depot` | claim / grant / deny / empty, depot id, cores left | every machine for its own pilot |

Cost rules: line-of-sight reuses results the enemy AI already has for `e>p`; `p>e` raycasts are batched, at most 12
per pilot per second, spread over frames; no per-frame strings. `test_perf` stays within budget with the log on.

**Timeline tool** (`tools/pacing_report/`): reads a run log, writes one self-contained HTML file with, per pilot over
mission time: structure % (total and weakest core), intensity, enemies engaging / in sight / seeing the pilot, damage
in and out, director state as a coloured band, releases and scout calls as marks, and quiet stretches drawn against
the 45 s cap; plus the per-deck summary table against the 8.2 targets (time engaged, peaks, longest quiet, lowest
structure, kill intervals).

## 4. Downed, revive, respawn

User decision, 2026-11-24 (verbatim): "Dying - Lets have it like a call for help mechanism once you are down. A mech
with a repair robot should be able to bring you back. But if you hold the key, maybe space, for N seconds, it respawns
you. This removes the automatic part. Adds a little time penalty and gives you a choice to exit the mission without a
death if your team came prepared."

Replaces the 1.5 s automatic respawn (user decision 2026-11-22). Every number lives in `DownedRules`
(`scripts/game/downed_rules.gd`); the state runs on the OWNER's machine in `PlayerTarget`; `DownedCrew`
(`scripts/game/downed_crew.gd`) is the scene's side (who can revive, the call for help, HUD, beacon, respawn point).

### 4.1 Rules

- **Downed**: a core component (torso, head, a leg) at 0 HP. The mech stays where it fell: no movement, no weapons, no
  further damage, not hittable (every enemy target search already skips `is_hittable() == false`, so enemies drop it at
  once; checked in `test_downed`). The camera stays on it. No automatic respawn.
- **Call for help** (automatic): a red strobe beacon on the wreck, in the world, seen by everyone (diegetic; enemies
  ignore it; looks from a per-pilot generator). Player-side HUD for the crew: a marker on the wreck ("DOWN  name",
  distance, the revive bar) and a red line in the top-right objective panel, "<name> is down: revive with a repair
  drone" when a standing crewmate can revive (a repair drone with a charge left or one on duty, back mount intact),
  else "<name> is down". For the downed pilot, a centre prompt: "DOWN", "Help is <m> m away" / "No repair drone in the
  crew", the revive bar, "Hold SPACE to respawn" with the hold bar, then "REDEPLOYING <s>".
- **Revive**: a crewmate's repair drone on duty (circling, inside its life) beams a downed mech within its 30 m radius (catalog `radius`; 15 m before 2026-11-26)
  (horizontal, from the launcher, the drone's own range rule): `REVIVE_TIME` 4 s of beam stands it up IN PLACE with
  `REVIVE_STRUCTURE` (destroyed components rebuilt at 30 %, every other at least 30 %), heat 0, shutdown cleared,
  ammo unchanged, `REVIVE_INVULN` 2 s of no damage. Not a death. Beam gone: the bar drains over `REVIVE_DECAY` 2 s
  (a full bar; decay, not reset). Two drones don't stack. An ORDINARY drone of the downed mech dies with it.
  **Cost**: the drone's own: the charge that launched it (2 per mission, depots restock). The revive takes no extra
  charge and no drone life (the drone is a scheduled effect with no per-target budget; shortening it would need a new
  message). The real cost is the reviver staying within 30 m for 4 s.
- **Self-revive** (R2.9, user decision 2026-11-26: REVERSES "a downed mech's own drone never revives it"): going down,
  the mech's own rack (owner's machine, bots too) launches ONE repair drone when a repair-drone slot has a charge and
  an intact back mount (`WeaponRack._self_revive`, record `"self": true` in the one `combat.drone` event). That drone
  survives its launcher being down and beams it through the normal `revive_tick` for the normal `REVIVE_TIME`: same
  result as a crewmate's revive, `player_revived(by)` with the mech's OWN id. `CombatWorld.self_reviving(target_id)`
  (every machine) is true while it is out and has not revived yet. Redeploy stays allowed: holding SPACE still
  redeploys (the drone dies when its launcher starts redeploying). The downed pilot's help line reads "Your repair drone
  is reviving you" (revive bar as usual, "Hold SPACE to respawn" stays); `DownedCrew.downed_crew()` marks the wreck
  `self_revive: true` so crewmates and bots need not detour. A self-revive is a revive (no death), logged
  `revive by=self`, and never counts as a revive given. Bots wait while it is true (`DownedRules.bot_wait_for`;
  MissionBot's `BotAid.wait_s` once the AI flies the bot), then the normal waits.
- **Respawn**: the downed pilot holds the `respawn` action (SPACE; added at runtime by `DownedRules.ensure_input`, the
  project defines no input actions; it only acts while downed, when the thrusters are off anyway) for `RESPAWN_HOLD`
  3 s (releasing resets), then is REDEPLOYING for `RESPAWN_PENALTY` 5 s (still disabled, out of the fight, on no deck
  for the director, not revivable, no beacon), then stands **fully restored** (R2.12, user-confirmed 2026-11-26; was
  50 % structure, ammo unchanged): `RESPAWN_STRUCTURE` 1.0, every component at full (destroyed ones rebuilt, their
  weapons usable again; the slot stays deselected until the pilot picks it, like a refilled EMPTY slot), heat 0,
  shutdown cleared (`PlayerTarget._finish_redeploy`), and with `RESPAWN_REARM` every limited-ammo weapon and the
  repair-drone charges refilled (`WeaponRack.refill_ammo`, called by the mech's owner in `DownedCrew._respawned`, the
  `on_respawn` handler, which has the rack: the local drive's, a bot's `cb.rack`). A death: the price is the 3 s hold,
  the 5 s penalty and the walk back. Revive in place (30 %, no death, no travel) is the other choice.
- **Respawn point**: the arrival point (`SectionPlan.arrival(k)`: a ramp foot / lift platform, the enemy spawner's 70 m
  safe bubble) of the deck the crew's LEAD pilot is on (the deepest deck any standing crewmate is on; nobody standing:
  the deck the pilot went down on), offset by crew seat and dropped onto clear floor with headroom. On the entry deck
  (and in a district) it is the pilot's own crew spawn slot: the old respawn point.
  **Exception (coordinator, 2026-11-24, from bot evidence: a solo pilot lost a defend because the relay died during
  the walk back)**: when the deck the pilot went down on has an ACTIVE defend or hold objective, the respawn lands
  60-90 m from that objective's site (`RESPAWN_NEAR_TRIES`: 75 m first, then 60, then 90; 8 bearings each, starting
  on the side of the deck's arrival point), out of its zone (+10 m), on clear ground (`MissionProps.snap_site`, the
  depots' / flags' snap rule), facing the site, preferring a spot with no live enemy within 40 m. Decided by the
  mech's owner from plan data + the replicated objective state; its teleport is what every machine sees. Same rule
  with crewmates standing. On seed 7 deck 1 the arrival point is 504 m straight / 783 m by road from the defend site
  (65 s walking, 36 s running): the old walk back.
- **Whole crew down**: each pilot can still hold to respawn; the mission goes on (`wipe` stays off by default). With
  `wipe` on, the mission is lost only when every pilot is down at the same time and nobody is redeploying (after
  `wipe_grace`): a hard mode, since a solo pilot then loses 1 s after going down.
- **Bots** (host-owned, cannot press a key): a downed bot waits `BOT_REVIVE_WAIT` 8 s when a standing crewmate can
  revive it, else `BOT_ALONE_WAIT` 2 s, and keeps waiting while a revive is in progress and while its own drone
  self-revives it; then the respawn path (same penalty, same full result). The local mech flown by `--bot` (MissionBot) does the same.

### 4.2 Other systems

- **Intensity**: +40 once per down (`PilotIntensity.disabled`); a downed or redeploying pilot is never `engaged`
  (`PacingFacts`, the combat log). The director's "no new non-objective releases at a downed pilot" keeps working:
  crew facts carry `downed` (true while redeploying too) and `redeploying`.
- **Depots**: a downed (or redeploying) mech gets no power core (`MissionDepots.apply_core_to`, the claim stand rule).
- **Objectives**: a downed mech holds no flag / zone and does not count for extraction (MissionRules skips downed).
- **Intensity after a redeploy**: the full structure is a rise, which only moves `PilotIntensity`'s baseline (no
  intensity from it); the +40 of the down decays as before. Unchanged by R2.12.
- **Depots and a redeployed mech**: the core effect and the bot need rule (`needs_core`: total structure < 70 %, a
  component destroyed, or a weapon slot unusable: empty or on a destroyed hardpoint) are unchanged; a redeployed bot simply no longer needs a core.
- **Combat log**: `down` (cause, source, weapon), then `help reviver=0|1 dist=`; `revive by=<id>|self down_s= tot=`;
  `respawn hold=1|0 down_s= tot=` (tot=100 after a redeploy since R2.12). End record: `deaths` (downs that were not revived), `respawns`, `downs`, `revives` (received),
  `revives_given` (this pilot's drone was beaming the crewmate when it stood up), `down_s` (total time down).

### 4.3 Networking

- The revive is decided by the DOWNED mech's owner: `RepairDrone` (a scheduled effect running on every machine) calls
  `PlayerTarget.revive_tick(dt, shooter)` only on the machine that owns the target (`CombatWorld.owns`), exactly like
  its heal; that machine applies `revive()`. No message is sent, nobody writes another pilot's mech. Host-owned bots:
  the same path on the host.
- The mech snapshot carries the state (`NetMechCodec`, entry 49 -> 50 bytes, host packet 158 of the 160 budget):
  `disabled` (flag 64, as before), `redeploying` (flag 128), and a new `aid` byte: the owner's repair-drone charges
  (bits 0-1) and the revive bar (bits 2-7, 0..63 of 4 s). `MechPuppet` mirrors them onto the puppet's PlayerTarget, so
  every machine's HUD, DownedCrew and the host's facts read the same state. Respawn placement is the owner's teleport,
  streamed like any move.
- Tests: `tests/test_downed.gd` (single process), `tests/test_net_downed.gd` (3 processes, both links),
  `tests/test_layout.gd` (the prompt and the crew line).

### 4.4 For the bot (Engine session)

`MissionScene.downed` (DownedCrew) answers: `downed_crew()` -> `[{peer, name, pos, revive, bot, self_revive}]`
(revivable downed crewmates, positions on this machine; `self_revive`: its own drone is reviving it), `self_reviving(pilot_id)`, `can_revive(pilot_id)`, `reviver_for(pilot_id)`, `nearest_reviver(pilot_id)` ->
`{peer, dist}`. A bot with a repair drone revives by standing within the drone's 30 m (horizontal) of the wreck with its drone on
duty for 4 s: launch the drone (`WeaponRack.activate(back slot)`) when a downed crewmate is within reach and no drone
is out, then hold position near the wreck until `downed_crew()` no longer lists it.
