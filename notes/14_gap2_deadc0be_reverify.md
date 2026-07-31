# GAP 2 Re-verification — DivxTac SetMessageHandlers "context magic"

**Date:** 2026-07-20
**Author:** Claude (V2 patch round)
**Status:** ✅ RESOLVED — V1 was WRONG. Correcting from `0xDEADC0BE` → **`0xDEADBABE`**.

---

## Verdict

**REFUTED (V1 value).** The context magic passed to `ClientServices::fpSetMessageHandler`
for opcodes 14 and 35 is **`0xDEADBABE`** (int32 `-559039810`), *not* `0xDEADC0BE`
as recorded in `notes/11a_divxtac_ac_logic.md §6`, `11d_extensions_network_ac.md`,
`12_ac_breakpoint_catalog.md` (S4.08, S5.01, S5.04), `ascension_ac_opcodes.json`,
YARA v2 rule "Ascension_MMgr64_Bridge", and Grok's briefing text.

V1 correctly extracted the *decimal literal* `-559039810` from `-Module-.cs` but
mis-converted it to hex. The correct conversion is:

```
-559039810 & 0xFFFFFFFF = 0xDEADBABE   (bytes LE = BE BA AD DE)
0xDEADC0BE               =  -559038274 (bytes LE = BE C0 AD DE)   ← never appears
```

The literal magic in every dumped binary is **`BE BA AD DE`** (little-endian
representation of `0xDEADBABE`).

---

## Primary evidence

### (1) Managed source — `dnspy_out/DivxTac/-Module-.cs`

```csharp
// Token: 0x06000072 RID: 114 RVA: 0x000058BC File Offset: 0x00004CBC
internal unsafe static void SetMessageHandlers()
{
    ... = <Module>.?fpSetMessageHandler@ClientServices@@0P6AXW4Opcodes@@...;
    calli(...,
          (Opcodes)14,
          <Module>.__unep@?AnticheatInitializeHandler@@$$FYAHPAXW4Opcodes@@IPAVCDataStore@@@Z,
          -559039810,                                   // <── context arg  (line 3108)
          ...);
    ... = <Module>.?fpSetMessageHandler@ClientServices@@0...;
    calli(...,
          (Opcodes)35,
          <Module>.__unep@?AnticheatBannedProcessListHandler@@$$FYAHPAXW4Opcodes@@IPAVCDataStore@@@Z,
          -559039810,                                   // <── context arg  (line 3110)
          ...);
}
```

- File: `C:\Ascension\Workspace\RaijinLab\re\dnspy_out\DivxTac\-Module-.cs`
- Lines: **3108** (opcode 14) and **3110** (opcode 35)
- Both context args are the identical int32 literal `-559039810`.

### (2) Raw IL bytes — `dumps/DivxTac.dll` @ file offset `0x4CBC` (RVA `0x58BC`)

```
0330040031000000 dd000011                       // .method + tinyheader + calli sig token
7e77000004                                      // ldsfld  fpSetMessageHandler (token 04000077)
0b                                              // stloc.1
1f 0e                                           // ldc.i4.s 14                     ← opcode 14
7e 44 00 00 04                                  // ldsfld  AnticheatInitializeHandler (token 04000044)
20 BE BA AD DE                                  // ldc.i4  0xDEADBABE              ← context magic
07                                              // ldloc.1
29 bb 00 00 11                                  // calli   0x110000BB
7e 77 00 00 04 0a                               // ldsfld / stloc.0 (2nd fp copy)
1f 23                                           // ldc.i4.s 35                     ← opcode 35
7e 43 00 00 04                                  // ldsfld  AnticheatBannedProcessListHandler (token 04000043)
20 BE BA AD DE                                  // ldc.i4  0xDEADBABE              ← context magic
06                                              // ldloc.0
29 bb 00 00 11                                  // calli   0x110000BB
```

The two `20 BE BA AD DE` sequences are `ldc.i4 <imm32>` (0x20 = ldc.i4) loading
the little-endian dword `BE BA AD DE` = `0xDEADBABE`. These are literally the
"push imm32" operand equivalents in MSIL.

### (3) Whole-binary literal scan

Little-endian search for `BE BA AD DE` (0xDEADBABE) and `BE C0 AD DE` (0xDEADC0BE)
across every dumped module (both `dumps/` and `dumps_mid_download/`):

| Module               | `BE BA AD DE` hits             | `BE C0 AD DE` hits |
|----------------------|--------------------------------|--------------------|
| DivxTac.dll          | **2** @ `0x4CD6`, `0x4CEE`     | 0                  |
| Extensions.dll       | 0                              | 0                  |
| MMgr64.exe           | 0                              | 0                  |
| Ascension.exe        | 0                              | 0                  |
| DivxDecoder.dll      | 0                              | 0                  |
| WowError.exe         | 0                              | 0                  |
| mid_download/DivxTac | **2** (identical offsets)      | 0                  |
| mid_download/Extensions | 0                           | 0                  |

