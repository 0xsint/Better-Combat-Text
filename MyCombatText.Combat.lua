-- ============================================================
-- MyCombatText.Combat.lua
-- Standalone combat event processing pipeline.
-- Registers native ESO EVENT_COMBAT_EVENT and EVENT_POWER_UPDATE
-- callbacks, classifies each event as damage/heal/CC, applies
-- per-feature filters, and dispatches to the merge queue
-- (MCT.Tracking) for display.
-- No external library dependencies — uses ESO API directly.
-- ============================================================

MyCombatText = MyCombatText or {}
local MCT = MyCombatText
local RF = MCT.Result           -- Combat result classifier namespace from ResultFilter.lua.

-- Local alias for frequently called timer function.
local GetGameTimeMs = GetGameTimeMilliseconds

-- ---------------------------------------------------------------
-- Player Unit ID Cache
-- ESO does not expose a direct GetPlayerUnitId() API. We derive
-- and cache the player's combat unit ID from EVENT_COMBAT_EVENT
-- callbacks where sourceType or targetType is COMBAT_UNIT_TYPE_PLAYER.
-- Updated on every relevant combat event for zone-change safety.
-- ---------------------------------------------------------------
MCT._playerUnitId = MCT._playerUnitId or nil

function MCT:GetPlayerUnitId()
    return self._playerUnitId
end

local function UpdatePlayerUnitId(sourceType, sourceUnitId, targetType, targetUnitId)
    if sourceType == COMBAT_UNIT_TYPE_PLAYER and sourceUnitId and sourceUnitId ~= 0 then
        MCT._playerUnitId = sourceUnitId
    elseif targetType == COMBAT_UNIT_TYPE_PLAYER and targetUnitId and targetUnitId ~= 0 then
        MCT._playerUnitId = targetUnitId
    end
end

-- ---------------------------------------------------------------
-- IsHealingResult: extended heal classifier that falls back to a
-- power-type heuristic when the ESO ACTION_RESULT_* constant does
-- not match any known heal result. This handles API version drift
-- where new result IDs appear that our result table hasn't been
-- updated to include yet.
--
-- Logic:
--   1. Check RF.IsHeal() first (explicit ACTION_RESULT match).
--   2. Fallback: if powerType == POWERTYPE_HEALTH and there is a
--      non-zero hit/overflow value and the result is NOT classified
--      as damage, treat it as healing.
-- ---------------------------------------------------------------
local function IsHealingResult(result, powerType, hitValue, overflow)
    if RF.IsHeal(result) then
        return true
    end

    local value = tonumber(hitValue) or 0
    local over = tonumber(overflow) or 0
    local isHealthPower = (powerType == POWERTYPE_HEALTH or powerType == COMBAT_MECHANIC_FLAGS_HEALTH)
    if isHealthPower and (value > 0 or over > 0) and not RF.IsDamage(result) then
        return true
    end

    return false
end

