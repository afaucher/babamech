# babamech: instructions for agents

**Several agents work in this folder at once (Claude sessions and an antigravity agent). Before starting or resuming
work, read `docs/coordination/antigravity.md` and check `git status` / `git diff`; record what you change there.**


babamech (codename) is a co-op (up to 4 players) third-person mech combat game in Godot 4.7 / GDScript, set inside a
rotating ring habitat. Start with `README.md`, then `docs/design/decisions.md` (every design decision so far; **do not
edit it**, append decisions through the user) and `docs/networking.md` (the net model and what is built). The build
system, test harness and net layer are ported from `..\cast` (`C:\Users\alexa\.gemini\antigravity\scratch\cast`), the lab
idea from `flap`. `art/` belongs to the art-direction work: don't touch it.

## This file overrides `scratch/AGENTS.md` for networking
The `AGENTS.md` above the antigravity projects describes a host-only simulation with a `receive_perceived_state` RPC.
**Its guardrails 1-3 do not apply here.** babamech uses cast's owner authority: each player's machine owns that player's
mech and streams it, and the host owns everything else. Guardrail 4 (run the tests) applies: see Tests.

## Networking rules (enforced by `tests/test_net_contract.gd`)
Built so far: the transport (Steam lobby + SteamMultiplayerPeer, ENet for dev and tests), the hello handshake carrying
each pilot's name / head / chassis, the crew roster (max 4), refusals with a reason, profile changes (`sys.profile`), the
shared clock, telemetry, the link simulator, Steam invites (`Session`, `scripts/net/`). Nothing in gameplay is synced yet.
Every change has to keep co-op possible:
1. **Declare authority.** A class with gameplay state has `net_fields()` classifying **every** script var as
   `Net.SPAWN`, `OWNER`, `PRIVATE` or `LOCAL` (`scripts/net/net.gd`). Adding a var means adding it there. A gameplay
   class that doesn't define `net_fields()` yet goes in the test's `NET_SCRIPTS`.
2. **Change other entities only through verbs** (`apply_damage`, `heal`, `revive`, ... as they get built), applied by the
   target's owner: never write another mech's HP, heat, components or position.
3. **The victim decides about its own mech; the attacker's machine decides about host-owned targets.** Hits resolve
   through one shared combat module (to be built), never your own loop over actors.
4. **Randomness:** gameplay rolls use a generator seeded from the mission seed (layouts are procedural from a seed and
   checksum-verified on every machine); looks use their own generators. Never global `randf()` / `randi()`.
5. **No network code outside `scripts/net/`**, and no Steam API either (`Engine.get_singleton("Steam")`,
   `SteamMultiplayerPeer`, `ENetMultiplayerPeer`, `@rpc`, `send_bytes`, `multiplayer_peer`): ask `Net` / `Session`.
   Never use `unreliable_ordered` (GodotSteam sends it reliably), `MultiplayerSynchronizer` or `MultiplayerSpawner`.
6. **New content takes one of four shapes** (cast's `docs/design/networking.md`): a scheduled effect (one broadcast,
   then every machine computes it from params + start time on the shared clock), an owned actor, a host-arbitrated
   world object, or cosmetic. If it fits none, design its networking first.
7. **Enemy telegraphs are at least 0.3 s** so a dodge works on every machine (cast lesson).

When the test fails, fix the code or the declaration. Don't widen an allowlist without a written reason, and treat adding
one as a design decision to report.

## Layout
- `scripts/net/`: everything network and Steam (`NetSession` = the `Session` autoload, `NetWire`, `NetClock`, `NetLink`,
  `NetSteamLink`, `NetTelemetry`, `SteamLobby`, `SteamIdentity`, `Net`).
- `scripts/app/`: `Boot` (entry, `--run-test`, flags), `GameSettings` (persisted settings), `Lab` + `LabRegistry`.
- `scripts/mech/`: `MechCatalog` (heads, chassis, weapons: weight / passive heat / active heat), `MechModel` (the
  placeholder biped, used by menu, hangar and lab alike), `MechParts` (placeholder meshes), `HeadGallery`.
