# run_city_perf.ps1 - the city render / physics cost probe (tools/city_perf/city_perf.gd) in a REAL renderer on the hidden
# desktop (never a visible window). Takes the shared GPU lock and waits its turn (godot_env.ps1). Results: the
# "[cityperf]" lines of test_logs\city_perf.log.
#
#   .\tools\city_perf\run_city_perf.ps1              # section seed 4
#   .\tools\city_perf\run_city_perf.ps1 -Seed 1
#   .\tools\city_perf\run_city_perf.ps1 -Headless    # no GPU: build time, memory and physics are valid, frame times are not
#   .\tools\city_perf\run_city_perf.ps1 -Headless -Drive   # the headless test drive, district vs stack (frame ms, city ticks)
#   .\tools\city_perf\run_city_perf.ps1 -Quality all       # the stack at HIGH / MEDIUM / LOW (CityQuality), same cameras
#   .\tools\city_perf\run_city_perf.ps1 -Quality 0 -Resolution 1280x720   # one level (0 low, 1 medium, 2 high), 1280x720
# With -Quality the log is test_logs\city_perf_quality_<resolution>.log.
param([int]$Seed = 4, [int]$TimeoutSec = 300, [switch]$Headless, [switch]$Drive, [string]$Quality = "", [string]$Resolution = "1600x900")
$root = Resolve-Path "$PSScriptRoot\..\.."
. "$root\godot_env.ps1"
. "$root\hidden_desktop.ps1"
$godot = Resolve-BabamechGodot
New-Item -ItemType Directory -Force "$root\test_logs" | Out-Null
$log = if ($Quality) { "test_logs\city_perf_quality_$Resolution.log" } else { "test_logs\city_perf.log" }
$tail = "-- --scene res://tools/city_perf/city_perf.tscn --perf-seed $Seed" + $(if ($Drive) { " --perf-drive" } else { "" }) + $(if ($Quality) { " --perf-quality $Quality --perf-size $Resolution" } else { "" })
Push-Location $root
try {
    if ($Headless) {
        & $godot --path . --headless --fixed-fps 60 --log-file $log $tail.Split(' ')
        $code = $LASTEXITCODE
    } else {
        $code = Invoke-HiddenDesktop -Exe $godot -Arguments "--path . --resolution $Resolution --log-file $log $tail" -TimeoutSec $TimeoutSec
    }
} finally { Pop-Location }
Get-Content (Join-Path $root $log) | Where-Object { $_.Contains("[cityperf]") }
exit $code
