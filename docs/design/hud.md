# Mech HUD

Picked 2026-11-21 from `hud/grid_hud_r1.png` (rows: layout, columns: style): **9, minimal corners / holographic**:
thin cyan and white lines on translucent glass, corner brackets. Reference render `hud/hud_corners_holo_s7.png`
(flux3_klein_t2i, seed 7; regenerate with `hud/hud_r1.ps1`). The renders set layout and mood only.

## Layout
- **Bottom-left: mech status.** The chassis drawn front-on (head, torso, both reverse-jointed legs, a box per mounted
  weapon at its hardpoint), each part tinted by health: cyan > 2/3, amber > 1/3, red, grey crossed out = destroyed.
  Around it a 270-degree **heat arc** (cyan, amber past 60 %, red past 85 %; blinks red while shut down), `HEAT n%` and
  `heat / cap` under it, and the mech state above that: THRUST, EMERGENCY BURN, SHUTDOWN, REBOOTING.
- **Bottom-right: weapons.** One row per hardpoint, numbered 1-5 like the keys. A filled key box = enabled, an outline
  and the whole row dimmed = disabled. Name, mount (L SIDE, R SHLDR, BACK...), ammo (`34/60`, `INF` for heat-limited,
  red at 0), a ready bar (cooldown / reload / charge; amber while a salvo weapon reloads), `+n HEAT` per shot, and one
  flag, the most important first: OFFLINE (no behaviour yet), RELOAD, the hold reason (MIN RANGE), NO LOS, RANGE, LOCK
  (designating). Empty hardpoints show `-- empty --`.
- **Centre: aim.** A screen-centre reticle, the true aim point as a ring (green while the designator is on), and from
  each enabled weapon's muzzle a line of four pips toward the aim point, lit by that weapon's ready fraction, amber with
  an X near the aim point when its line of sight is blocked.
- The test drive's help line moved to the top centre (the bottom corners are the HUD's).

## Crew panel
Picked 2026-11-22 from `hud/grid_hud_crew_r1.png` (rows: placement, columns: portrait): **9, corner / both**. One card
per **teammate** (never yourself; up to 3), stacked straight above the own status panel in the bottom-left corner so
the corner reads as one column of crew status, same holo glass and corner brackets as the rest of the HUD. A small
`CREW` header sits on top of the column. Each card:
- a thin **accent stripe** on its left edge (`MechAccent.color(entry.accent)`), the colour of that teammate's mech;
- the **portrait**: the teammate's low-poly pilot head (`PilotHead.make(head)`) in a hexagon frame, rendered once per
  head id into a 96x96 transparent SubViewport (own world, its own lights; updates a quarter second, then stops);
- a tiny square **Steam avatar** badge on the hexagon's lower right corner (`SteamAvatar.request(steam_id)` in
  `scripts/net/steam_avatar.gd`: small friend avatar, cached, async via `avatar_image_loaded`); hidden when there is
  none (ENet, offline, steam_id 0, still downloading);
- the **name** and the health percentage, a **health bar** (cyan > 2/3, amber > 1/3, red), a thin **heat bar** under it
  (amber while overheated or past 85 %);
- the **status line**: HEALTHY (cyan dot), OVERHEATED (amber warning triangle), NEEDS REVIVE (red crossed circle, the
  portrait dimmed, the hexagon edged red, and a red **countdown ring** at the right with the seconds left).
Cards are 300 x 80 (the status panel's width); when the screen is short they shrink (to 52 px at least) so all three
fit between the top 64 px (help line) and the status panel. Hidden when there are no teammates (solo).

**Data.** The roster comes from `Session.crew()` minus `Session.local_id()`, rebuilt on `Session.roster_changed`.
Health, heat and state have no source yet; the hook is
`hud.crew_panel.status_source: Callable`, `(peer: int) -> Dictionary` with
`{hp: 0..1, heat: 0..1, state: "ok" | "overheat" | "disabled", revive_t: seconds left to revive, revive_max: the
full window (default CrewPanel.REVIVE_WINDOW = 20)}`. Missing keys take the defaults (hp 1, heat 0, ok), and unset
means everyone healthy. **Co-op / weapons work:** wire it from the synced teammate mechs (their snapshot heat, the
components' HP once S5 lands, the disabled / revive state when revive exists), e.g.
`hud.crew_panel.status_source = func(peer): return mission.mech_of(peer).crew_status()`. The panel only reads it.
Code: `scripts/ui/crew_panel.gd` (CrewPanel; `Card.look()` says what a card shows), created by MechHud as
`hud.crew_panel`; `MechHud.demo` shows three demo teammates (chicken healthy, pickle overheated, dog disabled 12 s).
Tests: `tests/test_crew_panel.gd` (empty = hidden, roster, status states, avatar badge with a fake Steam),
`tests/test_layout.gd` (`_hud`: three cards on screen at every size, above and left-aligned with the status panel, no
overlaps), `tests/test_visual_hud.gd` (`hud_demo` includes it).

## Data
Read-only polling every frame: `WeaponRack` HUD contract (`scripts/combat/weapon_rack.gd` header: slots(),
heat_state(), aim(), designator_on()), `MechController` (shutdown, reboot_heat, thrusting, emergency), the camera
(projects muzzles and the aim point). Component health is a **stub** until S5: `MechHud.component_source` (a Callable
returning `{id: 0..1}` for head, torso, leg_l, leg_r and each hardpoint id) or a `components` dictionary on the mech.

## Code and tests
`scripts/ui/mech_hud.gd` (MechHud, a CanvasLayer; `MechHud.for_drive(test_drive)`; `demo = true` shows sample data).
`tests/test_layout.gd` (every panel fully on screen at 16:9, 4:3, ultrawide; corners don't overlap),
`tests/test_test_drive.gd` (bound to the drive's mech / rack / camera, a row per slot, reads heat),
`tests/test_visual_hud.gd` (shots `hud_demo`, `hud_drive`).

## Open
- Component damage: wire `component_source` when S5 lands.
- Co-op: each player's HUD reads only its own mech (owner-side state); nothing to sync. The crew panel reads teammates'
  synced state through `crew_panel.status_source` (to wire).
- Weapon icons instead of names, if names prove slow to read.
