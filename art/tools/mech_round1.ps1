# Round 1 mech concepts: 9 distinct body directions, same oversized chicken head, same framing.
$R = "$HOME\.claude\skills\local-render\render.ps1"
$out = "art\renders\mech_r1"

$common = "Low poly 3D game character concept render, flat-shaded faceted polygons, highly stylized, clean simple shapes, " +
  "a bipedal combat mech shown full body in a three-quarter front view, camera at chest height, standing on two articulated legs with visible hip, knee and ankle joints. " +
  "Instead of a cockpit, the mech has an oversized real organic chicken head (not armor, not a helmet): a big low poly chicken head with red comb, wattle and yellow beak, about a third of the mech's height, sitting on a short neck on top of the torso. " +
  "Weapon hardpoints visible on the arms and shoulders. Against a plain even soft grey-blue background, no floor, no shadow, soft studio lighting. No text, no interface, no border, no watermark. "

$concepts = [ordered]@{
  "a_babayaga"   = "The torso is a small boxy wooden cabin with a pitched shingle roof, shutters and a chimney, painted in folk-art colours, walking on scaly yellow chicken legs with backward-bending knees and big three-toed bird feet."
  "b_rescue"     = "Civil defense rescue mech: rounded torso in bright safety orange and white with reflective stripes, amber beacon lights, chunky straight legs with flat round feet, tidy panel lines."
  "c_loader"     = "Industrial construction loader mech: chunky caution-yellow and black hazard-striped plating, exposed hydraulic pistons at every joint, roll cage around the torso, wide stomping box feet."
  "d_toy"        = "Designer vinyl toy style mech: soft rounded pastel mint and cream body, stubby cute proportions, ball joints, short thick legs, playful and friendly."
  "e_riveted"    = "Old riveted war walker: olive drab steel plates with rivets, small vision slits, tank-like armor skirts, thick piston legs with digitigrade bird-like knees, worn and chipped paint."
  "f_habitat"    = "Clean sci-fi space habitat mech: sleek white panels with teal accent lights, smooth tapered limbs, slim reverse-jointed legs, minimalist and elegant."
  "g_scrap"      = "Scrappy junk-built mech: patchwork of mismatched rusty panels, a repurposed water tank torso, exposed cables, one leg sturdier than the other, improvised and charming."
  "h_brawler"    = "Heavy brawler mech: hunched broad torso, huge gorilla-like arms with gun pods, short powerful digitigrade legs, dark gunmetal with red accents."
  "i_strider"    = "Tall lanky strider mech: small compact torso high up on very long thin ostrich-like legs with backward knees, long thin arms, sandy beige and burnt orange."
}

$i = 0
foreach ($k in $concepts.Keys) {
  $i++
  $keep = if ($i -lt $concepts.Count) { @{ KeepServer = $true } } else { @{} }
  & $R -Name $k -Prompt ($common + $concepts[$k]) -Seeds 101 -Width 768 -Height 768 -OutDir $out @keep
}
