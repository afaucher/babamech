# Supply truck ("tender") round 1: a repainted civic truck that follows the enemy squad and launches repair drones.
# 2-axis grid. Rows = which civic vehicle it was (A utility / service truck, B box cargo hauler, C rescue tender).
# Columns = how it carries its drones (1 open roof cradles, 2 enclosed hive with hatches, 3 crane mast / gantry).
# Usage: .\art\tools\tender_r1.ps1 [-Only A1_utility_cradles,...] [-Seeds 4242]
param([string[]]$Only = @(), [int[]]$Seeds = @(4242))
Set-Location (Join-Path $PSScriptRoot "..\..")
$R = "$HOME\.claude\skills\local-render\render.ps1"
$out = "art\renders\tender_r1"

$common = "Low poly 3D video game concept render: CHUNKY low poly, big simple flat polygon faces with hard edges, one flat colour per face, no textures, no grime, no photorealism, like a stylized indie game. " +
  "Three-quarter view from slightly above, a wide street of a blocky low poly city with cream and terracotta buildings in warm bright artificial daylight. " +
  "In the centre, large in frame: a six-wheeled heavy civic support truck, a plain boxy municipal machine of the city's own civil-defence service that an occupying force has simply REPAINTED in its livery: " +
  "warm slate-grey body, lighter grey armour plates, bare steel parts, brick-red trim bands, a cream stencil of a downward-pointing arrowhead with three trailing bars on its side, amber rotating service lamps on the cab roof. " +
  "No alien parts, no weapons, no gun turret. Its job is field repair: it carries small square quad-rotor repair drones in the same slate and cream livery. " +
  "One drone has just lifted off from the truck and hovers over a damaged slate-grey tracked tank parked behind it, projecting a wide flat fan of pale cream light down onto the tank like a scanner sweep. " +
  "Clear readable silhouette, distinct from the tank. No people, no text, no letters, no interface, no border, no watermark. TRUCK: "

$scenes = [ordered]@{
  "A1_utility_cradles" = "A long municipal UTILITY SERVICE truck with a low flat cab and a flat equipment bed; on the bed an open steel rack of four drone cradles in a row, three drones still sitting in them, one cradle empty, plus tool lockers along the sides."
  "A2_utility_hive"    = "A long municipal UTILITY SERVICE truck with a low flat cab; behind the cab an armoured box body like a hive with four square hatches on its roof, one hatch flipped open with the drone rising out of it."
  "A3_utility_crane"   = "A long municipal UTILITY SERVICE truck with a low flat cab and a folding crane arm on its bed; drones hang from hooks along the raised crane boom like tools on a rack, one hook empty."
  "B1_cargo_cradles"   = "A tall boxy CARGO HAULER with a high square cargo box; on the flat roof of the box an open frame of drone cradles, drones sitting in them, one cradle empty, a ladder up the back."
  "B2_cargo_hive"      = "A tall boxy CARGO HAULER whose square cargo box has a row of louvred side shutters like a dovecote, drones nesting behind them; one shutter rolled up and its drone flying out."
  "B3_cargo_crane"     = "A tall boxy CARGO HAULER with a short telescopic mast rising from the middle of the cargo box roof, a cross-shaped gantry at its top with drones docked on each arm, one arm empty."
  "C1_rescue_cradles"  = "A chunky RESCUE TENDER like a fire-and-rescue vehicle with a tall cab, roller shutters along its sides and a light bar; on its roof an open rack of drone cradles, drones in them, one empty."
  "C2_rescue_hive"     = "A chunky RESCUE TENDER with a tall cab and an armoured rear module like a hive with two big clamshell roof doors, one door swung open and a drone lifting out."
  "C3_rescue_crane"    = "A chunky RESCUE TENDER with a tall cab and a turntable aerial ladder on its roof, folded back; drones docked along the ladder rungs, one dock empty."
}

$keys = @($scenes.Keys | Where-Object { $Only.Count -eq 0 -or $Only -contains $_ })
$i = 0
foreach ($k in $keys) {
  $i++
  $keep = if ($i -lt $keys.Count) { @{ KeepServer = $true } } else { @{} }
  & $R -Name $k -Prompt ($common + $scenes[$k]) -Seeds $Seeds -Width 1024 -Height 576 -OutDir $out @keep
}
