# run.ps1 - play babamech (windowed). Extra args go to the game (known Godot engine options such as --log-file,
# --resolution, --headless go to the engine, before "--"), e.g.
#   .\run.ps1 --scene res://scenes/lab.tscn
#   .\run.ps1 --menu-shot C:\shots\menu.png      # save the menu after --menu-after s (default 1.5) and quit
#
# A local crew over ENet (no Steam needed), one window per player (from cast):
#   .\run.ps1 -Crew 2                 # a host and one joiner, both on the hangar screen with the crew line-up
#   .\run.ps1 -Crew 4 -Link coast     # four players, every window simulating a coast-to-coast link
#   .\run.ps1 -Crew 2 -Size 1280x720  # bigger windows (default 800x450)
#   .\run.ps1 -Crew 3 -JoinLate 10    # the last window joins 10 s later
#   .\run.ps1 -Crew 2 -ShotDir C:\shots   # each window saves <Name>.png once the crew is in, then quits
# Players are Host, Crew2, Crew3, Crew4 with the heads chicken, pickle, corn, dog; each window keeps its own
# settings file (user://settings_<name>.cfg), so a crew run never touches your own settings. Extra args go to every window.
#
# GPU sharing: windows use the GPU, so this takes the shared GPU lock (godot_env.ps1) first and WAITS while another
# session renders (ComfyUI, port 8188) or runs visual tests. A single window holds the lock until it closes (this script
# blocks meanwhile); crew windows hold it until the last one closes. Close windows when done: renders wait on them.
.  "$PSScriptRoot\godot_env.ps1"
$godot = Resolve-BabamechGodot
Update-BabamechImport $godot

$crew = 0; $link = ""; $shotDir = ""; $size = "800x450"; $late = 0.0; $rest = @()
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq "-Crew" -and $i + 1 -lt $args.Count) { $crew = [int]$args[$i + 1]; $i++ }
    elseif ($args[$i] -eq "-Link" -and $i + 1 -lt $args.Count) { $link = [string]$args[$i + 1]; $i++ }
    elseif ($args[$i] -eq "-ShotDir" -and $i + 1 -lt $args.Count) { $shotDir = [string]$args[$i + 1]; $i++ }
    elseif ($args[$i] -eq "-Size" -and $i + 1 -lt $args.Count) { $size = [string]$args[$i + 1]; $i++ }
    elseif ($args[$i] -eq "-JoinLate" -and $i + 1 -lt $args.Count) { $late = [double]$args[$i + 1]; $i++ }
    elseif ($args[$i] -eq "-TestDrive") { $rest += @("--scene", "res://scenes/test_drive.tscn") }
    elseif ($args[$i] -eq "-Seed" -and $i + 1 -lt $args.Count) { $rest += @("--seed", [string]$args[$i + 1]); $i++ }
    elseif ($args[$i] -is [array]) { $rest += ($args[$i] -join ",") }
    else { $rest += $args[$i] }
}
# Godot engine options go BEFORE "--" (after it Godot hands everything to the game as user args, so e.g. --log-file
# would be ignored); everything else goes after it, to the game.
$engineValue = @("--log-file", "--resolution", "--position", "--path", "--rendering-driver", "--rendering-method",
    "--display-driver", "--audio-driver", "--screen", "--max-fps", "--fixed-fps", "--time-scale", "--frame-delay",
    "--xr-mode", "--tablet-driver", "--text-driver", "--quit-after")
$engineFlag = @("--headless", "--verbose", "-v", "--quiet", "-q", "--fullscreen", "-f", "--maximized", "-m",
    "--windowed", "-w", "--always-on-top", "-t", "--debug", "-d", "--print-fps", "--disable-vsync", "--gpu-validation",
    "--single-window", "--quit", "--debug-collisions", "--debug-navigation", "--disable-crash-handler")
$engine = @(); $game = @()
for ($i = 0; $i -lt $rest.Count; $i++) {
    $a = [string]$rest[$i]
    if ($engineValue -contains $a -and $i + 1 -lt $rest.Count) { $engine += @($a, [string]$rest[$i + 1]); $i++ }
    elseif ($engineFlag -contains $a) { $engine += $a }
    else { $game += $a }
}
$rest = $game
$gpu = $engine -notcontains "--headless"
$what = "$(if ($crew -ge 2) { "crew of $crew" } else { 'game window' }) $(($engine + $rest) -join ' ')".Trim()
if ($gpu -and -not (Enter-BabamechGpu $what)) {
    Write-Host "Not opening a window: the GPU stayed busy (see above)." -ForegroundColor Yellow
    exit 2
}
if ($crew -lt 2) {
    try { & $godot --path $PSScriptRoot @engine -- @rest } finally { if ($gpu) { Exit-BabamechGpu } }
    exit $LASTEXITCODE
}
if ($crew -gt 4) { Write-Host "A crew is at most 4 (a 5th window would be refused: Crew is full)." -ForegroundColor Yellow }

$port = 24600
$common = @("--net-port", "$port")
if ($link -ne "") { $common += @("--net-link", $link) }
$heads = @("chicken", "pickle", "corn", "dog", "chicken")
$w = [int]($size -split "x")[0]; $h = [int]($size -split "x")[1]
function Start-Player([int]$n, [string[]]$gameArgs, [string]$who) {
    $x = 40 + (($n - 1) % 2) * ($w + 20); $y = 40 + [Math]::Floor(($n - 1) / 2) * ($h + 30)
    $all = @("--path", "`"$PSScriptRoot`"", "--resolution", $size, "--position", "$x,$y") + $engine + @("--") + $gameArgs + $common + `
        @("--net-name", $who, "--head", $heads[($n - 1) % $heads.Count], "--settings-file", "user://settings_$($who.ToLower()).cfg") + $rest
    if ($shotDir -ne "") { New-Item -ItemType Directory -Force -Path $shotDir | Out-Null; $all += @("--crew-shot", "`"$shotDir\$who.png`"", "--crew-size", "$crew") }
    return Start-Process -FilePath $godot -ArgumentList $all -PassThru
}
try {
    $procs = @(Start-Player 1 @("--net-host") "Host")
    Start-Sleep -Seconds 2
    for ($n = 2; $n -le $crew; $n++) {
        if ($late -gt 0 -and $n -eq $crew) {
            Write-Host "Window $n joins in $late s..."
            Start-Sleep -Milliseconds ([int]($late * 1000))
        }
        $procs += Start-Player $n @("--net-join", "127.0.0.1:$port") "Crew$n"
    }
    if ($gpu) { Move-BabamechGpu @($procs | ForEach-Object { $_.Id }) $what }   # held until every window closes
} finally { if ($gpu) { Exit-BabamechGpu } }   # no-op once handed to the windows; frees it if starting failed
Write-Host "Started $crew windows on port $port$(if ($link) { " (link: $link)" }). Close them to stop."
