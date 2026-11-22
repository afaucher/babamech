# City rooftops: collision, standable structures and destructible roof clutter

Playtesting on building roofs surfaced three issues: landing on the front portico roof of the pillared civic hall falls
straight through, rooftop stair/plant bulkheads on office buildings have no collision, and rooftop clutter (water towers,
AC units, vents, planters, skylights) can be walked and shot straight through. **Design & implementation plan based on a
read-only audit of `scripts/world/city/` (2026-11-22); code belongs to the Environment session.**

---

## 1. Current state (audit)

`CityDistrict._build_collision()` (`scripts/world/city/city_district.gd:249-266`) generates building collision **only**
from `b["tiers"]` (one `BoxShape3D` per tier), `b["core"]` (pillar shafts), and `plan.columns` (park column trunks).
Everything else drawn in `scripts/world/city/city_buildings.gd` is visual-only with zero collision.

| Style | Planned `tiers` (`city_plan.gd:711-753`) — **solid today** | Uncollided roof / upper geometry (`city_buildings.gd`) — **no collision** |
|---|---|---|
| `civic` | `tiers[0]` plinth (`0..1.2 m`); `tiers[1]` recessed hall (`1.2..roof`, shifted back `-n * 2.5`) | **Front portico entablature** (`L386-388`, `(w-1.0) x 1.2 x (z_front-z_back)` at `roof-1.2..roof`, extending **6.3 m forward** past `tiers[1]` + `1.0 m` sides + `0.3 m` back); **pitched gable roof** (`L389`, `rise = 2.8 m` above `roof`, `9.5-17.8 deg` slope); **portico columns** (`L379-385`, `1.2..roof-1.2`); **front plinth steps** (`L368-370`, `2.2 m` forward). |
| `apartment` | `tiers[0]` main box (`0..roof`); `tiers[1]` stair bulkhead (`roof..roof+2.8`) | Roof clutter (`L237`: `tank` 2x, `ac`, `vent`); `0.5 m` parapet (`L230`); facade balconies & entrance canopy (`L213, L225`). |
| `office` | `tiers[0]` main; optional `tiers[1]` penthouse (`size-(5,5)`) | **Roof plant room / stairwell bulkhead** (`L258-260`, `(0.4w) x 2.4 m x (0.35d)` on every office with top tier >= `9 x 9 m`); roof mast (`L261-262`, `3.2 m` pole); roof clutter (`L263`: `ac` 2x, `vent`); `0.5 m` parapet & pier tops (`L280, L285`). |
| `sage` | `tiers[0]` main; optional `tiers[1]` penthouse (`size-(6,6)`) | Roof clutter on `tiers[0]` (`L318`: `planter` 2x, `skylight`) and `tiers[1]` (`L320`: `ac`, `vent`); `0.5 m` parapet (`L313`). |
| `shops` | `tiers[0]` main (`0..6.5 m`) | Stepped street-side parapet crown (`L349`, `0.4w x 0.7 m x 0.2 m` rising to `roof + 1.3 m`); `0.6 m` parapet (`L352`); roof clutter (`L353`: `ac`, `skylight`, `vent`); ground awnings (`L343`). |
| `pillar` | Non-lift: `tiers[0]` podium + `core` shaft. Lift: `core` shaft only. | Podium clutter (`L449`: `planter`, `ac`); `0.5 m` podium parapet (`L420`); ceiling capital (`L454-459`). |
| Park `column` | `plan.columns` trunk (`2r x (ceiling+2) x 2r`) | Planted stone base ring (`L466`, radius `r + 1.6`, `0..0.7 m`); upper flare & ceiling capital (`L468-469`). |

### Existing clutter-overlap bugs (found during audit)

`CityBuildings._clutter()` (`city_buildings.gd:157-182`) samples random positions across the whole tier rectangle without
excluding taller structures standing on that same tier. As a result, clutter currently clips inside solid/visual roof
structures in four places:
1. **Apartments (`L237`)**: clutter on `tiers[0]` spawns inside `tiers[1]` (the stair bulkhead).
2. **Offices (`L263`)**: clutter on the top tier spawns inside the centered roof plant room (`L258-260`).
3. **2-tier Sage blocks (`L318`)**: planters on `tiers[0]` spawn inside `tiers[1]` (the penthouse).
4. **Pillar podiums (`L449`)**: planters and AC units on `tiers[0]` spawn inside the pillar `core` shaft.

