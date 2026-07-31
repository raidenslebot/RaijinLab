# ROADMAP 1.7 — Systemic Synthesis

Version target: addon 1.7 / runtime 1.7. Written 2026-07-21 after 3-lens structural audit
(cast pipeline, AC-vs-capability, coupling/lifecycle). This is **not** a bug list. All
bugs are audited. This is the sequenced set of structural work that moves the ceiling.

---

## 1. The three candidate ceilings

| Lens | Named weakness | Class |
|---|---|---|
| Cast pipeline | Executor is pull-based; validator is a same-frame snapshot with no `UNIT_SPELLCAST_SUCCEEDED` consumption | Efficiency / correctness |
| AC-vs-capability | Object Manager enum is dead (`om.enable=0` default, `npcs=0` from probe); world model is an 88-slot token straw | **Capability** |
| Coupling / lifecycle | No unload contract — `FrameScript_UnregisterFunction` is never called; addon's own liveness probe dereferences a freed DLL | Stability / dev-iteration |

## 2. Which one is actually the ceiling

**The ceiling is the AC-vs-capability lens: the OM enum is dead and the world model has < 10 units in it.**

The other two are downstream of that decision.

### Why cast-pipeline is downstream

The polling cost inside `World.build_context` is only "expensive" relative to a 40-key
context over 8 units. `Engine.evaluate`'s per-slot `deepcopy(ctx)` at `Engine.lua:241`
is only a real bottleneck if the ctx grows — which it will the moment we start tracking
auras and cast bars on 50 arbitrary GUIDs instead of 8 tokens. **Optimizing the poll
loop of a world model that is not real yet is premature.** The push-based `StateCache`
described in lens 1 becomes critical *after* OM ships, because then per-tick aura scans
scale with real enemy count and 5 Hz OnUpdate is no longer enough.

The lens-1 remediation stays in the roadmap, but it moves to **step 3**, not step 1.
Its priority is created by fixing OM, not by the current 8-unit world.

### Why coupling/lifecycle is downstream

The FrameScript dangling-pointer issue is a real crash-on-shutdown risk, but it does
not cap what the system can *do* today. It becomes structurally urgent the moment we
start iterating on new bridge handlers (`NearbyEnemies`, `UnitCastingByGuid`,
`UnitAuraByGuid`) — because *those are exactly the changes* that will require hot DLL
swaps and per-handler ABI negotiation. So the coupling fix is not premature either,
but its value is unlocked *by* shipping OM handlers, not before.

### The one insight

`addon/core/World.lua:36 collect_units_from_tokens()` is the single 88-slot straw
through which `Combat.Brain`, `Grinder.pick_target`, `Questing.Suite`, `Gatherer`,
`Looter`, and — silently, most importantly — every `Conditions.enemies_in_N` predicate
in the rotation engine perceives the world. The AC map (verified in `notes/04_anticheat_map.md`
and `notes/12`, `notes/13`) grants us a much wider capability envelope than we
are using. Extensions is behavioral-only; DivxTac is name-scan; MMgr64 is not AC;
Warden is dormant. Nothing watches the OM callback, `ObjectPtr` reads, or the
rate we call spatial primitives. **We have disabled our own eyes for no AC reason.**

## 3. Roadmap (sequenced — each step unlocks the next)

