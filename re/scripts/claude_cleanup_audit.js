export const meta = {
  name: 'raijin-cleanup-audit',
  description: 'Tidy-up support: (A) verify Grok runtime offsets + crash claims against the binary, diagnose "runtime nil"; (B) exhaustive keep/archive/delete manifest for the RaijinLab tree. Read-only analysis; Claude executes the file ops afterward.',
  phases: [
    { title: 'Audit', detail: 'offset/claim verifier + tree janitor manifest, in parallel' },
  ],
}

const CTX = `
RaijinLab root: C:\\Ascension\\Workspace\\RaijinLab\\
Client binary (offline, hash-matches live): C:\\Ascension\\Workspace\\RaijinLab\\re\\dumps\\Ascension.exe (x86, image base 0x400000).
My prior RE (authoritative, already verified): C:\\Ascension\\Workspace\\RaijinLab\\re\\ghidra_out\\Extensions.dll.decompiled.c (+symbols), and notes/10_example_code_integration.md which lists a VALIDATED Ascension.exe address set:
  ClntObjMgrGetActivePlayer 0x4D3790, ClntObjMgrObjectPtr 0x4D4DB0, ClntObjMgrEnumVisibleObjects 0x4D4B30,
  GetCamera 0x4F5960, CGPlayer_C::ClickToMove 0x727400, FrameScript_RegisterFunction 0x817F90,
  FrameScript_Execute 0x819210, TLS index global 0xD439BC, g_luaState 0xD3F78C.
Grok's runtime lives at runtime/src/. Key facts already established by Claude (trust these):
  - main.cpp calls RL::Bridge::Register()/Version() -> bridge/Dispatch.cpp (namespace RL::Bridge, "1.4.0-crashfix", FrameScript_RegisterFunction ONLY, no Execute-on-register). THIS is the live path.
  - bridge/LinuxClientBridge.cpp (namespace Bridge, "0.2.0-ascension-example-port") is NOT in runtime/src/CMakeLists.txt -> DEAD CODE. It still calls FrameScript_Execute during register (the crash-era pattern).
  - runtime/src/game/Offsets.h has the FunctionTable defaults (FrameScript_RegisterFunction=0x817F90, FrameScript_Execute=0x819210, lua_gettop=0x84DBD0, lua_tolstring=0x84E0E0, lua_tonumber=0x84E030, lua_pushnumber=0x84E2A0, lua_pushstring=0x84E350, lua_pushboolean=0x84E4D0, lua_settop=0x84DBF0, g_TlsIndex=0xD439BC, g_LuaState=0xD3F78C, g_WorldFrame=0xB7436C; ClntObjMgr* + GetCamera + ClickToMove + WorldIntersect 0x7A3B70).
  - Grok's crash note (notes/12_crash_85100086.md) claims 0x84F7A0 was wrongly used as lua_setfield and is actually a taint/assert path touching globals 0xD413A0 / 0xD4139C, causing ERROR #134 (0x85100086). 1.4.0 removed that path.
  - Config the DLL reads: C:\\Ascension\\Workspace\\logs\\raijinlab_vars.cfg (om.enable=0, taint.patch=0, register.toast=0, log.api=0, hacks.enable=0).
  - inject.bat runs runtime/dist/RaijinLabLoader.exe --dll runtime/dist/RaijinLabRuntime_latest.dll.
Tools: python (pefile, capstone). re/scripts helpers: disasm_window.py <pe> <va...>, const_xref.py, xref_imports.py.
`

const VERIFY_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['checks','runtime_nil_diagnosis','net_assessment'],
  properties: {
    checks: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['claim','address','verdict','evidence'],
      properties: {
        claim: { type: 'string' },
        address: { type: 'string' },
        verdict: { type: 'string', enum: ['CONFIRMED','REFUTED','UNCERTAIN'] },
        evidence: { type: 'string' },
      } } },
    runtime_nil_diagnosis: { type: 'string', description: 'most-likely cause(s) the addon sees runtime=nil, ranked, with the concrete check to confirm each' },
    net_assessment: { type: 'string', description: 'is the 1.4.0 register path safe to inject? will it likely fix runtime nil? outstanding risks.' },
    corrections: { type: 'array', items: { type: 'string' } },
  },
}

const JANITOR_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['actions','canonical_layout'],
  properties: {
    actions: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['path','action','reason'],
      properties: {
        path: { type: 'string', description: 'repo-relative path under RaijinLab/' },
        action: { type: 'string', enum: ['keep','archive','delete','rename','rewrite'] },
        dest: { type: 'string', description: 'for archive/rename: destination path' },
        reason: { type: 'string' },
      } } },
    canonical_layout: { type: 'string', description: 'the tidy target structure for runtime/dist, tools/bin, notes numbering' },
    note_collisions: { type: 'array', items: { type: 'string' }, description: 'numbering collisions in notes/ + proposed renames' },
    stale_docs: { type: 'array', items: { type: 'string' }, description: 'docs that are out of date and should be superseded/updated' },
  },
}

phase('Audit')