-- ---------------------------------------------------------------
-- OnCombatEvent: unified handler for all ESO EVENT_COMBAT_EVENT.
-- Replaces the previous LibCombat2 damage callback and raw ESO
-- event handler with a single, direct ESO event listener.
--
-- Processing order:
--   1. Early-exit guards (disabled, error events, non-player).
--   2. Cache/update player unit ID from type enums.
--   3. Classify direction: outgoing / incoming / self.
--   4. Healing branch (all directions) via QueueHit.
--   5. Outgoing CC labels (player applied CC to target) via ShowText.
--   6. Outgoing damage via QueueHit + DPS/burst/shieldbreak tracking.
--   7. Incoming/self CC labels via ShowText.
--   8. Incoming/self damage via QueueHit.
-- ---------------------------------------------------------------
local function OnCombatEvent(ec, result, isError, abilityName, abilityGraphic, actionSlotType, sourceName, sourceType, targetName, targetType, hitValue, powerType, damageType, log, sourceUnitId, targetUnitId, abilityId, overflow)
    if not MCT.sv.enabled then return end
    -- Skip error results (e.g. "ability not ready", "out of range").
    if isError then return end

    -- Determine player involvement using COMBAT_UNIT_TYPE enums.
    -- The type enum is always reliable; unit IDs can arrive as 0 or nil.
    local sourceIsPlayer = (sourceType == COMBAT_UNIT_TYPE_PLAYER)
    local targetIsPlayer = (targetType == COMBAT_UNIT_TYPE_PLAYER)

    -- Skip events that involve neither the player as source nor target.
    if not sourceIsPlayer and not targetIsPlayer then return end

    -- Cache/update the player's combat unit ID from this event.
    UpdatePlayerUnitId(sourceType, sourceUnitId, targetType, targetUnitId)
    local playerId = MCT._playerUnitId

    -- Patch missing/zero unit IDs using the type-based detection above
    -- so downstream code can safely compare against playerId.
    if sourceUnitId == nil or sourceUnitId == 0 then
        sourceUnitId = sourceIsPlayer and playerId or sourceUnitId
    end
    if targetUnitId == nil or targetUnitId == 0 then
        targetUnitId = targetIsPlayer and playerId or targetUnitId
    end

    if MCT.sv.pvpOnly and not IsUnitPvPFlagged("player") then return end

    -- Classify event direction relative to the player.
    local outgoing  = sourceIsPlayer and not targetIsPlayer  -- player acted on another unit
    local incoming  = not sourceIsPlayer and targetIsPlayer   -- another unit acted on the player
    local selfEvent = sourceIsPlayer and targetIsPlayer       -- player acted on themselves

    -- Ensure numeric types.
    hitValue = tonumber(hitValue) or 0
    overflow = tonumber(overflow) or 0

    -- Opportunistic tracking table cleanup every 5 seconds.
    MCT:PruneTrackingTables(GetGameTimeMs())

    -- ---- Healing branch ----
    -- Checked before CC/damage branches so heals are never misrouted.
    local isHeal = IsHealingResult(result, powerType, hitValue, overflow)
    if isHeal then
        local crit = RF.IsCrit(result)

        if MCT.sv.showHealing and (not MCT.sv.critOnly or crit) then
            if hitValue > 0 then
                local mergeGroup = "healing:self"
                if incoming then
                    mergeGroup = "healing:incoming"
                elseif outgoing then
                    mergeGroup = "healing:outgoing"
                end

                MCT:QueueHit(hitValue, crit, true, sourceUnitId, targetUnitId, false, abilityId, mergeGroup)
            end

            if MCT.sv.showOverhealing and overflow > 0 then
                MCT:QueueOverhealing(overflow, crit, sourceUnitId, targetUnitId, abilityId)
            end
        end

        return
    end

    -- ---- Outgoing CC (player applied CC to another unit) ----
    if outgoing then
        local dodge     = RF.IsDodged(result)
        local charm     = RF.IsCharmed(result)
        local stun      = RF.IsStunned(result)
        local fear      = RF.IsFeared(result)
        local silence   = RF.IsSilenced(result)
        local disorient = RF.IsDisoriented(result)
        local offbalance  = RF.IsOffbalanced(result)
        local immobilized = RF.IsImmobilized(result)

        if dodge or charm or stun or fear or silence or disorient or offbalance or immobilized then
            if dodge then
                MCT:ShowText(nil, false, false, "dodged", sourceUnitId, targetUnitId, false, abilityId)
            elseif charm then
                MCT:ShowText(nil, false, false, "charmed", sourceUnitId, targetUnitId, false, abilityId)
            elseif stun then
                MCT:ShowText(nil, false, false, "stunned", sourceUnitId, targetUnitId, false, abilityId)
            elseif fear then
                MCT:ShowText(nil, false, false, "feared", sourceUnitId, targetUnitId, false, abilityId)
            elseif silence then
                MCT:ShowText(nil, false, false, "silenced", sourceUnitId, targetUnitId, false, abilityId)
            elseif disorient then
                MCT:ShowText(nil, false, false, "disoriented", sourceUnitId, targetUnitId, false, abilityId)
            elseif offbalance then
                MCT:ShowText(nil, false, false, "offbalanced", sourceUnitId, targetUnitId, false, abilityId)
            elseif immobilized then
                MCT:ShowText(nil, false, false, "immobilized", sourceUnitId, targetUnitId, false, abilityId)
            end
            return
        end
    end

    -- ---- Outgoing damage (player dealing damage to another unit) ----
    if outgoing then
        -- Mitigation: player's attack was negated by the target's defences.
        -- These produce zero or near-zero hitValue and should be shown instead of damage.
        local isMiss      = RF.IsMiss(result)
        local isImmune    = RF.IsImmune(result)
        local isParried   = RF.IsParried(result)
        local isReflected = RF.IsReflected(result)
        local isEnergize  = RF.IsEnergize(result)
        local isDrain     = RF.IsDrain(result)

        if isMiss and MCT.sv.showMiss then
            MCT:ShowNotification(string.format("|c%sMISS|r", MCT.sv.missColor), "miss", MCT.sv.mitigationFontSize)
            return
        elseif isImmune and MCT.sv.showImmune then
            MCT:ShowNotification(string.format("|c%sIMMUNE|r", MCT.sv.immuneColor), "immune", MCT.sv.mitigationFontSize)
            return
        elseif isParried and MCT.sv.showParried then
            MCT:ShowNotification(string.format("|c%sPARRIED|r", MCT.sv.parriedColor), "parried", MCT.sv.mitigationFontSize)
            return
        elseif isReflected and MCT.sv.showReflected then
            MCT:ShowNotification(string.format("|c%sREFLECTED|r", MCT.sv.reflectedColor), "reflected", MCT.sv.mitigationFontSize)
            return
        end

        -- Energize / Drain caused by player's outgoing ability.
        if isEnergize and MCT.sv.showEnergize and hitValue > 0 then
            local pwrName = (powerType == COMBAT_MECHANIC_FLAGS_MAGICKA and "Magicka") or (powerType == COMBAT_MECHANIC_FLAGS_STAMINA and "Stamina") or "Resource"
            MCT:ShowNotification(string.format("|c%s+%s %s|r", MCT.sv.energizeColor, MCT:FormatShortNumber(hitValue), pwrName), "energize", MCT.sv.energizeFontSize)
            return
        elseif isDrain and MCT.sv.showDrain and hitValue > 0 then
            local pwrName = (powerType == COMBAT_MECHANIC_FLAGS_MAGICKA and "Magicka") or (powerType == COMBAT_MECHANIC_FLAGS_STAMINA and "Stamina") or "Resource"
            MCT:ShowNotification(string.format("|c%sDrain -%s %s|r", MCT.sv.drainColor, MCT:FormatShortNumber(hitValue), pwrName), "drain", MCT.sv.energizeFontSize)
            return
        end

        local dmg     = RF.IsDamage(result)
        local crit    = RF.IsCrit(result)
        local dot     = RF.IsDot(result)
        local blocked = RF.IsBlocked(result)

        if dmg and hitValue > 0 then
            if MCT.sv.critOnly and not crit then return end
            if not MCT.sv.showDamage then return end
            if dot and not MCT.sv.showDots then return end

            MCT:QueueHit(hitValue, crit, false, sourceUnitId, targetUnitId, blocked, abilityId, "damage:outgoing")
            MCT:AddDps(targetUnitId, hitValue)
            MCT:TrackBurst(targetUnitId, hitValue, crit)
            MCT:TrackShieldbreak(targetUnitId, hitValue, RF.IsShielded(result))
            MCT:ApplyMarkerRule(targetUnitId, "pressure")
        end
        return
    end

    -- ---- Incoming / self events (player is the target) ----

    -- CC received by the player.
    local dodge       = RF.IsDodged(result)
    local charm       = RF.IsCharmed(result)
    local stun        = RF.IsStunned(result)
    local fear        = RF.IsFeared(result)
    local silence     = RF.IsSilenced(result)
    local disorient   = RF.IsDisoriented(result)
    local offbalance  = RF.IsOffbalanced(result)
    local immobilized = RF.IsImmobilized(result)

    if dodge or charm or stun or fear or silence or disorient or offbalance or immobilized then
        if dodge then
            MCT:ShowText(nil, false, false, "dodged", sourceUnitId, targetUnitId, false, abilityId)
        elseif charm then
            MCT:ShowText(nil, false, false, "charmed", sourceUnitId, targetUnitId, false, abilityId)
        elseif stun then
            MCT:ShowText(nil, false, false, "stunned", sourceUnitId, targetUnitId, false, abilityId)
        elseif fear then
            MCT:ShowText(nil, false, false, "feared", sourceUnitId, targetUnitId, false, abilityId)
        elseif silence then
            MCT:ShowText(nil, false, false, "silenced", sourceUnitId, targetUnitId, false, abilityId)
        elseif disorient then
            MCT:ShowText(nil, false, false, "disoriented", sourceUnitId, targetUnitId, false, abilityId)
        elseif offbalance then
            MCT:ShowText(nil, false, false, "offbalanced", sourceUnitId, targetUnitId, false, abilityId)
        elseif immobilized then
            MCT:ShowText(nil, false, false, "immobilized", sourceUnitId, targetUnitId, false, abilityId)
        end
        return
    end

    -- Cleanse alert: warn player when an incoming DoT tick lands (debuff to cleanse).
    if incoming and RF.IsDot(result) and MCT.sv.showAlertCleanse then
        local now = GetGameTimeMs()
        MCT._cleanseAlertAt = MCT._cleanseAlertAt or 0
        if (now - MCT._cleanseAlertAt) > 5000 then
            MCT._cleanseAlertAt = now
            MCT:ShowNotification(string.format("|c%sCLEANSE!|r", MCT.sv.alertColor), "alert", MCT.sv.alertFontSize)
        end
    end

    -- Damage taken by the player (incoming or self-damage).
    local damageTaken = RF.IsDamageTaken(result)
    if damageTaken and hitValue > 0 then
        local crit    = RF.IsCrit(result)
        local blocked = RF.IsBlocked(result)

        if MCT.sv.critOnly and not crit then return end
        if not MCT.sv.showDamageTaken then return end

        local mergeGroup
        if selfEvent then
            mergeGroup = "damage:self"
        else
            mergeGroup = blocked and "damageTaken:blocked" or "damageTaken"
        end
        MCT:QueueHit(hitValue, crit, false, sourceUnitId, targetUnitId, blocked, abilityId, mergeGroup)
    end
