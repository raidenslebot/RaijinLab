# RaijinLab — RUNBOOK (build · deploy · inject · troubleshoot)

Operational how-to. Consolidates the previously-scattered inject instructions.

---

## 1. Build the runtime (only if source changed)

```bat
tools\build_runtime.bat
```
Produces (into `runtime\dist\`): `RaijinLabRuntime.dll` (x86), `RaijinLabLoader.exe`,
`RaijinLabValidate.exe`. The DLL is the ONE canonical artifact — historical builds live in
`runtime\dist\archive\` (including `..._225150_CRASH_...` for forensics; do not inject those).

Offline offset sanity check (no game needed):
```bat
runtime\dist\RaijinLabValidate.exe
```

## 2. Deploy the addon

```powershell
powershell -ExecutionPolicy Bypass -File tools\deploy_addon.ps1
```
Then in the client AddOns list enable **RaijinLab**. Load-only mode (no runtime) is safe.

## 3. Inject the runtime — ORDER MATTERS

1. Start Ascension, log a character **fully into the world** (not char-select — the runtime
   needs a live `lua_State`; it registers ~300 ms after it first sees one).
2. Inject **once**:
   ```bat
   tools\inject.bat
   ```
   (= `runtime\dist\RaijinLabLoader.exe --dll runtime\dist\RaijinLabRuntime.dll`)
3. Do **not** inject more than once, and never inject the archived old/crash DLLs.
4. Press **END** (game focus) to unload the DLL.

Keep `logs\raijinlab_vars.cfg` at safe defaults (`om.enable=0`, `taint.patch=0`,
`register.toast=0`) for the first run.

## 4. Confirm it worked

- Log: `C:\Ascension\Workspace\logs\runtime.log` should show, newer than the inject time:
  ```
  RaijinLab Runtime 1.4.0-crashfix
  lua_State (nil) -> <ptr>
  BRIDGE ONLINE (safe path) L=<ptr>
  heartbeat guid=<NONZERO> objs=... pos=(...)
  ```
- In-game: `/rl status` → shows runtime version; and
  `/run print(type(RaijinLab_Runtime), type(IsLinuxClient))` → both `function`.

## 5a. `BRIDGE ONLINE` but `/rl status` does nothing / heartbeat `guid=0`

This is the **expected** picture when the DLL is injected but the **addon is not loaded**:

- `/rl` is an **addon** slash command; the DLL does not provide it. If the addon is
  disabled/not `/reload`ed, `/rl status` silently does nothing. Re-enable **RaijinLab** in the
  AddOns list and `/reload`.
- `heartbeat guid=0 objs=0 pos=(0,0,0)` is a **worker-thread TLS artifact**, not a failure.
  `ClntObjMgrGetActivePlayer` reads `fs:[0x2C]` (the *calling thread's* TLS). The runtime's own
  2 s heartbeat pings via `FrameScript_Execute` on its worker thread, where the game TLS slot is
  empty → 0. A **main-thread** call reads valid TLS and returns the real GUID.

Decisive check (works even with the addon disabled — `RaijinLab_Runtime` is a runtime-only global):
```
/run print(type(RaijinLab_Runtime), RaijinLab_Runtime and RaijinLab_Runtime('GetRuntimeVersion'))
```
Expect `function   1.4.0-crashfix`. The very next `heartbeat` line should then show a **non-zero
guid**, because that call pulsed `PulseFromMainThread` on the main thread. If so, the bridge is
fully working; just load the addon.

> **Known runtime limitation (Grok's lane):** the self-heartbeat will keep showing `guid=0`
> because `KickPing` runs on the worker thread. To make the runtime read player/OM state on its
> own, the player read must run on the game **main thread** (hook a per-frame client function, or
> only read inside `Lua_IsLinuxClient` which is already main-thread when the addon calls it).
> Not a blocker for addon-driven features.

## 5b. Troubleshoot `runtime = nil` (no `BRIDGE ONLINE` at all)

Ranked causes (from the offset-verification pass):

1. **DLL never loaded** (most common). No `1.4.0-crashfix` header in `runtime.log` newer than the
   inject. → Re-inject while in-world; confirm the log's `PID=` matches the live `Ascension.exe`.
2. **Injected too early** — at login/char-select the `lua_State` never stabilized, so `Register()`
   never fired. Log shows `lua_State` transitions but no `BRIDGE ONLINE`. → Inject only after in-world.
3. **`Register failed rc=...`** in the log — the `__try` guard caught a fault (rc = negated SEH
   code). → Capture the code and hand to Claude for offset re-check (offsets are currently verified,
   so this would be new).
4. **Loader/PID mismatch** — loader targeted the wrong process or `LoadLibrary` failed. → Check the
   loader exit code; confirm a fresh `runtime.log` write timestamp on inject.
5. **Addon false-negative** (unlikely; detection is version-agnostic). → `/run print(type(IsLinuxClient))`;
   if it prints `function`, the DLL side is fine and the issue is addon-side.

## 6. Escalating capability (only after the bridge is proven online with `guid≠0`)

Edit `logs\raijinlab_vars.cfg`, one flag at a time, re-testing between each:
`om.enable=1` (object manager enum) → `register.toast=1` (chat confirmation) →
`hacks.enable=1` / movement. `taint.patch=1` last, and only with Claude's sign-off.

## AC caution

LoadLibrary injection is visible to DivxTac's module-name scan (functional-correctness only, no
stealth yet). Do **not** kill `MMgr64.exe` (it's the MemoryBridge, not AC — killing it can stall the
client). If the realm runs Warden challenges, avoid static `.text` patches. See
`13_ac_evasion_strategy.md`.
