# Vertical slice: one playable mech, one small arena

Status: **agreed scope**, 2026-11-21 (decisions D1–D5 confirmed). Parent design: [game-design.md](game-design.md). Builds on the scaffold
(menus, settings, hangar, lab, crew session; see [../networking.md](../networking.md)).

## Goal
Prove the core feel in the smallest playable loop: **walk, jump, aim and shoot a chicken-legged mech in a small vertical
arena, against targets that shoot back, with heat as the limit, with up to 4 friends.** Everything outside that is cut.

The slice answers four questions:
1. Does the IK walk and thruster jump feel good at mech scale?
2. Does the aim point + per-hardpoint line of sight read clearly and feel fair?
3. Does heat make loadout and firing choices interesting?
4. Does the inherited net model hold up for 2–4 mechs fighting under a simulated `coast` link?

## Player loop
Main menu → Play/Host (or Join) → hangar (pick loadout) → **Launch** → spawn in the arena → fight waves of target robots,
tear down alien banners → all players disabled = fail, wave cleared = win → back to the hangar.

## In scope

### Mech (one chassis, "Strider")
| Area | Slice version |
|---|---|
| Model | Placeholder low-poly from the scaffold, rebuilt to the locked shape: no arms, reverse-jointed chicken legs, nose hatch + back plate, raised shoulder mounts. Head = one of the four placeholder heads. |
| Hardpoints | **5, matching the locked design**: 2 shoulder (raised), 2 torso side, 1 back. *(Scaffold catalog still says "arm"; rename to `side`.)* |
| Walk | Kinematic character controller (no rigid bodies) whose **up vector follows the local ring gravity** (radial). **Procedural two-bone IK** per leg with planted feet, step trigger by distance/speed, gait that scales with speed (walk → run), body bob and lean. Turn in place. |
| Thrusters | **Space** = thrust (hold). Jump onto roofs, hop gaps, slow falls. Thrust makes heat. **Auto emergency burn** on long falls; landing above a speed threshold = **hard landing**: leg damage + short stagger. |
| Camera | Over-the-shoulder third person, mouse look, collision-aware boom. |
| Aim | Ray from camera to the **aim point** on any surface, drawn as a marker; each straight-flight weapon draws a **line-of-sight indicator from its own hardpoint**, coloured blocked/clear, with incremental ticks along it. |
| Heat | Single gauge. Passive heat from mounted weapons, active heat per shot, thrust heat, constant cooling. **Overheat → shutdown (no move/fire) → cooldown → reboot.** |
| Damage | Component HP: head, torso, left leg, right leg, each weapon. Destroyed weapon = unusable; destroyed leg or head = **disabled**. HUD diagram of the mech. |
| Revive | Teammate holds interact on a disabled mech for N seconds → revived at low HP. (No pickups in the slice.) |

### Weapons (3, one per firing model)
| Weapon | Mount | Model | Tests |
|---|---|---|---|
| **Laser** | side | Hitscan beam, straight line from hardpoint | Hardpoint line of sight, instant hits |
| **Rocket pod** | shoulder | Projectile salvo, straight flight, splash | Travel time, scheduled-effect networking |
| **Mortar** | back | Arcing shell to the aim point, splash, no LOS needed | Indirect fire over cover |

Each has weight, passive heat, active heat, damage, reload/cooldown, ammo (unlimited in the slice). Fire groups: LMB = side
weapons, RMB = shoulder, a key (e.g. F) = back. Loadout chosen in the hangar.

### Arena
- **Small and vertical**: roughly 120 × 120 m footprint, one deck, a **ceiling** ~40 m up.
- **Seeded block layout** (generator v0, deterministic, checksummed): a street grid of blocky buildings at 3–4 height
  bands with jumpable roof gaps, one or two **pillar buildings** reaching the ceiling, one small **park** patch (open
  sightlines), a raised walkway or rail viaduct for a mid level.
- **Look** from the locked environment art: chunky low poly, flat colour per face, day lighting from ceiling light strips,
  cream/terracotta/sage palette, ceiling with ribs and light strips.
- **Occupation dressing**: alien banners on buildings (**destructible**), a few surveillance pylons (decor).
- **Curved ring segment** (D1): the arena sits on an arc of a ring deck. The floor curves along the spin direction and
  is level across it; the ceiling follows the same arc. **Gravity points outward from the ring axis at every position**,
  so "up" changes as you move along the arc. Ring radius is a tunable (lab), chosen so the curve is clearly visible
  across the arena (Cluckipede look). The rest of the ring beyond the arena is a low-detail backdrop.

