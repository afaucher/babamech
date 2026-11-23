# Enemy concept round 2: control-crown variants (r1 pick: concept 2). Same civic base group and livery;
# only the grafted alien control node varies. The node is the unit's weak point, so it must read at distance.
# Usage: .\art\tools\enemy_concept_r2.ps1 [-Only a,b] [-Seeds 4242]
param([string[]]$Only = @(), [int[]]$Seeds = @(4242))
Set-Location (Join-Path $PSScriptRoot "..\..")
$R = "$HOME\.claude\skills\local-render\render.ps1"
$out = "art\renders\enemy_concept_r2"

$common = "Low poly 3D video game concept render of enemy war machines: CHUNKY low poly, big simple flat polygon faces with hard edges, one flat colour per face, no textures, no grime, no photorealism, simple blocky geometric shapes like a stylized indie game. " +
  "One enemy group standing together in the middle of a sunny clean low poly city street, three-quarter view from slightly above, all three machines fully in frame: " +
  "a plain boxy civic civil-defence TRACKED TANK with a turret; a two-legged civic WALKER ROBOT with ostrich legs like a chicken walker or an AT-ST: a short boxy body on long digitigrade bird legs, the thigh angles forward and the lower leg angles BACKWARD, so the leg forms a backward-pointing zig-zag with the reverse knee joint behind the body, standing on splayed toes; the whole leg is grey steel machinery like the rest of the robot (not organic, not orange); and a small boxy HOVERING DRONE floating beside them. " +
  "Livery: muted medium grey armour with dull red accents (not black, not shiny). " +
  "Each machine has the SAME grafted alien control node, large, glowing red and clearly visible from far away, looking foreign on the simple human machine; it is the machine's weak point. " +
  "Background: intact blocky low poly buildings in cream, terracotta, sage green and sky blue, warm bright artificial daylight, soft shadows. " +
  "No people, no humans, no text, no letters, no interface, no border, no watermark. CONTROL NODE: "

$scenes = [ordered]@{
  "v1_crystal_spike" = "CRYSTAL SPIKE: a tall faceted red crystal spike set in a heavy bolted steel collar on top of each machine, thick black cables running from the collar down into the hull."
  "v2_brain_dome"    = "BRAIN DOME: a clear glass dome bolted on top of each machine, inside it a glowing red alien brain-like organ, faceted, with cables from the dome base into the chassis."
  "v3_halo_ring"     = "HALO RING: a floating flat ring of red light hovering in the air above each machine like a halo, not touching it, with several thin straight red beams shining down from the ring into the machine."
  "v4_eye_stalk"     = "EYE STALK: a long segmented alien neck rising from the top of each machine like a periscope, ending in one big glowing red faceted eyeball that peers around."
  "v5_bloom"         = "BLOOM: an alien flower crown on top of each machine: large angular fleshy petals opened outward around a bright glowing red core in the centre, like a low poly lotus."
  "v6_spine_fins"    = "SPINE FINS: a row of tall glowing red crystal dorsal spines and fins running along the back of each machine from front to rear, like a stegosaurus back."
  "v7_cowl"          = "COWL: an alien organic shell hood clamped over the top and front of each machine like a helmet, a smooth ridged carapace cowl with a glowing red slit visor, its claws gripping the steel."
  # r2b: first pass gave a small red grub on top; now a big tick on the flank.
  "v8_leech_clamp"   = "LEECH CLAMP: a BIG fat bloated alien tick, half the size of the machine's body, clamped onto the SIDE of each machine's hull, its round ribbed abdomen glowing red between dark armour ribs, six short hooked claw legs digging into the steel, and thick ribbed hoses from its head plugged into the chassis like a parasite feeding."
  "v9_hex_lantern"   = "HEX LANTERN: a hexagonal faceted glowing red lantern core held inside a sturdy steel cage frame mounted on top of each machine, cables running from the cage into the hull."
}

$keys = @($scenes.Keys | Where-Object { $Only.Count -eq 0 -or $Only -contains $_ })
$i = 0
foreach ($k in $keys) {
  $i++
  $keep = if ($i -lt $keys.Count) { @{ KeepServer = $true } } else { @{} }
  & $R -Name $k -Prompt ($common + $scenes[$k]) -Seeds $Seeds -Width 1024 -Height 576 -OutDir $out @keep
}
