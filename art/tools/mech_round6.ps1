# Round 6: the pilot creature SITS INSIDE the mech, part of its body out of an open cockpit in the nose.
# Grid = 4 pilots (rows: chicken, pickle, corn, dog) x 3 depths (cols: head out of hatch / chest out / waist out).
Set-Location (Join-Path $PSScriptRoot "..\..")
$R = "$HOME\.claude\skills\local-render\render.ps1"
$out = "art\renders\mech_r6"

$common = "Low poly 3D game vehicle concept render, flat-shaded faceted polygons, highly stylized, clean simple shapes. " +
  "A BIPEDAL combat mech with EXACTLY TWO LEGS: a rounded armored mechanical torso in white and safety-orange civil-defense livery with amber lights (a war machine, not a building) on two legs. " +
  "The legs are mechanical but shaped like a chicken's legs: armored thigh, a knee that clearly bends BACKWARD (reverse-jointed), long angled shin with pistons, and a big metal foot with three forward toes and a rear spur. " +
  "No human-like arms and no hands. Two big shoulder weapon pods are mounted HIGH on top of the torso, raised above the pilot and pointing forward. " +
  "At the front of the torso a nose juts forward holding an open cockpit with a tall armored back plate behind the pilot. " +
  "The PILOT IS A LIVING CARTOON CHARACTER SITTING INSIDE THE MECH'S COCKPIT, much bigger than a human pilot, comically oversized, in the same low poly cartoon style with big friendly expressive eyes. " +
  "Full body of the mech, three-quarter front view, camera at torso height. Against a plain even soft grey-blue background, no floor, no shadow, soft studio lighting. No text, no interface, no border, no watermark. "

$pilots = [ordered]@{
  "chicken" = "The pilot is a big white chicken with a red comb, wattle and yellow beak; its feathered body is inside the mech."
  "pickle"  = "The pilot is a big green bumpy dill pickle character with cartoon eyes and a smiling mouth; the pickle is inside the mech."
  "corn"    = "The pilot is a big corn-on-the-cob character with yellow kernels, green husk leaves peeled back like a collar, cartoon eyes and a smile; the corn cob is inside the mech."
  "dog"     = "The pilot is a big friendly golden-brown dog with floppy ears and a black nose; its furry body is inside the mech."
}
$depths = [ordered]@{
  "head"  = "Only the pilot's head and neck stick up out of a small round hatch in the nose; the rest of its body is hidden inside the mech."
  "chest" = "The pilot's head and upper body stick out of the open cockpit tub, resting on the rim of the cockpit (wings, paws or husk leaves on the rim); the lower body is inside."
  "waist" = "The pilot sits upright in an open-top cockpit seat like a driver in an open race car, visible down to the waist, with the back plate behind it."
}

$i = 0; $n = $pilots.Count * $depths.Count
foreach ($p in $pilots.Keys) { foreach ($d in $depths.Keys) {
  $i++
  $keep = if ($i -lt $n) { @{ KeepServer = $true } } else { @{} }
  & $R -Name "${p}_${d}" -Prompt ($common + $pilots[$p] + " " + $depths[$d]) -Seeds 606 -Width 768 -Height 768 -OutDir $out @keep
} }
