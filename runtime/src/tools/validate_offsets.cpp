// Offline PE validator — maps Ascension.exe and pattern-scans .text
#include "core/Patterns.h"
#include "game/AddressDB.h"
#include "core/Log.h"
#include <Windows.h>
#include <cstdio>
#include <vector>
#include <fstream>
#include <string>
#include <cstring>

static bool MapExe(const char* path, std::vector<uint8_t>& image, uintptr_t& preferredBase) {
    HANDLE hf = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    if (hf == INVALID_HANDLE_VALUE) return false;
    DWORD sz = GetFileSize(hf, nullptr);
    if (sz == INVALID_FILE_SIZE || sz < 0x400) { CloseHandle(hf); return false; }
    std::vector<uint8_t> file(sz);
    DWORD rd = 0;
    if (!ReadFile(hf, file.data(), sz, &rd, nullptr) || rd != sz) { CloseHandle(hf); return false; }
    CloseHandle(hf);

    auto dos = (PIMAGE_DOS_HEADER)file.data();
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return false;
    auto nt = (PIMAGE_NT_HEADERS)(file.data() + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return false;
    preferredBase = nt->OptionalHeader.ImageBase;
    size_t imageSize = nt->OptionalHeader.SizeOfImage;
    if (imageSize < sz || imageSize > 64 * 1024 * 1024) return false;
    image.assign(imageSize, 0);
    DWORD hdrCopy = nt->OptionalHeader.SizeOfHeaders;
    if (hdrCopy > sz) hdrCopy = sz;
    memcpy(image.data(), file.data(), hdrCopy);
    auto sec = IMAGE_FIRST_SECTION(nt);
    for (int i = 0; i < nt->FileHeader.NumberOfSections; ++i) {
        if (!sec[i].PointerToRawData || !sec[i].SizeOfRawData) continue;
        if ((size_t)sec[i].VirtualAddress + sec[i].SizeOfRawData > imageSize) continue;
        if (sec[i].PointerToRawData + sec[i].SizeOfRawData > sz) continue;
        memcpy(image.data() + sec[i].VirtualAddress,
               file.data() + sec[i].PointerToRawData,
               sec[i].SizeOfRawData);
    }
    return true;
}

// IS THIS THE START OF A FUNCTION, OR JUST SOMEWHERE INSIDE ONE?
//
// PrologueLooksValid answers "do these bytes look like code", which is far too
// weak to validate a CALL TARGET: it accepts a bare 0x8B (mov), so it matches
// almost anywhere in .text. Proof - corrupting a verified handler address by
// THREE BYTES still passed. A gate that cannot detect a wrong address is not a
// gate, it is decoration.
//
// The discriminator is what comes BEFORE. A function start is preceded by the
// end of the previous function or by alignment padding: ret (C3), ret n (C2 xx
// xx), int3 padding (CC), or nop padding (90). Landing mid-function almost never
// satisfies that, which is exactly the error we need to catch.
static bool IsFunctionStart(uintptr_t buf, uintptr_t preferred, size_t imageSize,
                            unsigned va) {
    if (va < preferred || (va - preferred) + 16 >= imageSize) return false;
    uintptr_t at = buf + (va - preferred);
    if (!RL::Patterns::PrologueLooksValid(at)) return false;
    const uint8_t* p = reinterpret_cast<const uint8_t*>(at);
    // A FULL FRAME PROLOGUE IS ITS OWN EVIDENCE.
    //
    // `push ebp; mov ebp,esp` is the standard function entry and does not occur
    // by accident at a call target. Requiring a preceding ret/padding on top of
    // it produced a FALSE NEGATIVE on lua_pushnil (0x0084E280): the address is
    // correct - it opens with 55 8B EC - but it is preceded by a JUMP TABLE
    // rather than by code, so the "what comes before" rule could not see it.
    // Data before a function is normal; demand the preceding terminator only
    // when the prologue itself is one of the weak single-byte forms.
    if (p[0] == 0x55 && p[1] == 0x8B && p[2] == 0xEC) return true;
    if ((va - preferred) < 4) return true;          // start of image: nothing before
    uint8_t m1 = p[-1];
    if (m1 == 0xC3 || m1 == 0xCC || m1 == 0x90) return true;   // ret / int3 / nop
    if (p[-3] == 0xC2) return true;                            // ret imm16
    if (m1 == 0xE9 || m1 == 0xEB) return true;                 // tail jmp
    return false;
}

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1]
                                : "C:\\Ascension\\Launcher\\resources\\ascension-live\\Ascension.exe";
    CreateDirectoryA("C:\\Ascension\\Workspace\\logs", nullptr);
    RL::Log::Init("C:\\Ascension\\Workspace\\logs\\validate.log");
    std::printf("RaijinLabValidate: %s\n", path);

    std::vector<uint8_t> image;
    uintptr_t preferred = 0;
    if (!MapExe(path, image, preferred)) {
        std::printf("FAILED to map PE\n");
        RL::Log::Error("map failed");
        return 1;
    }
    std::printf("base=0x%08X size=0x%X\n", (unsigned)preferred, (unsigned)image.size());

    uintptr_t buf = (uintptr_t)image.data();
    auto results = RL::Patterns::ResolveAllEx(buf, image.size(), preferred);

    int ok = 0, bad = 0;
    FILE* rep = nullptr;
    fopen_s(&rep, "C:\\Ascension\\Workspace\\logs\\validate_report.txt", "w");
    if (rep) fputs("# signature report (offline)\n", rep);

    for (auto& r : results) {
        uintptr_t va = 0;
        if (r.matchedPattern) {
            uintptr_t rva = r.address - buf;
            va = preferred + rva;
            // prologue already checked against mapped buffer
        } else {
            va = r.address; // fallback absolute
            // re-check prologue against mapped image
            if (va >= preferred && (va - preferred) + 16 < image.size()) {
                r.prologueOk = RL::Patterns::PrologueLooksValid(buf + (va - preferred));
            } else {
                r.prologueOk = false;
            }
        }
        std::printf("%-32s VA=0x%08X pat=%d prol=%d\n", r.name.c_str(), (unsigned)va,
                    (int)r.matchedPattern, (int)r.prologueOk);
        if (rep)
            fprintf(rep, "%s\t0x%08X\tpat=%d\tprol=%d\n", r.name.c_str(), (unsigned)va,
                    (int)r.matchedPattern, (int)r.prologueOk);
        if (r.prologueOk) ++ok;
        else ++bad;
    }
    // ---- RAW CALL TARGETS -------------------------------------------------
    //
    // Pattern signatures cover the addresses we RESOLVE. They say nothing about
    // the ones we HARDCODE and then call through a function pointer - and a
    // wrong constant there is not a compile error, it is a call into whatever
    // happens to live at that VA. Until now the only way to find out was to
    // inject into a live client and see whether it crashed.
    //
    // Every address below is dereferenced as code by the runtime. Checking them
    // against the real Ascension.exe offline turns "built, hope it is right"
    // into a verifiable fact before the DLL is ever injected.
    struct Raw { const char* name; unsigned va; };
    static const Raw kRaw[] = {
        // Lua C API used by InteractUnitDirect / CastViaLuaPCall
        { "lua_settop",       (unsigned)RL::Game::Addr::lua_settop },
        { "lua_gettop",       (unsigned)RL::Game::Addr::lua_gettop },
        { "lua_pushstring",   (unsigned)RL::Game::Addr::lua_pushstring },
        { "lua_getfield",     (unsigned)RL::Game::Addr::lua_getfield },
        { "lua_pcall",        (unsigned)RL::Game::Addr::lua_pcall },
        { "lua_type",         (unsigned)RL::Game::Addr::lua_type },
        { "lua_pushnumber",   (unsigned)RL::Game::Addr::lua_pushnumber },
        { "lua_pushnil",      (unsigned)RL::Game::Addr::lua_pushnil },
        // The interact path (replaces the forbidden ClickToMove route)
        { "HANDLER_InteractUnit",       0x00527F00 },
        // Movement input primitives - all held-key start/stop pairs
        { "MoveForwardStart",           0x005FC200 },
        { "MoveForwardStop",            0x005FC250 },
        { "MoveBackwardStart",          0x005FC290 },
        { "MoveBackwardStop",           0x005FC2E0 },
        { "TurnLeftStart",              0x005FC320 },
        { "TurnLeftStop",               0x005FC360 },
        { "TurnRightStart",             0x005FC3B0 },
        { "TurnRightStop",              0x005FC3F0 },
        { "StrafeLeftStart",            0x005FC440 },
        { "StrafeLeftStop",             0x005FC490 },
        { "StrafeRightStart",           0x005FC4D0 },
        { "StrafeRightStop",            0x005FC520 },
        { "JumpOrAscendStart",          0x005FBF80 },
        { "AscendStop",                 0x005FC0A0 },
        { "SitStandOrDescendStart",     0x0051B1D0 },
        { "DescendStop",                0x005FC140 },
        // Swim/fly pitch
        { "PitchUpStart",               0x005FC8E0 },
        { "PitchUpStop",                0x005FC570 },
        { "PitchDownStart",             0x005FC920 },
        { "PitchDownStop",              0x005FC5C0 },
        // Steering / camera
        { "MouselookStart",             0x005FCC10 },
        { "MouselookStop",              0x005FC890 },
        { "MovementApply",              0x005FBBC0 },
        { "TurnByDelta",                0x005FB4B0 },
        // Quest + cast
        { "GetQuestInteractType",       0x00744640 },
        { "Spell_C_CastSpell",          0x0080DA40 },
    };
    std::printf("\n-- raw call targets --\n");
    if (rep) fputs("\n# raw call targets\n", rep);
    for (const auto& e : kRaw) {
        bool inRange = e.va >= preferred && (e.va - preferred) + 16 < image.size();
        bool prol = IsFunctionStart(buf, preferred, image.size(), e.va);
        std::printf("%-32s VA=0x%08X prol=%d%s\n", e.name, e.va, (int)prol,
                    inRange ? "" : "  <-- OUTSIDE IMAGE");
        if (rep) fprintf(rep, "%s\t0x%08X\tprol=%d\n", e.name, e.va, (int)prol);
        if (prol) ++ok; else ++bad;
    }

    if (rep) fclose(rep);
    std::printf("summary ok=%d bad=%d\n", ok, bad);
    RL::Log::Info("summary ok=%d bad=%d", ok, bad);
    RL::Log::Shutdown();
    return bad ? 2 : 0;
}
