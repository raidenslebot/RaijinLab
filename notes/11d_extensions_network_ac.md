# 11d — Extensions.dll network anti-cheat surface (ExtendedAnticheatMgr + AC opcodes)

Scope: numeric opcode values, singleton layout, sink→wire linkage, version handshake.
Analysis is static: PE-level string / const / disasm cross-refs against
`C:\Ascension\Workspace\RaijinLab\re\dumps\Extensions.dll` (image base 0x10000000),
cross-checked against DivxTac managed source in `re/dnspy_out/DivxTac/`.

---

## TL;DR

- **CMSG_ANTICHEAT_ALERT = 0x51F = 1311**, **CMSG_ANTICHEAT_VERSION = 0x520 = 1312**
  (matches DivxTac exactly; the Extensions.dll opcode-name table indices 1309/1310 are a
  **STALE debug label table** — off by 2, see §2).
- **SMSG_WARDEN_DATA / CMSG_WARDEN_DATA** appear only as strings in the opcode-name table
  (indices 740/741). **Zero code paths emit or handle them** (0 real `push imm` sites, no
  handler registrations, name-table trampolines have 0 callers). **Legacy Warden is dead**
  on Extensions.dll's wire.
- The 14-vector local sink `FUN_100b5650` **is** the network path: it constructs a CDataStore
  on the stack (vtable `0x10b1c384` = `.?AVCDataStore@@`), pushes opcode `0x51F`, and calls
  the imported CDataStore packet-preparer. Sink is `CMSG_ANTICHEAT_ALERT` emitter #1 of 5.
- `CMSG_ANTICHEAT_VERSION` (0x520) has **zero `push imm32` emit sites in Extensions.dll** —
  the version handshake is emitted only from DivxTac's managed
  `AnticheatInitializeHandler` (subtype 4 + HDD serial). Extensions does not participate
  in the version handshake.
- `ExtendedAnticheatMgr` / `TemplatedSingleton<ExtendedAnticheatMgr>` RTTI is present but
  the class has essentially no virtuals (1-entry vtable, then falls into unrelated
  `%s%s` string data). Its singleton pointer is not the small once-init object at
  `0x10bdc244` (that's a different helper with vtable `0x10b2a42c`). ExtendedAnticheatMgr
  appears to be a **thin/data-only namespace**, not a full mediator — the actual send logic
  is inlined at each of the 5 alert sites, and DivxTac owns the version/handshake side.

Overall: Extensions.dll's network AC surface is **one direction** (client→server AC alerts
via opcode 1311). Server→client Warden is gone, and version/init flows through DivxTac's
managed side (opcodes 14/35 dispatched via `ClientServices::fpSetMessageHandler`, then
1312 emitted with magic `0xDEADBABE`).

---

## 1. Opcode-name string trampoline table

- Name table span: `0x102c60d6 .. 0x102c911e` in `.text`, 2060 entries of 6 bytes each
  (`B8 imm32 C3` — a per-opcode "return the name string pointer" trampoline).
- Table[0]=`MSG_NULL`, Table[1]=`CMSG_BOOTME`, Table[2]=`CMSG_DBLOOKUP` … i.e. the
  ordinal in the trampoline table equals the stock Blizzard opcode number.
- The four AC-relevant entries in this table:

| Trampoline VA | Table idx | String VA | Name |
|---|---|---|---|
| 0x102c722e | 740 (0x2E4) | 0x10b4c19c | `SMSG_WARDEN_DATA` |
| 0x102c7234 | 741 (0x2E5) | 0x10b4c1b0 | `CMSG_WARDEN_DATA` |
| 0x102c7f84 | 1309 (0x51D) | 0x10b4ff20 | `CMSG_ANTICHEAT_ALERT` |
| 0x102c7f8a | 1310 (0x51E) | 0x10b4ff38 | `CMSG_ANTICHEAT_VERSION` |

