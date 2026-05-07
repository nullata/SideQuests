' Launches backup.ps1 with no visible window. Used by the Backup-Mirror
' scheduled task so the daily runs don't flash a console window.
' wscript.exe (which runs this) has no console of its own, and Run with
' show=0 starts powershell.exe hidden from the outset (no flash), unlike
' calling powershell.exe -WindowStyle Hidden directly from the task.

Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")

' show=0 (hidden), waitOnReturn=True so the task's Last Run Result
' reflects the powershell exit code.
exitCode = sh.Run("powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & scriptDir & "\backup.ps1""", 0, True)
WScript.Quit exitCode