---

## 2. Choices

| Category | Items | Plan | Why |
|---|---|---|---|
| **Solid, standable architecture** | Civic entablature + gable roof + portico columns + front steps; Office roof plant room; Skylights; Park column planter ring | Static `StaticBody3D` shapes in `CityDistrict._build_collision()` driven from `CityPlan` | Permanent load-bearing structure: mechs must stand on roofs, bulkheads and the civic portico, take real cover behind columns, and have collisions verified by `CityPlan.checksum()`. |
| **Knockable / destructible roof clutter** | Water tanks (`tank`), AC units (`ac`), vents (`vent`), rooftop planters (`planter`) | Extend `CityProps` (`city_props.gd` + `city_prop_sim.gd`) to place and simulate props on flat building roofs | Reuses existing deterministic closed-form topple/slide, MultiMesh batching, `first_hit()` weapon blocking, `blast()` splash, `prop_moved` audio/FX hook, and host-arbitrated co-op sync (`prop.req` / `prop.ev` / `prop.sync`) — zero new net protocol or `RigidBody3D`s. |
| **Purely cosmetic** | `0.5 m` roof parapets, shallow facade ledges/balconies, ground awnings, high ceiling capitals | Leave without collision | Stepping over a `0.5 m` parapet rim while jumping between roofs should stay smooth and snag-free. |

---

## 3. Phase 1 — Solid architectural collision (`CityPlan`, `CityBuildings`, `CityDistrict`)

### 3.1 Civic Hall (`_civic`)
- **Portico entablature**: add an entablature tier in `CityPlan._build_tiers()` (`city_plan.gd:741-746`) matching
  `city_buildings.gd:386-388`: size `(w - 1.0) x (z_front - z_back)` (in building-local oriented axes), `y0 = roof - 1.2`,
  `y1 = roof`. This makes the entire 6.3 m front portico roof and side eaves solid and forms a real underside ceiling when
  walking between the pillars.
- **Pitched gable roof**: store a `"gable"` descriptor on civic buildings (`{off, w: w - 0.6, d: d - 0.8, y0: roof, rise: 2.8, front}`)
  and build a 6-vertex `ConvexPolygonShape3D` (or two tilted `BoxShape3D` slope slabs) in `CityDistrict._build_collision()`.
  The roof pitch (`atan(2.8 / (0.5 * (w - 0.6)))`) is `9.5-17.8 deg`, comfortably walkable for `CharacterBody3D` mechs so
  they walk cleanly over the ridge instead of sinking 2.8 m inside it.
- **Portico columns & front steps**: emit `BoxShape3D`s in `_build_collision()` for the stone columns (`1.2..roof-1.2`,
  exact spacing from `city_buildings.gd:380-385`) and a low ramp/stepped box for the 2.2 m front plinth steps (`0..1.2 m`).

### 3.2 Office roof plant room / stairwell bulkhead
- Move the office plant room `(ts.x * 0.4) x 2.4 m x (ts.y * 0.35)` from `city_buildings.gd:258-260` into
  `CityPlan._build_tiers()` whenever the office's top tier has `min(ts.x, ts.y) >= 9.0` (matching the existing apartment
  stair bulkhead pattern at `city_plan.gd:721-724`).
- `CityBuildings._office()` then renders it from that tier, `CityDistrict._build_collision()` makes it solid and standable
  automatically, and clutter avoidance automatically excludes its footprint.

### 3.3 Skylights, park column base rings & clutter exclusion
- **Skylights (`2.4 x 1.1 x 3.4 m`)**: keep as static architectural roof openings (anchored to the slab; sliding them like
  loose props would look wrong). Record planned skylight rects in `CityPlan` (or a per-building `"roof_boxes"` array) and
  emit low walkable `BoxShape3D`s in `_build_collision()`.
- **Park column planted base ring**: add a `(2r + 3.2) x 0.7 x (2r + 3.2)` `BoxShape3D` around each `plan.columns` entry in
  `_build_collision()` so mechs step onto or stop against the stone planter curb rather than clipping through it.
