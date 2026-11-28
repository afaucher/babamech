# The spine, the tram and the bulkhead doors

Status: design proposal 2026-11-25; **built on the 40 m plan 2026-11-27**: Missions' SectionPlan has the 10 | 14 | 6 |
10 spine, road / tram door gates and the ramp slope runs; section 3 (lane directions and markings), section 4 (bulkhead
doors, R2.11a), section 5 (tram, station) and the ramp-end rule (R2.17, "Ramp ends" below) are in on it. Environment leads the geometry; Missions owns the section plan
(lanes, gate kinds, entry, extraction). Replaces the spine / portal parts of `mission-section.md` §3, §6, §8 and
`city-ramps-and-stack.md` §9 (extraction portal) once built.

## 1. Fiction (user, 2026-11-25)
- The crew's ship docked with the station, perhaps by force. Between habitat sections are docking and cargo areas
  behind sealable blast doors, so each section can be locked down. The docking area is **not built**.
- The doors are normally open and traffic flows through. They close in an emergency, like a boarding: every **road**
  door is shut for the whole mission.
- The crew comes in through one road door and leaves through another.
- The tram normally runs round the whole ring. It has its own door, too narrow for a mech. **The train runs only while
  its own door is open**; that door can stay open in a lockdown.
- "The station is NOT designed for our game": doors, station and signs are civic fittings. No mission state on them.
- No blue curtain anywhere.

## 2. Spine cross-section: 50 m -> 40 m
Today: `ramp_a 10 | avenue 18 | rail 12 | ramp_b 10` = 50 m, a four-lane highway with two tracks, on every deck.

Proposed (same lane ids, new widths; west to east):

```
        ramp_a 10        |        avenue 14         |  rail 6  |      ramp_b 10
  service road, 2-way    |  main road, 2-way        |  tram    |  service road, 2-way
 |0.5| 4.5 v | 4.5 ^ |0.5|1| 4 v |  4 median | 4 ^ |1|1.5|3|1.5|0.5| 4.5 v | 4.5 ^ |0.5|
                                    (turn pocket)       track
   v = traffic towards +s (drives in the -x half of its road: right-hand traffic, as LifeTraffic)
   ^ = traffic towards -s
```

- **Main road, 14 m**: one lane each way (4 m), a 4 m centre strip, 1 m edges. The centre strip is the planted median
  between junctions and becomes a painted left-turn pocket for the last 28 m before each junction. 14 m is the
  arterial width, so **the spine's bulkhead door is the ordinary road door** (12.8 x 9 m clear) and the 48.8 x 14 m
  spine gates go.
