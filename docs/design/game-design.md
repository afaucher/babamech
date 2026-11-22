# babamech — Game Design Document

*Codename* **babamech**, after Baba Yaga's chicken-legged hut. Living document; last updated 2026-11-21.
The running log of individual decisions is [decisions.md](decisions.md). Networking details: [../networking.md](../networking.md).

---

## 1. Overview

**Pitch.** Up to four friends pilot chicken-legged combat mechs through the decks of a giant rotating space habitat, freeing a civilian population that alien invaders have quietly ruled for years.

| | |
|---|---|
| Genre | Co-op third-person mech action |
| Players | 1–4, online co-op (Steam), small friend groups |
| Session | One mission ≈ 30 minutes |
| Platform | Windows; keyboard + mouse (gamepad later) |
| Engine | Godot 4.7, GDScript |
| Look | Low poly, flat-shaded, highly stylized |

**Pillars**
1. **Tactical loadouts.** What you bolt onto your hardpoints, and what you scavenge mid-mission, decides how you fight. Heat is the budget.
2. **A vertical habitat.** Dense city decks stacked in concentric rings: rooftops, ledges and shafts give sightlines and shortcuts between layers.
3. **Rescue, not slaughter.** The goal is getting civilians out; the invaders run society, and you break their grip.
4. **Lag-proof co-op.** Smooth play between friends on ordinary connections, no anti-cheat overhead.

---

## 2. Setting

The habitat is a **rotating cylinder**. Decks are **concentric rings**; artificial gravity points **outward**, so every deck's floor is the inside of a ring and its ceiling is the underside of the deck above. Gravity is the same on every deck (for now).

**The invaders** are **aliens who control robots**. They took over the habitat's **civil defense forces** (tanks, mechs, infantry) and have ruled for a long time. Society still runs; the aliens are not burning it down. Occupation shows as **control**: checkpoints and cordons, surveillance pylons and drones, alien banners and signage, alien machinery grafted onto civic infrastructure, curfew-quiet streets, civil-defense units repainted in the invaders' colours. Robots are built first; the aliens' own look is an open art pass (§13).

**The players** are a rescue force of mechs, each piloted by an oversized cartoon character (chicken, pickle, corn, dog).

---

## 3. World structure

### 3.1 Decks and zones
Each deck is a dense urban habitat laid out like a **planned city in space**: key areas joined by **roads with traffic** and **paths**, separated by recreation areas. Zone types:

| Zone | Character | Pillars (deck supports) |
|---|---|---|
| Urban | Buildings of varied height, tight streets, constricted sightlines, jumpable rooftops | Tallest buildings merge into the ceiling (not standable) |
| Park | Lawns, trees, ponds, paths; long sightlines | Slim tree-like columns |
| Industrial | Factories, tanks, pipes, gantries, cranes | Steel truss pillars |
| Open air | Large openings in the floor: look down onto the deck below | — |
| Transit | Rail lines, roads, stations, ramps between decks | Lift shafts |

Gameplay rhythm alternates tight urban streets (ambush, flanking), open parks and shafts (long range, indirect fire) and transit corridors (lanes, chokepoints).

### 3.2 Habitat features
- **Low ceiling.** The next deck up caps building height; the tallest buildings join the ceiling as structural pillars. Non-urban pillars are slimmer or serve other uses.
- **Curved horizon.** Looking along the spin direction, the floor rises in the distance toward the ceiling (the Cluckipede look). Across the spin axis the floor is level.
- **Look-down ledges.** Openings in the floor (open-air shafts, atrium edges, ramp cuts) let you see and fight the deck below. Mechs can drop through (see thrusters, §5.4) — a fast, one-way shortcut.
- **Deck connections.** **Elevators** (in-world freight lifts, often inside pillars; no loading screen) and **ramps** (continuous descent over some distance). Vehicles and civilians need these; mechs can also drop.

### 3.3 Views
- **Gameplay:** full 3D, third person, over the shoulder.
- **2D cross-section:** the rings seen as a slice, used for level design and the in-game map, showing decks and where they connect.