end

-- ---------------------------------------------------------------
-- MCT.lastResourceAmounts: stores the last known power value for
-- each resource type so OnResourceRestore can calculate the delta.
-- Populated dynamically with numeric POWERTYPE_* keys at runtime.
-- ---------------------------------------------------------------
MCT.lastResourceAmounts = MCT.lastResourceAmounts or {}

-- ---------------------------------------------------------------
-- OnResourceRestore: ESO EVENT_POWER_UPDATE handler.
-- Fires every time a unit's power pool value changes. We listen
-- only for the player and only for increases (restores).
-- A minimum threshold of 50 prevents spam from natural 1-point
-- regen ticks and floating-point differences.
-- ---------------------------------------------------------------
local function OnResourceRestore(eventCode, unitTag, powerType, powerIndex)
    if not MCT.sv.enabled or not MCT.sv.showResourceRestore then return end
    if unitTag ~= "player" then return end
    if MCT.sv.pvpOnly and not IsUnitPvPFlagged("player") then return end

    local currentPower, maxPower, effectivePower = GetUnitPower("player", powerType)
    local lastAmount = MCT.lastResourceAmounts[powerType] or 0

    if currentPower > lastAmount then
        local restoreAmount = currentPower - lastAmount
        local playerId = MCT:GetPlayerUnitId()

        if restoreAmount > 50 then
            MCT:QueueResourceRestore(restoreAmount, powerType, playerId)
        end
    end

    MCT.lastResourceAmounts[powerType] = currentPower
