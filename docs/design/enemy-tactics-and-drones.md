# Enemy Tactics, Long-Range Arsenal & Patrol Drones

Status: **implemented** (all 4 phases A–D landed and verified), 2026-11-22.
Parent: [enemies.md](enemies.md), [weapons.md](weapons.md), `AGENTS.md`, [../networking.md](../networking.md).

---

## 1. Problem & Goals

Playtesting and our automated Player AI balance runs (`test_logs/balance/m3_baseline.json`) exposed a clear range and
initiative gap between player mechs and enemies:

1. **Player range advantage:** Players carry `160–250 m` weapons (Laser, Railgun, Autocannon, Missiles, Mortar), while
   today's enemy roster is mostly short/mid-range (`115–160 m`, patrol sight `62–70 m`), letting players snipe pockets from
   safely down the avenue.
2. **Isolated pockets (being addressed in parallel by Weapons):** Weapons' subagent is currently building nearby-fire
   hearing (idle enemies react to player shots passing within `25 m` on arrival, impacts/explosions within `30 m + blast
   radius`, and squadmates being hit). This spec builds directly on top of those hearing hooks — no duplicate hearing code.
3. **No aerial scout / reinforcement pull:** Ground enemies blocked by city blocks have no high-vantage spotter to
   investigate distant gunshots and pull nearby defenders toward an active firefight.
4. **Suicidal open-street closing:** When a short-range mobile unit is alerted at `130–180 m`, it jogs straight down the
   open avenue into player Laser/Railgun fire instead of using side streets and building cover to close distance.

### Architectural & Co-op Constraints (Zero `scripts/net/` or `scripts/game/` Edits Required)
- **Host-owned AI (W4):** All drone flight, beacon alerts, weapon selection, and cover-bounding run strictly on the host
  (`not puppet and Net.is_host()`). Clients receive synced poses, aims, telegraphs, and fire records automatically through
  Engine's existing `EnemySync` (`scripts/game/enemy_sync.gd`) and `NetEnemyCodec` (`scripts/net/net_enemy_codec.gd`).
- **Zero wire-format changes:** `EnemySync._spawn_puppet()` spawns any class listed in `EnemyCatalog.CLASSES` via
  `EnemySpawner.make_enemy(type)`. Cover-bounding stays host-private inside `STATE_FLANK`, and the drone's alert beacon
  rides on `STATE_TELEGRAPH` (`kind = "beacon"`), so `NetEnemyCodec.STATES` and packet layout remain unchanged.
- **Per-deck isolation (W2/W4):** Drones, beacons, and cover paths stay strictly on their own `spawn_deck` (`squad.on_deck`,
  `squad.deck_awake`, `deck_ring(k)`).
- **Hard rules (`AGENTS.md`):** Every new enemy telegraph `>= 0.3 s` (planned `0.50–0.95 s`); every script var declared in
  `net_fields()`; private seeded RNG only (zero global `randf()`/`randi()`).

---

## 2. Patrol / Scout Drones (`EnemyDrone`, `"drone"`)

A lightweight aerial spotter that patrols above avenues and rooftops, investigates distant gunshots, and draws nearby
ground enemies to the fight unless sniped first.

### 2.1 Role, Silhouette & Components
- **Unarmed Recon & Overwatch (User decision, 2026-11-22):** The scout drone **never shoots back** (`primary_weapon = ""`,
  `secondary_weapon = ""`). Its sole job is spotting the player, keeping standoff distance while circling the firefight
  overhead, and pulling reinforcements from around the deck until shot down.
- **Scale:** `2.4 m W × 2.4 m L × 1.6 m H` — compact, readable tri-fin shrouded rotor disc in invader obsidian & crimson
  with a glowing crimson belly optic dome and an angled translucent amber/crimson downward scanner cone.
- **Altitude & Flight:** Cruises `13–17 m` above the deck floor (well below the `40 m` ceiling and high enough to see over
  mid-rise roofs, staying clear of tall building tiers and pillar cores using 2D arc-space repulsion + height lift).
