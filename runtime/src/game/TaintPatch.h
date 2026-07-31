#pragma once

namespace RL::Game::Taint {

// Optional FrameScript taint bypass (binary patches only).
// Ported from WowAutoSDK lua_unlocker.cpp with byte verification.
// Enable via config: taint.patch=1

bool Apply();
void Restore();
bool IsApplied();
int PatchCount();

// Safe subset: only HardwareEventFlag JE->JMP / JNE->NOP.
// Required for Spell_C_CastSpell / CastSpellByID when not a real HW event.
// Does NOT touch VM taint, EventHandler, or TaintErrorReporter (those froze clients).
bool ApplyHardwareGatesOnly();
bool HardwareGatesApplied();
int HardwareGateCount();

} // namespace RL::Game::Taint