end

-- ---------------------------------------------------------------
-- MCT:ShowResourceRestore: constructs and immediately animates a
-- floating label for a magicka/stamina/health restoration event.
-- ---------------------------------------------------------------
function MCT:ShowResourceRestore(amount, powerType, playerId)
    local label, key = MCT.pool:AcquireObject()
    if not label then return end
    label:SetHidden(false)
    label:SetAlpha(1)

    local resourceName = "RESOURCE"
    if powerType == COMBAT_MECHANIC_FLAGS_MAGICKA then
        resourceName = "\226\156\166 Magicka"
    elseif powerType == COMBAT_MECHANIC_FLAGS_STAMINA then
        resourceName = "\226\156\166 Stamina"
    elseif powerType == COMBAT_MECHANIC_FLAGS_HEALTH then
        resourceName = "\226\156\166 Health"
    end

    local textureCode = "resource"
    if powerType == COMBAT_MECHANIC_FLAGS_MAGICKA then
        textureCode = "magicka"
    elseif powerType == COMBAT_MECHANIC_FLAGS_STAMINA then
        textureCode = "stamina"
    end

    label.mctAbilityId = nil
    label.mctEventCode = textureCode

    label:SetFont(MCT:GetCachedFTNFont(MCT.sv.resourceRestoreFontSize))
    label:SetAnchor(MCT:GetAnchor("resource"))
    label:SetText(MCT:StylizeDisplayText(
        string.format("|c%s+%s (%s)|r",
            MCT.sv.resourceRestoreColor,
            MCT:FormatShortNumber(amount),
            resourceName
        ),
        "resource"
    ))
    label:SetScale(1.6)

    MCT:Animate(label, "resourceRestore", key)
