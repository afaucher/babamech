# run_balance.ps1 - Run headless babamech Combat Balance Simulator and print Markdown/CSV/JSON scorecard.
#
# Examples:
#   .\tools\balance\run_balance.ps1
#   .\tools\balance\run_balance.ps1 -Suite duels -Profile rookie,average,veteran
#   .\tools\balance\run_balance.ps1 -Suite city -Seeds 1..5 -Profile average,veteran
#   .\tools\balance\run_balance.ps1 -SaveBaseline test_logs\balance\base.json
#   .\tools\balance\run_balance.ps1 -Override "enemy_bolter.damage=28,turret.base_hp=120" -Baseline test_logs\balance\base.json
param(
	[string]$Suite = "quick",
	[string]$Profile = "",
	[string]$Seeds = "",
	[string]$Loadout = "",
	[string]$Override = "",
	[string]$Baseline = "",
	[string]$SaveBaseline = "",
	[string]$OutDir = "",
	[int]$Jobs = 0,
	[switch]$NoImport
)

$root = Resolve-Path "$PSScriptRoot\..\.."
. "$root\godot_env.ps1"
$godot = Resolve-BabamechGodot

if (-not $NoImport) {
	Update-BabamechImport $godot
}

$logDir = Join-Path $root "test_logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
if (-not (Test-Path "$logDir\.gdignore")) {
	Set-Content -Path "$logDir\.gdignore" -Value ""
}

if ($Jobs -le 0) {
	$Jobs = if ($Suite -in @("quick", "coop", "full")) { [Math]::Min(4, [Math]::Max(1, [int]([Environment]::ProcessorCount / 4))) } else { 1 }
}

$baseArgs = @("--suite", $Suite)
if ($Profile -ne "") { $baseArgs += @("--profile", $Profile) }
if ($Seeds -ne "") { $baseArgs += @("--seeds", $Seeds) }
if ($Loadout -ne "") { $baseArgs += @("--loadout", $Loadout) }
if ($Override -ne "") { $baseArgs += @("--override", $Override) }
if ($Baseline -ne "") { $baseArgs += @("--baseline", (Resolve-Path $Baseline).Path) }
if ($SaveBaseline -ne "") {
	$sbFull = if ([System.IO.Path]::IsPathRooted($SaveBaseline)) { $SaveBaseline } else { Join-Path $root $SaveBaseline }
	$baseArgs += @("--save-baseline", $sbFull)
}
if ($OutDir -ne "") {
	$odFull = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $root $OutDir }
	$baseArgs += @("--out-dir", $odFull)
}

if ($Jobs -le 1) {
	& $godot --path $root --headless --fixed-fps 60 -- --scene res://tools/balance/balance_sim.tscn @baseArgs
	exit $LASTEXITCODE
}

$watch = [Diagnostics.Stopwatch]::StartNew()
$shardDir = Join-Path $logDir "balance\shards"
if (Test-Path $shardDir) { Remove-Item -Recurse -Force $shardDir }
New-Item -ItemType Directory -Force -Path $shardDir | Out-Null

$procs = @()
for ($i = 0; $i -lt $Jobs; $i++) {
	$sOut = Join-Path $shardDir ("shard_{0:D2}.json" -f $i)
	$aList = @("--path", $root, "--headless", "--fixed-fps", "60", "--", "--scene", "res://tools/balance/balance_sim.tscn") + $baseArgs + @("--shard", "$i/$Jobs", "--shard-out", $sOut)
	$psi = New-Object System.Diagnostics.ProcessStartInfo
	$psi.FileName = $godot
	$psi.Arguments = ($aList | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
	$psi.UseShellExecute = $false
	$psi.CreateNoWindow = $true
	$psi.RedirectStandardOutput = $true
	$psi.RedirectStandardError = $true
	$p = New-Object System.Diagnostics.Process
	$p.StartInfo = $psi
	[void]$p.Start()
	$procs += [PSCustomObject]@{ Proc = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync() }
}
$bad = $false
foreach ($pr in $procs) {
	$pr.Proc.WaitForExit()
	if ($pr.Proc.ExitCode -ne 0) { $bad = $true; Write-Error $pr.Err.Result }
}
$watch.Stop()
if ($bad) { exit 1 }

$mergeArgs = $baseArgs + @("--merge-dir", $shardDir, "--elapsed", $watch.Elapsed.TotalSeconds.ToString("F2", [Globalization.CultureInfo]::InvariantCulture))
& $godot --path $root --headless --fixed-fps 60 -- --scene res://tools/balance/balance_sim.tscn @mergeArgs
exit $LASTEXITCODE
