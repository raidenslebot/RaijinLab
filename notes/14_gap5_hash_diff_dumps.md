# GAP 5 — SHA-256 hash-diff: `re/dumps` vs `re/dumps_mid_download`

**Verdict: CONFIRMED — analyzed binaries == final binaries.**
All five core binaries present in both directories are byte-identical.
No prior VA / offset / opcode / xref analysis from v1 is stale.

Script: `scratchpad/hash_diff.py`
Manifest: `C:\Ascension\Workspace\RaijinLab\re\dumps_manifest.json`

---

## 1. Core binary hash + PE timestamp table

| Binary | Size | SHA-256 (final) | mid == final? | PE TimeDateStamp (raw / UTC) |
|---|---:|---|:---:|---|
| Extensions.dll | 12,647,992 | `4e81e71157771b1d6b4ea1635a74e5f940cabbf45ff71d3521577ebf433b282e` | YES | 1784515974 (2026-07-15) |
| DivxTac.dll    |     98,816 | `30c3b677d63ed5814f8f15cb5962aba4c9f7b5f352d484bf9892ce0b77ffca65` | YES | 1633835898 (2021-10-10) |
| MMgr64.exe     |    364,032 | `fa9cbcd062edecc05fb116af7afa366b7323d24318e371364951d53d152e38d3` | YES | 1777846817 (2026-05-04) |
| Ascension.exe  |  7,694,848 | `5b26e33b2129737af3a0c3164459f4c9b109398dab921f76c6740a8746fbb929` | YES | 1277448958 (2010-06-25, classic WotLK 3.3.5a client) |
| DivxDecoder.dll|    413,696 | `ed34d37b575c91a56704218eb9f6abbefda8b7de0e2ed44c96191abd0f9915a5` | YES | 1076466304 (2004-02-10) |
| WowError.exe   |    205,824 | `a1a159d1f2e81e933533dcf24d045d701607192107d6f172da3b0d168df4eed6` | N/A (final-only) | 1760214735 (2025-10-11) |

## 2. Files present only in final dumps (not captured mid-download)

- `WowError.exe` (core, never triaged in v1)
- `d3d10core.dll`, `d3d11.dll`, `d3d8.dll`, `d3d9.dll`, `dxgi.dll` (graphics)
- `discord_game_sdk.dll`

These are final-only; no drift possible. They were fetched after the mid-download snapshot completed.

## 3. Files present only mid-download

None.

## 4. Changed core binaries (would invalidate VAs)

**None.** No version bump between mid-download and final for any of the 5 shared core binaries. `Extensions.dll` in particular carries the same 12,647,992-byte image with the same SHA-256 and same TimeDateStamp = 0x6A6E7186 (1784515974) in both locations, so:

- The 14 direct callers of `FUN_100b5650` at RVA 0x100b5650 are current.
- All `.vm_sec` VMProtect section geometry (33 KB, VA range from v1 note 11b) is current.
- Ghidra decompiled listings under `re/ghidra_out/` map 1:1 to the running binary.
- `divxtac_globaloffsets.json`, `ascension_ac_opcodes.json`, `ext_antidebug_vectors.json`, `ext_virtualprotect_callsites.json` are all valid against the shipped binary.
- YARA rules `yara/ascension_ac.yar` and `yara/ascension_ac_v2.yar` target the current build.
- x32dbg script `scripts/set_ac_breakpoints.x32dbg.txt` addresses are current.

## 5. Notes for follow-up

- `Ascension.exe` TimeDateStamp = 2010-06-25 is the untouched Blizzard 3.3.5a client header — Ascension patches at runtime rather than restamping.
- `Extensions.dll` TimeDateStamp is 2026-07-15 (four days before this diff was run) — this is the freshest AC surface and matches the mid-download capture, so the download did not swap it out on final launch.
- `DivxTac.dll` timestamp 2021-10-10 is stable and matches the managed dnSpy source we've been reading.
- `WowError.exe` was never mid-captured, so we cannot prove it wasn't swapped, but it is not part of the AC hot path in v1 findings; treat as untriaged (still true).

**Bottom line:** All v1 offsets, xrefs, decompilations, and YARA rules remain valid. No re-analysis required due to build drift.
