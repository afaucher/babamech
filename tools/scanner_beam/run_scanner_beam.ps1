# run_scanner_beam.ps1 - repair-drone scanner beam render probe (tools/scanner_beam/scanner_beam_probe.gd): one PNG per
# cell and camera (<Out>\<cell>_<cam>.png), close 3-frame strips of the sweep cells, then the grids (art/tools/make_grid.py).
# REAL renderer on the hidden desktop (never a visible window); takes the shared GPU lock and waits its turn.
#
#   .\tools\scanner_beam\run_scanner_beam.ps1                   # everything
#   .\tools\scanner_beam\run_scanner_beam.ps1 -Cells A1,B2 -NoGrid
param(
    [string]$Cells = "",
    [string]$Cams = "gameplay,close",
    [string]$Phase = "0.3",
    [int]$Seed = 7,
    [string]$Out = "tools\scanner_beam\shots",
    [switch]$NoStrip,
    [switch]$NoGrid,
    [string]$Resolution = "1600x900",
    [int]$TimeoutSec = 600
)
$root = Resolve-Path "$PSScriptRoot\..\.."
. "$root\godot_env.ps1"
. "$root\hidden_desktop.ps1"
$godot = Resolve-BabamechGodot
Update-BabamechImport $godot
New-Item -ItemType Directory -Force "$root\test_logs" | Out-Null
$outAbs = if ([IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $root $Out }
New-Item -ItemType Directory -Force $outAbs | Out-Null
# Godot must never import the shots as resources.
if (-not (Test-Path "$outAbs\.gdignore")) { New-Item -ItemType File "$outAbs\.gdignore" | Out-Null }
$log = "test_logs\scanner_beam.log"
$engine = "--path . --resolution $Resolution --log-file $log"
$tail = "-- --scene res://tools/scanner_beam/scanner_beam_probe.tscn --settings-file user://sbeam_settings.cfg" +
    " --cams $Cams --seed $Seed --phase $Phase --out `"$outAbs`""
if ($Cells) { $tail += " --cells $Cells" }
if ($NoStrip) { $tail += " --strip 0" }
Push-Location $root
try { $code = Invoke-HiddenDesktop -Exe $godot -Arguments "$engine $tail" -TimeoutSec $TimeoutSec } finally { Pop-Location }
Get-Content (Join-Path $root $log) | Where-Object { $_.Contains("[sbeam]") -or $_.Contains("ERROR") }

if (-not $NoGrid) {
    $labels = @{
        "A1" = "A1 fan, soft sheet"; "A2" = "A2 fan, edges + rays"; "A3" = "A3 fan, panning blade";
        "B1" = "B1 cone, soft + footprint"; "B2" = "B2 cone, edges + lattice"; "B3" = "B3 cone, sliding spot";
        "C1" = "C1 scan, soft band"; "C2" = "C2 scan, line stack"; "C3" = "C3 scan, moving line" }
    $ids = "A1","A2","A3","B1","B2","B3","C1","C2","C3"
    foreach ($cam in $Cams.Split(",")) {
        $items = @()
        foreach ($id in $ids) {
            $png = Join-Path $outAbs "${id}_$cam.png"
            if (Test-Path $png) { $items += "$png|$($labels[$id])" }
        }
        if ($items.Count -gt 0) {
            & python "$root\art\tools\make_grid.py" (Join-Path $outAbs "grid_beam_$cam.png") "Repair drone scanner beam - $cam (rows: fan / cone / scan lines; cols: soft / edges / sweep)" @items
        }
    }
    $items = @()
    foreach ($id in "A3","B3","C3") { foreach ($f in 0,1,2) {
        $png = Join-Path $outAbs "${id}_close_f$f.png"
        if (Test-Path $png) { $items += "$png|$id frame $($f + 1)" } } }
    if ($items.Count -gt 0) {
        & python "$root\art\tools\make_grid.py" (Join-Path $outAbs "grid_beam_sweep_strip.png") "Sweep cells, 3 frames (close)" @items
    }
}
exit $code
