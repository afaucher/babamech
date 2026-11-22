# Ceiling and pillars

How a deck meets the deck above it: the ceiling you see from the street, the pillars that hold it up, and where the two
decks share structure. **Proposal, built in the generator; the choices marked "Open" at the end are the user's to confirm.**

Code: `scripts/world/city/` (`CitySite`, `CityPlan`, `CityStreets.ceiling`, `CityBuildings._pillar` / `capital` / `column`).
Pillar positions come from the section plan (`docs/design/mission-section.md`, `scripts/world/section/`). Lab: `.\lab.ps1 city`,
cameras `pillar` and `park`, sliders "Roof to ceiling clearance", "Pillar spacing", "Ceiling opening over the park".

## 1. The picture

A deck is a slab. Its top is one city's floor; its underside is the ceiling of the city below. Pillars are radial columns
that pass through every deck on the same line. Standing in the street you read, from the ground up: buildings, a band of
open air, then a warm sand-coloured grid of beams with long light strips, and here and there a tower that does not stop
at a roof but widens and merges into that grid.

| | Value | Why |
|---|---|---|
| Clear height (floor to ceiling panels) | **40 m** | D4; the section plan's deck pitch 48 m minus an 8 m slab |
| Slab thickness | **8 m** | Seen only in the side of an opening |
| Lowest thing hanging from the ceiling | 2.4 m below the panels (rim beam); girders 1.8 m, strips 1.4 m | Sets the clearance rule |

## 2. Ceiling

A regular grid, laid in arc coordinates so it curves with the ring:

- **Girders** run along the arc (the spin direction) every 14 m, 1.8 m deep. They are the dominant lines: looking down
  the avenue they converge up the curve.
- **Ribs** run across every 24 m, shallow (0.8 m).
- **Panels**: half a bay each way (7 x 12 m), three sand tones in a fixed pattern, so the ceiling reads as chunky facets.
- **Light strips**: one continuous strip down the middle of every girder bay, hung just below the ribs so nothing breaks
  the line. These are the scene's light sources in the fiction. In the engine they are separate geometry with an emissive
  material that `CityLightRig` drives (colour and energy per preset), and the rig hangs its fill lights under them. Turning
  the lights to dusk or clinical changes the strips and nothing else.
