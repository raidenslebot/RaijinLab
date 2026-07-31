#pragma once
#include <cstdint>

namespace RL::Game::Actions {

// All player "do something" commands the addon must use exclusively via
// RuntimeCall — never FrameScript from Lua (Blizzard UI taint).

bool CastSpell(int spellId, uint64_t targetGuid);
bool MoveTo(float x, float y, float z);
bool FaceDirection(float radians);

// ---- Authoritative cast gates (main-thread only) --------------------------
// flags for CanCast / CastSpellEx:
//   FACE_IF_NEEDED (1)  : TurnByDelta toward guid if not facing (no TargetUnit)
//   SKIP_IF_NOT_FACING (4): refuse without calling Spell_C if still not facing
//   CHECK_LOS (8)       : TraceLine refuse when blocked
constexpr uint32_t kCastFaceIfNeeded    = 1u;
constexpr uint32_t kCastNoTargetChange  = 2u; // documented for Lua; selection restore stays Lua
constexpr uint32_t kCastSkipIfNotFacing = 4u;
constexpr uint32_t kCastCheckLos        = 8u;

// Result packed for Lua: "1|ok" or "0|facing" / "0|los" / "0|oor" / "0|cast_fail" / ...
// (multi-return is unreliable on this client — always a single string.)
struct CastGateResult {
    bool ok;
    const char* reason; // static string, never heap
};

// Live face toward unit (TurnByDelta + CommitMovement). Does NOT change selection.
bool FaceTowardGuid(uint64_t guid);
// Fail-closed face check (half-angle rad, default π/2 = WotLK 180° front).
bool IsFacingGuid(uint64_t guid, float halfArcRad = 1.5707963f);
// Pre-wire gates only (no Spell_C). reason always set.
CastGateResult CanCast(int spellId, uint64_t targetGuid, uint32_t flags);
// Optional face + gates + Spell_C. Never wire if SKIP_IF_NOT_FACING and not facing.
CastGateResult CastSpellEx(int spellId, uint64_t targetGuid, uint32_t flags);
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

// Target / combat / interact (C-side FrameScript_Execute — not addon taint)
bool TargetGuid(uint64_t guid);
bool TargetByName(const char* name);
// Unit token (nameplate1, target, boss1, ...) — preferred for Ascension; hex GUID
// TargetUnit is not reliably accepted on all private-server builds.
bool TargetToken(const char* unitToken);
bool ClearTarget();
// Restore previous selection (stock TargetLastTarget) after GUID cast.
bool TargetLastTarget();
bool AttackTarget();
bool InteractGuid(uint64_t guid);
bool InteractTarget();
bool StopAttack();
bool SpellStopCasting();

// Run arbitrary protected-looking Lua from C (origin "*") — last resort.
// Prefer named helpers above.
bool ExecSecure(const char* luaCode);

// Arm hardware-event gate patches once after inject (safe subset).
void ArmUnlock();

// Feed current lua_State from Dispatch for nested CastSpellByID pcall.
void SetCurrentLuaState(void* L);

} // namespace RL::Game::Actions
