# Round 2: mech-like, not humanoid robots. Hull + legs + weapon pods, no hands. Bigger chicken head.
Set-Location (Join-Path $PSScriptRoot "..\..")
$R = "$HOME\.claude\skills\local-render\render.ps1"
$out = "art\renders\mech_r2"

$common = "Low poly 3D game vehicle concept render, flat-shaded faceted polygons, highly stylized, clean simple shapes. " +
  "A heavy walking war machine (a walker mech, a walking tank), NOT a humanoid robot: no human-like arms, no hands, no human body proportions. " +
  "It is an armored hull carried on two articulated mechanical legs with large visible hip, knee and ankle joints, hydraulic pistons and broad feet. " +
  "Weapons are boxy pods and barrels mounted directly on hardpoints on the hull sides, shoulders and back. " +
  "On top of the hull, in place of a cockpit, sits an OVERSIZED real organic chicken head (not armor, not a helmet): a big low poly chicken head with red comb, wattle and yellow beak, almost as large as the hull itself, comically big. " +
  "Full body, three-quarter front view, camera at hull height. Against a plain even soft grey-blue background, no floor, no shadow, soft studio lighting. No text, no interface, no border, no watermark. "

$concepts = [ordered]@{
  "a_chickenwalker" = "Compact boxy hull slung between tall reverse-jointed bird-like legs with backward knees, a gun pod on each side of the hull, gunmetal grey with orange stripes."
  "b_hunched"       = "Forward-leaning wedge-shaped hull like a predator about to pounce, long reverse-jointed legs, twin missile boxes on top behind the head, desert tan."
  "c_tankhull"      = "Wide flat tank-like armored hull with sloped armor plates, two short thick stompy legs, a long cannon on each side of the hull, olive green."
  "d_hut"           = "The hull is a small armored log cabin with a pitched metal roof and a chimney exhaust, carried on huge scaly reverse-jointed chicken legs with three-toed feet, gun barrels poking out of the shuttered windows, rust red and dark wood."
  "e_egg"           = "Rounded egg-shaped pod hull, reverse-jointed legs, a rotary gun slung underneath the hull and rocket tubes on the back, white and safety-orange civil defense livery."
  "f_upright"       = "Tall upright blocky hull on thick straight piston legs, the hull flanked by two big rectangular weapon pods mounted at shoulder level instead of arms, a mortar tube on the back, slate blue."
  "g_strider"       = "Small compact hull held very high on extremely long thin reverse-jointed legs, a long sniper laser barrel under the hull, sand and black."
  "h_squat"         = "Very low squat hull hanging between wide splayed heavy legs like a crab-stance walker, short knees, rocket pods on both sides, yellow and black hazard stripes."
  "i_rescue"        = "Civil defense rescue walker: rounded hull with amber beacons, a folded crane arm on one side and a gun pod on the other, sturdy reverse-jointed legs, bright red and white."
}

$i = 0
foreach ($k in $concepts.Keys) {
  $i++
  $keep = if ($i -lt $concepts.Count) { @{ KeepServer = $true } } else { @{} }
  & $R -Name $k -Prompt ($common + $concepts[$k]) -Seeds 202 -Width 768 -Height 768 -OutDir $out @keep
}
