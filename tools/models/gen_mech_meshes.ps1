# gen_mech_meshes.ps1 - regenerate assets/models/mech/*.res from scripts/mech/*_meshes.gd (headless).
#   .\tools\models\gen_mech_meshes.ps1                 every part
#   .\tools\models\gen_mech_meshes.ps1 --only wasp_    only the parts with that prefix
$root = Resolve-Path "$PSScriptRoot\..\.."
. "$root\godot_env.ps1"
$godot = Resolve-BabamechGodot
Invoke-BabamechImport $godot
if ($args.Count -gt 0) {
    & $godot --path $root --headless --script res://tools/models/gen_mech_meshes.gd -- @args
} else {
    & $godot --path $root --headless --script res://tools/models/gen_mech_meshes.gd
}
Invoke-BabamechImport $godot
