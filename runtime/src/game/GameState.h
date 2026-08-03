#pragma once
#include <cstdint>

// ===========================================================================
// AUTHORITATIVE player/spell state — pure client-memory reads (RE-verified
// 2026-08-01). Zero Lua, zero game-handler calls, zero HardwareEventFlag
// dependency, zero __try (VirtualQuery-guarded via Mem::Read). These are the
// same fields the client's OWN Lua handlers read; reading them directly gives
// the addon authoritative answers that are NEVER blocked by the hardware-event
// gate / protected-call layer (the root cause of the auto-attack re-fire loop:
// Lua IsCurrentSpell(6603) no-ops from insecure addon code, so the rotation
// re-cast Attack every 0.35s and the client reported busy + blocked actions).
//
// RE sources (Ascension 12340, .text):
//   IsCurrentSpell internal 0x805f30 walks a linked list of the player's
//     current spells. Head = [0xAF5254]. Node: +0x20 = spellId(u32),
//     +0x04 = next(u32). 6603 (Attack) is present in this list while the
//     player is auto-attacking — that is exactly IsCurrentSpell(6603)==true.
//   UnitCastingInfo handler 0x00611DF0 reads player fields:
//     +0xA6C = casting spell id (0 = not casting)
//     +0xA7C = cast END game-time (ms, same clock as GetTime())
//     +0xA70/+0xA74 = cast target GUID (low/high)
//   SpellIsTargeting handler 0x007FDCD0 returns 1 when [0xD3F4E4] != 0.
//   Auto-repeat (wand/auto-shot): [0xD397D0] = auto-repeat spell id.
//   Current/used spell: [0xD397CC] = last/current spell id.
//   Attack target GUID: player + 0xA20/0xA24 (8 bytes; from IsCurrentSpell
//     internal 0x806030 slot-78 Attack branch).
// ===========================================================================

namespace RL::Game::State {

// Current game time in MILLISECONDS, same clock the client's UnitCastingInfo
// uses for cast-end comparisons. Calls the client's read-only GetTime
// (0x86AE20) in a standalone __try guard — the time object at [0xD4159C] is
// permanently valid so this never faults under stealth.
int64_t GameTimeMs();

// True while the player's current-spell list contains `spellId`
// (authoritative IsCurrentSpell — NOT the HW-gated Lua API).
bool IsCurrentSpell(uint32_t spellId);

// True while auto-attacking (IsCurrentSpell(6603)).
bool IsAutoAttacking();

// GUID the player is currently attacking (player+0xA20/0xA24), 0 if none.
uint64_t AttackTargetGuid();

// Auto-repeat (wand / auto-shot) spell id, 0 if off. [0xD397D0]
uint32_t AutoRepeatSpellId();

// Last/current used spell id. [0xD397CC]
uint32_t CurrentSpellUsed();

// True while a spell-targeting cursor is active. [0xD3F4E4]
bool IsSpellTargeting();

// Player casting: 0 = not casting, else the casting spell id (player+0xA6C,
// still in progress per cast-end time). Channeling reports through the same
// fields in this client.
int CastingSpellId();
int64_t CastingEndMs();
uint64_t CastingTargetGuid();

// Packed cast state for the bridge: "free" | "attacking" | "casting" |
// "channeling" | "targeting". `attacking` (auto-attack engaged) is NOT busy
// for real spells — a real cast interrupts attack normally.
void CastStatePacked(char* buf, size_t n);

// Full packed diagnostic (for the addon + crash forensics):
//   "cast=<sid>|end=<ms>|tgt=0xGUID|attack=0|1|atk_tgt=0xGUID|auto=id|cur=id|tgt=0|1|time=ms"
void FullStatePacked(char* buf, size_t n);

} // namespace RL::Game::State
