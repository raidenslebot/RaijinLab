// ============================================================================
// ac_frida_hooks.js — Ascension AC surveillance agent (Frida)
// ----------------------------------------------------------------------------
// Usage:
//     frida -n Ascension.exe -l ac_frida_hooks.js
//     frida -n Ascension.exe -l ac_frida_hooks.js --runtime=v8
//
// Environment overrides (all optional):
//     FRIDA_AC_SILENT_S1=1     silence S1.01/S1.02 VirtualProtect spam
//     FRIDA_AC_DUMP_PACKETS=1  dump S7 CDataStore packet bodies on emit
//     FRIDA_AC_BACKTRACE=1     print resolved stack traces on every hit
//
// Scope:
//   Attaches Interceptor hooks against Ascension.exe process. This covers
//   Ascension.exe (base 0x00400000) and Extensions.dll (base 0x10000000) and
//   DivxTac.dll (if loaded — attaches lazily on Module.load). MMgr64.exe is a
//   SEPARATE x64 process — run a second frida session against it if needed.
//
// The BP table below is the ac_breakpoint_catalog v2 enrichment verbatim. Each
// row is a self-describing hook definition. The runner picks a strategy per
// row (generic-trace, sink-with-packet-dump, iat-filter, data-bp, il-managed).
// IL managed rows (S4.*, S5.*, S10.01/02/05) are stubbed as native BPs on the
// method IL start (native trap on managed code) — usable to observe, not to
// patch (patching would require IL rewriting via mono/clr — out of scope here).
// ============================================================================

'use strict';

// ---- module-base cache -----------------------------------------------------
const MOD = { asc: null, ext: null, div: null };

function findModule(name) {
    try { return Process.findModuleByName(name); } catch (_) { return null; }
}
function refreshModules() {
    MOD.asc = MOD.asc || findModule('Ascension.exe');
    MOD.ext = MOD.ext || findModule('Extensions.dll');
    MOD.div = MOD.div || findModule('DivxTac.dll');
}
function resolveVA(mod, va) {
    // catalog VAs are absolute (as loaded at preferred base). Compute the
    // in-process address by applying the current load slide.
    if (!mod) return null;
    let preferredBase;
    if (mod.name === 'Ascension.exe') preferredBase = 0x00400000;
    else if (mod.name === 'Extensions.dll') preferredBase = 0x10000000;
    else if (mod.name === 'DivxTac.dll')    preferredBase = 0x10000000;
    else preferredBase = mod.base;
    const slide = mod.base.sub(preferredBase);
    return ptr(va).add(slide);
}

function resolveSymbol(addr) {
    try {
        const s = DebugSymbol.fromAddress(addr);
        if (s && s.name) return `${s.moduleName}!${s.name}+0x${s.offset.toString(16)}`;
    } catch (_) {}
    try {
        const m = Process.findModuleByAddress(addr);
        if (m) return `${m.name}+0x${addr.sub(m.base).toString(16)}`;
    } catch (_) {}
    return `0x${addr.toString(16)}`;
}

function bt(ctx, depth) {
    depth = depth || 8;
    try {
        return Thread.backtrace(ctx, Backtracer.ACCURATE)
            .slice(0, depth)
            .map(resolveSymbol)
            .join('\n    ');
    } catch (e) {
        return '<backtrace failed: ' + e.message + '>';
    }
}

