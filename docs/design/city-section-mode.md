# City generator: section mode

How the city generator builds one whole deck of a mission section from the section plan
(`scripts/world/section/section_plan.gd`, `docs/design/mission-section.md`), instead of a stand-alone district with its
own avenue. **Spec for the implementation; the stand-alone mode stays exactly as it is** (the test drive calls
`CityDistrict.build({"seed": N, "walls": 1.0})`, spawns at arc (0, 12) on the avenue at x = 0, and uses `CityDistrict.props`).

## 1. Entry points

- `CityPlan.for_deck(section: SectionPlan, deck: int, overrides: Dictionary = {}) -> CityPlan`
- `CityDistrict.build_deck(section, deck, overrides = {})` (same children and collision as `build`)
- Lab `city`: option `site` = `alone` (default) | `section`, slider `deck` (0..4, clamped to the section's deck count). The
  section is `SectionPlan.make({"seed": seed})`.

One plan = one whole deck. Coordinates are the section's own for that deck (x = 0 on the section centre line, s = 0 in
the middle of the arc): no origin offset anywhere. `radius` = `section.radius_of(deck)`, `ceiling` =
`section.clear_height()`, `extent` = the deck's ground: x in [-width/2, width/2], s in [-arc_of(deck)/2, arc_of(deck)/2].
The plan keeps `section` and `deck` (null / -1 when stand-alone) and its checksum includes `section.checksum()` and the deck.

## 2. What comes from the section (the city invents none of it)

| Section plan | Becomes in `CityPlan` |
|---|---|
| Longitudinal road lines `col_x[i]` +- `line_width("s", i) / 2` | `roads_x` entries `{a, b, kind}`, kind = `spine` / `arterial` / `perimeter` |
| Cross lines `line_s(deck, j)` +- `line_width("x", j) / 2` | `roads_s` entries, kind = `cross` / `perimeter` |
| `cell_rect(deck, c, r)` | one block per cell: `{rect, ix: c, is: r, kind, zone}` (the rect is road edge to road edge, sidewalk inside, as now) |
| `zone(deck, c, r)` | how the block is filled (section 3) |
| `pillars`, `pillar_point`, `pillar_style`, `pillar_radius` | `site.pillars` (as `CitySite.from_section` does now, without the origin shift). `dropped_pillars` must be 0 |
| `decks[deck].keep_clear` | `site.keep_clear`: lots touching one become plazas |
| Connectors with `is_hole(ci, deck - 1)` | `site.openings`: holes in this deck's ceiling (rect scaled to this deck's radius, as now) |
| Connectors with `is_hole(ci, deck)` | **new** `site.floor_holes`: holes in this deck's floor (section 4) |
| `boundary(deck, edge)` | `CityPlan.boundary()` (section 5) |

Because the section's lines form a full grid, `roads_x` / `roads_s` keep their meaning and `road_graph()` still works.
`_axis`, `_pick_special` and `CitySite.stub` are not used in section mode.

## 3. Filling a block by zone

| Zone | Fill |
|---|---|
| urban | As now: `_carve` around the cell's pillar, then lots, styles, bands, the jump pass |
| park | As now: one park lot; the pillar is a tree-column |
| industrial | **Placeholder**: urban lots with shops off and offices / sage doubled; block `kind = "industrial"` so a real industrial generator can replace it |
| transit | **Placeholder**: one plaza lot (open paving, no buildings) around the pillar; the pillar tower is built (lift or transit core) |
| open | One plaza lot with the shaft's floor hole in it; no pillar (the section omits it) |

No civic hall in section mode for now (every cell that could hold one has a pillar). Cells are bigger than stand-alone
blocks (about 53-71 m x 76-110 m): the lot splitter already leaves alleys, and no minor streets are added yet.

## 4. Roads and floor holes

- `arterial`, `cross`, `perimeter` (12-14 m): drawn as today's `street` (parking strips, dashed centre line, crossings).
- `spine` (50 m), four lanes side by side from `section.lane_x(name)`:
  - `avenue` (18 m): today's avenue look (tan carriageway, planted median, lane lines), fitted to its width.
  - `rail` (12 m): a ballast strip (`concrete_dark`), two tracks of two rails each (`metal_dark` boxes 0.15 m high) on
    sleepers every 2 m (`trunk` colour). No collision on rails.
  - `ramp_a`, `ramp_b` (10 m each): plain asphalt lanes with edge lines.
  - Crossings: the cross roads' zebra stripes span the whole spine; rails and sleepers continue through.
