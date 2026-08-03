#!/usr/bin/env python3
"""Verify the native-carrier OM fix after a fresh inject.

Checks runtime.log for the key markers of the 2026-08-02 23:05 native-carrier
architecture:
  1. frame tick hook ACTIVE  (hook installed from bridge dispatch)
  2. OM ok units=...          (native enumeration running from the hook)
  3. om.enable=1              (addon armed OM)
  4. NO crash.fatal           (the 0x512B07 target is gone)
  5. enumeration NOT inside Lua (no enum from bridge context — implicit via
     the wantEnum gate; the log line "OM ok units=" only comes from the hook's
     Refresh or the bridge list-only path — check ordering)

Usage: python tools\\_nh_verify_carrier.py [tail_lines]
"""
import re
import sys

LOG = r"C:\Ascension\Workspace\logs\runtime.log"
TAIL = int(sys.argv[1]) if len(sys.argv) > 1 else 2000


def main() -> int:
    try:
        with open(LOG, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except FileNotFoundError:
        print(f"LOG NOT FOUND: {LOG}")
        return 1

    tail = lines[-TAIL:] if len(lines) > TAIL else lines
    joined = "".join(tail)
    ok = True

    print("=== Native carrier verification (last %d lines) ===" % len(tail))

    hook = [l for l in tail if "frame tick hook ACTIVE" in l]
    if hook:
        print(f"[PASS] frame tick hook ACTIVE: {hook[-1].strip()}")
    else:
        print("[FAIL] frame tick hook ACTIVE not found in tail — hook not installed")
        ok = False

    native_marker = [l for l in tail if "native carrier: frame hook ENUM PATH" in l]
    if native_marker:
        print(f"[PASS] native carrier ENUM PATH live: {native_marker[-1].strip()}")
    else:
        print("[FAIL] native carrier ENUM PATH marker not found — hook body not "
              "running Refresh (is the hook firing on the main thread?)")
        ok = False

    hook_fail = [l for l in tail if "tick body fault" in l or "self-disabling" in l]
    if hook_fail:
        print(f"[FAIL] hook self-disabled: {hook_fail[-1].strip()}")
        ok = False

    om = [l for l in tail if "OM ok units=" in l or "OM soft discover units=" in l]
    if om:
        print(f"[PASS] OM enumeration running (last): {om[-1].strip()}")
    else:
        print("[WARN] no 'OM ok units=' in tail — enumeration may be list-only/frozen")

    om_enable = [l for l in tail if "om.enable" in l.lower() or "SetSystemVar" in l]
    if any("om.enable" in l for l in tail):
        print("[INFO] om.enable references present (addon gating)")

    crash = [l for l in tail if "crash.fatal" in l or "0x512B07" in l or "0x00512B07" in l]
    if crash:
        print(f"[FAIL] crash present in tail: {crash[-1].strip()}")
        ok = False
    else:
        print("[PASS] no crash.fatal / 0x512B07 in tail")
    cstate = [l for l in tail if "crash.state" in l]
    if cstate:
        print(f"[INFO] crash.state (action-state at fault): {cstate[-1].strip()}")
    # 2026-08-02 (17:36 NOREG, 1.10.81-noreg): ROOT CAUSE fixed — the walk
    # reads the cast-target GUID from 0xD3C00E14 (client's UNCOMMITTED .data
    # BSS tail). SafeNativeCast commits that page + writes the victim GUID
    # into the slot, so the feedback resolves the victim WITHOUT selecting it.
    # Acquire-off casts are DIRECT-GUID (no registration) -> unitframe NEVER
    # touched, no restore armed. Expected live behaviour:
    #   - NO NativeSetTarget for acquire-off casts (only acquire-on).
    #   - NO 0x512B07 SHIELD fires (walk resolves cleanly via the slot).
    #   - SafeNativeCast logs guid=0xF... for every unit-targeted cast.
    #   - NO crash.fatal, NO blocked dialog (frame-level counter reset).
    nst = [l for l in tail if "NativeSetTarget" in l]
    if nst:
        print(f"[INFO] native target registration (0x524BF0): {nst[-1].strip()}")
    else:
        print("[WARN] no NativeSetTarget diag — no acquire cast registered yet")
    guidcast = [l for l in tail if "SafeNativeCast rc=" in l and "guid=0xF" in l]
    if guidcast:
        print(f"[PASS] Spell_C(GUID) casts present (last): {guidcast[-1].strip()}")
    else:
        print("[WARN] no Spell_C(GUID) casts seen — check acquire-off drains")
    selrest = [l for l in tail if "SelectionRestore applied" in l]
    if selrest:
        last = selrest[-1].strip()
        print(f"[INFO] selection restore (revert-after-cast): {last}")
        import re as _re
        m = _re.search(r'holdMs=(\d+)', last)
        if m and int(m.group(1)) > 140:
            print("  [WARN] holdMs > 140 — min-hold was NOT applied (should be ~40)")
        if m and int(m.group(1)) < 20:
            print("  [WARN] holdMs < 20 — restore may race the cast-feedback walk (0x512B07 shield is the only guard)")
    else:
        print("[WARN] no SelectionRestore — no acquire-off revert seen (rotation idle?)")
    # FacingLive local cross-check (1.10.80)
    fl = [l for l in tail if "FacingLive:" in l and "local=" in l]
    if fl:
        print(f"[INFO] FacingLive with local cross-check (last): {fl[-1].strip()}")
    shield = [l for l in tail if "0x512B07 SHIELD" in l]
    if shield:
        print(f"[WARN] 0x512B07 SHIELD fired {len(shield)}x — the walk AV'd and was recovered (not fatal, but investigate): {shield[-1].strip()}")

    # Enum errors
    enum_err = [l for l in tail if "EnumVisibleObjects AV" in l]
    if enum_err:
        print(f"[WARN] EnumVisibleObjects AV caught (list-only fallback): {enum_err[-1].strip()}")

    cast = [l for l in tail if "SafeNativeCast" in l]
    if cast:
        print(f"[INFO] casts in tail (last): {cast[-1].strip()}")

    # Addon-side fixes (2026-08-02 23:xx): check for the spam/OFF regressions
    # being absent in the tail.
    attempt_spam = [l for l in tail if "[cast] attempt" in l]
    if len(attempt_spam) > 40:
        print(f"[WARN] {len(attempt_spam)} cast-attempt lines in tail — "
              "possible 50Hz attempt spam (should now throttle on facing/oor)")
    wire = [l for l in tail if "[cast] wire " in l]
    print(f"[INFO] wires={len(wire)} attempts={len(attempt_spam)} in tail")

    # Critter fix (2026-08-02): creatureType=8 (CRITTER) must be rejected in
    # the runtime hostile filter. Check for any critter entries in OM packs.
    critter = [l for l in tail if "creatureType" in l.lower() or "critter" in l.lower()]
    if critter:
        print(f"[INFO] critter-related log lines: {len(critter)}")

    # Native cast carrier (2026-08-02): casts should be STAGED (QueueCast) and
    # DRAINED by the native hook — no Spell_C from the Lua bridge.
    staged = [l for l in tail if "CastQueue STAGE" in l]
    drained = [l for l in tail if "CastQueue DRAIN" in l]
    if drained:
        print(f"[PASS] native cast carrier draining: {len(drained)} drains (last: {drained[-1].strip()})")
    else:
        print("[WARN] no CastQueue DRAIN lines — queue not draining yet")
    if staged:
        print(f"[INFO] staged casts: {len(staged)} (last: {staged[-1].strip()})")

    # Selection-first native cast (2026-08-02, 1.10.72-actionstate): a GUID
    # cast must DRAIN with nrc=1 (Spell_C(0) after setting the client
    # selection) — the raw-GUID Spell_C that crashed 0x512B07 must never
    # appear again. If it crashes, check crash.state: a bare zero (d4139c=0,
    # d413a0=0, d413a4=0) means the action-state bookkeeping was bypassed.
    guid_drains = [l for l in tail if "CastQueue DRAIN" in l and "guid=0x0 " not in l and "guid=0x0000000000000000" not in l]
    if guid_drains:
        last = guid_drains[-1].strip()
        print(f"[INFO] GUID-cast drain (sel-first): {last}")
        if "nrc=1" in last:
            print("[PASS] GUID cast drained via selection-first Spell_C(0)")
        else:
            print("[WARN] last GUID-cast drain nrc != 1 (cast refused)")
    raw_guid = [l for l in tail if "SafeNativeCast rc=" in l and "guid=0x0 " not in l and "guid=0x0000000000000000" not in l]
    if raw_guid:
        print(f"[WARN] raw-GUID Spell_C lines present (should be gone in 1.10.71): {raw_guid[-1].strip()}")
    else:
        print("[PASS] no raw-GUID Spell_C lines (all casts now Spell_C(0) on selection)")

    # Deferred protected actions (blocked-action fix)
    dh = [l for l in tail if "DeferredHalt" in l]
    if dh:
        print(f"[INFO] DeferredHalt: {len(dh)} lines (last: {dh[-1].strip()})")

    # Facing live-cache (2026-08-02, 1.10.70-facingsafe): the frame hook must
    # resolve the player via camera→GUID→ObjectPtr and cache the live facing.
    # obj must be non-zero; face should be a real radian value (0.0..6.28).
    fl = [l for l in tail if "FacingLive:" in l]
    if fl:
        last = fl[-1].strip()
        ok_cam = "obj=0x0" not in last
        print(f"[{'PASS' if ok_cam else 'FAIL'}] FacingLive cache (last): {last}")
        if not ok_cam:
            print("  -> camera/GUID/ObjectPtr resolution returned 0; facing will "
                  "be undetermined (1e9) and casts will skip on facing.")
            ok = False
    else:
        print("[WARN] no FacingLive: diag line — hook RefreshLiveFacingCache not running")

    print("=== Result: %s ===" % ("OK" if ok else "ISSUES FOUND"))
    return 0 if ok else 2


if __name__ == "__main__":
    sys.exit(main())
