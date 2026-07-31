#pragma once
#include <cstdint>

namespace RL::Game::Actions {

// All player "do something" commands the addon must use exclusively via
// RuntimeCall — never FrameScript from Lua (Blizzard UI taint).

bool CastSpell(int spellId, uint64_t targetGuid);
bool MoveTo(float x, float y, float z);
bool FaceDirection(float radians);
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