end

-- ---------------------------------------------------------------
-- MCT:RegisterCombat: registers all combat and power update event
-- listeners using native ESO events only. No external library
-- dependencies.
-- ---------------------------------------------------------------

-- ---------------------------------------------------------------
-- CombatCloud-parity event handlers
-- ---------------------------------------------------------------

-- OnAlertTip: handles EVENT_DISPLAY_ACTIVE_COMBAT_TIP.
-- tipId mapping: 1=block, 2=exploit weakness, 3=interrupt, 4=dodge roll.
local function OnAlertTip(eventCode, tipId)
    if not MCT.sv or not MCT.sv.enabled then return end
    local sv = MCT.sv
    if tipId == 1 and sv.showAlertBlock then
        MCT:ShowNotification(string.format("|c%sBLOCK!|r", sv.alertColor), "alert", sv.alertFontSize)
    elseif tipId == 2 and sv.showAlertExploit then
        MCT:ShowNotification(string.format("|c%sEXPLOIT!|r", sv.alertColor), "alert", sv.alertFontSize)
    elseif tipId == 3 and sv.showAlertInterrupt then
        MCT:ShowNotification(string.format("|c%sINTERRUPT!|r", sv.alertColor), "alert", sv.alertFontSize)
    elseif tipId == 4 and sv.showAlertDodge then
        MCT:ShowNotification(string.format("|c%sDODGE!|r", sv.alertColor), "alert", sv.alertFontSize)
    end
end

-- OnCombatState: handles EVENT_PLAYER_COMBAT_STATE.
-- Fires when the player transitions in or out of combat.
local function OnCombatState(eventCode, inCombat)
    if not MCT.sv or not MCT.sv.enabled then return end
    if not MCT.sv.showCombatState then return end
    local sv = MCT.sv
    if inCombat then
        MCT:ShowNotification(string.format("|c%sEntered Combat|r", sv.combatStateColor), "combatState", sv.combatStateFontSize)
    else
        MCT:ShowNotification(string.format("|c%sLeft Combat|r", sv.combatStateColor), "combatState", sv.combatStateFontSize)
        if MCT.pool then
            MCT.pool:ReleaseAllObjects()
        end
    end
