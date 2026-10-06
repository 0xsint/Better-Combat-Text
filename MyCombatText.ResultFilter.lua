-- ============================================================
-- MyCombatText.ResultFilter.lua
-- Combat result classification tables and query functions.
-- Every ESO combat event carries an ACTION_RESULT_* constant
-- that identifies what happened (heal, damage, stun, etc.).
-- This file maps those constants into named boolean-lookup
-- tables so the rest of the addon can ask "IsDamage?",
-- "IsHeal?", "IsCrit?", etc. without hard-coding magic numbers
-- everywhere.
-- ============================================================

MyCombatText = MyCombatText or {}
local MCT = MyCombatText

-- MCT.Result is the public namespace for all result-check functions.
-- Other files access these as MCT.Result.IsHeal(result), etc.
MCT.Result = MCT.Result or {}
local R = MCT.Result

-- ---------------------------------------------------------------
-- Internal helpers: simple hash-set add and lookup.
-- Using a table-as-set gives O(1) lookup instead of linear scan.
-- ---------------------------------------------------------------

-- AddResult: inserts a numeric result id into a set-table so
-- it can later be looked up instantly with HasResult.
-- Silently ignores nil keys (safe to call with optional results).
local function AddResult(map, key)
    if key ~= nil then
        map[key] = true
    end
end

-- HasResult: returns true when the given result integer exists in
-- the set-table, false otherwise. Handles nil results safely so
-- callers do not need nil-guards around every check.
local function HasResult(map, result)
    if result == nil then return false end
    return map[result] == true
end

-- ---------------------------------------------------------------
-- Result classification sets.
-- Each table is a boolean hash-set populated with the
-- ACTION_RESULT_* constants that belong to that category.
-- Hard-coded numeric IDs are used where ESO does not expose a
-- named constant for that result code in the public API.
-- ---------------------------------------------------------------

-- RESULT_IS_DODGED: the target successfully dodged the attack.
-- 2140 is the numeric id for ACTION_RESULT_DODGED in current ESO.
local RESULT_IS_DODGED = {}
AddResult(RESULT_IS_DODGED, 2140)

-- RESULT_IS_CHARMED: the target was charmed (mind-controlled).
-- 3510 is the ESO numeric id for the charm status result.
local RESULT_IS_CHARMED = {}
AddResult(RESULT_IS_CHARMED, 3510)

-- RESULT_IS_STUNNED: the target was stunned by a hard CC ability.
local RESULT_IS_STUNNED = {}
AddResult(RESULT_IS_STUNNED, ACTION_RESULT_STUNNED)

-- RESULT_IS_FEARED: the target was feared and forced to flee.
local RESULT_IS_FEARED = {}
AddResult(RESULT_IS_FEARED, ACTION_RESULT_FEARED)

-- RESULT_IS_SILENCED: the target's abilities were silenced (cannot cast).
local RESULT_IS_SILENCED = {}
AddResult(RESULT_IS_SILENCED, ACTION_RESULT_SILENCED)

-- RESULT_IS_DISORIENTED: the target was disoriented (soft CC).
local RESULT_IS_DISORIENTED = {}
AddResult(RESULT_IS_DISORIENTED, ACTION_RESULT_DISORIENTED)

-- RESULT_IS_IMMOBILIZED: the target was rooted and cannot move.
-- 2480 is the ESO numeric id for the immobilize result.
local RESULT_IS_IMMOBILIZED = {}
AddResult(RESULT_IS_IMMOBILIZED, 2480)

-- RESULT_IS_OFFBALANCE: the target was knocked off-balance,
-- making them vulnerable to a Power Attack knockdown.
local RESULT_IS_OFFBALANCE = {}
AddResult(RESULT_IS_OFFBALANCE, ACTION_RESULT_OFFBALANCE)

-- RESULT_IS_DAMAGE_TAKEN: any result that means the player took
-- damage, including normal hits, crits, shielded hits, DoT ticks.
-- Used to decide whether to show incoming damage numbers.
local RESULT_IS_DAMAGE_TAKEN = {}
AddResult(RESULT_IS_DAMAGE_TAKEN, ACTION_RESULT_DAMAGE)           -- normal hit
AddResult(RESULT_IS_DAMAGE_TAKEN, ACTION_RESULT_CRITICAL_DAMAGE)  -- critical hit
AddResult(RESULT_IS_DAMAGE_TAKEN, ACTION_RESULT_DAMAGE_SHIELDED)  -- absorbed by shield
AddResult(RESULT_IS_DAMAGE_TAKEN, ACTION_RESULT_DOT_TICK)         -- damage over time tick
AddResult(RESULT_IS_DAMAGE_TAKEN, ACTION_RESULT_DOT_TICK_CRITICAL)-- critical DoT tick

