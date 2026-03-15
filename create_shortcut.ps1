$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut("$env:USERPROFILE\Desktop\THRESHOLD.lnk")
$Shortcut.TargetPath = "$env:USERPROFILE\Godot\Godot_v4.6.1-stable_win64.exe"
$Shortcut.Arguments = "--path `"$env:USERPROFILE\harpoon`""
$Shortcut.WorkingDirectory = "$env:USERPROFILE\harpoon"
$Shortcut.IconLocation = "$env:USERPROFILE\harpoon\threshold.ico, 0"
$Shortcut.Description = "THRESHOLD - Naval Warfare Simulation"
$Shortcut.WindowStyle = 1
$Shortcut.Save()
Write-Host "Shortcut created: $env:USERPROFILE\Desktop\THRESHOLD.lnk"
