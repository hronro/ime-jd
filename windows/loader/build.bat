@echo off
setlocal enableextensions

REM Builds the loader (loader.c), the DLL that is registered as the IME, for
REM one kind of application:
REM
REM     build.bat x64|x86|arm64x [<resources>]
REM
REM     x64     ..\target\loader\x64\ime_jd.dll       64-bit applications on
REM                                                   x64 Windows
REM     x86     ..\target\loader\x86\ime_jd_x86.dll   32-bit applications
REM     arm64x  ..\target\loader\arm64x\ime_jd.dll    ARM64 and x64
REM                                                   applications on ARM64
REM                                                   Windows: one Arm64X
REM                                                   file with a side for
REM                                                   each
REM
REM <resources> is the compiled resource file of a build of the IME's DLL:
REM ime_jd.lib in cargo's OUT_DIR for it (..\build.rs writes it there). It
REM gives the loader the IME's manifest, icon and version, which Windows
REM looks for in the DLL that is registered: the manifest when it lists the
REM IME among the keyboards to add, the icon when it shows it there. Left
REM out, it is looked for under ..\target, where a build of the IME leaves
REM it.
REM
REM Needs Visual Studio's C++ build tools for the architecture asked for —
REM for arm64x the ARM64 ones, which bring the ARM64EC ones — on an x64 or
REM an ARM64 machine.

set "HERE=%~dp0"
set "KIND=%~1"
set "RESOURCES=%~2"

REM The file's name, the linker's machine, and the compiler: the one for
REM that architecture that runs on this machine — on ARM64 the ARM64 one,
REM and where Visual Studio has none for that pair, the x64 one, which
REM ARM64 Windows runs as well.
set "NAME=ime_jd.dll"
set "MACHINE="
if /i "%KIND%"=="x64" set "MACHINE=x64" & set "TOOLS=x64" & set "TOOLS_ON_ARM64=arm64_x64"
if /i "%KIND%"=="x86" set "MACHINE=x86" & set "TOOLS=x64_x86" & set "TOOLS_ON_ARM64=arm64_x86" & set "NAME=ime_jd_x86.dll"
if /i "%KIND%"=="arm64x" set "MACHINE=arm64x" & set "TOOLS=x64_arm64" & set "TOOLS_ON_ARM64=arm64"
if not defined MACHINE goto :Usage
set "TOOLS_ELSE="
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "TOOLS_ELSE=%TOOLS%" & set "TOOLS=%TOOLS_ON_ARM64%"

for %%D in ("%~dp0..\target\loader\%MACHINE%") do set "OUT=%%~fD"

if not defined RESOURCES call :FindResources
if not defined RESOURCES goto :NoResources
if not exist "%RESOURCES%" goto :NoResources

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" goto :NoTools
REM The newest Visual Studio; for arm64x the newest that lists the ARM64
REM tools, and if none does, the newest there is: vcvarsall says whether it
REM has them.
set "VSINSTALL="
if /i "%MACHINE%"=="arm64x" for /f "usebackq delims=" %%I in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath`) do set "VSINSTALL=%%I"
if not defined VSINSTALL for /f "usebackq delims=" %%I in (`"%VSWHERE%" -latest -products * -property installationPath`) do set "VSINSTALL=%%I"
if not defined VSINSTALL goto :NoTools
REM vcvarsall runs vswhere itself, by its name alone.
set "PATH=%PATH%;%ProgramFiles(x86)%\Microsoft Visual Studio\Installer"
call "%VSINSTALL%\VC\Auxiliary\Build\vcvarsall.bat" %TOOLS% >nul
if errorlevel 1 if defined TOOLS_ELSE call "%VSINSTALL%\VC\Auxiliary\Build\vcvarsall.bat" %TOOLS_ELSE% >nul
if errorlevel 1 goto :NoTools

if not exist "%OUT%" mkdir "%OUT%"
if errorlevel 1 goto :Failed

REM No C runtime (loader.c): no stack cookies for one to set up, /GS-, and
REM no library named in the objects, /Zl, beyond those the linker is given
REM below.
set COMPILE=cl /nologo /c /utf-8 /W4 /O1 /GS- /Zl
set LINK_DLL=link /nologo /dll /noentry /nodefaultlib /out:"%OUT%\%NAME%"
set LIBRARIES=kernel32.lib user32.lib oleaut32.lib "%RESOURCES%"

if /i "%MACHINE%"=="arm64x" goto :Arm64X

%COMPILE% /Fo"%OUT%\loader.obj" "%HERE%loader.c"
if errorlevel 1 goto :Failed
%LINK_DLL% /machine:%MACHINE% /def:"%HERE%loader.def" "%OUT%\loader.obj" %LIBRARIES%
if errorlevel 1 goto :Failed
goto :Built

:Arm64X
REM One Arm64X DLL of two compilations: the same exports on the ARM64 side
REM (/defArm64Native) and on the x64 one (/def), which is ARM64EC code.
REM libcmt is there for what every ARM64EC image is made with, the helpers
REM its code calls x64 code through and the tables Windows reads, and
REM nothing else is taken from it.
%COMPILE% /Fo"%OUT%\loader_arm64.obj" "%HERE%loader.c"
if errorlevel 1 goto :Failed
%COMPILE% /arm64EC /Fo"%OUT%\loader_x64.obj" "%HERE%loader.c"
if errorlevel 1 goto :Failed
%LINK_DLL% /machine:arm64x /defArm64Native:"%HERE%loader.def" /def:"%HERE%loader.def" "%OUT%\loader_arm64.obj" "%OUT%\loader_x64.obj" %LIBRARIES% libcmt.lib
if errorlevel 1 goto :Failed

:Built
echo Built %OUT%\%NAME%
exit /b 0

REM The resources of the newest build of the IME's DLL under ..\target,
REM whichever architecture it was for: they are the same for all. The path
REM travels in the environment, so nothing in it needs quoting for
REM PowerShell.
:FindResources
set "JD_TARGET=%HERE%..\target"
for /f "usebackq delims=" %%F in (`powershell -NoProfile -NonInteractive -Command "Get-ChildItem -LiteralPath $env:JD_TARGET -Recurse -Filter ime_jd.lib -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\release\\build\\jd-windows-[^\\]+\\out\\ime_jd\.lib$' } | Sort-Object LastWriteTime | Select-Object -Last 1 -ExpandProperty FullName"`) do set "RESOURCES=%%F"
exit /b 0

:Usage
echo usage: build.bat x64^|x86^|arm64x [^<resources^>]
exit /b 1

:NoResources
echo The IME's compiled resources were not found: %RESOURCES%
echo Build the IME first (cargo build --release), or give the path of its ime_jd.lib.
exit /b 1

:NoTools
echo Visual Studio's C++ build tools for %KIND% were not found.
exit /b 1

:Failed
echo The loader was not built.
exit /b 1
