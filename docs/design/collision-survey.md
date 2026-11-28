# Collision survey (playtest backlog R2.25a, 2026-11-26/27)

Where a mech gets stuck against the world's collision, by collider kind, and what was changed. Environment subagent.
Absorbs R2.19 (low box corners) and R2.23 (stuck on a supply depot).

## How it was measured

- Harness: `scripts/test_support/stuck_probe.gd` (`StuckProbe`, tests only), shared with `tests/test_ramp_stuck.gd`.
  The real mech (`MechSpawn.make`: `MechController`, its capsule, step-up and move_and_slide settings) is stepped by
  hand at 60 Hz (deterministic). From a start point it walks 1 s into a target, rests, lands if it walked off an edge,
  then is driven 0.5 s each way along the two faces' normals (+u, -u, +v, -v) and back toward its start. A way counts as
  free at 0.5 m of progress. **Cornered**: free in fewer than 2 of the 4 ways (a dead-end nook does that). **Pinned**:
  cornered and it cannot even walk back the way it came. Only pins are findings.
- Sweep: `tests/test_collision_survey.gd`. The real stack (`CityStack`, default options) of section seeds 1, 2, 4, 6, 9
  and 22, all 3 decks (curved ring decks), with the real mission on it (`MissionPlan.make`, `CityStack.setup_mission`:
  wave gates and staging bays, air doors, lift doors, flag mast, defend relay; supply depots where
  `MissionDepots.place_on` puts them). Every enabled box / convex collision shape is grouped by kind (district shapes
  carry meta `col_kind`; mission pieces by their body). At each exposed vertical corner (the hull of its footprint turns
  by more than 25 deg, the point just outside it is in no collider, the corner rises 0.35 m or more) the Strider
  (r 2.2, h 8) and the Bulwark (r 3.6, h 8) each walk in from the diagonal, from along each face, and off the top.
  Full survey: up to 80 corners per kind and deck (`BABAMECH_SURVEY=1`); the regression test: seeds 9, 22, 4, up to 10.
- Tram cars are only solid while stopped, so a static copy of a car's box (3 x 3.3 x 9 m) is probed on a clear plaza.
- Street props (trees, lamps, benches, bins, sign posts, roof units) have **no physics collision** (CityProps: they
  topple and are shoved, they never block a mech). Signs (`city_signs.gd`): no collision. Lift doors: no collision (the
  pillar core is solid). The cordon barricades (`life_barriers.gd`) had no collision and are being removed from the game.

## The mechanism

