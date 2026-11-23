# Invader banner round 1: banner cut + emblem FORM (colour is chosen in-engine; every cell uses the same 3 colours).
# The occupation shows in the city through official alien banners; enemy robots are repainted civic machines.
# Usage: .\art\tools\banner_r1.ps1 [-Only b1_eye_chevron,...] [-Seeds 4242]
param([string[]]$Only = @(), [int[]]$Seeds = @(4242))
Set-Location (Join-Path $PSScriptRoot "..\..")
$R = "$HOME\.claude\skills\local-render\render.ps1"
$out = "art\renders\banner_r1"

$common = "Low poly 3D video game concept render: CHUNKY low poly, big simple flat polygon faces with hard edges, one flat colour per face, no textures, no fabric detail, no grime, no damage, no photorealism, like a stylized indie game. " +
  "Seen almost straight-on: the cream and terracotta facade of a blocky low poly city building in warm bright artificial daylight, and hanging on it ONE tall vertical banner from a horizontal steel cross-bar, large and centred in the frame so its emblem reads clearly. " +
  "The banner is official state authority propaganda of an alien regime that quietly rules the city: orderly, clean, symmetrical, imposing, like a government banner, not a war flag. " +
  "The banner uses ONLY three flat colours: a brick-red field, warm slate-grey, and cream; no other colours, no gold, no black. The emblem is made of a few BOLD flat geometric polygons, simple enough to read from fifty metres away, no fine detail, no text, no letters. " +
  "Small at the side of the frame, standing on the pavement: a plain boxy grey civic civil-defence walker robot with backward-bending bird legs, repainted slate grey with brick-red trim, the SAME emblem stencilled in cream on its hull. " +
  "No people, no text, no letters, no interface, no border, no watermark. BANNER: "

$scenes = [ordered]@{
  "b1_eye_chevron" = "EYE IN CHEVRON: emblem of a stylised angular eye inside a big downward-pointing chevron; the banner's bottom edge is cut as a swallowtail with two points."
  "b2_rings"       = "CONCENTRIC RINGS: emblem of three bold concentric rings like a surveillance target or an iris, with a solid centre; the banner's bottom edge is straight with one central point."
  # r1b: first pass read as a fan / shell over a ring; now a hand-like talon from below.
  "b3_grip"        = "GRIP: emblem of a plain thick cream circle ring in the centre, and three separate angular hooked claw prongs in slate grey around it, coming up from below at left, centre and right like a crane grabber, their hooked tips bending over the ring and closing on it, symmetrical; the banner is a plain rectangle with a row of short fringe tassels along the bottom."
  "b4_tricrown"    = "TRI-CROWN: emblem of three tall angular spikes rising from a horizontal bar, like a sharp crown, the middle spike tallest; the banner's bottom edge comes to a single point."
  "b5_glyphs"      = "GLYPH COLUMN: a long narrow streamer banner with a vertical column of four bold angular alien glyph symbols stacked one above the other, each glyph a few thick straight strokes, not letters."
  # r1b: first pass gave concentric squares; now a single continuous swirl.
  "b6_spiral"      = "SPIRAL: emblem of ONE continuous bold spiral line winding inward in three turns, made of straight angled segments like a low poly whirlpool or snail shell, open at the outer end, not concentric rings, not squares; the banner field is split vertically into two halves, brick red and slate grey."
  "b7_minimal"     = "MINIMAL: emblem of a single inverted triangle with one round dot in its centre; the banner is a plain rectangle with a wide cream border all round."
  "b8_hex_eye"     = "HEX EYE: emblem of a bold hexagon with a narrow vertical slit pupil in its centre like a reptile eye; the banner's bottom edge has a rectangular notch cut into it."
  "b9_descent"     = "DESCENT: emblem of a bold downward-pointing arrow or comet head with three parallel trailing bars above it, as if arriving from the sky; the banner's bottom edge is cut as a swallowtail."
}

$keys = @($scenes.Keys | Where-Object { $Only.Count -eq 0 -or $Only -contains $_ })
$i = 0
foreach ($k in $keys) {
  $i++
  $keep = if ($i -lt $keys.Count) { @{ KeepServer = $true } } else { @{} }
  & $R -Name $k -Prompt ($common + $scenes[$k]) -Seeds $Seeds -Width 1024 -Height 576 -OutDir $out @keep
}
