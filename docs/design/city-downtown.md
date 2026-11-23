# Downtown zone

Decision (user, 2026-11-23, from `city-downtown/grid_downtown.png`): "I like a mix of environment 1 & 4, the goal is
towers are similar but base layout has variety changing sightlines and roof perches." Earlier: "tall = touching the
ceiling, not a taller deck". Concepts: `city-downtown/downtown_slabs_podium_s47.png` (1) and
`downtown_points_podium_s47.png` (4).

Downtown is a **zone**: a contiguous group of blocks on a deck whose buildings are ceiling-touching towers on varied
bases. The rest of the deck stays the mixed urban district (`city-styles.md`). Same streets, same 40 m ceiling.

## 1. The tower family (similar everywhere)

One family, so downtown reads as one place:

- **Materials**: cream / sand concrete frame, sky-blue glass, the pillar tower's palette. No terracotta towers.
- **Two widths of the same design**: the **slab** (broad, about 18-26 m on its long side, pier-and-spandrel grid with glass
  ribbons, concept 1) and the **point** (slender, about 9-13 m square, vertical fins with tall glass strips, concept 4).
  Mix by seed, about 40 % slabs / 60 % points; never two slabs facing each other across a street (they wall the view).
- **Every tower reaches the ceiling** and ends in the same flared collar and drop panel the pillar towers use. Towers on
  the site's structural pillar points are the real pillars (unchanged rule); the others carry the same collar as looks.
- **Not standable** above the base (as pillars today). A band line every two storeys, as on the pillar shaft.
- Set back from the building line by at least 6 m on the street sides (the base fills the setback or leaves it open).

## 2. Base layouts (the variety)

Each downtown lot gets one base, chosen by seed. Neighbouring lots on a block face never get the same base, and each
block must contain at least three different bases. Roof heights are the roof bands (6.5, 13, 19.5 m), so the hop rule
(`city-styles.md`, "every roof is reachable") applies unchanged.

| Base | Shape | Sightline at mech eye (8 m) | Perches |
|---|---|---|---|
| **Podium** | One-band (6.5 m) shop podium out to the building line, tower rising from its middle or back | Over the podium roof, past the shaft | A wide 6.5 m roof round the tower |
| **Stepped podium** | 6.5 m podium with a 13 m terrace against the tower on one or two sides | Over the low part only | Two heights, a hop apart |
| **Plaza** | No podium: paved plaza with planters and benches in the setback, tower lobby at ground | Open at ground level right up to the shaft | None (the open ground is the point) |
| **Corner cut** | L-shaped podium on two sides, open plaza on the street corner | Diagonal across the corner | 6.5 m L roof |
| **Twin** | Two point towers on one shared podium with a gap of at least 8 m between them | A slot between the shafts | 6.5 m roof, including the slot |
| **Arcade** | Tower on a three-storey colonnade (9.75 m clear, columns at least 8 m apart) along one street side: a mech can walk under it | Through the columns | The arcade roof at 13 m |

Rules that make the variety matter:

- **A through view per block**: every downtown block has at least one line a mech can see along, at 8 m eye height,
  from one street to the opposite street (through a plaza, a corner cut, a twin's slot, an arcade, or a mid-block gap of
  at least 8 m between two bases). Checked in the plan, not hoped for.
- **Perch spread**: every downtown block has standable roofs at two or more different band heights, and no block is all
  plazas.
- **Cover rhythm**: tower shafts are the hard cover; no two shafts closer than 10 m, so a mech always fits between.

## 3. Where downtown goes

- A deck of a section gets **zero or one downtown zone**: a seeded contiguous cluster of blocks, about a third of the
  deck's blocks, grown from a block next to the avenue. Not on every deck: by seed, about two decks in three.
- The park block and the civic hall stay; downtown may border them (the civic hall facing the park is a good edge).
- A district on its own (lab, test drive): param `downtown` 0..1 = share of blocks in the zone, default 0, so the
  stand-alone golden checksums do not change.
- Zone membership is plan data (`block["zone"] = "downtown" | "urban"`), in the checksum, the same on every machine.

## 4. Gameplay shape

- Bases, towers, columns and the arcade are plan tiers with collision, in the checksum. Plaza furniture is street
  props (destructible, host-arbitrated) where it is loose, cosmetic where fixed.
- Arcade: columns collide, the space under is walkable; its ceiling is 9.75 m so the mech capsule (8 m) passes with
  the same 1.5 m margin as the ramp bridge rule.
