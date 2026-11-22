# Environment round 1: establish the habitat look on an URBAN street. Grid = lighting mood (rows) x condition (cols).
Set-Location (Join-Path $PSScriptRoot "..\..")
$R = "$HOME\.claude\skills\local-render\render.ps1"
$out = "art\renders\env_r1"

$common = "Low poly 3D game environment concept render, flat-shaded faceted polygons, every surface built from visible flat faces with a single flat colour, no textures, clean simple geometric shapes, highly stylized. " +
  "Interior of a giant rotating cylinder space habitat: a dense city street on one deck of the habitat. " +
  "Camera at the height of a two-storey building looking down a street, like a third-person view over the shoulder of a walking mech. " +
  "Blocky buildings of varied heights line the street, with flat rooftops at different levels a giant mech could jump between. Some of the tallest buildings rise all the way up and merge into the ceiling as structural pillars. " +
  "The ceiling is close overhead: it is the underside of the next deck, with structural ribs, panels and long light strips. " +
  "In the distance the ground curves UPWARD like the inside of a huge ring, the far streets and rooftops rising up toward the ceiling. " +
  "A road with a few low poly vehicles, sidewalks, small trees in planters, street lamps. No people, no characters, no mechs. No text, no interface, no border, no watermark. "

$moods = [ordered]@{
  "day"   = "Lighting: bright artificial daylight from the ceiling light strips, warm sunny feel, soft blue haze in the distance, palette of cream, terracotta, sage green and sky blue."
  "clinical" = "Lighting: cool even white light from the ceiling, clean clinical space-station feel, palette of white, pale grey, teal and safety orange accents."
  "dusk"  = "Lighting: artificial dusk cycle, the ceiling strips dimmed to amber and violet, lit windows and neon signs glowing on buildings, palette of deep blue, purple, warm orange and pink."
}
$conds = [ordered]@{
  "pristine" = "Condition: pristine and orderly utopian habitat, everything clean and maintained."
  "livedin"  = "Condition: lived-in and busy, laundry lines, awnings, signs, clutter, air ducts and pipes added onto buildings, a bit cramped and messy."
  "occupied" = "Condition: occupied by invading robots, abandoned crashed vehicles, barricades, scorch marks, broken windows, smoke rising, some warning lights flashing red."
}

$i = 0; $n = $moods.Count * $conds.Count
foreach ($m in $moods.Keys) { foreach ($c in $conds.Keys) {
  $i++
  $keep = if ($i -lt $n) { @{ KeepServer = $true } } else { @{} }
  & $R -Name "${m}_${c}" -Prompt ($common + $moods[$m] + " " + $conds[$c]) -Seeds 909 -Width 1024 -Height 576 -OutDir $out @keep
} }
