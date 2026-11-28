# Mission objectives

> **Status: design signed off by the user on 2026-11-22 ("Approve as proposed"), including waves (§5) and §5.8. The
> open questions of §8 are settled as recommended.** Build step 1 (§7) is in progress; its interfaces are in §9. Nothing
> else is built. Parents: [game-design.md](game-design.md) §3.4, §7, §8; [mission-section.md](mission-section.md) §14
> (the demo objective this replaces), §15 (finding the last enemies), §16 (encounter pacing).

## 1. The shape of a mission

A mission is a **list of objectives placed on the decks of one section**, then extraction.

- Every deck has **one primary objective and one or two bonus objectives**. A 3-deck section is 3 primaries and 3 to 6
  bonuses: 5 to 8 minutes a deck, inside the 15 to 30 minute target.
- **Primary**: must be done to finish the mission. **Bonus**: optional, smaller, off the main route; it pays off inside the
  mission (see §4), not only on a score screen.
- The mission is **won** when every primary is done, the crew held the extraction zone for 30 s while an ally opened the
  exit road door, and every standing pilot walked out through it (R2.10, 2026-11-27; §9 "The exit").
- "Clear every deck" stops being the goal. It stays as an objective type (**Sweep**, §2.0) and as the default when a
  deck rolls nothing else, so today's demo keeps working.

Every objective is **host-owned world state** (AGENTS.md rule 6: a host-arbitrated world object). The host decides
progress and completion and broadcasts the whole objective list on change (it stays small: about 40 bytes an objective);
every machine shows the same progress. A player's interaction (stand in a zone, order a vehicle) is a fact the host
reads or a request the host grants; no machine completes an objective on its own.

One record per objective: `{id, type, deck, role: primary | bonus, state: hidden | known | active | done | failed,
progress, total, site: {x, s}, needs: [ids]}`. `MissionRules` grew from "clear + extract" into the evaluator of this
list, and since 2026-11-25 it is only that (user: "Cut the legacy modes."; a section always has a mission plan, no flag
or setting selects anything else; the old clear-and-extract evaluator and the game's single-district mode were deleted
on 2026-11-26); objectives are placed by the section planner from the mission seed, so every machine derives the same list and
only the state is sent.

## 2. Objective types

Sizes: **S** = rules and HUD only, existing content; **M** = one new enemy, prop or behaviour; **L** = a new setting,
building or unit family. "Needs" is what does not exist yet.

### 2.0 Sweep (exists)
Destroy every enemy on the deck: the garrison and every wave of its pool (§5.7). The current demo objective, without waves. Kept as the fallback and for short missions; §15's hunt-out,
reveal and safety valve belong to it. **S** (built).

### 2.1 Wipe out the heavy artillery
- **Goal**: destroy X artillery pieces on the deck (X = 2 to 4, shown as "Artillery 1 / 3").
- **Why it plays well**: the guns **shell the crew from across the deck** while they live. Each shot is a marked impact
  circle on the ground with a long warning (2 s or more), so the deck gets calmer with every gun destroyed. The crew
  chooses: push through the barrage to the nearest gun, or go round.
- **Win**: all X destroyed. **Cannot fail.**
- **World**: emplacements in open ground: parks, open-air cells, industrial yards, plazas, with 40 m of ceiling for the
  arc. One gun under a shaft can fire onto the deck above or below (a threat announced before the crew gets there).
- **Enemies**: each gun has a small guard and a **spotter**; kill the spotter and that gun fires blind (slower, wider),
  which is the "cut their communications" counter from game design §7.
- **HUD**: a marker per gun once it has fired or been seen; impact circles in the world; count in the objective line.
- **Needs**: an artillery enemy (static, heavy, indirect fire) and the emplacement prop. **M**. antigravity (enemy),
  Environment (emplacement placement), Engine (HUD, objective state), Weapons (the shell as a fire record with a
  telegraph).

### 2.2 Clear out the political center
- **Goal**: take the occupiers' seat of government on this deck: destroy the **command post** grafted onto the capital
  building and its **garrison** (a fixed list of defenders, shown as a count).
- **Win**: command post destroyed and garrison down. **Cannot fail**, but see collateral below.
- **World**: a **capital building**: the one landmark of the deck, on a plaza, taller and wider than its neighbours,
  with a forecourt and two or three approaches. Alien machinery (the command post, banners, pylons) is bolted on.
- **Enemies**: the heaviest defended site of the mission: turrets on the building's terraces, troop squads in the
  forecourt, a reserve inside that comes out when the command post is hit. When the post falls, the deck's remaining
  enemies lose coordination for a while (no shared sightings): the reward for doing it first.
- **Collateral**: society still runs here. Damage to the capital itself is tracked and shown at the end; it does not fail
  the mission (open question 4).
- **HUD**: the building is marked from the moment the crew arrives on the deck; the post has a health bar.
- **Needs**: the capital building and plaza (a new landmark type for the city generator), the command post target.
  **L**. Environment (building, art grid for its look), antigravity (garrison, reserve), Engine (HUD, state).

### 2.3 Attack military output
- **Goal**: shut down the occupiers' production on this deck: destroy N **output targets** (fabricator halls, fuel and
  ammunition stores, a vehicle depot), shown as "Output 2 / 4".
- **Why it plays well**: while a fabricator stands, it **keeps sending new units** (§5): leave it and the deck never
  thins out. Fuel and ammunition stores explode and damage what is near them, friend or foe.
- **Win**: all N destroyed. **Cannot fail.**
- **World**: a **military-industrial district style**: a new setting for the industrial zone (factory halls, depot
  yards, barracks blocks, gantries), fenced, with a main gate and a rail spur off the transit spine.
- **Enemies**: guards at the gate, patrols in the yards, fresh units walking out of the fabricator on a timer.
- **HUD**: targets marked once the crew is inside the district; each has a health bar when aimed at.
- **Needs**: the district style and its destructible structures. **L**. Environment (setting, art grid), antigravity
  (spawning from fabricators), Weapons (structure damage, explosions), Engine (HUD, state).

