# run_chassis_compare.ps1 - Strider vs Bulwark effectiveness: paper numbers + bot-driven scenarios (headless, fixed step).
# docs/design/bulwark-effectiveness.md. Output: test_logs\balance\chassis\<Tag>.md / .json
#
#   .\tools\balance\run_chassis_compare.ps1 -Part paper
#   .\tools\balance\run_chassis_compare.ps1 -Variant base -Jobs 4
#   .\tools\balance\run_chassis_compare.ps1 -Variant c_turn -Scenarios duel_strider,city_solo
param(
	[string]$Part = "all",
	[string]$Variant = "base",
	[string]$Tag = "",
	[string[]]$Profiles = @("veteran", "average"),
	[string[]]$Seeds = @("1", "2", "5", "7"),
	[string]$Scenarios = "",
	[int]$Jobs = 4,
	[switch]$NoImport
)
$root = Resolve-Path "$PSScriptRoot\..\.."
. "$root\godot_env.ps1"
$godot = Resolve-BabamechGodot
if (-not $NoImport) { Update-BabamechImport $godot }
if ($Tag -eq "") { $Tag = $Variant }
$logDir = Join-Path $root "test_logs"
New-Item -ItemType Directory -Force -Path "$logDir\balance\chassis" | Out-Null
if (-not (Test-Path "$logDir\.gdignore")) { Set-Content -Path "$logDir\.gdignore" -Value "" }
$scene = "res://tools/balance/chassis_compare.tscn"
$base = @("--variant", $Variant, "--tag", $Tag, "--profiles", ($Profiles -join ","), "--seeds", ($Seeds -join ","))
if ($Scenarios -ne "") { $base += @("--scenarios", $Scenarios) }

if ($Part -eq "paper" -or $Jobs -le 1) {
	& $godot --path $root --headless --fixed-fps 60 -- --scene $scene --part $Part @base
	exit $LASTEXITCODE
}
$shardDir = Join-Path $logDir "balance\chassis\shards_$Tag"
if (Test-Path $shardDir) { Remove-Item -Recurse -Force $shardDir }
New-Item -ItemType Directory -Force -Path $shardDir | Out-Null
$procs = @()
for ($i = 0; $i -lt $Jobs; $i++) {
	$out = Join-Path $shardDir ("shard_{0:D2}.json" -f $i)
	$a = @("--path", "`"$root`"", "--headless", "--fixed-fps", "60", "--", "--scene", $scene, "--part", "scen") + $base + @("--shard", "$i/$Jobs", "--shard-out", "`"$out`"")
	$procs += Start-Process -FilePath $godot -ArgumentList $a -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $shardDir "shard_$i.log") -RedirectStandardError (Join-Path $shardDir "shard_$i.err")
}
$procs | Wait-Process
foreach ($p in $procs) { if ($p.ExitCode -ne 0) { Write-Warning "a shard exited $($p.ExitCode)" } }
& $godot --path $root --headless --fixed-fps 60 -- --scene $scene --part all --merge-dir "$shardDir" @base
exit $LASTEXITCODE