end

-- OnAlliancePoints: handles EVENT_ALLIANCE_POINT_UPDATE.
local function OnAlliancePoints(eventCode, alliancePoints, playSound, difference)
    if not MCT.sv or not MCT.sv.enabled then return end
    if not MCT.sv.showAlliancePoints then return end
    if not difference or difference <= 0 then return end
    MCT:ShowNotification(string.format("|c%s+%s AP|r", MCT.sv.alliancePointsColor, MCT:FormatShortNumber(difference)), "points", MCT.sv.pointsFontSize)
end

-- OnExperiencePoints: handles EVENT_EXPERIENCE_UPDATE.
-- Throttles output to a 500 ms window so multi-kill XP spikes merge.
MCT._xpGainBuffer = MCT._xpGainBuffer or 0
MCT._xpGainTimerActive = MCT._xpGainTimerActive or false
MCT._xpPreviousXp = nil
MCT._xpPreviousMaxXp = nil

local function OnExperiencePoints(eventCode, unit, currentXp, maxXp, reason)
    if not MCT.sv or not MCT.sv.enabled then return end
    if not MCT.sv.showExperiencePoints then return end

    local prevXp  = MCT._xpPreviousXp  or currentXp
    local prevMax = MCT._xpPreviousMaxXp or maxXp
    local gain    = 0

    if maxXp ~= prevMax or currentXp < prevXp then
        gain = (prevMax - prevXp) + currentXp
    else
        gain = currentXp - prevXp
    end

    MCT._xpPreviousXp  = currentXp
    MCT._xpPreviousMaxXp = maxXp

    if gain <= 0 then return end
    MCT._xpGainBuffer = MCT._xpGainBuffer + gain

    if not MCT._xpGainTimerActive then
        MCT._xpGainTimerActive = true
        zo_callLater(function()
            local buffered = MCT._xpGainBuffer
            MCT._xpGainBuffer  = 0
            MCT._xpGainTimerActive = false
            if buffered > 0 and MCT.sv and MCT.sv.enabled then
                MCT:ShowNotification(string.format("|c%s+%s XP|r", MCT.sv.experiencePointsColor, MCT:FormatShortNumber(buffered)), "points", MCT.sv.pointsFontSize)
            end
        end, 500)
    end
end

-- OnChampionPoints: handles EVENT_CHAMPION_POINT_UPDATE.
-- Throttles display to 500 ms to batch CP gains from a single kill.
MCT._cpGainBuffer = MCT._cpGainBuffer or 0
MCT._cpGainTimerActive = MCT._cpGainTimerActive or false
MCT._cpPreviousPoints = nil

local function OnChampionPoints(eventCode, unit, currentPoints, maxPoints, reason)
    if not MCT.sv or not MCT.sv.enabled then return end
    if not MCT.sv.showChampionPoints then return end

    local prev = MCT._cpPreviousPoints or currentPoints
    local gain = currentPoints - prev
    MCT._cpPreviousPoints = currentPoints

    if gain <= 0 then return end
    MCT._cpGainBuffer = MCT._cpGainBuffer + gain

    if not MCT._cpGainTimerActive then
        MCT._cpGainTimerActive = true
        zo_callLater(function()
            local buffered = MCT._cpGainBuffer
            MCT._cpGainBuffer  = 0
            MCT._cpGainTimerActive = false
            if buffered > 0 and MCT.sv and MCT.sv.enabled then
                MCT:ShowNotification(string.format("|c%s+%s CP|r", MCT.sv.championPointsColor, MCT:FormatShortNumber(buffered)), "points", MCT.sv.pointsFontSize)
            end
        end, 500)
    end
end

-- OnPowerWarning: handles EVENT_POWER_UPDATE for low-resource warnings,
-- ultimate-ready notification, and execute-threshold alerts on reticle target.
MCT._powerWarnState  = MCT._powerWarnState  or {}
MCT._ultimateState   = MCT._ultimateState   or { notified = false, maximum = 0 }
MCT._execAlerts      = MCT._execAlerts      or {}

