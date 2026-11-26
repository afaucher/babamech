# Bulwark effectiveness (2026-11-25, Mech session)

User (playtest): "It's actually less combat-effective because of the reduction of shoulder and arm hardpoints. We need to
reconsider. Maybe a 3rd hardpoint under the body? The goal was to trade off against the back-mounted slots, but those
aren't effective enough." (docs/playtest-backlog.md item 7; item 8, mortar ammo x2, has landed: the catalog says 6.)

There is **no third chassis** in the game ("Wasp" is a design sketch): everything below is Bulwark vs Strider only.

**Status (2026-11-25): decided. The user kept the belly turret (option A) as final and added the armour (C4: core HP
x1.5, now torso 900, legs 420, head 150 in `PlayerTarget.CHASSIS_COMPONENT_HP`; section 6).**

## How it is measured (repeatable)
| tool | what | run |
|---|---|---|
| `tools/balance/chassis_paper.gd` | paper numbers from the catalog: fixed-step heat sim (DT 0.05 s), "perfect pilot" (fires whenever ready, never over 95 % of the heat cap, cheapest damage per heat first, walking heat on), every shot a hit; burst 5 s, DPS 30 / 120 s, by range (Combat.falloff), ammo-limited damage; legal loadout enumeration (fits, weight <= max_weight, max_per_mech) | used by the two below |
| `tools/balance/chassis_options_paper.gd` | the option table (A / B / C what-ifs) | `<godot> --path . --headless --script res://tools/balance/chassis_options_paper.gd` |
| `tools/balance/chassis_compare.gd` (+ `.tscn`, `run_chassis_compare.ps1`) | paper report + the bot (PlayerBot, veteran and average) driving each chassis in BalanceScenarios: duel turret / strider / tank street, pockets vanguard / crossfire / cover siege, city_solo (150 s cap) on seeds 1, 2, 3, 4, 5, 7; per run damage by hardpoint, "can't bear" (enemy in sight and in the weapon's range, barrel not on target), heat-held time, ammo dry, TTK per enemy type; what-ifs as variants (`base`, `belly`, `belly_armor`, `c_turn`, `c_armor`, `c_heat`, `mortar6`) | `.\tools\balance\run_chassis_compare.ps1 -Variant belly -Seeds 1,2,3,4,5,7 -Jobs 3` -> `test_logs\balance\chassis\<tag>.md` |
| `tests/chassis_eff_mission.gd` (not a `test_*`) + `run_chassis_missions.ps1` + `sum_chassis_missions.ps1` | the mission bot plays a whole solo plan-mode mission (bot_obj_case: veteran, no cheat, bonuses off, fixed step, 2x) in a chassis / loadout from the environment; records win time, deaths, damage by hardpoint, taken, can't-bear, heat-held, dry time, TTK | `.\tools\balance\run_chassis_missions.ps1 -Tag x -Seeds 1,2,5,7 -RunsFile runs.txt` then `.\tools\balance\sum_chassis_missions.ps1 -Tag x` |

`scripts/ai/balance_scenarios.gd` gained four optional spec keys (`chassis`, `loadout_dict`, `on_spawn`, `on_step`);
BalanceScenarios without them is unchanged. All numbers are fixed step and seeded; within one batch the Strider rows
are identical across variants (checked), so variant rows of one batch compare directly. **Between batches they do
not**: other sessions changed enemy AI / bot / gait code during the day, so only same-batch rows are compared below.
Mortar ammo: 6 (backlog item 8 landed before every number here). The sibling changes (Bulwark hot thrust 80 /s and no
thrust ceiling, the gait phase fix, hangar clamps, fall damage per chassis) were in the tree for the scenario batch
"b2" and the mission batch "belly"; the first mission batch ("base") predates the gait fix and is used only as a
second sample.

## 1. The measured gap

### Paper (catalog only, every shot hits)
| loadout | weight | burst 5 s | DPS 30 s | DPS 120 s | ammo dmg | heat-held s / 120 |
|---|---|---|---|---|---|---|
| Strider default (laser, AC, rockets, -, mortar) | 26 / 30 | 952 | 84.7 | 68.0 | 1416 | 113 |
| Strider best at 30 s (-, AC, AC, AC, mortar) | 30 / 30 | 1018 | 110.2 | 84.8 | 480 | 113 |
| Bulwark default (AC, rockets, mortar, radiator) | 27 / 40 | 732 | 102.2 | 66.8 | 1416 | **0** |
| Bulwark best at 30 s (gatling, gatling, mortar, radiator) | 26 / 40 | 796 | 157.2 | 147.3 | 480 | 0 |

The decisive paper fact: the Strider is **heat-limited** (it holds fire for heat 113 of 120 s), the Bulwark default is
**slot-limited** (it never holds fire for heat: 0 s). Its 130 cap, 12 cooling and the radiator are heat it cannot
spend with two guns; its radiator adds **+0.0 DPS** on the default loadout (+20 on the Strider). It also has 13 t of
weight budget unused. Burst (5 s) is 77 % of the Strider's: two guns cannot dump a heat buffer.

Back items, delta against an empty slot (default loadout, 120 s at 80 m): mortar +3.8 DPS, 480 dmg per load (6 x 80;
its real job is roofs out of sight); radiator +0.0 on the Bulwark (slot-limited), +20 on the Strider; ammo bin +5.9 DPS /
+708 ammo dmg; repair drone 948 HP per charge, 1896 per mission. A second back item buys the Bulwark little because
damage, not utility, is what it lacks.

### Bot scenarios (batch b2: 24 runs per row: 6 city seeds + 6 duels / pockets, x veteran and average)
| | wins | kills / 234 | dealt / min | taken / min | downs | can't bear % | TTK turret / strider / tank s |
|---|---|---|---|---|---|---|---|
| Strider default | 15 | 202 | 877 | 119 | 0 | 18 | 57 / 22 / 48 |
| Bulwark default | 12 | 134 | 798 | 422 | 7 | 23 | 46 / 22 / 49 |
| Strider best (AC x3) | 22 | 212 | 1123 | 151 | 1 | 17 | 40 / 19 / 40 |
| Bulwark best (gatling x2) | 16 | 182 | 932 | 312 | 4 | 24 | 39 / 22 / 38 |

City only (12 runs a row, 150 s, 212 enemies): kills Strider 180 / Bulwark 112 (62 %); best loadouts 190 / 160 (84 %).
Enemy hit rates against the Bulwark (city, b1): gunship 52 % vs 12 % on the Strider, tank 40 % vs 7 %, turret 30 % vs
12 %: it is hit 2.5 to 5 times as often.

### Missions (mission bot, whole solo plan-mode missions, seeds 1, 2, 5, 7, batch "base")
| | won | mean win time | deaths / mission | dealt / min | taken / min | can't bear % |
|---|---|---|---|---|---|---|
| Strider default | 4 / 4 | 505 s | 0.5 | 691 | 164 | 37 |
| Bulwark default | 4 / 4 | 695 s (138 %) | 4.8 | 512 (74 %) | 340 (207 %) | 46 |
| Bulwark best (gatling x2) | 4 / 4 | 685 s (136 %) | 3.3 | 750 (109 %) | 283 (172 %) | 44 |

Bulwark default's rockets sit dry 299 s of a 785 s mission on seed 2 (it has one sustained gun the rest of the time);
the mortar is dry most of every mission (depots refill it).

### Bulwark as % of Strider (defaults)
| | scenarios (b2) | missions (base) |
|---|---|---|
| damage output (dealt / min) | 91 % | 74 % |
| kills (scenarios) / win time (missions) | 66 % of the kills | 138 % of the time |
| survivability: damage taken / min | 355 % | 207 % |
| deaths | 7 vs 0 (24 runs) | 4.8 vs 0.5 per mission |

Confidence: scenarios 24 runs a row (per-run dealt / min sd ~150 in the city, so +-5 % on a row mean); missions 4 seeds,
one run each (deterministic per seed, but seed-to-seed spread of win time is +-25 %). Direction is the same on every
seed and both batches.

## 2. Where the gap comes from
1. **Slot count (the biggest share of the output gap).** Two direct-fire guns cannot spend the Bulwark's heat: 0 s
   heat-held on paper and in the bots (0-2 %), against 19-35 % for the Strider. Fewer guns -> longer TTK -> more time
   exposed. Rockets run dry and leave one gun. The best two-gun loadout recovers most of it (84 % city kills).
2. **Being a big, slow target (the biggest share of the survivability gap).** 1.5x the hit-sphere area of the Strider
   for 1.4x its HP (HP per m^2 6.5 vs 7.1), it cannot dodge (walk 8 vs 12, side-step strafe) or climb onto roofs, so
   enemies hit it 2.5-5x as often. Damage taken is 2-3.5x per minute.
3. **Turn rate / aim limits: small.** Can't-bear is 23 % vs 18 % (scenarios), 46 % vs 37 % (missions). Giving the
   Bulwark the Strider's turn rate (variant c_turn) cut can't-bear to 13 % but did not raise kills (131 vs 134) or cut
   deaths (8). The inward yaw limit only bites on the swivel. Not the problem.
4. **Back items: weak as a trade.** The second back item is mostly a radiator that does nothing on a slot-limited mech;
   the mortar's 6 shells are good indirect damage but empty most of a mission.
5. **Bot handling: part of it, not all.** The bot does not use the Bulwark's spare heat or toughness on purpose; a human
   will brawl better. But the paper says the same thing as the bot: the default kit has nothing to spend its heat on.

## 3. Options
Paper (`chassis_options_paper.gd`), 120 s at 80 m unless noted; scenario numbers from batch b2 where measured.

| option | loadout | burst 5 s | DPS 30 | DPS 120 | measured (b2, all 24 runs: kills / taken per min / downs) |
|---|---|---|---|---|---|
| today | AC, rockets, mortar, radiator | 732 | 102 | 67 | 134 / 422 / 7 |
| **A belly turret** | + belly gatling (default) | 1050 | 172 | 138 | **175 / 359 / 4** |
| A, best | AC, AC, mortar, radiator, belly AC | 1018 | 180 | 163 | 204 / 240 / 1 |
| B back saddles take shoulder weapons | AC, rockets, mortar, rockets | 1018 | 133 | 74 | (not measured: needs a catalog change; paper only) |
| B, best | AC, AC, rockets (back), mortar | 1018 | 151 | 121 | |
| C1 heat cap 160 / cooling +4 | today's loadout | 732 | 102 | 67 | **no change on paper**: it is not heat-limited |
| C2 braced (+25 % fire rate) | today's loadout | 824 | 116 | 81 | (paper only: no rate hook) |
| C3 Strider turn rate (1.8) | today's loadout | - | - | - | 131 / 441 / 8: can't bear 23 -> 13 %, no gain |
| C4 armour (core HP x1.5) | today's loadout | - | - | - | 153 / 388 / 2 |
| **A + C4** | belly gatling + armour | 1050 | 172 | 138 | **183 / 358 / 1**; best loadout 217 / 265 / 0 |
| (Strider for reference) | default / best | 952 / 1018 | 85 / 110 | 68 / 85 | 202 / 119 / 0 ; 212 / 151 / 1 |

**A. Belly turret ("chin" under the keel).** A fifth hardpoint, key 5, so both chassis have 5: the Strider 4 direct +
1 back, the Bulwark 3 direct + 2 back. A pintle turret under the keel's flat bottom between the thighs, 2.6-2.9 m up.
Takes the **side** weapons only (laser, autocannon, gatling, swivel, flamer, flak): a 1.5 m pod or a 2.5 m railgun has
no room under the belly, and the shoulder classes stay the side guns' (which already take them). Arc: yaw +-30 (as the
side guns), pitch -10 / +15 (its parked pose in the heat-shutdown slump must stay off the ground; the flak's top meets
the bearing ring above +15): it is a level, forward gun, it cannot shoot up at gunships or down at feet; the side guns
keep the full -50 / +45. Cost: weight (the budget has 13 t free: a gatling makes 33 / 40), the heat the Bulwark already
has spare (the radiator starts to matter: +21 DPS), an 80 HP component with its own hit sphere under the nose (shots
from the front low hit it first). Playstyle: the Bulwark gets **more guns on target at once than the Strider** in a
planted fight (3 guns + 130 cap) and keeps its back items for utility; the Strider keeps mobility, roofs, burst-to-heat
efficiency. Art: one new part (`bulwark_belly_mount`, 372 faces), the gun is drawn by the existing weapon meshes.
Code: data only plus one hardware entry and a codec id. Networking: one more component and mount pair in the snapshot
(entry 52 -> 55 B). Risk: it is nearly invisible from the chase camera (only its muzzle peeks below the hull): the HUD
row and the diagram name it; a human may forget it exists. Not wide-arc: a full-traverse turret would need a
hardpoint-arc widening in WeaponMount (Weapons' code).

**B. Stronger back saddles (shoulder weapons on the back).** Lets the Bulwark carry 4 direct / indirect weapons. Paper:
+30 % DPS 30 over today, burst = the Strider's, but less sustained than A (rocket pods are ammo-limited, 36 rockets).
Art: rocket / missile pods and a railgun on rear-wing plinths need new pylons, clearance against the pilot's head and the
chase camera (the back boxes are already the camera risk, chassis-rules 2.6); railgun on the back fires over the head.
It erases the Bulwark's identity (a Strider with two guns moved backwards). Cheaper variant: a mortar bonus (faster
reload / more shells) on the Bulwark only: with 6 shells already, +50 % mortar is +240 damage per load: small.

