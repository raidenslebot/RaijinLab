# R04 — Stealth surface (honest residual risk)

**Version:** runtime `1.7.1` + loader random-stage + PEB unlink + PE header wipe  
**Date:** 2026-07-21

## Claim boundary

**“Entirely undetectable to any form of Ascension AC” is not a claim we make.**  
AC is multi-layer (client behavioural, module name list, HWID, server-side metrics). Anything that plays the game can be banned by behaviour alone.

What we *did* implement is the **v1+ stealth path** from note `13_ac_evasion_strategy.md`.

## Hardening shipped

| Surface | Before | After |
|---|---|---|
| Module name in PEB | `RaijinLabRuntime.dll` | Random stage name **+ PEB self-unlink** (default ON; `RL_PEB_UNLINK=0` to skip) |
| LDR name strings | Full path visible while listed | Scrubbed before unlink |
| In-memory PE headers | Intact MZ/PE | **Wiped** after load (`RL_WIPE_PE=0` to skip) |
| FrameScript global | `IsLinuxClient` + branded globals | **Only** stock `IsLinuxClient` rebind |
| PE exports | Named exports | **None** (DllMain only) |
| Named mutex | Branded | Anonymous mutex |
| Console / window title | AllocConsole + brand | Off by default; inject window tails `runtime.log` instead |
| Log noise | Quiet WARN+ | Quiet default; **inject.bat sets `RL_LOG=1`** → full Trace→file, no game console |
| Config path | Fixed logs path | `%LOCALAPPDATA%\Microsoft\Crypto\Keys\~cfg.dat` |
| Actions | Addon CastSpell* (taint) | Runtime only + HW-gate patches |

## Operator: live log window

```
tools\inject.bat
```

1. Sets `RL_LOG=1` + `RL_PEB_UNLINK=1`  
2. Injects with random staged DLL name  
3. **Keeps the CMD open** and live-tails `C:\Ascension\Workspace\logs\runtime.log`  
4. Ctrl+C stops the tail only; then press a key to close  

Stealth-quiet inject (no log spam): run loader without `RL_LOG`, or `set RL_LOG=0` before inject.

## Residual risk (still real)

1. **LoadLibrary** still used — PEB unlinked + headers wiped; full **manual-map** still better (no loader entry at all).  
2. **CreateRemoteThread** inject footprint — visible to outside observers / future hooks.  
3. **HW-gate `.text` patches** — no self-hash *today* (note 13); can change.  
4. **Behaviour** — perfect rotation / CTM / reaction times are server-side ban material.  
5. **Addon folder name `RaijinLab`** — still on disk under Interface\AddOns.  
6. **HWID / opcode 1312** — still reported by stock AC; not spoofed here.

## Next stealth tiers

- Manual-map (no PEB)  
- Single-point AC packet filter (note 13 option c)  
- Behavioural humanization (reaction jitter, camera, afk patterns)  
- Optional sink-stub for Extensions anti-debug vectors (note 13 option a) — only if vectors are live on your build  
