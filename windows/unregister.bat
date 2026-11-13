@echo off
setlocal enableextensions
chcp 65001 >nul

REM As in register.bat: started from a 32-bit process, hand over to the
REM 64-bit cmd, which sees the real Program Files and System32.
if not defined PROCESSOR_ARCHITEW6432 goto :Native
if not exist "%SystemRoot%\Sysnative\cmd.exe" goto :Native
"%SystemRoot%\Sysnative\cmd.exe" /c ""%~f0" %*"
exit /b %ERRORLEVEL%
:Native

set "INSTALL_DIR=%ProgramFiles%\ime-jd"
REM What register.bat installs: the loaders, which are what is registered,
REM and behind them the IME of the installation in use, jd-<id>-<arch>.dll,
REM named by `current`.
set "LOADER_NAME=ime_jd.dll"
set "LOADER32_NAME=ime_jd_x86.dll"
set "REGSVR32_32=%SystemRoot%\SysWOW64\regsvr32.exe"
set "EXE_NAME=ime_jd_userdict.exe"
set "SHORTCUT=%ProgramData%\Microsoft\Windows\Start Menu\Programs\键道用户自造词.lnk"

REM Need admin to delete files under Program Files; tested as in
REM register.bat.
fltmc >nul 2>&1
if errorlevel 1 goto :not_admin

if not exist "%INSTALL_DIR%" goto :nothing_to_do

REM Unregister from COM/TSF first, the 32-bit side with the 32-bit regsvr32.
REM The loader is asked, and passes it on to the IME in use. Where there is
REM no loader, or it does not find the IME, every IME that is there is
REM asked itself: any of them takes out what all of them register. So is,
REM before the loader, what an installation from before there was one has
REM behind its ime_jd.dll on ARM64.
set "ASK_IME32=1"
if exist "%INSTALL_DIR%\%LOADER32_NAME%" "%REGSVR32_32%" /s /u "%INSTALL_DIR%\%LOADER32_NAME%" && set "ASK_IME32="
if defined ASK_IME32 for %%F in ("%INSTALL_DIR%\jd-*-x86.dll") do "%REGSVR32_32%" /s /u "%%F"
if exist "%INSTALL_DIR%\ime_jd_arm64.dll" regsvr32 /s /u "%INSTALL_DIR%\ime_jd_arm64.dll"
set "ASK_IME=1"
if exist "%INSTALL_DIR%\%LOADER_NAME%" regsvr32 /s /u "%INSTALL_DIR%\%LOADER_NAME%" && set "ASK_IME="
if defined ASK_IME for %%F in ("%INSTALL_DIR%\jd-*-arm64.dll" "%INSTALL_DIR%\jd-*-x64.dll") do regsvr32 /s /u "%%F"

REM The user-dictionary window's Start menu entry. The phrases themselves,
REM in each user's %APPDATA%\ime-jd, are the user's and stay.
del /Q "%SHORTCUT%" >nul 2>&1

REM Best-effort file cleanup. The DLLs may still be loaded into running
REM processes that picked up the IME, and the window may be open; those hold
REM their files until they exit. Anything we can't delete now stays in the
REM directory.
del /Q "%INSTALL_DIR%\%LOADER_NAME%" >nul 2>&1
del /Q "%INSTALL_DIR%\%LOADER32_NAME%" >nul 2>&1
del /Q "%INSTALL_DIR%\jd-*.dll" >nul 2>&1
del /Q "%INSTALL_DIR%\current" >nul 2>&1
del /Q "%INSTALL_DIR%\current.new" >nul 2>&1
REM An installation from before there was a loader, on ARM64.
del /Q "%INSTALL_DIR%\ime_jd_arm64.dll" >nul 2>&1
del /Q "%INSTALL_DIR%\ime_jd_x64.dll" >nul 2>&1
del /Q "%INSTALL_DIR%\%EXE_NAME%" >nul 2>&1
del /Q "%INSTALL_DIR%\*.old-*" >nul 2>&1
REM The update's script, and what an update cut short may have left.
del /Q "%INSTALL_DIR%\update.bat" >nul 2>&1
for /d %%D in ("%INSTALL_DIR%\update-*") do rmdir /s /q "%%D" >nul 2>&1

REM Remove the directory if it's empty.
rmdir "%INSTALL_DIR%" >nul 2>&1

if exist "%INSTALL_DIR%" goto :partial
goto :done

:not_admin
echo 此脚本需要以管理员身份运行。
echo 请右键点击 unregister.bat 并选择「以管理员身份运行」。
goto :end

:nothing_to_do
echo 无需操作：%INSTALL_DIR% 不存在。
goto :end

:partial
echo.
echo 键道输入法已注销，但 %INSTALL_DIR% 中仍有残留文件：
echo DLL 仍被一个或多个运行中的进程加载（或用户自造词窗口仍开着）。
echo 请注销并重新登录（或重启系统）以释放它，然后重新运行此脚本，
echo 或手动删除该文件夹。
goto :end

:done
echo.
echo 键道输入法已完全卸载。
goto :end

:end
echo.
pause
endlocal