Measured with single shapes on a plaza of a real deck (tops in m over the mech's feet):

| shape | Strider | Bulwark |
| --- | --- | --- |
| box, top 0.8 - 2.2 | 0 pins | 0 |
| box, top 2.4 - 5.8 | pins (all 4 ways and back: 0.0 m) | pins at 3.6 - 4.4 |
| box, top 6.2 and up | 0 | 0 |
| same box, vertical edges rounded with true cylinders (r 0.15 - 0.6) | 0 | 0 |
| same box, edges filleted as a convex polygon (1-3 facets, r 0.15 / 0.4) | pins (as many or more) | pins |
| any top edge level with the capsule's equator (its radius over the feet, +-0.05 m) | pins, rounded or not | pins |

1. **The pin band.** A capsule walking round a vertical box corner whose top lies on the capsule's straight
   (cylindrical) side is pinned there: Strider 2.2 - 5.8 m, Bulwark 3.6 - 4.4 m over its feet. (The ramp-end work
   estimated 1.25 m as the lower bound; 1.4 - 2.2 m boxes pinned nothing here.) Polygon facets do not help, true
   cylinders do.
2. **The equator edge.** A top edge exactly at the capsule's radius over its feet (2.2 m Strider, 3.6 m Bulwark) pins it
   whatever the corner shape. Found once in the world (sinking ramp parapets, below).
3. **Off the top.** A mech that jumped onto a narrow top (a relay cabinet, a podium edge) can perch or drop into a gap
   narrower than its capsule. These need a jump to reach.

## Findings by kind (full survey, 6 seeds, both capsules)

"Before" is the original collision (the first pass, pinned = cornered in fewer than 2 ways, so dead-end nooks counted
too; the second pass with the back-way rule is in brackets where it differs). "After" is with every fix below.

| kind | corners (full) | probes after | pinned before | pinned after | cause | example (seed / deck / corner x, s) |
| --- | --- | --- | --- | --- | --- | --- |
| tier_upper (roof bulkheads, setbacks) | 2994 | 4465 + 2638 off top | 156 (124) | 1 + 2 off top | pin band on a roof | 1 / 0 / (-7.8, 241.4) |
| tier_ground (building bases, podiums) | 3814 | 4463 + 1210 off top | 62 (14) | 7 walking, 7 off top | gaps 4.0-4.2 m between buildings (narrower than the Strider); drops off 6.5 m podiums | 2 / 1 / (117.7, 123.6) |
| depot | 124 | 744 + 248 off top | 22 (13) | 0 | pin band (4.35 m box); fixed by Missions | 2 / 0 / (-99.5, 28.0) |
| solid_column (arcade, portico) | 360 | 3963 | 12 (10) | 0 | Bulwark wedged on box column corners | 2 / 2 / (-14.4, -192.7) |
| tram_car (synthetic) | 24 | 72 | not swept | 5 | pin band (3.3 m box); not fixed | 2 / 0 / (10.5, 67.1) |
| relay | 16-48 | 193 + 55 off top | 1, +3 of 28 synthetic | 0 walking, 2 off top | pin band (5.2 m box), 0.5-0.7 m past drawn | 22 / 1 / (-99.1, -260.9) |
| parapet (sinking ramp mouths) | 4178 | 2480 | 0 full, 1 in the regression sample | 0 | top edge at the Strider's equator | 9 / 0 / (-70.0, 176.0) |
| solid_skylight | 1352 | 2257 (ledges) | 6 (1), all off top beside bulkheads | 0 | (the bulkheads) | 1 / 1 / (-97.0, 269.9) |
| pier | 1056 | 752 | 4 (0) | 0 | dead-end nooks under a ramp, not pins | 1 / 1 / (-64.0, -35.7) |
| flag_mast | 128-384 | 936 | 0 | 0 | base 1 m past drawn (a) | - |
| gate, air_door, ramp_end, ramp_deck, hole_curb, column (park) | 212-4850 each | 42-2480 each | 0 | 0 | - | - |

Counts differ between passes where the corner rule changed (convex shapes' tops) and fixed shapes add corners (a
rounded box's two boxes); "probes" is approaches that met the corner. Residuals after the fixes: tier_upper 1 (seed 1,
deck 2, (100.3, 302.3) on a roof at 15.5 m: it creeps 0.3 - 0.5 m every way, slow rather than held), the tier_ground gap
wedges and the off-the-top pins (below), and the tram car.

### Per kind

- **Roof bulkheads and setbacks (`tier_upper`)**: the worst. A roof's 2.4 m plant room, an apartment's 2.8 m stair
  bulkhead, a 3.2 m one-floor setback: tops in the Strider's band over the roof it stands on. Example: seed 1, deck 0,
  corner (-7.8, 241.4), roof at 19.7 m, top 22.1 m: a Strider walking into it rests at (-8.19, 239.10) and moves 0.0 m
  every way. Collision matches the mesh; the shape is the problem. **Fixed** (rounded edges).
- **Supply depots (`depot`)**: the 6 x 4 x 4.35 m box, top in both bands (R2.23). Example: seed 2, deck 0, corner
  (-99.5, 28.0). **Fixed by Missions** (their own probe, `tests/test_supply_depot.gd` G): one convex shape over the
  visible footprint with a flat top at 6.2 m. Now 0.
- **Arcade / portico columns (`solid_column`)**: a Bulwark squeezing past an arcade's 1.2 m box columns (8 m clear
  between, its capsule 7.2 m) wedged on a column corner and could not back out. Example: seed 2, deck 2, corner
  (-14.4, -192.7), rests (-10.80, -194.01), free only +v 1.26 m. **Fixed** (rounded edges).
