# shots.ps1 - enemy detail images of the adopted EnemyMeshes (docs/design/enemy-detail/). Runs the headless mesh check,
# renders tools/enemy_detail/shots.tscn on the hidden desktop (REAL renderer, never a visible window; takes the shared GPU
# lock and waits its turn), raw shots to test_logs\enemy_detail\, then composes the images (make_adopted.py, Pillow).
#
#   .\tools\enemy_detail\shots.ps1                    # check + lineup + close-ups + compose
#   .\tools\enemy_detail\shots.ps1 -Shots close       # just the gunship / dropship close-ups
param(
    [string]$Shots = "lineup,close",
    [switch]$NoCompose,
    [int]$TimeoutSec = 900
)
$root = Resolve-Path "$PSScriptRoot\..\.."
. "$root\godot_env.ps1"
. "$root\hidden_desktop.ps1"
$godot = Resolve-BabamechGodot
Update-BabamechImport $godot
$raw = Join-Path $root "test_logs\enemy_detail"
New-Item -ItemType Directory -Force $raw | Out-Null
Push-Location $root
try {
    & $godot --headless --path . --script res://tools/enemy_detail/check_meshes.gd 2>$null | Where-Object { $_.Contains("[mesh]") }
    $tail = "-- --scene res://tools/enemy_detail/shots.tscn --settings-file user://edetail_settings.cfg --shots $Shots --out `"$raw`""
    $code = Invoke-HiddenDesktop -Exe $godot -Arguments "--path . --resolution 1600x900 --log-file test_logs\enemy_detail_shots.log $tail" -TimeoutSec $TimeoutSec
    Get-Content "test_logs\enemy_detail_shots.log" | Where-Object { $_.Contains("ERROR") -or $_.Contains("[edetail]") }
    if (-not $NoCompose) {
        & python "$PSScriptRoot\make_adopted.py" $raw (Join-Path $root "docs\design\enemy-detail")
    }
} finally { Pop-Location }
