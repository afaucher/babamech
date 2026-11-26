# build.ps1 - import, run the full test gate, then export build\windows\babamech.exe and zip it (ported from flap / cast).
#
#   .\build.ps1              # tests, then export + zip
#   .\build.ps1 -SkipTests   # export only (UNVERIFIED build)
#   .\build.ps1 -Force       # export even if tests failed
#
# Export templates (4.7.stable) live in build\deps\godot-data; APPDATA points there for the export only. If missing they
# are copied from flap's or cast's build\deps\godot-data. Every build is stamped yyyy-MM-dd.HHmmss into version.txt
# (gitignored, packed into the .pck: BuildVersion, and the Steam lobby match key), build\windows\version.txt and the zip name.
# steam_appid.txt and the GodotSteam DLLs go next to the exe.
param([switch]$SkipTests, [switch]$Force)

$GameName = "babamech"
$buildVersion = Get-Date -Format "yyyy-MM-dd.HHmmss"
Write-Host "Build version: $buildVersion" -ForegroundColor Cyan

. "$PSScriptRoot\godot_env.ps1"
$godot = Resolve-BabamechGodot
Write-Host "Importing project..." -ForegroundColor Cyan
Invoke-BabamechImport $godot

if (-not $SkipTests) {
    & "$PSScriptRoot\test_runner.ps1" -TestAll -NoImport
    if ($LASTEXITCODE -ne 0 -and -not $Force) { Write-Host "BUILD ABORTED: tests failed." -ForegroundColor Red; exit 1 }
}

$dataDir = Join-Path $PSScriptRoot "build\deps\godot-data"
$rel = "Godot\export_templates\4.7.stable\windows_release_x86_64.exe"
if (-not (Test-Path (Join-Path $dataDir $rel))) {
    $scratch = Join-Path $env:USERPROFILE ".gemini\antigravity\scratch"
    foreach ($src in @((Join-Path $scratch "flap\build\deps\godot-data"), (Join-Path $scratch "cast\build\deps\godot-data"))) {
        if (Test-Path (Join-Path $src $rel)) {
            Write-Host "Copying export templates from $src ..." -ForegroundColor Cyan
            New-Item -ItemType Directory -Force -Path (Split-Path $dataDir) | Out-Null
            Copy-Item $src -Destination $dataDir -Recurse -Force
            break
        }
    }
}
if (-not (Test-Path (Join-Path $dataDir $rel))) { Write-Host "Missing export templates: $dataDir\$rel" -ForegroundColor Red; exit 1 }

$outDir = Join-Path $PSScriptRoot "build\windows"
# Never kill a running babamech: this script starts none, and other sessions' windows (or a playtest of the last
# build) may be running. If something still runs from build\windows (the exe about to be replaced), stop and say so.
$running = @(Get-Process -Name $GameName -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and ([IO.Path]::GetFullPath($_.Path)).StartsWith([IO.Path]::GetFullPath($outDir) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) })
if ($running.Count -gt 0) {
    Write-Host ("BUILD ABORTED: {0} is running from {1} (pid {2}); close it and build again." -f $GameName, $outDir, (($running | ForEach-Object { $_.Id }) -join ", ")) -ForegroundColor Red
    exit 1
}
if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$exe = Join-Path $outDir "$GameName.exe"
Set-Content -Path "$PSScriptRoot\version.txt" -Value $buildVersion
Write-Host "Exporting $exe ..." -ForegroundColor Cyan
$oldAppData = $env:APPDATA
$env:APPDATA = $dataDir
try {
    & $godot --path $PSScriptRoot --headless --export-release "Windows Desktop" $exe 2>&1 |
        Where-Object { $_ -match "ERROR|WARNING|error" } | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
} finally { $env:APPDATA = $oldAppData }
foreach ($f in @("$GameName.exe", "$GameName.pck")) {
    if (-not (Test-Path (Join-Path $outDir $f))) { Write-Host "BUILD FAILED: missing $f" -ForegroundColor Red; exit 1 }
}
Set-Content -Path (Join-Path $outDir "version.txt") -Value $buildVersion
Copy-Item "$PSScriptRoot\steam_appid.txt" -Destination $outDir -Force

$zip = Join-Path $PSScriptRoot "build\${GameName}_Windows_v$buildVersion.zip"
Get-ChildItem -Path (Join-Path $PSScriptRoot "build") -Filter "${GameName}_Windows_v*.zip" -File -ErrorAction SilentlyContinue | Remove-Item -Force
Compress-Archive -Path (Get-ChildItem $outDir -File -Recurse | ForEach-Object { $_.FullName }) -DestinationPath $zip -Force
Write-Host "Build complete: $buildVersion" -ForegroundColor Green
Write-Host "  Executable: $exe"
Write-Host "  ZIP: $zip"
exit 0