### 2.4 Raise a flag
- **Goal**: reach the flag point and hold it until the flag is up: stand inside the zone for 20 s in total.
- **Win**: flag raised. Progress pauses while an enemy is inside the zone and never goes backwards. **Cannot fail.**
- **World**: a **flag point**: a mast on a rooftop terrace, a plaza or the top of a pillar tower; visible from far away
  (the alien banner comes down, ours goes up, and it stays up for the rest of the mission).
- **Enemies**: a guard at the mast; **starting** to raise the flag raises the alarm: one reinforcement wave is ordered
  the moment the capture starts (the flag goes active) and heads for the crew at the mast, so the flag is held under
  attack (playtest 2026-11-23). Once ordered it arrives even if the flag is up first. It comes through a door 80-200 m
  from the mast if there is one (never under 60 m unless no door is that far). Flag sites sit at least 60 m from every
  door on their deck where the deck has such a site.
- **HUD**: a marker and a ring on the ground; progress as a whole percent ("Raise the flag: 40%", 100 % only once
  raised), in the objective panel and the zone bar, while anyone is in the zone.
- **Needs**: the mast prop and the zone rule. **S**. Environment (mast, placement), Engine (zone, HUD, state),
  antigravity (the answering wave).

### 2.5 Evacuate VIPs
- **Goal**: get the VIPs from where they are held to the evacuation point on this deck (a freight lift or a transit
  station), shown as "VIPs 2 / 3 safe".
- **How**: the game-design §8 loop in its smallest form: a crew member orders an **evac truck** at the holding area; the
  VIPs board; the truck follows that mech along the roads to the evacuation point. Enemies target the truck.
- **Win**: at least the required number of VIPs arrive. **Fails** if the truck is destroyed with too few safe.
- **World**: a **holding area** (the plan already places these, mission-section §9), an evac truck, an evacuation point.
- **Enemies**: guards at the holding area, then ambushes along the road and a pursuit wave.
- **HUD**: the truck is always marked, with its health; the route's end is marked once the VIPs are aboard.
- **Needs**: the evac truck with follow orders (the ambient-life vehicles are the base), VIP figures, the order verb.
  **L**. Environment (truck, VIPs, boarding), Engine (orders, HUD, state), antigravity (enemies that target the truck).

- **Open question: APC escort (user, 2026-11-23).** The user pictures an escort-type evac APC that drives itself to the
  evac site while the crew escorts it, not a truck that follows a mech. To be discussed with the user when phase 3
  design begins; this section stays as written until then.

### 2.6 Help the local defense forces
- **Goal**: a **holdout** of loyal civil-defense units is pinned down; break the attack before they are overrun, shown as
  "Defenders 4 / 6 standing".
- **Win**: the attackers are destroyed with at least one defender standing. **Fails** if every defender is lost.
- **Afterwards**: the survivors hold their ground for the rest of the mission: that part of the deck stays safe and no
  reinforcements come through the gate or lift they guard (§5). More survivors, more firepower in a later Defend.
- **World**: a barricaded position: a station, a depot gate, a block with sandbags and a wrecked tank.
- **Enemies**: the deck's first waves (§5.7), already attacking when the crew arrives, so the fight is found by its
  noise.
- **HUD**: a marker from the moment the crew is on the deck (a distress call), the defenders' count, friendly outlines.
- **Needs**: **friendly units**: the existing enemy classes on the crew's side, in the original civil-defense colours,
  fighting the occupiers. **M to L** depending on how much friendly AI is wanted (they hold position; they do not
  follow). antigravity (allied units, attackers), Mech / Enemy art (colours), Engine (HUD, state), Weapons (no friendly
  fire damage from the crew, or reduced).

### 2.7 Defend a position
- **Goal**: keep an asset alive for a set time or a set number of waves: a relay the crew has switched on, the freight
  lift while it comes up, the flag just raised, the holdout of §2.6. Shown as a timer and the asset's health.
- **Win**: the time runs out or the last wave is beaten. **Fails** if the asset is destroyed.
- **World**: a **defensible position**: an asset with two to four approaches and some cover, placed where the plan has
  gates, lifts or ramps nearby for the waves to come from.
- **Enemies**: this objective is a schedule of waves from the deck's pool (§5.7), each announced, each from a named
  direction, with a lull between them.
- **HUD**: timer or wave count, asset health, an arrow to where the next wave is coming from.
- **Needs**: the asset prop and the wave schedule. **M**, almost all of it shared with §5. antigravity (waves), Engine
  (timer, HUD, state), Environment (asset, placement).

### Summary

| # | Objective | Can fail | Needs new | Size | Good as |
|---|---|---|---|---|---|
| 0 | Sweep | no | nothing | S (built) | fallback, short missions |
| 1 | Heavy artillery | no | artillery enemy, emplacement | M | primary, early or middle deck |
| 2 | Political center | no | capital building, command post | L | primary, finale |
| 3 | Military output | no | military-industrial setting | L | primary, finale or middle |
| 4 | Raise a flag | no | mast | S | bonus, or primary on the first deck |
| 5 | Evacuate VIPs | yes | evac truck, VIPs, orders | L | primary, middle deck |
| 6 | Local defense forces | yes | friendly units | M-L | bonus, or primary |
| 7 | Defend a position | yes | asset, waves | M | follow-up to 4, 5, 6; the last stand at extraction |

## 3. Failing

Recommended: **only an objective that can fail (5, 6, 7) can cost the mission, and only as a primary.** A failed primary
ends the mission as lost (the crew restarts); a failed bonus is just lost. Objectives that cannot fail keep most missions
unlosable except by the crew going down, which is deferred with revive. See open question 1 for the softer alternative.

## 4. Several objectives on one floor

