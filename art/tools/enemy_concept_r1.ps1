# Enemy concept round 1: nine FORM concepts for the invader-controlled civil-defence forces.
# Each image: one group (tracked tank + reverse-jointed walker + small hover drone) on a sunny low-poly street.
# Colour is kept neutral (muted grey + red) so the grid compares form; colour is decided in-engine.
# Usage: .\art\tools\enemy_concept_r1.ps1 [-Only a,b] [-Seeds 4242]
param([string[]]$Only = @(), [int[]]$Seeds = @(4242))
Set-Location (Join-Path $PSScriptRoot "..\..")
$R = "$HOME\.claude\skills\local-render\render.ps1"
$out = "art\renders\enemy_concept_r1"

$common = "Low poly 3D video game concept render of enemy war machines: CHUNKY low poly, big simple flat polygon faces with hard edges, one flat colour per face, no textures, no grime, no photorealism, simple blocky geometric shapes like a stylized indie game. " +
  "One enemy group standing together in the middle of a sunny clean low poly city street, three-quarter view from slightly above, all three machines fully in frame: a TRACKED TANK with a turret, a two-legged WALKER ROBOT with backward-bending reverse-jointed bird legs, and a small HOVERING DRONE floating beside them. All three share the same design language. " +
  "Livery: muted medium grey armour with dull red accents (not black, not shiny). " +
  "Background: intact blocky low poly buildings in cream, terracotta, sage green and sky blue, warm bright artificial daylight, soft shadows. " +
  "No people, no humans, no text, no letters, no interface, no border, no watermark. CONCEPT: "

$scenes = [ordered]@{
  "c1_repainted_civic"     = "REPAINTED CIVIC: plain municipal civil-defence utility machines with simple boxy service-vehicle shapes, hazard-light bars and maintenance hatches, simply repainted in the invaders' grey and red, a stencilled angular alien emblem painted on each hull, small triangular alien pennant flags on short poles. Otherwise unmodified human civic hardware."
  "c2_control_crown"       = "CONTROL CROWN: the same plain boxy civic civil-defence machines, each with a grafted alien control node bolted on top: a large glowing faceted crystal pod like a crown, with thick cables running down from it and plugged into the chassis. The alien pods glow red and look foreign on the simple human machines."
  "c3_parasite_rider"      = "PARASITE RIDER: plain boxy civic civil-defence machines, each with an open cockpit or saddle where a small strange alien creature sits strapped in and steers it, the creature low poly with a big head, many small limbs and glowing eyes, clearly visible piloting each machine; the drone has a tiny alien clinging on top."
  "c4_tendril_graft"       = "TENDRIL GRAFT: civic steel machines overgrown by organic alien tendrils, thick angular faceted root-like cables wrapped around the hulls, legs and turret, gripping the steel like tree roots, with glowing bulb nodes along them. Steel armour still visible between the tendrils."
  # r1b: first pass left the tank a plain tank; chitin now explicitly on all three.
  "c5_chitin_biomech"      = "CHITIN BIOMECH: ALL THREE machines rebuilt with alien insect chitin: the tank hull and turret covered in overlapping curved segmented beetle-carapace shell plates with a ridged insect back and mandible prongs at the front, the walker with armoured insect legs and a carapace body, the drone like a shelled flying beetle. Faceted shell segments over the steel frame, part machine part insect."
  "c6_puppet_tether"       = "PUPPET TETHER: plain boxy civic civil-defence machines, and hovering high above each one a small angular alien overseer drone, each overseer connected to the machine below by a thin straight glowing red beam like a puppet string, controlling it from above."
  "c7_crystal_tech"        = "CRYSTAL TECH: plain civic machines with faceted alien crystal growths implanted on them: tall crystal antennae, crystal sensor clusters replacing the lights, a large glowing crystal power core set into each hull, sharp geometric crystal shards sprouting from the armour."
  "c8_heraldic_occupation" = "HERALDIC OCCUPATION: the machines dressed like a parade guard of an alien empire: long hanging cloth tabards and vertical banners with an angular alien sigil draped over the hulls, ceremonial angular heraldic armour plates with spikes and crests, standing in neat parade-ground formation, orderly and imposing."
  # r1b: first pass gave an ordinary tracked military tank; the tank is now described as a hovering wedge (overrides 'TRACKED TANK' above).
  "c9_alien_built"         = "ALIEN BUILT: fully alien-designed war machines, nothing human or military-earth about them. IMPORTANT: the tank has NO tracks and NO wheels: it is a flat wedge-shaped alien hover tank shaped like a stingray or arrowhead, floating a metre above the street with a red glow underneath, with a long thin spine-like cannon. The walker is tall and thin with sharp blade-like insectoid legs and an elongated faceted head. The drone is a sharp arrowhead. All smooth angular alien geometry with glowing red slits, unlike any earth vehicle."
}

$keys = @($scenes.Keys | Where-Object { $Only.Count -eq 0 -or $Only -contains $_ })
$i = 0
foreach ($k in $keys) {
  $i++
  $keep = if ($i -lt $keys.Count) { @{ KeepServer = $true } } else { @{} }
  $c = $common
  # alien_built: the shared 'TRACKED TANK' wording kept forcing tracks onto the hover tank (seeds 4242, 77, 909).
  if ($k -eq "c9_alien_built") { $c = $c.Replace("a TRACKED TANK with a turret", "a trackless HOVER TANK floating above the ground") }
  & $R -Name $k -Prompt ($c + $scenes[$k]) -Seeds $Seeds -Width 1024 -Height 576 -OutDir $out @keep
}
