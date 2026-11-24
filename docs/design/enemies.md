# Enemies

Status: **approved design**, 2026-11-22. Parent: [game-design.md](game-design.md) §2, §6, §7; slice milestone S6 in
[vertical-slice.md](vertical-slice.md); weapons in [weapons.md](weapons.md). Net rules: `AGENTS.md`, [../networking.md](../networking.md).

## 1. Roster & Combat Roles

Hijacked civil-defense robots, emplacements, and armored vehicles repainted in invader dark obsidian & crimson livery:

| Class | ID | Archetype | Mass Class (`Combat.MASS`) | Role in Vertical City Combat |
|---|---|---|---|---|
| **Enforcer Turret** | `turret` | Static fortified gun emplacement | `static` (0× knockback, **aim kick** Δv × 3°) | Rooftop & chokepoint overwatch (S6 anchor). Forces cover, roof flanking, aim-kick suppression (1 Side Laser kicks aim off by 24°), or indirect Back Mortar strikes. |
| **Hound Skirmisher** | `strider` | Light mobile bipedal patrol walker | `light` (×1.0 knockback) | Street/park patrol, flanker, spotter, and **knockback / roof-shove / wall-slam showcase**. Relays sightings to the squad after 0.45 s. |
| **Bastion Siege Tank** | `tank` | Heavy armored tracked assault vehicle | `heavy` (×0.25 knockback) | Avenue anchor & verticality puzzle. Slow, heavy, dodgeable siege cannon + cover-flushing arc mortar. Exposes glowing rear/top radiator **`vents`** weak point to reward rooftop jumping and flanking. |

**Armour** (`EnemyCatalog` `"armored": true`, weapons.md §3.10: flak does × 0.35): `turret`, `turret_sniper`, `turret_missile`, `strider`, `strider_breacher`, `tank`; not `drone`, `gunship`, `dropship`, `trooper_rifle`, `trooper_at`.

## 2. Scale, Silhouettes & Contrast

Measured against the **8.0 m** player mech, **5.6 m** street trees, **12 m** streets, **20 m** avenues, and **40 m** ceiling:

- **Enforcer Turret (`turret`):** `4.8 m W × 4.8 m D × 5.6 m H`. Octagonal armored plinth, rotating drum turret, twin heavy blaster barrels extending 3.8 m, crimson optic mast rising to 5.6 m.
- **Hound Skirmisher (`strider`):** `3.8 m W × 4.2 m L × 5.2 m H`. Wide reverse-jointed dark legs, hunched forward angular chassis, underslung rapid carbine, twin antenna fins, bright crimson visor slit.
- **Bastion Siege Tank (`tank`):** `6.8 m W × 9.6 m L × 5.4 m H`. Twin wide armored tread sponsons, sloped glacis with crimson chevrons, flat angular turret with 6.4 m siege cannon, raised glowing rear/top radiator vent deck (`y = 2.6..3.4 m`).

**Palette (`EnemyMeshes`):** high-contrast cool obsidian (`#1c1f26`), slate armor (`#333845`), gunmetal steel (`#525761`), invader crimson trim (`#c21c24`), unshaded crimson optic glow (`#ff242e`, flaring white-amber on telegraph), and orange-crimson vent glow (`#ff661a`) — popping sharply against the warm sunlit cream/terracotta/sage `CityPalette` and the white/orange player mech.

**Feedback (no floating ASCII text walls):**
- Compact world-space `EnemyStatusBar`: distance-scaled crimson chevron when alerted (flashes hot yellow-white while telegraphing), thin red HP bar + amber heat sliver once alerted/damaged, 1-word status tag only during `STAGGER` or `OVERHEAT`.
- Diegetic cues: `0.07 s` hit-flash overlay per struck component, part destruction sparks & charred stub swap, overheat droop + vents/smoke, scaled `ImpactFx` death explosion.

## 3. Components, Weak Points, Heat & TTK

Core component is always the first key in `max_hp`. Killing either the core component or a critical weak point immediately destroys the unit (`_dead = true`, `destroyed() == true`, remaining HP zeroed).

| Unit | Heat (Cap / Cool) | Component | HP | Mult | On 0 HP |
|---|---|---|---:|---:|---|
| `turret` | `60 / 4.0` | `base` *(core)* | 120 | 1.0× | Destroyed (`R = 4.5 m`) |
| | | `gun` *(weak point)* | 70 | 1.25× | Critical kill (gun head pops → detonation) |
| `strider` | `50 / 5.0` | `chassis` *(core)* | 95 | 1.0× | Destroyed (`R = 3.5 m`) |
| | | `legs` | 55 | 1.0× | Cripples speed to 25%, 1.5 s stagger; 60% overflow to `chassis` |
| | | `sensor` *(weak point)* | 45 | 1.5× | Critical kill (instant sensor blowout) |
| `tank` | `100 / 4.0` | `hull` *(core)* | 280 | 1.0× | Destroyed (`R = 6.5 m` + column) |
| | | `turret` | 130 | 1.0× | Destroys main cannon, deals 100 shock dmg to `hull` |
| | | `vents` *(weak point)* | 80 | 1.75× (+1.5× heat) | Reactor meltdown kill |