-- RESULT_IS_DOT: specifically a damage-over-time tick (normal or crit).
-- This is a subset of RESULT_IS_DAMAGE_TAKEN used to distinguish
-- periodic DoT numbers from direct-hit numbers for separate display.
local RESULT_IS_DOT = {}
AddResult(RESULT_IS_DOT, ACTION_RESULT_DOT_TICK)
AddResult(RESULT_IS_DOT, ACTION_RESULT_DOT_TICK_CRITICAL)

-- RESULT_IS_CRIT: the event was a critical strike/heal of any kind.
-- Combining damage crits, heal crits, DoT crits, and HoT crits
-- into one set lets code ask a single IsCrit() for all event types.
local RESULT_IS_CRIT = {}
AddResult(RESULT_IS_CRIT, ACTION_RESULT_CRITICAL_DAMAGE)    -- critical damage hit
AddResult(RESULT_IS_CRIT, ACTION_RESULT_CRITICAL_HEAL)       -- critical heal hit
AddResult(RESULT_IS_CRIT, ACTION_RESULT_DOT_TICK_CRITICAL)   -- critical DoT tick
AddResult(RESULT_IS_CRIT, ACTION_RESULT_HOT_TICK_CRITICAL)   -- critical HoT tick

-- RESULT_IS_SHIELDED: the damage was fully or partly absorbed by a
-- damage shield (like Annulment). Useful for shield-break detection.
local RESULT_IS_SHIELDED = {}
AddResult(RESULT_IS_SHIELDED, ACTION_RESULT_DAMAGE_SHIELDED)

-- RESULT_IS_BLOCKED: the target blocked the attack, reducing damage.
-- Includes both a full block and a partial blocked-damage result.
local RESULT_IS_BLOCKED = {}
AddResult(RESULT_IS_BLOCKED, ACTION_RESULT_BLOCKED)         -- full block
AddResult(RESULT_IS_BLOCKED, ACTION_RESULT_BLOCKED_DAMAGE)  -- reduced-damage block

-- RESULT_IS_DAMAGE: any outgoing damage event, covering direct hits,
-- crits, shielded damage, DoT ticks, and blocked hits.
-- Used to route events to the damage text display path.
local RESULT_IS_DAMAGE = {}
AddResult(RESULT_IS_DAMAGE, ACTION_RESULT_DAMAGE)
AddResult(RESULT_IS_DAMAGE, ACTION_RESULT_CRITICAL_DAMAGE)
AddResult(RESULT_IS_DAMAGE, ACTION_RESULT_DAMAGE_SHIELDED)
AddResult(RESULT_IS_DAMAGE, ACTION_RESULT_DOT_TICK)
AddResult(RESULT_IS_DAMAGE, ACTION_RESULT_DOT_TICK_CRITICAL)
AddResult(RESULT_IS_DAMAGE, ACTION_RESULT_BLOCKED_DAMAGE)

-- RESULT_IS_HEAL: any healing event, covering direct heals,
-- absorbed heals (e.g. full health), critical heals, HoT ticks,
-- and critical HoT ticks. Used to route events to the heal display path.
local RESULT_IS_HEAL = {}
AddResult(RESULT_IS_HEAL, ACTION_RESULT_HEAL)               -- direct heal
AddResult(RESULT_IS_HEAL, ACTION_RESULT_HEAL_ABSORBED)       -- heal on a full-health target
AddResult(RESULT_IS_HEAL, ACTION_RESULT_CRITICAL_HEAL)       -- critical heal
AddResult(RESULT_IS_HEAL, ACTION_RESULT_HOT_TICK)            -- heal-over-time tick
AddResult(RESULT_IS_HEAL, ACTION_RESULT_HOT_TICK_CRITICAL)   -- critical HoT tick

-- ---------------------------------------------------------------
-- Public query functions exposed on MCT.Result.
-- Each function wraps HasResult for a specific category.
-- ---------------------------------------------------------------

-- Returns true when the combat result means the attack was dodged.
function R.IsDodged(result)
    return HasResult(RESULT_IS_DODGED, result)
end

-- Returns true when the result is the charmed/mind-control CC type.
function R.IsCharmed(result)
    return HasResult(RESULT_IS_CHARMED, result)
end

-- Returns true when the result is a hard stun crowd-control effect.
function R.IsStunned(result)
    return HasResult(RESULT_IS_STUNNED, result)
end

-- Returns true when the result applied a fear crowd-control effect.
function R.IsFeared(result)
    return HasResult(RESULT_IS_FEARED, result)
end

