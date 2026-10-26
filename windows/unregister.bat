@echo off
setlocal enableextensions
chcp 65001 >nul

set "INSTALL_DIR=%ProgramFiles%\ime-jd"
set "DLL_NAME=ime_jd.dll"
set "EXE_NAME=ime_jd_userdict.exe"
set "SHORTCUT=%ProgramData%\Microsoft\Windows\Start Menu\Programs\键道用户自造词.lnk"

REM Need admin to delete files under Program Files.
net session >nul 2>&1
if errorlevel 1 goto :not_admin

if not exist "%INSTALL_DIR%" goto :nothing_to_do

REM Unregister from COM/TSF first.
if exist "%INSTALL_DIR%\%DLL_NAME%" regsvr32 /s /u "%INSTALL_DIR%\%DLL_NAME%"

REM The user-dictionary window's Start menu entry. The phrases themselves,
REM in each user's %APPDATA%\ime-jd, are the user's and stay.
del /Q "%SHORTCUT%" >nul 2>&1

REM Best-effort file cleanup. The DLL may still be loaded into running
REM processes that picked up the IME, and the window may be open; those hold
REM their files until they exit. Anything we can't delete now stays in the
REM directory.
del /Q "%INSTALL_DIR%\%DLL_NAME%" >nul 2>&1
del /Q "%INSTALL_DIR%\%EXE_NAME%" >nul 2>&1
del /Q "%INSTALL_DIR%\*.old-*" >nul 2>&1

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
