# The spine, the tram and the bulkhead doors

Status: **design proposal, 2026-11-25, nothing built.** Environment leads the geometry; Missions owns the section plan
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

### Ramp ends stay out of junctions (playtest R2.17)
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

## 5. Tram and station
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
  the deck's middle. Shelters, a name / deck sign, a ticket machine: civic fittings, placed from the plan seed, part
  of the layout checksum. Solid and low: a mech steps onto the platform and walks through nothing.
- **In a fight**: cars are solid cover as today; the crush rule stays (60 per leg, once per pass). Damageable cars are
  not in this pass.
- Other decks: no track, no tram, no rail crossing rule.

## 6. What changes where
- **Missions (SectionPlan)**: lane widths 10 / 14 / 6 / 10 (`SPINE_W` 40); rail strips only on deck 0 (kind `verge`
  elsewhere); gate kinds `road_door` (with `role` entry / exit / none) and `tram_door` replacing `portal`; spine-end
  gate width 14; entry / exit / arrival / departure in front of the road doors; extraction zone = exit bay front.
- **Environment**: `CityStreets` (spine drawing, all markings, tram door, tunnel, verge), `CityDistrict` (collision),
  `MissionWorld` / `MissionProps` (entry / exit doors and bays, tram door state, portal removal), `CityStack`
  (spawn in the bay), `LifeTram` / `LifeTramCars` / `LifePlan` / `AmbientLife` (one deck, one-way, door link),
  station, `CitySigns`, tests, docs.
- **Engine**: spawn points, bot "hold then walk out", `test_tram_portal`.

## 7. Open questions for the user
1. ~~Tram door height.~~ **Decided: low tram-sized door, 3.8 x 4.6 m**, road door 9 m (user, 2026-11-26).
2. ~~40 m spine as above, or keep 50 m and only repaint?~~ **Decided: 40 m** (user, 2026-11-26).
3. Tram door and station look: 3x3 grids to follow.
