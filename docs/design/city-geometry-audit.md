# World geometry audit: z-fighting (2026-11-23)

User: "lets do a full world geometry audit for z-fighting". A headless tool that finds every pair of drawn triangles that
can z-fight, the fixes it led to, the rule for flat decals, and what is left on purpose.

## How it works

`tools/geometry_audit/world_zfight_audit.gd` (`WorldZfightAudit`) collects the triangles of every visible mesh and
multimesh under a node, in world space, with a label (the mesh node's name without digits, plus the CityGeo tag of the
batch the triangle came from), its colour and material, and its deck (`CityStack.deck_at` of its centroid: the slab
undersides of deck k-1 count with deck k, whose ceiling they face). A pair is a candidate when the two triangles are

1. near-coplanar: normals within 1 degree. Same facing = a candidate; opposite facing = "back to back" (with back-face
   culling only one of them is ever drawn from any side: counted, never a finding);
2. closer than 5 cm along the normal, measured at the centre of their overlap;
3. overlapping in the plane by more than 0.002 m^2 (exact 2D triangle clipping, not boxes).

Kinds: **finding** (same facing, different colour or material, closer than 1.95 cm: the decal rule's 2 cm less float
slack), **near** (2-5 cm: listed), **buried** (a finding pair lying flat against the back of a third, opposite-facing
coplanar face: inside a solid, e.g. a facade slab's back face on its wall, seen only from inside a building or behind a
boundary wall), **duplicate** (same colour and material: identical flat shading, invisible but wasted), **back**.
Every result is grouped by (label A, label B), sorted by total area, with counts, separation range, colours and one
example position (world and deck arc x, s, h). A separation histogram (0 / <1 mm / <1 cm / <2 cm / <5 cm) per kind.

Speed: each triangle gets a key from its quantised canonical plane (normal components in 0.04 cells, offset in 0.1 m
cells) and is also filed under the neighbouring cell of any dimension it lies within tolerance of, so a close pair
always shares the home cell of its lower-numbered triangle; the (key, triangle, home) entries are packed into int64s
and sorted natively; inside a big cell a 4 m grid in the plane finds overlapping candidates. A whole three-deck stack
(~1.03 M triangles with the mission) collects in ~3 s and searches in ~6 s per deck.

`CityGeo.tag(name)` marks where a batch starts, only while the static `CityGeo.audit` is true (the tool and the test set
it); `instance()` passes the marks as meta "audit_tags". Off, it is one test per call and no vertex, colour or order
changes: `geometry_digest()` is the same (the test checks it). Tags: `deck`, `road.*`, `spine.*`, `block`, `open_lot`,
`floor_hole`, `soffit`, `ramp.*`, `furniture`, `ceil.*`, `strip`, `rim_light`, `wall.<kind>`, `wall.gate`,
`farm_light`, `bld.<style>`. Headless, `MultiMesh.get_instance_transform()` answers identity, so street props take their
poses from `CityProps.transform_of`; other multimeshes (ambient life's people, the tram) are skipped and listed.

## Running it

- `.\tools\geometry_audit\run_world_zfight_audit.ps1 [-Seed 4] [-Decks 0,1,2] [-NoMission] [-NoLife] [-Limit 40]
  [-Trace "A|B"]` (headless, no GPU lock): builds the section's CityStack with `setup_mission(MissionPlan.make(sec))`
  and the static part of ambient life (no people or vehicles), prints the groups per deck and every deck's collision
  hash (count, hash of every shape); full text in `test_logs\zfight_audit_s<seed>.txt`. `-Trace` prints the triangles
  of the first findings whose labels contain the text. About 25 s for a whole stack.
- `tests/test_world_zfight_audit.gd` (normal suite, ~9 s): seed 4, deck 0, with the mission; fails on any finding group
  over 1 m^2 that is not in its `ALLOWED` list (each entry carries its reason), checks the decal constants and that
  tagging leaves the digest alone.

## Decals: one rule

Flat patches and markings without collision lie on their surface in fixed layers, constants in `CityStreets`:

| layer | height above its surface | what |
|---|---|---|
| 1 `DECAL_PATCH` | 0.02 m | gutters (were 0.012), the avenue's tan lane (0.008), parking strips (0.008), rail ballast (0.01), a median's lawn (0.01), an open lot's surface on the sidewalk, a farm fin's kick plate and channel (0.015) |
| 2 `DECAL_LINE` = `MARK` | 0.04 m | lines, dashes, zebras, stop lines, parking ticks, the ramp lane's and the ramp's lines, the gate's floor stripes (all were 0.02); an open lot's paths, court lines, plaza bands (were +0.01 over the lot); a garden's lawn on its slab |
| 3 `DECAL_TOP` | 0.06 m | the mission's zone rings (MissionProps, already 0.06), a park's central square (was +0.012) |

Layers are 2 cm apart and never closer: with flat shading two faces of different colour closer than that shimmered.
Ceiling hatches hang 4 and 7 cm under the panels (fine). Collision never sees decals.

## Fixes (geometry first)

- Ramp head: parapet end blocks straddled the floor hole's curb; now flush inside the ribbon (collision follows: part of
  the bridge change, not of the looks pass).