// ---- CDataStore packet dumper ---------------------------------------------
// From notes/11c: at the emit call site the CDataStore lvalue is [ebp-0xB0].
// Layout observed:
//     [this+0x00] buffer_ptr   (payload bytes)
//     [this+0x08] len_maybe
//     [this+0x10] opcode_slot  (dword; = 0x51F/0x520/0x2E7 at emit time)
// This is best-effort; if the layout mismatches you get a hex hexdump of the
// first 0x40 bytes and can post-process.
function dumpCDataStore(thisPtr, label) {
    if (!thisPtr || thisPtr.isNull()) {
        console.log('  [PKT] ' + label + ' this=NULL');
        return;
    }
    try {
        const bufPtr = thisPtr.readPointer();
        const len    = thisPtr.add(0x08).readU32();
        const opcode = thisPtr.add(0x10).readU32();
        console.log(`  [PKT] ${label} this=${thisPtr} buf=${bufPtr} len=0x${len.toString(16)} opcode=0x${opcode.toString(16)} (${opcode})`);
        if (bufPtr && !bufPtr.isNull() && len > 0 && len < 0x10000) {
            console.log(hexdump(bufPtr, { length: Math.min(len, 0x100), ansi: false, header: false }));
        } else {
            console.log(hexdump(thisPtr, { length: 0x40, ansi: false, header: false }));
        }
    } catch (e) {
        console.log('  [PKT] ' + label + ' dump failed: ' + e.message);
        try { console.log(hexdump(thisPtr, { length: 0x40, ansi: false, header: false })); } catch (_) {}
    }
}

// ---- packet-dump wrapper for the shared preparer @ Ascension!0x0047B0A0 ---
// The single "highest-leverage hook" (S1.05 / S7.06). ecx=CDataStore*,
// [esp+4]=opcode. Filter to AC opcodes (1311/1312/742/743) and dump.
function hookCDataStorePutOpcode() {
    if (!MOD.asc) return;
    const addr = resolveVA(MOD.asc, 0x0047B0A0);
    Interceptor.attach(addr, {
        onEnter: function (args) {
            // __thiscall: this in ECX, opcode in [esp+4]
            const opcode = this.context.esp.add(4).readU32();
            const isAC = (opcode === 0x51F || opcode === 0x520 ||
                          opcode === 0x2E6 || opcode === 0x2E7 ||
                          opcode === 14    || opcode === 35);
            if (!isAC && !global.__DUMP_ALL_OPCODES) return;
            const tag = (opcode === 0x51F) ? 'CMSG_ANTICHEAT_ALERT'
                     : (opcode === 0x520)  ? 'CMSG_ANTICHEAT_VERSION'
                     : (opcode === 0x2E6)  ? 'SMSG_WARDEN_DATA'
                     : (opcode === 0x2E7)  ? 'CMSG_WARDEN_DATA'
                     : `opcode_${opcode}`;
            console.log(`\n[S7.06] CDataStore::PutOpcode  ${tag} (0x${opcode.toString(16)})`);
            this.thisPtr = this.context.ecx;
            if (process.env.FRIDA_AC_DUMP_PACKETS === '1') dumpCDataStore(this.thisPtr, 'pre-put');
            if (process.env.FRIDA_AC_BACKTRACE === '1')
                console.log('    ' + bt(this.context, 10));
        },
        onLeave: function () {
            if (process.env.FRIDA_AC_DUMP_PACKETS === '1' && this.thisPtr)
                dumpCDataStore(this.thisPtr, 'post-put');
        }
    });
    console.log('[boot] Hooked S7.06 CDataStore::PutOpcode @ ' + addr);
}

// ---- Extensions violation sink @ FUN_100b5650 -----------------------------
// S3.15 — the single chokepoint that funnels ALL 14 vectors. [ebx+8]=vector,
// [ebx+0xC]=extra. Log both; if packet dump requested, walk the CDataStore
// at [ebp-0xB0] just prior to send @ +0x343.
function hookExtensionsSink() {
    if (!MOD.ext) return;
    const addr = resolveVA(MOD.ext, 0x100b5650);
    Interceptor.attach(addr, {
        onEnter: function (args) {
            const ebx = this.context.ebx;
            let vec = 0, extra = 0;
            try { vec   = ebx.add(0x08).readU32(); } catch (_) {}
            try { extra = ebx.add(0x0C).readU32(); } catch (_) {}
            const NAMES = [
                'reserved','DBG_BEINGDEBUGGEDPEB','DBG_CHECKREMOTEDEBUGGERPRESENT',
                'DBG_ISDEBUGGERPRESENT','DBG_NTGLOBALFLAGPEB',
                'DBG_NTQUERYINFORMATIONPROCESS','DBG_FINDWINDOW','v7','v8','v9','v10',
                'DBG_HARDWAREDEBUGREGISTERS','DBG_MOVSS','v13','v14','v15',
                'DBG_CLOSEHANDLEEXCEPTION','DBG_SINGLESTEPEXCEPTION','DBG_INT3CC',
                'DBG_PREFIXHOP','DBG_INT2D'
            ];
            const name = (vec < NAMES.length) ? NAMES[vec] : `v${vec}`;
            console.log(`\n[S3.15] SINK  vector=${vec} (${name})  extra=0x${extra.toString(16)}`);
            if (process.env.FRIDA_AC_BACKTRACE === '1')
                console.log('    ' + bt(this.context, 12));
        }
    });
    console.log('[boot] Hooked S3.15 Extensions sink FUN_100b5650 @ ' + addr);
}

