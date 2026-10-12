# PowerShell Script to Change Desktop Wallpaper on Windows 11
# https://endurtech.com/powershell-script-to-change-desktop-wallpaper-on-windows-11/

$WallpaperFolder = (Join-Path (Get-Item $PSScriptRoot).parent.parent.parent "Wallpapers")
echo $WallpaperFolder
$imgPath = Get-ChildItem $WallpaperFolder | Get-Random
echo $imgPath
$code = @"
using System;
using System.Runtime.InteropServices;
public class Wallpaper
{
  [DllImport("user32.dll", CharSet = CharSet.Auto)]
  public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
"@
Add-Type -TypeDefinition $code -Language CSharp
[Wallpaper]::SystemParametersInfo(20, 0, $imgPath, 3)

Read-Host -Prompt "Drücke ENTER, um das Fenster zu schließen"