Stock 3.3.5 numbering: SMSG_WARDEN_DATA=0x2E6, CMSG_WARDEN_DATA=0x2E7. The name-table
positions are **shifted −2** relative to stock; this is consistent for the surrounding
opcodes (SMSG_GROUP_JOINED_BATTLEGROUND at 742 in this table vs 0x2E8 in stock).

## 2. Actual wire opcode numbers (real `push imm32` sites)

`push imm32` byte pattern (`68 xx xx xx xx`) enumerated over `.text`:

| Wire opcode | Real emit sites | Interpretation |
|---|---|---|
| 0x51F (**1311**) — CMSG_ANTICHEAT_ALERT | 5 | `0x100b56dc` (sink), `0x102dba13`, `0x10a46260`, `0x10a4d292`, `0x10a7957b` |
| 0x520 (**1312**) — CMSG_ANTICHEAT_VERSION | 0 | Extensions.dll never emits it |
| 0x2E6 (SMSG_WARDEN_DATA stock) | 0 | dead |
| 0x2E7 (CMSG_WARDEN_DATA stock) | 0 | dead |
| 0x2E4 (SMSG_WARDEN_DATA per name-table) | 0 | dead |
| 0x2E5 (CMSG_WARDEN_DATA per name-table) | 0 | dead |
| 0x51D (CMSG_ANTICHEAT_ALERT per name-table) | 0 | not the real opcode |
| 0x51E (CMSG_ANTICHEAT_VERSION per name-table) | 0 | not the real opcode |

**Conclusion:** The `push imm32` sites are the ground truth. Wire opcodes are:
- **CMSG_ANTICHEAT_ALERT   = 0x51F = 1311**
- **CMSG_ANTICHEAT_VERSION = 0x520 = 1312**

Both values match DivxTac's `CDataStore::PutBeginToBuffer(1311/1312)` calls at
`dnspy_out/DivxTac/-Module-.cs` lines 489, 524, 589 (alert x3) and 2889 (version).

The name-table indices (1309/1310) are off by 2. Most likely explanation: two stock
opcodes were removed early in the enum after the name-table was frozen for logging, but
the code-site enum constants weren't renumbered. The name table is a debug/logging
artifact; the emit sites are the authoritative wire values.

## 3. Wire packet emit template (all 5 alert sites are identical)

All 5 CMSG_ANTICHEAT_ALERT sites share this exact template:

```
mov  [ebp-BUF+0],  0                       ; clear CDataStore fields
mov  [ebp-BUF+4],  0
mov  [ebp-BUF+8],  0
mov  [ebp-BUF+c],  0                       ; (sink variant only)
mov  [ebp-BUF+..], 0FFFFFFFFh
lea  ecx, [ebp-BUF]                        ; ecx = this (CDataStore*)
call dword ptr [0x10bca0bc]                ; -> Ascension.exe 0x00401050
push 0x51F                                  ; opcode CMSG_ANTICHEAT_ALERT
lea  ecx, [ebp-BUF]                        ; ecx = this
call dword ptr [0x10bca0cc]                ; -> Ascension.exe 0x0047b0a0
mov  [ebp-PAYLOAD+0], <magic dwordA>
mov  [ebp-PAYLOAD+4], <magic dwordB>
...
```

### Cross-image function pointers

- `[0x10bca0bc]` = `0x00401050` in `Ascension.exe` — a thiscall that writes vtable
  `0x009E0E24` into `*ecx` and zeroes the CDataStore fields. This is
  `Ascension::CDataStore::CDataStore()` (or equivalent Init).
  vtable at Ascension 0x9E0E24 has 6+ virtuals (0x47ADD0, 0x47AE50, 0x936900,
  0x47AEA0, 0x4038A0, 0x4010D0…).
- `[0x10bca0cc]` = `0x0047B0A0` in `Ascension.exe` — thiscall taking `(this, uint
  opcode)`. Pattern loads `[this+0x10]` vs `[this+8]`, compares, allocates via
  `[this+0xC]`. This is the CDataStore packet-preparer, either
  `CDataStore::PutBeginToBuffer(opcode)` or `ClientServices::Send(CDataStore*, uint
  opcode)`. Not a vtable slot at 0x9E0E24 → regular non-virtual member.