### 3.4 Missions
A mission attacks one **connected section** of the station, possibly spanning **several decks**, and lasts about **30 minutes**. The whole section is loaded as **one scene** (needed for ramps and look-down ledges). The crew may split across decks freely.

### 3.5 Procedural generation
**All layouts are procedural**, built from a seed. Every machine generates the same section from the host's seed and verifies it with a checksum, so a whole section costs one number on the wire. Generator passes:
1. Section cross-section: N decks, connection points (elevators, ramps, shafts) with guaranteed routes.
2. Per-deck district plan mixing the five zones, with a road/path network linking key areas.
3. Blocks: buildings of varied height capped by the ceiling; roof spacing tuned for mech jumps; pillars.
4. Gameplay passes: objectives, civilians, enemy spawns, vehicle routes, sightline and cover checks, occupation dressing (banners, pylons, checkpoints).

### 3.6 Destructibility
- **Alien banners are destructible** (and other occupation props as they are designed): tearing down the invaders' symbols is part of liberating an area.
- Broader environment destruction (buildings, cover) is expected but **deferred past the MVP**; it will need a destroyed-pieces list for the checksum and late join.

---

## 4. Mechs

### 4.1 Chassis (locked look)
- **Bipedal**, fully articulated. **No arms.**
- **Legs:** mechanical but shaped like a chicken's — armored thigh, **reverse-jointed knee**, long shin with pistons, foot with **three forward toes and a rear spur**.
- **Torso:** rounded armored body, white and safety-orange civil-defense livery with amber lights.
- **Nose cockpit:** a nose juts from the front of the torso with a hatch; a tall armored **back plate** stands behind the pilot.
- **Pilot:** sits **inside** the mech; **only the head and neck stick out** of the hatch.
- Start with **one chassis**. Body/legs as separate choices (mix and match) is undecided.

Reference: `art/picks/mech_base.png`, `art/picks/mech_loadout_full.png`.

### 4.2 Pilots (heads)
Chicken, pickle, corn, dog. **True low poly, ~150 faces**, flat colour per face, no texture. Attitude **stern** (heavy angled brow, narrowed eyes, mouth closed), from the Cluckipede concept art. **Cosmetic only** for now. The head is a real, unarmored part of the mech for damage purposes (§6.3).

Reference: `art/picks/head_*.png`.

### 4.3 Hardpoints
**Five hardpoints:**
| Slot | Count | Position | Typical weapons |
|---|---|---|---|
| Shoulder | 2 | Raised above the head | Autocannons, missile boxes, lasers, railgun |
| Torso side | 2 | Hip height (covers the "arm weapon" role) | Gatlings, swivel gun booms, small turrets |
| Back | 1 | Behind the back plate | Mortar / indirect fire |

Each weapon is its own swappable low-poly model. Asymmetric loadouts are allowed. Reference: `art/renders/mech_r8/grid_mech_r8.png`.

### 4.4 Weapons
- Every weapon has **weight**, **passive heat** (while mounted) and **active heat** (per use). **Weight is a penalty** (movement, thrust).
- Weapons are also **consumables collected during the mission** (new weapons, ammo).
- Examples: arm-role lasers, shoulder rocket pods, back mortar that arcs onto targets from above.
- **Straight-flight weapons need true line of sight from their own hardpoint** to the aim point; a shoulder pod can be blocked when a side gun is not. Arcing weapons are exempt.

### 4.5 Customization flow
- **Main settings (persistent identity):** player name, head. More cosmetics later.
- **Before each mission:** choose mech (body + legs) and loadout.
- **Main menu:** the player's current mech and look rendered live beside the menu options.
- Inspiration: Bridge to Friendship's customization/accessory screen.

---

## 5. Movement and control

### 5.1 Walking
Procedural **IK** plants feet on fixed ground positions at any speed and through speed changes; joints follow the legs' real motion. Animation needs: idle, walk/run at varied speeds, turn, crouch before takeoff, tuck in flight, landing absorb scaled to impact speed.

### 5.2 Aiming
Over-the-shoulder camera. A **true aim point** is drawn on whatever surface is targeted, with **incremental indicators** along the path from each weapon to that point.

