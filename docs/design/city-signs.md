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
`city-signs/compare_lift_ramp.png` (a freight lift; a ramp foot pointing up to 01). Switch with `CitySigns.style`
("white" | "dark" | "off"), or with the lab option `deck_signs` on the `city` subject. Lab cameras are `sign_gate`,
`sign_lift`, `sign_ramp` and `sign_road`, for example `--city site=stack,seed=1,deck=1,deck_signs=dark,camera=sign_gate`.
`sign_road` stands on the road that ends at a gate, 80 m back at 10 m up, and looks at the over-gate sign; with a mission
on it picks a gate with a MissionWorld door. Shots: `ingame_dark_road.png` (with `mission=doors`) and
`ingame_dark_road_nomission.png`.

## Numbering
Number = section deck index + 1, two digits. The top deck, with the entry portal, is 01. The mission HUD's
"DECK n OBJECTIVES" (`mission_hud.gd`) uses the same rule. A district on its own (no section) shows nothing.
`CitySigns.force_number` can force a number there (used by the tests).

## Where
- **Beside every boundary-wall gate** (blast doors, wave gates, portals, collapsed gates), on both sides where the wall
  allows, on bulkhead and farm walls.
  - The lettering's near edge is at least `GATE_CLEAR` = 5 m past the gate's edge. That clears a MissionWorld bunker's
    jambs and sloped buttress feet (`MissionProps.GateDoor`: up to 4.6 m past the opening's post, 2 m out of the wall).
  - On the gate's right as seen from the street (+X of `MissionProps.gate_frame`) the clearance is `GATE_CLEAR_PIER` =
    11.6 m, past the bunker's sign pier (8 m tall, 1.6 m out). I chose to keep clear of the pier rather than put the
    lettering on it: the pier's 6 x 4 m panel is smaller than a wall sign and exists only with a mission.
  - The sign must lie within `MAX_REACH` = 18 m of that clearance and at least 3 m from the wall's ends, or that side gets
    none.
  - Bulkheads: the sign is centred in a bay between two buttress posts (12 m bays along the arc, 14 m across it).
  - Farm walls: the lettering stands on a plain panel with its face 1.0 m out (the racks' leaves reach 0.8 m), so it never
    covers a rack.
  - Window walls (the hull, only on a district on its own) carry none: their glazing starts 8 m up.
- **Over every freight lift door**, on a panel above the door's lamps (bottom 10.4 m, 0.9 m out of the core). Beside the
  door, the leaves slide over the face when they open (`MissionProps.LiftDoor`), and the face is all pilasters.
- **Both ends of every ramp**, on a panel hung from the ceiling on two rods, about 10 m up (over a mech), with no
  collision.
  - On the deck the ramp leaves: 4 m into the cut, facing the way in, showing an arrow down and the deck below.
  - On the deck it lands on: 4 m past its foot, facing the way in, showing an arrow up and the deck above.
  - The back shows this deck ("DECK 02"), for whoever arrives by the ramp.
  - Where a ceiling opening (snapped to 12 m panels) is over that spot, the sign moves further along the way in, 4 m at a
    time.
- **Over every open-air shaft**, the same hung panel at the shaft's middle, showing an arrow down and the deck below on
  both faces. A shaft has no wall or pillar near it (it stands in an open plaza cell), so a hung panel is the simplest
  readable thing.

Sizes:

| Sign | Numeral height | DECK height | Height on its surface |
|---|---|---|---|
| Wall | 5.8 m | 1.45 m | white numeral bottom at 4.5 m; dark panel from 2.9 to 13.3 m (under the gallery band at 15.4 m and the farm light bars at 14.2 m) |
| Lift | 3.6 m | | |
| Hung | 4 m | | |

Counts per deck (sections 1, 4, 403112): 18 to 31 signs, of which 10 to 18 are side signs, 5 to 9 over-gate signs (one
per gate), 1 or 2 lifts, 0 to 2 ramp ends and 0 or 1 shaft.

## Seen from down the road: the over-gate sign (2026-11-24)
A sign 5 m beside a gate at a road's end is behind the corner block until you are close, when you walk up that road
toward the gate. The side signs read from the perimeter road along the wall and from open ground (parks, plazas), so they
stay. Every wall gate, portals included, also gets a sign centred **above** it, on the wall over the lintel (kind
`over_gate`, `CitySigns._over_gate`):
- **Width**: the panel is `OVER_SHARE` = 0.6 of the gate's width. Its numeral is 4-8 m (`OVER_U` 0.4-0.8), smaller if the
  ceiling is close.
- **Bottom**: at least `OVER_CLEAR` = 5.7 m over the gate's top. That clears a MissionWorld bunker's lintel (3 m), the
  beacon housings (0.4 m) and beacons (1.3 m) standing on it (`MissionProps.GateDoor`), with 1 m to spare. It also clears
  the baked hazard frame (gate top + 1.6 m).
- **Bulkheads**: the bottom is also at least `OVER_MIN` = 17.2 m, over the gallery band (15.4-16.6 m), which runs across
  the gates. In practice that puts the bottom at 17.2 m over 9 m gates and 19.7 m over 14 m spine gates.
- **Top**: at least `OVER_TOP` = 4 m under the ceiling.
- **Farm walls**: on the proud panel, like the side signs. Its box stands in front of the light bar at 58 % of the
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
- **Cost** with the over-gate signs: per deck, 1.8k to 3.3k triangles for the dark look (it was 1.3k to 2.4k without
  them) and 2.9k to 5.6k for the white look (a deck is about 270k to 360k). About 70 triangles for a numeral pair with its
  outline.
- **Colours** (`CityPalette`): `sign_white`, `sign_outline`, `sign_panel`, `sign_cream`, `sign_stripe`. The white look's
  panels (farm, lift, hung) are `concrete`.

Tests: `tests/test_city_signs.gd`.
