# Menu mech placement (2026-11-25): img2img from the in-engine blockout shots (engine_*.png) with flux3_klein_refs,
# 1024x848 (the menu's preview area is about 1078x900), seeds 11 and 22. Prompts in prompts\.
$R = "$HOME\.claude\skills\local-render\render.ps1"
$out = $PSScriptRoot
$refs = @{ A_cradle = "engine_A_cradle.png"; B_outside = "engine_B_outside.png"; C_holo = "engine_C_holo.png" }
foreach ($k in "A_cradle","B_outside","C_holo") {
  & $R -Name $k -PromptFile "$out\prompts\$k.txt" -Refs "$out\$($refs[$k])" -Seeds 11,22 -Width 1024 -Height 848 -OutDir "$out\renders" -KeepServer
  if ($LASTEXITCODE -ne 0) { & $R -StopServer; exit $LASTEXITCODE }
}
