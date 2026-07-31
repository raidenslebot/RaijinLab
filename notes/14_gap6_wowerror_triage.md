# GAP 6 — WowError.exe first-pass triage

Status: **CONFIRMED benign crash reporter, no active AC role, weak passive attribution risk**
Author: Claude (Opus 4.7)  Date: 2026-07-20
Binary: `C:\Ascension\Workspace\RaijinLab\re\dumps\WowError.exe`

---

## 1. PE triage

| Field | Value |
|---|---|
| Size | 205,824 bytes (201 KiB) |
| SHA-256 | `a1a159d1f2e81e933533dcf24d045d701607192107d6f172da3b0d168df4eed6` |
| MD5    | `a1e3a59a6479d3b04db159a172f51fcf` |
| Machine | `0x14c` (x86) |
| Subsystem | `2` (GUI) |
| Image base | `0x00400000` |
| Entry point | RVA `0x0000b9e0` (VA `0x0040b9e0`) |
| Timestamp | `1760214735` = **2025-10-11 20:32:15 UTC** (recent, real, not zeroed/faked) |
| Linker | MSVC **14.44** (Visual Studio 2022 17.14) |
| PDB path (embedded) | `C:\a\Asc_WowError\Asc_WowError\client\Release\WowError.pdb` — the `C:\a\...` root is the **standard GitHub Actions Windows runner workspace**, so this was built in Actions CI from a repo called `Asc_WowError` |
| Version info | CompanyName `Project Ascension`, FileDescription `Ascension crash reporter`, InternalName `WowError`, OriginalFilename `WowError.exe`, ProductName `Ascension WowError Client`, FileVersion `1.0.0.0` |
| Signature | none observed |
| Packer | **none** — no VMProtect / Themida / UPX sections, no anomalous entropy |

### Sections

| Name | VA | VSize | RSize | Entropy | Chars |
|---|---|---:|---:|---:|---|
| .text    | 0x1000  | 140,490 | 140,800 | **6.61** (normal native code) | 0x60000020 |
| .rdata   | 0x24000 |  43,718 |  44,032 | 5.26 | 0x40000040 |
| .data    | 0x2f000 |   7,804 |   4,096 | 2.96 | 0xC0000040 |
| .fptable | 0x31000 |     128 |     512 | 0.00 (all-zero except a small function-pointer table — MSVC CFG artifact) | 0xC0000040 |
| .rsrc    | 0x32000 |   7,264 |   7,680 | 4.36 (dialog + icon + version) | 0x40000040 |
| .reloc   | 0x34000 |   7,588 |   7,680 | 6.63 | 0x42000040 |

No section obfuscation. Normal MSVC layout.

### Imports (0 exports)

| DLL | Count | Notable |
|---|---:|---|
| **WINHTTP.dll** | 10 | `WinHttpOpen/Connect/OpenRequest/SendRequest/ReceiveResponse/QueryHeaders/QueryDataAvailable/ReadData/SetTimeouts/CloseHandle` — HTTPS client, this is the upload channel |
| KERNEL32.dll | 98 | CRT startup + `GetSystemInfo`, `GetVersionExA`, `GetComputerNameA`, `GlobalMemoryStatusEx`, `GetTimeZoneInformation`, `SetUnhandledExceptionFilter`, `IsDebuggerPresent` (all MSVC-CRT-default), `VirtualProtect` (CRT-default), `LoadLibraryExW`, `CreateThread`. **No** `CreateProcess`, **no** `OpenProcess`, **no** `ReadProcessMemory`, **no** `WriteProcessMemory`, **no** `Process32*`/`EnumProcess`, **no** `Module32*`, **no** `Toolhelp*` |
| USER32.dll | 36 | Standard dialog + window mgmt (`DialogBoxParamA`, `CreateWindowExA`, `MessageBoxA`) |
| GDI32.dll | 7 | Dialog painting |
| SHELL32.dll | 1 | `CommandLineToArgvW` |

**Absent imports (checked, not present):**
`dbghelp.dll` (no `MiniDumpWriteDump`, no `StackWalk*`, no `SymFromAddr`); `psapi.dll` (no `EnumProcessModules`, no `GetModuleInformation`); `crypt32.dll`, `advapi32.dll` (no `Crypt*`, no `Reg*`, no `Get*Sid`, no `Get*Token`); `iphlpapi.dll` (no `GetAdaptersInfo`, no MAC lookup); `setupapi.dll`/`wmi`/`wbemuuid` (no SMBIOS, no `PhysicalDrive*`, no `MachineGuid`).

**No AC-adjacent imports at all.**

---

## 2. String scan (relevant hits)

### 2a. Network / endpoint (**decisive**)

- `https://` – present
- `crash-report.ascension.gg` – **upload host**
- `B/api/v1/crash` (leading `B` is a length-prefixed C string preamble from adjacent data) → path is **`/api/v1/crash`**
- `Ascension WowError Client/1.0` – **User-Agent**
- `Content-Type: application/json`
- `Accept: application/json`
- `Server responded with HTTP status ` – error path
- No other hosts, no fallback endpoints, no telemetry servers.

