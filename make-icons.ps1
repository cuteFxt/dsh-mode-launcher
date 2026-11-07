<#
  生成 DSH 两个模式图标（ICO，多尺寸 16/32/48/64/128/256）
  ---------------------------------------------------------------------------
  纯 PowerShell + GDI+ 自绘，不依赖外部图片。

  视觉规则（两个图标共用一套骨架，靠配色与图形区分）：
    · 同一圆角底板（圆角半径 = 22% 边长）、同一安全边距
    · 无文字（文字交给快捷方式名称）
    · 股票侧：深板岩底 + 上涨的四根蜡烛（红为主、金色点睛）
    · 学习侧：深海军蓝底 + 翻开的书 + 暖黄灯泡与光线

  小尺寸（<=32px）自动简化：去掉光线、加粗笔画、放大主形，
  保证任务栏与桌面 16px 下仍可辨认。

  输出：
    launchers\icons\dsh-stock.ico
    launchers\icons\dsh-study.ico
    launchers\icons\preview-*.png   （仅供肉眼检查）
#>

Add-Type -AssemblyName System.Drawing

$OutDir = Join-Path $PSScriptRoot 'icons'
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$Sizes = @(16, 24, 32, 48, 64, 128, 256)

function New-RoundedPath {
    param([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = [single]($R * 2)
    $p.AddArc($X, $Y, $d, $d, 180.0, 90.0)
    $p.AddArc(($X + $W - $d), $Y, $d, $d, 270.0, 90.0)
    $p.AddArc(($X + $W - $d), ($Y + $H - $d), $d, $d, 0.0, 90.0)
    $p.AddArc($X, ($Y + $H - $d), $d, $d, 90.0, 90.0)
    $p.CloseFigure()
    return $p
}

function New-Pt([single]$X, [single]$Y) { New-Object System.Drawing.PointF($X, $Y) }

function New-Color([string]$Hex) { [System.Drawing.ColorTranslator]::FromHtml($Hex) }

# ---------------------------------------------------------------------------
# 股票：涨势蜡烛图
# ---------------------------------------------------------------------------
function Draw-Stock {
    param([System.Drawing.Graphics]$G, [single]$S)

    # 底板
    $plate = New-RoundedPath 0 0 $S $S ($S * 0.22)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Pt 0 0), (New-Pt $S $S),
        (New-Color '#333B52'), (New-Color '#0E1119'))
    $G.FillPath($brush, $plate)
    $brush.Dispose()

    # 顶部一道极淡高光，避免大尺寸下发闷
    # 注意：必须 Clamp，否则渐变越过终点后重新平铺，会在 45% 处留一条硬接缝
    if ($S -ge 48) {
        $glow = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            (New-Pt 0 0), (New-Pt 0 $S),
            ([System.Drawing.Color]::FromArgb(40, 255, 255, 255)),
            ([System.Drawing.Color]::FromArgb(0, 255, 255, 255)))
        $g2 = New-RoundedPath 0 0 $S $S ($S * 0.22)
        $G.FillPath($glow, $g2)
        $glow.Dispose(); $g2.Dispose()
    }

    $red = New-Color '#E5484D'
    $gold = New-Color '#F5C542'
    $shadow = New-Color '#000000'

    # 蜡烛：高度递增，最后一根最高 → 读作「涨」
    $heights = @(0.24, 0.36, 0.30, 0.50)
    $wicks = @(0.045, 0.05, 0.04, 0.055)
    $centers = @(0.255, 0.415, 0.575, 0.735)
    $bodyW = if ($S -le 32) { 0.115 } else { 0.092 }
    $baseY = if ($S -le 32) { 0.760 } else { 0.745 }

    for ($i = 0; $i -lt 4; $i++) {
        $cx = $centers[$i]
        $h = $heights[$i]
        $c = if ($i -eq 3) { $gold } else { $red }

        $bw = $bodyW * $S
        $bx = ($cx * $S) - ($bw / 2)
        $by = ($baseY - $h) * $S
        $bh = $h * $S

        # 影线
        $penW = [Math]::Max(1.2, $S * 0.022)
        $pen = New-Object System.Drawing.Pen($c, [single]$penW)
        $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
        $G.DrawLine($pen, [single]($cx * $S), [single](($baseY - $h - $wicks[$i]) * $S),
                          [single]($cx * $S), [single](($baseY + $wicks[$i] * 0.7) * $S))
        $pen.Dispose()

        # 实体
        $body = New-RoundedPath $bx $by $bw $bh ([Math]::Max(1.0, $bw * 0.28))
        $bb = New-Object System.Drawing.SolidBrush($c)
        $G.FillPath($bb, $body)
        $bb.Dispose(); $body.Dispose()
    }

    # 底部金色基座线，把四根蜡烛收在一起
    if ($S -ge 32) {
        $penW = [Math]::Max(1.2, $S * 0.020)
        $pen = New-Object System.Drawing.Pen((New-Color '#F5C542'), [single]$penW)
        $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
        $G.DrawLine($pen, [single](0.185 * $S), [single](0.845 * $S),
                          [single](0.815 * $S), [single](0.845 * $S))
        $pen.Dispose()
    }
}

