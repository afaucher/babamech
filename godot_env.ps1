# godot_env.ps1 - locate the Godot 4.7 console binary for babamech (ported from flap / cast).
# Order: $env:BABAMECH_GODOT, then babamech's own copy in build\deps (gitignored: Godot_v4.7-stable_win64_console.exe),
# then the sibling projects' copies (flap's build\deps, Hero-Reader's third_party\godot under the antigravity scratch
# folder). No machine-wide fallback.
function Resolve-BabamechGodot {
    if ($env:BABAMECH_GODOT -and (Test-Path $env:BABAMECH_GODOT)) { return $env:BABAMECH_GODOT }
    $scratch = Join-Path $env:USERPROFILE ".gemini\antigravity\scratch"
    $exe = "Godot_v4.7-stable_win64_console.exe"
    foreach ($p in @((Join-Path $PSScriptRoot "build\deps\$exe"),
                     (Join-Path $scratch "flap\build\deps\$exe"),
                     (Join-Path $scratch "cast\build\deps\$exe"),
                     (Join-Path $scratch "Hero-Reader\third_party\godot\$exe"))) {
        if (Test-Path $p) { return (Resolve-Path $p).Path }
    }
    throw "Godot 4.7 not found. Set BABAMECH_GODOT to Godot_v4.7-stable_win64_console.exe."
}

# Import (or reimport) the project so class_name caches and .import files exist; stamp when it ran.
function Invoke-BabamechImport([string]$Godot) {
    & $Godot --path $PSScriptRoot --headless --import 2>&1 | Out-Null
    $stamp = Join-Path $PSScriptRoot ".godot\babamech_imported.stamp"
    if (Test-Path (Split-Path $stamp)) { Set-Content -Path $stamp -Value (Get-Date -Format o) }
}

# Import only when a script, scene, asset or test is newer than the last import (from flap): without it a new
# class_name is unknown ("Could not find type").
function Update-BabamechImport([string]$Godot) {
    $since = $null
    $stamp = Join-Path $PSScriptRoot ".godot\babamech_imported.stamp"
    if (Test-Path $stamp) { $since = (Get-Item $stamp).LastWriteTime }
    $stale = $null -eq $since -or -not (Test-Path (Join-Path $PSScriptRoot ".godot\global_script_class_cache.cfg"))
    if (-not $stale) {
        $dirs = @("scripts", "scenes", "assets", "tools", "tests") | ForEach-Object { Join-Path $PSScriptRoot $_ } | Where-Object { Test-Path $_ }
        $stale = [bool](Get-ChildItem -Recurse -File -Path $dirs -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $since -and $_.Extension -ne ".import" -and $_.Extension -ne ".uid" } | Select-Object -First 1)
    }
    if ($stale) {
        Write-Host "Importing (scripts or assets changed since the last import)..."
        Invoke-BabamechImport $Godot
    }
}
