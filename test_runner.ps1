# test_runner.ps1 - run headless Godot tests from tests/<name>.gd (ported from cast, minus its voice suite).
#
#   .\test_runner.ps1 -TestName test_smoke                          # one test (comma-separate several)
#   .\test_runner.ps1 -TestAll                                      # every tests\test_*.gd, in parallel
#   .\test_runner.ps1 -TestAll -NoImport                            # skip the import check
#   .\test_runner.ps1 -TestName test_net_handshake -Link coast      # a net test under one link preset only
#   .\test_runner.ps1 -Visual                                       # the VISUAL tests: real renderer, hidden window
#
# VISUAL TESTS (docs/testing.md): a test whose source declares `const VISUAL := true` needs real pixels. -TestAll skips
# it; -Visual runs every visual test (or -Visual -TestName x) one at a time WITHOUT --headless, in a 1600x900 window on a
# hidden Windows desktop (hidden_desktop.ps1, from felt / flap) so nothing shows on screen, and saves its shots to
# test_logs\shots\. Its log is test_logs\<name>.log (--log-file). It uses the GPU, so it takes the shared GPU lock
# (godot_env.ps1) and WAITS while another session renders or holds a window, and while ComfyUI listens on port 8188;
# exit 2 if the GPU stays busy past $env:CLAUDE_GPU_LOCK_TIMEOUT (default 900 s). BABAMECH_SHOW_WINDOWS=1 shows the
# window instead. Headless runs (-TestAll, -TestName) never take the lock. A visual test that ALSO declares
# `const PEERS := N` (tests	est_visual_coop.gd) runs as N windowed processes on the hidden desktop at once (host first,
# ports from Get-FreePort, logs test_logs\<name>.<role>.log), under the batch's one GPU lock, judged like a net run.
#
# SERIAL TESTS: a test whose source declares `const SERIAL := true` (a wall-clock budget, e.g. test_perf) is left out of
# the parallel batch and runs after everything else (the net runs too), one at a time, with no other test process going.
#
# Logs: test_logs\<name>.log / .err.log. A test passes only with exit code 0, the ">>> [TEST PASSED] <name> <<<"
# marker, AND no "SCRIPT ERROR" / "Parse Error" in its output. Ordinary tests run under --fixed-fps 60.
#
# NET TESTS (cast's harness): a test whose source declares `const PEERS := N` runs as N headless processes over ENet
# on localhost, a host then N-1 clients, each with
#   --run-test X --net-role host|client --net-index i --net-port P --net-peers N --net-link L
# once per link preset in its `const LINKS := [...]` (default "off" and "coast"). PORTS: several sessions run tests at
# once, so every run gets a random port in 20000-59999 that a UDP probe finds free and no other run of this runner holds
# (Get-FreePort); a run whose host fails to bind ("the host opens port") is retried on a new port, up to twice.
# Single-process tests get one too as `--net-port P` (TestCase.test_port()) for tests that open a crew. Logs: test_logs\<name>.<link>.host.log, .c1.log, ... A run passes only if EVERY process exits 0,
# the host log has the PASS marker and no log has a SCRIPT ERROR. Net runs go after the parallel batch and run in
# real time (--max-fps 60, not --fixed-fps): they measure wall clocks.
param(
    [string]$TestName = "",
    [switch]$TestAll,
    [switch]$NoImport,
    [int]$TimeoutSec = 120,
    [string]$Link = "",
    [int]$NetTimeoutSec = 90,
    [switch]$Visual
)
. "$PSScriptRoot\godot_env.ps1"
$godot = Resolve-BabamechGodot
$logDir = Join-Path $PSScriptRoot "test_logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
# Keep Godot from importing anything written here (visual tests save PNGs under test_logs\shots).
if (-not (Test-Path "$logDir\.gdignore")) { Set-Content -Path "$logDir\.gdignore" -Value "" }

