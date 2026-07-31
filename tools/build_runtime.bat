@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" x86

REM vcvarsall sets INCLUDE/LIB for MSVC ONLY on this machine - it does not pick up
REM the Windows SDK, so cl.exe cannot find stdio.h (it lives in the SDK's ucrt,
REM not in MSVC). Add the SDK explicitly rather than depending on VS having
REM registered it. Guarded on the ucrt include actually being absent, so a
REM properly-configured machine is left alone.
set "WINSDK=C:\Program Files (x86)\Windows Kits\10"
set "WINSDKVER=10.0.26100.0"
echo %INCLUDE% | find /i "\ucrt" >nul
if errorlevel 1 (
    if not exist "%WINSDK%\Include\%WINSDKVER%\ucrt\stdio.h" (
        echo BUILD FAILED: Windows SDK %WINSDKVER% not found at "%WINSDK%"
        exit /b 1
    )
    set "INCLUDE=%INCLUDE%;%WINSDK%\Include\%WINSDKVER%\ucrt;%WINSDK%\Include\%WINSDKVER%\shared;%WINSDK%\Include\%WINSDKVER%\um;%WINSDK%\Include\%WINSDKVER%\winrt"
    set "LIB=%LIB%;%WINSDK%\Lib\%WINSDKVER%\ucrt\x86;%WINSDK%\Lib\%WINSDKVER%\um\x86"
    REM ...and the SDK bin, which holds mt.exe and rc.exe. Without it the
    REM compile succeeds and the LINK fails with CMAKE_MT-NOTFOUND.
    set "PATH=%PATH%;%WINSDK%\bin\%WINSDKVER%\x86"
)
set ROOT=C:\Ascension\Workspace\RaijinLab\runtime
if not exist "%ROOT%\build_x86" mkdir "%ROOT%\build_x86"
cd /d "%ROOT%\build_x86"
cmake -S "%ROOT%\src" -B . -G "NMake Makefiles" -DCMAKE_BUILD_TYPE=Release
nmake
if errorlevel 1 exit /b 1
if not exist "%ROOT%\dist" mkdir "%ROOT%\dist"
copy /Y RaijinLabRuntime.dll "%ROOT%\dist\" >nul
copy /Y RaijinLabLoader.exe "%ROOT%\dist\" >nul
if exist RaijinLabValidate.exe copy /Y RaijinLabValidate.exe "%ROOT%\dist\" >nul
echo BUILD OK
dir "%ROOT%\dist"
