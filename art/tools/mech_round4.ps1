# Round 4: head pokes out of the hull's front window; shoulder weapons raised up around the head.
# Grid = 3 hulls (rows) x 3 head/weapon arrangements (columns). Mechanical chicken legs throughout.
Set-Location (Join-Path $PSScriptRoot "..\..")
$R = "$HOME\.claude\skills\local-render\render.ps1"
$out = "art\renders\mech_r4"

$common = "Low poly 3D game vehicle concept render, flat-shaded faceted polygons, highly stylized, clean simple shapes. " +
  "A BIPEDAL walking war machine with EXACTLY TWO LEGS, like a giant mechanical chicken: two legs only, not a quadruped. " +
  "The legs are fully mechanical but shaped like a chicken's legs: armored thigh, a knee that bends BACKWARD (reverse-jointed), long shin with hydraulic pistons, and a big metal foot with three forward toes and a rear spur. " +
  "No human-like arms and no hands. " +
  "The pilot is an OVERSIZED real organic chicken head (not armor, not a helmet): a big low poly chicken head with red comb, wattle and yellow beak. " +
  "The head does NOT sit on top of the hull: it sticks forward OUT OF A LARGE OPEN FRONT WINDOW in the front face of the hull, like a chicken looking out of a hatch. " +
  "Full body, three-quarter front view, camera at hull height. Against a plain even soft grey-blue background, no floor, no shadow, soft studio lighting. No text, no interface, no border, no watermark. "

$hulls = [ordered]@{
  "hut"     = "The hull is a small armored log cabin with a pitched metal roof and a chimney exhaust, rust red and dark wood; the head pokes out of the cabin's big front window with its shutters open."
  "upright" = "The hull is a tall upright armored block in slate blue; the head pokes out of a wide rectangular front viewport."
  "egg"     = "The hull is a compact rounded egg-shaped armored pod in white and safety-orange; the head pokes out of a round front porthole."
}
$arms = [ordered]@{
  "flank" = "Two big boxy shoulder weapon pods are mounted HIGH on the upper corners of the hull, one on each side of the head at head height, framing it closely like big shoulders."
  "raised"= "Two shoulder weapon pods sit on short raised pylons that lift them ABOVE the head, angled forward, one on each side, like raised shoulders over the head."
  "collar"= "The weapons form a horseshoe collar around the head: a rocket pod above the window and a gun pod on each side of the head, all wrapped closely around it."
}

$i = 0; $n = $hulls.Count * $arms.Count
foreach ($h in $hulls.Keys) { foreach ($a in $arms.Keys) {
  $i++
  $keep = if ($i -lt $n) { @{ KeepServer = $true } } else { @{} }
  & $R -Name "${h}_${a}" -Prompt ($common + $hulls[$h] + " " + $arms[$a]) -Seeds 404 -Width 768 -Height 768 -OutDir $out @keep
} }
