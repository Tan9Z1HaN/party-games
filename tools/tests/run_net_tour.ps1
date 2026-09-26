# Plays a whole Tour of China game across real processes on loopback.
#
# ASCII-ONLY. Windows PowerShell 5.1 reads .ps1 files using the system ANSI
# code page unless they carry a UTF-8 BOM; non-ASCII bytes then get misread and
# an odd trailing byte can swallow the next newline. Keep build scripts ASCII.
#
# Usage:
#   .\tools\tests\run_net_tour.ps1
#   .\tools\tests\run_net_tour.ps1 -Clients 3

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

$script = 'res://tools/tests/net_tour.gd'
$logDir = Join-Path ([System.IO.Path]::GetTempPath()) 'party-games-net-tour'
if (Test-Path -LiteralPath $logDir) { Remove-Item -LiteralPath $logDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

# Deliberately NOT using Start-Process: it rebuilds the environment block and
# dies with a duplicate-key error (Path vs PATH) in some shells.
function Start-Tour {
    # NOTE: never name a parameter $Args / $args - PowerShell's automatic $args
    # collides with it and the bound value silently disappears.
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
Write-Host "Host + $Clients client(s) playing a whole Tour of China game on loopback" -ForegroundColor Cyan

$hostProc = Start-Tour -Tag 'host' -GodotArgs @('--role=host', '--name=host', "--expect=$Clients")
Start-Sleep -Seconds 3

$clientProcs = @()
for ($i = 1; $i -le $Clients; $i++) {
    $clientProcs += Start-Tour -Tag "client$i" -GodotArgs @('--role=client', "--name=p$i", '--ip=127.0.0.1')
    Start-Sleep -Milliseconds 900
}

$all = @($hostProc) + $clientProcs
foreach ($p in $all) {
    if (-not $p.Proc.WaitForExit(80000)) {
        try { $p.Proc.Kill() } catch { }
    }
}
Start-Sleep -Seconds 1

$failed = @()
$winners = @{}
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

    if ($text -notmatch '(HOST|CLIENT)_OK') { $failed += $p.Tag }

    $m = [regex]::Match($text, '(HOST|CLIENT)_WINNER=(\d+)')
    if ($m.Success) { $winners[$p.Tag] = [int]$m.Groups[2].Value }
}

# The whole point: every process must agree on who won.
$distinct = @($winners.Values | Sort-Object -Unique)
Write-Host ''
if ($winners.Count -ne $all.Count) {
    Write-Host "FAILED: only $($winners.Count)/$($all.Count) processes reported a winner" -ForegroundColor Red
    $failed += 'winner-missing'
} elseif ($distinct.Count -ne 1) {
    Write-Host "FAILED: processes disagree on the winner: $($winners.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Join-String -Separator ', ')" -ForegroundColor Red
    $failed += 'winner-mismatch'
} else {
    Write-Host "All $($all.Count) processes agree: winner = peer $($distinct[0])" -ForegroundColor Green
}

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host "FAILED: $($failed -join ', ')" -ForegroundColor Red
    Write-Host "Logs: $logDir" -ForegroundColor DarkGray
    exit 1
}
Write-Host 'Tour net round passed.' -ForegroundColor Green
exit 0
