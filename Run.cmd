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

setlocal
set "PS1=%~dp0RdpSesinMenicir.ps1"

if not exist "%PS1%" (
    echo.
    echo RdpSesinMenicir.ps1 was not found next to this launcher.
    echo Keep both files in the same folder.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
set "RC=%errorlevel%"

if not "%RC%"=="0" (
    echo.
    echo The tool exited with code %RC%.
    echo.
    echo To see the full error message, run this in a PowerShell window:
    echo    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
    echo.
    pause
)
endlocal
