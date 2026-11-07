<#
  DSH 多模式启动器 —— 安装脚本
  ---------------------------------------------------------------------------
  做三件事：
    1. 检查环境（DSH profile、补丁文件、主程序、脚本自身编码）
    2. 按 modes.json 里 pin=true 的模式，在桌面创建快捷方式 + 一个「DSH 模式面板」
    3. 提示后续用法

  用法：
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File install.ps1
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Uninstall
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File install.ps1 -CheckOnly
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File install.ps1 -NoPanel   # 不建面板快捷方式

  只创建/删除本程序自己的快捷方式，不改系统其它任何地方。
#>
[CmdletBinding()]
param(
    # 删除本脚本创建的快捷方式
    [switch]$Uninstall,

    # 不创建桌面图标，只做环境检查
    [switch]$CheckOnly,

    # 不创建「DSH 模式面板」快捷方式
    [switch]$NoPanel
)

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$libPath   = Join-Path $scriptDir 'dsh-modes-lib.ps1'
$modesPath = Join-Path $scriptDir 'modes.json'
$iconDir   = Join-Path $scriptDir 'icons'

function Write-Step([string]$Text)  { Write-Host "  $Text" }
function Write-Ok([string]$Text)    { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text) { Write-Host "  [警告] $Text" -ForegroundColor Yellow }
function Write-Bad([string]$Text)   { Write-Host "  [失败] $Text" -ForegroundColor Red }

Write-Host ''
Write-Host 'DSH 多模式启动器' -ForegroundColor Cyan
Write-Host '================' -ForegroundColor Cyan
Write-Host ''
Write-Host '检查环境：'
Write-Step "脚本目录：$scriptDir"

$required = @(
    (Join-Path $scriptDir 'dsh-mode.vbs'),
    (Join-Path $scriptDir 'dsh-mode.ps1'),
    $libPath,
    $modesPath
)
foreach ($f in $required) {
    if (Test-Path -LiteralPath $f) { Write-Ok (Split-Path -Leaf $f) }
    else { Write-Bad "缺少文件：$f"; exit 1 }
}

foreach ($opt in @('dsh-mode-panel.vbs', 'dsh-mode-panel.ps1')) {
    $f = Join-Path $scriptDir $opt
    if (Test-Path -LiteralPath $f) { Write-Ok $opt }
    else { Write-Warn2 "缺少 $opt，跳过面板快捷方式" }
}

# 脚本必须是 UTF-8；带不带 BOM 都能跑，但 5.1 读无 BOM 的中文会乱码
foreach ($f in @((Join-Path $scriptDir 'dsh-mode.ps1'), $libPath)) {
    $bytes = [System.IO.File]::ReadAllBytes($f)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
    $leaf = Split-Path -Leaf $f
    if ($hasBom) { Write-Ok "$leaf 编码 UTF-8 BOM" }
    else { Write-Warn2 "$leaf 没有 BOM，Windows PowerShell 5.1 下中文可能乱码" }
}

foreach ($ico in @('dsh-stock.ico', 'dsh-study.ico', 'dsh-panel.ico')) {
    if (Test-Path -LiteralPath (Join-Path $iconDir $ico)) { Write-Ok $ico }
    else { Write-Warn2 "缺少图标 $ico（快捷方式会用默认图标）" }
}

# 用共享库读配置，保证和面板/切换脚本用的是同一套解析
. $libPath

$cfg = $null
try { $cfg = Get-ModeConfig }
catch { Write-Bad "modes.json 解析失败：$($_.Exception.Message)"; exit 1 }

$modes = @($cfg.modes)
if ($modes.Count -eq 0) { Write-Bad 'modes.json 里没有任何模式'; exit 1 }
Write-Ok ("模式清单：{0} 个（{1}）" -f $modes.Count, (($modes | ForEach-Object { $_.name }) -join '、'))