Both hits in DivxTac fall inside `SetMessageHandlers` (file range
`0x4CBC..0x4D10`) — they are exactly the two `ldc.i4` operands shown above.

### (4) Ghidra opcode-name table (context for opcodes 14/35)

Unchanged from V1: Extensions.dll opcode table still names slots 14 and 35
`SMSG_MOVE_CHARACTER_CHEAT` / `SMSG_GODMODE` (repurposed 3.3.5a SMSGs), which
DivxTac hijacks as its inbound bootstrap channel.

---

## Cross-module handshake?  NO.

V1's YARA v2 rule `Ascension_MMgr64_Bridge` conditions on
`0xDEADC0BE` bytes being present in MMgr64 as evidence of a shared DivxTac↔MMgr64
handshake. **This is doubly wrong:**

1. `0xDEADC0BE` bytes never appear anywhere.
2. `0xDEADBABE` bytes never appear in MMgr64, Extensions, Ascension, DivxDecoder,
   or WowError. **Only** DivxTac carries the constant, purely as the
   `void* context` argument each handler will receive when the server dispatches
   opcode 14 or 35.

So the magic is a **DivxTac-internal handler-identity tag** (used by the shared
`fpSetMessageHandler` dispatcher to pass the same 4-byte cookie back into each
handler as arg1), not a cross-module protocol marker. The runtime confirmation
recipe from `12_ac_breakpoint_catalog.md` S5.04 still stands, just with the
corrected constant.

---

## Corrections required in existing artifacts

The following files reference the wrong magic and need to be patched to
`0xDEADBABE` in a follow-up housekeeping pass:

| File                                                | Occurrences (approx) |
|-----------------------------------------------------|----------------------|
| `notes/HANDOFF_claude.md`                           | 2                    |
| `notes/11a_divxtac_ac_logic.md`                     | 5                    |
| `notes/11d_extensions_network_ac.md`                | 2                    |
| `notes/11f_ascension_scan_divxdecoder.md`           | 1                    |
| `notes/12_ac_breakpoint_catalog.md`                 | 5                    |
| `re/ascension_ac_opcodes.json`                      | 3                    |
| `re/yara/ascension_ac_v2.yar`                       | 2 (+ rule condition) |
| `re/scripts/set_ac_breakpoints.x32dbg.txt`          | 1                    |
| `re/scripts/claude_ac_workflow_v2.js`               | 3                    |
| `re/scripts/claude_ac_patch_round.js`               | 2                    |

I have appended a footnote patch to `HANDOFF_claude.md` (see edit in this
round). The other files should be swept in a single sed-style pass:
`s/0xDEADC0BE/0xDEADBABE/g` and `s/BE C0 AD DE/BE BA AD DE/g`.

The **YARA rule** in particular is currently unsatisfiable — no artifact in the
dumped surface contains `bec0adde`. After patching to `bebaadde` the rule will
match DivxTac.dll (2 hits inside `SetMessageHandlers`) but still not match
MMgr64/Extensions, which means the rule name and its "cross-module handshake"
comment also need to be revised (the constant only proves DivxTac provenance;
it is not shared with MMgr64).

---

## What V1 got right vs. wrong

| Claim (V1)                                                           | Status     |
|----------------------------------------------------------------------|------------|
| SetMessageHandlers @ VA `0x100058C8` (file `0x4CBC`)                 | ✅ correct |
| Two `fpSetMessageHandler` calls at L3108/L3110                       | ✅ correct |
| Opcode 14 → `AnticheatInitializeHandler`                             | ✅ correct |
| Opcode 35 → `AnticheatBannedProcessListHandler`                      | ✅ correct |
| int32 literal = `-559039810`                                         | ✅ correct |
| `-559039810` == `0xDEADC0BE`                                         | ❌ **wrong (arithmetic error)** — actual value `0xDEADBABE` |
| Magic used as `void* context`                                        | ✅ correct |
| Magic is a "cross-module handshake" with MMgr64                      | ❌ **wrong** — DivxTac-only, no hits in any other module |

The functional model of the handler-registration mechanism is unchanged; only
the *name of the magic constant* changes. All downstream reasoning about
opcodes 14/35 semantics, breakpoint plans, and the kill-switch strategy for
`SetMessageHandlers` remains valid.

---

## Recipe (reproducible)

```powershell
python -c "v=-559039810 & 0xFFFFFFFF; print(hex(v))"
# -> 0xdeadbabe

python -c "
with open(r'C:/Ascension/Workspace/RaijinLab/re/dumps/DivxTac.dll','rb') as f: d=f.read()
print('BE BA AD DE hits:', [hex(i) for i in range(len(d)-3) if d[i:i+4]==bytes.fromhex('bebaadde')])
print('BE C0 AD DE hits:', [hex(i) for i in range(len(d)-3) if d[i:i+4]==bytes.fromhex('bec0adde')])
"
# -> BE BA AD DE hits: ['0x4cd6', '0x4cee']
# -> BE C0 AD DE hits: []
```
