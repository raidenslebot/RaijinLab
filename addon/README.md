# RaijinLab

**Ascension-targeted** evolution of the former cxmplexpack unlocker addon.

## Target

- Client: Ascension Live (3.3.5 / 12340 class)
- Requires: RaijinLab Runtime (unlocker APIs; see `../runtime/CONTRACT.md`)
- Does **not** run as a vanilla addon — needs injected Lua natives

## Modules

| Module | Status on Ascension |
|--------|---------------------|
| Object Manager / Tracker | Core — keep |
| Drawing | Core — keep |
| Farming / Loot / Travel | Core — keep |
| Arena Awareness | Keep (PvP) |
| Quest helpers | Partial (3.3.5 quest APIs) |
| Torghast | **Removed** from TOC (SL-only) |

## Install (dev)

```
Interface/AddOns/RaijinLab/   <- copy contents of this `addon/` folder
```

## Namespace

- Global: `RaijinLab`
- SavedVariables: `RaijinLabDB`
- Runtime bridge: `IsLinuxClient` (historical unlocker symbol) or `RaijinLab.Runtime`

## Version

0.1.0-ascension — rebrand + TOC port in progress
