"""Bind a simulated World to the globals the real addon calls.

Two fidelity rules, both learned by getting them wrong first:

1. A PYTHON CALLABLE CANNOT RETURN LUA MULTI-VALUES. lupa collapses them to one.
   That is not cosmetic: GetQuestLogTitle returns nine values and the addon reads
   the ninth (questID), so a collapsed return made every quest log parse as EMPTY
   and the simulated bot idled for 420 simulated seconds looking perfectly
   healthy - the exact "wrong shape certifies a broken bot" failure this harness
   exists to prevent. Use `gm` for anything multi-valued: it packs with an
   explicit count (embedded nils would otherwise truncate) and a Lua shim unpacks
   it back into real multiple returns.

2. MOCK THE RUNTIME BOUNDARY, NOT THE API ABOVE IT. Overriding
   RaijinLab:ObjectPosition does nothing - the addon's own API.lua defines it at
   load time and overwrites the override, so the mock silently disappears. The
   real boundary is the single global RaijinLab_Runtime(cmd, ...) returning packed
   strings; see runtime_bridge.py.

Movement is applied by the WORLD from held key state, never by teleporting the
player: the addon steers by holding keys and reading its heading back, so a bridge
that set positions directly would be testing itself.
"""
from __future__ import annotations

from .runtime_bridge import RuntimeBridge
from .world import World

NL = chr(10)


