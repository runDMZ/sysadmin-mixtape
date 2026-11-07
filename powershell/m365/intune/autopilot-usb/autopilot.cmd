@echo off
REM Launcher for Register-Autopilot.ps1 - keep both files at the root of the USB drive.
REM Usage:  autopilot.cmd CORP   -> registers the device with the group tag CORP
REM         autopilot.cmd        -> registers the device without group tag
if "%~1"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Register-Autopilot.ps1"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Register-Autopilot.ps1" -GroupTag "%~1"
)
pause
