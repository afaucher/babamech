# Crew panel (friendly players' health / status / icon) round 1: 3x3 mockups in the picked HUD style (corners / holo).
# Rows = where the panel sits, columns = the portrait. Renders with the local-render skill (it takes the GPU lock).
$R = "$HOME\.claude\skills\local-render\render.ps1"
$out = $PSScriptRoot
$scene = "A video game screenshot, third-person camera behind a compact two-legged white and orange mech with reverse-jointed " +
  "chicken legs walking down a sunny low-poly city street inside a space habitat. The player's HUD is thin cyan and " +
  "white holographic lines on translucent dark glass panels with small corner brackets: a mech damage diagram with a heat " +
  "arc in the bottom-left corner and a stacked weapon list in the bottom-right corner. The focus is a CREW PANEL showing " +
  "three teammates, one card each: a portrait, the player name as short placeholder text, a horizontal health bar, a thin " +
  "heat bar under it, and a status: the first teammate healthy (cyan), the second overheated (amber bar, a warning glyph), " +
  "the third disabled and needing a revive (portrait greyed out, a red cross icon and a countdown ring). "
$tail = " Crisp, readable game UI, flat vector shapes. No watermark, no border."

$place = @{
  left   = "Placement: the three crew cards stacked vertically along the left edge of the screen, at mid height, compact."
  top    = "Placement: the three crew cards side by side in a row along the top centre of the screen, small."
  corner = "Placement: the three crew cards stacked directly above the player's own damage diagram in the bottom-left corner, forming one column of crew status."
}
$portrait = @{
  steam = "Portrait: each card has a small square online-profile avatar picture (a simple flat illustrated avatar)."
  head  = "Portrait: each card has the teammate's oversized cartoon low-poly pilot head in a circle (a chicken, a pickle, a dog), flat faceted colours."
  both  = "Portrait: each card has the teammate's low-poly pilot head in a hexagon frame (a chicken, a pickle, a dog), with a tiny square profile avatar badge on its corner."
}

foreach ($p in "left","top","corner") {
  foreach ($q in "steam","head","both") {
    & $R -Name "crew_${p}_${q}" -Prompt ($scene + $place[$p] + " " + $portrait[$q] + $tail) -Seeds 7 -OutDir $out -KeepServer
    if ($LASTEXITCODE -ne 0) { & $R -StopServer; exit $LASTEXITCODE }
  }
}
& $R -StopServer
$items = foreach ($p in "left","top","corner") { foreach ($q in "steam","head","both") { "$out\crew_${p}_${q}_s7.png|$p / $q" } }
python "C:\Users\alexa\Documents\GitHub\babamech\art\tools\make_grid.py" "$out\grid_hud_crew_r1.png" "Crew panel r1 (rows: placement, cols: portrait)" @items