### Enemies
- **Turret** (D3): a hijacked civil-defense gun emplacement placed by the generator on streets and rooftops; static,
  host-owned. Behaviour: acquire the nearest visible mech, rotate to track, telegraph ≥ 0.3 s, fire a projectile.
  Component HP (barrel, base) and destructible.
- Squad coordination (shared last-known position, attack slots) **only in its simplest form**: a shared target board and
  at most N robots firing at one mech at once. Full squad roles come after the slice.
- Waves: K turrets activate/deploy, next wave when cleared, 3 waves = win.

### Multiplayer
- 1–4 players, host + joiners from the existing crew session. Arena built from the host's seed + checksum barrier.
- **Owned-mech sync**: hand-packed 30 Hz snapshots of position, velocity, facing, aim point, thrust state, heat bucket,
  component HP; remote mechs interpolated, IK runs locally on every machine from the synced motion.
- **Weapons as scheduled events** (`fire{hardpoint, weapon, origin, aim_point, t}` applied at t + lead); victim decides
  hits on mechs, attacker decides hits on host-owned robots/banners.
- Robots: host-owned, world snapshots with redundancy/refresh; spawns, deaths and banner destruction as reliable events.
- Late join into a running arena and AI takeover: **out of the slice** (joiners wait for the next round).

### HUD
Aim point + per-weapon LOS indicators, heat gauge with shutdown warning, mech damage diagram, weapon cooldowns, wave
counter, teammate name tags, disabled/revive prompt.

### Lab entries
Mech gait and IK (step length, height, speed, lean), thrusters (thrust, heat, landing threshold), each weapon (heat,
damage, cooldown, projectile speed), aim/LOS visualisation, arena generator (seed, density, heights), robot AI with debug
overlay.

### Tests
Unit: IK solver, ring gravity/up-vector math, heat model, damage/component rules, weapon ballistics, arena generator determinism (checksum per seed).
Net (multi-process, `off` + `coast`): 2-peer mech motion sync error bounds, fire event applied on all machines,
victim-decides hit, robot death + banner destruction replicated, 4-peer arena smoke.

## Out of scope (after the slice)
Multiple decks, ramps, elevators, look-down shafts, rescue vehicles, civilians, orders, objectives beyond waves, weapon
pickups/consumables, more chassis, final art models, audio beyond placeholder SFX, gamepad, late join, environment
destruction beyond banners, meta-progression.

## Milestones
| # | Milestone | Done when |
|---|---|---|
| S1 | Mech controller + IK walk in the lab | Walks/runs/turns on flat, stepped and **curved (ring) ground** with radial up, feet planted, tunable in the lab |
| S2 | Thrusters, falls, hard landing, camera | Can climb onto roofs and hop gaps; hard landing damages legs |
| S3 | Arena generator v0 on a ring arc | Seeded, checksummed curved block arena with radial gravity, ceiling, pillars, park, banners |
| S4 | Aim point, LOS, three weapons, heat | Can destroy banners and dummy targets; overheat shutdown works |
| S5 | Components, disabled, revive, HUD | Damage diagram live; disabled + revive loop works |
| S6 | Turrets + waves | Turrets track and shoot back with telegraphs; 3-wave win/fail |
| S7 | Co-op | 2–4 players under `coast`: motion, fire, hits, robots, banners all replicate; net tests pass |
| S8 | Playtest pass | Friends playtest; telemetry reviewed; tuning in the lab |

S1–S6 run offline-first but follow the net contract from day one (owned fields declared, verbs only, no global random),
so S7 is wiring, not a rewrite.

## Decisions
| # | Question | Decision |
|---|---|---|
| D1 | Arena floor flat or curved? | **Curved ring segment** with radial gravity. Risk: controller, camera and IK must all use a varying up vector from S1; the net position encoding must handle it (arc coordinates or full 3D). |
| D2 | Multiplayer in the slice? | **Yes, as the last milestone** (S7); S1–S6 built to the net contract. |
| D3 | Enemy for the slice | **Turret** (static, simplest AI). |
| D4 | Mech scale | ~8 m tall mech, buildings 10–35 m, ceiling ~40 m *(proposed, tune in the lab)*. |
| D5 | Art | **Placeholders** for S1–S6; real low-poly mech + heads from `art/picks/` swapped in by S8. |
