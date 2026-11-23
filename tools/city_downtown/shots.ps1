# shots.ps1 - downtown pass 2 shots (docs/design/city-downtown.md section 6), each on the hidden desktop (GPU lock).
#   .\tools\city_downtown\shots.ps1                 # every shot
#   .\tools\city_downtown\shots.ps1 -Only street_eye
param([string]$Only = "", [string]$Prefix = "pass2")
$root = Resolve-Path "$PSScriptRoot\..\.."
Push-Location $root
try {
    . .\godot_env.ps1
    . .\hidden_desktop.ps1
    $g = Resolve-BabamechGodot
    $shots = [ordered]@{
        "avenue"     = @("docs/design/city-downtown/${Prefix}_avenue.png", "site=section,seed=4,deck=2,camera=downtown_avenue")
        "perch"      = @("docs/design/city-downtown/${Prefix}_perch.png", "site=section,seed=4,deck=2,camera=downtown_perch")
        "plaza"      = @("docs/design/city-downtown/${Prefix}_plaza.png", "site=section,seed=4,deck=2,camera=downtown_plaza")
        "arcade"     = @("docs/design/city-downtown/${Prefix}_arcade.png", "site=section,seed=4,deck=2,camera=downtown_arcade")
        "top"        = @("docs/design/city-downtown/${Prefix}_top.png", "site=section,seed=4,deck=2,camera=downtown_top")
        "stack"      = @("docs/design/city-downtown/${Prefix}_stack.png", "site=stack,seed=4,camera=downtown_avenue")
        "street_eye" = @("docs/design/city-downtown/${Prefix}_street_eye.png", "site=section,seed=4,deck=2,camera=downtown_street")
        "alley"      = @("docs/design/city-variety/alley_section.png", "site=section,seed=4,deck=0,camera=alley_pillar")
    }
    foreach ($k in $shots.Keys) {
        if ($Only -and ($Only -split ",") -notcontains $k) { continue }
        $png = $shots[$k][0]
        $city = $shots[$k][1]
        $code = Invoke-HiddenDesktop -Exe $g -Arguments "--path . --resolution 1600x900 --log-file test_logs\shot_$k.log -- --scene res://scenes/lab.tscn --subject city --view three --shot $png --shot-after 4 --city $city" -TimeoutSec 240
        Write-Host "$k -> $png (exit $code)"
    }
} finally { Pop-Location }
