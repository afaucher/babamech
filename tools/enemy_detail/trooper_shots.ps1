# trooper_shots.ps1 - trooper look-variant images (docs/design/enemy-detail/trooper_variants_grid.png, trooper_squads.png).
# Runs the headless mesh check, renders tools/enemy_detail/trooper_shots.tscn on the hidden desktop (REAL renderer, never a
# visible window; takes the shared GPU lock and waits its turn), raw shots to test_logs\enemy_detail\troopers\, then
# composes the images (make_troopers.py, Pillow).
#
#   .\tools\enemy_detail\trooper_shots.ps1                  # check + variants + squads + compose
#   .\tools\enemy_detail\trooper_shots.ps1 -Shots squads    # just the squads
param(
    [string]$Shots = "variants,squads",
    [switch]$NoCompose,
    [int]$TimeoutSec = 900
)
$root = Resolve-Path "$PSScriptRoot\..\.."
. "$root\godot_env.ps1"
. "$root\hidden_desktop.ps1"
$godot = Resolve-BabamechGodot
Update-BabamechImport $godot
$raw = Join-Path $root "test_logs\enemy_detail\troopers"
New-Item -ItemType Directory -Force $raw | Out-Null
Push-Location $root
try {
    & $godot --headless --path . --script res://tools/enemy_detail/check_meshes.gd 2>$null | Where-Object { $_.Contains("[mesh]") -and ($_.Contains("trooper") -or $_.Contains("PASS") -or $_.Contains("FAIL")) }
    $tail = "-- --scene res://tools/enemy_detail/trooper_shots.tscn --settings-file user://edetail_settings.cfg --shots $Shots --out `"$raw`""
    $code = Invoke-HiddenDesktop -Exe $godot -Arguments "--path . --resolution 1600x900 --log-file test_logs\trooper_shots.log $tail" -TimeoutSec $TimeoutSec
    Get-Content "test_logs\trooper_shots.log" | Where-Object { $_.Contains("ERROR") -or $_.Contains("[tshots]") }
    if (-not $NoCompose) {
        & python "$PSScriptRoot\make_troopers.py" $raw (Join-Path $root "docs\design\enemy-detail")
    }
    exit $code
} finally { Pop-Location }
