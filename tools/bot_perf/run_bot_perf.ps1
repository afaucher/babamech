# run_bot_perf.ps1 - host CPU cost per frame with N hangar bots (tests/bench_bot_perf.gd), headless (no GPU lock),
# alternating bot counts on the same seed, then the MEDIAN over runs of every "[botperf]" key's avg / p95 / max.
# The machine is shared with other sessions: compare medians, and look at the spread (min..max of the run averages).
#
#   .\tools\bot_perf\run_bot_perf.ps1                       # 0 and 3 bots, 3 runs each, seed 11, 1800 frames
#   .\tools\bot_perf\run_bot_perf.ps1 -Bots 0,1,3 -Runs 2 -Seed 4 -Frames 3600
# Raw logs: test_logs\bot_perf_<bots>b_<i>.log
param([int[]]$Bots = @(0, 3), [int]$Runs = 3, [int]$Seed = 11, [int]$Frames = 1800, [int]$Warm = 300,
      [string]$Skill = "veteran", [int]$TimeoutSec = 400, [string]$ProjectPath = "", [switch]$Windowed)
# -ProjectPath: run a snapshot copy of the project instead (other sessions edit this tree mid-run; a frozen copy keeps
# every run on the same code). Logs still go to this checkout's test_logs.
# -Windowed: real renderer (1600x900, vsync off) on the hidden desktop under the GPU lock: adds render.* keys (draw
# calls, objects, primitives, viewport CPU / GPU ms). Keep it short (-Runs 1 -Frames 900): renders wait on it.
$root = Resolve-Path "$PSScriptRoot\..\.."
. "$root\godot_env.ps1"
if ($Windowed) { . "$root\hidden_desktop.ps1" }
$godot = Resolve-BabamechGodot
$proj = if ($ProjectPath) { $ProjectPath } else { "$root" }
if ($ProjectPath) { & $godot --path $proj --headless --import 2>&1 | Out-Null } else { Update-BabamechImport $godot }   # class cache
New-Item -ItemType Directory -Force "$root\test_logs" | Out-Null
$env:BOT_PERF_SEED = "$Seed"; $env:BOT_PERF_FRAMES = "$Frames"; $env:BOT_PERF_WARM = "$Warm"; $env:BOT_PERF_SKILL = $Skill
$data = @{}   # "<bots>|key" -> list of [avg, p95, max, calls]
for ($i = 1; $i -le $Runs; $i++) {
    foreach ($b in $Bots) {
        $env:BOT_PERF_BOTS = "$b"
        $tag = if ($Windowed) { "w" } else { "" }
        $log = Join-Path $root "test_logs\bot_perf_${b}b${tag}_$i.log"
        $port = Get-Random -Minimum 30000 -Maximum 59000
        if ($Windowed) {
            # A real renderer on the hidden desktop, under the shared GPU lock (waits its turn; released after each run).
            $code = Invoke-HiddenDesktop -Exe $godot -WorkDir $proj -TimeoutSec $TimeoutSec `
                -Arguments "--path `"$proj`" --resolution 1600x900 --fixed-fps 60 --log-file `"$log`" -- --run-test bench_bot_perf --net-port $port"
            if (-not (Test-Path $log)) { Write-Host "bots $b run $i (windowed): no log (exit $code)"; continue }
        } else {
            $p = Start-Process -FilePath $godot -ArgumentList "--path `"$proj`" --headless --fixed-fps 60 --log-file `"$log`" -- --run-test bench_bot_perf --net-port $port" `
                -NoNewWindow -PassThru -RedirectStandardOutput "$log.out" -RedirectStandardError "$log.err"
            if (-not $p.WaitForExit($TimeoutSec * 1000)) { $p.Kill(); Write-Host "bots $b run $i timed out"; continue }
        }
        foreach ($line in Get-Content $log) {
            if ($line -match '^\[botperf\] (\S+)\s+avg=\s*([\d.]+) p95=\s*([\d.]+) max=\s*([\d.]+)(?: calls/frame=([\d.]+))?') {
                $k = "$b|$($Matches[1])"
                if (-not $data.ContainsKey($k)) { $data[$k] = @() }
                $c = if ($Matches[5]) { [double]$Matches[5] } else { -1 }
                $data[$k] += , @([double]$Matches[2], [double]$Matches[3], [double]$Matches[4], $c)
            } elseif ($line -match '^\[botperf\] (enemies|codec|bot |seed)') { Write-Host "bots $b run ${i}: $line" }
            elseif ($line -match 'SCRIPT ERROR|Parse Error|FAIL') { Write-Host "bots $b run ${i}: $line" }
        }
    }
}
function Median([double[]]$v) { $s = $v | Sort-Object; if ($s.Count -eq 0) { return 0 }; return $s[[int][Math]::Floor($s.Count / 2)] }
$keys = $data.Keys | ForEach-Object { ($_ -split '\|', 2)[1] } | Sort-Object -Unique
$out = foreach ($k in $keys) {
    $row = [ordered]@{ Key = $k }
    foreach ($b in $Bots) {
        $v = $data["$b|$k"]
        if (-not $v) { continue }
        $avgs = $v | ForEach-Object { $_[0] }
        $row["${b}b avg"] = "{0:N3}" -f (Median $avgs)
        $row["${b}b spread"] = "{0:N2}..{1:N2}" -f ($avgs | Measure-Object -Minimum).Minimum, ($avgs | Measure-Object -Maximum).Maximum
        $row["${b}b p95"] = "{0:N3}" -f (Median ($v | ForEach-Object { $_[1] }))
        $row["${b}b max"] = "{0:N2}" -f (Median ($v | ForEach-Object { $_[2] }))
        $cs = $v | ForEach-Object { $_[3] } | Where-Object { $_ -ge 0 }
        if ($cs) { $row["${b}b calls"] = "{0:N2}" -f (Median $cs) }
    }
    [PSCustomObject]$row
}
$out | Format-Table -AutoSize | Out-String -Width 300 | Write-Host