if (-not $Visual -and -not $TestAll -and $TestName -eq "") {
    Write-Host "Usage: .\test_runner.ps1 -TestName <name> | -TestAll" -ForegroundColor Yellow
    Get-ChildItem "$PSScriptRoot\tests\test_*.gd" | ForEach-Object { Write-Host "  $($_.BaseName)" }
    exit 1
}
if (-not $NoImport) { Update-BabamechImport $godot }

function Start-Godot([string]$Name, [string]$Extra = "", [string]$Timing = "--fixed-fps 60", [string]$Display = "--headless") {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $godot
    $psi.Arguments = "--path `"$PSScriptRoot`" $Display $Timing -- --run-test $Name $Extra"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    return [PSCustomObject]@{ Proc = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync() }
}

function Test-Bad([string]$Text) { return $Text -match "SCRIPT ERROR|Parse Error" }

function Test-Visual([string]$Name) { return (Get-Content -Raw "$PSScriptRoot\tests\$Name.gd") -match '(?m)^const VISUAL\s*:=\s*true' }
function Test-Serial([string]$Name) { return (Get-Content -Raw "$PSScriptRoot\tests\$Name.gd") -match '(?m)^const SERIAL\s*:=\s*true' }

function Start-Test([string]$Name) {
    $g = Start-Godot $Name "--net-port $(Get-FreePort)"
    return [PSCustomObject]@{ Name = $Name; Proc = $g.Proc; Out = $g.Out; Err = $g.Err; Watch = [Diagnostics.Stopwatch]::StartNew() }
}

function Finish-Test($r) {
    $left = [Math]::Max(0, [int](($TimeoutSec - $r.Watch.Elapsed.TotalSeconds) * 1000))
    if (-not $r.Proc.WaitForExit($left)) { try { $r.Proc.Kill() } catch {}; $r.Proc.WaitForExit() }
    $out = $r.Out.Result; $err = $r.Err.Result
    Set-Content -Path "$logDir\$($r.Name).log" -Value $out
    Set-Content -Path "$logDir\$($r.Name).err.log" -Value $err
    # A script error inside a coroutine can abort a test silently and still end in a PASS marker.
    $ok = ($r.Proc.ExitCode -eq 0) -and ($out -match [regex]::Escape(">>> [TEST PASSED] $($r.Name) <<<")) -and -not (Test-Bad ($out + "`n" + $err))
    $secs = $r.Watch.Elapsed.TotalSeconds.ToString("F1")
    if ($ok) { Write-Host "  PASS  $($r.Name)  ($secs s)" -ForegroundColor Green }
    else {
        Write-Host "  FAIL  $($r.Name)  ($secs s, exit $($r.Proc.ExitCode))" -ForegroundColor Red
        ($out + "`n" + $err) -split "`n" | Where-Object { $_ -match "ASSERT FAILED|SCRIPT ERROR|Parse Error|ERROR:|TEST FAILED" } | Select-Object -First 15 | ForEach-Object { Write-Host "        $_" }
    }
    return $ok
}

# --- Net tests: several processes per run ------------------------------------------------------------

function Get-NetSpec([string]$Name) {
    $src = Get-Content -Raw "$PSScriptRoot\tests\$Name.gd"
    $m = [regex]::Match($src, '(?m)^const PEERS\s*:=\s*(\d+)')
    if (-not $m.Success) { return $null }
    $links = @("off", "coast")
    $lm = [regex]::Match($src, '(?m)^const LINKS\s*:=\s*\[([^\]]*)\]')
    if ($lm.Success) { $links = @([regex]::Matches($lm.Groups[1].Value, '"([a-z]+)"') | ForEach-Object { $_.Groups[1].Value }) }
    if ($Link -ne "") { $links = @($Link) }
    return @{ Peers = [int]$m.Groups[1].Value; Links = $links }
}

# A random UDP port that is free right now and not handed to another run of this runner (ENet binds UDP). Random over
# 40000 ports so concurrent runners in other sessions don't pick the same one; the bind retry covers the rest.
$script:usedPorts = @{}
function Get-FreePort {
    for ($try = 0; $try -lt 200; $try++) {
        $p = Get-Random -Minimum 20000 -Maximum 60000
        if ($p -eq 24600 -or $script:usedPorts.ContainsKey($p)) { continue }   # 24600: run.ps1 -Crew
        try { $u = [System.Net.Sockets.UdpClient]::new($p); $u.Close() } catch { continue }
        $script:usedPorts[$p] = $true
        return $p
    }
    throw "no free UDP port found"
}

