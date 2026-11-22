# run_city_perf.ps1 - the city render / physics cost probe (tools/city_perf/city_perf.gd) in a REAL renderer on the hidden
# desktop (never a visible window). Takes the shared GPU lock and waits its turn (godot_env.ps1). Results: the
# "[cityperf]" lines of test_logs\city_perf.log.
#
#   .\tools\city_perf\run_city_perf.ps1              # section seed 4
#   .\tools\city_perf\run_city_perf.ps1 -Seed 1
#   .\tools\city_perf\run_city_perf.ps1 -Headless    # no GPU: build time, memory and physics are valid, frame times are not
#   .\tools\city_perf\run_city_perf.ps1 -Headless -Drive   # the headless test drive, district vs stack (frame ms, city ticks)
param([int]$Seed = 4, [int]$TimeoutSec = 300, [switch]$Headless, [switch]$Drive)
$root = Resolve-Path "$PSScriptRoot\..\.."
. "$root\godot_env.ps1"
. "$root\hidden_desktop.ps1"
$godot = Resolve-BabamechGodot
New-Item -ItemType Directory -Force "$root\test_logs" | Out-Null
$log = "test_logs\city_perf.log"
$tail = "-- --scene res://tools/city_perf/city_perf.tscn --perf-seed $Seed" + $(if ($Drive) { " --perf-drive" } else { "" })
Push-Location $root
try {
    if ($Headless) {
        & $godot --path . --headless --fixed-fps 60 --log-file $log $tail.Split(' ')
        $code = $LASTEXITCODE
    } else {
        $code = Invoke-HiddenDesktop -Exe $godot -Arguments "--path . --resolution 1600x900 --log-file $log $tail" -TimeoutSec $TimeoutSec
    }
} finally { Pop-Location }
Get-Content (Join-Path $root $log) | Where-Object { $_.Contains("[cityperf]") }
exit $code
