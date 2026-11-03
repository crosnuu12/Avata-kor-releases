#requires -Version 5.1
param([string]$Core=(Join-Path $PSScriptRoot 'alerts_58175_20261103/bundle/payload/At58.Core.ps1'),[switch]$HostedRunner)
$ErrorActionPreference='Stop'
if($HostedRunner -and ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted')){throw 'HOSTED_RUNNER_REQUIRED'}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TrayDesktopProbe {
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr CreateDesktop(string n,IntPtr d,IntPtr m,uint f,uint a,IntPtr s);
 [DllImport("user32.dll",SetLastError=true)] public static extern bool SetThreadDesktop(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr GetThreadDesktop(uint id);
 [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
 [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
}
'@
$original=[TrayDesktopProbe]::GetThreadDesktop([TrayDesktopProbe]::GetCurrentThreadId())
$desk=[IntPtr]::Zero
if(!$HostedRunner){
 $desk=[TrayDesktopProbe]::CreateDesktop(('AvataTrayProbe-'+[guid]::NewGuid().ToString('N')),[IntPtr]::Zero,[IntPtr]::Zero,0,0x01ff,[IntPtr]::Zero)
 if($desk -eq [IntPtr]::Zero){throw ('ISOLATED_DESKTOP_CREATE '+[Runtime.InteropServices.Marshal]::GetLastWin32Error())}
}
$window=$null
try{
 if(!$HostedRunner -and ![TrayDesktopProbe]::SetThreadDesktop($desk)){throw ('ISOLATED_DESKTOP_ATTACH '+[Runtime.InteropServices.Marshal]::GetLastWin32Error())}
 Add-Type -AssemblyName System.Windows.Forms,System.Drawing
 . $Core
 At58Window-Native
 $window=[AvataTrayWindow]::new();$window.TrayHidden=$true;$window.ShowInTaskbar=$false
 $window.Add_Resize({if($window.WindowState -eq [Windows.Forms.FormWindowState]::Minimized){$window.EnterTray()}})
 $window.Show();[Windows.Forms.Application]::DoEvents()
 $window.RestoreFromTray();[Windows.Forms.Application]::DoEvents()
 Write-Output ('FIRST RESTORE '+(@{Visible=$window.Visible;Hidden=$window.TrayHidden;State=[string]$window.WindowState;Taskbar=$window.ShowInTaskbar}|ConvertTo-Json -Compress))
 $window.WindowState=[Windows.Forms.FormWindowState]::Minimized;[Windows.Forms.Application]::DoEvents()
 Write-Output ('MINIMIZE '+(@{Visible=$window.Visible;Hidden=$window.TrayHidden;State=[string]$window.WindowState;Taskbar=$window.ShowInTaskbar}|ConvertTo-Json -Compress))
 $window.RestoreFromTray();[Windows.Forms.Application]::DoEvents()
 Write-Output ('SECOND RESTORE '+(@{Visible=$window.Visible;Hidden=$window.TrayHidden;State=[string]$window.WindowState;Taskbar=$window.ShowInTaskbar}|ConvertTo-Json -Compress))
 if(!$window.Visible -or $window.TrayHidden -or !$window.ShowInTaskbar -or $window.WindowState -ne [Windows.Forms.FormWindowState]::Normal){throw 'TRAY_RESTORE_FAILED'}
 Write-Output 'RESTORE PASSED on isolated desktop; no foreground desktop switched.'
}finally{
 if($window){$window.Dispose()}
 if($desk -ne [IntPtr]::Zero){[void][TrayDesktopProbe]::SetThreadDesktop($original);[void][TrayDesktopProbe]::CloseDesktop($desk)}
}

