# Pickle / corn / dog head close-ups matched to the locked chicken: ~150-face true low poly, Cluckipede attitude.
# Grid = 3 characters (rows) x 3 aggression levels (cols).
Set-Location (Join-Path $PSScriptRoot "..\..")
$R = "$HOME\.claude\skills\local-render\render.ps1"
$out = "art\renders\head_others_r1"

$common = "Close-up 3D render of a single game character head and neck only, three-quarter front view, filling the frame. " +
  "TRUE LOW POLY game asset, extremely low polygon count, about 150 faces: big chunky clearly visible flat polygon faces with hard edges, every facet a single flat solid colour, flat shading, no smooth surfaces, no texture, no painted detail, no fur, no hair. " +
  "Simple enough to model by hand in Blender. Eyes are simple faceted shapes with a dark pupil and a heavy faceted brow above them. " +
  "Against a plain even soft grey-blue background, soft studio lighting from the upper left. No text, no interface, no border, no watermark. "

$chars = [ordered]@{
  "pickle" = "The character is a dill pickle: an upright green cucumber-shaped head with a few faceted bumps, darker green stripes as flat facets, a wide mouth."
  "corn"   = "The character is a corn cob: an upright yellow cob head whose kernels are rows of chunky faceted blocks, green husk leaves peeled back around the neck as big angular shards, a wide mouth."
  "dog"    = "The character is a dog: a golden-brown muzzle and head with angular floppy ears as big flat planes, a black faceted nose, a jaw that can show teeth."
}
$moods = [ordered]@{
  "stern"   = "Expression: stern and determined, heavy angled brow over narrowed eyes, mouth closed, a tough soldier."
  "angry"   = "Expression: angry and aggressive, deep furrowed brow, glaring eyes, mouth half open snarling."
  "furious" = "Expression: furious battle-scarred veteran, a scar across one eye, mouth wide open screaming, a chunk missing from the top."
}

$i = 0; $n = $chars.Count * $moods.Count
foreach ($c in $chars.Keys) { foreach ($m in $moods.Keys) {
  $i++
  $keep = if ($i -lt $n) { @{ KeepServer = $true } } else { @{} }
  & $R -Name "${c}_${m}" -Prompt ($common + $chars[$c] + " " + $moods[$m]) -Seeds 808 -Width 768 -Height 768 -OutDir $out @keep
} }
