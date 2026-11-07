<#
  DSH 多模式启动器（命令行入口）
  ---------------------------------------------------------------------------
  用法：
    powershell.exe -NoProfile -WindowStyle Hidden -File "dsh-mode.ps1" -Mode stock
    powershell.exe -NoProfile -WindowStyle Hidden -File "dsh-mode.ps1" -Mode study
    powershell.exe -NoProfile -WindowStyle Hidden -File "dsh-mode.ps1" -Mode <任意自定义模式 id>

  模式清单在 modes.json 里，可用 dsh-mode-panel.ps1 可视化编辑。
  -ListModes  只列出当前可用模式，不改任何文件
  -NoLaunch   只改文件，不拉起主程序（调试用）

  原理：Desktop 版只能跑 profiles\desktop，且单实例。
  所以所有入口共用一个 Host，靠改写 profile 的 cordis.patch.yml
  （以及 package.json 里的 profile.bundles）来切换插件集，
  dsh-hmr 会在 1 秒内自动 recompose，无需重启；
  最后把主程序拉起 / 唤起即可。

  写入铁律：UTF-8 无 BOM + LF，临时文件 + 改名，绝不写 BOM / CRLF。
#>
[CmdletBinding()]
param(
    [string]$Mode,

    # 仅改文件，不拉起主程序（用于测试）
    [switch]$NoLaunch,

    # 只列出模式，不做任何改动
    [switch]$ListModes
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'dsh-modes-lib.ps1')

# ---------------------------------------------------------------------------
# -ListModes
# ---------------------------------------------------------------------------
if ($ListModes) {
    $cfg = Get-ModeConfig
    $state = Get-ModeState
    Write-Host ''
    Write-Host ('可用模式（active = {0}）' -f $cfg.active) -ForegroundColor Cyan
    foreach ($m in $cfg.modes) {
        $mark = if ($m.id -eq $state.activeMode) { '*' } else { ' ' }
        Write-Host ('  {0} {1,-12} {2}' -f $mark, $m.id, $m.name)
        if ($m.note) { Write-Host ('      {0}' -f $m.note) -ForegroundColor DarkGray }
    }
    Write-Host ''
    exit 0
}

if (-not $Mode) {
    Write-Host '缺少 -Mode。用 -ListModes 查看可用模式。' -ForegroundColor Red
    exit 2
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
try {
    Write-DshLog $Mode "==== 开始切换 (NoLaunch=$NoLaunch) ===="

    $catalog = Get-DshCatalog
    $result = Apply-DshMode -ModeId $Mode -Catalog $catalog

    if ($result.Skipped.Count -gt 0) {
        Write-DshLog $Mode ('跳过（受保护或找不到）：' + ($result.Skipped -join ', '))
    }

    if (-not $NoLaunch) {
        [void](Start-DshApp)
        Write-DshLog $Mode "已拉起 / 唤起：$($script:ExePath)"
    }
    else {
        Write-DshLog $Mode '（-NoLaunch）跳过启动'
    }

    if ((-not $NoLaunch) -and $script:UseToast) {
        Show-Toast ('DSH · ' + $result.Mode.name) ('已应用：' + $result.Mode.note)
    }

    Write-DshLog $Mode '==== 完成 ===='
    exit 0
}
catch {
    Write-DshLog $Mode ('失败：' + $_.Exception.Message)
    exit 1
}
