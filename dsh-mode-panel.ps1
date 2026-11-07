# ---------------------------------------------------------------------------
# DSH 模式面板 —— 可视化挑选 / 编辑插件集
#
#   纯 WPF + PowerShell，无需任何额外依赖。
#   左侧是模式卡片（点一下切换编辑目标），右侧勾选该模式要开哪些插件。
#   改完点「应用」写回 profile；DSH 正在运行时会自动热切，不用重启。
# ---------------------------------------------------------------------------
param(
    [switch]$Apply,          # 打开面板后立刻应用当前模式（一般不用）
    [string]$Mode,           # 直接定位到某个模式
    [string]$SelfTest        # 自测：只跑逻辑不开窗（面板开发用）
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

. (Join-Path $PSScriptRoot 'dsh-modes-lib.ps1')

# ---------------------------------------------------------------------------
# 数据准备
# ---------------------------------------------------------------------------
$script:Catalog    = Get-DshCatalog
$script:Config     = Get-ModeConfig
$script:CurrentId  = if ($Mode) { $Mode } else { $script:Config.active }
$script:Suppress   = $false
$script:PkgGroup   = @{}

# 包名 -> 分组名（复用插件市场自己的分组），没归组的落到「其他」
$groups = Get-PluginGroups
foreach ($kv in $groups.GetEnumerator()) {
    foreach ($p in @($kv.Value)) { if ($p -and -not $script:PkgGroup.ContainsKey($p)) { $script:PkgGroup[$p] = $kv.Key } }
}
$groupOrder = @('股票', '日常', '常开', '微信机器人', '其他')

function Get-GroupOf([string]$pkg) {
    if ($script:PkgGroup.ContainsKey($pkg)) { return $script:PkgGroup[$pkg] }
    return '其他'
}

function New-Brush([string]$hex) {
    try { return [Windows.Media.SolidColorBrush][Windows.Media.ColorConverter]::ConvertFromString($hex) }
    catch { return [Windows.Media.SolidColorBrush][Windows.Media.ColorConverter]::ConvertFromString('#4C9AFF') }
}

$ACCENTS = @('#E5484D', '#4C9AFF', '#30A46C', '#8E4EC6', '#F5A524', '#12A594', '#E93D82', '#8A94A6')

# ---------------------------------------------------------------------------
# XAML：只搭骨架，动态内容在代码里填
# ---------------------------------------------------------------------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DSH 模式面板" Height="760" Width="1120"
        WindowStartupLocation="CenterScreen"
        Background="#10131A"
        TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="#E8ECF3"/>
      <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="#E8ECF3"/>
      <Setter Property="Background" Value="#232A3A"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#2E384C"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#3A465E"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="#E8ECF3"/>
      <Setter Property="Background" Value="#1A2030"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="CaretBrush" Value="#E8ECF3"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                            VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsFocused" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#212A3E"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Foreground" Value="#C9D2E0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="ScrollViewer">
      <Setter Property="PanningMode" Value="VerticalOnly"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- 顶栏 -->
    <Border Grid.Row="0" Background="#151A24" Padding="22,16,22,14">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
          <Border Width="30" Height="30" CornerRadius="8" Background="#1E2636" Margin="0,0,12,0">
            <UniformGrid Rows="2" Columns="2" Width="16" Height="16"
                         HorizontalAlignment="Center" VerticalAlignment="Center">
              <Border Background="#E5484D" CornerRadius="1.5" Margin="0.5"/>
              <Border Background="#4C9AFF" CornerRadius="1.5" Margin="0.5"/>
              <Border Background="#30A46C" CornerRadius="1.5" Margin="0.5"/>
              <Border Background="#8E4EC6" CornerRadius="1.5" Margin="0.5"/>
            </UniformGrid>
          </Border>
          <StackPanel>
            <TextBlock Text="DSH 模式面板" FontSize="16" FontWeight="SemiBold"/>
            <TextBlock x:Name="SubTitle" Text="" FontSize="11.5" Foreground="#7C8798" Margin="0,2,0,0"/>
          </StackPanel>
        </StackPanel>
        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnReload" Content="重新扫描插件" Margin="0,0,8,0" Background="#1E2636"/>
          <Button x:Name="BtnNew"    Content="＋ 新建模式"  Margin="0,0,8,0" Background="#1E2636"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- 主体 -->
    <Grid Grid.Row="1" Margin="18,14,18,10">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="292"/>
        <ColumnDefinition Width="16"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- 左：模式列表 -->
      <Grid Grid.Column="0">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="模式" FontSize="12" Foreground="#7C8798" Margin="4,0,0,8"/>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="ModeList"/>
        </ScrollViewer>
      </Grid>

      <!-- 右：编辑区 -->
      <Border Grid.Column="2" Background="#141922" CornerRadius="10" Padding="20,18">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <!-- 名称行 -->
          <Grid Grid.Row="0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="TxtName" Grid.Column="0" Width="200" FontSize="15" FontWeight="SemiBold"/>
            <TextBlock Grid.Column="2" x:Name="LblActive" Text="" FontSize="12" Foreground="#30A46C"
                       VerticalAlignment="Center" Margin="12,0,0,0"/>
          </Grid>

          <!-- 说明 + 工作区 -->
          <Grid Grid.Row="1" Margin="0,10,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="12"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="TxtNote" Grid.Column="0"/>
            <TextBox x:Name="TxtWork" Grid.Column="2"/>
          </Grid>

          <!-- 颜色 + 桌面图标开关 -->
          <Grid Grid.Row="2" Margin="0,12,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0" Orientation="Horizontal">
              <TextBlock Text="标识色" FontSize="12" Foreground="#7C8798" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <StackPanel x:Name="Swatches" Orientation="Horizontal"/>
            </StackPanel>
            <CheckBox Grid.Column="1" x:Name="ChkPin" Content="在桌面放图标"
                      FontSize="12" Foreground="#AEB8C8" VerticalAlignment="Center"/>
          </Grid>

          <!-- 插件清单 -->
          <Grid Grid.Row="3" Margin="0,14,0,0">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Grid Grid.Row="0" Margin="0,0,0,8">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" x:Name="LblCount" Text="插件" FontSize="12" Foreground="#7C8798"
                         VerticalAlignment="Center"/>
              <Button Grid.Column="1" x:Name="BtnAll"   Content="全开" Padding="10,5" FontSize="12"
                      Background="#1E2636" Margin="0,0,6,0"/>
              <Button Grid.Column="2" x:Name="BtnNone"  Content="全关" Padding="10,5" FontSize="12"
                      Background="#1E2636" Margin="0,0,6,0"/>
              <Button Grid.Column="3" x:Name="BtnInvert" Content="反选" Padding="10,5" FontSize="12"
                      Background="#1E2636"/>
            </Grid>
            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <StackPanel x:Name="PluginHost">
                <!-- 让子项按可用宽度排版，避免长描述把窗口撑开 -->
                <StackPanel.Resources>
                  <Style TargetType="CheckBox">
                    <Setter Property="HorizontalAlignment" Value="Stretch"/>
                    <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                  </Style>
                </StackPanel.Resources>
              </StackPanel>
            </ScrollViewer>
          </Grid>

          <!-- 底部按钮 -->
          <Grid Grid.Row="4" Margin="0,14,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" x:Name="Status" Text="" FontSize="12" Foreground="#7C8798"
                       VerticalAlignment="Center" TextWrapping="NoWrap"/>
            <Button Grid.Column="1" x:Name="BtnDelete" Content="删除模式" Margin="0,0,8,0"
                    Background="#2A1B20" Foreground="#FF8A94"/>
            <Button Grid.Column="2" x:Name="BtnSave" Content="保存" Margin="0,0,8,0" Background="#1E2636"/>
            <Button Grid.Column="3" x:Name="BtnApply" Content="应用并启动" Background="#E5484D"/>
          </Grid>
        </Grid>
      </Border>
    </Grid>

    <!-- 底栏 -->
    <Border Grid.Row="2" Background="#0C0F15" Padding="22,9">
      <TextBlock x:Name="Foot" Text="" FontSize="11" Foreground="#5C6678"/>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$win = [Windows.Markup.XamlReader]::Load($reader)

# 控件引用
$ui = @{}
foreach ($n in 'SubTitle', 'ModeList', 'TxtName', 'TxtNote', 'TxtWork', 'Swatches', 'PluginHost',
    'LblActive', 'LblCount', 'Status', 'Foot', 'ChkPin',
    'BtnReload', 'BtnNew', 'BtnAll', 'BtnNone', 'BtnInvert', 'BtnSave', 'BtnApply', 'BtnDelete') {
    $ui[$n] = $win.FindName($n)
}

$win.Title = 'DSH 模式面板'
$ui.SubTitle.Text = "$($script:AppName) · $($script:ProfileDir)"
$ui.Foot.Text = "补丁：$($script:PatchPath)　|　配置：$($script:ModesPath)"

# ---------------------------------------------------------------------------
# 左栏：模式卡片
# ---------------------------------------------------------------------------
function Show-ModeList {
    $ui.ModeList.Children.Clear()
    $activeId = $script:Config.active
    $i = 0
    foreach ($m in @($script:Config.modes)) {
        $i++
        $isCurrent = ($m.id -eq $script:CurrentId)
        $isActive  = ($m.id -eq $activeId)
        $accent    = if ($m.color) { $m.color } else { '#4C9AFF' }

        $border = New-Object System.Windows.Controls.Border
        $border.CornerRadius = '8'
        $border.Padding = '12,10'
        $border.Margin = '0,0,0,8'
        $border.Background = New-Brush $(if ($isCurrent) { '#212A3E' } else { '#171D29' })
        $border.BorderThickness = $(if ($isCurrent) { '1' } else { '0' })
        $border.BorderBrush = New-Brush $accent
        $border.Cursor = [System.Windows.Input.Cursors]::Hand
        $border.Tag = $m.id

        $grid = New-Object System.Windows.Controls.Grid
        $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = 'Auto'
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = '*'
        [void]$grid.ColumnDefinitions.Add($c0)
        [void]$grid.ColumnDefinitions.Add($c1)

        $bar = New-Object System.Windows.Controls.Border
        $bar.Width = '5'; $bar.CornerRadius = '2.5'
        $bar.Background = New-Brush $accent
        $bar.Margin = '0,1,12,1'
        [System.Windows.Controls.Grid]::SetColumn($bar, 0)
        [void]$grid.Children.Add($bar)

        $sp = New-Object System.Windows.Controls.StackPanel
        [System.Windows.Controls.Grid]::SetColumn($sp, 1)

        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = $m.name; $t.FontSize = '14'; $t.FontWeight = 'SemiBold'
        $t.Foreground = New-Brush '#E8ECF3'
        [void]$row.Children.Add($t)
        if ($isActive) {
            $b = New-Object System.Windows.Controls.TextBlock
            $b.Text = '当前'; $b.FontSize = '10.5'; $b.Margin = '8,2,0,0'
            $b.Foreground = New-Brush '#30A46C'
            [void]$row.Children.Add($b)
        }
        [void]$sp.Children.Add($row)

        $d = New-Object System.Windows.Controls.TextBlock
        $d.Text = $m.note; $d.FontSize = '11.5'; $d.Margin = '0,3,0,0'
        $d.Foreground = New-Brush '#7C8798'
        $d.TextTrimming = 'CharacterEllipsis'
        [void]$sp.Children.Add($d)

        $n = @($m.disabled | Where-Object { $_ }).Count
        $total = @($script:Catalog.packages.PSObject.Properties).Count
        $c = New-Object System.Windows.Controls.TextBlock
        $c.Text = ("关掉 {0} 个插件" -f $n) + $(if ($m.pin) { '　·　桌面有图标' } else { '' })
        $c.FontSize = '10.5'; $c.Margin = '0,4,0,0'
        $c.Foreground = New-Brush '#5C6678'
        [void]$sp.Children.Add($c)

        [void]$grid.Children.Add($sp)
        $border.Child = $grid
        $border.Add_MouseLeftButtonUp({
            param($s, $e)
            Select-Mode ([string]$s.Tag)
        }.GetNewClosure())
        [void]$ui.ModeList.Children.Add($border)
    }
}

# ---------------------------------------------------------------------------
# 右栏：编辑区
# ---------------------------------------------------------------------------
function Get-CurrentMode {
    return (@($script:Config.modes | Where-Object { $_.id -eq $script:CurrentId }) | Select-Object -First 1)
}

function Select-Mode([string]$id) {
    if (-not $id) { return }
    $script:CurrentId = $id
    Show-ModeList
    Show-Editor
}

function Show-Swatches([string]$selected) {
    $ui.Swatches.Children.Clear()
    foreach ($c in $ACCENTS) {
        $bd = New-Object System.Windows.Controls.Border
        $bd.Width = '22'; $bd.Height = '22'; $bd.CornerRadius = '11'
        $bd.Margin = '0,0,8,0'
        $bd.Background = New-Brush $c
        $bd.Cursor = [System.Windows.Input.Cursors]::Hand
        $bd.Tag = $c
        if ($c -eq $selected) { $bd.BorderThickness = '2'; $bd.BorderBrush = New-Brush '#FFFFFF' }
        $bd.Add_MouseLeftButtonUp({
            param($s, $e)
            $m = Get-CurrentMode
            $m.color = $s.Tag
            Show-Swatches $m.color
            Show-ModeList
        }.GetNewClosure())
        [void]$ui.Swatches.Children.Add($bd)
    }
}

function Show-Editor {
    $m = Get-CurrentMode
    if (-not $m) { return }
    $script:Suppress = $true

    $ui.TxtName.Text = $m.name
    $ui.TxtNote.Text = $m.note
    $ui.TxtWork.Text = $m.workspace
    $ui.LblActive.Text = $(if ($m.id -eq $script:Config.active) { '● 当前生效' } else { '' })
    $ui.ChkPin.IsChecked = [bool]$m.pin
    Show-Swatches $m.color

    $disabled = @($m.disabled | Where-Object { $_ })
    # 自动纳入的插件：勾选状态以外，还要在界面上标出来，否则用户看不出"为什么它被关了"。
    $autoPkgs = @(Get-ModeAutoPackages -Mode $m -Catalog $script:Catalog)
    $script:AutoNow = $autoPkgs
    $ui.PluginHost.Children.Clear()

    # 按分组渲染
    $byGroup = @{}
    foreach ($p in $script:Catalog.packages.PSObject.Properties) {
        $g = Get-GroupOf $p.Name
        if (-not $byGroup.ContainsKey($g)) { $byGroup[$g] = New-Object System.Collections.Generic.List[string] }
        $byGroup[$g].Add($p.Name)
    }
    $order = @()
    foreach ($g in $groupOrder) { if ($byGroup.ContainsKey($g)) { $order += $g } }
    foreach ($g in $byGroup.Keys) { if ($order -notcontains $g) { $order += $g } }

    $totalOn = 0
    $totalAll = 0
    foreach ($g in $order) {
        $names = @($byGroup[$g] | Sort-Object)
        $head = New-Object System.Windows.Controls.TextBlock
        $head.Text = ("{0}　·　{1}" -f $g, $names.Count)
        $head.FontSize = '12'; $head.FontWeight = 'SemiBold'
        $head.Foreground = New-Brush '#8A94A6'
        $head.Margin = '0,12,0,6'
        [void]$ui.PluginHost.Children.Add($head)

        $wrap = New-Object System.Windows.Controls.StackPanel
        foreach ($pkg in $names) {
            $totalAll++
            $isAuto = ($autoPkgs -contains $pkg)
            $on = ($disabled -notcontains $pkg) -and -not $isAuto
            if ($on) { $totalOn++ }
            $desc = ''
            try { $desc = [string]$script:Catalog.packages.$pkg.description } catch { }
            $ver = ''
            try { $ver = [string]$script:Catalog.packages.$pkg.version } catch { }

            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Tag = $pkg
            $cb.IsChecked = $on
            $cb.Margin = '0,5,0,5'
            $cb.HorizontalContentAlignment = 'Stretch'
            $cb.ToolTip = ("{0}`n包名：{1}`n版本：{2}" -f $desc, $pkg, $ver)

            # 用 Grid 而不是横向 StackPanel：StackPanel 会给子元素无限宽，长描述就会顶出窗口。
            $line = New-Object System.Windows.Controls.Grid
            $c0 = New-Object System.Windows.Controls.ColumnDefinition
            $c0.Width = 'Auto'
            $c1 = New-Object System.Windows.Controls.ColumnDefinition
            $c1.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
            [void]$line.ColumnDefinitions.Add($c0)
            [void]$line.ColumnDefinitions.Add($c1)

            $nm = New-Object System.Windows.Controls.TextBlock
            $nm.Text = $(if ($isAuto) { "$pkg　自动" } else { $pkg })
            $nm.FontSize = '12.5'
            $nm.VerticalAlignment = 'Center'
            if ($isAuto) { $nm.Foreground = New-Brush '#F5A524' }
            [System.Windows.Controls.Grid]::SetColumn($nm, 0)
            [void]$line.Children.Add($nm)

            if ($desc) {
                if ($desc.Length -gt 62) { $desc = $desc.Substring(0, 62) + '…' }
                $dm = New-Object System.Windows.Controls.TextBlock
                $dm.Text = $desc
                $dm.FontSize = '11'
                $dm.Margin = '6,0,0,0'
                $dm.VerticalAlignment = 'Center'
                $dm.Foreground = New-Brush '#5C6678'
                $dm.TextTrimming = 'CharacterEllipsis'
                $dm.TextWrapping = 'NoWrap'
                [System.Windows.Controls.Grid]::SetColumn($dm, 1)
                [void]$line.Children.Add($dm)
            }
            $cb.Content = $line
            [void]$wrap.Children.Add($cb)
        }
        [void]$ui.PluginHost.Children.Add($wrap)
    }

    $ui.LblCount.Text = ("插件　·　已开 {0} / 共 {1}" -f $totalOn, $totalAll)
    $script:Suppress = $false
}

# ---------------------------------------------------------------------------
# 把右栏的编辑结果写回内存里的模式对象
# ---------------------------------------------------------------------------
function Read-Editor {
    $m = Get-CurrentMode
    if (-not $m) { return }
    $m.name = $ui.TxtName.Text.Trim()
    $m.note = $ui.TxtNote.Text.Trim()
    $m.workspace = $ui.TxtWork.Text.Trim()
    $m.pin = ($ui.ChkPin.IsChecked -eq $true)
    $off = @()
    $autoNow = @($script:AutoNow)
    $except = New-Object System.Collections.Generic.List[string]
    foreach ($x in @($m.autoExcept | Where-Object { $_ })) { [void]$except.Add($x) }

    foreach ($wrap in $ui.PluginHost.Children) {
        if ($wrap -isnot [System.Windows.Controls.Panel]) { continue }
        foreach ($cb in $wrap.Children) {
            $pkg = [string]$cb.Tag
            $checked = ($cb.IsChecked -eq $true)
            if ($autoNow -contains $pkg) {
                # 自动纳入的包：勾上 = 明确要开（记进 autoExcept 抵消规则），不勾 = 交给规则管
                if ($checked -and -not $except.Contains($pkg)) { [void]$except.Add($pkg) }
                elseif (-not $checked) { [void]$except.Remove($pkg) }
                continue
            }
            if (-not $checked) { $off += $pkg }
        }
    }
    $m.disabled = @($off)
    $m.autoExcept = @($except.ToArray())
}

function Set-Status([string]$text, [string]$color = '#7C8798') {
    $ui.Status.Text = $text
    $ui.Status.Foreground = New-Brush $color
}

# PS 5.1 的坑：在 .GetNewClosure() 的代码块里写 $script:X = ... 只会改到闭包自己的私有
# 作用域，文件级变量毫无变化，且不报错。所以事件处理器一律走下面这几个 setter，
# 别在闭包体内直接给 $script: 变量赋值。
function Set-PanelConfig { param($Config) $script:Config = $Config }
function Set-PanelCurrent { param([string]$Id) $script:CurrentId = $Id }
function Set-PanelCatalog { param($Catalog) $script:Catalog = $Catalog }

# ---------------------------------------------------------------------------
# 按钮事件
# ---------------------------------------------------------------------------
$ui.BtnAll.Add_Click({
    foreach ($wrap in $ui.PluginHost.Children) {
        if ($wrap -is [System.Windows.Controls.Panel]) {
            foreach ($cb in $wrap.Children) { $cb.IsChecked = $true }
        }
    }
    Set-Status '已全开（记得点保存或应用）' '#30A46C'
}.GetNewClosure())

$ui.BtnNone.Add_Click({
    foreach ($wrap in $ui.PluginHost.Children) {
        if ($wrap -is [System.Windows.Controls.Panel]) {
            foreach ($cb in $wrap.Children) { $cb.IsChecked = $false }
        }
    }
    Set-Status '已全关（记得点保存或应用）' '#E5484D'
}.GetNewClosure())

$ui.BtnInvert.Add_Click({
    foreach ($wrap in $ui.PluginHost.Children) {
        if ($wrap -is [System.Windows.Controls.Panel]) {
            foreach ($cb in $wrap.Children) { $cb.IsChecked = ($cb.IsChecked -ne $true) }
        }
    }
    Set-Status '已反选' '#F5A524'
}.GetNewClosure())

$ui.BtnSave.Add_Click({
    try {
        Read-Editor
        Save-ModeConfig $script:Config
        Set-PanelConfig (Get-ModeConfig)
        $sync = Sync-DesktopShortcuts -Config $script:Config
        Show-ModeList
        Show-Editor
        $msg = '已保存到 modes.json　' + (Get-Date -Format 'HH:mm:ss')
        if ($sync.Created.Count -gt 0) { $msg += "　桌面图标 $($sync.Created.Count) 个" }
        if ($sync.Removed.Count -gt 0) { $msg += "　清理 $($sync.Removed.Count) 个" }
        Set-Status $msg '#30A46C'
    }
    catch { Set-Status ('保存失败：' + $_.Exception.Message) '#E5484D' }
}.GetNewClosure())

$ui.BtnApply.Add_Click({
    try {
        Read-Editor
        Save-ModeConfig $script:Config
        Set-PanelConfig (Get-ModeConfig)
        Set-Status '正在应用…' '#F5A524'
        $ui.BtnApply.IsEnabled = $false
        $res = Apply-DshMode -ModeId $script:CurrentId -Catalog $script:Catalog
        $sync = Sync-DesktopShortcuts -Config $script:Config
        $null = Start-DshApp
        Set-PanelConfig (Get-ModeConfig)
        Show-ModeList
        Show-Editor
        Set-Status ('已应用「{0}」，DSH 会热切生效' -f $res.Mode.name) '#30A46C'
        try { Show-Toast ('DSH · ' + $res.Mode.name) ('已应用：' + $res.Mode.note) } catch { }
    }
    catch { Set-Status ('应用失败：' + $_.Exception.Message) '#E5484D' }
    finally { $ui.BtnApply.IsEnabled = $true }
}.GetNewClosure())

$ui.BtnNew.Add_Click({
    try {
        $dlg = New-Object System.Windows.Window
        $dlg.Title = '新建模式'
        $dlg.Width = 380; $dlg.Height = 200
        $dlg.WindowStartupLocation = 'CenterOwner'
        $dlg.Background = New-Brush '#141922'
        $dlg.Owner = $win
        $dlg.ResizeMode = 'NoResize'

        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Margin = '20'
        $lb = New-Object System.Windows.Controls.TextBlock
        $lb.Text = '模式名称（例如：写作、复盘、面试准备）'
        $lb.FontSize = '12'; $lb.Foreground = New-Brush '#8A94A6'
        [void]$sp.Children.Add($lb)
        $tb = New-Object System.Windows.Controls.TextBox
        $tb.Margin = '0,8,0,0'
        $tb.Background = New-Brush '#1A2030'
        $tb.Foreground = New-Brush '#E8ECF3'
        $tb.Padding = '8,6'
        $tb.BorderThickness = '0'
        [void]$sp.Children.Add($tb)
        $hint = New-Object System.Windows.Controls.TextBlock
        $hint.Text = '新模式的插件默认全开，创建后在右侧自行取消勾选。'
        $hint.FontSize = '11'; $hint.Foreground = New-Brush '#5C6678'
        $hint.Margin = '0,10,0,0'; $hint.TextWrapping = 'Wrap'
        [void]$sp.Children.Add($hint)
        $btns = New-Object System.Windows.Controls.StackPanel
        $btns.Orientation = 'Horizontal'; $btns.HorizontalAlignment = 'Right'
        $btns.Margin = '0,14,0,0'
        $ok = New-Object System.Windows.Controls.Button
        $ok.Content = '创建'; $ok.Padding = '16,6'; $ok.Margin = '0,0,8,0'
        $ok.Background = New-Brush '#E5484D'; $ok.Foreground = New-Brush '#FFFFFF'
        $ok.BorderThickness = '0'
        $cancel = New-Object System.Windows.Controls.Button
        $cancel.Content = '取消'; $cancel.Padding = '16,6'
        $cancel.Background = New-Brush '#232A3A'; $cancel.Foreground = New-Brush '#E8ECF3'
        $cancel.BorderThickness = '0'
        [void]$btns.Children.Add($ok)
        [void]$btns.Children.Add($cancel)
        [void]$sp.Children.Add($btns)
        $dlg.Content = $sp

        # 用 hashtable 当容器接收输入：闭包写不了 $script: 变量，但能改对象的属性。
        $box = @{ name = '' }
        $dialog = $dlg
        $ok.Add_Click({
            $box.name = $tb.Text
            $dialog.Close()
        }.GetNewClosure())
        $cancel.Add_Click({ $dialog.Close() }.GetNewClosure())
        $tb.Add_KeyDown({
            param($s, $e)
            if ($e.Key -eq 'Enter') { $box.name = $tb.Text; $dialog.Close() }
        }.GetNewClosure())
        $tb.Add_Loaded({ param($s, $e) $s.Focus() | Out-Null }.GetNewClosure())
        $null = $dlg.ShowDialog()

        $name = (($box.name + '') -replace '\s+', ' ').Trim()
        if (-not $name) { Set-Status '已取消' '#7C8798'; return }
        $pick = $ACCENTS[(@($script:Config.modes).Count) % $ACCENTS.Count]
        $m = Add-ModeToConfig -Config $script:Config -Name $name -Color $pick -Workspace '' -Note '' -Disabled @()
        Save-ModeConfig $script:Config
        Set-PanelConfig (Get-ModeConfig)
        Set-PanelCurrent $m.id
        Show-ModeList
        Show-Editor
        Set-Status ('已新建「{0}」，勾掉不要的插件后点保存' -f $name) '#30A46C'
    }
    catch { Set-Status ('新建失败：' + $_.Exception.Message) '#E5484D' }
}.GetNewClosure())

$ui.BtnDelete.Add_Click({
    try {
        $m = Get-CurrentMode
        if (@($script:Config.modes).Count -le 1) { Set-Status '至少要保留一个模式' '#E5484D'; return }
        $ans = [System.Windows.MessageBox]::Show(
            ("确定删除模式「{0}」？`n（只删配置，不会改动已应用的插件状态）" -f $m.name),
            '删除模式', 'YesNo', 'Question')
        if ($ans -ne 'Yes') { return }
        $null = Remove-ModeFromConfig -Config $script:Config -Id $m.id
        Save-ModeConfig $script:Config
        Set-PanelConfig (Get-ModeConfig)
        Set-PanelCurrent $script:Config.modes[0].id
        Show-ModeList
        Show-Editor
        Set-Status ('已删除「{0}」' -f $m.name) '#F5A524'
    }
    catch { Set-Status ('删除失败：' + $_.Exception.Message) '#E5484D' }
}.GetNewClosure())

$ui.BtnReload.Add_Click({
    try {
        Set-PanelCatalog (Get-DshCatalog -Refresh)
        Show-ModeList
        Show-Editor
        Set-Status ('已重新扫描：{0} 个插件包' -f @($script:Catalog.packages.PSObject.Properties).Count) '#30A46C'
    }
    catch { Set-Status ('扫描失败：' + $_.Exception.Message) '#E5484D' }
}.GetNewClosure())

$win.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Escape') { $s.Close() }
    if ($e.Key -eq 'S' -and $e.KeyboardDevice.Modifiers -eq 'Control') { $ui.BtnSave.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent))) }
}.GetNewClosure())

