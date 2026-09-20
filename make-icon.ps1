#requires -version 7
<#
.SYNOPSIS
  生成 pwsh-launcher 的图标 icon.ico（多尺寸），画法全在代码里，改颜色/形状直接改这里再跑一次。

.DESCRIPTION
  设计：圆角方块 + 蓝色纵向渐变 + 白色终端提示符（>_）。
  为什么要多尺寸：16/24/32 是任务栏和标题栏用的，直接拿 256 缩下去会糊成一团；
  这里每个尺寸各画一遍，小尺寸还做了简化（<24 只留箭头，不然下划线挤成一坨）。
  容器格式：16~64 用传统 BMP(DIB) 条目，128/256 用 PNG 条目 —— 这是 Windows 自己产图标的做法。

.EXAMPLE
  pwsh -NoProfile -File .\make-icon.ps1
#>
[CmdletBinding()]
param(
  [string]$OutPath = (Join-Path $PSScriptRoot 'icon.ico')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function New-IconBitmap {
  param([int]$Size)

  $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.Clear([System.Drawing.Color]::Transparent)

  # --- 圆角方块 + 渐变底 ---
  $pad = [double]$Size * 0.03
  $side = [double]$Size - 2 * $pad
  $rect = New-Object System.Drawing.RectangleF($pad, $pad, $side, $side)
  $radius = [double]$Size * 0.24
  $d = $radius * 2

  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
  $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
  $path.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
  $path.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
  $path.CloseFigure()

  $top = [System.Drawing.Color]::FromArgb(255, 84, 164, 255)
  $bottom = [System.Drawing.Color]::FromArgb(255, 22, 74, 190)
  $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $top, $bottom, 90.0)
  $g.FillPath($brush, $path)

  # --- 白色提示符 ---
  $penWidth = [Math]::Max(1.4, [double]$Size * 0.105)
  $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, $penWidth)
  $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round

  if ($Size -lt 24) {
    # 小尺寸：只留箭头，居中放大一点
    $left = [double]$Size * 0.32
    $mid = [double]$Size * 0.46
    $topY = [double]$Size * 0.28
    $midY = [double]$Size * 0.50
    $bottomY = [double]$Size * 0.72
    $g.DrawLines($pen, [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF($left, $topY)),
        (New-Object System.Drawing.PointF($mid, $midY)),
        (New-Object System.Drawing.PointF($left, $bottomY))
      ))
    $g.DrawLine($pen, $mid + [double]$Size * 0.10, $bottomY, [double]$Size * 0.74, $bottomY)
  } else {
    # 大尺寸：完整的 >_ 提示符
    $left = [double]$Size * 0.27
    $mid = [double]$Size * 0.47
    $topY = [double]$Size * 0.29
    $midY = [double]$Size * 0.50
    $bottomY = [double]$Size * 0.71
    $g.DrawLines($pen, [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF($left, $topY)),
        (New-Object System.Drawing.PointF($mid, $midY)),
        (New-Object System.Drawing.PointF($left, $bottomY))
      ))
    $g.DrawLine($pen, [double]$Size * 0.58, $bottomY, [double]$Size * 0.76, $bottomY)
  }

  $pen.Dispose(); $brush.Dispose(); $path.Dispose(); $g.Dispose()
  return $bmp
}

function Get-IconDibBytes {
  param([System.Drawing.Bitmap]$Bitmap)

  $size = $Bitmap.Width
  $ms = New-Object System.IO.MemoryStream
  $bw = New-Object System.IO.BinaryWriter($ms)

  # BITMAPINFOHEADER：高度写 2 倍（XOR 图 + AND 掩码）
  $bw.Write([uint32]40)
  $bw.Write([int32]$size)
  $bw.Write([int32]($size * 2))
  $bw.Write([uint16]1)
  $bw.Write([uint16]32)
  $bw.Write([uint32]0)
  $bw.Write([uint32]($size * $size * 4))
  $bw.Write([int32]0); $bw.Write([int32]0)
  $bw.Write([uint32]0); $bw.Write([uint32]0)

  # 像素数据自下而上、BGRA
  $rect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
  $data = $Bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $buffer = New-Object byte[] ($data.Stride * $size)
  [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buffer, 0, $buffer.Length)
  $Bitmap.UnlockBits($data)
  for ($y = $size - 1; $y -ge 0; $y--) {
    $bw.Write($buffer, ($y * $data.Stride), ($size * 4))
  }

  # AND 掩码：32 位图靠 alpha 通道，这里全 0；每行仍要按 4 字节对齐
  $maskStride = [int]([Math]::Floor(($size + 31) / 32) * 4)
  $zeros = New-Object byte[] ($maskStride * $size)
  $bw.Write($zeros, 0, $zeros.Length)

  $bw.Flush()
  $bytes = $ms.ToArray()
  $bw.Dispose(); $ms.Dispose()
  return $bytes
}

function Get-IconPngBytes {
  param([System.Drawing.Bitmap]$Bitmap)
  $ms = New-Object System.IO.MemoryStream
  $Bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $bytes = $ms.ToArray()
  $ms.Dispose()
  return $bytes
}

# ---------------------------------------------------------------- 组装 ICO

$sizesDib = @(16, 20, 24, 32, 40, 48, 64)
$sizesPng = @(128, 256)
$entries = @()

foreach ($s in $sizesDib) {
  $bmp = New-IconBitmap -Size $s
  $entries += [pscustomobject]@{ Size = $s; Bytes = (Get-IconDibBytes -Bitmap $bmp); IsPng = $false }
  $bmp.Dispose()
}
foreach ($s in $sizesPng) {
  $bmp = New-IconBitmap -Size $s
  $entries += [pscustomobject]@{ Size = $s; Bytes = (Get-IconPngBytes -Bitmap $bmp); IsPng = $true }
  $bmp.Dispose()
}

$outDir = Split-Path -Parent $OutPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
  New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

$fs = [System.IO.File]::Create($OutPath)
$w = New-Object System.IO.BinaryWriter($fs)
try {
  $w.Write([uint16]0)                 # reserved
  $w.Write([uint16]1)                 # type = icon
  $w.Write([uint16]$entries.Count)

  $offset = 6 + 16 * $entries.Count
  foreach ($e in $entries) {
    $dim = if ($e.Size -ge 256) { 0 } else { $e.Size }   # 256 在目录里写 0
    $w.Write([byte]$dim)              # width
    $w.Write([byte]$dim)              # height
    $w.Write([byte]0)                 # 调色板数
    $w.Write([byte]0)                 # reserved
    $w.Write([uint16]1)               # color planes
    $w.Write([uint16]32)              # bits per pixel
    $w.Write([uint32]$e.Bytes.Length) # 数据长度
    $w.Write([uint32]$offset)         # 数据偏移
    $offset += $e.Bytes.Length
  }
  foreach ($e in $entries) { $w.Write($e.Bytes, 0, $e.Bytes.Length) }
} finally {
  $w.Dispose(); $fs.Dispose()
}

$sizeKb = [Math]::Round((Get-Item -LiteralPath $OutPath).Length / 1KB, 1)
Write-Host "已生成 $OutPath（$($entries.Count) 个尺寸：$(($entries | ForEach-Object { $_.Size }) -join ', ')，$sizeKb KB）" -ForegroundColor Green
