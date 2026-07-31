# Example Code Integration

**Source:** `C:\Ascension\Workspace\Example Code` (TurtleWoW_API by Einhar-style layout)  
**Vendored copy:** `RaijinLab/vendor/example_turtlewow_api/`  
**Integrated into:** `RaijinLab/runtime/src/`

## What the Example provides

Clean internal-hack architecture for a 3.3.5-class client:

| Piece | Role |
|-------|------|
| `Offsets.h` / `Functions.h` | Absolute VAs + typed function pointers |
| `Mem.h` | Read/Write templates |
| `API/*` | Object/Player/Unit/Camera/GameObject wrappers |
| `EnumVisibleObjects` + GUID → ptr | Object manager walk |
| `MoveTo` via ClickToMove | Movement |
| `DllMain` + worker thread | Inject lifecycle |
| VFunc `CallVFunc` | Name resolution pattern |

## Critical finding: offsets are NOT portable

Static validation against **Ascension.exe** showed Example VAs point at **garbage / mid-function** code.

| Example symbol | Example VA | On Ascension |
|----------------|------------|--------------|
| GET_PLAYER_GUID | `0x468550` | Invalid prologue |
| GET_OBJECT_PTR | `0x464870` | Starts with `int3` |
| ENUM_VISIBLE_OBJECTS | `0x468380` | Mid-function |
| GET_CAMERA | `0x4818F0` | Unrelated thiscall |

**Ascension matches stock 3.3.5.12340 OM/FrameScript:**

| Symbol | Ascension VA | Status |
|--------|--------------|--------|
| ClntObjMgrGetActivePlayer | `0x4D3790` | OK (TLS) |
| ClntObjMgrObjectPtr | `0x4D4DB0` | OK |
| ClntObjMgrEnumVisibleObjects | `0x4D4B30` | OK |
| GetCamera | `0x4F5960` | OK |
| CGPlayer_C::ClickToMove | `0x727400` | OK prologue |
| FrameScript_RegisterFunction | `0x817F90` | OK |
| FrameScript_Execute | `0x819210` | OK |

TLS index global: `0xD439BC`.

## What we kept vs changed

**Kept (structure):** namespaces, API layering, OM enum pattern, ClickToMove usage, console thread, DLL export surface.

**Replaced:** all function VAs with Ascension-validated set; object field offsets set to classic 3.3.5 (`Position 0x798`, etc.) pending live confirm; added ObjectManager snapshot; added `IsLinuxClient` / `RaijinLab_Runtime` FrameScript registration; added x86 loader.

## Build artifacts

```
runtime/build_x86/RaijinLabRuntime.dll   # inject into Ascension.exe
runtime/build_x86/RaijinLabLoader.exe    # LoadLibrary injector
runtime/dist/                            # copies
tools/bin/                               # copies
```

Rebuild:

```bat
"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" x86
cd C:\Ascension\Workspace\RaijinLab\runtime\build_x86
cmake -S ..\src -B . -G "NMake Makefiles" -DCMAKE_BUILD_TYPE=Release
nmake
```

## Runtime test procedure

1. Start Ascension, log in to world (character in-world).  
2. Ensure addon deployed (`tools\deploy_addon.ps1`).  
3. Run **as admin** if needed:  
   `tools\bin\RaijinLabLoader.exe`  
4. Expect console **RaijinLab Runtime** and chat message if register succeeds.  
5. In-game: `/rl status` — runtime should show version.  
6. END key unloads DLL.  

**AC risk:** LoadLibrary injection is visible to DivxTac module scans. Expect detection until stealth path exists. First goal is **functional correctness offline of stealth**.

## Remaining gaps

1. Resolve `lua_tostring` / `lua_push*` on Ascension so bridge returns real Lua values (currently register works; stack ops null-safe no-ops until resolved).  
2. Live-verify unit position / health descriptor offsets in-world.  
3. Confirm EnumVisibleObjects callback convention (cdecl guid,user) under load.  
4. Name vfunc index.  
5. Stealth load path vs TAC/MMgr.
