#include "SpellDB.h"
#include "Mem.h"
#include "core/Log.h"
#include <cstdio>
#include <cstring>

namespace RL::Game::SpellDB {

// Client spell-table globals (RE-verified, fixed VAs, no ASLR).
static constexpr uintptr_t kSpellTableGlob  = 0x00AD49D0; // [..+0x10]=min, +0xC=max, +0x20=table
static constexpr uintptr_t kSpellCompress   = 0x00C5DEA0; // !=0 -> records RLE-compressed
static constexpr uint32_t  kRecBytes        = 0x2A8;      // decoded record size (0x2A8)
// 2026-08-02 (RANGE FIX — RE-verified against the client's own range
// computation 0x7FF480): the OLD globals (0xAD489C/0xAD4898/0xAD48AC) resolve
// the SPELL RANGE NAME table (ID + display-string pairs) — so every spell
// read max=0.00 and melee=1 (live: Icy Touch 20yd reported melee). The client
// reads the NUMERIC SpellRange table from:
//   minI = [0xAD4998], maxI = [0xAD4994], base = [0xAD49A8]
//   entry = base + (ri - minI) * 4
//   min = [entry + 0x04], max = [entry + 0x0C]  (selector 0 = normal range)
static constexpr uintptr_t kRangeStoreMin   = 0x00AD4998;
static constexpr uintptr_t kRangeStoreMax   = 0x00AD4994;
static constexpr uintptr_t kRangeStoreBase  = 0x00AD49A8;

// Faithful port of client 0x4CFBB0 (RLE spell-record decode). Output exactly
// kRecBytes. Every source/run read is bounds-checked; never overruns.
static int RleDecode(const uint8_t* src, size_t srcCap,
                     uint8_t* dst, size_t dstBytes) {
    size_t si = 0, di = 0;
    while (di < dstBytes) {
        if (si >= srcCap) return 0;              // truncated source
        uint8_t b = src[si];
        dst[di++] = b;
        if (si > 0 && b == src[si - 1]) {        // run marker (client 0x4CFBDB)
            if (si + 1 >= srcCap) return 0;
            uint8_t run = src[si + 1];
            si += 2;
            while (run > 0 && di < dstBytes) {   // client 0x4CFBE8 repeat
                dst[di++] = b;
                --run;
            }
            if (di < dstBytes) {                 // client 0x4CFBFD post-run byte
                if (si >= srcCap) return 0;
                dst[di++] = src[si];
                si += 1;
            }
        } else {
            si += 1;                             // normal path (client 0x4CFC04)
        }
    }
    return 1;
}

// Decode the client's loaded spell record. Returns 1 found, 0 not found, -1 bad.
static int DecodeRecord(uint32_t spellId, uint8_t* out) {
    uint32_t minS = Mem::Read<uint32_t>(kSpellTableGlob + 0x10);
    uint32_t maxS = Mem::Read<uint32_t>(kSpellTableGlob + 0xC);
    uint32_t tbl  = Mem::Read<uint32_t>(kSpellTableGlob + 0x20);
    if (!tbl || tbl < 0x10000u || spellId < minS || spellId > maxS)
        return -1;
    uint32_t slot = Mem::Read<uint32_t>(tbl + (spellId - minS) * 4);
    if (!slot || slot < 0x10000u)
        return 0;
    if (Mem::Read<uint8_t>(kSpellCompress)) {
        uint8_t raw[512];
        size_t n = Mem::ReadBytes(slot, raw, sizeof(raw));
        if (n == 0) return 0;
        if (!RleDecode(raw, n, out, kRecBytes)) return 0;
    } else {
        if (Mem::ReadBytes(slot, out, kRecBytes) != kRecBytes)
            return 0;
    }
    return 1;
}

static uint32_t RangeEntry(const uint8_t* decoded, uint32_t* outRi) {
    // 2026-08-02: the client reads the range index at [rec + 0xB8] (0x7FF480:
    // `mov eax,[eax+0xB8]`). The old +0x214 offset was wrong (it read a
    // different field that happened to look plausible). Fall back to +0x214
    // only if +0xB8 is out of the table's index range.
    uint32_t minR = Mem::Read<uint32_t>(kRangeStoreMin);
    uint32_t maxR = Mem::Read<uint32_t>(kRangeStoreMax);
    uint32_t ri = Mem::Read<uint32_t>((uintptr_t)(decoded + 0xB8));
    // NO +0x214 FALLBACK: layout crack (2026-08-03) proved +0x214 is the
    // SpellIconID (Fireball -> 185, its icon). Falling back to it treated an
    // ICON as a range index - fabricated data that "worked" whenever the icon
    // number happened to be a valid index. An out-of-table +0xB8 means the
    // record is not a castable spell's; report unknown, do not invent.
    if (outRi) *outRi = ri;
    uint32_t base = Mem::Read<uint32_t>(kRangeStoreBase);
    if (!base || base < 0x10000u || ri < minR || ri > maxR) return 0;
    uint32_t e = Mem::Read<uint32_t>((uintptr_t)(base + (ri - minR) * 4));
    if (!e || e < 0x10000u) return 0;
    return e;
}

std::string SpellInfoLive(int spellId) {
    char buf[2300];
    uint8_t rec[kRecBytes] = {};
    int rc = DecodeRecord((uint32_t)spellId, rec);
    if (rc <= 0) {
        snprintf(buf, sizeof(buf), "sid=%d|found=%d", spellId, rc);
        return std::string(buf);
    }
    int comp = Mem::Read<uint8_t>(kSpellCompress) ? 1 : 0;
    uint32_t attr  = Mem::Read<uint32_t>((uintptr_t)(rec + 0x10));
    uint32_t attr2 = Mem::Read<uint32_t>((uintptr_t)(rec + 0x14));
    uint32_t ri = 0;
    uint32_t re = RangeEntry(rec, &ri);
    uint32_t alt = Mem::Read<uint32_t>((uintptr_t)(rec + 0x70));
    size_t off = (size_t)snprintf(buf, sizeof(buf),
        "sid=%d|found=1|mode=%d|comp=%d|attr=0x%08X|attr2=0x%08X|ri=%u|re=0x%08X|alt=%u",
        spellId, comp, comp, attr, attr2, ri, re, alt);
    for (int i = 0; i < 8 && re; ++i) {
        uint32_t w = Mem::Read<uint32_t>((uintptr_t)(re + i * 4));
        off += (size_t)snprintf(buf + off, sizeof(buf) - off, "|re%d=0x%08X", i, w);
    }
    off += (size_t)snprintf(buf + off, sizeof(buf) - off, "|hex=");
    for (size_t i = 0; i < kRecBytes && off + 3 < sizeof(buf); ++i)
        off += (size_t)snprintf(buf + off, sizeof(buf) - off, "%02X", rec[i]);
    return std::string(buf, off < sizeof(buf) ? off : sizeof(buf));
}

std::string SpellMeleeInfo(int spellId) {
    char buf[192];
    uint8_t rec[kRecBytes] = {};
    int rc = DecodeRecord((uint32_t)spellId, rec);
    if (rc <= 0) {
        snprintf(buf, sizeof(buf), "found=%d", rc);
        return std::string(buf);
    }
    uint32_t ri = 0;
    uint32_t re = RangeEntry(rec, &ri);
    if (!re) {
        snprintf(buf, sizeof(buf), "found=1|melee=0|ri=%u|re=0", ri);
        return std::string(buf);
    }
    // 2026-08-02 (RANGE FIX): the numeric SpellRange entry layout (selector 0)
    // is min=[re+0x04], max=[re+0x0C], flags=[re+0x14] — NOT +0x10/+0x14 (that
    // read the friendly-max / a string pointer → max=0.00 for every spell).
    uint32_t id    = Mem::Read<uint32_t>((uintptr_t)(re + 0x00));
    uint32_t flags = Mem::Read<uint32_t>((uintptr_t)(re + 0x14));
    float minH = Mem::Read<float>((uintptr_t)(re + 0x04));
    float maxH = Mem::Read<float>((uintptr_t)(re + 0x0C));
    if (maxH < 0.0f || maxH > 500.0f) maxH = Mem::Read<float>((uintptr_t)(re + 0x10));
    int melee = (maxH > 0.0f && maxH <= 8.0f) ? 1 : 0;
    snprintf(buf, sizeof(buf), "found=1|melee=%d|ri=%u|id=%u|flags=0x%08X|min=%.2f|max=%.2f",
             melee, ri, id, flags, minH, maxH);
    return std::string(buf);
}

// ---- CastReq: the full static gate snapshot -------------------------------
//
// Field offsets follow the cracked layout in SpellDB.h. Each is a plain word
// of the decoded record; nothing here guesses - every offset was pinned by a
// stock spell whose dbc value is public ground truth.
namespace rec {
    constexpr size_t Category        = 0x004;
    constexpr size_t Dispel          = 0x008;
    constexpr size_t Mechanic        = 0x00C;
    constexpr size_t Attr0           = 0x010;  // 0x40=passive, 0x4=on-next-swing
    constexpr size_t Attr1           = 0x014;
    constexpr size_t Attr2           = 0x018;
    constexpr size_t Attr3           = 0x01C;
    constexpr size_t Attr4           = 0x020;
    constexpr size_t StancesLo       = 0x030;  // 64-bit shapeshift mask
    constexpr size_t StancesHi       = 0x034;
    constexpr size_t StancesNotLo    = 0x038;
    constexpr size_t StancesNotHi    = 0x03C;
    constexpr size_t Targets         = 0x040;  // TARGET_FLAG_* (0x40 = dest location)
    constexpr size_t FacingFlags     = 0x04C;  // 1 = client enforces front arc
    constexpr size_t CasterAuraState = 0x050;  // reactive requirement (caster)
    constexpr size_t TargetAuraState = 0x054;  // reactive requirement (target)
    constexpr size_t CasterAuraSpell = 0x060;  // required aura on caster
    constexpr size_t TargetAuraSpell = 0x064;  // required aura on target
    constexpr size_t ExCasterAura    = 0x068;  // forbidden aura on caster
    constexpr size_t ExTargetAura    = 0x06C;  // forbidden aura on target
    constexpr size_t CastTimeIdx     = 0x070;  // 1 = instant
    constexpr size_t RecoveryMs      = 0x074;
    constexpr size_t CatRecoveryMs   = 0x078;
    constexpr size_t InterruptFlags  = 0x07C;
    // PROC FIELDS - derived from the cracked mapping (offset = dbc column * 4)
    // and confirmed live: every one of 11 probed spells read 101 at 0x08C,
    // which is Spell.dbc's "always proc" convention for procChance.
    constexpr size_t ProcFlags       = 0x088;
    constexpr size_t ProcChance      = 0x08C;
    constexpr size_t ProcCharges     = 0x090;
    // EffectChainTarget[0..2] - Spell.dbc columns 104/105/106, so word*4.
    //
    // MEASURED OFFLINE against the real Spell.dbc (209,082 records) rather than
    // recalled: Chain Lightning (421, 10605) and Chain Heal (1064, 25442) all
    // carry 3; Fireball, Smite, Arcane Blast and Lesser Healing Wave all carry
    // 0; Multi-Shot (2643) carries 3 with a second effect at 5. 4,617 of
    // 209,082 spells (2.21%) are non-zero, a plausible rate for chaining.
    //
    // THIS IS THE CHAIN SIGNAL, and it is NOT an implicit-target id - which is
    // what the audit assumed and why the chain half of basic check #10 sat
    // unmodelled: it was being looked for in the wrong field entirely.
    constexpr size_t ChainTarget0    = 104 * 4;
    constexpr size_t ChainTarget1    = 105 * 4;
    constexpr size_t ChainTarget2    = 106 * 4;
    constexpr size_t DurationIdx     = 0x0A0;
    constexpr size_t PowerType       = 0x0A4;  // 0 mana 1 rage 3 energy 5 rune 6 RP
    constexpr size_t ManaCost        = 0x0A8;  // rage/RP stored x10
    constexpr size_t ManaCostPerLvl  = 0x0AC;
    constexpr size_t RangeIdx        = 0x0B8;
    constexpr size_t Speed           = 0x0BC;  // float, projectile
    constexpr size_t EquipItemClass  = 0x110;  // -1 none, 2 weapon
    constexpr size_t EquipSubclass   = 0x114;  // mask (Backstab 0x8000 = dagger)
    constexpr size_t Effect0         = 0x11C;
    constexpr size_t ImplicitA0      = 0x158;  // 6=enemy 1=caster 25=any 21=ally...
    constexpr size_t ImplicitA1      = 0x15C;
    constexpr size_t NamePtr         = 0x220;
    constexpr size_t GcdCategory     = 0x234;  // StartRecoveryCategory (0 = no GCD)
    constexpr size_t GcdMs           = 0x238;  // StartRecoveryTime (exact GCD!)
    constexpr size_t FamilyName      = 0x240;
    constexpr size_t DmgClass        = 0x250;
    constexpr size_t PreventionType  = 0x254;  // 1 silence blocks, 2 pacify blocks
    constexpr size_t SchoolMask      = 0x284;
    constexpr size_t RuneCostId      = 0x288;  // SpellRuneCost.dbc row (241 = Icy Touch)
}

static uint32_t W(const uint8_t* r, size_t off) {
    return Mem::Read<uint32_t>((uintptr_t)(r + off));
}

// Per-sid cache: the rotation asks for the same handful of spells 20-30x a
// second, so a tiny open-address table keeps the steady state at one probe and
// zero decodes. It USED to be justified by "records are immutable for the
// session" - which stopped being true the moment SetProcChance made them
// writable, and a successful write then read back the STALE pack and looked
// like a failure (live: SetProcChance returned 1|35 while CastReq still said
// 35). File scope so the writer can invalidate.
static constexpr size_t kCastReqCacheN = 512;
struct CastReqSlot { int sid = 0; std::string pack; };
static CastReqSlot s_cache[kCastReqCacheN];
static constexpr size_t kCacheN = kCastReqCacheN;

void InvalidateCastReq(int spellId) {
    size_t h = ((uint32_t)spellId * 2654435761u) % kCastReqCacheN;
    if (s_cache[h].sid == spellId) { s_cache[h].sid = 0; s_cache[h].pack.clear(); }
}

std::string CastReq(int spellId) {
    // Per-sid cache: records are immutable for the session, and the rotation
    // asks for the same handful of spells 20-30x a second. A tiny open-address
    // table keeps the steady-state cost at one probe, zero decodes.
    static constexpr size_t kCacheN = 512;
    struct Slot { int sid = 0; std::string pack; };

    size_t h = ((uint32_t)spellId * 2654435761u) % kCacheN;
    if (s_cache[h].sid == spellId && !s_cache[h].pack.empty())
        return s_cache[h].pack;

    char buf[1024];
    uint8_t recb[kRecBytes] = {};
    int rc = DecodeRecord((uint32_t)spellId, recb);
    if (rc <= 0) {
        snprintf(buf, sizeof(buf), "sid=%d|found=%d", spellId, rc);
        return std::string(buf);   // not cached: the table may still be loading
    }
    uint32_t ri = 0;
    uint32_t re = RangeEntry(recb, &ri);
    float minH = 0.f, maxH = 0.f;
    if (re) {
        minH = Mem::Read<float>((uintptr_t)(re + 0x04));
        maxH = Mem::Read<float>((uintptr_t)(re + 0x0C));
        if (maxH < 0.0f || maxH > 500.0f) maxH = Mem::Read<float>((uintptr_t)(re + 0x10));
    }
    float speed = 0.f;
    { uint32_t sw = W(recb, rec::Speed); memcpy(&speed, &sw, 4); }
    snprintf(buf, sizeof(buf),
        "sid=%d|found=1|attr=0x%08X|attr1=0x%08X|attr2=0x%08X"
        "|stances=0x%08X|stancesnot=0x%08X|targets=0x%X|facing=%u"
        "|casterstate=%u|targetstate=%u|casteraura=%u|targetaura=%u"
        "|excaster=%u|extarget=%u"
        "|castidx=%u|cd=%u|catcd=%u|category=%u|interrupt=0x%X"
        "|power=%u|cost=%u|costlvl=%u|ri=%u|rmin=%.2f|rmax=%.2f|speed=%.1f"
        "|equipclass=%d|equipmask=0x%X|eff0=%u|ta0=%u|ta1=%u"
        "|gcdcat=%u|gcd=%u|family=%u|dmgclass=%u|prevent=%u"
        "|school=0x%X|rune=%u|mech=%u|dispel=%u|duridx=%u"
        "|procflags=0x%X|procchance=%u|proccharges=%u|chain=%u",
        spellId,
        W(recb, rec::Attr0), W(recb, rec::Attr1), W(recb, rec::Attr2),
        W(recb, rec::StancesLo), W(recb, rec::StancesNotLo),
        W(recb, rec::Targets), W(recb, rec::FacingFlags),
        W(recb, rec::CasterAuraState), W(recb, rec::TargetAuraState),
        W(recb, rec::CasterAuraSpell), W(recb, rec::TargetAuraSpell),
        W(recb, rec::ExCasterAura), W(recb, rec::ExTargetAura),
        W(recb, rec::CastTimeIdx), W(recb, rec::RecoveryMs),
        W(recb, rec::CatRecoveryMs), W(recb, rec::Category),
        W(recb, rec::InterruptFlags),
        W(recb, rec::PowerType), W(recb, rec::ManaCost),
        W(recb, rec::ManaCostPerLvl), ri, minH, maxH, speed,
        (int)W(recb, rec::EquipItemClass), W(recb, rec::EquipSubclass),
        W(recb, rec::Effect0), W(recb, rec::ImplicitA0), W(recb, rec::ImplicitA1),
        W(recb, rec::GcdCategory), W(recb, rec::GcdMs),
        W(recb, rec::FamilyName), W(recb, rec::DmgClass),
        W(recb, rec::PreventionType),
        W(recb, rec::SchoolMask), W(recb, rec::RuneCostId),
        W(recb, rec::Mechanic), W(recb, rec::Dispel), W(recb, rec::DurationIdx),
        W(recb, rec::ProcFlags), W(recb, rec::ProcChance), W(recb, rec::ProcCharges),
        // chain = the widest EffectChainTarget across the three effects.
        (std::max)((std::max)(W(recb, rec::ChainTarget0), W(recb, rec::ChainTarget1)),
                   W(recb, rec::ChainTarget2)));
    std::string out(buf);
    s_cache[h].sid = spellId;
    s_cache[h].pack = out;
    return out;
}

// SET A SPELL'S PROC CHANCE IN THE LIVE RECORD.
//
// The roll's INPUT, not its visual. Force-casting the proc's bolt only replayed
// the animation (live: lightning + sound, no damage) because the roll is
// evaluated elsewhere; procChance is what that evaluation reads.
//
// Only valid when records are UNCOMPRESSED (comp==0, which this client reports
// for every spell probed): then the table slot IS the live record and a write
// at slot+0x08C changes what the client evaluates. When compressed, the decoded
// buffer is a temporary copy and writing it would do nothing - so refuse rather
// than silently no-op, which is the failure mode this project keeps punishing.
//
// VERIFY-BEFORE-WRITE: the current value must look like a proc chance (0..101).
// Two write plans this session were built on addresses that measurement
// disproved in seconds; this one checks first and returns the old value so the
// caller can confirm it wrote what it meant to.
int SetProcChance(int spellId, int pct, int* outOld) {
    if (outOld) *outOld = -1;
    if (pct < 0 || pct > 101) return -2;              // out of range
    if (Mem::Read<uint8_t>(kSpellCompress)) return -3; // compressed: refuse
    uint32_t minS = Mem::Read<uint32_t>(kSpellTableGlob + 0x10);
    uint32_t maxS = Mem::Read<uint32_t>(kSpellTableGlob + 0xC);
    uint32_t tbl  = Mem::Read<uint32_t>(kSpellTableGlob + 0x20);
    if (!tbl || tbl < 0x10000u) return -4;
    if ((uint32_t)spellId < minS || (uint32_t)spellId > maxS) return -5;
    uint32_t slot = Mem::Read<uint32_t>(tbl + ((uint32_t)spellId - minS) * 4);
    if (!slot || slot < 0x10000u) return -6;          // no record
    uint32_t cur = Mem::Read<uint32_t>(slot + rec::ProcChance);
    if (cur > 101u) return -7;                        // not a proc chance: refuse
    if (outOld) *outOld = (int)cur;
    Mem::Write<uint32_t>(slot + rec::ProcChance, (uint32_t)pct);
    uint32_t back = Mem::Read<uint32_t>(slot + rec::ProcChance);
    InvalidateCastReq(spellId);   // the cached pack still holds the old chance
    RL::Log::Warn("SetProcChance sid=%d %u -> %d (readback %u)",
                  spellId, cur, pct, back);
    return (back == (uint32_t)pct) ? 1 : 0;           // 0 = write did not stick
}

std::string SpellName(int spellId) {
    uint8_t recb[kRecBytes] = {};
    if (DecodeRecord((uint32_t)spellId, recb) <= 0) return "";
    uint32_t p = Mem::Read<uint32_t>((uintptr_t)(recb + rec::NamePtr));
    if (!p || p < 0x10000u) return "";
    char name[128] = {};
    size_t n = Mem::ReadBytes((uintptr_t)p, (uint8_t*)name, sizeof(name) - 1);
    if (n == 0) return "";
    name[sizeof(name) - 1] = '\0';
    // stop at first non-printable byte: string pointers can dangle mid-load
    for (size_t i = 0; i < sizeof(name) - 1; ++i) {
        unsigned char c = (unsigned char)name[i];
        if (c == 0) break;
        if (c < 0x20) { name[i] = '\0'; break; }
    }
    return std::string(name);
}

} // namespace RL::Game::SpellDB
