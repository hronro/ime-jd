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
REM What is installed under the IME's name, and registered, is not the IME
REM but the loader in front of it (loader\loader.c): a small DLL that stays
REM as it is from one installation to the next. The IME is copied in beside
REM it under a name of this installation's own, jd-<id>-<arch>.dll, and the
REM file `current` says which id is in use. An application that is running
REM has the loader loaded, and the loader brings the new IME into it the
REM next time nothing is being typed there: no application has to be
REM started again for an upgrade.
set "LOADER_NAME=ime_jd.dll"
REM Windows loads an IME into each application in the application's own
REM architecture, so 32-bit applications (WPS Office, for one) load this
REM loader, registered by the 32-bit regsvr32 where they look, and the
REM 32-bit IME behind it.
set "LOADER32_NAME=ime_jd_x86.dll"
set "REGSVR32_32=%SystemRoot%\SysWOW64\regsvr32.exe"
set "EXE_NAME=ime_jd_userdict.exe"
set "INSTALL_DIR=%ProgramFiles%\ime-jd"
set "SHORTCUT=%ProgramData%\Microsoft\Windows\Start Menu\Programs\键道用户自造词.lnk"

REM Locate what is to be installed. Two layouts are supported:
REM   1) Distribution: everything next to this script — the loaders under
REM      their own names, the IME as jd-<arch>.dll.
REM   2) Dev: this script in windows\, cargo's builds under windows\target\
REM      and the loaders under windows\target\loader\ (loader\build.bat).
REM IME_ARCH is the architecture of the machine's own applications, x64 or
REM arm64, and SRC_IME the IME for them.
set "SRC_LOADER="
set "SRC_IME="
set "SRC_IME_X64="
set "SRC_LOADER32="
set "SRC_IME32="
set "IME_ARCH=x64"
if exist "%SCRIPT_DIR%%LOADER_NAME%" goto :Distribution

set "LOADER_KIND=x64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "IME_ARCH=arm64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "LOADER_KIND=arm64x"
set "SRC_LOADER=%SCRIPT_DIR%target\loader\%LOADER_KIND%\%LOADER_NAME%"
set "SRC_IME=%SCRIPT_DIR%target\release\ime_jd.dll"
set "SRC_IME_X64=%SCRIPT_DIR%target\x86_64-pc-windows-msvc\release\ime_jd.dll"
set "SRC_LOADER32=%SCRIPT_DIR%target\loader\x86\%LOADER32_NAME%"
set "SRC_IME32=%SCRIPT_DIR%target\i686-pc-windows-msvc\release\ime_jd.dll"
set "SRC_EXE=%SCRIPT_DIR%target\release\%EXE_NAME%"
goto :Located

:Distribution
REM The ARM64 package is told by the IME's ARM64 DLL in it.
if exist "%SCRIPT_DIR%jd-arm64.dll" set "IME_ARCH=arm64"
set "SRC_LOADER=%SCRIPT_DIR%%LOADER_NAME%"
set "SRC_IME=%SCRIPT_DIR%jd-%IME_ARCH%.dll"
set "SRC_IME_X64=%SCRIPT_DIR%jd-x64.dll"
set "SRC_LOADER32=%SCRIPT_DIR%%LOADER32_NAME%"
set "SRC_IME32=%SCRIPT_DIR%jd-x86.dll"
set "SRC_EXE=%SCRIPT_DIR%%EXE_NAME%"

:Located
if not exist "%SRC_LOADER%" goto :NotFound
if not exist "%SRC_IME%" goto :NotFound
REM ARM64 Windows runs x64 applications too, and they read the registry
REM that ARM64 ones read: the one DLL registered there has to load into
REM both. So the loader is one file with a side for each there (Arm64X),
REM and behind it are two IMEs, this one for the x64 applications. Without
REM it the IME still installs, for ARM64 applications only.
if /i not "%IME_ARCH%"=="arm64" set "SRC_IME_X64="
if defined SRC_IME_X64 if not exist "%SRC_IME_X64%" set "SRC_IME_X64="
REM The 32-bit loader and IME go together. Without them the IME still
REM installs, for 64-bit applications only.
if not exist "%SRC_LOADER32%" set "SRC_IME32="
if not exist "%SRC_IME32%" set "SRC_IME32="

