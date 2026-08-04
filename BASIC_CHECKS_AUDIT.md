# Basic Checks — implementation audit

Maps every gate in `Basic_Rotation_Checks_Raiden.md` to its implementation, or
records honestly that it is missing. Written 2026-08-03.

Two rules this audit is held to:

* **A gate that cannot fire is not implemented.** `check_target_flags` passed
  its own test for a whole round while doing nothing, because it bailed on a
  nil guid before ever reading the flags. Presence in the source is not
  coverage; a mutation that survives the suite is the proof of absence.
* **Unknown never invents a refusal.** Every gate below fails only on positive
  evidence. The client is the final referee, and a false block is worse than a
  missed one — a missed block costs one refusal the client absorbs, a false
  block costs the ability entirely (live: `wait no_weapon` with a weapon
  equipped, which stopped Plague Strike and Blood Strike outright).

Execution order is fixed and matters: slot priority → **basic checks** → editor
conditions → wire.

---

## Target relationship & validity

| # | Check | Status | Where |
|---|---|---|---|
| 1 | Target friendliness / hostility | **done** | `check_target_relationship` (`target_is_enemy`) |
| 2 | Ability intent vs target relationship | **done** | `check_intent` via `World.spell_target_class` (implicit-target ids) |
| 3 | Direct-cast vs existing-target | **done** | `Engine.slot_target_policy` (`require` / `optional` / `forbid` / `corpse`) |
| 4 | Heal/buff automatic friendly allowance | **done** | `check_target_relationship` — only an *enemy-targeted* spell refuses a friendly selection |
| 5 | Dead / corpse / special unit type | **partial - blocked on measurement** | `target_is_dead` and corpse policy done. passenger / minipet / vehicle need `UNIT_FIELD_FLAGS_2`; `Flags2 = 0xF0` was derived by ARITHMETIC from the verified `Flags = 0xEC` and has never been read live. Gating on an unverified offset is exactly what left #20 silently dead for months, so it stays unwired |
| 6 | Unit flags interaction | **done** | `check_target_flags` — NON_ATTACKABLE / IMMUNE_TO_PC / NOT_SELECTABLE |

## Ability intent / effect type

| # | Check | Status | Where |
|---|---|---|---|
| 7 | Harmful vs helpful vs neutral | **done** | `check_intent` |
| 8 | Self-only / friendly-only / hostile-only | **done** | `World.spell_target_class` |
| 9 | Melee-range-only vs outside-melee | **done** | `runtime_spell_melee` (decoded range entry) |
| 10 | Single vs multi-target / AoE shape | **partial** | `spell_is_self_area` (dest-location + implicit targets); **cone modelled** (`spell_is_cone`, ids 54/104, forces facing even with FacingCasterFlags clear - 4 mutations caught); **chain modelled** (`spell_is_chain` / `spell_chain_targets`, from **EffectChainTarget** - Spell.dbc cols 104-106, NOT an implicit-target id, which is why it went unfound). Measured offline against the real 209,082-record Spell.dbc: Chain Lightning/Chain Heal carry 3, Fireball/Smite/Arcane Blast carry 0. Requires re-injection to answer |

## Range, positioning, LOS, facing

| # | Check | Status | Where |
|---|---|---|---|
| 11 | Physical range | **done** | `check_range` + per-candidate and direct-cast gates in `Executor` |
| 12 | Line of sight | **done** | `check_los` / `World.is_los_guid`, per-candidate in the try-list |
| 13 | FOV / facing | **done** | `World.spell_needs_facing` (FacingCasterFlags) + 45° half-arc |
| 14 | Ground location validity | **done** | `check_ground_location` — DEST_LOCATION spells need a floor (GroundCache) |
| 15 | Height / vertical range | **done** | `check_vertical` — |dz| vs the spell's decoded max range |

## Resource, cooldown, availability

| # | Check | Status | Where |
|---|---|---|---|
| 16 | Resource sufficiency | **done** | `check_resources` → `World.resource_ok` (runtime RuneState / UnitPower) |
| 17 | Cooldown / charge | **done** | `check_gcd_cd`; the GCD is excluded from per-spell cooldowns via the record's RecoveryTime/CategoryRecoveryTime |
| 18 | GCD / server lock | **done** | `check_gcd_cd`, with data-driven off-GCD from StartRecoveryCategory |
| 19 | Silence / school lockout | **partial - blocked on RE** | silence **done** (`check_silence`, PreventionType + UNIT_FLAG_SILENCED). Per-school lockout lives in the client's own lockout table, not the descriptor - it needs a live RE pass to locate, which needs the client running |

