# lab.ps1 - open the lab (scenes/lab.tscn): every registered scene with its tunable params (modelled on flap's bird lab).
#   .\lab.ps1                         # opens on the first subject
#   .\lab.ps1 mech                    # a subject by id (ids in scripts/app/lab_registry.gd)
#   .\lab.ps1 mech -View side         # side | front | three | top
#   .\lab.ps1 -List                   # list the subject ids
param([string]$Subject = "", [string]$View = "", [switch]$List)
if ($List) {
    Select-String -Path "$PSScriptRoot\scripts\app\lab_registry.gd" -Pattern '"id": "([^"]+)", "label": "([^"]+)"' |
        ForEach-Object { "{0,-14} {1}" -f $_.Matches[0].Groups[1].Value, $_.Matches[0].Groups[2].Value }
    return
}
$a = @("--scene", "res://scenes/lab.tscn")
if ($Subject) { $a += @("--subject", $Subject) }
if ($View) { $a += @("--view", $View) }
& "$PSScriptRoot\run.ps1" @a
