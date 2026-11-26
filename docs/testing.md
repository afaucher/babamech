# Testing

Everything runs through `.\test_runner.ps1` (ported from cast). `AGENTS.md` (Tests) has the short rules; this page has
the why and the survey behind the scene tests.

| Command | What runs | Window |
| --- | --- | --- |
| `.\test_runner.ps1 -TestAll` | every `tests\test_*.gd` except visual tests; net tests as N processes | none (`--headless`) |
| `.\test_runner.ps1 -TestName test_layout` | one test (comma-separate several) | none |
| `.\test_runner.ps1 -Visual` | every test with `const VISUAL := true`, one at a time; waits for the GPU lock | real renderer, window on a hidden desktop |
| `.\test_runner.ps1 -Visual -TestName test_visual_coop` | a visual test that also has `const PEERS := N`: N windowed processes at once (host + clients) | N windows on the hidden desktop, one GPU lock |

`-TestAll` runs ordinary tests in parallel (up to cores - 4 processes), then net tests, then **serial tests**: a test
whose source declares `const SERIAL := true` runs last, one at a time, with no other test process going. Use it for
wall-clock budgets: `tests/test_perf.gd` ("CombatWorld+AI under 4 ms/frame") measured 0.7 ms mean / 2.4 ms max alone but
3.9-4.2 ms max inside the parallel batch.

## Timeouts and audio

