# run_enemy_style.ps1 - enemy colour-scheme render probe (tools/enemy_style/enemy_style_probe.gd): every enemy unit idle in
# a seeded city district under the real light rig, recoloured per palette option by a vertex-colour remap, one PNG per
# option and camera (<Out>\<option>_<cam>.png), then a 3x3 grid per camera (<Out>\grid_<cam>.png, art/tools/make_grid.py).
# REAL renderer on the hidden desktop (never a visible window); takes the shared GPU lock and waits its turn.
#
#   .\tools\enemy_style\run_enemy_style.ps1                                  # palettes_r1.json, all options + "current"
#   .\tools\enemy_style\run_enemy_style.ps1 -Options A1,B2                   # just these (plus the baseline)
#   .\tools\enemy_style\run_enemy_style.ps1 -Palettes tools\enemy_style\palettes_r2.json -Out art\renders\enemy_colour_r2
#   .\tools\enemy_style\run_enemy_style.ps1 -Cams gameplay -NoBaseline -NoGrid
#   .\tools\enemy_style\run_enemy_style.ps1 -Units turret,tank -Seed 4 -Lighting dusk
param(
    [string]$Palettes = "tools\enemy_style\palettes_r1.json",
    [string]$Options = "",
    [string]$Cams = "gameplay,lineup",
    [string]$Units = "",
    [int]$Seed = 0,          # 0: the table's "seed", else 7
    [string]$Lighting = "day",
    [string]$Ai = "",        # enemy ai_mode, e.g. telegraph_loop (default idle)
    [string]$Out = "art\renders\enemy_colour_r1",
    [string]$Title = "",
    [switch]$NoBaseline,
    [switch]$NoGrid,
    [string]$Resolution = "1600x900",
    [int]$TimeoutSec = 600
)
$root = Resolve-Path "$PSScriptRoot\..\.."
. "$root\godot_env.ps1"
. "$root\hidden_desktop.ps1"
$godot = Resolve-BabamechGodot
Update-BabamechImport $godot     # a new class_name elsewhere (other agents' work) is unknown until the project imports
New-Item -ItemType Directory -Force "$root\test_logs" | Out-Null
$outAbs = if ([IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $root $Out }
New-Item -ItemType Directory -Force $outAbs | Out-Null
$palAbs = if ([IO.Path]::IsPathRooted($Palettes)) { $Palettes } else { Join-Path $root $Palettes }
$table = Get-Content $palAbs -Raw | ConvertFrom-Json
if ($Seed -le 0) { $Seed = if ($table.seed) { [int]$table.seed } else { 7 } }
$log = "test_logs\enemy_style.log"
$engine = "--path . --resolution $Resolution --log-file $log"
$tail = "-- --scene res://tools/enemy_style/enemy_style_probe.tscn --settings-file user://estyle_settings.cfg" +
    " --palettes `"$palAbs`" --cams $Cams --seed $Seed --lighting $Lighting --out `"$outAbs`""
if ($Options) { $tail += " --options $Options" }
if ($Units) { $tail += " --units $Units" }
if ($Ai) { $tail += " --ai $Ai" }
if ($NoBaseline) { $tail += " --baseline 0" }
Push-Location $root
try { $code = Invoke-HiddenDesktop -Exe $godot -Arguments "$engine $tail" -TimeoutSec $TimeoutSec } finally { Pop-Location }
Get-Content (Join-Path $root $log) | Where-Object { $_.Contains("[estyle]") -or $_.Contains("ERROR") -or $_.Contains("SCRIPT ERROR") }

if (-not $NoGrid) {
    $want = if ($Options) { $Options.Split(",") } else { @() }
    $name = if ($Title) { $Title } elseif ($table.title) { $table.title } else { "Enemy colour schemes" }
    foreach ($cam in $Cams.Split(",")) {
        $items = @()
        foreach ($o in $table.options) {
            if ($want.Count -gt 0 -and -not ($want -contains $o.id)) { continue }
            $png = Join-Path $outAbs "$($o.id)_$cam.png"
            if (Test-Path $png) { $items += "$png|$($o.label)" }
        }
        if ($items.Count -gt 0) {
            & python "$root\art\tools\make_grid.py" (Join-Path $outAbs "grid_$cam.png") "$name - $cam" @items
        }
    }
}
exit $code