- **Clutter obstacle exclusion**: pass every upper tier's footprint + pillar `core` footprint (inflated by item half-size +
  `0.6 m` margin) as forbidden rects to roof clutter placement (both static skylights and `CityProps` roof items). Fixes all
  4 overlap bugs in section 1.

---

## 4. Phase 2 — Destructible / knockable rooftop props (`CityProps`, `CityPropSim`, `CityBuildings`)

Move the 4 loose roof clutter types (`water_tank`, `ac`, `vent`, `planter`) out of static `CityBuildings._clutter()` and into
`CityProps.layout(plan)` (covered by `CityProps.layout_checksum()`).

### 4.1 Proposed rooftop prop types (`CityProps.TYPES`)

| Type | Mass (kg) | Contact radius | Height | Falls in | Rests at | Topples from weapon at | Notes |
|---|---:|---:|---:|---:|---:|---:|---|
| `water_tank` | 1800 | 1.40 m | 4.3 m | 1.0 s | 82 deg | `dv >= 4.0` | Heavy wooden/steel tank on 4 legs; optional water-burst FX + sound via `prop_moved`. |
| `planter` | 900 | 1.10 m | 1.4 m | 0.6 s | 90 deg | `dv >= 3.0` | Concrete curb + bushes; slides short distance when shoved. |
| `ac` | 600 | 0.90 m | 1.3 m | 0.5 s | 90 deg | `dv >= 2.5` | Rooftop HVAC pad + housing. |
| `vent` | 120 | 0.45 m | 1.1 m | 0.4 s | 90 deg | `dv >= 1.5` | Light hexagonal metal stack; easy to knock over & kick around. |

### 4.2 Five required extensions to `CityProps` & `CityPropSim`

1. **Flat building-frame placement on curved decks**:
   - Street props use `geo.frame(x, s, h)` (curved ring surface). Building roofs are flat planes in `building_frame(i)`; an
     off-center roof prop placed in curved arc coordinates floats/sinks by `dz^2 / (2R)` (~`17 cm` at 10 m off-center).
   - Add optional fields on roof prop entries: `"building": i` (default `-1` for street props), `"tier": t_idx`, and
     building-local `lx, lz, ly` (plus roof clamp rect). `transform_of()` places roof props in `building_frame(i)` and maps
     their world coordinates cleanly through the district's `global_transform` (preserving multi-deck `CityStack` support).
2. **Keep fallen roof props on their roof (`slide_length` / `pose_of`)**:
   - Today `pose_of()` (`city_props.gd:365`) resets `p["h"] = CityPropSim.floor_at(_floors, x, s)`, which only knows street /
     sidewalk / plaza heights (`0..0.9 m`). Without a fix, hitting a roof prop would teleport it straight down to street level!
   - For roof props (`building >= 0`), keep `h` pinned to the roof tier's `y1`, and clamp `slide_length()` against the tier's
     inner parapet bounds (and any obstacle sub-rects like stair bulkheads / plant rooms / pillar cores) so shoved roof props
     slide across the roof and stop cleanly at the parapet edge.
3. **Tighten vertical pusher contact check (`city_props.gd:27, 720`)**:
   - Today's `absf(at.z - pose.h) < 6.0` is a symmetric 12 m window — a mech walking on the street or jumping beside a `6.5 m`
     shop could knock over props on the roof above (or vice versa across tiers).
   - Replace with vertical interval overlap: `[mech_foot_h, mech_foot_h + mech_height]` overlaps `[prop_h, prop_h + prop_height]`
     (with a small `0.3 m` tolerance).
4. **Closed bottom caps on all roof prop meshes**:
   - Currently `_water_tank` legs (`city_buildings.gd:135`), `_ac_unit` (`L128-129`), `_planter` box (`L142`) & bushes
     (`L146`), and `vent` (`L181`) use `NO_BOTTOM` or uncapped `prism`.
   - Switch their `CityProps._proto()` builders to `CityGeo.ALL` / bottom-capped prisms so toppling them 82–90 deg never
     exposes a hollow underside (automatically verified by `tests/test_geometry_audit.gd`).
