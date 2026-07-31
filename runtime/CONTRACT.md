# RaijinLab Runtime Contract

## Purpose

The addon under `addon/` is an **unlocker-backed** FrameScript package. Ascension does **not** ship the unlocker natives that cxmplexpack expected. The Runtime is the process that:

1. Lives alongside `Ascension.exe` without tripping custom AC (DivxTac / Extensions / MMgr64)
2. Exposes the Lua bridge historically called `IsLinuxClient(name, ...)`
3. Implements object manager, movement, drawing, FS, and nav primitives listed below

This document is the **ABI contract** between addon and runtime. Implementors must satisfy it; the addon assumes it.

---

## Hard constraints (Ascension)

| Constraint | Detail |
|------------|--------|
| Client arch | **x86** (WOW64 on 64-bit Windows) |
| Build | 3.3.5 (12340) class + Extensions.dll |
| Co-process | `MMgr64.exe` MemoryBridge **protocol 3** must remain healthy |
| AC modules | `DivxTac.dll` (process/title/module/debugger), `AnticheatMgr` in Extensions |
| Detours | `DetourMgr` may guard sensitive game functions |
| Graphics | DXVK local d3d* may be present — treat as legitimate modules |

---

## Bridge entry points

### Primary (legacy unlocker symbol)

```text
IsLinuxClient(apiName: string, ...): any
```

Injected as a global Lua C function. The addon calls this exclusively for privileged ops.

### Preferred alias (RaijinLab)

```text
RaijinLab_Runtime(apiName: string, ...): any
```

Runtime should register **both** names to the same handler for forward compatibility.

### Filesystem token

Historical unlocker required a magic string on FS APIs. Addon now passes:

```text
RaijinLabRuntime
```

Runtime may ignore or validate this token.

---

## Required API surface (minimum viable)

Grouped. Names match `addon/core/API.lua` / historical `IsLinuxClient` first argument.

### App / path

- `GetAppStorageDirectory`, `GetAppDirectory`, `GetAppUsername`, `GetWoWDirectory`
- `GetSystemVar`, `SetSystemVar`

### Filesystem

- `FileExists`, `ReadFile`, `WriteFile`, `DirectoryExists`, `CreateDirectory`
- `GetDirectoryFiles`, `GetDirectoryFolders`

### Object manager

- `GetObjectCount`, `GetObjectWithIndex`, `GetObject`, `GetObjectWithGUID`
- `GetNpcCount`, `GetNpcWithIndex`
- `GetPlayerCount`, `GetPlayerWithIndex`
- `GetGameObjectCount`, `GetGameObjectWithIndex`
- `GetDynamicObjectCount`, `GetDynamicObjectWithIndex` (may no-op on 3.3.5)
- `GetAreaTriggerCount`, `GetAreaTriggerWithIndex` (may no-op on 3.3.5)
- `GetMissileCount`, `GetMissileWithIndex` (may no-op)

### Object fields / geometry

- `ObjectPosition`, `ObjectFacing`, `ObjectId`, `ObjectExists`, `ObjectDescriptor`, `ObjectField`
- `ObjectTypeFlags`, `ObjectIsType`, `ObjectScale`, `ObjectDynamicFlags`
- `ObjectIsFacing`, `ObjectIsBehind`
- `GetDistanceBetweenObjects`, `GetDistanceBetweenPositions`
- `GetAnglesBetweenObjects`, `GetPositionBetweenObjects`, `GetPositionBetweenPositions`, `GetPositionFromPosition`
- `GameObjectType`

### Unit

- `UnitCreator`, `UnitBoundingRadius`, `UnitCombatReach`, `UnitTarget`, `UnitFlags`
- `UnitCasting`, `UnitChannel`, `UnitCastingTarget`, `UnitTransport`, `UnitPitch`
- `UnitMovementFlags`, `UnitCreatureTypeId`, `UnitCreatureFamilyId`, `UnitCreatureField`
- `UnitIsLootable`, `UnitIsSkinnable`, `UnitIsMounted`
- `GetAuraCount`, `GetAuraWithIndex`

### World / LOS / camera

- `TraceLine`, `WorldToScreen`, `GetCameraPosition`
- `ClickPosition`, `FaceDirection`, `SetPitch`, `MoveTo`
- `StopFalling`, `ResetAfk`, `GetKeyState`

### Optional advanced (stub OK initially)

- Flying / noclip: `EnableFlyingMode`, `IsFlyingModeEnabled`, `GetNoClipModes`, `SetNoClipModes`, `SetClimbAngle`
- Navmesh: `LoadMap`, `UnloadMap`, `IsMapLoaded`, `MapExists`, `FindPath`, `GetClosestPositionOnMesh`, mesh polygon APIs
- Memory: `ReadMemory`, `GetMemoryOffset`
- Network sidechannel: HTTP / WebSocket helpers
- Packet logger APIs
- Quest: `ObjectIsQuestObjective`, quest giver status tables

---

## Object manager data model (3.3.5)

Runtime should walk the client **object manager** (linked list / hash, classic WotLK layout) and expose:

| Field | Notes |
|-------|-------|
| GUID | 64-bit |
| Type | Object / Item / Container / Unit / Player / GameObject / DynamicObject / Corpse |
| Position | x, y, z, facing |
| Entry ID | from descriptor |
| Pointer | opaque; only for runtime-internal use |

Descriptor offsets **must** be resolved per Ascension build (Extensions may shift fields). Maintain an offset DB:

```
runtime/offsets/ascension-live.json
```

---

## Safety / AC interaction policy

The runtime must:

1. **Not** kill or replace `MMgr64.exe`
2. **Not** break MemoryBridge handshake (PID + token + protocol 3)
3. Avoid known-bad process image names / window titles once denylist is captured
4. Avoid leaving PEB `BeingDebugged` / hardware breakpoints visible
5. Prefer read-only OM walks for MVP; write primitives (MoveTo, Click) after validation
6. Log to `Workspace/logs/runtime.log` — never to game directory if that is scanned

---

## Versioning

| Component | Version field |
|-----------|---------------|
| Addon TOC | `## Version` in `RaijinLab.toc` |
| Runtime | `RaijinLab_Runtime("GetRuntimeVersion")` → string |
| Offsets | `offsets_revision` in JSON |

Addon should refuse to run privileged features if runtime missing:

```lua
if type(IsLinuxClient) ~= "function" and type(RaijinLab_Runtime) ~= "function" then
  print("|cffff5555RaijinLab|r: runtime not loaded")
end
```

---

## Implementation status (1.0.0-ascension-edge)

| Piece | Status |
|-------|--------|
| Contract (this file) | Done |
| Offset DB | `offsets/ascension-live.json` + pattern scan |
| Native host | **Full x86 DLL** — 124-API dispatch, OM, CTM, FS, Lua bridge |
| Loader | `RaijinLabLoader.exe` (LoadLibrary; AC-visible) |
| Validator | `RaijinLabValidate.exe` offline PE scan |
| Frida probe | `re/scripts/frida_probe.js` |
| Addon | TOC 30300, status UI, runtime guards |

---

## Non-goals (still deferred)

- Full navmesh / Detour pathing
- Packet forging
- Server-side AC opcode spoofing
- Kernel drivers / manual-map stealth loader (planned research)