- **Stats (`EnemyCatalog.CLASSES["drone"]`):**
  - `mass_class`: `"light"` (knockable by hits; crisp visual tumble on impact)
  - `move_speed`: `12.5 m/s` (patrol), `flank_speed`: `16.0 m/s` (investigate / standoff retreat / orbit)
  - `preferred_range`: `105 m`, `min_range`: `72 m` (actively backs away if the player pushes closer than `72 m`)
  - `patrol_sight_range`: `115 m`, `sight_range`: `175 m`, `fov_deg`: `160°` (wide belly scanner)
  - `heat_cap`: `40.0`, `cooling`: `6.0`
  - **Components:**
    - `hull` *(core)*: `55 HP`, `1.0×` — crisp 1–2 shot kill with Laser / Railgun / Autocannon / Missiles
    - `optic` *(weak point)*: `28 HP`, `1.5×`, `critical_kill: true` — rewarding 1-shot sniper pop
- **Destruction:** Pops off rotor shroud + optic chunks (`EnemyDebrisField`) and drops a burning charred core onto the
  street/roof below (`ImpactFx`, `R = 3.0 m`).

### 2.2 Investigation, Standoff Orbit & Alert Beacon Behaviour
1. **Patrol:** Cruises a deterministic closed loop along avenues/cross-streets on its `spawn_deck` (`13–15 m` above open
   roads, weaving around pillars).
2. **Investigate gunfire:** Hooks into Weapons' nearby-fire response (plus extended drone hearing radius ~`120 m` for loud
   fire/impacts on its deck). Instead of alerting the whole deck blindly on an unconfirmed sound, the drone flies at
   `16.0 m/s` toward the sound's origin to establish visual LOS first.
3. **Standoff Circle & Reinforcement Beacon (on real LOS contact):**
   - Immediately **opens distance to its standoff band (`90–125 m`, `14–17 m` altitude)** — if the player closes within
     `72 m`, the drone actively backs away while maintaining an angled sightline over the blocks, then **circles the
     firefight area** tangentially at `12–15 m/s`.
   - Triggers a `0.65 s` **Alert Beacon Telegraph** (`STATE_TELEGRAPH`, `kind = "beacon"`, pulsing bright amber-red flare
     ring + distinct rising radar ping audio).
   - **Counterplay window:** Shooting down the drone during that `0.65 s` flare **cancels the pull**, rewarding alert
     players who pick off scouts first!
   - When the beacon completes, it calls `EnemySquad.relay_beacon(pos, target, spawn_deck, 130.0)`, alerting ground enemies
     within `130 m` on that deck and posting a fresh LKP so idle defenders begin converging (using cover-bounding if
     short-range!).
   - While it stays alive in standoff orbit with LOS, it **periodically pulses the beacon every `5.0 s`** (refreshing live
     LKP on the squad board and drawing any newly-in-range defenders on that deck) — never shooting, purely acting as an
     urgent aerial spotter that rewards long-range anti-air fire.

---

## 3. Varied & Long-Range Enemy Weapons & Variants

Expand the enemy arsenal so encounters test **both** long-range counter-sniping and close-quarters cover pressure. All new
weapons live under `scripts/combat/weapons/enemy_*.gd` (one line each in `WeaponRegistry.BEHAVIOURS` + catalog stats in
`EnemyCatalog.WEAPONS`), fire as deterministic scheduled effects (`"enemy": true`), and replicate automatically through
`EnemySync`.

### 3.1 New Enemy Weapons (`EnemyCatalog.WEAPONS`)

| Weapon ID | User | Role & Range | Telegraph | Pattern | Speed | Damage | Splash | Cooldown |
|---|---|---|---:|---|---:|---:|---|---:|
| `enemy_lance` | `turret_sniper` | Long-range marksman bolt (**`215 m`**) | `0.95 s` (`lance` glow + high charge tone) | Single bright high-speed crimson lance, `0.3°` | `115 m/s` | `48` | — | `4.2 s` |
| `enemy_rockets` | `turret_missile` | Long-range area denial (**`190 m`**) | `0.85 s` (`salvo` lock + pod hatch flare) | 3-rocket staggered salvo (`0.22 s`), `2.2°` | `40 m/s` | `22 × 3` | `12 / 4.0 m` | `4.6 s` |
| `enemy_scatter` | `strider_breacher` | Close-quarters ambush (**`68 m`**) | `0.50 s` (`scatter` wide muzzle flash) | 5-pellet horizontal fan (`7.5°` spread) | `56 m/s` | `13 × 5` | — | `2.6 s` |

*(Existing `enemy_bolter` 160 m, `enemy_pulse` 115 m, `enemy_siege_shell` 180 m, and `enemy_mortar` 175 m remain in active
rotation.)*

