' DSH mode launcher shim.
' Runs dsh-mode.ps1 with a fully hidden console (powershell -WindowStyle Hidden
' still flashes a console window, because the console is created before the
' argument is processed). wscript + Run(..., 0, ...) avoids that flash entirely.
'
' Usage: wscript.exe "dsh-mode.vbs" stock
'        wscript.exe "dsh-mode.vbs" study

Option Explicit

Dim shell, fso, scriptDir, mode, cmd

If WScript.Arguments.Count < 1 Then
    WScript.Quit 1
End If

mode = LCase(Trim(WScript.Arguments(0)))
If mode <> "stock" And mode <> "study" Then
    WScript.Quit 1
End If

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)

cmd = "powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -WindowStyle Hidden" & _
      " -File """ & scriptDir & "\dsh-mode.ps1"" -Mode " & mode

' 0 = hidden window, False = do not wait
shell.Run cmd, 0, False
