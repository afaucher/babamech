# Hangar v2 (2026-11-25): nine ways a mech leaves the assault boat's bay. One prompt file per concept in prompts\.
# local-render skill, flux3_klein_t2i, 1024x576, seeds 11 and 22. Then: python make_grid.py (scratch) for hangar_grid.png.
$R = "$HOME\.claude\skills\local-render\render.ps1"
$out = $PSScriptRoot
foreach ($f in Get-ChildItem "$out\prompts\*.txt" | Sort-Object Name) {
  & $R -Name $f.BaseName -PromptFile $f.FullName -Seeds 11,22 -OutDir "$out\renders" -KeepServer
  if ($LASTEXITCODE -ne 0) { & $R -StopServer; exit $LASTEXITCODE }
}
