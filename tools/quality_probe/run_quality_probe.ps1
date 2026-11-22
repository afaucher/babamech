# run_quality_probe.ps1 - graphics quality probe (tools/quality_probe/quality_probe.gd): the solo stack test drive at
# HIGH / MEDIUM / LOW (GraphicsQuality viewport settings + CityQuality), frame and GPU ms, a shot per level in
# test_logs\shots\quality_<renderer>_<level>.png. REAL renderer on the hidden desktop (never a visible window); takes the
# shared GPU lock and waits its turn (godot_env.ps1).
#
#   .\tools\quality_probe\run_quality_probe.ps1                   # Forward+ (the project's renderer)
#   .\tools\quality_probe\run_quality_probe.ps1 -Compatibility    # --rendering-method gl_compatibility
param([switch]$Compatibility, [string]$Resolution = "1600x900", [int]$TimeoutSec = 300)
$root = Resolve-Path "$PSScriptRoot\..\.."
. "$root\godot_env.ps1"
. "$root\hidden_desktop.ps1"
$godot = Resolve-BabamechGodot
New-Item -ItemType Directory -Force "$root\test_logs" | Out-Null
$tag = if ($Compatibility) { "compat" } else { "forward" }
$log = "test_logs\quality_probe_$tag.log"
$engine = "--path . --resolution $Resolution --log-file $log" + $(if ($Compatibility) { " --rendering-method gl_compatibility" } else { "" })
$tail = "-- --scene res://tools/quality_probe/quality_probe.tscn --settings-file user://qprobe_settings.cfg"
Push-Location $root
try { $code = Invoke-HiddenDesktop -Exe $godot -Arguments "$engine $tail" -TimeoutSec $TimeoutSec } finally { Pop-Location }
Get-Content (Join-Path $root $log) | Where-Object { $_.Contains("[qprobe]") -or $_.Contains("ERROR") -or $_.Contains("SCRIPT ERROR") }
exit $code
