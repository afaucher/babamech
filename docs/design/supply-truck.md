# Supply truck ("tender"), visual brief

Status: **draft for discussion**, 2026-11-23. Not approved, nothing built. Parent: [enemies.md](enemies.md) (§7 art
direction: "Repainted civic", L1 slate / brick livery, Descent stencil). Concept grids: `art/renders/tender_r1/`.
Names (`tender`, `mender` drone) are placeholders.

## 1. The idea
A support vehicle that trails the enemy squad (tanks, striders, troopers) and launches small **repair drones** to patch
up whichever unit is hurt. It has no gun. It is the unit players should learn to hunt first, so it must be **easy to
identify once seen** without being easy to see from far away (same rule as the rest of the roster: mid-value L1, no
glowing beacons, no floating icons or warning beeps; tells come from the unit itself).

## 2. What it looks like
- **A repainted civic truck**, like the other units: the habitat's own service vehicle in the invaders' livery (warm
  slate body, lighter plates, steel, brick-red trim bands, cream Descent stencil, amber service lamps). No alien parts.
- **Silhouette distinct from the tank:** wheels (6x6) instead of tracks, a tall boxy body, **no barrel**. The one
  unusual shape on it is the **drone carrier** (rack, hive or mast: grid columns), so "box truck with a thing on top"
  becomes the read for "kill this first".
- **Size:** about 4.2 m W x 10 m L x 5 m H (tank is 6.8 x 9.6 x 5.4; mech 8 m tall). Big enough to see behind a tank,
  low enough to hide behind one.
- **Docked drones are visible** on the carrier: the count still docked is the count it can still send. Players read its
  remaining capacity from the model, not from a UI.

## 3. Behaviour cues players read (all diegetic)
| Moment | What shows | Why |
|---|---|---|
| Following | Amber cab lamps idle, drones docked | Reads as "service vehicle", not a threat |
| Dispatch (telegraph >= 0.3 s) | Cab lamps start rotating, cradle / hatch opens, drone spins up and lifts off | A beat to shoot the drone at launch, or the truck before it goes |
| Drone repairing | Drone hovers over the hurt unit, **spread scanner beam** sweeping it (enemy colour, see §4); repaired panels flash cream briefly | Shows which enemy is being healed: a reason to switch target |
| Drone shot down | Pops, small debris; its cradle stays empty | Permanent progress for the player |
| Truck hurt | Smoke from the carrier, lamps flicker; carrier destroyed = no more launches | Weak point that rewards flanking |

## 4. Repair drones (enemy)
- Small (~1.2 m) square quad-rotor, slate body, cream rotor guards, brick nose band: the same family as the truck.
- **Beam:** the same spread-scanner shape the player's repair drone gets (beam art pass, `tools/scanner_beam/`), but in
  the **enemy colour** so a glance tells friend from foe: player = green; enemy = warm cream / amber. Never green, never
  red (red is enemy fire / telegraph).
- Fragile: one or two hits. Worth shooting, but the truck is the better target.

## 5. Picks and open questions
- **Picked A1 "utility truck + open roof cradles"** (user, 2026-11-23; `art/renders/tender_r1/grid_tender_r1_s4242.png`,
  `A1_utility_cradles_s*.png`): long municipal utility truck, low flat cab, flat equipment bed with an open steel rack of
  drone cradles in a row (one empty per drone out), tool lockers along the sides. Refinement round r2: `art/renders/tender_r2/`.
- **Picked r2 #2 "low rack, landing pads"** (user, 2026-11-23; `art/renders/tender_r2/grid_tender_r2_s4242.png`,
  `R12_low_pads_s*.png`): a low steel rack directly on the bed, four flat square landing pads with brick-red corner
  clamps; an empty pad shows bare with its clamps open. Drones sit about cab-roof height.
- **Beam picked C3 "moving scan line"** (user, 2026-11-23; `tools/scanner_beam/shots/grid_beam_*.png`): one bright ring
  that travels up and down the target's body with a fading trail, joined to the drone by a faint thin wedge. Player =
  green; the enemy drones use the same shape in their own colour.

Open:
1. Enemy beam colour: cream, amber, or the L1 vent orange.
2. Can a truck be destroyed outright, or only disarmed (carrier destroyed, truck flees)?

Networking shape (for later, not decided): truck = host-owned actor like the tank; each drone dispatch is a scheduled
effect (one event, then every machine flies it from the clock), as the player's repair drone already does.
