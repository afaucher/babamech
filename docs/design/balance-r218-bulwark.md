# R2.18: Bulwark against gunships and snipers (measurement and proposal, 2026-11-27)

Playtest item R2.18 (`docs/playtest-backlog.md`): "measure and propose; don't retune without reporting". This note changes
nothing in the game. Measured by a Claude Missions subagent with bot-played missions through the real path (the setup of
`tests/test_bot_bulwark_mission.gd`), a temporary probe that only listened to signals (deleted), and a read-only sweep of
the defend relay sites. Raw logs, scripts and HTML pacing reports are in the session scratch folder (paths at the end).

## Decision (user, 2026-11-27)

"Leave the Bulwark. It can be a harder chassis to play." No chassis or enemy retuning for the Bulwark gap: proposals 1
and 4 to 6 below are not being applied. Bulwark-specific bot tests check that it completes missions, not that it matches
the Strider's damage or time. Still going ahead, because it helps every chassis: proposal 3 (a sweep whose last enemy is
a kiting scout drone). The bot findings (proposal 2) are with the Engine session.

## Summary (read this first)

The Bulwark is not losing to gunships and snipers in the current build. It is hit about twice as often and twice as
hard as the Strider by almost every enemy, worst by the ones that shoot from above (rooftop turrets 3.5x, snipers 3.3x,
gunships 1.9x more damage per round), because its hull is twice as big seen from above, about a third wider and a third
slower. Its 2.1x armour pays for that almost exactly: over seven seeds it took 1.7x the Strider's damage, was downed as
often (10 vs 11) and finished in about the same time (552 s vs 579 s on average). What does hurt it is that its two side
guns have the Strider's 80 HP: at least one was destroyed in 6 of 7 missions (the Strider lost a gun in 4 of 7), and with
them gone its only gun left (the belly gatling) cannot aim higher than 15 degrees, so it can no longer shoot gunships. The 950 s timeout, the 600 s sweep
and the 5 deaths in the R2.18 report do not happen any more: seed 22 is won at 587 s with 2 downs, identically in three
runs. The long sweeps today are bot chases after scout drones (one Strider sweep spent 280 s on one drone). Enemy
anti-air (gunships matching altitude) made no difference: it never triggers against a Bulwark.

## How it was measured

- Missions: solo plan-mode stack mission, mission bot `--bot veteran` alone, no cheat, bonuses off, every enemy at full
  strength, 2x sim, limit 950 s: exactly `tests/bot_obj_case.gd` + `tests/bulwark_bot_case.gd`. Loadouts as the bot tests:
  Bulwark = `BotProfile.LOADOUTS["bulwark"]` (side_l autocannon, side_r rockets, back_l mortar, back_r radiator, belly
  gatling: the chassis default); Strider = its chassis default (side_l laser, side_r autocannon, shoulder_l rockets,
  back mortar). Neither kit carries a repair drone, so no self-revive can happen in these runs.
