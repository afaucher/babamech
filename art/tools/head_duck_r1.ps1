# Duck pilot head, matched to the locked chicken / pickle / corn / dog: ~150-face true low poly, stern Cluckipede attitude.
# Grid = 3 plumages (rows) x 3 head/bill shapes (cols). Expression is fixed: stern, bill closed.
Set-Location (Join-Path $PSScriptRoot "..\..")
$R = "$HOME\.claude\skills\local-render\render.ps1"
$out = "art\renders\head_duck_r1"

$common = "Close-up 3D render of a single game character head and neck only: a duck, three-quarter front view, filling the frame. " +
  "TRUE LOW POLY game asset, extremely low polygon count, about 150 faces: big chunky clearly visible flat polygon faces with hard edges, every facet a single flat solid colour, flat shading, no smooth surfaces, no texture, no painted detail, no individual feathers. " +
  "Simple enough to model by hand in Blender. The eye is a simple faceted shape with a dark pupil under a heavy faceted angled brow ridge. " +
  "Expression: stern and determined, heavy angled brow over a narrowed eye, bill closed, a tough soldier. " +
  "Against a plain even soft grey-blue background, soft studio lighting from the upper left. No text, no interface, no border, no watermark. "

$plumes = [ordered]@{
  "mallard" = "Plumage: a mallard drake, iridescent dark green head as flat green facets, a thin white neck ring, brown chest at the bottom, yellow bill."
  "white"   = "Plumage: a white farm duck, off-white head and neck in flat cream facets, bright orange bill."
  "teal"    = "Plumage: a brown speckled hen duck, warm brown head in two tones of flat facets, a dark eye stripe, a teal-blue patch, dull orange bill."
}
$shapes = [ordered]@{
  "broad" = "Shape: a round head and a long broad flat spoon-shaped bill, the bill as one big angular slab."
  "tuft"  = "Shape: a sleek head with a short spiky crest tuft of three angular feather shards at the back of the crown, a medium flat bill."
  "heavy" = "Shape: a heavy square-jawed head with puffed cheeks, a short wide stubby bill with a hooked nail at the tip."
}

$i = 0; $n = $plumes.Count * $shapes.Count
foreach ($p in $plumes.Keys) { foreach ($s in $shapes.Keys) {
  $i++
  $keep = if ($i -lt $n) { @{ KeepServer = $true } } else { @{} }
  & $R -Name "${p}_${s}" -Prompt ($common + $plumes[$p] + " " + $shapes[$s]) -Seeds 808 -Width 768 -Height 768 -OutDir $out @keep
} }

$items = @()
foreach ($p in $plumes.Keys) { foreach ($s in $shapes.Keys) { $items += "$out\${p}_${s}_s808.png|$p / $s" } }
python art\tools\make_grid.py "$out\grid_head_duck_r1.png" "Duck head r1: plumage (rows) x shape (cols), stern, ~150 faces" @items
