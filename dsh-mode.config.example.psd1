@{
    # ---------------------------------------------------------------------
    # DSH 双模式启动器 —— 可选配置
    #
    # 把本文件复制一份、改名为 dsh-mode.config.psd1 就会生效。
    # 不建这个文件也能用：脚本会自动探测主程序位置。
    # ---------------------------------------------------------------------

    # DSH 主程序路径。留空 / 删掉这一行 = 自动探测。
    # 自动探测顺序：运行中的同名进程 → 桌面与开始菜单里的快捷方式。
    # ExePath = 'D:\deepseek\DeepSeek Harness.exe'

    # 主程序进程名（不含 .exe），用于探测运行中的程序。
    # AppName = 'DeepSeek Harness'

    # DSH_HOME。留空 = 环境变量 DSH_HOME，再没有就用 %USERPROFILE%\.dsh。
    # DshHome = 'C:\Users\you\.dsh'

    # profile 名。桌面版固定是 desktop，一般不用改。
    # ProfileName = 'desktop'

    # 切换完成后是否弹系统通知（toast）。不想要就设 $false。
    # Toast = $true
}