$pinned = @(Get-PinnedModes -Config $cfg)
Write-Ok ("其中 {0} 个会放桌面图标（{1}）" -f $pinned.Count, (($pinned | ForEach-Object { $_.name }) -join '、'))

if (Test-Path -LiteralPath $script:PatchPath) { Write-Ok "补丁文件 $($script:PatchPath)" }
else { Write-Bad "找不到 $($script:PatchPath) —— DSH 桌面版装过、并且至少启动过一次吗？"; exit 1 }

if (Test-Path -LiteralPath $script:Manifest) { Write-Ok "profile 清单 $($script:Manifest)" }
else { Write-Bad "找不到 $($script:Manifest)"; exit 1 }

# 模式里引用的插件是否真的装了
$nm = $script:NodeModules
$referenced = New-Object System.Collections.Generic.List[string]
foreach ($m in $modes) {
    foreach ($p in @($m.disabled) + @($m.requireBundles) + @($m.removeBundles)) {
        if ($p -and -not $referenced.Contains($p)) { $referenced.Add($p) }
    }
}
$missingPkgs = @()
foreach ($p in $referenced) {
    if (-not (Test-Path -LiteralPath (Join-Path $nm $p))) { $missingPkgs += $p }
}
if ($referenced.Count -eq 0) {
    Write-Step '模式里没有引用任何插件（全部保持原样）'
}
elseif ($missingPkgs.Count -eq 0) {
    Write-Ok ("{0} 个被引用的插件都在 node_modules 里" -f $referenced.Count)
}
else {
    Write-Warn2 ("没找到这些包（相关模式里对应项会被跳过）：" + ($missingPkgs -join ', '))
}

if ($script:ExePath) { Write-Ok "主程序 $($script:ExePath)" }
else { Write-Warn2 '没探测到运行中的 DSH；首次点图标时脚本会再找一次。找不到就在 dsh-mode.config.psd1 里写 ExePath。' }

if ($CheckOnly) {
    Write-Host ''
    Write-Host '（-CheckOnly）跳过创建快捷方式。' -ForegroundColor DarkGray
    exit 0
}

# ---------------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------------
if ($Uninstall) {
    Write-Host ''
    Write-Host '删除快捷方式：'
    foreach ($lnk in (Get-ShortcutPaths -Config $cfg)) {
        $leaf = [System.IO.Path]::GetFileName($lnk)
        if (-not (Test-Path -LiteralPath $lnk)) { Write-Step "不存在 $leaf"; continue }
        if (Test-OwnShortcut $lnk) {
            Remove-Item -LiteralPath $lnk -Force
            Write-Ok "已删除 $leaf"
        }
        else { Write-Warn2 "跳过 $leaf（不是本脚本建的）" }
    }
    Write-Host ''
    Write-Host '插件配置文件未改动（仍然是你最后一次切换到的模式）。' -ForegroundColor DarkGray
    exit 0
}

# ---------------------------------------------------------------------------
# 创建快捷方式
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '创建桌面快捷方式：'

$res = Sync-DesktopShortcuts -Config $cfg -IncludePanel:(-not $NoPanel)

foreach ($lnk in $res.Created) { Write-Ok ([System.IO.Path]::GetFileName($lnk)) }
foreach ($lnk in $res.Removed) { Write-Step "已清理过期图标 $([System.IO.Path]::GetFileName($lnk))" }

Write-Host ''
Write-Host ("完成：桌面上有 {0} 个图标。" -f $res.Created.Count) -ForegroundColor Green
Write-Host ''
Write-Host '点模式图标直接切换并启动；点「DSH 模式面板」可以勾选插件、新建自定义模式。' -ForegroundColor DarkGray
Write-Host '想验证不启动程序只改文件，可以跑：' -ForegroundColor DarkGray
Write-Host ('  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode study -NoLaunch' -f (Join-Path $scriptDir 'dsh-mode.ps1')) -ForegroundColor DarkGray
Write-Host ''
