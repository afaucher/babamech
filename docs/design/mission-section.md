# Mission section: macro layout

> **Status: resumed 2026-11-21 (late), still a proposal.** The city generator is building whole decks from this plan
> (`docs/design/city-section-mode.md`); the names it reads are frozen (see §11). Added since the pause:
> `SectionPlan.deck_view(k)`; a lift's footprint is its 22 m platform on every deck. The defaults below are
> **provisional** until playtested; the user answered the open points on 2026-11-22 (§13: size by playtest, straight
> ramps, pillar density fine, no hull shafts yet, boundary walls fine for now). Nothing is committed.

Status: **proposal, built as a planner** (2026-11-21). Open points are in §13. Parent: [game-design.md](game-design.md) §3
(world), §7 (enemies), §8 (rescue). This is generator pass 1 and the top half of pass 2 (§3.5): the section's cross-section,
the district plan of every deck, the pillars and the transit that ties them together. Building geometry is pass 3 (the city
generator, `scripts/world/city/`).

Code: `scripts/world/section/section_plan.gd` (`SectionPlan`, the planner and the plan data),
`section_map.gd` (`SectionMap`, the 2D view), `section_lab.gd` (lab subject `section`: `.\lab.ps1 section`).
Tests: `tests/test_section_plan.gd`.

## 1. What a section is

A mission attacks one **arc segment of the ring**, not the whole ring (user decision, 2026-11-21). The segment is walled
on all four sides on every deck (§8): two walls across the spin direction (the ends of the arc) and two across the axis
(the sides). The only ways through are the transit portals the crew enters and leaves by. Inside are **several decks**,
loaded as one scene. The ring radius is a free parameter: it is chosen for the curve and the scale, since the map never
has to close the circle.

| | Default | Range (lab) | Why |
|---|---|---|---|
| Decks | **3** | 2–5 | 30 min ≈ 10 min a deck. The MVP is 2. |
| Arc length (top deck) | **540 m** | 300–900 | One crossing ≈ 1–1.5 min at a run (13 m/s) before any fighting |
| Axial width | **270 m** | 160–450 | Three district columns: room to flank, never far from the spine |
| Top deck radius | **400 m** | 150–1200 | The section spans ~77° of ring; the floor climbs to the ceiling line ~180 m ahead, so the curved horizon caps sightlines along the arc and the end walls stand visibly "uphill" |
| Deck pitch | **48 m** | fixed | 40 m clear (D4's ceiling) + 8 m of deck slab |
| District cell | **90 m** | 60–140 | 3 × 6 cells a deck by default |

Decks are **concentric**: deck 0 is the top (nearest the axis), "down" is outward, and each deck is longer than the one
above it (same angle, bigger radius: 540 / 605 / 670 m by default). Anything that must line up between decks is therefore
stored as an **angle**, not an arc length.

## 2. The two views

- **Cross-section** (the in-game map and the level-design view): a slice across the axis. Decks are concentric arcs, the
  top deck innermost, the floor curving up at both ends. It shows what matters for the mission: decks, where they
  connect, and the route. Zones and pillars are those of one district column; connections and routes are projected onto
  the slice.
- **Deck plans**: each deck unrolled flat (arc across, axis up), for layout work.

The lab shows both beside a 3D block-out with a cutaway.

## 3. Entry, extraction and the critical path

The route is a **switchback**: it crosses each deck from end to end, and each deck is crossed the opposite way to the one
above. In the cross-section it reads as a zigzag.

```
 IN ─► deck 0 ─────────────────────────────► ▼ way down
       ▼ way down ◄───────────────────────── deck 1
       deck 2 ─────────────────────────────► OUT
```

- **Entry**: the transit spine's portal through the bulkhead at one end of the **top deck** (the crew arrives along the
  rail line; the motor pool with the first rescue vehicles is in the station there).
- **Extraction**: the spine's portal at the far end of the **lowest deck's** crossing.
- **The way down** from each deck is at the far end of its crossing, so the whole deck lies between arriving and
  leaving. There is exactly one guaranteed, vehicle-capable way down per deck (§6), and the occupiers hold it (§9).
- **Optional branches**: the district columns away from the spine; the "backwater" behind each arrival (under the ramp, or
  between the lift and the bulkhead); the civilian holding site of each deck, placed as far from the route as the deck
  allows (§9); the locked express lift (§6).
