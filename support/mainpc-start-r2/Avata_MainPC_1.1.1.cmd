@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "%~dp0MainPC-Start.ps1"
if errorlevel 1 pause
endlocal
