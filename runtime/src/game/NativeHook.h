#pragma once
#include <cstdint>
#include <string>

// ===========================================================================
// NativeHook — real native detour/trampoline engine (2026-08-02)
// ===========================================================================
// Goal: run the runtime's code on the game's NATIVE main thread with NO Lua
// callback on the stack, so Spell_C / target / movement writes can execute
// safely (they corrupt the Lua VM when invoked from inside Lua_IsLinuxClient).
//
// This is a minimal x86 detour: overwrite the first N bytes of a target game
// function with an absolute JMP to our handler, preserving the original bytes
// in a trampoline so the original function still works when the handler calls
// through. VEH-guarded (Guard::Scope) and VirtualQuery-guarded for page
// writes — never raw deref, never dead __try.
//
// The trampoline is emitted into a VirtualAlloc'd executable code cave
// (PAGE_EXECUTE_READWRITE). All patches are tracked and Restore-able.
//
// SAFETY MODEL (permanent):
//   * Hooks are CONFIG-GATED (config: native.hook.<name>=1) — nothing is
//     installed unless explicitly enabled, so a bad hook can never crash a
//     normal session.
//   * The handler must be re-entrant and must NOT call Lua.
//   * The patched instruction run must be relocated exactly (length >= 5,
//     no partial control-flow inside the moved window).
//   * VEH Guard::Scope wraps every entry so a fault in the handler is caught
//     and the hook self-disables rather than crashing the client.
// ===========================================================================

namespace RL::Game::NativeHook {

// Install a detour: `target` (game function) jumps to `handler`; `trampoline`
// out-param receives the original-function entry to call through.
// Returns true on success. target must be executable, len>=5, handler non-null.
bool Install(uintptr_t target, void* handler, uintptr_t* trampoline, const char* name);

// Remove a previously installed detour (restore original bytes).
bool Uninstall(uintptr_t target);

// True if a detour is currently installed at `target`.
bool IsHooked(uintptr_t target);

// ---- Frame tick counter hook (0x7E5120) ------------------------------------
// 0x7E5120 is `inc dword ptr [0xd380a4]; ret` — a CANDIDATE per-frame tick
// counter, NOT verified. It is therefore CONFIG-GATED (native.hook.frame_tick
// must equal "1") and OFF BY DEFAULT: a normal session can never be touched by
// an unverified hook. `force=true` bypasses the gate for explicit dev testing
// and must be logged loudly. After patching we READ BACK the bytes to verify
// the detour actually landed on our thunk; if not, we uninstall immediately.
bool InstallFrameTickHook(bool force = false);  // idempotent; safe to repeat
bool UninstallFrameTickHook();

// Diagnostic snapshot (packed, pipe-friendly): whether the hook is active,
// whether it has ever fired, which thread ID fired it LAST, how many of those
// firings were on the MAIN thread (0 = not yet set / unknown), and the
// observed min/avg/max inter-tick interval in ms. This is what tells us
// whether 0x7E5120 is really the main-thread per-frame pump or something that
// fires on a render/worker thread (which would be a smoking gun).
std::string FrameTickDiag();

// Set the game MAIN thread id (from a context known to be on it, e.g. the
// bridge dispatch, which runs inside the Lua VM on the main thread).
void SetMainThreadId(uint32_t tid);

// Non-blocking frame rate in frames/sec. First call returns 0 ("warming");
// after >=400ms of wall time between calls it returns the observed rate.
// Does NOT sleep the game thread (Sleep here would freeze the very ticks we
// are measuring). Callers poll this from their own cadence.
int FrameRateDelta();

// Cumulative ticks observed since the tick hook was installed (0 if not).
uint64_t FrameTickCount();

// Disable all native hooks (restore originals). Called on runtime teardown.
void Shutdown();

} // namespace RL::Game::NativeHook
