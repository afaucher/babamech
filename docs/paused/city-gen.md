# Paused: city generator work (2026-11-21)

Paused by the user's priority call: only the critical path to a playable demo continues. **Still active:** destructible
street props (`docs/design/city-props.md`) and keeping the city working in the test drive
(`CityDistrict.build({"seed": N, "walls": 1.0})`, avenue at x = 0, origin on its crossing). Everything below waits until
the main session says to resume.

What exists (not paused, just context): `scripts/world/city/` generates a seeded district on the ring deck in six
styles with streets, furniture, ceiling, pillars on given structural points, optional boundary walls and three lighting
presets. Docs: `docs/design/city-styles.md`, `docs/design/ceiling-and-pillars.md`. Tests: `tests/test_city.gd`. Lab: `city`.

> **Resumed 2026-11-21 late.** Item 1 is built (section mode: `docs/design/city-section-mode.md`, `CityPlan.for_deck`,
> `CityDistrict.build_deck`, lab `site=section`), and with it the wall kinds and gates of item 2. Next: the ramp ribbon
> between decks and its landing viaduct, several decks in one scene, then real industrial / transit / open-air fills.
> Items 3 to 5 below are still open.

## 1. Section integration (the biggest item)

**What.** The city plans a district on its own: its own avenue at x = 0, its own street grid, its own four edges. The
mission section plan (`scripts/world/section/section_plan.gd`, `docs/design/mission-section.md`) now defines the real
thing: district cells bounded by its roads, zone regions, pillar points, keep-clear areas, holes between decks and
boundary walls. Only pillars, keep-clear and ceiling holes are read so far (`CitySite.from_section`), and because the
district still lays its own avenue, a section pillar that lands on it is dropped (3 of 7 on deck 1, seed 4, in
`tests/test_city.gd::_section_site`).

**Files.** `scripts/world/city/city_plan.gd` (`generate`, `_axis`, `_pick_special`, `_fill_block`, `boundary`),
`city_site.gd` (`from_section`), `city_streets.gd` (`ground`, `_road`, `walls`, `backdrop`), `city_district.gd`,
`tests/test_city.gd`. Read-only: `scripts/world/section/section_plan.gd`.

**Exact next step.** Add a second planning mode to `CityPlan`: `CityPlan.for_region(section, deck, region_index, params)`.
In it, do not call `_axis`. Take the block outlines from the section: one block per cell (`section.cell_rect(deck, c, r)`
is the buildable ground with the section's roads already removed), optionally split by one minor street that dodges the
cell's pillar (reuse the barred-band logic in `_axis`). Then run the existing `_fill_block` / `_carve` per block. Roads
come from `section.roads`, `col_x`, `row_theta`, `line_s`, `line_width`, `lane_x`, not from `roads_x` / `roads_s`, so
`CityStreets.ground` needs a road list in a neutral form (strip rect + kind) instead of the two axis arrays. Walls: read
`section.boundary(deck, edge)` in `CityPlan.boundary()` instead of the stub. Success = `dropped_pillars == 0` on every
deck of sections with seeds 1 to 5, and the district origin offset handled in one place.

**Open questions.**
- Does a district keep a local origin (mech spawn at arc (0, 12) in the test drive assumes it) or adopt section
  coordinates? Proposal: section coordinates in section mode, local origin only in stand-alone mode.
- The section's spine is 50 m (ramp lanes, avenue, rail). The city only knows a 20 m avenue and 12 m streets: rail and
  ramp lanes need road kinds and geometry.
- Zone regions other than urban and park (industrial, transit, open air) have no generator.
- Section default radius is now 400 m; the city default is 300 m.

## 2. Boundary walls beyond the stub

**What.** `CityPlan.boundary()` + `CityStreets.walls` build bulkheads with sealed blast doors and a window wall on the
district's own edges. Not built: reading the section's wall format (`plan.boundaries`: bulkhead / window, gates portal /
blast_door / collapsed), open portals you can drive through, collapsed gates, buildings standing against a wall (a
perimeter street always runs along it), a backdrop seen through a window wall.

**Files.** `city_plan.gd` (`boundary`), `city_streets.gd` (`walls`), `city_district.gd` (wall collision),
`docs/design/ceiling-and-pillars.md` section 4b.

**Exact next step.** After item 1: map section gates to wall geometry by `kind`; for `portal`, leave the opening out of
the wall collision and draw the road through. Then add a "wall lot" row: shallow buildings (one lot deep) backing onto a
bulkhead where the section has no perimeter road.

**Open questions.** Should the bulkhead be lit better (it reads flat grey: the daylight comes from above)? Wall-mounted
light strips in the rig would fix it.

## 3. Pillar variants and the deck above

**What.** Built: urban pillar tower, park tree-column, lift pillar (dressed only). Designed only: industrial truss,
transit station pier. A ceiling opening shows sky colour, not the deck above. Lift pillars do not move anything.

**Files.** `city_buildings.gd` (`_pillar`, `capital`, `column`), `city_streets.gd` (`ceiling`, `_opening`).

**Exact next step.** None until industrial / transit zones exist (item 1). For openings: draw a low-detail slice of the
upper deck's ground and building tops above the hole (needs the upper deck's plan, so section mode first).

**Open questions (the user's, asked and unanswered).** Pillar spacing 90 m; capital = collar + flare + drop panel; roof
clearance 12 m (costs the 32.5 m roof band; a 46 m ceiling would bring it back).

## 4. More styles and variability

**What.** Six styles are built. Queued ideas, none started: L-shaped and courtyard footprints, corner buildings that turn
the corner, a tall slim "point block", a market hall, arcades over the sidewalk; a lived-in pass (per-building tint,
clutter, parked vehicles, signage); the occupation dressing pass (banners on `CityBuildings.Face`, pylons and checkpoints
in the furnishing band); night lighting preset with lamp-head lights.

**Files.** `city_plan.gd` (`STYLES`, `BANDS`, `_pick_style`, `_build_tiers`), `city_buildings.gd` (one mesher per style),
`city_light_rig.gd` (`PRESETS`), `docs/design/city-styles.md` ("Hooks for later variety").

**Exact next step.** Get the user's verdict on the six styles first (asked twice, unanswered): which to keep, change or
drop, palette balance, street proportions. Then add one style at a time, each as: a `BANDS` entry, tiers, a mesher, a
line in the styles table, and a seed where it shows in `docs/design/city-shots/`.

**Open questions.** Is the default ring radius 300 m right for the look (the concept art curve is gentler than 160 m,
which was the earlier default)? Should shops get a second storey of flats above (mixed-use), which the concept art suggests?

## 5. Small known issues (not blocking the demo)

- A lab screenshot run logs one leaked Environment RID at exit (from the `lab_own_lighting()` hook in `scripts/app/lab.gd`).
- Curb ramps and street furniture have no collision (a 0.2 m step); fine for an 8 m mech, wrong for future infantry.
- The lab's orbit view shows the district through thick haze (the fog is tuned for street level).
- Roof units (tanks, AC) are cosmetic and have no collision.

## How to resume

1. Read this file, `docs/design/city-styles.md`, `docs/design/ceiling-and-pillars.md`, and the shared notes
   `city-generator.md` + `section-plan.md`.
2. `.\test_runner.ps1 -TestName test_city,test_city_props` should pass before any change.
3. Start with item 1 (it unblocks 2 and 3). Implementation goes to Opus subagents with tight briefs; design and review
   stay in the city session. Renders only through the hidden desktop (`docs/testing.md`).
