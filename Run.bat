@echo off
setlocal
title WorkBuddy Account Switcher
set "APP=%~dp0"
if "%APP:~-1%"=="\" set "APP=%APP:~0,-1%"
set "PROF=%USERPROFILE%\.workbuddy-profiles"

if exist "%PROF%\pending-job.json" (
  echo [*] Pending job found, executing...
  echo.
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%APP%\switcher.ps1" -Action runjob
  echo.
  pause
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%APP%\switcher-gui.ps1"
)
endlocal
