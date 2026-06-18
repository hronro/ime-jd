@echo off
setlocal enableextensions
chcp 65001 >nul

set "SCRIPT_DIR=%~dp0"
set "DLL_NAME=jd_ime.dll"
set "INSTALL_DIR=%ProgramFiles%\jd-ime"

REM Locate the DLL. Two layouts are supported:
REM   1) Distribution: DLL next to this script.
REM   2) Dev: this script in windows\, DLL in windows\target\release\.
set "SOURCE_DLL="
if exist "%SCRIPT_DIR%%DLL_NAME%" set "SOURCE_DLL=%SCRIPT_DIR%%DLL_NAME%"
if not defined SOURCE_DLL if exist "%SCRIPT_DIR%target\release\%DLL_NAME%" set "SOURCE_DLL=%SCRIPT_DIR%target\release\%DLL_NAME%"
if not defined SOURCE_DLL (
    echo Could not find %DLL_NAME%. Looked in:
    echo     %SCRIPT_DIR%
    echo     %SCRIPT_DIR%target\release\
    echo.
    echo Build first: cd windows ^&^& cargo build --release
    pause
    exit /b 1
)

REM Require Administrator. regsvr32 auto-elevates, but writing to Program
REM Files and running icacls need admin up-front; if we're not elevated the
REM directory create silently fails.
net session >nul 2>&1
if errorlevel 1 (
    echo This script needs to run as Administrator.
    echo Right-click register.bat and choose "Run as administrator".
    pause
    exit /b 1
)

echo Installing %DLL_NAME%
echo     from: %SOURCE_DLL%
echo     to:   %INSTALL_DIR%

if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
if errorlevel 1 (
    echo Failed to create install directory.
    pause
    exit /b 1
)

REM If a previous copy is still loaded by some process, rename it out of the
REM way. Windows allows rename-while-loaded; the old name remains valid for
REM processes already holding it.
if exist "%INSTALL_DIR%\%DLL_NAME%" (
    regsvr32 /s /u "%INSTALL_DIR%\%DLL_NAME%" >nul 2>&1
    for /f "tokens=2 delims==" %%I in ('wmic os get localdatetime /value ^| find "="') do set "STAMP=%%I"
    move /Y "%INSTALL_DIR%\%DLL_NAME%" "%INSTALL_DIR%\%DLL_NAME%.old-%STAMP%" >nul
)

copy /Y "%SOURCE_DLL%" "%INSTALL_DIR%\" >nul
if errorlevel 1 (
    echo Failed to copy DLL.
    pause
    exit /b 1
)

REM AppContainer ACL so UWP/Store apps can load the DLL. Without this the
REM IME shows up as "(desktop only)" in Settings and can't be selected.
icacls "%INSTALL_DIR%" /grant "*S-1-15-2-1:(OI)(CI)(RX)" /T >nul
icacls "%INSTALL_DIR%" /grant "*S-1-15-2-2:(OI)(CI)(RX)" /T >nul

regsvr32 /s "%INSTALL_DIR%\%DLL_NAME%"
if errorlevel 1 (
    echo regsvr32 failed.
    pause
    exit /b 1
)

echo.
echo 键道输入法 registered.
echo Add it to your keyboard list via:
echo     Settings ^> Time ^& language ^> Language ^> Chinese (Simplified) ^>
echo     Options ^> Add a keyboard ^> 键道
echo.
pause
endlocal
