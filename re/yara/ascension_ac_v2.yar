// Ascension anti-cheat YARA — v2 companion rules
// Companion to ascension_ac.yar; adds signatures for newly-verified
// components: Extensions.dll violation sink FUN_100b5650, DivxTac
// managed anti-cheat surface + HWID collection, MMgr64 MemoryBridge
// protocol, and the ExtendedAnticheatMgr singleton RTTI.

rule Ascension_Ext_Sink_FUN_100b5650
{
    meta:
        description = "Extensions.dll violation sink FUN_100b5650 prologue (VA 0x100b5650 / file 0xb4a50) — target of all 14 anti-debug vectors"
        author      = "Claude"
        date        = "2026-07-20"
    strings:
        // 20-byte prologue extracted from Extensions.dll at file offset 0xb4a50
        // push ebx; mov ebx,esp; sub esp,8; and esp,0FFFFFFF0h; add esp,4; push ebp; mov ebp,[ebx+4]; mov [esp+4],ebp
        $prologue = { 53 8B DC 83 EC 08 83 E4 F0 83 C4 04 55 8B 6B 04 89 6C 24 04 }
    condition:
        uint16(0) == 0x5A4D and any of them
}

rule Ascension_DivxTac_ManagedAC
{
    meta:
        description = "DivxTac managed anti-cheat surface (AntiCheatService + BannedProccessesManaged + DetourMgr + banned-process list handler)"
        author      = "Claude"
        date        = "2026-07-20"
    strings:
        $a = "AntiCheatService" ascii
        $b = "BannedProccessesManaged" ascii
        $c = "DetourMgr" ascii
        $d = "AnticheatBannedProcessListHandler" ascii
    condition:
        uint16(0) == 0x5A4D and 3 of them
}

rule Ascension_DivxTac_HWID
{
    meta:
        description = "DivxTac HDD-serial HWID collection (SMART IOCTL path via MasterHardDiskSerial)"
        author      = "Claude"
        date        = "2026-07-20"
    strings:
        $a = "SMART_GET_VERSION" ascii
        $b = "\\\\.\\PhysicalDrive0" ascii
        $c = "DFP_RECEIVE_DRIVE_DATA" ascii
    condition:
        uint16(0) == 0x5A4D and 2 of them
}

rule Ascension_MMgr64_Bridge
{
    meta:
        description = "MMgr64 MemoryBridge protocol marker (protocol-string only; NO cross-module magic — the 0xDEADBABE context tag is DivxTac-internal, does NOT appear in MMgr64)"
        author      = "Claude"
        date        = "2026-07-20 (corrected 2026-07-20)"
    strings:
        $proto = "MemoryBridge" ascii
    condition:
        uint16(0) == 0x5A4D and $proto
}

rule Ascension_DivxTac_HandlerMagic
{
    meta:
        description = "DivxTac SetMessageHandlers context magic 0xDEADBABE — passed as void* context to AnticheatInitializeHandler (opcode 14) and AnticheatBannedProcessListHandler (opcode 35). DivxTac-only, 2 hits inside file range 0x4CBC-0x4D10."
        author      = "Claude"
        date        = "2026-07-20"
    strings:
        // 0xDEADBABE little-endian (NOT 0xDEADC0BE — V1 arithmetic error corrected)
        $magic = { BE BA AD DE }
    condition:
        uint16(0) == 0x5A4D and #magic >= 2
}

rule Ascension_ExtendedAnticheatMgr
{
    meta:
        description = "ExtendedAnticheatMgr RTTI type descriptors (singleton + TemplatedSingleton wrapper)"
        author      = "Claude"
        date        = "2026-07-20"
    strings:
        $a = ".?AVExtendedAnticheatMgr@@" ascii
        $b = ".?AV?$TemplatedSingleton@VExtendedAnticheatMgr@@@@" ascii
    condition:
        uint16(0) == 0x5A4D and any of them
}