REM Require Administrator. regsvr32 auto-elevates, but writing to Program
REM Files and running icacls need admin up-front; if we're not elevated the
REM directory create silently fails. The test is fltmc, which lists the
REM file system's filters to an administrator and to no one else. It used
REM to be `net session`, which asks the Server service — and so sent an
REM administrator away wherever that service is stopped or disabled.
fltmc >nul 2>&1
if errorlevel 1 goto :NotAdmin

echo 正在安装键道输入法
echo     源路径："%SRC_IME%"
echo     目标：  "%INSTALL_DIR%"

if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
if errorlevel 1 goto :NoInstallDir

REM What is there already: an installation with the loader, which has a
REM `current` — its id is kept, to go back to should this one not register —
REM or one from before there was a loader, in which ime_jd.dll is the IME
REM itself.
set "HAD_LOADER="
set "HAD_IME="
set "PREVIOUS_ID="
if exist "%INSTALL_DIR%\current" set "HAD_LOADER=1"
if defined HAD_LOADER set /p PREVIOUS_ID=<"%INSTALL_DIR%\current"
if not defined HAD_LOADER if exist "%INSTALL_DIR%\%LOADER_NAME%" set "HAD_IME=1"

REM Delete renamed leftovers from earlier upgrades. Copies still loaded by
REM some process can't be deleted — del skips them silently and they get
REM another chance on the next run.
del /q "%INSTALL_DIR%\*.old-*" >nul 2>&1
del /q "%INSTALL_DIR%\current.new" >nul 2>&1

REM This installation's id. The IME is copied in under a name with the id
REM in it, a name no installation before has used: nothing it replaces is
REM in use by an application, and the files of the installation before stay
REM whole for the applications that are running with them.
:NewId
set "ID=%RANDOM%%RANDOM%"
if exist "%INSTALL_DIR%\jd-%ID%-*.dll" goto :NewId

copy /Y "%SRC_IME%" "%INSTALL_DIR%\jd-%ID%-%IME_ARCH%.dll" >nul
if errorlevel 1 goto :CopyFailed

if defined SRC_IME_X64 (
    copy /Y "%SRC_IME_X64%" "%INSTALL_DIR%\jd-%ID%-x64.dll" >nul
    if errorlevel 1 echo 复制 x64 的 DLL 失败，键道将无法在 x64 程序中使用。
)
if /i "%IME_ARCH%"=="arm64" if not defined SRC_IME_X64 echo 未找到 x64 的 DLL，键道将无法在 x64 程序中使用。

if defined SRC_IME32 (
    copy /Y "%SRC_IME32%" "%INSTALL_DIR%\jd-%ID%-x86.dll" >nul
    if errorlevel 1 echo 复制 32 位的 DLL 失败，键道将无法在 32 位程序中使用。
) else (
    echo 未找到 32 位的 DLL，键道将无法在 32 位程序中使用。
)

REM The user-dictionary window. A running copy is renamed out of the way;
REM without one in the source the IME still installs whole.
if exist "%SRC_EXE%" (
    if exist "%INSTALL_DIR%\%EXE_NAME%" call :RenameOld %EXE_NAME%
    copy /Y "%SRC_EXE%" "%INSTALL_DIR%\" >nul
) else (
    echo 未找到 %EXE_NAME%，跳过用户自造词窗口。
)

REM What the IME's own update runs elevated, on the release it downloaded
REM (update.bat, beside this script): installed with the rest, so that the
REM copy it runs is one only an administrator can change.
if exist "%SCRIPT_DIR%update.bat" copy /Y "%SCRIPT_DIR%update.bat" "%INSTALL_DIR%\" >nul

