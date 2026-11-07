<#
  DSH 双模式启动器 —— 安装脚本
  ---------------------------------------------------------------------------
  做三件事：
    1. 检查环境（DSH profile、补丁文件、主程序、脚本自身编码）
    2. 在桌面创建两个快捷方式：DSH 股票 / DSH 学习
    3. 提示后续用法

  用法：
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File install.ps1
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Uninstall

  只创建快捷方式、不改系统其它任何地方。
#>
[CmdletBinding()]
param(
    # 删除本脚本创建的快捷方式
    [switch]$Uninstall,

    # 不创建桌面图标，只做环境检查
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$vbsPath   = Join-Path $scriptDir 'dsh-mode.vbs'
$ps1Path   = Join-Path $scriptDir 'dsh-mode.ps1'
$iconDir   = Join-Path $scriptDir 'icons'

$Modes = @(
    @{ Mode = 'stock'; Name = 'DSH 股票'; Icon = 'dsh-stock.ico' }
    @{ Mode = 'study'; Name = 'DSH 学习'; Icon = 'dsh-study.ico' }
)

function Write-Step([string]$Text) { Write-Host "  $Text" }
function Write-Ok([string]$Text)   { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text){ Write-Host "  [警告] $Text" -ForegroundColor Yellow }
function Write-Bad([string]$Text)  { Write-Host "  [失败] $Text" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# 0. 检查运行环境
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'DSH 双模式启动器' -ForegroundColor Cyan
Write-Host '================' -ForegroundColor Cyan
Write-Host ''

Write-Host '检查环境：'
Write-Step "脚本目录：$scriptDir"

foreach ($f in @($vbsPath, $ps1Path)) {
    if (Test-Path -LiteralPath $f) { Write-Ok (Split-Path -Leaf $f) }
    else { Write-Bad "缺少文件：$f"; exit 1 }
}

# 脚本必须是 UTF-8；带不带 BOM 都能跑，但 5.1 读无 BOM 的中文会乱码
$bytes = [System.IO.File]::ReadAllBytes($ps1Path)
$hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
if ($hasBom) { Write-Ok 'dsh-mode.ps1 编码 UTF-8 BOM' }
else { Write-Warn2 'dsh-mode.ps1 没有 BOM，Windows PowerShell 5.1 下中文日志可能乱码' }

# 图标
foreach ($m in $Modes) {
    $ico = Join-Path $iconDir $m.Icon
    if (Test-Path -LiteralPath $ico) { Write-Ok "$($m.Icon)" }
    else { Write-Warn2 "缺少图标 $($m.Icon)（快捷方式会用默认图标）" }
}

# DSH profile
$dshHome    = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
$profileDir = if ($env:DSH_PROFILE_DIR) { $env:DSH_PROFILE_DIR } else { Join-Path $dshHome 'profiles\desktop' }
$patchPath  = Join-Path $profileDir 'cordis.patch.yml'
$manifest   = Join-Path $profileDir 'package.json'

if (Test-Path -LiteralPath $patchPath) { Write-Ok "补丁文件 $patchPath" }
else { Write-Bad "找不到 $patchPath —— DSH 桌面版装过、并且至少启动过一次吗？"; exit 1 }

if (Test-Path -LiteralPath $manifest) { Write-Ok "profile 清单 $manifest" }
else { Write-Bad "找不到 $manifest"; exit 1 }

# 股票插件是否真的装了
$stockPkgs = @(
    'dsh-plugin-stock-x', 'dsh-stock-jt', 'dsh-live-data',
    'dsh-astock-research', 'dsh-stock-analysis', 'dsh-ths-holdings'
)
$nm = Join-Path $profileDir 'node_modules'
$missingPkgs = @()
foreach ($p in $stockPkgs) {
    if (-not (Test-Path -LiteralPath (Join-Path $nm $p))) { $missingPkgs += $p }
}
if ($missingPkgs.Count -eq 0) { Write-Ok '六个股票插件都在 node_modules 里' }
else {
    Write-Warn2 ("没找到这些包（对应模式切换会无效）：" + ($missingPkgs -join ', '))
    Write-Step  '装好插件后再跑本脚本即可；或者先跑一次 dsh-mode.ps1，它会跳过不存在的行。'
}

# 主程序
$cfgPath = Join-Path $scriptDir 'dsh-mode.config.psd1'
$appName = 'DeepSeek Harness'
if (Test-Path -LiteralPath $cfgPath) {
    try {
        $cfg = Import-PowerShellDataFile -LiteralPath $cfgPath
        if ($cfg.AppName) { $appName = $cfg.AppName }
    }
    catch { }
}

$probe = $null
try {
    $p = Get-Process -Name $appName -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
    if ($p) { $probe = $p.Path }
}
catch { }

if ($probe) { Write-Ok "主程序 $probe" }
else { Write-Warn2 '没探测到运行中的 DSH；首次点图标时脚本会再找一次。找不到就在 dsh-mode.config.psd1 里写 ExePath。' }

if ($CheckOnly) {
    Write-Host ''
    Write-Host '（-CheckOnly）跳过创建快捷方式。' -ForegroundColor DarkGray
    exit 0
}

# ---------------------------------------------------------------------------
# 1. 卸载
# ---------------------------------------------------------------------------
$desktop = [Environment]::GetFolderPath('Desktop')
$shell = New-Object -ComObject WScript.Shell

if ($Uninstall) {
    Write-Host ''
    Write-Host '删除快捷方式：'
    foreach ($m in $Modes) {
        $lnk = Join-Path $desktop ($m.Name + '.lnk')
        if (Test-Path -LiteralPath $lnk) {
            Remove-Item -LiteralPath $lnk -Force
            Write-Ok "已删除 $($m.Name).lnk"
        }
        else { Write-Step "不存在 $($m.Name).lnk" }
    }
    Write-Host ''
    Write-Host '插件配置文件未改动（仍然是你最后一次切换到的模式）。' -ForegroundColor DarkGray
    exit 0
}

# ---------------------------------------------------------------------------
# 2. 创建快捷方式
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '创建桌面快捷方式：'

$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
$created = 0

foreach ($m in $Modes) {
    $lnkPath = Join-Path $desktop ($m.Name + '.lnk')
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath       = $wscript
    $lnk.Arguments        = '"{0}" {1}' -f $vbsPath, $m.Mode
    $lnk.WorkingDirectory = $scriptDir
    $lnk.Description      = if ($m.Mode -eq 'stock') { 'DSH：打开全部股票插件' }
                            else { 'DSH：关闭全部股票插件（学习模式）' }
    $ico = Join-Path $iconDir $m.Icon
    if (Test-Path -LiteralPath $ico) { $lnk.IconLocation = "$ico,0" }
    $lnk.WindowStyle = 1
    $lnk.Save()
    Write-Ok "$($m.Name).lnk → $lnkPath"
    $created++
}

Write-Host ''
Write-Host "完成：创建了 $created 个快捷方式。" -ForegroundColor Green
Write-Host ''
Write-Host '点图标即可。想验证不启动程序只改文件，可以跑：' -ForegroundColor DarkGray
Write-Host "  powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ps1Path`" -Mode study -NoLaunch" -ForegroundColor DarkGray
Write-Host ''
