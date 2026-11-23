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
- **Anywhere: revealed enemies** (a deck's last stragglers, see "Revealed enemies").

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

## Mission objectives (plan mode)
Built 2026-11-23 (mission objectives phase 1, docs/design/mission-objectives.md; `MissionHud`, data from
`MissionFlow.hud_state()` when the drive runs the plan, DEV `--objectives`). On top of the objective strip (whose line is
`MissionRules.text()`: the first primary not done, "RAISE THE FLAG: 12 / 20 S", "HOLD THE EXTRACTION PORTAL: 42 S"):
- **Objective list**, top right (300 px wide, 40 px from the top; on a 4:3 screen it drops under the centre strips so it
  never meets the objective line): "DECK n OBJECTIVES" and, amber, "WAVES 2 / 3" (released / total on your deck from
  the director's state), then `MissionRules.lines(deck)`: the primary first, bonuses once found (cyan, "BONUS: ..."),
  done lines green, failed red, at most 7.
- **Objective markers**: a square over each known / active flag and defend of your deck (amber primary, cyan bonus;
  "? FLAG" for a found bonus not started) with the distance, edge-stuck with an arrow like the extraction waypoint. A
  **ring** projected on the floor round each defend site (radius 30 m); the flag rings and the extraction hold zone are
  drawn in the world by MissionWorld (idle / contested / ours colours pushed by MissionFlow).
- **Reinforcements**: "REINFORCEMENTS, EAST GATE  4S" in a red-edged 420 x 28 strip at 118 px (under the "last hostiles"
  line), from the order until 6 s after the door opens (", DECK n" when it is another deck). A red INBOUND
  triangle at the source on your deck (edge-stuck with an arrow) (`MissionHud.SOURCE_ARROW`, on: user decision
  2026-11-23 "keep both", alongside the gate's beacon and klaxon; it points at the door, never at enemies). Direction words: a gate's wall (s1 north, s0 south,
  x1 east, x0 west), otherwise the source's side of the deck in the deck's own frame.
- **Zone bar**: 380 x 40 at 154 px while anyone of the crew stands in an active flag or hold zone: "RAISING THE FLAG
  12 / 20 S" or "HOLDING THE PORTAL 42 S" (the hold's countdown) with a progress bar; red "CONTESTED" while an enemy
  is in the flag's ring (progress paused).
- **Banner**: lost by a failed primary reads "MISSION FAILED" / "Objective failed" (red).
- `demo_plan` shows a sample of all of it (list, marker, ring, reinforcement line with a left-edge arrow, zone bar).
  Tests: `test_layout` (plan panels on screen at the three sizes, clear of each other, the strip and the corners),
  `test_mission_objectives`, `test_net_objectives*`, visual `test_visual_objectives` (shots `objectives_hud_demo`,
  `objectives_drive_flag`).

## Revealed enemies: removed

Built and then removed on 2026-11-22. The user asked for no non-diegetic enemy indicators: "the charge orb is FINE but
the diamond over their head and the warning sound is not". The HUD draws no markers, diamonds or distances over
enemies, and plays no "last hostiles" beep. The reveal itself (`mission-section.md` §15) is made diegetic on the enemy
side by antigravity, for example a flare. The shared edge-arrow helpers in `mission_hud.gd` stay for the mission's own
waypoints.

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

## Loading screen
User feedback: "let's get an actual loading screen. It flashes everything as it loads right now." `LoadingScreen`
(`scripts/ui/loading_screen.gd`), a CanvasLayer at layer 125 (above MechHud's 5 and ShaderWarmup's 120), opaque, in the
HUD's holo style (MechHud colours, `draw_glass`) on a near-black blue backdrop with a faint drifting grid.
- **When.** `TestDrive._ready` puts it up in its first line, before anything is built, so no frame shows the city being
  built, the camera or the HUD (both HUD layers are hidden while it is up). It comes down at `mission_go` (crew) or when
  the solo load and the shader warm-up are done, with a 0.3 s fade (`LoadingScreen.FADE`). The 3D viewport keeps
  rendering underneath, so ShaderWarmup still draws its meshes (it gets no overlay of its own then:
  `ShaderWarmup.warm(..., overlay = false)`). It runs `PROCESS_MODE_ALWAYS` (the solo warm-up pauses the tree) and
  touches neither input nor the session, so the load's keepalive and Session polling are untouched.
- **Solo** uses the same screen: `TestDrive._load_solo` lets it draw two frames, shows the section, then runs the
  synchronous build as before. Under `--run-test` the solo load stays in `_ready` (tests check the scene right after
  adding it) unless a test sets `TestDrive.cover_solo`; tests also take the screen down at once unless
  `LoadingScreen.fade_in_tests`.
- **What it shows.** The title, the mission ("Section 57036"; "District N"), the section (`section_text`: deck count,
  entry and extraction deck, ramps / lifts / shafts from the SectionPlan; "Charting the section..." before), a phase
  line + segmented progress bar (`PHASES`: shaders_pre 0-5 %, build 5-78 % from `CityStack.build_progress()`, populate
  78-88 % eased over the `AmbientLife.setup_step` frames, shaders 88-100 %, then "Waiting for crew  n / N ready"), in a
  crew the crew list (accent hex, name, head, LOADING / READY tick: `Session.mission_ready_peers()`, which the host
  knows from `mission.ready` and clients from the host's `mission.wait`), and a tip line that rotates every 6 s.
- **Scene changes.** Leaving the mission (the outcome's end flow, the host ending it, Esc) puts the screen up in phase
  "leave", waits two frames, then changes scene; `LoadingScreen.handoff` tells the menu to put its own up in its
  `_ready` and fade it after three frames. The hangar's Launch (and a relaunch) puts one up ("Launching") two frames
  before the change to the mission scene, which covers itself at once.
- Tests: `tests/test_loading_screen.gd` (solo: up from the first frame, covers every frame until `loaded`, HUD hidden,
  fades and frees; the tests' synchronous path; phases / section / crew rows), `tests/test_net_loading_screen.gd`
  (2 peers, stepped load: covered until `mission_go`, both rows, READY ticks), `tests/test_layout.gd` (`_loading`: fills
  the screen, bar / phase / crew rows / tip on screen at the three sizes), `tests/test_visual_loading.gd` (shots
  `loading_solo_midload`, `loading_solo_done`, `loading_coop_wait`).

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