# 首次渲染
Show-ModeList
Show-Editor

if ($Apply) {
    try {
        $res = Apply-DshMode -ModeId $script:CurrentId -Catalog $script:Catalog
        Set-Status ('已应用「{0}」' -f $res.Mode.name) '#30A46C'
    }
    catch { Set-Status ('应用失败：' + $_.Exception.Message) '#E5484D' }
}

# ---------------------------------------------------------------------------
# 自测：不开窗，直接验证「选模式 → 读编辑区 → 保存 → 应用」整条链路
# ---------------------------------------------------------------------------
if ($SelfTest) {
    $ok = $true
    $log = New-Object System.Collections.Generic.List[string]

    Select-Mode $SelfTest
    $m = Get-CurrentMode
    if (-not $m) { $log.Add("FAIL: 找不到模式 $SelfTest"); $ok = $false }
    else {
        $log.Add(("模式={0} 名称='{1}' 工作区='{2}'" -f $m.id, $ui.TxtName.Text, $ui.TxtWork.Text))
        $boxes = 0; $on = 0
        foreach ($wrap in $ui.PluginHost.Children) {
            if ($wrap -isnot [System.Windows.Controls.Panel]) { continue }
            foreach ($cb in $wrap.Children) {
                $boxes++
                if ($cb.IsChecked -eq $true) { $on++ }
            }
        }
        $log.Add(("复选框 {0} 个，勾选 {1} 个" -f $boxes, $on))

        # 读回编辑区 → 应与配置一致
        Read-Editor
        $after = Get-CurrentMode
        $log.Add(("读回 disabled 数={0}" -f @($after.disabled).Count))
        if (@($after.disabled).Count -ne @($m.disabled | Where-Object { $_ }).Count) {
            $log.Add('WARN: 读回的禁用数与配置不一致')
        }

        # 全关 → 所有「非自动」包都进 disabled；自动纳入的包由规则接管，不写进白名单。
        # 但它们会被记进 autoExcept 的反面（不勾 = 交给规则），所以这里只校验非自动包。
        $autoCount = @($script:AutoNow).Count
        foreach ($wrap in $ui.PluginHost.Children) {
            if ($wrap -is [System.Windows.Controls.Panel]) { foreach ($cb in $wrap.Children) { $cb.IsChecked = $false } }
        }
        Read-Editor
        $allOff = @((Get-CurrentMode).disabled).Count
        $log.Add(("全关后 disabled 数={0}（非自动包 {1} 个，自动 {2} 个）" -f $allOff, ($boxes - $autoCount), $autoCount))
        if ($allOff -ne ($boxes - $autoCount)) { $log.Add('FAIL: 全关数量不符'); $ok = $false }

        # 全开 → 0（自动包被勾上时会进 autoExcept 抵消规则，所以 disabled 也应为 0）
        foreach ($wrap in $ui.PluginHost.Children) {
            if ($wrap -is [System.Windows.Controls.Panel]) { foreach ($cb in $wrap.Children) { $cb.IsChecked = $true } }
        }
        Read-Editor
        $allOn = @((Get-CurrentMode).disabled).Count
        $log.Add(("全开后 disabled 数={0}" -f $allOn))
        if ($allOn -ne 0) { $log.Add('FAIL: 全开后应为 0'); $ok = $false }
    }

    # 应用（不启动）
    try {
        $res = Apply-DshMode -ModeId $SelfTest -Catalog $script:Catalog
        $log.Add(("应用 OK：{0}，禁用行 {1} 个，跳过 {2} 个" -f $res.Mode.name, @($res.Rows).Count, @($res.Skipped).Count))
    }
    catch { $log.Add('FAIL apply: ' + $_.Exception.Message); $ok = $false }

    $log | ForEach-Object { $_ }
    if ($ok) { 'SELFTEST OK' } else { 'SELFTEST FAILED' }
    exit $(if ($ok) { 0 } else { 1 })
}

[void]$win.ShowDialog()
