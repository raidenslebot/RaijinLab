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

// EVERY static gate input for one spell, from the client's own record.
//
// LAYOUT, cracked 2026-08-03 against 17 stock spells with textbook 3.3.5a
// values (Fireball 13+1d9 base points, Backstab dagger mask 0x8000, Icy Touch
// school 16 + runeCostID 241, melee GCD 1000 vs caster 1500, family names
// mage=3/warrior=4/rogue=8/warlock=5/DK=15 all landing exactly):
//   the decoded record is Spell.dbc columns 0..135 at word*4, then the four
//   localized string blocks collapsed to 4 POINTERS (+0x220 name / +0x224
//   rank / +0x228 desc / +0x22C tooltip), then columns 204..233 resuming at
//   +0x230. That collapse is exactly the 64 dropped words: 4 fields x 17
//   locale columns -> 4 pointers.
//
// One call, one packed line, cached per sid (records are immutable in a
// session). This is what makes BasicRules data-driven for EVERY ability
// including Ascension customs - no name lists, no English substrings.
std::string CastReq(int spellId);

// The spell's display name via the in-record string pointer (+0x220).
std::string SpellName(int spellId);

// Set a spell's procChance in the LIVE record (record offset 0x08C, derived
// from the cracked layout and confirmed by 11 spells reading 101 = "always").
// Returns 1 written+verified, 0 write did not stick, negative = refused:
//   -2 pct out of range   -3 records compressed (decoded buffer is a copy)
//   -4 no spell table     -5 id out of range     -6 no record for this id
//   -7 current value is not a plausible proc chance (>101)
int SetProcChance(int spellId, int pct, int* outOld = nullptr);

} // namespace RL::Game::SpellDB
