# Mech HUD round 1: 3x3 mockups. Rows = layout, columns = visual style. Renders with the local-render skill (it takes
# the shared GPU lock). Output beside this script; grid_hud_r1.png is the one to look at.
$R = "$HOME\.claude\skills\local-render\render.ps1"
$out = $PSScriptRoot
$scene = "A video game screenshot, third-person over-the-shoulder camera behind and slightly above a compact two-legged mech " +
  "in the lower middle of the frame: rounded white and safety-orange armored torso, no arms, reverse-jointed mechanical " +
  "chicken legs, a pilot's oversized low-poly chicken head sticking out of the top hatch, two weapon pods raised on its " +
  "shoulders, guns on both hips and a mortar on its back. It walks down a sunny low-poly city street inside a space " +
  "habitat (cream and terracotta buildings, the ground curving up in the hazy distance). Over the game view is the " +
  "player's HUD: a small crosshair at the screen centre with thin lines from each of the mech's five weapons converging " +
  "on the aim point; five numbered weapon readouts (1 to 5) each with a weapon icon, an ammo count and a reload bar, one " +
  "of them greyed out as disabled; a heat gauge nearly half full; a small mech silhouette damage diagram with the left " +
  "leg tinted orange as damaged. Text is simple short placeholder glyphs and numbers. "
$tail = " Crisp, readable game UI, flat vector shapes. No watermark, no border."

$layout = @{
  diegetic = "Layout: diegetic, attached to the mech: each weapon's readout floats beside its own hardpoint on the mech, the heat gauge is a curved bar along the mech's back plate, the damage diagram is a small hologram above the hatch; the screen edges stay empty."
  cockpit  = "Layout: a cockpit frame: a solid instrument strip along the bottom of the screen with the five weapon cards side by side in the middle, the damage silhouette at its left end and a big vertical heat gauge at its right end; thin frame brackets in the top corners."
  corners  = "Layout: minimal corners: the damage diagram with a heat arc wrapped around it in the bottom-left corner, the five weapons as a compact stacked list in the bottom-right corner, nothing else on screen but the crosshair."
}
$style = @{
  civil  = "Style: civil-defense livery: solid flat panels in off-white and safety orange with amber highlights and dark grey text, rounded corners, like municipal emergency equipment."
  amber  = "Style: military monochrome: thin glowing amber lines and numbers on translucent dark panels, segmented bars, like an old CRT targeting display."
  holo   = "Style: clean holographic: thin cyan and white wireframe lines, translucent glassy panels, soft glow, minimal sci-fi."
}

foreach ($l in "diegetic","cockpit","corners") {
  foreach ($s in "civil","amber","holo") {
    & $R -Name "hud_${l}_${s}" -Prompt ($scene + $layout[$l] + " " + $style[$s] + $tail) -Seeds 7 -OutDir $out -KeepServer
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }
}
& $R -StopServer
$items = foreach ($l in "diegetic","cockpit","corners") { foreach ($s in "civil","amber","holo") { "$out\hud_${l}_${s}_s7.png|$l / $s" } }
python "C:\Users\alexa\Documents\GitHub\babamech\art\tools\make_grid.py" "$out\grid_hud_r1.png" "HUD r1 (rows: layout, cols: style)" @items
