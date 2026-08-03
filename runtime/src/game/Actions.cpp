#include "Actions.h"
#include "ObjectManager.h"
#include "GameState.h"
#include "Guard.h"
#include "Mem.h"
#include "MainThread.h"
#include "AddressDB.h"
#include "Offsets.h"
#include "TaintPatch.h"
#include "core/Log.h"
#include "lua/Lua.h"
#include <Windows.h>
#include <cstdio>
#include <cstring>
#include <cmath>

// Cast rules:
// - Never full Taint::Apply from here (freezes)
// - HardwareEvent gate patches only (safe) via ArmUnlock
// - Native Spell_C_CastSpell @ 0x80DA40: __cdecl(spellId, itemId, guidLo, guidHi, isTrade)
// - Also FrameScript_Execute CastSpellByID with origin "*" (3-arg FS)
// - Nested lua_pcall CastSpellByID when L is available from Dispatch

namespace RL::Game::Actions {

// --- Secure-action bitmask sets (native "addon blocked" / cast-origin state) ---
// RE-VERIFIED (2026-08-02): Spell_C's cast-origin check is 0x5222B0(5), which
// returns 0 (cast marked blocked: [0xAF53C4]=1, then after 10 blocks 0x530840
// fires the "<addon> has been blocked" dialog NATIVELY, no Lua event) whenever
// [0xBD1AF0]==0. Both sets are populated by the initializer 0x530920.
//   [0xBD1AE0]/[0xBD1AEC] = set A armed/count + bitmask ptr
//   [0xBD1AF0]/[0xBD1AFC] = set B armed/count + bitmask ptr (gates 0x5222B0)
constexpr uintptr_t kSecureFlagA = 0x00BD1AE0;
constexpr uintptr_t kSecureMaskA = 0x00BD1AEC;
constexpr uintptr_t kSecureFlagB = 0x00BD1AF0;
constexpr uintptr_t kSecureMaskB = 0x00BD1AFC;
// canCast(2) gate input (0x5191C0): while this is != 0 the gate returns 0 and
// Spell_C refuses EVERY cast. Stuck non-zero in this environment; the client
// itself zeroes it during its own action processing (0x48EC50).
constexpr uintptr_t kActionStateGlob = 0x00D4139C;
// 2026-08-02 (0x512B07 FINAL FIX v2): [0xD413A0] = action depth counter and
// [0xD413A4] = restore-flag are the client's save/zero/restore bookkeeping
// (0x48EC20 / 0x493180 / 0x857CA0 patterns). A BARE [0xD4139C]=0 without them
// left the client's action machinery permanently "in action" -> the cast-
// feedback recursed without the busy guard -> 0x512B07 in FrameScript unit
// resolution (proven: EVERY Spell_C cast crashed, all mechanisms).
// SafeNativeCast now replicates the client's full pattern.
constexpr uintptr_t kActionDepthGlob = 0x00D413A0;
constexpr uintptr_t kActionRestoreFlagGlob = 0x00D413A4;
// 2026-08-02 (BLOCKED-ACTION DIALOG FIX): Spell_C's cast-origin check
// (0x5222B0(5)) marks every insecure-origin cast "blocked" and increments
// [0xD3F604]; at >10 the client fires the native "RaijinLab has been blocked
// from an action only available to the Blizzard UI" dialog (0x530840). The
// client itself resets the counter to 0 (0x80CE84) on the first block within a
// cast — we reset it after every cast so it never reaches 10.
constexpr uintptr_t kBlockedCastCounter = 0x00D3F604;

// 2026-08-02 (19:25 BLOCKED-DIALOG ROOT CAUSE): 0xD3F604 (the "addon blocked"
// cast counter) lives in the client's UNCOMMITTED .data BSS tail (committed
// ends 0xB2EE00, virtual to 0xDD0508) — the SAME region as 0xD3C00E14.
// Mem::Write is VirtualQuery-guarded, so writing an uncommitted page is a
// silent NO-OP: the counter climbed past 10 and fired the native blocked
// dialog (0x530840) on suite disable DESPITE the reset. Commit the page once
// (idempotent) so the reset is real.
static void EnsureBlockedCounterCommitted() {
    static volatile LONG s_committed = 0;
    if (InterlockedCompareExchange(&s_committed, 1, 0) == 0) {
        LPVOID page = (LPVOID)(kBlockedCastCounter & ~0xFFFu);
        VirtualAlloc(page, 0x1000u, MEM_COMMIT, PAGE_READWRITE);
    }
}

namespace {

using RL::Game::Actions::SoftHardwareUnlock;

using fnVoid = void(__cdecl*)();
using fnFSExec3 = void(__cdecl*)(const char* code, const char* name, int taintArg);
// Real client cast used by FrameScript CastSpellByID / CastSpellByName
using fnCastSpell = int(__cdecl*)(int spellId, int itemId,
                                  uint32_t guidLo, uint32_t guidHi, int isTrade);
// ObjectPtr(guidLo, guidHi, typeMask)
using fnObjectPtr3 = uintptr_t(__cdecl*)(uint32_t lo, uint32_t hi, int typeMask);
using fnGetActive = uint64_t(__cdecl*)();

// Lua stack primitives used ONLY by InteractUnitDirect (native handler call).
// Nested getfield/pcall helpers are deleted (crash rule) — never re-add them.
using fn_settop = void(__cdecl*)(lua_State*, int);
using fn_gettop = int(__cdecl*)(lua_State*);
using fn_pushstring = void(__cdecl*)(lua_State*, const char*);

// thread_local so a stale write from a previous main-thread call cannot leak
// into an unrelated worker-thread bridge invocation, and vice-versa. Only
// the main-thread setter / reader pair inside Dispatch::CastSpell should
// ever see a non-null value. SafeFSExec reads it to refuse FSExec while the
// bridge (Lua_IsLinuxClient) is on the stack.
static thread_local lua_State* g_currentL = nullptr;

// Forward declarations (defined later in this namespace; used by the
// Spell_C gate diagnostic that lives before them).
static uintptr_t ObjectPtr3(uint64_t guid, int mask);
static uintptr_t PlayerPtr();

static fnVoid At(uintptr_t addr) {
    return addr ? reinterpret_cast<fnVoid>(addr) : nullptr;
}

static int SafeVoid(fnVoid fn) {
    if (!fn) return 0;
    // VEH longjmp guard — a dead __try under stealth let movement-call AVs
    // propagate into the game's Lua VM (corrupted closure table).
    Guard::Scope g;
    if (!g.Caught()) {
        fn();
        return 1;
    }
    return -1;
}

static int SafeFSExec(const char* code) {
    if (!code || !code[0]) return 0;
    // CRASH RULE (permanent): never FrameScript_Execute while inside the
    // bridge — re-entering the VM from inside Lua_IsLinuxClient hard-crashes
    // the client (ERROR #132, 1.10.19-castsafe). Nested lua_pcall is equally
    // forbidden (1.10.43: corrupts the Lua stack → eip=0 in game VM).
    // SafeFSExec is now reachable ONLY from non-bridge paths.
    if (g_currentL) return 0;
    uintptr_t addr = Addr::FrameScript_Execute ? Addr::FrameScript_Execute : 0x00819210;
    // CRASH RULE (permanent): do NOT write HardwareEventFlag=1 (0x00C21000)
    // or TaintContext=0 (0x00D4139C) here. Writing the HW flag corrupts the
    // Lua VM → AV_READ (proven isolation). The .text HW-gate patches are the
    // actual gate bypass; these runtime writes are removed.
    // FrameScript_Execute(code, source, taintOverride) - 3 args on this build
    // VEH longjmp guard: FrameScript_Execute is only reached OUTSIDE the
    // bridge (g_currentL==0), but guard it anyway so no AV ever escapes.
    Guard::Scope g;
    if (!g.Caught()) {
        reinterpret_cast<fnFSExec3>(addr)(code, "*", 0);
        return 1;
    }
    return -1;
}

// 2026-08-02 (0x512B07 FINAL FIX v3 — PROPER target registration): the
// client's REAL target setter. TargetUnit handler (0x525A30) -> resolver
// (0x520190/0x60ABF0) -> 0x5259E0 -> 0x524BF0(lo,hi) — cdecl, called with the
// target GUID. It RESOLVES the object (ObjectPtr mask 1) and registers the
// target via 0x80BC80 (0xBD07B0 + the target-object reference the cast
// feedback resolves against). REQUIREMENT: [0xD4139C]==0 — it refuses
// (0x513530) otherwise. The raw WriteClientTargetGuid only wrote 0xBD07B0/
// desc+0x48 WITHOUT registering the object, so the cast-feedback resolved a
// stale pointer -> 0x512B07 (live: crash.state bd07b0=0 at fault, every
// cast, all mechanisms).
static constexpr uintptr_t kClientSetTarget = 0x00524BF0;
using fnSetTarget = int(__cdecl*)(uint32_t lo, uint32_t hi);

// VEH-guarded call of the client's target setter. Only safe from the native
// hook / with [0xD4139C]==0 (the caller must already be inside the zeroed
// window). Returns true if it didn't fault.
static bool NativeSetTarget(uint64_t guid) {
    if (!guid) return false;
    Guard::Scope g;
    if (g.Caught()) return false;
    auto fn = reinterpret_cast<fnSetTarget>(kClientSetTarget);
    static volatile LONG s_diag = 0;
    if (InterlockedCompareExchange(&s_diag, 1, 0) == 0)
        RL::Log::Warn("NativeSetTarget guid=0x%llX (client's real setter)",
                      (unsigned long long)guid);
    fn((uint32_t)guid, (uint32_t)(guid >> 32));
    return true;
}

static int SafeNativeCast(int spellId, uint64_t targetGuid, uint64_t registerTarget = 0) {
    uintptr_t castAddr = Offsets::F().Spell_C_CastSpell;
    if (!castAddr) castAddr = Addr::Spell_C_CastSpell;
    if (!castAddr) castAddr = 0x0080DA40;
    uint32_t lo = (uint32_t)targetGuid;
    uint32_t hi = (uint32_t)(targetGuid >> 32);
    // VEH longjmp guard (Guard.h): an AV inside Spell_C is consumed here and
    // NEVER propagates into the game's Lua VM (a dead __try under stealth let
    // it corrupt the closure table -> garbage-eip crashes).
    Guard::Scope g;
    if (!g.Caught()) {
        // 0x512B07 CRASH FIX (2026-08-01, evidence-based): every crash was
        // "Lua calls 0x512B00(GUID-resolver) with a garbage arg ~6-15ms after a
        // SUCCESSFUL Spell_C" — Spell_C's cast-feedback re-enters FrameScript/
        // Lua, and it does so while our bridge C-closure (g_currentL) is on the
        // stack, corrupting the VM's TValues. The one config that NEVER crashed
        // (17:51) ran Spell_C with g_currentL==0 (native thunk drain). So clear
        // g_currentL around Spell_C so the game's own Lua integration does NOT
        // see our closure frame on the stack. Restore after (thread_local).
        lua_State* held = g_currentL;
        g_currentL = nullptr;
        auto fn = reinterpret_cast<fnCastSpell>(castAddr);
        // 2026-08-02 (0x512B07 FINAL FIX v2 — action-state integrity): the
        // old fix zeroed [0xD4139C] (the canCast busy gate) with NO save, NO
        // restore and NO [0xD413A0]/[0xD413A4] bookkeeping, which left the
        // client's action machinery permanently "in action". Its cast-feedback
        // then recursed without the busy guard and crashed 0x512B07 in
        // FrameScript unit resolution (proven: EVERY Spell_C cast crashes,
        // all mechanisms, even guid=0). Replicate the client's own
        // save/zero/restore (0x48EC20 / 0x493180) EXACTLY around Spell_C so
        // the client's action-state stays consistent.
        uint32_t depth = Mem::Read<uint32_t>(kActionDepthGlob) + 1;
        Mem::Write<uint32_t>(kActionDepthGlob, depth);
        uint32_t saved = Mem::Read<uint32_t>(kActionStateGlob);
        uint32_t a4 = Mem::Read<uint32_t>(kActionRestoreFlagGlob);
        if (saved != 0 && a4 == 0)
            Mem::Write<uint32_t>(kActionStateGlob, 0u);
        // 2026-08-02 (17:26 ROOT CAUSE — 0xD3C00E14 WALK-SLOT FIX): the
        // cast-feedback walk (0x856370 -> 0x512B00) reads the cast-target GUID
        // from a STATIC slot at 0xD3C00E14 and passes it to the resolver.
        // Live: the shield logged esi=0xD3C00E14 on ALL 129 AVs — the client's
        // .data BSS tail (committed end 0xB2EE00, virtual end 0xDD0508) is
        // UNCOMMITTED on this build, so the resolver's [esi+4] read AVs
        // 0x512B07. The client's OWN UI casts work because the loader commits
        // BSS AND the cast machinery writes the target GUID into the slot.
        // We replicate BOTH: commit the page once, then write the cast target
        // GUID into the slot BEFORE Spell_C — so the resolver's ObjectPtr
        // finds the victim and the walk completes cleanly. This is what makes
        // a DIRECT-GUID cast (no selection registration) resolvable -> the
        // client target / unitframe is NEVER touched for acquire-off.
        {
            static volatile LONG s_slotCommitted = 0;
            if (InterlockedCompareExchange(&s_slotCommitted, 1, 0) == 0) {
                LPVOID page = (LPVOID)(0xD3C00E14u & ~0xFFFu);
                VirtualAlloc(page, 0x1000u, MEM_COMMIT, PAGE_READWRITE);
            }
            Mem::Write<uint32_t>(0xD3C00E14u + 0u, lo);
            Mem::Write<uint32_t>(0xD3C00E14u + 4u, hi);
            // ROUND 26: also seed the record's +0x28 fallback slot
            // (0x80CD5B: if [rec+0x18]|[rec+0x1c]==0 the sync path falls back to
            // [rec+0x28]) — [0xD3C00DFC+0x28] == 0xD3C00E24.
            Mem::Write<uint32_t>(0xD3C00E14u + 0x10u, lo);
            Mem::Write<uint32_t>(0xD3C00E14u + 0x14u, hi);
        }
        // 2026-08-02 (19:25 CORRUPTION FIX — THE FALSE "Can't attack while
        // charmed"): the round-18 [player+0xd0]+0x18 write was a corruption
        // source because it used PlayerPtr(), whose MainThread snapshot stores
        // OM::LocalPtr() (garbage — FacingLive local=1e9 every session);
        // recPtr+0x18 then landed wherever garbage pointed (often a live
        // unit-flags field) and the victim GUID's LOW DWORD set
        // UNIT_FLAG_CHARMED (0x40) — the client then refused EVERY cast with
        // "Can't attack while charmed" while the player was NOT charmed.
        //
        // 2026-08-02 (ROUND 22 — SYNC TARGET RESOLUTION, the "Invalid
        // target" al=0 fix): the write is RE-ADDED but ONLY with a VERIFIED
        // player object (OM::VerifiedPlayerPtr = SafeGetActive → ObjectPtr
        // mask 0x10, then the camera path — the exact resolution
        // RefreshLiveFacingCache proves correct live, obj=0x37825EE0) and
        // ONLY in the native-hook context (held==0, no Lua on stack). With a
        // verified player, [player+0xd0] is the client's REAL cast record and
        // [recPtr+0x18/+0x1c] IS the cast-record target-GUID field — the same
        // field the client itself writes for its own casts, and the field
        // Spell_C's SYNC resolution (0x80CD4A) reads. Writing the victim GUID
        // there restores the sync resolution (which is why Consecration
        // lands — guid=0 needs no target — while EVERY unit-targeted cast
        // fails "Invalid target" al=0). If the player can't be verified, the
        // write is SKIPPED (never write through an unverified pointer).
        // The arg4 GUID-holder (below) stays: it feeds the victim GUID into
        // the client's NEW cast record via a pointer to OUR memory.
        // The static-slot write above stays (proven round-15, the walk's own
        // GUID slot).
        // 2026-08-02 (18:36 REGRESSION — 1.10.83 CAST-GUID FIX part 2): the
        // client's "guidLo" argument to Spell_C (0x80CCE0) is a POINTER, not
        // a raw dword: 0x80CDC1 does `mov ecx,[ebx+8]; mov eax,[ecx]; mov
        // ecx,[ecx+4]` to fill the NEW cast record's target GUID from
        // [guidPtr+8]. Passing the raw lo dword made the client read a
        // garbage GUID from [lo+8] into the record -> async cast-feedback walk
        // AV'd on that garbage (esi=0xF75FC697) and casts refused
        // "Out of range". Hand the client a valid holder so the record always
        // gets the real victim GUID.
        static uint64_t s_victimGuid = 0;
        static uint32_t s_guidHolder[4] = { 0, 0, 0, 0 };
        s_victimGuid = targetGuid;
        s_guidHolder[2] = (uint32_t)(uintptr_t)&s_victimGuid; // [holder+8] = &GUID
        uint32_t guidPtr = (uint32_t)(uintptr_t)s_guidHolder;
        // 2026-08-02 (ROUND 26 — THE DEFINITIVE FIX: restore the static
        // cast-record pointer). The round-25 CastDiag PROVED the [player+0xd0]+
        // 0x18 write is UNCONDITIONALLY UNSAFE: [player+0xd0] is NOT a cast
        // record — it points INTO the player's own descriptor (rec = desc+0x28
        // where desc = [player+0x8]), so writing [rec+0x18]/[rec+0x1c] lands on
        // desc+0x40/0x44, the player's live unit fields. Live proof:
        //   CastDiag ... rec=0x37470080 static=0 vt=0 r18=F1300005E5006AF0
        //   r28=F1300005E5006AF0 s20=0 flags=F1300005 charm=0
        // The "flags" field (desc+0x44) became the victim GUID's HIGH DWORD
        // (0xF1300005) — the write corrupted the player -> "Can't attack while
        // charmed" + XPerl flood. NEVER write [player+0xd0]+0x18 again.
        //
        // THE REAL MECHANISM: the client's sync resolution (0x80CD4A) reads
        // [player+0xd0]+0x18 as the cast-target GUID. In the 18:11 clean session
        // [player+0xd0] was the STATIC slot 0xD3C00DFC, so our walk-slot write
        // (0xD3C00E14 = [0xD3C00DFC+0x18]) fed the sync path and casts LANDED.
        // The user's target SELECTION (TargetUnit -> 0x524BF0) is what flips
        // [player+0xd0] to the descriptor alias — after that the walk-slot write
        // misses and every targeted cast refuses "Invalid target" al=0.
        // FIX: at cast time (native context), restore [player+0xd0] =
        // 0xD3C00DFC (a legitimate pointer VALUE the client itself uses as the
        // default — a pointer-field write, NOT a descriptor write, NOT a
        // selection write). The walk-slot write then feeds the sync path exactly
        // like 18:11. The user's selection (0xBD07B0) and the unitframe are
        // untouched — acquire-off casts still never change the target.
        // The [0xd0] pointer write is safe: 0xD3C00DFC is the client's own
        // default record address on the page we already committed (round 15).
        if (held == 0) {
            uintptr_t vplayer = OM::VerifiedPlayerPtr();
            if (vplayer) {
                uintptr_t cur = Mem::Read<uintptr_t>(vplayer + 0xD0);
                if (cur != 0xD3C00DFCu)
                    Mem::Write<uintptr_t>(vplayer + 0xD0, 0xD3C00DFCu);
            }
        }
        // 2026-08-02 (ROUND 23/24 — SYNC-TARGET DIAGNOSTIC): names the exact
        // resolution state on every targeted cast (native context, ~2s throttle):
        // the cast-wrapper player GUID ([ClntObjMgr+0xC0/0xC4] via the 0x4d3790
        // TLS chain), the cast-path player (ObjectPtr(guid, mask 0x10) — what
        // the wrapper uses), the camera player, whether they agree, the record
        // pointer [castPlayer+0xD0], its static-slot status, the record's
        // signature fields (+8/+0xc target, +0x10/+0x14 caster), the sync GUID
        // slots (+0x18/+0x1c, +0x28/+0x2c), and the player's UNIT_FIELD_FLAGS
        // charmed bit. This makes any remaining failure attributable.
        if (held == 0) {
            static volatile LONG s_diagMs = 0;
            LONG nowD = (LONG)(RL::Game::State::GameTimeMs() & 0x7FFFFFFF);
            LONG lastD = s_diagMs;
            if (targetGuid != 0 && (nowD - lastD > 2000 || lastD == 0)) {
                s_diagMs = nowD;
                uintptr_t mgr = OM::ClntObjMgrTls();
                uint32_t mlo = 0, mhi = 0;
                if (mgr) { mlo = Mem::Read<uint32_t>(mgr + 0xC0); mhi = Mem::Read<uint32_t>(mgr + 0xC4); }
                uintptr_t castPlayer = 0;
                if (mlo || mhi) castPlayer = OM::ObjectPtr3Guid(mlo, mhi, 0x10);
                uintptr_t camPlayer = OM::CameraPlayerPtrEx();
                uintptr_t recPtr = 0;
                uint32_t rv = 0, r8 = 0, rc = 0, r10 = 0, r14 = 0, r18 = 0, r1c = 0, r28 = 0, r2c = 0, spellAt20 = 0;
                if (castPlayer) {
                    recPtr = Mem::Read<uintptr_t>(castPlayer + 0xD0);
                    if (recPtr && recPtr >= 0x10000u) {
                        rv = Mem::Read<uint32_t>(recPtr + 0x0);
                        r8 = Mem::Read<uint32_t>(recPtr + 0x8);
                        rc = Mem::Read<uint32_t>(recPtr + 0xC);
                        r10 = Mem::Read<uint32_t>(recPtr + 0x10);
                        r14 = Mem::Read<uint32_t>(recPtr + 0x14);
                        r18 = Mem::Read<uint32_t>(recPtr + 0x18);
                        r1c = Mem::Read<uint32_t>(recPtr + 0x1C);
                        r28 = Mem::Read<uint32_t>(recPtr + 0x28);
                        r2c = Mem::Read<uint32_t>(recPtr + 0x2C);
                        spellAt20 = Mem::Read<uint32_t>(recPtr + 0x20);
                    }
                }
                uint32_t flags = 0;
                if (castPlayer) {
                    uintptr_t desc = Mem::Read<uintptr_t>(castPlayer + Offsets::O().Descriptor);
                    if (desc && desc >= 0x10000u) flags = Mem::Read<uint32_t>(desc + 0x44);
                }
                RL::Log::Warn("CastDiag id=%d guid=%08X%08X mgr=0x%lX mguid=%08X%08X "
                              "castP=0x%lX camP=0x%lX rec=0x%lX static=%d "
                              "vt=%08X r8=%08X%08X r10=%08X%08X r18=%08X%08X r28=%08X%08X "
                              "s20=%u flags=%08X charm=%d",
                              spellId, (unsigned)hi, (unsigned)lo,
                              (unsigned long)mgr, (unsigned)mhi, (unsigned)mlo,
                              (unsigned long)castPlayer, (unsigned long)camPlayer,
                              (unsigned long)recPtr, (recPtr == 0xD3C00DFCu),
                              (unsigned)rv,
                              (unsigned)rc, (unsigned)r8, (unsigned)r14, (unsigned)r10,
                              (unsigned)r1c, (unsigned)r18, (unsigned)r2c, (unsigned)r28,
                              spellAt20,
                              (unsigned)flags, (int)((flags & 0x40) != 0));
            }
        }
        // 2026-08-02 (0x512B07 FINAL FIX v3): we are inside the [0xD4139C]==0
        // window — register the cast target via the client's real setter so
        // the cast-feedback can resolve it. Raw 0xBD07B0 writes leave the
        // target unregistered -> stale pointer in feedback -> 0x512B07.
        // 2026-08-02 (1.10.81): with the 0xD3C00E14 walk-slot write above, the
        // feedback resolves the victim WITHOUT selection registration — so
        // registerTarget is no longer needed for crash safety and acquire-off
        // passes registerTarget=0 (unitframe never touched).
        if (registerTarget != 0)
            NativeSetTarget(registerTarget);
        int rc = fn(spellId, 0, guidPtr, 0, 0);
        // 2026-08-02 (BLOCKED-ACTION DIALOG FIX): reset the "addon blocked"
        // cast counter after every cast so it never accumulates to 10 and
        // fires the native blocked dialog (0x530840). Pure memory write of the
        // same value the client itself writes (0x80CE84).
        // 2026-08-02 (19:25): the counter page is UNCOMMITTED BSS — the write
        // was a silent no-op. Commit the page first so the reset is real.
        EnsureBlockedCounterCommitted();
        Mem::Write<uint32_t>(kBlockedCastCounter, 0u);
        if (depth != 0 && Mem::Read<uint32_t>(kActionRestoreFlagGlob) == 0)
            Mem::Write<uint32_t>(kActionStateGlob, saved);
        uint32_t d2 = Mem::Read<uint32_t>(kActionDepthGlob);
        Mem::Write<uint32_t>(kActionDepthGlob, d2 > 1 ? d2 - 1 : 0);
        g_currentL = held;
        // 2026-08-02: Spell_C's return is the AL BYTE (1=accepted, 0=refused).
        // The full eax can be non-zero (e.g. 0x50500000) on a REFUSED path
        // because failure epilogues do `xor al,al` after clobbering eax —
        // treating any non-zero eax as success masked every refusal as "1|ok".
        int al = rc & 0xFF;
        static volatile LONG s_lastRcLog = 0;
        LONG nowMs = (LONG)(RL::Game::State::GameTimeMs() & 0x7FFFFFFF);
        LONG last = s_lastRcLog;
        if (al == 0 || nowMs - last > 2000 || last == 0) {
            s_lastRcLog = nowMs;
            RL::Log::Warn("SafeNativeCast rc=0x%08X al=%d id=%d guid=0x%llX",
                          (unsigned)rc, al, spellId,
                          (unsigned long long)targetGuid);
        }
        return al ? 1 : 0;
    }
    RL::Log::Warn("SafeNativeCast AV 0x%08X spell=%d", (unsigned)g.Code(), spellId);
    return -1;
}

// --- Spell_C internal gate diagnostics — PURE MEMORY READS (2026-08-02) ---
// SAFETY FIX (1.10.68): the diagnostics used to CALL game functions from the
// Lua bridge (0x53BD10 known, 0x8009B0 usable, 0x5191C0 canCast, 0x809610 /
// 0x739650 / 0x80C790 gates, 0x4CFD20 spell lookup, 0x74BA40 "unit busy").
// Two hard problems (verified 2026-08-02):
//   1) 0x74BA40 is NOT a function — a dump of Ascension.exe shows a wide-char
//      XML/UI string at that RVA (" />..." = 22 00 20 00 2F 00 3E 00 ...).
//      Calling it EXECUTES the string as code: `00 00` = add [eax],al writes
//      zeros wherever eax points, silently corrupting memory until a stray
//      0xC3 returns. Live crash (1.10.67, 12:50:32): eip=0x68D4785A = our
//      Guard::Scope longjmp-recovery (RVA 0x785A), fault=0x48, stack-saved
//      `this` clobbered to 0 — the garbage write corrupted our frame, the VEH
//      guard caught a later AV, and the recovery itself faulted.
//   2) The real gates have SIDE EFFECTS: 0x5191C0 pops "can't do that" on its
//      fail path; 0x80C790 WRITES [0xD3F4E0] (commit state). Calling them from
//      diagnostics alters client state and costs the main thread.
// FIX: every diagnostic now reads the SAME globals those functions read/write
// DIRECTLY (VirtualQuery-guarded Mem::Read, ~ns each, zero side effects, zero
// crash risk, no Guard needed). All log lines are preserved; the refusing-gate
// value itself is logged. The active cast fix ([0xD4139C] save/zero/restore in
// CastSpell) is unchanged.
//
// Verified state mappings (RE 2026-08-02):
//   canCast(2) (0x5191C0)      -> returns 0 iff [0xD4139C] != 0 (PROVEN gate)
//   unit busy (0x74BA40 proxy) -> unit+0xA6C casting spell id (UnitCastingInfo
//                                  handler 0x611DF0 reads the same field)
//   commit state (0x80C790)    -> [0xD3F4E0] + pending [0xBD07B0/B4] + [0xD3F4E4]
//   spell known (0x53BD10)     -> spell-table slot present (0x4CFD20 source)
//   spell usable (0x8009B0)    -> entry present + flag 0x40 clear
//   secure flags               -> [0xBD1AE0/EC/F0/FC] + mask bit 5

constexpr uintptr_t kCastStateGlob  = 0x00D3F4E0; // commit state
constexpr uintptr_t kPendingCastLo  = 0x00BD07B0; // commit "pending" GUID lo
constexpr uintptr_t kPendingCastHi  = 0x00BD07B4; // commit "pending" GUID hi
constexpr uintptr_t kCastRecordOut  = 0x00D3F4E4; // cast record (0 = none)

// Pure-read spell-table entry — mirrors 0x4CFD20's lookup WITHOUT calling it:
// [0xAD49D0+0x10]=minSpell, +0xC=maxSpell, +0x20=table, entry=[tbl+(id-min)*4].
// Returns 1 found (out fields set), 0 slot null, -1 range/table bad.
constexpr uintptr_t kSpellTableGlob = 0x00AD49D0;
static int SpellTableEntryRead(uint32_t spellId, uint8_t* flagByteOut,
                               uint32_t* attr28Out, uint32_t* entryPtrOut) {
    uint32_t minS = Mem::Read<uint32_t>(kSpellTableGlob + 0x10);
    uint32_t maxS = Mem::Read<uint32_t>(kSpellTableGlob + 0xC);
    uint32_t tbl  = Mem::Read<uint32_t>(kSpellTableGlob + 0x20);
    if (!tbl || tbl < 0x10000u || spellId < minS || spellId > maxS)
        return -1;
    uint32_t slot = Mem::Read<uint32_t>(tbl + (spellId - minS) * 4);
    if (!slot || slot < 0x10000u)
        return 0;
    if (entryPtrOut) *entryPtrOut = slot;
    if (flagByteOut) *flagByteOut = Mem::Read<uint8_t>(slot + 0x10);
    if (attr28Out)   *attr28Out   = Mem::Read<uint32_t>(slot + 0x28);
    return 1;
}

// LIVE per-ability spell data (SpellInfoLive / SpellMeleeInfo) moved to
// game/SpellDB.cpp (2026-08-02) -- pure-memory decode of the client's loaded
// Spell.dbc records + range store. See SpellDB.h.

// Deep gate summary — every value is a DIRECT read of the state the real
// gates consume (identical info to the old 7 game-function calls, zero cost).
static void CastGatesDeepDiag(uint32_t spellId, uint64_t targetGuid) {
    (void)targetGuid;
    uint8_t flagByte = 0;
    uint32_t attr28 = 0, entryPtr = 0;
    int rc = SpellTableEntryRead(spellId, &flagByte, &attr28, &entryPtr);
    int known = (rc == 1) ? 1 : 0;
    int usable = (rc == 1 && !(flagByte & 0x40)) ? 1 : 0;
    uint32_t asGlob = Mem::Read<uint32_t>(kActionStateGlob);
    int canCast = (asGlob == 0) ? 1 : 0;          // proven 0x5191C0(2) mapping
    uint32_t castState = Mem::Read<uint32_t>(kCastStateGlob);
    uint32_t pendLo    = Mem::Read<uint32_t>(kPendingCastLo);
    uint32_t pendHi    = Mem::Read<uint32_t>(kPendingCastHi);
    uint32_t castRec   = Mem::Read<uint32_t>(kCastRecordOut);
    RL::Log::Warn(
        "CastGatesDeep spell=%u known=%d usable=%d canCast=%d "
        "castState=0x%08X pend=0x%08X%08X rec=%u d4139c=0x%08X",
        spellId, known, usable, canCast, castState, pendHi, pendLo, castRec, asGlob);
}

// --- Spell_C internal lookup diagnostic (pure read) ---
// RE-verified: Spell_C's real logic (0x80CCE0) looks the spell up in the
// client's spell table and checks [obj+0x10]&0x40; on EITHER failure it
// returns WITHOUT casting (the silent no-op behind "cast=0" in the POST
// verify). Same data, read directly — no 0x4CFD20 call needed to read the
// entry's flag/attr bytes.
static int SpellCLookupDiag(uint32_t spellId, int* flagByteOut, uint32_t* attr28Out) {
    uint8_t flagByte = 0;
    uint32_t attr28 = 0, entryPtr = 0;
    int rc = SpellTableEntryRead(spellId, &flagByte, &attr28, &entryPtr);
    if (rc < 0) {
        if (flagByteOut) *flagByteOut = -1;
        RL::Log::Warn("SpellCLookupDiag spell=%u TABLE_BAD/RANGE", spellId);
        return -1;
    }
    if (rc == 0) {
        if (flagByteOut) *flagByteOut = -1;
        RL::Log::Warn("SpellCLookupDiag spell=%u SLOT_NULL", spellId);
        return -1;
    }
    if (flagByteOut) *flagByteOut = (int)flagByte;
    if (attr28Out)   *attr28Out   = attr28;
    RL::Log::Warn("SpellCLookupDiag spell=%u rc=%d obj[0x10]=0x%02X (0x40=%d) attr28=0x%08X entry=0x%08X",
                  spellId, 1, flagByte, (flagByte & 0x40) ? 1 : 0, attr28, entryPtr);
    return 1;
}

// --- Spell_C deeper gate diagnostics — PURE MEMORY READS ---
// The next gates inside 0x80CCE0 (after lookup + flag 0x40):
//   - unit busy gate: player/target +0xA6C casting spell id (0 = idle) — the
//     verified UnitCastingInfo field, read directly. (The old "0x74BA40"
//     call was an XML string in the image — executing it corrupted memory.)
//   - [0xd3f4e0]: commit-gate state (sign test before the cast commit).
//   - [0xbd07b0]|[0xbd07b4]: commit-gate "pending cast" GUID pair.
//   - [0xd3f4e4]: cast record (0 = none).
static int CastGatesDiag(uint32_t spellId, uint64_t targetGuid,
                         uint32_t spellAttr28) {
    uintptr_t player = PlayerPtr();
    int playerBusy = -1;
    if (player)
        playerBusy = Mem::Read<uint32_t>(player + 0xA6C) ? 1 : 0;
    int targetBusy = -1;
    uintptr_t tgtObj = targetGuid ? ObjectPtr3(targetGuid, 0x18) : 0;
    if (tgtObj)
        targetBusy = Mem::Read<uint32_t>(tgtObj + 0xA6C) ? 1 : 0;
    uint32_t castState = Mem::Read<uint32_t>(kCastStateGlob);
    uint32_t pendLo    = Mem::Read<uint32_t>(kPendingCastLo);
    uint32_t pendHi    = Mem::Read<uint32_t>(kPendingCastHi);
    uint32_t castRec   = Mem::Read<uint32_t>(kCastRecordOut);

    RL::Log::Warn(
        "CastGates spell=%u attr28=0x%08X playerBusy=%d tgtBusy=%d "
        "castState=0x%08X pend=0x%08X%08X rec=%u",
        spellId, spellAttr28, playerBusy, targetBusy,
        castState, pendHi, pendLo, castRec);
    return (playerBusy == 1) ? 1 : (targetBusy == 1) ? 2 : 0;
}

// --- Secure-action flag diagnostic — PURE READS ONLY (2026-08-02) ---
// (constants kSecureFlagA/B, kSecureMaskA/B live at namespace scope above)
// flagB=256 (armed) live — the secure system IS armed. The 1.10.66 "arm set
// B + retry" write is DELETED: writing secure flags from the bridge is an
// unsafe game-state mutation, and the true refusing gate was [0xD4139C]
// (fixed in CastSpell). Reads only.
static void SecureActionDiag(uint32_t spellId, uint64_t targetGuid) {
    (void)targetGuid;
    uint32_t flagA = Mem::Read<uint32_t>(kSecureFlagA);
    uint32_t flagB = Mem::Read<uint32_t>(kSecureFlagB);
    uint32_t maskA = Mem::Read<uint32_t>(kSecureMaskA);
    uint32_t maskB = Mem::Read<uint32_t>(kSecureMaskB);
    uint32_t bit5A = 0, bit5B = 0;
    if (maskA && maskA < 0x80000000u)
        bit5A = (Mem::Read<uint32_t>(maskA) >> 5) & 1;
    if (maskB && maskB < 0x80000000u)
        bit5B = (Mem::Read<uint32_t>(maskB) >> 5) & 1;
    RL::Log::Warn(
        "SecureDiag spell=%u flagA=%u flagB=%u maskA=0x%08X maskB=0x%08X bit5A=%d bit5B=%d",
        spellId, flagA, flagB, maskA, maskB, bit5A, bit5B);
}

// --- Cast-refusal gate diagnostic (2026-08-02) ---
// CONFIRMED via live CastGatesDeep: the refusing gate is 0x5191C0(2)
// (canCast=0). That function returns 0 whenever [0xD4139C] != 0:
//   mode 2 (our spells) -> jump-table case 0 (0x5191E7) -> unconditional 0
//   when [0xD4139C] != 0 (when it's 0, `je 0x519239` -> return 1 = pass).
// Spell_C then does `je 0x80d249` -> silent refusal (al=0). [0xD4139C] is a
// reentrancy-guarded action/error-state global. THE FIX is now applied in
// CastSpell (zero it around the cast, save/restore) — this function only
// LOGS the state for verification (no retry: retrying in the POST block on
// top of the fixed main cast would double-cast).

static void CastGateFix(uint32_t spellId, uint64_t targetGuid) {
    (void)targetGuid;
    uint32_t asGlob = Mem::Read<uint32_t>(kActionStateGlob);
    uintptr_t obj = Mem::Read<uintptr_t>(0x00BD078C);
    uint32_t obj124c = 0, obj1250 = 0;
    if (obj && obj < 0x7FFFFFFF) {
        obj124c = Mem::Read<uint32_t>(obj + 0x124C);
        obj1250 = Mem::Read<uint32_t>(obj + 0x1250);
    }
    RL::Log::Warn("CastGateFix spell=%u d4139c=0x%08X obj078c=0x%08X obj+124c=0x%08X obj+1250=0x%08X",
                  spellId, asGlob, (unsigned)obj, obj124c, obj1250);
}

constexpr uintptr_t kJumpOrAscendStart  = 0x005FBF80;
constexpr uintptr_t kAscendStop         = 0x005FC0A0;
// SitStandOrDescendStart: on land sit/stand; in water = swim down.
// Address from AscensionLuaHandlers (FrameScript command table).
constexpr uintptr_t kSitStandOrDescendStart = 0x0051B1D0;
constexpr uintptr_t kDescendStop        = 0x005FC140;  // adjacent to AscendStop
constexpr uintptr_t kMoveForwardStart   = 0x005FC200;
// Swim/fly pitch (verified AscensionLuaHandlers.h:1823-1826; the same natives
// back VehicleAimUp/Down). Hold-style input like every other movement key.
constexpr uintptr_t kPitchUpStart       = 0x005FC8E0;
constexpr uintptr_t kPitchUpStop        = 0x005FC570;
constexpr uintptr_t kPitchDownStart     = 0x005FC920;
constexpr uintptr_t kPitchDownStop      = 0x005FC5C0;
constexpr uintptr_t kMoveForwardStop    = 0x005FC250;
constexpr uintptr_t kMoveBackwardStart  = 0x005FC290;
constexpr uintptr_t kMoveBackwardStop   = 0x005FC2E0;
constexpr uintptr_t kTurnLeftStart      = 0x005FC320;
constexpr uintptr_t kTurnLeftStop       = 0x005FC360;
constexpr uintptr_t kTurnRightStart     = 0x005FC3B0;
constexpr uintptr_t kTurnRightStop      = 0x005FC3F0;
constexpr uintptr_t kStrafeLeftStart    = 0x005FC440;
constexpr uintptr_t kStrafeLeftStop     = 0x005FC490;
constexpr uintptr_t kStrafeRightStart   = 0x005FC4D0;
constexpr uintptr_t kStrafeRightStop    = 0x005FC520;

// --- Mouselook / camera-yaw steering (RE-verified 2026-07-23) ---
// The ONLY analog/variable turn in the engine is mouselook: hold it, and the
// camera+character yaw follow mouse-X continuously (with the client's own easing).
// The keyboard TurnLeft/Right just set a flag integrated at ONE fixed rate.
constexpr uintptr_t kMouselookStart     = 0x005FCC10;  // cdecl, no args (reads globals)
constexpr uintptr_t kMouselookStop      = 0x005FC890;  // cdecl, no args
constexpr uintptr_t kMovementApply      = 0x005FBBC0;  // __thiscall(ctrl, [0xB499A4], 1)
constexpr uintptr_t kInputCtrlPtr       = 0x00C24954;  // *ptr = input controller
constexpr uintptr_t kInputTimePtr       = 0x00B499A4;  // arg the native handlers push
constexpr uintptr_t kWorldFramePtr      = 0x00B7436C;  // *(*+0x7E20) = camera object
constexpr uintptr_t kCamPtrOffset       = 0x7E20;
constexpr uintptr_t kInputFlagsOff      = 0x04;        // ctrl+4: mouselook bits live here
constexpr uint32_t  kMouselookBits      = 0x2000001;   // (0x1 | 0x2000000)
constexpr uintptr_t kCamAppliedYaw      = 0x120;       // smoothed/current camera yaw (rad)
constexpr uintptr_t kCamTargetYaw       = 0x230;       // target yaw the client eases toward
constexpr uintptr_t kCamAppliedPitch    = 0x11C;
constexpr uintptr_t kCamTargetPitch     = 0x260;

// --- In-process yaw turn (RE-verified 2026-07-23) - the CLEAN way to rotate the
// character without touching the OS mouse or capturing the cursor. This is the
// exact per-frame function the keyboard turn keys call; it reads the current
// facing, adds our delta, commits via the real SetFacing path (renders + sends
// MSG_MOVE_SET_FACING to the server). MUST be called on the game/main thread.
constexpr uintptr_t kTurnByDelta        = 0x005FB4B0;  // __thiscall(ctrl, token, float deltaRad); +delta = left/CCW
constexpr uintptr_t kCtrlFacingValid    = 0x4C;        // ctrl+0x4C != 0 => ctrl+0x50 is the cached (stale) facing
constexpr uintptr_t kCtrlFacing         = 0x50;
constexpr uintptr_t kVtblGetFacing      = 0x14C;       // player vtable[0x14C] = GetFacing() -> float (st0)
constexpr uintptr_t kPlayerFacingLive   = 0x7AC;       // CMovement+0x24: the LIVE local-player facing (rad)

using fnApply = int(__thiscall*)(void* ecx, void* p, int a);
using fnTurnByDelta = void(__thiscall*)(void* ctrl, int token, float deltaRad);
using fnGetFacing = float(__thiscall*)(void* self);

static bool g_armed = false;
static int g_cast_ok = 0;
static int g_cast_fail = 0;
// g_currentL is defined above (before SafeFSExec) — see declaration.

} // namespace

void SoftHardwareUnlock() {
    // NO-OP (2026-08-01, FINAL). BOTH hardware-event manipulation methods are
    // PROVEN to corrupt the game's Lua VM → AV_WRITE crash:
    //   - .text JE->JMP/JNE->NOP2 patches (1.10.46): AV_WRITE in game code.
    //   - writing *HardwareEventFlag=1 (1.10.48): AV_WRITE at a garbage eip
    //     (Lua closure-table corruption; stack = game Lua VM + FrameScript).
    // Disassembly PROVES Spell_C_CastSpell (0x80DA40 -> real logic 0x80CCE0)
    // never references 0x00C21000 — the hardware flag gates only the Lua QUERY
    // handlers (IsUsableSpell/IsSpellInRange). Native casts need NO unlock.
    // The addon treats nil/0 query answers as UNKNOWN (never blocks) and uses
    // the runtime's precise measurement for range. So: no flag writes, no .text
    // patches, no TaintContext — native Spell_C only.
}

namespace {

static uint64_t ActiveGuid() {
    auto fn = reinterpret_cast<fnGetActive>(Addr::ClntObjMgrGetActivePlayer);
    if (!fn) return 0;
    Guard::Scope g;
    if (!g.Caught()) {
        return fn();
    }
    return 0;
}

static uintptr_t ObjectPtr3(uint64_t guid, int mask) {
    auto fn = reinterpret_cast<fnObjectPtr3>(Addr::ClntObjMgrObjectPtr);
    if (!fn || !guid) return 0;
    uint32_t lo = (uint32_t)guid;
    uint32_t hi = (uint32_t)(guid >> 32);
    Guard::Scope g;
    if (!g.Caught()) {
        return fn(lo, hi, mask);
    }
    return 0;
}

static uintptr_t PlayerPtr() {
    // A) Main-thread snapshot
    auto snap = MainThread::Get();
    if (snap.playerPtr) return snap.playerPtr;

    // B) GetActivePlayer + ObjectPtr(lo,hi,mask)
    uint64_t g = ActiveGuid();
    if (g) {
        uintptr_t p = ObjectPtr3(g, -1);
        if (p) return p;
        p = ObjectPtr3(g, 0x18); // UNIT|PLAYER
        if (p) return p;
        p = ObjectPtr3(g, 0x10); // PLAYER only
        if (p) return p;
    }

    // Path C removed: the literal 0x00C7B098 was documented as "common 3.3.5
    // player ptr" but was NEVER verified for Ascension Live. Any garbage
    // above 0x10000 at that address would be accepted as a valid CGPlayer*
    // and passed to CTM/InteractGuid, dereferencing an attacker-controlled
    // vtable slot. Fall through to OM::LocalPtr which routes via the
    // verified GetActivePlayer + ObjectPtr commit-checked path.
    return OM::LocalPtr();
}

// CRASH RULE (permanent): ALL nested Lua re-entry from the bridge is deleted.
// Both FrameScript_Execute (1.10.19-castsafe: ERROR #132) AND nested
// lua_getfield+lua_pcall (1.10.43: Lua stack corruption → eip=0 in the game
// VM) hard-crash the client when invoked from inside Lua_IsLinuxClient.
// There are no LuaGlobal0/S/N helpers, no CastViaLuaPCall, no SafeScript
// fallback. Every bridge action is either a native client call (Spell_C,
// descriptor writes, handler calls) or a no-op. The addon does all Lua-side
// work in its own safe Lua context.

} // namespace

void ArmUnlock() {
    SoftHardwareUnlock();
    if (!g_armed) {
        g_armed = true;
        RL::Log::Warn("Actions: armed hwflag=0x%08X (taint writes disabled)",
                      (unsigned)Addr::HardwareEventFlag);
    }
}

// Forward decls — restore helpers are defined later in this file.
bool ClearTarget();
bool TargetGuid(uint64_t guid);
bool TargetLastTarget();

// CLIENT'S SELECTED TARGET GLOBAL (2026-08-02): the game's ClearTarget handler
// (0x525FC0) reads/writes the current target GUID at 0xBD07B0 (lo) / 0xBD07B4
// (hi) — this is what UnitGUID("target") returns and what the target frame
// renders. Writing ONLY the player's UNIT_FIELD_TARGET descriptor (desc+0x48)
// left the VISIBLE target on the cast victim (force-acquire, live 15:55: cast
// at tgt=n -> tgt=yes persisted). All selection reads/writes now go through
// this global so the client target truly restores.
constexpr uintptr_t kClientTargetGuid = 0x00BD07B0;

static uint64_t ReadClientTargetGuid() {
    uint64_t g = Mem::Read<uint64_t>(kClientTargetGuid);
    if (g) return g;
    // Fall back to UNIT_FIELD_TARGET descriptor (server-synced target).
    uintptr_t p = PlayerPtr();
    if (!p) return 0;
    uintptr_t d = Mem::Read<uintptr_t>(p + Offsets::O().Descriptor);
    if (!d || d < 0x10000u) return 0;
    return Mem::Read<uint64_t>(d + 0x48);
}

// Write BOTH the client selection global (0xBD07B0, what UnitGUID("target")
// reads) AND UNIT_FIELD_TARGET (desc+0x48, what Spell_C's melee path resolves
// against). Restoring only one left the victim visibly targeted.
// VirtualQuery-guarded; safe.
static bool WriteClientTargetGuid(uint64_t guid) {
    uint32_t lo = (uint32_t)guid;
    uint32_t hi = (uint32_t)(guid >> 32);
    Mem::Write<uint32_t>(kClientTargetGuid, lo);
    Mem::Write<uint32_t>(kClientTargetGuid + 4, hi);
    uintptr_t p = PlayerPtr();
    if (!p) return true;
    uintptr_t d = Mem::Read<uintptr_t>(p + Offsets::O().Descriptor);
    if (!d || d < 0x10000u) return true;
    Mem::Write<uint64_t>(d + 0x48, guid);
    return true;
}

// DESCRIPTOR-ONLY write (UNIT_FIELD_TARGET, desc+0x48) — the SERVER-synced
// target field. Safe to write immediately after Spell_C: it does NOT touch the
// client selection global (0xBD07B0) that UnitGUID("target") / the target
// frame / the client's cast-feedback UI read. Writing 0xBD07B0 mid-cast
// corrupted the client's target state under the game UI (live: Ascension's own
// Core-Core.lua threw "attempt to index field '?' (a nil value)" x8 after the
// immediate 0xBD07B0 restore raced the in-flight cast). The 0xBD07B0 restore
// is now deferred to PulseSelectionRestore (runs only when NOT casting).
static bool WriteDescriptorTargetOnly(uint64_t guid) {
    uintptr_t p = PlayerPtr();
    if (!p) return false;
    uintptr_t d = Mem::Read<uintptr_t>(p + Offsets::O().Descriptor);
    if (!d || d < 0x10000u) return false;
    return Mem::Write<uint64_t>(d + 0x48, guid);
}

// The player's UNIT_FIELD_TARGET descriptor address, or 0 if unreadable.
// Used by the zero-frame-acquire path to read/pin/restore the cast target
// descriptor around a guid=0 Spell_C.
static uintptr_t DescriptorOfPlayer() {
    uintptr_t p = PlayerPtr();
    if (!p) return 0;
    uintptr_t d = Mem::Read<uintptr_t>(p + Offsets::O().Descriptor);
    if (!d || d < 0x10000u) return 0;
    return d + 0x48;
}

// True while the player has a REAL cast in flight (same rule as GameState:
// casting field non-zero AND end-time in the future). Used to defer the
// client-selection restore until the client is not mid-cast.
static bool ClientCastingInProgress() {
    int id = RL::Game::State::CastingSpellId();
    if (id <= 0) return false;
    int64_t end = RL::Game::State::CastingEndMs();
    int64_t now = RL::Game::State::GameTimeMs();
    if (end <= 0 || now < 0) return false;   // fail open: cannot prove casting
    return now < end;
}

// Restore selection field after Spell_C. Descriptor only — never TargetUnit
// from the cast wire (mid-combat nested pcall crash). The client-selection
// global (0xBD07B0) is NOT written here (mid-cast race) — PulseSelectionRestore
// does that once the cast settles.
static void RestoreSelectionAfterCast(uint64_t prevTarget, uint64_t castVictim) {
    WriteDescriptorTargetOnly(prevTarget);
    (void)castVictim;
}

// ---- Delayed selection restore ("cast without targeting", 2026-08-02) ------
// Spell_C(guid) SELECTS the cast victim as the client target ASYNC — the pick
// lands NEXT frame. The immediate post-cast restore (ReadClientTargetGuid right
// after Spell_C) sees the OLD selection (pick not landed) and skips, so the
// victim STAYS targeted: the aura-search force-acquire with acquire OFF (live
// 15:40: cast at tgt=n -> victim stuck as the visible target). This records the
// victim + the pre-cast selection and applies the restore on EVERY Pulse (next
// bridge call ~ the same frame the async pick lands), so the client target
// never stays on the victim. It only writes back when the current selection is
// STILL the victim — a manual player target is never stomped.
struct PendingSelRestore {
    uint64_t victim;
    uint64_t restoreTo;
    ULONGLONG untilMs;      // absolute deadline (window expiry)
    ULONGLONG armedMs;      // when the restore was armed (min-hold anchor)
};
static PendingSelRestore g_pendingSel = { 0, 0, 0, 0 };

// 2026-08-02 (13:41 CRASH — 0x512B07 RE-INTRODUCED, ROOT CAUSE): the deferred
// restore ran in the SAME native tick as the cast. TickHookBody calls
// DrainCastQueue() then PulseSelectionRestore() back-to-back. For an INSTANT
// spell (Icy Touch 45477) ClientCastingInProgress() is false the instant
// Spell_C returns, so PulseSelectionRestore cleared 0xBD07B0 to 0 (restoreTo)
// on the same frame the cast-feedback was resolving the just-accepted cast's
// target GUID -> stale pointer -> 0x512B07 (live: SafeNativeCast rc=1, then
// crash 6ms later, crash.state bd07b0=0). The 13:27/13:29 sessions survived
// because the old facing gate delayed the cast ~1.5s, so by the time the cast
// fired the previous restore had expired (600ms window) and never re-armed in
// the same tick. Gate v4 + range fix fire on the FIRST tick -> every cast hit
// the race. FIX: MINIMUM-HOLD — never write the client selection global for
// kSelRestoreMinHoldMs after arming, regardless of casting state. The client's
// cast-feedback walk resolves the cast target GUID from the 0xD3C00E14 static
// slot; 100ms is the proven-safe hold (the 15:22 session at 100ms had ZERO
// 0x512B07 SHIELD AVs; the 17:26 session at 40ms had 129 — the 40ms restore
// raced the still-active walk and re-armed the resolver AV). Acquire-off casts
// (1.10.81 NOREG) are direct-GUID with NO selection change, so no restore is
// armed for them at all — the unitframe is never touched. This 100ms hold is
// the safety baseline for any legacy/acquire-on path that does arm a restore.
constexpr ULONGLONG kSelRestoreMinHoldMs = 100;
constexpr ULONGLONG kSelRestoreWindowMs = 600;

void PulseSelectionRestore() {
    if (!g_pendingSel.victim) return;
    ULONGLONG now = GetTickCount64();
    if (now > g_pendingSel.untilMs) {
        g_pendingSel.victim = 0;
        return;
    }
    // 2026-08-02 (MIN-HOLD, 0x512B07 fix): never restore within the minimum
    // hold window after arming. This is the SAME-tick-race guard — without it
    // an instant-cast (ClientCastingInProgress()==false immediately) let the
    // restore clear 0xBD07B0 while the client's cast-feedback was still
    // resolving the accepted cast's target -> 0x512B07 (13:41 crash).
    if (now < g_pendingSel.armedMs + kSelRestoreMinHoldMs) return;
    // 2026-08-02 (SAFETY): never write the client selection global mid-cast —
    // the client's cast-feedback UI (target frame, Ascension Core-Core.lua)
    // reads 0xBD07B0 during a cast; flipping it under that code crashed the UI
    // ("attempt to index field '?' (a nil value)"). Wait until the cast
    // settles (or the window expires) before restoring. For instant-cast GCD
    // abilities the cast window is one frame, so the visible acquire is ~1
    // frame — then the selection reverts ("cast without targeting").
    if (ClientCastingInProgress()) return;
    uint64_t cur = ReadClientTargetGuid();
    if (cur == g_pendingSel.victim) {
        // One-time diag proving the restore lands AFTER the min-hold window
        // (never same-tick as the cast) — the 0x512B07 same-tick-race guard.
        static volatile LONG s_restoreDiag = 0;
        if (InterlockedCompareExchange(&s_restoreDiag, 1, 0) == 0) {
            RL::Log::Warn("SelectionRestore applied victim=0x%llX -> 0x%llX "
                          "holdMs=%llu",
                          (unsigned long long)g_pendingSel.victim,
                          (unsigned long long)g_pendingSel.restoreTo,
                          (unsigned long long)(now - g_pendingSel.armedMs));
        }
        WriteClientTargetGuid(g_pendingSel.restoreTo);
    }
    // A few frames of grace, then disarm even if it never landed (target
    // stayed put — nothing to do).
    if (now > g_pendingSel.untilMs - 100) {
        g_pendingSel.victim = 0;
    }
}

static void ArmSelectionRestore(uint64_t victim, uint64_t restoreTo) {
    g_pendingSel.victim = victim;
    g_pendingSel.restoreTo = restoreTo;
    g_pendingSel.armedMs = GetTickCount64();
    g_pendingSel.untilMs = g_pendingSel.armedMs + kSelRestoreWindowMs;
}

bool CastSpell(int spellId, uint64_t targetGuid, uint32_t flags) {
    if (spellId <= 0) return false;
    SoftHardwareUnlock();
    if (!Taint::HardwareGatesApplied())
        Taint::ApplyHardwareGatesOnly();
    MainThread::PulseFromMainThread();

    lua_State* L = g_currentL;
    // Success path is Trace-only (Warn every cast spiked FPS under RL_LOG=1).
    RL::Log::Trace("CastSpell enter id=%d guid=0x%llX L=%p hw=%d",
                   spellId, (unsigned long long)targetGuid, (void*)L,
                   (int)Taint::HardwareGatesApplied());

    // Readiness is Lua-side (Executor GetSpellCooldown). Do NOT nested-pcall
    // GetSpellCooldown here — extra VM re-entry during IsLinuxClient is avoidable
    // risk; the melee pin below is the cast-target authority fix.

    uint64_t prev = ReadClientTargetGuid();

    // RUNTIME AUTHORITY: any non-zero GUID cast is Spell_C(guid) ONLY.
    // Never demote multi-dot / GUID casts to stock CastSpellByID (client target).
    //
    // ACQUIRE-OFF (fundamental): do NOT write UNIT_FIELD_TARGET before cast.
    // That field IS client selection — pinning it force-acquired the multi-dot
    // victim (live: pin=1 whenever prev!=guid). Acquire ON is Lua Target first.
    // CRASH FIX: never TargetUnit/ClearTarget from inside CastSpell (ERROR #132).
    // After Spell_C, if selection stuck on victim, restore descriptor only.
    // guid==0 = self / ground / current-target via native Spell_C only.
    //
    // 2026-08-02 CONFIRMED FIX: canCast(2) (0x5191C0) refuses EVERY cast while
    // [0xD4139C] != 0 — a reentrancy-guarded client action-state global that is
    // stuck non-zero here (observed 0x383D69E8 across every cast). The client
    // itself zeroes it during its own action processing (0x48EC50, save/restore
    // guarded by [0xD413A0]/[0xD413A4]).
    //
    // 2026-08-02 (FINAL FIX): NEVER restore the stuck non-zero value. The old
    // "restore only if the client did not take ownership" re-armed the canCast
    // refusal for every subsequent cast — SafeNativeCast intermittently refused
    // (al=0 -> cast_fail -> 1s busy-backoff -> rotation freeze mid-combat).
    // The action-state (canCast busy gate) save/zero/restore now lives inside
    // SafeNativeCast (the client's own 0x48EC20 pattern) — never a bare write.
    // registerTarget: SafeNativeCast registers the target via the client's real
    // setter (0x524BF0) then casts Spell_C(0) on it (raw-GUID Spell_C crashes).
    // 2026-08-02 (17:26 — 1.10.81 NOREG, ROOT CAUSE): the 129x 0x512B07 SHIELD
    // fires with esi=0xD3C00E14 (constant) proved the walk reads the cast
    // target GUID from a STATIC slot at 0xD3C00E14 in the client's UNCOMMITTED
    // .data BSS tail. SafeNativeCast now COMMITS that page and writes the
    // victim's GUID into the slot before Spell_C, so the feedback resolver
    // (ObjectPtr mask 8) finds the victim and the walk completes cleanly —
    // WITHOUT selecting it as the client target. Acquire-off therefore casts
    // DIRECT-GUID with registerTarget=0: the unitframe is NEVER touched, no
    // restore is needed, and the walk no longer AVs. Acquire-ON still
    // registers (the player wants the unitframe to follow the victim).
    if (targetGuid != 0) {
        int nrc;
        if (flags & kCastNoTargetChange) {
            nrc = SafeNativeCast(spellId, targetGuid, 0);          // direct-GUID, no selection touch
        } else {
            nrc = SafeNativeCast(spellId, targetGuid, targetGuid); // acquire-on: register + Spell_C(GUID)
        }
        // 2026-08-02 (CRASH FIX — 22:42 PROOF): NEVER write UNIT_FIELD_TARGET
        // (desc+0x48) synchronously from the bridge, in ANY form. The plain
        // CastSpell(guid) path's `WriteDescriptorTargetOnly(prev)` here — when
        // selection moved — crashed 0x512B07 the SAME way CastSpellNoAcquire
        // did (proven live 22:42: SafeNativeCast rc=1 id=45477
        // guid=0xF1300005E5017795, then 0x512B07 7ms later, "force acquired
        // then crashed"). The descriptor IS selection on this client, and
        // writing it synchronously around Spell_C's async cast-resolve
        // corrupts the game's Lua VM. The ONLY safe revert is the DEFERRED
        // PulseSelectionRestore (runs on the next MainThread Pulse, only when
        // NOT casting, VEH-guarded) — the mechanism proven stable at 17:51.
        // No synchronous descriptor/0xBD07B0 write here, ever.
        uint64_t nowSel = ReadClientTargetGuid();
        (void)nowSel;
        if (nrc > 0) {
            g_cast_ok++;
            // 2026-08-02 (14:09 UNITFRAME FIX): acquire-off casts now use the
            // DIRECT-GUID path (SafeNativeCast(spellId, guid, 0)) which never
            // writes 0xBD07B0 — there is NO selection change and therefore NO
            // restore to arm. Acquire-ON keeps the target (no restore either).
            // The min-hold PulseSelectionRestore machinery remains as a safety
            // net for any legacy register path but is no longer armed here.
            (void)prev;
            (void)targetGuid;
            // Throttle success logs: every 32nd cast (diagnostics without I/O storm).
            if ((g_cast_ok & 31) == 1) {
                RL::Log::Info("CastSpell path=runtime_guid id=%d guid=0x%llX prev=0x%llX ok=%d",
                              spellId, (unsigned long long)targetGuid,
                              (unsigned long long)prev, g_cast_ok);
            }
            return true;
        }
        if (nrc < 0)
            RL::Log::Warn("CastSpell native AV id=%d guid=0x%llX",
                          spellId, (unsigned long long)targetGuid);
        g_cast_fail++;
        RL::Log::Warn("CastSpell FAIL runtime_guid id=%d fail=%d", spellId, g_cast_fail);
        return false;
    }

    // guid==0: self / ground / current target via native Spell_C ONLY.
    // CRASH RULE (permanent): CastViaLuaPCall (nested lua_pcall of
    // CastSpellByID from inside Lua_IsLinuxClient) and SafeScript FSExec were
    // both proven fatal — nested VM re-entry corrupts the Lua stack → eip=0
    // in the game VM. Spell_C(0) casts on the current target/self natively.
    int nrc = SafeNativeCast(spellId, 0);
    // Same as the GUID path: leave [0xD4139C] at 0 (do not re-arm the stuck
    // value — that was the intermittent cast_fail / rotation-freeze source).
    if (nrc > 0) {
        g_cast_ok++;
        RL::Log::Info("CastSpell path=native_self id=%d ok=%d", spellId, g_cast_ok);
        return true;
    }
    if (nrc < 0)
        RL::Log::Warn("CastSpell native AV id=%d", spellId);
    g_cast_fail++;
    RL::Log::Warn("CastSpell FAIL self id=%d fail=%d", spellId, g_cast_fail);
    return false;
}

void SetCurrentLuaState(void* L) { g_currentL = reinterpret_cast<lua_State*>(L); }

// Normalize angle delta into (-pi, pi].
static float NormPi(float d) {
    const float pi = 3.14159265f;
    const float two = 6.2831853f;
    while (d > pi) d -= two;
    while (d < -pi) d += two;
    return d;
}

// Returns: 1 = facing, 0 = not facing (measured), -1 = undetermined (no positions).
// Callers that must not spam "in front" only skip when result == 0.
// Undetermined must NOT block multi-dot GUID casts (was zero Icy Touch fires).
static int IsFacingGuidEx(uint64_t guid, float halfArcRad) {
    if (!guid) return -1;
    if (halfArcRad <= 0.f) halfArcRad = 1.5707963f;
    uint64_t me = ActiveGuid();
    if (!me) return -1;
    Vec3 pa = OM::Position(me);
    Vec3 pb = OM::Position(guid);
    if ((pa.x == 0.f && pa.y == 0.f) || (pb.x == 0.f && pb.y == 0.f))
        return -1; // cannot measure — do not invent "not facing"
    // 2026-08-02 (POINT-BLANK / 0yd): a target at the player's own position
    // (edge=0yd, the mob being fought) has a degenerate atan2 heading that made
    // the runtime report "not facing" — the "wait facing:Blood Strike x161"
    // freeze. A target at zero distance is never "behind" the player; the
    // client's own arc check accepts it. Treat < 1yd center distance as facing.
    float dx = pb.x - pa.x, dy = pb.y - pa.y;
    if ((dx * dx + dy * dy) < 1.0f) return 1;
    float face = PlayerFacing();
    if (face > 1e8f || face != face)
        face = OM::Facing(me);
    if (face != face || face < -0.01f || face > 12.f)
        return -1;
    // 2026-08-02 (18:16 FACING CONVENTION FIX): atan2 is 0=+X/east CCW; the
    // client's facing (0x7AC) is 0=+Y/north CW. facing_wow = π/2 - atan2(dy,dx).
    float ang = 1.5707963f - std::atan2(pb.y - pa.y, pb.x - pa.x);
    float diff = NormPi(ang - face);
    return (std::fabs(diff) <= halfArcRad) ? 1 : 0;
}

bool IsFacingGuid(uint64_t guid, float halfArcRad) {
    // Legacy bool API: undetermined counts as facing so old callers don't soft-lock.
    int v = IsFacingGuidEx(guid, halfArcRad);
    return v != 0;
}

bool FaceTowardGuid(uint64_t guid) {
    if (!guid) return false;
    SoftHardwareUnlock();
    if (!Taint::HardwareGatesApplied())
        Taint::ApplyHardwareGatesOnly();
    MainThread::PulseFromMainThread();

    uint64_t me = ActiveGuid();
    if (!me) return false;
    Vec3 pa = OM::Position(me);
    Vec3 pb = OM::Position(guid);
    if ((pa.x == 0.f && pa.y == 0.f) || (pb.x == 0.f && pb.y == 0.f))
        return false;

    // Live facing (0x7AC), not stale 0x7A4.
    float face = PlayerFacing();
    if (face > 1e8f || face != face) {
        face = OM::Facing(me);
        if (face != face || face < -0.01f || face > 12.f)
            return false;
    }

    float ang = std::atan2(pb.y - pa.y, pb.x - pa.x);
    float diff = NormPi(ang - face);
    if (std::fabs(diff) <= 0.12f)
        return true; // already on-angle enough for cast cone

    // One TurnByDelta step (capped). Multi-step same-frame caused thrash/crash.
    if (diff > 1.4f) diff = 1.4f;
    if (diff < -1.4f) diff = -1.4f;
    return TurnByDelta(diff);
}

// LoS for optional CHECK_LOS flag. Fail OPEN: only refuse when TraceLineEx
// is DEFINITELY blocked (rc==0). Unknown/throw → allow cast (client is last word).
// TraceLineEx: 1=clear, 0=blocked, -1=unknown.
static bool LosDefinitelyBlocked(uint64_t guid) {
    uint64_t me = ActiveGuid();
    if (!me || !guid) return false;
    Vec3 a = OM::Position(me);
    Vec3 b = OM::Position(guid);
    if ((a.x == 0.f && a.y == 0.f) || (b.x == 0.f && b.y == 0.f))
        return false;
    float dx = a.x - b.x, dy = a.y - b.y;
    // Point-blank: model hitboxes false-block TraceLine (live: edge=0yd los refuse).
    if ((dx * dx + dy * dy) < 64.f) // 8 yd
        return false;
    a.z += 2.f;
    b.z += 2.f;
    Vec3 hit{};
    int rc = OM::TraceLineEx(a, b, &hit, 0x100111u);
    return rc == 0; // only hard-block on measured blocked
}

CastGateResult CanCast(int spellId, uint64_t targetGuid, uint32_t flags) {
    CastGateResult r{ false, "no_spell" };
    if (spellId <= 0) return r;
    uint64_t me = ActiveGuid();
    if (!me) { r.reason = "no_player"; return r; }
    // Readiness is Lua Executor GetSpellCooldown — never nested pcall here
    // (1.10.36 nested CD + TraceLine thrash → dead rotation / crash).

    if (targetGuid != 0) {
        Vec3 pb = OM::Position(targetGuid);
        Vec3 pa = OM::Position(me);
        if ((pb.x != 0.f || pb.y != 0.f) && (pa.x != 0.f || pa.y != 0.f)) {
            float dx = pb.x - pa.x, dy = pb.y - pa.y;
            float dist = std::sqrt(dx * dx + dy * dy);
            if (dist > 45.f) { r.reason = "oor"; return r; }
        }

        int face = IsFacingGuidEx(targetGuid, 1.5707963f);
        if (face == 0 && (flags & kCastFaceIfNeeded)) {
            FaceTowardGuid(targetGuid);
            face = IsFacingGuidEx(targetGuid, 1.5707963f);
        }
        // Only refuse when SKIP set AND measured not-facing. Undetermined allows.
        if (face == 0 && (flags & kCastSkipIfNotFacing)) {
            r.reason = "facing";
            return r;
        }
        if ((flags & kCastCheckLos) && LosDefinitelyBlocked(targetGuid)) {
            r.reason = "los";
            return r;
        }
    }

    r.ok = true;
    r.reason = "ok";
    return r;
}

CastGateResult CastSpellEx(int spellId, uint64_t targetGuid, uint32_t flags) {
    CastGateResult r{ false, "no_spell" };
    if (spellId <= 0) return r;

    SoftHardwareUnlock();

    // AUTHORITATIVE BUSY GATE (RE-verified 2026-08-01): before casting any
    // real spell, check the client's own casting state (player+0xA6C + the
    // current-spells list). If a real spell is in progress, the client would
    // reject the cast with "Another action is in progress" — the exact
    // blocked-action spam the rotation produced. Refuse here instead, with a
    // logged reason, so the client is NEVER asked to do something it will
    // reject. Auto-attack (6603) is exempt: it is engaged separately and never
    // arrives through CastSpellEx as a blocking action.
    if (spellId != 6603) {
        char st[32];
        State::CastStatePacked(st, sizeof(st));
        if (std::strcmp(st, "free") != 0 && std::strcmp(st, "attacking") != 0) {
            r.reason = "busy";
            r.busyState = st[0] ? st : "busy";
            // DIAG: raw values so we can see WHY it's busy (casting id / end /
            // now / auto-attack / list entries). Logging the full packed state
            // only on the FIRST busy-refuse after a 5s quiet window, so the
            // repeated 1/s busy refuses don't flood but we still get one full
            // dump when the state changes.
            {
                static volatile LONG g_lastFullDump = 0;
                LONG nowMs = (LONG)(RL::Game::State::GameTimeMs() & 0x7FFFFFFF);
                LONG last = g_lastFullDump;
                if (nowMs - last > 5000 || last == 0) {
                    g_lastFullDump = nowMs;
                    char full[160];
                    State::FullStatePacked(full, sizeof(full));
                    RL::Log::Warn("CastSpellEx busy-refuse id=%d state=%s full=%s",
                                  spellId, st, full);
                }
            }
            return r;
        }
    }
    if (!Taint::HardwareGatesApplied())
        Taint::ApplyHardwareGatesOnly();
    MainThread::PulseFromMainThread();

    // CRASH RULE (permanent): the spell range cache used SpellInfoFromLua
    // (nested lua_getfield+lua_pcall from inside Lua_IsLinuxClient) — proven
    // fatal (Lua stack corruption → eip=0 in game VM). Range is now validated
    // by the addon via Lua-level IsSpellInRange (Lua→Lua, safe) and by the
    // native 45yd gate in CanCast. No C++→Lua pcall here.

    // Pre-cast cooldown gate — pure C++ via live-scanned internal client
    // functions (InternalGetCooldown/InternalGetTime). Zero Lua. Returns 0.0
    // (no gate) if internals were not resolved.
    {
        double cdMs = RL::Lua::SpellCooldownMs(nullptr, spellId);
        if (cdMs > 30.0) { // >30ms → genuinely on cooldown
            r.reason = "cooldown";
            r.cooldownMs = cdMs;
            return r;
        }
    }

    // DIAG (2026-08-01): every CastSpellEx entry, throttled 1/sec per spell so
    // the runtime log shows whether the addon EVER reaches the runtime cast
    // path (live: "nothing casts" + no runtime CastSpellEx lines at all).
    {
        static volatile LONG g_lastCastLog = 0;
        LONG nowMs = (LONG)(RL::Game::State::GameTimeMs() & 0x7FFFFFFF);
        LONG last = g_lastCastLog;
        // Surface the secure-action flag state on the throttled ENTER line so
        // the single most important diagnostic (is set B armed?) is visible on
        // every cast and cannot be buried/truncated away. Reads computed ONLY
        // when logging (1/s) — the hot path stays at ~zero cost.
        if (nowMs - last > 1000 || last == 0) {
            g_lastCastLog = nowMs;
            uint32_t secFlagB = Mem::Read<uint32_t>(kSecureFlagB);
            uint32_t secMaskB = Mem::Read<uint32_t>(kSecureMaskB);
            uint32_t secBit5B = 0;
            if (secMaskB && secMaskB < 0x80000000u)
                secBit5B = (Mem::Read<uint32_t>(secMaskB) >> 5) & 1;
            RL::Log::Warn("CastSpellEx ENTER id=%d tgt=0x%llX flags=%u secB=%u bit5B=%d",
                          spellId, (unsigned long long)targetGuid, flags,
                          secFlagB, secBit5B);
        }
    }

    // Wire path to Spell_C_CastSpell — face/LOS gate + GUID cast.
    if (targetGuid != 0) {
        int face = IsFacingGuidEx(targetGuid, 1.5707963f);
        if (face == 0 && (flags & kCastFaceIfNeeded)) {
            FaceTowardGuid(targetGuid);
            face = IsFacingGuidEx(targetGuid, 1.5707963f);
        }
        if (face == 0 && (flags & kCastSkipIfNotFacing)) {
            r.reason = "facing";
            return r;
        }
        if ((flags & kCastCheckLos) && LosDefinitelyBlocked(targetGuid)) {
            r.reason = "los";
            return r;
        }
    }

    // CastSpell is pin-free Spell_C(guid) + descriptor restore if selection moved.
    // 2026-08-02 (NATIVE CAST CARRIER — user ABSOLUTE DIRECTIVE): the actual
    // Spell_C must NEVER execute on this Lua-dispatched bridge call (0x512B07
    // VM corruption when Spell_C's cast-feedback re-enters FrameScript under a
    // bridge C-closure). All the gates above (busy/cooldown/face/LOS) are pure
    // memory reads — safe here. The CAST ITSELF is STAGED into the native queue
    // and executed by the frame hook (no Lua on the stack). The selection
    // restore is armed in the `if (ok)` block below (deferred, not synchronous).
    uint64_t prev = (targetGuid != 0) ? ReadClientTargetGuid() : 0;
    bool ok = QueueCast(spellId, targetGuid, flags);
    // POST-CAST VERIFY (2026-08-01): did the CLIENT actually begin the cast?
    // Sample the client casting field right after to distinguish a real cast
    // (casting field reflects spellId) from a silently-blocked one.
    // Heavy gate diagnostics are throttled to once per 5s (they call ~15 game
    // functions + write ~10 log lines per cast — that I/O on the main thread
    // is the "massive lag" when they run every cast). The FIX (CastGateFix)
    // still runs every cast — it is the active fix attempt.
    if (spellId != 6603) {
        // POST-CAST VERIFY (2026-08-02): sample the client casting field right
        // after to distinguish a real cast from a silently-blocked one. The
        // state packing + log is throttled to 1/s per cast — running it on
        // EVERY cast (30Hz spam) was a main-thread I/O cost.
        static volatile LONG g_lastPostLog = 0;
        LONG nowMs = (LONG)(RL::Game::State::GameTimeMs() & 0x7FFFFFFF);
        LONG lastPost = g_lastPostLog;
        if (nowMs - lastPost > 1000 || lastPost == 0) {
            g_lastPostLog = nowMs;
            char castbuf[32];
            char fullbuf[160];
            State::CastStatePacked(castbuf, sizeof(castbuf));
            State::FullStatePacked(fullbuf, sizeof(fullbuf));
            RL::Log::Warn("CastSpellEx POST id=%d cast='%s' full=%s",
                          spellId, castbuf, fullbuf);
        }
        // Heavy gate diagnostics: PURE memory reads now (zero game-function
        // calls — the 1.10.67 crash was the old diag calling 0x74BA40, an
        // XML string), throttled to once per 5s. Zero cost when throttled.
        static volatile LONG g_lastDiag = 0;
        LONG lastDiag = g_lastDiag;
        if (nowMs - lastDiag > 5000 || lastDiag == 0) {
            g_lastDiag = nowMs;
            int flagByte = -1;
            uint32_t attr28 = 0;
            int rc = SpellCLookupDiag((uint32_t)spellId, &flagByte, &attr28);
            if (rc == 0 || flagByte == -1)
                RL::Log::Warn("SpellCLookupDiag spell=%d => LOOKUP_FAIL rc=%d",
                              spellId, rc);
            else if (flagByte & 0x40)
                RL::Log::Warn("SpellCLookupDiag spell=%d => FLAG_0x40", spellId);
            else
                RL::Log::Warn("SpellCLookupDiag spell=%d => lookup OK rc=%d flag=0x%02X",
                              spellId, rc, flagByte);
            int gate = CastGatesDiag((uint32_t)spellId, targetGuid, attr28);
            if (gate == 1)
                RL::Log::Warn("CastGates spell=%d => PLAYER_BUSY gate", spellId);
            else if (gate == 2)
                RL::Log::Warn("CastGates spell=%d => TARGET_BUSY gate", spellId);
            CastGatesDeepDiag((uint32_t)spellId, targetGuid);
            SecureActionDiag((uint32_t)spellId, targetGuid);
        }
        // CONFIRMED refusing gate fix (every cast): [0xD4139C]!=0 makes
        // canCast(2)=0 -> Spell_C refuses. Zero it for the retry, restore after.
        CastGateFix((uint32_t)spellId, targetGuid);
    }
    if (ok) {
        if (targetGuid != 0) {
            // 2026-08-02 (CRASH FIX — same as CastSpell, 22:42 PROOF): NEVER
            // write UNIT_FIELD_TARGET (desc+0x48) synchronously from the bridge.
            // 2026-08-02 (14:09 UNITFRAME FIX): acquire-off casts now use the
            // DIRECT-GUID path (QueueCast carries flags; DrainCastQueue routes
            // NOTGT -> SafeNativeCast(spellId, guid, 0)) with ZERO selection
            // writes — so there is NO restore to arm here. The min-hold
            // PulseSelectionRestore machinery remains as a safety net for any
            // legacy register path but is no longer armed from the bridge.
            (void)prev;
        }
        r.ok = true;
        r.reason = "ok";
    } else {
        if (targetGuid != 0) {
            // No synchronous descriptor write (crash source) — nothing to
            // restore synchronously; the deferred pulse handles any stuck
            // selection if it was armed.
        }
        r.reason = "cast_fail";
    }
    return r;
}

bool MoveTo(float x, float y, float z) {
    // Forbidden: click-to-move. OM::MoveTo now refuses; kept for ABI only.
    (void)x; (void)y; (void)z;
    OM::MoveTo(Vec3{ x, y, z });
    return false;
}

bool FaceDirection(float radians) {
    SoftHardwareUnlock();
    // Write LIVE facing (0x7AC) AND orientation field (0x7A4). Old code only
    // wrote 0x7A4 which this client ignores for cast/movement.
    // VirtualQuery-guarded writes — no __try dependency (SEH broken under stealth).
    uintptr_t p = OM::LocalPtr();
    if (p) {
        Mem::Write<float>(p + 0x7AC, radians);
        Mem::Write<float>(p + 0x7A4, radians);
    }
    OM::FaceDirection(radians);
    CommitMovement();
    return true;
}

bool Jump() {
    SoftHardwareUnlock();
    // One-shot: same native as ascend-start. Land hops and a single key tap.
    // Continuous swim-up MUST use Ascend(true/false) so AscendStop can release.
    return SafeVoid(At(kJumpOrAscendStart)) > 0;
}

bool Ascend(bool start) {
    SoftHardwareUnlock();
    return SafeVoid(At(start ? kJumpOrAscendStart : kAscendStop)) > 0;
}

bool Descend(bool start) {
    SoftHardwareUnlock();
    // FrameScript table: SitStandOrDescendStart @ 0x0051B1D0 (not in the
    // 0x005FC movement block - sit/stand wrapper that descends while swimming).
    // DescendStop @ 0x005FC140 releases.
    return SafeVoid(At(start ? kSitStandOrDescendStart : kDescendStop)) > 0;
}

bool StopMoving() {
    SoftHardwareUnlock();
    SafeVoid(At(kMoveForwardStop));
    SafeVoid(At(kMoveBackwardStop));
    SafeVoid(At(kStrafeLeftStop));
    SafeVoid(At(kStrafeRightStop));
    SafeVoid(At(kTurnLeftStop));
    SafeVoid(At(kTurnRightStop));
    SafeVoid(At(kAscendStop));
    SafeVoid(At(kDescendStop));
    return true;
}

// ---- Deferred protected actions (2026-08-02, native carrier) --------------
// Protected movement/cast APIs must NEVER execute from a Lua-dispatched
// RuntimeCall (client taint -> "blocked from an action only available to the
// Blizzard UI" dialog). The addon stages the action; the native frame hook
// (TickHookBody) drains it on the main thread with no Lua on the stack.
namespace {
// 0 = idle, 1 = halt pending (release keys + stop + commit). Executed by the
// hook; a volatile flag (no locks — the hook and the bridge both run on the
// game's main thread, never concurrently).
volatile int g_deferredHalt = 0;
// Pending auto-attack engage target (0 = none). Staged by the Lua bridge
// (RequestAttackEngage), executed by the native hook via AttackTarget().
volatile uint64_t g_deferredAttack = 0;
// Guard: the addon engages 6603 once per target; the runtime idempotency
// checks (AttackTargetGuid / IsAutoAttacking / s_engagedTarget) run in the
// hook — never double-engage.
}

bool RequestHaltMovement() {
    // Stage only. The native hook executes StopMoving() + CommitMovement() +
    // MouselookStop() on the next main-thread frame — NEVER from this Lua-
    // dispatched bridge call (that is the taint source).
    g_deferredHalt = 1;
    RL::Log::Info("DeferredHalt staged (native hook executes it)");
    return true;
}

bool RequestAttackEngage(uint64_t targetGuid) {
    if (!targetGuid) return false;
    // Already attacking exactly this target? (native check — no protected call)
    if (State::AttackTargetGuid() == targetGuid) return true;
    if (State::IsAutoAttacking()) return true;
    g_deferredAttack = targetGuid;
    RL::Log::Info("DeferredAttack staged tgt=0x%llX (native hook engages)",
                  (unsigned long long)targetGuid);
    return true;
}

void DrainDeferredActions() {
    // Native hook context (main thread, no Lua on the stack). All protected
    // APIs here run from THIS context — the client cannot flag them as addon
    // taint.
    if (g_deferredHalt) {
        g_deferredHalt = 0;
        StopMoving();
        MouselookStop();
        CommitMovement();
        RL::Log::Info("DeferredHalt executed (native)");
    }
    if (g_deferredAttack) {
        uint64_t tgt = g_deferredAttack;
        g_deferredAttack = 0;
        // Engage once per target (AttackTarget is idempotent natively).
        AttackTargetFor(tgt);
    }
}

bool MoveForward(bool start) {
    SoftHardwareUnlock();
    return SafeVoid(At(start ? kMoveForwardStart : kMoveForwardStop)) > 0;
}

// Pitch is the swim/fly vertical AIM axis - with pitch held down-forward, plain
// MoveForward descends. This replaces a SetPitch stub that answered true while
// doing nothing, which made depth control look implemented for months.
// Mutually exclusive by construction: starting one direction stops the other,
// because holding both natives leaves the client's pitch state wedged.
bool PitchUp(bool start) {
    SoftHardwareUnlock();
    if (start) SafeVoid(At(kPitchDownStop));
    return SafeVoid(At(start ? kPitchUpStart : kPitchUpStop)) > 0;
}
bool PitchDown(bool start) {
    SoftHardwareUnlock();
    if (start) SafeVoid(At(kPitchUpStop));
    return SafeVoid(At(start ? kPitchDownStart : kPitchDownStop)) > 0;
}
bool MoveBackward(bool start) {
    SoftHardwareUnlock();
    return SafeVoid(At(start ? kMoveBackwardStart : kMoveBackwardStop)) > 0;
}
bool StrafeLeft(bool start) {
    SoftHardwareUnlock();
    return SafeVoid(At(start ? kStrafeLeftStart : kStrafeLeftStop)) > 0;
}
bool StrafeRight(bool start) {
    SoftHardwareUnlock();
    return SafeVoid(At(start ? kStrafeRightStart : kStrafeRightStop)) > 0;
}
bool TurnLeft(bool start) {
    SoftHardwareUnlock();
    return SafeVoid(At(start ? kTurnLeftStart : kTurnLeftStop)) > 0;
}
bool TurnRight(bool start) {
    SoftHardwareUnlock();
    return SafeVoid(At(start ? kTurnRightStart : kTurnRightStop)) > 0;
}

// ---- Mouselook / camera-yaw steering (the human, analog turn) ----
// All reads VirtualQuery-guarded (Mem::Read) — no __try dependency.
static uintptr_t CameraPtr() {
    uintptr_t wf = Mem::Read<uintptr_t>(kWorldFramePtr);
    if (!wf) return 0;
    return Mem::Read<uintptr_t>(wf + kCamPtrOffset);
}

bool MouselookStart() { SoftHardwareUnlock(); return SafeVoid(At(kMouselookStart)) > 0; }
bool MouselookStop()  { SoftHardwareUnlock(); return SafeVoid(At(kMouselookStop))  > 0; }

int IsMouselooking() {
    uintptr_t c = Mem::Read<uintptr_t>(kInputCtrlPtr);
    if (!c) return 0;
    return (Mem::Read<uint32_t>(c + kInputFlagsOff) & kMouselookBits) ? 1 : 0;
}

// Current (smoothed) camera yaw in radians, or a large sentinel on failure.
float CameraYaw() {
    uintptr_t cam = CameraPtr();
    if (!cam) return 1e9f;
    return Mem::Read<float>(cam + kCamAppliedYaw);
}
float CameraTargetYaw() {
    uintptr_t cam = CameraPtr();
    if (!cam) return 1e9f;
    return Mem::Read<float>(cam + kCamTargetYaw);
}
// Set the camera's TARGET yaw; the client eases the applied yaw toward it. In
// mouselook this may or may not carry the player - the addon verifies live.
bool SetCameraYaw(float rad) {
    uintptr_t cam = CameraPtr();
    if (!cam) return false;
    return Mem::Write<float>(cam + kCamTargetYaw, rad);
}

// Push the current movement/heading state to the server (the native flag
// handlers call this after every change). __thiscall(ctrl, [0xB499A4], 1).
bool CommitMovement() {
    uintptr_t c = Mem::Read<uintptr_t>(kInputCtrlPtr);
    if (!c) return false;
    void* p = reinterpret_cast<void*>(Mem::Read<uintptr_t>(kInputTimePtr));
    // 2026-08-02 (defensive): the movement-apply game function was called raw
    // here. On the suite-disable path (halt_movement) the input controller can
    // be in a mid-teardown state; a fault here must never propagate into the
    // game Lua VM (the "call through garbage" crash family, live 15:45
    // eip=0x0094CF68 after the disable burst). VEH-guard it like every other
    // game call from the bridge.
    RL::Game::Guard::Scope g;
    if (!g.Caught()) {
        reinterpret_cast<fnApply>(kMovementApply)(reinterpret_cast<void*>(c), p, 1);
        return true;
    }
    return false;
}

// Synthesize a RELATIVE mouse move (genuine OS input). The client reads the OS
// cursor via GetCursorPos (no DirectInput), so while mouselook is active this
// feeds the exact native turn pipeline - camera+player yaw + the client's own
// easing - indistinguishable from a hand on the mouse. dx/dy are raw mickeys.
bool MouseMove(int dx, int dy) {
    INPUT in;
    ZeroMemory(&in, sizeof(in));
    in.type = INPUT_MOUSE;
    in.mi.dx = dx;
    in.mi.dy = dy;
    in.mi.dwFlags = MOUSEEVENTF_MOVE;
    return SendInput(1, &in, sizeof(INPUT)) == 1;
}

// Rotate the character by a yaw delta (radians, + = left/CCW) THIS frame - fully
// in-process, server-synced, no OS mouse, no cursor capture, no click-to-move.
// The user's physical mouse stays free while the bot steers. Game-thread only.
bool TurnByDelta(float deltaRad) {
    // VirtualQuery-guarded reads/writes — no __try dependency.
    uintptr_t ctrl = Mem::Read<uintptr_t>(kInputCtrlPtr);
    if (!ctrl) return false;
    // Force TurnByDelta to read the LIVE facing (GetFacing -> player+0x7AC) as its
    // base instead of the stale cached [ctrl+0x50] - clearing the valid bit at
    // [ctrl+0x4C] selects the GetFacing branch (0x5FB4DE). Without this it
    // accumulated on a stale base and the turn drifted.
    Mem::Write<uint32_t>(ctrl + kCtrlFacingValid, 0u);
    int token = Mem::Read<int>(kInputTimePtr);
    reinterpret_cast<fnTurnByDelta>(kTurnByDelta)(reinterpret_cast<void*>(ctrl), token, deltaRad);
    // COMMIT, OR THE TURN NEVER HAPPENED.
    //
    // CommitMovement's own comment says it: "the native flag handlers call this
    // after every change". TurnByDelta did not, so the rotation was set
    // in-process and nothing pushed it - the client's next movement apply
    // recomputed facing from an unchanged input state and the real facing never
    // moved. Live proof: "TurnByDelta ineffective (real facing not moving) ->
    // keyboard turn", after which every single turn in the session logged
    // m=keyboard. The smooth variable-rate turn was dead and the character was
    // steered by the stiff fixed-rate fallback all session - the "sloppy
    // control" report.
    //
    // Separate __try above so a throwing turn cannot skip straight past this,
    // and CommitMovement is itself SEH-guarded.
    CommitMovement();
    return true;
}

// The local player's LIVE facing (radians), CAMERA-INDEPENDENT (so free-look does
// not corrupt it). Mirrors what TurnByDelta reads: the input-controller cache
// [ctrl+0x50] when valid, else the player's GetFacing vtable[0x14C]. 1e9 on fail.
float PlayerFacing() {
    // 2026-08-02 (FACING ROOT CAUSE — RE-VERIFIED LIVE): LocalPtr()+0x7AC reads
    // 0 on this build while the client's own GetPlayerFacing() returns a real
    // value (1.4547 at the live probe). The client resolves the player via
    // camera → GUID → ClntObjMgrObjectPtr(0x4D4DB0) and reads [obj+0x7AC]
    // (vtable[0x34]=0x6E6FC0 = `fld [ecx+0x7AC]; ret`). Use that RE-correct path
    // FIRST; LocalPtr fallback only when the camera path is unavailable.
    float live = OM::FacingLiveLocal();
    if (live < 1e8f) return live;
    // The LIVE local-player facing = CMovement+0x24 = player+0x7AC (RE-verified:
    // GetFacing @0x6E6FC0 is just `fld [ecx+0x7AC]; ret`, single writer is the
    // movement apply 0x6EAA08). NOT the dead 0x7A4, NOT the stale input cache.
    // VirtualQuery-guarded read (Mem::Read) — no __try dependency.
    uintptr_t player = OM::LocalPtr();
    if (!player) return 1e9f;
    float f = Mem::Read<float>(player + kPlayerFacingLive);
    if (f != f || f < -0.01f || f > 6.30f) return 1e9f;   // NaN / out of [0,2pi)
    return f;
}

// CRASH RULE (permanent): ALL targeting/attack helpers are now NATIVE or
// NO-OP. LuaGlobal0/S/N (nested lua_getfield+lua_pcall of TargetUnit/
// ClearTarget/StartAttack from inside Lua_IsLinuxClient) and SafeFSExec
// fallbacks were both proven fatal. The addon performs Lua→Lua targeting
// itself when needed (A.Target token path); the runtime only needs the
// UNIT_FIELD_TARGET descriptor write, which is what the client reads for
// selection and what Spell_C resolves melee victims against.

bool TargetGuid(uint64_t guid) {
    if (!guid) return ClearTarget();
    SoftHardwareUnlock();
    // Native descriptor write of UNIT_FIELD_TARGET (player+desc+0x48).
    // This IS client selection — UnitGUID("target") reads the same field.
    return WriteClientTargetGuid(guid);
}

// Name targeting requires name→GUID resolution which has no native path.
// The addon resolves tokens/names to GUIDs and calls TargetGuid (native).
// No-op: never FSExec/nested-pcall from the bridge.
bool TargetByName(const char* name) {
    (void)name;
    return false;
}

// Unit-token targeting ("target", "nameplate1", ...) — the addon resolves
// these to GUIDs (UnitGUID) and calls TargetGuid. No-op: never Lua from C++.
bool TargetToken(const char* unitToken) {
    (void)unitToken;
    return false;
}

bool ClearTarget() {
    SoftHardwareUnlock();
    return WriteClientTargetGuid(0);
}

// No native LastTarget stack. The runtime's CastSpell already restores
// UNIT_FIELD_TARGET after GUID casts (WriteClientTargetGuid(prev)); the
// addon's own preserve-selection restore uses A.Target(guid) which is native.
bool TargetLastTarget() {
    return false;
}

// Core auto-attack engage for an explicit target GUID. Runs ONLY from the
// NATIVE hook context (deferred via RequestAttackEngage) — NEVER from the Lua
// bridge (the client treats bridge-origin Spell_C(6603) as protected
// "StartAttack" and pops the blocked-action dialog; live: "Attack engage
// nrc=0" every engage attempt). Idempotent: never re-casts while already
// attacking the same target.
bool AttackTargetFor(uint64_t targetGuid) {
    SoftHardwareUnlock();
    // AUTHORITATIVE + DEFENSE-IN-DEPTH auto-attack gating (2026-08-01). The
    // addon's Lua IsCurrentSpell(6603) NO-OPS from insecure code, and the
    // current-spells list [0xAF5254] does NOT reliably contain 6603 after
    // Spell_C(6603) on this client (proven: 3x "Attack engage" in 250ms on
    // 02:15). Re-casting 6603 while already attacking triggers blocked-action
    // errors and, with a dead __try on Spell_C, can AV into the Lua VM.
    // Signals, strongest first:
    //   1) player+0xA20/0xA24 = the GUID the player is CURRENTLY attacking
    //      (from IsCurrentSpell internal 0x806030 slot-78 Attack branch).
    //   2) current-spells list contains 6603.
    //   3) self-managed engage record for the same target (< 1.5s).
    if (!targetGuid) return false;
    uint64_t atkTarget = State::AttackTargetGuid();
    if (atkTarget == targetGuid) {
        // Already attacking exactly this target — never re-cast.
        return true;
    }
    if (State::IsAutoAttacking()) {
        return true; // list says 6603 active
    }
    // 2026-08-02 (MELEE-RANGE GATE — "auto-attack engaged a 30yd leaked target"
    // + blocked-action source): NEVER engage 6603 unless the target is actually
    // in melee range. A multi-dot leaked target at 20-30yd got Spell_C(6603)
    // fired at it — a nonsense engage the client treats as a protected
    // "StartAttack" from addon context (blocked-action popup) and which never
    // lands. Melee auto-attack only makes sense at ~0 edge; the rotation's
    // melee ABILITIES handle engagement naturally once in range, so a refusal
    // here just waits for the player to close (the client auto-attacks on any
    // melee spell anyway). Measure via snapshot positions (pure memory).
    {
        uint64_t me = ActiveGuid();
        if (me && targetGuid != me) {
            Vec3 pa = OM::Position(me);
            Vec3 pb = OM::Position(targetGuid);
            if (pa.x != 0.f || pa.y != 0.f) {
                float dx = pa.x - pb.x, dy = pa.y - pb.y;
                float center = std::sqrt(dx * dx + dy * dy);
                // ~melee band (default reach sum + small slack); beyond = refuse.
                if (center > 6.0f)
                    return false;
            }
        }
    }
    // 2026-08-02 (ROUND 23 — AUTO-ATTACK ENGAGE DISABLED): every session since
    // round 18 ran the Spell_C(6603) engage as its FIRST cast, and every one of
    // those sessions broke — while the ONLY clean session (18:11, 1.10.81) had
    // NO 6603 casts at all. The 19:34 log (1.10.86, direct-GUID engage, no
    // [0xd0] write) shows the engage firing repeatedly and failing nrc=0, then
    // EVERY unit-targeted cast refusing al=0 ("Invalid target") while
    // Consecration (guid=0) lands — i.e. the client's SYNC target resolution
    // broke the instant the engage ran. Spell_C's cast machinery allocates a
    // HEAP cast record (0x805010) and the client's sync path reads
    // [player+0xd0]+0x18; once the engage's record machinery has run, that
    // pointer is no longer the static walk slot (0xD3C00DFC) our slot write
    // feeds, so every later targeted cast fails sync resolution. The engage
    // itself is what we DON'T need: WoW auto-attacks natively the moment any
    // melee ability lands (18:11 proved the rotation's melee spells engage
    // without a 6603 cast), and the melee-range gate above already refuses
    // nonsense engages. DISABLED = detection-only + fail-open: never cast 6603,
    // never touch [0xd0], never touch selection; return true so the rotation
    // cycles (auto-attack is handled by the client on melee spell land).
    // Logged once so this is never a silent fallback.
    static volatile LONG s_engageNote = 0;
    if (InterlockedCompareExchange(&s_engageNote, 1, 0) == 0) {
        RL::Log::Warn("Attack engage DISABLED (round 23): no 6603 cast — client "
                      "auto-attacks on melee spell land; restores the 18:11-proven "
                      "sync cast resolution (no heap cast-record flip).");
    }
    return true;
}

bool AttackTarget() {
    // Resolve the current client selection and delegate to the native engage.
    // This is a NO-OP from the Lua bridge (never touches Spell_C here) — the
    // addon stages the engage via RequestAttackEngage and the native hook
    // runs it. Keeping the name so existing callers compile; returns true
    // (staged semantics) when a selection exists.
    uint64_t targetGuid = ReadClientTargetGuid();
    if (!targetGuid) targetGuid = OM::UnitTargetGuid(ActiveGuid());
    if (!targetGuid) return false;
    return RequestAttackEngage(targetGuid);
}

// No native stop-auto-attack primitive wired; rotation relies on range/target
// death to end swings (client handles it). No-op: never Lua from C++.
bool StopAttack() {
    return false;
}

// CLICK-TO-MOVE IS DELETED FROM THE INTERACT PATH ON PURPOSE.
// CtmInteract() lived here and called Offsets::F().ClickToMove with action 5
// ("move-to + interact"), which steers the character - forbidden project-wide,
// and already refused by name in Dispatch.cpp. It is removed rather than left
// unused so it cannot quietly come back. Interact now goes through the Lua
// handler directly; see InteractUnitDirect below.

// InteractUnit's Lua handler, called DIRECTLY. See
// vendor/WowAutoSDK/include/AscensionLuaHandlers.h:1643
//   #define HANDLER_InteractUnit 0x00527F00
// Signature is the standard Lua C closure: int __cdecl f(lua_State*).
static constexpr uintptr_t kHandlerInteractUnit = 0x00527F00;

// INTERACT WITHOUT CLICK-TO-MOVE AND WITHOUT TAINT.
//
// Two problems this solves at once.
//
// 1. CTM IS A HARD PROJECT CONSTRAINT VIOLATION. The old path called
//    Offsets::F().ClickToMove with action 5/7. Type 5 is literally "move-to +
//    interact": it steers the character with click-to-move, which is forbidden
//    outright in this project. The Lua-side guard never caught it because it
//    only scans addon/**/*.lua - the violation lived in C++.
//
// 2. `InteractUnit('target')` through FrameScript_Execute is a PROTECTED call
//    from an insecure context, so it no-ops. That is why the live log showed
//    `interact ok=1 target=1 face=1 frame=0` - we reported success and no
//    dialog ever opened.
//
// Protection is enforced by the Lua BINDING layer, not by the handler itself.
// Pushing the unit token and calling the handler function directly therefore
// performs the real interact with no CTM movement and no taint check. The stack
// is restored unconditionally so a throwing handler cannot corrupt the VM.
static bool InteractUnitDirect(lua_State* L, const char* token) {
    if (!L || !token) return false;
    using namespace RL::Game::Addr;
    auto settop = reinterpret_cast<fn_settop>(lua_settop);
    auto gettop = reinterpret_cast<fn_gettop>(lua_gettop);
    auto pushstring = reinterpret_cast<fn_pushstring>(lua_pushstring);
    if (!settop || !gettop || !pushstring) return false;
    using fnHandler = int(__cdecl*)(lua_State*);
    auto h = reinterpret_cast<fnHandler>(kHandlerInteractUnit);
    SoftHardwareUnlock();

    // A LUA C FUNCTION READS ITS FIRST ARGUMENT AT INDEX 1.
    //
    // The first version of this pushed the token on top of whatever the bridge
    // dispatch already had on the stack, so the token landed at index top+1 and
    // index 1 still held the RuntimeCall COMMAND NAME. The handler would have
    // resolved the unit token "InteractGuid", found no such unit, and done
    // nothing - the identical `ok=1, frame=0` symptom this function exists to
    // fix, just one layer deeper. Verified __cdecl against the shipped binary
    // (0x105 bytes, terminates ff 59 c3, no C2 anywhere), so the convention is
    // right; only the frame was wrong.
    //
    // Clearing to 0 first gives the handler exactly the stack Lua itself would:
    // its arguments and nothing else. Discarding what was below is safe because
    // Lua takes a C function's results from the TOP of the stack - the old
    // `settop(L, top)` restore was doing nothing useful.
    //
    // CONSTRAINT this creates: any `const char*` previously obtained from the
    // Lua stack (e.g. the dispatch's `name`) loses its stack reference here and
    // must NOT be used after this call. Today Handle() has finished its strcmp
    // chain and only returns a pushed bool, which satisfies that.
    // VEH longjmp guard: a dead __try under stealth let a throwing handler AV
    // propagate into the game's Lua VM. On a caught AV the Lua stack is reset
    // to empty (best recovery) and the caller gets false.
    Guard::Scope g;
    if (!g.Caught()) {
        settop(L, 0);
        pushstring(L, token);
        h(L);
        settop(L, 0);
        return true;
    }
    settop(L, 0);
    return false;
}

bool InteractGuid(uint64_t guid) {
    SoftHardwareUnlock();
    ArmUnlock();
    if (!guid) return InteractTarget();

    // Face the target first - interact often requires facing.
    {
        uint64_t meG = ActiveGuid();
        Vec3 me = meG ? OM::Position(meG) : Vec3{};
        Vec3 them = OM::Position(guid);
        if ((them.x != 0.f || them.y != 0.f) && (me.x != 0.f || me.y != 0.f)) {
            float ang = std::atan2(them.y - me.y, them.x - me.x);
            FaceDirection(ang);
        }
    }

    TargetGuid(guid);
    SoftHardwareUnlock();

    // 3.3.5 high-guid type (top of high dword):
    //   F1 3x = creature/unit, F1 1x = gameobject, F1 5x = pet, etc.
    uint32_t hi32 = (uint32_t)(guid >> 32);
    uint32_t kind = (hi32 >> 20) & 0xF; // nibble after F1
    bool isUnit = true;
    if ((hi32 & 0xFF000000u) == 0xF1000000u) {
        // F11 = GO, F13 = creature, F14 = pet, F15 = vehicle-ish
        isUnit = (kind != 0x1); // F11xxxx = gameobject
    }

    // Direct handler call. No CTM: the character does not get steered, so this
    // cannot violate the keyboard-only movement constraint. Navigation is the
    // navigator's job - by the time we interact we are already in range.
    bool ok = InteractUnitDirect(g_currentL, "target");

    // Last resort ONLY when we are not already inside Lua. This is the protected
    // path that no-ops from an insecure context; it is kept because it costs
    // nothing when it fails, but it is explicitly NOT counted as success.
    if (!ok && !g_currentL)
        ok = SafeFSExec("if UnitExists('target') then InteractUnit('target') end") > 0;

    // RETURN WHAT ACTUALLY HAPPENED. This used to `return true` unconditionally,
    // whatever the interact did - which is why the suite saw `ok=1 frame=0` and
    // sat in turnin:interact forever waiting for a dialog that was never asked
    // for. A confident value that means "no answer" is the single most expensive
    // bug pattern in this project; do not reintroduce it here.
    RL::Log::Info("InteractGuid g=0x%llX unit=%d L=%p ok=%d",
                  (unsigned long long)guid, (int)isUnit, (void*)g_currentL, (int)ok);
    return ok;
}

bool InteractTarget() {
    SoftHardwareUnlock();
    ArmUnlock();
    // Same direct-handler path as InteractGuid, and the same honest return: the
    // unconditional `return true` here was the other half of `ok=1 frame=0`.
    bool ok = InteractUnitDirect(g_currentL, "target");
    if (!ok && !g_currentL)
        ok = SafeFSExec("if UnitExists('target') then InteractUnit('target') end") > 0;
    return ok;
}

bool SpellStopCasting() {
    SoftHardwareUnlock();
    // CRASH + TAINT RULE (2026-08-02): SpellStopCasting is a PROTECTED call
    // and SafeFSExec re-enters the Lua VM. From inside the bridge (g_currentL
    // set) it is both a blocked-action source ("RaijinLab has been blocked
    // from an action only available to the Blizzard UI") and a nested-VM
    // crash surface. Refuse on the bridge; the addon resolves stop-casting
    // via the native action-state reset (Spell_C / ClearTarget) instead.
    // Only reachable from a genuine non-bridge main-thread path is it safe.
    if (g_currentL) return false;
    return SafeFSExec("SpellStopCasting()") > 0;
}

bool ExecSecure(const char* luaCode) {
    SoftHardwareUnlock();
    return SafeFSExec(luaCode) > 0;
}

// ---- Zero-frame acquire cast (2026-08-02) ---------------------------------
// HARD RULE (user): "having a spell cast at a target is not switching targets."
// Casting must NEVER select a client target it isn't already physically
// targeting. Spell_C(guid) SELECTS the victim as the client target ASYNC — a
// forbidden acquire in every context tried (thunk AND bridge). The fix: pin
// the player descriptor UNIT_FIELD_TARGET to the cast target, call
// Spell_C(spellId, 0) = cast-at-current-target via the descriptor (guid=0 does
// NOT trigger the async client-selection pick), then restore the descriptor.
// Client selection 0xBD07B0 is NEVER touched, not even for a frame.
// Runs DIRECTLY (normal stack, from the bridge) — NOT from the frame-tick
// thunk, which mis-aligns Spell_C's stack and corrupts the VM (0x512B07).
// Returns true if Spell_C accepted the cast.
bool CastSpellNoAcquire(int spellId, uint64_t targetGuid) {
    if (spellId <= 0) return false;
    if (targetGuid == 0) return CastSpell(spellId, 0);  // no pin needed
    // 2026-08-02 (1.10.81 NOREG): direct-GUID with the 0xD3C00E14 walk-slot
    // write — the feedback resolves the victim without selecting it (no
    // unitframe touch, no restore needed).
    int nrc = SafeNativeCast(spellId, targetGuid, 0);
    RL::Log::Warn("CastSpellNoAcquire id=%d at=0x%llX nrc=%d", spellId,
                  (unsigned long long)targetGuid, nrc);
    return nrc > 0;
}

// ---- Native-frame cast queue (2026-08-02) ----------------------------------
// The Lua bridge STAGES casts here (QueueCast) and returns immediately — it
// NEVER calls Spell_C. The native frame hook (NativeHook.cpp's object-gen
// ticker, main thread, no Lua) drains the queue and runs the EXACT same proven
// cast core as CastSpell — but with zero Lua callback frames on the stack.
// That is the structural fix for the 0x512B07 corruption (Spell_C under a Lua
// closure table corrupted the VM). Single-producer (Lua main thread) /
// single-consumer (native hook, same main thread) ring — no locks needed; the
// addon stages at most a few casts per GCD, the hook drains ≤2/frame.
//
// 2026-08-01 CRASH: the frame-tick thunk cannot run Spell_C (stack misalign ->
// 0x512B07). Queue casts are therefore executed DIRECTLY by the bridge command
// (CastQueued) instead of drained from the thunk. QueueCast/DrainCastQueue
// remain for the async design but are NOT the active cast path right now.
namespace {
constexpr int kCastQueueCap = 32;
constexpr int kCastQueueDrainMax = 2;
struct QueuedCast {
    int spellId;
    uint64_t guid;
    uint32_t flags;
    ULONGLONG queuedMs;
};
QueuedCast g_castQueue[kCastQueueCap];
int g_castQHead = 0;  // consumer (drain) index
int g_castQSize = 0;  // pending count
} // namespace

bool QueueCast(int spellId, uint64_t targetGuid, uint32_t flags) {
    if (spellId <= 0) return false;
    if (g_castQSize >= kCastQueueCap) {
        RL::Log::Warn("CastQueue FULL drop id=%d guid=0x%llX",
                      spellId, (unsigned long long)targetGuid);
        return false;
    }
    int tail = (g_castQHead + g_castQSize) % kCastQueueCap;
    g_castQueue[tail].spellId = spellId;
    g_castQueue[tail].guid = targetGuid;
    g_castQueue[tail].flags = flags;
    g_castQueue[tail].queuedMs = GetTickCount64();
    g_castQSize++;
    RL::Log::Warn("CastQueue STAGE id=%d guid=0x%llX flags=%u n=%d",
                  spellId, (unsigned long long)targetGuid, flags, g_castQSize);
    return true;
}

int PendingCastCount() { return g_castQSize; }

void ResetBlockedCastCounter() {
    // 2026-08-02 (19:25): the counter page was UNCOMMITTED -> Mem::Write was a
    // no-op -> the counter climbed past 10 and fired the native blocked dialog
    // (0x530840) on suite disable. Commit the page once (idempotent), then zero.
    EnsureBlockedCounterCommitted();
    Mem::Write<uint32_t>(kBlockedCastCounter, 0u);
}

void DrainCastQueue() {
    // Native hook context (no Lua on stack). Reuses CastSpell's proven core:
    // action-state zero + SafeNativeCast + DEFERRED client-selection restore
    // (PulseSelectionRestore on the next MainThread Pulse, not-mid-cast
    // guarded). Do NOT call CastSpellEx here (it does POST diagnostics +
    // cooldown gates via Lua-internal reads; the native drain must stay
    // minimal and Lua-free).
    //
    // 2026-08-02 (CRASH LOCKDOWN): NO synchronous descriptor/0xBD07B0 write
    // here, EVER. The 22:42 + 22:53 crashes proved WriteDescriptorTargetOnly
    // under the bridge corrupts the Lua VM even on the plain CastSpell path,
    // and the zero-frame pin (CastSpellNoAcquire) crashed twice. The ONLY
    // revert is the DEFERRED PulseSelectionRestore (proven stable 17:51).
    for (int n = 0; n < kCastQueueDrainMax && g_castQSize > 0; ++n) {
        QueuedCast q = g_castQueue[g_castQHead];
        // Drop entries older than 2s (stale queue, e.g. after a long frame).
        if (GetTickCount64() - q.queuedMs > 2000) {
            RL::Log::Warn("CastQueue DROP stale id=%d guid=0x%llX",
                          q.spellId, (unsigned long long)q.guid);
            g_castQHead = (g_castQHead + 1) % kCastQueueCap;
            g_castQSize--;
            continue;
        }
        g_castQHead = (g_castQHead + 1) % kCastQueueCap;
        g_castQSize--;

        // -- identical to CastSpell proven core (see CastSpell) --
        // (action-state save/zero/restore lives inside SafeNativeCast)
        uint64_t prev = (q.guid != 0) ? ReadClientTargetGuid() : 0;
        // SafeNativeCast clears g_currentL around Spell_C; here g_currentL is
        // already 0 (native hook context, no Lua on the stack) — the safest
        // possible context for Spell_C. This is the structural fix for the
        // 0x512B07 VM corruption.
        int nrc = 0;
        if (q.guid != 0) {
            // 2026-08-02 (17:26 — 1.10.81 NOREG): with the 0xD3C00E14 walk-slot
            // write inside SafeNativeCast, the feedback resolves the victim
            // WITHOUT selection registration. Acquire-off casts DIRECT-GUID
            // (registerTarget=0) — the unitframe is NEVER touched and no
            // restore is armed. Acquire-ON still registers (player wants the
            // unitframe to follow the victim).
            if (q.flags & kCastNoTargetChange) {
                nrc = SafeNativeCast(q.spellId, q.guid, 0);
            } else {
                nrc = SafeNativeCast(q.spellId, q.guid, q.guid);
            }
        } else {
            nrc = SafeNativeCast(q.spellId, 0);
        }
        // DEFERRED restore only — never synchronous (crash-proven). With
        // 1.10.81 NOREG the acquire-off path casts DIRECT-GUID and NEVER
        // registers the target (the 0xD3C00E14 walk-slot write inside
        // SafeNativeCast makes the feedback resolve the victim without
        // selecting it), so there is NO selection change and NO restore to
        // arm — the unitframe is never touched. Acquire-ON registers and
        // keeps the target. guid==0 casts never change selection. The min-hold
        // PulseSelectionRestore remains as a safety net for any legacy path.
        (void)prev;
        RL::Log::Warn("CastQueue DRAIN id=%d guid=0x%llX nrc=%d pend=%d",
                      q.spellId, (unsigned long long)q.guid, nrc, g_castQSize);
    }
}

} // namespace RL::Game::Actions
