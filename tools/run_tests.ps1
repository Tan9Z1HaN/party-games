# Runs every headless test suite in this project.
#
# NOTE: this file is deliberately ASCII-only. Windows PowerShell 5.1 reads
# .ps1 files using the system ANSI code page unless they carry a UTF-8 BOM,
# which turns any non-ASCII text into mojibake and can even break parsing.
# Keep build scripts ASCII; write Chinese in the .md docs instead.
#
# Usage:
#   .\tools\run_tests.ps1
#   .\tools\run_tests.ps1 -Godot 'C:\path\to\godot_console.exe'

param(
    # Leave empty to auto-pick the newest Godot console build under -GodotRoot.
    [string]$Godot = '',
    [string]$GodotRoot = 'D:\Godot Progame',
    [string]$Project = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

. (Join-Path $PSScriptRoot 'find_godot.ps1')

if ([string]::IsNullOrWhiteSpace($Godot)) {
    $Godot = Find-Godot -Kind Console -Root $GodotRoot
}

$suites = @(
    'res://tools/tests/export_config.gd',
    'res://tools/tests/catalog.gd',
    'res://tools/tests/app_shell.gd',
    'res://drawing/tests/run_tests.gd',
    'res://games/tour/tests/run_tests.gd',
    'res://games/draw_guess/tests/run_tests.gd',
    'res://games/uno/tests/run_tests.gd',
    'res://games/uno/tests/game_layer.gd',
    'res://games/uno/tests/smoke_scene.gd',
    'res://games/draw_guess/tests/smoke_scene.gd'
)

if ([string]::IsNullOrWhiteSpace($Godot) -or -not (Test-Path -LiteralPath $Godot)) {
    Write-Host 'Godot console build not found.' -ForegroundColor Red
    Write-Host "Looked under: $GodotRoot" -ForegroundColor Red
    Write-Host 'Pass -Godot <path> to point at it explicitly.' -ForegroundColor Red
    exit 2
}

Write-Host "Godot: $Godot" -ForegroundColor DarkGray

$failed = @()

foreach ($script in $suites) {
    Write-Host ''
    Write-Host "===== $script =====" -ForegroundColor Cyan
    & $Godot --headless --path $Project --script $script
    if ($LASTEXITCODE -ne 0) {
        $failed += $script
    }
}

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host "FAILED: $($failed.Count) suite(s)" -ForegroundColor Red
    foreach ($f in $failed) {
        Write-Host "  - $f" -ForegroundColor Red
    }
    exit 1
}

Write-Host 'All suites passed.' -ForegroundColor Green
exit 0
