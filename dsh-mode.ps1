<#
  DSH 模式启动器
  ---------------------------------------------------------------------------
  用法（从快捷方式调用，隐藏窗口）：
    powershell.exe -NoProfile -WindowStyle Hidden -File "dsh-mode.ps1" -Mode stock
    powershell.exe -NoProfile -WindowStyle Hidden -File "dsh-mode.ps1" -Mode study

  stock = 打开全部股票插件
  study = 关闭全部股票插件（其余插件照常）

  主程序位置自动探测（配置 > 环境变量 DSH_EXE > 运行中进程 > 快捷方式），
  也可以用同目录的 dsh-mode.config.psd1 显式指定。

  原理：Desktop 版只能跑 profiles\desktop，且单实例。
  所以两个图标共用一个 Host，靠改写 profile 的 cordis.patch.yml
  （以及 package.json 里的 profile.bundles）来切换插件集，
  dsh-hmr 会在 1 秒内自动 recompose，无需重启；
  最后把主程序拉起 / 唤起即可。

  写入铁律：UTF-8 无 BOM + LF，临时文件 + 改名，绝不写 BOM / CRLF。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('stock', 'study')]
    [string]$Mode,

    # 仅改文件，不拉起主程序（用于测试）
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 可选配置文件（与脚本同目录，名为 dsh-mode.config.psd1）
#   不存在时全部走内置默认值，开箱即用。
# ---------------------------------------------------------------------------
$ConfigPath = Join-Path $PSScriptRoot 'dsh-mode.config.psd1'
$Config = @{}
if (Test-Path -LiteralPath $ConfigPath) {
    try { $Config = Import-PowerShellDataFile -LiteralPath $ConfigPath }
    catch { $Config = @{} }
}

$AppName = if ($Config.AppName) { $Config.AppName } else { 'DeepSeek Harness' }

