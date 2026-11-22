# babamech — design decisions log

Codename: **babamech** (after Baba Yaga's chicken-legged hut — the chicken mech). Engine: **Godot 4.7, GDScript**. Windows, keyboard + mouse (gamepad later).

## Premise
Co-op mech combat (up to **4 players**) inside a rotating cylinder space habitat. Decks are **concentric rings**; "down" points outward. Each deck is a dense urban habitat mixing **urban, park, industrial, open air, transit** zones. Players rescue civilians from **robots controlled by aliens** that have hijacked civil defense (tanks, mechs, infantry). Robots are built first.

## View & world
- Gameplay is **full 3D, third-person over-the-shoulder**. The **2D cross-section** of the rings is for level design and the in-game map.
- Curved horizon, ring floor rising in the distance (Cluckipede look — https://github.com/afaucher/Cluckipede, ideas only).
- **Look-down ledges**: floor openings let you see/fight the deck below. Whole mission section loaded as one scene.
- Decks connect by **elevators** (in-world, no reload) and **ramps** (continuous descent).
- Tallest buildings are **pillars** joining the ceiling (not standable). Non-urban pillars are smaller / other uses.
- **All layouts procedural** from a seed (checksum-verified on every machine, as in cast).
- Planned-habitat layout: key areas linked by roads (with traffic) and paths; recreation areas; urban blocks of varied height with constricted sightlines; rooftops for sightlines.
- Gravity same on every deck (for now).
- Destructible environment expected; deferred past MVP.
- Mission ≈ **30 minutes**, one connected multi-deck section. Crew may split across decks freely.

## Mechs
- Biped, fully articulated, **procedural IK** foot planting at all speeds.
- Low poly, highly stylized.
- **Oversized organic head** (not armor): chicken, pickle, corn, dog. Head + player name live in main settings. Heads cosmetic only (for now).
- Pre-mission: pick **mech (body + legs)** and **loadout**. Start with **one chassis**; mix-and-match decided later.
- Main menu shows the player's current mech beside the options.
- Hardpoints around the mech (arms, shoulders, back). Weapons are also **consumables collected in-mission**. Examples: arm lasers, shoulder rocket pods, back-mounted indirect-fire mortar.
- Each weapon has **weight**, **passive heat**, and **active heat per use**. Weight is a penalty.
- **Heat is the primary limit.** Overheat → hard shutdown → cooldown → reboot. Thrusters also make heat.
- **Space fires thrusters** any time (that is the jump). Auto emergency burn on falls; falling too far = hard landing that **damages legs**.
- **Component damage** with HUD diagram (incl. head). Damaged weapons: more heat, slower reload, ammo loss. Destroyed parts are non-functional: lost leg → can't walk; head → disabled; arm → keep fighting.
- Disabled mechs revived by **pickups or teammates**. Mission fails when all players are disabled. No AI-filled seats (maybe later).

### Locked art direction (2026-11-21, picks in `art/picks/`)
- **Chassis** (`mech_base.png`): mech, not humanoid and not a house. Rounded armored torso (white + safety-orange civil-defense livery, amber lights), **no arms**, two **mechanical chicken legs** (reverse-jointed knee, three forward toes + rear spur). A **nose** juts from the front with a hatch and a tall **back plate** behind the pilot. Shoulder weapon pods **raised above the head**.
- **Pilot sits inside the mech; only head and neck stick out** of the hatch. Same chassis for all four pilots.
- **Heads**: true low poly, **~150 faces**, visible flat facets, flat colour per face, no texture. Attitude **stern** (heavy angled brow, narrowed eyes, mouth closed), from the Cluckipede concept art (`art/reference/cluckipede/`). Chicken, pickle, corn, dog all match.
- **Hardpoints: 5** — 2 shoulder (raised above the head), 2 torso side (hip height; covers the "arm weapon" role since there are no arms), 1 back (behind the back plate; indirect fire such as the mortar). Each weapon is its own swappable low-poly model.
- **Weapon looks** (`art/renders/mech_r8/grid_mech_r8.png`): twin autocannons, 6-tube missile boxes, teal-lens lasers, coil railgun (oversized, one shoulder), rotary gatlings (sides), swivel gun booms (sides), back mortar. Asymmetric loadouts allowed.
- Still open: head scale on the chassis.
- **Environment look**: low poly, **day** lighting (bright artificial daylight from ceiling strips; cream, terracotta, sage, sky blue; soft distance haze), **occupied** condition. Ref `art/renders/env_r1/day_occupied_s909.png`.
- **Occupation is control, not war damage**: the invaders have ruled for a while and run society; they are not actively destroying it. Show it with checkpoints and cordons, surveillance pylons and drones, alien/robot banners and signage, alien tech grafted onto civic infrastructure, curfew-quiet streets, parked civil-defense units. No burning wrecks, rubble or smoke (battle damage, if any, comes later from player combat).
- **Alien banners are destructible** by players (liberating an area). Other occupation props TBD.
- **Aliens need an art pass**: colour scheme and look still open (placeholder red/black, red eye-lenses).
- Full design written up in [game-design.md](game-design.md).
- **Vertical slice** defined in [vertical-slice.md](vertical-slice.md): one mech (laser / rocket pod / mortar), small
  arena on a **curved ring segment with radial gravity**, **turrets** as the enemy, co-op as the last milestone,
  placeholder art first.
- **Maps are arc segments, not full rings.** Ring radius is free (larger is fine); each section needs designed
  boundary walls and transitions into them (section-layout + city-gen sessions).

## Aiming
- True aim point drawn on the target surface with incremental indicators from each weapon to it.
- Straight-flight weapons need true **line of sight from their hardpoint**.

## Enemies
- Coordinated AI: shared last-known positions, flanking/surrounding, coordinated attacks. Host-owned.
- Telegraphs ≥ 0.3 s (cast lesson).

## Rescue
- Commandeer **civilian transport pods** and **supply trucks** (not targeted by enemies) and **evac trucks** (targeted). Follow at a distance once ordered; load civilians.
- Orders use cast's order pipeline, no voice yet.
- Combat first; mission objectives later. Meta-progression deferred.

## Multiplayer
- Inherit cast's model + tooling (see cast `docs/design/networking.md`): owner authority, victim decides hits, host owns world, scheduled effects, link sim, telemetry, headless multi-process tests. No anti-cheat.
- Steam lobby: Play/Host creates; Join takes first open lobby. Small group of friends.

## Tooling
- **Lab view** with every scene and tunable params (model: flap's lab; also cast's move lab / gym).
- **Art direction via 3x3 grids** (9 options, or 2 params × 3 values) rendered with local ComfyUI.

## References
- cast: `C:\Users\alexa\.gemini\antigravity\scratch\cast`
- flap (lab view): `C:\Users\alexa\.gemini\antigravity\scratch\flap`
- Bridge to Friendship (customization screen): `C:\Users\alexa\.gemini\antigravity\scratch\bridge-to-friendship`
- **Right mouse = camera zoom.** Missiles have no separate designator: they track the player's live crosshair aim point
  for as long as they fly (keeping the crosshair on the target is the "active track"; no lock-on, no auto-track).
