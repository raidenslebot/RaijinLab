# R03 — Crash ERROR #132 (0x85100084 / ACCESS_VIOLATION): worker-thread Lua execution

**Date:** 2026-07-21 09:03. **Fixed in:** runtime `1.4.1-nolua-worker`.

## Symptom
Client crashed at the **GlueXML / character-select** screen. WowError:
- `ERROR #132 (0x85100084)` → underlying `0xC0000005 ACCESS_VIOLATION at 0x00857D05`, reading `0x00000000`.
- Faulting instruction `0x857D05: 8B 38` = `mov edi,[eax]` with `EAX=0` → null-deref inside the Lua VM.
- **`Last FrameScript_Execute: if type(IsLinuxClient)=='function' then IsLinuxClient('Ping') end`** — verbatim the runtime's old `KickPing()` string.
- Faulting thread = **main thread**, stack: `…0x818F00 → 0x8190A9` (FrameScript_Execute) `→ 0x84EC11/46/9F` (lua_pcall ≈0x84EC50) `→` deep VM `→ 0x857D05`. Meanwhile `RaijinLabRuntime.dll` worker thread (ID 29360) was in `Sleep`.
- Context: `RealmData.lua`, `UPDATE_SELECTED_CHARACTER`, `ui_human.m2` (glue models).

## Root cause
The runtime's worker thread called `FrameScript_Execute(...)` every ~2 s (`KickPing`) to "pulse" the
player snapshot. The WoW Lua VM is **single-threaded / not reentrant**; the game runs it on the main
thread. When `KickPing` fired while the main thread was executing Lua (guaranteed at the busy
char-select screen), two threads entered the VM at once → heap/stack/pointer corruption → the main
thread dereferenced a corrupted null pointer at `0x857D05`.

The earlier "main-thread pulse via FrameScript_Execute" comment was **wrong**: `FrameScript_Execute`
runs the interpreter *inline on the calling thread*. Calling it from the worker thread does NOT
marshal to the main thread — it races it.

## Fix (1.4.1)
Removed **all** worker-thread Lua execution from `main.cpp`:
- Deleted `KickPing()`, `TrySafeToast()`, and the `SafeFrameScriptExecute` helper.
- The heartbeat now only reads the `MainThread::Get()` snapshot (a plain struct read — no Lua).
- Player state is pulsed **only on the main thread**, inside `Lua_IsLinuxClient` (i.e. when the addon
  or a `/run` calls the bridge). `heartbeat guid=0` is now expected until such a call.

Verified: `dist/RaijinLabRuntime.dll` (84 992 B, `1.4.1-nolua-worker`) contains no `IsLinuxClient('Ping')`
or `DEFAULT_CHAT_FRAME` string — no worker-thread Execute path remains.

## Residual risk / next runtime task
`Bridge::Register()` still calls `FrameScript_RegisterFunction` from the worker thread — the **same
class of race**, but a single quick call (pushcclosure+settable, µs window) that has been empirically
stable, vs the periodic full-interpreter Execute that crashed. **Proper fix:** run registration (and
any future runtime-initiated Lua) on the game main thread via a hook (detour a per-frame main-thread
client function, or an EndScene hook), then the worker thread only installs the hook and never touches
Lua. Until then: inject **in-world** (stable FrameXML state), not at the glue screen.