local function OnPowerWarning(eventCode, unitTag, powerIndex, powerType, power, powerMax)
    if not MCT.sv or not MCT.sv.enabled then return end

    -- Execute alert: watch reticle target health independently.
    if unitTag == "reticleover" and powerType == COMBAT_MECHANIC_FLAGS_HEALTH
       and MCT.sv.showAlertExecute and not IsUnitDead("reticleover")
       and IsUnitAttackable("reticleover")
    then
        if powerMax and powerMax > 0 then
            local pct       = power / powerMax * 100
            local threshold = tonumber(MCT.sv.executeThreshold) or 20
            if pct <= threshold then
                local now      = GetGameTimeMilliseconds()
                local freqMs   = (tonumber(MCT.sv.executeFrequency) or 8) * 1000
                local unitName = GetRawUnitName("reticleover") or "reticle"
                local last     = MCT._execAlerts[unitName] or 0
                if (now - last) > freqMs then
                    MCT._execAlerts[unitName] = now
                    MCT:ShowNotification(string.format("|c%sEXECUTE! (%d%%)|r", MCT.sv.alertColor, math.floor(pct)), "alert", MCT.sv.alertFontSize)
                end
            end
        end
        return
    end

    if unitTag ~= "player" then return end

    local sv = MCT.sv

    -- Ultimate ready: fires when ultimate pool reaches its ability cost.
    if powerType == COMBAT_MECHANIC_FLAGS_ULTIMATE then
        local ultState  = MCT._ultimateState
        local maximum   = 0
        pcall(function()
            maximum = GetSlotAbilityCost(ACTION_BAR_ULTIMATE_SLOT_INDEX + 1) or 0
        end)
        if maximum > 0 then
            ultState.maximum = maximum
        end

        if sv.showUltimateReady and ultState.maximum > 0 then
            if power >= ultState.maximum then
                if not ultState.notified then
                    ultState.notified = true
                    MCT:ShowNotification(string.format("|c%sULTIMATE READY!|r", sv.ultimateReadyColor), "resourceWarning", sv.resourceWarningFontSize)
                    if sv.warningSoundEnabled then pcall(PlaySound, "Ability_Failed") end
                end
            else
                ultState.notified = false
            end
        end
        return
    end

    if not powerMax or powerMax <= 0 then return end
    local pct = power / powerMax * 100

    MCT._powerWarnState[powerType] = MCT._powerWarnState[powerType] or { warned = false }
    local state = MCT._powerWarnState[powerType]

    local color, toggle, threshold, typeName
    if powerType == COMBAT_MECHANIC_FLAGS_HEALTH then
        color = sv.lowHealthColor;  toggle = sv.showLowHealth;  threshold = tonumber(sv.healthThreshold)  or 35; typeName = "HEALTH"
    elseif powerType == COMBAT_MECHANIC_FLAGS_MAGICKA then
        color = sv.lowMagickaColor; toggle = sv.showLowMagicka; threshold = tonumber(sv.magickaThreshold) or 35; typeName = "MAGICKA"
    elseif powerType == COMBAT_MECHANIC_FLAGS_STAMINA then
        color = sv.lowStaminaColor; toggle = sv.showLowStamina; threshold = tonumber(sv.staminaThreshold) or 35; typeName = "STAMINA"
    else
        return
    end

    if not toggle then return end

    if pct < threshold and not state.warned then
        state.warned = true
        MCT:ShowNotification(string.format("|c%sLOW %s!|r", color, typeName), "resourceWarning", sv.resourceWarningFontSize)
        if sv.warningSoundEnabled then pcall(PlaySound, "Ability_Failed") end
    elseif pct > threshold + 10 then
        state.warned = false
    end
end