**Full endpoint reconstructed:** `POST https://crash-report.ascension.gg/api/v1/crash` with JSON body.

### 2b. Payload fields (from format strings — every `%…` line becomes a JSON value in the request)

```
Processor:              0x%lx
Page Size:              %lu
Min App Address:        0x%p
Max App Address:        0x%p
Processor Mask:         0x%llx
Number of Processors:   %lu
Processor Type:         %lu
Allocation Granularity: %lu
Processor Level:        %hu
Processor Revision:     %hu
Os Version:             %lu.%lu
Os Service Pack:        %hu.%hu
Wine Runtime:           %s              <-- NOTE: it detects and reports Wine
Percent memory used:    %lu
Total physical memory:  %llu
Free Memory:            %llu
Page file:              %llu
Total virtual memory:   %llu
Windows %lu.%lu (SP %hu.%hu)
%s (%lu cores)
Type %lu Level %hu Revision %hu
%llu MB
```

Plus: computer name (from `GetComputerNameA`) and **user-typed free text** from the dialog (`"Describe what you were doing when the crash occurred"`).

That is the complete set — no stack trace, no module list, no crash address, no hashes, no HWID.

### 2c. UI strings (confirms this is a user-facing dialog, not a silent uploader)

- `Ascension Crash Report` (window title)
- `The following data will be sent Ascension when you click Send` [sic — trailing "to" missing]
- `Though you can opt not to send this information, doing so will help us to improve the game.`
- `Describe what you were doing when the crash occurred`
- `Press Send to Send` / `Sending` / `Send successful` / `Done` / `Error sending data`
- Buttons: send / cancel

Consent-gated Send. User can cancel.

### 2d. AC / HWID / crypto / dump — **all absent**

Zero hits for: `anticheat`, `warden`, `ban`, `kick`, `cheat`, `hack`, `bot`, `detour`, `hook`, `inject`, `unlock`, `DivxTac`, `Extensions`, `MMgr`, `Raijin`, `CMSG_`, `SMSG_`, `opcode`.
Zero hits for: `HWID`, `PhysicalDrive`, `SerialNumber`, `MachineGuid`, `WMI`, `SMBIOS`, `BIOS`, `MAC`, `adapter`, `CPUID`, `Volume`, `Registry`, `RegQuery`.
Zero hits for: `sha`, `md5`, `crypt`, `hmac`, `ssl`, `tls`, `cert`, `key`, `nonce`, `salt` (only `TlsAlloc`/`TlsGetValue` — thread-local storage, unrelated).
Zero hits for: `MiniDump`, `dbghelp`, `dump`, `StackWalk`, `SymFromAddr`, `EXCEPTION_POINTERS`, `Module32`, `EnumProcess`, `OpenProcess`, `CreateProcess`, `CreateRemoteThread`.
Zero hits for: `account`, `username`, `password`, `email`, `token`, `cookie`, `session`, `login`.

### 2e. Third-party libs

- `nlohmann::json` v3.12.0 (JSON serializer) — RTTI names `.?AV…json_abi_v3_12_0@nlohmann@@` present. This is the payload encoder.

---

## 3. Ascension.exe ↔ WowError.exe xref

The Ascension.exe strings blob contains the literal `"WowError.exe\0"` once, at file offset `0x5e0694` / VA `0x009e1e94`.

Two code references to that VA (both in `.text`):

1. **`0x00403515`** — inside function starting `0x004034f0`:
   ```asm
   004034f0  push ebp; mov ebp,esp; sub esp,0x30c
   004034f9  push 0x104
   004034fe  lea eax, [ebp - 0x104]
   00403504  push eax
   00403505  call 0x00771960        ; helper that fills [ebp-0x104] with a path
   0040350a  test eax,eax
   0040350c  jz   0x00403548
   0040350e  lea ecx, [ebp - 0x104]
   00403514  push ecx               ;   arg2 of snprintf → 2nd %s (path)
   00403515  push 0x009e1e94        ;   arg1 of snprintf → 1st %s = "WowError.exe"
   0040351a  push 0x009e1e8c        ;   fmt = "%s %s"
   0040351f  lea edx, [ebp - 0x30c]
   00403525  push 0x208             ;   dst size = 520
   0040352a  push edx               ;   dst buffer
   0040352b  call 0x0076f070        ;   snprintf_s
   00403530  add esp, 0x14
   00403533  push 0
   00403535  push 0
   00403537  lea eax, [ebp - 0x30c]
   0040353d  push eax               ;   command line
   0040353e  push 0x009e1e94        ;   application name = "WowError.exe"
   00403543  call 0x00770290        ;   CreateProcess-style wrapper (0x1094-byte stack frame; consistent with STARTUPINFO+PROCESS_INFORMATION locals)
   00403548  mov eax, 1
   0040354d  leave; ret 0x14
   ```
   Format string at `0x9e1e8c` reads verbatim `"%s %s\0\0\0WowError.exe\0…"` — confirms this function builds the command line `"WowError.exe <path>"` and spawns the child. Return `1` indicates success/report-sent, `0x14` argstack matches an `int __stdcall foo(...)` with five DWORD args.

