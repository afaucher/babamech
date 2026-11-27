# pacing_report

Pacing timeline from a run log: one self-contained HTML file (inline SVG, no CDN, no external files). Reads the combat
log's `[Flow]` records (`scripts/game/combat_log.gd`, format in `docs/testing.md` "Combat log"). Python 3, standard
library only. Spec: `docs/design/pacing-director.md` section 3; targets: `docs/design/pacing-research.md` 8.2.

```powershell
# the newest mission log in %APPDATA%\Godot\app_userdata\babamech\logs (godot.log + dated copies: run.ps1 games and
# playtests) or test_logs\playtest\; test runs are skipped. Godot keeps only a few logs and headless test runs rotate
# them: copy a playtest worth keeping to test_logs\playtest\.
python tools\pacing_report\pacing_report.py -Latest -o pacing.html
# a given log (several logs = several pilots, one per machine of a crew)
python tools\pacing_report\pacing_report.py path\to\run.log [-o report.html]
python tools\pacing_report\selftest.py      # the tool's own checks
```

Per pilot over mission time: structure % (total, weakest core), intensity, enemies engaging / in sight / seeing the
pilot, damage in / out per 10 s, director state band, releases / scout calls / disables / depot marks, quiet stretches
(nobody engaged) against the 45 s cap with every one over 30 s labelled; then the deck / mission summary table, each
cell marked in or out of target. A host's hangar bots (threat lines with `bot=1`) get their own sections. Older logs (no `threat` / `deck_sum` records) still chart from `summary`, `dmg_in`,
`dmg_out`; their quiet stretches are estimated from the summary's combat flag.

A headless bot mission that writes such a log (about 3.5 min of game time, no window, no GPU):

```powershell
& <godot console exe> --headless --path . --fixed-fps 60 --quit-after 12600 --log-file run.log -- `
    --scene res://scenes/mission.tscn --seed 403112 --objectives --bot
```