$netTiming = "--max-fps 60"
function Start-NetRun([string]$Name, [int]$Peers, [string]$LinkName, [int]$Retry = 0) {
    $port = Get-FreePort
    $common = "--net-port $port --net-peers $Peers --net-link $LinkName"
    $procs = @()
    $procs += [PSCustomObject]@{ Role = "host"; G = (Start-Godot $Name "--net-role host --net-index 0 $common" $netTiming) }
    Start-Sleep -Milliseconds 400   # the host binds first; clients also retry while it starts
    for ($i = 1; $i -lt $Peers; $i++) {
        $procs += [PSCustomObject]@{ Role = "c$i"; G = (Start-Godot $Name "--net-role client --net-index $i $common" $netTiming) }
    }
    return [PSCustomObject]@{ Name = $Name; Link = $LinkName; Peers = $Peers; Port = $port; Retry = $Retry; Label = "$Name [$LinkName]"; Procs = $procs; Watch = [Diagnostics.Stopwatch]::StartNew() }
}

function Test-NetRunExited($run) { return @($run.Procs | Where-Object { -not $_.G.Proc.HasExited }).Count -eq 0 }

function Finish-NetRun($run) {
    $deadline = [DateTime]::Now.AddSeconds([Math]::Max(0, $NetTimeoutSec - $run.Watch.Elapsed.TotalSeconds))
    foreach ($p in $run.Procs) {
        $left = [Math]::Max(0, ($deadline - [DateTime]::Now).TotalMilliseconds)
        if (-not $p.G.Proc.WaitForExit([int]$left)) { try { $p.G.Proc.Kill() } catch {}; $p.G.Proc.WaitForExit() }
    }
    $ok = $true; $why = @()
    foreach ($p in $run.Procs) {
        $out = $p.G.Out.Result; $err = $p.G.Err.Result
        $base = "$logDir\$($run.Name).$($run.Link).$($p.Role)"
        Set-Content -Path "$base.log" -Value $out
        Set-Content -Path "$base.err.log" -Value $err
        if ($p.G.Proc.ExitCode -ne 0) { $ok = $false; $why += "$($p.Role) exit $($p.G.Proc.ExitCode)" }
        if (Test-Bad ($out + "`n" + $err)) { $ok = $false; $why += "$($p.Role) SCRIPT ERROR" }
        if ($p.Role -eq "host" -and -not ($out -match [regex]::Escape(">>> [TEST PASSED] $($run.Name) <<<"))) { $ok = $false; $why += "no PASS marker from the host" }
        $p | Add-Member -NotePropertyName Text -NotePropertyValue ($out + "`n" + $err) -Force
    }
    $secs = $run.Watch.Elapsed.TotalSeconds.ToString("F1")
    $script:usedPorts.Remove($run.Port)
    # Port taken by someone else between the probe and the host's bind: run it again on a new port.
    $hostText = ($run.Procs | Where-Object { $_.Role -eq "host" }).Text
    if (-not $ok -and $run.Retry -lt 2 -and $hostText -match "the host opens port") {
        Write-Host "  RETRY $($run.Label)  (the host could not bind port $($run.Port); new port)" -ForegroundColor Yellow
        return "retry"
    }
    if ($ok) { Write-Host "  PASS  $($run.Label)  ($secs s, $($run.Procs.Count) processes)" -ForegroundColor Green }
    else {
        Write-Host "  FAIL  $($run.Label)  ($secs s: $($why -join ', '))" -ForegroundColor Red
        foreach ($p in $run.Procs) {
            $p.Text -split "`n" | Where-Object { $_ -match "ASSERT FAILED|SCRIPT ERROR|Parse Error|ERROR:|TEST FAILED" } | Select-Object -First 8 | ForEach-Object { Write-Host "        [$($p.Role)] $_" }
        }
    }
    return $ok
}