Two limits apply to a single-process test. **The test's own**: `TestCase.timeout_sec` (default 60) is a Timer on
**game time** (scaled by `Engine.time_scale`, so a bot test at 2x gets twice the game seconds per wall second). Set it
in `_init()` or `setup()`: setting it restarts the timer with the new value (before 2026-11-25 a value set in `setup()`
was ignored and the test kept 60 s; code-audit-2026-11 #8). Left unset, `const TEST_TIMEOUT := N` is used when larger.
**The runner's**: a wall-clock kill at max(`-TimeoutSec` (120), 1.5 x D + 30 s), D = the larger of `TEST_TIMEOUT` and a
literal `timeout_sec = N` in the test or the case file it `extends "res://tests/..."` (game time runs slower than the
wall clock under load). A computed `timeout_sec` (`limit + 60.0`) isn't read: declare `TEST_TIMEOUT` then. Net tests
(`NetTest`) stop the game-time timer and watch the wall clock (`net_timeout`); the runner gives a net run
max(`-NetTimeoutSec` (90), `NET_TIMEOUT`, a literal `net_timeout` + 20 s).

Tests make no sound: every test process gets `--audio-driver Dummy` (implied by `--headless` already), and on a headless
run `AudioDirector.silent` skips cues entirely (no fetch, no synthesis, no `play()`; music and ambience beds never
start; `CombatAudio` / `MechAudio` skip their per-frame step; the gate siren isn't played). A test that records cues
(`record_events = true`, `test_audio`) keeps the bookkeeping, only `play()` is skipped; `test_perf` sets `silent = false`
to time the live audio path.

## Ports

Several sessions run tests at once, so fixed ports (the old `28000 + 10 * slot`, or a test's own `const PORT`) collided
and failed net tests at random. Now `test_runner.ps1` (`Get-FreePort`) gives every net run a random port in 20000-59999
that a UDP bind probe finds free and that no other run of the same runner holds (24600, `run.ps1 -Crew`, is skipped).
If the host still fails to bind (another process took the port between the probe and Godot's bind: its log shows
"the host opens port"), the runner prints `RETRY` and reruns it on a new port, up to twice. Single-process tests get a
free port as `--net-port P` too; a test that opens a crew reads it with `TestCase.test_port(fallback)` (`test_menu`,
`test_perf_coop`). Never hard-code a port in a test.

## Co-op end-to-end test

`tests/test_net_coop_e2e.gd` (2 processes, links off + coast) and `test_net_coop_e2e_4.gd` (a full crew, off), scenario
`tests/net_coop_case.gd` (W9 of `docs/coordination/integration-plan.md`), play one crew mission from launch to end. At
every step each machine reports what it has and the host asserts they all agree: (a) launch + barrier (seed, crew,
build checksum), (b) the city (the stack's checksum; every crew mech
spawned, puppets with PlayerTargets), (c) everyone walks at one shared-clock moment and every puppet stands within
0.5 m of its owner's stop, (d) everyone fires every weapon and every machine receives exactly every other machine's
fire records (CombatNet), (e) with W4's host-owned enemies (AI idled by the host) a client fires at an enemy and
finishes it with a lethal hit: the host decides the kill and every machine shows the same enemies (ids, core HP, dead
flags, the wreck, alive per deck), (f) a client knocks a lamp and every deck's props snapshot matches, (g) down +
revive (skipped: deferred by user decision), (x) W6's win: the crew kills every remaining enemy with real
attacker-decided hits, the last client's mech goes into the extraction zone, the host decides won, and every machine
went through the same `mission.state` sequence (`clear_0,extract,/won`) and shows MISSION COMPLETE, (h) the mission ends (after a win, the host's MissionFlow ends it: every client hears "Mission complete") and every machine is back in the lobby with the snapshot stream off.
A step whose co-op API is not in yet is detected at runtime and skipped with a `TODO W9 skip <step>: <missing> (owner:
<owner>)` line; the host ends with `[W9] summary: done [...] skipped [...]` (grep the `.host.log`). Nothing is faked:
no machine writes another's state, nothing local-only is asserted as synced. When a missing API appears, the step says
it is not written yet (owner: headless-tests) instead of passing silently.

`tests/test_perf_coop.gd` (SERIAL) is the crew's frame budget in one process: the host opens a session alone, launches a
real crew mission, adds three puppet mechs through `CrewSync.setup` and feeds each a synthetic 30 Hz snapshot stream into
`Session.mechs.buffer(peer)` (only the wire and codec are not exercised). It measures a warm-up (discarded), the drive
solo, then with the puppets: crew p95 under 11 ms and the 3 puppets under 4.5 ms per frame on average (the header has
the measured numbers and why).

## Test drive hooks (city mode, offline crew)
- The stack is the only city (the single-district mode was cut 2026-11-25); `td.city_mode` is always `MODE_STACK`
  (a test may still set it; nothing else is built). Command line: `--seed N`; `--stack` and `--objectives` are
  accepted and ignored. A test that needs a bare district builds a `CityDistrict` itself (`test_enemy_effectiveness`).
- `TestDrive.offline_crew = N` (static, set before the scene enters the tree; reset it after) or `--offline-crew N`: a
  solo test drive with N mechs and no session, for headless perf runs. Mechs 2..N are idle puppets (`puppet` on, no
  MechPuppet, no input or physics) with fake owner peers `TestDrive.OFFLINE_PEER + seat`, placed in the crew slots
  (`TestDrive.entry_spawn`); their rigs, gait, FX and audio run. `test_stack_drive` checks it.

## Fixtures (one mission mode; TEST-ONLY isolation)
The game has one mission mode, the objectives (user 2026-11-25: "Cut the legacy modes."). Which mode a test runs depends
on what it covers (user: "The unit tests can have their own mode if needed. That might be more robust." / "Depending
what we are testing."):
- **Integration** (mission flow, the pacing director, bots, co-op objectives, the mission start): the real objectives
  mode, the only one (no switch to set). For a fast, predictable mission force the plan
  on every machine with `MissionFlow.test_plan` (it joins the plan checksum), e.g. `{"primary": "sweep", "bonus_max": 0,
  "waves_per_deck": 0, "hold": 3.0}`: every deck a sweep (the closest to the old "clear every deck"), no reserve waves,
  a 3 s hold (`test_mission_flow`, `net_mission_flow_case`, `net_coop_case`).
- **A narrow system** (a weapon, an enemy behaviour, net sync, city / stack layout, perf) that needs "a section with
  enemies" and nothing of the mission: `QuietSectionFixture` (`scripts/test_support/quiet_section_fixture.gd`). Declare
  `const QUIET_SECTION := true` in the test or in the shared case it extends; `TestCase._ready` arms it in every process
  (net tests: host and clients) before `setup()`. It sets `MissionFlow.test_quiet`: MissionFlow builds no rules, plan or
  director, so the stack, the crew and the FULL garrison stand, nothing is released, nothing is evaluated and the
  mission never ends (`td.mission.rules == null`). TestDrive honours it too: no plan prebuild in the crew's stepped
  load, the full garrison (share 1.0) in `spawn_enemies`, `mission_checksum()` the stack's alone.
- **Never from the game**: nothing in `scripts/app`, `scripts/ui` or `scripts/game` references a test-support class
  (PerfProbe, the bench timer, excepted), `MissionFlow.test_quiet` is written only by `scripts/test_support/` and
  `tests/`, and no flag, setting or menu reaches it: `tests/test_objectives_only.gd` checks all of that.

## Combat log (damage in playtest logs)
Every mission run (stack mode, solo or crew) prints `[Flow]` damage lines for THIS machine's player
(`scripts/game/combat_log.gd`, `CombatLog`; attached by `TestDrive` once `MissionFlow` exists, starts when the mission is
released). Off: `--no-combat-log`. Never in the lab. Logging only (all LOCAL, no messages). Format:
`[Flow] t=<FlowLog clock> <tag> mt=<mission s> peer=<id> key=value ...`, fixed field order, values without spaces
(`-` = empty), so `grep "\[Flow\]"` gives the whole run's flow and damage together.
- `dmg_in src=<id>/<kind> wpn= comp= amt= n= dur= hp=<comp>:<cur>/<max>,... tot=<% total> core=<% weakest of torso / head
  / legs> heat=<0..1> shut=0|1 heat_in=`: damage to the local mech, coalesced per source + weapon + component over 0.5 s
  (mt = first hit; hp = when the line prints, at most 0.5 s later). Exact (the victim decides). Falls: `src=fall/env`,
  wall slams `src=wall/env`.
- `dmg_out tgt=<id>/<kind> wpn= amt= n= dur= thp=<% target HP, -1 unknown> kill=0|1 est=0|1`: the player's hits per
  target + weapon over 1 s (a kill prints at once). `est=0` (solo, host, anything applied on this machine): the amount the
  target applied, after its weak-point multipliers. `est=1` (a client's hit on a host-owned enemy, applied on the host):
  the raw hit damage, thp from the local replica, kill unknown (0). `wpn=dot`: non-hit damage credited to the player.
- `down cause= src= wpn=`, `respawn tot=`.
- `summary hp= core= comp=<comp>:<%>,... heat= shut= in= out= near= nearest= combat=0|1 deck= obj= down=`: every 10 s of
  mission time; in / out = this window's damage, near = live enemies within 150 m, combat = shot / hit / took non-env
  damage within the last 6 s.
- `end outcome= reason= in= out= kills= est= taken_by=<kind>:<amt>,... dealt_by=<wpn>:<amt>,... hp_min= hp_min_mt=
  core_min= core_min_mt= deaths= death_mt=a;b respawns= respawn_mt= combat_s= quiet_s= longest_combat= longest_combat_mt=
  longest_quiet= longest_quiet_mt=` then the mission's pacing numbers `eng_s= eng_pct= quiet_max= quiet_max_mt= quiet30=
  peaks= peak_mt= kint_med= kint_p90= kint_max= in_pm= out_pm= core_min_c= est_eng=`: once, at won / lost, or `quit`
  when the scene goes first.
`amt` is what the target's `damaged` signal reported. Players (`PlayerTarget`) and plain targets (`CombatTarget`,
`DepotTarget`): the HP actually removed, no overkill (150 damage on a 100 HP head logs 100); a hit that removes nothing
(an invulnerable mech, a wreck) emits no `damaged` and logs nothing (a heat-only hit still logs `amt=0.0` with its
`heat_in`), and a hit on a player's destroyed hardpoint lands on the torso it hangs on (`comp=torso`). Enemies
(`EnemyBase`): the hit after the component's weak-point multiplier, not clamped (overkill included; a hit on a broken
non-core component reports its overflow share on the core). Assets (`AssetTarget`): the requested amount (they report,
never subtract). So `in` / `taken_by` and the `summary` / `end` totals are true HP lost for the local mech; `out` /
`dealt_by` are true HP for plain targets and raw (overkill included) for enemies. `kills` = the player's own hits that
left a target destroyed, applied on this machine (`est=1` hits never count: the host decides); a shot into a wreck emits
nothing, so it never counts a kill twice.

Threat and pacing records (`docs/design/pacing-director.md` section 3; summaries per `pacing-research.md` 8.6):
- `shot src=<id>/<kind> tgt=<id>/<kind>|- wpn= n= hits= hit=0|1 dist= est=0|1`: shots coalesced per shooter + weapon +
  target over 1 s (mt = first shot). Every machine logs its own pilot's shots, exact: tgt = what the shot hit (paired by
  shot key from `hit_landed` / `remote_hit`), `-` = missed (no hit within range / speed + 0.5 s); dist = muzzle to hit
  point (misses: to the aim point). The host also logs enemy shots at pilots (tgt = the enemy's `_target_id` when it
  fired, dist = muzzle to pilot): hits exact on pilots it owns; on a client's pilot (the victim decides there)
  `hits=-1 hit=-1 est=1`.
- `threat i= src=host|local eng= engaging= near= sees= seen_by= nearest= est= crew_i= crew_eng= deck= alive= tot= core=
  heat= shut=0|1 rays= pilot= bot=0|1` at 1 Hz for the local pilot (pilot = the line's peer) and, on the host, for each hangar bot
  (host-owned pilots with negative ids: `bot=1 pilot=<id>`, own intensity and ray budget). `heat` / `shut` come from the
  pilot's `MechController` (a bot's too: a bound `PlayerTarget`'s own heat gauge is never ticked). `i` = intensity (`PilotIntensity`, `scripts/game/pilot_intensity.gd`, the
  1.2 table): the host director's value from mission state `intensity` when present (`src=host`), else computed here.
  Engaged = an enemy fired at the pilot, or was awake within 60 m with it as target, in the last 4 s. `near` = live
  enemies within 200 m; `sees` = awake ones among the 12 nearest in line of sight (p>e rays); `seen_by` = enemies with
  the pilot as target and line of sight (host: read from the AI's `_target_id` / `_has_los`; client: replicated
  `ai_state` + range + the pilot's ray, `est=1`); `crew_eng` = any pilot engaged (host: all pilots); `alive` = live
  enemies of the deck; `rays` = p>e rays in the last second.
- `los list=<id>:<p>e 1|0|->:<e>p 1|0>,... pilot= bot=` (1 Hz per pilot, the 12 nearest awake enemies within 200 m).
- `quiet from= dur= deck=`: a stretch over 30 s with nobody engaged just ended.
- `deck_sum deck= from= dur= eng_s= eng_pct= quiet_max= quiet_max_mt= quiet30=<start>+<dur>;... peaks= peak_mt= kills=
  kint_med= kint_p90= kint_max= in_pm= out_pm= hp_min= hp_min_mt= core_min= core_min_c= core_min_mt= deaths= est=`:
  when the local pilot has been 3 s on another deck, and at the end. Peaks = crew intensity crossing 70 (re-armed under
  35); kill intervals over every enemy destroyed (anyone's kill); `est=1` = engagement from replicated state.
- `pace deck= from= to= i= reason=`, `release wave= deck= src= size= kinds=<kind>:<n>,... reason=`, `scout ev= drone=
  deck=`, `depot ev= depot= left=`: printed by `CombatLog.note_pace / note_release / note_scout / note_depot` (static,
  no-ops when no log runs); `pace` also from mission state key `pace` changes until `note_pace` is used.
- `scale from= to= reason=leave|state pilot= at=`: the crew scale changed on this machine (`CombatLog.note_scale`, from
  `MissionFlow._apply_scale`), printed on EVERY machine at the host's `at` (shared clock, 3 decimals: compare `at` across
  machines' logs, it is the same); `pilot` = who left (negative for a hangar bot, 0 when learned from mission state). The
  run log also has `[mission] scale a -> b (reason, pilot, at)` and, on the host, `[mission] scale decided ...`.
Cost: one scan of `world.targets` every 0.25 s, the threat record at 1 Hz, at most 12 p>e rays a second (3 per physics
step, `CombatWorld.shot_ray`), strings only when a line prints. `tests/test_combat_log.gd` checks the records (a staged
physics scene with real turrets and a wall for the threat counts and the ray budget), `PilotIntensity` against the
table, `PacingStats`, that every line parses, and runs the report tool on its own lines.

**Pacing timeline** (`tools/pacing_report/`, Python 3 standard library): one self-contained HTML file per run log.
`python tools\pacing_report\pacing_report.py -Latest -o pacing.html` takes the newest mission log in
`%APPDATA%\Godot\app_userdata\babamech\logs` (`godot.log` and its dated copies: run.ps1 games and playtests; Godot
keeps only the last few and headless test runs without `--log-file` rotate them, so copy a playtest worth keeping to
`test_logs\playtest\`) or in `test_logs\playtest\` (test runs skipped); or pass log path(s), one per machine (bots get
their own section).
`python tools\pacing_report\selftest.py` checks it.

## Why scene tests

`.\run.ps1` once opened to an empty grey screen while every headless test passed. `front_end.gd` called
`set_anchors_preset(PRESET_FULL_RECT)` in `_ready`, when the Control was already in the tree with size 0: that call sets
the anchors but recomputes the offsets to keep the old rect, so the menu root and its rows stayed 0x0 (the left panel
56 px tall). `test_menu` pressed the buttons through code and never asked where they were.

`--headless` uses a dummy renderer, so nothing is drawn, but **the GUI still lays out** against the root viewport
(project size 1600x900; setting `get_tree().root.size` reshapes it under stretch mode `canvas_items` / `expand`).
Control rects, visibility and clipping are real, which is enough to catch that class of bug without a window.

## Layout tests (headless, always on)

`scripts/test_support/layout_check.gd` (`LayoutCheck`), used by `tests/test_layout.gd`:

- `fills_screen(c, what)`: a full-screen Control covers the viewport.
- `full_height(c, what)`: a side panel spans top to bottom.
- `at_least(c, size, what)`: a panel did not collapse to its margins.
- `on_screen(c, what)`: visible in tree, real size, inside the viewport, and not clipped away by a ScrollContainer or
  `clip_contents` ancestor.
- `buttons_on_screen(root, what)`, `all_controls_sane(root, what)`.

`test_layout` opens the menu (main, settings, hangar) and the lab (every `LabRegistry` subject) at 1600x900, 1024x768
(the canvas grows to 1600x1200) and 2560x1080 (2133x900). Below-the-fold controls in a scroll panel are scrolled to
(`ensure_control_visible`) and must then be on screen. **Proof:** with the anchor fix reverted, `test_layout` fails
with 84 failures (`menu@1600x900 root fills the 1600x900 screen (rect ... S: (0.0, 0.0))`) while `test_menu` and
`test_smoke` still pass; with the fix it passes.

Add checks for every new screen, HUD or panel. A new lab subject is covered automatically (its side panel, subject
pick and first param).

## Visual tests (`-Visual`, on demand)

A test that declares `const VISUAL := true` needs pixels. `-TestAll` skips it (so `build.ps1` stays headless).
`-Visual` runs it without `--headless`, in a 1600x900 window started on a **hidden Windows desktop**
(`hidden_desktop.ps1`, ported from felt's `tools\hidden_desktop.ps1`; flap's `test_lib.ps1` does the same): Godot renders
normally on the real GPU, but the window is never on screen, never in the taskbar and can't take focus. The process has no
console there, so its output comes back through `--log-file test_logs\<name>.log`, judged by the same rules as headless
tests. One test at a time; shots go to `test_logs\shots\` (the runner writes a `.gdignore` into `test_logs` so Godot never
imports them). It takes the **GPU lock** for the batch and waits while another session renders or holds a window, then
while anything still listens on port 8188 (see GPU sharing; exit 2 if the GPU stays busy). `BABAMECH_SHOW_WINDOWS=1` runs the window on your own desktop to watch it. A visual test run without `-Visual` sees
`ShotCheck.available() == false` and passes with a note.

`scripts/test_support/shot_check.gd` (`ShotCheck`): `grab(name)` (waits for `frame_post_draw`, saves the PNG),
`not_blank(img, rect_fraction, what)` (luminance spread and distinct colours on a 64x64 sample grid), `differs(img, a,
b, what)`. `tests/test_visual.gd` shoots the three menu screens and every lab subject and checks the UI panel and the 3D
view each show detail. Checks are coarse on purpose: no golden images while the art changes daily; look at the shots.
**Proof:** with the anchor fix reverted it fails 9 checks (`menu main mech preview is not blank (luminance std 0.000,
1 colours)`).

**Co-op visual tests (VISUAL + PEERS).** A visual test that also declares `const PEERS := N` runs under `-Visual` as N
real windowed processes on the hidden desktop at once, like a net run: the host (`--net-role host`) first, the clients
400 ms later, a port from `Get-FreePort`, `--max-fps 60`, and each process writes `--log-file
test_logs\<name>.<role>.log` (`.host.log`, `.c1.log`, ...; `<name>.<link>.<role>.log` when it runs under several links).
The runner holds ONE GPU lock for the whole batch and starts the windows with `Start-HiddenDesktop`
(`hidden_desktop.ps1`, non-blocking: returns a handle with `.Wait(ms)` / `.ExitCode` / `.Kill()` / `.Close()`, takes no
lock of its own; `Invoke-HiddenDesktop` still takes it per run). Judged like a net run: every exit code 0, the PASS marker
from the host, no SCRIPT ERROR in any log; a host that could not bind is retried on a new port; at least 150 s before the
windows are killed. `-TestAll` still skips it (it is VISUAL); `-TestName` alone runs it headless, where it passes with a
note. `tests/test_visual_coop.gd` (2 peers, link off, about 25 s): the host launches a stack mission, both walk forward at
one shared-clock moment, then each machine aims its own chase camera at the teammate (test code: `look_dir` / `pitch`,
smoothing off, a 22 m boom, offsets until the teammate is on screen, in line of sight and not covered by its own mech)
and grabs `coop_<host|client>_1` (the teammate), `_2` / `_3` (mid-burst: every weapon held, the teammate's shots arriving
through CombatNet) and `_4` (a live enemy, with the teammate in the same look). The client reports its facts per shot and
the host judges both machines: image not blank; teammate puppet in the frustum, on screen, in sight, its pilot head node
on screen, roster head and accent (plus accent-hued pixels in its screen box); the HUD crew panel shows exactly the
teammate's card (`LayoutCheck.on_screen`, head, accent, drawn pixels); the teammate's records fired here and its effects
in view; the enemy alive here and on the host, in the frustum, on screen and in sight.

Why not simpler tricks: an off-screen `--position -20000,-20000` window did render here (2026-11-21), but flap found
Windows can clamp it back onto the screen, and a minimized window stops Godot drawing (flap `test_lib.ps1` header). The
hidden desktop avoids both and felt checked its shots are byte-identical to on-screen ones.

## GPU sharing

Several Claude Code sessions work here at once, and the 12 GB RTX 3080 is shared with local ComfyUI renders
(`~\.claude\skills\local-render\render.ps1`, port 8188) and llama-server (port 8080). FLUX hangs while any Godot window
draws, so the two take turns through one lock for all sessions and projects, `~\.claude\gpu-lock\gpu_lock.ps1`
(loaded by `godot_env.ps1`; `Enter-BabamechGpu` / `Exit-BabamechGpu` / `Move-BabamechGpu`):

| Command | Lock |
| --- | --- |
| `.\test_runner.ps1 -TestAll`, `-TestName x`, `build.ps1` | never (headless) |
| `.\test_runner.ps1 -Visual`, `Invoke-HiddenDesktop` | for the batch / run |
| `.\run.ps1 ...`, `.\lab.ps1 ...` | while the window is open (the script blocks until it closes) |
| `.\run.ps1 -Crew N` | handed to the windows: held until the last one closes |
| `render.ps1` batch / `-KeepServer` | for the batch / until `render.ps1 -StopServer` |

A taker that finds the lock held prints who holds it (owner, purpose, PID, cwd) every 30 s and polls; after
`$env:CLAUDE_GPU_LOCK_TIMEOUT` seconds (default 900) it gives up with exit 2 (render: exit 7). Godot takers then also
wait for a ComfyUI that runs outside the lock (port 8188). The lock lives in `~\.claude\gpu-lock\status.json`, written
under the named mutex `Global\ClaudeGpu`; it is held while any listed process (PID + start time) lives, so a crashed or
killed holder frees it, and the next taker stops a ComfyUI server that a dead render batch had started.

```
& "$HOME\.claude\gpu-lock\gpu_lock.ps1"          # who holds the lock; ComfyUI / llama-server / Godot processes; VRAM
& "$HOME\.claude\gpu-lock\gpu_lock.ps1" clear    # drop a stale status file (refuses while its holder lives)
$env:CLAUDE_GPU_LOCK_TIMEOUT = 60                # wait at most 60 s in this shell
```

Rules: close your windows when done; don't close or kill windows or a ComfyUI that another session started, report
them. Windows started without the lock (a Godot editor) are not covered: renders wait for them to close, then exit 7.
Tested 2026-11-21: two and three concurrent holders run one after another; a waiter gives up cleanly at its timeout; a
killed holder frees the lock within one poll and its registered server is stopped; `-Visual` waited 14 s for a holder.

## Survey of the other projects

Read-only survey, 2026-11-21. Every Godot project here shares cast's harness shape: `--headless --fixed-fps 60 --
--run-test <name>`, pass = exit 0 + the PASS marker + no `SCRIPT ERROR`.

| Project (Godot) | Scene / layout testing | Screenshots without a window | Adopted here |
| --- | --- | --- | --- |
| **flap** (4.7) | `test_game_smoke` instantiates the game scene headless and checks HUD / camera; `gpu_test_*` render a SubViewport (`UPDATE_ALWAYS`, two `frame_post_draw`) and read pixels back to check shader output | **Yes**: every run starts on `WinSta0\FlapHidden` (`CreateDesktopW`, `test_lib.ps1`), `gpu_test_*` drop `--headless`; plus a job object, mute env var, a retry for a D3D12 quit hang | the hidden-desktop idea, `frame_post_draw` capture, coarse pixel checks instead of goldens |
| **felt** (4.7, GitHub) | lab self-tests | **Yes**: `tools\hidden_desktop.ps1` (57 lines, same trick), shots via `--log-file`, byte-identical to on-screen shots | **ported** as `hidden_desktop.ps1` + `--log-file` |
| **cast** (4.7) | layout asserts on `get_global_rect()` inside a holder Control sized 1600x900: fits the canvas, no overlap (`test_license_checkout`, `test_character_select`), `is_visible_in_tree` | No: labs take `--shot` in a visible window (`lab_base.gd`) | rect / visibility asserts (generalized to the real viewport in `LayoutCheck`) |
| **bridge-to-friendship**, **inkwood** (4.7) | headless viewport defaults tiny (64x64 per bridge's CLAUDE.md), so tests set `get_window().size = 1280x720` then assert against `get_visible_rect()`; advice: placement maths as pure functions of screen size | No: inkwood's `--render-shot` opens a window, but refuses under headless | setting the root size per shape; the "no renderer" guard (`ShotCheck.available()`) |
| **ballista-tanks** (4.7) | headless tests | No: windowed compare rig; the only golden-image comparison (landmarks, silhouette IoU, colour dE, `art\compare\history.csv`) | not yet: worth borrowing when art locks |
| rare (4.7) | copy of flap's `test_lib.ps1` | yes (as flap) | (as flap) |
| project_deep_space, it-gets-deeper, goto, team-dark, tank-dance, desk-rally (4.4), sticky-wicket (4.3) | plain headless runners, no scene/layout checks | no | nothing |
| tank-game, spider-game, squirrel-racer | not Godot (JS/HTML or no project) | - | - |

Gaps none of them had, added here: a ComfyUI (port 8188) refusal in the runner, an "image is not one flat colour"
check, a test that walks every screen and every lab subject, and layout at several window shapes. Nobody uses
`--rendering-driver opengl3`, `--display-driver`, `--write-movie` or minimized windows.

In babamech the root viewport under `--headless` is the project size (1600x900), not 64x64; `test_layout` prints the
canvas size per shape so a change there shows.
