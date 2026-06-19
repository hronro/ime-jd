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
    echo 未找到 %DLL_NAME%，已在以下位置查找：
    echo     %SCRIPT_DIR%
    echo     %SCRIPT_DIR%target\release\
    echo.
    echo 请先编译：cd windows ^&^& cargo build --release
    pause
    exit /b 1
)

REM Require Administrator. regsvr32 auto-elevates, but writing to Program
REM Files and running icacls need admin up-front; if we're not elevated the
REM directory create silently fails.
net session >nul 2>&1
if errorlevel 1 (
    echo 此脚本需要以管理员身份运行。
    echo 请右键点击 register.bat 并选择「以管理员身份运行」。
    pause
    exit /b 1
)

echo 正在安装 %DLL_NAME%
echo     源路径：%SOURCE_DLL%
echo     目标：  %INSTALL_DIR%

if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
if errorlevel 1 (
    echo 创建安装目录失败。
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
    echo 复制 DLL 失败。
    pause
    exit /b 1
)

REM AppContainer ACL so UWP/Store apps can load the DLL. Without this the
REM IME shows up as "(desktop only)" in Settings and can't be selected.
icacls "%INSTALL_DIR%" /grant "*S-1-15-2-1:(OI)(CI)(RX)" /T >nul
icacls "%INSTALL_DIR%" /grant "*S-1-15-2-2:(OI)(CI)(RX)" /T >nul

regsvr32 /s "%INSTALL_DIR%\%DLL_NAME%"
if errorlevel 1 (
    echo regsvr32 注册失败。
    pause
    exit /b 1
)

echo.
echo 键道输入法注册成功。
echo 通过以下路径将其添加到键盘列表：
echo     设置 ^> 时间和语言 ^> 语言 ^> 中文（简体） ^>
echo     选项 ^> 添加键盘 ^> 键道
echo.
pause
endlocal
