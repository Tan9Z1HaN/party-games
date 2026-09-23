# Launches the project without opening the editor.
#
# ASCII-only on purpose: Windows PowerShell 5.1 reads .ps1 files using the
# system ANSI code page unless they carry a UTF-8 BOM.
#
# Usage:
#   .\tools\play.ps1
#   .\tools\play.ps1 -Godot 'C:\path\to\godot.exe'

param(
    # Leave empty to auto-pick the newest Godot editor build under -GodotRoot.
    [string]$Godot = '',
    [string]$GodotRoot = 'D:\Godot Progame',
    [string]$Project = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

. (Join-Path $PSScriptRoot 'find_godot.ps1')

if ([string]::IsNullOrWhiteSpace($Godot)) {
    $Godot = Find-Godot -Kind Editor -Root $GodotRoot
}

if ([string]::IsNullOrWhiteSpace($Godot) -or -not (Test-Path -LiteralPath $Godot)) {
    Write-Host 'Godot editor build not found.' -ForegroundColor Red
    Write-Host "Looked under: $GodotRoot" -ForegroundColor Red
    Write-Host 'Pass -Godot <path> to point at it explicitly.' -ForegroundColor Red
    exit 2
}

if (-not (Test-Path -LiteralPath (Join-Path $Project 'project.godot'))) {
    Write-Host "Not a Godot project: $Project" -ForegroundColor Red
    exit 2
}

Write-Host "Launching $Project" -ForegroundColor Green
& $Godot --path $Project
exit $LASTEXITCODE