- **Shortcuts** (mechs only): open-air shafts mid-deck drop straight to the deck below, skipping half of each crossing.
  The mech route with shafts is about 30 % shorter than the vehicle route. The price is leaving the vehicles to drive
  around, which is the escort tension of §8.

## 4. Pacing along one deck

Every deck is zoned along its crossing so the rhythm of §3.1 comes out of the layout:

| Stretch | Zones | Play |
|---|---|---|
| Arrival (first third) | Transit station, then **urban** | Tight streets, ambushes, rooftop routes |
| Middle | **Park**, **open-air shaft** | Long sightlines, indirect fire, the look down to the next deck, the shortcut |
| Way down (last cell) | **Transit** head: ramp mouth or lift lobby | A chokepoint with a heavy checkpoint |
| Edges, around lifts | **Industrial** | Freight yards, gantries, cover-rich detours |

Deeper decks get more industry (freight and plant sit toward the hull); the top deck is the most residential.

## 5. Districts: the cell grid

Each deck is a grid of **district cells** bounded by roads, like a planned city: **key areas joined by roads, recreation
between them**.

- **Longitudinal lines** run along the arc at constant x: the two perimeter roads inside the side bulkheads, arterials
  between columns, and one line that is the **transit spine** (§6).
- **Cross lines** run along the axis at constant angle: a perimeter road inside each end bulkhead, cross streets between
  rows. Cross lines are at the same angle on every deck.
- A **cell** is the buildable ground between four roads. Every cell has one zone; neighbouring cells of one zone form a
  **region**, the unit the city generator fills.

Zone rules, in order:
1. **Transit** where the route enters, leaves or changes deck: the entry and extraction stations, the cell at every ramp
   mouth and ramp foot, every lift stop.
2. **Open air** where a shaft is cut; the cell under a shaft is a **park** (clear landing ground, marked keep-clear).
3. Everything else is rolled along the crossing from the zone mix (urban / park / industrial weights), biased by the
   pacing of §4, by depth, and by the neighbours already placed so districts clump instead of speckling. Parks grow
   around shafts; industry gathers at the edges and beside lifts.
4. Every deck has at least one park.

## 6. Transit

**The spine** is one 50 m corridor running the whole arc of every deck, at the same x on all of them:

| Lane | Width | |
|---|---|---|
| Ramp lane A | 10 m | Ramps of even deck changes dive out of / land in this lane |
| Avenue | 18 m | The road spine: vehicles, traffic |
| Rail | 12 m | Two tracks, through the bulkhead portals at both ends; stations at transit cells |
| Ramp lane B | 10 m | Ramps of odd deck changes |

Alternating lanes means a ramp arriving from above and the ramp leaving for below never fight for the same ground, however
their lengths overlap.

**Roads** form a full grid on every deck (spine 50 m, arterials 14 m, perimeter 12 m), so every district touches a road and
vehicles can reach any cell. Paths and minor streets inside a region are the city generator's.

**Traffic rule.** Every road line is **two-way, right-hand traffic**; the plan has no one-way lines and carries no
direction data. Ramps are two-way within their 10 m lane. The rail runs wall to wall on every deck; only the entry and
extraction portals are open, so a tram shuttles within its deck. Ambient traffic (`docs/design/ambient-life.md`) builds
its lanes from `road_graph(false)`, `node_pos` and the spine lanes (`lane_x`).

**Between decks:**

| | Who | Shape | Rules |
|---|---|---|---|
| **Ramp** | Everyone, both ways | A straight descent in a spine ramp lane, from the far end of the deck back toward the middle, landing on the deck below already heading the new way | Length = pitch / grade, rounded up to whole rows so the foot meets a cross street (default 18 % → 3 rows, ~270 m). On the upper deck it is a long **cut** (a look-down ledge, bridged by the cross streets); on the lower deck a viaduct coming down from the ceiling, which blocks the cross street at its foot |
| **Freight lift** | Everyone, both ways | A 22 m platform inside a **lift pillar** in the cell beside the spine | The pillar is a lift tower on the decks it serves; the lobby faces the spine |
| **Shaft** | Mechs, down only | An opening up to 40 m square in the middle of an open-air cell | Mid-crossing; lands in a park; shafts may stack into an atrium through several decks |
| **Express lift** | Everyone, **locked** | One lift pillar mid-section stopping on every deck | A branch: sealed by the occupiers, a light checkpoint on every deck. Opening it is an objective hook (a fast way back up for a loaded convoy) |

