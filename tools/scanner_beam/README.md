# Repair-drone scanner beam probe

Art-direction render probe for the repair drone's beam ("look more like a spread scanner" instead of the thin line).
**Not game code:** `scripts/combat/equipment/repair_drone.gd` is untouched; this only draws candidate looks.

Scene (`scanner_beam_probe.gd`): city seed 7 under the real day light rig (GraphicsQuality HIGH), a player mech
(MechModel, scale 2, chicken / strider, ~11.5 m to the top of the head) in the left lane short of an intersection, facing
down the avenue, and the real flying drone mesh (`weapon_repair_drone_flying`, accent tinted, FLY_SCALE 2.1) on its orbit
6 m above the back mount and 5 m out, to the mech's front-right. The drone repairs its own launcher. Everything is the
game's player green `Color(0.25, 1.0, 0.45)`, unshaded, alpha-blended (no additive), occluded by the mech (no x-ray).
The faint 15 m ground ring of the game is drawn in every cell.

Grid: rows = shape, columns = treatment.

| | 1 soft volume | 2 edges + lattice | 3 sweep |
|---|---|---|---|
| **A fan** | A1: translucent triangular sheet (alpha 0.06 at the lens to 0.24 at the target) plus a narrower core sheet, a bright hot leading edge across the chest, faint side edges | A2: near-empty sheet, bright side edges and leading edge, 5 faint rays, 2 cross lines, barcode ticks along the edge | A3: a vertical blade (knees to head) panning side to side across the body; hot line where it is on the body, dim off it; a faint trailing swept band |
| **B cone** | B1: octagonal frustum from the lens, faint at the top, denser at the bottom, landing in a bright ring around the waist with a soft disc fill (the "footprint") | B2: 8 edge lines, 2 lattice rings up the cone, bright waist ring, lens ring | B3: a narrower spot cone whose disc footprint (facing the drone, on the mech's front) slides diagonally across the torso; ghost ring where it was |
| **C scan lines** | C1: a translucent 1.3 m band around the torso, bright top line and two soft lines; a faint thin wedge to the drone | C2: 4 stacked rings (bright top, fading down) with vertical lattice ticks; two thin lines to the drone | C3: one hot ring travelling up the full height with 3 fading trail rings and a soft band below it; faint wedge to the drone |

`current_*.png` is the game's look today (0.06 m prism to the chest), for comparison.

Sweep cells (A3/B3/C3) show sweep position 0.3 (of -1..1) in the grids; `<cell>_close_f0..2.png` and
`grid_beam_sweep_strip.png` show positions -0.8 / 0 / 0.8.

## Outputs (`shots/`)
- `grid_beam_gameplay.png`: chase-camera view (the game's ChaseCamera numbers: 16 m boom, 9.5 m pivot, right shoulder,
  fov 70). The drone is small here (1.6 m at ~22 m): that is the real gameplay scale.
- `grid_beam_close.png`: 3/4 view from the mech's right front, drone and mech in frame.
- `grid_beam_sweep_strip.png`: 3 frames of each sweep cell (close).
- `<cell>_<gameplay|close>.png`: the full 1600x900 shots.

## Rerender
Real renderer on the hidden desktop only (never a visible window), under the shared GPU lock (waits for ComfyUI):

```powershell
.\tools\scanner_beam\run_scanner_beam.ps1                      # all cells, both cameras, strips, grids
.\tools\scanner_beam\run_scanner_beam.ps1 -Cells A3,C3 -Cams close -Phase -0.5
.\tools\scanner_beam\run_scanner_beam.ps1 -NoStrip -NoGrid
```

Log: `test_logs\scanner_beam.log`. A `--headless` run only checks the script (it skips the shots).
The cell geometry is in `_fan` / `_cone` / `_scan` (built with SurfaceTool each shot; lines are thin square bars).
