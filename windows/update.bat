@echo off
setlocal enableextensions
chcp 65001 >nul

REM The IME's own update (src\update) ends here. It downloads a release's
REM zip into the user's temporary folder and starts this script elevated —
REM the installed copy, in a folder only an administrator can write — with
REM the zip's path and the SHA-256 of what it downloaded:
REM
REM     update.bat "<zip>" <sha256>
REM
REM Between the download and here, any program of the user's could have put
REM another file in the zip's place, so nothing is run from where it lies.
REM It is read once, and only if what was read has that SHA-256 are those
REM same bytes written into a folder beside this script, unpacked there, and
REM installed by the release's own register.bat.

REM As in register.bat: started from a 32-bit process, hand over to the
REM 64-bit cmd, which sees the real Program Files and System32. The carets
REM keep the quotes around each path in force for this cmd too, and the
REM exit is on the same line because this script may not be the same file
REM when the other cmd is done with it (see the end).
if not defined PROCESSOR_ARCHITEW6432 goto :Native
if not exist "%SystemRoot%\Sysnative\cmd.exe" goto :Native
"%SystemRoot%\Sysnative\cmd.exe" /d /c ^""%~f0" %*^" && exit /b 0 || exit /b 1
:Native

set "JD_ZIP=%~1"
set "JD_SHA=%~2"
if not defined JD_ZIP goto :Usage
if not defined JD_SHA goto :Usage

REM cmd looks for a program named without a path in the current folder
REM first: let that be this one, not wherever the caller was.
cd /d "%~dp0"

:Stage
set "STAGE=%~dp0update-%RANDOM%%RANDOM%"
if exist "%STAGE%" goto :Stage
mkdir "%STAGE%" >nul 2>&1
if errorlevel 1 goto :NotAdmin
set "JD_STAGED=%STAGE%\update.zip"

REM The paths travel in the environment, so nothing in them needs quoting
REM for PowerShell. Read, checked, and only then written: what is unpacked
REM below is what was checked, whatever happens to the download meanwhile.
echo 正在校验更新包...
powershell -NoProfile -NonInteractive -Command "$ErrorActionPreference = 'Stop'; if ((Get-Item -LiteralPath $env:JD_ZIP).Length -gt 64MB) { exit 1 }; $bytes = [IO.File]::ReadAllBytes($env:JD_ZIP); $hash = -join ([Security.Cryptography.SHA256]::Create().ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }); if ($hash -ne $env:JD_SHA) { exit 1 }; [IO.File]::WriteAllBytes($env:JD_STAGED, $bytes)" >nul
if errorlevel 1 goto :Mismatch

tar -xf "%JD_STAGED%" -C "%STAGE%"
if errorlevel 1 goto :Unpacked
if not exist "%STAGE%\register.bat" goto :Unpacked

REM register.bat installs the release's copy of this script over this one,
REM and cmd reads a script a command at a time, from where it left off in
REM the file. So what follows the call is in one block with it — read
REM whole before any of it runs — and ends the script.
(
    call "%STAGE%\register.bat"
    if errorlevel 1 (
        rmdir /s /q "%STAGE%" >nul 2>&1
        exit /b 1
    )
    rmdir /s /q "%STAGE%" >nul 2>&1
    exit /b 0
)

:NotAdmin
echo 无法写入安装目录：此脚本需要以管理员身份运行。
goto :Failed

:Mismatch
echo 更新包校验未通过，未安装。
goto :Failed

:Unpacked
echo 更新包无法解压，或其中没有 register.bat，未安装。
goto :Failed

:Failed
if defined STAGE rmdir /s /q "%STAGE%" >nul 2>&1
echo 可前往 https://github.com/hronro/ime-jd/releases 下载后手动安装。
echo.
pause
exit /b 1

:Usage
echo 此脚本由键道输入法的自动更新调用，不需要手动运行。
echo 安装或升级，请运行发布包中的 register.bat。
echo.
pause
exit /b 1