- Enemy and bot navigation keep using the road graph in v1; plazas and arcades are extra room, not graph edges.
- Mission sites, life doors and spawn slots already avoid building footprints from plan data; nothing special.

## 5. Budgets

- Triangles: a deck with a downtown zone may be at most 15 % heavier than the same deck without one. Tower facades are
  coarse on purpose (fins and strips on points; piers every 3.2 m but spandrels every two storeys on slabs).
- Build: every build chunk stays under about 20 ms on the host PC (`stack.chunk_log`).
- No new lights. Quality levels unchanged.

## 6. As built

Landed 2026-11-23 (Environment session subagent). Code: `scripts/world/city/city_plan.gd` section "Downtown",
`city_buildings.gd` section 7 (`_tower`), `city_streets.gd` (plaza paving, planters, ceiling pads), `city_district.gd`
(weighted building chunks), `city_lab.gd` (param and cameras). Test: `tests/test_city_downtown.gd`. Shots: `city-downtown/built_*.png`.

**What exists**

- **Zone placement** (`CityPlan._downtown_zone`): its own generator (seed, deck), never the plan's `_rng` before the
  zone, so a deck without a zone is byte-identical to before. A section deck rolls a zone with chance 0.67 (`DT_DECK_CHANCE`),
  target a third of its blocks (`DT_SHARE`: 6 of 18), grown from a random eligible block on the spine through urban or
  industrial neighbours. Overrides `{"downtown": x}` on `for_deck` force share x (0 = none: the budget comparison). On its
  own, param `downtown` 0..1 (default 0) is the share. Membership is `block["downtown"] = true` (and `base` on each
  building), both in the checksum only when set.
- **Block layout** (`_dt_design`, pure; also the eligibility test): pillar lots as `_carve`; a **through-view lane**
  chosen per block (a line across the block beside every core) at which the pieces are cut, a paved 9 m mid-block gap there
  one time in three; lots of 21..42 m; each lot's **shaft room** (6 m back from the street, half the 10 m spacing from
  the next lot's room, 10 m from a core, the lean of a 41 m box on the curved deck, its drop panel clear of ceiling
  openings); the bases each lot can take; then a bounded seeded search: neighbours on a block face differ, 3+ kinds a
  block, standable roofs at 6.5 and 13 m. A block that cannot meet them stays urban.
- **Bases** as plan tiers and solids (collision from the same numbers): podium (6.5 m), stepped (6.5 m podium + 13 m
  terrace against the shaft on one or two street sides, 1.5 m lip), plaza (shaft at ground, lot paved, two planters),
  corner (open plaza lot on the street corner + L podium as two lots, the tower on the long leg), twin (two points, slot
  >= 10 m on the podium roof), arcade (lobby 0..9.75 m, roof slab 9.75..13 m over the whole lot, 1.2 m columns 8 m clear
  along the street, the tower standing on the 13 m roof). A pillar in the zone gets podium (6.5 m) or plaza (bare core).
- **Towers**: tier kind `tower` (`tower`: slab | point) from the base up to ceiling + 1, `stand: false`. Slab 18-26 x
  10-13 m, piers every 3.2 m, spandrel every two storeys; point 9-13 m, broad corner piers, centre fin, two glass strips,
  band line every two storeys; all cream / sand frame and sky-blue glass, ending in `CityBuildings.capital` (collar,
  flare, drop panel). `CityPlan.ceiling_heads()` adds every shaft's drop panel to the pillars' so ceiling strips and ducts
  stop there.
- **Rules readable for tests** (`downtown_blocks`, `through_views`, `perch_heights`, `shaft_rects`, `tier_rect`,
  `ceiling_heads`, `shaft_head`).
- **Lab**: param `downtown` (on a section / stack site 0 = by seed), cameras `downtown_avenue`, `downtown_perch`,
  `downtown_plaza`, `downtown_arcade`, `downtown_top` (ceiling and the other decks hidden).

**Numbers** (section seeds 1-12: 25 of 36 decks have a zone, 1 to 6 blocks)

| deck | zone blocks | triangles with zone | without | |
|---|---|---|---|---|
| s1 d0 | 1 | 287 483 | 284 475 | +1.1 % |
| s1 d1 | 0 | 326 536 | 326 536 | 0 |
| s1 d2 | 4 | 297 274 | 326 440 | -8.9 % |
| s4 d0 | 0 | 306 831 | 306 831 | 0 |
| s4 d1 | 3 | 344 264 | 356 588 | -3.5 % |
| s4 d2 | 6 | 302 601 | 346 817 | -12.7 % |

