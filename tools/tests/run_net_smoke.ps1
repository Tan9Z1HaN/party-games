# Spins up one headless host and N headless clients on loopback and checks that
# they actually handshake, exchange room state, start a game and route messages.
#
# ASCII-ONLY. This is not a style preference.
# Windows PowerShell 5.1 reads .ps1 files using the system ANSI code page unless
# they carry a UTF-8 BOM. Non-ASCII bytes then get misread, and because the
# code page is double-byte, an odd trailing byte can swallow the following
# newline and comment out the next line of code. That silently broke this very
# script once. Write Chinese in the .md docs, keep build scripts ASCII.
#
# Usage:
#   .\tools\tests\run_net_smoke.ps1
#   .\tools\tests\run_net_smoke.ps1 -Clients 3

param(
    [string]$Godot = '',
    [string]$GodotRoot = 'D:\Godot Progame',
    [string]$Project = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [int]$Clients = 2
)

. (Join-Path $PSScriptRoot '..\find_godot.ps1')

if ([string]::IsNullOrWhiteSpace($Godot)) {
    $Godot = Find-Godot -Kind Console -Root $GodotRoot
}
if ([string]::IsNullOrWhiteSpace($Godot) -or -not (Test-Path -LiteralPath $Godot)) {
    Write-Host 'Godot console build not found.' -ForegroundColor Red
    exit 2
}

$script = 'res://tools/tests/net_smoke.gd'
$logDir = Join-Path ([System.IO.Path]::GetTempPath()) 'party-games-net-smoke'
if (Test-Path -LiteralPath $logDir) { Remove-Item -LiteralPath $logDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

# Deliberately NOT using Start-Process: it rebuilds the environment block and
# dies with a duplicate-key error (Path vs PATH) in some shells. Building
# ProcessStartInfo directly and never touching EnvironmentVariables keeps the
# environment inherited as-is. Output is not redirected either; Godot writes
# its own log via --log-file.
function Start-Smoke {
    # NOTE: never name a parameter $Args / $args. PowerShell exposes an
    # automatic $args variable, and the name collision silently makes the
    # bound value unreadable - the arguments just vanish.
    param([string]$Tag, [string[]]$GodotArgs)

    $log = Join-Path $logDir "$Tag.log"
    $argv = @('--headless', '--path', $Project, '--script', $script,
        '--log-file', $log, '--') + $GodotArgs
    $quoted = $argv | ForEach-Object {
        if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Godot
    $psi.Arguments = ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $Project

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    return [pscustomobject]@{ Tag = $Tag; Proc = $proc; Log = $log }
}

Write-Host "Godot: $Godot" -ForegroundColor DarkGray
Write-Host "Host + $Clients client(s) on loopback" -ForegroundColor Cyan

$hostProc = Start-Smoke -Tag 'host' -GodotArgs @('--role=host', '--name=host', "--expect=$Clients")
Start-Sleep -Seconds 3

$clientProcs = @()
for ($i = 1; $i -le $Clients; $i++) {
    $clientProcs += Start-Smoke -Tag "client$i" -GodotArgs @('--role=client', "--name=player$i", '--ip=127.0.0.1')
    Start-Sleep -Milliseconds 800
}

$all = @($hostProc) + $clientProcs
foreach ($p in $all) {
    if (-not $p.Proc.WaitForExit(40000)) {
        try { $p.Proc.Kill() } catch { }
    }
}
Start-Sleep -Seconds 1

$failed = @()
foreach ($p in $all) {
    Write-Host ''
    Write-Host "===== $($p.Tag) =====" -ForegroundColor Cyan

    $text = ''
    if (Test-Path -LiteralPath $p.Log) {
        $text = [System.IO.File]::ReadAllText($p.Log, [System.Text.Encoding]::UTF8)
    }
    if ($text) {
        foreach ($line in ($text.Trim() -split "`r?`n")) {
            if ($line -match '^(HOST|CLIENT|JOINED|FAILED)') { Write-Host "  $line" }
        }
    }

    if ($text -notmatch 'OK') { $failed += $p.Tag }
    if ($p.Proc.HasExited -and $p.Proc.ExitCode -ne 0) {
        $failed += "$($p.Tag)(exit $($p.Proc.ExitCode))"
    }
}

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host "FAILED: $($failed -join ', ')" -ForegroundColor Red
    Write-Host "Logs: $logDir" -ForegroundColor DarkGray
    exit 1
}
Write-Host 'All net smoke checks passed.' -ForegroundColor Green
exit 0
