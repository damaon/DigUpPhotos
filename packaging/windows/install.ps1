# Installs DigUp for this user on Windows, from the folder this script is in (the Windows build's zip, or
# .build\release after `swift build -c release --product digup` with ONNX Runtime's DLL copied next to it): the program
# in %LOCALAPPDATA%\Programs\DigUp, "DigUp" in the Start menu (it opens DigUp in the browser), and DigUp started at
# sign-in, without a window, so new files are found while the page is closed. Sound, video and HEIC need ffmpeg
# (winget install Gyan.FFmpeg); PDFs need poppler's pdftotext and pdftoppm on PATH.
#   powershell -ExecutionPolicy Bypass -File install.ps1             install, or update
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Remove     take it out again (the index and the model stay)
param([switch]$Remove)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $env:LOCALAPPDATA "Programs\DigUp"
$menu = Join-Path ([Environment]::GetFolderPath("Programs")) "DigUp.lnk"
$startup = Join-Path ([Environment]::GetFolderPath("Startup")) "DigUp.lnk"

Get-Process digup -ErrorAction SilentlyContinue | Stop-Process -Force
if ($Remove) {
    Remove-Item -Force -ErrorAction SilentlyContinue $menu, $startup
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $target
    Write-Host "DigUp is gone (the index and the model are still in $env:LOCALAPPDATA\DigUpPhotos)"
    exit 0
}

New-Item -ItemType Directory -Force $target | Out-Null
Copy-Item -Force (Join-Path $here "digup.exe"), (Join-Path $here "*.dll") $target
$icon = Join-Path $here "digup.ico"
if (Test-Path $icon) { Copy-Item -Force $icon $target }
# Started through wscript, so no console window stays open.
@"
Set shell = CreateObject("WScript.Shell")
shell.CurrentDirectory = "$target"
args = ""
If WScript.Arguments.Count > 0 Then args = " " & WScript.Arguments(0)
shell.Run """$target\digup.exe"" serve" & args, 0, False
"@ | Set-Content -Encoding ASCII (Join-Path $target "digup.vbs")

$shell = New-Object -ComObject WScript.Shell
foreach ($link in @(@{ Path = $menu; Arguments = "--open" }, @{ Path = $startup; Arguments = "" })) {
    $shortcut = $shell.CreateShortcut($link.Path)
    $shortcut.TargetPath = Join-Path $env:WINDIR "System32\wscript.exe"
    $shortcut.Arguments = "`"$target\digup.vbs`" $($link.Arguments)"
    $shortcut.WorkingDirectory = $target
    $shortcut.IconLocation = Join-Path $target "digup.ico"
    $shortcut.Description = "Find photos, videos and documents by what they show or say"
    $shortcut.Save()
}

# The program on PATH for this user, for `digup search` and `digup mcp`.
$path = [Environment]::GetEnvironmentVariable("Path", "User")
if (-not ($path -split ";" | Where-Object { $_ -eq $target })) {
    [Environment]::SetEnvironmentVariable("Path", (($path, $target) -join ";").Trim(";"), "User")
}
Start-Process (Join-Path $env:WINDIR "System32\wscript.exe") "`"$target\digup.vbs`" --open"
Write-Host "Installed. DigUp is at http://127.0.0.1:7811/ and starts when you sign in."
