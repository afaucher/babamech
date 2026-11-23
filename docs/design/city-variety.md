# City variety: cheap changes

Decision (user, 2026-11-23): "Let's add the downtown district as well as the cheap variety changes." Downtown is in
`city-downtown.md`. This doc is the cheap set: road variety and per-building variety. Built after downtown lands (same
files).

## 1. Road variety

Today: the 20 m avenue and 12 m streets on a uniform grid. Add four minor forms, chosen by seed; the avenue, the
section's spine / arterial lines, ramp lanes and every street a ramp, floor cut or wall gate sits on never change.

| Form | What | Width | Mechs |
|---|---|---|---|
| **Lane** | A cross street narrowed to one traffic lane, no parking, narrow walkways, buildings step closer | 8 m | Pass in single file |
| **Alley** | A service lane cut through the middle of a block: no walkway, back doors, bins, pipes, a drain line | 7 m | Pass, tight (capsule 4.4 m): an ambush space |
| **Pedestrian street** | A street closed to vehicles: paved in the plaza colour, trees, planters and benches down the middle, no curbs | 12 m | Walk it; the furniture is knockable props |
| **Superblock** | A street removed between two blocks; the gap becomes a court or small plaza inside one large block | - | Enter from the court's openings (8 m or more) |

Rules (plan data, in the checksum, tested):

- About a third of the minor streets of a deck take one of these forms; no two parallel neighbours take the same one.
- The road graph stays connected for vehicles after closures (pedestrian streets and superblocks remove vehicle edges);
  every block keeps vehicle access on at least one side.
- Every alley and court opening is at least 7 m wide between collision faces at mech height (buildings lean together
  with height on the ring: measure at 8 m, not at the ground), has two ends (no dead ends), and is in the mech-walkable
  area; alleys are not vehicle or pedestrian routes in v1.
- Downtown blocks may take alleys and pedestrian streets; the through-view rule there counts them.
- Stand-alone districts: one param `road_variety` 0..1 (default 0.33). The stand-alone golden checksums change on
  purpose and are re-captured.
