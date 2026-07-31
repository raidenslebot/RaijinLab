# GAP 4 — Raw disassembly / MSIL of DivxTac ManagedDetourMgr::FunctionMap initializer

**Verdict: CONFIRMED empty forever.** The `flat_hash_map<GlobalOffsets, unsigned char*>` static field
`ManagedDetourMgr::FunctionMap` is initialized to the phmap "empty sentinel" state at DLL load and
is never populated by any code path in `DivxTac.dll`. There are no `GetProcAddress` results stored,
no `insert`/`emplace` calls, and no other writes to the map's storage anywhere in the module.

## 1. Symbols located

`re/ghidra_out/DivxTac.dll.symbols.txt`:

| Line | VA | Symbol (unmangled fragment) |
|---:|---|---|
|   4 | `0x10001028` | `??__E?FunctionMap@ManagedDetourMgr@@0V?$flat_hash_map@…@@YMXXZ`  (dynamic **initializer**) |
| 431 | `0x10008654` | `??__F?FunctionMap@ManagedDetourMgr@@0V?$flat_hash_map@…@@YMXXZ`  (atexit **finalizer**) |
| 168 | `0x1000479c` | `phmap::priv::internal_layout::LayoutImpl<…GlobalOffsets…>::Offset<1,0>` |
| 180 | `0x10004a54` | `phmap::priv::raw_hash_set<…GlobalOffsets…>::destroy_slots` |

The `??__E?<name>` / `??__F?<name>` MSVC mangling is the standard Microsoft "dynamic initializer / atexit
finalizer for static object" pair emitted for any C++ file-scope object with a non-trivial ctor/dtor.
The trailing `YMXXZ` calling convention is `__clrcall` — meaning both symbols are **managed methods**,
not native x86, and the bytes at their VAs are not real instructions.

## 2. Raw x86 window at the initializer VA (script output)

```
python re/scripts/disasm_window.py re/dumps/DivxTac.dll 0x10001028 --after 400
```

The window from `0x10001028..0x100010f4` is not executable code — capstone parses the bytes but they
decode as `add byte ptr [eax], al`, `sub cl, ah`, `push es`, `int3`, `jg <backward>` etc.
The bytes have a repeating 8-byte structure

```
 04 XX 58 16 54 7F 3C 00     (with 0x1a, 0x1e, 0x1f, 0x1f variants at XX)
```

which is the CLR **VTable Fixup / IMAGE_COR_ILMETHOD RVA table** stored inline in `.text` for a
mixed-mode C++/CLI DLL. Real native code in this DLL only resumes at `0x10001100`
(`c2 00 00  ret 0`, an empty thunk) followed by ordinary functions at `0x10001110`+
(`push ebp; mov ebp,esp; …`). Same picture at the finalizer VA `0x10008654` — data padding then
zero-padded region.

Implication: the initializer body cannot be read from the native `.text` bytes. It exists as MSIL
in the CLR method-body pool and can only be read via a CLR decompiler (dnSpy).

## 3. Authoritative MSIL body (dnSpy → `<Module>.cs`)

From `re/dnspy_out/DivxTac/-Module-.cs` (identifiers abbreviated to `FunctionMap` for readability;
raw symbol is `?FunctionMap@ManagedDetourMgr@@0V?$flat_hash_map@W4GlobalOffsets@@PAEU…@@A`):

```csharp
// L2844-2852  ??__E?FunctionMap  (dynamic initializer, __clrcall, void()
internal unsafe static void ??__E?FunctionMap@ManagedDetourMgr@@…()
{
    <Module>.FunctionMap        = <Module>.phmap.priv.EmptyGroup();  // ctrl_ = static empty sentinel
    *((ref <Module>.FunctionMap) +  4) = 0;                          // size_        = 0
    *((ref <Module>.FunctionMap) +  8) = 0;                          // capacity_    = 0
    *((ref <Module>.FunctionMap) + 12) = 0;                          // slots_       = nullptr
    *((ref <Module>.FunctionMap) + 20) = 0;                          // growth_left_ = 0
    <Module>._atexit_m(ldftn(??__F?FunctionMap@ManagedDetourMgr@@…));
}

// L2855-2858  ??__F?FunctionMap  (atexit finalizer, __clrcall, void()
internal static void ??__F?FunctionMap@ManagedDetourMgr@@…()
{
    <Module>.phmap.priv.raw_hash_set<…GlobalOffsets,unsigned char*…>.destroy_slots(
        ref <Module>.FunctionMap);
}

// L5643   field declaration
internal static flat_hash_map<GlobalOffsets, unsigned char*, …> FunctionMap;

// L5647   $initializer$ function-pointer slot (used by CRT init-table dispatcher)
internal unsafe static delegate*<void> ?FunctionMap$initializer$@ManagedDetourMgr@@0P6MXXZA;
```

