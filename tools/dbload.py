"""Load the vendored RaijinQuest database EXACTLY as the client's TOC does, with
no pfQuest code, and prove the tables QuestDB reads are really there.

WHY THIS EXISTS. RaijinQuest ships as an addon: a database plus the UI that
queries it. We use only the database - the UI half is deliberately not loaded
(it threw a cascade of errors when vendored, and this client is 32-bit: a crash
dump showed 1.8GB of a 2GB address space with 140MB of Lua). That is a real
saving, but it means the database now loads in a configuration its authors never
shipped, and NOTHING ELSE TESTS IT: the simulator's TOC loader skips the whole
vendored tree on purpose (it is data, not our source), so a missing <Include>, a
patch that indexes a table we dropped, or a locale file the merge loop needs
would sail through every other gate and only show up as a dead bot in-game.

So this walks the four XML manifests in TOC order, executes each Lua file the way
the client would, runs the Ascension patch on top, and then asserts the shape
QuestDB actually depends on - including one full end-to-end lookup with a known
answer, so a database that loads but answers nothing still fails.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RQ = os.path.join(ROOT, "addon", "RaijinQuest")

# TOC order. These are the manifests RaijinLab.toc actually lists; addon.xml (the
# pfQuest UI) is absent by design - see the comment block in RaijinLab.toc.
MANIFESTS = [
    os.path.join(RQ, "init", "data.xml"),
    os.path.join(RQ, "init", "enUS.xml"),
    os.path.join(RQ, "ascension", "init", "data-ascension.xml"),
    os.path.join(RQ, "ascension", "init", "enUS-ascension.xml"),
]
PATCH = os.path.join(RQ, "ascension", "patchtable.lua")

# The five tables QuestDB reads, and the field it needs from each.
REQUIRED = [
    ("units", "data"), ("objects", "data"), ("items", "data"),
    ("quests", "data"), ("zones", "data"),
    ("units", "loc"), ("objects", "loc"), ("zones", "enUS"),
]

# A lookup with a known answer, verified against the raw tables:
#   "Scavenger Paw" is LOOT - no unit carries that name, so perception could
#   never find it. item 3265 drops from units 1508/1509, which spawn in zone 85
#   (Tirisfal Glades). If this resolves, the data path works end to end.
PROBE_ITEM = "Scavenger Paw"
PROBE_UNIT = 1508          # Young Scavenger, a dropper of it
PROBE_ZONE = 85
PROBE_ZONE_NAME = "Tirisfal Glades"   # what GetRealZoneText is stubbed to return

# (zone name -> the id QuestDB.current_zone must return). Names are NOT unique in
# the database, and picking the wrong id silently produces coordinates for a
# different place - the failure mode that once put `map=1240 solved=true` on the
# same log line as `no_known_location`.
ZONE_PROBES = [
    (PROBE_ZONE_NAME, PROBE_ZONE),
    ("Blackrock Mountain", 254),   # 25/254/1445; only 254 has a rect
    ("The Bulwark", 152),          # 152/813; both real, lowest id wins
]


def manifest_files(path):
    """The .lua files an XML manifest includes, in order."""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        body = fh.read()
    out = []
    for rel in re.findall(r'file="([^"]+)"', body):
        out.append(os.path.normpath(os.path.join(
            os.path.dirname(path), rel.replace("\\", "/"))))
    return out


def build_lua():
    """A Lua state with the handful of client globals the database files touch."""
    from lupa import LuaRuntime
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("""
        GetLocale = function() return "enUS" end
        GetAddOnMetadata = function() return nil end
        -- the db files are data, but the patch and init touch these
        CreateFrame = function() return setmetatable({}, {__index=function()
            return function() end end}) end
        UnitName = function() return "Probe" end
        GetRealZoneText = function() return "Tirisfal Glades" end
        print = function() end
    """)
    return lua


def load_database(lua, verbose=False):
    """Execute every manifest file, then the Ascension patch. Returns byte count."""
    total = 0
    for man in MANIFESTS:
        if not os.path.exists(man):
            raise SystemExit("FAIL: manifest missing: %s" % man)
        for f in manifest_files(man):
            if not os.path.exists(f):
                raise SystemExit(
                    "FAIL: %s includes a file that does not exist: %s"
                    % (os.path.basename(man), f))
            with open(f, "r", encoding="utf-8", errors="replace") as fh:
                src = fh.read()
            total += len(src)
            try:
                lua.execute(src)
            except Exception as exc:  # the whole point of the gate
                raise SystemExit("FAIL: %s did not load: %s" % (f, exc))
            if verbose:
                print("  loaded %-46s %6.1f KB"
                      % (os.path.basename(f), len(src) / 1024.0))

    # NOTHING IS FABRICATED HERE ON PURPOSE.
    #
    # This used to create RaijinQuestDB.locales because the patch iterates it -
    # and that hid a real defect for a whole session: the global lived in
    # database.lua, which the TOC no longer loads, so in the actual client
    # patchtable.lua threw on pairs(nil) and the name shortcuts were never built.
    # The gate was green while the shipped addon could not resolve a single name.
    # A harness that supplies a missing dependency is testing itself.

    with open(PATCH, "r", encoding="utf-8", errors="replace") as fh:
        src = fh.read()
    try:
        lua.execute(src)
    except Exception as exc:
        raise SystemExit("FAIL: patchtable.lua did not run: %s\n"
                         "       (it indexes tables that data.xml must load, and "
                         "it must not call into the unloaded UI)" % exc)
    return total


def check_shape(lua):
    """Assert the tables QuestDB reads exist AND are populated."""
    bad = []
    for tbl, field in REQUIRED:
        n = lua.eval("""(function()
            local t = RaijinQuestDB and RaijinQuestDB["%s"]
            t = t and t["%s"]
            if type(t) ~= "table" then return -1 end
            local n = 0
            for _ in pairs(t) do n = n + 1 end
            return n
        end)()""" % (tbl, field))
        n = int(n)
        if n < 0:
            bad.append("RaijinQuestDB[%r][%r] is missing" % (tbl, field))
        elif n == 0:
            bad.append("RaijinQuestDB[%r][%r] is EMPTY" % (tbl, field))
        else:
            print("  %-16s %7d entries" % ("%s.%s" % (tbl, field), n))
    return bad


def check_probe(lua):
    """Exercise the REAL QuestDB against the real database.

    Loading the module rather than reimplementing its lookups is the point: an
    earlier version of this gate replicated the logic and would have stayed green
    while QuestDB.current_zone() silently returned nil for every zone, because it
    still called into the UI we stopped loading. A gate that reimplements the
    thing it is guarding only ever tests itself.
    """
    qdb = os.path.join(ROOT, "addon", "modules", "questing", "QuestDB.lua")
    lua.execute("RaijinLab = RaijinLab or {}")
    with open(qdb, "r", encoding="utf-8", errors="replace") as fh:
        try:
            lua.execute(fh.read())
        except Exception as exc:
            return ["QuestDB.lua did not load: %s" % exc]

    bad = []

    def call(expr):
        try:
            return lua.eval("(function() local ok, a, b, c = pcall(function() "
                            "return %s end) if not ok then return nil, a end "
                            "return a, b, c end)()" % expr)
        except Exception as exc:
            return (None, str(exc))

    if not lua.eval("RaijinLab.QuestDB and RaijinLab.QuestDB.available()"):
        return ["QuestDB.available() is false against a fully loaded database"]

    # name -> id, by the module's own index
    item_id = call('RaijinLab.QuestDB.name_to_id("%s", "items")' % PROBE_ITEM)
    item_id = item_id[0] if isinstance(item_id, tuple) else item_id
    if item_id is None:
        bad.append("QuestDB.name_to_id(%r, 'items') returned nil" % PROBE_ITEM)
    else:
        print("  name_to_id       %r -> item %d" % (PROBE_ITEM, int(item_id)))

    # the lookup perception can never do: loot -> the mobs that drop it
    n = call('(function() local s = RaijinLab.QuestDB.item_sources("%s") '
             'return s and #s or -1 end)()' % PROBE_ITEM)
    n = int((n[0] if isinstance(n, tuple) else n) or -1)
    # to_world_points needs a solved transform, which needs a live position, so
    # offline this correctly yields zero PLACED points - what matters is that the
    # raw chain resolved at all.
    raw = call('(function() local id = RaijinLab.QuestDB.name_to_id("%s","items") '
               'if not id then return -1 end '
               'local it = RaijinQuestDB.items.data[id] '
               'if not (it and it.U) then return -1 end '
               'local t = 0 '
               'for u in pairs(it.U) do '
               '  local sp = RaijinLab.QuestDB.unit_spawns_raw(u) '
               '  if sp then t = t + #sp end end return t end)()'
               % PROBE_ITEM)
    raw = int((raw[0] if isinstance(raw, tuple) else raw) or -1)
    if raw <= 0:
        bad.append("QuestDB.unit_spawns_raw found no spawns for droppers of %r"
                   % PROBE_ITEM)
    else:
        print("  item_sources     %d raw spawn(s) (%d placed offline - no "
              "transform yet, expected)" % (raw, max(n, 0)))

    # THE ZONE ID. This is what broke silently when the UI stopped loading.
    #
    # 46 zone names are ambiguous, so both halves of the tie-break are pinned:
    #   Blackrock Mountain (25, 254, 1445) - only 254 has a rect in zones.data,
    #     so the "prefer a zone we can actually place" rule must pick it even
    #     though 25 is lower.
    #   The Bulwark (152, 813) - BOTH are real, so only the lowest-id rule
    #     decides. Without this case the tie-break is untestable: a mutation
    #     flipping it to highest-id passed every other check.
    for name, expect in ZONE_PROBES:
        lua.execute('GetRealZoneText = function() return "%s" end' % name)
        lua.execute("RaijinLab.QuestDB._zone_idx = nil")   # force a rebuild
        zid = call("RaijinLab.QuestDB.current_zone()")
        zid = zid[0] if isinstance(zid, tuple) else zid
        if zid is None:
            bad.append("QuestDB.current_zone() returned nil for %r - spawns are "
                       "keyed by this id, so nil here means no coordinates at all"
                       % name)
        else:
            print("  current_zone     %-20r -> %d" % (name, int(zid)))
            if int(zid) != expect:
                bad.append("current_zone() gave %d for %r, expected %d"
                           % (int(zid), name, expect))

    # id -> name, the object manager's only source of names on 3.3.5
    nm = call('RaijinLab.QuestDB.entry_name(%d, "units")' % PROBE_UNIT)
    nm = nm[0] if isinstance(nm, tuple) else nm
    if not nm:
        bad.append("QuestDB.entry_name(%d,'units') returned nil" % PROBE_UNIT)
    else:
        print("  entry_name       unit %d -> %r" % (PROBE_UNIT, nm))

    return bad


def main():
    verbose = "-v" in sys.argv
    try:
        import lupa  # noqa: F401
    except ImportError:
        print("SKIP: lupa not installed")
        return 0

    print("Loading RaijinQuest as DATA ONLY (no pfQuest code)...")
    lua = build_lua()
    nbytes = load_database(lua, verbose)
    print("  %.1f MB of Lua parsed\n" % (nbytes / 1048576.0))

    bad = check_shape(lua) + check_probe(lua)
    print("")
    if bad:
        for b in bad:
            print("FAIL: %s" % b)
        return 1
    print("PASS: database loads standalone and answers a known query")
    return 0


if __name__ == "__main__":
    sys.exit(main())
