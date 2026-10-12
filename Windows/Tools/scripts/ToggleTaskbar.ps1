# Define the Windows API functions needed to find and manipulate windows
$WinAPI = Add-Type -MemberDefinition @'
[DllImport("user32.dll")]
public static extern IntPtr FindWindow(string className, string windowText);

[DllImport("user32.dll")]
public static extern int ShowWindow(IntPtr hwnd, int command);

[DllImport("user32.dll")]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool IsWindowVisible(IntPtr hWnd);
'@ -Name "TaskbarToggle" -Namespace "Win32" -PassThru

# Get handles for both the main and secondary (multi-monitor) taskbars
$hTaskbar = $WinAPI::FindWindow("Shell_TrayWnd", $null)
$hSecondaryTaskbar = $WinAPI::FindWindow("Shell_SecondaryTrayWnd", $null)

if ($hTaskbar -ne [IntPtr]::Zero) {
    # Check if the primary taskbar is currently visible
    if ($WinAPI::IsWindowVisible($hTaskbar)) {
        # Hide them completely (0 = SW_HIDE)
        [void]$WinAPI::ShowWindow($hTaskbar, 0)
        if ($hSecondaryTaskbar -ne [IntPtr]::Zero) { [void]$WinAPI::ShowWindow($hSecondaryTaskbar, 0) }
    } else {
        # Show them again (5 = SW_SHOW)
        [void]$WinAPI::ShowWindow($hTaskbar, 5)
        if ($hSecondaryTaskbar -ne [IntPtr]::Zero) { [void]$WinAPI::ShowWindow($hSecondaryTaskbar, 5) }
    }
}
