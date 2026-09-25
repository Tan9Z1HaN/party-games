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
    # Ink is scaled to this fraction of the canvas. Launchers mask app icons
    # (adaptive icons only guarantee the middle ~66% is visible), so this has
    # to leave real room - at 0.72 the four characters were getting clipped.
    [double]$InkRatio = 0.6,
    # YouYuan is the rounded face shipped with Windows; the round-join stroke
    # below thickens it back up so it still reads at 48 px.
    [string]$FontFamily = 'YouYuan',
    [switch]$Bold,
    # Extra stroke width in em units, drawn on top of the filled outline.
    # This is how a font without a bold weight (YouYuan, a rounded face) gets
    # thick enough to read at icon size - and with round joins it also makes
    # the strokes look softer.
    [double]$Weight = 7.0,
    # Fraction of an adaptive layer the content may occupy. Android only
    # guarantees the middle disc (2/3 of the layer) survives the launcher's
    # mask, and our four characters fill their square's corners, so the square
    # has to be inscribed in that disc: 0.667 / sqrt(2) = 0.47. export_config.gd
    # measures every opaque pixel and fails if anything pokes outside.
    [double]$LayerRatio = 0.46
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# The app name, written as code points so this file stays ASCII.
#   805A = ju  5728 = zai  4E00 = yi  8D77 = qi
$glyphs = @([char]0x805A, [char]0x5728, [char]0x4E00, [char]0x8D77)

$family = New-Object System.Drawing.FontFamily($FontFamily)
$style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
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

# The extra weight is a stroke on top of the filled outline. Round joins make
# the stroke ends and corners soft instead of square - which is the whole point
# of picking a rounded face like YouYuan in the first place.
$stroke = ''
if ($Weight -gt 0.0) {
    $stroke = ' stroke="#111111" stroke-width="' + $Weight.ToString('0.##', $fs) +
        '" stroke-linejoin="round" stroke-linecap="round"'
}

$svg = @"
<svg xmlns="http://www.w3.org/2000/svg" width="$Size" height="$Size" viewBox="0 0 $Size $Size">
  <rect width="$Size" height="$Size" rx="$radius" fill="#FFFFFF"/>
  <rect x="0.5" y="0.5" width="$($Size - 1)" height="$($Size - 1)" rx="$radius" fill="none" stroke="#D8D8DE" stroke-width="1"/>
  <g transform="translate($sTx $sTy) scale($sScale)">
    <path d="$($sb.ToString().Trim())" fill="#111111"$stroke/>
  </g>
</svg>
"@

[System.IO.File]::WriteAllText($Out, $svg, (New-Object System.Text.UTF8Encoding($false)))

# ---- Android adaptive icon layers + splash -------------------------------
#
# An adaptive icon has two layers: a foreground (the content) and a background.
# The system only guarantees the middle disc is visible, and every launcher
# masks it to a different shape (circle, squircle, teardrop...). Shipping a
# single flat icon means the shape mask eats the corners of the characters -
# which is exactly what happened. Explicit layers let us inset the content
# into the safe zone so no mask can clip it.
$dir = Split-Path -Parent $Out
if ([string]::IsNullOrEmpty($dir)) { $dir = (Get-Location).Path }
$layer = 432                      # the size Android requires for these layers
$layerRatio = $LayerRatio         # content size, leaving room for the mask

$fg = [System.Drawing.Bitmap]::new($layer, $layer)
$g2 = [System.Drawing.Graphics]::FromImage($fg)
$g2.Clear([System.Drawing.Color]::Transparent)
$g2.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$targetSize = $layer * $layerRatio
$s2 = [math]::Min($targetSize / $bounds.Width, $targetSize / $bounds.Height)
$tx2 = ($layer / 2.0) - (($bounds.X + $bounds.Width / 2.0) * $s2)
$ty2 = ($layer / 2.0) - (($bounds.Y + $bounds.Height / 2.0) * $s2)
$g2.TranslateTransform($tx2, $ty2)
$g2.ScaleTransform($s2, $s2)
$brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 17, 17, 17))
$pen2 = New-Object System.Drawing.Pen($brush, $Weight)
$pen2.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
$pen2.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$pen2.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$g2.FillPath($brush, $merged)
$g2.DrawPath($pen2, $merged)
$fg.Save((Join-Path $dir 'android_icon_foreground.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$pen2.Dispose(); $brush.Dispose(); $g2.Dispose(); $fg.Dispose()

# The background layer is plain white; Android does the shaping.
$bg = [System.Drawing.Bitmap]::new($layer, $layer)
$g3 = [System.Drawing.Graphics]::FromImage($bg)
$g3.Clear([System.Drawing.Color]::White)
$bg.Save((Join-Path $dir 'android_icon_background.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$g3.Dispose(); $bg.Dispose()

# The icon on the launch screen. Android 12+ forces a launch screen and it
# cannot be removed, but a fully transparent icon reduces it to a plain
# background colour - which reads as "the app just opened".
$blank = [System.Drawing.Bitmap]::new(512, 512)
$g4 = [System.Drawing.Graphics]::FromImage($blank)
$g4.Clear([System.Drawing.Color]::Transparent)
$blank.Save((Join-Path $dir 'android_splash_blank.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$g4.Dispose(); $blank.Dispose()

$merged.Dispose()
$family.Dispose()

Write-Host "Wrote $Out  ($($svg.Length) chars, scale $sScale) + android layers"
