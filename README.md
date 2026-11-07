<#
  DSH 模式启动器 —— 使用说明
#>

# DSH 双模式启动器

桌面上两个图标：一个打开 DSH 时启用全部股票插件，另一个关闭全部股票插件（学习模式）。
**不用关程序、不用重开**，随时互切，约 1 秒生效。

![股票模式](icons/preview-stock-256.png)
![学习模式](icons/preview-study-256.png)

## 这是解决什么问题的

DSH 桌面版只能跑 `profiles\desktop` 这一个 profile，启动参数里塞不进「模式」。
如果你的 profile 装了一堆股票插件，写代码或学东西时它们全都在线，会一直占着侧边栏、往工具列表里塞一堆用不到的东西。

这个项目用一条很窄的路子解决：**先改 profile 的插件清单，再把程序拉起或唤起**。
因为 DSH 的 `dsh-hmr` 在 watch 那几个文件，改完大约 1 秒内自动重新组合插件树——所以这不是「先改配置再重启」，是**热切**。

## 三个入口怎么配合

| 图标 | 做什么 |
| --- | --- |
| **DSH 股票** | 股票插件全部启用 |
| **DSH 学习** | 股票插件全部关闭，其余插件照常 |
| **DeepSeek Harness**（原来那个） | 保持原样，当「全部开」的第三入口 |

DSH 是单实例的：第二次点图标不会开新窗口，只会把已有窗口叫到前面，同时把插件集换成对应模式。

## 安装

需要：Windows、Windows PowerShell 5.1（系统自带）、DSH 桌面版装过并且至少启动过一次。

```powershell
git clone https://github.com/cuteFxt/dsh-mode-launcher.git
cd dsh-mode-launcher
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

它只做两件事：检查环境，在桌面创建两个快捷方式。不改系统别的地方。

先看看环境检查结果、不建图标：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -CheckOnly
```

删掉快捷方式：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

## 主程序位置

脚本**自动探测** DSH 在哪，顺序是：

1. `dsh-mode.config.psd1` 里的 `ExePath`
2. 环境变量 `DSH_EXE`
3. 正在运行的 `DeepSeek Harness` 进程
4. 桌面 / 开始菜单里名字含 `DeepSeek Harness` 的快捷方式

都找不到时，复制 `dsh-mode.config.example.psd1` 为 `dsh-mode.config.psd1`，把 `ExePath` 填上即可。

## 文件说明

```
.
├─ install.ps1                    安装 / 卸载快捷方式，附带环境检查
├─ dsh-mode.vbs                   入口（wscript 调用，保证不闪黑框）
├─ dsh-mode.ps1                   真正的切换逻辑
├─ make-icons.ps1                 图标生成脚本（想改配色改这个再跑一遍）
├─ dsh-mode.config.example.psd1   可选配置模板
└─ icons\
   ├─ dsh-stock.ico               股票图标（16/24/32/48/64/128/256 七种尺寸）
   ├─ dsh-study.ico               学习图标
   └─ preview-*.png               预览图
```

## 它到底改了什么

改动三处，都是原子写入（临时文件 + 改名），改前自动备份成 `.bak-时间戳`，只留最近 8 份。

### 1. `cordis.patch.yml`

- 学习模式：给 7 个股票行加 `disabled: true`
- 股票模式：把这些块删掉（= 恢复默认启用）

涉及的 7 个行 id：

```
dsh-plugin-stock-x
dsh-stock-jt
live-data
astock-research
stock-analysis
ths-holdings
ths-holdings-skill
```

> 注意后两个。`ths-holdings` 和 `ths-holdings-skill` 原本不在这个文件里，
> 是 `dsh-ths-holdings` 包自带的 `- insert:` 拉起来的，脚本会新增这两块。
>
> 这也说明一件事：**改 patch 必须用「行 id」而不是「包名」**，两者经常不一样
> （比如包 `dsh-stock-analysis` 的行 id 是 `stock-analysis`）。

### 2. `package.json` 的 `dsh.profile.bundles`

