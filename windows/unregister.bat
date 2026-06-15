@echo off
setlocal enableextensions

set "INSTALL_DIR=%ProgramFiles%\jd-ime"
set "DLL_NAME=jd_ime.dll"

REM Need admin to delete files under Program Files.
net session >nul 2>&1
if errorlevel 1 (
    echo This script needs to run as Administrator.
    echo Right-click unregister.bat and choose "Run as administrator".
    pause
    exit /b 1
)

if not exist "%INSTALL_DIR%" (
    echo Nothing to do — %INSTALL_DIR% doesn't exist.
    pause
    exit /b 0
)

REM Unregister from COM/TSF first.
if exist "%INSTALL_DIR%\%DLL_NAME%" (
    regsvr32 /s /u "%INSTALL_DIR%\%DLL_NAME%"
    if errorlevel 1 (
        echo regsvr32 /u reported an error; continuing with cleanup.
    )
)

REM Best-effort file cleanup. The DLL may still be loaded into running
REM processes that picked up the IME — those hold the file open until they
REM exit. Anything we can't delete now stays in the directory.
del /Q "%INSTALL_DIR%\%DLL_NAME%" >nul 2>&1
del /Q "%INSTALL_DIR%\*.old-*" >nul 2>&1

REM Remove the directory if it's empty.
rmdir "%INSTALL_DIR%" >nul 2>&1

if exist "%INSTALL_DIR%" (
    echo.
    echo JD IME unregistered, but %INSTALL_DIR% still contains files —
    echo the DLL is loaded into one or more running processes. Sign out
    echo and back in (or reboot) to release it, then re-run this script
    echo or delete the folder by hand.
) else (
    echo.
    echo JD IME fully removed.
)
echo.
pause
endlocal
