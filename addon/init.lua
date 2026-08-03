local frame = CreateFrame("FRAME")

frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("VARIABLES_LOADED")
-- 2026-08-02 (blocked-action diagnostics): register on the ALWAYS-ALIVE core
-- frame (not the rotation frame, which is destroyed on stop) so every protected
-- call that pops "RaijinLab has been blocked from an action only available to
-- the Blizzard UI" is logged with the exact function name in the dev log.
-- ADDON_ACTION_FORBIDDEN is the other protected-call signal (in-combat,
-- different arg shape) — capture both.
frame:RegisterEvent("ADDON_ACTION_BLOCKED")
frame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
-- PLAYER_LOGOUT fires right before WoW writes SavedVariables; we flush + sanitize
-- the DB there so a clean exit always captures the latest rotation state.
frame:RegisterEvent("PLAYER_LOGOUT")
-- PLAYER_LEAVING_WORLD fires on /reload and on the transition to character-select
-- (which is when Ascension's client also serializes SavedVariables). Belt-and-
-- suspenders flush so a mid-session exit path can't lose the active rotation.
frame:RegisterEvent("PLAYER_LEAVING_WORLD")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
-- frame:RegisterEvent("CRITERIA_UPDATE")
frame:RegisterEvent("TRACKED_ACHIEVEMENT_UPDATE")
frame:RegisterEvent("QUEST_ACCEPTED")
frame:RegisterEvent("QUEST_FINISHED")
frame:RegisterEvent("QUEST_LOG_UPDATE")
-- The taxi window opening is the only moment the client will hand us this
-- character's full flight map, so it is where the travel network is learned.
frame:RegisterEvent("TAXIMAP_OPENED")
-- Meeting a merchant is the only reliable moment to learn where one IS, and
-- whether it can repair - neither is discoverable from a distance.
frame:RegisterEvent("MERCHANT_SHOW")
-- Dying is the one event we cannot afford to miss: the corpse position must be
-- persisted immediately or a ghost can end up permanently stranded.
frame:RegisterEvent("PLAYER_DEAD")
-- The spirit healer's resurrect dialog is the only moment we can learn where one
-- stands - and a ghost that cannot reach its corpse depends on knowing.
frame:RegisterEvent("CONFIRM_XP_LOSS")
-- Standing at a class trainer is the only moment we can see what is learnable.
frame:RegisterEvent("TRAINER_SHOW")
-- Watchdog progress signals: unambiguous evidence the run is advancing.
frame:RegisterEvent("QUEST_TURNED_IN")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("LOOT_OPENED")

frame:SetScript("OnEvent", RaijinLab.CoreOnEvent)
frame:SetScript("OnUpdate", RaijinLab.CoreOnUpdate)

RaijinLab.core_frame = frame
