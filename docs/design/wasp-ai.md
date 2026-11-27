# Wasp AI & Enemy Anti-Air Design

Companion to `docs/design/chassis-rules.md` (§7.2 Hover / Wasp) and `docs/design/player-ai.md`.
Covers two halves:
1. **Enemy Anti-Air (`scripts/enemy/`)** — how enemies aim at, lead, reposition against, and duel an airborne player (Wasp, or jump-jetting Strider/Bulwark). Zero dependency on Wasp's hover controller; built now.
2. **Wasp Player Bot AI (`scripts/ai/`, `scripts/game/bot_route_planner.gd`, `mission_bot.gd`)** — 3D hover navigation, altitude choice, and pre-overheat landing onto mini-legs, plus the minimal controller contract agreed with Mech (`docs/design/wasp-hover.md`).

---

## 1. Enemy Anti-Air (Built in `scripts/enemy/`)

### 1.1 3D Velocity Lead (`EnemyBase._lead_aim_point`)
- Previously `_lead_aim_point` projected `_target_vel` onto the floor plane (`flat_v`), ignoring climb/dive velocity.
- **New rule:** Direct-fire weapons (`kind != "arc"`) include damped vertical lead (`flat_v + up * (_target_vel.dot(up) * 0.65)`), capped by `MAX_LEAD_TIME * lead_factor`. Arc mortars (`kind == "arc"`) keep floor-plane lead.

### 1.2 Pitch Elevation Limits & Overhead Dead-Zone Back-Off
Every ground unit has a realistic upper elevation limit (`_max_aim_pitch()`):
- **Tank (`EnemyTank`):** `+32°` — heavy low-slung turret cannot fire straight up.
- **Strider (`EnemyStrider`):** `+52°` — torso-mounted weapons track high, but have an overhead cone.
- **Turret (`EnemyTurret`):** `+62°` (raised from `+45°` so static defenses threaten fliers cleanly; `_track_aim` returns error against the unclamped elevation so hovering inside the overhead cone prevents firing straight through the gun housing).
- **Trooper (`EnemyTrooper`):** `+70°` — infantry shoulder arms aim steeply upward.

**Counterplay:**
- If a target is above `_max_aim_pitch()`, `_choose_weapon` rejects primary fire (no shooting straight up through hulls).
- Mobile ground units (`tank`, `strider`) in `_step_engage_movement` detect when an airborne target is inside their overhead dead zone (`elev > _max_aim_pitch() - 5°`) and **back away** to open horizontal range until the target drops back into their firing arc.

### 1.3 Weapon & Behaviour Rules vs. Airborne Targets
- **No wasted mortars:** `_choose_weapon` skips `enemy_mortar` when the target is hovering high above the deck (`> 10 m` deck height or `> 8 m` above the shooter's eye).
- **No false trooper stomp/rush panic:** `EnemyTrooper` skips `RUSH_PANIC_DIST` ground scatter/jump-pack when the target is `> 8 m` vertically overhead (a hovering Wasp isn't about to crush infantry underfoot).

### 1.4 Air-to-Air Altitude Matching (`EnemyGunship`)
- Gunships are the natural counter to a hovering Wasp.
- During `_step_attack_strafe` and `_step_cover_skim`, Gunships read the target's deck height (`ring.height(target_pos)`): when the target hovers above the normal street-skim band (`ALT_ATTACK_HIGH = 11 m`), the Gunship climbs smoothly to `clampf(target_alt + 2.5, ALT_ATTACK_LOW, CEILING_CAP)` (up to `32 m`) to duel at altitude rather than strafing 15 m below it.

---

## 2. Wasp Player Bot AI (Planned — Awaits User Approval & Mech's Hover Controller)

### 2.1 Minimal Controller Contract (Aligned with Mech's `docs/design/wasp-hover.md`)
So `PlayerBot`, `MissionBot`, and `BotRoutePlanner` stay chassis-agnostic (matching `chassis-rules.md` §7.3), Wasp's controller (`MechController` hover mode or dedicated hover controller) exposes:
- **Catalog flag:** `MechCatalog.chassis(id)["move"] == "hover"` (already in `chassis-rules.md` §1.1).
- **Inputs (written by human or `PlayerBot`):**
  - Existing `move_input: Vector2` (strafe/forward), `aim_yaw`, `running` (sprint/boost).
  - `climb_input: float` in `[-1.0, 1.0]` (`+1` climb / Space, `-1` descend / Ctrl, `0` hold altitude).
- **Read-only state (read by `PlayerBot` / `MissionBot`):**
  - `grounded: bool` (true when landed on mini-legs).
  - `altitude() -> float` (m above the ground/roof directly under the Wasp).
  - `headroom() -> float` (m of free air above the Wasp, up to the slab of the deck above or the roof of an opening — **no artificial altitude cap**).
  - `can_fly() -> bool` (true when **both** fans are alive and not in heat shutdown).
  - `working_fans() -> int` (`0..2`, mapped onto the existing `leg_l` / `leg_r` component slots on the wire; hardpoints reuse `side_l` / `side_r` / `belly`).

### 2.2 3D Hover Navigation (`BotRoutePlanner` + `BotNavigator` + `HoverRoute`)
- **Same-deck travel:** Direct over-roof flight (`HoverRoute.clear_altitude` against `CityPlan` tiers, keeping safe headroom below the deck slab above), routing laterally only around full-height pillars/towers that reach the slab.
- **Cross-deck transit (first-class route):** With no artificial altitude cap, two-way vertical flight through `SectionPlan` ceiling openings and shafts (`HoverRoute` `shaft_up` / `shaft_down`) is the primary way to change decks, with ramps (`ramp_fly`) as backup.
- **Objective zones:** Descend into flag/defend/depot/extraction cylinders as required (hovering low inside the cylinder height so capture/resupply triggers).

### 2.3 Altitude Choice, Pre-Overheat Landing & Fan Loss (`PlayerBot`)
- **Combat altitude band:** Cruise at `10–18 m` with comfortable `headroom()` below the deck slab above (above ground clutter and tank elevation caps), dipping behind rooftop cover when under sniper/lance/gunship fire.
- **Pre-overheat safe landing (critical — no automatic landing burn):** When `heat_fraction >= 0.78` (or a high-heat burst is queued) and `altitude() > 6.0 m`, smoothly command `climb_input = -1.0` toward `HoverRoute.safe_landing_spot()` (nearest clear street or flat standable roof) before heat shutdown cuts the fans and unfolds the mini-legs — avoiding hard-landing fall damage.
- **Fan loss (`working_fans() < 2`):** Losing either fan downs the Wasp under the existing `DownedRules` (same as a walker losing a leg: no movement, no weapons, no damage taken; revived by a repair drone or by redeploying). No grounded-turret fallback mode is needed; `can_fly() == false` simply commands `0 m` altitude while downed/shut down.