# ---------------------------------------------------------------------------
# 学习：书本 + 灯泡
# ---------------------------------------------------------------------------
function Draw-Study {
    param([System.Drawing.Graphics]$G, [single]$S)

    # 底板
    $plate = New-RoundedPath 0 0 $S $S ($S * 0.22)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Pt 0 0), (New-Pt $S $S),
        (New-Color '#1B3A57'), (New-Color '#0A1523'))
    $G.FillPath($brush, $plate)
    $brush.Dispose()

    if ($S -ge 48) {
        $glow = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            (New-Pt 0 0), (New-Pt 0 $S),
            ([System.Drawing.Color]::FromArgb(40, 255, 255, 255)),
            ([System.Drawing.Color]::FromArgb(0, 255, 255, 255)))
        $g2 = New-RoundedPath 0 0 $S $S ($S * 0.22)
        $G.FillPath($glow, $g2)
        $glow.Dispose(); $g2.Dispose()
    }

    $small = $S -le 32
    $lampY = if ($small) { 0.300 } else { 0.255 }
    $lampR = if ($small) { 0.105 } else { 0.088 }
    $bookTop = if ($small) { 0.400 } else { 0.395 }
    $bookBot = if ($small) { 0.800 } else { 0.785 }
    $spineX = 0.500

    # 书（左右两页，右侧稍暗表示翻页）
    $lp = [System.Drawing.PointF[]]@(
        (New-Pt ($spineX * $S) ($bookTop * $S)),
        (New-Pt (0.185 * $S)     (($bookTop + 0.055) * $S)),
        (New-Pt (0.185 * $S)     ($bookBot * $S)),
        (New-Pt ($spineX * $S)   (($bookBot - 0.055) * $S))
    )
    $rp = [System.Drawing.PointF[]]@(
        (New-Pt ($spineX * $S) ($bookTop * $S)),
        (New-Pt (0.815 * $S)     (($bookTop + 0.055) * $S)),
        (New-Pt (0.815 * $S)     ($bookBot * $S)),
        (New-Pt ($spineX * $S)   (($bookBot - 0.055) * $S))
    )

    $bLeft = New-Object System.Drawing.SolidBrush((New-Color '#EAF2F9'))
    $bRight = New-Object System.Drawing.SolidBrush((New-Color '#C3D8E9'))
    $G.FillPolygon($bLeft, $lp)
    $G.FillPolygon($bRight, $rp)
    $bLeft.Dispose(); $bRight.Dispose()

    # 书脊
    $penW = [Math]::Max(1.4, $S * 0.026)
    $pen = New-Object System.Drawing.Pen((New-Color '#2E9BD6'), [single]$penW)
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $G.DrawLine($pen, [single]($spineX * $S), [single]($bookTop * $S),
                      [single]($spineX * $S), [single](($bookBot - 0.055) * $S))
    $pen.Dispose()

    # 书页横线（仅中等以上尺寸，纯装饰）
    if ($S -ge 64) {
        $hp = New-Object System.Drawing.Pen(([System.Drawing.Color]::FromArgb(90, 46, 155, 214)), [single][Math]::Max(1.0, $S * 0.011))
        foreach ($k in 0.14, 0.22) {
            $G.DrawLine($hp, [single](0.265 * $S), [single](($bookTop + 0.055 + $k * ($bookBot - $bookTop)) * $S),
                             [single](0.455 * $S), [single](($bookTop + 0.030 + $k * ($bookBot - $bookTop)) * $S))
            $G.DrawLine($hp, [single](0.545 * $S), [single](($bookTop + 0.030 + $k * ($bookBot - $bookTop)) * $S),
                             [single](0.735 * $S), [single](($bookTop + 0.055 + $k * ($bookBot - $bookTop)) * $S))
        }
        $hp.Dispose()
    }

    # 灯泡
    $lamp = New-Color '#FFD166'
    $lr = $lampR * $S
    $lcx = 0.500 * $S
    $lcy = $lampY * $S
    $lb = New-Object System.Drawing.SolidBrush($lamp)
    $G.FillEllipse($lb, [single]($lcx - $lr), [single]($lcy - $lr), [single]($lr * 2), [single]($lr * 2))

    # 灯颈
    $neckW = $lr * 0.62
    $neckH = $lr * 0.55
    $neck = New-RoundedPath ($lcx - $neckW / 2) ($lcy + $lr * 0.62) $neckW $neckH ([Math]::Max(1.0, $neckW * 0.35))
    $G.FillPath($lb, $neck)
    $neck.Dispose(); $lb.Dispose()

    # 光线
    if (-not $small) {
        $penW = [Math]::Max(1.3, $S * 0.020)
        $pen = New-Object System.Drawing.Pen((New-Color '#8FD3F4'), [single]$penW)
        $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
        $rays = @(
            @(@(0.380, 0.130), @(0.320, 0.088)),
            @(@(0.620, 0.130), @(0.680, 0.088)),
            @(@(0.500, 0.080), @(0.500, 0.038))
        )
        foreach ($r in $rays) {
            $G.DrawLine($pen, [single]($r[0][0] * $S), [single]($r[0][1] * $S),
                              [single]($r[1][0] * $S), [single]($r[1][1] * $S))
        }
        $pen.Dispose()
    }
}