**C. Chassis rules that make two guns worth more.** Heat cap / cooling (C1) does **nothing** for the default: it is not
heat-limited (paper 0 s held). "Braced" +25 % fire rate (C2) is +14 % DPS 30 and needs a new rate hook. Turn rate (C3)
measured: no gain. Armour (C4: core HP x1.5, i.e. a damage multiplier ~0.67 on the hull and legs) attacks the
survivability gap directly: downs 7 -> 2, kills 134 -> 153, but output stays two-gun.

## 4. Recommendation
**A + C4: the belly turret, plus an armour multiplier on the Bulwark's core (~1.5x core HP or 0.67 damage taken), the
armour as a follow-up decision.** A fixes the cause the user named and the paper confirms (slot-limited output, unused
heat and weight), C4 fixes the cause the bots expose (it is hit 3-5x as often). Together (b2): kills 183 vs the
Strider's 202 (91 %), taken 358 vs 119 per min (still 3x, but the deaths drop to 1 in 24 runs), dealt 816 vs 877; best
loadouts 217 vs 212 kills, 0 deaths. Shape: the Bulwark out-guns the Strider standing still (3 guns, 130 heat, 1 s
longer burst), shrugs off damage, is slow and roof-bound; the Strider is the mobile, efficient one. B was rejected:
more art and camera risk, and it turns the Bulwark into a backwards Strider. C1-C3 were measured or computed as no gain.