These `.data` pointers are populated at Extensions load time by Ascension.exe passing a
table of client-services entry points — the same mechanism the addon runtime uses to
plumb Blizzard client interfaces into a loaded extension DLL.

### Payload magic per emit site

- Sink `FUN_100b5650`  @ `0x100b56ed`+ writes `0x2E4AD59E` / `0x0F95819C`
- Sites 0x10a46260 / 0x10a4d292 / 0x10a7957b write `0x225DC89E` / `0x159E97B6`
- Site 0x102dba13 (payload not extracted — worth checking) likely a third variant

These dword pairs are VMProtect-style obfuscated context/reason codes bound to the
specific detection class. They are written **after** the opcode push, i.e. they are
part of the CDataStore payload the server decodes to route the alert to a specific
detector bucket. `0x2E4AD59E / 0x0F95819C` is the "anti-debug 14-vector" reason code;
`0x225DC89E / 0x159E97B6` is another reason code (candidate: hook/module scan).

## 4. Sink → wire linkage (question 3, definitively answered)

**Yes — the 14-vector sink `FUN_100b5650` @ VA `0x100B5650` IS the network path.**
No indirection through a mediator; the CDataStore build + opcode push + prepare call
are inlined at the head of the sink function. The 14 anti-debug callers (verified in
prior notes 02/04) all funnel here, and this one function emits
`CMSG_ANTICHEAT_ALERT (0x51F)` with reason `0x2E4AD59E / 0x0F95819C`.

The 4 additional alert-emit sites (0x102dba13, 0x10a46260, 0x10a4d292, 0x10a7957b) are
independent detection paths (not called from the 14-vector cluster) that reuse the same
packet template with different reason codes — worth mapping to Ghidra function symbols
in a follow-up (they cluster in the `0x10a4xxxx-0x10a7xxxx` region, which is the
detection-heavy part of the DLL alongside the sink).

## 5. ExtendedAnticheatMgr singleton — is it actually the mediator?

- RTTI `.?AVExtendedAnticheatMgr@@` name @ `0x10bd48c0`; TypeDescriptor @ `0x10bd48b8`.
- RTTI `.?AV?$TemplatedSingleton@VExtendedAnticheatMgr@@@@` name @ `0x10bd48e4`;
  TypeDescriptor @ `0x10bd48dc`.
- Each TD is referenced by exactly one CompleteObjectLocator (COL @ `0x10b9f3fc` for
  ExtendedAnticheatMgr, `0x10b9f440` for the singleton wrapper). Only the
  ExtendedAnticheatMgr COL is referenced by a vtable: **vtable @ `0x10b2a42c`,
  vtable[0] = destructor `0x1008d970`**. No other vtable slots (bytes immediately
  after are unrelated ASCII `%s%s`… data).

  → The class has 1 virtual (destructor) — essentially a **non-polymorphic class**.
  It's not a message-dispatch mediator.

- The vtable value `0x10b2a42c` is `mov ...,0x10b2a42c`-referenced from 17 sites, but
  16 of them (`0x10a3dc6e … 0x10a3e2cd`) are Meyers-style once-init blocks constructing
  a **local instance** of a small (~9-byte) object at `0x10bdc244` guarded by
  `_Init_thread_header/footer` (`0x10ae70c0` / `0x10ae6b60`) at flag `0x10bdc250`. That
  singleton is only ~9 bytes (vtable + dword + byte) — too small to be the
  Anticheat manager. It is more likely a Logger-adjacent throwaway.

  The 17th reference is inside the sink itself (`0x100b5ab3`), where the object is
  built on the stack rather than in a global — again used transiently.

