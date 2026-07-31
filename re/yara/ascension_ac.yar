rule Ascension_DivxTac_AntiCheatService
{
    meta:
        description = "DivxTac AntiCheatService markers"
    strings:
        $a = "AntiCheatService" ascii
        $b = "DetectHackProcesses" ascii
        $c = "DetectHackModules" ascii
        $d = "DetourMgr" ascii
        $e = "AnticheatInitializeHandler" ascii
    condition:
        uint16(0) == 0x5A4D and 3 of them
}

rule Ascension_Extensions_MemoryBridge
{
    meta:
        description = "Extensions MemoryBridge client markers"
    strings:
        $a = "MemoryBridgeClient" ascii
        $b = "MMgr64.exe" ascii
        $c = "object token" ascii
        $d = "AnticheatMgr" ascii
        $e = ".vm_sec" ascii
    condition:
        uint16(0) == 0x5A4D and 3 of them
}

rule Ascension_MMgr64_Server
{
    meta:
        description = "MMgr64 MemoryBridge server"
    strings:
        $a = "MemoryBridgeServer" ascii
        $b = "CreateFileMappingW" ascii
        $c = "object security descriptor" ascii
        $d = "protocol={}" ascii
    condition:
        uint16(0) == 0x5A4D and 2 of them
}
