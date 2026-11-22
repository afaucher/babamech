# Mech HUD

Picked 2026-11-21 from `hud/grid_hud_r1.png` (rows: layout, columns: style): **9, minimal corners / holographic**:
thin cyan and white lines on translucent glass, corner brackets. Reference render `hud/hud_corners_holo_s7.png`
(flux3_klein_t2i, seed 7; regenerate with `hud/hud_r1.ps1`). The renders set layout and mood only.

## Layout
- **Bottom-left: mech status.** The damage diagram (see "Damage diagram" below): the real mech's front outline with a
  zone per head, torso, leg and hardpoint, each tinted by health: cyan > 2/3, amber > 1/3, red, destroyed = grey with a
  red outline and cross. Empty hardpoints are a dim dashed mount with a dimmed slot badge.
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
- **Top centre, under the help line: the mission objective** (W6, see "Mission objective").

## Mission objective
Built 2026-11-22 (`scripts/ui/mission_hud.gd`, MissionHud, a child of MechHud's root, `hud.mission_hud`), same holo style:
- **Objective line**: a glass strip 520 x 34 px, 40 px from the top, centred, amber edge, "OBJECTIVE" over
  `MissionRules.text()` ("CLEAR DECK 1: 5 HOSTILES LEFT", "REACH THE EXTRACTION PORTAL"). Hidden without an objective
  (district mode).
- **Extraction waypoint** while extraction is the objective: an amber diamond at `MissionRules.marker()` (3 m above the
  zone's centre on its deck) with "EXTRACT  184m" (distance from your mech), drawn over everything so it shows through
  decks; off screen or behind the camera it sticks 48 px inside the screen edge with an arrow pointing toward it.
- **End banner**: 640 x 120 px, centred 140 px above the crosshair, "MISSION COMPLETE" (green rules; red "CREW LOST" is
  drawn too but no rule produces it yet) over the reason, for the 4 s hold before everyone goes back to the hangar.
- Data: `MissionHud.source` = `MissionFlow.hud_state()` ({objective, waypoint {pos, deck, label}, banner {title,
  reason, won}}), wired by MechHud from the drive's `mission`. `demo` shows a sample objective and waypoint;
  `demo_banner` adds the banner.
- Not built (user decision 2026-11-22, "don't do revive yet"): the downed overlay, the revive prompt / ring and downed
  teammate markers.

## Damage diagram
Picked 2026-11-22 from `hud/grid_hud_diagram_r1.png` (rows: view front / side profile / 3/4, columns: abstraction
geometric / traced / schematic; shots in `hud/diagram_r1/`): **3, front / schematic**. It replaced the stick figure
(round head, oval body, straight legs, hardpoint boxes), asked for as "match the actual mech outline a little more".
- **Traced from the real mech.** `MechDiagram` (`scripts/ui/mech_diagram.gd`) builds the bound mech's MechModel off-tree
  (its pilot head, chassis and loadout), projects every mesh into 2D (front, 12 degrees from above, mirrored so the mech's
  left is on the left like the weapon rows' L / R), and makes each component's zone from the union of its meshes' hulls.
  Cached per view, style, head, loadout and panel size; a new head or loadout rebuilds it.
- **Schematic.** Each zone's outline, every mesh's plate seams in thin lines (not on the head: it gets a clean
  silhouette, a thicker line and the pilot's two eyes so it reads as a head), a dark gap where a part covers another,
  joint markers on hip / knee / ankle, a dashed body axis and ground line, and a **slot badge** by each hardpoint with
  the weapon row's number (1-5), placed clear of the head. A hardpoint mostly hidden (the back mortar behind the head) is
  redrawn as a dashed outline outside the head with a dashed leader to its badge.
- **Fits the panel.** The diagram stays inside the heat arc's inner circle and ends 64 px above the panel's bottom, so the
  state line (THRUST, EMERGENCY BURN, SHUTDOWN, REBOOTING) and the heat readout never overlap it.
- MechHud: `hud.status_diagram` (view `MechHud.DIAGRAM_VIEW`, style `DIAGRAM_STYLE`), fed every frame by `_sync_diagram()`
  from `pilot_head()`, `diagram_loadout()` (the weapon rows' slots, else the model's loadout), the slot numbers and
  `components()`. The other eight options stay drawable (`view` / `style`) for the grid and tests.
- Tests: `tests/test_mech_diagram.gd` (every zone for every view / style / loadout, inside the panel and above the text;
  chicken knee; the HUD in demo and through `for_drive` uses front / schematic with the actual head and loadout),
  `tests/test_visual_mech_diagram.gd` (the nine option shots), `tests/test_visual_hud.gd`.

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
`tests/test_visual_hud.gd` (shots `hud_demo`, `hud_demo_banner`, `hud_drive`); the mission layer's objective strip,
waypoint and banner are in `test_layout` too.

## Open
- Component damage: wire `component_source` when S5 lands.
- Co-op: each player's HUD reads only its own mech (owner-side state); nothing to sync. The crew panel reads teammates'
  synced state through `crew_panel.status_source` (to wire).
- Weapon icons instead of names, if names prove slow to read.
