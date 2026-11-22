# gen_mech_meshes.ps1 - regenerate assets/models/mech/*.res from scripts/mech/mech_meshes.gd (headless).
$root = Resolve-Path "$PSScriptRoot\..\.."
. "$root\godot_env.ps1"
$godot = Resolve-BabamechGodot
Invoke-BabamechImport $godot
& $godot --path $root --headless --script res://tools/models/gen_mech_meshes.gd
Invoke-BabamechImport $godot