- **Why these are fair and dodgeable:** Even `enemy_lance` (`115 m/s`) has a loud `0.95 s` telegraph with `lock_share = 0.55`
  — its aim locks `0.43 s` before firing, plus `~1.3 s` flight time at `150 m`, giving a moving player `~1.7 s` to sidestep
  while strongly punishing stationary snipers!
- **HP sanity tweak (informed by M3 scorecard):** Bump `strider.sensor` HP `40 -> 65` (and `strider.chassis` `100 -> 125`)
  so a single `55 dmg` Side Laser pulse no longer 1-shots a Hound Skirmisher in `0.3 s` before its alert delay completes.

### 3.2 Enemy Variants (`EnemyCatalog.CLASSES` & `EnemyMeshes`)

New variants reuse existing base subclasses (`EnemyTurret`, `EnemyStrider`) with distinct silhouette weapon meshes so
players can **read a unit's range and threat on sight**:

| Class ID | Subclass | Distinct Silhouette Read | Alert Sight | Weapon | Tactical Role |
|---|---|---|---:|---|---|
| `turret_sniper` | `EnemyTurret` | Extra-long twin-rail barrel (`5.4 m`) + tall twin-vane sensor mast | `215 m` | `enemy_lance` | Far rooftop anti-sniper overwatch; answers player Railgun/Laser. |
| `turret_missile` | `EnemyTurret` | Twin boxy 3-tube shoulder rocket pods flanking the drum | `195 m` | `enemy_rockets` | Mid/far rooftop volley turret; flushes roof campers. |
| `strider_breacher` | `EnemyStrider` | Broad armored prow + underslung twin-drum scatter cannon | `135 m` | `enemy_scatter` | Aggressive short-range flanker (`68 m` range); showcase for cover-bounding! |
| `drone` | `EnemyDrone` | Hovering tri-fin disc + crimson optic + amber scan cone (`13–17 m` up) | `175 m` | Unarmed + Alert Beacon | Aerial standoff scout & deck reinforcement puller. |

### 3.3 Encounter Mix (`EnemySpawner.plan_encounters`)
- **Solo (`crew_size = 1`, 5–6 units per deck):**
  1. Avenue scout (`strider` or `strider_breacher`, seeded 50/50)
  2. Mid-district rooftop turret (`turret` or `turret_missile`)
  3. Far avenue heavy anchor (`tank`)
  4. Distant park/flank mobile unit (`strider_breacher` or `strider`)
  5. Far flank rooftop overwatch (`turret_sniper` — replaces plain turret on the far perch so long-range sniping is contested!)
  6. **1 Patrol Drone (`drone`)** cruising a mid-to-far avenue loop (`>= 68 m` from player spawn, so never agro on frame 0).
- **Co-op (`crew_size = 2..4`):** Scales cleanly as in M3, adding a 2nd Drone at `crew >= 3` and mixing `turret_missile` /
  `strider_breacher` into reinforcement slots.

---

## 4. Cover-Bounding & Peek-to-Reacquire Tactics (Short-Range Closing AI)

Whenever a mobile ground enemy (`strider`, `strider_breacher`, or `tank` when out of LOS/range) is alerted and its target is
beyond its effective weapon range (`dist > engage_range`), it must **stop running down open fire lanes** and instead advance
under cover.

### 4.1 Trigger & Effective Range
- Each class/weapon defines `engage_range = min(weapon.range * 0.85, preferred_range * 1.45)` (e.g., `~58 m` for
  `strider_breacher`, `~82 m` for `strider`).
- If `ai_state in [STATE_ALERT, STATE_ENGAGE, STATE_FLANK]` and `dist_to_target > engage_range` (or the unit has taken
  player fire from outside its weapon range): enter **Cover-Bound mode** (`_cover_mode = "bound"`, host-only `Net.PRIVATE`
  inside `STATE_FLANK`).

### 4.2 Fast 2D Cover-Weighted Road-Graph A\* (`EnemySquad.find_cover_path`)
Running 3D physics raycasts on every A\* node would blow our `4.0 ms` AI frame budget (`tests/test_perf.gd`). Instead,
`EnemySquad` computes **2D building-footprint occlusion directly from `CityPlan` in arc `(x, s)` space**:
- Pre-cache each deck's building solid `Rect2` list (tiers with `y1 >= 6.0 m` and pillar cores) once in `add_deck_nav()`.
- Helper `EnemySquad.arc_segment_occluded(a: Vector2, b: Vector2, deck: int) -> bool`: tests whether 2D segment `a -> b`
  intersects any tall building footprint rect (fast AABB slab test, microseconds per node!).