- **One primary, one or two bonuses.** The primary sits on the far half of the deck (toward the way down, where §16
  already puts the deck's heaviest group). Bonuses sit off the route: a side district, the express lift's stop, a roof.
- **Parallel, not scripted.** The crew does them in any order and can split up. Where one feeds another, the second lists
  the first in `needs` and appears when it is done: raise the flag, then defend it.
- **Bonuses pay off in the mission**, which is what makes them worth the detour:
  - Flag: marks every enemy within 150 m of the mast for the whole crew (it is a relay).
  - Local defense forces: a safe area, a sealed reinforcement source, help in a later Defend.
  - Artillery as a bonus: no shelling for the rest of the deck.
  - **Seal a gate** (a small bonus that comes with reinforcements, §5): destroy a gate's control box or secure a lift, and
    nothing arrives that way again.
- **How the crew learns about them**:
  - **In the hangar**: the briefing lists the primaries, one line a deck.
  - **On arriving on a deck**: the primary gets a marker and one comms line.
  - **Bonuses are found**: they appear as a marker (labelled with the plain type, "FLAG" / "DEFEND", like a primary) when a mech comes within about 150 m, when something
    reveals them (the flag relay, a spotter's death, a distress call), or at once for the loud ones (artillery that is
    firing, a holdout under attack).
- **The way down is not locked.** The decision stands that the crew may move between decks freely; a crew can leave a
  primary undone, but must come back before extracting (the objective list shows what is missing, by deck).

## 5. Waves and reinforcements

User direction (2026-11-22): "One way to manage the enemy count is to deliver in waves to build pressure on the players
instead of flooding them." So waves are the core of how a deck's enemies are delivered, not an extra.

### 5.1 Garrison and wave pool

A deck's enemy budget is split in two:

- **The garrison** (about half): standing on the deck when the crew arrives, placed along the encounter sites of
  mission-section §16. It is what the crew finds.
- **The wave pool** (the other half): not in the world yet. It is delivered in waves through the deck's doors, in answer
  to what the crew does. It is what finds the crew.

The pool is **finite and fixed at mission start** (rolled from the mission seed with the deck's budget). Every wave is
drawn from it; when it is empty no trigger can produce another enemy on that deck. That is what makes pressure build and
then end, and it is what keeps the enemy count bounded.

### 5.2 What a wave is

| | Rule (starting numbers, to tune in playtest) |
|---|---|
| **Size** | A deck's pool is split over **2 to 4 waves** (2 on the first decks, more with depth; plus a deck's extra flag waves), each about a quarter larger than the one before, never more than 12 units (`PacingDirector.WAVE_MAX`). A troop squad or a dropship load counts as one unit. A wave is `budget x (1 - garrison) x share x 1.75` units (`EnemySpawner.WAVE_POOL_SCALE`, playtest 2026-11-23: waves of 2 to 4 were too small; the garrison is unchanged, so a deck's total rises). The budget grows with the crew (`deck_budget`: 9 + 3 per extra mech + depth). Seeds 1-8: solo waves 2-5 units (mean 3.7, was 2.3), 2 crew 2-7 (4.8), 3 crew 3-9 (6.0), 4 crew 3-10 (7.1, was 4.0). A wave bigger than its door's load (gate / ramp 6, lift / shaft 4) comes out in follow-up loads, each with its own telegraph: a 10-unit wave takes 2 openings over ~7 s through a gate, 3 over ~14 s through a lift |
| **Composition** | One idea per wave, so the crew can read it: "striders rushing", "a tank with infantry", "gunships". Light units first; heavies only from the second wave on a deck |
| **Entry** | One source per wave (one gate, one lift, one ramp, one flight of dropships), announced by name and direction. Big waves late in a deck may use two sources at once |
| **Behaviour** | A wave arrives already hunting: it knows where the objective or the crew is and goes there. It never hides |
| **Spacing** | The next wave is released when the current one is **mostly beaten** (a quarter or less of it alive) **and** the lull has passed. It is never released on a timer alone while the previous wave is still fresh |
| **Lull** | At least 25 s with no new arrival after a wave is mostly beaten: time to cool down, call the repair drone, move. The HUD says "Wave cleared" and counts the lull down only in Defend (where the crew is waiting for it) |

**Escalation along a floor**: waves get larger and heavier (wave 1 light, wave 2 mixed, wave 3 brings the deck's heavy).
**Escalation across floors**: deeper decks have a larger pool, a larger first wave, a shorter lull (25 s on the first deck
down to 15 s on the lowest) and heavier unit types; the finale's last wave is the biggest fight of the mission.

**As built (2026-11-23), found by playing whole missions:**

- A wave's **door is chosen when it is released**, not in the plan: the open source nearest the crew (or nearest the
  objective under attack) that is at least 60 m from every mech, preferring one within 300 m.
- **A defend's waves, a flag's wave and the extraction hold's wave go first**, and the first of them does not wait
  behind another wave. A flag's wave is measured from the mast (the snapped site), not from the crew.
- Free waves wait, without expiring, for the crew to be on the deck. (The step-"done" alarm rule, released only with a
  mech on the deck and dropped after 20 s, stays in the director but no plan uses it since flag waves moved to the start.)
- **A Sweep deck always keeps one wave of its own** (first in its pool), so it ends on a fight; flags take what is
  left, and a flag with no slot left gets an extra wave taken from that deck's garrison share (the garrison drops below
  half, never under a quarter): every flag on a deck with doors has its wave.
- A wave that has not changed for 90 s no longer blocks the next one.

### 5.3 The cap on enemies alive

Explicit limits, enforced by the host; they are frame-budget limits first and difficulty second:

| Limit | Value to start from | What happens at the limit |
|---|---|---|
| Enemies alive on one deck | **24 units** | A wave that would exceed it **waits in the queue** and is released as kills make room (in part, if it must) |
| Enemies alive in the section | **40 units** | Same, across decks; the deck the crew is on has priority |
| Units in one wave | **8** | Larger pools become more waves, not bigger ones |
| Waves queued or in flight per deck | **1 arriving at a time** | A second trigger while a wave is arriving queues behind it |
| Arrivals per source per wave | **4 per lift load, 6 per gate, 2 dropships** | The rest of the wave follows as a second load after a few seconds |

The numbers are to be confirmed against `tests/test_perf.gd` (the frame budget with 4 mechs in the stack) before they are
called final; if the budget says 18, it is 18. The cap is why waves exist: the same 40 enemies as four waves of 10 cost
a quarter of what they cost all at once, and play better.

### 5.4 What starts a wave

1. **An objective step** (the main source): starting, advancing or finishing an objective releases a planned wave.
   Flag raised; command post hit; VIPs aboard the truck; each gun destroyed. These are the waves a crew can prepare for.
2. **The alarm**: a spotter or relay that survives long enough calls the next wave early, from the source nearest to it.
   Killing the caller first prevents it (game design §7).
3. **Lingering**: if the crew spends long on a deck with the primary undone (suggest 6 minutes), the next wave is
   released at the crew. It turns a stall into a fight.
4. **Production**: a standing fabricator (§2.3) adds a unit to the pool every so often, until it is destroyed. This is
   the one case where the pool grows, and destroying the fabricator is how it stops.
5. **The garrison running out**: when the garrison is nearly dead and waves remain, the next one comes after the lull,
   so a deck never goes quiet with enemies still owed.

### 5.5 What ends the pressure

- **The pool is empty**: no more waves on that deck, whatever happens. The HUD's objective line shows it ("Waves 3 / 3").
- **The objective is done**: waves that were answering its *start* and have not been released are **cancelled**; one
  already arriving still arrives. Finishing the job is the way to stop the reinforcements. (Except a flag's wave: it
  answers the capture starting and still comes if the flag is up before it is out.)
- **The source is closed**: a gate's control box destroyed, a lift secured, a holdout guarding it: waves that would have
  used it are re-routed to another source if one is open, and cancelled if none is. A crew that closes every door on a
  deck has ended that deck's waves.

### 5.6 How waves arrive

Only through places the section plan already has, so every arrival has a door the crew can see, watch and close:

| Source | In the plan | Telegraph (well above the 0.3 s rule) | Who comes |
|---|---|---|---|
| **Exterior gate** in a boundary wall | `boundaries[..].gates` of kind `blast_door`, with their `cordon` hooks | Klaxon and a turning amber beacon 3 s, then the door takes 2 s to open | Ground units: tanks, striders, troop squads |
| **Lift** | The locked express lift (stops on every deck), freight lifts | Floor lights count down and a chime, about 5 s; the doors open | One lift load |
| **From another deck** | Ramp heads and feet, shaft landings | A comms call ("contacts coming up the ramp") and a HUD arrow, 3 s before they appear at the crest | Ground units by ramp; jump-capable units and drones by shaft |
| **Dropship** | In and out through an air gate (a shaft, or a hangar door in a wall); drops in open ground (§5.8) | The existing 1.5 s drop telegraph plus engine noise on approach | Troop squads, several trips |

Every wave also gets a **comms line and a HUD arrow** naming the source ("Reinforcements, east gate"). Arrivals are never
inside the 70 m arrival bubble and never appear in sight of a mech: the door, the lift car or the ramp crest hides them
until the telegraph has played.

**Co-op**: waves are host-owned enemies like any other. A wave is one broadcast (source, composition, the shared-clock
time the door opens), so the beacon, the lift lights and the audio play at the same moment on every machine. Pool,
composition and source are rolled from the mission seed, never from global randomness. The queue and the caps live on
the host only.

### 5.7 How waves fit the objectives

- **Sweep (clear the deck)**: a deck is **clear when no wave is owed and every enemy alive on it is dead.** "Owed" means
  the deck's free waves (garrison running low, lingering); a wave reserved for an objective that has not started (an
  undiscovered bonus, the extraction hold) does not hold the Sweep open. The
  crew fights the garrison, the waves come to them, and the last wave is the end of the deck: the deck finishes on a
  fight, not on a search. The objective line shows both ("Hostiles 6, waves 2 / 3"). §15's hunt-out and reveal still
  cover a garrison straggler; a wave never needs them because it arrives hunting.