-- Returns true when the result applied a silence to the target.
function R.IsSilenced(result)
    return HasResult(RESULT_IS_SILENCED, result)
end

-- Returns true when the result applied a disorient (soft stun).
function R.IsDisoriented(result)
    return HasResult(RESULT_IS_DISORIENTED, result)
end

-- Returns true when the result immobilized (rooted) the target.
function R.IsImmobilized(result)
    return HasResult(RESULT_IS_IMMOBILIZED, result)
end

-- Returns true when the result knocked the target off-balance.
function R.IsOffbalanced(result)
    return HasResult(RESULT_IS_OFFBALANCE, result)
end

-- Returns true when the result represents any damage taken by the player,
-- including direct hits, crits, shielded hits, and DoT ticks.
function R.IsDamageTaken(result)
    return HasResult(RESULT_IS_DAMAGE_TAKEN, result)
end

-- Returns true specifically for damage-over-time tick results (DoT).
function R.IsDot(result)
    return HasResult(RESULT_IS_DOT, result)
end

-- Returns true when the event was a critical strike or critical heal of any type
-- (damage crit, heal crit, critical DoT tick, critical HoT tick).
function R.IsCrit(result)
    return HasResult(RESULT_IS_CRIT, result)
end

-- Returns true when the hit was absorbed by a damage shield rather than
-- reducing the target's health directly. Used by shield-break tracking.
function R.IsShielded(result)
    return HasResult(RESULT_IS_SHIELDED, result)
end

-- Returns true when the target successfully blocked the attack,
-- which reduces the incoming damage. Covers full and partial blocks.
function R.IsBlocked(result)
    return HasResult(RESULT_IS_BLOCKED, result)
end

-- Returns true for any result that represents outgoing or incoming damage,
-- including direct hits, crits, shielded damage, DoTs, and blocked hits.
function R.IsDamage(result)
    return HasResult(RESULT_IS_DAMAGE, result)
end

-- Returns true for any result that represents a healing event,
-- including direct heals, absorbed heals, critical heals, HoT ticks,
-- and critical HoT ticks. This is the primary heal classifier.
function R.IsHeal(result)
    return HasResult(RESULT_IS_HEAL, result)
end

-- ---------------------------------------------------------------
-- Additional result classifiers: mitigation, energize, drain.
-- These map to CombatCloud-equivalent events that show when the
-- player's outgoing attack was mitigated by the target, or when
-- resource energize/drain abilities fire.
-- ---------------------------------------------------------------

-- RESULT_IS_MISS: the source missed the target completely.
local RESULT_IS_MISS = {}
AddResult(RESULT_IS_MISS, ACTION_RESULT_MISS)

-- RESULT_IS_IMMUNE: the target is immune to the effect.
local RESULT_IS_IMMUNE = {}
AddResult(RESULT_IS_IMMUNE, ACTION_RESULT_IMMUNE)

-- RESULT_IS_PARRIED: the target parried the incoming attack.
local RESULT_IS_PARRIED = {}
AddResult(RESULT_IS_PARRIED, ACTION_RESULT_PARRIED)

-- RESULT_IS_REFLECTED: the target reflected the ability back at the source.
local RESULT_IS_REFLECTED = {}
AddResult(RESULT_IS_REFLECTED, ACTION_RESULT_REFLECTED)

-- RESULT_IS_ENERGIZE: an ability restored a resource pool (power energize).
local RESULT_IS_ENERGIZE = {}
AddResult(RESULT_IS_ENERGIZE, ACTION_RESULT_POWER_ENERGIZE)

-- RESULT_IS_DRAIN: an ability drained a resource pool (power drain).
local RESULT_IS_DRAIN = {}
AddResult(RESULT_IS_DRAIN, ACTION_RESULT_POWER_DRAIN)

-- Returns true when the attacker missed the target.
function R.IsMiss(result)
    return HasResult(RESULT_IS_MISS, result)
end

-- Returns true when the target is immune to the attack.
function R.IsImmune(result)
    return HasResult(RESULT_IS_IMMUNE, result)
end

-- Returns true when the target parried the attack.
function R.IsParried(result)
    return HasResult(RESULT_IS_PARRIED, result)
end

-- Returns true when the target reflected the attack back at the player.
function R.IsReflected(result)
    return HasResult(RESULT_IS_REFLECTED, result)
end

-- Returns true when the result is a power energize (resource restore via ability).
function R.IsEnergize(result)
    return HasResult(RESULT_IS_ENERGIZE, result)
end

-- Returns true when the result is a power drain (resource drained via ability).
function R.IsDrain(result)
    return HasResult(RESULT_IS_DRAIN, result)
end
