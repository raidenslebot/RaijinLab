// ===========================================================================
// LdeHarness — verifies the REAL compiled RL::Lde::LengthOf (from Lde.h, the
// exact header the runtime uses) against a Capstone reference over the entire
// .text of Ascension.exe.
//
// Build (run after tools/lde_ref.py has generated _lde_ref.bin):
//   cl /nologo /O2 /EHsc /I ..\runtime\src tools\lde_harness.cpp /Fe:tools\lde_harness.exe
// Run:
//   tools\lde_harness.exe <exe> <ref.bin>
// Exit 0 == 100% match. Exit 1 == mismatches (printed).
// ===========================================================================
#include "game/Lde.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static const uint32_t IMAGE_BASE = 0x400000;
static const uint32_t TEXT_OFF = 0x400;
static const uint32_t TEXT_VA = IMAGE_BASE + 0x1000;
static const uint32_t TEXT_SIZE = 0x5DD400;

int main(int argc, char** argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: lde_harness <exe> <ref.bin>\n");
        return 2;
    }
    FILE* f = std::fopen(argv[1], "rb");
    if (!f) { std::fprintf(stderr, "cannot open exe\n"); return 2; }
    std::fseek(f, 0, SEEK_END);
    long sz = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> file(sz);
    if (std::fread(file.data(), 1, (size_t)sz, f) != (size_t)sz) { return 2; }
    std::fclose(f);
    if ((size_t)(TEXT_OFF + TEXT_SIZE) > file.size()) {
        std::fprintf(stderr, "exe too small\n");
        return 2;
    }
    const uint8_t* text = file.data() + TEXT_OFF;

    FILE* r = std::fopen(argv[2], "rb");
    if (!r) { std::fprintf(stderr, "cannot open ref.bin\n"); return 2; }
    struct Entry { uint32_t va; uint8_t len; };
    std::vector<Entry> ref;
    for (;;) {
        uint8_t b[5];
        if (std::fread(b, 1, 5, r) != 5) break;
        Entry e;
        e.va = (uint32_t)b[0] | ((uint32_t)b[1] << 8) |
               ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
        e.len = b[4];
        ref.push_back(e);
    }
    std::fclose(r);

    size_t checked = 0, mismatches = 0, shown = 0;
    for (const auto& e : ref) {
        uint32_t fo = TEXT_OFF + (e.va - TEXT_VA);
        if (fo + 16 > (uint32_t)file.size()) continue;
        int mine = RL::Lde::LengthOf(file.data() + fo, 0, 16);
        checked++;
        if (mine != (int)e.len) {
            mismatches++;
            if (shown < 30) {
                shown++;
                std::printf("MISMATCH va=0x%08X capstone=%d mine=%d bytes=",
                            e.va, (int)e.len, mine);
                for (int k = 0; k < e.len + 4 && k < 16; ++k)
                    std::printf("%02X ", file.data()[fo + k]);
                std::printf("\n");
            }
        }
    }
    std::printf("checked %zu instructions, %zu mismatches\n", checked, mismatches);
    if (mismatches == 0) {
        std::printf("COMPILED C++ DECODER PROVEN CORRECT against capstone\n");
        return 0;
    }
    std::printf("COMPILED C++ DECODER NOT CORRECT\n");
    return 1;
}