- Ceiling ribs ending at an opening's edge: no end face there (it lay in the opening's inside face and in the cut face of
  the floor hole above).
- Ceiling strips on a walled deck stop at the walls (a strip piece ran into a farm wall and ended 0.5 mm from a fin).
- Pillars: pilasters and the lift channel stop under the capital's collar (their tops lay in its top face).
- Shops: awnings 2 cm clear of the pilasters (their double-sided end gussets lay in the pilasters' side faces): an
  offset, because the gusset is double-sided and the pilaster's face is the shop's.
- The decal layers above.

Collision is identical before and after the looks pass (seed 4 decks 0-2: [1431, 214513608], [2072, 1075195680],
[1859, 3998777181]; seed 1 deck 0 [1398, 3304332043], the farm walls test's golden).

## Findings, before and after (section seed 4, mission on, findings closer than 2 cm)

| group | before (deck 0) | after |
|---|---|---|
| road base vs parking / lane_tan / gutter / ballast / median lawn / open-lot layers (0.8-1.2 cm) | 27,600 m^2 | 0 |
| markings at 2.0 cm over patches and the road (zebras, lines, gate stripes) | 2,600 m^2 | 0 |
| farm fin kick plate and channel vs fin face (1.5 cm) | 2,140 m^2 (deck 1: 2,780) | 0 |
| apartment / shops / pillar internal faces at 0 cm | 370 m^2 | 3 m^2 left as findings; the rest is "buried" (back faces on walls) |
| pillar pilasters vs capital collar | 110 m^2 | 0 |
| strips vs farm fin | 56 m^2 | 0 |
| ceiling opening vs ribs | 19-31 m^2 (decks 1-2) | 0 (one 0.004 m^2 pair) |
| ramp end block vs floor hole curb | 0.15 m^2 per ramp head | 0 |
| bulkhead internal and bulkhead / farm corner | 60-110 m^2 | the same: allowed (below) |
| total findings, decks 0 / 1 / 2 | 43,560 / 48,410 / 60,770 m^2 | 63 / 1.6 / 81 m^2 |

(Before = the first run with tags; the props had been mis-posed headless in an earlier run, so its prop groups are not
counted.) Seed 1 after: 32 / 3.4 / 159 m^2, the same kinds.

## What is left, and why

- `Walls:wall.bulkhead` with itself and with `wall.farm` (30-160 m^2 per deck; allowed in the test): back and side faces
  of a bulkhead's buttress posts and base / gallery boxes lying on the wall's own plane, facing out of the map behind a
  solid 6 m wall, and the corner where a bulkhead meets a farm wall. The classifier calls most of them "buried"; where the
  wall's facets meet it does not find the wall face under them.
- Small (each under 1.2 m^2 per deck): apartment / shops / office faces at 0 cm (back faces of slabs at a wall's edge),
  pillar plinth faces under the sidewalk (h -0.33), parking ticks at 1.3-1.9 cm where the tick and the strip end on
  different facets, the tactile ramps' sidewalk band (0.07 m^2), a bench touching a park column (prop).
- Not ours, listed for their owners: MissionProps door leaves `LeafL` / `LeafR` (metal on m_leaf at 0 cm: 2-6 m^2 of
  buried faces and a few 0.01 m^2 findings, `scripts/world/city/mission_props.gd`); ambient life `Deck/Barriers`
  (blocks 1 cm from the floor hole's railing posts, coplanar block faces; `scripts/world/life/life_barriers.gd`).
- Near (2-5 cm, by design): the lower deck's ceiling 5 cm in front of the soffits above it, rim lights 3 cm under the
  rim beam, window panes 2-5 cm off their walls (`_pane` 0.05, door panes 0.03-0.17), ceiling hatches.
- Duplicates (same colour, invisible): girder halves overlapping by 0.5%, the block curb under the floor hole's curb,
  the ceiling opening's inside faces where they coincide with the cut faces of the floor hole above, prop parts.

Shots after (hidden desktop, seed 4): `city-shots/zfight_ramp_mouth.png`,
`zfight_farm_fins.png`, `zfight_decals_avenue.png`, `zfight_ceiling_opening.png`.