// ---- IAT filter: DivxTac.dll loader kill (S1.07 companion) ----------------
// Detect and log LoadLibraryA("DivxTac.dll"); we do NOT NULL it here (that's
// a patch decision, not a surveillance one) — flip the SUPPRESS flag if you
// want to observe the effect of blocking it live.
const SUPPRESS_DIVXTAC = false;
function hookLoadLibraryA() {
    const p = Module.findExportByName('kernel32.dll', 'LoadLibraryA');
    if (!p) return;
    Interceptor.attach(p, {
        onEnter: function (args) {
            try {
                const name = args[0].readCString();
                this.name = name;
                if (name && name.toLowerCase().indexOf('divxtac') >= 0) {
                    console.log(`\n[S1.07] LoadLibraryA("${name}")  caller=${resolveSymbol(this.returnAddress)}`);
                    if (SUPPRESS_DIVXTAC) this.suppress = true;
                }
            } catch (_) {}
        },
        onLeave: function (retval) {
            if (this.suppress) {
                console.log('[S1.07] SUPPRESSED — returning NULL');
                retval.replace(ptr(0));
            } else if (this.name && this.name.toLowerCase().indexOf('divxtac') >= 0) {
                console.log(`[S1.07] LoadLibraryA -> ${retval}`);
            }
        }
    });
    console.log('[boot] Hooked KERNEL32!LoadLibraryA (filter: DivxTac.dll)');
}

// ---- IAT filter: DeviceIoControl HWID IOCTL surveillance (S4.10/S10.03) ---
function hookDeviceIoControl() {
    const p = Module.findExportByName('kernel32.dll', 'DeviceIoControl');
    if (!p) return;
    const HWID_IOCTLS = { 0x74080: 'SMART_GET_VERSION',
                          0x7C088: 'SMART_RCV_DRIVE_DATA',
                          0x2D1400: 'STORAGE_QUERY_PROPERTY',
                          0x70020: 'IOCTL_DISK_GET_DRIVE_GEOMETRY_EX' };
    Interceptor.attach(p, {
        onEnter: function (args) {
            const ioctl = args[1].toInt32() >>> 0;
            if (HWID_IOCTLS[ioctl] !== undefined) {
                console.log(`\n[S10.03] DeviceIoControl  ioctl=0x${ioctl.toString(16)} (${HWID_IOCTLS[ioctl]})  caller=${resolveSymbol(this.returnAddress)}`);
            }
        }
    });
    console.log('[boot] Hooked KERNEL32!DeviceIoControl (filter: HWID IOCTLs)');
}

// ---- IsDebuggerPresent surveillance (S3.03 / S4.09 / S4.11 / S8.17) -------
function hookIsDebuggerPresent() {
    const p = Module.findExportByName('kernel32.dll', 'IsDebuggerPresent');
    if (!p) return;
    Interceptor.attach(p, {
        onEnter: function () {
            this.caller = this.returnAddress;
        },
        onLeave: function (rv) {
            const sym = resolveSymbol(this.caller);
            console.log(`[IDP]  IsDebuggerPresent -> ${rv}  caller=${sym}`);
        }
    });
    console.log('[boot] Hooked KERNEL32!IsDebuggerPresent');
}

