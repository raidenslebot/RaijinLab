Complete Enumeratable Information + Exact Ties to the Basic Checks
(Every single item from the supplied list, organized, with an explicit statement of how that piece of data feeds into one or more of the basic checks above. Nothing is omitted.)
Core Identification & Static Metadata
Unique Spell ID → primary key used by every check to look up all other data.
Name, Rank/Subtext, Description, Aura Tooltip → used only for display; never gate a basic check, but the Description Variables ID supplies dynamic numbers that can appear in tooltip-driven reactive conditions.
Icon texture / FileID / originalIconID, Spell visual IDs, Missile/projectile visual ID → pure client presentation; no impact on basic checks.
Category / Spell Category → directly feeds the Shared category cooldown check and the Dispel-type interaction inside the Immunity/DR checks.
Spell Family Name / Flags / Masks → used by Proc and Reactive condition checks and by talent/Mystic-Enchant modifiers that can alter any basic check.
Class Options / Class Mask → early filter before any other check (wrong class → instant fail).
Level requirements → early filter (caster level outside min/max → fail).
Passive flag → if true, the ability never enters the cast decision tree (always-on).
Tradeskill / recipe flag, Hidden client-side flags, Ability vs Spell display distinction → presentation only; no cast gate.
Scaling data, Description Variables ID, Max stacks, Max targets → Max targets feeds the Single-target vs multi-target / AoE shape check; scaling can modify resource costs or range values that the Resource and Range checks read.
Equipped item class / inv-type / subclass, Reagent requirements, Totem requirements, Rune cost references → all feed the Resource sufficiency check (missing item/reagent/rune → fail).
Ability Classification / Type
Self-only buffs, Friendly-only buffs, Any non-hostile / non-neutral target buffs, Hostile / neutral-only targeted casts → these flags are the exact data read by the Target friendliness and Ability intent vs target relationship checks.
Differentiated between casted and instant-cast variations, GCD-immune casts → feed the Castable-while-casting / GCD lock and Timing & Cast-Type checks.
Melee-range-only, Outside-of-melee-range-only → feed the Melee-range-only vs outside-melee-range-only and Physical range checks.
Damage element / type (all schools and multi-school combinations) → feeds School lockout, Immunity, and Resist handling inside the Out-of-control / Immunity check.
Projectile type (instant or travel-time) → affects whether the LOS and Facing checks are re-evaluated mid-flight and whether the ability can be interrupted after launch.
Active vs Passive vs Toggle vs On-Next-Swing / On-Next-Ranged, Channeled vs Instant vs Cast-time, Harmful vs Helpful vs Neutral/Utility → core inputs to the Ability Intent / Effect Type Compatibility checks and the Timing checks.
Damage / Healing / Absorb / Buff / Debuff / Crowd-control / Summon / Teleport / Interrupt / Dispel / Steal / Pet command / Stance change / Weapon imbue / Trap / Totem / Portal / Ritual / Profession / Racial / Glyph-modified / Talent-granted / Mystic-Enchant-granted → these labels are the “intended purpose” data that the Intent vs target relationship check compares against the target’s friendliness.
Single-target vs Multi-target / AoE (and every shape) → feeds the AoE shape compatibility check.
Binary vs partial-resist, On-next-swing variants, Cooldown-on-event, Cast-when-learned, Server-only / script-driven → Binary/partial feeds Immunity/Resist handling; Cooldown-on-event alters when the Cooldown availability check becomes true; the others are edge-case modifiers to the overall decision tree.
Targeting System
Self only, Friendly only (players + pets + healable NPCs), Any non-hostile / non-neutral, Hostile / neutral only → exact flags for the Target Relationship checks.
Direct casting on a target vs already-targeting then casting → the distinction required by the Direct-cast vs existing-target check.
Heal or buff automatic friendly allowance (does not prohibit use while targeting enemies) → the precise rule implemented by the Heal/buff automatic friendly allowance check.
Corpse ally/enemy, passenger, minipet, Implicit vs explicit, Ground-targeted, Chain targets / amplitude, Max number of targets / selection category, Direction filters, Can target dead / corpse / not-in-LOS / while-dead / while-mounted / while-sitting / only-stealth / only-outdoors / only-indoors / only-daytime / only-night / not-shapeshifted / only-in-stance-X, Friendly / enemy / neutral / party / raid / raid-class filters, Unit flags interaction → every one of these is a direct input to the Dead/corpse/special unit, Unit flags, Implicit vs explicit, Ground location, and Stance/form checks.
Casting Mechanics & Timing
Cast time, Channel time, Interruptible vs uninterruptible, Castable while casting / while channeling, GCD duration contribution / triggers GCD, Server compensation / latency compensation, On-next-swing timing, Cast speed modifiers affected or immune, Animation length / recovery time, Face-target-during-cast, Track-target-in-cast, Cancelable by movement / damage / other casts → all feed the Timing & Cast-Type checks and the Castable-while-casting / GCD lock check.
Cooldowns, Charges & Locks
Individual cooldown (start/duration/enabled/modRate), Shared category cooldown, Charge system, GCD lock / server-compensation lock, Loss-of-control cooldown, Cooldown that only starts on aura removal / event, Visible / hidden / haste / CDR affected → every value is read by the Cooldown / charge availability and GCD / server-compensation lock checks.
Range, Positioning, LOS, Facing
Min range / max range, Melee-range-only vs outside-melee-only, Physically in castable range, LOS requirement / can-ignore-LOS, Character FOV / facing restrictions, Cone angle / directionality, Height / vertical range, Indoor / outdoor only, Dynamic object / ground location validity → exact data consumed by the entire Range, Positioning, LOS & Facing check group.
Requirements & Restrictions
Correct stance / form / shapeshift detection, Mounted / sitting / dead / ghost allowances, PvP / arena / battleground / instance restrictions, Faction / race restrictions → direct inputs to the Caster State & Restriction checks.
Runtime Usability Conditions
Physically has the resources, Off cooldown, GCD or server-compensation locked, Physically in castable range, Actually usable on the target (heal/buff friendly rule), Distinguish direct-cast vs existing-target, IsUsableSpell / C_Spell.IsSpellUsable, SpellCanTargetUnit, Is current cast / targeting mode active, Reactive condition met, Out of control / silenced / locked school, Immunity / invulnerability piercing or blocked, Diminishing returns category and current DR stage → these are the live query results that the Resource, Cooldown, Range, Target Relationship, and Out-of-control checks evaluate.
Effects, Outcomes & Application Rules
Effect indices, Effect type, Aura type / period / amplitude, Base points / die sides / bonus coefficients, Chain targets / amplitude, Proc chance / charges / flags / PPM / RPPM, Trigger spell IDs, Mechanic, Dispel type, Stacking rules / exclusive with / overrides, Can be reflected / redirected / stolen, Threat generation / no-threat, Critical strike chance / multiplier, Miss / dodge / parry / block / resist / absorb / immune handling, Overkill / overheal tracking, Periodic vs direct, Duration, Can be canceled by player or not → after the basic checks pass, these determine the final outcome, but Mechanic / Dispel / Reflect / Immune handling also feed back into the Immunity and DR checks that can still fail a cast.
Spell School / Element
Primary school mask, Multi-school combinations and interactions with resists / interrupts / damage amps, Damage type vs school of the spell itself, School lockout behavior on interrupt → all feed the School lockout portion of the Out-of-control / Immunity check and the Resist handling after the cast succeeds.
Projectile / Travel
Instant vs travel-time, Missile speed, Launch delay, Homing / trajectory type, Visual missile ID, Can be interrupted mid-flight or has collision → determine whether LOS / Facing checks must be re-run after launch and whether the ability can still be cancelled mid-flight (affects Interruptible check timing).
Edge Cases & Interactions
Client prediction vs server authority (GCD, range, LOS, facing), Latency / compensation effects on double-casting or queue-weaving, Form/stance changes mid-cast or that transform the spell, Pet / guardian / vehicle / passenger targeting special cases, Dead target / corpse interaction, Multi-school interrupt and lockout edge cases, Absorb / immune / invuln piercing rules, Charge consumption on failed cast or immune → these modify the exact moment or the exact result of almost every basic check listed in Perspective 1 (especially GCD lock, Range/LOS/Facing, Stance, Dead/corpse, and Immunity checks).
Every enumeratable item either (a) supplies the static data a basic check reads, (b) is the live runtime value a basic check evaluates, or (c) modifies the outcome after the checks have passed. No item is left unconnected.


