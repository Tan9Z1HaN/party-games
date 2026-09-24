# Plays a FULL networked game of draw-guess across one host and N client
# processes, then compares what each process recorded.
#
# Why cross-process comparison instead of per-process asserts:
# almost every bug reported so far was a "the two sides disagree" bug - a
# non-drawer could edit the canvas, a guess got attributed to the drawer, the
# client's round summary was always empty, the word picker was visible to
# everyone. All of those look correct inside a single process. They only show
# up when both sides' records are put next to each other.
#
# ASCII-ONLY, and it is enforced by tools/tests/export_config.gd.
# Windows PowerShell 5.1 reads .ps1 files using the system ANSI code page
# unless they carry a UTF-8 BOM. Non-ASCII bytes then get misread, and because
# that code page is double-byte, an odd trailing byte can swallow the next
# newline and comment out a line of code. This file was written with Chinese
# strings once and failed to parse. Keep build scripts ASCII.
#
# Usage:
#   .\tools\tests\run_net_round.ps1
#   .\tools\tests\run_net_round.ps1 -Clients 3

param(
    [string]$Godot = '',
    [string]$GodotRoot = 'D:\Godot Progame',
    [string]$Project = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [int]$Clients = 2,
    [int]$TimeoutSeconds = 150
)

. (Join-Path $PSScriptRoot '..\find_godot.ps1')

if ([string]::IsNullOrWhiteSpace($Godot)) {
    $Godot = Find-Godot -Kind Console -Root $GodotRoot
}
if ([string]::IsNullOrWhiteSpace($Godot) -or -not (Test-Path -LiteralPath $Godot)) {
    Write-Host 'Godot console build not found.' -ForegroundColor Red
    exit 2
}

$script = 'res://tools/tests/net_round.gd'
$logDir = Join-Path ([System.IO.Path]::GetTempPath()) 'party-games-net-round'
if (Test-Path -LiteralPath $logDir) { Remove-Item -LiteralPath $logDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Start-Proc {
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

function Get-LogLines {
    param([string]$Log, [string]$Pattern)
    if (-not (Test-Path -LiteralPath $Log)) { return @() }
    $text = [System.IO.File]::ReadAllText($Log, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    $out = $text -split "`r?`n" | Where-Object { $_ -match $Pattern } | ForEach-Object { $_.Trim() }
    return @($out | Where-Object { $_ -ne '' })
}

Write-Host "Godot: $Godot" -ForegroundColor DarkGray
Write-Host "Host + $Clients client(s), playing one full game" -ForegroundColor Cyan

$hostProc = Start-Proc -Tag 'host' -GodotArgs @('--role=host', '--name=host', "--expect=$Clients")
Start-Sleep -Seconds 3

$clientProcs = @()
for ($i = 1; $i -le $Clients; $i++) {
    $clientProcs += Start-Proc -Tag "client$i" -GodotArgs @('--role=client', "--name=player$i", '--ip=127.0.0.1')
    Start-Sleep -Milliseconds 900
}

$all = @($hostProc) + $clientProcs
foreach ($p in $all) {
    if (-not $p.Proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Proc.Kill() } catch { }
    }
}
Start-Sleep -Seconds 1

$tags = @()
foreach ($p in $all) { $tags += $p.Tag }

$records = @{}
foreach ($p in $all) {
    $records[$p.Tag] = @{
        Rounds = Get-LogLines $p.Log '^ROUND '
        Leaks  = Get-LogLines $p.Log '^LEAKCHECK '
        Cand   = Get-LogLines $p.Log '^CANDIDATES '
        Finish = Get-LogLines $p.Log '^FINISHED '
        Failed = Get-LogLines $p.Log '^FAILED'
    }
}

$problems = @()
$expectedRounds = 3

foreach ($tag in $tags) {
    $r = $records[$tag]
    if ($r.Failed.Count -gt 0) { $problems += "${tag}: $($r.Failed[0])" }
    if ($r.Finish.Count -eq 0) { $problems += "${tag} did not finish the game (no FINISHED line)" }
    if ($r.Rounds.Count -ne $expectedRounds) {
        $problems += "${tag} recorded $($r.Rounds.Count) round summaries, expected $expectedRounds"
    }
}

$hostRounds = $records['host'].Rounds
foreach ($p in $clientProcs) {
    $diff = Compare-Object $hostRounds $records[$p.Tag].Rounds
    if ($diff) {
        $problems += "$($p.Tag) round records differ from the host"
        foreach ($d in $diff) {
            Write-Host ("      {0} {1}" -f $d.SideIndicator, $d.InputObject) -ForegroundColor DarkYellow
        }
    }
}

foreach ($tag in $tags) {
    foreach ($line in $records[$tag].Leaks) {
        if ($line -match 'is_drawer=(\w+) seen_len=(\d+)') {
            $isDrawer = ($Matches[1] -eq 'true')
            $len = [int]$Matches[2]
            if ((-not $isDrawer) -and ($len -ne 0)) {
                $problems += "LEAK: ${tag} is not the drawer but received the answer (len $len)"
            }
            if ($isDrawer -and ($len -eq 0)) {
                $problems += "${tag} is the drawer but received no answer"
            }
        }
    }
}

foreach ($p in $clientProcs) {
    foreach ($line in $records[$p.Tag].Cand) {
        if ($line -match 'is_drawer=false') {
            $problems += "LEAK: $($p.Tag) received word candidates it should not have"
        }
    }
}

if ($hostRounds.Count -gt 0) {
    $drawers = @()
    foreach ($line in $hostRounds) {
        if ($line -match 'drawer=(\d+)') { $drawers += $Matches[1] }
    }
    $distinct = @($drawers | Sort-Object -Unique).Count
    if ($distinct -ne $drawers.Count) {
        $problems += "drawer did not rotate: $($drawers -join ' -> ')"
    }
    Write-Host ''
    Write-Host "Drawer order: $($drawers -join ' -> ')" -ForegroundColor DarkGray
}

foreach ($tag in $tags) {
    Write-Host ''
    Write-Host "===== $tag =====" -ForegroundColor Cyan
    foreach ($line in $records[$tag].Rounds) { Write-Host "  $line" }
    foreach ($line in $records[$tag].Leaks)  { Write-Host "  $line" -ForegroundColor DarkGray }
    if ($records[$tag].Failed.Count -gt 0) {
        Write-Host "  $($records[$tag].Failed[0])" -ForegroundColor Red
    }
}

Write-Host ''
if ($problems.Count -gt 0) {
    Write-Host "FAILED ($($problems.Count)):" -ForegroundColor Red
    foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Red }
    Write-Host "Logs: $logDir" -ForegroundColor DarkGray
    exit 1
}
Write-Host 'Full networked round passed: both sides agree.' -ForegroundColor Green
exit 0