**Net:** ExtendedAnticheatMgr is a class *name* preserved by RTTI but functionally
data-only. There is no "AC manager" that owns a message table and routes
CMSG_ANTICHEAT_ALERT construction. Every emit site inlines its own CDataStore
build+push+call. This matches the observed division of labor:
- **Native side (Extensions.dll)**: emit `CMSG_ANTICHEAT_ALERT` from 5 inline sites.
- **Managed side (DivxTac.dll)**: emit `CMSG_ANTICHEAT_ALERT` from process/module/title
  scans (via calli), and own `CMSG_ANTICHEAT_VERSION` handshake plus the server-driven
  handlers at opcodes 14 (AnticheatInitialize) and 35 (BannedProcessList).

Neither side needs a shared mediator because both use `CDataStore` (a stock Blizzard
client type) as the transport primitive and the server multiplexes by opcode.

## 6. CMSG_ANTICHEAT_VERSION payload (question 4)

Extensions.dll does not emit opcode `0x520`. The version handshake is entirely DivxTac:

`re/dnspy_out/DivxTac/-Module-.cs` line 2861 `AnticheatInitializeHandler`:
- Registered via `ClientServices::fpSetMessageHandler((Opcodes)14, AnticheatInitializeHandler, 0xDEADBABE)` (line 3108).
- Server sends inbound `Opcodes 14`, DivxTac responds:
  - Builds a `CDataStore` (line 2889 `calli(CDataStore*, ..., 1312, ...)`).
  - Writes **subtype 4** as the discriminator, then the HDD serial obtained via
    `MasterHardDiskSerial` (SMART/STORAGE `DeviceIoControl` — see prior verified note).

Confirmed: version-handshake integer is subtype **4**, payload is HDD serial. Extensions
emits **no** version/handshake integer — it is DivxTac's exclusive responsibility.

## 7. Integrity relevance (integrity/hash/checksum of Extensions or client .text?)

**NO.** Nothing in the network AC surface examined does:
- No `ReadProcessMemory` / hashing / memcmp against `.text` bytes.
- No CRC/MD5/SHA construction near the emit sites.
- The 5 alert emit sites all write **fixed dword-pair magic numbers** as payload, not
  computed hashes.
- DivxTac has zero hashing imports (already verified — DeviceIoControl + version APIs only).

The network AC surface reports **detection facts** (which vector fired, which module/
process matched the banlist, HDD-serial as identity), not integrity hashes. There is no
`.text` scanner or Extensions-checksum path here.

## 8. Answers to the four numbered questions

1. **Numeric opcode values (wire truth):**
   - `CMSG_ANTICHEAT_ALERT = 0x51F = 1311`
   - `CMSG_ANTICHEAT_VERSION = 0x520 = 1312`
   - `SMSG_WARDEN_DATA / CMSG_WARDEN_DATA`: opcode-name strings exist at name-table
     indices 740/741 (Ascension-shifted from stock 742/743), but **no code emits or
     dispatches these** — no `push 0x2E4/0x2E5/0x2E6/0x2E7`, no handler registration,
     no receive-side reference. WARDEN is a **dead opcode** in Extensions.dll's live
     network surface.
   - The opcode-name trampoline table indices for CMSG_ANTICHEAT_ALERT/VERSION are
     1309/1310 — off by 2 from the real wire values. The name table is stale debug
     metadata; the `push imm32` sites are authoritative.

2. **ExtendedAnticheatMgr singleton:**
   - RTTI TypeDescriptors: `0x10bd48b8` (class), `0x10bd48dc` (TemplatedSingleton
     wrapper).
   - Only vtable ref-anchored to it: `0x10b2a42c`, 1 virtual (destructor `0x1008d970`).
   - **No global singleton pointer is used in the AC send path.** Local/temporary
     objects at `0x10bdc244` (via `_Init_thread_header/footer` at flag `0x10bdc250`)
     appear in 16 unrelated once-init blocks but the object is too small (~9 bytes) to
     be the mediator.
   - There is **no active SMSG_WARDEN_DATA handler** in ExtendedAnticheatMgr — the
     opcode name is present in the name table but has zero handler registration and
     zero read-side references. Legacy Warden is not live; the opcode name is
     vestigial. If the opcode number is ever "reused" as a shell, that reuse must
     happen server-side because Extensions has no client-side handler for it.

