# Locates a Godot binary under $Root and returns the newest version.
# ASCII-only on purpose; see the note in run_tests.ps1.
#
# Dot-source this file, then call:
#   Find-Godot -Kind Console   # ..._console.exe, for --headless work
#   Find-Godot -Kind Editor    # plain .exe, for playing
#
# Why this exists: hardcoding the engine path breaks the moment you upgrade
# Godot. The old install got replaced by 4.7.2 during development and every
# script pointing at 4.7-stable died with it.

function Find-Godot {
    param(
        [ValidateSet('Editor', 'Console')]
        [string]$Kind = 'Console',
        [string]$Root = 'D:\Godot Progame'
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        return $null
    }

    # Console builds end in _console.exe, so the two patterns never overlap.
    if ($Kind -eq 'Console') {
        $pattern = '^Godot_v(\d+(?:\.\d+)*)-stable_win64_console\.exe$'
    } else {
        $pattern = '^Godot_v(\d+(?:\.\d+)*)-stable_win64\.exe$'
    }

    $best = $null
    $bestVersion = $null
    $candidates = Get-ChildItem -LiteralPath $Root -Recurse -Depth 3 -File `
        -Filter 'Godot_v*.exe' -ErrorAction SilentlyContinue

    foreach ($file in $candidates) {
        $m = [regex]::Match($file.Name, $pattern)
        if (-not $m.Success) { continue }
        $version = [version]$m.Groups[1].Value
        if (($null -eq $bestVersion) -or ($version -gt $bestVersion)) {
            $bestVersion = $version
            $best = $file.FullName
        }
    }

    return $best
}
