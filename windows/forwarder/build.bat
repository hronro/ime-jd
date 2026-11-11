@echo off
setlocal enableextensions

REM Builds the forwarder, ime_jd.dll of the ARM64 package (see forwarder.c),
REM as ..\target\forwarder\ime_jd.dll.
REM
REM     build.bat [<resources>]
REM
REM <resources> is the compiled resource file of a build of the IME's DLL:
REM ime_jd.lib in cargo's OUT_DIR for it (..\build.rs writes it there). With
REM it the forwarder carries the IME's manifest, icon and version, so that
REM whatever looks at the registered DLL finds in it what it finds in the
REM IME's own; without it, none of them.
REM
REM Needs Visual Studio's C++ build tools for ARM64, which bring the ARM64EC
REM ones, on an ARM64 or an x64 machine.

set "HERE=%~dp0"
for %%D in ("%~dp0..\target\forwarder") do set "OUT=%%~fD"
set "RESOURCES=%~1"
if defined RESOURCES if not exist "%RESOURCES%" goto :NoResources

REM The compiler for ARM64 that runs on this machine.
set "TOOLS=x64_arm64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "TOOLS=arm64"

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" goto :NoTools
REM The newest Visual Studio that lists the ARM64 tools; if none does, the
REM newest there is, and vcvarsall says whether it has them.
set "VSINSTALL="
for /f "usebackq delims=" %%I in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath`) do set "VSINSTALL=%%I"
if not defined VSINSTALL for /f "usebackq delims=" %%I in (`"%VSWHERE%" -latest -products * -property installationPath`) do set "VSINSTALL=%%I"
if not defined VSINSTALL goto :NoTools
REM vcvarsall runs vswhere itself, by its name alone.
set "PATH=%PATH%;%ProgramFiles(x86)%\Microsoft Visual Studio\Installer"
call "%VSINSTALL%\VC\Auxiliary\Build\vcvarsall.bat" %TOOLS% >nul
if errorlevel 1 goto :NoTools

if not exist "%OUT%" mkdir "%OUT%"
if errorlevel 1 goto :Failed

REM No C runtime (forwarder.c): no stack cookies for one to set up, /GS-,
REM and no library named in the objects, /Zl, beyond the two the linker is
REM given below.
cl /nologo /c /utf-8 /W4 /O1 /GS- /Zl /Fo"%OUT%\forwarder_arm64.obj" "%HERE%forwarder.c"
if errorlevel 1 goto :Failed
cl /nologo /c /utf-8 /W4 /O1 /GS- /Zl /arm64EC /Fo"%OUT%\forwarder_x64.obj" "%HERE%forwarder.c"
if errorlevel 1 goto :Failed

REM One Arm64X DLL of the two: the same exports on the ARM64 side
REM (/defArm64Native) and on the x64 one (/def). libcmt is there for what
REM every ARM64EC image is made with, the helpers its code calls x64 code
REM through and the tables Windows reads, and nothing else is taken from
REM it. The resources, if any, go in as they are.
set RESOURCES_INPUT=
if defined RESOURCES set RESOURCES_INPUT="%RESOURCES%"
link /nologo /dll /noentry /nodefaultlib /machine:arm64x /defArm64Native:"%HERE%forwarder.def" /def:"%HERE%forwarder.def" /out:"%OUT%\ime_jd.dll" "%OUT%\forwarder_arm64.obj" "%OUT%\forwarder_x64.obj" kernel32.lib libcmt.lib %RESOURCES_INPUT%
if errorlevel 1 goto :Failed

echo Built %OUT%\ime_jd.dll
exit /b 0

:NoResources
echo The resource file was not found: %RESOURCES%
exit /b 1

:NoTools
echo Visual Studio's C++ build tools for ARM64 were not found.
exit /b 1

:Failed
echo The forwarder was not built.
exit /b 1
