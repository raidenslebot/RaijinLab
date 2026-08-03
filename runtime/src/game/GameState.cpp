#include "GameState.h"
#include "Mem.h"
#include "ObjectManager.h"
#include "Guard.h"
#include <Windows.h>
#include <cstdio>

namespace RL::Game::State {

// Client addresses (RE-verified 2026-08-01, Ascension 12340):
static constexpr uintptr_t kCurrentSpellListHead = 0x00AF5254; // IsCurrentSpell list
static constexpr uintptr_t kAutoRepeatSpell      = 0x00D397D0; // auto-repeat spell id
static constexpr uintptr_t kCurrentSpellUsed     = 0x00D397CC; // last/current used spell
static constexpr uintptr_t kSpellTargetingFlag   = 0x00D3F4E4; // targeting cursor active
static constexpr uintptr_t kGameTimeObject       = 0x00D4159C; // GetTime C++ object
static constexpr uintptr_t kGetTimeFn            = 0x0086AE20; // GetTime() -> ms

// Node layout (from 0x805f30): +0x20 = spellId, +0x04 = next.
static constexpr uint32_t kNodeSpellIdOff = 0x20;
static constexpr uint32_t kNodeNextOff    = 0x04;

// Player fields (from UnitCastingInfo 0x00611DF0 and IsCurrentSpell 0x806030):
static constexpr uint32_t kPlayerCastSpellOff   = 0xA6C;
static constexpr uint32_t kPlayerCastEndOff     = 0xA7C;
static constexpr uint32_t kPlayerCastTgtLowOff  = 0xA70;
static constexpr uint32_t kPlayerCastTgtHighOff = 0xA74;
static constexpr uint32_t kPlayerAtkTgtLowOff   = 0xA20;
static constexpr uint32_t kPlayerAtkTgtHighOff  = 0xA24;

// MAX_NODES caps the walk so a corrupted list cannot loop forever.
static constexpr int kMaxNodes = 64;

int64_t GameTimeMs() {
    // The game-time object at [0xD4159C] is permanently valid; the VEH guard
    // is pure insurance. Returns -1 on any fault.
    Guard::Scope g;
    if (!g.Caught()) {
        auto fn = reinterpret_cast<int64_t(__cdecl*)()>(kGetTimeFn);
        return fn();
    }
    return -1;
}

bool IsCurrentSpell(uint32_t spellId) {
    uintptr_t node = Mem::ReadPtr(kCurrentSpellListHead);
    for (int i = 0; i < kMaxNodes && node; ++i) {
        uint32_t id = Mem::Read<uint32_t>(node + kNodeSpellIdOff);
        if (id == spellId) return true;
        uintptr_t next = Mem::ReadPtr(node + kNodeNextOff);
        if (!next || next == node) break;   // corrupt/self-loop guard
        node = next;
    }
    return false;
}

bool IsAutoAttacking() {
    return IsCurrentSpell(6603);
}

uint64_t AttackTargetGuid() {
    uintptr_t p = OM::LocalPtr();
    if (!p) return 0;
    uint32_t lo = Mem::Read<uint32_t>(p + kPlayerAtkTgtLowOff);
    uint32_t hi = Mem::Read<uint32_t>(p + kPlayerAtkTgtHighOff);
    return ((uint64_t)hi << 32) | lo;
}

uint32_t AutoRepeatSpellId() {
    return Mem::Read<uint32_t>(kAutoRepeatSpell);
}

uint32_t CurrentSpellUsed() {
    return Mem::Read<uint32_t>(kCurrentSpellUsed);
}

bool IsSpellTargeting() {
    return Mem::Read<uint32_t>(kSpellTargetingFlag) != 0;
}

int CastingSpellId() {
    uintptr_t p = OM::LocalPtr();
    if (!p) return 0;
    return (int)Mem::Read<uint32_t>(p + kPlayerCastSpellOff);
}

int64_t CastingEndMs() {
    uintptr_t p = OM::LocalPtr();
    if (!p) return 0;
    return (int64_t)Mem::Read<uint32_t>(p + kPlayerCastEndOff);
}

uint64_t CastingTargetGuid() {
    uintptr_t p = OM::LocalPtr();
    if (!p) return 0;
    uint32_t lo = Mem::Read<uint32_t>(p + kPlayerCastTgtLowOff);
    uint32_t hi = Mem::Read<uint32_t>(p + kPlayerCastTgtHighOff);
    return ((uint64_t)hi << 32) | lo;
}

// A "real" cast is in progress ONLY if the casting field is non-zero AND the
// cast-end time is genuinely in the future (mirrors UnitCastingInfo's
// now < castEnd). A stale / lingering field must NEVER lock the rotation
// into "casting" forever — that was the "nothing casts" busy trap (the player
// sits auto-attacking; +0xA6C holds a leftover id, and the rotation refused
// every real spell as busy).
//
// CRITICAL (2026-08-01): FAIL OPEN, never fail closed to "casting". If the
// end-time is 0 (field not populated by the client for this cast type), or the
// clock cannot be read (-1), treat it as NOT in progress and let the client be
// the final authority (it will refuse a truly-impossible cast with its own
// "Another action is in progress"). A stale non-zero id with end in the past
// simply means "the cast already finished" — the field just hasn't cleared.
static bool CastInProgress(int* outId) {
    int id = CastingSpellId();
    if (id == 6603) id = 0;
    if (id <= 0) {
        if (outId) *outId = 0;
        return false;
    }
    int64_t end = CastingEndMs();
    int64_t now = GameTimeMs();
    // Cast is ongoing ONLY when end is a valid future time.
    //   end<=0      -> client never set an end (no real cast) -> NOT busy.
    //   now<0       -> clock unreadable -> DON'T block (fail open).
    //   now >= end  -> cast already finished (field stale) -> NOT busy.
    if (end <= 0) {
        if (outId) *outId = 0;
        return false;
    }
    if (now >= 0 && now >= end) {
        if (outId) *outId = 0;
        return false;
    }
    if (now < 0) {
        // Clock unreadable: cannot prove a cast is in progress. Fail open —
        // the client is the authority and refuses impossible casts itself.
        if (outId) *outId = 0;
        return false;
    }
    if (outId) *outId = id;
    return true;
}

void CastStatePacked(char* buf, size_t n) {
    if (!buf || n == 0) return;
    if (IsSpellTargeting()) {
        snprintf(buf, n, "targeting");
        return;
    }
    // AUTHORITY FOR "casting" = the real casting field with a future end-time
    // ONLY (CastInProgress mirrors UnitCastingInfo's now < castEnd). We DO NOT
    // classify "casting" from the current-spells list walk: that linked list
    // retains residual entries (a prior swing/cast/Consecration attempt) that
    // report "casting" FOREVER even when the player is visibly idle — the
    // exact "nothing casts, reason=busy" bug (live: Consecration blocked every
    // frame with state=casting while the player stood still). A residual list
    // entry is NOT an in-progress cast; only the casting field + future end
    // time proves a real cast. The client refuses truly-impossible casts itself.
    int cid = 0;
    if (CastInProgress(&cid)) {
        snprintf(buf, n, "casting");
        return;
    }
    // Auto-attack engaged is NOT busy for real spells.
    if (IsAutoAttacking()) {
        snprintf(buf, n, "attacking");
        return;
    }
    snprintf(buf, n, "free");
}

void FullStatePacked(char* buf, size_t n) {
    if (!buf || n == 0) return;
    int cid = 0;
    CastInProgress(&cid);
    uint64_t atk = AttackTargetGuid();
    uint64_t ctg = CastingTargetGuid();
    int64_t end = CastingEndMs();
    int64_t now = GameTimeMs();
    snprintf(buf, n,
        "cast=%d|end=%lld|tgt=0x%llX|attack=%d|atk_tgt=0x%llX|auto=%u|cur=%u|tgtflag=%d|time=%lld",
        cid, (long long)end, (unsigned long long)ctg,
        (int)IsAutoAttacking(), (unsigned long long)atk,
        (unsigned)AutoRepeatSpellId(), (unsigned)CurrentSpellUsed(),
        (int)IsSpellTargeting(), (long long)now);
}

} // namespace RL::Game::State