REM AppContainer ACL so UWP/Store apps can load the DLLs. Without this the
REM IME shows up as "(desktop only)" in Settings and can't be selected.
REM What is copied in from here on is created in the folder, and gets the
REM folder's.
icacls "%INSTALL_DIR%" /grant "*S-1-15-2-1:(OI)(CI)(RX)" /T >nul
icacls "%INSTALL_DIR%" /grant "*S-1-15-2-2:(OI)(CI)(RX)" /T >nul

REM Without a 32-bit IME in this installation, what an earlier one
REM registered for 32-bit applications goes — while its loader still finds
REM the IME that unregisters it.
if not defined SRC_IME32 if exist "%INSTALL_DIR%\%LOADER32_NAME%" (
    "%REGSVR32_32%" /s /u "%INSTALL_DIR%\%LOADER32_NAME%" >nul 2>&1
    call :RenameOld %LOADER32_NAME%
)

REM This installation is the one in use from here on: `current` says so,
REM to every loader — those of applications that are running included,
REM which hand over to this installation's IME when the one they have is
REM next idle. The line is written to a file beside it and that file moved
REM into its place, so that whoever reads `current` meanwhile finds the old
REM line or the new one, whole.
(echo %ID%)>"%INSTALL_DIR%\current.new"
if errorlevel 1 goto :CopyFailed
move /Y "%INSTALL_DIR%\current.new" "%INSTALL_DIR%\current" >nul
if errorlevel 1 goto :CopyFailed

REM An installation from before there was a loader: applications that are
REM running have its DLLs loaded — the IME itself — and go on with them
REM until they are started again. They are unregistered and moved out of
REM the way, which Windows allows of a file that is loaded; that is what
REM every upgrade used to do. The rename lives in a subroutine on purpose:
REM cmd expands %VARS% inside a parenthesized block when the block is
REM PARSED, so an inline `move ... .old-%RANDOM%` would use one name for
REM every file.
if defined HAD_LOADER goto :Loaders
if exist "%INSTALL_DIR%\%LOADER_NAME%" (
    regsvr32 /s /u "%INSTALL_DIR%\%LOADER_NAME%" >nul 2>&1
    call :RenameOld %LOADER_NAME%
)
if exist "%INSTALL_DIR%\%LOADER32_NAME%" (
    "%REGSVR32_32%" /s /u "%INSTALL_DIR%\%LOADER32_NAME%" >nul 2>&1
    call :RenameOld %LOADER32_NAME%
)
REM What an ARM64 package of then installed behind its ime_jd.dll, which
REM has just passed the unregistering on to it.
if exist "%INSTALL_DIR%\ime_jd_arm64.dll" call :RenameOld ime_jd_arm64.dll
if exist "%INSTALL_DIR%\ime_jd_x64.dll" call :RenameOld ime_jd_x64.dll

:Loaders
set "FROM=%SRC_LOADER%"
call :PlaceLoader %LOADER_NAME%
if errorlevel 1 goto :CopyFailed
if defined SRC_IME32 (
    set "FROM=%SRC_LOADER32%"
    call :PlaceLoader %LOADER32_NAME%
    if errorlevel 1 echo 复制 %LOADER32_NAME% 失败，键道将无法在 32 位程序中使用。
)

REM regsvr32 is given the loader, which passes the call on to the IME in
REM use, and the IME registers the loader as what applications load. The
REM 32-bit one registers first. Both register the one input profile, which
REM 32-bit and 64-bit applications share, and the last to register leaves
REM its own path there for the profile's icon: the 64-bit loader's, which
REM is always installed.
if defined SRC_IME32 if exist "%INSTALL_DIR%\%LOADER32_NAME%" (
    "%REGSVR32_32%" /s "%INSTALL_DIR%\%LOADER32_NAME%"
    if errorlevel 1 echo %LOADER32_NAME% 注册失败，键道将无法在 32 位程序中使用。
)