const [verify, janitor] = await parallel([
  () => agent(
    `Verify Grok's RaijinLab runtime offsets and crash claims against the actual Ascension.exe binary + my ghidra output. Be adversarial; cite disassembly.\n\n` +
    `CHECK EACH:\n` +
    `1. Is 0x817F90 FrameScript_RegisterFunction? (prologue + does it push a cclosure / rawset a global name?) disasm_window.py re/dumps/Ascension.exe 0x817F90.\n` +
    `2. Is 0x819210 FrameScript_Execute? \n` +
    `3. Is 0x84F7A0 NOT lua_setfield? What IS it? Does it reference globals 0xD413A0 / 0xD4139C (taint) as Grok claims? disasm it.\n` +
    `4. Are the lua C API addrs plausible (lua_gettop 0x84DBD0, lua_tolstring 0x84E0E0, lua_tonumber 0x84E030, lua_pushnumber 0x84E2A0, lua_pushstring 0x84E350, lua_pushboolean 0x84E4D0, lua_settop 0x84DBF0)? Spot-check 2-3 prologues.\n` +
    `5. g_luaState 0xD3F78C and TLS index 0xD439BC — consistent with my prior RE (notes/10)? \n` +
    `6. DIAGNOSE "runtime nil": the addon (addon/core/Runtime.lua) checks type(RaijinLab_Runtime)=="function" or type(IsLinuxClient)=="function". The 1.4 runtime registers both via FrameScript_RegisterFunction only, ~300ms after it first sees lua_State, gated by om/taint off. Given the last successful runtime.log run was 1.1.0 at 22:42 and a crash at 22:51 (1.3), and Grok said the game wasn't running when 1.4 was built — rank the likely causes of runtime=nil and give the exact confirm step for each (e.g., check runtime_status.txt / runtime.log for 'BRIDGE ONLINE', check the DLL was injected, check FrameScript_RegisterFunction actually took).\n` +
    `Return VERIFY_SCHEMA.\n\n` + CTX,
    { label: 'verify:offsets', phase: 'Audit', schema: VERIFY_SCHEMA, effort: 'high' }),

  () => agent(
    `Produce an EXHAUSTIVE keep/archive/delete manifest to tidy the RaijinLab tree. Prefer ARCHIVE over DELETE for anything Grok built (move to an archive/ subfolder), reserve DELETE only for regenerable build intermediates or exact-duplicate files. List EVERY non-trivial file/dir under runtime/ (dist, build, build_x86, src), tools/, and notes/ that should move/rename, plus the tidy target layout.\n\n` +
    `KNOWN FACTS to encode:\n` +
    `- runtime/dist/ DLL fingerprints: canonical latest = 386091495cfdf6fa (86016 bytes, 22:56) = _latest.dll = _225641.dll = build_x86 output. Historical distinct hashes: 4220f4dd (=_225331/_225607/_225625), 8035a486 (=_225150, the 22:51 CRASH build), 962bde27 (=_224455), ff15a45c (=_fix, also copied to tools/bin), 036e3145 (=dist/RaijinLabRuntime.dll plain + tools/bin, the OLD 20:25 build). runtime/build/RaijinLabRuntime.dll = a68d6743 (9216 bytes) is a WRONG-ARCH x64 stub.\n` +
    `- Canonical runtime output should be runtime/dist/RaijinLabRuntime.dll (= latest content), + RaijinLabLoader.exe + RaijinLabValidate.exe. All timestamped/_fix/_latest snapshots -> runtime/dist/archive/. inject.bat must then point at RaijinLabRuntime.dll (currently _latest.dll).\n` +
    `- runtime/build/ (x64 junk) vs runtime/build_x86/ (real). CMake build dirs are regenerable.\n` +
    `- tools/bin/ currently holds STALE runtime DLLs (036e old + ff15 fix) + RaijinLabLoader.exe + RaijinLabValidate.exe + x32dbg.cmd + x64dbg.cmd. inject.bat uses dist/, so the tools/bin runtime binaries are vestigial duplicates. Keep x32dbg.cmd/x64dbg.cmd (+ the big dnSpy/ghidra/jdk dirs under tools/bin — DO NOT touch those).\n` +
    `- runtime/src/bridge/LinuxClientBridge.cpp + .h are DEAD (not in CMakeLists.txt; namespace Bridge, superseded by bridge/Dispatch.cpp). Archive them. Note RL_SOURCES var in CMakeLists is defined-but-unused.\n` +
    `- notes/ numbering COLLISIONS: two 11_ (11_wowautosdk_integration.md is Grok's runtime-integration doc; 11a-f are Claude's AC RE) and two 12_ (12_ac_breakpoint_catalog.md = Claude AC RE; 12_crash_85100086.md = Grok runtime crash). Propose renames so RE series (11a-f,12 catalog,13,14 gaps,15) stays intact and runtime-dev notes get a distinct prefix (e.g. R-series or a notes/runtime/ subfolder). 07_status_and_next.md is STALE (pre-crash).\n` +
    `- tools/ loose python: _categorize_api.py, _list_api.py, _fix_runtime_lua.py, patch_api_bridge.py, patch_chat.py, rebrand.py — classify (scratch vs keep); suggest moving one-shot scripts to tools/scripts/.\n` +
    `- tools/installers/*.zip (dnSpy.zip, ghidra.zip, jdk21.zip, x64dbg.zip, x64dbg_try.zip) — large installers already extracted to tools/bin; candidate archive/delete.\n` +
    `Walk the real tree with find/ls to catch anything not listed above. Return JANITOR_SCHEMA with concrete repo-relative paths.\n\n` + CTX,
    { label: 'janitor:manifest', phase: 'Audit', schema: JANITOR_SCHEMA, effort: 'high' }),
])

return { verify, janitor }