A was built first for the user to judge; the user then kept it and added C4 (section 6).

### What the belly turret build does
- `MechCatalog.CHASSIS["bulwark"].hardpoints` += `{"id": "belly", "label": "Belly turret", "mount": "belly",
  "mounts": ["side"], "yaw_in_max": 30, "yaw_out_max": 30, "pitch_down_max": 10, "pitch_up_max": 15}` (slot / key 5);
  default loadout and BotProfile's "bulwark" kit `"belly": "gatling"`.
- `BulwarkMeshes`: `bulwark_belly_mount` (base plate on the keel's flat underside between the ribs, neck, bearing ring
  with orange rim and bolts, steel pintle post into the gun, end cap, feed cable), `MOUNTS["belly"]`, `BELLY_*`
  constants; `ChassisParts` mount_hw `"belly"`. Strider `.res` byte-identical (checked by hash).
- `PlayerTarget.CHASSIS_HARDPOINT_SPHERES["bulwark"]["belly"]` (0, 2.6, -2.2) r 0.9.
- `NetMechCodec.COMPONENTS` and `MOUNTS` += `"belly"`, ENTRY_SIZE 52 -> 55 (docs/networking.md updated; 3 mechs = 173 B
  of the 512 B budget).
- `MechDiagram` groups the belly's mount and weapon like the other hardpoints; MechHud lists it as "BELLY"
  (`MechHud.MOUNT_SHORT`).