REM On ARM64, where the loader does not load, or does not find the IME, the
REM IME's ARM64 DLL registers itself, as it did before there was a loader:
REM ARM64 applications get the IME, and x64 ones do not.
regsvr32 /s "%INSTALL_DIR%\%LOADER_NAME%"
if errorlevel 1 if /i "%IME_ARCH%"=="arm64" (
    echo %LOADER_NAME% 注册失败，改为直接注册 jd-%ID%-arm64.dll：键道将无法在 x64 程序中使用。
    regsvr32 /s "%INSTALL_DIR%\jd-%ID%-arm64.dll"
)
if errorlevel 1 goto :RegisterFailed

REM The IME of the installations before this one. An application that had
REM one loaded has it loaded still — a DLL does not leave a process — and
REM del skips that file silently: it gets another chance on the next run.
for %%F in ("%INSTALL_DIR%\jd-*.dll") do if /i not "%%~nxF"=="jd-%ID%-%IME_ARCH%.dll" if /i not "%%~nxF"=="jd-%ID%-x64.dll" if /i not "%%~nxF"=="jd-%ID%-x86.dll" del /q "%%F" >nul 2>&1

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
if defined HAD_LOADER echo 已打开的程序不必重新启动：它们会在下一次输入的间隙用上新版本。
if defined HAD_IME echo 已打开的程序要重新启动后才会用上新版本；此后的升级不再需要重新启动程序。
echo 通过以下路径将其添加到键盘列表：
echo     设置 ^> 时间和语言 ^> 语言 ^> 中文（简体） ^>
echo     选项 ^> 添加键盘 ^> 键道
echo 用户自造词可在「开始」菜单的「键道用户自造词」中编辑。
echo.
pause
endlocal
exit /b 0

:NotFound
echo 未找到要安装的文件：
echo     "%SRC_LOADER%"
echo     "%SRC_IME%"
echo.
echo 请先编译：cd windows ^&^& cargo build --release ^&^& loader\build.bat x64
pause
exit /b 1

:NotAdmin
echo 此脚本需要以管理员身份运行。
echo 请右键点击 register.bat 并选择「以管理员身份运行」。
pause
exit /b 1

:NoInstallDir
echo 创建安装目录失败。
pause
exit /b 1

:CopyFailed
echo 复制文件失败，未完成安装。
pause
exit /b 1

REM The installation before this one, if there was one with a loader, is
REM the one in use again: its files are all still there.
:RegisterFailed
echo regsvr32 注册失败。
if not defined PREVIOUS_ID goto :NotRegistered
(echo %PREVIOUS_ID%)>"%INSTALL_DIR%\current.new"
move /Y "%INSTALL_DIR%\current.new" "%INSTALL_DIR%\current" >nul
echo 已恢复使用此前安装的版本。
:NotRegistered
pause
exit /b 1

REM Rename the loaded file %1 to a unique .old-* name. Lines in a CALLed
REM label are parsed one at a time, so %RANDOM% expands at run time here
REM (unlike inside a parenthesized block). Redraw if the name is taken — a
REM stale .old-* can linger loaded from a previous upgrade.
:RenameOld
set "OLD_TARGET=%INSTALL_DIR%\%~1.old-%RANDOM%%RANDOM%"
if exist "%OLD_TARGET%" goto :RenameOld
move /Y "%INSTALL_DIR%\%~1" "%OLD_TARGET%" >nul
exit /b 0

REM Put the loader %FROM% in place as %1. One that is there already and is
REM the same, byte for byte, stays: applications have it loaded, and
REM another copy of it would gain nothing. One that differs is moved out of
REM the way first, as a file that is loaded can be.
:PlaceLoader
if not exist "%INSTALL_DIR%\%~1" goto :CopyLoader
fc /b "%FROM%" "%INSTALL_DIR%\%~1" >nul 2>&1
if not errorlevel 1 exit /b 0
call :RenameOld %~1
:CopyLoader
copy /Y "%FROM%" "%INSTALL_DIR%\%~1" >nul
exit /b %ERRORLEVEL%