## 4. Enemy Weapons & Telegraphs (Hard Floor ≥ 0.3 s)

Stored in `EnemyCatalog.WEAPONS` (separate from player `MechCatalog.WEAPONS`; `CombatWorld.stats()` falls back to `EnemyCatalog`). Fired through `CombatWorld.fire(record)` as deterministic scheduled effects with `"enemy": true` and `"team": "enemy"`.

| Weapon ID | User | Telegraph | Pattern | Speed | Size (× Growth) | Damage | Splash | Δv | Self Heat | Cooldown |
|---|---|---|---|---:|---|---:|---|---:|---:|---:|
| `enemy_bolter` | Turret | 0.55 s | 3-shot burst (0.18 s), 1.2° | 48 m/s | 0.65 m (×2.5) | 14 | — | 1.5 | 10 | 2.4 s |
| `enemy_pulse` | Skirmisher | 0.45 s | 4-shot burst (0.12 s), 2.0° | 58 m/s | 0.50 m (×2.8) | 7 | — | 0.6 | 8 | 2.0 s |
| `enemy_siege_shell` | Tank (LOS) | 0.90 s | Single heavy shell | 42 m/s | 1.00 m (×2.5) | 38 | 22 / 6.0 m | 6.0 | 22 | 3.6 s |
| `enemy_mortar` | Tank (No LOS > 2.5 s) | 0.60 s + ≥ 2.4 s arc | Single arcing shell + closing ground ring | ballistic | 0.80 m (×3.0) | 30 | 20 / 6.5 m | 3.5 (+2.5 lift) | 24 | 5.5 s |

## 5. AI, Squad Coordination & Curved-Deck Navigation