- `find_cover_path(from_arc, to_arc, threat_arc, deck)`: runs A\* over the deck's road graph where each candidate node `v`
  gets an exposure penalty:
  - If `not arc_segment_occluded(v, threat_arc, deck)` and `v.distance_to(threat_arc) > engage_range * 0.75`: add
    `EXPOSURE_PENALTY = 48.0 m` to the edge cost (plus `+22.0 m` if the midpoint of edge `u -> v` is also exposed).
  - Result: A\* naturally prefers **side streets, cross-alleys, and building-shadowed flanks** that stay out of the player's
    sightline while still monotonically closing distance!
- Fallback: if no occluded detour exists (e.g., wide open park or flat test arena without buildings), falls back cleanly to
  wide lateral zigzag flanking so units never stall.

### 4.3 Peek-to-Reacquire Cycle
Because the enemy has **no wallhacks** (`AGENTS.md` / fair LKP rules), staying behind buildings indefinitely would let its
target memory go stale. While in Cover-Bound mode:
1. **`BOUND` (`3.2–4.5 s` or until reaching a corner node):** Sprints at `flank_speed` along the cover-weighted path while
   keeping buildings between itself and `_last_seen_pos`.
2. **`PEEK` (`0.75–1.0 s`):** Once `_cover_peek_timer` expires (and `_no_los_time >= 2.5 s`), the enemy steps laterally
   `3.5–5.5 m` toward the nearest open sightline edge (a nearby road-graph intersection or lateral clear ray) and rotates its
   sensor toward `_last_seen_pos`.
   - The instant real physics LOS reacquires the player, it refreshes `_last_seen_pos`, updates `EnemySquad.known_targets`,
     and **immediately snaps back to `BOUND`** (recomputing a fresh cover-weighted path to the player's new position) — so it
     never lingers exposed!
   - If the player isn't there after `1.0 s`, it returns to `BOUND` advancing toward the last known sector.
3. **`AMBUSH / ENGAGE`:** As soon as `dist_to_target <= engage_range * 0.95` (and LOS is available), exits Cover-Bound mode
   into `STATE_ENGAGE`, grabbing an attack slot to unleash its close-range burst!

---

## 5. Audio, Visuals & Performance Hooks

- **Audio (`scripts/audio/`):**
  - Emit existing `enemy_event("telegraph_started", ..., {"kind": "beacon" | "lance" | "salvo" | "scatter"})` so
    `CombatAudio` can map distinct cues (rising radar ping for drone beacon, sharp high-pitch rail charge for `enemy_lance`,
    rapid pod clack for `enemy_rockets`, heavy scatter thump for `enemy_scatter`) with zero new signal contracts.
- **Visuals (`EnemyMeshes` / `EnemyTelegraphFx`):**
  - Add cached `ArrayMesh` parts in `EnemyMeshes`: `drone_hull`, `drone_optic`, `drone_cone`, `turret_sniper_gun`,
    `turret_missile_gun`, `strider_breacher_chassis` (all watertight, audited by `tests/test_geometry_audit.gd`).
  - Add subtle amber-crimson beacon pulse ring on `EnemyDrone` when telegraphing `"beacon"` so the pull is unmistakably
    readable from `120 m` away.
- **Performance:**
  - 2D `CityPlan` footprint occlusion in `find_cover_path` is recalculated at most once every `1.2 s` per bounding enemy
    (throttled), keeping `CombatWorld+AI` well below the `4.0 ms` frame budget in `tests/test_perf.gd`.

---

## 6. Build Order & Verification Plan (Starts After Weapons Lands Nearby-Fire)

1. **Phase A — New Enemy Weapons & Variants:**
   - Create `scripts/combat/weapons/enemy_{lance,rockets,scatter}.gd`, register in `WeaponRegistry.BEHAVIOURS`,
     add stats + `turret_sniper`, `turret_missile`, `strider_breacher`, `drone` to `EnemyCatalog`, add watertight meshes to
     `EnemyMeshes`.
2. **Phase B — Patrol Drone (`scripts/enemy/enemy_drone.gd`) + Beacon Relay:**
   - Implement hovering curved-deck flight, gunfire investigation (hooking directly into Weapons' landed hearing callback),
     interruptible `0.65 s` Alert Beacon, `EnemySquad.relay_beacon()`, and downward crash debris on kill.
   - Wire into `EnemySpawner` and `EnemyLab` presets (`"drone"`, `"long_range"`, `"breacher_cover"`).
3. **Phase C — Cover-Bounding & Peek-to-Reacquire (`enemy_squad.gd`, `enemy_base.gd`, `enemy_strider.gd`):**
   - Implement `arc_segment_occluded()` + `find_cover_path()` + `BOUND` / `PEEK` cycle for short-range mobile enemies.
4. **Phase D — Tests & Automated Balance Diff:**
   - New `tests/test_enemy_tactics.gd`:
     - Drone investigates gunfire, pops `0.65 s` beacon, and pulls a ground unit `90 m` away on the same deck (and killing
       the drone before `0.65 s` cancels the pull; zero AI on client puppets).
     - `turret_sniper` engages a target at `180 m` with `>= 0.95 s` telegraph.
     - `strider_breacher` alerted at `130 m` chooses an occluded side-street route (lower LOS-exposure ratio than straight-line
       avenue) and performs periodic peeks to refresh LKP before closing into `68 m`.
     - Co-op `EnemySync` manifest/puppet round-trip spawns `drone`, `turret_sniper`, `turret_missile`, and `strider_breacher`
       cleanly with valid hit spheres and replicated fire records.
   - Run `.\test_runner.ps1 -TestAll` (including `test_geometry_audit`, `test_net_contract`, `test_perf`, `test_net_enemy`).
   - Run `.\tools\balance\run_balance.ps1 -Suite quick -Baseline test_logs\balance\m3_baseline.json` and `-Suite coop
     -Baseline test_logs\balance\m3_coop_baseline.json` to measure the exact balance impact!

---

## 7. As Built Notes

- **Phase A (Weapons & Variants):** Added `scripts/combat/weapons/enemy_{lance,rockets,scatter}.gd` registered in `WeaponRegistry.BEHAVIOURS`, catalog entries for `turret_sniper`, `turret_missile`, `strider_breacher`, and `drone` (plus `strider` HP bump `chassis 125 / sensor 65`) in `EnemyCatalog`, and 6 strictly watertight `EnemyMeshes` parts (`turret_sniper_gun`, `turret_missile_gun`, `strider_breacher_chassis`, `drone_hull`, `drone_optic`, `drone_cone` — 0 open edges in `test_geometry_audit`). Multi-pellet horizontal fan (`enemy_scatter`, 5 pellets over `7.5°`) fires deterministic scheduled records in `EnemyBase._fire_one_round`.
- **Phase B (Patrol Drone & Beacon Relay):** Added `scripts/enemy/enemy_drone.gd` (`EnemyDrone`, unarmed, `13–17.5 m` hover altitude, `120 m` extended hearing in `EnemySquad` without premature ground relay, `90–125 m` standoff orbit with `< 72 m` retreat, interruptible `0.65 s` `beacon` telegraph pulsing `EnemySquad.relay_beacon(..., 130 m)` every `5.0 s`). Fixed `EnemyBase._kill()` to emit `telegraph_cancelled` before switching `ai_state = STATE_DEAD` so mid-beacon snipes cleanly cancel audio/UI telegraphs. Wired into `EnemySpawner.plan_encounters()` (5–6 solo units + 1 Drone; 2nd Drone at `crew >= 3`) and `EnemyLab` (`"drone"`, `"long_range"`, `"breacher_cover"`).
- **Phase C (Cover-Bounding & Peek-to-Reacquire):** Cached per-deck 2D tall building & pillar occluders (`y1 >= 6 m`) in `EnemySquad`, with `arc_segment_occluded()` and `find_cover_path()` (`COVER_EXPOSURE_PENALTY = 140 m`, `COVER_MID_EXPOSURE_PENALTY = 70 m`, tuned above `CityPlan`'s ~65 m parallel street spacing, plus corner-building prepend guard so units never clip block corners). Implemented throttled (`1.2 s`) `BOUND` -> `PEEK` cycle in `EnemyBase` with instant snap-back to `BOUND` on real physics LOS reacquisition.
- **Phase D (Audio & Verification):** Mapped new weapon/telegraph cues (`lance`, `salvo`, `scatter`, `beacon`) in `CombatAudio` reusing existing `SoundBank` cues, added `tests/test_enemy_tactics.gd`, updated `test_geometry_audit`, `test_enemy_combat`, `test_enemy_ai`, `test_enemy_effectiveness`, and `net_enemy_case` (zero `scripts/net/` or `scripts/game/` edits).
