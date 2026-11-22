# babamech

Co-op (up to 4) third-person mech combat in Godot 4.7 / GDScript: chicken-legged mechs with oversized cartoon pilots
(chicken, pickle, corn, dog), inside a rotating ring habitat. Design: `docs/design/decisions.md`. Agents: `AGENTS.md`.

**Status: scaffold.** Menus, settings, a placeholder mech, the hangar (pre-mission) screen, the lab, and the crew session
(Steam lobbies + ENet) work. There is no mission yet.

## Run
```powershell
.\run.ps1                      # the game (menu)
.\run.ps1 -Crew 2              # a host + a joiner over ENet on this PC (each its own window and settings file)
.\run.ps1 -Crew 4 -Link coast  # four windows, simulated coast-to-coast link
.\lab.ps1                      # the lab: every scene with tunable params
.\test_runner.ps1 -TestAll     # all tests, headless
.\build.ps1                    # tests + Windows export (build\windows\babamech.exe)
```
Godot is found by `godot_env.ps1` (`$env:BABAMECH_GODOT`, `build\deps`, or the flap / cast / Hero-Reader copies).

## Menu
- **Play / Host**: opens a Steam lobby (alone, it is solo play). Without Steam: an ENet crew on port 24600.
- **Join**: the first open Steam lobby with this game key and build. Without Steam: ENet on 127.0.0.1:24600.
- Steam overlay invites work in both directions (Invite crew on the hangar; accepting one joins).
- **Settings**: pilot name, head, video, audio, simulated link (saved at once to `user://settings.cfg`).
- **Hangar** (after Play/Join): the crew with each pilot's name / head / chassis, your chassis and loadout
  (weapons with weight, passive heat, active heat), a 3D line-up of the crew's mechs. Launch is a stub.
- **Lab**: placeholder mech (leg lengths, crouch, stance, walk, head, loadout) and the head gallery.

## Not committed
- `addons/godotsteam/win64/*.dll`: copy from `..\cast\addons\godotsteam\win64` (GodotSteam 4.17.1). Without them the game
  runs without Steam.
- `build/`, `test_logs/`, `version.txt`.
