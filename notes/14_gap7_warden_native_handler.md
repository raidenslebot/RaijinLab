# GAP 7 — Native SMSG/CMSG_WARDEN_DATA Handler

**Verdict: PARTIAL (question premise wrong, real answer discovered).**

Native Warden handler is **NOT in Extensions.dll**. It lives in `Ascension.exe`
(the WoW client) and is a live legacy Blizzard-style `WardenClient.cpp` module
that survives DivxTac lacking memory-integrity primitives.

This CONTRADICTS the V1 statement "DivxTac + Extensions FUN_100b5650 are the
only detection paths." A third, independent detection path is live: legacy
Blizzard Warden inside the client itself.

---

## 1. Extensions.dll — Warden strings but NO handler

`Extensions.dll` contains the two strings:

| VA | String |
|---|---|
| `0x10B4C19C` | `SMSG_WARDEN_DATA` |
| `0x10B4C1B0` | `CMSG_WARDEN_DATA` |

These are indexed into a `GetOpcodeName(idx)` thunk table:

* Thunk-pointer table (name lookup): `.text:0x102C9928 .. 0x102CA5A4` — 799 entries.
* Index of `SMSG_WARDEN_DATA` thunk = 228 (0xE4).
* Index of `CMSG_WARDEN_DATA` thunk = 229 (0xE5).
* Thunks themselves are 6-byte `MOV EAX, imm32 ; RET` stubs at
  `SMSG=0x102C722E` and `CMSG=0x102C7234`.

**No handler registration for opcodes 0x2E6/0x2E7 exists in Extensions.dll.**
Full-dword scan of `Extensions.dll .text` for immediates `0x2E6` and `0x2E7`
returns only Jcc-branch relative offsets that happen to coincide byte-wise
(`0F 84 E6 02 00 00`, `0F 87 E7 02 00 00`, `E9 E7 02 00 00`, etc.) — never
`PUSH 0x2E6` or `MOV reg, 0x2E7`. Extensions.dll's opcode/name table therefore
carries the two Warden names as vestigial identifiers used by the client's
network trace logger, not as evidence of a handler.

---

## 2. Ascension.exe — live legacy Warden module (~2.3 KB)

Reference string `.\\WardenClient.cpp` at `Ascension.exe:0x00A40774`
(rdata; file offset 0x63EF74) is xref'd from **22 distinct call sites** in
`.text` between `0x7DA20F` and `0x7DAA8E`. Every ref feeds a Blizzard-style
line-numbered log/assert (`push 0; push <line>; push 0xA40774; push <arg>;
call 0x76E540/A0`), so line numbers pin routine boundaries:

| Log line | VA cluster | Role (inferred) |
|---|---|---|
| 0xAD .. 0xF9 | 0x7DA200 – 0x7DA2BB | packet-buffer copy in / out helpers |
| ~0x140 | 0x7DA2C0 – 0x7DA2FB | subsystem 1 dtor (`[0xD31A44]` free) |
| ~0x150 | 0x7DA300 – 0x7DA357 | subsystem 2 dtor via vtable `[[0xD31A4C]]+4` |
| 0x187 – 0x1A1 | 0x7DA700 – 0x7DA7C5 | key-init / SHA1 or RC4 setup |
| 0x2AB / 0x2B2 | 0x7DA4B0 / 0x7DA4D0 | small log wrappers |
| 0x2BA .. 0x2CC | 0x7DA500 – 0x7DA5AE | **memory-read primitive** — see §4 |
| — | 0x7DA850 – 0x7DA8BF | **inbound opcode 0x2E6 dispatcher** |
| — | 0x7DA8C0 – 0x7DA92B | **module init + `SetMessageHandler(0x2E6,…)`** |
| — | 0x7DAAE9 – 0x7DAB6D | **outbound CMSG_WARDEN_DATA (0x2E7) build/send** |

Globals used by the module (all in `.data`):