-- InitPotionReady: hooks the potion action button to detect when
-- a potion cooldown finishes, then fires a ShowNotification.
-- Wrapped in pcall to survive API drift across ESO updates.
local function InitPotionReady()
    local ok, btn = pcall(function()
        return ZO_ActionBar_GetButton(ACTION_BAR_FIRST_NORMAL_SLOT_INDEX + 1)
    end)
    if not ok or not btn or not btn.UpdateCooldown then return end

    local UpdateCooldown_Orig = btn.UpdateCooldown
    local inCooldown = false

    btn.UpdateCooldown = function(button, ...)
        UpdateCooldown_Orig(button, ...)
        if not MCT.sv or not MCT.sv.showPotionReady then return end

        local ok2, slotNum = pcall(function() return button:GetSlot() end)
        if not ok2 then return end

        local ok3, snd = pcall(GetSlotItemSound, slotNum)
        if not ok3 or snd ~= ITEM_SOUND_CATEGORY_POTION then return end

        if not inCooldown and button.inCooldown then
            local cooldown = button.cooldown and button.cooldown:GetTimeLeft() or 0
            if cooldown > 0 then
                inCooldown = true
                local ok4, slotName = pcall(function()
                    return zo_strformat(SI_LINK_FORMAT_ITEM_NAME, GetSlotName(slotNum))
                end)
                local name = (ok4 and slotName and slotName ~= "") and slotName or "Potion"
                zo_callLater(function()
                    if MCT.sv and MCT.sv.enabled and MCT.sv.showPotionReady then
                        MCT:ShowNotification(string.format("|c%s%s Ready!|r", MCT.sv.potionReadyColor, name), "resourceWarning", MCT.sv.resourceWarningFontSize)
                        if MCT.sv.warningSoundEnabled then pcall(PlaySound, "Ability_Failed") end
                    end
                    inCooldown = false
                end, cooldown)
            end
        end
    end
end

function MCT:RegisterCombat()
    -- Primary combat event: handles all damage, healing, CC, mitigation, energize/drain.
    EVENT_MANAGER:RegisterForEvent(MCT.name .. "Combat", EVENT_COMBAT_EVENT, OnCombatEvent)

    -- Power update: detect resource restoration (magicka, stamina, health).
    EVENT_MANAGER:RegisterForEvent(MCT.name .. "ResourceRestore", EVENT_POWER_UPDATE, OnResourceRestore)

    -- Active combat tip alerts: block, exploit weakness, interrupt, dodge roll.
    EVENT_MANAGER:RegisterForEvent(MCT.name .. "AlertTip", EVENT_DISPLAY_ACTIVE_COMBAT_TIP, OnAlertTip)

    -- Combat state: entered / left combat.
    EVENT_MANAGER:RegisterForEvent(MCT.name .. "CombatState", EVENT_PLAYER_COMBAT_STATE, OnCombatState)

    -- Alliance points gained (PvP).
    EVENT_MANAGER:RegisterForEvent(MCT.name .. "AlliancePoints", EVENT_ALLIANCE_POINT_UPDATE, OnAlliancePoints)

    -- Experience points (player only).
    EVENT_MANAGER:RegisterForEvent(MCT.name .. "ExperiencePoints", EVENT_EXPERIENCE_UPDATE, OnExperiencePoints)
    EVENT_MANAGER:AddFilterForEvent(MCT.name .. "ExperiencePoints", EVENT_EXPERIENCE_UPDATE, REGISTER_FILTER_UNIT_TAG, "player")

    -- Champion points (player only).
    EVENT_MANAGER:RegisterForEvent(MCT.name .. "ChampionPoints", EVENT_CHAMPION_POINT_UPDATE, OnChampionPoints)
    EVENT_MANAGER:AddFilterForEvent(MCT.name .. "ChampionPoints", EVENT_CHAMPION_POINT_UPDATE, REGISTER_FILTER_UNIT_TAG, "player")

    -- Power warnings: low health/magicka/stamina, ultimate ready, execute alert.
    EVENT_MANAGER:RegisterForEvent(MCT.name .. "PowerWarning", EVENT_POWER_UPDATE, OnPowerWarning)

    -- Potion ready hook (deferred 1s to let action bar initialize first).
    zo_callLater(InitPotionReady, 1000)
end
