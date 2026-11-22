# Chicken head close-ups. Attitude from Cluckipede concept art (art/reference/cluckipede): aggressive, scowling.
# Grid = 3 polygon budgets (rows) x 3 aggression levels (cols). Text only (a painterly ref would pull style away from low poly).
Set-Location (Join-Path $PSScriptRoot "..\..")
$R = "$HOME\.claude\skills\local-render\render.ps1"
$out = "art\renders\head_chicken_r1"

$common = "Close-up 3D render of a single game character head: a rooster chicken head and neck only, three-quarter front view, filling the frame. " +
  "TRUE LOW POLY game asset: built from clearly visible flat polygon faces with hard edges, every facet a single flat solid colour, flat shading, no smooth surfaces, no texture, no painted detail, no individual feathers or hair, " +
  "the feather ruff is a few big angular faceted shards. Simple enough to model by hand in Blender. " +
  "Colours: off-white head and neck, bright red comb and wattle, yellow-orange beak, dark eye. " +
  "Against a plain even soft grey-blue background, soft studio lighting from the upper left. No text, no interface, no border, no watermark. "

$polys = [ordered]@{
  "p150" = "Extremely low polygon count, about 150 faces: big chunky facets, the comb is a few sharp triangular spikes."
  "p400" = "Low polygon count, about 400 faces: clear triangular facets, readable shapes."
  "p900" = "Moderate low polygon count, about 900 faces: smaller facets but every polygon edge still clearly visible."
}
$moods = [ordered]@{
  "stern"   = "Expression: stern and determined, heavy angled brow ridge over a narrowed eye, beak closed, a tough soldier."
  "angry"   = "Expression: angry and aggressive, deep furrowed brow, glaring eye, beak half open in a squawk, hackles raised."
  "furious" = "Expression: furious battle-scarred war rooster, scar across the eye, beak wide open screaming, ragged comb with a notch missing, feather shards flared out."
}

$i = 0; $n = $polys.Count * $moods.Count
foreach ($p in $polys.Keys) { foreach ($m in $moods.Keys) {
  $i++
  $keep = if ($i -lt $n) { @{ KeepServer = $true } } else { @{} }
  & $R -Name "${p}_${m}" -Prompt ($common + $polys[$p] + " " + $moods[$m]) -Seeds 808 -Width 768 -Height 768 -OutDir $out @keep
} }
