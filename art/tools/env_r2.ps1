# Environment round 2: the five zone types (plus key habitat features) in the locked day + occupied look.
Set-Location (Join-Path $PSScriptRoot "..\..")
$R = "$HOME\.claude\skills\local-render\render.ps1"
$out = "art\renders\env_r2"

$common = "Low poly 3D game environment concept render: CHUNKY low poly, big simple flat polygon faces with hard edges, one flat colour per face, no textures, few small details, simple blocky geometric shapes like a stylized indie game. " +
  "Inside a giant rotating cylinder space habitat, on one deck. The ceiling is close overhead: the underside of the next deck, with structural ribs and long glowing light strips. " +
  "In the far distance the ground clearly CURVES UPWARD and away like the inside of a giant wheel, distant buildings tilted and rising up toward the ceiling. " +
  "Camera at ground level about eight metres up, like a third-person over-the-shoulder view from a walking mech, looking ahead. " +
  "Lighting: bright artificial daylight from the ceiling strips, warm sunny feel, soft blue haze in the distance, palette of cream, terracotta, sage green and sky blue. " +
  "The habitat is OCCUPIED by invading robots: wrecked and burning vehicles, concrete barricades, scorch marks, rubble, broken windows, columns of dark smoke, flashing red warning lights. " +
  "No people, no characters, no mechs, no robots visible. No text, no interface, no border, no watermark. SCENE: "

$scenes = [ordered]@{
  "a_urban_street" = "URBAN: a city street between blocky apartment and office buildings of varied heights, a few tall buildings rising all the way into the ceiling as structural pillars."
  "b_urban_roofs"  = "URBAN ROOFTOPS: view across flat rooftops at different heights with gaps between them, rooftop vents, water tanks and antennas, a tall pillar building merging into the ceiling."
  "c_park"         = "PARK: a recreation park with low poly trees, lawns, a pond, footpaths and a gazebo, slim tree-like pillars with leafy tops holding up the ceiling, city blocks at the edges."
  "d_industrial"   = "INDUSTRIAL: factories, storage tanks, pipes, conveyor gantries and cranes, chunky steel truss pillars up to the ceiling, hazard stripes."
  "e_openair"      = "OPEN AIR: the edge of a huge open shaft cut through the deck floor, a railing at the ledge, and looking DOWN through the shaft you see the next deck below with its own streets and buildings; light pours through."
  "f_transit_rail" = "TRANSIT: an elevated rail station with a monorail track on concrete pylons running along the deck, platforms, overhead wires, a derailed rail car."
  "g_transit_ramp" = "TRANSIT RAMP: a wide vehicle ramp spiralling DOWN through an opening in the floor to the next deck below, road markings, guard rails, abandoned trucks on the ramp."
  "h_elevator"     = "ELEVATOR: the base of a giant freight elevator built into a pillar that rises into the ceiling, big blast doors, loading bays, a plaza in front."
  "i_plaza"        = "CIVIC PLAZA: an open civic square with a fountain, a government building with columns, benches and banners, roads leading off in several directions."
}

$i = 0
foreach ($k in $scenes.Keys) {
  $i++
  $keep = if ($i -lt $scenes.Count) { @{ KeepServer = $true } } else { @{} }
  & $R -Name $k -Prompt ($common + $scenes[$k]) -Seeds 909 -Width 1024 -Height 576 -OutDir $out @keep
}
