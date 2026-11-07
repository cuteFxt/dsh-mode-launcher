' DSH 模式面板 shim —— 无黑框拉起 dsh-mode-panel.ps1
'
' 面板是 WPF 窗口，本身不闪控制台；但用 wscript 调起仍然更干净
' （不会在任务栏留下一个 powershell 控制台图标）。
'
' Usage: wscript.exe "dsh-mode-panel.vbs"

Option Explicit

Dim shell, fso, scriptDir, cmd

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)

cmd = "powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -WindowStyle Hidden" & _
      " -File """ & scriptDir & "\dsh-mode-panel.ps1"""

' 0 = hidden window, False = do not wait
shell.Run cmd, 0, False