This is the textbook parallel-hashmap default-constructor pattern:

```
raw_hash_set::raw_hash_set() noexcept
    : ctrl_(EmptyGroup()), slots_(nullptr), size_(0), capacity_(0), growth_left_(0) {}
```

`EmptyGroup()` returns a pointer to a read-only static byte block (the sentinel used when
`capacity_ == 0`). No allocation, no insertion, no `GetProcAddress`, no pointer stores except zero.

## 4. Search for populators (module-wide)

```
grep -n "FunctionMap"          re/dnspy_out/DivxTac/-Module-.cs         →   11 hits
grep -r -n "FunctionMap|ManagedDetourMgr" re/dnspy_out/DivxTac/         →   11 in <Module>.cs + 2 in ManagedDetourMgrlockRef.cs
```

All 11 hits in `<Module>.cs` are one of:

- initializer body (L2844-2851, quoted above)
- finalizer body (L2855-2857)
- field declaration (L5643)
- `$initializer$` function-pointer table slot (L5647)

The two `ManagedDetourMgrlockRef.cs` hits are only the lock companion class — a bare
`public static ManagedDetourMgrlockRef _lockRef = new ManagedDetourMgrlockRef();`, no map access.

**No `insert`, `emplace`, `find`, `operator[]`, `try_emplace`, or `at` call targets
`ManagedDetourMgr::FunctionMap` anywhere in DivxTac.dll.**

Additional negative controls (also grepped over the whole `dnspy_out/DivxTac/` tree):

- `GetProcAddress`  — 0 hits (matches v1 finding that DivxTac imports no `GetProcAddress`)
- `SetProcAddress`  — 0 hits (not a real API; sanity)
- `MODULE_HANDLE` / `kernel32` string constants — 0 hits
- References to `GlobalOffsets` outside phmap template infrastructure — 0

The only other `GlobalOffsets` hits are template-instantiation declarations
(`flat_hash_map<…GlobalOffsets…>`, `raw_hash_set<…GlobalOffsets…>`, `Layout<signed char, map_slot_type<GlobalOffsets, unsigned char*>>`, `LayoutImpl<…>::Offset<1,0>`, `destroy_slots`).
None of those are *call sites* — they are the template code the C++/CLI compiler had to emit to
support the (unused) map.

## 5. Cross-check against v1 extractions

`re/divxtac_globaloffsets.json` (v1) reported `GlobalOffsets` enum with **0 members** and no insert
sites. That conclusion is upheld. No patch to the JSON is required.

## 6. Answers to the DO checklist

1. **Symbol lookup:** found — `FUNC 0x10001028` initializer and `FUNC 0x10008654` finalizer.
2. **Raw disassembly:** performed via `disasm_window.py`. The bytes at both VAs are CLI metadata /
   RVA tables, not native code — expected for `__clrcall` methods in a mixed-mode DLL. The real
   method body is MSIL and lives in the CLR method-body pool.
3. **Patterns searched:**
   - (a) `mov [reg+N], <ptr>` writes into the phmap struct — **only zero writes** at offsets +4/+8/+12/+20 by the initializer, plus the `EmptyGroup()` sentinel store at +0. No literal function pointers written.
   - (b) `GetProcAddress` return values stored — **none** (DivxTac has 0 `GetProcAddress` calls anywhere).
   - (c) phmap `insert` / `emplace` calls — **none** targeting `FunctionMap`. The only `raw_hash_set<…GlobalOffsets…>` method the compiler actually instantiated is `destroy_slots`, called only from the finalizer.
4. **Verdict:** **CONFIRMED empty forever** — the map is created empty at DLL load and never populated by any DivxTac code path (managed or native). The `ManagedDetourMgr` detour framework was scaffolded but its function-address table was never wired up in the shipping build.
5. **JSON patch:** not required — `divxtac_globaloffsets.json` correctly reports an empty map.

## 7. Consequences for the AC map

- `ManagedDetourMgr` is **dead infrastructure** in the shipped DivxTac binary. It cannot be
  monitoring any client function via this map. Any function-level detour AC has to come from
  another surface: `Extensions.dll`'s 14-vector sink `FUN_100b5650`, or DivxTac's managed
  `AntiCheatService` / `BannedProccessesManaged` name-based scan.
- No new client VAs are added to the "monitored functions" set — the set contributed by
  DivxTac's `FunctionMap` is `∅`.