2. **`0x0040353e`** — same site, second use (passed as `lpApplicationName`).

So Ascension.exe **spawns WowError.exe as a child process** exactly once in its code base, from a single helper routine, most plausibly from its unhandled-exception filter (standard Blizzard-style postmortem pattern). No other Ascension.exe imports/strings reference WowError beyond this one call site.

Ascension.exe uses `WININET.dll` (not WinHTTP) for its own network, so the two binaries do not share HTTP code — WowError.exe is a standalone reporter reached only by process spawn.

---

## 4. AC role assessment

**Question:** does WowError.exe act as an anti-cheat vector — either actively probing the client, or passively leaking information that identifies RaijinLab-modified installs?

### 4a. Active AC probing — **none**

WowError.exe **cannot** read the crashed process because it has no `OpenProcess` / `ReadProcessMemory` / `dbghelp` / `psapi` imports. Unlike a standard Blizzard `WowError.exe`, this build does **not** generate a minidump, walk the crashed process's stack, enumerate its modules, or open a handle to the parent PID. It only reads its **own** process context (system info, its own memory stats) plus a user text field. There is no code path that could exfiltrate module names, injected-DLL evidence, hooked-import tables, or scanning results.

### 4b. Passive attribution risk — **low but non-zero**

Fields sent to `crash-report.ascension.gg/api/v1/crash` that carry identifying signal:

| Field | Attribution value |
|---|---|
| `GetComputerNameA` | **Medium.** Uniquely identifies the machine on the account's operator's LAN; if the operator has told anyone the machine name, this can dox a private server user. |
| `Wine Runtime: %s` | **Medium for AC context.** Explicitly flags Linux/macOS users running under Wine — a server operator could use this to segment/ban a Wine-run population if they cared. Not directly Raijin-relevant. |
| User free-text (`Describe what you were doing`) | **User-controlled**, so risk depends on user discipline. |
| CPU/OS/RAM signature | **Very weak fingerprint** on its own; low uniqueness. |
| **Crashing exception address, thread state, module list** | **NOT SENT** — WowError has no imports to obtain any of these. The absence of dbghelp and psapi is the strong signal. |

There is **no** evidence WowError.exe was written to catch cheats — it does not sniff for RaijinLab, does not report loaded DLLs, does not hash the client, does not enumerate hardware IDs. The tells one would expect from a cover-story crash reporter (a call-stack, a module list, or a client-hash field) are all absent.

**However**, since Ascension.exe launches WowError.exe from what is almost certainly its `SetUnhandledExceptionFilter` callback, and since the Extensions.dll `FUN_100b5650` violation sink is a plausible cause of forced crashes, WowError may end up being seen a lot by RaijinLab users. That is fingerprintable at the *server* level (spike in crash reports from one IP), but not by anything WowError itself does.

### 4c. Verdict

**(a) Benign crash reporter.** Not (b). Standard "system info + user description → HTTPS JSON POST" pattern. Zero AC-scanning code, zero HWID collection, zero introspection of the crashed process. The AC-adjacent risks are entirely inherited from the parent (Ascension.exe) — whatever arguments Ascension.exe passes on the command line at `call 0x00770290`, and whatever the user types in the free-text box.

Recommend RaijinLab treatment: **do not ship / suppress**. Two simple, safe options:

1. **Block the endpoint.** Deny outbound to `crash-report.ascension.gg` at hosts-file / firewall level. WowError will hit `Server responded with HTTP status …` path and abandon.
2. **Neuter the spawn.** In a private WoW launcher, patch Ascension.exe function starting at `0x004034f0` to `ret 0x14` immediately (or NOP the `call 0x00770290` at `0x00403543`) — prevents WowError.exe from ever launching. Confirms benign, so no functional AC impact from suppressing it.
3. **Delete/rename `WowError.exe` in the install dir.** The parent's `CreateProcess` will fail, no user dialog, no upload.

Any one of the three fully removes the (already weak) attribution vector.

---

## 5. Data written

- Full JSON triage: `C:\Ascension\Workspace\RaijinLab\re\wowerror_triage.json`
- This report: `C:\Ascension\Workspace\RaijinLab\notes\14_gap6_wowerror_triage.md`

## 6. Followup (fields uploaded — not an AC finding, informational)

Complete uploaded payload set:
- `computer_name` (from `GetComputerNameA`)
- CPU: architecture, page size, min/max app address, mask, count, type, level, revision, allocation granularity, cores
- Memory: percent used, total physical, free, page file, total virtual (all bytes)
- OS: major.minor version + service pack major.minor
- **Wine Runtime string** (Windows API returns something Wine-specific — flags non-native Windows)
- **User-typed free-text description**
- Timezone info (from `GetTimeZoneInformation`) — plausible, imported but not tied to a format string
- Client identifier: hardcoded `Ascension WowError Client/1.0` in User-Agent

Notably **absent** from payload: crash address, stack trace, loaded module list, client executable hash, HWID, MAC, disk serial, machine GUID, username, path names.
