# Deploy RaijinLab addon into Ascension Interface/AddOns
param(
    [string]$ClientRoot = "C:\Ascension\Launcher\resources\ascension-live",
    [string]$Source = "C:\Ascension\Workspace\RaijinLab\addon"
)

$dest = Join-Path $ClientRoot "Interface\AddOns\RaijinLab"
Write-Host "Deploy $Source -> $dest"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
# Clean dest files but keep folder
Get-ChildItem $dest -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
robocopy $Source $dest /E /XD .git /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
# robocopy uses a BITMASK, not a status: 0-7 are all success (1 = files copied,
# 2 = extra files, 3 = both...), only >=8 is a real failure. Leaking it as this
# script's exit code made every successful deploy report failure - and would have
# hidden a genuine one.
if ($LASTEXITCODE -ge 8) { Write-Error "Deploy failed: robocopy $LASTEXITCODE"; exit 1 }
if (-not (Test-Path (Join-Path $dest "RaijinLab.toc"))) {
    Write-Error "Deploy failed: TOC missing"
    exit 1
}
Write-Host "OK: deployed $(@(Get-ChildItem $dest -Recurse -File).Count) files"
Write-Host "Enable in-game character addon list if needed (AddOns button at character select)."
exit 0
