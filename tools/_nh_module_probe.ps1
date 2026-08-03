$p = Get-Process Ascension | Select-Object -First 1
if (-not $p) { Write-Host "no process"; exit }
$target = 0x6A88F090
foreach ($m in $p.Modules) {
    $end = $m.BaseAddress + $m.ModuleMemorySize
    if ($m.BaseAddress -le $target -and $end -ge $target) {
        Write-Host ("HIT: {0} base=0x{1:X} size=0x{2:X} offset=0x{3:X} file={4}" -f $m.ModuleName, $m.BaseAddress, $m.ModuleMemorySize, ($target - $m.BaseAddress), $m.FileName)
    }
}
Write-Host "---"
# Also show the runtime DLL base
foreach ($m in $p.Modules) {
    if ($m.ModuleName -like "*RaijinLab*") {
        Write-Host ("RUNTIME: {0} base=0x{1:X} size=0x{2:X}" -f $m.ModuleName, $m.BaseAddress, $m.ModuleMemorySize)
    }
}
