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
- Enemy / bot navigation reads `CityPlan.road_graph()`: closed streets leave it, alleys are not in it (v1).
- z-fight audit stays clean; ramp, farm wall, mission world tests stay green.

## 3b. Road forms come from the SectionPlan (Missions, landed dormant 2026-11-23)

The section plan rolls a `form` per road SEGMENT (one stretch of a line between two neighbouring crossings) and the city
draws it; the grid, cell rects and strip widths never move. Dormant by default (every segment `street`); to get forms:
`SectionPlan.make({"seed": n, "f_lane": 0.20, "f_pedestrian": 0.10, "f_none": 0.08})`. Missions switches the defaults
when the drawing has landed (checksums change once, then).

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

(filled in when it lands)