- **Building bases (`tier_ground`)**: walking round, 7 pins, all at the mouth of a gap between two buildings 4.0 - 4.2 m
  wide, narrower than the Strider's 4.4 m capsule: it walks into the mouth and wedges between the two corners (seed 2,
  deck 1: buildings at s 113.1-123.6 and 127.9-142.3, x 96.5-118, a Strider at (118.18, 125.74) free only one way;
  seed 1, deck 0: s 238.2 / 242.2 at x 79.5-102, 4.0 m). Collision matches the mesh; the layout makes the slot. Off the
  top of 6.5 m podiums: mechs dropping into such gaps (7). Not fixed: see "For other owners" (layout).
- **Defend relay (`relay`)**: one 4.2 x 5.4 x 4.2 m box: 0.5 - 0.7 m past the drawn cabinet above the 1 m plinth
  (finding a), its corners' 5.2 m top in the Strider's band (b): the synthetic probe pinned 3 of 28 approaches.
  **Fixed**: plinth box (top 1.0) + the cabinet at its cap's outline (3.2 m, to 4.25 m) with rounded edges. Left: a
  Strider that jumps onto the 3.2 m cabinet top can perch there (off the top, see "Off the top").
- **Flag mast (`flag_mast`)**: no pins, but its base was one 3.6 x 1.6 m box standing up to 1 m past the drawn upper
  steps (a). **Fixed**: the three drawn steps (each under 0.6 m) and the pole.
- **Sinking ramp parapets (`parapet`)**: where a ramp sinks into a floor hole, the parapet guard (2.5 m over the ribbon)
  has its top edge pass 2.2 m over the deck beside it: the equator edge. Seed 9, deck 0, ramp x -70..-60, s 180 (mouth):
  a Strider on the deck at (-72.2, 178.3) next to the 0.5 m hole curb was pinned (only one way free, not back).
  **Fixed**: a mouth guard over each parapet, END_GUARD (6.5 m) tall like the end blocks, from the mouth until the
  ribbon is 0.8 m below the deck (the crossing is inside it; its end face is 1.7 m over the deck).
- **Piers under ramps (`pier`)**: 4 cornered spots (seeds 1, 2, 4, deck 1, beside a pier near a ramp foot, under the
  soffit) in the first pass; all walk back out: dead-end nooks, not pins.
- **Skylights (`solid_skylight`)**: 0.4 m curbs, never pinned walking round; the off-the-top pins were mechs on roofs
  next to bulkheads (fixed with those).
- **Ramp ends, gates and staging bays, air doors, hole curbs, park columns and rings, ramp decks**: 0 pins.
- **Tram cars (`tram_car`, synthetic)**: the 3 x 3.3 x 9 m box, top in the Strider's band: 2 pins of 24-46 approaches
  per run. Not fixed (not my file): see "For other owners".

### Collision past the drawn mesh (finding a)

- Relay: fixed (above). Flag base: fixed (above). The relay cabinet's collision follows the cap (3.2 m), 0.2 m outside
  the drawn 2.8 m cabinet under the cap's overhang.
- Ramp parapets (2.5 m over the 1 m drawn), end blocks and now the mouth guards (6.5 m over the 1.3 m / 1 m drawn) are
  invisible on purpose (a mech must not step over a parapet; a corner must clear the capsule).
- Building tiers, solids, gables, columns, walls, gate frames: built from the same numbers as their meshes (no
  overhang found). The rounded edges cut at most 4 cm (r 0.15) off a drawn corner's diagonal.

## Fixes (collision only: meshes, plans, checksums and geometry digests unchanged)

