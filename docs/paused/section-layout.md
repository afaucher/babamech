# Paused: mission-section layout (multi-deck planner)

> **Resumed 2026-11-21 (late).** Done since: `SectionPlan.deck_view(k)` (one deck's blocks, road strips, pillars,
> connector parts, ceiling openings and walls), the lift footprint fixed to the 22 m platform on every deck, and the API
> the city generator reads confirmed as frozen. Step 2 below is now the city session's work in progress
> (`docs/design/city-section-mode.md`, `CityPlan.for_deck`). The open questions at the bottom are still unanswered; the
> defaults stand as provisional.

Paused 2026-11-21 by the user: the playable demo runs in a single city district (the test drive), so multi-deck section
planning is off the critical path. Nothing is committed. Session: "mission-section layout" side session.

## What was paused

The macro layout of a mission section: several concentric decks of the ring habitat as one arc segment, with zones,
pillars, transit, connections between decks, boundary walls and the route from entry to extraction.

Built and working:
- **Design** (a proposal, not yet confirmed by the user): section size, the cross-section and deck-plan views, the
  zigzag critical path, pacing, zone rules, the transit spine, ramps / freight lifts / shafts / a locked express lift,
  the pillar grid, boundary walls and gates, enemy and occupation hooks, the plan format.
- **Planner** `SectionPlan`: seeded, deterministic, checksummed. Outputs decks, zone regions per deck, the pillar grid
  shared by all decks, connectors, the road and rail spine, four boundary walls per deck with gates, entry and
  extraction, a vehicle route and a mech route, and hooks.
- **Lab subject** `section`: 3D block-out with a cutaway, plus the 2D cross-section and deck plans.
- **Tests**: determinism, routes for vehicles and mechs, pillar alignment between decks, cell reachability, connector
  clearance from pillars, boundaries; 40 seeds plus the extremes of every setting. Passing when paused.

Not built:
- Nothing consumes the plan. The city generator (`scripts/world/city/`) still lays out one district on its own and
  picks its own pillar lots.
- The backdrop beyond window walls (the plan only flags which walls need one).
- Spiral ramps, rail stations as geometry.

## Files

| File | What |
|---|---|
| `docs/design/mission-section.md` | The design; status note at the top, open points in §13, plan format in §11 |
| `scripts/world/section/section_plan.gd` | `SectionPlan`: the planner and the plan data |
| `scripts/world/section/section_map.gd` | `SectionMap`: the 2D cross-section and deck plans (a Control) |
| `scripts/world/section/section_lab.gd` | `SectionLab`: lab subject `section` |
| `tests/test_section_plan.gd` | The planner's tests |
| `scripts/app/lab_registry.gd` | One line registering `section` |

Outside the repo, in the sessions' shared notes folder: `section-plan.md`, the hand-over describing the plan format for
the city generator session (sent to it twice; delivery was queued, never confirmed read).

To look at it: `.\test_runner.ps1 -TestName test_section_plan`, and `.\lab.ps1 section` (takes the GPU lock) or a
hidden-desktop screenshot with `--subject section` (docs/testing.md).

## Exact next step

1. Get the open questions below answered by the user and update `docs/design/mission-section.md` (and the planner's
   `DEFAULTS` in `section_plan.gd` if the size changes).
2. Make the city generator consume the plan for **one deck**: for each urban region of `plan.decks[k].regions`, build a
   district inside the region's cells (`plan.cell_rect`), with a pillar tower exactly at each `plan.pillar_point(k, id)`
   (style and size from `plan.pillar_style` / `plan.pillar_radius`), nothing built on `plan.decks[k].keep_clear` or
   connector footprints (`plan.connector_rect`, `plan.is_hole`), and the walls of `plan.boundaries`. This needs agreeing
   with the city generator's owner first: `CityPlan` currently takes only a size and a seed, uses its own origin and
   radius, and places its own pillars.
3. Then the remaining zones (park, industrial, transit, open air), the connectors as geometry (ramp, lift, shaft), and
   all decks in one scene.

Per the user's standing instruction, code changes go to Opus subagents with tight briefs; design and review stay in the
session.

## Questions for the user: answered 2026-11-22

1. **Section size**: to be settled by playtest. Target is 30 minutes or less, probably nearer 15; the demo district
   clears in about 2 minutes. Defaults stay provisional.
2. **Entry and exit**: keep "finish the mission" (top in, bottom out); what finishing means is not defined yet.
3. **Pillar density**: fine as seen in the demo city.
4. **Ramps**: straight only for now; spiral later.
5. **Lowest deck**: no hull shafts or windows yet.
6. **Boundary walls**: fine for now, as shown (shots in `test_logs/shots/walls_*.png`).

Settled earlier: the map is an arc segment, not the whole ring, and the ring radius is free (default 400 m, top deck).