- **Tram strip, 6 m**: one track on its centre line (car 3 m, 1.5 m clear each side). Only the tram deck has track; on
  every other deck the strip is a planted verge (the boulevard's tree line), broken at junctions.
- **Service roads, 10 m** (9 m between the lines the ramp parapets continue): a two-way road that carries the ramps.
  A deck has a service road in a ramp lane only if that lane has a ramp mouth on that deck (a cut going down or a
  ramp landing from above). Otherwise the lane is a **promenade**: paved, no lane lines. On the top deck `ramp_b` has
  no ramp, so its east side is promenade: that is where the station goes.
- Service roads stop 20 m short of a bulkhead wall (hatched end, no door behind it): only the main road meets a door.

Why 40 and not less: the two ramp lanes are fixed by the 9 m ramps, and the open width is where four mechs fight.
Cost: every block east or west of the spine moves 5 m, so every plan and city checksum is re-pinned once (the gate
kinds change them anyway).

### Ramp ends stay out of junctions (playtest R2.17; built 2026-11-27, see "Ramp ends" under "As built: spine markings")
Today a ramp spans whole rows, so its mouth and its parapets end on a cross line: inside the junction, on the
crosswalk. Rule: **the sloped part and its parapets end at least 8 m short of the junction box at both ends** (clear of
the zebra at 1.8-4.8 m and the stop line at 5.6-6 m, with 2 m to spare). The 8 m of flat service road between the ramp
end and the box carries the stop line and the zebra like any other approach. The plan keeps whole-row ramp spans;
the slope is fitted inside the span minus 16 m, and the plan picks enough rows that this shorter run still meets
`ramp_grade` (3 rows of 90 m: 48 m over 254 m = 0.189, so the grade limit or the row count moves: Missions' call).
A test checks every ramp end against every junction over the seed range.

## 3. Lane directions and markings
Rule everywhere: right-hand traffic, two-way roads, one lane per direction. Markings follow data the plan already has
(road kind, lane rect, junction lines, ramp rects); no new plan fields.

| Where | Marking |
|---|---|
| Main road, between junctions | solid edge lines; planted median 3 m wide in the 4 m centre strip |
| Main road, last 28 m before a junction | median ends; left-turn pocket with a left arrow; through lane with a straight + right arrow; stop line across pocket and lane; zebra behind the stop line |
| Service road | dashed centre line (as on the ramp), solid edges; straight + right arrow before each junction; stop line; no left turns (they would cross the main road's approach) |
| Service road at a ramp mouth | the ramp's own lines run on; a down arrow in the descending lane 12 m before the cut |
| Service road end at a bulkhead | diagonal hatch over the last 20 m, merge arrows towards the cross street before it |
| Cross street meeting the spine | stop line on its approach half, zebra; one combined arrow |
| Junction box | bare, except the tram track with a yellow keep-clear hatch 6 m wide, and dashed guide lines carrying the main road's edges across |
| Lift door on the spine | hatched keep-clear apron the width of the door, to the service road's edge |
| Road door (bulkhead) | hatched keep-clear box the width of the door (as today), stop line 8 m before it |
| Promenade | no road markings |

Junction, plan view (north = +s):

```
      svc_a      main road      tram  svc_b
     | v | ^ |  | v |[L]| ^ |   |T|  | v | ^ |
     |===|   |  |=======|   |   |T|  |===|   |      stop lines on the approach halves
  ---+-------+--+-----------+---+T+--+-------+---   zebra
                                 T                  cross street (two-way) runs through the box;
  ---+-------+--+-----------+---+T+--+-------+---   tram keep-clear hatch across it
     |   |===|  |   |=======|   |T|  |   |===|
     | v | ^ |  | v |[L]| ^ |   |T|  | v | ^ |      [L] = left-turn pocket
```

Life traffic: the avenue pods keep their loop on the main road with the new lane offsets; walkers cross on the drawn
zebras (today they cross on the street centre line); the rail crossing rule stays, on the tram deck only.

## 4. Doors in the bulkheads
One road door type, everywhere; two specials.

| Door | Size (clear) | Where | Mission state |
|---|---|---|---|
| Road door | 12.8 x 9 m | every road that meets an end wall, the spine's main road included | shut (lockdown). Wave gates open from the far side as today |
| Entry / exit road door | same door | spine main road: entry on the top deck's s0 wall, exit on the lowest deck (as the portals today) | entry opens at release; exit opens when the hold completes |
| Tram door | 3.8 x 4.6 m | tram deck only, both end walls, on the track | open; the train runs through it |
| Air door | 12 x 6 m at 21 m | unchanged | unchanged |

- **Low tram door** (user, 2026-11-26): the tram door is tram-sized, 3.8 m wide and 4.6 m high (car 3 x 3.2 m),
  beside the 9 m road door. A Strider's 4.4 m capsule does not fit by width, and no mech fits by height.
- Road doors look and move like the wave gates the user picked (bunker frame, sliding ribbed leaves, siren and lamps
  only while moving). No lock lamps, no progress display.
- **Entry and exit bays**: behind each is the standard bay (20 m wide inside, 26 m deep, floor, roof), closed at the
  back by a static inner blast door: the docking side. The crew spawns inside the entry bay (two columns 10 m apart,
  rows at 10 m and 18 m) and walks out when the door opens. Missions decides when it shuts again (proposal: once the
  bay is empty) and when the exit opens; the win volume is the exit bay.
- **Tram tunnel**: a 3.8 m wide, 4.6 m high, 40 m deep dark recess with walls, floor, roof and a back plate; the cars run on
  through the plate out of sight. The map stays sealed with the door open (`test_map_sealed` sweeps it).
- "collapsed" stays a shut road door that never opens. The `portal` kind, `MissionProps.Portal`, the curtain,
  `set_portal` and `portal_event` are removed.

## 5. Tram and station (built 2026-11-27, see the end of this section)
- **One deck**: the top deck (deck 0). Its `ramp_b` lane is free of ramps, so track and station sit east of the main
  road without touching a ramp.
- **One track, one direction**: a ring line. A train comes in through the s0 door, stops at the station (20 s), leaves
  through the s1 door, and the next one arrives a fixed period later (proposal 120 s). No turning back, no second
  track.
- **Door link**: the train moves towards a tram door only while that door is open. Shut ahead: it brakes and waits
  5 m short. Shut behind (the door it would arrive through): no train arrives. Door changes are host events with a
  time on the shared clock; the train's position stays a pure function of plan + clock + those events (the existing
  halt episodes), so every machine agrees. Missions default: both doors open. The lab can shut either.
- **Station**: one platform on the promenade side of the track, 32 x 3.5 m, 0.35 m high, in the spine segment nearest
  the deck's middle. Existing street lamps and benches in a row, a small low back wall and a station name sign (pick:
  cell 7), placed from the plan seed, part of the layout checksum. Solid and low: a mech steps onto the platform and walks through nothing.
- **In a fight**: cars are solid cover as today; the crush rule stays (60 per leg, once per pass). Damageable cars are
  not in this pass.
- Other decks: no track, no tram, no rail crossing rule.

**Built 2026-11-27 (Environment, R2.11; tram + station, uncommitted).** Everything above is in; details in
`ambient-life.md` "Tram (R2.11)" and `city-props.md` "Station".
- `LifeTram` (`scripts/world/life/life_tram.gd`): deck 0 only (`make` returns null elsewhere and on a district on its
  own), on the centre line of `lane_x("rail")` (width-agnostic). One way: a train starts hidden 10 m behind the s0
  tunnel's back plate (40 m behind the door plane) at 14 m/s, stops 20 s with its middle car at the platform's centre,
  leaves into the s1 tunnel and parks once wholly behind its plate. Pass 78.8 s on the default deck (540 m), so the
  period is 120 s (`period = max(PERIOD 120, ceil(pass + GAP 20))`). One train at a time: a slot that comes while the
  previous train has not parked is skipped.
- Door link: `AmbientLife.set_tram_door(end: String, open: bool, at: float)` (end "s0" | "s1"; no call: both open)
  -> `LifeDeck.set_tram_door` (host / offline; a client's call does nothing) -> `LifeTram.set_door(end, open, at) -> bool`,
  sent to the crew as `life.door` {end, open, t, deck}, in the life snapshot (`LifeTram` snapshot version 2). A door is
  usable 3.0 s (`DOOR_OPEN`) after it starts opening. Shut ahead: brake (1.2 m/s^2, up to 2.5 if it must) and wait with
  the nose 5 m short of the plane; shut behind: the next train waits in the tunnel behind it (out of sight), so none
  comes in; reopened: it comes in once the door is fully open. A train too close to stop when a door shuts in front of it
  runs through (committed): MissionWorld should shut a tram door only when `AmbientLife.tram_door_clear(end)`.
  Queries: `AmbientLife.tram()`, `tram_door_open(end)`, `tram_door_clear(end)`.
- Station: `CityStation` (`scripts/world/city/city_station.gd`): platform against the rail lane's east edge in the
  `ramp_b` lane, in the spine segment nearest the deck's middle with 8 m to both junction boxes, clear of cuts, ramps and
  kept-clear ground; a 0.8 m back wall (top 1.15 m over the street); 4 street lamps and 4 benches (the existing props,
  appended last to `CityPropLayout.layout`, so in its checksum); a name board (the deck signs' dark panel, a name from
  the cosmetic seed in CitySigns' stencil letters) standing on the wall. Collision: platform and wall boxes per floor
  facet, a rounded box for the board, meta `col_kind` "station".
- Collision: the cars are `CityGeo.rounded_box`es (the collision survey no longer lists `tram_car` as known).
- Not built: walkers waiting on the platform (no walk edge reaches it; the crowd only uses block / park / plaza
  benches). On the 40 m plan the rail lane is 6 m, so the platform edge is 1.5 m from the car side.

## 6. What changes where
- **Missions (SectionPlan)**: lane widths 10 / 14 / 6 / 10 (`SPINE_W` 40); rail strips only on deck 0 (kind `verge`
  elsewhere); gate kinds `road_door` (with `role` entry / exit / none) and `tram_door` replacing `portal`; spine-end
  gate width 14; entry / exit / arrival / departure in front of the road doors; extraction zone = exit bay front.
- **Environment** (file layout of 2026-11-26): `scripts/world/city/`: `CityStreets` (spine drawing, all markings,
  verge, ramp ends), `CityWalls` (road door and tram door openings, tram tunnel), `CityDistrict` (collision),
  `CityStack` (spawn in the bay), `CityProps` / `CityPropLayout` (station fittings), `CitySigns`.
  `scripts/mission/world/`: `MissionWorld` + `MissionGateDoor` (entry / exit doors and bays, tram door state);
  `MissionPortal` is deleted. `scripts/world/life/`: `LifeTram` / `LifeTramCars` / `LifePlan` / `LifeDeck` /
  `AmbientLife` (one deck, one-way, door link). Tests and docs.
- **Engine**: spawn points, bot "hold then walk out", `test_tram_portal`.

## 7. Open questions for the user
1. ~~Tram door height.~~ **Decided: low tram-sized door, 3.8 x 4.6 m**, road door 9 m (user, 2026-11-26).
2. ~~40 m spine as above, or keep 50 m and only repaint?~~ **Decided: 40 m** (user, 2026-11-26).
3. ~~Tram door look.~~ **Decided: "match the existing design"** (user, 2026-11-26; grid `city-spine/grid_tram_door.png`,
   closest cell 1): a scaled-down road door: the same projecting concrete bunker frame and the same sliding ribbed
   leaves, so it opens and shuts. No new style. Its state drives the train. To be exact (user): the same door as the
   road doors, "just a different size" (3.8 x 4.6 m): same frame, leaves, materials, siren and lamp behaviour; nothing
   else from the grid cell is used.
4. ~~Station look.~~ **Decided: cell 7** of `city-spine/grid_station.png` (open, kerb platform; user, 2026-11-26),
   the simplest: "7 is just some basic lights and benches. Both of which we have. Just arranged with a small wall."
   Built from existing props only: the street lamps and benches we have, along a raised kerb platform with a small
   low wall, plus a station name sign. No canopy, no glass shelters, no new prop kit, no ticket machine.

## As built: spine markings (R2.11 / R2.17, 2026-11-27)
Built on today's plan (`ramp_a 10 | avenue 18 | rail 12 | ramp_b 10`) from `section.lane_x()` and the spine road's
`lanes` only, so the same code draws the 40 m spine when Missions changes the widths (nothing hard-codes a position).
Code: `CityStreets.spine_layout(plan)` lays every marking out as data, `CityStreets._spine` draws it
(`scripts/world/city/city_streets.gd`, "The transit spine"); shared numbers in `CityDims` (`city_dims.gd`).

**Main road split** (`CityDims.avenue_split(w)`): 1 m edges, the rest lane | centre strip | lane in 1 : 1 : 1 with the
lanes capped at 4.5 m and the surplus going to the centre strip: 14 m -> 1 | 4 | 4 | 4 | 1, 18 m -> 1 | 4.5 | 7 | 4.5 | 1.
`CityDims.avenue_lanes(av)` gives the two lane centres; the paint and `LifeTraffic._make_avenue_loop` both read it. The
planted median is at most 3 m wide (`avenue_median`), so bots and spawn columns that keep 1.5 m off the centre line hold.

| Where | As drawn |
|---|---|
| Main road | solid edge lines and centre-strip lines; median from 28 m after one box to 28 m before the next (a white hatched nose where the pockets meet instead); per approach: stop line across lane + pocket 5.6-6 m before the box, zebra 1.8-4.8 m, a straight + right arrow in the lane and a left arrow in the pocket 11.5 m before the box; dashed guide lines carry the edge lines across every box |
| Road door | stop line 8 m before the end wall across the door-bound half, as far as the door reaches (the hatched box is `CityWalls._gate`'s, the door's width) |
| Tram strip, deck 0 (`CityDims.has_track`: deck 0 and the spine road's rail lane of kind "rail", `CityPlan` copying `SectionPlan.lane_kind` onto each lane) | one track on the strip's centre line through everything, ballast 4.4 m (less on a narrow strip), a yellow keep-clear hatch over the strip in every box |
| Tram strip, other decks | planted verge (the median's slab and lawn), 7 m clear of each box, a tree line on it (as the median's) |
| Service road (a ramp lane with a ramp part on the deck) | gutter on the spine's outer edge, the ramp's own edge lines (0.9 m in) and dashed centre line on every stretch the ramp does not take; per free approach: stop line on the approach half, zebra, a straight + right arrow; **down** arrow instead in the descending lane before the junction the ramp leaves from; **merge** (bend right) arrow instead before the last junction ahead of an end wall; over its last 20 m before an end wall (the 8 m between the perimeter road and wall + 20 m) a white hatch closed by a bar, no stop line, zebra or arrow there |
| Promenade (a ramp lane without one) | sidewalk paving with bands, no markings (the station stands on deck 0's) |
| Cross street meeting the spine | its own stop line and zebra (`_road`, unchanged) plus one combined arrow in its approach lane |
| Lift door facing the spine | yellow hatched apron on the sidewalk / plaza, the door's 10 m wide, from the door face to the curb |

Zebras are per roadway: only on the main road and the service roads (none over the track, the verge or a promenade).
Arrows are flat glyphs (`CityStreets.arrow` / `arrow_polys`: straight, left, right, straight_right, combined, down,
merge; 3-12 triangles each), split at the deck's facets like every marking; they stay in the ground mesh at every quality
level. Life: avenue pods on `avenue_lanes`; walkers cross the spine on the +s zebra beside each inner junction (the -s
one when that would cross a cut or kept-clear ground; `LifePlan._spine_zebras`); the rail crossing rule only on the deck
with track. Shots (seed 4, deck 0 = tram deck + promenade, deck 1 = two service roads + verge): `city-spine/spine_top_d0.png`,
`spine_top_d1.png`, `spine_cross_d0.png`, `spine_cross_d1.png`, `spine_ramp_mouth.png`, `spine_door.png` (lab cameras
`spine_top`, `spine_cross`, `spine_ramp`, `spine_door`). Test: `tests/test_spine_markings.gd`.

**Ramp ends (R2.17), as built 2026-11-27 on the 40 m plan.** The plan fits each ramp's slope inside its whole-row span:
connector `run_top` / `run_foot` (angles), `SectionPlan.ramp_end_inset(j)` = that cross road's half width +
`RAMP_END_PAST_BOX` 6 m from the cross line centre at each end (13 m on a 14 m cross road, 12 m at a perimeter road),
grade limit 0.20 on the run (steepest fitted 0.1956). So **every slope and its parapets end 6.0 m past the junction box at
both ends** (test_ramp_walk prints it: 6.00 m on every ramp of seeds 1, 2, 4, 9), clear of the zebra (1.8-4.8 m) and
level with the stop line (5.6-6 m): 6 m of flat service road between box and slope, not the 8 m proposed above.
- `CityPlan._make_ramps` slopes over the run (was: cross line centre to centre, the floor cut starting at the run left a
  ~1.4 m lip at every mouth); every `CityPlan.ramps` part carries `run_top` / `run_foot` in its deck's s, so its
  `s_top` / `s_foot` lie on the run and every reader of them (drawing, `CityDistrict._ramp_collision` with its end
  blocks, `END_GUARD`, the sunk-mouth guards `SUNK_DROP` and `_parapet_points`, `CityGraphs.court_open`, `floor_cuts`,
  `bridge_allowed` / `_bridged` / `bridge_clearance`, `CitySigns` hung ramp signs, the lab ramp cameras, `CityStation`,
  `BannerPlan`, `SiteFit`, `MissionAirDoors`, and the enemy / bot readers of `CityPlan.ramps`) follows with no code of
  its own. `CityDims.RAMP_INSET` and `ramp_part` are gone; `CityDims.ramp_run(plan, r)` returns the part's run.
- The mouth is the floor cut's plain open edge 6 m past the box; `floor_cuts()` no longer reaches into the cross road, so
  the cross road keeps its full edge (walk / road graph edges across it come back).
- Probed with physics (`tests/test_ramp_walk.gd`, seeds 1, 2, 4, 9, every ramp): rays down the lane across the mouth and
  the foot hit the floor then the slope with no lip or gap (0.15 m tolerance); a real Strider and a real Bulwark walk
  from 20 m before the mouth down to 16 m past the foot and back up, never stuck 2 s, never under the slope, deck changing
  once. The drawn ribbon's ends, the parts' ends and the floor cut's mouth are asserted equal (test_ramp_walk,
  test_spine_markings). test_city_stack / test_city_stack_walk measure the slope from `run_top` / `run_foot`.

**Spine trees (2026-11-27, done):** `CityPropLayout._spine_trees` puts a tree line down the middle of every rect of
`CityDims.spine_planted` (medians and, on decks without track, the tram strip's verges), 2 m in from each end, about 15 m
apart (as the avenue median's), from their own generator (`props_seed() + 3`), after the roof units and before the
station fittings; the old 12 m-after-the-box median trees are gone on a section (their generator draws are kept, so the
blocks, lots, alleys and forms lay out as before; stand-alone districts unchanged). No street prop stands on a lift door's
apron (`CityDims.lift_aprons`, which `CityStreets` paints). `test_spine_markings` checks every prop against the paint.

## As built: bulkhead doors (2026-11-27, R2.11a)
- Works with today's plan (50 m spine, `portal` / `blast_door` spine gates, no tram doors) and with Missions' coming one
  (`road_door` with a role, `tram_door`): `CityWalls.section_gates` (through `CityPlan.boundary()`) makes every spine-end
  gate a 14 m road door (12.8 x 9 m clear) on the avenue lane's centre, the rest plain wall; deck 0 gets a tram door in
  both arc-end walls on the rail lane's centre when the plan names none. Widths come from the plan / lanes, never 50.
- Road doors, entry / exit doors, tram doors: one class (`MissionGateDoor`), the tram door scaled (`tram_config`). No
  marking of role on any door; no curtain; `MissionPortal`, `portal_event` gone; `set_portal` a deprecated stub.
- Entry / exit bays, crew spawn in the entry bay (once the mission world is set up), `ENTRY_OPEN_DEFAULT`, `bay_contains`,
  `shut_source`, no-jump re-orders, moving leaves never solid, tram tunnel (40 m, sealed), `set_tram_door` ->
  `AmbientLife.set_tram_door`: `city-ramps-and-stack.md` §9 "Bulkhead doors".
- Tight spine (40 m plan, verified 2026-11-27 on the real plan, seeds 1-30, `tests/test_door_fit.gd`): the road door and
  the tram door stand 1.7 m apart clear-to-clear. Their frames meet as one pier, the road door's sign pier moves to its
  free side, both road-door leaves slide to the free side (open, clear of the opening, their pockets clear of the tram
  tunnel), and the entry bay (22 m inside, 20 m usable) moves 5.8 m sideways off the tram tunnel (`MissionWorld.door_fit`,
  `plan_bay_span`). The plan's `road_door` / `tram_door` gates reach `CityWalls.section_gates` as they are (no derived
  doubles); other spine ends (`blast_door`, role "none") are ordinary 12.8 x 9 m wave gates.
- Bay slots (`MissionWorld.slot_layout`, 2026-11-27): laid out for the Bulwark (r 3.6), columns 7.4 m apart as near the
  door's centre line as the bay allows, rows 11.6 / 20.4 m; in the off-centre entry bay the far column steps back
  (14.0 / 21.4 m) and both its slots face a point on the door plane so a straight walk passes the opening (frame X, door
  centre 0, bay -16.8..5.2 on seed 1: (0.6, 11.6) straight, (-6.4, 14.0) aim 0.9, (0.6, 20.4) straight, (-6.73, 21.4)
  aim 0.3). Swept with both capsules from every slot to 6 m past the door on seeds 1-30 (`tests/test_bay_walkout.gd`).
- Shots: `city-spine/door_entry_shut.png`, `door_entry_opening.png`, `door_entry_open.png`, `door_exit_shut.png`,
  `door_tram_open.png`, `door_tram_shut.png` (lab `--city site=stack,seed=1,deck=0,mission=doors,mission_phase=<shut|open>,camera=<entry_door|exit_door|tram_door>`).

## As built: lift cars (2026-11-27, R2.22)
- Every freight lift door (critical lifts beside the spine and the express lift) opens on a real car in a mission: 16 m wide x
  18.5 m deep x 10 m high inside (usable 14 x 16 x 9.6 m), a hollow in the pillar core (cores are 25.1-25.7 x 28 m on
  every lift of seeds 1..200). Doorway 10 x 9 m. Without a mission the core stays solid with its doors baked shut.
- No countdown lamps or green "go" row any more (the station is a real place): a plain call panel on the jamb; the doors'
  motion is the tell.
- Details, API and tests: `city-ramps-and-stack.md` §9 "Lift cars". Shots: `city-spine/lift_shut.png`, `lift_open.png`
  (lab `--city site=stack,seed=1,deck=1,mission=doors,mission_phase=<shut|open>,camera=mission_lift`).
