# City styles: the pristine urban district

How the urban zone is built from a seed, and the building styles it uses. Source art: `art/renders/env_r3/` (zones 1, 2, 9)
and `art/renders/env_r1/day_pristine_s909.png`. Code: `scripts/world/city/`. Lab: `.\lab.ps1 city`.

This is the **pristine** base: no occupation dressing (banners, pylons, checkpoints), no wear, no traffic. Those are later
passes on top (see Hooks).

> **Paused (2026-11-21):** new city work (more styles, variability, section integration, walls beyond the stub) waits
> until the demo is playable. What was queued and the exact next steps are in `docs/paused/city-gen.md`. Still active:
> destructible street props (`city-props.md`) and keeping the city working in the test drive.

## Rules that hold for every style

- **Chunky low poly, one flat colour per face, no textures.** All detail is geometry: a window is a dark pane with a sill,
  a cornice is a box. Nothing smaller than about 0.1 m.
- **Surface colour and light are separate.** Every colour comes from `CityPalette` and is a plain albedo. Warmth, shadow,
  haze and the glow of the ceiling strips all come from `CityLightRig`. The same meshes are relit by switching the rig
  preset (`day`, `dusk`, `clinical`); `test_city` checks that relighting changes no vertex and no colour.
- **Scale.** Storey 3.25 m. Mech about 8 m (two and a half storeys). Ceiling 40 m. Standable roofs stop 12 m below it
  (room for a mech under the beams): see `ceiling-and-pillars.md`.
- **Roof bands.** Roofs sit in bands 6.5 m apart (two storeys): 6.5, 13, 19.5, 26 m. One band is one hop. The
  plan lowers any roof that can't be reached by hopping one band at a time from a band 0 or 1 roof, across gaps of at
  most 6 m inside a block, so **every roof is reachable**. Pillars are the exception: not standable.
- **Buildings stand radially.** Each is a straight box on the curved deck, so walls lean together toward the ring axis.
  Footprints are narrowed along the arc so tops don't collide; the gap between neighbours closes with height.
- **Palette.** Cream, terracotta, sage, sky blue, with sand/concrete neutrals and dark teal or blue glass. Trim is usually
  the lightest cream. Roofs are a warm grey.

## The six styles

| # | Style | Bands (roof) | Massing | Facade | Roof | Palette |
|---|---|---|---|---|---|---|
| 1 | **Terracotta apartments** | 1-3 (13-26 m) | One block; stair bulkhead on the roof | Punched windows with sills, 3.4 m bays; balconies on alternate bays of the street side and its opposite; pale ground floor band, belt course, cornice | Water tank on legs, vents, AC | Terracotta (three tones) or cream body; cream trim; teal glass |
| 2 | **Cream offices** | 2-3 (19.5-26 m) | Block, or block + top two floors set back 2.5 m | Grid: piers every 3.2 m and spandrels over a glass box, so glazing reads as ribbons with real relief; entrance canopy | Plant room, mast, AC | Cream / sand frame; blue or teal glass; one accent canopy |
| 3 | **Sage panel blocks** | 1-3 | Slab, or slab + penthouse set back 3 m | Continuous ribbon windows broken by mullions; cream floor ledges every storey | Roof garden planters, skylights | Sage (three tones) or blue-grey; cream ledges; dark glass |
| 4 | **Shop rows** | 0 (6.5 m) | Low box on the building line, no setback | Shopfront per 5.6 m unit: big pane, door, sloped awning, sign fascia, two upper windows; stepped parapet | AC, skylight | Body cream / terracotta / sage / sky blue; awnings in every accent |
| 5 | **Civic hall** | fixed 12 m | Plinth with steps, hall, portico toward the avenue, forecourt | Column row, entablature, pediment; tall windows between pilasters | Low blue-grey gable (the pediment is its end) | Sand walls, cream stone, blue-grey roof |
| 6 | **Pillar tower** | reaches the ceiling | Podium (band 1, standable) + structural core on its given point + collar, flare and drop panel (`ceiling-and-pillars.md`) | Podium: office grid. Shaft: concrete fins with tall sky-blue strips, a band every two storeys | none (it carries the deck above) | Concrete, sky blue |