### 5.3 Controls (keyboard + mouse, initial)
Mouse aims; WASD moves; **Space fires thrusters** (jump/hover/brake); weapon group fire on mouse buttons/keys; interact key for vehicles and pickups; order keys or radial menu (§8). Exact bindings TBD.

### 5.4 Thrusters, jumping and falling
- **Space fires thrusters at any time** — that is how mechs jump onto roofs, hop between them and slow a fall.
- **Automatic emergency burn** fires before touchdown on long falls; it is only an emergency system, so long drops can still end in a **hard landing**.
- **Hard landings damage the legs.**
- Mechs **survive** dropping to the deck below via the emergency burn plus manual burns.
- Thrusters generate **heat** (no separate fuel). Hold vs. tap behavior TBD.

---

## 6. Combat systems

### 6.1 Heat (primary limit)
Weapons (active and passive) and thrusters generate heat. **Overheat → hard shutdown → cooldown → reboot.** Venting options (coolant pickups, water) TBD.

### 6.2 Component damage
- Each part has its own health: head, torso sections, each leg, each weapon/hardpoint.
- HUD shows a **diagram of your mech** with each part's state, including the head.
- **Damaged weapons:** more heat, longer reload, or ammo lost when hit.
- **Destroyed parts are non-functional**, and some disable the mech:
  - Lost leg → cannot walk (disabled).
  - Head destroyed → disabled.
  - Weapon / side-mount destroyed → keep fighting without it.

### 6.3 Disabled, revival, failure
- A disabled mech can be **revived by pickups or by teammates**.
- The **mission fails when all players are disabled**.
- No AI mechs fill empty seats (maybe later). Solo is allowed but harder.

---

## 7. Enemies

- **Roster:** hijacked civil-defense **tanks, mechs and infantry**, robots under alien control. Roster details and sizes TBD; robots built first.
- **Coordinated AI** (host-owned), working as squads:
  - Shared **last-known-position** board, fed only by actual sightings.
  - Roles within a squad: suppress, flank, indirect fire, spotter.
  - **Attack slots** so enemies take turns rather than all firing at once.
  - Spotting and calls for help spread through the AI's own network with a delay, so players can cut communications (spotters, relays) as a counter.
- **Telegraphs ≥ 0.3 s** on attacks (lesson from cast: shorter wind-ups feel unfair under lag).
- Enemies **target evac trucks**, not transport pods or supply trucks (§8).
- Alien look and colour scheme: open art pass (§13).

---

## 8. Rescue and vehicles

- Players **commandeer rescue vehicles** that **follow at a distance** once ordered and **load civilians**.
- Vehicle types: **civilian transport pods**, **supply trucks** (not targeted by enemies), **evac trucks** (targeted — escort pressure).
- **Orders** reuse cast's order pipeline without voice: an order is `(who, order, issuer, aim point)` — follow, wait/hold, go to point, load/unload. The issuer's machine requests; the host applies once and broadcasts (markers, barks). Commandeering is a host-granted request (first request wins).
- Vehicles move between decks only via ramps and freight elevators.
- **Mission objectives come after combat is proven.** Meta-progression (campaign, unlocks, station map) is deferred.

---

## 9. Multiplayer

Inherited from **cast** (`C:\Users\alexa\.gemini\antigravity\scratch\cast`); see [../networking.md](../networking.md).

- **Lobby:** Steam. **Play/Host** creates a lobby (solo = lobby with nobody else). **Join** takes the first open lobby with a matching game key and build. Overlay invites. ENet for local dev/tests. Max **4** players. No host migration.
- **Authority:** each machine owns its own mech (position, HP, components, heat, loadout); the host owns enemies, vehicles, civilians, pickups, banners and objectives. Your own mech is never corrected; remote entities are interpolated (adaptive 100–400 ms).
- **Hits:** the victim's machine decides, with the component id; dodges on your screen are real.
- **Weapons as scheduled events:** "fired at time T from hardpoint P toward aim point A", applied 0.2 s later on every machine; late arrivals catch up.
- **Wire:** one reliable event RPC; 30 Hz unreliable snapshots under 1200 B with 3-tick redundancy; seed + checksum for the world.
- **Join handshake** carries name, head and chassis/loadout so everyone sees each other's mechs.
- **No anti-cheat**; clients are trusted.
- Adaptations vs. cast: 4-player crew; wider position ranges or per-deck coordinates; aim point + hardpoint pose sync; kinematic mech controller (no rigid bodies).
- **Tooling:** link simulator presets, per-second telemetry CSVs, headless multi-process net tests, multi-window local launcher, log packer, net contract lint.