- Wasp: skipped. It is a draft chassis (`MechCatalog.DRAFT_CHASSIS`), not playable and not in `BOT_CHASSIS_ORDER`.
- Determinism: every repeated run (seeds 2, 16, 22 x2-3 for both chassis, 7 for the Bulwark) gave identical results, so
  one run per chassis and seed is the sample. Main set: seeds 2, 7, 16, 22, both chassis, same build. Seed 403112: the
  first Strider run was invalid (two runs shared the bot tests' settings file and it loaded a Bulwark; see "Could not
  measure"), and another session's edits landed mid-measurement (a parse error stopped two runs), so 403112 and the extra
  seeds 1 and 5 were run as pairs on the newer build and are reported separately.
- Data: the combat log (`dmg_in`, `dmg_out`, `shot`, `threat`, `los`, `deck_sum`, `end`, `debrief`), the mission bot's
  `[Bot]` lines, and a probe on `EnemySquad.enemy_spawned`, `EnemyBase.telegraph_started / weapon_fired /
  destroyed_enemy`, `CombatWorld.hit_landed / fired`, `PlayerTarget.damaged / player_component_destroyed` (enemy spawn and
  death times, every enemy round at the pilot with range, height and the bot's sight, every bot round with the kind it
  was fighting).

## Results

### Per mission (main set, deterministic)

| chassis | seed | outcome | time s | deck 0/1/2 s | downs | lowest structure % | damage in | gunship | sniper | other turrets | tank | breacher | hound | troopers | drop troops |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Bulwark | 2 | won | 553 | 80/216/256 | 2 | 41 | 3353 | 1158 | 381 | 304 | 550 | 91 | 385 | 485 | 0 |
| Bulwark | 7 | won | 499 | 70/131/298 | 1 | 22 | 2106 | 558 | 336 | 97 | 0 | 124 | 468 | 324 | 199 |
| Bulwark | 16 | won | 564 | 80/136/348 | 1 | 42 | 2151 | 212 | 240 | 73 | 170 | 543 | 701 | 170 | 42 |
| Bulwark | 22 | won | 587 | 60/216/310 | 2 | 52 | 3065 | 916 | 240 | 192 | 1295 | 113 | 68 | 225 | 16 |
| Strider | 2 | won | 510 | 60/146/304 | 2 | 53 | 1592 | 520 | 96 | 134 | 366 | 64 | 144 | 235 | 32 |
| Strider | 7 | won | 349 | 50/126/173 | 0 | 69 | 587 | 159 | 48 | 0 | 85 | 50 | 57 | 189 | 0 |
| Strider | 16 | won | 895 | 60/151/684 | 1 | 64 | 1111 | 0 | 48 | 0 | 592 | 48 | 176 | 183 | 64 |
| Strider | 22 | won | 794 | 45/241/507 | 4 | 36 | 2691 | 1002 | 172 | 207 | 763 | 171 | 51 | 141 | 182 |

Objectives (all seeds: deck 0 flag, deck 1 defend, deck 2 sweep, extraction hold): every one done by both chassis. Defend
relays ended at 65-95 % (Bulwark) and 60-93 % (Strider). Deck 2 (the sweep) is the long deck everywhere. "Lowest
structure" is the debrief's `hp_min` (total structure while standing; downs are separate). Depot cores used: Bulwark 1 in
4 missions, Strider 7. Self-revives 0 (no drone in either kit). Redeploys = downs.

Damage taken, summed over the four seeds: Bulwark 10675 (2669 per mission): gunship 27 %, tank 19 %, hound 15 %,
troopers 11 %, sniper 11 %, breacher 8 %, other turrets 6 %, drop troops 2 %. Strider 5981 (1495 per mission): tank 30 %,
gunship 28 %, troopers 12 %, hound 7 %, sniper 6 %, breacher 6 %, drop troops 5 %, other turrets 5 %. Per deck the gunship
damage sits on whichever deck has gunships (seed 22 Bulwark: 240 / 311 / 365 on decks 0 / 1 / 2; Strider deck 2 alone 714
with three gunships alive at once). Downs by killer: Bulwark tank 3, turret, hound, breacher; Strider tank 3, gunship 2,
sniper, breacher.

Newer build (another session's edits landed during the measurement), pairs run back to back:

| chassis | seed | outcome | time s | deck 0/1/2 s | downs | lowest structure % | damage in | gunship | sniper | other turrets | tank | breacher | hound | troopers |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Bulwark | 1 | won | 618 | 70/276/272 | 1 | 29 | 2558 | 258 | 0 | 520 | 627 | 592 | 179 | 354 |
| Strider | 1 | won | 592 | 55/341/195 | 3 | 49 | 2133 | 910 | 0 | 231 | 357 | 191 | 210 | 234 |
| Bulwark | 5 | won | 588 | 55/301/232 | 2 | 31 | 3358 | 869 | 96 | 0 | 881 | 199 | 923 | 358 |
| Strider | 5 | won | 471 | 45/216/209 | 0 | 65 | 989 | 245 | 96 | 0 | 170 | 113 | 76 | 289 |
| Bulwark | 403112 | won | 454 | 206/115/132 | 1 | 36 | 2945 | 380 | 608 | 434 | 0 | 477 | 526 | 408 |
| Strider | 403112 | won | 442 | 206/115/120 | 1 | 46 | 2128 | 523 | 48 | 405 | 256 | 370 | 328 | 183 |

Same picture: Bulwark 2954 damage per mission vs 1750 (1.7x), 4 downs each, gunships 1.4x and snipers 2.1x more damage
per round on the Bulwark, the Strider downed 3 times by gunships on seed 1 (910 gunship damage). (The first Bulwark
403112 run, on the main build, won at 449 s with 2 downs.)

### Every enemy hits the Bulwark more (main set)

| enemy kind | rounds at the pilot B / S | hit rate B / S | damage per round B / S | B / S |
|---|---|---|---|---|
| gunship | 312 / 347 | 41 % / 22 % | 9.1 / 4.8 | 1.9x |
| sniper turret | 71 / 71 | 35 % / 11 % | 16.9 / 5.1 | 3.3x |
| enforcer turret | 60 / 144 | 22 % / 6 % | 6.8 / 1.8 | 3.7x |
| salvo turret | 111 / 114 | 14 % / 4 % | 2.3 / 0.7 | 3.5x |
| tank | 110 / 142 | 25 % / 19 % | 18.3 / 12.7 | 1.4x |
| hound (strider) | 346 / 211 | 27 % / 12 % | 4.7 / 2.0 | 2.3x |
| breacher (5 pellets a round) | 50 / 43 | - | 17.4 / 7.8 | 2.2x |

Hit = a round whose shot key touched the pilot (splash included). The elevated shooters gain the most.

### Time to kill (bot's first hit to the kill, median s, n)

| kind | Bulwark | Strider |
|---|---|---|
| gunship | 49 (9) | 63 (7) |
| tank | 24 (11) | 36 (9) |
| breacher | 8.5 (35) | 7.8 (29) |
| hound | 5.6 (40) | 4.8 (39) |
| troopers | 3.4 (89) | 3.1 (66) |
| drop troops | 14 (11) | 0.6 (16) |
| enforcer turret | 4.0 (10) | 1.8 (8) |
| sniper turret | 3.2 (2) | 0.2 (3) |
| drone | 19 (18) | 14 (13) |

### Bot accuracy (hits / rounds fired while fighting that kind, main set)

| weapon | vs gunship | vs sniper | vs tank | vs hound | vs troopers | vs drone |
|---|---|---|---|---|---|---|
| Bulwark autocannon | 20 % (303) | 29 % (51) | 76 % (148) | 25 % (590) | 22 % (472) | 10 % (330) |
| Bulwark belly gatling | 12 % (1677) | 5 % (183) | 41 % (722) | 12 % (2948) | 8 % (2351) | 5 % (1777) |
| Bulwark rockets | 7 % (82) | - | 65 % (17) | 16 % (77) | - | 4 % (46) |
| Bulwark mortar | 0 % (5) | 57 % (7) | 80 % (5) | - | - | 10 % (10) |
| Strider autocannon | 20 % (484) | 20 % (20) | 61 % (183) | 33 % (497) | 23 % (562) | 5 % (505) |
| Strider laser | 6 % (53) | - | 77 % (22) | 20 % (65) | 17 % (100) | 2 % (244) |
| Strider rockets | 17 % (58) | - | 29 % (42) | 28 % (61) | - | 0 % (54) |
| Strider mortar | 0 % (12) | 29 % (7) | 17 % (6) | - | - | 0 % (10) |

Elevation of a gunship when the bot fired at it: Bulwark gatling 54 % under 15 deg, 43 % at 15-45, 4 % over 45 (the
belly turret's arc ends at +15: `MechCatalog` bulwark hardpoint `belly` `pitch_up_max` 15, so 47 % of the 1677 gatling
rounds at gunships could not reach); Bulwark autocannon 69 / 25 / 6 % (side guns pivot to +45, `Combat.PIVOT_PITCH_UP`;
the camera, the bot's too, stops at +0.55 rad = 31.5 deg). The Strider's guns sit on the same +45 limit.

### Gunship fact sheet (main set; every gunship that fired at the pilot)

| | Bulwark | Strider |
|---|---|---|
| gunships firing at the pilot | 12 (3.0 per mission) | 10 (2.5) |
| rounds at the pilot | 312 | 347 |
| hit rate / damage per round | 41 % / 9.1 | 22 % / 4.8 |
| damage per gunship (median) | 204 | 162 |
| range at first round (median / max) | 58 / 67 m | 40 / 68 m |
| range of all rounds (median / max) | 52 / 76 m | 51 / 77 m |
| height over the pilot's feet (median) | 9.5 m | 9.9 m |
| time from its first round to its last (median) | 38 s | 55 s |
| killed by the bot (median s from its first hit) | 9 of 12, 49 s | 6 of 10, 75 s |
| rounds fired while the bot had no sight of it | 3 % | 2 % |
| most alive on the pilot's deck at once | 2 | 3 (seed 22 deck 2: 714 damage, 2 of its 4 downs) |

### Sniper turret fact sheet (main set)

| | Bulwark | Strider |
|---|---|---|
| snipers firing at the pilot | 7 (1.8 per mission) | 6 (1.5) |
| rounds / hit rate / damage per round | 71 / 35 % / 16.9 | 71 / 11 % / 5.1 |
| range at first round (median / max) | 123 / 170 m | 135 / 162 m |
| range of all rounds (median / max) | 102 / 211 m | 112 / 213 m |
| roof height over the pilot (median) | 15 m | 16 m |
| telegraph | 0.95 s every time (catalog `enemy_lance`, >= 0.3 s rule kept) | same |
| killed by the bot | 2 of 7 (3 s once it engages one) | 3 of 6 |
| rounds while the bot had not seen it | 48 % | 45 % |
| of those, the combat log's ray from the pilot to the sniper was clear | about 3 in 4 | about 3 in 5 (a quarter not in its list) |
| most alive on a deck | 2 | 2 |

Unseen rounds by range (main set, Bulwark / Strider): under 100 m, 81 / 72 % unseen; 100-175 m, 9 / 14 %; beyond 175 m (the PlayerBot's
`SIGHT_RANGE`), 100 %. The sniper is rarely hidden from the pilot (rooftop rule `EnemySpawner.ROOF_SIGHT_*` holds); the
bot does not notice it, mostly when it stands close under the roof.

### The chassis

| | Strider | Bulwark |
|---|---|---|
| hit-sphere area seen from above / side / front (m2, body + hardpoints) | 33.2 / 47.4 / 62.0 | 64.2 / 42.6 / 62.4 |
| width across (approx., from the spheres) | ~7.6 m | ~10.2 m |
| walk / run m/s, strafe, turn | 12 / 22, 1.0, 1.8 | 8 / 14, 0.8, 1.1 |
| core HP torso / legs / head (total) | 400 / 200+200 / 100 (900) | 900 / 420+420 / 150 (1890) |
| weapon hardpoint HP | 80 each | 80 each (`PlayerTarget.WEAPON_HP`, same on every chassis) |
| heat cap / cooling | 100 / 9 | 130 / 12 (+3 radiator) |

Damage per core HP: Bulwark 2669 / 1890 = 1.41 per mission, Strider 1495 / 900 = 1.66. Hardpoints destroyed: Bulwark side
guns lost in 3 of 4 missions (both in 2), first at 84-416 s, with at least one gun down 52 %, 26 %, 5 % of the mission (0 %
on seed 16); the Strider lost one hardpoint in 2 of 4 (54 % and 7 % of the mission). With the three newer-build pairs:
Bulwark 6 of 7 missions, a gun down 31 % of mission time on average (first loss as early as 76 s); Strider 4 of 7, 17 %. The Bulwark's side gun spheres sit
at the hull's front corners (3.57 m out, 3.7 m ahead, r 0.9) and took 8 % of its damage (side_l 516, side_r 349 over four
missions); 80 HP is gone after two sniper rounds or one tank shell's splash plus a burst. A destroyed hardpoint's hits go
to the torso, so the loss is firepower, not survival.

### The director

Enemies alive on the pilot's deck (5 s samples, max / median): 7-18 / 3-14 for the Bulwark, 8-20 / 2-14 for the Strider;
enemies targeting the pilot up to 17-19. The solo `DECK_CAP_BY_CREW` 14 counts "in play" units only (the director's own
rule), so the larger raw counts are garrison plus wave units, not a broken cap. Attack slots hold: `max_attackers` is 1
per pilot (`scripts/mission/mission_combat.gd`); leaving out the drones' beacon telegraphs, only 3 % (Bulwark) / 5 %
(Strider) of enemy telegraphs overlapped another enemy's window, and a gunship and a sniper never telegraphed at the same
pilot at once. Gunships and snipers share the one slot with everything else.

The long sweeps are not unreachable enemies, and not the Bulwark: deck 2 took 256-348 s for the Bulwark. The longest
sweep was the Strider's on seed 16 (684 s): the bot spent 280 s chasing one patrol scout drone (`d2_pat2_02`, hit once)
that holds 72-105 m off (`drone` `min_range` / `preferred_range`), then 120 s on a second drone. Other runs show the same
pattern for 40-100 s (drones, once a gunship for 100 s).

### The bot (for the Engine session; not fixed here)

- Fires the belly gatling at gunships above its +15 deg arc (47 % of its rounds at gunships). `PlayerBot` only waits for
  the barrel to align on high-heat / limited-ammo weapons (`scripts/bots/player_bot.gd`, slot pass ~line 940), so the
  cheap gatling sprays from its parked limit.
- Target choice (`PlayerBot._choose_target`) has no threat term for snipers or gunships: the +12 "turret" bonus matches
  only `enemy_type == "turret"`, not `turret_sniper` / `turret_missile`; a sniper 140 m away scores below near troopers.
- Does not notice snipers that shoot from close above (48 % of sniper rounds came from one it had not seen, with a clear
  line in about 3 of 4 of them).
- Sweep chases after scout drones it cannot catch (above). The mortar never hit a gunship (0 of 17) and hit a drone once in 20.
- Travel: the Bulwark spends 38-45 % of its `[Bot]` lines travelling vs 18-29 % for the Strider (slower, longer
  routes); stuck checks 0-5 per Bulwark mission (0-1 Strider); still 6-16 % of samples.
- Minor log issue (combat log, Missions): `shot` records for the laser always show `hits=0` although `dmg_out` shows its
  hits (beam hits are not paired with their shot key).

### Enemy anti-air (antigravity, 2026-11-26)

Could not be switched off from a test (no flag: `EnemyFlier._air_match_target_alt` is called unconditionally by
`EnemyGunship._step_cover_skim` / `_step_attack_strafe`), so it was isolated from the code and the measured heights. The
gunship climbs only when the target's aim point + 2.5 m is above its own band (attack 8.5-11 m, skim 10.5 m). The
Bulwark's aim point was 5.0-5.5 m above its deck for every gunship round (the bot hops rarely), so the rule returned the
unchanged band every time: no effect on the Bulwark at all. The Strider's aim point (6.9-7.7 m) can lift a gunship at most
~0.9 m in the low half of its bob. The other anti-air parts only reduce enemy fire at airborne / overhead targets (pitch
dead zones, no mortar at airborne targets). The data gives no sign that anti-air made gunships worse for either chassis.

### Defend relays in tight alleys (seeds 1-100, 3 decks, read only)

Every snapped defend relay of the default plan (73 relays on 63 seeds; the default plan has primaries only), free width =
2 x the distance to the nearest obstacle a mech cannot walk through (the site-fit obstacles: building tiers and solids,
pillar cores, park columns, floor cuts + curb, ramps, the walls, the other mission pieces), on a 1 m grid:

| measure | < 9 m | < 12 m | median |
|---|---|---|---|
| width at the relay itself | 27 | 31 | 23.6 m |
| widest spot within 10 m of the relay | 3 | 5 | 40 m |
| widest way out from there to 30 m (bottleneck) | 4 | 5 | 40 m |
| widest disc anywhere inside the 30 m zone | 0 | 0 | 57 m |

The relay itself often stands against a wall (27 of 73 under 9 m): the snap takes the nearest point with a 3.5 m clear
disc (`MissionWorld.ASSET_CLEAR`). Only 5 relays (7 %) have no spot 12 m wide within 10 m of them: seeds 22, 56, 57, 62, 70,
all deck 1 primaries in the same corner of the section (x -96..-101, s -234..-267, a recurring layout); in 6 the area
where the width is at least 9 m covers under a quarter of the zone. Seed 22's relay is the tightest of all (7.5 m at the
relay and within 10 m, 300 m2 of 9 m-wide ground in the zone): that is the "8 m alley". Outcome: both chassis won seed
22's defend (relay at 78 % Bulwark, 71 % Strider); the open relays of seeds 2 and 16 ended lower (65 % / 60-62 %). With 4
defends per chassis no correlation can be claimed either way.

## Proposals (ranked; none applied)

1. **Bulwark hardpoint HP (Mech + Weapons).** `PlayerTarget.WEAPON_HP` 80 is one number for every chassis
   (`scripts/combat/player_target.gd`, Weapons' file; the per-chassis value is the Mech session's call). Give the Bulwark's
   hardpoints its armour too, e.g. 80 x 2.1 = 170 (a `CHASSIS_WEAPON_HP` beside `CHASSIS_COMPONENT_HP`), or move / shrink
   the side gun spheres off the front corners (`CHASSIS_HARDPOINT_SPHERES["bulwark"]`). Expected: fewer and later gun losses (today 6 of 7
   missions, a gun down 31 % of the time vs the Strider's 17 %); how many would survive at a given HP cannot be read from
   these logs (hits on a destroyed gun's sphere are logged as torso), so re-measure with the change. No Strider effect;
   3-4 pilot Bulwarks keep their guns (slightly easier crews). Verify: these bot runs (`hp_first_loss`, share of time
   with a gun down), `tests/test_chassis_body.gd`, `tests/test_net_bulwark_body.gd`.
2. **Bot weapon reach and target choice (Engine).** Don't fire a slot whose mount cannot reach the aim (the belly's +15,
   the side guns' +45, the camera's +31.5); count `turret_sniper` / `turret_missile` / `gunship` as threats in
   `_choose_target`; give up a scout drone outside its range after N s in a sweep (or leave it to the mortar's
   splash / a straggler rule). Expected: fewer wasted gatling rounds (47 % of those at gunships), snipers killed sooner,
   sweeps not held by drones (Strider seed 16: about 400 s). No balance cost. Verify: these runs, `tests/test_bot_obj_sweep.gd`,
   `tests/test_bot_bulwark_mission.gd` (time).
3. **Sweep and scout drones (Missions).** A patrol drone that keeps 72-105 m off holds a sweep open: let the sweep count
   a lone scout drone like defend stragglers (`DEFEND_STRAGGLERS`-style rule in `scripts/mission/pacing/pacing_director.gd`
   / `MissionRules`), or make it close in or leave after a time. Expected: deck 2 sweep times 173-684 s -> no tail over
   ~60 s from drones. Cost: none for crews. Verify: `tests/test_bot_obj_sweep.gd`, these runs (sweep chases).
4. **Elevated shooters versus wide bodies (Missions, only if the user wants the Bulwark to take less, not as a fix).**
   The gap is largest for rooftop turrets (3.3-3.7x per round). Options, cheapest first: aim elevated turrets at the
   target's aim centre with spread scaled to keep the Strider's hit rate (catalog `enemy_lance` / `enemy_bolter` /
   `enemy_rockets` `spread`, `lead_factor` in `scripts/enemy/enemy_catalog.gd`); or nothing, since the 2.1x core HP was
   chosen for exactly this (docs/design/bulwark-effectiveness.md C4: "hit 2.5-5x as often") and the measured result is a
   wash (damage per core HP 1.41 vs 1.66). Snipers are 11 % of the Bulwark's damage, 6 % of the Strider's.
5. **Sniper tell and reach (Missions).** The 0.95 s telegraph keeps the 0.3 s rule, but its only tell is the muzzle
   charge orb (`enemy_telegraph_fx.gd`), small at 100-200 m. A diegetic glint or a short beam from the barrel during the
   lock would read at range (no HUD marker: user rule). Notice range 215 m = the lance's range, past the 175 m a bot
   sees; 12 of 142 sniper rounds came from beyond 175 m, all unseen. Lower `turret_sniper` `notice_range` to ~175 m if the
   user wants snipers to open only inside a normal engagement. Cost: snipers less of a threat for every crew. Verify:
   `tests/test_enemy_*` sniper cases, these runs (unseen rounds by range).
6. **Gunships for a solo crew (Missions).** Gunships are 27-28 % of the damage for BOTH chassis: they are not
   anti-Bulwark. If solo should be easier: at most one gunship alive per solo deck (the Strider's worst deck had three:
   714 damage, 2 downs), via `EnemySpawner._roll_wave_types` (shaft 60 %, heavy 55 %, mixed 22 % gunship) and the garrison
   heavy / medium sites (50 % / 45 %), keyed to the host's crew scale. Or a longer break-off for solo (`_step_breakoff`,
   `burst_cooldown` 3.4 s of `enemy_gunship_rockets`): +30 % cooldown is about -20 % gunship damage, ~-130 per Bulwark
   mission. Cost: 3-4 pilot crews (already "too easy") must keep today's numbers: key everything to the crew scale.
   Verify: these runs, `tests/test_wave_pursuit.gd`, `tests/test_enemy_antiair.gd`.
7. **Defend site width (Environment).** Ask the snap to prefer a relay site with a spot >= 12 m wide within 10 m
   (`SiteFit.snap_fit` / `MissionWorld.ASSET_CLEAR` 3.5 m -> a stand-width test), or raise the relay's clear disc to the
   fit disc (4.1 m) so it never stands in a 7-8 m alley. Moves 5 of 73 relays (all in one deck 1 corner); a section-plan
   fix for that corner may be simpler. Verify: `tests/test_site_fit.gd`, this sweep.
8. **No change needed:** attack slots (one attacker at a time holds; gunship + sniper never together), enemy anti-air.

Pacing targets (`pacing-research.md` 8.2) for the solo veteran bot today: downs 0-4 per mission (target 0-1: Bulwark 1-2,
Strider 0-4), lowest structure under 25 % once in 1 of 8 missions (target: every mission has one). Downs come from
single big hits (tank shells, turret bursts) rather than a slow grind; none of the proposals above changes that much.

## What the data does not support

- That the Bulwark is losing to gunships and snipers in the current build: outcomes, downs and times are no worse than the
  Strider's on the same seeds.
- That anti-air made gunships worse: it never triggers against a Bulwark (shown from the code and the measured heights; no
  A/B was possible without editing the file).
- That a gunship and a sniper double-team a solo pilot: the attack slot keeps them apart.
- That the deck 2 sweep is long because of enemies the Bulwark cannot reach: its sweeps were 256-348 s; the long ones are
  drone chases, and mostly the Strider's.
- That tight relay sites decide defends: both chassis won the tightest one (seed 22).

## Could not measure

- The old symptom itself (950 s timeout, 600 s sweep, 5 deaths on seed 22): not reproduced in this build (many changes
  since: redeploy at full, slot fixes, bays, perception). Its logs were not available.
- Anti-air on / off A/B (no switch, see above).
- Whether the sniper's telegraph is visible to a human at 100-200 m (headless only; needs a look in the game).
- Self-revives (no repair drone in either bot kit) and depot effects on the Bulwark (it took 1 core in 4 missions).
- More than one sample per chassis and seed: the runs are deterministic; variety comes only from more seeds.
- Seed 403112 on the main build for the Strider: the first run loaded a Bulwark because two runs started together and
  shared the bot tests' settings file (`user://test_bulwark_bot_settings.cfg`, `tests/bulwark_bot_case.gd`); worth knowing
  for anyone running bot tests in parallel.

## After bot fixes (Engine sub-agent, 2026-11-27)

Bot-side fixes from "The bot" above, all in `scripts/bots/` (`PlayerBot` reach rules, `MissionBot` sweep), plus test
settings isolation:

1. **Weapon reach.** A pivoting weapon fires only while its mount can bear on the aim point (`WeaponMount.in_aim_range`
   from its pivot: belly +15, side guns +45). Targets nothing the bot carries can reach right now (above every arc or
   past the camera's +31.5 deg; the mortar only reaches ground units) score `UNREACHABLE_PENALTY` lower.
2. **Threats and perception.** `THREAT_BONUS` per type (turret 12, turret_missile 24, turret_sniper 70, gunship 30), +30
   for whoever hit the bot in the last 4 s. Turrets are seen out to `TURRET_SIGHT` 220 m (>= the sniper's 215 m notice
   range); everything else keeps 175 m (220 m for every unit pulled the sweep bot to far enemies: test_bot_obj_sweep
   went over its limit). A turret whose base is hidden behind its parapet counts as seen when its gun (`eye_world`) is in
   sight: a second ray only when the first is blocked, on the same staggered 12 Hz refresh. test_perf passes.
3. **Scout drones.** A drone targeted for 25 s farther than 60 m without losing HP is ignored for 60 s by both layers
   (`PlayerBot.ignoring`), **unless it is the last enemy left on the deck** (a first try without that exception stalled
   the sweep: Bulwark seed 7 timed out at 950 s waiting on the one drone).
4. **Mortar.** Never at air units; never under min_range + 6 m (3D or along the deck) or steeper than 0.6 rise over run.
5. **Settings isolation.** `Boot._isolate_test_settings` adds `_p<OS pid>` to every test's settings file (pruned after
   6 h); `tests/bulwark_bot_case.gd` and `tests/test_bot_bulwark_mixed.gd` write into that file instead of a shared one.

Measured as above (bulwark_bot_case path, veteran, solo, 2x, limit 950, seeds 2 / 7 / 16 / 22, both chassis, 8
processes in parallel, now safe), with a temporary listen-only probe (deleted). The build has moved since the first
measurement (other sessions' edits: Strider seed 16 now loses its defend at 197 s with the old bot), so the table has
the doc's numbers, an A/B on today's build with the fixes off (`PlayerBot.reach_rules = false`, a test-only switch) and
the fixes on. Runs are deterministic (a repeated run matched to the HP).

| sum over seeds 2/7/16/22 | Bulwark doc | Bulwark off | Bulwark on | Strider doc | Strider off | Strider on |
|---|---|---|---|---|---|---|
| outcome | 4 won | 4 won | 4 won | 4 won | 3 won, 16 lost | 4 won |
| time s | 2203 | 2388 | 2235 | 2548 | 1575 (3 won) | 2226 (1528 on 2/7/22) |
| downs | 6 | 4 | 6 | 7 | 3 | 5 (3 on 2/7/22) |
| damage taken | 10675 | 10175 | 10509 | 5981 | 3938 | 4373 (2953 on 2/7/22 vs 3511) |
| belly gatling rounds at gunships out of its arc * | 47 % of 1677 | 65 % of 1356 | 6 % of 681 | - | - | - |
| all rounds at gunships out of arc * | - | 1035 / 1765 | 61 / 1015 | - | 129 / 421 | 42 / 818 |
| hits on gunships (all weapons) | - | 245 | 209 | - | 55 | 96 |
| sniper rounds from one the bot had not seen | 34 / 71 | 36 / 62 | 1 / 34 | 32 / 71 | 22 / 49 | 1 / 16 |
| time targeting a scout drone (s; longest on one) | - | 354 (86) | 303 (109) | ~400 on seed 16 alone | 222 (45) | 325 (72) |
| mortar rounds / at air units / hits | 27 / 15 / 9 | 56 / 16 / 17 | 60 / 0 / 33 | 35 / 22 / 3 | 43 / 17 / 15 | 58 / 0 / 19 |

\* Probe: the round's mount could not bear on the target's core (`WeaponMount.in_aim_range` from the pivot) when fired;
stricter than the first measurement's elevation bands. The few left come from the aim point's drift around the core.

Per mission (fixes on): Bulwark 2 won 573 s, 2 downs, 3842 in; 7 won 554 s, 2, 2435; 16 won 588 s, 1, 2200; 22 won
520 s, 1, 2032. Strider 2 won 425 s, 0, 792; 7 won 536 s, 1, 935; 16 won 699 s, 2, 1420; 22 won 567 s, 2, 1226.

Read: the wasted fire is gone (out-of-arc gatling rounds at gunships 65 % -> 6 %, mortar rounds at aircraft 33 -> 0,
mortar hits up), and the bot sees nearly every sniper that shoots at it (58 unseen rounds -> 2). Outcomes: every
mission won (Strider seed 16 is won again), Bulwark 6 % faster for 3 % more damage and two more downs (seed 7: 0 -> 2),
Strider 3 % faster and 16 % less damage on the three seeds both versions won. It now engages gunships and snipers as
threats, which on some seeds costs damage (Bulwark seed 2: gunship damage 561 -> 1690). The drone time hardly moved:
what is left is a sweep's **last** enemy being a scout drone (Bulwark seed 16: 109 s on one, Strider seed 16: 187 s on
drones), which the bot must kill for the sweep to end. That needs Missions' proposal 3 (a lone scout drone counts like a
defend straggler); the bot side can't fix it without leaving sweeps open. Raw logs: the Engine sub-agent's scratch
`r218_logs/` (v1: the stalled first try; v2_sight220: 220 m sight for every unit).
