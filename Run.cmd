@echo off
rem ===========================================================================
rem  rdp sesin menicir - launcher
rem  belesware / fikired by ugur.es
rem
rem  Double-click this instead of the .ps1 file.
rem
rem  -ExecutionPolicy Bypass applies to THIS process only. It writes nothing
rem  to the registry and changes no machine setting, so you never need to run
rem  Set-ExecutionPolicy. It also bypasses the Mark of the Web that Windows
rem  puts on downloaded files, so Unblock-File is not needed either.
rem
rem  For elevated rights: right-click this file -> Run as administrator.
rem  (The tool also offers to restart elevated if you start it as a user.)
rem ===========================================================================

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RdpSesinMenicir.ps1"

if errorlevel 1 (
    echo.
    echo The tool exited with an error. Press any key to close.
    pause >nul
)