# --- Visual net tests: several windowed processes on the hidden desktop -----------------------------------------
# A test with both `const VISUAL := true` and `const PEERS := N`, under -Visual: a host then N-1 clients, each a real
# rendered 1600x900 window on the hidden desktop (Start-HiddenDesktop, non-blocking), all under the ONE GPU lock the
# -Visual batch already holds (Start-HiddenDesktop takes none). Each writes --log-file test_logs\<name>.<role>.log
# (<name>.<link>.<role>.log when the test runs under several links). Judged like a net run: every exit code 0, the PASS
# marker from the host, no SCRIPT ERROR in any log; a host that could not bind its port is retried on a new one.
function Invoke-VisualNetRun([string]$Name, [int]$Peers, [string]$LinkName, [int]$Retry, [bool]$TagLink) {
    $port = Get-FreePort
    $common = "--net-port $port --net-peers $Peers --net-link $LinkName"
    $tag = if ($TagLink) { "$Name.$LinkName" } else { $Name }
    $label = "$Name [$LinkName]"
    $limit = [Math]::Max($NetTimeoutSec, 150)   # windows compile shaders on first draw
    $w = [Diagnostics.Stopwatch]::StartNew()
    $procs = @()
    try {
        for ($i = 0; $i -lt $Peers; $i++) {
            $role = if ($i -eq 0) { "host" } else { "c$i" }
            $netRole = if ($i -eq 0) { "--net-role host --net-index 0" } else { "--net-role client --net-index $i" }
            $log = "$logDir\$tag.$role.log"
            Remove-Item $log -ErrorAction SilentlyContinue
            $argLine = "--path `"$PSScriptRoot`" --resolution 1600x900 --position $(40 * $i),$(40 * $i) --max-fps 60 --log-file `"$log`" -- --run-test $Name $netRole $common"
            $procs += [PSCustomObject]@{ Role = $role; Log = $log; P = (Start-HiddenDesktop -Exe $godot -WorkDir $PSScriptRoot -Arguments $argLine) }
            if ($i -eq 0) { Start-Sleep -Milliseconds 400 }   # the host binds first; clients also retry while it starts
        }
        $deadline = [DateTime]::Now.AddSeconds($limit)
        foreach ($p in $procs) {
            $left = [int][Math]::Max(0, ($deadline - [DateTime]::Now).TotalMilliseconds)
            if (-not $p.P.Wait($left)) { $p.P.Kill() }
        }
        $ok = $true; $why = @(); $hostText = ""
        foreach ($p in $procs) {
            $code = $p.P.ExitCode
            $text = if (Test-Path $p.Log) { Get-Content -Raw $p.Log } else { "" }
            $p | Add-Member -NotePropertyName Text -NotePropertyValue $text -Force
            if ($code -ne 0) { $ok = $false; $why += "$($p.Role) exit $code" }
            if (Test-Bad $text) { $ok = $false; $why += "$($p.Role) SCRIPT ERROR" }
            if ($p.Role -eq "host") {
                $hostText = $text
                if (-not ($text -match [regex]::Escape(">>> [TEST PASSED] $Name <<<"))) { $ok = $false; $why += "no PASS marker from the host" }
            }
        }
    } finally {
        foreach ($p in $procs) { try { $p.P.Kill() } catch {}; $p.P.Close() }
        $script:usedPorts.Remove($port)
    }
    $secs = $w.Elapsed.TotalSeconds.ToString("F1")
    if (-not $ok -and $Retry -lt 2 -and $hostText -match "the host opens port") {
        Write-Host "  RETRY $label  (the host could not bind port $port; new port)" -ForegroundColor Yellow
        return "retry"
    }
    if ($ok) { Write-Host "  PASS  $label  ($secs s, $Peers windowed processes, visual)" -ForegroundColor Green }
    else {
        Write-Host "  FAIL  $label  ($secs s, visual: $($why -join ', '))" -ForegroundColor Red
        foreach ($p in $procs) {
            $p.Text -split "`n" | Where-Object { $_ -match "ASSERT FAILED|SCRIPT ERROR|Parse Error|ERROR:|TEST FAILED" } | Select-Object -First 8 | ForEach-Object { Write-Host "        [$($p.Role)] $_" }
        }
    }
    return $ok
}

