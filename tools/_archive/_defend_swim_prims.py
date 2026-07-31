from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\tests\run_suite_tests.py")
s = p.read_text(encoding="utf-8")

# extend the navigator group with a functional Actions swim-primitive check
A = 'nc("norm negative wraps"'
assert A in s, "navigator anchor not found"
BLOCK = '''-- ---- SWIM PRIMITIVES ARE HOLDS, NOT PULSES -------------------------------
-- The mutation harness flagged Ascend/Descend as DECORATIVE: nothing failed
-- when they were renamed away. These drive the REAL Actions.lua with a mocked
-- runtime and pin the contract the swim controller depends on - Ascend(true)
-- issues AscendStart and Ascend(false) issues AscendStop, so depth control can
-- HOLD the key. A one-shot Jump pulse cannot hold depth: the client only rises
-- while ascend is held, which is exactly why these exist.
do
    local calls = {}
    RaijinLab.RuntimeCall = function(_, name) calls[#calls + 1] = name; return 1 end
    RaijinLab.HasRuntime = function() return true end
    local Act = RaijinLab.Actions
    nc("Actions.Ascend exists", Act and type(Act.Ascend) == "function")
    nc("Actions.Descend exists", Act and type(Act.Descend) == "function")
    if Act and Act.Ascend and Act.Descend then
        calls = {}
        Act.Ascend(true);  nc("Ascend(true) -> AscendStart", calls[#calls] == "AscendStart")
        Act.Ascend(false); nc("Ascend(false) -> AscendStop", calls[#calls] == "AscendStop")
        Act.Descend(true); nc("Descend(true) -> DescendStart", calls[#calls] == "DescendStart")
        Act.Descend(false); nc("Descend(false) -> DescendStop", calls[#calls] == "DescendStop")
    end
end

''' + A
if "SWIM PRIMITIVES ARE HOLDS" not in s:
    s = s.replace(A, BLOCK, 1)

p.write_text(s, encoding="utf-8")
print("navigator group: swim primitive tests added")

# does the navigator group load Actions.lua? check and report
i = s.index("def test_navigator")
seg = s[i:i + 2500]
print("loads Actions.lua:", "Actions.lua" in seg)

# terrain_probe span: source guard (the function is a local; a unit test cannot
# reach it without driving the whole tick, and the SPAN is the contract)
g = Path(r"C:\Ascension\Workspace\RaijinLab\tools\_rebuild_main.py")
t = g.read_text(encoding="utf-8")
A2 = '    guard("DisableCTM.lua ships", (ADDON / "core/DisableCTM.lua").exists())'
N2 = '''    navigator_src = rd("core/Navigator.lua")
    # terrain_probe is a file-local; its span contract cannot be reached by a
    # unit test without driving the whole tick, and the mutation harness proved
    # nothing else defends it. The span is what keeps deep water from being
    # green-lit ahead and reclassified as airborne on arrival.
    guard("terrain_probe passes its span to GroundCache",
          "GC.ground(ax, ay, pz, nil, 3.0, span)" in navigator_src)

''' + A2
if "terrain_probe passes its span" not in t:
    assert A2 in t, "guard anchor not found"
    t = t.replace(A2, N2, 1)
    g.write_text(t, encoding="utf-8")
    print("generator: terrain_probe span guard added")
