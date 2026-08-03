-- Input hooks.
--
-- CreateJumpHook REMOVED 2026-08-03. It replaced the PROTECTED global
-- JumpOrAscendStart with an addon closure. Saving and re-assigning a protected
-- global from addon Lua is a taint source - the same rule already documented in
-- API.lua's UnlockMovement/LockMovement, which were made no-ops for exactly
-- this reason and then violated here. It had NO callers, so it was never the
-- active taint source, but a dead function that taints the client the moment
-- anything calls it is a bomb, not dead code.
--
-- Multijump, if it returns, routes through RaijinLab.Actions (the runtime) like
-- every other movement primitive. Nothing in this addon may write a protected
-- global - see the `taint` rule in the project directive: assume everything
-- non-runtime and native is protected.

return true
