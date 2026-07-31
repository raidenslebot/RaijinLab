# Status board — 2026-07-20

## Done

- [x] Workspace + tool install (7zip, Ghidra, dnSpy, JDK21, x64dbg winget, MSVC x86, Python RE stack, YARA)
- [x] Final PE samples + triage + YARA validation of AC modules
- [x] First-run log harvest (MemoryBridge protocol 3, auth, realm, character)
- [x] Deep static RE notes (MB, TAC, natives)
- [x] Full cxmplexpack → RaijinLab rebrand (namespace, SV, TOC 30300)
- [x] Compat + Runtime bridge layers; Torghast removed from load path
- [x] Slash `/rl` `/raijin` `/raijinlab`
- [x] Deploy to `Interface\AddOns\RaijinLab` (27 files)
- [x] Runtime x86 stub DLL built + exported
- [x] MPQ extractor; base FrameXML/GlueXML/UIParent/ChatFrame extracted (Interface **30300**)
- [x] Frida probe script (attach-only)
- [x] Runtime CONTRACT.md + offset template

## In progress / blocked on live session

- [ ] Resolve OM / FrameScript offsets live (Ghidra + x32dbg)
- [ ] Capture MMgr64 command line + mapping name dynamically
- [ ] Dump ban lists / scan intervals from DivxTac at runtime
- [ ] Locate Ascension_* addon MPQ packages (not in enUS patches; not found under common names yet)
- [ ] Implement real Runtime (Lua register + OM) after offsets

## Known facts

- TOC interface for client FrameXML: **30300** (matches our addon)
- Custom UI primarily shipped via MPQ (not loose files)
- Extensions embeds custom Lua + MemoryBridge client + AnticheatMgr
- YARA: DivxTac / Extensions / MMgr64 all match expected rules
