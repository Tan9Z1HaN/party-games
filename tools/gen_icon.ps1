# Regenerates icon.svg: the four characters of the app name laid out in a 2x2
# square, black on white.
#
# Why a generator instead of a hand-written SVG: the glyphs have to be
# outlines. Godot rasterises SVG with ThorVG, which does NOT support <text>,
# so a <text> element would silently render as nothing. Text is turned into
# paths here with GDI+ (System.Drawing.Drawing2D.GraphicsPath.AddString),
# which needs a font only at generation time - the committed SVG carries the
# outlines, so the game does not depend on any font being installed.
#
# ASCII-ONLY. tools/tests/export_config.gd enforces this for every *.ps1: with
# no BOM, Windows PowerShell 5.1 reads scripts using the system ANSI code page,
# and a trailing double-byte character can swallow the next newline.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\tools\gen_icon.ps1

param(
    [string]$Out = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'icon.svg'),
    [int]$Size = 128,
    [double]$InkRatio = 0.72,
    [string]$FontFamily = 'SimHei'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# The app name, written as code points so this file stays ASCII.
#   805A = ju  5728 = zai  4E00 = yi  8D77 = qi
$glyphs = @([char]0x805A, [char]0x5728, [char]0x4E00, [char]0x8D77)

$family = New-Object System.Drawing.FontFamily($FontFamily)
$style = [System.Drawing.FontStyle]::Regular
$format = [System.Drawing.StringFormat]::GenericTypographic

# Lay the four glyphs out on a 2x2 grid where one cell is exactly one em wide,
# so the whole block is 2em by 2em. The final transform below scales that
# block to the requested ink ratio of the canvas.
$cell = 100.0
$merged = New-Object System.Drawing.Drawing2D.GraphicsPath
for ($i = 0; $i -lt 4; $i++) {
    $col = $i % 2
    $row = [math]::Floor($i / 2)
    $origin = New-Object System.Drawing.PointF(($col * $cell), ($row * $cell))
    $one = New-Object System.Drawing.Drawing2D.GraphicsPath
    $one.AddString([string]$glyphs[$i], $family, $style, $cell, $origin, $format)
    $merged.AddPath($one, $false)
    $one.Dispose()
}

# GDI+ path data: each point carries a type byte. Low 3 bits describe the
# segment reaching that point (0 = start of a new figure, 1 = line, 3 = cubic
# bezier); bit 0x80 on the last point of a figure means "close it".
#
# The exact placement of bezier control points against those type bytes is
# under-documented and easy to get wrong (the first attempt produced control
# points flying outside the glyph). So the path is flattened into line
# segments first: after that only "move" and "line" remain, which is
# unambiguous. At a 128 px icon the difference is invisible, and the outline
# is still vector, so larger sizes stay sharp.
$flatness = 0.1   # in the same units as the glyph em box (100 here)

# bounds are taken while the path is still curved, so the fit is exact
$bounds = $merged.GetBounds()
$merged.Flatten((New-Object System.Drawing.Drawing2D.Matrix), $flatness)
$data = $merged.PathData
$points = $data.Points
$types = $data.Types
$inv = [System.Globalization.CultureInfo]::InvariantCulture
$sb = New-Object System.Text.StringBuilder

for ($i = 0; $i -lt $points.Length; $i++) {
    $kind = $types[$i] -band 7
    $x = $points[$i].X.ToString('0.##', $inv)
    $y = $points[$i].Y.ToString('0.##', $inv)

    if ($kind -eq 0) {
        [void]$sb.Append("M $x $y ")
    } elseif ($kind -eq 1) {
        [void]$sb.Append("L $x $y ")
    } else {
        continue
    }

    if (($types[$i] -band 0x80) -ne 0) {
        [void]$sb.Append('Z ')
    }
}

# Fit the ink bounding box into the canvas with a margin, keeping the aspect
# ratio so the four characters stay square.
$target = $Size * $InkRatio
$scale = [math]::Min($target / $bounds.Width, $target / $bounds.Height)
$tx = ($Size / 2.0) - (($bounds.X + $bounds.Width / 2.0) * $scale)
$ty = ($Size / 2.0) - (($bounds.Y + $bounds.Height / 2.0) * $scale)

$fs = [System.Globalization.CultureInfo]::InvariantCulture
$sScale = $scale.ToString('0.####', $fs)
$sTx = $tx.ToString('0.##', $fs)
$sTy = $ty.ToString('0.##', $fs)
$radius = [int][math]::Round($Size * 0.22)

$svg = @"
<svg xmlns="http://www.w3.org/2000/svg" width="$Size" height="$Size" viewBox="0 0 $Size $Size">
  <rect width="$Size" height="$Size" rx="$radius" fill="#FFFFFF"/>
  <rect x="0.5" y="0.5" width="$($Size - 1)" height="$($Size - 1)" rx="$radius" fill="none" stroke="#D8D8DE" stroke-width="1"/>
  <g transform="translate($sTx $sTy) scale($sScale)">
    <path d="$($sb.ToString().Trim())" fill="#111111"/>
  </g>
</svg>
"@

[System.IO.File]::WriteAllText($Out, $svg, (New-Object System.Text.UTF8Encoding($false)))
$merged.Dispose()
$family.Dispose()

Write-Host "Wrote $Out  ($($svg.Length) chars, scale $sScale)"