- **Defend a position** is a wave schedule and nothing else: N waves from the deck's pool at the asset, with the lull
  shown as a countdown. Won when every one of its waves has been released and beaten; the asset's health is the fail condition.
- **Help the local defense forces**: the attack on the holdout is the deck's first waves, already under way when the
  crew arrives (wave 1 in contact, wave 2 due). Each wave beaten with defenders standing is progress; surviving
  defenders then close the source they guard.
- **Raise a flag / artillery / political center / military output**: each objective step releases a wave from the pool
  (§5.4), so pressure rises as the crew gets closer to finishing and stops when it does.
- **Extraction**: the 30 s hold in front of the exit door draws the last groups from whatever is left of the lowest deck's pool (then patrols); if the
  pool is empty the hold is quiet, which is the reward for having cleaned up.
- **Between decks**: enemies stay on their deck today. "From another deck" is first built as units appearing at the ramp
  or shaft after the telegraph; real travel between decks is a later step for the enemy AI.

### 5.8 Turrets, fortified sites and dropships (user questions, 2026-11-22)

**Turrets cannot walk in, so they are never "delivered".** Two kinds:

- **Garrison turrets**: standing and visible from the start, at the heavy encounter sites. Part of the garrison half.
- **Reserve turrets**: only at fortified sites (a base, the capital). Dormant under a closed hatch or shutter, they
  **deploy as part of a wave** (hatch opens over 2 s with a warning light, then the usual firing telegraph). A reserve
  turret is a unit of the wave pool: it counts toward the wave's size and the alive cap once deployed, and if its wave is
  cancelled (objective done, pool emptied) it never deploys and never has to be hunted down. A dormant turret cannot be
  damaged, so it cannot be cleared early.

