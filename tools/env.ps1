# Source this to put RaijinLab tools on PATH for the session
$RL = "C:\Ascension\Workspace\RaijinLab"
$env:RAIJINLAB_ROOT = $RL
$env:JAVA_HOME = Join-Path $RL "tools\bin\jdk-21.0.11+10"
$ghidra = Join-Path $RL "tools\bin\ghidra_11.3.2_PUBLIC"
$dnspy = Join-Path $RL "tools\bin\dnSpy"
$env:PATH = @(
  (Join-Path $env:JAVA_HOME "bin"),
  $ghidra,
  $dnspy,
  (Join-Path $RL "tools\bin"),
  "C:\Program Files\7-Zip",
  $env:PATH
) -join ";"

Write-Host "RaijinLab env ready"
Write-Host "  JAVA_HOME=$env:JAVA_HOME"
Write-Host "  ghidraRun.bat / dnSpy.exe / deploy_addon.ps1"
Write-Host "  Client: C:\Ascension\Launcher\resources\ascension-live"
Write-Host "  x32dbg: run 'x32dbg' if winget install completed"

# x64dbg / x32dbg (Ascension is x86 -> use x32dbg)
$env:PATH = "C:\Users\Administrator\AppData\Local\Microsoft\WinGet\Packages\x64dbg.x64dbg_Microsoft.Winget.Source_8wekyb3d8bbwe\release\x32;C:\Users\Administrator\AppData\Local\Microsoft\WinGet\Packages\x64dbg.x64dbg_Microsoft.Winget.Source_8wekyb3d8bbwe\release\x64;$env:PATH"
