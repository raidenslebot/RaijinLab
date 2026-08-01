#pragma once
#include <cstdint>

namespace RL::Game::GameTime {

// Init: sample GetTime() + QPC once. Call after Lua state is available.
void Init();

// Current game time in seconds (same clock as Lua GetTime()).
// Sub-microsecond precision via QPC interpolation between samples.
// Falls back to calling Lua GetTime() if sampling hasn't occurred.
double Now();

// Re-sample from Lua GetTime() to correct QPC drift (call ~every 10s).
void Resync();

// Remaining cooldown for a spell in milliseconds.
// Reads GetSpellCooldown via Lua pcall (once per resync cycle for hot spells).
// Returns 0 if ready, -1 if unreadable.
double CooldownRemainingMs(int spellId);

} // namespace RL::Game::GameTime
