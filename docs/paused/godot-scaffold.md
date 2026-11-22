# Paused: Godot scaffold, menus and hangar polish

Paused 2026-11-21 for the critical path to a playable demo (the mech HUD stays active in the same session). Everything
listed here works today; these are polish items and loose ends, none blocks the demo.

## State when paused
- Scaffold done: project, `Session` (Steam lobby + ENet), menus (main / settings / hangar), persisted settings, lab,
  run / test / build scripts. All headless tests and `test_visual` pass.
- Hangar = the bay of a military assault boat (`docs/design/hangar.md`, pick: assault / prep -> alert from
  `docs/design/hangar/grid_hangar_r1.png`). Built: `scripts/ui/hangar_bay.gd` (HangarBay), used by
  `scripts/ui/mech_stage.gd` in bay mode for the hangar screen; Launch in `scripts/ui/front_end.gd` plays a 2.5 s alert,
  then loads the test drive. Lab subject `hangar`.

## Resumed 2026-11-21 (late): done
Items 1-5, 7 and 8 are **done**: name tags sit at the model's measured top (`HangarBay.tag_height`); the Settings name
field's placeholder is the name the crew sees; checkboxes have their own visible icons; the hangar's Launch / Settings /
Leave live in a footer pinned under the scrolling panel (`FrontEnd.footer`, checked in `test_layout` with a long note);
the lab's preset views turn with an optional `lab_view_yaw()` (contract in `lab_registry.gd`; the hangar uses it);
`test_net_crew`'s host stays up until the refused joiner is dropped; `.\build.ps1` exports (exe + pck + GodotSteam
DLLs + steam_appid + zip in `build\`) and the exported exe boots headless cleanly. Still open: 6 (synced launch alert,
waits on S7) and 9 (Steam on two PCs).

## Paused items (each with files and the exact next step)

1. **Solo hangar name tag overlaps the head crest** (seen in the old turntable hangar; check whether it still happens in
   the bay). Files: `scripts/ui/hangar_bay.gd` (`show_crew`, tag at `+5.8` y), `scripts/ui/mech_stage.gd` (turntable
   tags at `+5.6`). Next: take `menu_hangar_prep.png` with `.\test_runner.ps1 -Visual test_visual`; if the tag touches
   the head, place it from the model's top (`MechModel` head node bounds) plus 0.6 m instead of a constant.
2. **Settings Name field shows the "Pilot" placeholder when the name came from `--net-name`.** Files:
   `scripts/ui/front_end.gd` (`_build_settings`, `name_edit`). Next: set `name_edit.placeholder_text` to
   `Session.display_name("Pilot")` when the saved name is empty, so the field shows the name the crew actually sees.
3. **An unchecked Fullscreen box is nearly invisible on the dark panel.** Files: `scripts/ui/front_end.gd` (`_check`).
   Next: give the CheckBox a theme override for `unchecked` / `checked` icons (or a lighter `font_color` + a visible
   box StyleBox), then re-shoot `menu_settings.png`.
4. **The hangar panel scrolls at `run.ps1`'s 800x450 windows; Leave crew is below the fold.** Files:
   `scripts/ui/front_end.gd` (`_build_hangar`, panel width 520), `tests/test_layout.gd`. Next: below ~600 px height,
   drop the chassis blurb and the stats to one line, or put Launch / Settings / Leave in a fixed footer outside the
   ScrollContainer; add a 800x450 case to `test_layout.gd` with `LayoutCheck.on_screen(fe.btn_leave)`.
5. **Lab camera for `hangar` starts behind the seat-1 mech.** Files: `scripts/ui/hangar_bay.gd` (`lab_focus`,
   `lab_radius`), `scripts/app/lab.gd` (the "three" view direction). Next: either add an optional `lab_view_dir()` to
   the lab contract (`scripts/app/lab_registry.gd` header) that `lab.gd` uses for the start view, or move the focus to
   the aisle so the default direction looks at the mechs' fronts.
6. **Launch alert is local only.** Files: `scripts/ui/front_end.gd` (`_on_launch`), `scripts/net/net_session.gd`.
   Next (with the co-op mission milestone, S7): the host's Launch broadcasts one scheduled effect (start time on the
   shared clock); every machine calls `stage.set_alert(true)` at that time and loads together. Clients' Launch stays
   disabled.
7. **`test_net_crew` flaked once under full load** ("The host left" instead of "Crew is full" for the refused 5th
   client: the host exits before the refusal reaches it). Files: `tests/test_net_crew.gd`, `scripts/net/net_session.gd`
   (refusal path). Next: have the host wait for the refused peer's disconnect (or 1 s) before finishing; or have the
   client accept `last_reason` set before `session_ended`.
8. **`build.ps1` export never run.** Next: run `.\build.ps1` once, check `build/` has the exe + pck and the GodotSteam
   DLLs, and fix `export_presets.cfg` if not.
9. **Steam path untested on two PCs** (only ENet is tested). Next: two machines, both logged into Steam, Play on one,
   Join on the other; confirm the roster shows both names and heads, then an overlay invite.

## Open questions (for the user)
- Breach state: should the hangar (or the mission start) show the door cutting through the hull (column 3 of the
  hangar grid), and does the boat clamp onto the rim (matching spin) or dock at the hub?
- Should the main menu also be inside the bay (the turntable floor today), or stay neutral?
- `decisions.md` line to add (the user's file): "Hangar = the bay of a military assault boat clamped to the hull; prep
  while you pick a loadout, red alert on Launch (`docs/design/hangar.md`)."

## How to resume
Read `AGENTS.md`, `docs/design/hangar.md`, then this file. Run `.\test_runner.ps1 -TestAll` (headless) to confirm green,
and `.\test_runner.ps1 -Visual test_visual` (takes the GPU lock, hidden desktop) for shots in `test_logs\shots\`.
Items 1-5 are independent and small; 6 waits on co-op mission sync; 7-9 are tooling checks.