# ---------------------------------------------------------------------------
# 定位主程序：配置 > 环境变量 DSH_EXE > 运行中的进程 > 桌面/开始菜单快捷方式
# ---------------------------------------------------------------------------
function Resolve-DshExe {
    param([string]$Configured, [string]$Name)

    if ($Configured   -and (Test-Path -LiteralPath $Configured)) { return $Configured }
    if ($env:DSH_EXE  -and (Test-Path -LiteralPath $env:DSH_EXE)) { return $env:DSH_EXE }

    try {
        $proc = Get-Process -Name $Name -ErrorAction SilentlyContinue |
                Where-Object { $_.Path } | Select-Object -First 1
        if ($proc) { return $proc.Path }
    }
    catch { }

    $roots = @(
        [Environment]::GetFolderPath('Desktop')
        [Environment]::GetFolderPath('CommonDesktopDirectory')
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    $shell = $null
    try { $shell = New-Object -ComObject WScript.Shell } catch { }

    foreach ($root in $roots) {
        $links = Get-ChildItem -LiteralPath $root -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue
        foreach ($lnk in $links) {
            if ($shell) {
                try {
                    $target = $shell.CreateShortcut($lnk.FullName).TargetPath
                    if ($target -and (Test-Path -LiteralPath $target) -and
                        ((Split-Path -Leaf $target) -like "*$Name*")) { return $target }
                }
                catch { }
            }
            # 没有 COM 时退化为按文件名猜
            if ($lnk.BaseName -like "*$Name*") {
                $guess = Join-Path (Split-Path -Parent $PSScriptRoot) "$Name.exe"
                if (Test-Path -LiteralPath $guess) { return $guess }
            }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# 路径
# ---------------------------------------------------------------------------
$DshHome = if ($env:DSH_HOME) { $env:DSH_HOME }
           elseif ($Config.DshHome) { $Config.DshHome }
           else { Join-Path $env:USERPROFILE '.dsh' }

$ProfileName = if ($Config.ProfileName) { $Config.ProfileName } else { 'desktop' }
$ProfileDir  = if ($env:DSH_PROFILE_DIR) { $env:DSH_PROFILE_DIR }
               else { Join-Path $DshHome (Join-Path 'profiles' $ProfileName) }

$PatchPath   = Join-Path $ProfileDir 'cordis.patch.yml'
$Manifest    = Join-Path $ProfileDir 'package.json'
$MarketState = Join-Path $ProfileDir '.dsh-market\state.json'
$ExePath     = Resolve-DshExe -Configured $Config.ExePath -Name $AppName
$LogPath     = Join-Path $PSScriptRoot 'dsh-mode.log'
$UseToast    = if ($Config.ContainsKey('Toast')) { [bool]$Config.Toast } else { $true }

# ---------------------------------------------------------------------------
# 股票侧清单
#   $StockRows      —— cordis.patch.yml 里的「行 id」（不是包名！）
#   $StockPackages  —— .dsh-market\state.json 里的包名
#   $StockBundles   —— package.json 里 dsh.profile.bundles 的条目
# ---------------------------------------------------------------------------
$StockRows = @(
    'dsh-plugin-stock-x'
    'dsh-stock-jt'
    'live-data'
    'astock-research'
    'stock-analysis'
    'ths-holdings'
    'ths-holdings-skill'
)
$StockPackages = @(
    'dsh-plugin-stock-x'
    'dsh-stock-jt'
    'dsh-live-data'
    'dsh-astock-research'
    'dsh-stock-analysis'
    'dsh-ths-holdings'
)
# ths-holdings 是 bundle 级插件：光写 disabled 行不够，必须从 bundles 里摘掉，
# 否则它自带的 - insert: 会把 ths-holdings / ths-holdings-skill 两行重新拉起来。
$StockBundles = @('dsh-ths-holdings')

# ---------------------------------------------------------------------------
# 学习侧清单（目前为空 = 学习模式是「纯减法」，只关股票插件）
#
# 以后装了学习专用插件，把它的行 id 填进来：
#   $StudyOnlyRows      —— 学习模式启用、股票模式禁用
#   $StudyOnlyBundles   —— 学习模式加进 bundles、股票模式摘掉
# 空数组时代码什么也不做，不影响现有行为。
# ---------------------------------------------------------------------------
$StudyOnlyRows    = @()
$StudyOnlyBundles = @()

# ---------------------------------------------------------------------------
# 文本读写（UTF-8 无 BOM / LF）
# ---------------------------------------------------------------------------
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-Utf8([string]$Path) {
    [System.IO.File]::ReadAllText($Path, $script:Utf8NoBom)
}

function Write-Utf8Atomic([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = Join-Path $dir ('.' + (Split-Path -Leaf $Path) + '.tmp-' + $PID)
    [System.IO.File]::WriteAllText($tmp, $Text, $script:Utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function New-StringList { New-Object System.Collections.Generic.List[string] }

# ---------------------------------------------------------------------------
# cordis.patch.yml：加 / 摘 一个「恰好两行」的禁用块
#   - id: <RowId>
#     disabled: true
#   带 config: 的块不碰（与 dshmarket/lib/patch.js 的 rowBlocksRe 语义一致）
# ---------------------------------------------------------------------------
function Set-RowDisabled {
    param([string[]]$Lines, [string]$RowId)

    $out = New-StringList
    $done = $false
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if (-not $done -and $i -lt ($Lines.Count - 1) -and
            $line -match '^- id:\s*(\S+)\s*$' -and $Matches[1] -eq $RowId) {
            if ($Lines[$i + 1] -match '^\s+disabled:\s*(true|false)\s*$') {
                $out.Add($line)
                $out.Add('  disabled: true')
                $i++
                $done = $true
                continue
            }
        }
        $out.Add($line)
    }
    if (-not $done) {
        $at = $out.Count
        if ($at -gt 0 -and $out[$at - 1] -eq '') { $at = $at - 1 }
        $out.Insert($at, '  disabled: true')
        $out.Insert($at, "- id: $RowId")
    }
    return , $out.ToArray()
}

function Clear-RowDisabled {
    param([string[]]$Lines, [string]$RowId)

    $out = New-StringList
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($i -lt ($Lines.Count - 1) -and
            $line -match '^- id:\s*(\S+)\s*$' -and $Matches[1] -eq $RowId -and
            $Lines[$i + 1] -match '^\s+disabled:\s*true\s*$') {
            $i++
            continue
        }
        $out.Add($line)
    }
    return , $out.ToArray()
}

# ---------------------------------------------------------------------------
# package.json：增删 dsh.profile.bundles 里的一项（纯文本编辑，保持原格式）
# ---------------------------------------------------------------------------
function Set-BundlePresent {
    param([string[]]$Lines, [string]$Name, [bool]$Present)

    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*"bundles"\s*:\s*\[\s*$') { $start = $i; break }
    }
    if ($start -lt 0) { throw "package.json 里找不到 dsh.profile.bundles 数组：$Manifest" }

    $end = -1
    for ($i = $start + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*\]\s*,?\s*$') { $end = $i; break }
    }
    if ($end -lt 0) { throw 'dsh.profile.bundles 数组没有闭合括号' }

    $names = New-StringList
    for ($i = $start + 1; $i -lt $end; $i++) {
        if ($Lines[$i] -match '^\s*"([^"]+)"\s*,?\s*$') { $names.Add($Matches[1]) }
    }

    $has = $names.Contains($Name)
    if ($Present -and -not $has) { $names.Add($Name) }
    if (-not $Present -and $has) { [void]$names.Remove($Name) }

    $block = New-StringList
    for ($k = 0; $k -lt $names.Count; $k++) {
        $comma = if ($k -lt $names.Count - 1) { ',' } else { '' }
        $block.Add('        "' + $names[$k] + '"' + $comma)
    }

    $new = New-StringList
    for ($i = 0; $i -le $start; $i++) { $new.Add($Lines[$i]) }
    foreach ($b in $block) { $new.Add($b) }
    for ($i = $end; $i -lt $Lines.Count; $i++) { $new.Add($Lines[$i]) }
    return , $new.ToArray()
}

# ---------------------------------------------------------------------------
# .dsh-market\state.json：同步 disabled 包名列表（保留其它插件原有状态）
# ---------------------------------------------------------------------------
function Sync-MarketState {
    param([bool]$Disable)

    if (-not (Test-Path -LiteralPath $MarketState)) { return $false }

    $obj = (Read-Utf8 $MarketState) | ConvertFrom-Json
    $list = New-StringList
    foreach ($d in @($obj.disabled)) { if ($d) { $list.Add([string]$d) } }

    $changed = $false
    foreach ($p in $StockPackages) {
        if ($Disable) {
            if (-not $list.Contains($p)) { $list.Add($p); $changed = $true }
        }
        else {
            if ($list.Contains($p)) { [void]$list.Remove($p); $changed = $true }
        }
    }
    if (-not $changed) { return $false }

    $obj.disabled = @($list.ToArray())
    $json = $obj | ConvertTo-Json -Depth 8 -Compress
    Write-Utf8Atomic $MarketState $json
    return $true
}

# ---------------------------------------------------------------------------
# 备份（保留最近 8 份）
# ---------------------------------------------------------------------------
function Backup-File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item -LiteralPath $Path -Destination "$Path.bak-$stamp" -Force
    Get-ChildItem -LiteralPath (Split-Path -Parent $Path) -Filter ((Split-Path -Leaf $Path) + '.bak-*') -File |
        Sort-Object Name -Descending |
        Select-Object -Skip 8 |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Toast（静默提示，失败不影响主流程）
# ---------------------------------------------------------------------------
function Show-Toast([string]$Title, [string]$Body) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
        $tpl = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $nodes = $tpl.GetElementsByTagName('text')
        [void]$nodes.Item(0).AppendChild($tpl.CreateTextNode($Title))
        [void]$nodes.Item(1).AppendChild($tpl.CreateTextNode($Body))
        $toast = [Windows.UI.Notifications.ToastNotification]::new($tpl)
        $aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid).Show($toast)
    }
    catch { }
}

function Write-Log([string]$Message) {
    try {
        $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Mode, $Message
        [System.IO.File]::AppendAllText($LogPath, $line + "`n", $script:Utf8NoBom)
    }
    catch { }
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
try {
    Write-Log "==== 开始切换 (NoLaunch=$NoLaunch) ===="

    if (-not (Test-Path -LiteralPath $PatchPath))   { throw "找不到补丁文件：$PatchPath" }
    if (-not (Test-Path -LiteralPath $Manifest))    { throw "找不到 profile 清单：$Manifest" }

    $origPatch = Read-Utf8 $PatchPath
    $origPkg   = Read-Utf8 $Manifest

    if ($origPatch.IndexOf("`r") -ge 0) {
        Write-Log '警告：补丁文件原本是 CRLF，将统一改写为 LF'
    }

    $patchLines = $origPatch -split "`n"
    $pkgLines   = $origPkg   -split "`n"

    if ($Mode -eq 'study') {
        Write-Log "关闭股票插件：$($StockRows -join ', ')"
        foreach ($id in $StockRows) { $patchLines = Set-RowDisabled -Lines $patchLines -RowId $id }
        foreach ($b in $StockBundles) { $pkgLines = Set-BundlePresent -Lines $pkgLines -Name $b -Present $false }

        if ($StudyOnlyRows.Count -gt 0) {
            Write-Log "启用学习插件：$($StudyOnlyRows -join ', ')"
            foreach ($id in $StudyOnlyRows) { $patchLines = Clear-RowDisabled -Lines $patchLines -RowId $id }
        }
        foreach ($b in $StudyOnlyBundles) { $pkgLines = Set-BundlePresent -Lines $pkgLines -Name $b -Present $true }
    }
    else {
        Write-Log '打开股票插件'
        foreach ($b in $StockBundles) { $pkgLines = Set-BundlePresent -Lines $pkgLines -Name $b -Present $true }
        foreach ($id in $StockRows) { $patchLines = Clear-RowDisabled -Lines $patchLines -RowId $id }

        if ($StudyOnlyRows.Count -gt 0) {
            Write-Log "关闭学习插件：$($StudyOnlyRows -join ', ')"
            foreach ($id in $StudyOnlyRows) { $patchLines = Set-RowDisabled -Lines $patchLines -RowId $id }
        }
        foreach ($b in $StudyOnlyBundles) { $pkgLines = Set-BundlePresent -Lines $pkgLines -Name $b -Present $false }
    }

    $newPatch = ($patchLines -join "`n")
    $newPkg = ($pkgLines -join "`n")

    $changed = @()

    if ($newPatch -ne $origPatch) {
        Backup-File $PatchPath
        Write-Utf8Atomic $PatchPath $newPatch
        $changed += 'cordis.patch.yml'
    }
    if ($newPkg -ne $origPkg) {
        Backup-File $Manifest
        Write-Utf8Atomic $Manifest $newPkg
        $changed += 'package.json'
    }
    if (Sync-MarketState -Disable:($Mode -eq 'study')) { $changed += '.dsh-market\state.json' }

    # 自检：study 模式下每一行都应是「紧跟 disabled: true」
    $missing = @()
    if ($Mode -eq 'study') {
        $verify = $newPatch -split "`n"
        foreach ($id in $StockRows) {
            $ok = $false
            for ($i = 0; $i -lt $verify.Count - 1; $i++) {
                if ($verify[$i] -match '^- id:\s*(\S+)\s*$' -and $Matches[1] -eq $id -and
                    $verify[$i + 1] -match '^\s+disabled:\s*true\s*$') { $ok = $true; break }
            }
            if (-not $ok) { $missing += $id }
        }
    }
    if ($missing.Count -gt 0) { Write-Log "自检失败，未禁用：$($missing -join ', ')" }
    else { Write-Log '自检通过' }

    if ($changed.Count -eq 0) { Write-Log '文件已是目标状态，无需改写' }
    else { Write-Log ("已改写：" + ($changed -join '、')) }

    if (-not $NoLaunch) {
        if ($ExePath -and (Test-Path -LiteralPath $ExePath)) {
            Start-Process -FilePath $ExePath -WorkingDirectory (Split-Path -Parent $ExePath)
            Write-Log "已拉起 / 唤起：$ExePath"
        }
        else {
            throw "找不到 $AppName 主程序。请在 dsh-mode.config.psd1 里设置 ExePath，或设置环境变量 DSH_EXE。"
        }
    }

    if ($NoLaunch) {
        Write-Log '（-NoLaunch）跳过启动'
    }
    elseif ($UseToast) {
        if ($Mode -eq 'stock') { Show-Toast 'DSH · 股票模式' '已启用全部股票插件' }
        else                   { Show-Toast 'DSH · 学习模式' '已关闭全部股票插件' }
    }

    Write-Log '==== 完成 ===='
    exit 0
}
catch {
    Write-Log ("失败：" + $_.Exception.Message)
    exit 1
}
