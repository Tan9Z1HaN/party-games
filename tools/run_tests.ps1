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
    [string]$Godot = 'D:\Godot Progame\Godot_v4.7-stable_win64.exe\Godot_v4.7-stable_win64_console.exe',
    [string]$Project = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$suites = @(
    'res://drawing/tests/run_tests.gd',
    'res://games/draw_guess/tests/run_tests.gd',
    'res://games/draw_guess/tests/smoke_scene.gd'
)

if (-not (Test-Path -LiteralPath $Godot)) {
    Write-Host "Godot not found: $Godot" -ForegroundColor Red
    exit 2
}

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