### Re-measured with the belly turret
Scenarios (batch b2, same batch as section 1, 24 runs a row):

| | wins | kills / 234 | dealt / min | taken / min | downs | can't bear % |
|---|---|---|---|---|---|---|
| Strider default | 15 | 202 | 877 | 119 | 0 | 18 |
| Bulwark today | 12 | 134 (66 %) | 798 (91 %) | 422 (355 %) | 7 | 23 |
| **Bulwark + belly gatling (default)** | 13 | **175 (87 %)** | 891 (102 %) | 359 (302 %) | 4 | 34 |
| Bulwark + belly, best (AC x3) | 19 | 204 (101 %) | 991 (113 %) | 240 (202 %) | 1 | 33 |
| Bulwark + belly + armour x1.5 (A + C4 what-if) | 13 | 183 (91 %) | 816 (93 %) | 358 | 1 | 34 |
| same, best | 21 | 217 (107 %) | 1037 (118 %) | 265 | 0 | 33 |

Missions with the belly turret (batch "belly": all four rows in the same tree, seeds 1, 2, 5, 7; win time over won
missions):

| | won | mean win time | deaths / mission | dealt / min | taken / min | belly's share of damage |
|---|---|---|---|---|---|---|
| Strider default | 4 / 4 | 522 s | 2.8 | 671 | 182 | - |
| Bulwark today | **3 / 4** (seed 2: the deck-1 relay was lost at 272 s) | 680 s (130 %) | 2.8 | 532 (79 %) | 280 (154 %) | - |
| **Bulwark + belly gatling** | 4 / 4 | 639 s (122 %) | **1.0** | 684 (102 %) | 211 (116 %) | 36 % |
| Bulwark + belly, best (AC x3) | 4 / 4 | **463 s (89 %)** | 2.5 | 948 (141 %) | 315 (173 %) | 29 % |

