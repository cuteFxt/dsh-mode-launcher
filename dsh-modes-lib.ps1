# =============================================================================
#  DSH 多模式启动器 —— 公共库
#  被 dsh-mode.ps1（命令行）与 dsh-mode-panel.ps1（可视化面板）共同 dot-source。
#  只定义函数与变量，不执行任何有副作用的动作。
#
#  写入铁律：cordis.patch.yml / package.json 一律 UTF-8 无 BOM + LF，
#  临时文件 + 改名，绝不写 BOM / CRLF。
# =============================================================================

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 配置（同目录 dsh-mode.config.psd1，可选）
# ---------------------------------------------------------------------------
$script:ConfigPath = Join-Path $PSScriptRoot 'dsh-mode.config.psd1'
$script:Config = @{}
if (Test-Path -LiteralPath $script:ConfigPath) {
    try { $script:Config = Import-PowerShellDataFile -LiteralPath $script:ConfigPath } catch { $script:Config = @{} }
}

$script:AppName = if ($script:Config.AppName) { $script:Config.AppName } else { 'DeepSeek Harness' }

# ---------------------------------------------------------------------------
# 定位主程序：配置 > 环境变量 DSH_EXE > 运行中的进程 > 桌面/开始菜单快捷方式
# ---------------------------------------------------------------------------
function Resolve-DshExe {
    param([string]$Configured, [string]$Name)

    if ($Configured  -and (Test-Path -LiteralPath $Configured)) { return $Configured }
    if ($env:DSH_EXE -and (Test-Path -LiteralPath $env:DSH_EXE)) { return $env:DSH_EXE }

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
$script:DshHome = if ($env:DSH_HOME) { $env:DSH_HOME }
                  elseif ($script:Config.DshHome) { $script:Config.DshHome }
                  else { Join-Path $env:USERPROFILE '.dsh' }

$script:ProfileName = if ($script:Config.ProfileName) { $script:Config.ProfileName } else { 'desktop' }
$script:ProfileDir  = if ($env:DSH_PROFILE_DIR) { $env:DSH_PROFILE_DIR }
                      else { Join-Path $script:DshHome (Join-Path 'profiles' $script:ProfileName) }

$script:PatchPath    = Join-Path $script:ProfileDir 'cordis.patch.yml'
$script:Manifest     = Join-Path $script:ProfileDir 'package.json'
$script:MarketState  = Join-Path $script:ProfileDir '.dsh-market\state.json'
$script:NodeModules  = Join-Path $script:ProfileDir 'node_modules'

$script:ModesPath    = if ($script:Config.ModesPath) { $script:Config.ModesPath }
                       else { Join-Path $PSScriptRoot 'modes.json' }
$script:StatePath    = Join-Path $PSScriptRoot 'modes.state.json'
$script:CatalogPath  = Join-Path $PSScriptRoot 'catalog.json'
$script:LogPath      = Join-Path $PSScriptRoot 'dsh-mode.log'
$script:ExePath      = Resolve-DshExe -Configured $script:Config.ExePath -Name $script:AppName
$script:UseToast     = if ($script:Config.ContainsKey('Toast')) { [bool]$script:Config.Toast } else { $true }

# ---------------------------------------------------------------------------
# 受保护的行 id：永不允许被模式关闭（关掉它们 Host 会残废）
# ---------------------------------------------------------------------------
$script:ProtectedRowPattern = '^(llm-|session|storage|agent|tool-|hmr$|timer$|typert|settings$|credentials|sandbox|approval|permission|skill$|fs-|commands|working-directory)'

# ---------------------------------------------------------------------------
# 文本读写（UTF-8 无 BOM / LF）
# ---------------------------------------------------------------------------
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-Utf8([string]$Path) {
    [System.IO.File]::ReadAllText($Path, $script:Utf8NoBom)
}

function Read-Utf8Text([string]$Path) {
    # 兼容带/不带 BOM 的输入
    [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
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
function Get-BundleNames {
    param([string[]]$Lines)

    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*"bundles"\s*:\s*\[\s*$') { $start = $i; break }
    }
    if ($start -lt 0) { return @() }
    $names = New-StringList
    for ($i = $start + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*\]\s*,?\s*$') { break }
        if ($Lines[$i] -match '^\s*"([^"]+)"\s*,?\s*$') { $names.Add($Matches[1]) }
    }
    # 注意：不要写成 return , $names.ToArray() —— 那会再包一层，
    # 调用方 @(Get-BundleNames ...).Count 会永远得到 1。
    return $names.ToArray()
}

function Set-BundlePresent {
    param([string[]]$Lines, [string]$Name, [bool]$Present)

    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*"bundles"\s*:\s*\[\s*$') { $start = $i; break }
    }
    if ($start -lt 0) { throw "package.json 里找不到 dsh.profile.bundles 数组：$script:Manifest" }

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
# 插件目录：扫描 profile 的 node_modules，找出所有带 bundle patch 的包，
# 记录 <包名> -> <行 id 列表>、描述、是否带 UI。
# 结果缓存到 catalog.json（默认 12 小时内复用，-Refresh 强制重建）。
# ---------------------------------------------------------------------------
function Get-DshCatalog {
    param([switch]$Refresh, [int]$MaxAgeHours = 0)

    # 每次现扫。实测全量扫描 19 个包约 440ms，没必要缓存 —— 缓存只会让
    # 刚装的插件在面板里"看不见"，那是最容易踩的坑。
    # 这里仍保留一个同进程内的 memo，避免同一次运行里重复扫两遍。
    if (-not $Refresh -and $script:CatalogMemo) { return $script:CatalogMemo }

    # 插件包扫描根：优先当前 profile，其次是默认 desktop profile
    # （调试时用 DSH_PROFILE_DIR 指向临时目录，插件仍从真实 profile 读）
    $scanRoot = $null
    foreach ($cand in @(
            $script:NodeModules
            (Join-Path $script:DshHome 'profiles\desktop\node_modules')
        )) {
        if ($cand -and (Test-Path -LiteralPath $cand)) { $scanRoot = $cand; break }
    }

    $packages = [ordered]@{}
    if ($scanRoot) {
        $dirs = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
        foreach ($d in Get-ChildItem -LiteralPath $scanRoot -Directory -ErrorAction SilentlyContinue) {
            if ($d.Name -like '@*') {
                foreach ($s in Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue) { $dirs.Add($s) }
            }
            else { $dirs.Add($d) }
        }

        foreach ($d in $dirs) {
            $pkgJson = Join-Path $d.FullName 'package.json'
            if (-not (Test-Path -LiteralPath $pkgJson)) { continue }
            $j = $null
            try { $j = (Read-Utf8Text $pkgJson) | ConvertFrom-Json } catch { continue }
            if (-not $j.name) { continue }
            $patchRel = $null
            if ($j.dsh -and $j.dsh.bundle -and $j.dsh.bundle.patch) { $patchRel = $j.dsh.bundle.patch }
            if (-not $patchRel) { continue }
            $patchFile = Join-Path $d.FullName $patchRel
            if (-not (Test-Path -LiteralPath $patchFile)) { continue }

            $rows = New-StringList
            foreach ($ln in [System.IO.File]::ReadAllLines($patchFile, [System.Text.Encoding]::UTF8)) {
                if ($ln -match '^\s*-\s*id:\s*(\S+)\s*$') { $rows.Add($Matches[1].Trim('"', "'")) }
            }
            if ($rows.Count -eq 0) { continue }

            $hasClient = ($null -ne $j.dsh.client)
            $packages[$j.name] = [pscustomobject]@{
                name        = $j.name
                version     = [string]$j.version
                description = [string]$j.description
                rows        = @($rows.ToArray())
                client      = $hasClient
            }
        }
    }

    $result = [pscustomobject]@{
        generatedAt = (Get-Date).ToString('s')
        packages    = $packages
    }
    try { Write-Utf8Atomic $script:CatalogPath ($result | ConvertTo-Json -Depth 8) } catch { }
    $script:CatalogMemo = ($result | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    return $script:CatalogMemo
}

# ---------------------------------------------------------------------------
# modes.json 读写
# ---------------------------------------------------------------------------
function Get-ModeConfig {
    if (-not (Test-Path -LiteralPath $script:ModesPath)) { throw "找不到模式配置：$script:ModesPath" }
    $obj = (Read-Utf8Text $script:ModesPath) | ConvertFrom-Json
    if (-not $obj.modes) { throw "modes.json 缺少 modes 数组：$script:ModesPath" }
    # 补齐可选字段，老配置文件也能读
    foreach ($m in @($obj.modes)) {
        if ($m.PSObject.Properties.Name -notcontains 'pin') {
            $m | Add-Member -NotePropertyName 'pin' -NotePropertyValue $true -Force
        }
        if ($m.PSObject.Properties.Name -notcontains 'requireBundles') {
            $m | Add-Member -NotePropertyName 'requireBundles' -NotePropertyValue @() -Force
        }
        if ($m.PSObject.Properties.Name -notcontains 'removeBundles') {
            $m | Add-Member -NotePropertyName 'removeBundles' -NotePropertyValue @() -Force
        }
        if ($m.PSObject.Properties.Name -notcontains 'builtin') {
            $m | Add-Member -NotePropertyName 'builtin' -NotePropertyValue $false -Force
        }
        if ($m.PSObject.Properties.Name -notcontains 'autoGroups') {
            $m | Add-Member -NotePropertyName 'autoGroups' -NotePropertyValue @() -Force
        }
        if ($m.PSObject.Properties.Name -notcontains 'autoMatch') {
            $m | Add-Member -NotePropertyName 'autoMatch' -NotePropertyValue @() -Force
        }
        if ($m.PSObject.Properties.Name -notcontains 'autoExcept') {
            $m | Add-Member -NotePropertyName 'autoExcept' -NotePropertyValue @() -Force
        }
    }
    return $obj
}

# 只返回要在桌面上建图标的模式
function Get-PinnedModes {
    param($Config)
    if (-not $Config) { $Config = Get-ModeConfig }
    return @($Config.modes | Where-Object { $_.pin })
}

# PS 5.1 的 ConvertTo-Json 会输出大量空行、缩进也很怪，这里自己排版，让 modes.json 能读能改。
function Format-ModeJson {
    param($Config)

    function Esc([string]$s) {
        if ($null -eq $s) { return '""' }
        $v = $s.Replace('\', '\\').Replace('"', '\"')
        $v = $v.Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
        return '"' + $v + '"'
    }
    function Arr($items) {
        $vals = @($items | Where-Object { $_ -ne $null -and "$_" -ne '' })
        if ($vals.Count -eq 0) { return '[]' }
        return '[' + (($vals | ForEach-Object { Esc ([string]$_) }) -join ', ') + ']'
    }

    $sb = New-Object System.Text.StringBuilder
    $nl = "`n"
    [void]$sb.Append('{' + $nl)
    [void]$sb.Append('  "version": ' + [int]$Config.version + ',' + $nl)
    [void]$sb.Append('  "active": ' + (Esc ([string]$Config.active)) + ',' + $nl)
    [void]$sb.Append('  "modes": [' + $nl)

    $modes = @($Config.modes)
    for ($i = 0; $i -lt $modes.Count; $i++) {
        $m = $modes[$i]
        $comma = if ($i -lt $modes.Count - 1) { ',' } else { '' }
        [void]$sb.Append('    {' + $nl)
        [void]$sb.Append('      "id": ' + (Esc ([string]$m.id)) + ',' + $nl)
        [void]$sb.Append('      "name": ' + (Esc ([string]$m.name)) + ',' + $nl)
        [void]$sb.Append('      "color": ' + (Esc ([string]$m.color)) + ',' + $nl)
        [void]$sb.Append('      "glyph": ' + (Esc ([string]$m.glyph)) + ',' + $nl)
        [void]$sb.Append('      "workspace": ' + (Esc ([string]$m.workspace)) + ',' + $nl)
        [void]$sb.Append('      "note": ' + (Esc ([string]$m.note)) + ',' + $nl)
        [void]$sb.Append('      "builtin": ' + $(if ($m.builtin) { 'true' } else { 'false' }) + ',' + $nl)
        [void]$sb.Append('      "pin": ' + $(if ($m.pin) { 'true' } else { 'false' }) + ',' + $nl)
        [void]$sb.Append('      "disabled": ' + (Arr $m.disabled) + ',' + $nl)
        [void]$sb.Append('      "autoGroups": ' + (Arr $m.autoGroups) + ',' + $nl)
        [void]$sb.Append('      "autoMatch": ' + (Arr $m.autoMatch) + ',' + $nl)
        [void]$sb.Append('      "autoExcept": ' + (Arr $m.autoExcept) + ',' + $nl)
        [void]$sb.Append('      "requireBundles": ' + (Arr $m.requireBundles) + ',' + $nl)
        [void]$sb.Append('      "removeBundles": ' + (Arr $m.removeBundles) + $nl)
        [void]$sb.Append('    }' + $comma + $nl)
    }

    [void]$sb.Append('  ]' + $nl)
    [void]$sb.Append('}' + $nl)
    return $sb.ToString()
}

function Save-ModeConfig {
    param($Config)
    if (-not $Config.version) { $Config | Add-Member -NotePropertyName 'version' -NotePropertyValue 2 -Force }
    Write-Utf8Atomic $script:ModesPath (Format-ModeJson $Config)
}

function Get-ModeState {
    if (Test-Path -LiteralPath $script:StatePath) {
        try { return (Read-Utf8Text $script:StatePath) | ConvertFrom-Json } catch { }
    }
    return [pscustomobject]@{
        activeMode       = $null
        disabledPackages = @()
        bundlesRemoved   = @()
        appliedAt        = $null
    }
}

function Save-ModeState {
    param($State)
    Write-Utf8Atomic $script:StatePath ($State | ConvertTo-Json -Depth 8)
}

# ---------------------------------------------------------------------------
# 模式编辑（面板用）：新增 / 修改 / 删除 / 重排
# ---------------------------------------------------------------------------
function New-ModeId {
    param([string]$Seed)
    $id = ($Seed -replace '[^\p{L}\p{Nd}]+', '-').Trim('-').ToLowerInvariant()
    if (-not $id) { $id = 'mode' }
    $cfg = Get-ModeConfig
    $taken = @($cfg.modes.id)
    if ($taken -notcontains $id) { return $id }
    $i = 2
    while ($taken -contains ($id + '-' + $i)) { $i++ }
    return ($id + '-' + $i)
}

function Add-ModeToConfig {
    param($Config, [string]$Name, [string]$Color, [string]$Workspace, [string]$Note, [string[]]$Disabled, [string]$Id)
    if (-not $Id) { $Id = New-ModeId -Seed $Name }
    $m = [pscustomobject]@{
        id             = $Id
        name           = $Name
        color          = if ($Color) { $Color } else { '#4C9AFF' }
        glyph          = if ($Name) { $Name.Substring(0,1) } else { '?' }
        workspace      = $Workspace
        note           = $Note
        builtin        = $false
        pin            = $true
        disabled       = @($Disabled | Where-Object { $_ })
        autoGroups     = @()
        autoMatch      = @()
        autoExcept     = @()
        requireBundles = @()
        removeBundles  = @()
    }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($x in @($Config.modes)) { $list.Add($x) }
    $list.Add($m)
    $Config.modes = @($list.ToArray())
    return $m
}

function Remove-ModeFromConfig {
    param($Config, [string]$Id)
    $target = @($Config.modes | Where-Object { $_.id -eq $Id }) | Select-Object -First 1
    if (-not $target) { throw "没有这个模式：$Id" }
    $left = @($Config.modes | Where-Object { $_.id -ne $Id })
    if ($left.Count -eq 0) { throw '至少要保留一个模式。' }
    $Config.modes = $left
    if ($Config.active -eq $Id) { $Config.active = $left[0].id }
    return $target
}

# ---------------------------------------------------------------------------
# 桌面快捷方式：按模式的 pin 字段增删（安装脚本和面板共用同一份逻辑）
# ---------------------------------------------------------------------------
function Get-ModeIconName {
    param([string]$ModeId)
    $map = @{ 'stock' = 'dsh-stock.ico'; 'study' = 'dsh-study.ico' }
    if ($map.ContainsKey($ModeId)) { return $map[$ModeId] }
    return 'dsh-panel.ico'
}

function Get-ShortcutPaths {
    param($Config)
    $desktop = [Environment]::GetFolderPath('Desktop')
    $paths = New-StringList
    foreach ($m in @($Config.modes)) {
        [void]$paths.Add((Join-Path $desktop ('DSH ' + $m.name + '.lnk')))
    }
    [void]$paths.Add((Join-Path $desktop 'DSH 模式面板.lnk'))
    return @($paths.ToArray())
}

# 只认「Target 是 wscript.exe 且 Arguments 指向本目录」的快捷方式，别人的图标一律不碰
function Test-OwnShortcut {
    param([string]$LnkPath)
    if (-not (Test-Path -LiteralPath $LnkPath)) { return $false }
    try {
        $shell = New-Object -ComObject WScript.Shell
        $sc = $shell.CreateShortcut($LnkPath)
        if ($sc.TargetPath -notmatch 'wscript\.exe$') { return $false }
        return ($sc.Arguments -like "*$PSScriptRoot*")
    }
    catch { return $false }
}

function New-DshShortcut {
    param([string]$Path, [string]$Arguments, [string]$Description, [string]$Icon)

    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($Path)
    $lnk.TargetPath       = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $lnk.Arguments        = $Arguments
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.Description      = $Description
    if ($Icon -and (Test-Path -LiteralPath $Icon)) { $lnk.IconLocation = "$Icon,0" }
    $lnk.WindowStyle      = 1
    $lnk.Save()
}

# 返回 @{ Created = @(); Removed = @() }
function Sync-DesktopShortcuts {
    param($Config, [switch]$IncludePanel)

    if (-not $Config) { $Config = Get-ModeConfig }
    $desktop  = [Environment]::GetFolderPath('Desktop')
    $vbsPath  = Join-Path $PSScriptRoot 'dsh-mode.vbs'
    $panelVbs = Join-Path $PSScriptRoot 'dsh-mode-panel.vbs'
    $iconDir  = Join-Path $PSScriptRoot 'icons'

    $created = New-StringList
    $removed = New-StringList
    $wanted  = New-StringList

    foreach ($m in @($Config.modes)) {
        if (-not $m.pin) { continue }
        if ($m.name -match '[\\/:*?"<>|]') { continue }   # 文件名非法字符，跳过
        $lnk = Join-Path $desktop ('DSH ' + $m.name + '.lnk')
        [void]$wanted.Add($lnk)
        $icon = Join-Path $iconDir (Get-ModeIconName $m.id)
        $desc = if ($m.note) { 'DSH：' + $m.note } else { 'DSH：' + $m.name }
        New-DshShortcut -Path $lnk -Arguments ('"{0}" {1}' -f $vbsPath, $m.id) -Description $desc -Icon $icon
        [void]$created.Add($lnk)
    }

    if ($IncludePanel -and (Test-Path -LiteralPath $panelVbs)) {
        $plnk = Join-Path $desktop 'DSH 模式面板.lnk'
        [void]$wanted.Add($plnk)
        New-DshShortcut -Path $plnk -Arguments ('"{0}"' -f $panelVbs) `
            -Description 'DSH：可视化挑选 / 编辑模式' -Icon (Join-Path $iconDir 'dsh-panel.ico')
        [void]$created.Add($plnk)
    }

    # 清掉「本程序建的、但已经不该存在」的模式图标（模式改名、取消 pin、模式被删）。
    # 面板图标不在这里处理：-NoPanel 装过的人，不该因为保存一次模式就被删掉面板。
    $desktopPath = $desktop
    $modePaths = New-StringList
    foreach ($m in @($Config.modes)) {
        [void]$modePaths.Add((Join-Path $desktopPath ('DSH ' + $m.name + '.lnk')))
    }
    # 取消 pin / 改名后，旧名字的图标也要清掉 —— 这里靠扫描桌面上的自有图标实现
    $candidates = New-StringList
    foreach ($p in @($modePaths.ToArray())) { [void]$candidates.Add($p) }
    foreach ($f in @(Get-ChildItem -LiteralPath $desktopPath -Filter 'DSH *.lnk' -File -ErrorAction SilentlyContinue)) {
        if (-not $candidates.Contains($f.FullName)) { [void]$candidates.Add($f.FullName) }
    }

    foreach ($lnk in @($candidates.ToArray())) {
        if (-not (Test-Path -LiteralPath $lnk)) { continue }
        if ($wanted.Contains($lnk)) { continue }
        if ([System.IO.Path]::GetFileName($lnk) -eq 'DSH 模式面板.lnk') { continue }
        if (Test-OwnShortcut $lnk) {
            Remove-Item -LiteralPath $lnk -Force
            [void]$removed.Add($lnk)
        }
    }

    return [pscustomobject]@{
        Created = @($created.ToArray())
        Removed = @($removed.ToArray())
    }
}

# ---------------------------------------------------------------------------
# 插件分组（复用 dshmarket 自己的分组，用于面板里分区显示）
# ---------------------------------------------------------------------------
function Get-PluginGroups {
    $groups = [ordered]@{}
    if (Test-Path -LiteralPath $script:MarketState) {
        try {
            $ms = (Read-Utf8Text $script:MarketState) | ConvertFrom-Json
            if ($ms.groups) {
                foreach ($p in $ms.groups.PSObject.Properties) {
                    $groups[$p.Name] = @($p.Value)
                }
            }
        }
        catch { }
    }
    return $groups
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
# .dsh-market\state.json：同步 disabled 包名列表（保留其它插件原有状态）
#   纯字符串层面的增删，避免 ConvertFrom-Json 往返污染中文键。
# ---------------------------------------------------------------------------
function Add-MarketDisabled {
    param([string]$Package)

    if (-not (Test-Path -LiteralPath $script:MarketState)) { return $false }
    $text = Read-Utf8Text $script:MarketState
    $m = [regex]::Match($text, '"disabled"\s*:\s*\[(.*?)\]', 'Singleline')
    if (-not $m.Success) { return $false }

    $inner = $m.Groups[1].Value
    $items = @([regex]::Matches($inner, '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value })
    if ($items -contains $Package) { return $false }
    $items += $Package
    $newInner = (@($items | ForEach-Object { '"' + $_ + '"' }) -join ',')
    $newText = $text.Substring(0, $m.Groups[1].Index) + $newInner + $text.Substring($m.Groups[1].Index + $m.Groups[1].Length)
    Write-Utf8Atomic $script:MarketState $newText
    return $true
}

function Remove-MarketDisabled {
    param([string]$Package)

    if (-not (Test-Path -LiteralPath $script:MarketState)) { return $false }
    $text = Read-Utf8Text $script:MarketState
    $m = [regex]::Match($text, '"disabled"\s*:\s*\[(.*?)\]', 'Singleline')
    if (-not $m.Success) { return $false }

    $inner = $m.Groups[1].Value
    $items = @([regex]::Matches($inner, '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value })
    if ($items -notcontains $Package) { return $false }
    $items = @($items | Where-Object { $_ -ne $Package })
    $newInner = (@($items | ForEach-Object { '"' + $_ + '"' }) -join ',')
    $newText = $text.Substring(0, $m.Groups[1].Index) + $newInner + $text.Substring($m.Groups[1].Index + $m.Groups[1].Length)
    Write-Utf8Atomic $script:MarketState $newText
    return $true
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

function Write-DshLog {
    param([string]$Tag, [string]$Message)
    try {
        $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Tag, $Message
        [System.IO.File]::AppendAllText($script:LogPath, $line + "`n", $script:Utf8NoBom)
    }
    catch { }
}

# ---------------------------------------------------------------------------
# 自动纳入（autoGroups / autoMatch）
#   模式可以声明"凡是属于这些分组 / 匹配这些通配符的插件，都算在这个模式里"。
#   这样新装的插件不需要手工勾进每个模式 —— 只要它归了组或名字对得上。
# ---------------------------------------------------------------------------
function Test-ModeGlob {
    param([string]$Pattern, [string]$Text)
    if (-not $Pattern -or -not $Text) { return $false }
    $rx = [regex]::Escape($Pattern).Replace('\*', '.*').Replace('\?', '.')
    return ($Text -match ('^' + $rx + '$'))
}

function Get-ModeAutoPackages {
    param($Mode, $Catalog)

    $hit = New-StringList
    if (-not $Catalog) { return @() }

    # --- 1. 按分组：autoGroups = ["股票"] ---
    $groups = @($Mode.autoGroups | Where-Object { $_ })
    if ($groups.Count -gt 0) {
        $map = Get-PluginGroups
        foreach ($g in $groups) {
            if (-not $map.Contains($g)) { continue }
            foreach ($pkg in @($map[$g])) {
                if ($pkg -and -not $hit.Contains($pkg)) { [void]$hit.Add($pkg) }
            }
        }
    }

    # --- 2. 按包名 / 描述通配：autoMatch = ["*stock*", "dsh-*"] ---
    $patterns = @($Mode.autoMatch | Where-Object { $_ })
    if ($patterns.Count -gt 0) {
        foreach ($p in $Catalog.packages.PSObject.Properties) {
            $name = $p.Name
            $desc = ''
            try { $desc = [string]$p.Value.description } catch { }
            $matched = $false
            foreach ($pat in $patterns) {
                if ((Test-ModeGlob $pat $name) -or (Test-ModeGlob $pat $desc)) { $matched = $true; break }
            }
            if ($matched -and -not $hit.Contains($name)) { [void]$hit.Add($name) }
        }
    }

    # --- 3. 例外：autoExcept = ["dsh-market"] —— 被自动规则误伤的包可以在这里排除 ---
    $except = @($Mode.autoExcept | Where-Object { $_ })
    if ($except.Count -gt 0) {
        $kept = New-StringList
        foreach ($pkg in @($hit.ToArray())) {
            if ($except -notcontains $pkg) { [void]$kept.Add($pkg) }
        }
        return @($kept.ToArray())
    }

    return @($hit.ToArray())
}

# ---------------------------------------------------------------------------
# 计算某个模式要关闭的「行 id」清单
# ---------------------------------------------------------------------------
function Get-ModeRows {
    param($Mode, $Catalog)

    $rows = New-StringList
    $skipped = New-StringList
    $auto = @(Get-ModeAutoPackages -Mode $Mode -Catalog $Catalog)
    $wanted = @(@($Mode.disabled) + $auto | Where-Object { $_ } | Select-Object -Unique)
    # autoExcept 是「这个模式里我要显式开」的例外，必须能盖过显式 disabled 名单，
    # 否则用户在面板里勾上它，保存后仍然会被关掉。
    $except = @($Mode.autoExcept | Where-Object { $_ })
    if ($except.Count -gt 0) {
        $wanted = @($wanted | Where-Object { $except -notcontains $_ })
    }
    foreach ($pkg in $wanted) {
        if (-not $pkg) { continue }
        $entry = $null
        if ($Catalog.packages.PSObject.Properties.Name -contains $pkg) { $entry = $Catalog.packages.$pkg }
        if (-not $entry) { [void]$skipped.Add($pkg); continue }
        foreach ($r in @($entry.rows)) {
            if ($r -match $script:ProtectedRowPattern) { [void]$skipped.Add("$pkg/$r"); continue }
            if (-not $rows.Contains($r)) { $rows.Add($r) }
        }
    }
    return [pscustomobject]@{
        Rows    = @($rows.ToArray())
        Skipped = @($skipped.ToArray())
    }
}

# ---------------------------------------------------------------------------
# 应用模式：改 cordis.patch.yml / package.json / .dsh-market\state.json
# 返回 { Changed = @(...), Mode = <mode 对象>, Skipped = @(...) }
# ---------------------------------------------------------------------------
function Apply-DshMode {
    param([Parameter(Mandatory)][string]$ModeId, $Catalog)

    $cfg = Get-ModeConfig
    $mode = @($cfg.modes | Where-Object { $_.id -eq $ModeId }) | Select-Object -First 1
    if (-not $mode) {
        throw ("未知模式：{0}。可用：{1}" -f $ModeId, ((@($cfg.modes.id)) -join ', '))
    }
    if (-not $Catalog) { $Catalog = Get-DshCatalog }

    if (-not (Test-Path -LiteralPath $script:PatchPath))  { throw "找不到补丁文件：$($script:PatchPath)" }
    if (-not (Test-Path -LiteralPath $script:Manifest))   { throw "找不到 profile 清单：$($script:Manifest)" }

    $state = Get-ModeState
    # 手动勾的 + 自动纳入的，合成这个模式真正要关掉的包名集合
    # autoExcept 里的包要在这里剔除，否则它们会被写进 .dsh-market 的 disabled 列表，
    # 而 Get-ModeRows 已经把同一批包排除了 —— 两边不一致会让 dshmarket 面板显示错乱。
    $desiredDisabled = @(
        @($mode.disabled) + @(Get-ModeAutoPackages -Mode $mode -Catalog $Catalog) |
            Where-Object { $_ } | Select-Object -Unique
    )
    $exceptList = @($mode.autoExcept | Where-Object { $_ })
    if ($exceptList.Count -gt 0) {
        $desiredDisabled = @($desiredDisabled | Where-Object { $exceptList -notcontains $_ })
    }
    $calc = Get-ModeRows -Mode $mode -Catalog $Catalog

    $origPatch = Read-Utf8 $script:PatchPath
    $origPkg   = Read-Utf8 $script:Manifest
    if ($origPatch.IndexOf("`r") -ge 0) { Write-DshLog $ModeId '警告：补丁文件原本是 CRLF，将统一改写为 LF' }

    $patchLines = $origPatch -split "`n"
    $pkgLines   = $origPkg   -split "`n"

    # 行 id -> 包名 反查表（用于「哪些行现在被禁着、该不该放开」）
    $rowOwner = @{}
    foreach ($p in $Catalog.packages.PSObject.Properties) {
        foreach ($r in @($p.Value.rows)) { if (-not $rowOwner.ContainsKey($r)) { $rowOwner[$r] = $p.Name } }
    }

    # --- 1. 放开：补丁里当前被禁、但本模式不该禁的行 ---
    #   先整表扫描收集（不能在改数组的同时按索引遍历，否则会漏）。
    $toEnable = New-StringList
    $disabledNow = New-StringList
    for ($i = 0; $i -lt $patchLines.Count - 1; $i++) {
        $m0 = [regex]::Match($patchLines[$i], '^- id:\s*(\S+)\s*$')
        if ($m0.Success -and $patchLines[$i + 1] -match '^\s+disabled:\s*true\s*$') {
            [void]$disabledNow.Add($m0.Groups[1].Value)
        }
    }
    foreach ($rid in $disabledNow) {
        $owner = if ($rowOwner.ContainsKey($rid)) { $rowOwner[$rid] } else { $null }
        if (-not $owner) { continue }                       # 不认识的行走开，别乱动
        if ($owner -match $script:ProtectedRowPattern) { continue }
        if ($desiredDisabled -notcontains $owner) {
            if (-not $toEnable.Contains($owner)) { [void]$toEnable.Add($owner) }
        }
    }
    foreach ($rid in $disabledNow) {
        $owner = if ($rowOwner.ContainsKey($rid)) { $rowOwner[$rid] } else { $null }
        if (-not $owner) { continue }
        if ($owner -match $script:ProtectedRowPattern) { continue }
        if ($desiredDisabled -notcontains $owner) {
            $patchLines = Clear-RowDisabled -Lines $patchLines -RowId $rid
        }
    }

    # --- 2. 关闭本模式要关的行 ---
    foreach ($r in $calc.Rows) { $patchLines = Set-RowDisabled -Lines $patchLines -RowId $r }

    # --- 3. bundle 级插件：声明式处理，幂等 ---
    #   requireBundles = 这个模式下必须在 bundles 里的包（缺了就补回）
    #   removeBundles  = 这个模式下必须不在 bundles 里的包（在就摘掉）
    #   两者都不写就不动 package.json —— 绝大多数插件靠补丁行就能开关。
    $currentBundles = Get-BundleNames -Lines $pkgLines
    $bundleRemoved = New-StringList

    foreach ($pkg in @($mode.requireBundles | Where-Object { $_ })) {
        if (-not ($Catalog.packages.PSObject.Properties.Name -contains $pkg)) { continue }
        if (-not ($currentBundles -contains $pkg)) {
            $pkgLines = Set-BundlePresent -Lines $pkgLines -Name $pkg -Present $true
            $currentBundles = Get-BundleNames -Lines $pkgLines
        }
    }
    foreach ($pkg in @($mode.removeBundles | Where-Object { $_ })) {
        if (-not ($Catalog.packages.PSObject.Properties.Name -contains $pkg)) { continue }
        if ($currentBundles -contains $pkg) {
            $pkgLines = Set-BundlePresent -Lines $pkgLines -Name $pkg -Present $false
            $currentBundles = Get-BundleNames -Lines $pkgLines
        }
        if (-not $bundleRemoved.Contains($pkg)) { [void]$bundleRemoved.Add($pkg) }
    }

    $newPatch = ($patchLines -join "`n")
    $newPkg   = ($pkgLines -join "`n")

    $changed = @()
    if ($newPatch -ne $origPatch) {
        Backup-File $script:PatchPath
        Write-Utf8Atomic $script:PatchPath $newPatch
        $changed += 'cordis.patch.yml'
    }
    if ($newPkg -ne $origPkg) {
        Backup-File $script:Manifest
        Write-Utf8Atomic $script:Manifest $newPkg
        $changed += 'package.json'
    }

    # --- 4. 同步 dshmarket 的 disabled 列表 ---
    $marketChanged = $false
    foreach ($pkg in $toEnable) { if (Remove-MarketDisabled $pkg) { $marketChanged = $true } }
    foreach ($pkg in $desiredDisabled) {
        if ($Catalog.packages.PSObject.Properties.Name -contains $pkg) {
            if (Add-MarketDisabled $pkg) { $marketChanged = $true }
        }
    }
    if ($marketChanged) { $changed += '.dsh-market\state.json' }

    # --- 5. 自检 ---
    $verify = $newPatch -split "`n"
    $missing = @()
    foreach ($id in $calc.Rows) {
        $ok = $false
        for ($i = 0; $i -lt $verify.Count - 1; $i++) {
            if ($verify[$i] -match '^- id:\s*(\S+)\s*$' -and $Matches[1] -eq $id -and
                $verify[$i + 1] -match '^\s+disabled:\s*true\s*$') { $ok = $true; break }
        }
        if (-not $ok) { $missing += $id }
    }
    if ($missing.Count -gt 0) { Write-DshLog $ModeId ("自检失败，未禁用：" + ($missing -join ', ')) }
    else { Write-DshLog $ModeId '自检通过' }

    if ($changed.Count -eq 0) { Write-DshLog $ModeId '文件已是目标状态，无需改写' }
    else { Write-DshLog $ModeId ('已改写：' + ($changed -join '、')) }

    # --- 6. 落状态 + 更新 active ---
    $newState = [pscustomobject]@{
        activeMode       = $ModeId
        disabledPackages = @($desiredDisabled)
        bundlesRemoved   = @($bundleRemoved.ToArray())
        appliedAt        = (Get-Date).ToString('s')
    }
    Save-ModeState $newState

    $cfg.active = $ModeId
    Save-ModeConfig $cfg

    return [pscustomobject]@{
        Changed = $changed
        Mode    = $mode
        Skipped = $calc.Skipped
        Rows    = $calc.Rows
    }
}

# ---------------------------------------------------------------------------
# 拉起 / 唤起主程序
# ---------------------------------------------------------------------------
function Start-DshApp {
    if ($script:ExePath -and (Test-Path -LiteralPath $script:ExePath)) {
        Start-Process -FilePath $script:ExePath -WorkingDirectory (Split-Path -Parent $script:ExePath)
        return $true
    }
    throw "找不到 $($script:AppName) 主程序。请在 dsh-mode.config.psd1 里设置 ExePath，或设置环境变量 DSH_EXE。"
}

function Test-DshRunning {
    try { return [bool](Get-Process -Name $script:AppName -ErrorAction SilentlyContinue) } catch { return $false }
}