Each deck change gets a ramp when one fits (rolled, and biased to alternate with lifts so a section shows both), otherwise a
lift. The lift is the fallback that always fits.

**Routing.** Vehicles and civilians: the road grid + ramps + lifts (`road_graph`). Mechs: every cell + ramps + lifts +
shafts as one-way drops (`mech_graph`). The planner computes the shortest route for each from entry to extraction and
stores it; the tests prove both exist, that vehicles can drive back up, and that every cell is reachable.

## 7. Pillars

The decks hang on **columns that run unbroken from the hull to the top deck**. Spin gravity loads every deck outward, so a
pillar on one deck must stand exactly over the pillar on the deck below: same angle, same x, on every deck.

- **One pillar per cell**, near its centre (seeded offset up to 6 m, shared by all decks). Spacing is therefore one cell
  (~90 m): close enough that no sightline along a deck runs more than a couple of cells without a column in it, wide
  enough for a mech fight between them.
- **Never in a road**: pillars stay inside their cell on every deck, so roads, the spine and ramps are column-free.
- **Look by zone** (§3.1), per deck, since one column passes through different districts: urban → the core of the
  tallest building (9 m half-width; the city generator wraps a tower around it); park → slim tree-like column (2.5 m);
  industrial → steel truss (5 m); transit → 7 m; a **lift pillar** → 14 m tower holding the platform.
- **Long-span bays**: a cell with a shaft has **no pillar on any deck** (the hole would cut the column). Two such bays
  never share an edge, so no span exceeds two cells.
- **Connections keep 4 m clear** of every pillar they are not housed in.

## 8. Boundaries: the walls and how the city meets them (`plan.boundaries`)

Every deck has four walls, floor to ceiling, 6 m thick, standing just outside the section's ground: `s0` and `s1` close
the ends of the arc, `x0` and `x1` the sides.

| Wall kind | What it is | Beyond it |
|---|---|---|
| **Bulkhead** | A structural frame of the habitat: solid, ribbed, the city built up to it | Nothing visible |
| **Window** | A pressure wall with tall windows between its ribs | The **backdrop**: the rest of the ring in low detail, still curving upward, so the habitat reads as continuing (`backdrop = true`) |

The ends of the arc are windows more often than the sides (65 % against 25 %): looking along the spin direction is where
the curve shows. A wall the crew passes through is always a bulkhead, so the portal is a gate in a solid wall.

**Gates** are where a road meets a wall:

| Gate | Where | |
|---|---|---|
| **Portal** | The spine, in the entry wall (top deck) and the extraction wall (lowest deck) | Open: rail tunnel and avenue through the bulkhead. The only two ways in or out |
| **Blast door** | Every other spine and arterial end; about a third of the cross streets at the side walls | Sealed by the occupiers (quarantine barrier, alien hardware grafted onto the frame). A `cordon` hook stands in front of each |
| **Collapsed** | Some spine ends | A transit tunnel brought down: rubble and a dead rail line instead of a door |
| (none) | The remaining cross streets | The street ends in a T at the perimeter road |

**How the city transitions into a wall:**
- A **perimeter road** (12 m) runs along the inside of every wall: the last ring of circulation for vehicles and patrols,
  and the gap that keeps the wall readable as a wall. Cells stop at it.
- **Against a bulkhead** the far side of the perimeter road is the wall itself: ribs at every road line, service
  galleries and pipe runs between them, lean-to structures (sheds, substations, stairs) as wall dressing. Not walkable
  above the gallery level; it is the map's hard edge.
- **Against a window wall** the perimeter road is a promenade: low sill, windows, the backdrop beyond.
- **Ways down sit next to the end walls**: the critical ramp mouth or lift is in the last row before the wall (§3), so
  the chokepoint fight has the wall at its back and the route never dead-ends.
- **The spine** runs wall to wall on every deck; its rail line disappears into a portal, a sealed door or a collapse.
- **The backdrop** is the city generator's or the scene's: a low-detail continuation of the deck and ceiling beyond
  window walls, and nothing beyond bulkheads.

## 9. Enemy placement hooks (`plan.hooks`)

The planner marks positions; the gameplay pass decides what stands there.

