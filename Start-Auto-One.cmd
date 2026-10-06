@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Monitor.ps1" -Auto -Iterations 1
echo.
pause