5. **Spatial hash & networking**:
   - Roof props register into the existing 16 m 2D spatial hash grid (`city_props.gd`) with zero per-frame overhead when
     standing/resting, and sync over the existing `prop.req` / `prop.ev` / `prop.sync` events (no wire format change needed
     if `from: {x, s, lie}` stores local roof `(lx, lz)` when `building >= 0`).
   - Water-tank destruction flavour: if a burst/shatter look is desired on topple, `prop_moved("water_tank", world_pos)` can
     trigger a local cosmetic splash/debris burst + metal crash SFX without needing a separate HP/target system.

---

## 5. Open decisions (confirm with user before coding)

1. **Water tanks / AC units / vents / planters**: knockable/toppleable `CityProps` (with optional water-splash burst FX on
   water-tank topple), or solid static cover?
2. **Skylights**: solid walkable static `BoxShape3D` bumps on the roof, or breakable glass later?
3. **Roof trims**: keep `0.5 m` parapets non-colliding for smooth rooftop hopping, and add collision only to the taller
   `1.3 m` stepped shop crowns (or keep shop crowns cosmetic too)?

---

## 6. Checksum & test plan

- **Checksums**: adding the civic entablature/gable and office plant room to `CityPlan` will intentionally update
  `CityPlan.checksum()` (and moving roof clutter to `CityProps` updates `CityProps.layout_checksum()`). Update golden
  checksum tests only once in the same commit/pass, keeping determinism across runs and machines intact.
- **Tests to add/extend**:
  - `tests/test_city.gd`: raycast down onto every civic hall's front portico roof (`tiers[1]` forward extension) and gable
    ridge -> hits solid floor with no fall-through; raycast onto every office's roof plant room -> hits at `roof + 2.4 m`;
    raycast into portico columns & park column base rings -> hits solid; verify zero roof clutter overlaps any upper tier,
    stair bulkhead, plant room, or pillar core across seeds `1..5`.
  - `tests/test_city_props.gd`: verify rooftop props spawn flush on `building_frame(i)` on curved decks (error `< 0.02 m`);
    toppling and shoving a roof prop keeps its height pinned to the roof tier and clamped inside the parapet (never snaps to
    street `floor_at`); a mech on the street below a `6.5 m` shop cannot accidentally topple props on its roof; `first_hit()`
    and `blast()` work on roof props in both standalone and offset `CityStack` districts.
  - `tests/test_net_props.gd`: verify roof prop topple/shove syncs identically across host + client peers.
  - `tests/test_geometry_audit.gd`: verify all new rooftop `CityProps` prototypes (`water_tank`, `ac`, `vent`, `planter`)
    have closed bottom caps and valid outward winding.

---

## 7. As built (2026-11-22, Environment session)

Built with the section 5 choices: tanks, AC units, vents and roof planters are knockable `CityProps` (no burst FX;
`prop_moved` fires as for street props); skylights are solid static bumps; 0.5 m parapets and the shop crowns stay
without collision.

### Gameplay shape is plan data
Everything new and solid is data in `CityPlan`, covered by `checksum()`; `CityBuildings` draws it from that data and
`CityDistrict._build_collision()` builds the collision from the same numbers.
- **Tiers** may carry `kind`: `"plant"` (office plant room) or `"entablature"` (civic portico beam box).
- **Office plant room**: a tier `(top.x * 0.4) x (top.y * 0.35)`, 2.4 m tall, on the top roof when `min(top) >= 9 m`,
  `stand` true (false above `stand_limit()`, like the apartment stair bulkhead).
- **Civic hall**: tiers plinth, hall (`stand` now **false**: its flat top is under the gable), entablature
  (`off = n * 0.5`, `(d - 1.4) x (w - 1.0)`, `roof - 1.2 .. roof`, `stand` false); `b["gable"] = {off, w: w - 0.6,
  d: d - 0.8, y0: roof, rise: 2.8, front}` (collision: a 6-point `ConvexPolygonShape3D` matching the drawn roof, ridge
  front to back); `b["solids"]` holds the portico columns (`1.2 x 1.2` boxes, `1.2 .. roof - 1.2`) and the four front
  steps (0.3 m risers, 0.55 m treads).
- **Skylights**: `b["solids"]` entries of kind `skylight` (2.4 x 3.4 m, a quarter turn by the plan roll), placed from the
  plan's gameplay stream on the roofs whose slot lists a skylight (sage single tier, shops), clear of the roof edge and
  of what stands on the roof. **Solid height 0.4 m** (the concrete curb); the 0.7 m glass ridge on top is drawn only.
  A full-height hull was tried: the test drive's capsule (radius 2.2 m, 8 m, step-up 1.2 m) wedged against a glass
  gable end or a hipped ridge; on the 0.4 m curb it walks on and off from all four sides (`test_city` `_skylight_walk`).