| Global | Meaning |
|---|---|
| `0xD31A44` | subsystem-1 heap block |
| `0xD31A48` | WardenClient-alive flag (non-zero ⇒ dispatch) |
| `0xD31A4C` | `WardenClient *` singleton pointer (vtable used) |
| `0xD31A50` | memory-read source base |
| `0xD31A54` | memory-read source length |
| `0xD31A58` | `SetMessageHandler` cookie return value |
| `0xD31A60` | `KernelObject` (CRITICAL_SECTION) — `EnterCriticalSection = 0x774640`, `LeaveCriticalSection = 0x774650` |

---

## 3. Handler registration — proves Warden is live

`Ascension.exe:0x7DA8FC` (inside the init routine ending at `0x7DA92B`):

```
7DA8F7  mov  [0xD31A54], 0                 ; reset len
7DA901  call 0x86AE20                       ; alloc / init singleton
7DA906  push 0                              ; unk / userdata
7DA908  push 0x7DA850                       ; handler function ptr
7DA90D  push 0x2E6                          ; opcode = SMSG_WARDEN_DATA (742)
7DA912  mov  [0xD31A58], eax                ; store cookie
7DA917  call 0x6B0B80                       ; ClientServices::SetMessageHandler(op, fn, ud, ...)
7DA91C  add  esp, 0x14                      ; 5 dwords cleaned -> cdecl
7DA91F  mov  ecx, 0xD31A60
7DA924  call 0x774650                       ; leave critsec
7DA929  xor  al, al
7DA92B  ret
```

`call 0x6B0B80` is the client's standard packet-handler-registrar (single
callsite for opcode 0x2E6 confirmed by the exhaustive immediate scan).

---

## 4. Inbound handler — real dispatch into Warden vtable

`Ascension.exe:0x7DA850` — the pointer registered above:

```
7DA850  push ebp
7DA851  mov  ebp, esp
7DA853  push ecx
7DA854  cmp  [ebp+0Ch], 0x2E6          ; opcode arg  (must be SMSG_WARDEN_DATA)
7DA85B  je   short OK
7DA85D  xor  eax, eax                  ; wrong opcode -> return false
7DA85F  mov  esp, ebp
7DA861  pop  ebp
7DA862  ret
OK:
7DA863  push esi
7DA864  mov  ecx, 0xD31A60
7DA869  call 0x774640                  ; EnterCriticalSection
7DA86E  mov  ecx, [ebp+14h]            ; CDataStore *pkt
7DA871  mov  esi, [ecx+10h]            ; pkt.size
7DA874  sub  esi, [ecx+14h]            ; pkt.size - pkt.rpos = payload_len
7DA877  lea  eax, [ebp-4]              ; &payload_ptr
7DA87A  push esi                       ; len
7DA87B  push eax
7DA87C  call 0x47B6B0                  ; CDataStore::GetReadPtr(&p, len)
7DA881  cmp  [0xD31A48], 0             ; WardenClient alive?
7DA888  mov  [ebp+0Ch], 0
7DA88F  je   short SKIP
7DA891  mov  ecx, [0xD31A4C]           ; wc = *singleton
7DA897  mov  edx, [ecx]                ; vtable
7DA899  mov  edx, [edx+8]              ; vtable[2]  = WardenClient::OnPacket
7DA89C  lea  eax, [ebp+0Ch]
7DA89F  push eax                       ; & out state
7DA8A0  mov  eax, [ebp-4]              ; payload_ptr
7DA8A3  push esi                       ; payload_len
7DA8A4  push eax
7DA8A5  call edx                       ; WardenClient::OnPacket(data, len, &out)
7DA8A7  call 0x7DA360                  ; post-process (log/assert wrapper)
SKIP:
7DA8AC  mov  ecx, 0xD31A60
7DA8B1  call 0x774650                  ; LeaveCriticalSection
7DA8B6  mov  eax, 1                    ; return true (handled)
7DA8BB  pop  esi
7DA8BC  mov  esp, ebp
7DA8BE  pop  ebp
7DA8BF  ret
```

