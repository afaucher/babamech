# Hangar: inside the assault boarding vessel

The pre-mission screen (FrontEnd's hangar) is the vehicle bay of a **military assault boat clamped to the habitat's
hull**, about to force its way aboard. The crew's mechs stand in docking cradles along a central aisle; at the far end a
heavy breaching door is pressed against the station hull.

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
- Ammunition racks between the cradles.
- Breaching door at the far end: a two-leaf armoured door in a striped frame, a red lamp each side.

## States
- **Prep**: cool white work lights, clamps closed on the mechs, calm.
- **Alert** (Launch pressed): work lights drop, red rotating beacons and amber strobes, the countdown strip on the door
  glows, the cradle clamps swing open. After the countdown the mission (for now the test drive) loads.
- (Breach, from the same grid, is left for the mission start: the door cutting through the hull.)

## Layout
- Aisle along the bay; four cradles, two each side (seat 1 right-front, 2 left-front, 3 right-back, 4 left-back).
- Mechs face the aisle, turned toward the camera so the heads read. Name tag above each.
- Camera at the near end of the aisle, looking toward the door. One mech: framed on its cradle; a crew: the whole bay.

## Networking
Cosmetic. The alert plays locally when this machine launches. When missions are synced, the host's Launch becomes a
scheduled effect (one broadcast with a start time; every machine plays the same alert and loads together).

## Code
`HangarBay` (`scripts/ui/hangar_bay.gd`): the set, cradles, lights and the prep / alert states. `MechStage` shows it for
the hangar screen (the main menu keeps the turntable). Lab subject `hangar`.
