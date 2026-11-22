# Round 3: bipeds with chicken-like legs. Grid = 3 hulls (rows) x 3 leg treatments (columns).
Set-Location (Join-Path $PSScriptRoot "..\..")
$R = "$HOME\.claude\skills\local-render\render.ps1"
$out = "art\renders\mech_r3"

$common = "Low poly 3D game vehicle concept render, flat-shaded faceted polygons, highly stylized, clean simple shapes. " +
  "A BIPEDAL walking war machine with EXACTLY TWO LEGS, like a giant mechanical chicken: two legs only, not four, not a quadruped. " +
  "The legs are shaped like a chicken's legs: a thick thigh, a knee that bends BACKWARD (reverse-jointed, digitigrade), a long shin, and a big foot with three long forward toes and one rear spur toe. " +
  "No human-like arms and no hands; weapons are boxy pods and barrels mounted on hardpoints on the hull sides, shoulders and back. " +
  "On top of the hull, in place of a cockpit, sits an OVERSIZED real organic chicken head (not armor, not a helmet): a big low poly chicken head with red comb, wattle and yellow beak, almost as large as the hull. " +
  "Full body, three-quarter side view so both legs are clearly visible, camera at hull height. Against a plain even soft grey-blue background, no floor, no shadow, soft studio lighting. No text, no interface, no border, no watermark. "

$hulls = [ordered]@{
  "hut"     = "The hull is a small armored log cabin with a pitched metal roof and a chimney exhaust, gun barrels poking out of shuttered windows, rust red and dark wood."
  "upright" = "The hull is a tall upright armored block flanked by two big rectangular weapon pods at shoulder level and a mortar tube on the back, slate blue."
  "egg"     = "The hull is a compact rounded egg-shaped armored pod with a gun pod on each side and rocket tubes on the back, white and safety-orange livery."
}
$legs = [ordered]@{
  "mech"   = "The legs are fully mechanical: armored metal plates, exposed hydraulic pistons and big round joints, metal three-toed feet."
  "hybrid" = "The legs are armored metal thighs with pistons, but the shins and feet are covered in yellow scaly chicken skin with sharp claws."
  "organic"= "The legs are real organic yellow scaly chicken legs, thick and muscular, with sharp claws, attached under the metal hull."
}

$i = 0; $n = $hulls.Count * $legs.Count
foreach ($h in $hulls.Keys) { foreach ($l in $legs.Keys) {
  $i++
  $keep = if ($i -lt $n) { @{ KeepServer = $true } } else { @{} }
  & $R -Name "${h}_${l}" -Prompt ($common + $hulls[$h] + " " + $legs[$l]) -Seeds 303 -Width 768 -Height 768 -OutDir $out @keep
} }