---

## 10. UI and menus

- **Main menu:** Play/Host, Join, Settings, Lab, Quit; live 3D mech preview beside the options.
- **Settings:** player name, head; video/audio.
- **Pre-mission (hangar):** chassis + loadout across the five hardpoints, showing weight and heat.
- **HUD:** aim point with per-weapon indicators, heat gauge, component damage diagram, ammo, order markers, minimap/cross-section.

---

## 11. Art direction

**Locked**
- **Mechs:** §4.1–4.3. Low poly, white/safety-orange civil-defense livery.
- **Pilots:** ~150-face true low poly, stern, Cluckipede attitude.
- **Environments:** chunky low poly, flat colour per face, **day** lighting (bright artificial daylight from ceiling strips; cream, terracotta, sage, sky blue; soft distance haze), occupation shown as control, not damage. References: `art/renders/env_r3/grid_env_r3.png`, `art/renders/env_r1/day_occupied_s909.png`.

**Process:** every art decision goes through a **3x3 grid** (9 options or 2 parameters × 3 values) rendered on the local ComfyUI. Prompt scripts live in `art/tools/`, renders in `art/renders/<round>/` with a `SEEDS.md`, locked picks in `art/picks/`.

**Open**
- **Aliens and invader robots:** colour scheme and look (current placeholder in renders: red and black, red eye-lenses).
- Head scale on the chassis.
- Ring-habitat geometry: the image model struggles with it; settle with an in-engine test scene.
- Audio and music: not started.

---

## 12. Tooling

- **Lab view:** every scene with tunable parameters (model: flap's lab; also cast's move lab/gym). Covers IK and gait, mech parts and damage states, weapons (heat, reload, line of sight, aim markers), the generator (seed, decks, zones, cross-section), art comparisons, enemy AI with debug overlays.
- `run.ps1` (incl. multi-window crew + link sim), `test_runner.ps1`, `build.ps1`, `lab.ps1`.
- Art: `art/tools/*.ps1` prompt scripts, `art/tools/make_grid.py` grid assembler.

---

## 13. Open questions

| # | Question |
|---|---|
| 1 | Alien and robot look and colour scheme (art pass next) |
| 2 | Enemy roster: unit types, sizes, roles; boss/command units |
| 3 | Body and legs as separate choices? Stats per chassis? |
| 4 | Heat venting (coolant, water)? |
| 5 | Thruster hold vs. tap; hard-landing thresholds |
| 6 | Mission objectives and win condition (after combat works) |
| 7 | Vehicle details: capacity, speed, armor; who can order |
| 8 | Which occupation props besides banners are destructible |
| 9 | Head scale on the chassis |
| 10 | Audio direction |
| 11 | Meta-progression |

---

## 14. MVP scope (proposed)

1. Scaffold: Godot project, Steam/ENet session, menus, settings, hangar, lab *(in progress)*.
2. One mech: IK walk, thrusters, heat, five hardpoints with 3–4 weapons, component damage, aim point.
3. One procedural section: two decks, urban + park + transit, one ramp, one elevator, one shaft; destructible banners.
4. One robot squad type with coordinated AI.
5. 4-player co-op over Steam with the inherited net model and tooling.
6. Then: rescue vehicles and civilians, mission objectives.

---

## 15. References

| What | Where |
|---|---|
| cast (netcode, tooling, orders, elevators) | `C:\Users\alexa\.gemini\antigravity\scratch\cast` |
| flap (lab view, Godot 4.7 setup) | `C:\Users\alexa\.gemini\antigravity\scratch\flap` |
| Bridge to Friendship (customization screen) | `C:\Users\alexa\.gemini\antigravity\scratch\bridge-to-friendship` |
| Cluckipede (ring look, curved horizon, chicken attitude) | https://github.com/afaucher/Cluckipede, `art/reference/cluckipede/` |
