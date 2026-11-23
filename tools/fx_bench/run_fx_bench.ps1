# run_fx_bench.ps1 - CombatWorld effects micro-benchmark (tests/bench_combat_fx.gd: test_perf's combat load with
# CombatWorld.profiling on), headless, N runs one after another, then the MEDIAN over runs of every "[fxbench]" key's
# avg and max ms per frame. The machine is shared: compare medians before / after a change, never single runs.
#
#   .\tools\fx_bench\run_fx_bench.ps1            # 5 runs
#   .\tools\fx_bench\run_fx_bench.ps1 -Runs 3 -Tag after
# Raw logs: test_logs\fx_bench_<tag>_<i>.log
param([int]$Runs = 5, [string]$Tag = "run", [int]$TimeoutSec = 180, [switch]$UserLoadout)
# -UserLoadout: fly the saved hangar loadout (what test_perf flies) instead of the bench's fixed one.
if ($UserLoadout) { $env:FX_BENCH_LOADOUT = "user" } else { Remove-Item Env:FX_BENCH_LOADOUT -ErrorAction SilentlyContinue }
$root = Resolve-Path "$PSScriptRoot\..\.."
. "$root\godot_env.ps1"
$godot = Resolve-BabamechGodot
New-Item -ItemType Directory -Force "$root\test_logs" | Out-Null
$rows = @{}      # key -> list of [avg, max, calls]
$crows = @{}     # [fxbench-call] key -> list of [med, p95, max, calls] (usec per call)
$heads = @(); $rheads = @()
for ($i = 1; $i -le $Runs; $i++) {
    $log = Join-Path $root "test_logs\fx_bench_${Tag}_$i.log"
    $p = Start-Process -FilePath $godot -ArgumentList "--path `"$root`" --headless --fixed-fps 60 --log-file `"$log`" -- --run-test bench_combat_fx" `
        -NoNewWindow -PassThru -RedirectStandardOutput "$log.out" -RedirectStandardError "$log.err"
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { $p.Kill(); Write-Host "run $i timed out"; continue }
    foreach ($line in Get-Content $log) {
        if ($line -match '^\[fxbench\] CombatWorld') { $heads += $line; Write-Host "run ${i}: $line" }
        elseif ($line -match '^\[fxbench\] WeaponRack') { $rheads += $line; Write-Host "run ${i}: $line" }
        elseif ($line -match '^\[fxbench\] rack spike') { Write-Host "run ${i}: $line" }
        elseif ($line -match '^\[fxbench\] (\S+)\s+avg=\s*([\d.]+) ms\s+max=\s*([\d.]+) ms\s+calls/frame=\s*([\d.]+)') {
            if (-not $rows.ContainsKey($Matches[1])) { $rows[$Matches[1]] = @() }
            $rows[$Matches[1]] += , @([double]$Matches[2], [double]$Matches[3], [double]$Matches[4])
        }
        elseif ($line -match '^\[fxbench-call\] (\S+)\s+med=\s*(\d+) us\s+p95=\s*(\d+) us\s+max=\s*(\d+) us\s+calls=(\d+)') {
            if (-not $crows.ContainsKey($Matches[1])) { $crows[$Matches[1]] = @() }
            $crows[$Matches[1]] += , @([double]$Matches[2], [double]$Matches[3], [double]$Matches[4], [double]$Matches[5])
        }
        elseif ($line -match '^\[fxbench\] (live|loadout|encounter|targets)') { if ($i -eq 1) { Write-Host $line } }
    }
}
function Median([double[]]$v) { $s = $v | Sort-Object; if ($s.Count -eq 0) { return 0 }; return $s[[int][Math]::Floor($s.Count / 2)] }
$avgs = @(); $p95s = @(); $maxs = @()
foreach ($h in $heads) {
    if ($h -match 'avg=([\d.]+) p50=([\d.]+) p95=([\d.]+) max=([\d.]+)') { $avgs += [double]$Matches[1]; $p95s += [double]$Matches[3]; $maxs += [double]$Matches[4] }
}
Write-Host ("MEDIAN over {0} runs  CombatWorld.advance avg={1:N3} p95={2:N3} max={3:N3} ms" -f $avgs.Count, (Median $avgs), (Median $p95s), (Median $maxs))
$ra = @(); $rm = @()
foreach ($h in $rheads) { if ($h -match 'avg=([\d.]+) p50=([\d.]+) p95=([\d.]+) max=([\d.]+)') { $ra += [double]$Matches[1]; $rm += [double]$Matches[4] } }
Write-Host ("MEDIAN over {0} runs  WeaponRack.step avg={1:N3} max={2:N3} ms" -f $ra.Count, (Median $ra), (Median $rm))
$out = foreach ($k in $rows.Keys) {
    $v = $rows[$k]
    [PSCustomObject]@{ Key = $k; AvgMs = (Median ($v | ForEach-Object { $_[0] })); MaxMs = (Median ($v | ForEach-Object { $_[1] })); CallsPerFrame = (Median ($v | ForEach-Object { $_[2] })) }
}
$out | Sort-Object AvgMs -Descending | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$cout = foreach ($k in $crows.Keys) {
    $v = $crows[$k]
    [PSCustomObject]@{ PerCall = $k; MedUs = (Median ($v | ForEach-Object { $_[0] })); P95Us = (Median ($v | ForEach-Object { $_[1] })); MaxUs = (Median ($v | ForEach-Object { $_[2] })); Calls = (Median ($v | ForEach-Object { $_[3] })) }
}
if ($cout) { Write-Host "Per call (median over runs of each run's median / p95 / max, usec):"; $cout | Sort-Object PerCall | Format-Table -AutoSize | Out-String -Width 200 | Write-Host }