# --- Schedule ------------------------------------------------------------------------------------

$names = if ($TestAll -or ($Visual -and $TestName -eq "")) { Get-ChildItem "$PSScriptRoot\tests\test_*.gd" | ForEach-Object { $_.BaseName } } else { @($TestName -split '[\s,]+' | Where-Object { $_ -ne "" }) }
$existing = @($names | Where-Object { Test-Path "$PSScriptRoot\tests\$_.gd" })
if ($Visual) {
    # Only visual tests, one window at a time (GPU).
    $names = @($existing | Where-Object { Test-Visual $_ })
    if ($names.Count -eq 0) { Write-Host "No visual tests (const VISUAL := true) among: $($existing -join ', ')" -ForegroundColor Yellow; exit 1 }
} elseif ($TestAll) {
    $skipped = @($existing | Where-Object { Test-Visual $_ })
    $names = @($names | Where-Object { $skipped -notcontains $_ })
    if ($skipped.Count -gt 0) { Write-Host "  (visual tests skipped, run with -Visual: $($skipped -join ', '))" -ForegroundColor DarkGray }
}
$max = if ($Visual) { 1 } else { [Math]::Max(2, [Math]::Min(12, [Environment]::ProcessorCount - 4)) }
$netMax = [Math]::Max(2, [Math]::Min(6, [int]([Environment]::ProcessorCount / 5)))
$running = @(); $failed = @(); $total = 0
$netRuns = @()
foreach ($n in $names) {
    if (-not (Test-Path "$PSScriptRoot\tests\$n.gd")) { Write-Host "  FAIL  $n  (no tests\$n.gd)" -ForegroundColor Red; $failed += $n; $total += 1; continue }
    $spec = Get-NetSpec $n
    if ($spec -ne $null) { foreach ($l in $spec.Links) { $netRuns += [PSCustomObject]@{ Name = $n; Peers = $spec.Peers; Link = $l } } }
}
$netNames = @($netRuns | ForEach-Object { $_.Name } | Select-Object -Unique)
$parallel = @($names | Where-Object { $netNames -notcontains $_ -and (Test-Path "$PSScriptRoot\tests\$_.gd") })
if ($Visual) {
    # Visual tests: one at a time, windowed (real renderer) on the hidden desktop; output comes back through --log-file.
    . "$PSScriptRoot\hidden_desktop.ps1"
    # One GPU lock for the whole batch (waits for other sessions' renders / windows; docs/testing.md "GPU sharing").
    if (-not (Enter-BabamechGpu "visual tests")) {
        Write-Host "Refusing -Visual: the GPU stayed busy (see above). Run headless tests, or retry later." -ForegroundColor Yellow
        exit 2
    }
    try {
        # Visual NET tests (VISUAL and PEERS): N windowed processes on the hidden desktop at once, under this one lock.
        foreach ($vr in $netRuns) {
            $res = "retry"; $retry = 0
            while ($res -is [string] -and $retry -le 2) {
                $res = Invoke-VisualNetRun $vr.Name $vr.Peers $vr.Link $retry ($netRuns.Count -gt 1)
                $retry += 1
            }
            $total += 1
            if ($res -isnot [bool] -or -not $res) { $failed += "$($vr.Name) [$($vr.Link)]" }
        }
        $netRuns = @()
        foreach ($n in $parallel) {
            $log = "$logDir\$n.log"
            Remove-Item $log -ErrorAction SilentlyContinue
            $w = [Diagnostics.Stopwatch]::StartNew()
            $code = Invoke-HiddenDesktop -Exe $godot -WorkDir $PSScriptRoot -TimeoutSec $TimeoutSec `
                -Arguments "--path `"$PSScriptRoot`" --resolution 1600x900 --fixed-fps 60 --log-file `"$log`" -- --run-test $n"
            $out = if (Test-Path $log) { Get-Content -Raw $log } else { "" }
            $total += 1
            $ok = ($code -eq 0) -and ($out -match [regex]::Escape(">>> [TEST PASSED] $n <<<")) -and -not (Test-Bad $out)
            $secs = $w.Elapsed.TotalSeconds.ToString("F1")
            if ($ok) { Write-Host "  PASS  $n  ($secs s, visual)" -ForegroundColor Green }
            else {
                $failed += $n
                Write-Host "  FAIL  $n  ($secs s, exit $code, visual)" -ForegroundColor Red
                $out -split "`n" | Where-Object { $_ -match "ASSERT FAILED|SCRIPT ERROR|Parse Error|ERROR:|TEST FAILED" } | Select-Object -First 15 | ForEach-Object { Write-Host "        $_" }
            }
        }
    } finally { Exit-BabamechGpu }
    $parallel = @()
}
# SERIAL tests (wall-clock budgets) run last, one at a time, with nothing else going.
$serial = @($parallel | Where-Object { Test-Serial $_ })
$parallel = @($parallel | Where-Object { $serial -notcontains $_ })
foreach ($n in $parallel) {
    while ($true) {
        $done = @($running | Where-Object { $_.Proc.HasExited -or $_.Watch.Elapsed.TotalSeconds -gt $TimeoutSec })
        foreach ($r in $done) {
            $total += 1
            if (-not (Finish-Test $r)) { $failed += $r.Name }
            $running = @($running | Where-Object { $_ -ne $r })
        }
        if ($running.Count -lt $max) { break }
        Start-Sleep -Milliseconds 100
    }
    $running += Start-Test $n
}
foreach ($r in $running) { $total += 1; if (-not (Finish-Test $r)) { $failed += $r.Name } }

