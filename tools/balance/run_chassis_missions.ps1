# run_chassis_missions.ps1 - the mission bot plays whole solo missions in each chassis / loadout / seed
# (tests/chassis_eff_mission.gd, headless, fixed step, 2x sim speed) and writes one JSON per run to
# test_logs\balance\chassis\missions_<Tag>\. docs/design/bulwark-effectiveness.md.
#
#   .\tools\balance\run_chassis_missions.ps1 -Tag base -Seeds 1,2,5,7 -Jobs 4
#   .\tools\balance\run_chassis_missions.ps1 -Tag belly -Only bulwark
# Runs: strider default, strider "best", bulwark default (BotProfile kit), bulwark "best" (the loadouts below; edit or
# pass -Runs "name=chassis:{json};..." or -RunsFile with one name=chassis:{json} per line: JSON survives a file, not a
# nested -Command).
param(
	[string]$Tag = "base",
	[string[]]$Seeds = @("1", "2", "5", "7"),
	[int]$Jobs = 4,
	[string]$Only = "",
	[string]$Runs = "",
	[string]$RunsFile = ""
)
$root = Resolve-Path "$PSScriptRoot\..\.."
. "$root\godot_env.ps1"
$godot = Resolve-BabamechGodot
$outDir = Join-Path $root "test_logs\balance\chassis\missions_$Tag"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$defs = [ordered]@{
	"strider_default" = @("strider", '{}')
	"strider_best"    = @("strider", '{"side_l":"","side_r":"autocannon","shoulder_l":"autocannon","shoulder_r":"autocannon","back":"mortar"}')
	"bulwark_default" = @("bulwark", '{}')
	"bulwark_best"    = @("bulwark", '{"side_l":"gatling","side_r":"gatling","back_l":"mortar","back_r":"radiator"}')
}
if ($RunsFile -ne "") { $Runs = ((Get-Content $RunsFile) | Where-Object { $_.Trim() -ne "" }) -join ";" }
if ($Runs -ne "") {
	$defs = [ordered]@{}
	foreach ($r in ($Runs -split ';')) {
		if ($r -match '^([^=]+)=([^:]+):(.*)$') { $defs[$Matches[1]] = @($Matches[2], $Matches[3]) }
	}
}
$queue = @()
foreach ($name in $defs.Keys) {
	if ($Only -ne "" -and -not $name.StartsWith($Only)) { continue }
	foreach ($s in (($Seeds -join ",") -split ",")) { $queue += [PSCustomObject]@{ Name = $name; Chassis = $defs[$name][0]; Loadout = $defs[$name][1]; Seed = $s } }
}
$running = @()
foreach ($q in $queue) {
	while (($running | Where-Object { -not $_.HasExited }).Count -ge $Jobs) { Start-Sleep -Milliseconds 500 }
	$env:EFF_CHASSIS = $q.Chassis
	$env:EFF_LOADOUT = $q.Loadout
	$env:EFF_SEED = $q.Seed
	$env:EFF_OUT = Join-Path $outDir ("{0}_s{1}.json" -f $q.Name, $q.Seed)
	$log = Join-Path $outDir ("{0}_s{1}.log" -f $q.Name, $q.Seed)
	$running += Start-Process -FilePath $godot -ArgumentList @("--path", "`"$root`"", "--headless", "--fixed-fps", "60", "--", "--run-test", "chassis_eff_mission") -NoNewWindow -PassThru -RedirectStandardOutput $log -RedirectStandardError "$log.err"
	Write-Host "started $($q.Name) seed $($q.Seed)"
}
$running | Wait-Process
Write-Host "done: $outDir"