- **Service ducts**: a duct beside every other girder.
- **Access hatches**: a dark framed square in about 1 panel in 30 (the deck above's manholes, seen from below).

From street level the strips and girders give direction (they point along the ring); from a rooftop at the top band you
are 14 m under the panels and the grid fills the upper half of the view.

## 3. Pillars

**Pillars are structure, and structure is shared between decks.** A pillar on this deck stands on the same radial line as
the pillar below and above it: same x, same angle around the ring. So the city generator never chooses pillar positions.
It is given them (`CitySite`):

- In a mission, from the section plan: one pillar per district cell (about 90 m), offset from the cell centre by a seeded
  few metres, identical on every deck (`CitySite.from_section(section, deck, origin, reach)`).
- For a district on its own (the lab, the S3 arena), from `CitySite.stub`: the same rule, one pillar per 90 m bay, moved
  to the nearest spot inside a block. The civic block is left as a long-span bay with no pillar.

What the generator does with a pillar point:

| Rule | Detail |
|---|---|
| Never in a road | Streets slide sideways off any pillar (core + sidewalk + 1 m). A stub pillar is placed inside a block to begin with |
| The core is exact | The structural core is built on the radial line through the given point, not on the building's own frame, so it lines up across decks to the centimetre |
| The tower wraps the core | In an urban block the pillar gets its own lot (core + 4 m apron). A podium (band 1, about 13 m, standable) fills the lot; the core rises out of it. The rest of the block is cut into ordinary lots around it |
| Not standable | The core has no roof: it ends in the ceiling |
| Hard cover | The core is a solid box 15 m wide (24 m for a lift pillar), floor to ceiling |

### How a pillar meets the ceiling

Three parts, the same on every variant: a **collar** 7.5 m below the ceiling, a **flare** widening from the shaft to the
drop panel, and a **drop panel**: a thickened square of the deck above (core + 5 m each way, 1.8 m deep) that the girders
die into. The light strips stop at the drop panel. This is how flat-slab concrete buildings carry columns, and it reads
clearly in low poly: the tower opens like a hand under the ceiling.

### Variants

| Zone | Pillar | Core | Built |
|---|---|---|---|
| Urban | **Pillar tower**: podium + concrete shaft with fins and sky-blue glazing strips | 15 m | yes |
| Urban, freight lift | **Lift pillar**: bare shaft in its own plaza, a mech-sized door in a hazard frame facing the avenue, a green guide channel up the shaft. The lift platform rides inside | 24 m | look only (no moving lift yet) |
| Park | **Tree column**: slim trunk in a planted ring, branching into the ceiling from 10 m below it | 4 m | yes |
| Industrial | Steel truss tower, open lattice, pipes following it up | 10 m | no (no industrial zone yet) |
| Transit | Station pier: the pillar is the middle of a platform canopy | 14 m | no |
| Open air | No pillar: a cell with a shaft is a long-span bay on every deck | - | - |

## 4. Where the decks overlap

- **Shared lines.** Pillars, and anything else that crosses decks (lift shafts, ramp cuts), are stored as an angle
  around the ring plus x. On deck k the arc position is angle x that deck's radius. Lower decks are longer, so the same
  pillar grid is wider spaced along the arc there.
- **Openings.** A hole in the floor of the deck above (open-air shaft, ramp cut) is a hole in this ceiling. The generator
  takes them as rectangles (`CitySite.openings`) and cuts the ceiling back to whole panels. Around the hole, from below:
  the **cut face of the 8 m slab**, a **rim beam** 2.4 m deep, and a **rim light** under it. Girders, ribs, strips and
  ducts stop at the rim. The ceiling's collision is open there, so a mech dropping from above comes through.
- **An opening never cuts a pillar.** The section plan leaves the pillar out of any cell with a shaft, on every deck.
- **What lands below an opening** stays unbuilt: `CitySite.keep_clear` rectangles become plazas.

## 4b. Boundary walls (stub)

A mission section is an arc of the ring, not the whole ring, so the map ends in walls. Lab slider "Boundary walls";
`CityPlan.boundary()`; camera `gate`. Off by default (the lab and the S3 arena show the low-detail backdrop instead).

| Edge | Wall | Look | Roads |
|---|---|---|---|
| Ends of the arc (across the spin direction) | **Bulkhead**, floor to ceiling, 6 m thick | Sand panels between buttress fins that line up with the ceiling girders, a gallery band at 16 m | Every road along the arc ends in a **blast door** in a hazard-coloured portal (14 m high on the avenue, 9 m on streets), with a hatched keep-clear box in front. Sealed: solid |
| Sides (along the arc) | **Window wall** (the habitat's hull) | 8 m solid sill, then sky-blue glazing in a lattice of mullions and transoms up to the ceiling | Cross streets end at the perimeter street that runs along the wall |

Walls are in the same palette and material as everything else, so the lighting rig relights them too. Both are solid.
With walls on, the backdrop is not built.

Names follow the section plan's wall format (`plan.boundaries`: bulkhead / window, gates portal / blast_door / collapsed),
but the district does not read that format yet: its walls sit on its own four edges. Not built: open portals you can drive
through, collapsed gates, buildings standing against a wall (a perimeter street always runs along it), a backdrop seen
through a window wall.

## 5. Gameplay rules

- **Roof clearance: 12 m.** A standable roof is never higher than ceiling minus 12 m (28 m under a 40 m ceiling): an 8 m
  mech, 2.4 m of beams, and about 1.5 m to hop. This removed the old 32.5 m band: roofs now top out at 26 m (8 storeys).
  Roof units that poke above the limit (stair bulkheads on the top band) are marked not standable. `test_city` checks it.
- **Bands** therefore: 6.5, 13, 19.5, 26 m. One band is one hop; every roof is reachable (see city-styles.md).
- **Pillars are not standable** and have no ledges. Podiums are (band 1), which makes a pillar tower a good first step up.
- **Sightlines.** Roads are column-free by rule, so the avenue is one long sightline, cut only by the curve of the floor.
  Across blocks, a pillar is the one piece of cover nothing can shoot over. Under an opening you can be seen and shot from
  the deck above.
- **Thrusters.** Flying above 28 m puts a mech among the girders: possible between them (14 m bays), not across them.

## 6. Generator hooks

- `CityPlan.make(params, site)`: `site` null = stand-alone stub; a `CitySite` = imposed structure. The site is part of
  the plan's checksum.
- `CitySite.from_section(section, deck, origin, reach)` reads `SectionPlan` (pillars, their style per deck, keep-clear
  rectangles, holes in the deck above). `tests/test_city.gd` builds a district this way on every deck of a section.
- `plan.site.pillars`, `plan.columns`, `building["core"]`, `CityDistrict.core_frame(i)` for anything that needs to find a
  pillar (lift platforms, banners, cover queries).
- Deterministic: the stub's pillars depend only on the seed and the bay size; the section's only on the section seed.

## 7. Open (to confirm)

1. **Pillar spacing 90 m**, one per bay. A 220 x 240 m district gets about 6 to 8, the 120 m arena 2 to 4. Denser reads
   more structural and cuts sightlines; sparser makes each pillar a landmark.
2. **Capital style**: collar + flare + drop panel (built). Alternatives: a steel truss collar, or no flare (the shaft
   simply runs into a deep beam crossing).
3. **Clearance 12 m** costs the tallest roof band. Raising the ceiling to 46 m would bring it back.
4. **Section roads vs. city streets.** Given a section's pillars, the district still lays its own avenue and streets
   around them; where a section pillar falls on the district's own avenue it is dropped (seen on one deck in the test).
   The clean fix is for the city to fill the section's cells and use its road lines instead of generating an avenue:
   next step, with the section-layout session.
5. **Lift pillars** are dressed but static, and the upper deck is not drawn through an opening (you see sky colour).
