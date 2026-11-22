# City generator: ramps between decks and the multi-deck stack

The step after section mode (`city-section-mode.md`): build the ramps that join decks, and put every deck of a section
in one scene so a mech can walk or drop from one to the next. **Spec for the implementation.** Stand-alone mode and
single-deck section mode keep working; stand-alone checksums must not move.

## 1. The stack

`scripts/world/city/city_stack.gd`, `class_name CityStack extends Node3D`: all decks of one section in one scene.

- `build(section: SectionPlan, overrides: Dictionary = {})`: one `CityDistrict` child per deck (`Deck0`, `Deck1`, ...),
  each built with `build_deck(section, k, overrides)` and positioned at `section.deck_offset(k)`, so all decks turn about
  one axis and the lowest deck's floor passes through the world origin.
- `var section`, `var decks: Array[CityDistrict]`, `var rig: CityLightRig`, `var stats`.
- `deck_at(world_pos) -> int`: the deck whose floor is the nearest one below the point (by distance from the axis).
- `ring() -> RingFrame`: the lowest deck's frame. Its `up_at` / `basis_at` are right on every deck (same axis), so one
  mech controller frame serves the whole stack.
- `entry_transform() -> Transform3D`: on the section's entry road node (`section.entry`), on the avenue lane, facing into
  the map, 0.3 m above the floor. For the test drive to spawn at.
- `props_at(world_pos) -> CityProps`: the props node of `deck_at(world_pos)`.
- `checksum() -> String`: section checksum + every deck's plan checksum.

A district that is not at the world origin must still work: everything in `CityProps` that takes or returns world
positions (`first_hit`, `apply_impulse`, `blast`, pushers, `prop_moved`, `pose_of`) converts through the node's
`global_transform`. Add a test with a district moved and rotated.

Only one `CityProps` per scene is found by the group lookup other systems use (`get_first_node_in_group("city_props")`).
In a stack, every deck's props node is in the group, and the stack is in group `city_stack`; note in the report that
combat and audio should ask `CityStack.props_at(pos)` when a stack exists (do not edit their files).

## 2. Lighting a stack

One `CityLightRig` for the whole stack (one WorldEnvironment). Decks must not light or shadow each other:

- Every deck's meshes go on render layer bit `k + 1` (layer 1 stays for mechs and everything else): `CityDistrict` gets
  `render_layer` and applies it to all its mesh instances and MultiMeshes.