| Hook | Where | Intent |
|---|---|---|
| `checkpoint` heavy | The head of every way down | The chokepoint fight of each deck; cordons, barriers, turrets |
| `checkpoint` light | The express lift on every deck | Guards on the locked lift |
| `patrol` | A loop on the roads around every park | Patrols with long sightlines across open ground; the park is where they see you |
| `holding` | The built-up cell farthest from the route, one per deck | Where civilians are held: the optional branch worth the detour |
| `station` | Every transit region | Vehicles (motor pool at the entry), rail, resupply |
| `cordon` | In front of every sealed blast door | A small guard post; reinforcements could arrive through the door later |

Squad spawns, relays and spotters (§7 of the game design) come later and should key off the same graph: relays on the
spine, spotters on park edges and shaft rims.

## 10. Occupation dressing hooks

`banner` at every transit region (station fronts are where the occupier's signage hangs; banners are destructible),
`pylon` along the spine at every other cross street (surveillance over the main road), cordons at checkpoints and
sealed blast doors (§8). The city generator and the dressing pass place the props.

## 11. The plan format (for the city generator and gameplay passes)

`SectionPlan.make({"seed": n, ...})` returns plain data; `checksum()` covers all of it. Coordinates are **per-deck arc
coordinates** `(x, s)`: x along the axis with 0 on the section's centre line, s along the spin direction with 0 at the
middle of the section, in metres on that deck. Shared things carry an **angle** `theta`; `s = theta * radius_of(k)`.

| | |
|---|---|
| `deck_count`, `cols`, `rows`, `span` | Grid size; `span` = the section's angle |
| `radius_of(k)`, `clear_height()`, `arc_of(k)` | Deck k's floor radius, the 40 m clear height, its arc length |
| `ring(k)`, `deck_offset(k)`, `to_world(k, x, s, h)` | A `RingFrame` for deck k and the offset that puts every deck on one axis |
| `decks[k].zones[row][col]`, `zone(k, c, r)` | urban / park / industrial / open / transit |
| `decks[k].regions` | `{kind, cells, rect}`: joined cells of one zone |
| `decks[k].keep_clear` | Rects that must stay unbuilt (shaft landings) |
| `cell_rect(k, c, r)` | The buildable ground of a cell (roads excluded) |
| `roads`, `col_x`, `row_theta`, `line_width()`, `lane_x()` | The road lines and the spine's lanes |
| `pillars` | `{id, col, row, x, theta, lift, stops}`; `pillar_point(k, id)`, `pillar_style(k, id)`, `pillar_radius(k, id)` |
| `connectors` | `{kind, role, from, to, stops, vehicles, two_way, locked, x0, x1, theta0, theta1, col, row, pillar, top, bottom, …}`; `connector_rect(ci, k)`, `is_hole(ci, k)` |
| `entry`, `extraction`, `route` | Road crossings and cells; `route.vehicle`, `route.mech` |
| `road_graph()`, `mech_graph()`, `walk()` | The graphs behind the route, for AI and vehicle routing |
| `boundaries` | Four per deck: `{deck, edge: s0/s1/x0/x1, kind: bulkhead/window, backdrop, gates: [{kind: portal/blast_door/collapsed, role, axis, line, x, s, width}]}`; `boundary(k, edge)`, `boundary_rect(k, edge)` |
| `hooks` | §9, §10 |
| `deck_view(k)` | One deck in one Dictionary, in that deck's `(x, s)`: `extent`, `blocks` (cell rect, zone, region, pillar), `pillars`, `road_strips` (the spine split into its four lanes), `connectors` (part: hole / landing / stop), `ceiling_openings` (the holes of the deck above), `keep_clear`, `walls`. Read-only; the strips and blocks tile the deck exactly. A ramp hole crosses the cross-street strips: cut it out of each, or bridge it |

**What the city generator should take from it:** build inside `cell_rect` / region rects only; put a pillar tower exactly
at each `pillar_point` with at least `pillar_radius`, styled by `pillar_style`; leave `keep_clear` and connector
footprints unbuilt; cut the floor where `is_hole`; treat the plan's roads as given and add only streets inside regions; build each wall at `boundary_rect` in its kind, with
its gates, and a low-detail backdrop beyond the walls whose `backdrop` is true.

## 12. Networking

The section is static world data: the host sends the mission seed and planner params (`Net.SPAWN`), every
machine runs the planner and compares `checksum()` (rule 4, §3.5). No global randomness; looks use `cosmetic_seed()`.

## 13. Decisions and open points

Answered by the user (2026-11-22):

1. **Section size: to be settled by playtest.** Target mission length is **30 minutes or less, probably nearer 15**. The
   single demo district currently clears in about 2 minutes. The 3 decks x 540 m x 270 m default stays provisional
   until a multi-deck section can be played.
2. **Mission end: "finish the mission"**, not yet defined. The top-in, bottom-out route with an extraction portal stays as
   the provisional shape; out-and-back is not adopted. What finishing means is an objectives question (game design §8).
3. **Pillar density: fine as seen in the demo city** (one per ~90 m cell).
4. **Ramps: straight only for now.** Spiral ramps are a later consideration.
5. **Lowest deck: no shafts or windows to the hull yet.**
6. **Ring radius: free** (the map is an arc segment; 400 m default, tune in the lab).

7. **Boundary walls: fine for now** (2026-11-22), as shown: the section plan's wall kinds and gates, the city
   generator's bulkhead with a blast door and its window wall, and the current bulkhead / window mix.

Open: nothing waiting on the user. Still to settle by playtest: section size (item 1); still undefined: what finishing the
mission means (item 2).

## 14. Demo objective and end conditions (co-op demo, 2026-11-22)

> **Revive and the crew-wipe loss are deferred** (user, 2026-11-22: "Don't do revive yet"). The win side below stands. The
> loss rule is built in `MissionRules` but **off by default** (`make(sec, {"wipe": true})` turns it on): until revive
> exists a disabled mech still respawns on its own, and the mission cannot be lost. The loss text below describes what
> switches on with revive.

The smallest mission that uses the section: **clear every deck, then reach the extraction portal.** It stands in for
"finish the mission" (§13 item 2) until real objectives are designed (game design §8).

**Objectives**, in order, derived from the plan on every machine (nothing is sent):

| id | Done when | |
|---|---|---|
| `clear_k` (one per deck) | No enemy that spawned on deck k is alive | Latches: stays done |
| `extract` | Every `clear_k` is done and a standing crew mech is inside the extraction zone | The zone is the spine's width, 40 m deep, at the extraction portal on the lowest deck. Optional (`extract: false` makes the win "all enemies down") |

**Won**: every objective done. **Lost**: every crew mech still in the mission is downed at the same time (solo: downed is
lost at once). A downed mech stays down until a teammate revives it: no respawn, no bleed-out. The outcome latches; a win
is checked before a loss.

The loss has a **1 s grace** (`wipe_grace`): everyone must stay downed for that long on the shared clock. The host reads
other machines' downed flags with link delay, so a revive that lands as the last teammate falls must not end the mission.

**Who does what** (the fourth shape of AGENTS.md rule 6: host-arbitrated world state):

- `MissionRules` (`scripts/world/section/mission_rules.gd`) is a pure evaluator: no nodes, no network, no randomness.
  `MissionRules.make(section, overrides)` builds the objective list.
- The **host** feeds it facts a few times a second: `evaluate({"t": shared-clock seconds, "enemies": [alive per deck], "crew": [{peer,
  downed, deck, x, s}]})`. When it returns true the host broadcasts `state()` (`{outcome, reason, done, left, current}`) as one reliable
  event; clients call `apply_state(d)`. On `won` / `lost` the mission flow ends the mission and returns to the hangar.
- The HUD reads `text()` ("Clear deck 2: 5 hostiles left", "Reach the extraction portal") and `marker()` (`{deck, x, s}`
  of the extraction zone once the decks are clear).
- "Downed" is the mech's own decision: `PlayerTarget.disabled`, set by its owner and mirrored to the host's puppets by
  the mech stream. The revive verb belongs to combat (`docs/design/weapons.md`; starting numbers: within 12 m, a 4 s hold,
  back at half HP on every component, cold heat), applied by the downed mech's owner. The evaluator only reads the flag.

Agreed with Engine (wiring, HUD, `mission.state` event, extract on for the first demo, each enemy carries its
`spawn_deck`) and Weapons (downed flag, no auto-respawn in crew missions, the grace) on 2026-11-22.

Enemies stay on the deck they spawn on in the demo, so "spawn deck" and "where it is" are the same thing; if that changes,
the count still goes by spawn deck.