Read: with the belly gun the default Bulwark deals the Strider's damage per minute (79 -> 102 %), dies a third as often,
and finishes missions in 122 % of the time (the rest is walking speed: it travels at two thirds of the Strider's pace);
a gun-heavy loadout (three autocannons) beats the Strider's mission time. `test_bot_bulwark_mission` (seed 2, the
belly kit, before the armour) won at 487.9 s with 1 death (its documented baseline: 534.9 s, 5 deaths).

Weak spots seen in the shots (`docs/design/chassis-concepts/effectiveness/`): from the chase camera the belly gun is
hidden under the hull (only its muzzle shows); from the side it is behind the near leg. It reads clearly from the front
three-quarter and from below (bearing ring, orange rim, pintle post, gun between the knees).

## 5. Where the belly turret lives (for a later change)
- The `belly` line in `MechCatalog.CHASSIS["bulwark"].hardpoints`, `"belly"` in its default_loadout and in
  `BotProfile.LOADOUTS["bulwark"]`. Every test reads the hardpoint list (the belly checks skip themselves if it goes).
  The mesh, sphere and codec ids: `BulwarkMeshes` BELLY_* / `_belly_mount` / BODY_PARTS entry, `ChassisParts` mount_hw
  "belly", `CHASSIS_HARDPOINT_SPHERES` belly, codec `"belly"` (ENTRY_SIZE 55; 52 without it).
- B (not taken) would be: `back_l` / `back_r` `"mounts": ["back", "shoulder"]` (then pylons, clearance and camera work).

## 6. Decision and the armour as built (2026-11-25)
The user kept A as final and added C4. `PlayerTarget.CHASSIS_COMPONENT_HP["bulwark"]` = torso 900, legs 420 each,
head 150 (was 600 / 280 / 100): every core component x1.5, as the measured C4 variant did (`chassis_compare.gd`
scales all of `PlayerTarget.CORE_COMPONENTS`, the head included; hardpoints stay 80). Core total 1890 = 2.1x the
Strider's 900. Everything else reads fractions of the per-chassis max and follows on its own: HUD / diagram / crew
panel, the snapshot (`NetMechCodec`: u8 0..254 of the owner's max, so 900 HP rides with 3.5 HP steps, no clipping; a
round-trip check in `test_weapons_bulwark`), the repair drone (1 % of total max HP per s: a full repair takes the same
100 s of beam on both chassis, 18.9 HP/s on the Bulwark vs 9 on the Strider), depot cores (50 % of the missing
structure), the bot's repair / retreat thresholds (fractions). Fall damage keeps the same share of the leg: legs
31.5 / 63 / 100.8 / 252 at 25 / 30 / 36 / 60 m/s, torso 67.5 at 60 m/s, cap 378 (weapons.md "Fall damage").
The corn pilot on a Bulwark got two small head spheres for its leaves (`CHASSIS_HEAD_EXTRA`): with the belly gun mounted
6.8 % of head shots missed; now 3.4 % (limit 6 %).
`test_bot_bulwark_mission` (seed 2, belly kit + armour, the tree of 2026-11-25 evening): won at 558.6 s, 3 deaths
(head at 86 s, torso at 175 s and 327 s). Not comparable to the 487.9 s / 1 death above: other sessions changed enemy
and bot code in between, and one seed is one sample.
