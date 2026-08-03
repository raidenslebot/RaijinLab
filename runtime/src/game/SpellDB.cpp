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
    if (ri < minR || ri > maxR)
        ri = Mem::Read<uint32_t>((uintptr_t)(decoded + 0x214));
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

} // namespace RL::Game::SpellDB
