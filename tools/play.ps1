# Launches the project without opening the editor.
#
# ASCII-only on purpose: Windows PowerShell 5.1 reads .ps1 files using the
# system ANSI code page unless they carry a UTF-8 BOM.
#
# Usage:
#   .\tools\play.ps1
#   .\tools\play.ps1 -Godot 'C:\path\to\godot.exe'

param(
    [string]$Godot = 'D:\Godot Progame\Godot_v4.7-stable_win64.exe\Godot_v4.7-stable_win64.exe',
    [string]$Project = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

if (-not (Test-Path -LiteralPath $Godot)) {
    Write-Host "Godot not found: $Godot" -ForegroundColor Red
    exit 2
}

if (-not (Test-Path -LiteralPath (Join-Path $Project 'project.godot'))) {
    Write-Host "Not a Godot project: $Project" -ForegroundColor Red
    exit 2
}

Write-Host "Launching $Project" -ForegroundColor Green
& $Godot --path $Project
exit $LASTEXITCODE
