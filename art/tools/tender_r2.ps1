# Supply truck round 2: refine the pick A1 (utility truck + open roof drone cradles). r1 concern: the cradles sit low on
# the bed and could vanish behind cover. Rows = RACK HEIGHT (low bed rack / raised rack on posts / two-tier stepped rack).
# Columns = CRADLE STYLE (open cages / flat landing pads with clamps / launch rails tilted up and back).
# Usage: .\art\tools\tender_r2.ps1 [-Only R1_low_cages,...] [-Seeds 4242,777]
param([string[]]$Only = @(), [int[]]$Seeds = @(4242, 777))
Set-Location (Join-Path $PSScriptRoot "..\..")
$R = "$HOME\.claude\skills\local-render\render.ps1"
$out = "art\renders\tender_r2"

$common = "Low poly 3D video game concept render: CHUNKY low poly, big simple flat polygon faces with hard edges, one flat colour per face, no textures, no grime, no photorealism, like a stylized indie game. " +
  "Three-quarter view from slightly above and behind the side, a wide street of a blocky low poly city with cream and terracotta buildings in warm bright artificial daylight. " +
  "In the centre, large in frame: a long six-wheeled municipal UTILITY SERVICE truck with a low flat cab and a long flat equipment bed with tool lockers along its sides, a plain boxy civic civil-defence machine that an occupying force has simply REPAINTED in its livery: " +
  "warm slate-grey body, lighter grey armour plates, bare steel parts, brick-red trim bands along the sides, a cream stencil of a downward-pointing arrowhead with three trailing bars on the cab door, amber rotating service lamps on the cab roof. " +
  "No alien parts, no weapons, no gun turret. On the bed it carries small square quad-rotor repair drones with slate bodies and cream rotor guards, four drone places in a row, three drones docked and ONE PLACE EMPTY because that drone has flown off: " +
  "it hovers over a damaged slate-grey tracked tank parked behind the truck, projecting a wide flat fan of pale cream light down onto the tank like a scanner sweep. " +
  "Clear readable silhouette. No people, no text, no letters, no interface, no border, no watermark. DRONE RACK: "

$height = [ordered]@{
  "low"    = "a low steel rack sitting directly on the flat bed, the drones at the height of the cab roof"
  "raised" = "a rack raised on four tall steel posts well above the bed, like a roof rack, the drones clearly higher than the cab with tool lockers visible underneath"
  "tiered" = "a stepped two-tier rack rising toward the rear of the truck, two drone places on the low front tier and two on the higher back tier, like stadium seats"
}
$style = [ordered]@{
  "cages" = "each drone sits in an open box cage of steel bars, the empty cage clearly visible"
  "pads"  = "each drone sits on a flat square landing pad with brick-red corner clamps, the empty pad bare with its clamps open"
  "rails" = "each drone sits on a short launch rail tilted up and back at an angle, nose up, ready to fling it into the air, the empty rail pointing at the sky"
}

$scenes = [ordered]@{}
$row = 0
foreach ($h in $height.Keys) {
  $row++
  $c = 0
  foreach ($s in $style.Keys) {
    $c++
    $scenes["R$row$c`_$h`_$s"] = $height[$h] + "; " + $style[$s] + "."
  }
}

$keys = @($scenes.Keys | Where-Object { $Only.Count -eq 0 -or $Only -contains $_ })
$i = 0
foreach ($k in $keys) {
  $i++
  $keep = if ($i -lt $keys.Count) { @{ KeepServer = $true } } else { @{} }
  & $R -Name $k -Prompt ($common + $scenes[$k]) -Seeds $Seeds -Width 1024 -Height 576 -OutDir $out @keep
}
