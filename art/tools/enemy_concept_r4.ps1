# Enemy concept round 4: heraldic corruption (user: "Show me more options for heraldic corruption", from r1 cell 8).
# The invaders mark the hijacked civil-defence machines as THEIRS: heraldry, not damage. Constant across cells:
# civic base group, A2 livery, the r3 B1 violet gem beacon fitted on the body, one angular alien sigil.
# Usage: .\art\tools\enemy_concept_r4.ps1 [-Only h1_tabard,...] [-Seeds 4242]
param([string[]]$Only = @(), [int[]]$Seeds = @(4242))
Set-Location (Join-Path $PSScriptRoot "..\..")
$R = "$HOME\.claude\skills\local-render\render.ps1"
$out = "art\renders\enemy_concept_r4"

$common = "Low poly 3D video game concept render of enemy war machines: CHUNKY low poly, big simple flat polygon faces with hard edges, one flat colour per face, no textures, no grime, no rust, no damage, no photorealism, simple blocky geometric shapes like a stylized indie game. " +
  "One enemy group standing together in the middle of a sunny clean low poly city street, three-quarter view from slightly above, all three machines fully in frame: " +
  "a plain boxy civic civil-defence TRACKED TANK with a turret; a two-legged civic WALKER ROBOT with ostrich legs like a chicken walker or an AT-ST: a short boxy body on long digitigrade bird legs, the thigh angles forward and the lower leg angles BACKWARD, so the leg forms a backward-pointing zig-zag with the reverse knee joint behind the body, standing on splayed toes; the whole leg is grey steel machinery like the rest of the robot (not organic, not orange); and a small boxy HOVERING DRONE floating beside them. " +
  "Livery: warm slate grey armour body with muted brick-red trim stripes and small red camera optics (not black, not shiny). " +
  "Each machine carries the SAME small, subtle alien device fitted flush ONTO the side or front face of its main body mass, like a bolted-on module, NOT perched on top: on the tank it sits on the hull's front sloped armour plate (not on the turret roof); on the walker it sits in the middle of its chest, on the front face of the torso; on the drone it sits on the front face of its box body. The device is a small faceted glowing violet gem, an octahedron, in a small steel bracket, with a single thin whip antenna rising a little way up along the body. " +
  "The invaders have claimed these machines with HERALDRY: their one alien sigil, a simple angular emblem of a stylised eye inside a downward chevron, in deep violet and brick red, repeated on each machine. Clean and orderly, ceremonial, not damaged. " +
  "Background: intact blocky low poly buildings in cream, terracotta, sage green and sky blue, warm bright artificial daylight, soft shadows. " +
  "No people, no humans, no text, no letters, no interface, no border, no watermark. HERALDRY: "

$scenes = [ordered]@{
  "h1_tabard"   = "TABARD BANNERS: long straight cloth banners and tabards in deep violet with brick-red borders hanging down from the tank hull sides and from the walker's chest, and a small one under the drone, each showing the eye-chevron sigil."
  "h2_overpaint" = "PAINTED-OVER CREST: the old civic municipal crest and yellow-and-white civic service stripes are still visible on each machine, but crudely painted over with a big stencilled violet eye-chevron sigil and violet overpaint blocks, the civic stripes peeking out around it. Clean paint, no rust, no damage."
  "h3_pennants" = "PENNANTS: small triangular violet and brick-red pennant flags with the sigil fluttering from the antenna tips and from two thin poles mounted on the back of each machine."
  "h4_shields"  = "SHIELD PLATES: big angular heraldic shield-shaped armour plates bolted onto the walker's shoulders and the tank's hull sides and turret, one on the drone's side, each plate painted violet with the eye-chevron sigil in brick red."
  "h5_sash"     = "SASH: a wide diagonal ceremonial cloth sash in deep violet with brick-red edges wrapped across each machine's body like an order of knighthood, with the sigil as a badge where the sash crosses the front."
  "h6_crest"    = "CREST FINS: a tall angular ceremonial crest fin like a parade plume or helmet crest on top of the walker's head and on top of the tank turret, a small one on the drone, the fins violet with brick-red edges and the sigil on their side."
  "h7_glyphs"   = "GLYPH BANDS: rows of angular blocky alien glyph symbols painted as horizontal bands around the tank hull, the turret, the walker's torso and legs, and around the drone, in violet on the slate grey, like ownership ID markings, plus the sigil once on each machine."
  "h8_seal"     = "CHAIN AND SEAL: decorative heavy steel chains draped across each machine with a large round violet wax-seal-like medallion hanging from them stamped with the eye-chevron sigil, an ownership seal on the tank hull, the walker's chest area and the drone."
  "h9_livery"   = "FULL LIVERY: the civic paint fully replaced by an all-over heraldic paint scheme: bold quartered fields and big chevron stripes in slate grey and deep violet with brick-red edging covering every panel of all three machines, and the sigil large on the tank turret and walker body."
}

$keys = @($scenes.Keys | Where-Object { $Only.Count -eq 0 -or $Only -contains $_ })
$i = 0
foreach ($k in $keys) {
  $i++
  $keep = if ($i -lt $keys.Count) { @{ KeepServer = $true } } else { @{} }
  & $R -Name $k -Prompt ($common + $scenes[$k]) -Seeds $Seeds -Width 1024 -Height 576 -OutDir $out @keep
}