// ---- WardenClient dispatcher (S11.01/S11.02/S11.04/S11.05/S11.06) ---------
function hookWardenClient() {
    if (!MOD.asc) return;
    const rows = [
        { id: 'S11.01', va: 0x007DA850, name: 'WardenClient::OnPacket'          },
        { id: 'S11.04', va: 0x007DA500, name: 'Warden memcpy primitive A'       },
        { id: 'S11.05', va: 0x007DA550, name: 'Warden memcpy primitive B'       },
        { id: 'S11.06', va: 0x007DAAE9, name: 'CMSG_WARDEN_DATA build/send'     }
    ];
    rows.forEach(function (r) {
        const a = resolveVA(MOD.asc, r.va);
        try {
            Interceptor.attach(a, {
                onEnter: function () {
                    console.log(`\n[${r.id}] ${r.name}  @${a}`);
                    if (process.env.FRIDA_AC_BACKTRACE === '1')
                        console.log('    ' + bt(this.context, 8));
                }
            });
            console.log(`[boot] Hooked ${r.id} ${r.name} @ ${a}`);
        } catch (e) {
            console.log(`[boot] Failed to hook ${r.id}: ${e.message}`);
        }
    });
    // Data-BP-equivalent: watch the singleton pointer write (S11.03) by
    // polling on init. Frida MemoryAccessMonitor accepts pages, not bytes.
    try {
        const pMon = resolveVA(MOD.asc, 0x00D31A4C);
        MemoryAccessMonitor.enable(
            [{ base: pMon.and(~0xfff), size: 0x1000 }],
            { onAccess: function (details) {
                if (details.address.equals(pMon)) {
                    console.log(`\n[S11.03] WardenClient singleton write @ ${pMon} value=${pMon.readPointer()}`);
                }
            }}
        );
        console.log('[boot] Armed S11.03 MemoryAccessMonitor @ ' + pMon);
    } catch (e) {
        console.log('[boot] MemoryAccessMonitor unavailable: ' + e.message);
    }
}

