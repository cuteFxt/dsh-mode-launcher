' DSH mode launcher shim.
' Runs dsh-mode.ps1 with a fully hidden console (powershell -WindowStyle Hidden
' still flashes a console window, because the console is created before the
' argument is processed). wscript + Run(..., 0, ...) avoids that flash entirely.
'
' Usage: wscript.exe "dsh-mode.vbs" stock
'        wscript.exe "dsh-mode.vbs" study
'        wscript.exe "dsh-mode.vbs" <任意自定义模式 id>
'
' 模式 id 由 modes.json 决定，所以这里不再写死白名单，只做最基本的校验
' （非空、不含空白与引号），避免把奇怪的东西拼进命令行。

Option Explicit

Dim shell, fso, scriptDir, mode, cmd

If WScript.Arguments.Count < 1 Then
    WScript.Quit 1
End If

mode = Trim(WScript.Arguments(0))
If Len(mode) = 0 Then
    WScript.Quit 1
End If

Dim bad, i, ch
bad = False
For i = 1 To Len(mode)
    ch = Mid(mode, i, 1)
    If ch = " " Or ch = vbTab Or ch = """" Or ch = "&" Or ch = "|" Or ch = "<" Or ch = ">" Then
        bad = True
    End If
Next
If bad Then
    WScript.Quit 1
End If

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)

cmd = "powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -WindowStyle Hidden" & _
      " -File """ & scriptDir & "\dsh-mode.ps1"" -Mode """ & mode & """"

' 0 = hidden window, False = do not wait
shell.Run cmd, 0, False
