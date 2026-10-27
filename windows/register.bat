@echo off
setlocal enableextensions
chcp 65001 >nul

REM Started from a 32-bit process — the IME's update, clicked in a 32-bit
REM application — this script runs in the 32-bit cmd, which sees Program
REM Files (x86) as %ProgramFiles% and SysWOW64 as System32. Hand it over to
REM the 64-bit cmd, which the 32-bit one reaches as Sysnative.
if not defined PROCESSOR_ARCHITEW6432 goto :Native
if not exist "%SystemRoot%\Sysnative\cmd.exe" goto :Native
"%SystemRoot%\Sysnative\cmd.exe" /c ""%~f0" %*"
exit /b %ERRORLEVEL%
:Native

set "SCRIPT_DIR=%~dp0"
set "DLL_NAME=ime_jd.dll"
REM Windows loads an IME into each application in the application's own
REM architecture, so 32-bit applications (WPS Office, for one) load this
REM one, registered by the 32-bit regsvr32 where they look.
set "DLL32_NAME=ime_jd_x86.dll"
set "REGSVR32_32=%SystemRoot%\SysWOW64\regsvr32.exe"
set "EXE_NAME=ime_jd_userdict.exe"
set "INSTALL_DIR=%ProgramFiles%\ime-jd"
set "SHORTCUT=%ProgramData%\Microsoft\Windows\Start Menu\Programs\键道用户自造词.lnk"

REM Locate the DLL and the user-dictionary window beside it. Two layouts
REM are supported:
REM   1) Distribution: both next to this script.
REM   2) Dev: this script in windows\, both in windows\target\release\.
set "SOURCE_DIR="
if exist "%SCRIPT_DIR%%DLL_NAME%" set "SOURCE_DIR=%SCRIPT_DIR%"
if not defined SOURCE_DIR if exist "%SCRIPT_DIR%target\release\%DLL_NAME%" set "SOURCE_DIR=%SCRIPT_DIR%target\release\"
if not defined SOURCE_DIR (
    echo 未找到 %DLL_NAME%，已在以下位置查找：
    echo     %SCRIPT_DIR%
    echo     %SCRIPT_DIR%target\release\
    echo.
    echo 请先编译：cd windows ^&^& cargo build --release
    pause
    exit /b 1
)

REM The 32-bit DLL: next to this script, or in dev the i686 build, under the
REM DLL's own name in windows\target\i686-pc-windows-msvc\release\.
set "SOURCE32="
if exist "%SCRIPT_DIR%%DLL32_NAME%" set "SOURCE32=%SCRIPT_DIR%%DLL32_NAME%"
if not defined SOURCE32 if exist "%SCRIPT_DIR%target\i686-pc-windows-msvc\release\%DLL_NAME%" set "SOURCE32=%SCRIPT_DIR%target\i686-pc-windows-msvc\release\%DLL_NAME%"

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
echo     源路径：%SOURCE_DIR%
echo     目标：  %INSTALL_DIR%

if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
if errorlevel 1 (
    echo 创建安装目录失败。
    pause
    exit /b 1
)

REM Delete renamed leftovers from earlier upgrades. Copies still loaded by
REM some process can't be deleted — del skips them silently and they get
REM another chance on the next run.
del /q "%INSTALL_DIR%\*.old-*" >nul 2>&1

REM If a previous copy is still loaded by some process, rename it out of the
REM way. Windows allows rename-while-loaded; the old name remains valid for
REM processes already holding it. The rename lives in a subroutine on
REM purpose: cmd expands %VARS% inside a parenthesized block when the block
REM is PARSED, so the old inline `move ... .old-%STAMP%` always saw an empty
REM STAMP and renamed to one constant name — the second upgrade-while-loaded
REM then collided with the loaded leftover and the install aborted until
REM reboot. (The stamp also came from wmic, which Windows 11 24H2 removed.)
if exist "%INSTALL_DIR%\%DLL_NAME%" (
    regsvr32 /s /u "%INSTALL_DIR%\%DLL_NAME%" >nul 2>&1
    call :RenameOld %DLL_NAME%
)
if exist "%INSTALL_DIR%\%DLL32_NAME%" (
    "%REGSVR32_32%" /s /u "%INSTALL_DIR%\%DLL32_NAME%" >nul 2>&1
    call :RenameOld %DLL32_NAME%
)

