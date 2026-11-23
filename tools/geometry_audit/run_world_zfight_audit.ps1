# run_world_zfight_audit.ps1 - the world z-fighting audit (tools/geometry_audit/, docs/design/city-geometry-audit.md),
# headless (no GPU, no lock). Builds the CityStack of a section seed with its mission and the static ambient life, finds
# near-coplanar overlapping triangles per deck and prints the grouped findings ("[zfight]" lines); the full list is in
# test_logs\zfight_audit_s<seed>.txt.
#
#   .\tools\geometry_audit\run_world_zfight_audit.ps1               # section seed 4, every deck
#   .\tools\geometry_audit\run_world_zfight_audit.ps1 -Seed 1 -Decks 0
#   .\tools\geometry_audit\run_world_zfight_audit.ps1 -NoMission -NoLife -Limit 80
param([int]$Seed = 4, [string]$Decks = "", [switch]$NoMission, [switch]$NoLife, [int]$Limit = 40, [string]$Trace = "")
$root = Resolve-Path "$PSScriptRoot\..\.."
. "$root\godot_env.ps1"
$godot = Resolve-BabamechGodot
New-Item -ItemType Directory -Force "$root\test_logs" | Out-Null
$log = "test_logs\zfight_audit.log"
$tail = @("--", "--scene", "res://tools/geometry_audit/world_zfight_audit.tscn", "--audit-seed", "$Seed", "--audit-limit", "$Limit")
if ($Decks) { $tail += @("--audit-decks", $Decks) }
if ($NoMission) { $tail += "--audit-no-mission" }
if ($NoLife) { $tail += "--audit-no-life" }
if ($Trace) { $tail += @("--audit-trace", $Trace) }
Push-Location $root
try {
    & $godot --path . --headless --log-file $log @tail
    $code = $LASTEXITCODE
} finally { Pop-Location }
Get-Content (Join-Path $root $log) | Where-Object { $_.Contains("[zfight]") }
exit $code