- **Floor holes** (`site.floor_holes: Array[Rect2]`): where this deck's floor is cut (a ramp diving out of a ramp lane, an
  open-air shaft). The ground mesh, markings and the deck's collision are left out over the hole; around it a 0.5 m curb
  and a 1.2 m railing (posts every 4 m, one top rail, `metal_dark`; no collision on the railing, the curb is 0.5 m of
  solid), and the cut face of the slab going down `section.p("slab")` metres (the same look as the ceiling opening's cut
  face). Nothing is drawn below: the deck beneath is another `CityDistrict`.
- The ramp itself (the sloping road between decks) and the viaduct landing on the lower deck are **not built here**:
  the landing's footprint is in `keep_clear` and stays empty. That is the next step after this one.

## 5. Walls

`CityPlan.boundary()` returns one entry per edge in both modes: `{side, kind: bulkhead | window, at, backdrop, gates:
[{a, b, h, kind: blast_door | portal | collapsed}]}` with side 0:+x 1:-x 2:+s 3:-s (section edges x1, x0, s1, s0). `a..b` is
the gate's span along the wall (x for arc-end walls, s for side walls) from the section gate's position and width; `h` =
14 m on the spine, 9 m otherwise.

`CityStreets.walls` must draw either kind on any side: across the arc the wall is one flat plane (constant s); along the
arc it follows the facets (constant x). Gates:
- `blast_door`: as built (door leaves, hazard portal, hatched box).
- `portal`: the same portal frame with no leaves, a dark recess 6 m deep behind it (`glass_dark`), and **no collision**
  across the opening (the way in / out of the map).
- `collapsed`: built exactly as a shut `blast_door` (leaves, hazard portal, hatched box, the wall's solid collision)
  since the 2026-11-23 playtest ("the wide door with rocks in it isn't working, make it a normal door"); the rubble
  pile is gone. The kind stays `collapsed` in the section plan.
- `backdrop: true` (window walls): the low-detail backdrop is built beyond that edge only. No backdrop behind bulkheads.

In section mode walls are always on (the `walls` param is ignored).

## 6. Props, lighting, lab

- `CityPropLayout.layout` must work from the plan in both modes (median trees on the spine's avenue lane; no props in floor
  holes or keep-clear areas).
- `CityLightRig.setup` gets the deck extent; the fill-light cap stays.
- Lab cameras use the plan: add `plan.avenue_x() -> Vector2` (the avenue carriageway's x range: [-10, 10] stand-alone,
  the spine's avenue lane in section mode) and place the `avenue`, `gate` and `rooftop` cameras from it.

## 7. Tests (`tests/test_city.gd`, extend)

For section seeds 1-5 and every deck: `for_deck` plans; `dropped_pillars == 0`; every section pillar is built (tower or
column) at its exact point; one block per cell with the cell's rect; every lot inside its block; no building or prop in a
floor hole or keep-clear rect; standable roofs under the stand limit; the existing per-plan checks (`_check_plan`) pass
where they apply; `boundary()` has four sides whose kinds and gate counts match the section's; same inputs give the same
checksum, another deck a different one. One `CityDistrict.build_deck` for seed 1 deck 0: it builds, a ray down a floor
hole hits nothing within 10 m, a ray through a `portal` gate hits nothing and through a `blast_door` hits the wall.
The stand-alone tests stay unchanged and green, as do `test_city_props`, `test_net_props`, `test_lab`, `test_layout`.

## 8. As built (2026-11-21)

Built as specified, with these differences:
- Pillar core sizes come from `section.pillar_radius` (urban 9, lift 14, transit 7, park 2.5), not the city's own table.
- `site.floor_holes` holds the hole pieces after the cross streets bridge a ramp cut (ground and collision stay across
  each cross road). Every piece is railed on all sides, including the ramp's top end, until the ramp itself is built.
- A ramp's footprint on its lower deck is added to `keep_clear` (the section lists only shaft landings there).
- A transit cell is a pillar lot plus plaza lots, not one plaza lot.
- A window wall with a backdrop has no glazing (sill, mullions, transoms only), so the backdrop shows through.
- The city seed defaults to the section seed mixed with the deck number.
- Stand-alone plan and prop checksums are unchanged; stand-alone walls share the new wall code and look slightly different
  (a header above each gate, the base strip cut at gates).

Seen in renders (seed 1, deck 0): the spine with avenue, rail and ramp lanes, crossings, the blast door, the window wall
with its backdrop, pillars and tree-columns. A floor hole shows as flat sky colour (nothing is drawn below). Known
rough edges: the spine gate's door covers only part of the 50 m spine, so the rails run into the wall beside it; a deck
is 330-370k triangles; the `plaza` and `park` lab cameras may fall back to the default view in section mode.
