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

- **Spine gate** (superseded 2026-11-27: the 40 m spine's end is one 14 m road door on the main road, plus a tram door on
  deck 0; city-spine.md §4): a gate on the 50 m spine was one portal across all four lanes (`h` = 14 m).
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
  **Since 2026-11-27 (R2.17)** the slope runs over the plan's run (connector `run_top` / `run_foot`), which starts and ends
  `SectionPlan.RAMP_END_PAST_BOX` (6 m) past the junction boxes: every `CityPlan.ramps` part lies on it (and carries the
  run as `run_top` / `run_foot` in the deck's s), the mouth is the floor cut's plain open edge on flat service road, the
  foot lands on flat road short of the next box, and `floor_cuts()` no longer reaches into a cross road
  (city-spine.md "Ramp ends").
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

### Quality levels (2026-11-22)

A LAN test laptop (Intel UHD 620) ran the 3-deck stack at 230-430 ms a frame. `CityQuality` (`scripts/world/city/city_quality.gd`,
`LOW = 0`, `MEDIUM = 1`, `HIGH = 2`, `name_of(q)`, the numbers in `LEVELS`) is a local draw level: `CityStack.set_quality(q)`
and `AmbientLife.set_quality(q)`, any time, before or after the build, switchable at runtime. It never touches a plan,
a checksum, a prop, a collision shape, an RNG draw, a life timetable or who can be hit: a LOW and a HIGH machine play the
same game (`tests/test_city_quality.gd`). HIGH is exactly the look before levels existed (the test restores every flag
after LOW). Lab: city subject, option "quality" (`--city site=stack,camera=avenue,quality=low`).

| | HIGH | MEDIUM | LOW |
|---|---|---|---|
| decks drawn | all | active +- 1 | active + the one below |
| daylight shadows | on, 4 splits, 320 m | on, 2 splits, 220 m | off (the daylight also lights the deck below) |
| fills (omni) | all (39 per deck on seed 4) | every 2nd, on the drawn decks | none; ambient + fill energy x share cut |
| SSAO / glow | on / on | off / on | off / off |
| block mesh range | unlimited | 320 m | 230 m |
| life drawn within | 200 m (`DRAW_R`) | 160 m | 110 m |

Hidden decks are `visible = false` on the deck node: collision, props simulation and life keep running. Fills of hidden
decks are hidden (not just masked). Life: only the drawing is cut (`_show_person` / `_show_vehicle`, the tram);
the bands (`EVAL_R` / `DRAW_R`), sampling, `_on` / `_von` (what local shots can hit) and the host's decisions are
unchanged. Fog and filmic tone mapping stay at every level; SSIL, SDFGI and volumetric fog are never on.

**Holes and ramp mouths.** LOW draws the deck below the active one: without it, looking down a shaft or a ramp from the
upper deck shows the background colour, and `deck_at` switches only 1 m below the upper floor (`FOOT_SLACK`), so a mech
walks most of the way down a ramp still "on" the upper deck. Cost of the deck below at LOW (avenue, 1600x900): 0.53 ->
0.65 GPU ms, 382 k -> 858 k primitives, 28 -> 57 draws. Not covered: walking UP a ramp at LOW the deck above is hidden
until `deck_at` switches near the top, so the ceiling opening over the ramp shows the background colour (sky blue,
fogged), not black; it pops in at the top.

**Measured** (`run_city_perf.ps1 -Quality all [-Resolution WxH]`, RTX 3080, forward+, MSAA 2x, vsync off, seed 4 from
the entry deck; frame / GPU ms averages; we cannot emulate a UHD 620, so the relative change is what counts):

| view, level | 3840x2160 frame / GPU | 1600x900 frame / GPU | 1024x576 frame / GPU | draws | primitives | omni | shadows |
|---|---|---|---|---|---|---|---|
| avenue HIGH | 4.80 / 4.29 | 1.78 / 1.43 | 1.58 / 1.23 | 182 | 1.77 M | 117 | on |
| avenue MEDIUM | 3.73 / 3.23 | 1.35 / 0.99 | 1.15 / 0.80 | 98 | 1.10 M | 40 | on |
| avenue LOW | 2.67 / 2.19 | 1.01 / 0.65 | 0.87 / 0.53 | 57 | 0.86 M | 0 | off |
| ramp HIGH | 4.66 / 4.16 | 1.76 / 1.41 | 1.53 / 1.19 | 196 | 1.82 M | 117 | on |
| ramp MEDIUM | 3.57 / 3.09 | 1.35 / 0.99 | 1.16 / 0.81 | 106 | 1.14 M | 40 | on |
| ramp LOW | 2.49 / 2.01 | 0.97 / 0.61 | 0.84 / 0.49 | 53 | 0.84 M | 0 | off |
| shaft HIGH | 4.00 / 3.51 | 1.48 / 1.14 | 1.26 / 0.91 | 151 | 1.61 M | 117 | on |
| shaft MEDIUM | 3.01 / 2.53 | 1.13 / 0.78 | 0.98 / 0.63 | 85 | 1.05 M | 40 | on |
| shaft LOW | 2.08 / 1.60 | 0.83 / 0.47 | 0.73 / 0.38 | 45 | 0.81 M | 0 | off |

(The 3840x2160 column is `--resolution 1600x900` on the hidden desktop, which its DPI scale turns into a 4K window; the
probe now forces the window with `--perf-size`; asked for 1280x720 the render target came out 1024x576.) GPU time: LOW is
about half of HIGH (-49% at 4K, -55% at 1600x900), MEDIUM about -25%. Outside the city, at LOW avenue 1600x900: MSAA off
0.65 -> 0.43 GPU ms, and a 0.75 3D render scale 0.36; HIGH with MSAA off 1.43 -> 1.13.

Shots (entry deck avenue, same camera): `docs/design/city-shots/quality_high.png`, `quality_medium.png`,
`quality_low.png`. LOW is flatter (no shadows or ambient occlusion) and a little brighter, every building and street
still distinct; MEDIUM is hard to tell from HIGH at a glance.

### Incremental build (2026-11-22)

The same LAN laptop spent 7.8 s inside ONE frame in `CityStack.build()` (1.2 s on the host PC), which starved the
network. The build can now be spread over frames:

    stack.build_begin(sec, overrides := {})   # cheap: frees the old decks, stores the section
    stack.build_step(budget_ms := 8.0) -> bool # chunks until budget_ms of wall time is spent (at least one); true when done
    stack.build_progress() -> float            # 0..1, never goes down
    stack.build_done() -> bool                 # false from build_begin until the last chunk (and before any build)
    stack.build(sec, overrides)                # unchanged: begin + step to the end
    life.setup_stack_begin(stack, ...)  /  life.setup_step(budget_ms := 8.0) -> bool  /  life.setup_done()

A build is a queue of chunks run in order (an explicit queue of [label, Callable], no coroutines): per deck
`CityDistrict.build_deck_begin` / `build_step()` (one chunk each; `build()` / `build_deck()` run the same queue to the
end): plan, ground (one part per road along s + 3, `CityStreets.ground_part`), ramps, buildings 16 at a time into their
block's CityGeo, columns, block meshes 6 at a time, props, furniture, walls, ceiling (2 girder bays or 16 girder lines
per chunk, `CityStreets.ceiling_range`), ceiling mesh, strips mesh, backdrop, collision (floor, walls, ramps, buildings
60 at a time), finish; then the stack's rig and entry chunks. Every split keeps the order of triangles, digests, nodes,
collision shapes and `look` draws, so a stepped build is exactly a one-shot one (`tests/test_city_build_steps.gd`, also
checked against the code before the change: same checksums, digests, shapes, names, props for seeds 4, 1, 7 and two
districts). `stats.ms` is the time inside chunks, plus `stats.chunks`, `stats.max_chunk_ms`; `chunk_log` holds every
chunk's label and ms ("d1 ceiling 3/22").

