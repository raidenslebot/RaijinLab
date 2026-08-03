#include "NativeHook.h"
#include "Lde.h"
#include "Mem.h"
#include "Guard.h"
#include "Actions.h"
#include "ObjectManager.h"
#include "AddressDB.h"
#include "core/Log.h"
#include "core/Config.h"
#include <Windows.h>
#include <cstring>
#include <cstdint>
#include <string>

// ===========================================================================
// NativeHook implementation — minimal x86 detour engine (see header).
// ===========================================================================
namespace RL::Game::NativeHook {

static uintptr_t AllocCave(size_t size);
static bool WriteExec(uintptr_t addr, const void* data, size_t len);

namespace {

constexpr int kMaxInstalled = 16;
struct Hook {
    uintptr_t target = 0;
    uint8_t original[16]{};
    int origLen = 0;
    uintptr_t trampoline = 0;
    bool active = false;
    char name[24]{};
};
Hook g_hooks[kMaxInstalled];
int g_hookCount = 0;

// ---- Frame tick counter hook (0x7E5120: add [0xd380a4],1; ret) -------------
// The 2026-08-01 crash was caused by the ORIGINAL decoder mis-sizing this
// 7-byte instruction (0x83 05 disp32 imm8) as 6 bytes: the trampoline dropped
// the imm8, executed `add [0xd380a4], 0xE9` every frame, then ran garbage.
// With the PROVEN Lde decoder the trampoline now relocates all 7 bytes and
// lands exactly on the `ret`, preserving game behavior 1:1.
// Volatile so the worker/diagnostic can observe it; only the hook handler
// writes it, always on the game main thread.
volatile uint64_t g_frameTicks = 0;
volatile bool g_tickHooked = false;
uintptr_t g_tickTrampoline = 0;
uintptr_t g_tickThunk = 0;
// Original bytes of 0x7E5120 = 83 05 A4 80 D3 00 01 C3 (add+ret, 8 bytes).
uint8_t g_tickOriginal[16]{};
int g_tickOrigLen = 0;
uintptr_t g_tickTarget = 0x007E5120;

// ---- Tick diagnostics (what proves the hook is a real main-thread per-frame
// carrier vs. something firing on a render/worker thread) -------------------
volatile uint32_t g_tickLastThread = 0;   // thread id of the LAST firing
volatile uint64_t g_tickMainCount = 0;    // firings on the game main thread
volatile uint64_t g_tickMinMs = 0;        // min inter-tick interval
volatile uint64_t g_tickMaxMs = 0;        // max inter-tick interval
volatile uint64_t g_tickSumMs = 0;        // sum of intervals (for avg)
volatile uint64_t g_tickLastMs = 0;       // last tick timestamp
volatile uint32_t g_mainThreadId = 0;     // set via SetMainThreadId
volatile bool g_tickFired = false;        // has it fired at all

// The handler body. Runs on the game's native thread (inside the tick counter
// that the game calls). NO Lua is on the stack here — this is the exact native
// per-frame context the whole conversion targets. Guard::Scope means a fault
// here is caught (and we self-disable) instead of crashing the client.
void TickHookBody() {
    Guard::Scope g;
    if (g.Caught()) {
        RL::Log::Error("NativeHook: tick body fault - self-disabling");
        if (g_tickHooked) UninstallFrameTickHook();
        return;
    }
    uint64_t now = GetTickCount64();
    uint32_t tid = GetCurrentThreadId();
    g_tickLastThread = tid;
    g_tickFired = true;
    if (g_mainThreadId != 0 && tid == g_mainThreadId) g_tickMainCount++;
    if (g_tickLastMs != 0) {
        uint64_t dt = now - g_tickLastMs;
        if (g_tickMinMs == 0 || dt < g_tickMinMs) g_tickMinMs = dt;
        if (dt > g_tickMaxMs) g_tickMaxMs = dt;
        g_tickSumMs += dt;
    }
    g_tickLastMs = now;
    g_frameTicks++;
    // 2026-08-02 (0x512B07 ROOT-CAUSE FIX — the native carrier): this hook is
    // the ONLY context that may run EnumVisibleObjects (no Lua on the stack).
    // ObjectManager::Refresh is pure-memory + VEH-guarded + mutex-protected:
    // the list walk is safe; the EnumVisibleObjects game call is the corrupting
    // step, and it is DEFERRED here instead of the Lua bridge (the bridge now
    // skips enum while InLuaContext()). Rate-limited inside Refresh (omCacheMs).
    // Never Spell_C from here (stack-misalign crash history).
    // Main-thread gate: EnumVisibleObjects must only ever run on the game's
    // main thread. If the main-thread id isn't established yet (pre-register),
    // treat the first firings as main (the ticker is a main-loop counter);
    // once known, refuse enumeration from any other thread.
    //
    // 2026-08-02 (ROUND 37 — RELOAD/GLUE GATE): the game calls below (Spell_C
    // via DrainCastQueue, camera/object resolution in RefreshLiveFacingCache,
    // selection writes in PulseSelectionRestore) are ONLY safe in a STABLE
    // in-world state. During /reload the Lua VM is torn down and rebuilt on
    // the main thread — running Spell_C or game resolution mid-teardown crashes
    // the client (live 23:14:40: AV_READ eip=0x684BF090 in the CRT
    // atexit/init path, 460ms after the rebind was detected — the OM freeze
    // only gates OM::Refresh, NOT the cast drain or facing cache). Gate on the
    // same PURE-MEMORY signals the worker uses: a real active player GUID + a
    // live lua_State. Both are 0 during glue / char-select / loading / reload
    // and set once in-world. Fail-open: during a reload there is nothing to
    // cast and the addon Lua is not running.
    if (RL::Game::Addr::ActiveGuidPure() == 0 ||
        RL::Game::Addr::LuaState() == nullptr) {
        RL::Game::Actions::ResetBlockedCastCounter(); // harmless, keep alive
        return;
    }
    if (g_mainThreadId == 0 || tid == g_mainThreadId) {
        // One-time loud marker proving the NATIVE carrier (not the Lua bridge)
        // is the enumeration path — the verification tool greps this line.
        static volatile LONG s_logged = 0;
        if (InterlockedCompareExchange(&s_logged, 1, 0) == 0) {
            RL::Log::Warn("native carrier: frame hook ENUM PATH live "
                          "(main-thread id=%u, no Lua on stack)",
                          (unsigned)g_mainThreadId);
        }
        RL::Game::OM::Refresh(false);
        // 2026-08-02 (NATIVE LIVE-FACING CACHE): refresh the player's live
        // facing here, on the main thread with no Lua on the stack. The client
        // resolves facing via camera → GUID → ObjectPtr → [obj+0x7AC] (RE'd
        // 0x60A490); LocalPtr()+0x7AC reads 0 on this build. The cache lets the
        // Lua-facing path read a native value with ZERO game calls from the VM.
        RL::Game::OM::RefreshLiveFacingCache();
        // 2026-08-02 (NATIVE CAST CARRIER — user ABSOLUTE DIRECTIVE): drain the
        // staged cast queue HERE, on the main thread with NO Lua on the stack.
        // The Lua bridge stages casts via QueueCast (never touches Spell_C);
        // Spell_C runs ONLY from this native context — the structural fix for
        // the 0x512B07 Lua-VM corruption (Spell_C's cast-feedback re-enters
        // FrameScript/Lua, which corrupts the VM when a bridge C-closure is on
        // the stack). The thunk's `sub esp,8` before the call gives DrainCastQueue
        // 16-byte stack alignment (the earlier stack-misalign crash reason).
        RL::Game::Actions::DrainCastQueue();
        // 2026-08-02 (0x512B07 FINAL FIX): apply the deferred client-selection
        // restore here too (not only on the next Lua bridge pulse) so the
        // acquire-off "cast without targeting" revert lands on the hook even if
        // Lua never pulses again. Pure memory — safe on the main-thread hook.
        RL::Game::Actions::PulseSelectionRestore();
        // 2026-08-02 (DEFERRED PROTECTED ACTIONS): execute staged movement
        // halts here too — protected APIs must never run from a Lua-dispatched
        // bridge call (the "blocked action" dialog on suite disable).
        RL::Game::Actions::DrainDeferredActions();
        // 2026-08-02 (BLOCKED-DIALOG FIX, 1.10.81): zero the "addon blocked"
        // cast counter every frame — the walk's async origin-check can bump it
        // past 10 and fire the native blocked dialog (0x530840); a frame-level
        // reset guarantees the threshold is never reached.
        RL::Game::Actions::ResetBlockedCastCounter();
    }
}

// Build the thunk code cave that calls TickHookBody() then tail-jumps to the
// trampoline. Bytes:
//   9C                 pushfd
//   60                 pushad
//   83 EC 08           sub esp, 8      ; re-align ESP to 16B for the C++ callee
//   E8 rel32           call TickHookBody
//   83 C4 08           add esp, 8
//   61                 popad
//   9D                 popfd
//   68 imm32           push <trampoline>        ; no register clobbered
//   C3                 ret                       ; -> trampoline -> original ret
// pushfd(4)+pushad(32)=36 bytes pushed; the game's caller leaves ESP 16B
// aligned (≡0 mod 16), so at the `call` ESP≡36≡4 (mod 16); adding 8 restores
// ≡12 (mod 16) and the call's own 4-byte return-address push lands the callee
// at ≡0 (mod 16) — the 16-byte alignment MSVC x86 code assumes for movaps.
// Without this, EnumVisibleObjects (game code using aligned SSE locals)
// faults inside the hook and the Guard self-disables the carrier.
// Returns the thunk address, or 0 on failure.
static uintptr_t BuildTickThunk(uintptr_t trampoline) {
    uintptr_t cave = AllocCave(64);
    if (!cave) return 0;
    uint8_t* c = reinterpret_cast<uint8_t*>(cave);
    int off = 0;
    c[off++] = 0x9C;                                  // pushfd
    c[off++] = 0x60;                                  // pushad
    c[off++] = 0x83; c[off++] = 0xEC; c[off++] = 0x08; // sub esp, 8
    c[off++] = 0xE8;                                  // call rel32
    uint32_t body = (uint32_t)&TickHookBody;
    uint32_t callEnd = (uint32_t)(cave + off + 4);
    *(int32_t*)(c + off) = (int32_t)(body - callEnd);
    off += 4;
    c[off++] = 0x83; c[off++] = 0xC4; c[off++] = 0x08; // add esp, 8
    c[off++] = 0x61;                                  // popad
    c[off++] = 0x9D;                                  // popfd
    c[off++] = 0x68;                                  // push imm32
    *(uint32_t*)(c + off) = (uint32_t)trampoline;
    off += 4;
    c[off++] = 0xC3;                                  // ret
    return cave;
}

} // namespace

// Decode the relocation length for a target (>=5 whole instructions). Uses
// RL::Lde::LengthOf (see Lde.h) which is PROVEN correct against Capstone on
// 100% of Ascension.exe's .text. Returns bytes consumed, or 0 on failure.
static int RelocLength(const uint8_t* buf, int size) {
    int len = 0, pos = 0;
    while (pos < size && len < 5) {
        int l = RL::Lde::LengthOf(buf, pos, size);
        if (l <= 0) return 0;
        len += l;
        pos += l;
    }
    if (len < 5 || len > 16) return 0;
    return len;
}

// Build the trampoline for a target+orig, WITHOUT patching anything. Used so
// the trampoline pointer is committed to the global BEFORE the target is
// patched (no race window where the thunk jumps through a 0 global).
static uintptr_t BuildTrampoline(uintptr_t target, const uint8_t* orig, int len) {
    uintptr_t cave = AllocCave(64);
    if (!cave) return 0;
    uint8_t* c = reinterpret_cast<uint8_t*>(cave);
    memcpy(c, orig, len);
    // jmp rel32 back to (target + len)
    c[len] = 0xE9;
    uint32_t jmpDst = (uint32_t)(target + len);
    uint32_t jmpSrc = (uint32_t)(cave + len + 5);
    *(int32_t*)(c + len + 1) = (int32_t)(jmpDst - jmpSrc);
    return cave;
}

// Patch target to absolute-jump to handler (E9 rel32). Returns false on
// VirtualProtect/memcpy failure.
static bool PatchJump(uintptr_t target, uintptr_t handler) {
    uint8_t patch[5];
    patch[0] = 0xE9;
    uint32_t h = (uint32_t)handler;
    uint32_t t = (uint32_t)(target + 5);
    *(int32_t*)(patch + 1) = (int32_t)(h - t);
    return WriteExec(target, patch, 5);
}

// Allocate an executable trampoline code cave.
static uintptr_t AllocCave(size_t size) {
    void* p = VirtualAlloc(nullptr, size, MEM_COMMIT | MEM_RESERVE,
                           PAGE_EXECUTE_READWRITE);
    return reinterpret_cast<uintptr_t>(p);
}

static bool WriteExec(uintptr_t addr, const void* data, size_t len) {
    DWORD old = 0;
    if (!VirtualProtect(reinterpret_cast<void*>(addr), len, PAGE_EXECUTE_READWRITE, &old))
        return false;
    memcpy(reinterpret_cast<void*>(addr), data, len);
    DWORD prev = 0;
    VirtualProtect(reinterpret_cast<void*>(addr), len, old, &prev);
    FlushInstructionCache(GetCurrentProcess(), reinterpret_cast<void*>(addr), len);
    return true;
}

bool Install(uintptr_t target, void* handler, uintptr_t* trampoline, const char* name) {
    if (!target || !handler || !trampoline) return false;
    if (g_hookCount >= kMaxInstalled) return false;
    if (IsHooked(target)) return false;

    // Read original bytes (VirtualQuery-guarded).
    uint8_t orig[16]{};
    size_t n = Mem::ReadBytes(target, orig, sizeof(orig));
    if (n < 5) {
        RL::Log::Error("NativeHook: unreadable target 0x%08X", (unsigned)target);
        return false;
    }
    // Find the relocation length (>=5 whole instructions) using the PROVEN
    // Lde decoder (crash-fix: the old decoder mis-sized `add r/m32, imm8`).
    int len = RelocLength(orig, (int)n);
    if (len <= 0) {
        RL::Log::Error("NativeHook: target 0x%08X not relocatable (len<=0)",
                       (unsigned)target);
        return false;
    }

    // Build the trampoline: relocated original bytes + absolute jmp back to
    // target+len.
    uintptr_t cave = BuildTrampoline(target, orig, len);
    if (!cave) return false;

    // Patch the target: E9 rel32 to handler.
    if (!PatchJump(target, reinterpret_cast<uintptr_t>(handler))) {
        VirtualFree(reinterpret_cast<void*>(cave), 0, MEM_RELEASE);
        return false;
    }

    Hook& hk = g_hooks[g_hookCount];
    hk.target = target;
    memcpy(hk.original, orig, len);
    hk.origLen = len;
    hk.trampoline = cave;
    hk.active = true;
    if (name) { strncpy_s(hk.name, name, 23); hk.name[23] = '\0'; }
    else hk.name[0] = '\0';
    ++g_hookCount;
    *trampoline = cave;
    RL::Log::Info("NativeHook: installed '%s' at 0x%08X tramp=0x%08X len=%d",
                  hk.name, (unsigned)target, (unsigned)cave, len);
    return true;
}

bool Uninstall(uintptr_t target) {
    for (int i = 0; i < g_hookCount; ++i) {
        if (g_hooks[i].target == target && g_hooks[i].active) {
            WriteExec(target, g_hooks[i].original, g_hooks[i].origLen);
            g_hooks[i].active = false;
            RL::Log::Info("NativeHook: uninstalled at 0x%08X", (unsigned)target);
            return true;
        }
    }
    return false;
}

bool IsHooked(uintptr_t target) {
    for (int i = 0; i < g_hookCount; ++i)
        if (g_hooks[i].target == target && g_hooks[i].active) return true;
    return false;
}

// ---- Frame tick hook (benign, config-gated, proof-of-mechanism) ------------

bool InstallFrameTickHook(bool force) {
    if (g_tickHooked) return true;
    // CONFIG GATE: OFF by default. A normal session can never be touched by
    // an unverified hook. Only native.hook.frame_tick=1 (or force=true from an
    // explicit dev test command) installs it, and force is logged loudly.
    if (!force && RL::Config::Get("native.hook.frame_tick") != "1") {
        RL::Log::Warn("NativeHook: frame_tick hook REFUSED (config gate off)");
        return false;
    }
    Guard::Scope g;
    if (g.Caught()) { RL::Log::Error("NativeHook: AV installing tick hook"); return false; }
    g_frameTicks = 0;
    g_tickLastThread = 0;
    g_tickMainCount = 0;
    g_tickMinMs = 0;
    g_tickMaxMs = 0;
    g_tickSumMs = 0;
    g_tickLastMs = 0;
    g_tickFired = false;
    // Read original (8 bytes: 83 05 A4 80 D3 00 01 C3)
    size_t n = Mem::ReadBytes(g_tickTarget, g_tickOriginal, sizeof(g_tickOriginal));
    if (n < 5) { RL::Log::Error("NativeHook: tick target unreadable"); return false; }
    int len = RelocLength(g_tickOriginal, (int)n);
    if (len <= 0) { RL::Log::Error("NativeHook: tick target decode failed"); return false; }
    g_tickOrigLen = len;
    // Build trampoline FIRST, then thunk, then commit globals BEFORE patching
    // (no race where the game enters a half-built hook).
    uintptr_t tramp = BuildTrampoline(g_tickTarget, g_tickOriginal, len);
    if (!tramp) { RL::Log::Error("NativeHook: tick trampoline alloc failed"); return false; }
    uintptr_t thunk = BuildTickThunk(tramp);
    if (!thunk) {
        VirtualFree(reinterpret_cast<void*>(tramp), 0, MEM_RELEASE);
        RL::Log::Error("NativeHook: tick thunk alloc failed");
        return false;
    }
    g_tickTrampoline = tramp;
    g_tickThunk = thunk;
    if (!PatchJump(g_tickTarget, thunk)) {
        g_tickTrampoline = 0;
        g_tickThunk = 0;
        VirtualFree(reinterpret_cast<void*>(tramp), 0, MEM_RELEASE);
        VirtualFree(reinterpret_cast<void*>(thunk), 0, MEM_RELEASE);
        RL::Log::Error("NativeHook: tick patch failed");
        return false;
    }
    // READ-BACK VERIFICATION: confirm the E9 rel32 actually landed on our thunk
    // (crash-prevention: a torn/misplaced patch must never be left active).
    uint8_t verify[5]{};
    if (Mem::ReadBytes(g_tickTarget, verify, 5) != 5 || verify[0] != 0xE9) {
        WriteExec(g_tickTarget, g_tickOriginal, g_tickOrigLen);  // roll back
        g_tickTrampoline = 0;
        g_tickThunk = 0;
        VirtualFree(reinterpret_cast<void*>(tramp), 0, MEM_RELEASE);
        VirtualFree(reinterpret_cast<void*>(thunk), 0, MEM_RELEASE);
        RL::Log::Error("NativeHook: tick patch READ-BACK FAILED - rolled back");
        return false;
    }
    uint32_t expectThunk = (uint32_t)thunk;
    uint32_t patchTarget = (uint32_t)(g_tickTarget + 5);
    int32_t rel = *(int32_t*)(verify + 1);
    if ((uint32_t)(patchTarget + rel) != expectThunk) {
        WriteExec(g_tickTarget, g_tickOriginal, g_tickOrigLen);  // roll back
        g_tickTrampoline = 0;
        g_tickThunk = 0;
        VirtualFree(reinterpret_cast<void*>(tramp), 0, MEM_RELEASE);
        VirtualFree(reinterpret_cast<void*>(thunk), 0, MEM_RELEASE);
        RL::Log::Error("NativeHook: tick patch rel32 MISMATCH - rolled back");
        return false;
    }
    // Register in the hook table so Shutdown() restores it.
    Hook& hk = g_hooks[g_hookCount];
    hk.target = g_tickTarget;
    memcpy(hk.original, g_tickOriginal, g_tickOrigLen);
    hk.origLen = g_tickOrigLen;
    hk.trampoline = tramp;
    hk.active = true;
    strncpy_s(hk.name, "frame_tick", 23); hk.name[23] = '\0';
    ++g_hookCount;
    g_tickHooked = true;
    RL::Log::Warn("NativeHook: frame tick hook ACTIVE (0x7E5120) tramp=0x%08X "
                  "thunk=0x%08X len=%d force=%d",
                  (unsigned)tramp, (unsigned)thunk, len, (int)force);
    return true;
}

bool UninstallFrameTickHook() {
    if (!g_tickHooked) return true;
    for (int i = 0; i < g_hookCount; ++i) {
        if (g_hooks[i].target == g_tickTarget && g_hooks[i].active) {
            WriteExec(g_tickTarget, g_hooks[i].original, g_hooks[i].origLen);
            g_hooks[i].active = false;
            g_tickHooked = false;
            g_tickTrampoline = 0;
            g_tickThunk = 0;
            RL::Log::Info("NativeHook: frame tick hook removed");
            return true;
        }
    }
    return true;
}

// Non-blocking delta rate: computes fps from ticks elapsed since the previous
// call, but only reports when >=400ms of wall time has passed (else it returns
// the last cached rate / 0 while warming). Never sleeps the game thread.
int FrameRateDelta() {
    if (!g_tickHooked && !InstallFrameTickHook()) return 0;
    static uint64_t s_lastTicks = 0;
    static ULONGLONG s_lastMs = 0;
    static int s_lastFps = 0;
    uint64_t now = g_frameTicks;
    ULONGLONG ms = GetTickCount64();
    if (s_lastMs == 0) {
        s_lastMs = ms;
        s_lastTicks = now;
        return 0;  // warming
    }
    ULONGLONG dt = ms - s_lastMs;
    if (dt < 400) return s_lastFps;  // not enough elapsed; return cached
    uint64_t d = now - s_lastTicks;
    s_lastMs = ms;
    s_lastTicks = now;
    s_lastFps = dt ? (int)(d * 1000ULL / dt) : 0;
    return s_lastFps;
}

uint64_t FrameTickCount() { return g_frameTicks; }

void SetMainThreadId(uint32_t tid) { g_mainThreadId = tid; }

std::string FrameTickDiag() {
    char b[256];
    uint64_t avg = 0;
    if (g_frameTicks > 1) avg = g_tickSumMs / (g_frameTicks - 1);
    snprintf(b, sizeof(b),
             "active=%d|fired=%d|ticks=%llu|last_thread=0x%X|main_thread=0x%X|"
             "main_ticks=%llu|min_ms=%llu|avg_ms=%llu|max_ms=%llu",
             (int)(g_tickHooked ? 1 : 0), (int)(g_tickFired ? 1 : 0),
             (unsigned long long)g_frameTicks, (unsigned)g_tickLastThread,
             (unsigned)g_mainThreadId, (unsigned long long)g_tickMainCount,
             (unsigned long long)g_tickMinMs, (unsigned long long)avg,
             (unsigned long long)g_tickMaxMs);
    return std::string(b);
}

void Shutdown() {
    for (int i = 0; i < g_hookCount; ++i) {
        if (g_hooks[i].active) {
            WriteExec(g_hooks[i].target, g_hooks[i].original, g_hooks[i].origLen);
            g_hooks[i].active = false;
        }
    }
    g_hookCount = 0;
    g_tickHooked = false;
    g_tickTrampoline = 0;
    g_tickThunk = 0;
}

} // namespace RL::Game::NativeHook