- Section decks: cross lines and their widths come from the SectionPlan (Missions' file). Alleys and courts are inside
  blocks, so they are city-side. Narrowing or closing a section line needs the section's road graph to agree: propose the
  rule to Missions before building that part, and until then apply lanes / pedestrian streets / superblocks only where
  the section marks a line as minor and non-routed.

## 2. Building variety (looks only, no checksum change)

- **Tint**: each building's body colour shifts a little in hue and value from its style's tone (seeded, cosmetic
  stream), so a row of apartments is not one colour.
- **Second colourways**: each style gets one more body / trim pairing from the palette (e.g. sky-blue apartments, sand
  offices with teal glass).
- **Ground floors**: more shopfront variants (awning shapes, sign fascia colours, recessed entrances, a corner entrance
  on corner lots).
- **Street character per form**: lanes get wall lamps and hanging signs instead of street trees; alleys get bins,
  pipes and back doors; pedestrian streets get planters, benches and string lights (emissive geometry, no Light3D).
- Stays "occupied, not damaged": no dirt, cracks or rubble.

## 3. Budgets and checks

- Triangles per deck within 5 % of today for section 1 and 4 decks; build chunks under about 20 ms.
- Life: pedestrians keep to walkways and crossings (pedestrian streets count as walkway); vehicles use the remaining
  vehicle graph; `test_life_section`, `test_life_spacing`, `test_life_traffic` stay green.
- Enemy / bot navigation reads `CityPlan.road_graph()`: closed streets leave it, alleys are not in it (v1). Superseded
  2026-11-23 by `walk_graph()` (see "Graphs" in section 4).
- z-fight audit stays clean; ramp, farm wall, mission world tests stay green.

## 3b. Road forms come from the SectionPlan (Missions; landed dormant, live by default since 2026-11-23)

The section plan rolls a `form` per road SEGMENT (one stretch of a line between two neighbouring crossings) and the city
draws it; the grid, cell rects and strip widths never move. **Live by default since 2026-11-23 (f_lane 0.20,
f_pedestrian 0.15, f_none 0.08), switched by Missions** once the drawing had landed (the checksums changed once, then).
To get a plan without forms: `SectionPlan.make({"seed": n, "f_lane": 0.0, "f_pedestrian": 0.0, "f_none": 0.0})`.

- `sec.segments(k) -> [{axis, line, index, a, b, form, rect, inner, minor, blocked}]`; `sec.line_segments(k, axis, line)`;
  `sec.segment_form(k, a, b)`; `sec.carriageway(k, a, b)`; `SectionPlan.FORM_WIDTH` = street -1 (the line's width),
  lane 8, pedestrian 0, none 0. `deck_view(k).road_strips`: one strip per segment with `index` and `form`.
- `rect` runs crossing centre to crossing centre; `inner` is the stretch strictly between the crossings (what the city
  fills for `none`). `blocked` = "" | "bridge" | "foot": nothing drives across there.
- Forms: `street` (today), `lane` (8 m carriageway in the strip; the rest is wider walkway / setback), `pedestrian`
  (paved, no carriageway), `none` (fill the strip with block content: the two blocks become one superblock).
- Always `street`: spine, perimeter, ramp head / foot neighbourhoods, lift lobbies, anything within 1 m of a floor cut
  or connector footprint, gate nodes, checkpoint / cordon segments, the planned vehicle route.
- `sec.road_graph()` omits pedestrian / none segments and bridge edges. `CityPlan.road_graph()` (bots, enemies) must
  drop the same edges when the forms are drawn.
- Measured by Missions over 40 seeds with that mix: 19 % of segments minor; of those street 0.59, lane 0.22,
  pedestrian 0.14, none 0.04.

## 4. As built

Landed 2026-11-23 (Environment session subagent). Code: `scripts/world/city/` (`city_plan.gd` sections "Alleys" and
"Road forms", `city_streets.gd` `_alley` / `_form_segment` / `_raised` / `string_lights`, `city_buildings.gd` tint,
colourways, shopfronts, `_alley_face`, `_lane_face`, `city_props.gd` `_alley_items` / `_form_items`, `city_district.gd`
raised collision and the `StringLights` node, `city_lab.gd`), `scripts/world/life/life_plan.gd` + `life_traffic.gd`.
Test: `tests/test_city_variety.gd`. Shots: `city-variety/`.

**Part A, building looks** (cosmetic, no plan / props / collision change: the test holds the numbers captured before).
Each building has its own variety stream (`CityBuildings._vr`, seeded from the cosmetic seed and the building index), so
the district's shared cosmetic stream is drawn exactly as before. Tint: `CityPalette.tint` (hue +-0.014, saturation
+-12 %, value +-7 %) on apartments, offices (frame / spandrel, 70 %), sage blocks and shops. Second colourway on 24 %
(`COLOURWAY`): sky-blue apartments with cream trim and blue glass, sand offices with teal glass, pale cream panel blocks
with sage ledges, rose-terracotta shop rows. Shopfronts: one awning shape per row (sloped, flat canopy, short steep),
recessed doors on 40 % of rows, half the awnings and fascias from new palette colours, and on a corner lot a door on the
side street right by the corner with a blade sign over it. Towers, pillars and the civic hall are untouched. New palette
names: `apt_sky`, `apt_sky_dark`, `sand_light`, `office_sand`, `sage_cream`, `shop_rose`, `awning_*`, `fascia_*`, and for
the streets `service`, `service_dark`, `drain`, `pipe`, `door_back`, `planting`, `bulb`.

**Part B, alleys** (plan data, checksum). `CityPlan.alleys` [{block, rect, axis}]. A block is eligible when it is a plain
built block (stand-alone: not the park or civic block; section: an urban or industrial cell), holds no pillar, is not
downtown, and the alley clears floor holes (+2 m), ramps (+2 m) and kept-clear ground; it needs two lot rows of 14 m
(`ALLEY_ROW`) beside the alley. Share: param `alleys` (default 0.33), rolled from its own generator (seed, deck), four
draws per block whatever happens. Width: 7 m clear at the mech's top (8 m) between walls that lean together across the
arc, so 7.5 m on the ground at these radii (`alley_band()`), plus each building's setback. Position: the block's middle
+- 4 m; an alley lined up with the neighbour's across a street is moved off its line (by the band + 4 m) or kept as the
deck's one corridor (`ALLEY_CORRIDOR`, seeded). The block is first filled as without an alley (so the plan generator
stays in step for every later block), then refilled in two rows from the alley's own generator (`_fill_alley`).
Looks: service paving, dark edge bands, a drain line with grates (decal layers 1 / 2), back doors with hoods, downpipes
and a pipe run on the walls facing it, bins as street props. It is on the block's sidewalk slab: no collision change.
No walk graph or vehicle lap enters one (tested). Numbers: 25 alleys over 12 stand-alone seeds (about 2 a district: a
block needs 35.5 m of depth); in sections almost none (2 over 60 decks): urban cells hold pillars (deviation: the spec's
"about a third" is of blocks that can take one; through-pillar alleys were not built). The real mech capsule walks every
alley of stand-alone seeds 1, 2, 5 and section 4 deck 0 (no contact, >= 7 m wall to wall at 8 m by rays).

