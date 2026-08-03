#pragma once
#include <cstdint>
#include <string>

namespace RL::Game::SpellDB {

// LIVE PER-ABILITY SPELL DATA (2026-08-02) -- pure-memory reads of the
// client's loaded Spell.dbc records. RE-verified against the client:
//   * Record is 0x2A8 bytes; RLE-compressed when [0xC5DEA0] != 0, raw
//     otherwise (client 0x4CFD20 -> 0x4CFBB0). Both paths replicated here.
//   * decoded+0x10  = Attributes   (0x80CD11: bit 0x40 = passive, refuse cast)
//   * decoded+0x214 = RangeIndex   (0x540BA4 & 0x5209D3 validate against the
//                                   range store [0xAD48AC])
//   * range store: [0xAD489C]=min idx, [0xAD4898]=max, [0xAD48AC]=array of
//     pointers; rangeEntry = [base + (ri-min)*4].
//
// Full record dump for layout ground truth. Format:
//   "sid=N|found=1|mode=0/1|comp=0/1|attr=0x%08X|attr2=0x%08X|ri=N|re=0x%08X|
//    alt=N|re0..re7=0x%08X|hex=<decoded hex>"
std::string SpellInfoLive(int spellId);

// Authoritative melee/facing classification + exact max range for a spell.
// Returns "found=1|melee=0/1|ri=N|id=N|flags=0x%08X|max=%.2f" so the Lua
// rotation replaces its maxR>8 heuristic with client truth. Facing is required
// only for melee-range spells (range entry MaxRange <= 8).
std::string SpellMeleeInfo(int spellId);

} // namespace RL::Game::SpellDB
