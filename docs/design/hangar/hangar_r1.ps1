# Hangar round 1: the inside of an assault boarding vessel, clamped to the habitat, about to force-board.
# Grid axes: rows = vessel origin (civil-defense rescue tender / purpose-built assault boat / improvised salvage tug),
#            cols = moment (quiet prep / launch alert / breach cutting through the hull).
$R = "$HOME\.claude\skills\local-render\render.ps1"
$out = $PSScriptRoot
$style = "Low poly 3D game art, flat-shaded faceted surfaces with flat colour per face, no textures, clean stylized look. " +
  "Wide interior shot of a cramped vehicle bay inside a boarding spacecraft, camera at chest height looking down the bay. " +
  "In the right half of the frame stands one compact two-legged mech held in a docking cradle: rounded white and " +
  "safety-orange armored torso, amber lights, no arms, reverse-jointed mechanical chicken legs with three forward toes, " +
  "a pilot hatch on top, missile pods raised on the shoulders. The left third of the frame is darker, plain wall, " +
  "uncluttered (room for a menu). At the far end of the bay is a heavy breaching door or ram pressed against the " +
  "outer hull of a giant space habitat. "
$tail = " No people, no text, no interface, no border, no watermark."

$origin = @{
  tender  = "The vessel is a civil-defense rescue tender: clean white and orange panels matching the mech, rounded padded walls, tidy cable runs, green safety markings, a stretcher rack folded on the wall."
  assault = "The vessel is a purpose-built military assault boat: gunmetal grey armor plates, exposed ribs and girders, heavy hydraulic clamps, yellow-black hazard stripes, rows of ammunition racks."
  salvage = "The vessel is an improvised salvage tug pressed into service: mismatched welded plates, rusty ochre and teal paint, cargo crates strapped down, cables hanging, a cutting torch rig bolted on by hand."
}
$moment = @{
  prep   = "Quiet preparation: even cool white work lights, maintenance arms resting, calm."
  alert  = "Launch alert: the bay is lit by rotating red-orange warning beacons and amber strobes, a countdown glow on the breaching door, clamps opening."
  breach = "Breach in progress: a ring of glowing white-hot molten metal is being cut through the habitat hull beyond the door, sparks spraying into the bay, warm orange light flooding in."
}

foreach ($o in "tender","assault","salvage") {
  foreach ($m in "prep","alert","breach") {
    & $R -Name "hangar_${o}_${m}" -Prompt ($style + $origin[$o] + " " + $moment[$m] + $tail) -Seeds 41 -OutDir $out -KeepServer
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }
}
& $R -StopServer
$items = foreach ($o in "tender","assault","salvage") { foreach ($m in "prep","alert","breach") { "$out\hangar_${o}_${m}_s41.png|$o / $m" } }
python "C:\Users\alexa\Documents\GitHub\babamech\art\tools\make_grid.py" "$out\grid_hangar_r1.png" "Hangar r1: boarding vessel (rows: origin, cols: moment)" @items
