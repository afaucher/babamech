# Deck lettering

Built 2026-11-23 (`scripts/world/city/city_signs.gd`, `CitySigns`). The user wrote "There is no indication of what level you
are on today besides counting. Maybe we should write it on the walls by the doors?" From the concept grid
`city-signs/grid_deck_signs.png` they picked cell 4, then said cell 6 "might be better. Can we see both in game?" Both
looks were built and compared in game.

**User pick 2026-11-24: cell 6, dark panel; compared in game against cell 4.** `dark` is the default
(`CitySigns.style`, and the lab option's default). `white` stays as a lab-only option.

| | Look | Reference | In game |
|---|---|---|---|
| `dark` (default, the pick) | warm cream stencil on a dark blue-grey panel with chamfered corners, thin sky-blue stripe at the bottom (cell 6) | `city-signs/sign_numeral_dark_s71.png` | `ingame_dark_*.png` |
| `white` (lab only) | bold stencil numerals painted on the wall in off-white, thin dark outline (cell 4) | `city-signs/sign_numeral_white_s71.png` | `ingame_white_*.png` |

Side by side (white left, dark right): `city-signs/compare_gate.png` (a wall gate, deck 02, from 60 m) and
`city-signs/compare_lift_ramp.png` (a freight lift; a ramp foot pointing up to 01). `compare_gate.png` and `ingame_*_gate.png`
are historical: they show the side signs beside the gate, removed on 2026-11-25. Switch with `CitySigns.style`
("white" | "dark" | "off"), or with the lab option `deck_signs` on the `city` subject. Lab cameras are `sign_road`,
`sign_lift` and `sign_ramp`, for example `--city site=stack,seed=1,deck=1,deck_signs=dark,camera=sign_road`.
`sign_road` stands on the road that ends at a gate, 80 m back at 10 m up, and looks at the over-gate sign; with a mission
on it picks a gate with a MissionWorld door. Shots (current, 2026-11-25): `ingame_dark_road.png` (with `mission=doors`),
`ingame_dark_road_nomission.png` and `ingame_dark_ramp.png`. The `sign_gate` camera went with the side signs.

## User feedback 2026-11-25: one sign above each door, none beside; no hung signs over shafts; ramps keep theirs
"Just one sign above doors, not 3. We also don't need hanging signs above holes. Normal traffic would take the ramp, which
is where the sign should be." So:
- Every wall gate / portal has exactly one sign, the over-gate one. The side signs beside gates (both sides, bulkhead and
  farm walls, with the farm walls' proud panels behind them) are gone.
- No hung sign over shafts or ceiling openings (the `shaft` kind is gone).
- Ramps keep theirs (both ends, unchanged). A freight lift keeps its one panel above the door.
- The over-gate sign could not come lower. Over a 9 m gate the bunker lintel and beacons need its bottom at 14.7 m or
  higher, and the gallery band takes 15.4-16.6 m, so 17.2 m is the lowest clear bottom. It grew instead: `OVER_SHARE`
  0.6 -> 0.75 of the gate's width. Over a 9 m gate (14 m wide) it is now a 10.5 m wide panel from 17.2 to 28.8 m with a
  6.5 m numeral (was 8.4 m wide, to 26.5 m, numeral 5.2 m; the old side signs' numeral was 5.8 m). Over a 14 m spine gate it is
  unchanged at the `OVER_U` cap: 13 m wide, 19.7 to 34.0 m, numeral 8 m.

## Numbering
Number = section deck index + 1, two digits. The top deck, with the entry portal, is 01. The mission HUD's
"DECK n OBJECTIVES" (`mission_hud.gd`) uses the same rule. A district on its own (no section) shows nothing.
`CitySigns.force_number` can force a number there (used by the tests).

## Where
- **Above every boundary-wall gate** (blast doors, wave gates, portals, collapsed gates) on bulkhead and farm walls: one
  sign, centred over it (below). Window walls (the hull, only on a district on its own) carry none.
- **Over every freight lift door**, on a panel above the door's lamps (bottom 10.4 m, 0.9 m out of the core). Beside the
  door, the leaves slide over the face when they open (`MissionProps.LiftDoor`), and the face is all pilasters.
- **Both ends of every ramp**, on a panel hung from the ceiling on two rods, about 10 m up (over a mech), with no
  collision.
  - On the deck the ramp leaves: 4 m into the cut, facing the way in, showing an arrow down and the deck below.
  - On the deck it lands on: 4 m past its foot, facing the way in, showing an arrow up and the deck above.
  - The back shows this deck ("DECK 02"), for whoever arrives by the ramp.
  - Where a ceiling opening (snapped to 12 m panels) is over that spot, the sign moves further along the way in, 4 m at a
    time.
- Nothing beside gates and nothing over shafts or ceiling openings (removed 2026-11-25, above). Until then a side sign
  (numeral 5.8 m, panel 2.9-13.3 m) stood beside each gate on both sides where the wall allowed, and a hung panel over
  each open-air shaft.

| Sign | Numeral height | DECK height | Height on its surface |
|---|---|---|---|
| Over a gate | 6.5 m (9 m gate), 8 m (14 m gate) | a quarter of it | panel bottom 17.2 m (9 m gate), 19.7 m (14 m gate) |
| Lift | 3.6 m | 0.9 m | panel bottom 10.4 m |
| Hung (ramp) | 4 m | 1 m | panel bottom 10 m |

Counts per deck (sections 1, 4, 403112), 2026-11-25: 7 to 12 signs, of which 5 to 9 over-gate signs (one per gate), 1 or
2 lifts and 0 to 2 ramp ends. Before the removal: 18 to 31 (plus 10 to 18 side signs and 0 or 1 shaft).

## The over-gate sign (2026-11-24)
A sign 5 m beside a gate at a road's end is behind the corner block until you are close, when you walk up that road
toward the gate. So every wall gate, portals included, got a sign centred **above** it, on the wall over the lintel
(kind `over_gate`, `CitySigns._over_gate`). Since 2026-11-25 it is the gate's only sign:
- **Width**: the panel is `OVER_SHARE` = 0.75 of the gate's width (0.6 before 2026-11-25). Its numeral is 4-8 m (`OVER_U`
  0.4-0.8), smaller if the ceiling is close.
- **Bottom**: at least `OVER_CLEAR` = 5.7 m over the gate's top. That clears a MissionWorld bunker's lintel (3 m), the
  beacon housings (0.4 m) and beacons (1.3 m) standing on it (`MissionProps.GateDoor`), with 1 m to spare. It also clears
  the baked hazard frame (gate top + 1.6 m).
- **Bulkheads**: the bottom is also at least `OVER_MIN` = 17.2 m, over the gallery band (15.4-16.6 m), which runs across
  the gates. In practice that puts the bottom at 17.2 m over 9 m gates and 19.7 m over 14 m spine gates.
- **Top**: at least `OVER_TOP` = 4 m under the ceiling.
- **Farm walls**: on a proud panel (face 1.0 m out, clear of the racks' leaves). Its box stands in front of the light bar at 58 % of the
  ceiling height, which it crosses.
- **Visibility**: from the gate's road centre line at 40, 60 and 80 m out and 10 m up, no building tier of the plan
  blocks the over-gate sign, at any gate of sections 1, 4 and 403112 (`test_city_signs`; none blocked, so none to list).

## Geometry and cost
- **Glyphs** are a hand-made stencil face on a 10-unit cap height (digits 6 wide, stroke 1.9, stencil gaps 0.7): 0-9,
  D E C K, solid triangle arrows. They are triangulated with `Geometry2D`; the white look's outline is the glyph grown with
  `offset_polygon` (mitred).
- **Layers**: decals 2 cm apart (`CityStreets.DECAL_PATCH`). For the white look: outline, then fill, over the wall or panel.
  For the dark look: panel face, then stripe and glyphs. Each layer has its own `CityGeo` audit tag: `deck_sign.panel`,
  `.outline`, `.glyph`, `.stripe`, `.rod`.
- **Mesh**: one `DeckSigns` mesh per district, built in its own chunk "signs" after the walls. It is shown at every
  `CityQuality` level, casts no shadow and has no collision.
- **Kept out of the gameplay shape**: not in the plan checksum, not in `geometry_digest()` and not in `stats.triangles`. Its
  triangles go in `stats.sign_triangles`, so switching the look moves nothing else.
  `CityDistrict.rebuild_signs()` rebuilds it alone.
- **Cost** since 2026-11-25 (one sign per gate, no shafts): per deck, 0.7k to 1.3k triangles for the dark look and 1.2k
  to 2.3k for the white look (with the side and shaft signs it was 1.8k to 3.3k and 2.9k to 5.6k; a deck is about 270k to
  360k). About 70 triangles for a numeral pair with its outline.
- **Colours** (`CityPalette`): `sign_white`, `sign_outline`, `sign_panel`, `sign_cream`, `sign_stripe`. The white look's
  panels (farm, lift, hung) are `concrete`.

Tests: `tests/test_city_signs.gd`.
