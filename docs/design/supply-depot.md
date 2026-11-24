# Military supply depot, visual brief

Status: **picked B2 (user, 2026-11-23)**, 2026-11-23. Nothing built. Gameplay comes from Missions (a host-arbitrated
world object, one or two per deck, finite power cores: a player takes a core from it). This doc covers the look only.

## Constraints (from the brief)
- Reads at mech scale (8 m mech) from the play camera.
- **Cores left show on the model itself**, never in UI.
- Player side / neutral: the habitat's own civil-defence forces, **never the enemy livery** (enemy = slate / brick, see
  [enemies.md](enemies.md) §7).
- **No green** (the repair beam's colour, [back-equipment.md](back-equipment.md)). Also avoid red (enemy fire /
  telegraphs) and amber (enemy service lamps).

## Round 1 (`art/tools/depot_r1.ps1` -> `art/renders/depot_r1/grid_depot_r1_s4242.png`, `_s777.png`)
Livery used in every cell: off-white body, charcoal frames, safety-orange hazard stripes and corners, orange cross-and-
bolt service emblem (it matches the player mech's white / orange). Cores: chunky cylinders with **ice-blue** glowing
cells and charcoal caps; empty places are dark and hollow.

| | 1 upright rack | 2 socket wall | 3 ring pylons |
|---|---|---|---|
| **A crates + cage** | A1 | A2 | A3 |
| **B hardened bunker kiosk** | B1 | B2 | B3 |
| **C shipping containers** | C1 | C2 | C3 |

- Rows = form: a crate stack around an open cage with a ramp and floodlights / a squat sloped-slab bunker kiosk with
  rolled-up blast shutters / two opened shipping containers with a gantry and low barriers.
- Columns = how the cores read: upright cores in a row of slots out front / cores slotted into a socket grid like a
  battery bank / tall pylons whose stacked rings go dark from the top as cores are taken (a fill gauge).

## Read (round 1)
- **Ice blue works:** it is the brightest thing in the frame against cream / terracotta, and it is nobody else's colour.
- **The socket wall (column 2) shows the count best:** a grid of lit and black circles reads like a battery meter. B2 and
  C2 make the strongest "how many left" read; the bunker (B) reads most military and the most solid.
- **Upright rack (column 1)** is the most literal "take one" read (B1, C1): you see the item you will pick up. But a long row
  of 8 is hard to count at a glance.
- **Ring pylons (column 3)** stand out from far away because they are tall, but the count is abstract (rings, not cores)
  and they read as an energy plant more than a supply point.
- **Scale:** the depots came out waist-to-chest high on the mech. That's fine for a pickup, but the pylons are the only
  part that rises over cover; a tall marker (mast, floodlight or flag pole) may be needed whatever form wins.
- The generator ignored "half stocked" in most cells (nearly all full) and added "MILITARY SUPPLY DEPOT" signage. The
  real model will show empty places by construction, and gets no text.

## Pick
**B2 "hardened bunker kiosk + socket wall"** (user, 2026-11-23; `art/renders/depot_r1/B2_bunker_wall_s4242.png`,
`_s777.png`): squat bunker of sloped off-white slabs with charcoal frames and orange hazard corners, heavy overhanging
roof, blast shutter rolled up over a socket wall; each core sits horizontally in a round socket, lit ice blue when
stocked, a black hole when taken. The socket grid is the count.

## Open
1. Refinement round (core count, tall marker, how empty looks: dark socket vs open cap).
2. Number of cores per depot (Missions): it decides how many sockets / slots the model needs.

## Build (model only, 2026-11-23)
The B2 model, cosmetic only: the depot's state (cores left, destroyed) stays host-arbitrated in the Missions code
(`scripts/game/supply_depot.gd`, `MissionDepots`), which pushes it to the model. Shots: [supply-depot/](supply-depot/)
(`depot_chase_cap3_3.png`, `depot_close.png`, `depot_destroyed.png`, `depot_far_40m.png`).

- **Scene** `scenes/props/supply_depot_kiosk.tscn` (root `Node3D` + `scripts/world/depot/depot_kiosk.gd`, `DepotKiosk`);
  meshes in `scripts/world/depot/depot_meshes.gd` (`DepotMeshes`, MeshKit, cached, every piece a closed outward shell).
  Lab subject `depot` (`depot_lab.gd`: stocked 0-4, capacity 1-4, marker, destroyed, take / refill actions).
- **Frame:** origin on the ground at the centre, up = local +Y, the socket wall faces **local +Z**. Body 6 x 4 m (6.6 x
  4.6 m with the roof overhang), roof top 4.35 m, beacon ~8.3 m (mast on the rear-left roof corner).
- **Sockets:** exactly 4, a 2 x 2 grid on the recessed charcoal panel (front face z = 1.3 m), columns x = -0.66 / +0.66,
  rows y = 3.05 / 2.0 m, collars 1.0 m across. Index 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right (seen from
  the front). The first `stocked` hold cores, so the bottom-right goes dark first.
- **Interface:** `set_cores(stocked, capacity)` (state, idempotent; sockets < stocked show an ice-blue core, the rest are
  black holes, sockets >= capacity black from the start; only visibility changes, no rebuild), `core_taken(index)`
  (one-shot: a copy of the core slides out 1.4 m and dims over 0.6 s; call `set_cores` right after), `set_destroyed(dead)`
  (scorched wreck, roof slumped, mast snapped, every socket dark; reversible), `socket_point(index)` (local centre of the
  socket's opening), `set_marker(on)`, `set_render_layers(mask)` (every mesh + the light's cull mask; the pieces are built
  in `_init`, so call it before the node enters the tree). Queries: `socket_count`, `stocked_count`, `capacity`,
  `is_stocked`, `core_shown`, `is_destroyed`.
- **No collision** (the game adds its own box). **Lights:** cores and beacon are unshaded vertex colour (emissive look);
  one small ice-blue `OmniLight3D` (range 6 m, no shadows) scaled by the cores shown, off when none or destroyed.
- Colours: `MechMeshes.WHITE` / `ORANGE` / `DARK` (the player mech's), ice blue `#7fd8ff` with an `#e2f8ff` centre; no
  green, red or amber (`tests/test_depot.gd` checks the faces).