- **Park columns**: entries carry `ring_r` (r + 1.6) and `ring_h` (0.7); the planted ring is an octagonal convex prism.
- `CityPlan.roof_slots(i)`, `roof_rect(i, t)`, `roof_blockers(i, t)` describe the roof units' roofs and what stands on
  them (tiers on the tier, the pillar core + 0.5 m, skylights). Skylight and prop placement both use them: the four
  clutter-overlap bugs of section 1 are gone.
- `reachable_roofs()` and the bands are unchanged for seeds 1-5 (golden in `test_city`); the plant room is an extra
  standable tier only.

### Roof props
- New `CityPropSim.TYPES` `water_tank`, `planter`, `ac`, `vent` (section 4.1 numbers), appended to `TYPE_ORDER`.
- `CityProps.layout(plan)` appends them **after** the street props (street ids unchanged) from their own stream
  (`cosmetic_seed() + 2`): per roof slot as many tries as the old clutter, 3.6 m apart, clear of `roof_blockers` by the
  unit's footprint + 0.6 m. Item fields: `building`, `tier`, `lx`, `ly`, `lz` (building frame); `x`, `s`, `h` are the same
  spot in arc coordinates. `layout_checksum` hashes the roof fields too.
- A roof prop is placed in `CityProps.building_xf()` (the same transform as `CityDistrict.building_frame(i)`), so it
  sits flush on the flat roof on a curved deck and follows the district's `global_transform` (stacks, moved districts).
- Its pose `x / s` are roof-local `(lx, lz)` and event directions are in the building frame. **Wire format unchanged**
  (same `prop.req` / `prop.ev` / `prop.sync` payload keys and snapshot bytes); only the meaning of `x / s` in a roof
  prop's `from` pose and snapshot entry is roof-local.
- Its height stays its roof's; a shove slides it inside its tier (`CityPropSim.slide_in`) and stops at what stands on
  the roof or at the roof's edge: **a roof prop shoved to the edge stops there, it never falls off.** A toppled tank may
  lie partly over the parapet or against a bulkhead (cosmetic).
- Pushers: street props keep the old check (`|feet - h| < PUSH_HEIGHT`); a roof prop is reached only when the pusher's
  `[feet, feet + PUSH_HEIGHT]` meets the prop's height span (0.3 m tolerance) in the roof's frame: a mech in the street
  under a 6.5 m shop does not reach its roof units, one on the roof does.
- The prototypes (`CityBuildings.roof_unit`) are closed underneath (base caps checked by `test_geometry_audit`).
- `CityBuildings` keeps consuming the cosmetic stream exactly as the old roof clutter did, so building colours are
  unchanged.

### Checksums and counts
- Plan `make({seed: 1})` `209989488eaa0e52` (was `c2d5556be15dbd6e`); with `walls: 1` `e4ec580da1956459` (was
  `bf6b10f3898d9732`); props `layout_checksum(layout(make({seed: 1})))` `7e78d4e1e3db1a61` (was `e8f839c8369dd0db`).
- Seed 1 stand-alone: 380 -> 420 collision shapes, 252 886 -> 252 900 triangles, 485 -> 541 props. Stack seed 4
  (3 decks): 5 219 -> 5 355 shapes, 1 317 060 -> 1 313 070 triangles, 3 015 -> 3 402 props.

### Audit claims that did not hold
- `prop_moved` is `prop_moved(id, type, kind, world_pos, speed)`, not `(type, world_pos)`.
- Section 4.2.3: with the old symmetric 6 m window a mech standing in the street could not reach props on a 6.5 m roof
  (6.7 m above its feet); only a jumping mech or one on a lower roof could.
- Line numbers had drifted a little; the facts in the section 1 table (sizes, offsets, the 6.3 m portico) held.

### Notes for other owners
- `EnemySpawner._rooftop_candidates` / `BotNavigator._build_city_roofs` read `stand`: the civic hall is no longer a
  candidate (its top is under the solid gable), and an office plant room of 7 m or more becomes the top standable tier.