**Pillar-side alleys (downtown pass 2, 2026-11-23).** On section decks a block with a pillar may take an alley
(`_plan_alleys(eligible, by_block)`): the same four draws a block, then `_alley_beside` takes the line nearest the seeded
one (this axis, else the other) that keeps 1 m (`ALLEY_PILLAR`) off every core, with both 14 m rows; each row is carved
with `_carve`, so the pillar's lot ends at the alley and its podium is one wall. Same width rule, both ends open, still
never over a floor cut, ramp or kept-clear ground; parks, transit / open cells, the civic hall and downtown blocks are not
eligible (downtown blocks taking an alley was not built). Stand-alone districts: unchanged (pillar blocks stay
ineligible there, so the stand-alone goldens hold). Section seeds 1-12, alleys per deck: before 3 over 36 decks (one
each on s4 d0, s6 d2, s10 d0); after 66 over 36 (0-5 a deck, mean 1.8; 64 beside a pillar), about 27 % of the eligible
(urban / industrial, not downtown) blocks. The real-capsule walk covers section 4 deck 0, section 1 deck 1 and section
12 deck 2 (pillar-side alleys asserted present); no walkway edge or vehicle lap enters one (test_life_section,
test_life_spacing, test_city_variety). Shot: `city-variety/alley_section.png` (lab camera `alley_pillar`, section 4 deck 0:
the pillar's teal podium is the right wall).

**Part C, road forms.** `CityPlan.forms` {seg_key: lane | pedestrian | none} (keys as `SectionPlan.seg_key`; section mode
copies `sec.segments(deck)`), `CityPlan.raised` [{rect, kind: court | band, seg}] (solid, sidewalk height). Drawing:
- lane: 8 m carriageway in the middle of the strip, gutters, solid edge lines, zebra and stop line at both ends, no
  parking or centre line; a raised planting band each side (curb on the carriageway side), stopping 6 m short of each
  crossing so the corner ramps and zebras stay at road level.
- pedestrian: plaza paving over the whole strip with bands across (decal layers 1 / 2); no gutters, zebras or stop lines;
  **one low step**: the blocks' 0.2 m curbs stay (collision unchanged, walkable for mechs and people). Trees, street
  planters and pairs of benches down the middle as knockable props (7 m clear of each end), string lights: posts
  zig-zagging along both edges every 10 m with a sagging wire and bulbs (`StringLights` node, the farm wall's warm
  emissive material, no Light3D, no shadow). No signal poles beside it.
- none: the stretch between the crossings raised to the sidewalk as a paved court (curb face toward each crossing, the
  blocks' edges on it drawn as plain sidewalk), entered across the strip's whole width (14 m) from both crossings, two
  trees and benches. Never sealed (flood fill in the test).
- Crossings: zebras and stop lines only on segments vehicles drive; the perpendicular streets keep theirs.
- `CityPlan.road_graph()` drops pedestrian / none segments. Over section seeds 1-20 with the mix (60 decks) it agrees
  edge for edge with `SectionPlan.road_graph()` except ramp-foot segments (`blocked == "foot"`, 20), which the section
  drops for vehicles and the city graph keeps (walkers); no crossing is left without a road edge.
  **Ramp-foot rule (2026-11-23, downtown pass 2 session):** Missions made `sec.road_graph()` the rule, so the city
  should drop a foot segment too, unless the built geometry is open there. `tools/city_downtown/foot_probe.gd` sweeps
  the 8 m mech capsule across the ramp lane (+-3 m) on parallel lines 1 m apart over each foot segment's road: all 20
  foot segments over section seeds 1-20 are OPEN (2-3 clear lines on the toe side of the foot line, where the ramp has
  already reached the floor), none is blocked by the ramp body. So the city graph keeps all 20 and Missions fixes the
  plan side; `tests/test_city_variety.gd` lists them (`FOOT_OPEN`) and fails on any other foot segment. The same test
  asserts `CityPlan.road_graph()` is one connected network on every deck of section seeds 1-20, with and without forms.
- Stand-alone roll (`road_variety`, default 0.33): own generator, never the avenue or the edge roads, a court never
  beside the park / civic block, no two parallel neighbours alike, then at most one pedestrian / none segment per six
  blocks (`CLOSED_PER`, deviation: a 16-block district otherwise lost most of its vehicle loops), then repaired: one
  vehicle network, every crossing keeps a vehicle segment, every block a vehicle side, no stubs. Over 20 seeds: lane 74,
  pedestrian 27, none 11 of about 400 minor segments (28 %).

**Graphs (2026-11-23, forms live).** Two graphs over the same crossings: `CityPlan.road_graph()` is where VEHICLES go
(unchanged, byte-identical: pedestrian / none segments and floor cuts dropped); `CityPlan.walk_graph(with_alleys := false)`
is where MECHS, enemies and the bot go. Same shape and a drop-in: the same `nodes` (ids i * ns + j, same positions) and
`edges` [[i, j]] (every road_graph edge first, in its order; then every pedestrian segment, then every superblock court
the mech capsule (r 2.2 m, 8 m) can cross between its end crossings, `court_open` from plan data: corridor inside the
strip with 1 m to spare, no tier / solid between 0.5 and 8 m, pillar core, park column, floor cut or ramp in it), never an
edge across a floor cut (road_graph's test, which covers a ramp's removed bridge), plus `forms` {Vector2i(min, max):
"street" | "lane" | "pedestrian" | "none" | "alley"}. `with_alleys`: a node at each alley mouth on the centre line of the
road it opens onto, level with the alley's centre line, that road edge split there (halves keep its form), an "alley"
edge mouth to mouth; new ids from nx * ns up in `alleys` order, low-side mouth first, shared within 1 m; a mouth whose way
to the road crosses a floor cut (beside a spine's ramp lane) stays at the alley's end on the building line, on no road.
On a forms-off plan walk_graph == road_graph. Measured over section seeds 1-20 (live) and stand-alone 1-20: 130
pedestrian and 38 court edges added, every court open, 151 alleys walked; walk graphs connected on every deck; every
walk-only edge of 6 decks swept by the capsule in built collision with no contact (`tests/test_city_variety.gd`).

**Life.** Crossings over a pedestrian street or a court have no signal (junction -1, crossed on arrival); walkers keep
the walkways (they do not walk down a pedestrian street's middle in v1). Vehicles: no loop round a block beside a
pedestrian street or a court; a lane is one lane, driven one way down its middle by the first loop that claims it
(`LifeTraffic.lane_claims`), the block across gets no loop; when blocks run short, more pods share the loops that have
slots (only then). The tram stays on the spine. Deterministic, no new messages.

**Part D, dressing.** Lanes: no street trees or benches; the buildings on them get wall lamps every 8 m and a hanging
sign. Alleys: bins, pipes, back doors. Pedestrian streets: planters, benches, trees, string lights. Courts: trees, benches.

**Numbers.** Triangles per deck (before -> forms dormant -> forms on): s1 d0 287 483 -> 287 867 -> 288 917 (+0.5 %),
s1 d1 326 536 -> 326 672 -> 327 424 (+0.3 %), s1 d2 297 274 -> 297 528 -> 301 652 (+1.5 %), s4 d0 306 831 -> 310 483 ->
307 897 (+0.3 %), s4 d1 344 264 -> 344 416 -> 343 752 (-0.1 %), s4 d2 302 601 -> 303 017 -> 306 117 (+1.2 %). Build
chunks: the slowest stay `ground 4/8` (16-19 ms); with forms the props chunk is 18.7 ms; stack seed 4 stepped build max
17.8 ms (city_perf headless). z-fight audit with forms (seeds 4 and 7, `run_world_zfight_audit.ps1 -Forms`): no finding
on any of the new tags (one found and fixed: the alley pipe run lay in the shops' sill tops).

**Goldens re-captured** (stand-alone, alleys + forms on by default; with `alleys 0, road_variety 0` the old values still
hold, tested): plan seed 1 209989488eaa0e52 -> bd1d848c575e85df, walled e4ec580da1956459 -> 3eb0728c9b4cffa2, props
layout 7e78d4e1e3db1a61 -> f321076ebd6e98f1; stand-alone life / traffic (test_life_section) 1: 509c51ad1d41d49a /
742568104e969d8d -> cde9f443947f3108 / 9871bde2f8293485, 2: 504b06bd82a5a9ab / f95817faffc270f1 -> 663736b939fb3227 /
4f11c6e60adf44b5, 3: 14c5573cbbee8a40 / 3daf84e9a4299bca -> 8d12b766dfd8f264 / a3fb3d0f9cf1877b. Section decks: unchanged
except where a deck rolls an alley (seed 4 deck 0: 3cc51e61b1918548 -> b8939964445ae725); with the section's forms
off the drawing is byte-identical (tested). Since the forms went live (2026-11-23) the tests pin both: the forms-off
values above, built with the explicit zero mix, and the default (live) plans, digests and collision as captured then.

**Lab.** Params `alleys`, `road_variety`; option `road_forms` (on, the default since 2026-11-23: the section's default,
live forms; off: the section / stack site plans the section with the forms explicitly off); cameras `tint_street`, `variety_top`, `alley`, `alley_top`, `lane`,
`pedestrian`, `court`.