- The daylight (the directional light) lights and takes shadows from **the active deck only**:
  `light_cull_mask` = layer 1 + the active deck's layer, `shadow_caster_mask` the same. `CityStack.set_active_deck(k)`
  switches it. The active deck is local presentation (each player's machine uses the deck its camera is on):
  `CityStack.follow(node)` re-evaluates `deck_at(node.global_position)` every 0.25 s.
- Fill lights (omnis under the strips) are built for every deck, each with cull mask = layer 1 + its deck's layer and a
  range that stays inside its own deck (at most `0.9 x pitch`). So a deck seen through a hole is lit by its own strips,
  a little dimmer than the one you stand on, with no daylight shadows.
- `CityLightRig.setup` keeps working for a single district (mask = everything).

## 3. Ramps

A ramp connector (`kind == "ramp"`) leaves deck `from` at cross line `top_line`, runs along one spine ramp lane
(`x0..x1`, 10 m) and lands on deck `to = from + 1` at cross line `foot_line`. Along the way its height above the lower
floor falls linearly from `pitch` (the upper floor) to 0: `h_lower(t) = pitch * (1 - t)`, t from top to foot by angle.
Above the upper floor it is `h_upper = h_lower - pitch` (0 at the top, negative after).

`CityPlan` gets `ramps: Array` in section mode: `[{connector, role: "top" | "bottom", x0, x1, s_top, s_foot, h_top, h_foot}]`
in THIS deck's arc coordinates and heights (a "top" part on the upper deck with h from 0 down to `-(slab + 1)`, a "bottom"
part on the lower deck with h from `clear_height` down to 0; the cut-off end's s is where the line crosses that height).
Both parts are in the checksum.

Geometry (`CityStreets.ramps`), same palette and material as roads:
- **Deck**: a ribbon 10 m wide in facet-long pieces following the slope, asphalt top with two edge lines and a dashed
  centre line, 1 m thick (underside and sides `concrete`).
- **Parapets**: 1.0 m high, 0.5 m thick along both sides (`concrete`, cap `curb`), solid.
- **Top (upper deck)**: the ribbon starts flush with the road at `top_line`; the railing and curb across that end of the
  floor hole are removed (the long sides keep theirs). The ramp passes under the cross-street bridges.
- **Bottom (lower deck)**: comes down out of the ceiling opening. Piers every 24 m where the deck is more than 3 m up
  (`concrete` boxes 2 x 2 m from the floor to the ribbon's underside, a wider cap), solid. For the last stretch (deck
  under 3 m) a solid embankment (the ribbon's sides run down to the floor). The foot meets the road flush at `foot_line`.
- **Collision**: a slope a mech can walk: per facet piece one box tilted to the slope (top face on the ribbon), parapets
  as boxes, piers as boxes, the embankment as part of the ribbon boxes. No steps taller than 0.05 m between pieces.
- Props and buildings stay out of the ramp's footprint (it is on road and in `keep_clear` already).

## 4. Smaller fixes in the same pass

- **Spine gate**: a gate on the 50 m spine is one portal across all four lanes (door leaves or opening spanning the whole
  spine, `h` = 14 m), so the rails and ramp lanes meet a door, not blank wall.
- **Lab**: `site` gains `stack` (all decks; the `deck` slider picks the active deck and the deck the cameras stand on).
  New cameras: `ramp` (standing on the upper deck at the top of the first ramp looking down it; falls back to `avenue` if
  the section has no ramp) and `shaft` (at the railing of the first open-air shaft looking down; falls back likewise).
  Section seeds differ in whether they have a ramp: `--city site=stack,seed=N,camera=ramp`.

## 5. Tests

`tests/test_city_stack.gd`:
- For section seeds 1-5: the stack builds every deck; `checksum()` is stable for equal inputs; every ramp has a top part
  on its upper deck and a bottom part on its lower deck whose world positions agree where they meet (within 0.1 m).
- Walking surface: for a seed with a ramp, rays cast down along the ramp's centre line every 4 m from top to foot hit the
  ramp or the road with no gap, the hit heights fall monotonically, and no step between neighbours is over 0.8 m.
- Rays down the ramp's parapet lines hit the parapet; a ray from the lower deck's road up under the ramp (where it is
  over 6 m) hits the underside.
- `deck_at`, `ring()`, `entry_transform()` (on the entry road, above solid ground), `props_at`.
- Lighting: after `set_active_deck(k)` the daylight's masks are layer 1 + deck k's layer; each deck's meshes are on its
  layer; fill lights of deck j have deck j's layer; relighting still leaves every deck's `geometry_digest()` unchanged.
- `CityProps` on a moved and rotated district: `first_hit`, `blast` and a pusher work in world space.
`tests/test_city.gd`, `test_city_props`, `test_net_props`, `test_lab`, `test_layout`, `test_test_drive` stay green.

## 6. Not in this step

Rail stations and trains; lifts that move; real industrial / transit / open-air fills; drawing far decks at low detail
(all decks are full detail: about 1 M triangles for three decks, to be measured); the test drive using the stack (the
main session's file: `CityStack.build`, `ring()`, `entry_transform()`, `follow(mech)` are the hooks).

## 7. As built (2026-11-22)

Built as specified (`CityStack`, `CityPlan.ramps`, `CityStreets.ramps`, `CityLightRig.setup_decks`), with these differences:
- The ramp is flush with the upper road only at the cross line's centre, so the floor is cut across half that cross road
  (`CityPlan.floor_cuts()`), with no curb or railing across the ramp's mouth. `site.floor_holes` is unchanged.
- The stretch where the two parts meet is drawn once (the top part's mesh stops at the lower deck's ceiling plane);
  collision overlaps by 1 m of height.
- Slab undersides are drawn round floor holes, so the lower deck's ceiling opening does not show through bridges.
- Piers are moved off cross roads. Parapets take the ribbon's outer 0.5 m each side (9 m to drive).
- The fill-light cap (48) applies per deck.
- The spine gate already spanned all four lanes in the data; a test now asserts it.

Section seeds 1-5 all have a ramp (270-335 m long, grade 0.14-0.18); seed 9 has none. A three-deck stack is 1.05-1.32 M
triangles, about 4,200-4,850 collision shapes and 3,000 props, and builds in about 0.9-1.3 s. Stand-alone checksums are
unchanged.

Seen in renders: the ramp diving from the upper deck (seed 4), the deck below through an open-air shaft, dimmer than the
deck you stand on (seed 1), and a lower deck's spine. Not yet seen: the ramp's foot and piers from the lower deck.

Underside and piers (seen from the lower deck, lab cameras `ramp_foot` and `ramp_under`, shots in `city-shots/`
`ramp_foot_s4/s1.png`, `ramp_under_s4/s1.png`): where the ramp is open underneath, its soffit (`concrete_dark`) sits
between two edge beams 1.2 m wide hanging 1 m below it, and the outer fascia runs down past them (`concrete`). Piers no
longer step every 24 m from the embankment and get pushed off roads: the cross roads split the raised stretch into spans,
and in each the piers are spread evenly about 24 m apart (`CityStreets.pier_s`), with a pair framing every cross road
3 m off its edges and none at the embankment's end wall; the last span steps on toward the ceiling. Each pier is a
3.2 m plinth (0.5 m), the 2 x 2 m shaft, a haunch widening into a 6.5 x 2.2 m cross-head, and a cross beam under the
soffit, a little deeper than the edge beams, that the cross-head carries. Each parapet ends at the road in a short
block (0.8 x 1.2 m, 1.3 m high). All of it has collision (edge beams per facet piece; per pier its plinth, shaft,
cross-head and cross beam; the end blocks), and between two high piers the lane under the ramp is open for a mech. The
lower deck's ceiling slot already spans the whole ramp lane with a margin, so the ramp passes through it without
touching the rim; no change was needed there. Plan data and checksums are unchanged.

Hooks for others: the test drive can use `CityStack.build(section)`, `ring()`, `entry_transform()`, `follow(mech)`; with
a stack in the scene, combat and audio should ask `CityStack.props_at(pos)` (group `city_stack`) instead of taking the
first node in group `city_props`.

## 8. In the game (2026-11-22)

The test drive builds the stack (Engine: `scripts/game/test_drive.gd`, `SectionPlan.make({"seed": seed})`,
`CityStack.build`, the entry deck's floor through the world origin: `stack.position = -section.deck_offset(entry deck)`).
The city side of that switch:

**Frames.** The stack may be translated, never rotated. Deck k's arc coordinates are its own ring on deck-local
positions: `decks[k].ring.world_to_arc(decks[k].to_local(p))`. `decks[k].ring` on WORLD positions is right only for the
deck at the origin. `ring()` is now `deck_ring(lowest)`, a ring that works in world positions (it follows the deck
node), so its up / basis are right anywhere in the stack, and its height is above the lowest floor.

**Helpers for code written for one district** (`CityStack`): `district_at(p) -> CityDistrict`, `plan_at(p) -> CityPlan`,
`deck_ring(k) -> RingFrame` and `ring_at(p)` (deck k's arc coordinates, world positions: give these to EnemySpawner,
EnemySquad, BotNavigator, CombatWorld), `to_deck_arc(p) -> {deck, x, s, h}`, `from_deck_arc(deck, x, s, h) -> Vector3`,
`height_above_bottom(p)`, `fell_out(p, below = 25.0)`, `spawn_transforms(n) -> Array[Transform3D]` (alone: the entry
transform; a crew: one column on each carriageway of the 18 m avenue lane, `CARRIAGE` = 5.25 m either side of its 3 m
median, rows 8 m apart going in, facing in, 0.3 m above the road; tested clear of walls, the median, props and each
other).

**Spawn inset (2026-11-22).** `entry_transform()` (where the first mech stands) is `ENTRY_INSET` = 26 m in from the
entry road along the avenue (chase boom 16 m + capsule 2.2 m + 6 m margin), on the left-hand carriageway, plus
`entry_slide()`: the whole formation moves in 2 m steps (up to 30 m) until all four slots are clear of props, floor cuts,
kept-clear ground, checkpoint / cordon lines and the first junction (plan data only; 0 m for seeds 1-20);
`entry_gate_transform()` is the old point on the entry road. On the entry road itself (6 m inside the wall) the chase
camera sat 10 m behind the wall's inner face, in the gate's portal recess, and the recess's flat dark-teal top with the
tan portal frame filled the top quarter of the view (`docs/design/city-shots/chase_before.png` / `chase_after.png`).
The outside of a wall is not drawn (inward faces only), so a camera outside it sees through it.

**Lighting.** `CityLightRig.ALWAYS` = layer 1 + layer 20 (the local pilot head, `ChaseCamera.FP_HIDDEN_LAYER`): every
fill and the daylight (light and shadow casters) include it on every deck; the single-district rig lights all layers.

**A real mech on the stack** (`tests/test_city_stack_walk.gd`, section seed 4, MechSpawn's mech, walk speed): down and
up both ramps (about 330-360 m of walking from road to road, 27-30 s each way) with `deck_at` changing exactly once, never under the ramp's surface,
never stuck, `follow()` switching the active deck at the end; across the cross-road bridge over the ramp lane's hole;
over the 0.5 m curb into an open-air shaft, a 48 m drop caught by the emergency burn (landing at 9.8 m/s, soft), standing
on the deck below. Found and fixed: the legs step up 1.25 m, so the 1 m parapets were stepped over by a mech strafing
into them and it fell off the ramp's side. Parapet collision is now `CityStreets.PARAPET_GUARD` = 2.5 m (the drawn
parapet stays 1 m; the 1.5 m above it is invisible). Seen, not fixed (controller): walking DOWN a ramp the mech is
"not grounded" in about 63% of frames (contact flicker, never more than 12 frames, at most 0.16 m off the slope);
walking up it is grounded.

**Props on decks.** Prop ids repeat on every deck and every deck's `CityProps` hears every prop event, so
`CityProps.deck` (set by `build_deck`, -1 stand-alone) goes into every `prop.req` / `prop.ev` / `prop.sync`, and props
ignore events for another deck (a missing deck counts as -1). Tests: `test_city_props` (`_decks`), `test_net_props_stack`.

**Cost** (RTX 3080, 1600x900, forward+, vsync off; `tools/city_perf/run_city_perf.ps1`, hidden desktop):

| view | avg ms | p95 | worst | GPU ms | draws | primitives |
|---|---|---|---|---|---|---|
| stand-alone district (today's test drive), chase view | 5.08 | 6.37 | 6.59 | 4.58 | 213 | 0.27 M |
| stack seed 4, deck 0 avenue | 5.01 | 5.74 | 10.02 | 4.46 | 182 | 1.77 M |
| stack deck 1 avenue | 5.11 | 5.85 | 10.34 | 4.60 | 187 | 1.85 M |
| stack deck 2 avenue | 4.95 | 5.47 | 11.19 | 4.41 | 175 | 1.63 M |
| stack shaft (deck 0) | 4.13 | 4.69 | 8.85 | 3.65 | 151 | 1.61 M |
| deck 0, other decks hidden | 4.55 | 5.15 | 8.98 | 4.04 | 115 | 0.90 M |
| deck 0, daylight shadows off | 4.63 | 5.20 | 10.06 | 4.12 | 103 | 1.29 M |
| deck 0, fill lights off | 4.92 | 5.48 | 9.79 | 4.38 | 182 | 1.77 M |

Rendering is inside the 16.7 ms frame: the other decks cost about 0.45 ms of GPU (0.9 M primitives), daylight shadows
about 0.4 ms, fills almost nothing. The stack builds in 1.3-1.8 s (1.31 M triangles, 5,355 collision shapes, 3,402
props), about +30 MB static memory and 1.1 GB video memory in use. Physics: `MechController.step` 0.14 ms (0.10 in the
district); a ray costs about 10.5 us (3.5 us in the district).

Props were the cost that grew with the stack, fixed in a second pass (`CityProps`):
- `_push` looped over every prop of its deck for every moving body (2.2-2.4 ms per tick summed over three decks while a
  mech walks). It now asks `push_candidates(here, radius)`: the rest-position grid (`ARC_CELL` 8 m, cells within the
  body's radius + the largest prop radius) plus every prop that has moved, ascending, the same set the old loop let
  through its distance test; and a body below this deck's floor or above its ceiling returns at once. 0.07 ms per tick.
  `test_city_props._grid_matches_brute_force` drives a scripted mech (furnishing bands there and back, a roof, the deck
  above) through a grid instance and a `brute_force` one on seeds 1-3 and a stack deck: the same requests every tick.
- The body scan (every 1 s per deck, when nobody registered pushers) walked the whole tree, the decks' 5,355 collision
  shapes included: 4.15 ms per round. It skips static bodies now (`_bodies_under`, same order): 0.73 ms.
- The headless test drive (`run_city_perf.ps1 -Headless -Drive`, walking and strafing, no firing): district p95
  4.4-4.7 ms, stack 4.7-5.0 ms; the three decks' `CityProps.step` 0.05 ms per tick. `test_perf` (with combat) after the
  fix: p95 8.77 / 10.05 / 7.87 ms in three runs on a machine shared with other sessions' Godot processes.

Not built: hiding decks that cannot be seen from the active deck (about 0.45 ms of GPU, and a risk of popping when
`follow()` switches decks 0.25 s late on a ramp); a shorter daylight shadow distance.