How each reads in low poly: apartments are the warm red masses with dotted windows; offices are pale grids; sage blocks
are green with horizontal stripes; shops are the low, colourful edge of a block and the first step up to the roofs; the
civic hall is the one building with columns; pillars are the only things touching the ceiling, visible from anywhere.

Open lots (density below 1): **garden** (raised lawn, trees), **plaza** (paving, planter, benches), **court** (parking
court). One block per district is a **park** with crossing paths and a fountain; the civic hall faces it across the avenue.

## Streets

Grid in arc coordinates: a central **avenue** runs along the spin direction (it climbs the curve, the Cluckipede view),
cross streets run level. The origin is the avenue / cross-street crossing.

Cross-section, centre line outward: lane, parking strip (streets) or outer lane (avenue), **gutter** (dark, 0.5 m),
**curb** (pale, 0.3 m, up 0.2 m), **furnishing band** (1.3 m: trees in pits, lamps, bins, signal poles), **walkway**
(2.4 m), building line.

- Avenue, 20 m: tan centre carriageway, planted median, dashed lane lines, solid edge lines.
- Street, 12 m: two lanes, dashed centre line, parking strips with bay ticks.
- Every approach to a crossing has a zebra crossing and a stop line on the incoming side.
- Every block corner has two **curb ramps** in a tactile colour, lined up with the zebra crossings.
- Furniture: street trees about every 9 m, a lamp every third slot, benches and bins beside them, a signal pole per corner.

## Ceiling

The underside of the next deck: panels in three sand tones, girders along the arc every 14 m, ribs across every 24 m, one
long **light strip** per bay, service ducts, hatches, and openings where the deck above is cut. The strips are separate
geometry with an emissive material that the light rig drives. Full design: `ceiling-and-pillars.md`.

## What is gameplay and what is cosmetic

| Gameplay (in `CityPlan`, seeded, in the checksum, has collision) | Cosmetic (second seeded stream, no collision) |
|---|---|
| Streets, blocks, lots, sidewalks (0.2 m), building tiers incl. bulkheads and setbacks, pillars, deck, ceiling | Colours, windows, balconies, awnings, cornices, roof units and tanks, trees, lamps, benches, curb ramps, backdrop |

Both streams come from the mission seed, so every machine shows the same city; only the left column can affect play.

## Lab settings (`city`)

Seed, district width and length, block size, density, height bias, roof band step, ceiling height, roof clearance, pillar
spacing, ceiling opening over the park, roof hop gap, ring radius, style mix (four weights); lighting preset; camera (`lab`
orbit, `avenue`, `street`, `rooftop`, `plaza`, `pillar`, `park`).
Screenshots: `.\run.ps1 --scene res://scenes/lab.tscn --subject city --shot out.png --city camera=avenue,lighting=dusk,seed=7`.

## Hooks for later variety

- **Occupation dressing**: banners hang on `CityBuildings.Face` (it gives wall frames per side and storey); pylons and
  checkpoints go in the furnishing band and at crossings.
- **Lived-in wear**: a per-building tint and a clutter pass can use the cosmetic stream without touching the plan.
- **More styles**: add a name to `CityPlan.STYLES` / `BANDS`, tiers in `_build_tiers`, a mesher in `CityBuildings`.
- **Other zones**: `CityPlan` block kinds (`park` exists) are where industrial, transit and open-air blocks plug in.
- **Night**: lamps and windows are geometry in palette colours; a rig preset can add lights at lamp heads.
- **Superblocks / closed streets**: `road_graph()` is already a graph, so removing an edge is checkable.
