# Weapons

Status: **built**, synced with the code 2026-11-22. Parent: [game-design.md](game-design.md) §4.3–4.4, §6; slice
milestone S4 in [vertical-slice.md](vertical-slice.md). Net rules: `AGENTS.md`, [../networking.md](../networking.md).
All numbers are first-pass and tunable in the lab (`weapon_range` subject). The truth for every number is
`MechCatalog.WEAPONS` (`scripts/mech/mech_catalog.gd`); this page follows it.

**Build status (2026-11-22):**
| Piece | State |
|---|---|
| Foundation (`scripts/combat/`), `weapon_range` lab | built |
| All nine weapons: `laser`, `autocannon`, `gatling`, `swivel`, `rockets`, `missiles`, `mortar`, `railgun`, `flamer` | built, tested (`tests/test_weapon_<id>.gd`, `tests/test_visual_weapon_<id>.gd`), fire in the lab and through `WeaponRack` in the test drive |
| `WeaponRack` (test drive: keys 1–5 toggle / double-tap solo, LMB fire; RMB is camera zoom) + HUD state API | built |
| Fixed-weapon fire arcs (§4.4) | built, **off by default** (`Combat.FIXED_ARC_ENABLED = false`; the lab option "Fixed arcs" turns it on) |
| City prop hooks (`CityProps.first_hit` / `apply_impulse` / `blast`) | built |
| Ambient-life hooks (`life.sweep` / `life.blast`, [ambient-life.md](ambient-life.md) §6) | built (`tests/test_combat_life.gd`, stub node) |
| Readability check at 50 / 100 m (`tests/test_visual_weapon_distance.gd`) | built |
| Combat across machines (co-op step 3, §5 "As built"): fire records as scheduled effects, shared clock, victim decides, host-owned hits to the host, remote missile guidance, railgun charge telegraph | built (`scripts/combat/combat_net.gd`; `tests/test_combat_net.gd`, `tests/test_net_combat.gd` (2), `tests/test_net_combat_3.gd` (3)); gaps listed in §5 |
| Back-mount equipment ([back-equipment.md](back-equipment.md)): `repair_drone` (active, key 5; scheduled effect over `combat.drone`), `radiator` (+3 /s cooling), `ammo_bin` (+50 % ammo, whole salvos); `CombatTarget.heal` verb | built (`scripts/combat/repair_drone.gd`; `tests/test_back_equipment.gd`, `tests/test_net_drone.gd` (2), `tests/test_visual_weapon_repair_drone.gd`); hangar entry, HUD row and meshes wait on Engine / Mech |
| Enemy fire across machines (W4, §5.1): carried by Engine's `EnemySync` ("fire" items in `enemy.ev`); CombatNet guards it on clients (`CombatWorld.fire_gate`: duplicates dropped, no locally simulated enemy record); victim decides | built (`tests/test_net_enemy_fire.gd` (2)) |
| Unusable slots (rack): a destroyed hardpoint or 0 ammo deselects the slot automatically; its key / a double tap on it can't select it; no fire, no heat (active or passive), off the guided track, no charge glow; usable again (refill / repair) it stays deselected until pressed. HUD: `slots()` `usable` (new), `hold` "DESTROYED" / "EMPTY", `enabled` false | built (`tests/test_weapon_rack.gd` `_unusable`) |
| Shots ignore mech capsules (CombatWorld `shot_ray`: registered targets' bodies excluded from shot / impact rays) | built (`tests/test_combat_capsule.gd`) |

## 1. Direction

1. **Slow, readable fire.** Projectiles are slow enough to watch stream out at medium range (100 m takes 1–2 s). They
   **grow as they travel** and drag **clear low-poly trails**, so a fight is legible from any distance.
2. **Devastating.** Every hit has a big faceted impact. **Lasers and guns shove targets around**; rockets and missiles
   do less damage per hit and trade on splash, salvo size and guidance.
3. **Limits define the weapon.** Heat limits everything. Guns spread at range. Rockets and missiles run out. Missiles
   only guide while you hold a visible laser on the target. The flamer has to get close.
4. **Low poly everywhere.** Projectiles, trails, beams, flames and explosions are faceted flat-shaded meshes in the
   `MechMeshes` palette. No soft particles, no smooth gradients.

## 2. Reference values

| Thing | Value |
|---|---|
| Chassis heat | cap **100**, cooling **6 /s** (`MechCatalog.CHASSIS.strider`); overheat = shutdown |
| Mech HP (for enemy fire) | torso 400, each leg 200, head 100, each weapon 80 |
| Turret (S6) | base 300, barrel 120, heat cap 60, cooling 4 /s |
| Lab dummy | 1000 HP (resets), heat cap 100, cooling 6 /s, mass class selectable |
| Weapon weight budget | 30 t before the overweight penalty |
| Distances | close < 25 m, medium 50–100 m, long 150 m+ |

**Knockback** is a velocity change (Δv, m/s) along the shot direction, multiplied by the target's mass class:
light robot ×1.0, mech ×0.5, heavy/tank ×0.25, static (turret) ×0 (it takes **aim kick** instead: its barrel is thrown
off by Δv × 3°, recovering at 60°/s). Knockback is added to a kinematic velocity that decays with ground friction
(8 m/s² on the ground, none in the air), except for a **hit-slide**: for 0.35 s after each shove friction is only
3 m/s², so a stream of small shoves builds into a real slide instead of being swallowed by the ground, and a target
stops quickly once the hits stop. Accumulating **≥ 6 m/s within 0.5 s staggers** the target (0.6 s: no fire, aim
thrown). **Wall slam:** a knocked target that hits a wall faster than 5 m/s takes 4 damage per m/s over 5.

Measured at 25 m on open flat ground, until the target rests (`tests/test_combat_knockback_feel.gd`, 2026-11-21):

| Weapon (Δv) | light | mech | heavy | static |
|---|---|---|---|---|
| Gatling (1.1), 2 s stream after the 0.6 s spin-up | 24.9 m, staggered 0.43 s after the first round | 7.3 m | 0.5 m | 0 (aim kick) |
| Laser (8.0), one pulse | 5.6 m, staggered | 1.8 m | 0.6 m | 0 |
| Autocannon (3.0), one shell | 1.1 m | 0.4 m | 0.1 m | 0 |
| Autocannon, 2 s burst (5 shells) | 14.5 m, staggered | 2.3 m | 0.5 m | 0 |
| Rockets (0.4), one salvo | 0.1 m | 0.0 m | 0 | 0 |

In the `weapon_range` lab the walls 4 m behind each dummy stop a light one (gatling and laser pin it, often with a slam).

**City props** (`CityProps`, [city-props.md](city-props.md) §5) stop shots like a wall and take the weapon's Δv through
their own verb (topple at a threshold, no damage); splash reaches them as `prop_blast` (rockets 3, mortar 8, else the
weapon's splash knockback). Decided on the shooter's machine, like host-owned targets.

## 3. The weapons

Heat/s is the sustained active heat while holding the trigger. DPS is everything hitting at close range.

Heat/s = active heat ÷ the full cycle (salvo weapons: the salvo plus the reload). DPS = everything hitting at close
range over the same cycle; for explosive weapons it counts direct + splash damage.

| id | Name | Mounts | Kind | Dmg / hit | Rate | Speed | Range (falloff) | Spread | Knockback Δv | Splash | Ammo | Weight | Passive heat | Active heat | Heat/s | DPS | Impact R |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `laser` | Side Laser | side | beam pulse | 55 | 0.8 /s (0.15 s charge, 0.3 s beam, 1.25 s cycle) | instant | 150 m (100% to 80 m → 50% at 150) | none | **8.0** | – | ∞ | 4 | 0.5 | 9 / pulse | 7.2 | 44 | 2.0 m |
| `autocannon` | Autocannon | shoulder, side | shell | 22 | 2.5 /s | 70 m/s | 220 m (100% to 120 → 60%) | 0.4° fixed | **3.0** | 6 dmg / 1.5 m | ∞ | 7 | 0.3 | 1.5 / shot | 3.75 | 55 | 1.6 m |
| `gatling` | Rotary Gatling | side | bullet stream | 6 | 12 /s after 0.6 s spin-up | 85 m/s | 200 m (100% to 60 → 50%) | 1.2° → 4.0° bloom | **1.1** (13 /s sustained) | – | ∞ | 6 | 0.4 | 0.45 / shot | 5.4 | 72 | 1.1 m |
| `swivel` | Swivel Boom | side | twin slugs | 12 | 4 /s (alternating barrels) | 75 m/s | 160 m (100% to 80 → 50%) | 0.8° fixed | **1.6** | – | ∞ | 4 | 0.3 | 1.0 / shot | 4.0 | 48 | 1.0 m |
| `rockets` | Rocket Pod | shoulder | dumb-fire salvo | 26 | 6 rockets 0.1 s apart, 4 s reload (4.6 s cycle) | 45 m/s | 250 m (no falloff) | 3.5° + wobble | 0.4 | 18 dmg / 4 m | **36** (6 salvos) | 6 | 0.2 | 10 / salvo | 2.2 | 57 | 2.5 m |
| `missiles` | Guided Missiles | shoulder | crosshair-guided | 30 | 3 missiles 0.3 s apart, 5 s reload (5.9 s cycle) | 35 → 55 m/s | 350 m (9 s life) | none | 0.6 | 12 dmg / 5 m | **18** (6 salvos) | 7 | 0.4 | 8 / salvo | 1.4 | 21 | 3.0 m |
| `mortar` | Back Mortar | back | arcing shell | 80 | 1 per 3.5 s | ballistic (2.0–4.5 s flight) | 30–250 m (min range!) | 0–3 m scatter with range | 4.0 radial + 3.0 lift | 50 dmg / 8 m | 3 | 9 | 0.4 | 18 / shell | 5.1 | 37 | 6.0 m |
| `railgun` | Coil Railgun | shoulder (one per mech) | charged slug | 200 | 1.0 s charge, 4 s cycle | 200 m/s | 400 m (no falloff) | none | **14.0** | – (pierces 3 targets, −25% each) | ∞ | 14 | 1.0 | 30 / shot (10 on an early release) | 7.5 | 50 | 3.5 m |
| `flamer` | Flamer | side, shoulder | focused flame jet | 1.5 / chunk | 10 chunks /s | 32 m/s | **45 m** (no falloff) | 5° cone | 0 | **+2.2 target heat / chunk** | ∞ | 3 | 1.0 | 0.6 / chunk | 6.0 | 15 (+22 heat/s) | – |

Heat check: any one weapon held down sits near the 6 /s cooling line, so a single gun is nearly sustainable; a full
loadout firing everything (laser + gatling + autocannon + rockets + mortar ≈ 24 /s + ~2 passive) goes from cold to
shutdown in about **5 s**. Thrusters stack on top. Passive heat of a full loadout (≈ 1.5–2.5 /s) eats a quarter to a
third of the cooling.

### 3.1 Side Laser (`laser`)
- **Role:** precise mid-range punch; the knockback weapon. Shoves a light robot off a roof.
- **Fire:** hold to charge 0.15 s (a teal faceted glow grows at the muzzle: `ChargeGlow`), then a 0.3 s beam. The hit
  resolves once at beam start; the beam's start then follows the live muzzle cosmetically.
- **Look:** a fat lance: a teal six-sided prism core inside a paler, wider shell, both faceted, emissive, growing from
  0.35 m at the muzzle to 1.0 m at 150 m; the shell pulses. Impact: teal flash, molten orange shards, a scorch polygon.
- **Limits / counterplay:** hottest sustained weapon for its damage; needs line of sight from the side mount (low,
  easily blocked by cover a shoulder weapon clears); falloff past 80 m; the charge glow telegraphs it.

### 3.2 Autocannon (`autocannon`)
- **Role:** the all-round gun. Slow heavy shells you can watch walk onto a target, each with a real kick.
- **Look:** an amber faceted shell (stretched octahedron, flame MID) with a tapered 4-sided tracer ribbon (flame
  OUTER); a faceted muzzle flash (`MuzzleFlash`, every projectile weapon: 3 hard steps over 0.06 s).
  Impact: 1.6 m burst, debris shards, small ground ring.
- **Limits:** slow shells need lead at range (100 m = 1.4 s); heavy (7 t); slight fixed spread.

### 3.3 Rotary Gatling (`gatling`)
- **Role:** close-range hose. The highest DPS inside 50 m and a constant shove that pins a target against a wall.
- **Fire:** 0.6 s spin-up (barrels visibly spin) before the first round; spin holds 1 s after release.
- **Spread:** cone starts at 1.2° and blooms +0.25° per shot to 4.0°, recovering 3°/s when not firing. At 100 m a
  bloomed cone is ~7 m wide: most rounds miss a mech. Tap-fire stays tight.
- **Look:** small yellow-white darts with short tracer ribbons; a stream reads as a dotted line that fans out.
  Impacts are small (1.1 m) but constant.
- **Limits:** spread at range, damage falloff from 60 m, spin-up delay.

### 3.4 Swivel Boom (`swivel`)
- **Role:** the off-axis gun. The boom tracks the aim point through **±120° yaw, −40°/+60° pitch** of the body's
  facing at up to **240°/s**, so it keeps firing while the mech walks one way and looks another, or at something above
  or below. With fixed arcs on (§4.4, off by default) it is the one direct-fire weapon that reaches past ±25°.
- **As built** (`scripts/combat/weapons/swivel.gd`, `SwivelBoom`): the boom's yaw / pitch are per-mount `OWNER` state
  (`WeaponMount.aim_yaw`, `aim_pitch`, `aim_dir`); each tick it slews toward the aim point, clamped to the arc. Rounds
  leave along the boom's **current** direction (after a snap turn the first rounds lag until it catches up), from the
  left barrel on even shots and the right on odd ones; a round due mid-step takes the boom's direction at its exact
  time, so the fan of a slew does not depend on the frame rate. Aim point outside the arc: the boom stops at the limit
  and the weapon holds (`Combat.OUT_OF_ARC`). Origin, direction and target all go into the fire record, so every machine
  flies the same slug from the record alone. `SwivelBoom.pose_boom` turns the mounted model to match (cosmetic).
- **Look:** twin dark slugs with orange tracers (drawn 0.5 m at launch, ×3.5 by 120 m, 0.3 s trail); the boom visibly
  slews.
- **Limits:** lowest damage of the guns; the slew rate means a snap turn takes a moment to catch up.

### 3.5 Rocket Pod (`rockets`)
- **Role:** area saturation. A ripple of six unguided rockets that blankets a street or a group.
- **Fire:** one press ripples all six tubes, 0.1 s apart. Each rocket gets a seeded 3.5° launch error and a slow
  corkscrew wobble (0.6 m radius), so the salvo lands as a ~10 m pattern at 100 m (9.3 m measured, seed 3).
- **Look:** white rocket with orange nose (the tube cap from the pod mesh), a chain of chunky grey low-poly smoke
  puffs (tumbling icosahedra that shrink and darken) and an amber exhaust cone. Impact: 2.5 m fireball each.
- **Limits:** **36 rockets**, then empty until a pickup; slow (45 m/s) and unguided; low damage per rocket.

### 3.6 Guided Missiles (`missiles`)
- **Role:** long-range precision at the price of your attention.
- **Guidance (user decision, 2026-11-21): the crosshair is the track.** There is no designator button and no lock-on.
  A press launches three missiles (0.3 s apart); each steers toward **the shooter's live aim point** for its whole
  flight. `WeaponRack` writes `world.designators[shooter] = {on, dot}` every step: `dot` = the aim point, `on` = an
  enabled, intact missile slot on a mech that can act.
- **As built** (`scripts/combat/missile.gd`, `Missile extends Rocket`): integrated in fixed 1/60 s steps (kept, so
  `flight_pos(e)` is a lookup and the same designator samples give the same path at any frame rate). While the track is
  on, the heading turns toward the dot by at most **120°/s** and the speed rises from 35 toward **55 m/s** at
  **ACCEL = 20 m/s²**; while it is off (shutdown, slot disabled) the missile flies straight on, and **when the track
  comes back it steers again**. Self-destructs with its explosion after 9 s; a contact detonates like a rocket. A
  missile started late (network) fast-forwards the missed steps with the current designator state (accepted
  divergence: only the deciding machine's path counts).
- **Laser line** (`MissileLaser`): while any of a shooter's missiles from one hardpoint flies and the track is on, a
  red 3-sided faceted line runs from the launcher's live muzzle to the aim point, 9 cm wide at the launcher growing to
  30 cm at 150 m, ending in a faceted red dot (0.35 m radius + 0.003 per m of line). Drawn on every machine, enemies
  included. It **costs no heat** (open, §7).
- **Look:** white body with a red band, red tip, fins and canards, drawn 1.0 m at launch growing ×2.8 by 120 m (visual
  only: the hit shape never changes); an amber exhaust; a thinner, straighter chain of red-tinted puffs than the rocket.
- **Limits / counterplay:** **18 missiles**; the shooter must keep aiming at the target for the whole flight; the laser
  line gives the shooter's position away; a shutdown breaks the track. Open: whether guidance also needs line of sight
  from the launcher to the aim point (§7).
- **Lab:** picking `missiles` in `weapon_range` sets the Designator option to "hold" so they guide out of the box
  (a hand-picked Designator value sticks).

### 3.7 Back Mortar (`mortar`)
- **Role:** indirect fire over buildings; the biggest explosion.
- **Fire:** lobs a shell to the aim point on an arc (flight time 2.0 s + 1 s per 100 m, apex scaled to clear the
  ceiling). No line of sight needed. Scatter grows from 0 m at 30 m to a 3 m radius at 250 m (seeded).
- **Look:** a fat dark shell with an orange band that tumbles slowly and grows a lot on the way down; a thin smoke
  trail. A **ground ring marker** appears at the landing point at launch and closes as the shell falls (everyone sees
  it: that is the telegraph, always ≥ 2 s). Impact: 6 m fireball, a tall faceted column, 9 m ground ring, big shards.
- **Limits:** **30 m minimum range**; long flight makes moving targets escape; ceiling and overhangs block the arc
  (the shell detonates on whatever it meets); 18 heat a shell.

### 3.8 Coil Railgun (`railgun`)
- **Role:** the one big shot. Oversized: takes a shoulder, **one per mech** (`max_per_mech`, enforced by
  `sanitize_loadout`), nearly half the weight budget.
- **Fire:** hold 1.0 s to charge; the charge telegraph (`ChargeGlow`) grows in **4 steps** (`charge_steps`: the coils
  light one by one). The slug leaves the moment the charge completes (exact time at any frame step); the 4 s cycle
  includes the next charge. Releasing early cancels and still costs **10 heat** (`cancel_heat`, paid through
  `WeaponMount.heat_due`). A release while the mech is shut down is not a cancel: no heat (a full charge held into a
  shutdown simply can't fire).
- **Effect** (`RailSlug`, a straight piercing `Projectile`): 200 damage, Δv 14 (sends a light robot flying, staggers a
  mech), passes through up to 3 targets losing 25% each (200 → 150 → 112.5), each target hit once; stops at world
  geometry and city props. An entry burst on every target and an **exit burst** on the far side of each one it pierces.
- **Look:** a long teal spike; a wide faceted twisted ribbon trail (teal band plus a narrower pale band at 90°, a
  zig-zag helix of 6 m a turn) that hangs where the slug passed and narrows to nothing 1.5 s after; a big teal muzzle
  star. The ribbon is built once per slug and aged on the GPU (a shader narrows it), so a visible trail costs nothing
  per frame.
- **Limits:** 30 heat a shot (three shots in a row from cold is a shutdown with anything else firing); the charge is a
  1 s telegraph; passive heat 1.0; weight 14.

### 3.9 Flamer (`flamer`)
- **Role:** close-range heat weapon. Little damage; it **overheats the target**. A mech or turret pushed over its
  heat cap shuts down like a player does. User direction (2026-11-22): still short range, but able to **focus a stream
  of fire onto a target**: a long focused jet, not a wide puff. It stays the shortest-ranged weapon by far (next is the
  laser at 150 m).
- **Fire:** hold for 10 flame chunks a second in a **5° cone**, **45 m** reach, 32 m/s. Each chunk is a fire record
  and an invisible `FlameChunk` (`scripts/combat/flame_stream.gd`): straight flight from the record, a hit radius
  growing from 0.3 m at the muzzle to 1.8 m at full reach (the front of the chunk reaches exactly 45 m), swept on a
  fixed 1/30 s grid; the first target it meets takes +2.2 heat and 1.5 damage, no knockback; walls and props stop it
  (and a target just behind cover is not licked through the wall).
- **Target heat:** ≈ 22 /s on a target taking the full stream: a mech-class target with cooling 6 at 15 m shuts down
  in about **6.6 s** (measured, `tests/test_weapon_flamer.gd`), a turret faster. Above **50% heat** a target shows a few
  burning tongues stuck to it (`BurnFx`, any `CombatTarget` can adopt it).
- **Look: LOW-POLY FLAME, shared with the thrusters.** One `LowPolyFlame.Stream` per firing mount (`FlamerFx`), the
  game's one flame style: rigid faceted tongues (`LowPolyFlame.tongue()`), three bands (OUTER orange, MID amber, CORE
  white-yellow) with `color_jitter` (5 colour variants, bands overlapping a little: mottled, not striped). Tuned as a
  jet: length 45 m, speed 32 m/s, spread = tan 5°, 64 tongues 1.5 m wide, so the stream is dense and continuous along
  its whole length. Each step one `CombatWorld.first_hit` along the aim sets the Stream's `max_length`: tongues
  reaching a wall or the target splat against it (squash wide, shrink in rigid steps) instead of flying through. No
  particles, no alpha gradients: a new shape goes into `LowPolyFlame` so thrusters and flamer stay matched.
- **Limits:** 45 m; no knockback; blocked by any cover. **Shooter heat:** 0.6 a chunk = 6 /s active + 1.0 passive
  ≈ 7 /s against 6 /s cooling, so on its own it barely heats the shooter (open tuning question, §7).

## 4. Shared rules

### 4.1 Fire groups
Test drive (built): keys **1–5** toggle the weapon on side_l, side_r, shoulder_l, shoulder_r, back; pressing the same
key again within 0.3 s solos it. **Left mouse held fires every enabled weapon.** Right mouse is camera zoom.

### 4.2 Projectile visuals: growth and trails
- **Growth is visual only.** The hit shape never changes. Drawn scale is
  `s(d) = s0 × lerp(1, g, smoothstep(0, d_full, d))` with `d` = distance travelled (`Combat.growth_scale`). On top, a
  projectile is never drawn smaller than **6 px** on the viewer's screen (`Combat.MIN_PIXELS`).
- Per weapon (catalog `size` = s0 in m, `growth` = g, `growth_full` = d_full, `trail` in s), retuned 2026-11-22 after
  the 50 / 100 m readability shots (`tests/test_visual_weapon_distance.gd`):

| Weapon | size s0 | growth g | d_full | trail | drawn at 100 m |
|---|---|---|---|---|---|
| autocannon | 0.6 | 3.5 | 120 m | 0.45 s | 2.0 m |
| gatling | 0.5 | 3.5 | 120 m | 0.2 s | 1.7 m |
| swivel | 0.5 | 3.5 | 120 m | 0.3 s | 1.7 m |
| rockets | 0.9 | 2.0 | 120 m | 1.2 s (puffs) | 1.7 m |
| missiles | 1.0 | 2.8 | 120 m | 1.2 s (puffs) | 2.7 m |
| mortar | 0.9 | 3.0 | 120 m | 0.5 s | peaks on descent |
| railgun | 1.0 | 1.5 | 120 m | 1.5 s (ribbon) | 1.5 m |
| laser (beam width) | 0.35 | 2.86 | 150 m | – | – |
| flamer (tongues) | 0.25 | 6.0 | 45 m | – | – |

- **Trails** are a ribbon of flat quads (4-sided cross-section, no smoothing), unlit, one segment per 0.04 s of
  flight, width tied to the projectile's drawn scale, tapering to a point. Rockets and missiles leave puff chains
  instead (one low-poly puff per 0.06 s, 1.2 s life); the railgun has its own twisted ribbon (§3.8). All trail colours
  come from the palette (AMBER, TEAL, ORANGE, WHITE, GREY).

### 4.3 Impacts (cosmetic)
One `ImpactFx` builder scaled by radius **R**: a faceted flash sphere (0 → R in 0.08 s, gone by 0.3 s), 5–12 fireball
chunks (flame ramp, drift up), debris shards in the hit surface's colour flung along the normal with gravity, a flat
ground ring out to 1.5 R when within R of the ground, a scorch polygon (10 s), and camera shake scaled by R and
distance. Explosive weapons (rockets, missiles, mortar) add a second, slower chunk wave. Uses its own looks RNG.

### 4.4 Aim, arcs and line of sight
- Every weapon aims at the **true aim point** (convergence), from its own hardpoint.
- **Direct-fire weapons pivot (built).** Laser, autocannon, gatling, rockets, missiles, railgun and flamer turn at
  their mount point toward the aim point and fire **straight out of the barrel**: the shot leaves pivot + barrel ×
  `muzzle` along the barrel's current direction (plus the weapon's seeded spread). Slew `slew` °/s (catalog: 180 for
  most, railgun 90, rocket and missile pods 120), pivot range **±30° yaw, −50°/+45° pitch** of the body
  (`Combat.PIVOT_*`, overridable per weapon with `yaw_arc` / `pitch_down` / `pitch_up`). While a barrel slews its
  shots go where it points; settled, straight at the aim point, so looking down at a close target pitches the guns
  down onto it. Past the range the barrel parks at its limit and fires along it (it visibly can't reach).
  `WeaponPose` turns each `Weapon_<id>` model to match, so muzzle flash, charge glow, beam, flame and missile laser
  all start at the turned muzzle; `WeaponRack.slots()[i].on_target` says whether a barrel is on the aim yet. The
  mortar does not pivot; the swivel keeps its own ±120° boom (§3.4). `aim_yaw` / `aim_pitch` are OWNER state:
  remote machines pose the models from them once mech snapshots exist.
- **Fixed arcs (built, off by default).** With `Combat.FIXED_ARC_ENABLED` on (the lab option "Fixed arcs"), a
  pivoting weapon fires only while the aim point is inside its **pivot range** (one set of numbers: ±30° yaw,
  −50°/+45° pitch, measured from the pivot in the body's frame, `WeaponMount.body_basis`); the swivel boom always has
  its own wide arc; the mortar and the missiles only need the range. Out of arc = that weapon holds fire
  (`hold_reason` = `Combat.OUT_OF_ARC`), its HUD indicator greys. Off (the default), it fires along its parked
  barrel (open question, §7).
- Straight-flight weapons that are **blocked between hardpoint and aim point still fire** and hit the obstacle; the
  indicator turns red first. Nothing is refused silently.

### 4.5 Spread and randomness
Every random number in a shot (spread, rocket wobble, mortar scatter, flame chunk jitter) comes from a generator seeded
with `hash(mission_seed, shooter_id, hardpoint, shot_index)`, so every machine draws the same shot. Looks (impact
debris) use a separate looks generator. No global `randf()`.

### 4.6 Heat, ammo, damage states
- Active heat is paid by the shooter when the shot leaves. A weapon cannot fire during shutdown.
- Ammo is per mounted weapon; empty = dry click and a HUD flag. Pickups refill it (after the slice).
- Damaged weapon (below 50% HP): +50% active heat and +30% cycle time. Destroyed: gone; an ammo weapon destroyed with
  rounds left cooks off as one of its own impacts on the owner (after the slice).
- **Friendly fire:** no damage and no heat to teammates; knockback at 25%.

## 5. Networking

Shapes from the net contract (rule 6):

| Thing | Shape | Owner | Notes |
|---|---|---|---|
| Shells, bullets, slugs, rockets, mortar shell, laser pulse, railgun slug | **scheduled effect** | – | one `fire` event `{shooter, hardpoint, weapon, origin, dir or target, t, shot_index}`; every machine simulates the flight from the params + shared clock |
| Gatling / flamer stream | scheduled effect, batched | – | shots of the same weapon within a 33 ms tick share one event |
| Missile | scheduled effect + **owner-streamed input** | – | launch is a `fire` event; steering reads the shooter's live aim point |
| Missile track (on/off) and the aim point | `OWNER` fields of the shooter's mech | shooter | the aim point is already in the mech snapshot; the track flag rides next to it |
| Heat, HP, ammo, weapon cooldowns, bloom, spin | `OWNER` / `PRIVATE` fields of the mech | each player | never written by anyone else |
| Dummy / turret HP, heat, velocity | host-owned actor | host | changed only through verbs |
| Impacts, trails, muzzle flashes, flame chunks' look | cosmetic | – | local, looks RNG |

- **Timing.** The shooter's machine shows its shot at once at time `T` (its shared-clock time). Other machines start
  the effect when the event arrives and **fast-forward it by `now − T`**; slow projectiles make that a few metres.
  Enemy fire (host-owned) is sent with its telegraph (≥ 0.3 s) ahead of `T`, so it is never late anywhere.
- **Hits** go through one module, `Combat`. Each machine simulates every projectile but only **decides** hits on
  targets it has authority over: its own mech (victim decides, with the component hit), and, on the shooter's machine,
  host-owned targets (attacker decides, the result is sent to the host, which applies it). A projectile that another
  machine decided has hit is removed there by the hit event; otherwise it flies on to its local visual impact.
- **Verbs** (applied only by the target's owner): `apply_damage(amount, component, src)`, `apply_impulse(dv, src)`,
  `apply_heat(amount, src)`. A hit carries all three in one `Hit` record.
- **Missile divergence.** Machines see the shooter's aim point through interpolation, so a missile's path differs by a
  little between machines. That is fine: only the deciding machine's path counts, and its detonation is an event.
- **Determinism test:** the same `fire` params and seed give the same trajectory, spread and impact point on any
  machine and at any frame rate (flight is integrated from elapsed time, not per-frame steps, except guided missiles
  which use fixed 1/60 s steps).
- **Ambient life** ([ambient-life.md](ambient-life.md) §6). When a node in group `ambient_life` exists (looked up lazily
  by `CombatWorld.life()`, at most every 0.5 s of clock while missing, cached until freed), every shot path is reported
  through `CombatWorld.life_sweep(record, a, b, r)` -> `life.sweep(a, b, r, src)`: each chord of `Projectile._sweep`
  (all projectiles: shells, rockets, missiles, mortar shells, rail slug, enemy shots; r = `Combat.PROJECTILE_RADIUS`,
  ending at the stopping hit, so the calls chain muzzle to impact), the laser's ray once per pulse (muzzle to beam end,
  r = `RAY_RADIUS`), each flame chunk's chord (r = its far-end hit radius, clipped where the chunk is spent).
  `CombatWorld.splash` calls `life.blast(point, splash_radius, src)`. Only the machine that `decides_shot` calls them
  (as for props); `src` = the record's `peer`, or -1 when the record is enemy fire (`"enemy": true` or team `"enemy"`).
  The returned kill counts are ignored: civilians never stop or change a shot. No node, no calls.

### 5.1 As built (co-op step 3, 2026-11-22)
`CombatNet` (`scripts/combat/combat_net.gd`, child "CombatNet" of `TestDriveCombat` in a crew mission only; solo, the
lab and single-process tests are unchanged). It sends nothing itself: it uses Session's existing reliable events
(`send_event` / `event_received`); no change in `scripts/net/`.
- **Clock.** In a crew mission `CombatWorld.set_clock(CombatNet.session_clock)`: `advance` sets `now` from
  `Session.host_time()` (never backwards; while the session is gone it counts deltas again). Records' `t` are the same
  moment everywhere. Without a clock (`clock` invalid, the default) `now` counts deltas exactly as before.
- **Fire records.** Every record the local rack fires (`peer` = local, `shooter` = `player<peer>`) is queued and sent as
  `combat.fire {r: [[hardpoint, weapon, origin, dir, target, t, shot_index, spread], ...]}` at most 30 times a second
  (the first after a pause at once). A client sends to the host, which relays it with `{o: origin peer}` to every other
  client (clients only talk to the host). Receivers take `shooter` / `peer` from the sender, validate types / finite
  numbers / a player weapon id, drop a repeated shot key, and call `CombatWorld.fire`: a late record fast-forwards.
  Records hold nothing else (every weapon checked by `test_combat_net`: the swivel's and pivots' `shape_record` only
  rewrite origin / dir / target), so spread, rocket wobble, mortar scatter and flame jitter reproduce from
  `Combat.shot_rng`. The design table's "batched within a 33 ms tick" is this 30 Hz flush.
- **Per-weapon event rate** (records/s, trigger held): laser 0.8 (one per pulse), autocannon 2.5, gatling 12 (the 0.6 s
  spin-up is in the first record's `t`; there is no barrel-spin visual to send), swivel 4, rockets 6 in 0.5 s then a 4 s
  reload, missiles 3 in 0.6 s then 5 s, mortar 0.29, railgun 0.25 plus one `combat.charge` per charge and per cancel,
  flamer 10 (one per chunk; each remote chunk keeps that mount's `FlamerFx` lit). Events per shooter: at most 30/s.
- **Who decides** (unchanged `CombatWorld.decides`, now reachable): a mech hit is decided **only by its owner**, from
  the replicated shot simulated against its own mech (the victim's view; A and C show the impact on the puppet and
  build no Hit), so no hit message crosses for mechs and double application is impossible (one simulation per shot
  per machine, duplicate shot keys dropped). Host-owned targets (`owner_peer` 0: enemies, dummies) are decided by the
  shooter's machine; a client's `remote_hit` goes to the host as `combat.hit {id, dmg, imp, heat, pt, n, comp, w, sh,
  shot}`; the host checks `sh` is the sender, drops a repeat of (shot, target) and applies it to the target it owns by
  id. Props and ambient life keep their own host paths (`prop.req`, `life.req`).
- **The deck stack** (integration W3, 2026-11-22). In the mission city (`CityStack`, one `CityProps` per deck, prop ids
  per deck) `TestDriveCombat.rebuild_encounters` sets `world.stack = td.stack` (null in district mode; a scene with a
  node in group `city_stack` and no injection has it adopted by the props scan). `first_hit` asks the props of every
  deck the swept sphere can touch (`CombatWorld.deck_span(a, b, r)`: `stack.deck_at` of the segment point nearest the
  shared axis, moved r toward it, and of the farther end, moved r away; one deck for almost every chord, two when a shot
  crosses a ceiling opening), and a prop hit carries `"prop_node"` (that deck's `CityProps`) so `hit_prop` calls the
  right deck's `apply_impulse`; `splash` calls `blast` on every deck within the splash radius of the point. The verbs'
  signatures are unchanged: each `CityProps` puts its own `deck` on its `prop.req` / `prop.ev` / `prop.sync` events.
  `ring_at(p)` (= `stack.ring_at`, the deck under p, for the no-physics `surface_below` height) and `up_at(p)`
  (= `stack.ring()`, the shared axis, for impact alignment) replace `ring` when there is a stack. Ambient life is one
  `AmbientLife` for the whole stack that routes per deck itself, so `life()` is unchanged. Per call: no allocation,
  no group scan (deck props are read from `stack.decks[k].props`, right after a rebuild). No stack: the single
  `city_props` node and `ring`, exactly as before. Tested by `test_combat_props` (fake two-deck stack + a real one).
- **Missiles.** Before each `advance`, each puppet's track is mirrored into `world.designators["player<peer>"]` from its
  owner's newest snapshot (aim point, designator flag), so a remote missile steers toward the shooter's streamed aim
  point and the laser line shows. Measured (`test_net_combat`, aim sweeping 87 m sideways): remote path within 1.5 m of
  the shooter's at 3 s (link off), 2.2 m (coast). The shooter's own behaviour is unchanged.
- **Live muzzles.** Each puppet's hardpoints are registered as CombatWorld muzzles (its model's `HP_<id>` node), so
  remote beams, flamer streams, missile lines and charge glows start at the puppet's weapons.
- **Railgun charge** (`stats.charge >= 0.3 s`): `combat.charge {hp, t, on}` at charge start and on a cancel; receivers draw
  a stepped `ChargeGlow` from `t` until the shot's record or the cancel arrives. The laser's 0.15 s charge sends nothing.
- **Enemy fire** (W4, 2026-11-22). The host's `EnemySync` (Engine, `scripts/game/enemy_sync.gd`) sends each enemy fire
  record (peer 1, `enemy` true, team `enemy`) as a "fire" item of its ordered per-frame `enemy.ev` batch; clients take it
  from the host only and fire it with `CombatWorld.fire` (fast-forwarded). CombatNet does NOT send enemy records (that
  would double them). On a client CombatNet sets `CombatWorld.fire_gate`: a repeated enemy shot key is dropped and an
  enemy record fired while the world steps the targets this machine owns (a locally simulated enemy; enemies tick only
  where owned, so never on a client) is refused. Who is hurt is plain `CombatWorld`: peer 1 = the victim decides about
  its own mech (the host builds no Hit on a client's puppet), the host decides props / ambient life (`decides_shot`).
  Remote look: enemy weapons are all projectiles, so muzzle flash and flight start at the record's origin (the host's
  `muzzle_world`). Rate: about 0.6 records/s per bolter turret, 1.1 per pulse skirmisher, 0.25 siege, 0.15 mortar while
  firing (bursts + cooldown + telegraph); with every enemy of an encounter firing, under ~10 records/s, all inside the
  host's one `enemy.ev` per physics frame.
- **Mech capsules.** Shots meet targets only through their hit spheres: `CombatWorld.shot_ray` (first_hit, ground_below,
  surface_below) excludes every registered target's physics body (a PlayerTarget's MechController capsule, local or
  puppet; enemies have no bodies) from world-geometry rays, with one reused query object.
- **Not covered yet:** player shots still skip teammates entirely (same team, friendly fire open §7.3); a remote shot starts
  at the shooter's true muzzle while its puppet is drawn ~100-200 ms behind; no muzzle flash for a remote record
  arriving later than `MuzzleFlash.LIFE`; remote weapon models are not turned (`aim_yaw` / `aim_pitch` not streamed);
  mech HP / components are not streamed (crew panel hp stays 1); a missile's detonation is not an event (each machine
  shows its own copy's); the laser's charge glow is not shown remotely.

## 6. Code map

- `scripts/combat/combat.gd` `Combat`: shared rule numbers, the fire record, shot RNG, spread, growth, falloff, mass
  classes, fixed arcs. `combat_world.gd` `CombatWorld`: the combat clock, targets, effects, `fire`, `first_hit`,
  `resolve_hit` / `deliver`, splash, props (per deck with a `stack`: `deck_props`, `props_at`, `deck_span`), the ring
  per point (`ring_at`, `up_at`), impacts, designators, muzzles. `combat_target.gd` `CombatTarget` (verbs,
  hit spheres, mass class), `hit.gd` `Hit`, `heat.gd` `Heat`, `knockback.gd` (kinematic Δv, hit-slide, stagger, wall
  slam), `combat_effect.gd` (base of everything on the clock).
- Firing: `weapon_mount.gd` `WeaponMount` (one mounted weapon's owner state; trigger → fire records),
  `weapon_behaviour.gd` + `weapons/<id>.gd` (one behaviour per weapon), `weapon_registry.gd` (id → behaviour),
  `weapon_rack.gd` `WeaponRack` (a mech's weapons in play, keys, HUD API), `test_drive_combat.gd`.
- Shots: `projectile.gd` (straight / curved flight, sweep, growth, trail), `rocket.gd`, `missile.gd`,
  `missile_laser.gd`, `weapons/mortar_shell.gd`, `rail_slug.gd`, `beam.gd` (laser, laser line), `flame_stream.gd`
  `FlameChunk`, `flamer_fx.gd`, `burn_fx.gd`.
- Looks: `impact_fx.gd`, `muzzle_flash.gd`, `charge_glow.gd`, `combat_meshes.gd`; flames from
  `scripts/fx/low_poly_flame.gd`.
- Targets in the lab: `target_dummy.gd`; the player: `player_target.gd`. Lab subject: `weapon_range_lab.gd`.
- Crew missions: `combat_net.gd` `CombatNet` (fire records / hits / charges across machines, §5.1).
- Data: `MechCatalog.WEAPONS` / `WEAPON_ORDER` / `WEAPON_STATS`; `sanitize_loadout` honours `max_per_mech`.
- Tests: `tests/test_combat*.gd`, `tests/test_weapon_<id>.gd`, `tests/test_weapon_rack.gd`, `tests/test_flame_stream.gd`,
  visual `tests/test_visual_weapon_*.gd` (one per weapon, the range, and the 50 / 100 m readability set).

## 7. Open questions

1. **Fixed-weapon arcs** (±25°, built but off): turn them on, or let every weapon reach any aim point (and then what is
   the swivel boom for)?
2. **Stagger and wall slam** from knockback (both built): in or out?
3. **Friendly fire:** no damage and no heat to teammates, 25% knockback: OK? (Not built yet.)
4. **Blocked line of sight:** fire into the obstacle (built) or refuse to fire?
5. **Railgun one per mech:** OK?
6. **Flamer ground fire** (burning patches that keep heating whoever stands in them): later, or never?
7. **Projectile speeds:** is 100 m in 1.2–2.2 s the right "slow"? Speeds are the first thing to tune in the lab.
8. **Missile guidance and line of sight:** does guidance need line of sight from the launcher to the aim point?
9. **Laser line heat:** should the missiles' laser line cost heat (it costs none)?
10. **Flamer shooter heat:** 6 /s active + 1.0 passive ≈ the 6 /s cooling, so it barely heats the shooter. Raise it?
11. **Light targets slide very far** under gatling / autocannon bursts (gatling 2 s: ~25 m; autocannon 2 s: ~15 m,
    §2): keep that, or cap the hit-slide?