Measured headless on the dev PC, section seed 4: 156 chunks, 1.17 s in all (the same as one shot), max chunk 36 ms. Over
20 ms: the ceiling mesh (18-36 ms) and strips mesh (7-15 ms), each ONE `ArrayMesh.add_surface_from_arrays` of up to
~150 k triangles that cannot be split without changing the mesh (several surfaces or nodes). Everything else is 0.3-18 ms
(the spine road's ground part 17 ms, plan 7-11 ms, props 11-13 ms). Before the split the worst chunks were the ceiling
(128-270 ms) and the ground (58-65 ms).

While building: finished decks are in `decks` and in the tree, the deck being built is a child too; `checksum()`,
`deck_ring()`, `entry_transform()`, `spawn_transforms()` are valid only once `build_done()`; `follow` waits. Calling
`build_begin` again mid-build throws the half away. Ambient life: 4 chunks per deck (plan + people, traffic, tram cars
and barriers, first exact draw) + 1, 150-170 ms in all, max chunk ~31 ms; until `setup_done()` its `units` stay empty and
`stack` null, the units do not run, and life.* events heard meanwhile are replayed when it finishes.

## 9. Mission world (phase 1) (2026-11-22)

The world side of mission objectives phase 1 (`docs/design/mission-objectives.md` §5.6, §7, §9): `MissionWorld`
(`scripts/world/city/mission_world.gd`), its pieces in `mission_props.gd` (`MissionProps`), the lab driver
`mission_lab.gd` (`MissionLab`). Presentation plus a little collision: no mission logic, no network, no global
randomness (looks use a generator seeded from the section's cosmetic seed and the piece id). Tests:
`tests/test_mission_world.gd`.

**Setup.** `stack.setup_mission(plan) -> MissionWorld` once the stack is built (also kept as `stack.mission`; null until
then; a second call replaces it; `build()` frees it). `plan` is a `MissionPlan` (`MissionPlan.make(sec)`) or a
Dictionary with the same fields (`sources`, `objectives`; missing keys are tolerated). Only listed sources get a wave
door: other blast doors stay baked as before. `MissionWorld.stand_in_plan(stack)` builds such a Dictionary when
`MissionPlan` is missing. Pieces are children of their deck's `CityDistrict`, so `set_quality` hides them with the deck.
`stack.set_quality` passes the level on (LOW: no warning light, no relay particles). Setup takes 125-140 ms in all on
this PC (seed 1: 18 doors on 3 decks; it was 0.3-0.4 s before the site search went nearest-first).

**Stepped setup** (like the stack build): `stack.setup_mission_begin(plan)`, then `stack.setup_mission_step(budget_ms :=
8.0) -> bool` each frame (runs chunks until the budget is spent, at least one; true when finished),
`stack.setup_mission_done()`, `stack.setup_mission_progress()` (0..1, never goes down). `stack.mission` is null until done,
then the finished MissionWorld. `setup_mission(plan)` is begin + step to the end, with the same result (tested: snapshot,
sites, nodes, walls and collision). Chunks (`MissionWorld.chunk_log`): plan (match sources to doors, ~2 ms), one per wave
door (2-3 ms; the entry / exit and tram doors one each too), each deck's walls in CityDistrict's own parts (one per side,
a farm side in its parts; 0.4-10 ms), pose doors, per flag / defend its site search (0.5-3 ms) and its build (~1 ms),
hold, finish. Largest chunk ~9-10 ms.
Before done, every call that changes state (open_source, set_flag, advance_to, restore, ...) returns at once. A rebuild,
a second begin or a teardown mid-setup leaves nothing behind. Without `setup_mission` nothing
changes: plan, props and stack checksums, every Walls mesh and every collision shape are the build's own. The test checks
this, and checks it again after `teardown()`.

**Clock.** `advance_to(t)` takes the shared mission clock and runs every frame on every machine. Everything is a
scheduled effect: the calls store times, and the look at t is a pure function of those times
(`MissionWorld.door_state`). Two machines given the same calls agree at any frame rate, and a late call or a late joiner
snaps to the right state. Idle cost: one comparison (about 0.2-0.3 us) until the next stored moment, while nothing moves.

**Wave doors** (sources of kind gate / lift; ramp, shaft and unknown ids are accepted and do nothing). Since 2026-11-23
every gate wave door is a **staging bay** (below).
- **Timing (2026-11-23): `open_at` is the moment the leaves START to move, and the siren is the opening signal.**
  `open_source(id, open_at, hold := 12, order_at := now)`:
  - `open_at - 5 .. open_at`: state `warn` (`source_event("warn")` at its start). Silent and dark at a gate and at a lift
    (the lift's countdown lamps went 2026-11-27, R2.22: the station is a real place, a freight lift shows nothing of a
    wave's arrival; its doors' motion is the tell).
  - `open_at .. open_at + OPENING` (gate 3.0 s, `MissionWorld.OPENING`; lift 1.5 s): state `opening`, the reveal. The leaves
    slide apart. At a gate the siren loops, the recessed amber lamps under the lintel flash in turn (0.8 s), the beacons on
    the lintel turn, the bay's `WarnLight` comes on. `source_event("open")` fires at `open_at`.
  - From `open_at + OPENING` (`source_state().passable_at`, `MissionWorld.passable_after(kind)`): `open`, `passable`
    true, the door box off. It stays open `hold` s (`close_at = open_at + OPENING + hold`), then closes over 2 s (`close`).
  - Before 2026-11-23 the leaves took 2.0 s and ENDED at `open_at` (fully open at `open_at`); now they start there, so a
    gate is passable 3 s after `open_at`. Callers that spawn at `open_at` now spawn as the leaves start to move (the door
    box holds the units in for those 3 s).
  - The siren may lead the leaves by `ALARM_LEAD` s (one constant, 0 now, the lead is still being settled):
    `alarm_from = clamp(order_at, open_at - ALARM_LEAD, open_at)` is the schedule's 4th field. `alarm_on(kind, sched,
    seal_at, t)` / `alarm(id)` / `source_state().alarm`: on for `alarm_from <= t < open_at + OPENING`, off from the seal
    time; gates only. A snapshot with 3 fields restores with `open_at - ALARM_LEAD`; one with an older, longer lead is
    clamped to the rule. An order merged into an open door (only the hold extends) sounds nothing.
  - The siren plays only for a gate on the stack's active deck (`stack.active_deck`, the deck `CityStack.follow` keeps
    the viewer on); on other decks the lamps run silently.
  - Called again while the door is due to be open (the new `open_at` is not after the current close time): only the hold
    is extended. A later `open_at` starts a new cycle.
- `hold_source(id, until_t)`: keep it open until at least `until_t`.
- `close_source(id, at := now)`: sealed for good at clock time `at`, scheduled like `open_at`, so a late call snaps. A
  door open (or opening) at `at` closes over its 2 s first; one already closing finishes. Then it is sealed (welded bars
  in an X, a weld seam, scorch on the leaves, beacons dead) and solid. `seal` fires once when the clock passes `at`.
  Later orders are ignored.
- `source_state(id) -> {state: shut | warn | opening | open | closing | sealed, t (when it began; the seal time once
  sealed), open_at, close_at, alarm, alarm_from, passable (fully open: true only in "open"), passable_at}`.
- Siren: an `AudioStreamPlayer3D` "Siren" on each `GateDoor` (mid-opening, 4 m up), `MissionSound.gate_siren`:
  inverse-distance, `unit_size` 20 m, `max_distance` 140 m, bus `SFX_World` (Master when it does not exist), started at
  the shared clock's phase. PLACEHOLDER sound: a procedural two-tone horn (`MissionSound.klaxon()`).
- `source_point(id) -> {deck, x, s}` for every kind: where to spawn. A gate with its door: the floor centre of its staging
  bay (16 m behind the wall plane, `GATE_POINT`). Every other source (lift, ramp, shaft): the plan's point. Unknown ids: `{}`.
- Gate matching: the `blast_door` gate in the plan's `boundary()` on the wall named by `edge` (s0 / s1 / x0 / x1; any wall
  when empty) nearest (x, s). Only `blast_door` gates get wave doors (`collapsed` gates, now built as plain shut blast
  doors, cannot be wave sources: `find_gate` is unchanged). Lift matching: the pillar of `sec.connectors[connector]`,
  else the nearest lift core.

**Staging bay** (2026-11-23; `MissionProps.GateDoor`). User pick 2026-11-23: grid `city-gates/grid_bay.png` cell 2, sliding
leaves in a projecting concrete bunker frame (`bay_sliding_bunker_s61.png`). Shots: `docs/design/city-gates/bay_shut.png`,
`bay_opening.png`, `bay_open_gate.png`, `bay_open_inside.png` (lab: `mission=doors,mission_phase=shut|opening|open`,
cameras `mission_gate` / `mission_bay`).
- **Room.** Behind the wall a hangar room `BAY_DEPTH` 26 m deep from the wall plane (the 6 m wall + 20 m). Interior width:
  the gate's own width, widened behind the wall thickness to `BAY_MIN_W` 22 m (20 m clear after 1 m margins);
  `MissionWorld.plan_bay_span` shrinks it symmetrically (never below the gate) to stay 0.5 m clear of a neighbouring gate's
  bay, a collapsed gate, and 2 m inside the deck's corners (no clamp was needed on seeds 1, 4, 7, 403112: gates on one wall
  are 40 m+ apart); beside a tram tunnel it moves sideways instead (2026-11-27: the entry bay sits off centre). Roof underside `BAY_H` 18 m above the floor at the wall plane: taller inside than the opening (the
  roof steps up behind the lintel). Light bars hang 0.25 m under it; nothing else hangs inside.
- **Floor** level with the street, no lip or sill: drawn (3 cm up, like the old recess) and collided on the deck's own
  facets in the district's arc coordinates (one 1 m slab per facet, as `CityDistrict._col_floor`), so it meets the deck
  floor flush on the ring's curve (an end-wall bay's floor rises ~0.85 m over its depth against a flat frame).
- **Gates** (unchanged plan data): lane / street gates 14 m in the wall, 12.8 m clear between the jambs, 9 m to the lintel's
  underside; avenue gates 50 m (48.8 m clear), 14 m high (until 2026-11-27: on the 40 m spine the avenue gate is an ordinary
  14 m road door, 12.8 x 9 m clear). Every narrow gate is under 14 m clear and under 10 m high. The
  opening is clear up to the lintel underside (lamps sit recessed above it).
- **Look** (flat colours, every choice in `GateDoor`'s `_build_*`): a pale concrete bunker frame projecting 2 m into the
  street (lintel 2.4 m) with sloped buttresses (2.4 m jambs, 2.2 m wider at the foot) and a deep chamfered lintel with a
  recess holding round amber lamps (2 per narrow gate, 4 per avenue gate); beacon housings on the lintel over the jambs;
  two steel leaves with ribs, a panel line and a yellow / black hazard band each, sliding into the wall; inside, dark walls
  with ribs carrying vertical light strips, ceiling light bars (glowing warn .. closing), yellow guide lines running out to
  1.2 m in front of the door and a stop bar, and on the back wall a shut blast door (16 x 12 m on a narrow gate) with
  diagonal yellow / black chevrons in a steel frame (static: where the units came from). The hatched keep-clear box on the
  road stays. The baked hazard portal is left out of the Walls mesh for a mission door (`g["frame"] = false`).
- **Sign panel.** Beside the +X buttress a plain concrete pier (6.8 x 8 m face, 1.6 m out of the wall) keeps a clean 6 x 4 m
  panel centred 5 m up for a stencilled deck number painted later (no text drawn here):
  `MissionWorld.source_sign_panel(id) -> {ok, frame (origin at the panel's centre on its face, +Z toward the street, X along
  the wall), size}`.
- **Collision.** The door box closes the opening at the wall plane while shut / warn / opening / sealed (same layers as the
  district's walls, so it stops shots and line-of-sight rays like a wall). The bay is a sealed box of 1.2 m plates (sides,
  back, roof reaching 1 m into the cut wall slab, overlapping at the edges) plus the facet floor slabs. The bunker's jambs
  (convex), lintel and sign pier are solid. `tests/test_map_sealed.gd` checks it: into an open bay the capsule reaches the
  back and no further, cannot leave by the sides or the roof (walking, hopping at roof height, straight up, at angles), has
  flush floor everywhere, rolls straight out from the usable floor between the jambs, and the frame stops a walk along the
  wall.
- **Cost** per bay: 1040-1080 triangles (narrow gate), 1340-1360 (avenue gate); 16-18 collision shapes (door box, 4 plates,
  7-8 floor slabs, 2 jambs, lintel, pier) besides the rebuilt wall pieces; its setup chunk 6.5-13 ms.
- `source_bay(id)`, for placing a wave inside (Missions): `{ok = false}` for ramps, shafts, unknown ids (test `ok`); a lift
  answers with its car since 2026-11-27 ("Lift cars" below).
  Otherwise `{ok: true, deck, frame (global in the tree: origin on the wall plane at floor mid-gate, +Z into the map),
  center (the usable floor's centre, same space), x, s, h (its arc coordinates, h 0), origin (Vector2(x, s)), out (unit
  arc vector into the deck), facing (unit, into the map), exit (on the street 6 m in front of the door), half_width (10 on
  a narrow gate), width (20), depth_from 8, depth_to 24 (usable metres behind the wall plane), depth 16, height (true clear
  height under the light bars over the floor's highest point: 16.9-17.6 m), door_w, door_h, door (Vector2: arc point of
  mid-gate on the wall plane), door_s (the wall plane's arc coordinate along `out`: x on a side wall x0 / x1, s on an end
  wall s0 / s1), edge}`. A 20 x 16 m usable floor holds 6 units with two ~6 x 10 m heavies.
- **Units.** Spawned at `source_point` (the bay centre) or anywhere on the usable floor between the jambs' line, a unit
  walks straight out along `facing`. From the usable floor's outer corners (beyond the 12.8 m opening's width) the direct
  line to `exit` clips the wall's inner corner: steer to the door's axis first. Fliers: drones cruise at 15 m and gunships
  at 11.5 m (`EnemySpawner`), above a 9 m opening; they fit in the bay but must come down to 6-8 m to pass the door.
- **Which face the lift door is on.** The `front` of the lift pillar's building in `CityPlan`: the first face of its lot
  that lies on the block's building line, in this order (`CityPlan._add_lot`):
  1. the x side toward the avenue (the `-x` face when the lot's centre x is east of the avenue's centre line, `+x` when
     west);
  2. the other x side;
  3. +s;
  4. -s.

  The door is centred on that face of the core (size from `core.size`). `source_point` gives the right point whichever
  face it is.

**Lift cars** (2026-11-27, playtest backlog R2.22; `MissionLiftDoor`, `CityBuildings._lift_doorway`). Units are staged in
the freight lift's car and walk out when its doors open, like a gate's staging bay.
- **Measured** (section seeds 1..200, every deck, 996 lift cores incl. the express lift): every lift core is bare (no podium,
  no solid, no other footprint, no floor hole in it), 25.13 / 25.44 / 25.69 m along the door face (the s size: 28 m leaned
  to the ceiling, by deck radius) x 28.00 m deep (every door is on a +-x face: front 0 in 438, 1 in 558), the deck's
  ceiling 40 m. Inside it today: one solid collision box per deck district (`CityDistrict._col_buildings`, kind `core`), no
  shaft, stairs or other deck's lift (each deck is its own district; the lift's other stops have their own cars).
- **The car** (every lift, guaranteed): interior 16 m wide (`CAR_HALF` 8) from the 1 m front wall (`LIFT_WALL`) to the back
  wall at 18.5 m (`CAR_BACK`), roof 10 m over the floor (`CAR_H`; light bars 0.25 m under it: clear 9.67-9.7 m). Usable
  (source_bay): **14 m wide x 16 m deep x 9.6 m high** (`half_width` 7, `depth_from` 1.5, `depth_to` 17.5). It leaves 4.6 m
  of core each side and 9.5 m behind. `MissionLiftDoor.car_fit` builds a smaller car where a core is smaller (never under
  11 x 12 m: below it the lift keeps its solid core, `source_bay` `{ok = false}`); none is in seeds 1..200.
- **Doorway** 10 x 9 m (`CityDims.LIFT_DOOR_W`, `CityBuildings.LIFT_DOOR_H`; 9 m since R2.22 so an 8 m mech capsule walks in
  with a step's room), in the hazard frame (now 9.8 m to its top); the windows start at 10 m, pilasters over the doorway
  start above the frame. The district draws the core's front face round the doorway, a 1 m reveal and the shut doors
  baked across it 0.3 m behind the face (`lift_leaves` / `lift_leaf`: two leaves, seam, hazard band); a call panel on the
  right jamb's face. No mission: the core is solid, the baked doors shut.
- **In a mission** (`MissionWorld._c_lift`): the district's core box is disabled (`_cut`, restored by teardown) and
  `MissionLiftDoor.body` ("LiftBody") stands in for it with walls round the car (sides, back, front wall beside and over the
  doorway, roof) and `door_shape` in the doorway (solid while shut / warn / sealed, never while the leaves move); the
  baked doors are taken out of the block mesh (`hide_fill`, the triangles inside `in_fill`; the original mesh is kept in
  `_lift_meshes` and put back by teardown). The car itself: steel walls with ribs, yellow bump rails at 1.4 / 3.2 m, roof
  light bars and wall strips (warm, always lit), a dark floor on the deck's facets with a threshold plate and a hazard line;
  an OmniLight in the car while its doors open / stand open / close. The floor is the deck's own (the plaza's sidewalk
  slab under the core: the car is level with the plaza, `h` = `CityPlan.CURB_H`).
- **API.** `source_bay(lift)`: the gate bay's keys with the same frame convention (origin on the door plane at floor
  mid-door, +Z out of the car), plus `kind` "lift" and `bay_depth` 18.5; `edge` "", `offset` 0. `bay_contains(lift, p)`:
  inside the throat (|x| <= 5) or the car; doorway within 1.5 m of the door plane. `bay_slots(lift, n)`: columns 8 m apart,
  rows 5.5 / 13.5 m in (two Bulwark capsules abreast fit). `source_point(lift)` unchanged (the lobby in front of the door).
  Timing unchanged: passable at `open_at + LIFT_OPEN` (1.5 s).
- **Tests**: tests/test_mission_world.gd (`_lift_car`), test_map_sealed.gd (`_lift_car`: both capsules and a 1.4 m sphere in
  through the doorway, never out but by it), test_collision_survey.gd (`lift_car_inside`, `lift_car_exit`; the jambs as
  kind `lift_car`, though the survey's corner finder skips boxes as tall as a deck, as it does the cores and columns).
  Shots: docs/design/city-spine/lift_shut.png, lift_open.png (lab camera `mission_lift`).

**Air doors** (2026-11-24; the user approved "flying doors in the walls" for dropships). High hangar doors in the END walls
(s0 / s1), derived by MissionWorld from the stack itself (not from MissionPlan: they exist whenever a mission world is set
up), so every machine builds the same ones. Shots: `docs/design/city-gates/air_shut.png`, `air_open.png` (bulkhead),
`air_farm_open.png` (farm wall); lab `mission=doors`, cameras `mission_air` / `mission_air_farm`.
- **Guarantee** (2026-11-26, playtest R2.24: dropships always come and go through an air door, so Missions can drop the
  in-deck fallback): every deck of a section has one or two air doors, and every one is **usable**: a box the opening's
  size (12 m + 1 m a side across, 20.5-27 m up) flies straight in from the wall plane for at least `APPROACH` 30 m
  without touching a building tier or solid (gables included), pillar core, park column, ramp keep-out or ceiling opening.
  `MissionAirDoors.approach_len(plan, wall, c)` measures it exactly for the ring (the line is straight while the floor
  curves up to meet it, plan s is arc length on the floor, a building box tangent at its centre overhangs its footprint as
  it rises), up to `REACH` 80 m; the doors carry it as `clear_len` (and `usable`). The rule below gained the usable test
  and a second pass: when no spot passes the first pass (the old rule + usable), the nearest spot that is usable and
  clear of the gates is taken, sliding along the whole wall. Measured over section seeds 1-300 (doors per deck: before ->
  after): 3 decks (the game's): 833 decks with 2, 66 with 1, 1 with none (seed 261 deck 1: buildings over 20 m in front
  of both farm walls) -> 900 decks with 2, all usable; 2 decks: 551 / 49 -> 599 / 1 (seed 48 deck 1 keeps one); 5 decks:
  1415 / 84 / 1 -> 1500 with 2. Before, 97 of the 1732 doors (3 decks) failed usable, all only because of the curve (a
  building 18-20 m tall 20-30 m in sits in the straight line's way; with a flat floor every one passed): those moved
  (97, 5.6 %); 68 walls gained a door; the rest kept their spot. Physics agrees (the opening's box cast `clear_len` m in,
  every door of seeds 1-140). Side walls (x0 / x1) were not needed (no deck without an end-wall door over 2700 decks).
  API for Missions: `air_door_count(deck)` >= 1, `air_door(deck, i)` (+ `usable`, `clear_len`),
  `air_door_approach(deck, i) -> {ok, from (the opening's centre, mid height), to (clear_len m along facing), clear_len}`.
- **Placement rule** (`MissionAirDoors.spot(plan, wall)` / `doors(plan)`, plan data only, no random draw): on each
  end wall the spot nearest the avenue's centre line (candidates every 0.5 m, + before -) whose door (`air_half()` 9.1 m
  each side) stays 4 m inside the wall's ends and 1 m clear of every gate's staging bay footprint (`plan_bay_half` +
  plates) and span, whose frame rect (19.5-29.1 m up, +-8.6 m) is 1 m clear of the band kept over every gate for its deck
  sign (`GATE_SIGN_HALF` 6.5 m either side of the gate's centre line), and whose flight corridor (the opening +-1.6 m,
  40 m straight into the deck) crosses no building taller than 20 m, pillar core, park column, ramp (`ramp_keep_out`: the
  ramp +2 m across, + `RAMP_SIGN_REACH` 5 m past both ends for its hung sign) or ceiling opening (that corridor: the first pass only; both passes need the door usable, above); the ceiling must leave
  4 m over the lintel. **In the load checksum** (2026-11-25, code audit): `CityStack.checksum()` joins every deck's
  `MissionAirDoors.checksum(plan)` (side, position and, since R2.24, `clear_len` of each door), so two builds that place air doors differently fail
  the load barrier. Until then the rule read the cosmetic `CitySigns.layout` itself (side signs, hung ramp / shaft
  signs): a sign constant could move wall cuts and dropship entries with no checksum change. Now the looks fit the
  gameplay: `tests/test_air_doors.gd` checks every over-gate sign fits `GATE_SIGN_HALF`, every hung ramp sign lies in its
  `ramp_keep_out` or clear of every corridor, and no sign on an end wall overlaps a door's frame. Placement over seeds 1,
  4, 7, 403112 is unchanged by the switch (all 24 end walls, before and after). One or two per deck (one per end wall;
  zero, one or two before R2.24). Seeds 1, 4, 7, 403112: two on every deck (before R2.24 seed 1 deck 2 had one: its s0
  wall, with the collapsed spine gate, had no corridor clear by the first pass; it now has one at x -8.5; seed 1 deck 1's
  two moved for the usable test). Most sit just beside the avenue gate's bay
  (30.5 m from the avenue's centre line, or 42.5 m on the other side); a few go out to 120-160 m where buildings block the
  corridor nearer.
- **Sizes.** Opening 12 m wide x 6 m high clear, sill 21 m, head 27 m above the deck floor at the wall (`AIR_SILL`,
  `AIR_HEAD`, `AIR_W`). Recess 14 m deep from the wall plane (`AIR_DEPTH`; 12 m+ clear in front of its back door), 14 m wide
  inside (opening + 1 m a side) behind the wall's thickness, roof 6.5 m (6.25 m clear under its light bar). A sealed box
  of 1.2 m plates (flat floor plate, sides, back, roof) overlapping the cut wall; the wall slab is cut round the opening
  (pieces left, right, under the sill and over the head: `_cut_wall` with `sill`, which still handles several doors in one
  wall).
- **Look:** a smaller sibling of the bunker gate (the same `GateDoor`, `air_config`: jambs 1.4 m with a 0.8 m slope, frame
  1.8 m out, lintel 1.8 m with two recessed amber lamps, beacons on it, a 1.5 m sill ledge level with the recess floor),
  ribbed leaves with hazard bands, a dark recess with light strips, a light bar and a chevron back door, guide lines out
  over the ledge.
- **Walls round it** (plan meta `mission_air`, set by MissionWorld, removed at teardown; nothing changes without it):
  the opening is left out of the wall's face (bulkhead) and of a farm's backing; a bulkhead's ribs, a farm's fins, racks and
  light bars stop round the frame's rect (a fin stub and a shorter rack under it, the rest from over it). No wall triangle
  lies inside the opening (`tests/test_air_doors.gd`). A bulkhead's gallery band (15.4-16.6 m) passes under the sill ledge.
- **Ids, API, timing.** Source id `air_d<deck>_<i>` (i in the wall order s1, s0), kind `air`, the same machinery as a gate:
  `open_source(id, open_at, hold)` (open_at: the leaves start to move; `passable_after("air")` = `OPENING` 3 s), `hold_source`,
  `close_source`, `source_state` (passable, passable_at, alarm), signals, snapshot / restore (old snapshots without air doors
  restore), `set_quality`, the siren only on the active deck. `source_point(id)`: the hide point (arc x, s, plus `h` 24).
  `source_bay(id)`: `{ok = false}`. Convenience: `air_door_count(deck)`, `air_door(deck, i) -> {ok, id, deck, frame
  (global, at the opening's centre, +Z into the deck), center, x, s (the opening's foot on the wall plane), h_bottom 21,
  h_top 27, width 12, height 6, depth 14, hide (7 m behind the wall plane, mid height), out (8 m in front, mid height),
  facing}`, `open_air_door(deck, i, open_at, hold := HOLD)`, `close_air_door(deck, i)`, `air_door_passable(deck, i)`.
- **Sealing.** Shut, the door box closes the opening (stops shots and sight like a wall). Open, a 1 m sphere pushed round the
  recess stays in it (`tests/test_map_sealed.gd`); a mech (8 m capsule) cannot fit the 6 m opening, though thrusters can
  lift it that high; it can stand on the ledge or the lintel.
- **Cost** per air door: 740-760 triangles; 10 collision shapes (door box, 4 plates, floor, ledge, 2 jambs, lintel) plus the
  4 rebuilt wall pieces; its setup chunk 4-6.5 ms (the placement runs in the plan chunk, ~5 ms for three decks).

**Collapsed gates** (2026-11-23 playtest: "the wide door with rocks in it isn't working, let's make it a normal door"):
a `collapsed` gate (the 50 m x 14 m spine gate at a deck's far end; seed 1 deck 2 s0, seed 4 deck 2 s0, seed 7 deck 1 s0,
seed 403112 deck 2 s0) is drawn by `CityStreets._gate` exactly as a shut `blast_door` with its baked leaf, hazard portal
and hatched keep-clear box, no rubble; collision was and stays the wall's solid slab. The kind in the section plan is
unchanged.

**Flag** (objectives of type `flag`):
- A 16 m mast (0.55 m pole, yellow bands and finial) on a stepped base at the snapped site, readable from 80 m. Slim
  collision: a pole cylinder of radius 0.6 and the base box. `flag_site(id) -> {deck, x, s, h, snapped, ok, fit, moved_for_fit}`.
- `set_flag(id, raised, at := now)`: a 2 s swap from `at`. The banner that is up comes down over 1 s, then the other goes
  up over 1 s.
- Banners, about 5 x 3.2 m, differ in shape as well as colour. The alien one is dark slate, torn and angular (a ragged
  swallowtail), with a harsh dark-red emblem block and a glowing red slit. Ours is a clean rectangle in safety orange
  (the default crew accent, `MechMeshes.ORANGE` / `MechAccent.DEFAULT`) with a bright cream stripe.
- A zone ring of the objective's `radius` round the snapped point, 6 cm above the road or curb, left out over floor
  cuts and inside buildings.
  `set_zone(id, idle | contested | ours)` sets its glow (pale / red / orange).

**Defend asset** (type `defend`):
- A relay about 6 m to the dish's rim (plinth, cabinet with a bold cyan band blinking every 1.2 s, mast, big dish) with a
  tall thin antenna to 8.6 m (glowing tip) that marks it above parked props, at the snapped site. A chained defend shares
  its flag's site: the relay snaps beside the mast and never on it.
- `asset_site(id)`. `asset_body(id) -> StaticBody3D`: a 4.2 x 5.4 x 4.2 box in group `mission_asset` with meta
  `objective_id`, for Weapons to register as a host-owned target for enemy fire.
- `set_asset(id, hp)`, hp 0..1, changes the look only:
  - above 0.5: intact;
  - 0.5 or less: damaged (dish knocked askew, antenna bent, sparks and smoke as CPUParticles3D, none at LOW);
  - 0: wreck (cabinet slumped and scorched, mast snapped with its top on the ground, dish fallen on its rim, antenna down,
    nothing glows).

  The body never changes.

**Snap rule** (`MissionProps.snap_site`; uses plan data and the props' initial layout only, so it is the same on every
machine):
- Candidates: the site and every point of a 1 m grid centred on it within the SNAP DISTANCE: the objective record's
  `snap`, else `MissionPlan.SNAP`, else 45 m (`MissionWorld.snap_reach`). The objective's radius then applies round the
  snapped point.
- Score: distance from the site, plus 6 m when the point is not on a block (so sidewalk, plaza and park win).
- The lowest score wins (ties: smaller s, then smaller x) among points whose disc is clear. The search runs nearest first
  and stops once the distance passes the best score found, which gives the same pick as sorting every candidate. The disc is 2.5 m for a
  flag and 3.5 m for a relay. Clear means inside the walls with 4 m to spare, and clear of:
  - every building footprint and pillar core;
  - floor cuts and their curbs (+0.5 m), ramps (+2 m) and park columns (+2 m);
  - kept-clear rects and street props;
  - the ground in front of every wall gate (12 m into the map, 1 m past each side: where waves walk in);
  - the rail lane and the avenue median;
  - pieces already placed on the deck (flags first, then relays).
- When nothing is clear within the snap distance: the site itself, with `ok = false` and `snapped = false`. On seeds
  1-30 every flag and defend objective finds clear ground.

**Fit rule** (2026-11-24; `MissionProps.snap_site_fit`, used by MissionWorld for flag and defend sites only: `snap_site`
itself is unchanged for its other callers, depots and the downed-crew respawn). The widest player mech must be able to do
the objective. `CityPlan.MECH_R_MAX` = 3.6 m is the widest chassis capsule (the Bulwark; `test_site_fit` asserts it covers
every chassis in `MechCatalog`). The fit disc is that + 0.5 m = 4.1 m, so the way in must be at least 8.2 m wide.
- Reachable: a disc of 4.1 m gets from the deck's walk graph (every edge of `CityPlan.walk_graph()`) to a point within
  0.9 x the objective's radius of the site (flag 14 m, relay 30 m). It moves on a 1 m grid (`MissionProps.FitMask`,
  4-neighbour steps, all from plan data). A cell is free when the disc misses everything a mech cannot walk through below
  `MECH_TOP`, the same obstacles as `court_open`: building tiers and solids between a step (0.5 m) and `MECH_TOP`, pillar
  cores, park column rings, floor cuts plus their curb, ramps plus 0.5 m, and the walls. The mission pieces already placed
  on the deck also block it (their clear radius). Sidewalks, curbs, raised courts and knockable street props do not.
- If `snap_site`'s pick is reachable it stands, byte for byte (`fit = true`, `moved_for_fit = false`). Otherwise the
  first reachable candidate among those `snap_site` would accept, in its order (score, then s, then x). If none is
  reachable, the nearest clear road point (not on a block) within 2 x the snap distance. If that fails too, `snap_site`'s
  pick with `fit = false`.
- Cost: the mask is built once per deck that has a flag or relay, in its own setup chunk ("fit d<k>", about 5-8 ms) and
  cached on the plan. A site whose old pick stands adds well under 1 ms. A site that moves costs 12-20 ms in its chunk.
- Seeds 1-7 and 9 (default MissionPlan): 5 sites moved, 2-9 m each, all flags inside downtown blocks: seed 4 d1_p and
  d2_b0, seed 6 d0_p, seed 7 d2_b0, seed 9 d2_b0. Every other site is unchanged. Hold zones were already reachable.
  Downtown blocks still have gaps between buildings that are wider than a Strider needs (4.4 m) but narrower than 8.2 m;
  this rule does not touch the layout (`test_site_fit` prints how many).

Missions calls `MissionRules.set_site(id, x, s)` with the result.

**Bulkhead doors: entry / exit doors, tram doors (2026-11-27, R2.11a; docs/design/city-spine.md §4).** The extraction
portal, its charging frame, its energy curtain (`MissionPortal`) and `portal_event` are gone (no blue curtain anywhere).
- Gates (`CityPlan.boundary()` through `CityWalls.section_gates`, either shape of the section plan): every spine-end
  gate (the old 50 m `portal` / `blast_door` / `collapsed`, or Missions' `road_door`) is a standard road door 14 m wide
  in the wall (12.8 x 9 m clear) centred on the avenue lane; the rest of the old span is plain wall. Portal / road_door
  become kind `blast_door` with a `role` (entry / exit / ""). Deck 0 gets a `tram_door` (3.8 x 4.6 m clear) in both
  arc-end walls on the rail lane's centre (the plan's `tram_door` gates when it has them).
- Every road door looks the same, whatever its role (no lamps, no marking; siren and lamps only while the leaves open).
  Without a mission a road door is the baked shut leaf (solid).
- **Entry / exit doors** (`MissionWorld.ENTRY_ID` "door_entry", `EXIT_ID` "door_exit"): MissionGateDoor with the
  standard staging bay (20 m usable, 26 m deep, roof, sealed 1.2 m plates) closed at the back by the static inner blast
  door (the docking side, not built). `entry_door()` / `exit_door()` return `source_bay(id)` + `id`; ordinary door ids
  for `open_source` / `hold_source` / `shut_source` (closes without sealing) / `close_source` / `source_state`. Never wave
  sources (`find_gate` and `stand_in_plan` skip gates with a role). The entry door opens at setup time 0 and stays open
  (`ENTRY_OPEN_DEFAULT`) until Missions orders it; the exit door is shut.
- Beside the tram tunnel the entry bay sits off centre (`MissionWorld.plan_bay_span`: moved away from the tunnel, 20 m
  kept; `source_bay().offset`), the two frames meet as one pier between the openings (`door_fit`: reach_lo / reach_hi),
  the sign pier stands on the free side, and where a leaf's pocket would cross the tram opening both leaves slide to the
  other side (the far leaf steps back and runs behind; shut, it looks the same).
- **Crew spawn**: with the mission world set up, `CityStack.spawn_transforms(n)` = `entry_bay_slots(n)`: two columns 10 m
  apart either side of the bay's centre, rows 10 and 18 m behind the door plane, facing out. Without it (lab, tests, and
  today the game, whose crew is placed before the mission world exists) the avenue slots as before.
- **Tram doors** (`TRAM_IDS` "tram_s0" / "tram_s1"): the same MissionGateDoor at the tram door's size (`tram_config`:
  frame, lintel, leaves, beacons scaled by gh / 9), no bay and no sign. Behind it the world's dark tunnel
  (`CityWalls._tunnel`, 3.8 x 4.6 m, 40 m to its back plate; `CityDistrict._col_walls`: the wall open over the gate,
  plates round the tunnel in 10 m pieces, a back plate: nothing leaves the map, `test_map_sealed`). Open by default;
  `set_tram_door(end, open, at)` schedules it on the shared clock (in `snapshot()`), emits `tram_door_changed` and calls
  `AmbientLife.set_tram_door(end, open, at)` (the train link). `tram_door(end)` describes it.