## Caster state

| # | Check | Status | Where |
|---|---|---|---|
| 20 | Stance / form | **done** | `check_stance`. It was SILENTLY DEAD: `Bytes2` sat at 0xCC inside a region that reads zero, so `ShapeshiftForm` answered "unshifted" for every caster in every form while passing its gate. Measured to **0x1E8** (`0x00000801` - sheath 1, pvp 0x08, form 0) on 2026-08-03 |
| 21 | Mounted / sitting / dead / ghost | **partial** | mounted **done**; dead/ghost **done**; **sitting unmeasurable so far** - no descriptor dword changes between seated and standing (full 0x00..0x400 diff, both directions), so standState is an instance field or the emote is cosmetic. Gate abstains |
| 22 | Reactive condition | **done** | `check_aura_state` matches the record's CasterAuraState / TargetAuraState against `UNIT_FIELD_AURASTATE` (**0x0F4**, read `0x08400000` live). State N lives in bit (N-1); `BasicRules.aura_state_has` is a pure function with 8 assertions. Mutation-proven: off-by-one, unknown-becomes-refusal, always-present all CAUGHT |
| 23 | Immunity / invulnerability | **done** | `check_immunity` + `Protection` classification |

## Targeting mode

| # | Check | Status | Where |
|---|---|---|---|
| 24 | Implicit vs explicit targeting | **done** | slot policy + `spell_is_self_area` |
| 25 | SpellCanTargetUnit / IsUsableSpell | **n/a by design** | both are hardware-gated; removed and replaced by runtime reads (see the taint rule) |
| 26 | Current cast / targeting mode active | **done** | `check_caster_busy` |

## Timing

| # | Check | Status | Where |
|---|---|---|---|
| 27 | Cast / channel / instant | **done** | `check_caster_busy` + `spell_instant` |
| 28 | Castable while casting / channeling | **done** | `while_casting` slot flag + instant detection |
| 29 | Interruptible vs uninterruptible | **n/a for gating** | affects outcome, not permission |

---

## Honest totals

**26 done - 4 partial - 0 missing - 2 n/a** (was 24/6 before 2026-08-03).

Closed since: **#20 stance** (was listed done while structurally incapable of
firing - `Bytes2` pointed into a zero region) and **#22 reactive conditions**
(`UNIT_FIELD_AURASTATE` measured to 0x0F4 and the comparison wired, with a pure
`aura_state_has` and 8 mutation-proven assertions).

Items 14 and 15 were the two outright missing rows in the first pass of this
audit and are now implemented and mutation-proven. Vertical range matters even
without ground casting: a target forty yards up a cliff reads as "in range" on
the horizontal projection while a 30-yard spell cannot reach it, and the client
measures true 3D distance.

**#21 sitting is BLOCKED BY MEASUREMENT, not by effort.** The full descriptor
`0x00..0x400` was snapshotted standing, seated (via `DoEmote("SIT")`, which is
not protected here and succeeded), and standing again. **Both diffs came back
empty** - not one dword moves. So standState is an instance field rather than a
descriptor field (as `Facing` at 0x7A8 and `QuestGiverStatus` at 0x90 already
are), or the emote is cosmetic on this server. `Bytes1` stays 0 and the check
ABSTAINS rather than asserting "standing" - asserting is exactly what the dead
`Bytes2` did for two months.

**All four remaining partials now reduce to ONE blocker: the client is not
running.** #21 needs a live descriptor diff while seated; #5 needs `Flags2`
confirmed by a live read before anything may gate on it; #19 needs a live RE
pass to find the school-lockout table; (#10 is now fully modelled - the chain half was measured offline from Spell.dbc.) Every one of them is a
MEASUREMENT, not a design problem - and each is a few minutes' work with a live
client, which is why none of them are being guessed at instead.

The four remaining partials are each a *narrower* gap than the row suggests: sitting,
per-school lockout, reactive aura-*states*, chain/cone shapes, and the exotic
unit types (passenger / minipet / vehicle). Every one of them fails open today,
so none can block a legal cast — they can only miss an illegal one, which the
client then refuses once and the refusal floor absorbs.

Coverage note: the gates carrying tests are identity, gcd/cd, resources,
equipment, stance, aura requirements, silence, mounted, target flags, intent,
target relationship, vertical range and ground location. Each was mutation-checked — a deliberate break fails
the suite. Gates without a mutation test are not proven, only present.