- `scripts/world/city/city_geo.gd`: `PIN_LOW`, `PIN_HIGH`, `ROUND_R`, `rounded_box()` (two crossing boxes and a cylinder
  in each corner: flush with the box's faces), `in_pin_band()`.
- `scripts/world/city/city_district.gd`: building tiers whose top is in the pin band over the ground or roof they stand
  on, and every `column` solid, use `rounded_box` (`_rounded`); sinking ramps get a mouth guard (`SUNK_DROP`); every
  collision shape carries meta `col_kind` (the survey's grouping; nothing reads it at runtime).
- `scripts/mission/world/mission_relay_asset.gd`: plinth box + rounded cabinet (was one 4.2 x 5.4 x 4.2 box).
- `scripts/mission/world/mission_flag_mast.gd`: the stepped base as drawn (was one 3.6 x 1.6 x 3.6 box).
- No change needed in `mission_gate_door.gd`, `mission_lift_door.gd`, `mission_props.gd`, `city_props.gd`,
  `city_signs.gd`, `city_walls.gd`, `city_streets.gd`.

Rounding vs full height (Missions measured rounded corners WORSE on their depot, 73 traps vs 17): on the stack's curved
decks this harness found rounded tiers remove the pins (tier_upper walking round: 120 of 6681 probes before, 1 of 4465
after, full survey; the regression sample with the rounding switched off pinned 7 of 264, with it 0; arcade columns
10 of 2010 before, 0 of 3963 after), and rounded boxes stayed at 0 on every height tried except the
equator edge. A likely difference: rounded corners still pin wherever a top edge sits at a capsule's radius over its
feet, which a 4.35 m roof on a sidewalk-high pad is close to for the Bulwark (3.6 m + feet). Full height was not used for
tiers because a 2.4 m roof bulkhead would need an invisible column to 8 m over a roof.

## Needs sign-off

None of the fixes changes what is drawn or the shape of play. Two invisible-collision additions, in the spirit of the
existing END_GUARD: the mouth guards (6.5 m posts over the first metres of a sinking ramp's parapets: a mech can no
longer jump over the parapet there into the hole, which the 2.5 m guard nearly prevented already).

## For Missions

- Depots: fixed on your side (0 pins of 992 / 512 probes). Nothing more.
- Placement could keep objective sites and depots off narrow plaza nooks, but the survey found no pin caused by
  placement.

## For other owners

- **Tram cars** (`scripts/world/life/life_tram_cars.gd`, whoever owns ambient life): the car's box (3 x 3.3 x 9 m) has
  its top in the Strider's band: a Strider walking round a stopped car's corner is pinned (2 of 24 approaches per seed
  in the synthetic probe). Proposed fix: build the car's collision with `CityGeo.rounded_box(body, IDENTITY,
  Vector3(0, CAR_H * 0.5 + 0.1, 0), Vector3(CAR_W, CAR_H, CAR_L))` (drawn car is a rounded loft anyway), then drop
  `tram_car` from `KNOWN` in `tests/test_collision_survey.gd`. Note `_touching` / `_blocked` query the car shape; they
  would take the 6 shapes or keep a box for queries.
- **Mech (R2.25b, the controller's stuck safety net)**: what collision alone cannot remove: perching on a jump-only top
  (the relay cabinet's 3.2 m top, podium edges) and a Bulwark dropping into a gap between buildings narrower than its
  capsule (layout: alleys and setback gaps under 7.2 m), and any equator edge. Counted in the test as `<kind>_top`
  (known, not failed).
- **Layout (Environment, a later task)**: gaps between neighbouring buildings narrower than a capsule. Walking: 4.0 -
  4.2 m slots wedge a Strider at their mouth (7 pins in the full survey). From roofs: gaps under 7.2 m catch a falling
  Bulwark. Two ways out: (1) a plan rule, gap 0 or at least 7.5 m (changes layouts and checksums), or (2) collision
  only: an invisible plug across any gap narrower than 4.6 m, flush with the two facades, full height (a mech cannot use
  such a slot anyway; it would be collision where nothing is drawn: needs sign-off). Counted in the test as
  `<kind>_gap` (known, not failed).