- 学习模式：摘掉 `dsh-ths-holdings`
- 股票模式：加回去（还原到末尾原位）

> 这步不能省。只写 `disabled` 行的话，bundle 自带的 insert 会把它重新装回来。

### 3. `.dsh-market\state.json`

同步维护插件市场的「已禁用」列表，免得面板显示与实际不一致。
这个文件的键是**包名**（又和 patch 的行 id 不一样），两边各自维护。

写入铁律：**UTF-8 无 BOM + LF**。用 PowerShell 的 `Set-Content` 会写 BOM 和 CRLF，DSH 那边可能读不对，所以脚本里全是 `[System.IO.File]::WriteAllText` + `UTF8Encoding($false)`。

## 为什么不用重启

DSH 的 `dsh-hmr` 服务在 watch `cordis.patch.yml` 和 `package.json`，每 500ms 轮询一次文件内容，变了就重新组合插件树。失败只 warn，不会让 Host 崩。

实测（切到学习模式后立刻查询）：股票查询工具从工具列表里消失，`ths-portfolio-report` 技能也一起消失；切回来又都回来。**全程进程没重启过**，7 个进程的 StartTime 一直没变。

## 已知限制

**工作区不会自动切。** 活动工作区存在渲染进程的 selection store 里，后端 `storages\` 目录下没有对应的域，外部脚本没法指定。
点完图标后工作区还是上次那个，需要手动切一下。

如果以后 DSH 支持了 `--workspace` 之类的启动参数，改 `dsh-mode.ps1` 里 `Start-Process` 那一行就行。

**「学习模式」目前是纯减法。** 它只做「关掉股票插件」，并不会主动开启什么学习专用插件——因为 profile 里目前一个学习专用插件都没有。
以后装了（假设行 id 是 `some-study-plugin`），在 `dsh-mode.ps1` 里新建一个 `$StudyOnlyRows` 列表，在 study 分支 `Clear-RowDisabled`、stock 分支 `Set-RowDisabled` 即可。设计稿里已经预留了位置。

## 故障排查

看脚本目录下的 `dsh-mode.log`，每次运行追加一段：

```
[2026-11-07 10:31:33] [stock] ==== 开始切换 (NoLaunch=False) ====
[2026-11-07 10:31:33] [stock] 打开股票插件
[2026-11-07 10:31:33] [stock] 自检通过
[2026-11-07 10:31:33] [stock] 已改写：cordis.patch.yml、package.json、.dsh-market\state.json
[2026-11-07 10:31:33] [stock] 已拉起 / 唤起：D:\deepseek\DeepSeek Harness.exe
[2026-11-07 10:31:33] [stock] ==== 完成 ====
```

只改文件、不启动程序（适合验证）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\dsh-mode.ps1 -Mode study -NoLaunch
```

从备份恢复：

```powershell
$dir = Join-Path $env:USERPROFILE '.dsh\profiles\desktop'
Get-ChildItem $dir -Filter 'cordis.patch.yml.bak-*' | Sort-Object Name -Descending | Select-Object -First 5
Copy-Item "$dir\cordis.patch.yml.bak-20261107-103133" "$dir\cordis.patch.yml" -Force
```

### 点图标没反应

脚本用 `wscript` 静默跑，出错不弹窗，只会写日志。先看 `dsh-mode.log` 最后几行。

### 中文日志乱码

`dsh-mode.ps1` 必须存成 **UTF-8 带 BOM**。Windows PowerShell 5.1 读无 BOM 的 UTF-8 会按 GBK 解码。
`install.ps1` 会检查这一点并提醒。

## 自定义

改图标配色：编辑 `make-icons.ps1` 顶部的颜色常量，然后

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\make-icons.ps1
```

它会重画 7 种尺寸并打包成 ICO，同时在 `icons\` 下留预览 PNG。

图标是纯 GDI+ 画的（4 倍超采样再缩），不依赖 ImageMagick 或任何第三方库。

## License

MIT
