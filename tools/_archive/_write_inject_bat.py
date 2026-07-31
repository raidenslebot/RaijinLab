from pathlib import Path

text = r"""@echo off
setlocal EnableExtensions
title RaijinLab Runtime Log
color 0A

rem Live log session: verbose file logging + PEB unlink
set RL_LOG=1
set RL_PEB_UNLINK=1

set BUILD=C:\Ascension\Workspace\RaijinLab\runtime\build_x86\RaijinLabRuntime.dll
set DIST=C:\Ascension\Workspace\RaijinLab\runtime\dist
set LOADER=%DIST%\RaijinLabLoader.exe
set LOGDIR=C:\Ascension\Workspace\logs
set LOG=%LOGDIR%\runtime.log
set DLL=

if exist "%BUILD%" set DLL=%BUILD%
if not defined DLL if exist "%DIST%\RaijinLabRuntime.dll" set DLL=%DIST%\RaijinLabRuntime.dll

if not exist "%LOGDIR%" mkdir "%LOGDIR%"

echo.
echo ============================================================
echo  RaijinLab inject + live runtime log
echo  Be fully IN-WORLD first (not character select).
echo ============================================================
echo.

if not defined DLL (
  echo [ERROR] Runtime DLL not found.
  echo Build with tools\build_runtime.bat first.
  goto end
)
if not exist "%LOADER%" (
  echo [ERROR] Loader missing: %LOADER%
  goto end
)
if not exist "%DLL%" (
  echo [ERROR] DLL missing: %DLL%
  goto end
)

echo Loader: %LOADER%
echo DLL:    %DLL%
for %%A in ("%DLL%") do echo Size:   %%~zA  Date: %%~tA
echo Log:    %LOG%
echo Env:    RL_LOG=%RL_LOG%  RL_PEB_UNLINK=%RL_PEB_UNLINK%
echo.

if exist "%LOG%" (
  copy /Y "%LOG%" "%LOGDIR%\runtime.prev.log" >nul 2>&1
)
echo.>"%LOG%"
echo === inject session %DATE% %TIME% ===>>"%LOG%"

echo Staging random module name + inject into Ascension.exe ...
echo.

"%LOADER%" --dll "%DLL%"
set ERR=%ERRORLEVEL%
echo.
if %ERR% equ 0 (
  echo [OK] inject finished exit=0
  echo [OK] Next: /reload in-game, then /raijin status
  echo.
  echo ------------------------------------------------------------
  echo  LIVE LOG - every runtime event streams below.
  echo  Window stays open. Ctrl+C stops tail only; then press a key.
  echo  Log file: %LOG%
  echo ------------------------------------------------------------
  echo.
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Write-Host '[tail] waiting for runtime.log ...'; $p='%LOG%'; if (-not (Test-Path $p)) { New-Item -ItemType File -Path $p -Force | Out-Null }; Get-Content -LiteralPath $p -Wait -Tail 100"
) else (
  echo [FAIL] inject exit=%ERR%
  echo Common causes:
  echo   - Ascension.exe not running / not in-world
  echo   - Need admin
  echo   - Wrong DLL arch
  echo.
  echo Last log lines:
  if exist "%LOG%" type "%LOG%"
)

:end
echo.
echo --- inject window idle (press any key to close) ---
pause >nul
endlocal
"""

path = Path(__file__).with_name("inject.bat")
data = text.replace("\r\n", "\n").replace("\n", "\r\n").encode("ascii")
path.write_bytes(data)
print("wrote", path, "bytes", len(data))
print("first16", list(data[:16]))
print("nul_in_first100", data[:100].count(0))
