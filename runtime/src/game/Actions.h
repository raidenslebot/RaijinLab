#pragma once
#include <cstdint>

namespace RL::Game::Actions {

// All player "do something" commands the addon must use exclusively via
// RuntimeCall — never FrameScript from Lua (Blizzard UI taint).

bool CastSpell(int spellId, uint64_t targetGuid, uint32_t flags = 0);
bool MoveTo(float x, float y, float z);
bool FaceDirection(float radians);

// NO-OP (2026-07-31, permanent). Writing HardwareEventFlag=1 at 0x00C21000 or
// TaintContext=0 at 0x00D4139C corrupts the game's Lua VM → AV_READ crash.
// PROVEN by isolation tests. The .text HW-gate patches (ApplyHardwareGatesOnly)
// are the actual gate bypass. Kept as a call site so existing callers compile;
// writes NOTHING to client memory.
void SoftHardwareUnlock();

// ---- Authoritative cast gates (main-thread only) --------------------------
// flags for CanCast / CastSpellEx:
//   FACE_IF_NEEDED (1)  : TurnByDelta toward guid if not facing (no TargetUnit)
//   SKIP_IF_NOT_FACING (4): refuse without calling Spell_C if still not facing
//   CHECK_LOS (8)       : TraceLine refuse when blocked
constexpr uint32_t kCastFaceIfNeeded    = 1u;
constexpr uint32_t kCastNoTargetChange  = 2u; // documented for Lua; selection restore stays Lua
constexpr uint32_t kCastSkipIfNotFacing = 4u;
constexpr uint32_t kCastCheckLos        = 8u;
// ZERO-FRAME ACQUIRE (2026-08-02, HARD RULE): with this flag, Spell_C is called
// with guid=0 after writing the cast target into the player descriptor
// UNIT_FIELD_TARGET. guid=0 cast-at-current-target does NOT trigger the async
// client-selection pick that Spell_C(guid) does — so the client target is
// NEVER selected, not even for one frame (the "deferred revert after" hack was
// explicitly rejected). The descriptor is restored immediately after.
constexpr uint32_t kCastNoAcquire       = 16u;

// Result packed for Lua: "1|ok" or "0|facing" / "0|los" / "0|oor" / "0|cast_fail" / ...
// (multi-return is unreliable on this client — always a single string.)
struct CastGateResult {
    bool ok;
    const char* reason;    // static string, never heap
    double cooldownMs;     // remaining cooldown milliseconds (0 when reason != "cooldown")
    const char* busyState; // authoritative busy state when reason == "busy" ("casting"/"channeling"/"targeting")
};

// Live face toward unit (TurnByDelta + CommitMovement). Does NOT change selection.
bool FaceTowardGuid(uint64_t guid);
// Fail-closed face check (half-angle rad, default π/2 = WotLK 180° front).
bool IsFacingGuid(uint64_t guid, float halfArcRad = 1.5707963f);
// Pre-wire gates only (no Spell_C). reason always set.
CastGateResult CanCast(int spellId, uint64_t targetGuid, uint32_t flags);
// Optional face + gates + Spell_C. SKIP/LOS only apply when those flags are set.
// Default multi-dot flags = NO_TARGET_CHANGE only (Lua owns soft face/ready).
CastGateResult CastSpellEx(int spellId, uint64_t targetGuid, uint32_t flags);

// ---- Native-frame cast queue (2026-08-02, structural crash fix) -----------
// THE WHOLE POINT: Spell_C must NEVER execute with a Lua callback frame on the
// stack (proven: 0x512B07 VM corruption when called from inside the bridge).
// The Lua bridge therefore STAGES a cast into this FIFO and returns immediately
// (QueueCast = never touches Spell_C). The NATIVE frame hook (NativeHook.cpp,
// on the game's object-generation ticker, main thread, no Lua) DRAINS it and
// runs Spell_C from pure native context. Semantics are identical to CastSpell's
// proven core (action-state zero, descriptor-only restore, deferred client-
// selection restore) — only the execution context changes.
//
// QueueCast: push a cast. Returns true if queued, false if full/too old.
// Cast at `targetGuid` WITHOUT ever selecting it as the client target.
// Pins the player descriptor UNIT_FIELD_TARGET, calls Spell_C(spellId, 0)
// (guid=0 = cast at current/specified target via descriptor, NO async client-
// selection pick), restores descriptor. Client selection never touched, not
// even a frame. Runs directly (normal stack) — NOT from the frame-tick thunk.
bool CastSpellNoAcquire(int spellId, uint64_t targetGuid);

bool QueueCast(int spellId, uint64_t targetGuid, uint32_t flags);
// Drain the queue (call from the native frame hook, NOT from Lua). Executes up
// to kCastQueueDrainMax casts per call to bound frame time.
void DrainCastQueue();
// Number of casts currently staged (for diagnostics). 0 = idle.
int PendingCastCount();

bool Jump();                 // one-shot hop (land lip)
bool StopMoving();
// Swim vertical is HELD like forward/strafe - not a one-shot pulse.
// Ascend: JumpOrAscendStart / AscendStop. Descend: SitStandOrDescendStart / DescendStop.
bool Ascend(bool start);
bool Descend(bool start);
bool MoveForward(bool start);
bool PitchUp(bool start);
bool PitchDown(bool start);
bool MoveBackward(bool start);
bool StrafeLeft(bool start);
bool StrafeRight(bool start);
bool TurnLeft(bool start);
bool TurnRight(bool start);

// Mouselook / camera-yaw steering - the analog, human turn (RE-verified).
bool MouselookStart();
bool MouselookStop();
int  IsMouselooking();          // 1 = on, 0 = off, -1 = unreadable
float CameraYaw();              // current smoothed camera yaw (rad); 1e9 on failure
float CameraTargetYaw();        // target yaw the client eases toward
bool SetCameraYaw(float rad);   // write target yaw (client eases applied toward it)
bool CommitMovement();          // push heading/movement state to the server
bool MouseMove(int dx, int dy); // synthesize a relative OS mouse move (mickeys)

// In-process yaw turn - rotate the character without the OS mouse or cursor capture.
bool TurnByDelta(float deltaRad); // + = left/CCW, radians this frame; server-synced
float PlayerFacing();             // live camera-independent facing (rad); 1e9 on fail

// ---- Deferred protected actions (2026-08-02, native carrier) --------------
// CRITICAL: calling the client's protected APIs (MoveForwardStart/Stop,
// Strafe*/Turn*Stop, MouselookStop, StartAttack via Spell_C(6603), ...) from a
// Lua-dispatched RuntimeCall pops "RaijinLab has been blocked from an action
// only available to the Blizzard UI" — the client treats bridge-origin calls as
// addon taint regardless of the HW-gate patch. The user's ABSOLUTE DIRECTIVE:
// NO protected action runs from a Lua callback frame. These APIs therefore
// STAGE the action and the NATIVE frame hook (TickHookBody, main thread, no
// Lua on the stack) executes it. Returns true when staged.
//
// Halt: release every held movement key + stop + commit, natively. Used by the
// suite disable path (was calling MoveForward(false)... from Lua -> taint).
bool RequestHaltMovement();
// Engage auto-attack (Spell_C(6603)) from the NATIVE hook — never from the Lua
// bridge (the client treats bridge-origin 6603 as protected "StartAttack" and
// pops the blocked-action dialog; the log shows "Attack engage nrc=0" every
// engage attempt). Stages the target GUID; the hook drains it. Returns true
// when staged (or already attacking the same target).
bool RequestAttackEngage(uint64_t targetGuid);
// Native engage core for an explicit GUID (drained by the hook).
bool AttackTargetFor(uint64_t targetGuid);
void DrainDeferredActions();   // call from the native frame hook (idempotent)
// 2026-08-02 (BLOCKED-DIALOG FIX, 1.10.81): zero the client's "addon blocked"
// cast counter (0xD3F604) every frame from the native hook. SafeNativeCast
// resets it after each cast, but the walk's async origin-check can still bump
// it past 10 and fire the native blocked dialog (0x530840) — a frame-level
// reset guarantees it never reaches the threshold.
void ResetBlockedCastCounter();   // call from the native frame hook

// Target / combat / interact — CRASH RULE (permanent): all of these are NATIVE
// descriptor writes or no-ops. Nested lua_pcall (TargetUnit/ClearTarget/
// StartAttack) and C-side FSExec from inside the bridge both hard-crash the
// client. TargetGuid/ClearTarget write UNIT_FIELD_TARGET (player+desc+0x48),
// which IS client selection. AttackTarget casts the native Attack ability (6603).
bool TargetGuid(uint64_t guid);
bool TargetByName(const char* name); // NO-OP: addon resolves names→GUIDs (Lua)
bool TargetToken(const char* unitToken); // NO-OP: addon resolves tokens→GUIDs (Lua)
bool ClearTarget();
bool TargetLastTarget(); // NO-OP: CastSpell restores selection natively
bool AttackTarget();     // native Spell_C(6603, targetGuid)
bool InteractGuid(uint64_t guid);
bool InteractTarget();
bool StopAttack();       // NO-OP: client ends swings on range/death
bool SpellStopCasting(); // native/guarded — never FSExec while inside bridge

// Run arbitrary protected-looking Lua from C (origin "*") — last resort.
// Prefer named helpers above.
bool ExecSecure(const char* luaCode);

// Arm hardware-event gate patches once after inject (safe subset).
void ArmUnlock();

// Feed current lua_State from Dispatch for nested CastSpellByID pcall.
void SetCurrentLuaState(void* L);

// Delayed client-selection restore for NOTGT / acquire-OFF GUID casts. Spell_C
// selects the victim ASYNC (next frame) so the immediate post-cast restore
// misses it; call this on EVERY Pulse (next bridge call) and it restores the
// previous selection the moment the async pick lands — "cast without targeting".
void PulseSelectionRestore();

} // namespace RL::Game::Actions