// ---- Generic BP table (top-30 curated + full catalog reference) ----------
// Each entry: { id, mod, va, note }
// mod: 'asc' | 'ext' | 'div'
// Rows already covered by dedicated hookers above are commented as [dedicated]
// but still listed for cross-reference.
const BP_TABLE = [
    // --- Subsystem 1: Boot phase (self-unpack / trampolines / DivxTac load)
    { id: 'S1.01', mod: 'ext', va: 0x1000106B, note: 'ScopedProtect::ctor VirtualProtect call (self-unpack). Fires HUNDREDS of times — silenced unless FRIDA_AC_SILENT_S1 unset.' },
    { id: 'S1.02', mod: 'ext', va: 0x100010E4, note: 'ScopedProtect::dtor VirtualProtect restore. Paired 1:1 with S1.01.' },
    { id: 'S1.03', mod: 'ext', va: 0x100A0A10, note: 'Trampoline builder VirtualProtect (RWX page). Rare after boot.' },
    { id: 'S1.04', mod: 'ext', va: 0x100A0A2E, note: 'Trampoline builder VirtualProtect restore.' },
    { id: 'S1.05', mod: 'asc', va: 0x0047B0A0, note: '[dedicated] CDataStore::PutOpcode preparer — see hookCDataStorePutOpcode.' },
    { id: 'S1.07', mod: 'ext', va: 0x10A3B690, note: 'DivxTac.dll loader stub — patches to C3 kill entire subsystem.' },
    { id: 'S1.09', mod: 'ext', va: 0x10A6BDA5, note: 'DivxTac loader-stub registration into callback container 0x10BE3974.' },

    // --- Subsystem 2: AC thread spawn
    { id: 'S2.01', mod: 'ext', va: 0x10A3DC20, note: 'Parent monitor loop entry (14-vector dispatcher). Patches to C3 kill.' },
    { id: 'S2.02', mod: 'ext', va: 0x10A3E317, note: 'Sleep(5s) inside parent loop — cadence anchor.' },
    { id: 'S2.04', mod: 'ext', va: 0x100B5A70, note: 'Singleton getter for AC-monitor state @ 0x10BDC244.' },
    { id: 'S2.05', mod: 'ext', va: 0x100B5220, note: '_beginthreadex helper thread routine (delayed vector-code write).' },

    // --- Subsystem 3: 14 anti-debug vectors (all callers -> sink FUN_100b5650)
    { id: 'S3.01', mod: 'ext', va: 0x100B5CBA, note: 'V1  DBG_BEINGDEBUGGEDPEB (PEB+2).' },
    { id: 'S3.02', mod: 'ext', va: 0x100B5EB8, note: 'V2  DBG_CHECKREMOTEDEBUGGERPRESENT.' },
    { id: 'S3.03', mod: 'ext', va: 0x100B72F7, note: 'V3  DBG_ISDEBUGGERPRESENT.' },
    { id: 'S3.04', mod: 'ext', va: 0x100B6154, note: 'V6  FindWindowW (single-class variant).' },
    { id: 'S3.05', mod: 'ext', va: 0x100B6C32, note: 'V11 DBG_HARDWAREDEBUGREGISTERS (DR0-DR7).' },
    { id: 'S3.06', mod: 'ext', va: 0x100B76B8, note: 'V4  DBG_NTGLOBALFLAGPEB (PEB+0x68 & 0x70).' },
    { id: 'S3.07', mod: 'ext', va: 0x100B7C79, note: 'V5  DBG_NTQUERYINFORMATIONPROCESS (classes 7/0x1E/0x1F).' },
    { id: 'S3.08', mod: 'ext', va: 0x100B6954, note: 'V16 DBG_CLOSEHANDLEEXCEPTION.' },
    { id: 'S3.09', mod: 'ext', va: 0x100B6731, note: 'V6  FindWindowW (multi-class variant, 1.5KB body).' },
    { id: 'S3.10', mod: 'ext', va: 0x100B6FF1, note: 'V20 DBG_INT2D (CD 2D in SEH).' },
    { id: 'S3.11', mod: 'ext', va: 0x100B7189, note: 'V18 DBG_INT3CC (embedded CC in SEH).' },
    { id: 'S3.12', mod: 'ext', va: 0x100B74BD, note: 'V12 DBG_MOVSS (TF via pushfd|or 0x100|popfd).' },
    { id: 'S3.13', mod: 'ext', va: 0x100B80B2, note: 'V19 DBG_PREFIXHOP.' },
    { id: 'S3.14', mod: 'ext', va: 0x100B82E4, note: 'V17 DBG_SINGLESTEPEXCEPTION.' },
    { id: 'S3.15', mod: 'ext', va: 0x100B5650, note: '[dedicated] Violation SINK — see hookExtensionsSink.' },
    { id: 'S3.16', mod: 'ext', va: 0x100B56DC, note: 'push 0x51F immediately before CDataStore preparer indirect-call.' },
    { id: 'S3.17', mod: 'ext', va: 0x100B56E7, note: 'call [0x10bca0cc] — NOP 6 bytes to prevent packet build.' },
    { id: 'S3.18', mod: 'ext', va: 0x100B5993, note: 'SendPacket call (esi=fptr from [0x10bca1F0]).' },
    { id: 'S3.19', mod: 'ext', va: 0x100B599C, note: 'Latch write: mov byte [0x10bdc24c], 1.' },
    { id: 'S3.20', mod: 'ext', va: 0x100B59D3, note: '_beginthreadex spawning helper FUN_100b5220.' },

    // --- Subsystem 4/5: DivxTac managed (native BPs on IL entry — observe only)
    { id: 'S4.01', mod: 'div', va: 0x100035BC, note: 'DivxTac AntiCheatThreadLoop (managed IL — patch = 0x2A ret).' },
    { id: 'S4.02', mod: 'div', va: 0x100030A0, note: 'DetectHackModules (banned-module scan).' },
    { id: 'S4.03', mod: 'div', va: 0x10003234, note: 'DetectHackProcesses (ProcessName substring match).' },
    { id: 'S4.04', mod: 'div', va: 0x100033F8, note: 'DetectHackTitles (MainWindowTitle substring match).' },
    { id: 'S4.05', mod: 'div', va: 0x10002ED0, note: 'DetectDebugger (P/Invoke IsDebuggerPresent).' },
    { id: 'S4.06', mod: 'div', va: 0x10002FA8, note: 'SendModuleAntiCheatAlert -> opcode 1311.' },
    { id: 'S4.07', mod: 'div', va: 0x100022FC, note: 'SendProcessAntiCheatAlert -> opcode 1311.' },
    { id: 'S4.08', mod: 'div', va: 0x100058C8, note: 'SetMessageHandlers (opcodes 14/35, context 0xDEADBABE).' },
    { id: 'S5.02', mod: 'div', va: 0x10005908, note: 'AnticheatInitializeHandler (opcode 14) -> opcode 1312 with HWID.' },
    { id: 'S5.03', mod: 'div', va: 0x10005580, note: 'AnticheatBannedProcessListHandler (opcode 35) -> populates 3 vectors.' },

    // --- Subsystem 6: DetourMgr (INERT — trace only for regression)
    { id: 'S6.01', mod: 'div', va: 0x10001028, note: '[inert] FunctionMap initializer — DLL_PROCESS_ATTACH once.' },
    { id: 'S6.02', mod: 'div', va: 0x1000100C, note: '[inert] DetourMgr singleton initializer.' },
    { id: 'S6.03', mod: 'div', va: 0x100085A0, note: '[inert] DetourMgr atexit dtor. Mid-session hit = regression.' },
    { id: 'S6.04', mod: 'div', va: 0x10008654, note: '[inert] FunctionMap atexit dtor.' },

    // --- Subsystem 7: Additional AC emit sites
    { id: 'S7.02', mod: 'ext', va: 0x102DBA13, note: 'Emit path 2 (uninvestigated class).' },
    { id: 'S7.03', mod: 'ext', va: 0x10A46260, note: 'Emit path 3 — reason magic 0x225DC89E/0x159E97B6.' },
    { id: 'S7.04', mod: 'ext', va: 0x10A4D292, note: 'Emit path 4 — same reason magic.' },
    { id: 'S7.05', mod: 'ext', va: 0x10A7957B, note: 'Emit path 5 — same reason magic.' },
    { id: 'S7.06', mod: 'asc', va: 0x0047B0A0, note: '[dedicated] SEE hookCDataStorePutOpcode.' },
    { id: 'S7.07', mod: 'ext', va: 0x100B5993, note: 'SendPacket (dup of S3.18).' },
    { id: 'S7.12a', mod: 'ext', va: 0x102C7F84, note: '[inert] Stale name-table trampoline for 1309.' },
    { id: 'S7.12b', mod: 'ext', va: 0x102C7F8A, note: '[inert] Stale name-table trampoline for 1310.' },

    // --- Subsystem 10: HWID collection
    { id: 'S10.01', mod: 'div', va: 0x10003ECC, note: 'ReadPhysicalDriveInNTUsingSmart (ATA IDENTIFY word 10-19).' },
    { id: 'S10.02', mod: 'div', va: 0x10003B30, note: 'ReadPhysicalDriveInNTWithZeroRights (STORAGE_QUERY_PROPERTY).' },
    { id: 'S10.05', mod: 'div', va: 0x10004654, note: 'GetSerialNo — safest single-BP HWID spoof (2A void ret).' },

    // --- Subsystem 11: Ascension.exe native Warden (LIVE)
    { id: 'S11.01', mod: 'asc', va: 0x007DA850, note: '[dedicated] SEE hookWardenClient.' },
    { id: 'S11.02', mod: 'asc', va: 0x007DA917, note: 'SetMessageHandler(0x2E6, 0x7DA850, 0) — NOP 5 bytes = kill switch.' },
    { id: 'S11.04', mod: 'asc', va: 0x007DA500, note: '[dedicated] SEE hookWardenClient.' },
    { id: 'S11.05', mod: 'asc', va: 0x007DA550, note: '[dedicated] SEE hookWardenClient.' },
    { id: 'S11.06', mod: 'asc', va: 0x007DAAE9, note: '[dedicated] SEE hookWardenClient.' }
];