Signature matches WoW's `int __cdecl handler(int netEventId, int opcode,
DWORD ctx, CDataStore *pkt)` — the exact type `SetMessageHandler` expects.
The handler forwards the raw Warden payload to `WardenClient::OnPacket` via
vtable slot +8. The vtable is populated at construction (dynamic; not
resolvable statically without loading), but the classification below stands
on what this dispatcher body itself does.

---

## 5. Memory-read primitive — matches Blizzard-Warden MEMORY_CHECK

`Ascension.exe:0x7DA500` — this is a set-memory-window helper:

```
7DA51F  call 0x76E540                  ; log ".\WardenClient.cpp:0x2BA"
7DA524  mov  ecx, [ebp+8]              ; src
7DA527  push esi                       ; len
7DA528  push ecx                       ; src
7DA529  push eax                       ; dst (allocated)
7DA52A  mov  [0xD31A50], eax           ; save base
7DA52F  mov  [0xD31A54], esi           ; save len
7DA535  call 0x40CB10                  ; memcpy(dst, src, len)
```

And its companion `Ascension.exe:0x7DA550` (the read-back):

```
7DA554  mov  esi, [0xD31A50]
7DA55A  test esi, esi
7DA55C  jne  short have_buf
...
7DA574  mov  eax, [eax]                ; caller-supplied length
7DA576  mov  ecx, [ebp+8]              ; caller dst
7DA579  push eax
7DA57A  push esi                       ; src = [0xD31A50]
7DA57B  push ecx                       ; dst
7DA57C  call 0x40CB10                  ; memcpy(dst, src, len)
...
7DA596  mov  [0xD31A50], 0             ; clear
7DA5A0  mov  [0xD31A54], 0
```

`0x40CB10` was disassembled: it is a stock `memcpy` (dword-aligned copy with
SSE fast-path guarded by feature flag at `[0xDD0344]`, and forward/backward
overlap handling at `0x411F0B`/`0x40CCD4`). No RPM needed — the client reads
its own address space directly. Warden checksums of the client's `.text` are
built by pointing `src` at `.text` bytes and letting `WardenClient::OnPacket`
schedule this memcpy for the response payload. **In-process memory-integrity
scans are alive.**

---

## 6. Outbound CMSG_WARDEN_DATA (opcode 0x2E7 / 743)

Immediate scan of `.text` gave two callsites that literally `PUSH 0x2E7`:

* `Ascension.exe:0x7DAAE9` — inside the WardenClient module. Constructs a
  `CDataStore` on stack (`[ebp-0x24] = 0x9E2148` — vtable), then
  `push 0x2E7 ; lea ecx,[ebp-24] ; call 0x47B0A0` (CDataStore::PutOpcode),
  then loops appending payload bytes with `call 0x47AFE0` (CDataStore::PutByte),
  and finally `call 0x6B0B50` — the `ClientServices::SendPacket`. This is
  `WardenClient::SendResponse`.
* `Ascension.exe:0x8E2440` — a separate subsystem's opcode-count/log call
  (`push edi; push 0x2E7; push 0xA95860; push eax; call 0x8CFF30`). Same
  4-arg cdecl shape as `0x4C91FC` which pushes `0x2E6` next to descriptor
  `0x9F2644`. These are the client's opcode-name/statistics registry
  constructors, not extra send sites.

Together with §3, this confirms the full Blizzard challenge/response cycle
is wired in: server sends 742 → client dispatches → WardenClient handles →
client responds with 743.

---

## 7. Classification (per §3 of the task)

**(a) Legacy Blizzard Warden challenge/response.** Confirmed:
* Dispatcher is a legitimate `SetMessageHandler` callback with exact
  Blizzard signature.
* Handler forwards raw payload into a `WardenClient` object via vtable +8.
* The module owns `.\WardenClient.cpp`-annotated helpers for
  memcpy-based memory reads, buffer serialisation, and packet response.
* Registration happens at runtime under a critical section.

**(b) Stub / no-op.** Rejected — 2.3 KB of code, 22 log-refs, real memcpy
plumbing, real vtable dispatch, real registration.

**(c) Repurposed shell for DivxTac / Extensions checks.** Rejected — no
call-throughs from `0x7DA200–0x7DAAE0` into `Extensions.dll`
(FUN_100B5650 sink) or `DivxTac.dll`. Warden runs on its own path.

---

## 8. Contradiction with V1

V1 enumerated only:
1. Extensions.dll `FUN_100B5650` violation sink (14 direct callers).
2. DivxTac managed BannedProccessesManaged (name-match on ToLower + ".dll").

Gap 7 adds a **third, independent live detection path**:

3. **Ascension.exe legacy Warden module** at `0x7DA200–0x7DAAE0` with
   dispatcher at `0x7DA850` and registration via `call 0x6B0B80` at
   `0x7DA917`, exchanging opcodes 0x2E6 (in) and 0x2E7 (out) with the
   server. Includes in-process memcpy-based memory read primitive.

Practical implication for the RaijinLab port:
* The AC surface is broader than V1 mapped. Warden can be scripted by the
  live server to fingerprint arbitrary regions of the emulator/addon
  process. Any patch that relies on DivxTac / Extensions being the whole
  story will still get burned by a server-driven Warden memory-check.
* If the server operator does not push Warden challenges (typical for
  boutique realms), Warden sleeps and this third path is dormant. Verify
  live traffic (opcode 0x2E6 arrivals) to know whether the third path is
  actually exercised.

---

## 9. Breakpoint / catalog additions

Add to `12_ac_breakpoint_catalog.md` (Ascension.exe process, image base
`0x00400000`):

| Purpose | VA | Notes |
|---|---|---|
| Warden inbound dispatcher (SMSG_WARDEN_DATA 0x2E6) | `Ascension.exe+0x3DA850` (`0x7DA850`) | bp on entry to log all inbound Warden payloads |
| Warden `SetMessageHandler` registration | `Ascension.exe+0x3DA917` (`0x7DA917`) | one-shot; catch module init |
| Warden vtable dispatch | `Ascension.exe+0x3DA8A5` (`0x7DA8A5`) | logs vtable ptr = `[[0xD31A4C]]+8` for WardenClient::OnPacket location |
| Warden memcpy set-window | `Ascension.exe+0x3DA529` (`0x7DA529`) | captures `(dst, src, len)` — reveals which memory regions Warden is scanning |
| Warden memcpy read-back | `Ascension.exe+0x3DA57C` (`0x7DA57C`) | captures the payload just before it enters the response builder |
| Warden outbound send (CMSG_WARDEN_DATA 0x2E7) | `Ascension.exe+0x3DAAE9` (`0x7DAAE9`) | bp to log full response payload before `SendPacket` at `0x6B0B50` |

Add to `11d_extensions_network_ac.md`: the Warden strings in Extensions.dll
are name-table-only (no handler); real Warden processing is in
Ascension.exe (§2 above).

---

## 10. Evidence & method

* Immediate-scan of Extensions.dll `.text` for `0x2E6`/`0x2E7` — 2 and 7 hits,
  all Jcc/JMP relative offsets, none `PUSH`/`MOV imm`. Zero registration.
* Immediate-scan of Ascension.exe `.text` for the same — 18 and 9 hits.
  Real `PUSH 0x2E6` at `0x4C91FC`, `0x573183`, `0x7DA486`, `0x7DA90D`;
  real `PUSH 0x2E7` at `0x7DAAE9`, `0x8E2440`; real `CMP dword ptr, 0x2E6`
  at `0x7DA854` (the dispatcher).
* String-xref of `0xA40774 = ".\\WardenClient.cpp"` — 22 hits, all inside
  `0x7DA200–0x7DAA8E`.
* Disassembly windows at each hit confirmed the register/handler/send/memcpy
  wiring above.
* `0x40CB10` disassembly confirmed it is stock `memcpy`.