| # | Ship | Effort | Unlocks |
|---|---|---|---|
| 1 | **Prove OM enum callback ABI.** Verify `__cdecl(uint64_t guid, void* ctx)` signature at `runtime/src/game/ObjectManager.cpp:385` against the client's actual call frame. Sanity-check against the linked-list merge path already working at line 659. Fix until `EnumVisibleObjects` returns `npcs > 0` on a live scene. | hours-day | Everything below. Currently P0 in HANDOFF. |
| 2 | **Wire OM into the world model.** Flip `om.enable` default to `1` in `runtime/src/bridge/Dispatch.cpp:157`. Implement the stub handlers `NearbyEnemies(r,max)`, `UnitCastingByGuid`, `UnitChannelByGuid`, `UnitTargetByGuid`, `UnitAuraByGuid` at `Dispatch.cpp:396-404`, all reading from the OM Object cache. Refactor `World.collect_units_from_tokens` to *merge* tokens + OM, not replace. | day | `Conditions.enemies_in_8` becomes truthful. Grinder can pick from the pull. Interrupt scheduling has targets. `FaceDirection`/`Strafe`/`TurnLeft` verbs (currently 0 module callers) become usable. |
| 3 | **Build `addon/core/rotation/StateCache.lua`.** Single frame `RegisterEvent`ing `SPELL_UPDATE_COOLDOWN`, `UNIT_SPELLCAST_SUCCEEDED/FAILED/START/STOP` (player+target), `UNIT_AURA` (player+target+arbitrary GUID via OM), `UPDATE_STEALTH/SHAPESHIFT`. `World.build_context` READS from the cache with poll fallback; the 4× redundant target-aura scans (`World.lua:510/512` + `build_target_protection`) collapse to one. `Executor.attempt_action` confirms via `UNIT_SPELLCAST_SUCCEEDED` inside a 250 ms deadline. | days | 100 Hz tick feasible against a real 50-unit world. Silent Path-A taint failures become distinguishable from validator false-negatives (separate diag). Per-slot `deepcopy(ctx)` at `Engine.lua:241` can move to shared-immutable snapshot. The `0.35s` throttle, soft-GCD gate, retry-snapshot, and `strict_gcd=false` overrides all become redundant workarounds we can retire *safely*. |
| 4 | **Bridge liveness token + shutdown unregister.** Runtime shutdown at `main.cpp:106-118` marshals onto the main thread and calls `FrameScript_UnregisterFunction("IsLinuxClient")` (offset already known at `AddressDB.h:23`). Add an out-of-band heartbeat: mmap or heartbeat file with `{ts, runtime_version, handler_abi_hash, savedvars_schema_version}`. `A.ensure()` gates on token freshness (< 3 s) *before* invoking `IsLinuxClient`. `Runtime.lua:15` refuses to enable rotation on `handler_abi_hash` mismatch. | day | END-key shutdown safe. Dev inject/build/re-inject without quitting the client. Real version handshake instead of the loose `^1%.%d+` accept-anything at `Runtime.lua:15`. Same token carries the schema-version slot needed for step 5. |
| 5 | **Schema-version SavedVariables + per-character namespace.** Engine.serialize gets a `.version` field; deserialize dispatches on it with a migration slot. Split `RaijinLabDB.active_rotation` and keybinds into per-character namespace; keep rotations themselves account-scoped. | hours | Adding a new condition id or renaming an existing one no longer silently corrupts old profiles. Druid + warrior on one account stop fighting over `active_rotation` each login. |
| 6 | **First real utility feature: interrupt / dispel scheduler.** New module consuming `UnitCastingByGuid` (step 2) + `UNIT_AURA` events (step 3) to schedule kicks and dispels against arbitrary GUIDs. Runs through the existing Actions facade — zero new AC surface. | days | Proves the whole stack: OM sight → event cache → deadline-driven cast confirmation → module. This is the first feature that would have been *impossible* under 1.6 and is the smoke test that the trajectory has actually changed. |

Step 6 is deliberately included because the point of steps 1–5 is not the plumbing;
it is that the flagship rotation engine finally operates on real world state. Shipping
one net-new capability that requires all five plumbing changes is how we verify the
ceiling actually moved.

## 4. What we are NOT doing (traps future sessions will be tempted by)

See the `do_not_do` list in `SYNTH_SCHEMA`. Highlights:

- No stealth / evasion work. The AC map is verified static and Warden is dormant.
- No humanization jitter. Nothing in-game or in-AC observes cast rate.
- No retail (4.x+) API port. Runtime is 3.3.5-specific and AC map is realm-specific.
- No rewrite of any proven-working Grok surface (Path A/B/C cast fallback, TaintPatch,
  PEB unlink, the 100 Hz Executor tick engine, the priority evaluator).

## 5. Structural map of the change

```
[step 1: OM enum ABI]  ──proves──▶  live spatial cache
        │
        ▼
[step 2: OM handlers + collect_units merge]  ──expands──▶  world model 8 → 50 units
        │                                                        │
        │                                                        ▼
        │                                            build_context poll cost explodes
        │                                                        │
        ▼                                                        ▼
[step 6: interrupt/dispel]  ◀── depends on ──  [step 3: StateCache push cache]
        ▲                                                        ▲
        │                                                        │
        └──────── depends on ────── [step 5: schema versioning] ─┘
                                              ▲
                                              │
                            [step 4: liveness token + ABI hash]
```

Step 4 must land before step 5 (the token carries the schema version). Step 3 must
land before step 6 (the interrupt scheduler needs sub-250ms cast confirmation on
arbitrary GUIDs). Steps 1 and 2 are the only ones that must be first — everything
else is unlocked by them.