function attachGenericTable() {
    let attached = 0, skipped = 0;
    const silent1 = (process.env.FRIDA_AC_SILENT_S1 === '1');
    BP_TABLE.forEach(function (row) {
        const mod = MOD[row.mod];
        if (!mod) { skipped++; return; }
        // Skip anything already handled by a dedicated hook to avoid double-fire
        if (/\[dedicated\]/.test(row.note)) return;
        if (silent1 && (row.id === 'S1.01' || row.id === 'S1.02')) return;
        const addr = resolveVA(mod, row.va);
        try {
            Interceptor.attach(addr, {
                onEnter: function () {
                    console.log(`[${row.id}] hit @${addr}  ${row.note}`);
                    if (process.env.FRIDA_AC_BACKTRACE === '1')
                        console.log('    ' + bt(this.context, 6));
                }
            });
            attached++;
        } catch (e) {
            console.log(`[boot] Failed to attach ${row.id} @ ${addr}: ${e.message}`);
        }
    });
    console.log(`[boot] Generic table: attached=${attached} skipped=${skipped}`);
}

// ---- module-load watcher for DivxTac ---------------------------------------
function watchDivxTacLoad() {
    if (MOD.div) return;
    // hook LdrLoadDll return to catch DivxTac.dll appearing
    const loadLibW = Module.findExportByName('kernel32.dll', 'LoadLibraryW');
    if (!loadLibW) return;
    Interceptor.attach(loadLibW, {
        onLeave: function (retval) {
            if (MOD.div) return;
            refreshModules();
            if (MOD.div) {
                console.log('\n[boot] DivxTac.dll loaded — attaching subsystem 4/5/10 hooks');
                attachDivxTacRows();
            }
        }
    });
}
function attachDivxTacRows() {
    BP_TABLE.filter(r => r.mod === 'div' && !/\[dedicated\]/.test(r.note)).forEach(function (row) {
        try {
            const a = resolveVA(MOD.div, row.va);
            Interceptor.attach(a, { onEnter: function () {
                console.log(`[${row.id}] hit @${a}  ${row.note}`);
            }});
        } catch (_) {}
    });
}