if ($netRuns.Count -gt 0) {
    $netWatch = [Diagnostics.Stopwatch]::StartNew()
    $queue = [System.Collections.ArrayList]@($netRuns)
    $active = @()
    while ($queue.Count -gt 0 -or $active.Count -gt 0) {
        while ($queue.Count -gt 0 -and $active.Count -lt $netMax) {
            $next = $queue[0]; $queue.RemoveAt(0)
            $active += Start-NetRun $next.Name $next.Peers $next.Link $next.Retry
        }
        $doneRun = $active | Where-Object { (Test-NetRunExited $_) -or $_.Watch.Elapsed.TotalSeconds -gt $NetTimeoutSec } | Select-Object -First 1
        if ($doneRun -eq $null) { Start-Sleep -Milliseconds 100; continue }
        $res = Finish-NetRun $doneRun
        if ($res -is [string]) {   # "retry" ($true -eq "retry" is true in PowerShell, so test the type)
            $queue.Insert(0, [PSCustomObject]@{ Name = $doneRun.Name; Peers = $doneRun.Peers; Link = $doneRun.Link; Retry = $doneRun.Retry + 1 })
        } else {
            $total += 1
            if (-not $res) { $failed += $doneRun.Label }
        }
        $active = @($active | Where-Object { $_ -ne $doneRun })
    }
    Write-Host "  net runs: $($netRuns.Count) in $($netWatch.Elapsed.TotalSeconds.ToString('F1')) s ($netMax at a time)" -ForegroundColor DarkCyan
}

foreach ($n in $serial) {
    $r = Start-Test $n
    $r.Proc.WaitForExit($TimeoutSec * 1000) | Out-Null
    $total += 1
    if (-not (Finish-Test $r)) { $failed += $n }
}

if ($failed.Count -gt 0) { Write-Host "$($failed.Count) of $total test(s) FAILED: $($failed -join ', ')" -ForegroundColor Red; exit 1 }
Write-Host "All $total test(s) passed." -ForegroundColor Green
if ($Visual) { Write-Host "Shots: $logDir\shots" -ForegroundColor DarkCyan }
exit 0