- `scripts/ui/`: `FrontEnd` (main / settings / hangar screens, built in code), `MechStage` (the 3D preview), `BuildVersion`.
- `scripts/world/city/`: the seeded urban district (`docs/design/city-styles.md`): `CitySite` (given structure: pillar points, ceiling openings; from the
  section plan or a stub, `docs/design/ceiling-and-pillars.md`), `CityPlan` (layout as data, checksummed:
  the gameplay shape), `CityBuildings` / `CityStreets` (flat-colour meshes via `CityGeo`, colours from `CityPalette`),
  `CityLightRig` (all lighting, separate from surface colour), `CityDistrict` (nodes + collision), `CityLab` (lab subject).
- `scripts/test_support/`: `TestCase`, `NetTest` (multi-process net tests).
- `scenes/`: `boot.tscn`, `menu.tscn`, `lab.tscn` (thin: a root node and its script).

## The lab
Every scene with tunable params is registered in `LabRegistry.SUBJECTS` and implements the lab contract (header of
`scripts/app/lab_registry.gd`): `lab_params` / `set_lab_param`, `lab_options` / `set_lab_option`, `lab_focus`,
`lab_radius`, `time_scale`. A new scene with numbers worth tuning goes there; `test_lab` sweeps every param of every subject.

## Tests
- `.\test_runner.ps1 -TestAll` runs everything (about 15 s). Net tests with `const PEERS := N` run as N headless processes
  over ENet localhost, once per link in `const LINKS` (default off and coast). Run them after any code change.
- Prefer headless runs. **GPU sharing:** several sessions share one GPU with local ComfyUI renders (port 8188), which
  hang while any Godot window draws. Everything that draws takes the shared GPU lock (`~\.claude\gpu-lock\gpu_lock.ps1`,
  via `godot_env.ps1`) and **waits its turn**: `run.ps1` / `lab.ps1` (held while the window is open; crew windows until
  the last closes), `test_runner.ps1 -Visual` and `Invoke-HiddenDesktop`. Headless runs never take it. Exit 2 means the
  GPU stayed busy past `$env:CLAUDE_GPU_LOCK_TIMEOUT` (default 900 s). See who holds it:
  `& "$HOME\.claude\gpu-lock\gpu_lock.ps1"`. Close your windows when done (renders wait on them), never close or kill
  another session's window or ComfyUI: report it. Details: `docs/testing.md` (GPU sharing).
- **Layout is tested headlessly** (`docs/testing.md`). `--headless` draws nothing, but Controls still lay out against the
  1600x900 viewport, so `tests/test_layout.gd` asserts the menu (main / settings / hangar) and the lab (every subject)
  fill the screen, panels have real sizes and key buttons are on screen, at 16:9, 4:3 and ultrawide. Any new screen,
  HUD or panel gets checks there with `LayoutCheck` (`scripts/test_support/layout_check.gd`): `fills_screen`,
  `full_height`, `on_screen`, `at_least`, `buttons_on_screen`. A new lab subject is covered automatically.
- Build UI in code with `set_anchors_and_offsets_preset(...)`, not `set_anchors_preset(...)`, on a Control that is
  already in the tree: the latter keeps its old (zero) size. That is the bug that opened the game to an empty screen.
- **Visual tests**: a test with `const VISUAL := true` needs real pixels. `-TestAll` skips it; `.\test_runner.ps1 -Visual`
  runs it in a real renderer on a hidden Windows desktop (`hidden_desktop.ps1`: nothing shows on screen), one at a time,
  saves shots to `test_logs\shots\`, and waits for the GPU lock (and for ComfyUI to stop). `ShotCheck` (`scripts/test_support/shot_check.gd`):
  `grab`, `not_blank`, `differs`. `tests/test_visual.gd` shoots the menu and every lab subject. Run `-Visual` after
  changing how a scene looks, and look at the shots.
- **Serial tests**: a test that measures wall-clock time (a frame budget) declares `const SERIAL := true`; the runner
  takes it out of the parallel batch and runs it last, alone (`tests/test_perf.gd`). Other tests must not time themselves
  against the wall clock.
- `.\build.ps1` runs the tests and exports.
- In a worktree, set `$env:BABAMECH_GODOT` to the Godot console exe and copy `addons/godotsteam/win64/*.dll` from the
  main checkout (gitignored).
