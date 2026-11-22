# Round 8: round-7 chassis (chicken pilot, head out of hatch) with 9 weapon mount / shoulder pod variations.
Set-Location (Join-Path $PSScriptRoot "..\..")
$R = "$HOME\.claude\skills\local-render\render.ps1"
$out = "art\renders\mech_r8"

$common = "Low poly 3D game vehicle concept render, flat-shaded faceted polygons, highly stylized, clean simple shapes. " +
  "A BIPEDAL combat mech with EXACTLY TWO LEGS: a rounded armored mechanical torso in white and safety-orange civil-defense livery with amber lights (a war machine, not a building) on two legs. " +
  "The legs are mechanical but shaped like a chicken's legs: armored thigh, a knee that clearly bends BACKWARD like a bird's (reverse-jointed, digitigrade), long angled shin with pistons, and a big metal foot with three forward toes and a rear spur. " +
  "No arms and no hands. At the front of the torso a nose juts forward with a round hatch and a tall armored back plate behind it. " +
  "The pilot sits INSIDE the mech: only the head and neck of a rooster stick up out of the hatch. The rooster head is TRUE LOW POLY, about 150 big flat faces with hard edges, flat solid colour per facet, no texture, no feathers: off-white head, red comb of a few sharp triangular spikes, red wattle, yellow beak, and a STERN expression with a heavy angled brow over a narrowed eye, beak closed. The head is oversized, about as wide as the torso. " +
  "Full body of the mech, three-quarter front view, camera at torso height. Against a plain even soft grey-blue background, no floor, no shadow, soft studio lighting. No text, no interface, no border, no watermark. " +
  "WEAPONS: "

$weapons = [ordered]@{
  "a_twincannon" = "two long-barrelled autocannons on raised shoulder mounts above the head, one each side, pointing forward."
  "b_missilebox" = "two big square missile box pods on the shoulders, each with a grid of six round launch tubes facing forward, raised beside and above the head."
  "c_asym"       = "asymmetric loadout: a long cannon on a raised mount over the left shoulder and a chunky missile box pod on the right shoulder."
  "d_mortar"     = "a tall back-mounted mortar tube rising vertically behind the back plate, angled up and forward, plus two small guns on the torso sides."
  "e_hipgatling" = "two rotary gatling guns with many barrels slung low on the sides of the torso at hip height, and a small sensor pod on top."
  "f_laser"      = "two sleek laser emitters on raised shoulder mounts, long slim barrels ending in glowing teal crystal lenses, with cooling fins."
  "g_railgun"    = "a single huge long railgun mounted over the right shoulder, longer than the mech is tall, with coil rings along the barrel and a counterweight on the left."
  "h_booms"      = "two short articulated weapon booms on the torso sides, like stubby swivelling arms, each ending in a boxy gun pod."
  "i_maxed"      = "fully loaded: a missile pod and a cannon on the shoulders, two small turrets on the torso sides, and a mortar on the back, every hardpoint filled."
}

$i = 0
foreach ($k in $weapons.Keys) {
  $i++
  $keep = if ($i -lt $weapons.Count) { @{ KeepServer = $true } } else { @{} }
  & $R -Name $k -Prompt ($common + $weapons[$k]) -Seeds 707 -Width 768 -Height 768 -OutDir $out @keep
}
