# WowAuto Suite v2 — Architecture & Design

> **A failure-hardened, AI-orchestrated framework for World of Warcraft reverse engineering, addon development, memory patching, and detection evasion — built on the ashes of 11 failed tools and 4 crashes.**

---

## Table of Contents

1. [Design Philosophy](#1-design-philosophy)
2. [Failure Audit & Lessons](#2-failure-audit--lessons)
3. [Trust Chain Architecture](#3-trust-chain-architecture)
4. [Agent System](#4-agent-system)
5. [Skill Library](#5-skill-library)
6. [MCP Servers](#6-mcp-servers)
7. [Hook System](#7-hook-system)
8. [Instructions & Prompts](#8-instructions--prompts)
9. [Data Layer](#9-data-layer)
10. [Workflows](#10-workflows)
11. [Runtime Diagnostics Engine](#11-runtime-diagnostics-engine)
12. [Injection Pipeline](#12-injection-pipeline)
13. [SDK Header Auto-Regeneration](#13-sdk-header-auto-regeneration)
14. [Struct & Descriptor Reverse Engineering](#14-struct--descriptor-reverse-engineering)
15. [Network Layer & Opcode Analysis](#15-network-layer--opcode-analysis)
16. [Automated Testing Framework](#16-automated-testing-framework)
17. [Rollback & Recovery System](#17-rollback--recovery-system)
18. [Existing Asset Integration](#18-existing-asset-integration)
19. [Directory Map](#19-directory-map)
20. [Setup & Bootstrap](#20-setup--bootstrap)

---

## 1. Design Philosophy

### 1.1 Core Principles

This suite was born from **systematic failure**. Over 10+ sessions, we built 11 verification tools across 6 iterations each, produced 4 crashes, and discovered that every auto-generated address was wrong. The suite exists to make these failures **structurally impossible**.

| Principle | What It Means | What It Prevents |
|-----------|---------------|------------------|
| **Trust Nothing** | Every address, offset, and pointer must trace back to a verified anchor point through disassembly evidence | Wrong addresses (g_luaState was off by 0x9694 bytes) |
| **Anchor-First RE** | Always start from a known-good function prologue, trace outward through call graphs | Circular validation loops (11 tools, 0 results) |
| **Crash-Proof by Default** | All memory reads wrapped in SEH, all function calls behind fallback chains, all pointers validated before dereference | ACCESS_VIOLATION at 0x77C41E1E reading 0x0000000C |
| **Context-Aware Lifecycle** | Distinguish GlueXML (login) vs FrameXML (in-game) Lua states; never register in the wrong one | GlueXML teardown destroying registered closures |
| **Binary Patches > Function Calls** | When possible, patch bytes (JE→JMP) instead of calling unverified functions | lua_unlocker v7 works; rotation_engine v5 crashed |
| **Single Source of Truth** | One canonical address database (`data/addresses/`), generated from binary evidence, consumed by all agents and code | Conflicting labels (0xD3F78C = "g_currentMapId" AND "g_luaState") |
| **Progressive Confidence** | Addresses start at confidence=0, gain confidence through prologue check → call-graph → cross-ref → runtime test | Premature use of unverified addresses |
| **Defensive Multiplicity** | 3+ methods for every critical operation; if method 1 crashes via SEH, method 2 tries a different path | Single-point failures in object manager, player lookup |

### 1.2 The Golden Rule

> **No address enters the codebase unless it has a Trust Chain: a verified anchor point → disassembly trace → cross-reference confirmation → confidence score ≥ 0.8.**

This is enforced at every level: hooks block code generation with unverified addresses, agents refuse to produce code without verification, skills include mandatory validation steps.

### 1.3 Model Requirement

All agents and subagents **MUST** use Claude Opus 4.6. This is non-negotiable. The reasoning depth required for binary analysis, cross-referencing disassembly, and designing evasion strategies exceeds what smaller models can provide. Fallback to other models is explicitly forbidden.

```yaml
model: "claude-opus-4-20250514"
```

---

## 2. Failure Audit & Lessons

### 2.1 The Address Catastrophe

Every auto-generated global variable address was wrong:

| Global | Auto-Generated | Reality | Delta | How Discovered |
|--------|---------------|---------|-------|----------------|
| `g_luaState` | 0xD415F8 | **0xD3F78C** | -0x986C | `mov esi,[0xD3F78C]` inside FrameScript_Execute |
| `g_InWorld` | 0xC7D0EC | **0xD3F60C** | +0xC2520 | Binary scanner bool-write pattern near g_luaState |
| `lua_pushstring` | 0x84E3D0 | **0x84E350** | -0x80 | 0x84E3D0 = lua_pushlstring (3 args); 0x84E350 = lua_pushstring (2 args, 1008 callers) |
| `g_currentMapId` | 0xD3F78C | **WRONG LABEL** | N/A | 0xD3F78C IS g_luaState, not g_currentMapId |

**Root cause**: IDA auto-analysis heuristics produced plausible but incorrect results. No human or automated verification existed to catch them before use.

**Suite prevention**: Trust Chain Architecture (Section 3) makes this structurally impossible.

### 2.2 The GlueXML Crash

**What happened**: rotation_engine v6.0 registered 49 Lua closures in the GlueXML Lua state (login screen). When the player clicked "Enter World", the WoW client destroyed the GlueXML Lua VM and created a new FrameXML VM. The registered closures pointed to freed memory → ACCESS_VIOLATION.

**Suite prevention**: The `dll-engineering` skill encodes the GlueXML/FrameXML lifecycle as a mandatory design pattern. The `context-lifecycle` hook validates that all DLL code checks InWorld + lua_State validity before any Lua operation.

### 2.3 The Verification Tool Spiral

11 Python tools across 5-6 iterations each, **zero conclusive results**:

| Tool Family | Iterations | Approach | Why It Failed |
|-------------|-----------|----------|---------------|
| `verify_addresses[1-5].py` | 5 | PE parsing, byte matching, caller site analysis | Bytes existing at an address ≠ correct function; heuristics fail when compiler optimizes |
| `disasm_taint[1-6].py` | 6 | Guess addresses, look for taint patterns | No anchor point; each guess propagated errors from the previous guess |

**Root cause**: Circular dependency — can't verify functions without knowing what they do; can't know what they do without correct addresses.

**Suite prevention**: The `anchor-first` methodology in `wow-binary-scanning` skill breaks the circularity by starting from a human-verifiable prologue and tracing outward.

### 2.4 The Assumption Cascade

| Assumption | Reality | Damage |
|-----------|---------|--------|
| Auto-generated addresses are reliable | ~40 addresses wrong or conflicting | 4 crashes, 10+ debug sessions |
| More verification iterations = better | Method was flawed, not effort | 11 tools × 6 iterations = 0 useful results |
| Pattern matching can verify addresses | Patterns exist at wrong addresses too | False positives everywhere |
| Label from one tool = ground truth | Different tools gave different labels for 0xD3F78C | Identity crisis, cross-contamination |
| Calling Lua functions is always safe | Wrong address = immediate crash | ACCESS_VIOLATION in securecall |
| GlueXML and FrameXML share Lua state | They are separate VMs with separate lifetimes | Registration in wrong VM = crash on transition |

**Suite prevention**: Every assumption is encoded as a **validation checkpoint** in the relevant skill or hook.

---

## 3. Trust Chain Architecture

This is the suite's core innovation. Every piece of data flows through a chain of verification before it can be used.

### 3.1 The Trust Chain

```
Level 0: RAW BINARY
  │  Read bytes from PE sections (.text, .data, .rdata)
  │  Confidence: 0.0 (unverified raw data)
  ▼
Level 1: PROLOGUE VERIFICATION
  │  Find function start via prologue pattern (55 8B EC = push ebp; mov ebp, esp)
  │  Verify prologue is at expected offset from PE base
  │  Confidence: 0.3 (confirmed function boundary)
  ▼
Level 2: ANCHOR POINT ESTABLISHMENT
  │  Pick a known-good function (FrameScript_Execute @ 0x819210)
  │  Verify its prologue, verify it's in .text section
  │  This becomes the trust root — all other addresses derive from it
  │  Confidence: 0.5 (verified anchor)
  ▼
Level 3: CALL-GRAPH TRACING
  │  From anchor, follow CALL rel32 instructions to discover targets
  │  Each target inherits trust from the verified caller
  │  Extract literal operands (MOV reg, [imm32]) for global addresses
  │  Example: FrameScript_Execute contains `mov esi, [0xD3F78C]` → g_luaState
  │  Confidence: 0.7 (anchored via call graph)
  ▼
Level 4: CROSS-REFERENCE CONFIRMATION
  │  Verify address appears in multiple independent call sites
  │  Check caller count (lua_pushstring: 1008 callers vs lua_pushlstring: 15)
  │  Verify argument count matches expected signature
  │  Confidence: 0.8 (cross-referenced, usable in code)
  ▼
Level 5: RUNTIME VALIDATION
  │  Read memory at runtime, verify expected patterns
  │  For globals: verify non-null when InWorld=1
  │  For functions: verify callable with safe test arguments
  │  Confidence: 0.95 (runtime confirmed)
  ▼
Level 6: PRODUCTION USE
  │  Address used in compiled DLL with SEH protection
  │  Fallback chain in place if address fails at runtime
  │  Confidence: 1.0 (battle-tested)
```

### 3.2 Confidence Scoring

Every address in `data/addresses/` carries a confidence score:

```json
{
  "name": "g_luaState",
  "address": "0x00D3F78C",
  "confidence": 0.95,
  "trust_chain": [
    {"level": 1, "evidence": "prologue 55 8B EC at offset 0x419210"},
    {"level": 2, "evidence": "anchor: FrameScript_Execute @ 0x819210"},
    {"level": 3, "evidence": "mov esi,[0xD3F78C] at 0x819249 inside anchor"},
    {"level": 4, "evidence": "cross-ref: 47 other functions read from 0xD3F78C"},
    {"level": 5, "evidence": "runtime: non-null pointer (0x1C177628) when InWorld=1"}
  ],
  "section": ".data",
  "type": "global_pointer",
  "size": 4,
  "build": "12340",
  "conflicts": [
    {"label": "g_currentMapId", "source": "sdk_metadata.json", "resolution": "MISLABEL - verified as g_luaState via disasm"}
  ]
}
```

### 3.3 Confidence Gates

| Confidence | Allowed Use |
|-----------|-------------|
| 0.0 – 0.29 | Read-only analysis; never reference in code |
| 0.3 – 0.49 | Can appear in comments and documentation |
| 0.5 – 0.69 | Can be used in experimental scripts with warning |
| 0.7 – 0.79 | Can be used in code with SEH protection + fallback |
| 0.8 – 0.94 | Can be used in code with SEH protection |
| 0.95 – 1.0 | Full production use |

The `PreToolUse` hook enforces these gates: any code generation referencing an address below 0.8 confidence is blocked with a warning.

---

## 4. Agent System

### 4.1 Agent Roster

Ten agents, each with a focused role and minimal tool surface:

| # | Agent | File | Role | Tools | Key Innovation |
|---|-------|------|------|-------|----------------|
| 1 | **Orchestrator** | `orchestrator.agent.md` | Master workflow coordinator | `agent`, `read`, `search`, `todo`, `web` | Delegates everything; never writes code directly |
| 2 | **RE-Analyst** | `re-analyst.agent.md` | Reverse engineering & disassembly analysis | `read`, `search`, `execute`, `wow-addresses/*` | Anchor-first methodology; produces Trust Chains |
| 3 | **Binary-Scanner** | `binary-scanner.agent.md` | Raw binary pattern scanning (no IDA required) | `read`, `execute`, `search` | Headless scanning with address_scanner.py patterns |
| 4 | **Addon-Engineer** | `addon-engineer.agent.md` | WoW addon Lua development | `read`, `edit`, `search`, `execute` | GlueXML/FrameXML lifecycle awareness |
| 5 | **DLL-Engineer** | `dll-engineer.agent.md` | C++ DLL development (rotation_engine, lua_unlocker) | `read`, `edit`, `search`, `execute` | SEH wrapping, fallback chains, InWorld gating |
| 6 | **Warden-Analyst** | `warden-analyst.agent.md` | Detection analysis & evasion design | `read`, `edit`, `search`, `execute`, `warden-patterns/*` | Signature matching, PEB hiding, VEH techniques |
| 7 | **Verifier** | `verifier.agent.md` | Address & code verification specialist | `read`, `search`, `execute`, `wow-addresses/*` | Trust Chain validation, confidence scoring |
| 8 | **IDA-Bridge** | `ida-bridge.agent.md` | IDA Pro automation & script generation | `read`, `edit`, `execute`, `ida-bridge/*` | IDAPython script generation, disasm export |
| 9 | **Crash-Analyst** | `crash-analyst.agent.md` | Crash log parsing, post-mortem, root cause analysis | `read`, `search`, `execute`, `wow-addresses/*` | Automated crash→root cause→fix pipeline |
| 10 | **Injection-Engineer** | `injection-engineer.agent.md` | DLL injection, process manipulation, launcher | `read`, `edit`, `search`, `execute` | Multi-method injection, privilege escalation, timing |

### 4.2 Agent Relationships

```
User
 │
 ▼
┌─────────────────────────────────────────────────────┐
│                   ORCHESTRATOR                       │
│  Receives all user requests. NEVER writes code.      │
│  Delegates to specialists. Verifies cross-agent      │
│  consistency. Maintains the master address database.  │
│  Has web access for researching WoW internals,       │
│  Warden updates, and community RE findings.          │
│                                                       │
│  Handoffs:                                            │
│  ├── RE task ──────────→ RE-Analyst                  │
│  ├── Scan task ────────→ Binary-Scanner              │
│  ├── Addon task ───────→ Addon-Engineer              │
│  ├── DLL task ─────────→ DLL-Engineer                │
│  ├── Warden task ──────→ Warden-Analyst              │
│  ├── Verify task ──────→ Verifier                    │
│  ├── IDA task ─────────→ IDA-Bridge                  │
│  ├── Crash task ───────→ Crash-Analyst               │
│  └── Inject task ──────→ Injection-Engineer          │
└─────────────────────────────────────────────────────┘

Cross-agent verification flow:
  RE-Analyst ──(discovered address)──→ Verifier ──(trust chain)──→ Orchestrator
  DLL-Engineer ──(needs address)──→ Orchestrator ──(lookup)──→ data/addresses/
  Addon-Engineer ──(needs C API)──→ Orchestrator ──(delegate)──→ RE-Analyst
  Warden-Analyst ──(needs hooks)──→ DLL-Engineer
  Binary-Scanner ──(raw results)──→ Verifier ──(scored)──→ data/addresses/
  IDA-Bridge ──(disasm export)──→ RE-Analyst ──(analysis)──→ Verifier
  Crash-Analyst ──(root cause)──→ DLL-Engineer ──(fix)──→ Verifier ──(re-verify)
  Injection-Engineer ──(needs DLL)──→ DLL-Engineer ──(build)──→ Warden-Analyst ──(audit)
```

### 4.2.1 Failure Recovery Flow

When something goes wrong, the suite has a structured recovery path that prevents the "spiral of guessing" that cost us 10+ sessions:

```
CRASH DETECTED (user pastes log or ascension-live/Errors/ updated)
  │
  ▼
Crash-Analyst parses exception (address, fault type, call stack, module)
  │
  ├── Is crash in our DLL? ──→ DLL-Engineer: locate function, add SEH/null check
  ├── Is crash in Lua? ──→ RE-Analyst: verify lua_State was valid at crash time
  ├── Is crash in game code? ──→ Verifier: check if we patched that region
  └── Is crash in ntdll/OS? ──→ Crash-Analyst: trace cascading fault backward
  │
  ▼
Root cause identified + fix proposed
  │
  ├── Verifier: re-verify all addresses touched by the fix
  ├── Warden-Analyst: audit fix for detectability
  └── DLL-Engineer: rebuild with fix
```

### 4.3 Agent Design Patterns

Each agent follows these structural rules (learned from failures):

**Pattern 1: No Unverified Address Usage**
```
BEFORE writing any code that references a game address:
1. Query data/addresses/ for the address
2. Check confidence >= 0.8
3. If confidence < 0.8, delegate to Verifier first
4. If address not found, delegate to RE-Analyst or Binary-Scanner
```

**Pattern 2: Mandatory SEH on Memory Access**
```
Every pointer dereference in generated C++ code MUST be wrapped:
  __try { result = *(type*)address; }
  __except(EXCEPTION_EXECUTE_HANDLER) { result = fallback; }
```

**Pattern 3: Context Lifecycle Gating**
```
Before any Lua operation:
1. Read InWorld flag (0xD3F60C) — must be 1
2. Read g_luaState (0xD3F78C) — must be non-NULL
3. If EITHER fails, do NOT proceed
4. After reading both, wait 2 seconds for FrameXML setup
5. Re-verify both values haven't changed (context transition detection)
```

**Pattern 4: Fallback Chain Template**
```cpp
static void* GetThing() {
    // Method 1: Direct function call
    __try { void* p = DirectCall(); if (p) return p; }
    __except(EXCEPTION_EXECUTE_HANDLER) {}
    
    // Method 2: Alternative lookup
    __try { void* p = AlternativeLookup(); if (p) return p; }
    __except(EXCEPTION_EXECUTE_HANDLER) {}
    
    // Method 3: Manual memory walk
    __try { void* p = ManualWalk(); if (p) return p; }
    __except(EXCEPTION_EXECUTE_HANDLER) {}
    
    return nullptr; // Safe null = feature disabled, not crash
}
```

### 4.4 Detailed Agent Specifications

#### 4.4.1 Orchestrator

```yaml
# .github/agents/orchestrator.agent.md
---
description: "Use when: coordinating multi-step WoW reverse engineering tasks, managing address verification workflows, delegating between RE/addon/DLL/security specialists, researching WoW internals online, planning complex multi-phase operations. The master coordinator for WowAuto Suite."
tools: [agent, read, search, todo, web]
model: "claude-opus-4-20250514"
agents: [re-analyst, binary-scanner, addon-engineer, dll-engineer, warden-analyst, verifier, ida-bridge, crash-analyst, injection-engineer]
---
```

**Responsibilities:**
- Receive all user requests and decompose into sub-tasks
- Maintain consistency across agents (address A in RE must match address A in DLL code)
- Enforce trust chain requirements before code generation
- Track progress via todo lists
- Research WoW internals, community RE findings, and Warden updates via web
- Detect when a task spans multiple agents and coordinate handoffs
- Never write code directly — always delegate
- Maintain session context: which build we target, which addresses are verified, which are stale

**Decision Matrix:**
| User Says | Delegate To | Why |
|-----------|-------------|-----|
| "find address of X" | Binary-Scanner → Verifier | Discovery then verification |
| "update rotation engine" | DLL-Engineer | Direct code task |
| "game crashed" | Crash-Analyst | Post-mortem specialist |
| "make a new addon" | Addon-Engineer | Lua development |
| "is my DLL detectable?" | Warden-Analyst | Security audit |
| "new patch dropped" | Binary-Scanner → RE-Analyst → Verifier → DLL-Engineer | Multi-phase pipeline |
| "inject the DLL" | Injection-Engineer | Process manipulation |
| "export disasm from IDA" | IDA-Bridge | IDA automation |
| "verify all addresses" | Verifier | Bulk verification |

**Anti-patterns to avoid:**
- Writing C++ or Lua code (delegate to DLL-Engineer or Addon-Engineer)
- Calling binary analysis tools directly (delegate to Binary-Scanner)
- Skipping verification (always route through Verifier)
- Guessing which agent to use — use the decision matrix above

#### 4.4.2 RE-Analyst

```yaml
# .github/agents/re-analyst.agent.md
---
description: "Use when: analyzing disassembly, reading IDA Pro output, tracing call graphs, identifying function signatures, extracting addresses from .asm files, mapping Lua C API functions, understanding x86 instruction sequences."
tools: [read, search, execute, wow-addresses/*]
model: "claude-opus-4-20250514"
user-invocable: true
---
```

**Responsibilities:**
- Parse IDA Pro disassembly (.asm files in AscensionSDK/disasm/)
- Trace call graphs from verified anchor points
- Identify function boundaries via prologue patterns
- Extract global variable references from `MOV reg, [imm32]` patterns
- Distinguish function argument counts from stack cleanup patterns
- Produce Trust Chain evidence for every discovered address
- Resolve address label conflicts (like g_currentMapId vs g_luaState)

**Critical knowledge (from failures):**
- `mov esi, [0xD3F78C]` in FrameScript_Execute = g_luaState (NOT g_currentMapId)
- lua_pushstring (2 args, 1008 callers) vs lua_pushlstring (3 args, 15 callers) — caller count is the discriminator
- Standard Lua 5.1 prologue: `push ebp; mov ebp, esp; ...` (55 8B EC)
- Lua functions live in range 0x840000-0x860000 in Ascension.exe (build 12340)

#### 4.4.3 Binary-Scanner

```yaml
# .github/agents/binary-scanner.agent.md
---
description: "Use when: scanning raw WoW executables for patterns without IDA Pro, finding function prologues, locating global variables by byte patterns, discovering InWorld candidates, running address_scanner.py or similar Python binary tools."
tools: [read, execute, search]
model: "claude-opus-4-20250514"
user-invocable: true
---
```

**Responsibilities:**
- Run and interpret Python binary scanning tools
- Find function prologues (55 8B EC pattern) at specific offsets
- Extract CALL rel32 targets from known code regions
- Identify global variable candidates by data section cross-references
- Locate InWorld flag candidates (byte-sized writes near g_luaState)
- Generate new scanner scripts for novel analysis tasks

**Key method (from address_scanner.py breakthrough):**
1. Start from verified anchor (FrameScript_Execute @ 0x819210)
2. Read bytes at file offset, verify prologue
3. Scan forward for `CALL rel32` (E8 XX XX XX XX) instructions
4. Compute target_VA = current_VA + 5 + rel32_signed
5. For each target: verify prologue, count callers, classify

#### 4.4.4 Addon-Engineer

```yaml
# .github/agents/addon-engineer.agent.md
---
description: "Use when: creating WoW addons, writing Lua code for WoW UI, designing addon module architecture, implementing rotation engines in Lua, creating quest automation, building GUI frames, handling WoW events (ADDON_LOADED, PLAYER_LOGIN, COMBAT_LOG_EVENT)."
tools: [read, edit, search, execute]
model: "claude-opus-4-20250514"
user-invocable: true
---
```

**Responsibilities:**
- Create modular addon architectures (core + modules pattern)
- Implement WoW Lua UI code (frames, buttons, event handlers)
- Design rotation logic (priority systems, cooldown tracking)
- Integrate with C++ DLL functions (AREngine_* API)
- Handle addon lifecycle correctly (ADDON_LOADED → PLAYER_LOGIN → PLAYER_ENTERING_WORLD)
- Implement DLL detection with graceful fallbacks

**Critical knowledge (from failures):**
- NEVER assume DLL functions exist — always check with pcall: `local ok, result = pcall(AREngine_IsLoaded)`
- The addon loads in GlueXML first (login screen) — DLL functions are NOT available there
- Wait for PLAYER_ENTERING_WORLD event before using any AREngine_* functions
- All 49 DLL functions can return "NOT FOUND" if DLL isn't injected — handle gracefully
- Use `/reload` to re-initialize addon after DLL injection if needed

#### 4.4.5 DLL-Engineer

```yaml
# .github/agents/dll-engineer.agent.md
---
description: "Use when: writing C++ DLL code for WoW injection, implementing rotation_engine functions, designing lua_unlocker patches, creating DLL entry points (DllMain), managing Lua function registration via FrameScript_RegisterFunction, building with MSVC x86."
tools: [read, edit, search, execute]
model: "claude-opus-4-20250514"
user-invocable: true
---
```

**Responsibilities:**
- Write crash-proof C++ DLL code for WoW injection
- Implement FrameScript_RegisterFunction-based Lua function registration
- Design initialization threads with proper context gating
- Create fallback chains for all critical operations
- Build with MSVC x86 (32-bit, no ASLR target)
- Integrate SEH exception handling around all game memory access

**Mandatory patterns (learned from 4 crashes):**

1. **Context-Gated Initialization:**
```
Phase 1: Wait for InWorld=1 AND g_luaState!=NULL (both required)
Phase 2: Settle 3 seconds for FrameXML to finish loading
Phase 3: Double-check both values haven't changed (transition detection)
Phase 4: Register Lua functions
Phase 5: Start watchdog thread
```

2. **Watchdog Thread:**
```
Every 5 seconds:
  - Check InWorld flag
  - Check g_luaState pointer
  - If lua_State changed → wait for settle → re-register
  - If InWorld=0 → unregister, enter recovery mode
```

3. **SEH on Every Memory Access:**
```cpp
// NEVER do this:
int value = *(int*)game_address;  // Crash if wrong
// ALWAYS do this:
int value = 0;
__try { value = *(int*)game_address; }
__except(EXCEPTION_EXECUTE_HANDLER) { log("SEH caught bad read at %p", game_address); }
```

4. **Fallback Chains:**
```
For GetLocalPlayerPtr: direct call → GUID lookup → object manager walk
For GetMapId: direct read → Lua API fallback → hardcoded default
For any function: primary address → alternative address → safe null return
```

#### 4.4.6 Warden-Analyst

```yaml
# .github/agents/warden-analyst.agent.md
---
description: "Use when: analyzing Warden anti-cheat detection methods, designing evasion strategies, implementing PEB hiding, creating VEH-based protection, reviewing bytecode signatures for detectability, assessing ban risk."
tools: [read, search, warden-patterns/*]
model: "claude-opus-4-20250514"
user-invocable: true
---
```

**Responsibilities:**
- Analyze Warden scanning methods (memory reads, checksums, module enumeration)
- Design evasion strategies for each detection vector
- Assess ban risk for proposed code changes
- Review DLL code for detectable patterns
- Design module hiding (PEB unlinking, section header erasure)
- Implement VEH-based Warden redirection
- Monitor Warden signature updates

**Detection vectors to address:**
1. Module enumeration (PEB walk) — hide DLL from module list
2. Memory checksumming (read game code sections) — redirect reads to clean copies
3. Thread enumeration — hide injection threads
4. Import table scanning — avoid suspicious imports
5. String scanning — encrypt/obfuscate identifiable strings
6. Behavioral analysis — randomize timing, avoid robotic patterns

#### 4.4.7 Verifier

```yaml
# .github/agents/verifier.agent.md
---
description: "Use when: validating discovered addresses, building Trust Chains, scoring address confidence, cross-referencing multiple evidence sources, resolving address label conflicts, checking addresses before code generation."
tools: [read, search, execute, wow-addresses/*]
model: "claude-opus-4-20250514"
user-invocable: false
---
```

**Responsibilities:**
- Build Trust Chains for newly discovered addresses
- Assign confidence scores based on evidence strength
- Cross-reference addresses across disasm files, scanner output, metadata
- Detect and resolve label conflicts
- Maintain the canonical address database
- Block code generation for addresses below confidence threshold

**Verification checklist (from our failures):**
1. Is the address in the correct PE section? (.text for code, .data for globals)
2. Does the function have a valid prologue? (55 8B EC or equivalent)
3. Can we trace it back to a verified anchor? (chain of CALL instructions)
4. How many callers reference this address? (lua_pushstring: 1008 vs lua_pushlstring: 15)
5. Does the argument count match the expected signature?
6. Are there conflicting labels? (resolve with strongest evidence)
7. Has it been tested at runtime? (non-null when expected)

#### 4.4.8 IDA-Bridge

```yaml
# .github/agents/ida-bridge.agent.md
---
description: "Use when: generating IDAPython scripts, automating IDA Pro analysis, exporting disassembly from IDA, running the SDK generator (ascension_sdk_generator.py), creating function signature databases, batch-analyzing binary regions."
tools: [read, edit, execute]
model: "claude-opus-4-20250514"
user-invocable: true
---
```

**Responsibilities:**
- Generate IDAPython scripts for targeted analysis
- Export disassembly segments to .asm files
- Run ascension_sdk_generator.py with proper configuration
- Create reusable IDA analysis templates
- Generate function type signatures for IDA database
- Export cross-reference databases for offline analysis

#### 4.4.9 Crash-Analyst

```yaml
# .github/agents/crash-analyst.agent.md
---
description: "Use when: a crash dump or error log appears, the game client hung or terminated unexpectedly, diagnosing ACCESS_VIOLATION / null dereference / SEH failures, performing post-mortem analysis on ascension-live/Errors/ crash files."
tools: [read, search, execute, wow-addresses/*]
model: "claude-opus-4-20250514"
user-invocable: true
---
```

**Responsibilities:**
- Parse Windows minidump (.dmp) and crash text files from `ascension-live/Errors/`
- Extract exception code, faulting address, faulting module, and call stack
- Classify crash origin: our DLL, Lua VM, game code, or OS/ntdll cascade
- Cross-reference faulting addresses against `data/addresses/` to identify which function crashed
- Determine if crash resulted from wrong address, null pointer, context transition, or SEH missing
- Produce structured post-mortem report with root cause, affected addresses, and recommended fix
- Track crash history to detect recurring patterns

**Known Crash Patterns (from our 4 crashes):**
| Pattern | Signature | Root Cause | Fix |
|---------|-----------|-----------|-----|
| Null+Offset dereference | `reading 0x0000000C` | g_luaState was NULL, code accessed L->ci | Add null check before Lua operations |
| Wrong address read | `reading 0xXXXXXXXX` where XX is near a known global | Address was wrong by delta | Re-verify via Trust Chain |
| Context transition crash | Crash during loading screen | GlueXML VM destroyed, closures freed | Context lifecycle gating |
| SEH corruption | Exception inside exception handler | __try without /EHa, or nested SEH | Use /EHa compiler flag, avoid nested SEH |

**Post-Mortem Report Template:**
```markdown
## Crash Post-Mortem — {date}
- **Exception**: 0x{code} at 0x{address}
- **Faulting Module**: {module} (ours / game / OS)
- **Fault Type**: {null_deref | wrong_address | context_transition | seh_failure}
- **Call Stack**: {abbreviated stack}
- **Root Cause**: {explanation}
- **Affected Addresses**: {list of addresses involved}
- **Confidence Impact**: {which addresses should be re-verified}
- **Recommended Fix**: {specific code change}
- **Prevention**: {which hook/skill/pattern would have caught this}
```

#### 4.4.10 Injection-Engineer

```yaml
# .github/agents/injection-engineer.agent.md
---
description: "Use when: injecting DLLs into the WoW process, building or modifying the launcher, designing injection timing and method selection, handling privilege escalation, troubleshooting DLL load failures, managing multi-method injection fallbacks."
tools: [read, edit, search, execute]
model: "claude-opus-4-20250514"
user-invocable: true
---
```

**Responsibilities:**
- Design and implement DLL injection strategies (CreateRemoteThread, NtCreateThreadEx, manual map, thread hijack)
- Build and maintain the Ascension Launcher (AscensionLauncher.exe)
- Select optimal injection timing (process creation, after anti-cheat init, after world load)
- Handle injection failures with fallback methods
- Manage privilege escalation (SeDebugPrivilege for cross-process injection)
- Coordinate with Warden-Analyst to select least-detectable injection method
- Verify DLL loaded successfully via shared memory or named pipe feedback

**Injection Methods (from ar_injection.h):**
| Method | Detectability | Reliability | When to Use |
|--------|--------------|-------------|-------------|
| CreateRemoteThread + LoadLibrary | HIGH | HIGH | Development/testing only |
| NtCreateThreadEx | MEDIUM | HIGH | Pre-Warden init injection |
| Manual Map (PE loader) | LOW | MEDIUM | Production: maps DLL without LoadLibrary trace |
| Thread Hijack (SuspendThread + context swap) | LOW | LOW | Last resort: no new threads created |

**Injection Timing:**
```
Game Process Created
  │
  ├── PHASE 1: Pre-main (before WoW code runs)
  │   └── Manual map here for earliest hook installation
  │
  ├── PHASE 2: Post-init (after Warden loads)
  │   └── Must evade already-running Warden scans
  │
  ├── PHASE 3: Post-login (after InWorld=1)
  │   └── Safest for Lua registration (FrameXML ready)
  │   └── Used by current launcher v2.0
  │
  └── Fallback: User-triggered via /reload
      └── DLL re-registers on addon reload event
```

**Feedback Loop:**
After injection, Injection-Engineer verifies success via:
1. Check if DLL's shared memory region exists (named: `AscensionRotationEngineLoaded`)
2. Read DLL log file for initialization success message
3. If using named pipe: wait for "READY" signal with timeout
4. On failure: log method used, switch to next fallback method, retry

---

## 5. Skill Library

### 5.1 Skill Roster

Ten skills, each encoding hard-won procedural knowledge:

| # | Skill | Folder | Purpose | Invocable |
|---|-------|--------|---------|-----------|
| 1 | `ida-pro-analysis` | `.github/skills/ida-pro-analysis/` | Parse & analyze IDA Pro disassembly | Yes |
| 2 | `wow-binary-scanning` | `.github/skills/wow-binary-scanning/` | Raw binary pattern scanning without IDA | Yes |
| 3 | `lua-api-discovery` | `.github/skills/lua-api-discovery/` | Find and verify Lua C API functions | Yes |
| 4 | `warden-evasion` | `.github/skills/warden-evasion/` | Detection analysis & bypass design | No (auto) |
| 5 | `addon-engineering` | `.github/skills/addon-engineering/` | WoW addon architecture & Lua patterns | No (auto) |
| 6 | `dll-engineering` | `.github/skills/dll-engineering/` | Crash-proof C++ DLL patterns | No (auto) |
| 7 | `address-verification` | `.github/skills/address-verification/` | Trust Chain building & confidence scoring | Yes |
| 8 | `version-adaptation` | `.github/skills/version-adaptation/` | Multi-build address migration | No (auto) |
| 9 | `crash-analysis` | `.github/skills/crash-analysis/` | Crash dump parsing & root cause analysis | Yes |
| 10 | `injection-engineering` | `.github/skills/injection-engineering/` | DLL injection methods & launcher design | Yes |

### 5.2 Skill Design — Progressive Loading

Each skill follows the three-tier loading pattern:

```
Tier 1: SKILL.md (name + description) → ~100 tokens for discovery
Tier 2: SKILL.md body (procedures) → <5000 tokens when activated
Tier 3: references/ + scripts/ → loaded only when referenced
```

### 5.3 Detailed Skill Specifications

#### 5.3.1 ida-pro-analysis

**SKILL.md body outline:**

```markdown
## When to Use
- Parsing .asm disassembly files from IDA Pro
- Extracting function boundaries and call targets
- Generating IDAPython automation scripts
- Understanding x86 instruction sequences

## Procedure
1. Load target .asm file from AscensionSDK/disasm/
2. Identify function boundaries (proc/endp or prologue patterns)
3. For each function:
   a. Extract all CALL instructions → build call graph
   b. Extract all MOV/LEA with immediate addresses → find globals
   c. Identify argument count from stack frame size and parameter access
   d. Check for string references via .rdata pointers
4. Cross-reference with data/addresses/ for known labels
5. Output: function map with addresses, call targets, globals referenced

## Reference Files
- [x86-instruction-reference.md](./references/x86-instruction-reference.md)
- [ida-export-format.md](./references/ida-export-format.md)
- [generate-ida-script.py](./scripts/generate-ida-script.py)

## Critical Patterns
- Function prologue: `push ebp; mov ebp, esp` = 55 8B EC
- CALL rel32: E8 XX XX XX XX (target = PC + 5 + signed_offset)
- MOV reg, [imm32]: 8B 35 XX XX XX XX (for esi), A1 XX XX XX XX (for eax)
- JE short: 74 XX (used in taint checks — lua_unlocker patches these)
```

#### 5.3.2 wow-binary-scanning

**SKILL.md body outline:**

```markdown
## When to Use
- No IDA Pro available, need to scan raw binary
- Finding function addresses from pattern matching
- Building address_scanner.py variants for new targets
- Verifying addresses found by other methods

## The Anchor-First Method (MANDATORY)
This method was the ONLY one that worked across 11 tool iterations.

### Step 1: Establish Anchor
Pick a function whose address is publicly known or easily findable:
- FrameScript_Execute @ 0x819210 (referenced by string "Script_Execute")
- Verify: read bytes at file offset, check for 55 8B EC prologue

### Step 2: Trace Call Graph
From the anchor function:
- Scan for E8 (CALL rel32) instructions
- Compute target: current_VA + 5 + int32(next_4_bytes)
- Each target is a called function — inherits trust from caller

### Step 3: Extract Data References
From the anchor function:
- Scan for MOV patterns that load from absolute addresses
- 8B 35 XX XX XX XX = mov esi, [addr] — global variable read
- A1 XX XX XX XX = mov eax, [addr] — global variable read
- Verify addresses fall in .data section (VA range from PE headers)

### Step 4: Cross-Reference
Count how many functions reference each discovered address:
- High caller count = well-known API (lua_pushstring: 1008 callers)
- Low caller count = specialized function (lua_pushlstring: 15 callers)
- Zero callers from known functions = likely wrong identification

## CRITICAL: What To Avoid
- NEVER trust an address just because bytes exist there
- NEVER trust address labels from auto-generation without cross-ref
- NEVER build verification on top of unverified addresses (breaks circularity)

## Reference Files
- [pe-section-layout.md](./references/pe-section-layout.md)
- [scanner-template.py](./scripts/scanner-template.py)
- [ascension-exe-map.md](./references/ascension-exe-map.md)
```

#### 5.3.3 lua-api-discovery

**SKILL.md body outline:**

```markdown
## When to Use
- Mapping Lua C API functions in a WoW binary
- Distinguishing similar functions (pushstring vs pushlstring)
- Verifying lua_State global address
- Finding FrameScript_Register/Unregister addresses

## Known Lua C API Layout (Ascension Build 12340)
All verified via binary scanner + disassembly:

| Function | Address | Args | Callers | Signature Evidence |
|----------|---------|------|---------|-------------------|
| lua_gettop | 0x84DBD0 | 1 (L) | 500+ | top-base>>4 pattern |
| lua_settop | 0x84DBF0 | 2 (L, idx) | 400+ | idx>=0 branch + stack fill |
| lua_type | 0x84DEB0 | 2 (L, idx) | 300+ | checks luaO_nilobject |
| lua_tonumber | 0x84E030 | 2 (L, idx) | 200+ | checks type==3 (LUA_TNUMBER) |
| lua_tolstring | 0x84E0E0 | 3 (L, idx, len*) | 100+ | 3 args distinguish from tostring |
| lua_pushnumber | 0x84E2A0 | 2 (L, n) | 150+ | stores double + type=3 |
| lua_pushstring | 0x84E350 | 2 (L, s) | 1008 | NOT 0x84E3D0 (that's pushlstring with 3 args!) |
| lua_pushcclosure | 0x84E520 | 3 (L, fn, n) | 50+ | closure creation |
| lua_setfield | 0x84EA00 | 3 (L, idx, k) | 100+ | field assignment |
| lua_pcall | 0x84F2D0 | 4 (L, nargs, nresults, errfunc) | 200+ | protected call |
| lua_createtable | 0x84E6A0 | 3 (L, narr, nrec) | 50+ | table allocation |
| lua_rawgeti | 0x84E810 | 3 (L, idx, n) | 80+ | raw table index |
| lua_next | 0x84EE20 | 2 (L, idx) | 30+ | table iteration |

## CRITICAL DISAMBIGUATION
| Address | WRONG Label | CORRECT Label | How to Tell |
|---------|------------|---------------|-------------|
| 0x84E350 | (unlabeled) | lua_pushstring | 2 args: (L, s). 1008 callers. |
| 0x84E3D0 | lua_pushstring | **lua_pushlstring** | 3 args: (L, s, len). 15 callers only. |
| 0x84E670 | lua_pushstring | **SecurityValidation** | Completely different function! |

## Game State Globals
| Global | Address | How Found |
|--------|---------|-----------|
| g_luaState | 0xD3F78C | `mov esi,[0xD3F78C]` in FrameScript_Execute (0x819249) |
| g_InWorld | 0xD3F60C | Bool flag, 0x180 bytes before g_luaState in .data |
| FrameScript_RegisterFunction | 0x817F90 | String xref "RegisterFunction" |
| FrameScript_UnregisterFunction | 0x817FD0 | 0x40 bytes after Register |
| FrameScript_Execute | 0x819210 | String xref "Execute" + prologue verified |

## Reference Files
- [lua51-api-signatures.md](./references/lua51-api-signatures.md)
- [framescript-api.md](./references/framescript-api.md)
```

#### 5.3.4 warden-evasion

**SKILL.md body outline:**

```markdown
## When to Use (auto-loaded for DLL and security work)
- Designing DLLs that must remain undetected
- Implementing anti-detection measures
- Reviewing code for Warden-detectable patterns
- Assessing ban risk of proposed changes

## Warden Detection Methods
1. **Module Enumeration**: Walks PEB.Ldr module list to find loaded DLLs
   - Evasion: Unlink DLL from PEB.Ldr.InLoadOrderModuleList/InMemoryOrderModuleList/InInitializationOrderModuleList
   
2. **Memory Scanning**: Reads game memory pages looking for known cheat signatures
   - Evasion: Don't leave identifiable strings in .rdata; encrypt or runtime-generate
   
3. **Code Checksumming**: Hashes original .text section, compares periodically
   - Evasion: Use VEH (Vectored Exception Handler) to redirect Warden reads to clean page copies
   
4. **Thread Enumeration**: Looks for threads not created by the game
   - Evasion: Create threads from within game's own thread pool or disguise start addresses
   
5. **Import Table Analysis**: Checks for suspicious DLL imports
   - Evasion: Use GetProcAddress at runtime instead of import table entries
   
6. **Behavioral Heuristics**: Detects robotic input patterns
   - Evasion: Add human-like jitter to all timing; random delays between actions

## Code Review Checklist
Before any DLL ships:
- [ ] No hardcoded "rotation_engine" or "lua_unlocker" strings in binary
- [ ] DLL unlinked from PEB after initialization
- [ ] VEH installed for Warden read redirection
- [ ] All timing includes random jitter (±15% of base interval)
- [ ] No detectable byte patterns in first 16 bytes of DLL
- [ ] Thread start addresses point to legitimate code regions
- [ ] Import table contains only standard Windows API imports

## Reference Files
- [warden-scan-methods.md](./references/warden-scan-methods.md)
- [peb-hiding-guide.md](./references/peb-hiding-guide.md)
- [veh-redirection.md](./references/veh-redirection.md)
```

#### 5.3.5 addon-engineering

**SKILL.md body outline:**

```markdown
## When to Use (auto-loaded for Lua addon work)
- Creating new WoW addon modules
- Designing event handler architectures
- Integrating with C++ DLL functions
- Handling GlueXML vs FrameXML lifecycle correctly

## CRITICAL: GlueXML vs FrameXML Lifecycle
This was the root cause of our worst crash. The WoW client has TWO separate Lua environments:

| Phase | Lua VM | When | DLL Functions Available? |
|-------|--------|------|------------------------|
| Login Screen | GlueXML | Before "Enter World" | **NO** — registering here will CRASH on transition |
| Character Select | GlueXML | Before "Enter World" | **NO** |
| Loading Screen | Neither | Transitioning | **NO** — both VMs destroyed/recreated |
| In-Game | FrameXML | After PLAYER_ENTERING_WORLD | **YES** — safe to use DLL functions |

### The Crash Pattern
1. Addon loads in GlueXML (ADDON_LOADED fires at login screen)
2. DLL registers Lua functions in GlueXML Lua state
3. Player clicks "Enter World"
4. GlueXML Lua VM is DESTROYED
5. Registered closures now point to freed memory
6. FrameXML VM tries to invoke them → ACCESS_VIOLATION

### The Safe Pattern
```lua
-- In your addon's core:
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_ENTERING_WORLD" then
        -- NOW it's safe to check for DLL functions
        C_Timer.After(3, function()  -- Wait for DLL registration settle
            if AREngine_IsLoaded and AREngine_IsLoaded() == 1 then
                -- DLL is ready, initialize modules
                MyAddon:OnDLLReady()
            else
                print("DLL not detected — running in Lua-only mode")
                MyAddon:OnLuaOnlyMode()
            end
        end)
    end
end)
```

## Module Architecture Pattern
```
MyAddon/
├── MyAddon.toc                 (load order manifest)
├── Core.lua                    (event framework, DLL detection)
├── Modules/
│   ├── Rotation.lua            (combat automation)
│   ├── Movement.lua            (pathfinding, navigation)
│   ├── Targeting.lua           (target selection logic)
│   ├── Questing.lua            (quest automation)
│   └── GUI.lua                 (user interface)
├── Libs/                       (embedded libraries)
│   └── LibStub.lua
└── Data/
    └── SpellDB.lua             (spell definitions)
```

## DLL Integration Pattern
```lua
-- Safe DLL function wrapper
local function SafeCall(funcName, ...)
    local func = _G[funcName]
    if not func then return nil, "NOT_LOADED" end
    local ok, result = pcall(func, ...)
    if not ok then return nil, "CALL_FAILED: " .. tostring(result) end
    return result
end

-- Usage:
local enemies = SafeCall("AREngine_GetNearbyEnemies", 40)
if enemies then
    -- Use DLL result
else
    -- Fallback to Lua-only method
    enemies = FallbackGetNearbyEnemies(40)
end
```

## Reference Files
- [wow-event-lifecycle.md](./references/wow-event-lifecycle.md)
- [addon-template/](./references/addon-template/)
- [toc-format.md](./references/toc-format.md)
```

#### 5.3.6 dll-engineering

**SKILL.md body outline:**

```markdown
## When to Use (auto-loaded for C++ DLL work)
- Writing rotation_engine.dll or lua_unlocker.dll code
- Designing DLL initialization sequences
- Implementing Lua function registration
- Building MSVC x86 compilation

## MANDATORY: Context-Gated Initialization
This pattern prevents the GlueXML crash that destroyed 3 sessions:

```cpp
DWORD WINAPI InitThread(LPVOID) {
    // PHASE 1: Wait for game world (up to 10 minutes)
    for (int i = 0; i < 6000; i++) {
        BYTE inWorld = 0;
        __try { inWorld = *(volatile BYTE*)ADDR_g_InWorld; }
        __except(EXCEPTION_EXECUTE_HANDLER) {}
        
        void* luaState = nullptr;
        __try { luaState = *(void* volatile*)ADDR_g_luaState; }
        __except(EXCEPTION_EXECUTE_HANDLER) {}
        
        if (inWorld == 1 && luaState != nullptr) goto phase2;
        Sleep(100); // 100ms per check
    }
    // Timeout: enter recovery mode, don't abort
    StartWatchdog(RECOVERY_MODE);
    return 0;
    
phase2:
    // PHASE 2: Settle for FrameXML initialization (3 seconds)
    Sleep(3000);
    
    // PHASE 3: Double-check (detect context transitions)
    BYTE inWorld2 = 0;
    void* luaState2 = nullptr;
    __try { inWorld2 = *(volatile BYTE*)ADDR_g_InWorld; } __except(...) {}
    __try { luaState2 = *(void* volatile*)ADDR_g_luaState; } __except(...) {}
    
    if (inWorld2 != 1 || luaState2 == nullptr || luaState2 != luaState) {
        // Context changed during settle — retry
        goto phase1_retry;
    }
    
    // PHASE 4: Register Lua functions
    RegisterAllFunctions(luaState2);
    
    // PHASE 5: Start watchdog
    StartWatchdog(NORMAL_MODE);
    return 0;
}
```

## MANDATORY: Watchdog Thread
```cpp
DWORD WINAPI WatchdogThread(LPVOID) {
    void* lastLuaState = nullptr;
    while (!g_shutdown) {
        Sleep(5000); // Check every 5 seconds
        
        BYTE inWorld = 0;
        void* currentLuaState = nullptr;
        __try { inWorld = *(volatile BYTE*)ADDR_g_InWorld; } __except(...) {}
        __try { currentLuaState = *(void* volatile*)ADDR_g_luaState; } __except(...) {}
        
        if (inWorld != 1) {
            // Player logged out or in loading screen
            UnregisterAllFunctions();
            lastLuaState = nullptr;
            continue; // Wait for re-entry
        }
        
        if (currentLuaState != lastLuaState && currentLuaState != nullptr) {
            // Lua state changed (reload, instance transition)
            Sleep(2000); // Settle
            // Re-verify
            void* recheck = nullptr;
            __try { recheck = *(void* volatile*)ADDR_g_luaState; } __except(...) {}
            if (recheck == currentLuaState) {
                UnregisterAllFunctions();
                RegisterAllFunctions(currentLuaState);
                lastLuaState = currentLuaState;
            }
        }
    }
    return 0;
}
```

## MANDATORY: Fallback Chain Pattern
Every function that reads game memory MUST have 2+ methods:
```cpp
static void* GetLocalPlayerPtr() {
    // Method 1
    __try { ... } __except(EXCEPTION_EXECUTE_HANDLER) {}
    // Method 2
    __try { ... } __except(EXCEPTION_EXECUTE_HANDLER) {}
    // Method 3
    __try { ... } __except(EXCEPTION_EXECUTE_HANDLER) {}
    return nullptr; // NEVER crash; return null = feature disabled
}
```

## Build Configuration
```bat
cl.exe /LD /O2 /MT /EHa /Fe:rotation_engine.dll rotation_engine.cpp
rem /LD = DLL, /O2 = optimize, /MT = static CRT, /EHa = async exceptions (SEH)
rem MUST use /EHa for __try/__except to work!
```

## Reference Files
- [seh-patterns.md](./references/seh-patterns.md)
- [msvc-x86-build.md](./references/msvc-x86-build.md)
- [framescript-register-api.md](./references/framescript-register-api.md)
```

#### 5.3.7 address-verification

**SKILL.md body outline:**

```markdown
## When to Use
- Validating a newly discovered address before use
- Building a Trust Chain for the address database
- Resolving address label conflicts
- Scoring confidence for an address

## The Verification Protocol
For EVERY address before it enters data/addresses/:

### Check 1: Section Membership
- Code functions MUST be in .text section (VA: 0x401000 – 0xBE6000 for build 12340)
- Global variables MUST be in .data section (VA: 0xBE7000 – 0xE35000)
- String constants MUST be in .rdata section
- REJECT any address outside expected sections

### Check 2: Prologue Validation (functions only)
- Read first 3 bytes at the address
- Must match a known prologue pattern:
  - `55 8B EC` (push ebp; mov ebp, esp) — most common
  - `56 8B F1` (push esi; mov esi, ecx) — thiscall
  - `53 8B DC` (push ebx; mov ebx, esp) — alternate
- REJECT functions without valid prologues

### Check 3: Anchor Traceability
- Can this address be reached from a verified anchor via call graph?
- FrameScript_Execute (0x819210) is the primary anchor
- If not reachable, confidence capped at 0.5

### Check 4: Cross-Reference Count
- How many other verified functions reference this address?
- 0 references from known functions → suspicious (cap at 0.3)
- 1-5 references → moderate confidence
- 5-50 references → good confidence
- 50+ references → high confidence (well-known API)

### Check 5: Argument Count Verification
- For Lua C API: match expected arg count from Lua 5.1 spec
- lua_pushstring: 2 args (L, s) — NOT 3
- lua_pushlstring: 3 args (L, s, len) — the extra arg distinguishes it
- Mismatch → this is a DIFFERENT function (like 0x84E3D0 confusion)

### Check 6: Conflict Detection
- Search all existing entries for same address with different label
- Search all entries for same label with different address
- Any conflict must be resolved with evidence before proceeding

### Confidence Calculation
confidence = sum(
    section_check * 0.15,        // 0 or 0.15 (is address in expected PE section?)
    prologue_check * 0.15,       // 0 or 0.15 (valid function prologue?)
    anchor_trace * 0.25,         // 0 to 0.25 (reachable from verified anchor?)
    xref_score * 0.20,           // 0 to 0.20 (scaled by cross-reference count)
    arg_count_match * 0.15,      // 0 or 0.15 (signature matches expected?)
    no_conflicts * 0.10          // 0 or 0.10 (no label conflicts?)
) + runtime_bonus                // 0 or 0.15 if runtime-tested
// Maximum theoretical: 1.00 + 0.15 = 1.15, capped at 1.0
// Minimum usable for code: 0.80

## Reference Files
- [confidence-calculation.md](./references/confidence-calculation.md)
- [known-conflicts.md](./references/known-conflicts.md)
```

#### 5.3.8 version-adaptation

**SKILL.md body outline:**

```markdown
## When to Use (auto-loaded when version-related work detected)
- WoW client updated to new build
- Migrating addresses from one build to another
- Creating version-neutral code
- Building compatibility layers

## Version Detection
```cpp
// Read build number from Ascension.exe PE header or known offset
static int GetBuildNumber() {
    // Build 12340 stored at known offset in .rdata
    __try { return *(int*)ADDR_BUILD_NUMBER; }
    __except(EXCEPTION_EXECUTE_HANDLER) { return 0; }
}
```

## Address Migration Strategy
When WoW patches:
1. Binary-Scanner runs on new executable
2. Start from same anchor (FrameScript_Execute — find by string xref)
3. Trace call graph — most functions shift by consistent delta
4. If consistent delta found (e.g., all functions shifted +0x1000):
   - Apply delta to all known addresses
   - Re-verify prologues at new locations
5. If inconsistent: re-scan each function individually
6. Update data/addresses/ with new build column
7. Generate version-specific header: AscensionGlobals_BUILDNUM.h

## Conditional Compilation Pattern
```cpp
#if WOW_BUILD == 12340
    #define ADDR_g_luaState 0x00D3F78C
#elif WOW_BUILD == 12600
    #define ADDR_g_luaState 0x00D41234  // hypothetical
#else
    #error "Unsupported WoW build"
#endif
```

## Reference Files
- [build-delta-analysis.md](./references/build-delta-analysis.md)
- [version-table.json](./references/version-table.json)
```

#### 5.3.9 crash-analysis

**SKILL.md body outline:**

```markdown
## When to Use
- Parsing crash dumps from ascension-live/Errors/
- Diagnosing ACCESS_VIOLATION, null dereference, or SEH failures  
- Performing post-mortem analysis on game client crashes
- Identifying whether a crash originated in our DLL, Lua VM, game code, or OS

## Crash Log Format
Ascension crash files are in `ascension-live/Errors/` with naming:
  `YYYY-MM-DD HH.MM.SS Crash.txt` (human-readable)
  `YYYY-MM-DD HH.MM.SS Crash.dmp` (Windows minidump)

## Crash Text Parsing Procedure
1. Open the .txt file and extract:
   - Exception code (e.g., 0xC0000005 = ACCESS_VIOLATION)
   - Exception address (where the fault instruction is)
   - Fault address (what memory location was accessed)
   - Module list (identify which DLL/EXE contains the fault)
   - Call stack (if available)
   
2. Classify the crash origin:
   | Fault Address Range | Module | Classification |
   |---------------------|--------|----------------|
   | 0x400000-0xBE6FFF   | Ascension.exe (.text) | Game code crash |
   | 0xBE7000-0xE35FFF   | Ascension.exe (.data) | Data corruption |
   | 0x10000000+         | rotation_engine.dll | Our DLL crash |
   | 0x77000000+         | ntdll.dll / kernel32 | OS-level cascade |
   | 0x00000000-0x0000FFFF | N/A | Null pointer dereference |

3. Cross-reference with known patterns (see §4.4.9 for pattern table)

4. Produce structured post-mortem report

## Minidump Analysis (Advanced)
For .dmp files, use Windows debugger integration:
```python
# scripts/parse-crashdump.py
# Uses comtypes to interface with DbgEng.dll for minidump parsing
# Extracts: exception record, thread context, module list, stack trace
```

## Reference Files
- [windows-exception-codes.md](./references/windows-exception-codes.md)
- [parse-crashdump.py](./scripts/parse-crashdump.py)
- [known-crash-patterns.md](./references/known-crash-patterns.md)
```

#### 5.3.10 injection-engineering

**SKILL.md body outline:**

```markdown
## When to Use
- Injecting DLLs into the WoW process
- Building or modifying the Ascension Launcher
- Selecting injection methods based on detection risk
- Troubleshooting injection failures
- Managing privilege escalation for cross-process operations

## Injection Methods

### Method 1: Manual Mapping (Recommended for Production)
Maps DLL into target process without LoadLibrary API call:
1. Allocate memory in target process (VirtualAllocEx)
2. Copy PE sections manually (.text, .data, .rdata, .reloc)
3. Process relocations (apply delta from preferred base)
4. Resolve imports (manually walk IAT, use GetProcAddress)
5. Call DllMain via CreateRemoteThread to TLS callback region
Pros: No module list entry, no LoadLibrary trace
Cons: Complex, fragile if PE format changes

### Method 2: NtCreateThreadEx + LoadLibrary
1. Write DLL path to target process (VirtualAllocEx + WriteProcessMemory)
2. Get LoadLibraryA address from kernel32.dll
3. Create thread via NtCreateThreadEx (less hooked than CreateRemoteThread)
4. Thread calls LoadLibraryA with DLL path
Pros: Reliable, OS handles PE loading
Cons: DLL visible in module list, LoadLibrary easily hooked by anti-cheat

### Method 3: Thread Hijack
1. Enumerate threads in target process
2. SuspendThread on a game thread
3. GetThreadContext, modify EIP to point to shellcode
4. Shellcode calls LoadLibrary, then resumes original execution
5. ResumeThread
Pros: No new thread created
Cons: Race conditions, can crash if thread was in critical section

## Timing Considerations
- Pre-main: Inject via process creation with CREATE_SUSPENDED flag
- Post-load: Wait for Ascension.exe to finish initializing (window visible)
- Post-login: Wait for InWorld flag (safest for Lua registration)

## Privilege Escalation
```cpp
// Required for cross-process operations
BOOL EnableDebugPrivilege() {
    HANDLE hToken;
    OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES, &hToken);
    TOKEN_PRIVILEGES tp;
    LookupPrivilegeValue(NULL, SE_DEBUG_NAME, &tp.Privileges[0].Luid);
    tp.PrivilegeCount = 1;
    tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    AdjustTokenPrivileges(hToken, FALSE, &tp, 0, NULL, NULL);
    CloseHandle(hToken);
    return GetLastError() == ERROR_SUCCESS;
}
```

## Reference Files
- [injection-methods.md](./references/injection-methods.md)
- [injection-tester.py](./scripts/injection-tester.py)
- [manual-map-guide.md](./references/manual-map-guide.md)
```

---

## 6. MCP Servers

### 6.1 Server Roster

Three MCP servers providing structured data access to agents:

| Server | Transport | Purpose | Tools Exposed |
|--------|-----------|---------|---------------|
| `wow-addresses` | stdio (Python) | Canonical address database | lookup, search, add, verify, list-conflicts |
| `warden-patterns` | stdio (Python) | Detection signature database | check-signature, list-methods, assess-risk |
| `ida-bridge` | stdio (Python) | IDA Pro automation bridge | run-script, export-disasm, get-xrefs, get-functions |

### 6.2 wow-addresses MCP Server

**File**: `mcp-servers/wow-addresses-server.py`

**Tools:**
- `lookup(name)` → Returns address entry with full trust chain
- `search(pattern)` → Fuzzy search by name, address, or type
- `add(entry)` → Add new address (requires trust_chain with confidence ≥ 0.3)
- `verify(address)` → Run verification checks, return confidence score
- `list_conflicts()` → Show all addresses with label conflicts
- `get_by_confidence(min, max)` → Filter addresses by confidence range
- `export_header(build)` → Generate C header with #define ADDR_* macros

**Resources:**
- `addresses://all` → Full address database as JSON
- `addresses://build/{build_number}` → Build-specific subset
- `addresses://unverified` → Addresses below 0.8 confidence

**Data source**: `data/addresses/*.json` files

### 6.3 warden-patterns MCP Server

**File**: `mcp-servers/warden-patterns-server.py`

**Tools:**
- `check_signature(bytes)` → Check if byte sequence matches known Warden scan pattern
- `list_methods()` → Enumerate known Warden detection methods
- `assess_risk(dll_path)` → Scan a DLL for detectable patterns, return risk score
- `get_evasion(method)` → Get recommended evasion strategy for a detection method
- `add_pattern(pattern)` → Add newly discovered Warden scan pattern

**Resources:**
- `warden://methods` → All known detection methods
- `warden://signatures` → Current scan signature database
- `warden://evasions` → Method-to-evasion mapping

**Data source**: `data/warden-signatures/*.json` files

### 6.4 ida-bridge MCP Server

**File**: `mcp-servers/ida-bridge-server.py`

**Tools:**
- `run_script(script)` → Execute IDAPython script in IDA Pro (if running)
- `export_disasm(start, end)` → Export disassembly for address range
- `get_xrefs(address)` → Get all cross-references to/from address
- `get_functions(start, end)` → List all functions in address range
- `get_strings(filter)` → Search string table
- `analyze_function(address)` → Get detailed function analysis (args, locals, calls)

**Connection**: HTTP to IDA Pro's built-in REST API (requires IDA bridge plugin)

### 6.5 MCP Configuration

```json
// .vscode/mcp.json
{
  "servers": {
    "wow-addresses": {
      "type": "stdio",
      "command": "python",
      "args": ["${workspaceFolder}/mcp-servers/wow-addresses-server.py"],
      "env": {
        "DATA_DIR": "${workspaceFolder}/data/addresses"
      }
    },
    "warden-patterns": {
      "type": "stdio",
      "command": "python",
      "args": ["${workspaceFolder}/mcp-servers/warden-patterns-server.py"],
      "env": {
        "DATA_DIR": "${workspaceFolder}/data/warden-signatures"
      }
    },
    "ida-bridge": {
      "type": "stdio",
      "command": "python",
      "args": ["${workspaceFolder}/mcp-servers/ida-bridge-server.py"],
      "env": {
        "IDA_HOST": "localhost",
        "IDA_PORT": "9090"
      }
    }
  }
}
```

---

## 7. Hook System

### 7.1 Overview

Hooks enforce deterministic rules that agents might otherwise skip. They are the safety net that prevents the failures we experienced.

### 7.2 Hook Definitions

#### PreToolUse: Address Gate

**File**: `.github/hooks/address-gate.json`

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "type": "command",
        "command": "python ${workspaceFolder}/.github/hooks/scripts/address-gate.py",
        "timeout": 10
      }
    ]
  }
}
```

**Purpose**: Before any file edit or code generation, scan the proposed content for hex address patterns (0x00XXXXXX). For each address found, query `data/addresses/` for its confidence score. If any address has confidence < 0.8, return `"permissionDecision": "deny"` with a message explaining which address needs verification.

**What it prevents**: Using unverified addresses in code (the root cause of all our crashes).

#### PostToolUse: Build Validator

**File**: `.github/hooks/build-validator.json`

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "type": "command",
        "command": "python ${workspaceFolder}/.github/hooks/scripts/build-validator.py",
        "timeout": 30
      }
    ]
  }
}
```

**Purpose**: After any terminal command that looks like a build (cl.exe, msbuild, build.bat), scan the output for errors. If build succeeded, run a quick signature check on the output DLLs to detect Warden-detectable patterns. If detectable pattern found, warn the user.

**What it prevents**: Shipping DLLs with detectable signatures.

#### SessionStart: Context Loader

**File**: `.github/hooks/session-start.json`

```json
{
  "hooks": {
    "SessionStart": [
      {
        "type": "command",
        "command": "python ${workspaceFolder}/.github/hooks/scripts/load-context.py",
        "timeout": 5
      }
    ]
  }
}
```

**Purpose**: At the start of every agent session, inject a `systemMessage` containing:
- Current build number being targeted
- Count of verified vs unverified addresses
- Any active address conflicts
- Last known crash date and cause
- Warden signature update status

**What it prevents**: Agents starting work without awareness of current project state.

#### PreToolUse: SEH Enforcer

**File**: `.github/hooks/seh-enforcer.json`

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "type": "command",
        "command": "python ${workspaceFolder}/.github/hooks/scripts/seh-enforcer.py",
        "timeout": 10
      }
    ]
  }
}
```

**Purpose**: Before any file edit to a .cpp file, scan the proposed code for raw pointer dereferences (`*(type*)address`) that aren't wrapped in `__try/__except`. If found, return `"permissionDecision": "deny"` with a message requiring SEH wrapping.

**What it prevents**: Crashes from accessing wrong/invalid memory addresses.

#### SubagentStart: Model Enforcer

**File**: `.github/hooks/model-enforcer.json`

```json
{
  "hooks": {
    "SubagentStart": [
      {
        "type": "command",
        "command": "python ${workspaceFolder}/.github/hooks/scripts/model-enforcer.py",
        "timeout": 5
      }
    ]
  }
}
```

**Purpose**: When any subagent is invoked, verify the requested model is `claude-opus-4-20250514`. If a lesser model is requested (e.g., GPT-4o, Claude Sonnet), return `"permissionDecision": "deny"` with message: "WowAuto Suite requires Claude Opus 4.6 for all agents. Model '{requested}' is not permitted."

**What it prevents**: Degraded reasoning quality from smaller models that can't handle binary analysis or cross-referencing disassembly.

#### UserPromptSubmit: Crash Auto-Router (Optional)

**File**: `.github/hooks/crash-auto-router.json`

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "type": "command",
        "command": "python ${workspaceFolder}/.github/hooks/scripts/crash-auto-router.py",
        "timeout": 5
      }
    ]
  }
}
```

**Purpose**: When the user submits a message, scan for crash indicators (exception codes like `0xC0000005`, file paths matching `Errors/*.txt`, phrases like "game crashed" or "ACCESS_VIOLATION"). If detected, inject a `systemMessage` recommending: "Crash detected in input. Consider routing to @crash-analyst for structured post-mortem."

**What it prevents**: Users debugging crashes manually instead of using the structured post-mortem pipeline.

---

## 8. Instructions & Prompts

### 8.1 Workspace Instructions

**File**: `.github/copilot-instructions.md`

The always-on rules for every agent interaction in this workspace:

```markdown
# WowAuto Suite — Workspace Instructions

## Target Environment
- WoW 3.3.5a (Ascension private server), Build 12340
- Ascension.exe: 32-bit x86, no ASLR, PE base 0x400000, 7,694,848 bytes  
- Compiler: MSVC x86 with /EHa (async exceptions for SEH)

## Address Safety Rules
1. NEVER hardcode a game address without checking data/addresses/ first
2. EVERY address must have confidence >= 0.8 before use in production code
3. EVERY pointer dereference to game memory MUST be in __try/__except
4. EVERY critical function MUST have 2+ fallback methods
5. EVERY Lua operation MUST check InWorld AND g_luaState first

## Known Dangerous Patterns
- 0xD415F8 is NOT g_luaState (it's 0xD3F78C) — if you see 0xD415F8, it's WRONG
- 0x84E3D0 is NOT lua_pushstring (it's lua_pushlstring) — pushstring is 0x84E350
- 0xC7D0EC is NOT g_InWorld (it's 0xD3F60C) — the old address always reads 0x00
- NEVER register Lua functions before InWorld=1 (GlueXML crash)
- NEVER assume lua_State persists across loading screens

## Code Generation Rules
- All C++ code: /MT /EHa /O2 /LD for DLLs
- All Lua code: pcall() for every external function call
- All addresses: #define ADDR_* macro, never inline hex literals
- All strings: no identifiable names in release builds (Warden)

## File Locations
- Address database: data/addresses/*.json
- Warden signatures: data/warden-signatures/*.json
- Verified disasm: AscensionSDK/disasm/*.asm
- SDK headers: AscensionSDK/include/*.h
- Source code: AscensionSDK/src/*.cpp
- Python tools: AscensionSDK/sdk_tools/*.py
- Compiled output: AscensionSDK/bin/
```

### 8.2 File-Specific Instructions

#### C++ Files

**File**: `.github/instructions/cpp-safety.instructions.md`

```yaml
---
description: "Use when editing C++ source files (.cpp, .h) that interface with WoW game memory. Enforces SEH wrapping, fallback chains, and context-gated initialization patterns."
applyTo: "**/*.cpp"
---
```

#### Lua Files

**File**: `.github/instructions/lua-addon.instructions.md`

```yaml
---
description: "Use when editing WoW addon Lua files (.lua). Enforces GlueXML/FrameXML lifecycle awareness, safe DLL function calls via pcall, and proper event handling."
applyTo: "**/*.lua"
---
```

#### Python Scanner Files

**File**: `.github/instructions/binary-analysis.instructions.md`

```yaml
---
description: "Use when editing Python binary analysis scripts. Enforces anchor-first methodology, Trust Chain evidence collection, and section boundary validation."
applyTo: "AscensionSDK/sdk_tools/**/*.py"
---
```

#### Address Data Files

**File**: `.github/instructions/address-data.instructions.md`

```yaml
---
description: "Use when editing address database files. Enforces trust_chain requirement, confidence scoring, conflict detection, and build version tagging."
applyTo: "data/addresses/**"
---
```

### 8.3 Prompt Files

#### Find Address

**File**: `.github/prompts/find-address.prompt.md`

```yaml
---
description: "Find a specific function or global variable address in the WoW binary using anchor-first methodology"
agent: "orchestrator"
model: "claude-opus-4-20250514"
argument-hint: "Name of function or global to find (e.g., 'lua_pushstring', 'g_InWorld')"
---
Find the address of the specified function/global using the anchor-first methodology:
1. Start from verified anchor FrameScript_Execute @ 0x819210
2. Trace call graph to reach the target
3. Build full Trust Chain with evidence at each level
4. Assign confidence score
5. Check for conflicts with existing entries
6. Add to data/addresses/ if confidence >= 0.3
```

#### Verify All Addresses

**File**: `.github/prompts/verify-all.prompt.md`

```yaml
---
description: "Re-verify all addresses in the database, rebuilding Trust Chains and updating confidence scores"
agent: "orchestrator"
model: "claude-opus-4-20250514"
---
Run a full verification pass on all addresses in data/addresses/:
1. For each address, re-check section membership
2. Re-verify function prologues
3. Re-trace from anchor point
4. Update confidence scores
5. Report any addresses that dropped below threshold
6. Report any new conflicts detected
```

#### Build DLL

**File**: `.github/prompts/build-dll.prompt.md`

```yaml
---
description: "Build rotation_engine.dll or lua_unlocker.dll with full safety checks"
agent: "dll-engineer"
model: "claude-opus-4-20250514"
argument-hint: "Which DLL to build (rotation_engine or lua_unlocker)"
---
Build the specified DLL:
1. Verify all referenced addresses have confidence >= 0.8
2. Check all pointer dereferences have SEH wrapping
3. Verify context-gated initialization pattern is present
4. Compile with MSVC x86: cl.exe /LD /O2 /MT /EHa
5. Run Warden signature check on output
6. Report build status and any warnings
```

#### New Addon Module

**File**: `.github/prompts/new-addon-module.prompt.md`

```yaml
---
description: "Create a new WoW addon module with proper lifecycle handling and DLL integration"
agent: "addon-engineer"
model: "claude-opus-4-20250514"
argument-hint: "Module name and purpose (e.g., 'AutoQuester - automate quest completion')"
---
Create a new addon module:
1. Generate module file following the module architecture pattern
2. Implement PLAYER_ENTERING_WORLD lifecycle gate
3. Add safe DLL function wrappers with pcall
4. Implement Lua-only fallback for when DLL is unavailable
5. Add to .toc load order
6. Create slash command for enable/disable
```

#### Warden Audit

**File**: `.github/prompts/warden-audit.prompt.md`

```yaml
---
description: "Audit a DLL or code file for Warden-detectable patterns and ban risk"
agent: "warden-analyst"
model: "claude-opus-4-20250514"
argument-hint: "Path to DLL or source file to audit"
---
Perform a complete Warden detection audit:
1. Scan for identifiable strings in binary
2. Check import table for suspicious entries
3. Analyze code patterns for detection signatures
4. Check if PEB hiding is implemented
5. Verify VEH redirection is in place
6. Assess overall ban risk (Low/Medium/High/Critical)
7. Recommend specific mitigations for any findings
```

#### Patch Adaptation

**File**: `.github/prompts/patch-adaptation.prompt.md`

```yaml
---
description: "Adapt the suite to a new WoW build/patch version"
agent: "orchestrator"
model: "claude-opus-4-20250514"
argument-hint: "New build number and path to new executable"
---
Adapt to a new WoW build:
1. Binary-Scanner: Find anchor point in new binary (FrameScript_Execute via string xref)
2. RE-Analyst: Trace call graph from new anchor
3. Verifier: Compare old addresses with new, compute deltas
4. If consistent delta: apply to all addresses
5. If inconsistent: individually re-scan each critical address
6. Update data/addresses/ with new build entries
7. Regenerate SDK headers for new build
8. Rebuild DLLs with new addresses
9. Test Warden compatibility
```

#### Crash Post-Mortem

**File**: `.github/prompts/crash-postmortem.prompt.md`

```yaml
---
description: "Analyze a game crash, identify root cause, and propose fixes"
agent: "crash-analyst"
model: "claude-opus-4-20250514"
argument-hint: "Path to crash file or paste crash text directly"
---
Perform a structured crash post-mortem:
1. Parse crash log (exception code, fault address, call stack, modules)
2. Classify crash origin (our DLL / Lua VM / game code / OS cascade)
3. Cross-reference fault address against data/addresses/
4. Identify root cause (wrong address / null pointer / context transition / SEH missing)
5. Check which addresses need re-verification
6. Propose specific code fix with SEH wrapping
7. Recommend preventive measure (hook/skill/pattern)
8. Update crash history log
```

#### Inject DLL

**File**: `.github/prompts/inject-dll.prompt.md`

```yaml
---
description: "Inject a DLL into the running WoW process with optimal method selection"
agent: "injection-engineer"
model: "claude-opus-4-20250514"
argument-hint: "DLL name to inject (e.g., 'rotation_engine.dll')"
---
Inject the specified DLL:
1. Verify DLL exists in AscensionSDK/bin/ and was built recently
2. Run Warden signature check on the DLL before injection
3. Select optimal injection method (manual map > NtCreateThreadEx > CreateRemoteThread)
4. Verify WoW process is running and accessible
5. Enable SeDebugPrivilege if needed
6. Perform injection with fallback chain
7. Verify success via DiagnosticsBlock shared memory
8. Report: injection method used, DLL status, function registration count
```

#### Regenerate SDK Headers

**File**: `.github/prompts/regenerate-sdk.prompt.md`

```yaml
---
description: "Regenerate all SDK headers from the canonical address database"
agent: "orchestrator"
model: "claude-opus-4-20250514"
---
Regenerate SDK headers from data/addresses/:
1. Snapshot current headers (rollback safety)
2. Load all address entries from data/addresses/*.json
3. Filter to confidence >= 0.8 for #define macros
4. Generate AscensionGlobals.h, AscensionLuaAPI.h, AscensionHandlers.h
5. Diff old vs new headers — report all changes
6. If any ADDR_* macro changed: flag affected DLLs for rebuild
7. Run integrity tests on generated headers
8. Commit with structured message if git enabled
```

---

## 9. Data Layer

### 9.1 Address Database

**Location**: `data/addresses/`

Each file is a JSON array of address entries for a specific category:

```
data/addresses/
├── lua-c-api.json          (lua_gettop, lua_pushstring, etc.)
├── framescript.json         (FrameScript_Execute, Register, Unregister)
├── globals.json             (g_luaState, g_InWorld, g_objectManager, etc.)
├── game-functions.json      (GetLocalPlayer, Click2Move, CastSpell, etc.)
├── lua-handlers.json        (4500+ Lua handler addresses)
├── object-manager.json      (object iteration, GUID lookup, descriptors)
├── network.json             (opcodes, packet handling)
└── _conflicts.json          (all detected label/address conflicts)
```

**Entry schema:**
```json
{
  "name": "string",
  "address": "0xXXXXXXXX",
  "confidence": 0.0-1.0,
  "type": "function|global|handler|offset",
  "section": ".text|.data|.rdata",
  "size": 4,
  "build": "12340",
  "args": ["lua_State* L", "const char* s"],
  "returns": "void",
  "callers": 1008,
  "trust_chain": [
    {"level": 1, "evidence": "..."},
    {"level": 2, "evidence": "..."}
  ],
  "conflicts": [],
  "notes": "string",
  "discovered_by": "binary-scanner|ida-pro|manual",
  "discovered_date": "2026-04-05",
  "last_verified": "2026-04-05"
}
```

### 9.2 Warden Signature Database

**Location**: `data/warden-signatures/`

```
data/warden-signatures/
├── scan-methods.json        (known Warden detection methods)
├── byte-patterns.json       (detectable byte sequences)
├── string-patterns.json     (detectable string patterns)
├── evasion-strategies.json  (method → evasion mapping)
└── risk-history.json        (historical ban risk assessments)
```

### 9.3 Version Compatibility

**Location**: `data/version-compatibility/`

```
data/version-compatibility/
├── build-12340.json          (current Ascension build)
├── address-deltas.json       (version-to-version address shifts)
└── compatibility-matrix.json (feature × version support table)
```

---

## 10. Workflows

### 10.1 New Address Discovery (The Safe Way)

```
User: "Find the address of SpellCast_Start"
  │
  ▼
Orchestrator receives request
  │
  ├─→ Binary-Scanner: "Scan for SpellCast_Start via string xref or call pattern"
  │     Returns: candidate address 0x006A3210, evidence: string "SpellCast" at 0x006A3200
  │
  ├─→ Verifier: "Verify 0x006A3210 — build trust chain"
  │     Check 1: In .text section? YES ✓
  │     Check 2: Valid prologue (55 8B EC)? YES ✓  
  │     Check 3: Reachable from anchor? YES (3 hops) ✓
  │     Check 4: Cross-ref count? 47 callers ✓
  │     Check 5: Arg count? 3 (matches expected) ✓
  │     Check 6: Conflicts? NONE ✓
  │     Score: 0.85 (usable)
  │
  ├─→ wow-addresses MCP: add entry with trust chain
  │
  └─→ Report to user: "SpellCast_Start @ 0x006A3210, confidence 0.85"
```

### 10.2 DLL Update After Address Change

```
User: "g_luaState moved to 0xD40000 in new build"
  │
  ▼
Orchestrator receives request
  │
  ├─→ Verifier: "Verify 0xD40000 as g_luaState in new build"
  │     [runs full trust chain verification]
  │     Score: 0.90 ✓
  │
  ├─→ wow-addresses MCP: update g_luaState entry
  │
  ├─→ DLL-Engineer: "Update ADDR_g_luaState in rotation_engine.cpp"
  │     Updates #define, rebuilds DLL
  │     Verifies SEH wrapping still present
  │     Runs build: cl.exe /LD /O2 /MT /EHa
  │
  ├─→ Warden-Analyst: "Check new DLL for detectable patterns"
  │     Risk: LOW ✓
  │
  └─→ Report: "Updated and rebuilt. Confidence 0.90, Warden risk LOW."
```

### 10.3 Full Patch Adaptation

```
User: "New Ascension patch dropped. Adapt everything."
  │
  ▼
Orchestrator decomposes into phases:
  │
  Phase 1: Binary Analysis
  ├─→ Binary-Scanner: Find FrameScript_Execute in new binary
  ├─→ IDA-Bridge: Export new disassembly if IDA available
  ├─→ RE-Analyst: Trace full call graph from new anchor
  │
  Phase 2: Address Migration  
  ├─→ Verifier: Compare all old addresses with new discoveries
  ├─→ Verifier: Compute address deltas (consistent or per-function)
  ├─→ wow-addresses MCP: Update all entries with new build
  │
  Phase 3: Code Update
  ├─→ DLL-Engineer: Update all ADDR_* macros, rebuild DLLs
  ├─→ Addon-Engineer: Update any hardcoded references in Lua
  │
  Phase 4: Security
  ├─→ Warden-Analyst: Full audit of new DLLs
  ├─→ Warden-Analyst: Check if Warden signatures changed in new patch
  │
  Phase 5: Validation
  ├─→ All agents: Cross-check consistency
  └─→ Report: Full migration summary with confidence scores
```

### 10.4 Crash Post-Mortem

```
User: "Game crashed. Here's the crash log."
  │
  ▼
Orchestrator:
  │
  ├─→ RE-Analyst: "Parse crash log — extract exception address, fault address, call stack"
  │     Exception: 0xC0000005 at 0x77C41E1E reading 0x0000000C
  │     Stack: rotation_engine.dll → securecall → (null)
  │
  ├─→ RE-Analyst: "What function is at the crash address? Is it in our code?"
  │     0x77C41E1E = ntdll.dll (OS level — cascaded from our bug)
  │     Root: reading 0x0000000C = null pointer dereference (offset 0xC into null struct)
  │
  ├─→ Verifier: "Which of our addresses could produce a null+0xC read?"
  │     Candidate: g_luaState was null, Lua function tried to access L->ci (offset 0xC)
  │     Or: FrameXML Lua state was destroyed during context transition
  │
  ├─→ DLL-Engineer: "Add missing null check / SEH wrapper at crash site"
  │
  └─→ Report: Root cause + fix + preventive measures
```

---

## 11. Runtime Diagnostics Engine

The suite includes a real-time diagnostics layer that runs inside the injected DLL, providing continuous health monitoring and telemetry that feeds back into the agent system.

### 11.1 DLL Health Beacon

The DLL exposes a lightweight diagnostics interface via shared memory that external tools and agents can read without attaching a debugger:

```cpp
// Shared memory layout (mapped as "AscensionDiagnostics")
struct DiagnosticsBlock {
    DWORD magic;               // 0xA5CE0001 — identifies valid block
    DWORD version;             // Diagnostics protocol version
    DWORD dllBuildTimestamp;   // __TIME__ hash at compile time
    BYTE  inWorldFlag;         // Mirror of g_InWorld
    DWORD luaStatePtr;         // Mirror of g_luaState (for external verify)
    DWORD registeredFuncCount; // How many Lua functions currently registered
    DWORD failedFuncCount;     // How many registrations returned error
    DWORD sehCaughtCount;      // Total SEH exceptions caught since load
    DWORD watchdogTicks;       // Incremented by watchdog thread (liveness proof)
    DWORD lastCrashAddress;    // Address of last SEH-caught fault
    DWORD lastCrashTime;       // GetTickCount() of last SEH-caught fault
    char  statusMessage[256];  // Human-readable status string
    char  lastError[512];      // Last error detail string
};
```

### 11.2 Registration Verification

The "49/49 NOT FOUND" problem — DLL thought it registered functions but addon couldn't find them — is prevented by a registration verification loop:

```
After RegisterAllFunctions():
  For each registered function name:
    1. Call lua_getglobal(L, funcName) 
    2. Check lua_type(L, -1) != LUA_TNIL
    3. If NIL → function didn't actually register → log + re-register
    4. lua_pop(L, 1)
  Write registered count to DiagnosticsBlock
```

### 11.3 Diagnostics Lua API

The DLL exposes diagnostics to the addon layer:

| Function | Returns | Purpose |
|----------|---------|---------|
| `AREngine_GetDiagnostics()` | JSON string | Full diagnostics snapshot |
| `AREngine_GetSEHCount()` | number | Total SEH catches (0 = healthy) |
| `AREngine_GetRegisteredCount()` | number | Lua functions currently registered |
| `AREngine_GetLastError()` | string | Last error message |
| `AREngine_IsHealthy()` | 0/1 | Quick health check (all systems nominal) |

### 11.4 Agent Integration

The `session-start` hook reads the diagnostics block and injects a status summary into the agent context:

```
SessionStart → load-context.py → reads shared memory "AscensionDiagnostics"
  → Injects: "DLL Status: {healthy|degraded|not_loaded}. Registered: {N}/49 functions. SEH catches: {M}. Last error: {msg}"
```

Agents can also query diagnostics mid-session via the `wow-addresses` MCP server:
- `get_dll_status()` → reads shared memory, returns health report
- `get_registration_status()` → returns per-function registration success/failure

---

## 12. Injection Pipeline

### 12.1 End-to-End Injection Flow

The full pipeline from "user clicks Launch" to "DLL functions available in addon":

```
┌──────────────────────────────────────────────────────────────────────┐
│                        INJECTION PIPELINE                             │
│                                                                       │
│  Stage 1: LAUNCH                                                      │
│  ┌─────────────┐     ┌──────────────────┐     ┌─────────────────┐   │
│  │ User clicks  │────→│ AscensionLauncher│────→│ CreateProcess   │   │
│  │ "Play"       │     │ selects method   │     │ (SUSPENDED)     │   │
│  └─────────────┘     └──────────────────┘     └────────┬────────┘   │
│                                                          │            │
│  Stage 2: INJECT                                         ▼            │
│  ┌─────────────────────────────────────────────────────────────┐     │
│  │ Method Selection (priority order):                           │     │
│  │  1. Manual Map → lowest detection, maps PE sections manually │     │
│  │  2. NtCreateThreadEx → medium detection, reliable             │     │
│  │  3. CreateRemoteThread → high detection, most reliable        │     │
│  │  4. Thread Hijack → lowest detection, least reliable          │     │
│  │                                                               │     │
│  │ Each method has 3 retry attempts with 1s backoff              │     │
│  │ On failure: fall through to next method                       │     │
│  │ On total failure: log all errors, prompt user                 │     │
│  └───────────────────────────────┬─────────────────────────────┘     │
│                                   │                                    │
│  Stage 3: DLL INIT                ▼                                    │
│  ┌─────────────────────────────────────────────────────────────┐     │
│  │ DllMain(DLL_PROCESS_ATTACH):                                 │     │
│  │  1. Create DiagnosticsBlock shared memory                    │     │
│  │  2. Write status: "INJECTED, WAITING FOR WORLD"              │     │
│  │  3. Spawn InitThread (see §5.3.6 dll-engineering)            │     │
│  │  4. Spawn WatchdogThread                                     │     │
│  │  Return TRUE immediately (never block DllMain)               │     │
│  └───────────────────────────────┬─────────────────────────────┘     │
│                                   │                                    │
│  Stage 4: CONTEXT GATE            ▼                                    │
│  ┌─────────────────────────────────────────────────────────────┐     │
│  │ InitThread:                                                   │     │
│  │  Loop: check InWorld=1 AND g_luaState!=NULL                  │     │
│  │  ├── Both true → wait 3s settle → double-check → Phase 5    │     │
│  │  └── Timeout 10min → enter RECOVERY_MODE                     │     │
│  └───────────────────────────────┬─────────────────────────────┘     │
│                                   │                                    │
│  Stage 5: REGISTRATION            ▼                                    │
│  ┌─────────────────────────────────────────────────────────────┐     │
│  │ RegisterAllFunctions(luaState):                               │     │
│  │  For each of 49 functions:                                    │     │
│  │    FrameScript_RegisterFunction(name, callback)              │     │
│  │    Verify: lua_getglobal(L, name) != NIL                    │     │
│  │  Write registered count to DiagnosticsBlock                  │     │
│  │  Write status: "READY — {N}/49 functions registered"         │     │
│  │  Signal named event: "AscensionRotationEngineReady"          │     │
│  └───────────────────────────────┬─────────────────────────────┘     │
│                                   │                                    │
│  Stage 6: ADDON DETECTION          ▼                                    │
│  ┌─────────────────────────────────────────────────────────────┐     │
│  │ Addon (PLAYER_ENTERING_WORLD):                                │     │
│  │  C_Timer.After(3, function()                                  │     │
│  │    if AREngine_IsLoaded and AREngine_IsLoaded() == 1 then    │     │
│  │      -- DLL ready, initialize modules                         │     │
│  │    else                                                       │     │
│  │      -- Lua-only fallback mode                                │     │
│  │    end                                                        │     │
│  │  end)                                                         │     │
│  └─────────────────────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────────────────┘
```

### 12.2 Failure Modes & Recovery

| Failure | Detection | Recovery |
|---------|-----------|----------|
| Injection method blocked | CreateRemoteThread returns NULL | Fall through to next method |
| DLL fails to load (missing deps) | GetLastError() = ERROR_MOD_NOT_FOUND | Log, check /MT linkage, retry with dependency fix |
| InitThread timeout (10 min) | Watchdog enters RECOVERY_MODE | Write diagnostic, wait for user /reload |
| Registration fails (wrong lua_State) | Verify loop finds NIL globals | Unregister all, wait for state change, re-register |
| Addon can't find functions | AREngine_IsLoaded() returns nil | Check DiagnosticsBlock via external tool, prompt user |
| Warden detects injection | Account ban | Switch to manual map method, add PEB hiding |

### 12.3 Launcher ↔ DLL Communication

```
Launcher                              DLL (injected)
   │                                      │
   ├── CreateFileMapping("AscDiag")       │
   │                                      ├── OpenFileMapping("AscDiag")
   │                                      ├── Write status updates
   ├── MapViewOfFile (read-only) ────────→│
   ├── Poll every 500ms for status        │
   │                                      │
   ├── If status == "READY":              │
   │     Display "DLL Loaded" in UI       │
   ├── If status == "FAILED":             │
   │     Display error, offer retry       │
   └── If no update for 30s:             │
         Display timeout warning          │
```

---

## 13. SDK Header Auto-Regeneration

### 13.1 The Problem

When addresses change (new patch, re-verification), SDK headers (`AscensionSDK/include/*.h`) become stale. Manual updates are error-prone and we've seen conflicting addresses survive across files.

### 13.2 The Pipeline

```
data/addresses/*.json  ──(source of truth)──→  Header Generator  ──→  AscensionSDK/include/
                                                     │
                                 Uses: sdk_tools/ascension_sdk_generator.py
                                       sdk_tools/sdk_builder.py
                                                     │
                                 Outputs:
                                   ├── AscensionGlobals.h      (#define ADDR_* macros)
                                   ├── AscensionLuaAPI.h       (Lua C API function pointers)
                                   ├── AscensionDescriptors.h  (object field descriptors)
                                   ├── AscensionHandlers.h     (4500+ Lua handler addresses)
                                   └── AscensionSDK.h          (umbrella include)
```

### 13.3 Generation Rules

1. **Single Source of Truth**: Headers are GENERATED from `data/addresses/*.json` — never edited by hand
2. **Confidence Gate**: Only addresses with confidence ≥ 0.8 appear in headers; lower-confidence entries are emitted as comments
3. **Build Tagging**: Each header includes `#define WOW_BUILD 12340` guard
4. **Conflict Warnings**: If `_conflicts.json` has unresolved entries, generator emits `#warning` directives
5. **Diff Check**: Before overwriting, generator diffs old vs new headers and reports changes

### 13.4 Auto-Trigger

The `PostToolUse` hook monitors edits to `data/addresses/*.json`. When an address entry changes:
1. Run header regeneration automatically
2. Compare old vs new headers
3. If any `ADDR_*` macro changed → prompt DLL-Engineer to rebuild affected DLLs
4. Log all changes to `AscensionSDK/logs/header-regen.log`

### 13.5 Integration with Existing Tools

The existing Python generators are integrated directly:
- `sdk_tools/ascension_sdk_generator.py` — Already generates headers from IDA metadata; adapted to also read `data/addresses/`
- `sdk_tools/sdk_builder.py` — Already handles multi-file header orchestration
- `sdk_tools/run_sdk_generation.py` — Entry point; extended with `--source=address-db` flag

---

## 14. Struct & Descriptor Reverse Engineering

### 14.1 Overview

WoW's object system uses a descriptor table — a flat array of typed fields at known offsets from an object's base pointer. Ascension's custom content adds hundreds of non-standard descriptor fields. This section details how the suite discovers, catalogs, and uses them.

### 14.2 Existing Asset: AscensionDescriptors.h

We already have `AscensionSDK/include/AscensionDescriptors.h` with 4500+ field definitions:

```cpp
// Example from existing header:
#define OBJECT_FIELD_GUID                    0x0000  // ObjectGuid
#define OBJECT_FIELD_TYPE                    0x0002  // uint32
#define OBJECT_FIELD_ENTRY                   0x0003  // uint32
#define OBJECT_FIELD_SCALE_X                 0x0004  // float
#define UNIT_FIELD_HEALTH                    0x0006  // uint32
#define UNIT_FIELD_MAXHEALTH                 0x0007  // uint32
#define UNIT_FIELD_LEVEL                     0x0024  // uint32
#define PLAYER_FIELD_VISIBLE_ITEM            0x0030  // uint32[38]
// ... 4500+ more
```

### 14.3 Descriptor Discovery Workflow

For unknown or Ascension-custom descriptors:

```
1. Binary-Scanner: Scan for descriptor table initialization code
   - Pattern: sequential writes to base+offset with incrementing offsets
   - Pattern: switch/case on descriptor index
   
2. RE-Analyst: Map descriptor index → field name → type
   - Use string references near the initialization code
   - Cross-reference with known WoW 3.3.5a descriptor layout
   - Flag Ascension-custom fields (not in standard 3.3.5a)
   
3. Verifier: Validate descriptor offsets
   - Read object at runtime
   - Check that UNIT_FIELD_HEALTH reads a plausible HP value
   - Check that UNIT_FIELD_LEVEL reads 1-80
   - Check that OBJECT_FIELD_GUID reads a non-zero 64-bit value
   
4. SDK Auto-Regen: Update AscensionDescriptors.h with new findings
```

### 14.4 Object Type Enumeration

From existing `AscensionTypes.h`:

| Type ID | Type | Descriptor Prefix | Base Offset |
|---------|------|-------------------|-------------|
| 0 | Object | OBJECT_FIELD_* | 0x0000 |
| 1 | Item | ITEM_FIELD_* | 0x0006 |
| 2 | Container | CONTAINER_FIELD_* | varies |
| 3 | Unit (NPC) | UNIT_FIELD_* | 0x0006 |
| 4 | Player | PLAYER_FIELD_* | varies |
| 5 | GameObject | GAMEOBJECT_FIELD_* | varies |
| 6 | DynamicObject | DYNAMICOBJECT_FIELD_* | varies |
| 7 | Corpse | CORPSE_FIELD_* | varies |

### 14.5 Struct Layout Discovery

Beyond descriptors, the suite can discover C++ struct layouts used internally:

```
Method 1: IDA Struct Recovery
  - IDA-Bridge exports struct definitions from IDA database
  - RE-Analyst maps field offsets to names
  
Method 2: Access Pattern Analysis
  - Binary-Scanner finds `mov eax, [ecx+0xNN]` patterns
  - Groups accesses by base register to form implicit structs
  - Cross-references with string labels for field naming
  
Method 3: RTTI Recovery (if available)
  - Scan .rdata for RTTI type descriptors
  - Recover class hierarchy from vftable chains
  - Map each class to its field layout
```

---

## 15. Network Layer & Opcode Analysis

### 15.1 Overview

The WoW client communicates with the server via a custom protocol using numbered opcodes. Ascension adds custom opcodes for its unique features (classless system, random enchantments, mystic enchantments). Understanding opcodes enables packet-level automation and deeper game state awareness.

### 15.2 Existing Assets

We already have extensive opcode data:
- `AscensionSDK/include/AscensionOpcodes.h` — Standard 3.3.5a opcodes
- `AscensionSDK/include/AscensionOpcodesFull.h` — Extended opcode list including Ascension-custom

```cpp
// From AscensionOpcodesFull.h (examples):
#define CMSG_PLAYER_LOGIN            0x003D
#define SMSG_UPDATE_OBJECT           0x00A9
#define CMSG_CAST_SPELL              0x012E
#define SMSG_SPELL_GO                0x0132
#define CMSG_MESSAGECHAT             0x0095
// Ascension custom:
#define CMSG_ASCENSION_RANDOM_ENCHANT 0x8001  // hypothetical
```

### 15.3 Opcode Discovery Workflow

```
1. IDA-Bridge: Export send/recv handler tables from binary
   - Pattern: large switch/case or function pointer array indexed by opcode
   - Each case/entry = one opcode handler

2. RE-Analyst: For each handler:
   - Extract opcode number
   - Identify direction (CMSG = client→server, SMSG = server→client)
   - Parse packet structure from the handler's field reads
   - Name based on string references or behavior analysis

3. Verifier: Cross-reference with known 3.3.5a opcode catalog
   - Known opcodes should match expected numbers
   - Unknown opcodes → likely Ascension-custom

4. Data Layer: Store in data/addresses/network.json
```

### 15.4 Packet Structure Analysis

For automation-relevant packets:

```json
{
  "opcode": "0x012E",
  "name": "CMSG_CAST_SPELL",
  "direction": "client_to_server",
  "fields": [
    {"offset": 0, "name": "castCount", "type": "uint8"},
    {"offset": 1, "name": "spellId", "type": "uint32"},
    {"offset": 5, "name": "castFlags", "type": "uint8"},
    {"offset": 6, "name": "targetGUID", "type": "uint64"}
  ],
  "handler_address": "0x006A3210",
  "confidence": 0.85
}
```

### 15.5 Applications

| Use Case | How Opcodes Help |
|----------|-----------------|
| Spell casting verification | Confirm CMSG_CAST_SPELL was sent, wait for SMSG_SPELL_GO response |
| Movement automation | Send CMSG_MOVE_* packets instead of calling Click2Move |
| Chat automation | Parse SMSG_MESSAGECHAT for trigger patterns |
| Inventory management | Track SMSG_ITEM_PUSH_RESULT for loot events |
| Ascension-specific | Handle custom opcode responses for classless features |

---

## 16. Automated Testing Framework

### 16.1 Overview

Every component of the suite is testable without connecting to a live game server. This prevents the "build → inject → crash → debug → repeat" cycle that consumed 40+ hours.

### 16.2 Test Layers

```
Layer 1: UNIT TESTS (offline, no game required)
  ├── Address database integrity tests
  ├── Trust Chain validation tests
  ├── Header generation regression tests
  ├── Scanner output parsing tests
  └── Hook script tests (mock stdin/stdout)

Layer 2: BINARY ANALYSIS TESTS (offline, needs Ascension.exe on disk)
  ├── Anchor point verification (FrameScript_Execute still at 0x819210?)
  ├── Prologue pattern tests (read bytes, verify 55 8B EC)
  ├── Section boundary tests (address in expected section?)
  └── Cross-reference count regression (lua_pushstring still has 1000+ callers?)

Layer 3: INTEGRATION TESTS (needs game running, careful)
  ├── DiagnosticsBlock shared memory read test
  ├── DLL injection success test (check for shared memory marker)
  ├── Lua function registration test (addon-side pcall check)
  └── Context transition test (log out → log in → verify re-registration)

Layer 4: WARDEN REGRESSION TESTS (offline)
  ├── DLL signature scan (known-bad byte patterns)
  ├── Import table analysis (no suspicious imports)
  ├── String scan (no identifiable names in .rdata)
  └── PEB visibility check (simulated module enumeration)
```

### 16.3 Test Runner

```python
# sdk_tools/run_tests.py
# Invoked by: python sdk_tools/run_tests.py [--layer=1|2|3|4] [--verbose]

class TestRunner:
    def test_address_db_integrity(self):
        """Every entry in data/addresses/ has required fields, valid confidence, and non-empty trust_chain."""
        
    def test_no_conflicts_unresolved(self):
        """_conflicts.json has zero entries with resolution='UNRESOLVED'."""
        
    def test_header_matches_db(self):
        """Every #define ADDR_* in generated headers matches data/addresses/."""
        
    def test_anchor_still_valid(self):
        """FrameScript_Execute at 0x819210 still has 55 8B EC prologue."""
        
    def test_all_confidence_above_threshold(self):
        """No address used in src/*.cpp has confidence < 0.8."""
        
    def test_seh_coverage(self):
        """Every *(type*)ADDR_ dereference in src/*.cpp is inside __try/__except."""
        
    def test_no_warden_signatures(self):
        """bin/*.dll contains no patterns from data/warden-signatures/byte-patterns.json."""
```

### 16.4 CI-like Integration

The `PostToolUse` hook (build-validator) runs the relevant test layer after builds:
- After editing `data/addresses/` → Layer 1 (integrity)
- After editing `AscensionSDK/src/*.cpp` → Layer 1 + syntax check
- After `cl.exe` build → Layer 1 + Layer 4 (Warden)
- Before injection → Layer 2 (verify anchor still valid)

---

## 17. Rollback & Recovery System

### 17.1 Overview

When something breaks (wrong address, bad DLL, detection event), the suite can roll back to a known-good state rather than debugging forward in the dark.

### 17.2 Snapshot Points

The suite takes snapshots at critical moments:

| Trigger | What's Snapshot | Storage |
|---------|----------------|---------|
| Address DB change | `data/addresses/*.json` | `data/addresses/.snapshots/{timestamp}/` |
| DLL build success | `AscensionSDK/bin/*.dll` + source | `AscensionSDK/bin/.snapshots/{timestamp}/` |
| Header regeneration | `AscensionSDK/include/*.h` | `AscensionSDK/include/.snapshots/{timestamp}/` |
| Pre-injection | Full DLL + address DB | `data/.pre-inject-snapshot/` |
| Warden signature update | `data/warden-signatures/` | `data/warden-signatures/.snapshots/{timestamp}/` |

### 17.3 Rollback Commands

```powershell
# Rollback address database to last known-good state
python sdk_tools/rollback.py --target=addresses --to=last-good

# Rollback DLL to specific snapshot
python sdk_tools/rollback.py --target=dll --to=2026-04-05T14:30:00

# Rollback everything to pre-injection state
python sdk_tools/rollback.py --target=all --to=pre-inject

# List available snapshots
python sdk_tools/rollback.py --list
```

### 17.4 Automatic Recovery Triggers

| Event | Automatic Action |
|-------|-----------------|
| DLL crashes 3 times in 10 minutes | Rollback DLL to last stable snapshot, notify user |
| Address confidence drops below 0.5 | Quarantine address (remove from headers), trigger re-verification |
| Warden detection event | Rollback to pre-detection DLL, switch injection method, full Warden audit |
| Build fails after address update | Rollback address change, report conflict |

### 17.5 Git Integration

For users who have the workspace under git:
- Each snapshot is also a git stash or tagged commit
- `rollback.py --git` uses `git checkout` for file recovery
- Address DB changes are committed with structured messages: `[addresses] Update g_luaState confidence 0.85→0.95`
- DLL builds are tagged: `dll/rotation-engine/v6.2-build12340`

---

## 18. Existing Asset Integration

### 18.1 Overview

The workspace already contains a rich set of reverse engineering artifacts from our 10+ session effort. The suite doesn't discard this work — it integrates and leverages every useful piece.

### 18.2 Asset Inventory & Integration Plan

#### PE Analysis (42 JSON files in `AscensionSDK/pe_analysis/`)

```
What exists:
  - Detailed PE section headers, import/export tables, and section characteristics
  - Analyzed across 6 different binaries (Ascension.exe, Battle.net.dll, etc.)
  - File size, entry point, section VA ranges, checksum data

Integration:
  - wow-binary-scanning skill reads PE section layout from pe_analysis/*.json
  - address-verification skill uses section VA ranges for boundary checking
  - Warden-Analyst uses import table data to understand normal vs suspicious imports
  - Section layout fed into wow-addresses MCP server for automated section validation
```

#### IDA Disassembly (13 .asm files in `AscensionSDK/disasm/`)

```
Files:
  - Ascension_lua.asm (Lua C API functions)
  - Ascension_player.asm (player-related functions)
  - Ascension_spell.asm (spell casting system)
  - Ascension_movement.asm (Click2Move, pathfinding)
  - Ascension_object_manager.asm (object iteration, GUID lookup)
  - Ascension_framescript.asm (FrameScript_Execute, Register, etc.)
  - Ascension_misc.asm, Ascension_event.asm, Ascension_security.asm
  - Ascension_net.asm (networking), Ascension_ui.asm, Ascension_combat.asm
  - Ascension_ascension_custom.asm (Ascension-specific features)

Integration:
  - RE-Analyst reads these as primary analysis input
  - ida-pro-analysis skill references them for cross-reference data
  - Binary-Scanner verifies addresses against disassembly
  - IDA-Bridge can regenerate/update these from current IDA database
```

#### Lua Handler Map (4500+ handlers in `AscensionSDK/metadata/lua_handler_map.json`)

```
What exists:
  - Mapping of Lua function name → handler address for 4500+ game functions
  - Includes both standard WoW and Ascension-custom Lua API
  - Example: {"CastSpellByName": "0x006B3A10", "GetSpellCooldown": "0x006B41C0"}

Integration:
  - Seeded into data/addresses/lua-handlers.json (with initial confidence 0.3 — needs verification)
  - addon-engineering skill uses for "what Lua functions are available" queries
  - RE-Analyst uses handler addresses as starting points for reverse engineering
  - Verifier can bulk-verify handler addresses via prologue checks
```

#### SDK Metadata (`AscensionSDK/metadata/sdk_metadata.json`)

```
What exists:
  - Auto-generated metadata from IDA analysis
  - Contains function addresses, types, labels (WARNING: some labels are WRONG — see §2.1)
  - Also contains string references, section info, version data

Integration:
  - Imported as UNVERIFIED data (confidence 0.1) into data/addresses/
  - Every entry from sdk_metadata.json must pass Trust Chain before use
  - Known-wrong entries are pre-populated in _conflicts.json
  - Serves as discovery starting points, NOT as ground truth
```

#### Python Tools (23 scripts in `sdk_tools/`)

```
Key tools:
  - address_scanner.py — THE breakthrough scanner that found correct addresses
  - ascension_sdk_generator.py — Generates SDK headers from IDA metadata
  - sdk_builder.py — Orchestrates multi-header generation
  - pe_analyzer.py — Analyzes PE files and exports JSON summaries
  - verify_addresses[1-5].py — 5 iterations (mostly failed, but contain useful patterns)
  - disasm_taint[1-6].py — 6 iterations (failed, but demonstrate what NOT to do)
  - verify_lua_api.py — Lua API function verification

Integration:
  - address_scanner.py is the primary tool for binary-scanner agent
  - ascension_sdk_generator.py + sdk_builder.py extended for §13 auto-generation
  - pe_analyzer.py feeds PE analysis data to multiple skills
  - Failed tools (verify_addresses*, disasm_taint*) preserved as anti-pattern examples
  - Skills reference failed tools in "What NOT to do" sections
```

#### Compiled Binaries (`AscensionSDK/bin/`)

```
What exists:
  - rotation_engine.dll (160KB) — v6.1, context-gated, 49 Lua functions
  - lua_unlocker.dll (131KB) — v7, byte-patch based, Warden-resistant
  - AscensionLauncher.exe (433KB) — v2.0, 4-method injection, privilege escalation

Integration:
  - These are the CURRENT production binaries
  - Warden-Analyst audits these for detection risk
  - Injection-Engineer uses AscensionLauncher.exe as the injection vehicle
  - DLL-Engineer rebuilds rotation_engine.dll and lua_unlocker.dll when addresses change
  - Snapshots of these binaries are the rollback targets (§17)
```

### 18.3 Data Migration Checklist

When bootstrapping the suite for first time, existing assets are migrated:

```
[ ] Import lua_handler_map.json → data/addresses/lua-handlers.json (confidence 0.3)
[ ] Import sdk_metadata.json globals → data/addresses/globals.json (confidence 0.1, flagged)
[ ] Import known-good addresses from address_scanner.py → data/addresses/ (confidence 0.85+)
[ ] Copy PE section data from pe_analysis/ → referenced by skills
[ ] Register known conflicts in _conflicts.json (g_currentMapId vs g_luaState, etc.)
[ ] Catalog all disasm files in IDA-Bridge agent's reference index
[ ] Tag current binaries as v6.1/v7/v2.0 snapshots in rollback system
[ ] Index all 4500+ handler addresses for bulk verification queue
```

---

## 19. Directory Map

```
c:\Ascension\Launcher\resources\
│
├── .github/
│   ├── copilot-instructions.md              ← Workspace-wide rules (always loaded)
│   ├── ARCHITECTURE.md                      ← This design document
│   │
│   ├── agents/
│   │   ├── orchestrator.agent.md            ← Master coordinator (web, agent, todo)
│   │   ├── re-analyst.agent.md              ← Reverse engineering & disasm
│   │   ├── binary-scanner.agent.md          ← Raw binary pattern scanning
│   │   ├── addon-engineer.agent.md          ← WoW addon Lua development
│   │   ├── dll-engineer.agent.md            ← C++ DLL development
│   │   ├── warden-analyst.agent.md          ← Detection evasion & security
│   │   ├── verifier.agent.md                ← Address Trust Chain verification
│   │   ├── ida-bridge.agent.md              ← IDA Pro automation
│   │   ├── crash-analyst.agent.md           ← Crash post-mortem & root cause
│   │   └── injection-engineer.agent.md      ← DLL injection & launcher
│   │
│   ├── skills/
│   │   ├── ida-pro-analysis/
│   │   │   ├── SKILL.md
│   │   │   ├── scripts/generate-ida-script.py
│   │   │   └── references/x86-instruction-reference.md
│   │   ├── wow-binary-scanning/
│   │   │   ├── SKILL.md
│   │   │   ├── scripts/scanner-template.py
│   │   │   └── references/pe-section-layout.md
│   │   ├── lua-api-discovery/
│   │   │   ├── SKILL.md
│   │   │   └── references/lua51-api-signatures.md
│   │   ├── warden-evasion/
│   │   │   ├── SKILL.md
│   │   │   ├── scripts/signature-scanner.py
│   │   │   └── references/warden-scan-methods.md
│   │   ├── addon-engineering/
│   │   │   ├── SKILL.md
│   │   │   ├── references/wow-event-lifecycle.md
│   │   │   └── references/addon-template/
│   │   ├── dll-engineering/
│   │   │   ├── SKILL.md
│   │   │   ├── references/seh-patterns.md
│   │   │   └── references/framescript-register-api.md
│   │   ├── address-verification/
│   │   │   ├── SKILL.md
│   │   │   └── scripts/verify-address.py
│   │   ├── version-adaptation/
│   │   │   ├── SKILL.md
│   │   │   └── references/build-delta-analysis.md
│   │   ├── crash-analysis/
│   │   │   ├── SKILL.md
│   │   │   ├── scripts/parse-crashdump.py
│   │   │   └── references/windows-exception-codes.md
│   │   └── injection-engineering/
│   │       ├── SKILL.md
│   │       ├── scripts/injection-tester.py
│   │       └── references/injection-methods.md
│   │
│   ├── instructions/
│   │   ├── cpp-safety.instructions.md       ← Auto-applied to *.cpp
│   │   ├── lua-addon.instructions.md        ← Auto-applied to *.lua
│   │   ├── binary-analysis.instructions.md  ← Auto-applied to sdk_tools/*.py
│   │   └── address-data.instructions.md     ← Auto-applied to data/addresses/**
│   │
│   ├── prompts/
│   │   ├── find-address.prompt.md           ← /find-address in chat
│   │   ├── verify-all.prompt.md             ← /verify-all in chat
│   │   ├── build-dll.prompt.md              ← /build-dll in chat
│   │   ├── new-addon-module.prompt.md       ← /new-addon-module in chat
│   │   ├── warden-audit.prompt.md           ← /warden-audit in chat
│   │   ├── patch-adaptation.prompt.md       ← /patch-adaptation in chat
│   │   ├── crash-postmortem.prompt.md       ← /crash-postmortem in chat
│   │   ├── inject-dll.prompt.md             ← /inject-dll in chat
│   │   └── regenerate-sdk.prompt.md         ← /regenerate-sdk in chat
│   │
│   └── hooks/
│       ├── address-gate.json                ← Block unverified addresses
│       ├── build-validator.json             ← Post-build Warden + test check
│       ├── session-start.json               ← Inject project context + DLL status
│       ├── seh-enforcer.json                ← Require SEH in C++ edits
│       ├── model-enforcer.json              ← Require Claude Opus 4.6 for subagents
│       └── scripts/
│           ├── address-gate.py
│           ├── build-validator.py
│           ├── load-context.py
│           ├── seh-enforcer.py
│           └── model-enforcer.py
│
├── .vscode/
│   └── mcp.json                             ← MCP server configuration
│
├── mcp-servers/
│   ├── wow-addresses-server.py              ← Address database MCP
│   ├── warden-patterns-server.py            ← Warden signatures MCP
│   └── ida-bridge-server.py                 ← IDA Pro bridge MCP
│
├── data/
│   ├── addresses/
│   │   ├── lua-c-api.json
│   │   ├── framescript.json
│   │   ├── globals.json
│   │   ├── game-functions.json
│   │   ├── lua-handlers.json               ← 4500+ handlers from migration
│   │   ├── object-manager.json
│   │   ├── network.json                     ← Opcodes and packet handlers
│   │   ├── _conflicts.json
│   │   └── .snapshots/                      ← Rollback snapshots
│   ├── warden-signatures/
│   │   ├── scan-methods.json
│   │   ├── byte-patterns.json
│   │   ├── string-patterns.json
│   │   ├── evasion-strategies.json
│   │   └── .snapshots/
│   └── version-compatibility/
│       ├── build-12340.json
│       ├── address-deltas.json
│       └── compatibility-matrix.json
│
├── sdk_tools/
│   ├── address_scanner.py                   ← The breakthrough scanner
│   ├── ascension_sdk_generator.py           ← Header generation from IDA
│   ├── sdk_builder.py                       ← Multi-header orchestration
│   ├── pe_analyzer.py                       ← PE file analysis
│   ├── run_tests.py                         ← Test runner (§16)
│   ├── rollback.py                          ← Rollback/recovery (§17)
│   ├── seed_addresses.py                    ← Bootstrap address DB
│   ├── verify_addresses[1-5].py             ← Legacy (anti-pattern examples)
│   └── disasm_taint[1-6].py                 ← Legacy (anti-pattern examples)
│
├── AscensionSDK/                            ← Existing SDK
│   ├── bin/
│   │   ├── rotation_engine.dll              ← v6.1, 160KB
│   │   ├── lua_unlocker.dll                 ← v7, 131KB
│   │   ├── AscensionLauncher.exe            ← v2.0, 433KB
│   │   └── .snapshots/                      ← DLL rollback snapshots
│   ├── disasm/                              ← 13 IDA .asm files
│   ├── include/                             ← 18 auto-generated headers
│   │   └── .snapshots/                      ← Header rollback snapshots
│   ├── metadata/                            ← sdk_metadata, lua_handler_map
│   ├── pe_analysis/                         ← 42 PE analysis JSONs
│   ├── src/                                 ← 8 C++ source files
│   └── logs/                                ← Generation & regen logs
│
└── ascension-live/                          ← Game client directory
    ├── Interface/AddOns/                    ← Addon deployment target
    ├── Errors/                              ← Crash dumps (Crash-Analyst reads)
    └── WTF/                                 ← Config files
```

---

## 20. Setup & Bootstrap

### 20.1 Prerequisites

- VS Code with GitHub Copilot extension (Copilot Chat enabled)
- Claude Opus 4.6 model access (`claude-opus-4-20250514`)
- Python 3.10+ with venv
- MSVC Build Tools (x86 target, with `/EHa` support)
- IDA Pro 7.x+ (optional — for IDA-Bridge agent)
- Git (optional — for rollback git integration)

### 20.2 First-Time Setup

```powershell
# 1. Activate Python environment
cd c:\Ascension\Launcher\resources
.\.venv\Scripts\Activate.ps1

# 2. Install MCP server dependencies
pip install mcp jsonschema pefile capstone

# 3. Seed the address database with known-good addresses
python sdk_tools/seed_addresses.py

# 4. Run integrity tests on seeded data
python sdk_tools/run_tests.py --layer=1

# 5. Create initial rollback snapshot
python sdk_tools/rollback.py --snapshot=initial

# 6. Open in VS Code
code .

# 7. VS Code auto-discovers:
#    - .github/agents/*.agent.md    → @orchestrator, @re-analyst, etc. in chat
#    - .github/skills/*/SKILL.md    → auto-loaded by matching agents
#    - .github/prompts/*.prompt.md  → /find-address, /build-dll, etc. in chat
#    - .github/hooks/*.json         → active lifecycle hooks
#    - .vscode/mcp.json             → MCP servers started
#    - .github/copilot-instructions.md → always-on workspace rules
```

### 20.3 Verification

After setup, test each component:

```
# Test agents (in Copilot Chat):
@orchestrator What is the current state of the address database?
@re-analyst What functions are in AscensionSDK/disasm/Ascension_lua.asm?
@verifier Verify g_luaState at 0xD3F78C
@crash-analyst Analyze the latest crash in ascension-live/Errors/
@injection-engineer What injection methods are available?

# Test prompts (in Copilot Chat):
/find-address lua_pushstring
/verify-all
/warden-audit AscensionSDK/bin/rotation_engine.dll
/crash-postmortem
/inject-dll rotation_engine.dll
/regenerate-sdk

# Test hooks (automatic):
# → Edit a .cpp file with raw pointer dereference → seh-enforcer blocks it
# → Use address 0xDEADBEEF in code → address-gate blocks it
# → Build a DLL → build-validator runs Warden check + tests
# → Start a session → session-start injects project context + DLL health

# Test rollback:
python sdk_tools/rollback.py --list
python sdk_tools/rollback.py --target=addresses --to=initial --dry-run
```

### 20.4 Daily Workflow

```
1. Start VS Code → session-start hook loads context
2. @orchestrator "What needs attention today?"
   → Reports: unverified addresses, stale confidence scores, pending crashes
3. Work with specialist agents as needed
4. All edits pass through hooks (address-gate, seh-enforcer)
5. Builds pass through post-build validator
6. Snapshots taken automatically at key moments
7. If something breaks → rollback.py to known-good state
```

---

## Appendix A: Complete Failure → Prevention Matrix

| Past Failure | Root Cause | Prevention Mechanism | Layer |
|-------------|-----------|---------------------|-------|
| g_luaState wrong (0xD415F8) | Auto-gen without verification | Trust Chain + confidence gate | Verifier agent + address-gate hook |
| g_InWorld wrong (0xC7D0EC) | Auto-gen without verification | Trust Chain + confidence gate | Verifier agent + address-gate hook |
| lua_pushstring/pushlstring confusion | Same-name different function | Caller count + arg count verification | address-verification skill |
| g_currentMapId mislabel | Cross-tool label conflict | Conflict detection in address DB | wow-addresses MCP + _conflicts.json |
| GlueXML crash on Enter World | Context unawareness | Mandatory lifecycle gating | dll-engineering skill + addon-engineering skill |
| Null pointer at offset 0xC | Missing null check | SEH enforcement hook | seh-enforcer hook |
| 11 tools × 6 iterations = 0 results | Circular verification | Anchor-first methodology | wow-binary-scanning skill |
| securecall ACCESS_VIOLATION | Called Lua with bad state | Context-gated init + watchdog | dll-engineering skill |
| Object manager crash | Wrong offsets | Fallback chain pattern | dll-engineering skill |
| DLL not detected (49/49 NOT FOUND) | Wrong initialization timing | GlueXML/FrameXML awareness | addon-engineering + dll-engineering skills |
| Exception handler crashed | SEH corruption | VEH over SEH, clean handling | warden-evasion skill |
| Build errors across sessions | No consistent build config | Standardized build commands | copilot-instructions.md |
| No crash root cause analysis | Manual debugging, guessing | Crash-Analyst agent + post-mortem pipeline | crash-analysis skill + §4.2.1 flow |
| Headers out of sync with address DB | Manual header editing | Auto-regeneration pipeline | §13 SDK Header Auto-Regen |
| No rollback after bad change | Forward-only debugging | Snapshot + rollback system | §17 Rollback & Recovery |
| Lost context between sessions | No persistent state | session-start hook + DiagnosticsBlock | §11 Runtime Diagnostics |
| Existing 4500+ handlers unused | No integration pipeline | Bulk import with confidence 0.3 | §18 Existing Asset Integration |
| Subagent used wrong model | No model enforcement | model-enforcer hook | SubagentStart hook |
| Injection method detected by Warden | Single injection method | Multi-method fallback chain | injection-engineering skill |

---

## Appendix B: The Address That Broke Everything

The single most impactful bug in this project's history:

```
Address: 0xD3F78C
Auto-generated label: g_currentMapId    ← WRONG
Actual identity: g_luaState             ← CORRECT

This ONE mislabel caused:
- g_luaState set to 0xD415F8 (wrong address, 0x986C bytes too high)
- Every Lua API call used corrupted lua_State pointer
- securecall crashed with ACCESS_VIOLATION
- 4 separate crash dumps generated
- 10+ debugging sessions spent on wrong leads
- 5 iterations of verify_addresses.py (all inconclusive)
- 6 iterations of disasm_taint.py (all inaccurate)

How it was finally discovered:
- address_scanner.py traced FrameScript_Execute disassembly
- Found `mov esi, [0xD3F78C]` — this loads the Lua state
- Cross-referenced: 0xD3F78C is in .data section ✓
- Verified: 47 other functions use this same address ✓
- Conclusion: 0xD3F78C = g_luaState, NOT g_currentMapId

Time to discovery: ~40 hours across 10+ sessions
Time to discover with WowAuto Suite: ~2 minutes via /find-address g_luaState
```

This appendix exists as a permanent reminder of why the Trust Chain Architecture is non-negotiable.