**Fortified sites have their own doors.** A military base, the capital building and a holdout under siege get **site
sources** in addition to the deck's gates and lifts: barracks doors, depot garage shutters, a fabricator's output bay,
a lift inside the compound. They work like a gate (a shutter that rolls up after a 3 s warning, a load limit, units
appear from inside a closed building, never in view), with three differences:

- They serve **only the waves of their own objective**, so the site's defenders come from inside it and reach the fight
  in seconds instead of walking in from the deck's edge. Alarm and lingering waves still use the deck's doors.
- **Destroying the building closes the source.** In Attack military output the barracks and the fabricator are both an
  output target and a door: every one destroyed is one fewer place for the next wave to come from.
- They are **placed by the setting**, not by the section plan: the base's layout marks its doors, and the mission reads
  them. A site without a marked door falls back to the nearest deck source.

**Dropships make several trips.** A dropship is a carrier, not a one-shot effect:

- It **enters and leaves through an air gate**: a shaft opening in the ceiling or floor, or a hangar door high in a
  bulkhead wall (a new gate kind for the plan's walls). It flies in, hovers and drops its load (the existing 1.5 s
  telegraph), then flies back out the way it came. It never vanishes in mid-air and never climbs through a solid ceiling.
- Out of sight it **reloads from the wave pool** (about 20 s) and returns with the next load, for as long as its wave has
  units left. Two dropships at most serve a deck.
- **Shooting it down matters**: a dropship destroyed on the way in loses the load aboard (those units leave the pool
  without ever landing), and that carrier makes no more trips. A deck with no air gate (no shaft, no hangar door) gets
  no dropships at all.
- While it is in the deck it counts toward the alive cap; while it is away it does not.

## 6. Across floors

- **Escalate**: the first deck gets a small primary (S or M), the lowest deck the largest (L). Enemy budgets already grow
  with depth (mission-section §4).
- **The finale is on the lowest deck**: political center or military output, the two that need a landmark.
- **What you do above matters below**: the alarm carries downward. A deck left loud (spotters alive, artillery
  standing, gates open) raises the starting alert of the next one; a deck left quiet lowers it.
- **Extraction is the last beat** (R2.10, as built 2026-11-27): when the last primary is done, the crew holds the zone in front of the exit road door for 30 s while an ally opens it.
  Those 30 s are a short Defend against the last groups (pacing-director.md 1.5). Then the door opens and the crew walks out together.

### Example missions

**A. "Silence the guns" (2 decks, about 12 minutes, no new settings needed)**

| Deck | Primary | Bonus |
|---|---|---|
| 1 | Heavy artillery (3 guns) | Raise a flag on the station roof |
| 2 | Sweep the depot district | Seal the east gate |
| | Extraction: hold the exit 30 s, walk out | |

**B. "Government quarter" (3 decks, about 25 minutes)**

| Deck | Primary | Bonus |
|---|---|---|
| 1 | Raise the flag on the transit hub, then defend it (2 waves) | Heavy artillery (2 guns shelling the hub) |
| 2 | Evacuate VIPs from the holding area to the freight lift | Help the local defense forces at the depot gate |
| 3 | Clear out the political center | Seal the express lift; the artillery guarding the plaza |
| | Extraction: hold the exit 30 s, walk out | |

**C. "Break the supply line" (3 decks, about 20 minutes)**

| Deck | Primary | Bonus |
|---|---|---|
| 1 | Help the local defense forces (the holdout is the way in) | Raise a flag |
| 2 | Heavy artillery (4 guns, one firing down the shaft onto deck 3) | Seal the west gate |
| 3 | Attack military output (4 targets, 2 fabricators) | Defend the relay to call the extraction early |
| | Extraction: hold the exit 30 s, walk out | |

## 7. Build plan (phases)

Signed off 2026-11-22. Each phase ends playable, with `-TestAll` and `test_perf` green and a co-op net test for what it
adds. **A phase is also not done until the mission bot can complete every objective type of that phase,
headless, without cheats** (user request, 2026-11-23): one bot run per type on a plan forced to that type
(`MissionPlan.make(sec, {"primary": type})`), walking, fighting and holding zones through the same inputs a player has,
ending in "won". Phase 1: sweep, flag, defend and the extraction hold. A type the bot cannot finish is a bug in the
mission, the level or the bot, and each case gets resolved, not waived. Phase boundaries are reported to the main session. Shared files are coordinated in
`docs/coordination/antigravity.md`.

| Phase | Playable result | Missions (this session) | Engine | antigravity | Environment | Weapons / others |
|---|---|---|---|---|---|---|
| **1. The frame** (no new enemies or settings) | A mission with a primary and bonuses per deck from Sweep, Raise a flag, Defend; enemies split into garrison and waves from gates and lifts; 60 s hold at the portal | `MissionPlan`, `WaveDirector`, `MissionRules` extension, tests (§9) | Host loop, `mission.state` / `mission.wave` events, objective lines, markers, zone ring, wave arrow and counter, net test of objective progress on every machine | Garrison = half the budget at the encounter sites; `spawn_wave(order)` from a source, hunting on arrival; wave tags and counts; perf check of the caps | Gate and lift doors that open on a wave order with their telegraphs, flag mast and zone, defend asset (with HP), portal opening over 60 s | Weapons: the asset as a damageable target (enemy fire only) |
| **2. New units** | Heavy artillery and Help the local defense forces playable; reserve turrets and site doors (§5.8) | Objective types `artillery`, `holdout`; placement rules; site sources in the plan | HUD for gun markers, impact circles, defender count, friendly outlines | Artillery enemy and spotter; allied units (hold position); reserve turrets deploying with a wave | Emplacements, the holdout barricade | Weapons: the shell as a telegraphed fire record, friendly-fire rule. Enemy art: civil-defense colours, artillery look |
| **3. New places** | Political center, Attack military output, Evacuate VIPs; dropship trips through air gates | Objective types `capital`, `output`, `evac`; hangar-door gates in the section plan's walls | Orders for the evac truck, structure health bars, briefing in the hangar | Garrison and reserve of the capital, production from fabricators, enemies targeting the truck, dropship round trips | Capital building, military-industrial setting (each after a 3x3 art grid), evac truck and VIPs | Weapons: structure damage and explosions. Pilots: reactions to objective beats |