Towers replace terracotta apartments (balconies are the heaviest facade), so a zone makes a deck lighter. Build chunks:
the slowest are still `ground 4/8` (23-28 ms on a busy PC, the same without zones); building chunks count a tower as 4
buildings (`CityDistrict.TOWER_WEIGHT`) and stay out of the top five. Bases over 8 seeds: podium 69, plaza 59, stepped
56, arcade 37, corner 5, twin 5.

**Deviations and why**

- Membership is `block["downtown"]`, not `block["zone"]`: in section mode `zone` is the section's cell zone and other code
  and tests read it (`test_city`, `test_section_plan`).
- Industrial cells may join the zone (they are urban lots for now); a block joins only if its layout meets every rule,
  so short pillar cells (a 26 m pillar lot leaves pieces too shallow for a tower 10 m from the core and 6 m from the
  street) never join, and zones are often smaller than a third (1-6 blocks). Missions may want to own which decks /
  cells are downtown later (`SectionPlan` zone "downtown"); today it is derived on the city side from section seed + deck.
- On its own, a district with `downtown > 0` plans its grid with blocks of at least 62 m (`DT_BLOCK`): a 44 m block
  holds one tower each way, not three bases.
- Corner cuts and twins are rare: they need a 30 x 30 m corner lot or a 28 m shaft room.
- The through view is checked axis-aligned (lines along x or s at 0.5 m steps, a 2 m corridor, at least 6 m inside the
  building line, blocked by anything spanning 8 m: tiers, shafts, columns, cores). Diagonal views through corner cuts are
  extra, not counted.
- Plaza furniture: the two planters are fixed and cosmetic (no collision), like an open plaza's; loose props come only
  in open plaza lots (corner plazas, mid-block gaps) through `CityProps.layout`.
- Enemy code treats the arcade roof tier as solid down to the ground (cover / spawn footprints); conservative.

**Not enforced**: "about a third" (zone size is what eligible contiguous blocks allow); the 40 / 60 slab / point mix (a
slab needs an 18 x 10 m room; roughly a third of shafts are slabs).

### Pass 2 (2026-11-23, Environment session subagent): density, family looks, distinct bases

Review of pass 1: a few scattered towers in open ground, zones of 1-6 blocks, slabs dominating, points hard to read,
bases alike at eye level. Stats tool: `tools/city_downtown/dt_stats.gd` (`--seeds 1-12 --map --why`); shots
`tools/city_downtown/shots.ps1` -> `city-downtown/pass2_*.png`.

**Plan** (`city_plan.gd` "Downtown")

