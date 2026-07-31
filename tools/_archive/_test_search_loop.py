from pathlib import Path

p = Path(r"C:\Ascension\Workspace\RaijinLab\tests\run_suite_tests.py")
s = p.read_text(encoding="utf-8")

anchor = "-- ---- THE BUDGET MUST NOT COLLAPSE"
# put it in the search test group instead
anchor2 = None
i = s.find("def test_search_behavior")
assert i > 0
# find that group's lua body start
j = s.find('lua.execute(', i)
# find an assertion helper name in that group
import re
m = re.search(r"local function (\w+)\(name, cond\)", s[i:i+4000])
assert m, "search test helper not found"
helper = m.group(1)

# append the loop-breaker test at the end of the group's lua body
# find the LAST lua.execute block end for this test function
k = s.find("def test_", i + 10)
seg = s[i:k]
last_q = seg.rfind('"""')
# the body closes with """ then ) - insert before that
insert_at = i + seg.rfind('\n', 0, last_q)

BLOCK = '''
-- ---- THE SAME-WALL LOOP MUST BREAK ---------------------------------------
-- Live failure this reproduces: 18 of 18 destination choices were the identical
-- cell, each one a march into the same building. Two causes, both fixed and
-- both pinned here:
--   (1) best() knew no geometry, so a cell inside a building could win forever.
--   (2) a failed leg did not drain the field, so the same cell stayed best.
do
    local f = SF.new({})
    f:seed(0, 0, { radius = 200 })
    -- a huge spike of belief at one spot, as the live field had
    f:add(100, 0, 50)

    -- (1) the oracle vetoes it: best() must pick somewhere ELSE and must not
    -- keep resurfacing the vetoed cell on later calls
    local bx1 = select(1, f:best(0, 0, { oracle = function(x, y)
        if math.abs(x - 100) < 30 and math.abs(y) < 30 then return false end
        return nil
    end }))
    local far1 = bx1 == nil or math.abs(bx1 - 100) >= 30
    ''' + helper + '''("a geometry-vetoed cell cannot win best()", far1)

    -- (2) failure drains: without an oracle, repeated unreachable() at the spike
    -- must eventually move best() off it
    local g = SF.new({})
    g:seed(0, 0, { radius = 200 })
    g:add(100, 0, 50)
    local first = select(1, g:best(0, 0, {}))
    for _ = 1, 6 do g:unreachable(100, 0) end
    local second = select(1, g:best(0, 0, {}))
    local moved = (second == nil) or (first == nil)
        or math.abs(second - first) > 20
    ''' + helper + '''("an unreachable target stops being the best target", moved)
end
'''
s = s[:insert_at] + BLOCK + s[insert_at:]
p.write_text(s, encoding="utf-8")
print("search-loop tests added to", helper, "group")
