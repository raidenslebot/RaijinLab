# GAP 8 — Which binary loads DivxTac.dll?

**Verdict: CONFIRMED — Extensions.dll is the sole loader of DivxTac.dll.**
The load call is `KERNEL32!LoadLibraryA("DivxTac.dll")` invoked from a
small stub inside Extensions.dll via a thunk exported by the host module
(Ascension.exe). No other analysed binary contains the string
`DivxTac.dll`, imports it statically, or invokes it dynamically.

---

## 1. String uniqueness (byte-level scan of all dumps)

```
Ascension.exe    (7,694,848 B) : ASCII 0  UTF16 0
Extensions.dll  (12,647,992 B) : ASCII 1  UTF16 0   <-- SOLE HIT
DivxDecoder.dll   (413,696 B)  : ASCII 0  UTF16 0
MMgr64.exe        (364,032 B)  : ASCII 0  UTF16 0
WowError.exe      (205,824 B)  : ASCII 0  UTF16 0   (newly triaged)
```

`"DivxTac.dll"` lives at:
- Extensions.dll file offset **0x00B626C8**
- Extensions.dll VA **0x10B63CC8**  (section `.rdata`, RVA 0xB63CC8)

## 2. Static-import audit

None of the binaries statically import `DivxTac.dll` (parsed with pefile):

```
Ascension.exe     : 17 imports, DivxTac=False, DivxDecoder=True
Extensions.dll    : 21 imports, DivxTac=False, DivxDecoder=False
WowError.exe      :  5 imports, DivxTac=False, DivxDecoder=False
DivxDecoder.dll   :  1 imports, DivxTac=False
```

Ascension.exe pulls in `DivxDecoder.dll` (the codec) statically but NOT
`DivxTac.dll`. `DivxTac.dll` is loaded dynamically.

## 3. Loader stub — Extensions.dll VA 0x10A3B690

Sole code xref to `"DivxTac.dll"` (0x10B63CC8) is at 0x10A3B691, inside a
9-byte thunk:

```
0x10a3b690: push 0x10b63cc8        ; "DivxTac.dll"
0x10a3b695: mov  eax, 0x86c4e0     ; Ascension.exe VA (host module)
0x10a3b69a: call eax
0x10a3b69c: pop  ecx
0x10a3b69d: ret
```

## 4. The 0x86c4e0 thunk is Ascension.exe's LoadLibraryA wrapper

`0x86c4e0` lies inside Ascension.exe `.text` (ImageBase 0x400000,
`.text` 0x401000–0x9DE3B3). Disassembly:

```
0x86c4e0: push ebp
0x86c4e1: mov  ebp, esp
0x86c4e3: mov  eax, [ebp+8]
0x86c4e6: push eax
0x86c4e7: call [0x9df248]          ; IAT slot
0x86c4ed: pop  ebp
0x86c4ee: ret
```

IAT slot `0x9DF248` resolves (via `pefile.DIRECTORY_ENTRY_IMPORT`) to:

```
KERNEL32.dll -> LoadLibraryA  @ IAT 0x9df248
```

Therefore `Extensions.dll!0x10A3B690` is a 1-arg wrapper that calls
`LoadLibraryA("DivxTac.dll")`.

Note the "cross-module hardcoded VA" trick: Extensions.dll embeds an
absolute pointer to a function inside Ascension.exe. This only works
because both live in the same process image; it also means the loader is
tied to Ascension.exe's `.text` layout and would break if that binary
were rebased/patched.

## 5. Trigger — how the stub is invoked

The stub is never called directly (0 E8 callers). Its address is
registered as a callback:

Registration site — Extensions.dll `0x10A6BDA5` inside a large init
routine that also registers CVars (adjacent code registers
`"autoAcceptTrades"` via 0x10114620):

```
0x10a6bda5: push 0x10a3b690         ; DivxTac loader stub
0x10a6bdaa: call 0x10278b70         ; register callback
```

The `register` helper stores the pointer in a global container at
`0x10BE3974`:

```
0x10278b70: sub  esp, 8
0x10278b73: lea  eax, [esp+0xc]
0x10278b77: mov  ecx, 0x10be3974    ; container instance
0x10278b7c: push eax
0x10278b7d: lea  eax, [esp+4]
0x10278b81: push eax
0x10278b82: call 0x100997c0         ; std::vector<Fn>::push_back-style
0x10278b8a: ret
```