3. **Sink → network linkage:**
   - `FUN_100b5650` **directly** builds a stack CDataStore (vtable `0x10b1c384`),
     calls `[0x10bca0bc]`→`Ascension.exe!CDataStore::Init` (0x401050), pushes opcode
     `0x51F` (CMSG_ANTICHEAT_ALERT = 1311), calls `[0x10bca0cc]`→`Ascension.exe`
     packet-preparer (0x47B0A0), then writes reason-code payload
     `0x2E4AD59E / 0x0F95819C`. Confirmed at sink offsets `0x100B569A..0x100B56FB`.
   - There is no `ExtendedAnticheatMgr::Send()` mediator; the packet build+send is
     inlined at every emit site (5 total for CMSG_ANTICHEAT_ALERT).

4. **CMSG_ANTICHEAT_VERSION payload:**
   - Not emitted by Extensions.dll. Emitted only from DivxTac managed
     `AnticheatInitializeHandler` (opcode 14 inbound, opcode 1312 outbound).
   - Payload: subtype integer **4** + HDD serial (from SMART/STORAGE ioctls via
     `MasterHardDiskSerial`). Matches the previously verified DivxTac writeup (11a).

---

## Concrete artifacts

- Sink `FUN_100b5650`  VA `0x100B5650`  file offset `0xB4A50`
- Alert emit sites (all push `0x51F` then call CDataStore preparer):
  `0x100B56DC` (sink), `0x102DBA13`, `0x10A46260`, `0x10A4D292`, `0x10A7957B`
- Cross-image callable slots in Extensions `.data`:
  `0x10BCA0BC` → `Ascension.exe 0x00401050` (CDataStore ctor / Init)
  `0x10BCA0CC` → `Ascension.exe 0x0047B0A0` (CDataStore opcode-prep / send)
- CDataStore vtable in Extensions `.rdata`: `0x10B1C384` (class = `.?AVCDataStore@@`, COL `0x10B9EC38`, TD `0x10BD4508`)
- ExtendedAnticheatMgr vtable: `0x10B2A42C` (1 virtual — destructor `0x1008D970`)
- ExtendedAnticheatMgr RTTI:  TD `0x10BD48B8`, COL `0x10B9F3FC`
- TemplatedSingleton<ExtendedAnticheatMgr> RTTI: TD `0x10BD48DC`, COL `0x10B9F440` (no vtable back-ref found)
- Opcode-name trampoline table: `0x102C60D6..0x102C911E` (2060 × 6-byte entries), no callers
- Opcode-name strings: SMSG_WARDEN_DATA `0x10B4C19C`, CMSG_WARDEN_DATA `0x10B4C1B0`,
  CMSG_ANTICHEAT_ALERT `0x10B4FF20`, CMSG_ANTICHEAT_VERSION `0x10B4FF38`
- Once-init guard/instance for the small 0x10b2a42c-vtable helper:
  flag `0x10BDC250`, instance `0x10BDC244`, ctor calls `_Init_thread_header` `0x10AE70C0` / `_footer` `0x10AE6B60`

## Follow-up (open questions)

- Symbol-map the 4 non-sink alert emitters (`0x102dba13`, `0x10a46260`, `0x10a4d292`,
  `0x10a7957b`) to Ghidra `FUN_...` names and identify which detection class each
  represents (module scan? window/title check? hardware breakpoint variant?).
- Decode the reason-code payload dword pairs. `0x2E4AD59E / 0x0F95819C` (sink) vs
  `0x225DC89E / 0x159E97B6` (other sites). These look like fixed obfuscated
  tags — server almost certainly has a static table mapping them to
  human-readable violation reasons.
- Verify runtime: set breakpoints at `0x100B56DC` and `0x10A46260` under a debugger
  attached to `Ascension.exe` to confirm the emit sites fire and observe the exact
  wire bytes leaving the client.
