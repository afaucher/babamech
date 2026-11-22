# Testing

Everything runs through `.\test_runner.ps1` (ported from cast). `AGENTS.md` (Tests) has the short rules; this page has
the why and the survey behind the scene tests.

| Command | What runs | Window |
| --- | --- | --- |
| `.\test_runner.ps1 -TestAll` | every `tests\test_*.gd` except visual tests; net tests as N processes | none (`--headless`) |
| `.\test_runner.ps1 -TestName test_layout` | one test (comma-separate several) | none |
| `.\test_runner.ps1 -Visual` | every test with `const VISUAL := true`, one at a time; waits for the GPU lock | real renderer, window on a hidden desktop |

`-TestAll` runs ordinary tests in parallel (up to cores - 4 processes), then net tests, then **serial tests**: a test
whose source declares `const SERIAL := true` runs last, one at a time, with no other test process going. Use it for
wall-clock budgets: `tests/test_perf.gd` ("CombatWorld+AI under 4 ms/frame") measured 0.7 ms mean / 2.4 ms max alone but
3.9-4.2 ms max inside the parallel batch.

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
