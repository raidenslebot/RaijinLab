# WowAutoSDK Integration (Example Code resources)

**Source:** `Workspace/Example Code/resources/`  
**Vendored:** `RaijinLab/vendor/WowAutoSDK/`  
**Address merge:** `runtime/offsets/raijin_addresses.json` rev3

## What arrived

Full **WowAuto Suite v2** drop:

| Asset | Value |
|-------|-------|
| `wow_addresses_12340.h` | 80 addresses conf≥0.80 |
| `data/addresses/*.json` | Trust-chain JSON DB |
| `lua_unlocker.cpp` | Binary-only taint patches (working lineage) |
| `injector.cpp` | SeDebug + LoadLibrary injector |
| `addr_loader.h` | Runtime JSON address loader design |
| `Ascension*.h` SDK headers | Structs, opcodes, descriptors |
| Architecture.md | Failure audit (GlueXML crash, wrong g_luaState) |

## Critical corrections (do not trust SDK OM blindly)

| Symbol | SDK | RaijinLab (disasm) | Verdict |
|--------|-----|--------------------|---------|
| GetActivePlayer | `0x4D4DB0` | **`0x4D3790`** | SDK wrong (swap) |
| ObjectPtr | `0x4D4B30` | **`0x4D4DB0`** | SDK swap |
| EnumVisibleObjects | `0x4D3D50` | **`0x4D4B30`** | SDK different helper |
| ClickToMove | `0x468550` | **`0x727400`** | SDK invalid on Ascension |
| g_luaState | `0xD3F78C` | same | ✅ |
| FrameScript_* / lua_* | as SDK | same | ✅ |
| g_InWorld | `0xD3F60C` | adopted | ✅ |

## Integrated into runtime 1.1

1. **AddressDB.h** — canonical constants (merged + corrected)  
2. **Full Lua C API** — pushnil, pcall, toboolean, settop, etc.  
3. **InWorld lifecycle** — register only when `g_InWorld` + non-null `g_luaState`  
4. **TaintPatch** — optional (`taint.patch=1`) from lua_unlocker  
5. **Loader** — SeDebugPrivilege  
6. **Vendor** — SDK headers/src/address JSON for reference  

## Config

`C:\Ascension\Workspace\logs\raijinlab_vars.cfg`:

```
taint.patch=1
log.api=0
hacks.enable=0
```

## Lessons enforced (from SDK architecture)

- Never register Lua in GlueXML  
- Re-register after world enter  
- Byte-verify before every patch  
- SEH on all external calls  
- Single address source of truth with conflict log  