Artillery is in phase 2, not phase 1, because it needs a new enemy; phase 1 uses only what exists so the frame can be
played and tuned first.

## 8. Questions for the user: settled as recommended (2026-11-22)

The user approved the design as proposed, so each question below stands at its recommendation: a failed primary loses
the mission; one primary plus one or two bonuses a floor; "clear every deck" survives only as Sweep; collateral is only
reported; local defense forces hold position; the garrison / wave split, the four sources, closable sources and the
lingering wave are in; 60 s hold at the portal; step 1 first; fewer on screen and more waves when the budget is tight.

1. **Failing a primary** (VIPs lost, holdout overrun, asset destroyed): does the mission end as lost (recommended, clear
   stakes), or carry on with a lower result?
2. **How many per floor**: one primary plus one or two bonuses (recommended), or several primaries a floor?
3. **Does "clear every deck" go away** as the standard goal once objectives exist (recommended: yes, it stays only as
   the Sweep type), or must every deck also be cleared?
4. **Collateral** at the political center: only reported at the end (recommended), or can wrecking the capital fail it?
5. **Local defense forces**: they hold their position (recommended, far less AI work), or follow the crew?
6. **Waves**: is the split right (about half the deck's enemies standing as a garrison, half arriving in waves)? Are the
   four sources and the "every source can be closed" rule right? Is a wave for lingering (about 6 minutes on a deck)
   wanted, or only waves tied to objectives and alarms?
9. **Caps**: 24 enemies alive a deck and 40 in the section are starting numbers, to be checked against the frame budget.
   Is "fewer on screen, more waves" the right trade when the budget is tight (recommended)?
7. **Extraction**: a 60 s hold at the portal every mission (recommended), or just walk out?
8. **Build order**: is step 1 (flag, defend, reinforcements, with what exists) the right first slice, or is one of the
   landmark objectives (political center, military output) wanted sooner?

## 9. Step 1 interfaces (the frame: Sweep, Raise a flag, Defend, waves, the extraction hold)

Three pure classes in `scripts/world/section/`, no nodes, no network, no global randomness; the host runs them, the
other sessions wire them. All positions are a deck's arc coordinates (x, s, metres).

**`MissionPlan`** (`mission_plan.gd`): what the mission is, derived on every machine from the section plan and the
mission seed. `MissionPlan.make(sec, overrides)`; `checksum()` joins the load barrier.

- `objectives`: `[{id, type: sweep | flag | defend | hold, deck, role: primary | bonus, site: {x, s}, radius, needs: [ids],
  params}]`. `flag`: `params.hold` seconds in the zone. `defend`: `params.waves`, `params.asset_hp`. `hold`: the 30 s (R2.10; was 60)
  in front of the exit road door, last, needs every primary (§9 "The exit").
- `sources`: `[{id, deck, kind: gate | lift | ramp | shaft, x, s, toward: {x, s}, load, connector, edge}]`: every door a
  wave can use (blast-door gates, lift stops, ramp ends, shaft landings); `toward` is the direction units walk out.
- `pools`: per deck `{deck, garrison: 0.5 (less when the deck has extra flag waves), reserve: [{id, share, theme: light |
  mixed | heavy, source, for}]}` (2026-11-23, pacing-director.md 1.1: no triggers; `for` names the objective a group
  belongs to, "" for a free group; the PacingDirector decides when each goes).

  `share` is the group's fraction of the deck's pool (the spawner turns it into units from the reserve budget = the solo
  deck budget x CREW_SCALE, x 1.75, 12 at most).

**Superseded 2026-11-23 by the `PacingDirector`** (`pacing_director.gd`, docs/design/pacing-director.md section 1: states,
quiet cap, objective spikes, scout calls, co-op scaling; same order shape plus `reason`). The WaveDirector described
below no longer exists; kept for the record. **`WaveDirector`** (`wave_director.gd`): host only, the queue and the caps.
`tick(t, facts) -> orders`.

- `facts`: `{alive: [per deck], wave_alive: {wave id: {alive, total}}, garrison_alive: [per deck], crew_deck: [decks with
  a standing mech], objectives: MissionRules.state(), closed: [source ids]}`.
- `orders`: `[{wave, deck, source, open_at, max_units}]`: release this wave from this source; the door opens at
  `open_at` on the shared clock (the telegraph plays before it); `max_units` is what the alive caps allow now, the rest
  of the wave stays queued and is ordered again later.
- Rules: §5.2 spacing and lull, §5.3 caps (constants on the class), §5.4 triggers, §5.5 cancelling and re-routing.
- `state()`: `{waves: [[released, total] per deck], next: {deck: open_at}}`, small, broadcast with the mission state.

**`MissionRules`** (`mission_rules.gd`, extended; `make(sec)` without a plan behaves exactly as today):
`make(sec, {"plan": MissionPlan})` evaluates the plan's objectives. Extra facts: `waves_left: [per deck]` (from the
director), `zone_enemies: {objective id: count of enemies inside its radius}`, `assets: {objective id: hp 0..1}`, `t`.
Sweep: deck clear when `enemies[k] == 0 and waves_left[k] == 0`. Flag: accumulates time while a standing mech is in the
zone and no enemy is. Defend: done when its waves are released and beaten, failed when its asset reaches 0. A failed
primary sets the outcome to lost. `state()` adds `objs: {id: [state, progress, total]}` and `reached` (the deepest deck a
standing mech has been on, latched). HUD text (built here so host and clients read the same from the replicated state):
an undiscovered bonus is not listed; the flag reads "Raise the flag: 40%"; in the flat list (`lines()`), once a deck's
primary is done it starts with "Proceed to deck n" (the extraction deck: the hold's line, or "Return to deck n: objective
unfinished"); the panel is described below; and
`text()` reads "Proceed to deck n" until a standing mech reaches the next primary's deck. The HUD has one objective
panel, top right (the top-centre strip was removed, playtest 2026-11-23).

**Objective panel** (2026-11-24, user: "no indication of what level you are on"; reworked 2026-11-25, playtest backlog
#3; **rebuilt 2026-11-26, playtest backlog R2.13**, user: "The objective panel still doesn't work", with the layout
below: one section per deck, every deck always listed). `MissionRules.panel(viewer_deck, viewer_pos)` builds it from
the replicated state plus two local facts of the viewing pilot (their deck and (x, s) on it, never sent);
`MissionRules.fit(panel, rows)` shortens it to a height; `MissionHud` only draws it. Nothing new on the wire: `reached`
was already in `state()`. The previous design ("DECK 1 OF 3" header, "PROCEED TO DECK N" dim and last, "Deck 1: 2
optional left" one-liners, "Return to deck n: objective unfinished") is gone.

```
> DECK 1:                                       at the start (">" = the viewer's deck: bright, marked; others dim)
    CLEAR HOSTILES, WAVES 2/3                   the sweep (primary, white)
    RAISE THE FLAG: 0% (OPTIONAL)               a found bonus (dimmer cyan)
  DECK 2:
    PROCEED TO DECK 2                           all an unvisited deck shows (dim)
  DECK 3:
    PROCEED TO DECK 3

  DECK 1:                                       after going down early: deck 1 keeps its lines where they were left
    CLEAR HOSTILES, WAVES 2/3
    RAISE THE FLAG: 23% (OPTIONAL)
> DECK 2:                                       visited: its objectives open up
    RAISE THE FLAG: 0%
  DECK 3:
    PROCEED TO DECK 3

> DECK 1:                                       deck 1's primary done
    CLEAR HOSTILES, WAVES 3/3                   green, its final value
    RAISE THE FLAG: 23% (OPTIONAL)
  DECK 2:
    PROCEED TO DECK 2                           amber: the next step (nothing moves)
        SHAFT DOWN 135 M                        its route hint (amber); the waypoint diamond points there
  DECK 3:
    PROCEED TO DECK 3

  DECK 1:                                       on deck 3, its primary done, deck 2's not
    CLEAR HOSTILES, WAVES 3/3
  DECK 2:
        RAMP UP 85 M                            under the header, only when a ramp up exists
    RAISE THE FLAG: 45%                         amber: go back (no separate "Return" sentence)
    DEFEND THE POSITION: WAVE 1/3 (OPTIONAL)
> DECK 3:
    DEFEND THE POSITION: WAVE 2/2
```

- **Sections**: every deck, in deck order, a header "Deck n:" (numbered as painted on the walls). The viewer's deck's
  header is bright with a marker before it (U+25B6 when the HUD font has the glyph, else ">": `MissionHud.current_mark`,
  decided once at startup), the other headers dim; no "DECK X OF Y" line.
- **Visited decks** (up to `max(reached, viewer deck)`: `reached` is the crew's latched deepest deck; the viewer's own
  deck always counts, so a client never shows an empty section in the moment before the host's next state): their known
  objectives, indented: the extraction hold first once it shows (it is the last deck's), then the primary (white), then
  the found bonuses ("(optional)", dimmer cyan); hidden bonuses are not listed. Done lines stay green with their final
  value; failed lines red with "(failed)". Visited decks keep their lines after the crew leaves. Lines of decks other
  than the viewer's are drawn a little dimmer.
- **Wording** (the section names the deck, so the line doesn't): sweep "Clear hostiles, waves 2/3" (the user's words;
  "Clear hostiles: 5 left" only while no wave count is known), flag "Raise the flag: 23%", defend "Defend the position:
  wave 1/3", hold "Hold the exit: 40%" (percent, like the flag), then "Exit through the door" (amber) once the exit is open. `text()` and the flat `lines()` keep "Clear deck 2: 5 hostiles,
  waves 2 / 3" (nothing around them names the deck).
- **Unvisited decks**: exactly one line, "Proceed to deck n", every one of them.
- **The next step** (`lead`, amber), only while the viewer's deck has no primary left and the mission is on: the nearest
  deck below with a primary left or still unvisited (its "Proceed to deck n" turns amber), else the nearest visited deck
  above with a primary left (that primary line turns amber: the crew must go back). Co-op: a pilot behind the crew sees
  the crew's visited deck below with its objectives; once their own primary is done, that deck's unfinished primary is
  amber.
- **Route hint**: one line only, under the next step: under its "Proceed to deck n", or under the visited deck's header
  (the go-back case); only when a walkable way exists: the nearest way off the pilot's deck that way, straight-line along
  the deck rounded to 5 m, plain words ("ramp down 120 m", "shaft down 90 m", "ramp up 85 m"): down, a ramp's mouth or a
  shaft whose drop lands on the next deck (never a stacked atrium); up, a ramp's foot only. Lifts are left out while
  they don't carry mechs (`MissionRules.LIFTS_RIDE`, BotRoutePlanner skips them too); locked connectors never count.
- **Waypoint**: `route_at` (the hint's route) is also the HUD's waypoint diamond ("RAMP DOWN 120m") when there is no
  extraction waypoint; `marker()` is untouched (the bot reads it and `rules.plan`, never the panel).
- **Depot and crew lines**: the depot line ("Taking power core: 60%") at the end of the viewer's section, the downed-crew
  lines ("Pickle is down: revive with a repair drone", red) last, after every section; neither is ever cut.
- **Height**: one panel, top right, never past 40 % of the screen height (`MissionHud.PANEL_FRAC`, rows of 19 px, no
  title row). Every header always stays. Too long (`MissionRules.fit`, each step only as far as needed, other decks
  farthest from the viewer first): the route hint; other decks' done / failed lines; other decks' optional lines -> one
  "n optional" line; other decks' remaining lines -> one "1 objective, 2 optional" line (amber if it replaces an amber
  line); then the viewer's done / failed lines and optional lines -> "n optional"; then other decks down to their header;
  then the viewer's lines from the end. Worst case measured (`test_layout`, 5 decks all visited, two found bonuses each,
  the depot line, one crew line): 22 rows wanted, 18 drawn on a 900 px tall screen (356 px = 40 %; 16:9 and ultrawide):
  the two farthest decks' bonuses fold to "2 optional", nothing else is cut. The 4:3 layout (taller logical screen)
  draws all 22.
- **No prefixes**: no "-" / "^1" / "V1" direction column; every text is plain ASCII the HUD font draws, upper-cased.
  The flat "OBJECTIVE" + text panel of the old clear-and-extract mode was removed with that mode (2026-11-26): this panel
  is the only one.

**The exit** (R2.10, user 2026-11-27: "a third party is opening the doors for us ... once you are in the zone it takes 30
s to get the doors open. And waves will try to stop you"; "the crew walks out to win"; as built, uncommitted):
- **Hold rules (unchanged, now 30 s)**: each host evaluate adds the facts.t delta (at most `MAX_STEP` 1 s) while at least
  ONE standing (not downed) crew mech is inside the zone rect on the extraction deck. Enemies in the zone change nothing
  (no contested state for the hold). Nobody in it: progress PAUSES (no reset, no decay), the objective stays active. A
  partly-in crew counts fully. The zone (`MissionRules.extraction_zone`, 40 m deep across the spine at the exit's end
  wall) contains the exit road door's whole width on every seed checked (1-50: door on the zone's x range, at its wall).
- **Door**: when the hold completes the rules latch `exit_at` = facts.t + `EXIT_LEAD` (1 s) and the host orders the exit
  road door open at `exit_at`, held for the rest of the mission (`MissionFlow.DOOR_HOLD`), as a replicated order on the
  wave path: `mission.wave {wave: "door", source: "door_exit", door: "open", open_at: exit_at, hold}` (no NetMission
  change: NetMission dedups on wave + source + open_at + hold); every machine calls `MissionWorld.open_source(id, open_at,
  hold, open_at)`: the door's own warn / siren / opening (passable at exit_at + OPENING). A client that missed the order
  applies the same from the state's `exit`. Nothing else opens the exit door (no plan source names it, no wave uses it).
  Without an exit door on the deck (none on seeds 1-50) the rules' `walk_out` is off and the hold's completion wins
  (warning logged).
- **Win**: "won" on the first evaluate where every STANDING crew entry is inside the exit bay and at least one stands.
  Inside = `MissionWorld.bay_contains(door_exit, position).inside` AND depth behind the door plane >= the mech's capsule
  radius (Strider 2.2 m, Bulwark 3.6 m: the whole hull is through). Downed pilots never block (they are recovered with
  the crew); a redeploying pilot is downed, so it does not block either (redeploy takes 3 + 5 s and lands 60-90 m from
  the zone, which counts as active through the walk-out). Enemies are never counted: one standing in the 14 m doorway
  cannot make the win impossible (the door never closes again).
- **Replicated state** (`mission.state`, MissionRules.state()): `objs.hold` = ["done", 30, 30] once held; `exit` = the
  exit door's open_at on the shared clock (-1.0 before); `outcome` "won", `reason` "objectives" at the walk-out.
- **HUD (player-side only)**: "Hold the exit: 40%" (panel / lines / text; the zone bar "HOLDING THE EXIT 40 %"), then
  "Exit through the door" (amber, leads the extraction deck's section, from any deck) and the EXIT waypoint on the exit
  bay's centre once the exit is open. The ally's lines, text only, cyan, in the alert strip, once each per mission
  (`MissionRules.ally_due`): "Working on the door" when the hold goes active, "Almost there" at 70 %, "Door's open, go!"
  when the exit opens. No station hardware shows anything game-made; the portal / curtain code is gone (`set_portal` no
  longer called).
- **Entry door (crew missions)**: every machine shuts it at setup (`shut_source(door_entry, ENTRY_SHUT_AT)`, one constant,
  so the crew in the entry bay waits behind it through the load barrier) and opens it at the barrier's `start_at` (every
  machine has it: no message); moving leaves are never solid, so nobody is held. The host shuts it (replicated door order,
  `door: "shut"`) once no crew mech has been in its bay or doorway for `ENTRY_CLEAR` 3 s, and reopens it whenever one is
  found there again (a pilot redeploying to its spawn slot in the bay, a pilot walking back). Solo: the door's default
  (open from clock 0).
- **Logs**: `[mission] exit open at <t>`, `[mission] entry open|shut at <t>`, `[mission] exit: the crew walked out at <t>`,
  `[mission] ally: <line>`; CombatLog `door ev=open|shut|win id= at=`.


**Who wires what**

| Session | Step 1 work |
|---|---|
| Missions | The three classes and their tests |
| Engine | Host loop (facts in, orders and state out), one `mission.state` / `mission.wave` event, objective HUD lines, markers, zone ring, "Reinforcements, east gate" arrow, wave counter |
| antigravity | Spawner: garrison = half the deck budget at the encounter sites; `spawn_wave(order)` creating a wave's units at a source, tagged with `wave` id and `spawn_deck`, arriving hunting; `wave_alive` counts |
| Environment | Doors that open on a wave order: blast-door gates, lift doors, the flag mast and its zone, the defend asset prop (with HP), the extraction portal's 60 s opening |
