# Hangar: inside the assault boarding vessel

The pre-mission screen (FrontEnd's hangar) is the vehicle bay of a **military assault boat clamped to the habitat's
hull**, about to force its way aboard. The crew's mechs stand in recessed alcoves side by side along one wall of the bay,
facing the aisle and the camera; on the end wall a heavy breaching door is pressed against the station hull.

Picked 2026-11-21 from `hangar/grid_hangar_r1.png` (rows: vessel origin, columns: moment): **assault / prep -> alert**.

| Ref | Render | Workflow / seed |
|---|---|---|
| Prep (the hangar while you pick a loadout) | `hangar/hangar_assault_prep_s41.png` | flux3_klein_t2i, seed 41, 1024x576 |
| Alert (after Launch, before the mission loads) | `hangar/hangar_assault_alert_s41.png` | flux3_klein_t2i, seed 41, 1024x576 |

Regenerate with `hangar/hangar_r1.ps1` (local-render skill; prompts are in the script). The renders are mood and
material references only: the mechs in them are generic, the scene uses the real `MechModel`, in the locked flat
low-poly look.

## Look
- Gunmetal armour plates, exposed ribs and ceiling girders, heavy hydraulic cradle clamps.
- **Yellow-black hazard stripes**: aisle edges, cradle lips, the band in front of the breaching door, the door frame.
- Ammunition racks against the wall beyond the alcove row.
- Breaching door on the left end wall: a two-leaf armoured door in a striped frame, a red lamp and a strobe each side.

## States
- **Prep**: cool white work lights, clamps and brace arms open (the shoulder clamps stowed upright on the posts, the
  brace rams back in their sleeves), calm. Empty alcoves stay dark.
- **Alert** (Launch pressed): work lights drop, red rotating beacons (one over each post) and amber strobes, the ambient
  turns dim red, the countdown strip over the alcoves glows and runs down, the shoulder clamps swing down level onto the
  mechs' shoulders and the brace rams close on their hips (bracing for the breach). After the countdown the mission (for
  now the test drive) loads.
- (Breach, from the same grid, is left for the mission start: the door cutting through the hull.)

## Layout (one wall, 2026-11-22)
The first layout (an aisle with two cradles each side, camera at the near end) had mechs turned 143 degrees toward the
camera but out of their bays, clamps through the mechs and seat 2 cut off at the menu's edge. Rearranged to one wall:
- **The camera looks at one side wall** of the bay. Four recessed alcoves side by side along it (`ALCOVE_X`, 6.2 m
  apart: 5.4 m clear between 0.8 m bulkhead posts, 4.7 m deep), under a header carrying the striped beam, the countdown
  strip and the beacons. Each alcove: a cradle platform with a striped lip, a dark ribbed back, a hose, its own lamp and
  light strip, two shoulder clamps and two brace arms, and the pilot's nameplate above the mech.
- **Seats fill from the middle** (1: left-centre, 2: right-centre, 3: far left, 4: far right), so the occupied alcoves
  are always side by side.
- **Mechs face the camera** (`MECH_YAW` = PI), upright, fully inside their alcove (the mech's box, x +-1.7 m, z -1.32 ..
  +2.13 m around its origin, fits the 5.4 x 4.7 m alcove).
- **Framing rule: centre on the occupied alcoves.** `HangarBay.camera_frame(aspect, orbit)` takes the box of the
  occupied alcoves (posts, platform and header included), looks at its centre from the aisle (5 degrees down, FOV 50
  vertical) and backs off exactly as far as the tightest corner needs to stay 4 % inside every edge of a view of that
  aspect. MechStage passes its SubViewport's real size, which is the preview area right of the menu panel (the panel is
  a sibling in the HBox, so its width is already taken out), so the fit holds at 16:9, 4:3 and ultrawide and adapts when
  the window or the panel changes. Picked over "always frame all four": a solo pilot's mech fills most of the preview
  instead of a quarter of it, and a full crew still gets every alcove; empty neighbours show at the edges, dark.
- **Drag orbit** +-0.3 rad (`ORBIT_MAX`) about the frame's centre, refitted at every angle, so it can never swing behind
  the wall or push a mech out of the preview.
- **Clamps from the real mech box.** `fit_clamps()` measures each mech's meshes (`mesh_box`, the same walk as
  `tag_height`) and fits that alcove's hardware: closed, each pad stops `CLAMP_GAP` (6 cm) short of the box. The hinged
  shoulder clamp's far corners sweep a circle that just reaches that line, so it never cuts in mid-swing. Measured by
  `tests/test_menu.gd` on a crew of four with the widest weapons, chicken and forward legs alike: closest approach 0.51 m
  in prep, 0.10 m mid-swing, 0.06 m in alert; farthest closed pad 0.11 m.
- Lab subject `hangar`: crew of four by default, focus on the occupied alcoves' centre, the preset views turned to face
  the wall (`lab_view_yaw` = PI), starting at the hangar screen's distance.

Shots: `hangar/one_wall_*.png` (crew of 1, 2 and 4, prep and alert, and the lab).

## Networking
Cosmetic. The alert plays locally when this machine launches. When missions are synced, the host's Launch becomes a
scheduled effect (one broadcast with a start time; every machine plays the same alert and loads together).

## Code
`HangarBay` (`scripts/ui/hangar_bay.gd`): the set, alcoves, clamps, lights, the prep / alert states and the framing
(`camera_frame`). `MechStage` shows it for the hangar screen (the main menu keeps the turntable) and frames it from its
viewport size. Lab subject `hangar`.
