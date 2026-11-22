# run.ps1 - play babamech (windowed). Extra args go to the game, e.g.
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
# GPU sharing: windows use the GPU. If ComfyUI (port 8188) is rendering, close it first or stick to tests (headless).
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
    elseif ($args[$i] -is [array]) { $rest += ($args[$i] -join ",") }
    else { $rest += $args[$i] }
}
if ($crew -lt 2) {
    & $godot --path $PSScriptRoot -- @rest
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
    $all = @("--path", "`"$PSScriptRoot`"", "--resolution", $size, "--position", "$x,$y", "--") + $gameArgs + $common + `
        @("--net-name", $who, "--head", $heads[($n - 1) % $heads.Count], "--settings-file", "user://settings_$($who.ToLower()).cfg") + $rest
    if ($shotDir -ne "") { New-Item -ItemType Directory -Force -Path $shotDir | Out-Null; $all += @("--crew-shot", "`"$shotDir\$who.png`"", "--crew-size", "$crew") }
    return Start-Process -FilePath $godot -ArgumentList $all -PassThru
}
$procs = @(Start-Player 1 @("--net-host") "Host")
Start-Sleep -Seconds 2
for ($n = 2; $n -le $crew; $n++) {
    if ($late -gt 0 -and $n -eq $crew) {
        Write-Host "Window $n joins in $late s..."
        Start-Sleep -Milliseconds ([int]($late * 1000))
    }
    $procs += Start-Player $n @("--net-join", "127.0.0.1:$port") "Crew$n"
}
Write-Host "Started $crew windows on port $port$(if ($link) { " (link: $link)" }). Close them to stop."
