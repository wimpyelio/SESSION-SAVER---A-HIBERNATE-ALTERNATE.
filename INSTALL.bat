@echo off
setlocal

:: ================================================================
::  INSTALL.bat  -  Windows Session Restore 
::  Double-click this file to install OR upgrade.
::  Handles UAC elevation automatically. No manual right-click needed.
::
::  What this does:
::    - Detects whether v1 or v2 is already installed
::    - Backs up your saved session before any changes are made
::    - Stops running instances safely before replacing anything
::    - Registers all scheduled tasks and updates Desktop shortcuts
::    - Launches UPGRADE.ps1 which handles all logic and output
:: ================================================================

title Session Restore v2.1 - Installer

:: -- Elevation check ----------------------------------------------
net session >nul 2>&1
if %ERRORLEVEL% EQU 0 goto :ALREADY_ADMIN

:: Not elevated - re-launch this same .bat with UAC
echo.
echo  Windows Session Restore - Installer
echo  =====================================
echo.
echo  Administrator rights are required to register scheduled tasks.
echo  A UAC prompt will appear - please click YES to continue.
echo.
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -Wait"

:: The elevated instance ran and closed. Exit the original window silently.
goto :EOF

:ALREADY_ADMIN
:: -- Running as Administrator -------------------------------------
CD /D "%~dp0"

:: Verify UPGRADE.ps1 is present next to this .bat file
if not exist "%~dp0UPGRADE.ps1" (
    echo.
    echo  ERROR: UPGRADE.ps1 not found in the same folder as INSTALL.bat.
    echo  Make sure all files are extracted together:
    echo    SessionSave.ps1   SessionRestore.ps1   Setup.ps1
    echo    UPGRADE.ps1       INSTALL.bat
    echo.
    pause
    goto :EOF
)

echo.
echo  Running as Administrator...
echo.

PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0UPGRADE.ps1"

:: -- Error handling -----------------------------------------------
:: Exit code 0  = success  (window closes automatically)
:: Exit code 1+ = failure  (keep window open so user can read output)
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo  ============================================================
    echo  Installer exited with error code %ERRORLEVEL%.
    echo  Read the output above for details on what failed.
    echo  ============================================================
    echo.
    pause
)

endlocal