class Bridge:
    def __init__(self, lua, world: World):
        self.lua = lua
        self.w = world
        self.calls: dict[str, int] = {}
        self.runtime: RuntimeBridge | None = None
        self._sel = 1

    # ---------------------------------------------------------------- utils
    def _count(self, name: str) -> None:
        self.calls[name] = self.calls.get(name, 0) + 1

    def g(self, name: str, fn) -> None:
        """A global returning a SINGLE value."""
        def wrapped(*a, **kw):
            self._count(name)
            return fn(*a, **kw)
        self.lua.globals()[name] = wrapped

    def gm(self, name: str, fn) -> None:
        """A global returning MULTIPLE Lua values (see rule 1 above)."""
        pyname = "__py_" + name
        lua = self.lua

        def wrapped(*a):
            self._count(name)
            res = fn(*a)
            if res is None:
                return None
            if not isinstance(res, tuple):
                res = (res,)
            t = lua.eval("function(n) return { n = n } end")(len(res))
            for i, v in enumerate(res, 1):
                t[i] = v
            return t

        lua.globals()[pyname] = wrapped
        lua.execute(
            "function " + name + "(...)" + NL +
            "  local t = " + pyname + "(...)" + NL +
            "  if t == nil then return nil end" + NL +
            "  return unpack(t, 1, t.n)" + NL +
            "end"
        )

    @property
    def unhandled(self):
        return self.runtime.unhandled if self.runtime else {}

    @property
    def files(self):
        return self.runtime.files if self.runtime else {}

    # ------------------------------------------------------------- install
    def install(self) -> None:
        # WoW's Lua 5.1 has a GLOBAL unpack; 5.2+ moved it to table.unpack and the
        # test harness runs 5.5. Same family of trap as math.atan2 and loadstring
        # in this project - provide the 5.1 name the addon (and the gm shim) expect.
        self.lua.execute("if not unpack then unpack = table.unpack end")
        self.lua.execute("if not loadstring then loadstring = load end")
        w = self.w
        p = w.player

        def unit_of(token):
            if token in ("player", "Player"):
                return p
            if token == "target":
                return w.unit(p.target) if p.target else None
            return w.unit(token) if isinstance(token, str) else None

        # ---- time / client ----
        self.g("GetTime", lambda: w.t)
        self.g("GetLocale", lambda: "enUS")
        self.g("GetRealmName", lambda: p.realm)
        self.gm("GetBuildInfo", lambda: ("3.3.5", "12340", "", 30300))
        self.g("GetMoney", lambda: 100000)

        # ---- units ----
        self.g("UnitHealth", lambda t: (unit_of(t).health if unit_of(t) else 0))
        self.g("UnitHealthMax", lambda t: (unit_of(t).max_health if unit_of(t) else 1))
        # Keyed BY INDEX: the custom-pool work (FelFury) depends entirely on
        # per-index values, and max == 0 means "this character has no such pool" -
        # a distinction the absent-pool guards rely on in both directions.
        self.g("UnitPower", lambda t, idx=None, *_: (
            p.powers.get(int(idx) if idx is not None else p.power_type, 0)
            if unit_of(t) is p else 0))
        self.g("UnitPowerMax", lambda t, idx=None, *_: (
            p.power_max.get(int(idx) if idx is not None else p.power_type, 0)
            if unit_of(t) is p else 0))
        self.gm("UnitPowerType", lambda t: (p.power_type, "MANA"))
        self.g("UnitMana", lambda t: (p.power if unit_of(t) is p else 0))
        self.g("UnitManaMax", lambda t: (p.max_power if unit_of(t) is p else 1))
        self.g("UnitPowerType", lambda t: 0)
        # -1 is the boss/skull sentinel the rotation classifies on.
        self.g("UnitLevel", lambda t: (unit_of(t).level if unit_of(t) else 0))
        self.gm("UnitName", lambda t: (
            None if unit_of(t) is None else
            ((p.name, None) if unit_of(t) is p else (unit_of(t).name, None))))
        self.g("UnitExists", lambda t: unit_of(t) is not None)
        self.g("UnitIsDeadOrGhost", lambda t: bool(
            getattr(unit_of(t), "dead", False) or getattr(unit_of(t), "ghost", False)))
        self.g("UnitIsDead", lambda t: bool(
            getattr(unit_of(t), "dead", False) and not getattr(unit_of(t), "ghost", False)))
        self.g("UnitIsGhost", lambda t: bool(getattr(unit_of(t), "ghost", False)))
        def _repop():
            # Corpse -> ghost at the same position (spirit runs from body).
            if p.dead and not p.ghost:
                p.ghost = True
            return True
        self.g("RepopMe", _repop)
        def _retrieve():
            if p.ghost:
                p.ghost = False
                p.dead = False
                p.health = p.max_health
            return True
        self.g("RetrieveCorpse", _retrieve)
        self.g("GetCorpseRecoveryDelay", lambda: 0)
        self.g("AcceptXPLoss", lambda: True)
        self.g("UnitAffectingCombat", lambda t: (p.in_combat if unit_of(t) is p else False))
        self.g("UnitCanAttack", lambda a, b: bool(getattr(unit_of(b), "hostile", False)))
        self.g("UnitIsEnemy", lambda a, b: bool(getattr(unit_of(b), "hostile", False)))
        self.g("UnitIsFriend", lambda a, b: not bool(getattr(unit_of(b), "hostile", False)))
        # Actions.guid_of() pattern-matches ^0[xX]%x+$ - a friendly name like
        # "duskbat1" is REJECTED, so targeting and interaction silently fail.
        self.g("UnitGUID", lambda t: (None if unit_of(t) is None else
                                      (w.guid_hex("player") if unit_of(t) is p
                                       else w.guid_hex(unit_of(t).guid))))
        self.gm("UnitClass", lambda t: ("Warrior", "WARRIOR", 1))
        self.gm("UnitRace", lambda t: ("Human", "Human", 1))
        def casting_info(t):
            if unit_of(t) is not p or not p.casting:
                return None
            # name, nameSubtext, text, texture, startTimeMS, endTimeMS,
            # isTradeSkill, castID, notInterruptible
            return (p.casting, "", p.casting, "icon",
                    (w.t - 0.5) * 1000.0, p.cast_ends * 1000.0, False, 1,
                    p.cast_uninterruptible)
        self.gm("UnitCastingInfo", casting_info)
        self.g("UnitChannelInfo", lambda t: None)
        self.g("UnitBuff", lambda *a: None)
        self.g("UnitDebuff", lambda *a: None)
        self.g("UnitAura", lambda *a: None)
        self.g("IsMounted", lambda: p.mounted)
        self.g("IsSwimming", lambda: p.swimming)
        self.g("IsIndoors", lambda: p.indoors)
        self.g("IsFalling", lambda: False)
        self.g("IsFlying", lambda: False)
        self.g("IsResting", lambda: False)
        # Breath mirror timer: only present while submerged (matches client).
        def mirror_timer(kind=None):
            kind = str(kind or "")
            if kind != "BREATH":
                return None
            if not p.swimming:
                return None
            wb = w.terrain.water_at(p.x, p.y, p.z)
            if not wb or p.z >= (wb.surface - 0.4):
                return None
            # name, value, maxvalue, scale, paused, label
            return ("BREATH", float(p.breath) * 1000.0, 1000.0, -1, 0, "Breath")
        self.gm("GetMirrorTimerInfo", mirror_timer)

        def target_unit(token):
            u = unit_of(token)
            p.target = None if (u is None or u is p) else u.guid
            return True
        self.g("TargetUnit", target_unit)
        self.g("ClearTarget", lambda: setattr(p, "target", None))
        self.g("AssistUnit", lambda *a: True)

        # ---- spells ----
        self.g("CastSpellByName", lambda name, *_: (
            w.casts.append((w.t, str(name))), True)[-1])
        self.gm("GetSpellInfo", lambda sid: (
            (w.spells.get(sid) or ("Spell%s" % sid)), "", "icon", 0, 0, 0, int(sid or 0)))
        self.gm("GetSpellCooldown", lambda *_: (0, 0, 1))
        self.gm("IsUsableSpell", lambda *_: (True, False))
        self.g("IsSpellKnown", lambda sid: int(sid) in w.known_spells)
        self.g("IsCurrentSpell", lambda *_: False)
        self.g("GetSpellBookItemInfo", lambda *a: None)
        self.g("GetNumSpellTabs", lambda: 0)

        # ---- skills (riding lives here on custom servers) ----
        self.g("GetNumSkillLines", lambda: len(w.skills))

        def skill_line(i):
            i = int(i)
            if 1 <= i <= len(w.skills):
                nm, hdr, rank = w.skills[i - 1]
                return (nm, hdr, None, rank)
            return None
        self.gm("GetSkillLineInfo", skill_line)

        # ---- companions: on 3.3.5 mounts are companions, NOT C_MountJournal ----
        self.g("GetNumCompanions", lambda kind: (len(w.companions) if kind == "MOUNT" else 0))

        def companion_info(kind, i):
            i = int(i)
            if kind == "MOUNT" and 1 <= i <= len(w.companions):
                c = w.companions[i - 1]
                return (c.get("creature", 1), c.get("name", "Mount"),
                        c.get("spell", 1), "icon", False)
            return None
        self.gm("GetCompanionInfo", companion_info)

        RIDING = {33388, 33391, 34090, 34091, 90265}

        def call_companion(kind, i):
            # Owning a mount is not permission to ride it. The client refuses
            # without the riding skill, and reproducing THAT refusal is the only
            # reason the mount scenario can exist at all.
            if not (w.known_spells & RIDING):
                return False
            p.mounted = True
            return True
        self.g("CallCompanion", call_companion)
        self.g("Dismount", lambda: setattr(p, "mounted", False))

        # ---- bags / items ----
        self.g("GetContainerNumSlots",
               lambda b: (len(w.bags[int(b)]) if 0 <= int(b) < len(w.bags) else 0))

        def container_link(b, s):
            b, s = int(b), int(s)
            if 0 <= b < len(w.bags) and 1 <= s <= len(w.bags[b]):
                it = w.bags[b][s - 1]
                return it["link"] if it else None
            return None
        self.g("GetContainerItemLink", container_link)
        self.gm("GetContainerItemInfo",
                lambda b, s: (None, 0, False, False, False, False, container_link(b, s)))
        self.g("GetInventoryItemLink", lambda unit, slot: w.equipped.get(int(slot)))
        self.gm("GetInventoryItemDurability", lambda slot: (100, 100))

        def item_info(link):
            key = str(link)
            meta = None
            for bag in w.bags:
                for it in bag:
                    if it and it.get("link") == key:
                        meta = it
            if meta is None:
                meta = w.item_meta.get(key)
            if meta is None:
                meta = {"name": key, "type": "Miscellaneous", "subtype": "Junk"}
            nm = meta.get("name", key)
            return (nm, nm, meta.get("quality", 1), 1, 1,
                    meta.get("type", "Miscellaneous"), meta.get("subtype", "Junk"),
                    1, "", "", meta.get("price", 0))
        self.gm("GetItemInfo", item_info)

        # ---- quest log ----
        self.gm("GetNumQuestLogEntries", lambda: (len(w.quests), len(w.quests)))

        def get_title(i):
            i = int(i)
            if not (1 <= i <= len(w.quests)):
                return None
            q = w.quests[i - 1]
            # title, level, tag, group, isHeader, isCollapsed, isComplete, isDaily, questID
            return (q["title"], 1, None, None, False, False,
                    q.get("isComplete"), False, q["questId"])
        self.gm("GetQuestLogTitle", get_title)

        self.g("SelectQuestLogEntry", lambda i: setattr(self, "_sel", int(i)))
        self.g("GetQuestLogSelection", lambda: self._sel)
        self.g("GetNumQuestLeaderBoards", lambda i=None: (
            len(w.quests[int(i or self._sel) - 1]["objectives"])
            if 1 <= int(i or self._sel) <= len(w.quests) else 0))

        def leaderboard(oi, i=None):
            qi, oi = int(i or self._sel), int(oi)
            if not (1 <= qi <= len(w.quests)):
                return None
            objs = w.quests[qi - 1]["objectives"]
            if not (1 <= oi <= len(objs)):
                return None
            o = objs[oi - 1]
            return (o["text"], o.get("type", "monster"), o.get("finished", False))
        self.gm("GetQuestLogLeaderBoard", leaderboard)
        self.g("GetQuestLogQuestText", lambda: "")
        # The accept / turn-in dialog path - previously absent entirely, so the
        # half of questing that actually completes a quest could not be simulated.
        self.g("IsQuestCompletable", lambda: bool(w.quest_frame.get("completable")))
        self.g("GetNumQuestChoices", lambda: int(w.quest_frame.get("choices", 0)))
        self.g("AcceptQuest", lambda: w.quest_events.append("AcceptQuest"))
        self.g("CompleteQuest", lambda: w.quest_events.append("CompleteQuest"))
        self.g("GetQuestReward", lambda i=None: w.quest_events.append("GetQuestReward"))
        self.g("DeclineQuest", lambda: w.quest_events.append("DeclineQuest"))
        self.g("GetNumActiveQuests", lambda: int(w.quest_frame.get("active", 0)))
        self.g("SelectActiveQuest", lambda i: w.quest_events.append("SelectActive:%s" % i))
        self.g("GetNumAvailableQuests", lambda: int(w.quest_frame.get("available", 0)))
        self.g("SelectAvailableQuest", lambda i: w.quest_events.append("SelectAvail:%s" % i))
        self.g("SelectGossipActiveQuest", lambda i: w.quest_events.append("GossipActive:%s" % i))
        self.g("SelectGossipAvailableQuest", lambda i: w.quest_events.append("GossipAvail:%s" % i))
        self.g("SelectGossipOption", lambda i, *a: w.quest_events.append("GossipOpt:%s" % i))
        self.g("CloseQuest", lambda: None)
        self.g("CloseGossip", lambda: None)
        self.g("AbandonQuest", lambda *a: True)

        # ---- merchant / gossip ----
        self.g("GetMerchantNumItems", lambda: 0)
        self.g("CanMerchantRepair", lambda: False)
        self.gm("GetRepairAllCost", lambda: (0, False))
        self.g("GetNumGossipOptions", lambda: 0)
        self.g("GetNumGossipActiveQuests", lambda: 0)
        self.g("GetNumGossipAvailableQuests", lambda: 0)

        self.install_frames()
        self.install_runtime()

    # -------------------------------------------------------------- frames
    def install_frames(self) -> None:
        self.lua.execute(
            """
__sim_addon_tbl = {}
SlashCmdList = {}
-- WoW ships BitLib as the global `bit`; the harness Lua does not, so
-- RunObjectManager's flag masking threw "attempt to index a nil value (global
-- 'bit')" on every tick - swallowed by __sim_pump's pcall, leaving
-- object_list.npcs permanently empty. Shipped addon code must stay Lua 5.1, so
-- it CANNOT use native bitwise operators; it uses this table, and so must we.
if not bit then
  bit = {}
  local function norm(x) return math.floor(x) % 4294967296 end
  function bit.band(a, b)
    a, b = norm(a), norm(b)
    local r, m = 0, 1
    while m <= 2147483648 and (a > 0 or b > 0) do
      if (a % 2 >= 1) and (b % 2 >= 1) then r = r + m end
      a, b, m = math.floor(a / 2), math.floor(b / 2), m * 2
    end
    return r
  end
  function bit.bor(a, b)
    a, b = norm(a), norm(b)
    local r, m = 0, 1
    while m <= 2147483648 and (a > 0 or b > 0) do
      if (a % 2 >= 1) or (b % 2 >= 1) then r = r + m end
      a, b, m = math.floor(a / 2), math.floor(b / 2), m * 2
    end
    return r
  end
  function bit.bxor(a, b)
    a, b = norm(a), norm(b)
    local r, m = 0, 1
    while m <= 2147483648 and (a > 0 or b > 0) do
      if (a % 2 >= 1) ~= (b % 2 >= 1) then r = r + m end
      a, b, m = math.floor(a / 2), math.floor(b / 2), m * 2
    end
    return r
  end
  function bit.bnot(a) return 4294967295 - norm(a) end
  function bit.lshift(a, n) return norm(norm(a) * (2 ^ n)) end
  function bit.rshift(a, n) return math.floor(norm(a) / (2 ^ n)) end
end

-- Objective name -> world point, the simulator's stand-in for RaijinQuest.
-- Populated from World.known so a scenario can say "the bot SHOULD know where
-- this is" without shipping 12MB of database into the harness.
__sim_known = {}

__sim_frames = {}
local function noop() end
function CreateFrame(kind, name, parent, tmpl)
  local f = { _scripts = {}, _events = {}, _shown = true }
  -- A FRAME IS NOT A FUNCTION FACTORY.
  --
  -- This returned noop for EVERY unknown key, so any addon that stores state on
  -- its own frame got a truthy function instead of nil. ObjectManagerOnUpdate
  -- does `if not self.last_time then self.last_time = 0 end` then adds elapsed:
  -- the guard saw a function (truthy), skipped the init, and threw "attempt to
  -- perform arithmetic on a function value (field 'last_time')" - swallowed by
  -- __sim_pump's pcall. RunObjectManager therefore NEVER RAN in the simulator,
  -- object_list.npcs stayed empty, and every quest-giver / objective scenario was
  -- silently testing a blind bot.
  --
  -- Unknown keys now read nil, like a real frame. Only actual widget METHODS get
  -- a no-op, and only if they were not defined explicitly below.
  -- Widget METHODS are PascalCase in this API (SetPoint, Show, CreateTexture);
  -- addon state stored on a frame is lower_case (last_time, _scripts). So an
  -- unknown Capitalised key gets a no-op method, and anything else reads nil the
  -- way a real table does. Enumerating a method list instead broke all 14
  -- scenarios - there are far more widget methods than one can list.
  local mt = { __index = function(t, k)
    if type(k) == "string" and k:match("^%u") then return noop end
    return nil
  end }
  function f:SetScript(k, fn) self._scripts[k] = fn end
  function f:GetScript(k) return self._scripts[k] end
  function f:HookScript(k, fn) self._scripts[k] = fn end
  function f:RegisterEvent(e) self._events[e] = true end
  function f:RegisterUnitEvent(e) self._events[e] = true end
  function f:UnregisterEvent(e) self._events[e] = nil end
  function f:UnregisterAllEvents() self._events = {} end
  function f:Show() self._shown = true end
  function f:Hide() self._shown = false end
  function f:IsShown() return self._shown end
  function f:IsVisible() return self._shown end
  function f:GetName() return name end
  function f:GetFrameStrata() return "MEDIUM" end
  function f:GetFrameLevel() return 1 end
  function f:GetText() return "" end
  function f:GetAttribute() return nil end
  function f:GetParent() return parent end
  function f:GetWidth() return 100 end
  function f:GetHeight() return 100 end
  function f:CreateFontString() return setmetatable({}, mt) end
  function f:CreateTexture() return setmetatable({}, mt) end
  setmetatable(f, mt)
  __sim_frames[#__sim_frames+1] = f
  return f
end
__sim_tickers = {}
C_Timer = {
  NewTicker = function(interval, fn)
    local t = { interval = interval, fn = fn, _cancelled = false }
    function t:Cancel() self._cancelled = true end
    __sim_tickers[#__sim_tickers+1] = t
    return t
  end,
  After = function(delay, fn)
    local t = { interval = delay, fn = fn, once = true, _cancelled = false }
    function t:Cancel() self._cancelled = true end
    __sim_tickers[#__sim_tickers+1] = t
    return t
  end,
}
-- SWALLOWED ERRORS ARE HOW THE HARNESS LIED FOR MONTHS.
--
-- Both loops below pcall'd and discarded the result, so anything that threw did
-- so once per tick, forever, invisibly. Three separate harness bugs hid here at
-- once (frame mock returning functions for unknown keys, no `bit` library, no
-- ObjectTypeFlags) and between them kept RunObjectManager from EVER running -
-- every scenario was quietly testing a bot that could not see a single object.
--
-- Errors are still caught (one bad handler must not abort the run) but they are
-- now RECORDED, de-duplicated by message, and readable via __sim_errors.
__sim_errors = {}
local function __sim_note(err)
  local k = tostring(err)
  if not __sim_errors[k] then
    __sim_errors[k] = 0
    __sim_errors[#__sim_errors + 1] = k
  end
  __sim_errors[k] = __sim_errors[k] + 1
end
function __sim_pump(now)
  for _, t in ipairs(__sim_tickers) do
    if not t._cancelled then
      t.next = t.next or (now + t.interval)
      if now >= t.next then
        t.next = now + t.interval
        local ok, err = pcall(t.fn)
        if not ok then __sim_note(err) end
        if t.once then t._cancelled = true end
      end
    end
  end
  for _, f in ipairs(__sim_frames) do
    local u = f._scripts and f._scripts.OnUpdate
    if u then
      local ok, err = pcall(u, f, __sim_dt or 0.033)
      if not ok then __sim_note(err) end
    end
  end
end
function __sim_fire(event, ...)
  for _, f in ipairs(__sim_frames) do
    if f._events and f._events[event] then
      local h = f._scripts and f._scripts.OnEvent
      if h then pcall(h, f, event, ...) end
    end
  end
end
UIParent = CreateFrame("Frame")
WorldFrame = CreateFrame("Frame")
function SendChatMessage() end
function PlaySound() end
function StaticPopup_Show() end
function InCombatLockdown() return false end
function GetCVar() return "0" end
function SetCVar() end
"""
        )

    # ------------------------------------------------------------- runtime
    def install_runtime(self) -> None:
        """Install the REAL boundary: one global returning packed strings."""
        self.runtime = RuntimeBridge(self.lua, self.w, counter=self._count)
        self.runtime.install()