- **Pillar cells join.** Almost every urban section cell holds an 18 m pillar core, and pass 1 failed them ("fewer than
  three lots with a base": 76 of the eligible blocks over seeds 1-12). Three causes, three fixes: (1) the core spacing
  was measured axis by axis, so a tower diagonally off a core was refused: `_dt_avoid` now keeps 10.5 m face to face
  (Euclidean) and finds the largest room anchored at a corner of the lot's room (analytic per width, 0.5 m steps);
  (2) `_carve_geom` cut full-length strips beside the core (12-13 m wide: no room after the 6 m setback): it now also
  cuts full-width bands first (`first` 1) and `_dt_design` keeps whichever layout holds more based lots; (3) points go
  down to 8 m square (`DT_POINT.x`). A block of two based lots (pillar + one tower) joins when both differ (the
  ">= 3 bases" rule relaxed for two-lot blocks). Still failing over seeds 1-12: 4 pillar blocks ("fewer than two lots
  with a base": the core leaves no 8 m room anywhere 6 m from the street).
- **Zone size.** The zone starts at an avenue block whose cluster can reach the target (else the biggest), and grows
  through side neighbours, then corner-to-corner neighbours across a crossing when no side neighbour can join
  (deviation: "contiguous" now includes blocks that share only a crossing; urban cells are scattered among parks and
  transit cells). Seeds 1-12, zone blocks / deck blocks on zoned decks: before 9 decks at 0.06, 3 at 0.11, 2 at 0.17, 1 at
  0.22, 1 at 0.28, 9 at 0.33; after 5 at 0.28, 20 at 0.33 (25 of 36 decks zoned, as before).
- **Shafts per block** (pillar cores and twins included), seeds 1-12: before {3: 51, 4: 1, 5: 17, 6: 13, 7: 1, 8: 1};
  after {2: 12, 3: 44, 4: 89}. `DT_MAX_SHAFTS` 4: past it the tightest rooms become open lots, and a twin is offered
  only while the block has fewer than four based lots.
- **Wings** (`_dt_wings`): an open lot left beside a podium-like base (podium, stepped, twin, corner, a pillar's
  podium) becomes that base's low wing (6.5 m podium on its own lot, same `unit`, `wing` true) three times in four,
  unless it would put two lots of one base side by side on a street. This is the continuous street wall of the
  concepts; at 6.5 m it never closes a through view (seen over at 8 m). The through view's paved gap stays open.
- **Slabs** 37 % of towers (seeds 1-12; `DT_SLAB_CHANCE` 0.9 where an 18 x 10 m room fits, tight rooms are points).
- **Diagonal views** (`diagonal_views(bi)`): 45-degree lines on a 1 m step whose stretch inside the building line is
  at least 20 m (`DT_DIAG_MIN`) and whose 2 m corridor clears everything rising past 8 m. Counted, not required (the
  axis-aligned view per block stays the rule): every zone block over seeds 1-8 has one, all 11 corner-cut blocks too
  (low podiums do not block a view at 8 m, so diagonals are common).
- Corner cuts and twins stay rare (12 and 2 over 8 seeds): a corner cut needs a 30 x 30 m corner lot, a twin a 26 m room,
  and the four-shaft cap leaves little room for twins.
- **Stand-alone `downtown` at the default 44 m block: not feasible.** The inside of a block is 36 m; two tower lots side
  by side need 6 + 8 + 5 + 5 + 8 + 6 = 38 m (setback, smallest point, half the spacing, each side), so a block holds one
  tower each way and never three bases. `DT_BLOCK` (62 m) stays.

**Looks** (`city_buildings.gd` section 7)

- One family: cream (or cream-light) frame and sand trim on every tower, sky-blue glass, the same band line every two
  storeys (a sand ring round each corner pier, across the slab, round the point's fin), the same collar.
- The glass is recessed behind the plan line (point 1.1 m, slab 0.45 m): the frame stands flush with the collision box,
  so the relief is deep without the looks sticking out of the collision.
- **Point**: one deep corner pier a corner (both faces), a full-height centre fin between two unbroken glass strips a
  face (the band line rings only the piers and fin). **Slab**: a flush spandrel every storey, shallow piers every 3.2 m,
  solid corner piers: it reads horizontal.
- **Collar**: 1.6 m tall, 1.3 m proud (`DT_COLLAR`, `DT_COLLAR_PROUD`; pillars keep theirs), dark concrete under the
  flare: it reads from the street (`pass2_street_eye.png`, `pass2_avenue.png`).
- **Bases at eye level**: podium / twin = shop fronts with awnings (one awning colour a building); stepped = sand
  podium with a stone base course and tall windows, a metal rail on the terrace's street edges (looks only); corner = a
  teal glass curtain with slim mullions; arcade = columns in the frame tone (as before); plaza = paving and planters (as
  before); a pillar's podium keeps its teal grid.

**Numbers** (triangles with the zone / with `{"downtown": 0}`): s1 d0 (5 blocks) 267 705 / 281 251 (-4.8 %), s1 d1 (no
zone) 336 024, s1 d2 (5) 302 716 / 323 004 (-6.3 %), s4 d0 (no zone) 309 753, s4 d1 (5) 331 864 / 354 954 (-6.5 %), s4 d2
(6) 311 229 / 338 057 (-7.9 %). Build (city_perf headless, stack seed 4): max chunk 18.5 ms, the five slowest are all
`ground` chunks; no building chunk in the top five. z-fight audit (seed 4, full tool): no tower finding on decks 0 and 2;
one group left on deck 1 (0.97 m2, cream-light / sand at 1.7 cm, a podium band against a corner pier face; not traced
to the end).

**Lab**: camera `downtown_street` (mech eye 8 m on a zone street, looking along it); `downtown_avenue` starts inside the
zone (pass 1 started 22 m before it, between two foreground columns); `downtown_perch` looks away from its shaft;
`downtown_arcade` stands under the gallery; top views (`downtown_top`, `variety_top`, `alley_top`) quarter the haze.

**Honest look at the shots**: the zone now reads as a downtown (continuous podiums, three or four shafts a block,
collars in a row under the ceiling, towers behind towers along a street); slab and point are both legible as one family
(horizontal bands vs a fin between strips). Still off: seed 4 deck 2's best street has the park on one side, so the
avenue and street-eye shots show towers on one side only; from the street the podium bases differ mostly by colour and
awnings, the stepped rail is small; corner cuts and twins are rare.
