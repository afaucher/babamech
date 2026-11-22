# gen_audio.ps1 - export SoundBank cues as .wav to test_logs/audio/ (or -Bake into assets/audio/*.res), headless.
param([switch]$Bake)
$root = Resolve-Path "$PSScriptRoot\..\.."
. "$root\godot_env.ps1"
$godot = Resolve-BabamechGodot
if ($Bake) {
	& $godot --path $root --headless --script res://tools/audio/gen_audio.gd -- --bake
} else {
	& $godot --path $root --headless --script res://tools/audio/gen_audio.gd
}
