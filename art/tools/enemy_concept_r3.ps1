# Enemy concept round 3: subtle purple beacon x antenna (user: "something more subtle, like a purple glowing beacon
# with an antenna attached more centrally"). Rows = beacon form (A orb, B gem, C cylinder lamp),
# columns = antenna (1 whip, 2 twin prongs, 3 mast with ring). Livery A2: warm slate grey, muted brick-red trim.
# Usage: .\art\tools\enemy_concept_r3.ps1 [-Only A1,B2] [-Seeds 4242]
param([string[]]$Only = @(), [int[]]$Seeds = @(4242))
Set-Location (Join-Path $PSScriptRoot "..\..")
$R = "$HOME\.claude\skills\local-render\render.ps1"
$out = "art\renders\enemy_concept_r3"

$common = "Low poly 3D video game concept render of enemy war machines: CHUNKY low poly, big simple flat polygon faces with hard edges, one flat colour per face, no textures, no grime, no photorealism, simple blocky geometric shapes like a stylized indie game. " +
  "One enemy group standing together in the middle of a sunny clean low poly city street, three-quarter view from slightly above, all three machines fully in frame: " +
  "a plain boxy civic civil-defence TRACKED TANK with a turret; a two-legged civic WALKER ROBOT with ostrich legs like a chicken walker or an AT-ST: a short boxy body on long digitigrade bird legs, the thigh angles forward and the lower leg angles BACKWARD, so the leg forms a backward-pointing zig-zag with the reverse knee joint behind the body, standing on splayed toes; the whole leg is grey steel machinery like the rest of the robot (not organic, not orange); and a small boxy HOVERING DRONE floating beside them. " +
  "Livery: warm slate grey armour body with muted brick-red trim stripes and small red camera optics (not black, not shiny). " +
  "Each machine carries the SAME small, subtle alien device fitted flush ONTO the side or front face of its main body mass, like a bolted-on module, NOT perched on top: on the tank it sits on the hull's front sloped armour plate (not on the turret roof); on the walker it sits in the middle of its chest, on the front face of the torso; on the drone it sits on the front face of its box body. Its antenna sprouts from the device and rises a little way up along the body. The device is SMALL, about the size of a hatch, softly glowing PURPLE violet, neat and compact, noticeable up close but not dominant; no big crystal, no sprawling cables, no other alien parts. " +
  "Background: intact blocky low poly buildings in cream, terracotta, sage green and sky blue, warm bright artificial daylight, soft shadows. " +
  "No people, no humans, no text, no letters, no interface, no border, no watermark. DEVICE: "

$beacon = [ordered]@{
  "A" = @("orb",      "a small softly glowing violet ORB sphere seated in a low round steel collar")
  "B" = @("gem",      "a small faceted glowing violet GEM, an octahedron diamond shape, held in a small steel bracket")
  "C" = @("cylinder", "a short glowing violet CYLINDER LAMP like a police beacon light, with a flat steel cap on top; exactly ONE lamp per machine, on the body face only, NO lamp on the turret roof or on the top of the drone")  # r3b: first pass doubled the lamp onto turret/drone tops
}
$antenna = [ordered]@{
  "1" = @("whip",   "with a single thin whip antenna rising straight up from the beacon, longer than the beacon is tall")
  "2" = @("prongs", "with a short twin-pronged forked antenna, two short thin prongs rising in a V from the beacon")
  "3" = @("mast",   "with a short thin antenna mast rising from the beacon carrying a small flat ring disc near its tip")
}

$jobs = [ordered]@{}
foreach ($b in $beacon.Keys) { foreach ($a in $antenna.Keys) {
  $id = "$b$a"
  if ($Only.Count -eq 0 -or $Only -contains $id) {
    $jobs["${id}_$($beacon[$b][0])_$($antenna[$a][0])"] = "$($beacon[$b][1]), $($antenna[$a][1])."
  }
} }

$i = 0
foreach ($k in $jobs.Keys) {
  $i++
  $keep = if ($i -lt $jobs.Count) { @{ KeepServer = $true } } else { @{} }
  & $R -Name $k -Prompt ($common + $jobs[$k]) -Seeds $Seeds -Width 1024 -Height 576 -OutDir $out @keep
}