- **Moving doors**: `MissionGateDoor.blocks()` is solid only while the leaves stand shut (shut / warn / sealed): a door
  that opens or closes never crushes or wedges a unit. `door_state` never jumps: an order landing on a closing door (or
  so soon after that its warn would start before the leaves are shut) waits for the closing to end.
- `bay_contains(id, point) -> {inside, doorway, depth}`: exact from the bay's frame (gates, entry / exit doors).
- The hold zone is the `hold` objective's `params.zone` (a Rect2 in that deck's arc coordinates; default
  `MissionRules.extraction_zone(sec, 40)`), outlined on the ground (a glowing floor outline, no wall or curtain).
  `set_hold_zone(idle | holding | contested | done)` sets its glow (pale / orange / red / green). `set_portal(p)` is a
  deprecated stub (stores `portal_progress`, draws nothing) until Missions drops its call.
**Signals** (no audio here besides the gates' sirens):
- `source_event(kind: warn | open | close | seal, id, world_pos)`: once per scheduled moment, from `advance_to`. A moment
  more than 1.5 s old when first seen fires nothing, so there is no stale klaxon after a jump or a restore.
- `flag_event(id, raised, world_pos)`: on each change.
- `asset_event(id, damaged | destroyed, world_pos)`: once each.
- `tram_door_changed(end, open, at)`: on each `set_tram_door`.

**Late join.** `snapshot()` returns `{now, doors: {id: [open_at, close_at, prev_close_at, alarm_from]}, sealed: {id: seal_at}, flags: {id:
[raised, from, t0]}, zones, assets, hold}` (the entry / exit and tram doors' schedules in `doors`), and `restore(d)` applies it (a door it does not name gets its default). `net_fields()` classifies every var:
schedules and states are OWNER (the host decides them and Engine carries them), nodes are LOCAL, and the plan and the
sites are SPAWN.

**Who calls what.**
- Engine (every machine):
  - `setup_mission(plan)` once the stack and the plan exist;
  - `advance_to(clock)` every frame;
  - `open_source` for each `mission.wave` order, with the order's `open_at`;
  - `close_source` when a source is closed;
  - `set_flag`, `set_zone`, `set_asset`, `set_hold_zone` from `mission.state`; `set_tram_door` when the host changes one;
  - `snapshot` / `restore` for a late joiner;
  - the signals for the HUD.
- antigravity: spawn gate waves in the staging bay (`source_point(id)` / `source_bay(id)`) up to `open_at` (the leaves
  start to move then; the units can leave from `passable_at`), and lift waves in front of the doors at `open_at`; play
  the lift chime and door sounds from `source_event` (the gate's siren is its own: do not add a second one).
- Weapons: use `asset_body(id)` (or group `mission_asset`) as an enemy-fire target and report hp to the host, which feeds
  `set_asset`.
- Missions: pass `flag_site` / `asset_site` to `MissionRules.set_site`.

**Lab and shots.** In the city lab with site "stack":
- option `mission` (off / doors / flag / asset / all) loops the pieces;
- `mission_phase` pins one look;
- cameras: `mission_gate`, `mission_bay` (into a gate's staging bay from the street, 6.5 m up), `mission_lift`,
  `mission_flag` (45 m), `mission_flag_far` (80 m), `mission_asset`, `entry_door` / `exit_door` / `tram_door` /
  `tram_door_s1` (the bulkhead doors); phase `opening` shows the leaves moving with the lamps lit; phases `shut` / `open`
  apply to the entry / exit and tram doors too.

The shots are in `docs/design/city-shots/mission_*.png`; the bulkhead doors in `docs/design/city-spine/door_*.png`.

## 10. Bridges over a ramp, and the ramp's cut (2026-11-23)

User: "the first bridge across the ramp is always too low and you pass through it" and "z-fighting on the cut for ramps".

**How bridges were made.** Not in the section plan: the section cuts the whole ramp connector rect out of the floor of the
deck the ramp leaves (`SectionPlan.is_hole`, `CitySite.for_deck`), and `CityPlan._bridged` cut every cross road back out
of that hole, so each cross road over the ramp lane was a bridge: the full slab (8 m; the cut's faces and the soffit are
drawn that deep) whose collision is only its top 1 m. Mesh (`CityStreets` ground, `_floor_hole`, `_soffits`) and
collision (`CityDistrict._col_floor`, `_col_walls`) all read `plan.floor_cuts()`.

**Rule** (`CityPlan.BRIDGE_CLEAR` = `MECH_TOP` 8 m (the mech's capsule, MechSpawn) + 1.5 m): a cross road may bridge a
ramp's cut only where the clear height from the ramp's surface to the bridge's underside, on the ramp's centre line at
the bridge's edge nearer the head (`CityPlan.bridge_clearance`), is at least 9.5 m (`bridge_allowed`, applied in
`_bridged`, so plan data, mesh and collision agree). Where it fails, the cut runs on under the road: the road ends at the
cut's curb (0.5 m, solid) and railing on both sides, like the rest of the cut's long sides. The head's own cross road
stays the ramp's mouth (`floor_cuts`).

Clearance on the centre line, section seeds 1-8 (`tests/test_city_ramp_bridges.gd` prints it):

| ramp (seeds) | cross road past the head | from head | clear | before | after |
|---|---|---|---|---|---|
| deck 0 -> 1, ramp_a (1, 2, 4, 5, 8) | first | 83.0 m | 6.76 m | bridge | **removed** |
| | second | 173.0 m | 22.76 m | bridge | bridge |
| deck 1 -> 2, ramp_b (3, 4, 6, 7) | first | 93.8 m | 6.89 m | bridge | **removed** |
| | second | 194.6 m | 22.89 m | bridge | bridge |

With the default grade the rule removes exactly the first; a much gentler ramp (grade under about 0.1) would also lose
the second, and the rule handles that. A mech walking down (`tests/test_city_stack_walk.gd` `_headroom`: the real capsule
every 2 m from 20 m above the head to 10 m past the foot) touches no collision and stays under every drawn slab; with
the rule disabled the same check finds 5 poses per ramp up to 1.4 m into the old first bridge.

**Plan coherence.** `CityPlan.road_graph()` (EnemySquad, EnemySpawner, BotNavigator) drops every edge that crosses the
inside of a floor cut (an edge along a cut's edge, the mouth, stays). Everything else already reads the cuts:
`clear_at` (props, spawn slots, mission sites), LifePlan (spine crossings avoid the cut: none at that line now),
LifeTraffic laps, BotRoutePlanner, MissionProps. Stand-alone plans have no holes: their checksums and goldens are
unchanged; section deck checksums change (floor holes are in them).

**For the section plan (Missions, not changed here).** `SectionPlan.road_graph()` / `route.vehicle` still link the spine
across cross line `j = top_line + sign(foot_line - top_line)` on the ramp's upper deck (`from`). That crossing is gone
for the ramp lane's width only (`x0..x1`; the rest of that cross street is unchanged); the edge to drop is the one
`_crossing_blocked` already drops at the foot: `(spine_line - 1) <-> spine_line` for ramp_a, `spine_line <->
spine_line + 1` for ramp_b, on deck `from`, at that line. In section terms: for each cross line `j` strictly between
`top_line` and `foot_line`, near edge distance `d = |line_s(from, j) - line_s(from, top_line)| - line_width("x", j)/2`,
clearance `pitch * d / |line_s(from, foot_line) - line_s(from, top_line)| - slab`; drop when under 9.5 m.

**The cut's z-fighting.** Found by the geometry audit (`city-geometry-audit.md`): the parapet end blocks at the ramp's
head straddled the floor hole's curb (centred on the parapet, 0.8 m wide), so their end faces lay in the curb's end face
(concrete against curb colour, both sides of the head, at eye level); they now stand flush inside the ribbon
(`CityStreets.end_blocks`, collision follows). The ceiling ribs below ended in the plane of the opening's inside faces
and of the floor hole's cut faces above (no end face there now). The ramp's lines are layer 2 decals (4 cm). Not a
z-fight: where the ramp's foot meets the road the two surfaces are 10 degrees apart (a sliver of millimetres), and the
lower deck's ceiling sits 5 cm in front of the soffits above it by design. Shots: `city-shots/ramp_head_before.png` /
`_after.png`, `ramp_cut_before.png` / `_after.png` (each with a `_b` frame from 0.7-1.5 m away), `ramp_foot_after.png`,
`zfight_ramp_mouth.png`.
