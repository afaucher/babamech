# Military supply depot round 1: a finite player-side resupply point holding power cores (host-arbitrated world object).
# Rows = FORM (A crate stack + cage, B hardened bunker kiosk, C shipping-container depot).
# Columns = HOW THE CORES READ (1 open rack of upright glowing cylinders, 2 socket wall like a battery bank,
# 3 tall pylons with stacked rings that go dark from the top). Every cell shows the depot about half stocked.
# Usage: .\art\tools\depot_r1.ps1 [-Only A1_crates_rack,...] [-Seeds 4242,777]
param([string[]]$Only = @(), [int[]]$Seeds = @(4242, 777))
Set-Location (Join-Path $PSScriptRoot "..\..")
$Render = "$HOME\.claude\skills\local-render\render.ps1"
$out = "art\renders\depot_r1"

$common = "Low poly 3D video game concept render: CHUNKY low poly, big simple flat polygon faces with hard edges, one flat colour per face, no textures, no grime, no photorealism, like a stylized indie game. " +
  "Third-person game camera from behind and above a giant robot: in the foreground at the left edge, the back of a big white and safety-orange bipedal mech robot (8 metres tall) walking toward the scene, for scale. " +
  "Ahead of it in a small plaza of a blocky low poly city with cream and terracotta buildings in warm bright artificial daylight, large in the centre of the frame: a MILITARY SUPPLY DEPOT of the habitat's own civil-defence forces, about half the height of the mech, " +
  "painted off-white with charcoal-grey frames and safety-orange hazard stripes and corner markings, a simple orange cross-and-bolt service emblem, chunky and sturdy, orderly. " +
  "It holds big POWER CORES: chunky cylinders, each about as long as the mech's forearm, with bright glowing ICE-BLUE cells and charcoal end caps. The depot is HALF STOCKED: some core places are full and glowing ice blue, the others are clearly EMPTY, dark and hollow, so the number left is readable at a glance. " +
  "No green anywhere, no red, no enemies. No people, no text, no letters, no interface, no border, no watermark. DEPOT: "

$form = [ordered]@{
  "crates"    = "a stack of chunky reinforced supply crates around a tall open steel CAGE frame with a fold-down loading ramp and two floodlights on poles"
  "bunker"    = "a squat HARDENED BUNKER KIOSK of thick sloped concrete-like slabs with a heavy overhanging roof, blast shutters rolled up, like a fortified fuel or ammo point"
  "container" = "two big SHIPPING CONTAINERS set at right angles with their side walls swung open as awnings, a gantry on top, sandbag-like low barriers around"
}
$cores = [ordered]@{
  "rack"   = "the cores stand UPRIGHT in an open rack of eight slots in a row out front, glowing cores in some slots, empty slots dark"
  "wall"   = "the cores are slotted horizontally into a big SOCKET WALL like a battery bank, a grid of eight round sockets on its face, full sockets glowing ice blue, empty sockets black holes"
  "pylons" = "four tall charcoal PYLONS rise from it, each with a stack of glowing ice-blue rings like a gauge; the rings go dark from the top down as cores are taken, so each pylon reads as a fill level"
}

$scenes = [ordered]@{}
$row = 0
foreach ($f in $form.Keys) {
  $row++
  $col = 0
  foreach ($c in $cores.Keys) {
    $col++
    $scenes[[string]([char](64 + $row)) + "$col`_$f`_$c"] = $form[$f] + "; " + $cores[$c] + "."
  }
}

$keys = @($scenes.Keys | Where-Object { $Only.Count -eq 0 -or $Only -contains $_ })
$i = 0
foreach ($k in $keys) {
  $i++
  $keep = if ($i -lt $keys.Count) { @{ KeepServer = $true } } else { @{} }
  & $Render -Name $k -Prompt ($common + $scenes[$k]) -Seeds $Seeds -Width 1024 -Height 576 -OutDir $out @keep
}