copy /Y "%SOURCE_DIR%%DLL_NAME%" "%INSTALL_DIR%\" >nul
if errorlevel 1 (
    echo 复制 DLL 失败。可能有程序仍在占用旧版本 ——
    echo 注销并重新登录（或重启）后再运行本脚本。
    pause
    exit /b 1
)

REM Without the 32-bit DLL in the source the IME still installs, for 64-bit
REM applications only.
if defined SOURCE32 (
    copy /Y "%SOURCE32%" "%INSTALL_DIR%\%DLL32_NAME%" >nul
    if errorlevel 1 echo 复制 %DLL32_NAME% 失败，键道将无法在 32 位程序中使用。
) else (
    echo 未找到 32 位的 %DLL32_NAME%，键道将无法在 32 位程序中使用。
)

REM The user-dictionary window. A running copy is renamed out of the way
REM like the DLL; without one in the source the IME still installs whole.
if exist "%SOURCE_DIR%%EXE_NAME%" (
    if exist "%INSTALL_DIR%\%EXE_NAME%" call :RenameOld %EXE_NAME%
    copy /Y "%SOURCE_DIR%%EXE_NAME%" "%INSTALL_DIR%\" >nul
) else (
    echo 未找到 %EXE_NAME%，跳过用户自造词窗口。
)

REM AppContainer ACL so UWP/Store apps can load the DLL. Without this the
REM IME shows up as "(desktop only)" in Settings and can't be selected.
icacls "%INSTALL_DIR%" /grant "*S-1-15-2-1:(OI)(CI)(RX)" /T >nul
icacls "%INSTALL_DIR%" /grant "*S-1-15-2-2:(OI)(CI)(RX)" /T >nul

REM The 32-bit DLL registers first. Both DLLs register the one input
REM profile, which 32-bit and 64-bit applications share, and the last to
REM register leaves its own path there for the profile's icon: the 64-bit
REM DLL's, which is always installed.
if exist "%INSTALL_DIR%\%DLL32_NAME%" (
    "%REGSVR32_32%" /s "%INSTALL_DIR%\%DLL32_NAME%"
    if errorlevel 1 echo %DLL32_NAME% 注册失败，键道将无法在 32 位程序中使用。
)

regsvr32 /s "%INSTALL_DIR%\%DLL_NAME%"
if errorlevel 1 (
    echo regsvr32 注册失败。
    pause
    exit /b 1
)

REM A Start menu entry for the window, for every user. The paths travel in
REM the environment, so nothing in them needs quoting for PowerShell. The
REM shortcut is saved under an ASCII name and then renamed: WScript.Shell
REM writes its file name through the ANSI code page, which on a Windows that
REM is not Chinese turns the name into question marks and fails the save.
if exist "%INSTALL_DIR%\%EXE_NAME%" (
    set "SHORTCUT_TARGET=%INSTALL_DIR%\%EXE_NAME%"
    powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Stop'; $tmp = Join-Path (Split-Path $env:SHORTCUT) 'ime_jd_userdict.lnk'; $s = (New-Object -ComObject WScript.Shell).CreateShortcut($tmp); $s.TargetPath = $env:SHORTCUT_TARGET; $s.WorkingDirectory = $env:INSTALL_DIR; $s.Save(); Move-Item -LiteralPath $tmp -Destination $env:SHORTCUT -Force" >nul 2>&1
    if errorlevel 1 echo 未能在「开始」菜单中创建「键道用户自造词」。
)

echo.
echo 键道输入法注册成功。
echo 通过以下路径将其添加到键盘列表：
echo     设置 ^> 时间和语言 ^> 语言 ^> 中文（简体） ^>
echo     选项 ^> 添加键盘 ^> 键道
echo 用户自造词可在「开始」菜单的「键道用户自造词」中编辑。
echo.
pause
endlocal
exit /b 0

REM Rename the loaded file %1 to a unique .old-* name. Lines in a CALLed
REM label are parsed one at a time, so %RANDOM% expands at run time here
REM (unlike inside a parenthesized block). Redraw if the name is taken — a
REM stale .old-* can linger loaded from a previous upgrade.
:RenameOld
set "OLD_TARGET=%INSTALL_DIR%\%~1.old-%RANDOM%%RANDOM%"
if exist "%OLD_TARGET%" goto :RenameOld
move /Y "%INSTALL_DIR%\%~1" "%OLD_TARGET%" >nul
exit /b 0
