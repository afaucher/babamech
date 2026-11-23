# Enemy Troop Squads & Drop Drones

Status: **Phase 1 implemented & verified** (Phase 2 Drop Drones queued next), 2026-11-22.
Parent: [enemies.md](enemies.md), [enemy-tactics-and-drones.md](enemy-tactics-and-drones.md), [ambient-life.md](ambient-life.md), `AGENTS.md`, [../networking.md](../networking.md).

---

## 1. Concept & Fantasy

Mech combat feels best when the city holds threats at **multiple scales**: massive `5–6 m` Siege Tanks & Turrets,
`5 m` Skirmisher walkers, high-altitude Scout Drones — and now **grouped infantry fireteams** using the urban terrain like
soldiers fighting a giant robot:

- **Group together in cover:** 4–5 armored exo-troopers move as a cohesive fireteam, crouching behind building corners,
  street cover, and rooftop parapets rather than standing in the open.
- **Pop up, fire single-shot weapons, duck back:** Troopers briefly lean out or rise over parapets with a readable
  telegraph, loose crisp single-shot anti-armor rounds, and immediately drop back behind cover to reload.
- **Take the high ground:** Squads deploy on rooftops or ascend onto low/mid roofs (`<= 12 m`) with short jump-pack boosts
  to harass players from above — giving players a great reason to jump onto roofs, flush them with Mortar/Rockets/Flamer,
  or counter-snipe them during their peek window.
- **Future reinforcement delivery (Phase 2):** Armored **Drop Drones** fly in when a Scout Drone calls for backup, hover
  over a plaza or rooftop, and deploy a fresh troop squad — unless the crew shoots the carrier down mid-approach.

---

## 2. Scale, Readability & Civilian Contrast

Civilians (`docs/design/ambient-life.md`) are `1.8 m` solo pedestrians in everyday clothes fleeing into doors. Enemy
troopers must read **unmistakably as hostile military units** from `120+ m` away:

- **Silhouette & Scale:** `2.2–2.3 m` bulky armored exo-troopers (broad shoulder pauldrons, visored combat helmet, backpack
  jump-thruster / ammo pack, oversized shoulder-mounted anti-armor tube or long heavy rifle).
- **Palette (`EnemyMeshes`):** Same high-contrast invader obsidian (`#1c1f26`), dark slate (`#333845`), crimson chest
  chevron (`#c21c24`), and **bright unshaded crimson visor + shoulder squad-leader strobe** (`#ff242e`).
- **Tactical Posture:** Always clustered in tight `3.5–6.5 m` military formations kneeling/peeking at cover edges — never
  wandering solo on sidewalks like civilians.
- **Clean Stylized Defeat (No Blood/Gore):** Consistent with `ambient-life.md`, downed troopers pop a small armor-spark
  burst and topple / lie still as dark charred exo-suits (no blood, no ragdolls).

---

## 3. Architecture: Squad-as-One-`EnemyBase` (`EnemyTroopSquad`)

Spawning 4–5 separate `EnemyBase` nodes per fireteam would burn 5× AI ticks, crowd `NetEnemyCodec.MAX_ENTRIES = 32` across
multi-deck stacks, clutter the screen with overlapping health bars, and turn cleanup into pixel-hunting.

Instead, each fireteam is **one `EnemyTroopSquad extends EnemyBase` entity** (`"troop_squad"` / `"troop_roof"`) whose
**`components` are its 4–5 individual troopers** (`"t0"`, `"t1"`, `"t2"`, `"t3"`, optional `"t4"`):