# ---------------------------------------------------------------------------
# 渲染一个尺寸 → PNG 字节（4 倍超采样后缩小，小尺寸也不糊）
# ---------------------------------------------------------------------------
function Render-Png {
    param([int]$Size, [scriptblock]$Painter)

    $ss = 4
    $big = $Size * $ss
    $canvas = New-Object System.Drawing.Bitmap($big, $big, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($canvas)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.Clear([System.Drawing.Color]::Transparent)
    & $Painter $g ([single]$big)
    $g.Dispose()

    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g2 = [System.Drawing.Graphics]::FromImage($bmp)
    $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g2.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g2.Clear([System.Drawing.Color]::Transparent)
    $g2.DrawImage($canvas, (New-Object System.Drawing.Rectangle(0, 0, $Size, $Size)))
    $g2.Dispose()
    $canvas.Dispose()

    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $bytes = $ms.ToArray()
    $ms.Dispose()
    return , $bytes
}

# ---------------------------------------------------------------------------
# 打包 ICO（PNG 压缩条目，Vista+ 支持）
# ---------------------------------------------------------------------------
function Write-Ico {
    param([string]$Path, [int[]]$Dims, [scriptblock]$Painter)

    $entries = @()
    foreach ($d in $Dims) {
        $entries += , @($d, (Render-Png -Size $d -Painter $Painter))
    }

    $fs = [System.IO.File]::Create($Path)
    $bw = New-Object System.IO.BinaryWriter($fs)
    $bw.Write([uint16]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]$entries.Count)

    $offset = 6 + 16 * $entries.Count
    foreach ($e in $entries) {
        $d = [int]$e[0]
        $data = $e[1]
        $dim = if ($d -ge 256) { 0 } else { $d }
        $bw.Write([byte]$dim)
        $bw.Write([byte]$dim)
        $bw.Write([byte]0)
        $bw.Write([byte]0)
        $bw.Write([uint16]1)
        $bw.Write([uint16]32)
        $bw.Write([uint32]$data.Length)
        $bw.Write([uint32]$offset)
        $offset += $data.Length
    }
    foreach ($e in $entries) { $bw.Write([byte[]]$e[1]) }

    $bw.Flush(); $bw.Close(); $fs.Close()
}

Write-Ico -Path (Join-Path $OutDir 'dsh-stock.ico') -Dims $Sizes -Painter { param($g, $s) Draw-Stock -G $g -S $s }
Write-Ico -Path (Join-Path $OutDir 'dsh-study.ico') -Dims $Sizes -Painter { param($g, $s) Draw-Study -G $g -S $s }

# 预览图（256 与 32）
foreach ($p in @(@('stock', 256), @('stock', 32), @('study', 256), @('study', 32))) {
    $name = $p[0]; $sz = $p[1]
    $bytes = if ($name -eq 'stock') { Render-Png -Size $sz -Painter { param($g, $s) Draw-Stock -G $g -S $s } }
             else { Render-Png -Size $sz -Painter { param($g, $s) Draw-Study -G $g -S $s } }
    [System.IO.File]::WriteAllBytes((Join-Path $OutDir "preview-$name-$sz.png"), $bytes)
}

Get-ChildItem -LiteralPath $OutDir -File | Select-Object Name, Length | Format-Table -AutoSize