// ============================================================================
// BOOT
// ============================================================================
function boot() {
    console.log('================================================================');
    console.log(' ac_frida_hooks.js — Ascension AC surveillance agent');
    console.log(' Catalog: notes/12_ac_breakpoint_catalog.md v2 (S1..S11 + gaps)');
    console.log(' Runtime : Frida ' + Frida.version);
    console.log(' Process : ' + Process.id + ' arch=' + Process.arch);
    console.log('----------------------------------------------------------------');
    console.log(' Env flags: FRIDA_AC_SILENT_S1=' + (process.env.FRIDA_AC_SILENT_S1 || '0'));
    console.log('            FRIDA_AC_DUMP_PACKETS=' + (process.env.FRIDA_AC_DUMP_PACKETS || '0'));
    console.log('            FRIDA_AC_BACKTRACE=' + (process.env.FRIDA_AC_BACKTRACE || '0'));
    console.log('================================================================');

    refreshModules();
    console.log('[boot] Ascension.exe   = ' + (MOD.asc ? MOD.asc.base : 'NOT LOADED'));
    console.log('[boot] Extensions.dll  = ' + (MOD.ext ? MOD.ext.base : 'NOT LOADED'));
    console.log('[boot] DivxTac.dll     = ' + (MOD.div ? MOD.div.base : 'NOT LOADED — lazy attach armed'));

    // Dedicated hooks first
    if (MOD.asc) {
        hookCDataStorePutOpcode();
        hookWardenClient();
    }
    if (MOD.ext) {
        hookExtensionsSink();
    }
    hookLoadLibraryA();
    hookDeviceIoControl();
    hookIsDebuggerPresent();

    // Generic table for everything else
    attachGenericTable();

    // Lazy DivxTac attach
    watchDivxTacLoad();

    console.log('[boot] READY. Waiting for AC traffic...\n');
}

// ---- entry -----------------------------------------------------------------
// Frida evaluates top-level; wrap in setImmediate to let module list settle.
setImmediate(function () {
    try { boot(); }
    catch (e) { console.log('[boot] FATAL: ' + e.stack); }
});