| Benefit | How It Works |
|---|---|
| **Zero `scripts/net/` or `EnemySync` edits** | `NetEnemyCodec` already streams up to `MAX_COMPONENTS = 16` HP bytes per enemy. Every trooper's alive/dead HP (`t0..t4`) replicates automatically in a single 33-byte entry! |
| **Individual sniping + glorious splash wipes** | Each alive trooper owns a positioned hit-sphere (`radius = 1.15 m`, forgiving against an 8 m mech's weapons) at its live cover slot. Precision weapons (Laser, Autocannon, Railgun) pick off peeking troopers individually; explosive/area weapons (`CombatWorld.splash`, Rockets, Mortar, Flamer) hit **every alive trooper within the blast radius**, letting one well-placed rocket wipe a clustered rooftop squad! |
| **Mech stomp / crush** | Walking or landing directly through a ground/rooftop squad with an 8 m mech crushes any trooper within the mech's foot radius (`3.0 m`) — classic mech power fantasy! |
| **One clean HUD read** | A single compact `EnemyStatusBar` hovers above the squad anchor, showing aggregate squad strength (or pips per surviving trooper) with zero clutter. |
| **Clean objective tracking** | The squad is `destroyed()` only when **all** troopers reach `0 HP` (overriding `_on_component_broken` so killing `t0` never insta-kills `t1..t3`). `EnemySync.alive_per_deck` & `MissionRules` work unchanged. |

---

## 4. Troop Variants, Stats & Single-Shot Weapons

### 4.1 Fireteam Types (`EnemyCatalog.CLASSES`)

| Class ID | Size | Troopers | HP / Trooper | Where They Operate | Primary Weapon |
|---|---|---:|---:|---|---|
| `troop_squad` | 4-man Assault Fireteam | 4 (`t0..t3`) | `30 HP` (`120` total) | Street corners, plazas, park cover; can jump-pack onto low roofs (`<= 12 m`) | `enemy_troop_rifle` |
| `troop_roof` | 4-man Rooftop Anti-Armor Team | 4 (`t0..t3`) | `28 HP` (`112` total) | Mid-rise rooftops (`7–16 m`), crouched along street-facing parapets | `enemy_troop_at` |

*(No single critical-kill weak point on a squad — every trooper is already fragile at `28–30 HP`, dying to 1 Laser/Railgun
hit, 1 Autocannon round, 2 Gatling bullets, or 1 nearby Rocket/Mortar splash.)*

### 4.2 Single-Shot Weapons (`EnemyCatalog.WEAPONS`, `scripts/combat/weapons/enemy_troop_*.gd`)

All telegraphs remain strictly `>= 0.3 s` (`AGENTS.md` rule 7) and fire through `CombatWorld.fire` (`"enemy": true`):

| Weapon ID | User | Range | Telegraph | Firing Pattern | Speed | Damage | Splash | Reload |
|---|---|---:|---:|---|---:|---:|---|---:|
| `enemy_troop_rifle` | `troop_squad` | `150 m` | `0.60 s` (pop-up + bright muzzle/optic glint) | **1 single shot per peeking trooper** (up to 2–3 active shooters, `0.14 s` stagger), `1.4°` | `58 m/s` | `15` | — | `3.2 s` |
| `enemy_troop_at` | `troop_roof` | `190 m` | `0.85 s` (pop-up + rocket backblast flash) | **1 single shoulder rocket per peeking trooper** (1–2 active shooters, `0.25 s` stagger), `1.8°` | `38 m/s` | `26` | `12 / 3.8 m` | `4.6 s` |

- **Firepower degrades naturally as you thin the squad:** A full 4-man `troop_squad` fires 3 staggered single shots per
  peek cycle; down to 1 survivor, it only fires 1 shot and tries to fall back to deeper cover.
- **Distinct visual/audio read:** Bright crimson muzzle glints from the parapet/corner during the pop-up telegraph, followed
  by sharp single-shot cracks (rifle) or a whistling shoulder-rocket smoke trail (`troop_roof`).

---

## 5. Cover-Fire, Repositioning & Rooftop Behaviour

All squad tactics run host-only (`not puppet and Net.is_host()`) inside `EnemyBase`'s existing `STATE_FLANK` / `STATE_ENGAGE`
/ `STATE_TELEGRAPH` states (zero `NetEnemyCodec` changes):

### 5.1 Cover Anchor & Trooper Formation Slots
- **Street / Corner Cover (`troop_squad`):** Queries nearby building corners from `EnemySquad.deck_occluders` (`CityPlan`
  building footprints) to pick a corner edge whose back side is occluded from the player's LKP while its peek side has LOS.
  Troopers fan out into 4 deterministic local slots (`2.0–4.5 m` spacing) hugged along the sheltered wall face.
- **Rooftop Parapet Cover (`troop_roof`):** Picks the roof tier edge facing the player's LKP and lines the 4 troopers
  `1.2 m` behind the parapet lip (`2.5–3.5 m` spacing along the edge). Between volleys they crouch (`height ~ 1.1 m`) so
  the building lip / roof edge naturally shields them from street-level flat fire.

### 5.2 Peek -> Single-Shot -> Duck Cycle
1. **`IN_COVER` (`2.6–4.0 s` reload/wait):** Troopers kneel behind the corner or parapet lip. Hit spheres sit at crouched
   height (`+0.9 m`), partially/fully shielded by the wall or roof edge.
2. **`PEEK_TELEGRAPH` (`0.60–0.85 s`, `STATE_TELEGRAPH`):** Once the squad wins an attack slot, 1–3 surviving troopers
   stand/lean `1.4 m` out past the corner or upright above the parapet (`+1.6 m`) with glowing muzzle/visor flares — this
   is the player's clean snipe window!
3. **`VOLLEY` (`STATE_FIRE`):** Each peeking trooper fires **exactly 1 shot** (staggered `0.14–0.25 s` apart, each muzzle
   positioned at that specific trooper's world position!).
4. **`DUCK` (`STATE_COOLDOWN`):** Troopers immediately drop back behind the corner/parapet to reload. If a player hits the
   squad with splash or closes within `28 m`, surviving troopers break cover and sprint (`6.5 m/s`) via
   `EnemySquad.find_cover_path()` to the next occluded corner — or execute a **rooftop jump-pack ascent** onto an adjacent
   standable low roof (`y1 <= 12 m`)!

### 5.3 Rooftop Ascent (Jump-Pack Hop)
- When a street `troop_squad` is alerted near a standable building tier (`roof_h <= 12 m`, `kind != "plant"`, within `14 m`
  of the wall) and has no active cover against a charging mech, it can trigger a coordinated `1.4 s` **Jump-Pack Ascent**:
  troopers rise smoothly up the wall face with small `LowPolyFlame` booster puffs onto the roof ledge, immediately taking
  parapet positions above the player.

---

## 6. Phase 2 — Transport / Drop Drones (`EnemyDropDrone`, Future Extension)

Designed cleanly now so Phase 1's `EnemyTroopSquad` plugs straight into it with zero refactor:

- **Lifecycle hook built in Phase 1:** `EnemyTroopSquad.deploy_from_air(landing_pos, deck)` starts troopers in a `0.8 s`
  fast-drop / jump-pack landing descend pose (`STATE_ALERT`), automatically fanning into the nearest cover/parapet on
  touchdown.
- **`EnemyDropDrone` (Phase 2):**
  - Larger twin-rotor armored dropship (`5.2 m W × 6.8 m L × 2.8 m H`), `140 HP` hull / `55 HP` twin rotor pods weak point.
  - **Trigger:** Called in on the host when a **Scout Drone** completes a beacon pull (or a deck escalation trigger), strictly
    capped at **`1` drop per deck solo (`2` in 3–4p co-op)** and **only while the deck still has living defenders** — so
    `MissionRules` deck-clear objectives can never soft-lock or drag on endlessly.
  - **Flight & Drop Telegraph:** Enters from a deck bulkhead/ceiling shaft edge at `18–22 m` altitude, cruises to a validated
    rooftop or plaza drop zone `45–85 m` from the player, descends to `11 m`, and holds a **`1.5 s` Drop-Bay Telegraph**
    (bright amber drop ring on the roof/street below + loud turbine whine).
  - **Counterplay:** Destroying the Drop Drone before the `1.5 s` bay timer finishes **destroys the carried squad mid-air**
    in a big explosion (`R = 6.5 m`) with zero troopers spawned!
  - **Co-op Sync:** If the drop succeeds, the host spawns 1 `EnemyTroopSquad` via `EnemySquad.add_enemy()` — `EnemySync`'s
    existing `"add"` reliable event automatically spawns the synced puppet squad on every connected client with zero new
    network messages! The empty Drop Drone then climbs to `26 m` and despawns cleanly (`EnemySync` `"gone"` event).

---

## 7. Encounter Placement, Performance & Co-op Budget

- **Encounter Mix (`EnemySpawner.plan_encounters`):**
  - Solo (`crew_size = 1`): replace 1 generic pocket or add 1 `troop_roof` (rooftop parapet team) + 1 `troop_squad` (street
    corner fireteam) on larger decks -> total ~`6–7` squad/unit entries per deck (well inside `NetEnemyCodec.MAX_ENTRIES = 32`
    even across a 3-deck stack!).
  - Co-op (`crew_size = 2..4`): adds an extra `troop_roof` or `troop_squad` to reinforce flanks.
- **CPU & Draw Budget (`tests/test_perf.gd`):**
  - 1 `EnemyTroopSquad` updates 4 troopers via simple local-offset transforms (no per-trooper physics bodies, no per-trooper
    A\* paths — one shared squad path & cover query throttled to `1.2 s`).
  - Expected cost: `< 0.08 ms` per squad per frame, keeping `CombatWorld+AI` well below `4.0 ms`.
- **Tests (`tests/test_enemy_troops.gd`):**
  - Killing 1 trooper reduces shooter count without killing the squad; killing all 4 destroys the squad cleanly.
  - Splash blast (`CombatWorld.splash`) damages all troopers inside radius in one hit.
  - Street squad picks building-corner cover occluded from player, peeks during telegraph, fires 1 shot per peeking trooper,
    and ducks back behind cover during cooldown.
  - Rooftop squad spawns along a standable building edge (`kind != "plant"`), crouches behind parapet, and fires `enemy_troop_at`.
  - Co-op `EnemySync` streams individual trooper HP (`t0..t3`) and hides downed troopers identically on clients; `test_geometry_audit`
    verifies watertight trooper meshes; `test_net_contract` passes.

---

## 8. Confirmed User Decisions (2026-11-22)

1. **Durability & Anti-Cluster Awareness:** **Approved** — 4 troopers at `28–30 HP` each; easy to defeat individually or
   when caught bunched together, AND **troopers actively avoid bunching**: they spread out (`4.0–6.0 m` spacing along cover
   walls/parapets when space allows) and immediately **scatter / widen spacing or jump-pack to a roof** if hit by splash
   or rushed by a mech, so cluster wipes reward catching them in transit or pinning them in tight cover!
2. **Mech Stomp:** **Approved** — walking or landing within `3.0 m` horizontally (`2.5 m` vertically) of an alive trooper
   crushes that trooper instantly under foot (`sparks + crunch + knocked-over charred exo-suit`) and triggers surviving
   squadmates to scatter/jump-pack away.
3. **Scope:** Build **Phase 1 now** (`troop_squad`, `troop_roof`, single-shot cover peeking, anti-cluster spacing/scatter,
   rooftop jump-pack hop, mech stomp, and `deploy_from_air` hook); **Phase 2 (`EnemyDropDrone`)** follows next.

---

## 9. As Built (Phase 1)

- **Weapons & Catalog:** Added `scripts/combat/weapons/enemy_troop_rifle.gd` (`150 m`, `58 m/s`, `15 dmg`, `0.60 s` telegraph) and `scripts/combat/weapons/enemy_troop_at.gd` (`190 m`, `38 m/s`, `26 dmg` + `12 / 3.8 m` splash, `0.85 s` telegraph), registered in `WeaponRegistry.BEHAVIOURS`. Added `troop_squad` (4 × `30 HP`) and `troop_roof` (4 × `28 HP`) to `EnemyCatalog.CLASSES`.
- **Watertight Meshes:** Built `trooper_rifle` and `trooper_at` (`~2.26 m` bulky obsidian/slate exo-troopers with crimson chest chevrons, glowing crimson visors, backpack jump-thrusters, and rifle vs. shoulder AT launcher) in `EnemyMeshes` — both strictly watertight (`0` open edges in `test_geometry_audit`).
- **`EnemyTroopSquad` (`scripts/enemy/enemy_troop_squad.gd`):** Single `EnemyBase` managing `t0..t3` components, dynamic per-trooper `world_spheres()` (`R = 1.15 m`), multi-trooper splash distribution in `apply_hit()`, anti-cluster `4.0–6.0 m` spacing with splash/rush scatter + `1.4 s` jump-pack ascent onto adjacent standable low roofs (`<= 12 m`, `kind != "plant"`), host-only mech stomp (`3.0 m` horiz / `2.5 m` vert), `deploy_from_air(landing_pos, deck)` Phase 2 hook, and zero-wire-change co-op puppet sync (`puppet_aim` + `t0..t3` HP).
- **Spawner, Lab, Audio & Tests:** Wired `troop_squad` & `troop_roof` into `EnemySpawner.plan_encounters()` (6–7 entries per deck solo, keeping 3-deck stacks safely under `NetEnemyCodec.MAX_ENTRIES = 32`), added `"troops"` and `"troops_roof"` to `EnemyLab`, mapped cues in `CombatAudio`, and added `tests/test_enemy_troops.gd`.
