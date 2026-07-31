Basic Checks
(Every gate an ability/spell/passive from the spellbook must pass or be evaluated against to determine whether, how, and on what it can actually be cast. These are the runtime decision points. Each is phrased as a clear binary or multi-state check that either allows the cast to proceed, rejects it, or alters its behavior.)
Target Relationship & Validity Checks
Target friendliness / hostility check: Determine whether the current (or intended) target is friendly, hostile, or neutral. Friendly must include every nearby player, every form of pet/guardian, and every healable NPC. A purely hostile-targeted ability fails on friendly or neutral. A purely friendly-targeted ability fails on hostile (neutral is evaluated separately because some heals/HoTs can land on neutral).
Ability intent vs target relationship compatibility check: Cross-reference the ability’s inherent purpose (damage, heal, buff, debuff, etc.) against the target’s relationship. Melee or hostile-only damage abilities fail on friendly targets. Instant or casted heals/HoTs/buffs fail on hostile targets (and usually on neutral unless the specific ability explicitly allows neutral healing). Utility or neutral abilities may pass either.
Direct-cast-on-target vs existing-target-not-required check: Distinguish whether the player is explicitly targeting a unit and casting, or already has a unit targeted and is casting an ability that does not actually consume that target. The two paths are separate; some abilities only care about the explicit target, others ignore the current target entirely.
Heal/buff automatic friendly allowance check: If the ability is classified as a heal or buff, it automatically passes on any friendly (players + pets + healable NPCs). This allowance does not imply the ability is forbidden while an enemy is targeted; the two states remain independent.
Dead / corpse / special unit type check: Verify whether the target is alive, a corpse (ally or enemy), a passenger, a minipet, a guardian, a vehicle, or an object. Abilities that cannot target dead units fail; abilities that can only target corpses pass only on corpses.
Unit flags interaction check: Confirm the target’s flags (player, NPC, pet, guardian, object, etc.) are legal for this ability.
Ability Intent / Effect Type Compatibility Checks
Harmful vs helpful vs neutral intent check: Classify the ability as Harmful, Helpful, or Neutral/Utility. Harmful abilities are rejected on friendly targets; Helpful abilities are rejected on hostile targets (neutral is case-by-case).
Self-only / friendly-only / any-non-hostile / hostile-only check: Enforce the ability’s hard-coded target restriction. Self-only fails on any other unit. Friendly-only fails on hostile. Hostile-only fails on friendly. Any-non-hostile allows friendly + neutral.
Melee-range-only vs outside-melee-range-only check: If the ability is flagged melee-range-only it fails when the target is outside melee range; the inverse flag fails when the target is inside melee range.
Single-target vs multi-target / AoE shape compatibility check: Confirm the selected target(s) or ground location matches the ability’s required shape (radius, cone, line, chain, area-around-caster, area-around-target, ground-targeted). Wrong shape or wrong number of targets causes failure.
Range, Positioning, LOS & Facing Checks
Physical range check: Confirm the designated target is inside the ability’s min-range / max-range (yards). Fail if outside.
Line-of-sight (LOS) check: Confirm clear LOS exists (or the ability carries a can-ignore-LOS flag). Fail if blocked and the flag is absent.
Character FOV / facing restriction check: Confirm the caster is facing the target within the required FOV or cone angle. Fail if the facing condition is not met.
Ground location / dynamic object validity check: For ground-targeted abilities, confirm the chosen location is valid (not indoors if outdoor-only, not blocked, etc.).
Height / vertical range check: Confirm the vertical distance is within tolerance.
Resource, Cooldown & Availability Checks
Resource sufficiency check: Confirm the caster currently possesses every required resource (mana, rage, energy, runes, reagents, etc.). Fail if any is insufficient.
Cooldown / charge availability check: Confirm the ability is off its individual cooldown, shared category cooldown, and has an available charge (if charge-based). Fail if any timer or charge is missing.
GCD / server-compensation lock check: Confirm the ability is not blocked by the global cooldown or server latency compensation lock. GCD-immune abilities pass this check even while another cast is in progress or immediately after another ability.
Loss-of-control / silence / school-lockout check: Confirm the caster is not silenced, locked out of the school, or under loss-of-control that prevents this ability. Fail if blocked.
Caster State & Restriction Checks
Stance / form / shapeshift correctness check: Confirm the caster is in the exact required stance or form (or not in a forbidden one). Fail if mismatched.
Mounted / sitting / dead / ghost allowance check: Confirm the caster’s current state (mounted, sitting, dead, ghost) is permitted by the ability’s flags. Fail if disallowed.
Reactive condition check: Confirm any required preceding event (dodge, crit, specific aura present, etc.) has occurred. Fail if the reactive prerequisite is missing.
Out-of-control / immunity / invulnerability interaction check: Confirm the caster is not under an immunity or invulnerability that the ability cannot pierce, and that the target is not immune in a way that blocks the ability.
Targeting Mode & Selection Checks
Implicit vs explicit targeting mode check: Determine whether the ability requires an explicit unit target, a ground location, or can fire with no target at all.
SpellCanTargetUnit / IsUsableSpell result check: Query the client/server usability APIs; the combined “usable + not insufficient power” result must be true.
Current cast / targeting-mode active check: Confirm whether a cast is already in progress or the client is in targeting mode; GCD-immune or special abilities may still proceed.
Timing & Cast-Type Checks
Cast-time / channel / instant differentiation check: Determine whether the ability is instant, has a cast time, or is channeled; this decides whether movement, damage, or other casts can interrupt or slow it.
Castable-while-casting / while-channeling check: GCD-immune or specially flagged abilities pass even while another cast or channel is active; normal abilities fail.
Interruptible vs uninterruptible check: Decide whether the cast can be interrupted by damage, movement, or other actions.
These basic checks form the complete decision tree that must be evaluated (in roughly the order above, with short-circuiting on the first hard failure) before an ability is allowed to begin casting or apply its effects.