- **Host-owned (`owner_peer = 0`):** AI, movement, and squad coordination run only when `CombatWorld.owns(enemy)`.
- **Curved-deck movement:** Macro pathfinding runs A\* over `CityPlan.road_graph()` (plus open park/plaza nodes) in 2D arc `(x, s)` space; local steering adds sibling separation and 3-ray obstacle avoidance, then projects back onto `RingFrame` with radial `up_at(pos)` and downward ground snapping. Knockback updates `up` and `ground_y` dynamically so rooftop enemies shoved past a ledge fall to the street.
- **Shared target board (`EnemySquad`):** Fed only by real physics LOS checks (or damage alerts). Sightings propagate to squadmates within 90 m after a `0.45 s` comm relay delay (killing the spotter first cancels the relay).
- **Hears fire (`EnemySquad` hearing, `EnemyBase.hear_fire`):** an un-alerted enemy with live AI reacts to PLAYER fire near it (enemy fire never alerts enemies): a shot whose path (origin to aim point, clamped to the weapon's range) passes within `HEAR_SHOT_RADIUS` = 25 m of its eye (`CombatWorld.fired`; a slow shot is heard when it reaches the closest point, at the weapon's speed; hitscan at once; the lobbed mortar only at its muzzle), an impact or blast within `HEAR_IMPACT_RADIUS` = 30 m + its splash radius (`CombatWorld.impact_from`), or a player hit on a squadmate within 30 m of the hit point (`hit_landed`, also when the hit kills it). It alerts toward the shooter with the normal `ALERT_DELAY` (0.35 s) wind-up as a spotter ("spotted"), puts the shooter's position on the board as the heard position (so it turns / searches toward it without line of sight) and runs its own 0.45 s relay. Sound passes walls. Stack: only stimuli on its own deck, never while the deck sleeps. Host / solo only (a client's enemies are puppets); no network messages: the alert reaches clients through EnemySync. Killing a spotter still cuts its 52 m relay; only squadmates within hearing of the kill learn of it.
- **Attack slots:** At most `max_attackers` (default 2) enemies may telegraph/fire at the same player target simultaneously, prioritized by unit weight and rotated fairly.
- **Last-enemy hunt, reveal & safety valve (`EnemySquad`, host-only):** Never triggers while more than `HUNT_MAX_REMAINING = 3` enemies remain on a deck (counting both living enemies and queued/pending wave units on that deck), and never before the crew has had real combat contact on that deck (`_deck_engaged`). Once `<= 3` remain after contact and the deck stays quiet for `HUNT_QUIET_S = 75.0 s`, Step 1 pushes mobile stragglers into active hunt pursuit; if any straggler still has not engaged after a further `REVEAL_HUNT_DELAY_S = 50.0 s`, Step 2 marks `EnemyBase.revealed = true` (synced via `EnemySync` `"alert"` / `"revealed"` to Engine's HUD markers); `CULL_IDLE_S = 120.0 s` after reveal with zero damage dealt or taken, Step 3 culls unreachable stragglers cleanly (`"timeout"`).

## 6. Audio Integration Contract

- `EnemyBase` joins group `"enemies"`; `EnemySquad` joins group `"enemy_squad"`; `PlayerTarget` joins group `"player_target"`.
- `EnemySquad` emits `enemy_event(kind: String, enemy: Node, payload: Dictionary)` forwarding:
  `telegraph_started`, `telegraph_cancelled`, `alerted`, `weapon_fired`, `component_damaged`, `component_destroyed`, `overheated`, `rebooted`, `destroyed`, `footstep`.
- `CombatWorld` emits `impact_spawned(point: Vector3, radius: float, explosive: bool, is_energy: bool)` inside `spawn_impact()`.

## 7. Art Direction (in progress, 2026-11-22)

Enemy art pass, every choice from a 3x3 grid (`art/renders/enemy_concept_r*/`, `art/renders/enemy_colour_r*/`; in-engine
colour probe `tools/enemy_style/`).
- **Concept: "Repainted civic"** (concept r1 #1; user decision after exploring r1 #2 control crown, r2 crown variants, r3
  subtle violet body beacon, r4 heraldic corruption): the units are the habitat's own civil-defence robots, simply
  repainted in the invaders' livery: no alien grafts. The occupation shows in the city through **alien banners in the same
  colours**: one livery shared by banners and units. Rounds r2-r4 kept in `art/renders/enemy_concept_r2..r4/` for later
  (e.g. elite markers).
- **Colour: picked L1 = A2 "slate / brick"** (livery r2, `art/renders/enemy_colour_r2/`): warm slate grey body `#6b6a6c`, plates `#807d7c`, steel `#939089`,
  brick-red trim `#a2453a`, red optics `#ff4a36`, vents `#ff8a3a`. Mid value: findable against the warm city without
  popping like the black/red placeholder.
- **Banner: picked #9 "Descent"** (`art/renders/banner_r1/grid_banner_r1.png`): swallowtail banner, bold downward
  arrowhead with three trailing bars ("they arrived from above"), two tones + border. Same emblem for unit stencils later.
  Emblem as in the concept (`art/renders/banner_r1/b9_descent_s4242.png`): one broad arrowhead pointing diagonally
  down-left with a thin slit, three parallel bars trailing to the upper right.
- **Banner colouring: picked F2c3** (livery r3, `art/renders/enemy_colour_r3/`): dark slate field `#3e3c3e`, brick arrow
  `#a2453a`, cream bars + border `#e8dcc0`. Reads on brick, sage and cream facades and matches the slate / brick units.
- **Banner build: approved by the user** (reference, probe placeholder in `tools/enemy_style/enemy_style_probe.gd`): 4.0 m wide x 6.4 m tall
  to the swallowtail points (about 1.6:1), cream border, emblem scaled 0.85 and centred (~0.55 m clear of the border),
  bars drawn behind the arrowhead, slit on top. Shot: `art/renders/enemy_colour_r3/F2c3_banner_close.png`. Banners are
  built as a game prop on 2026-11-23: `scripts/world/occupation/`, spec `docs/design/banners.md`.
- **Applied (2026-11-22):** L1 palette + civic detail pass on every `EnemyMeshes` part (Descent stencils with slate backing
  plates on brick faces, hazard bands, number plates, amber service lamps / light bars, headlights, hatches, antenna whips,
  wreck debris); consts SLATE `#4a4a4e`, CIVIC_CREAM `#d8ccb0`, LAMP_AMBER `#c08a44`. Before / after:
  `art/renders/enemy_detail_r1/grid_before_after.png`. §2's "obsidian & crimson" palette text is superseded by this.
- **Detail pass B: adopted for ALL parts** (user, 2026-11-22; review `docs/design/enemy-detail/`, same method as the mech's
  body / legs / weapons reviews). Plus final models for antigravity's `gunship` and `dropship` (part contracts on thread
  `babamech-20261122-2000-enemy-art`), built to the same B level in the L1 livery.
- **Trooper looks (2026-11-22):** 12 seeded variants per kit (rifle / AT): build slim / standard / heavy, helmet dome /
  crest / flat-top, gear jump pack / radio + whip / pouch belt, chest mark, small L1 tint shifts; leaders (n 0, 4, 8) carry
  cream marks. `EnemyMeshes.trooper_part(kit, look_seed)`; grid `docs/design/enemy-detail/trooper_variants_grid.png`.
  Distinct at ~20 m, a group at ~40 m; user kept them as is (no extra per-trooper colour).
