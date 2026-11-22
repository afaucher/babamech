# Environment round 3: zones in day light, occupation shown as CONTROL (no battle damage), cylinder geometry fix.
Set-Location (Join-Path $PSScriptRoot "..\..")
$R = "$HOME\.claude\skills\local-render\render.ps1"
$out = "art\renders\env_r3"

$common = "Low poly 3D game environment concept render: CHUNKY low poly, big simple flat polygon faces with hard edges, one flat colour per face, no textures, few small details, simple blocky geometric shapes like a stylized indie game. " +
  "Inside a giant rotating cylinder space habitat, on one deck, looking ALONG the direction of spin. The ceiling is close overhead: a long FLAT band, the underside of the next deck, with straight parallel structural ribs and long straight light strips running ahead into the distance (NOT a round dome, NOT a circular ceiling, NOT a bowl or arena). " +
  "Straight ahead, far away, the ground gently CURVES UPWARD like the floor of a very long tilted tunnel, distant buildings rising up toward the ceiling; to the left and right the ground stays level. " +
  "Camera at ground level about eight metres up, like a third-person over-the-shoulder view from a walking mech, looking ahead. " +
  "Lighting: bright artificial daylight from the ceiling strips, warm sunny feel, soft blue haze in the distance, palette of cream, terracotta, sage green and sky blue. " +
  "The habitat is intact and clean but has been CONTROLLED by alien invaders for a long time: tall dark surveillance pylons with glowing red eye-lenses, checkpoint gates and cordon barriers, big alien banners and angular red-and-black signage hung on buildings, strange alien machinery grafted onto civic structures, parked civil-defense vehicles repainted in the invaders' colours, mostly empty curfew-quiet streets. NO destruction, NO fire, NO smoke, NO rubble, NO wrecked cars. " +
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
