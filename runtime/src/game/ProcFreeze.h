#pragma once
// ProcFreeze — client-memory control of proc-ICD / proc-buff persistence
// (Stormbringer-class Enhancement procs). ALL writes are to client memory
// (aura expiry fields); ZERO packets are emitted — a proc is client-authoritative,
// so forcing the roll / shortening the ICD sends byte-identical packets to a
// naturally-occurring proc. The server cannot distinguish them.
//
// WHY A PROC NEEDS THIS AND A CAST COOLDOWN DOESN'T:
//   Spell 273056 (Stormbringer) has cd=0/category=0/gcd=0 in its record and
//   GetSpellCooldown=0 (live-proven). Its "cooldown" is NOT in the cast-cooldown
//   table 0xD3F5AC — it is an INTERNAL COOLDOWN (ICD) carried by a hidden buff
//   on the player. The proc rolls on melee; when it 'succeeds' it applies the
//   active buff (which also gates the ICD). Two levers, both pure-memory:
//     * freeze  — keep the active proc-buff's aura expiry rolling forward so it
//                 never expires (retain-the-effect-forever mode).
//     * cycle   — set the proc-buff expiry to now+cycleMs every frame, so the
//                 "ICD" becomes 0.3s (each proc is re-ready 0.3s later).
//
// SAFETY: every write is a VirtualQuery-guarded Mem::Write to the aura expiry.
// The module only acts when >=1 spell id is registered via Add(). Default OFF.
// Runs on the game main thread (from the frame hook / IpcPoll) — never a
// background thread.
#include <cstdint>

namespace RL::Game::ProcFreeze {

// Register a spell id to act on. mode: 1=freeze (never expires),
// 0=cycle (expiry = now+cycleMs each frame). Returns true if added/updated.
bool AddSpell(uint32_t spellId, int mode, uint32_t cycleMs);

// Remove a registered spell id.
bool RemoveSpell(uint32_t spellId);

// Clear all registrations (fully disable).
void ClearAll();

// Run one pass on the local player. Returns the number of auras mutated this
// call. Safe to call every frame.
int Tick();

// Diagnostic state, packed for the pipe: "n|<sid>:<mode>:<cycleMs>|...".
std::string State();

} // namespace RL::Game::ProcFreeze