Two `.text` references to container `0x10BE3974`:
- 0x10278B78 — the `register()` (write side, shown above)
- 0x10073740 — an iterator/runner (read side) — it sits at vtable index 4
  of vtable `0x10B1ABE0`:
  ```
  0x10073740: mov  ecx, 0x10be3974
  0x10073745: call 0x1009e630        ; std::vector::for_each -> invoke fn
  0x1007374a: push 0x10b16040
  0x1007374f: call 0x10ae6b60        ; release / cleanup
  0x10073755: ret
  ```

No plain E8 callers of 0x10073740 exist and no `.text` reference to the
vtable base 0x10B1ABE0 is present in the raw dump, so the enclosing
class is instantiated indirectly (likely constructed via a class factory
or referenced through a member offset). Identifying the exact trigger
event requires runtime tracing (a breakpoint on `LoadLibraryA` with an
Extensions.dll return-address filter will name it in one login cycle).

## 6. Load-edge summary

| Property | Value |
|---|---|
| Loader binary | **Extensions.dll** |
| String location | Extensions.dll .rdata VA 0x10B63CC8 (file 0x00B626C8) |
| Loader stub VA | Extensions.dll .text **0x10A3B690** |
| API used | `KERNEL32!LoadLibraryA` |
| API dispatch | Ascension.exe `.text` thunk **0x86C4E0** -> IAT 0x9DF248 |
| Registration site | Extensions.dll 0x10A6BDA5 (init routine) |
| Callback registrar | Extensions.dll 0x10278B70 -> container 0x10BE3974 |
| Runner (invokes stub) | Extensions.dll 0x10073740 (vtable 0x10B1ABE0[4]) |
| Trigger | callback list flushed by vtable-driven runner — exact event unresolved statically (needs runtime BP) |
| Ascension.exe static import? | **No** |
| WowError.exe reference? | **No** — WowError.exe contains no DivxTac string |
| MMgr64 involvement? | **No** — string absent; MMgr64 is memory bridge only |

## 7. Implications for RaijinLab

- DivxTac.dll is **not present in memory at process start**; it is loaded
  on demand by Extensions.dll after both `Ascension.exe` and
  `Extensions.dll` have initialized enough to hit the callback flush.
- A **`LoadLibraryA` hook / IAT swap** installed BEFORE the callback
  flush (i.e. during process launch, before `Extensions.dll` init
  finishes) can intercept, redirect, or veto the DivxTac load.
  The interception point is:
    * User-mode API `KERNEL32!LoadLibraryA` (or the IAT slot 0x9DF248 in
      Ascension.exe) with argv[1] == `"DivxTac.dll"`.
    * Alternatively: patch the stub prologue at Extensions.dll 0x10A3B690
      to `ret` immediately, once Extensions.dll is mapped and relocated
      (VMProtect wraps only `.vm_sec`, not `.text`, so this stub sits in
      plain code).
- Because Extensions.dll's stub calls Ascension.exe by absolute VA
  (0x86C4E0), any patch or hot-patch that shifts Ascension.exe `.text`
  breaks the load — useful for identifying tampering, but Ascension.exe
  has no ASLR (`ImageBase=0x400000` fixed) so this is stable in
  production.
- **Extensions.dll therefore governs both violation reporting
  (FUN_100B5650 sink, V1 verdict) AND anti-cheat module loading.**
  RaijinLab must treat Extensions.dll as the primary integrity host;
  DivxTac.dll can be evaded either by preventing the load or by
  neutralising the stub, and neither path touches Ascension.exe.

## 8. Evidence commands (reproducible)

```powershell
# String uniqueness
python -c "import os; [print(t, open(f'C:/Ascension/Workspace/RaijinLab/re/dumps/{t}','rb').read().count(b'DivxTac')) for t in ['Ascension.exe','Extensions.dll','DivxDecoder.dll','MMgr64.exe','WowError.exe']]"

# Loader stub disasm
python -c "import pefile; from capstone import Cs,CS_ARCH_X86,CS_MODE_32; pe=pefile.PE(r'C:\Ascension\Workspace\RaijinLab\re\dumps\Extensions.dll'); s=pe.sections[0]; d=s.get_data(); md=Cs(CS_ARCH_X86,CS_MODE_32); [print(hex(i.address), i.mnemonic, i.op_str) for i in md.disasm(d[0xa3b690-0x1000:0xa3b690-0x1000+24], 0x10a3b690)]"

# IAT resolve
python -c "import pefile; pe=pefile.PE(r'C:\Ascension\Workspace\RaijinLab\re\dumps\Ascension.exe'); [print(e.dll,i.name,hex(i.address)) for e in pe.DIRECTORY_ENTRY_IMPORT for i in e.imports if i.address==0x9df248]"
```
