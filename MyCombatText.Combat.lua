-- ============================================================
-- MyCombatText.Combat.lua
-- Standalone combat event processing pipeline.
-- Registers native ESO events, classifies each event as
-- damage/heal/CC, applies per-feature filters, and dispatches to
-- the merge queue (MCT.Tracking) for display.
-- No external library dependencies — uses ESO API directly.
--
-- Performance notes
-- -----------------
-- * EVENT_COMBAT_EVENT is registered TWICE with engine-side filters
--   (source == player, target == player) and IS_ERROR == false. The
--   game client then only calls into Lua for events that involve the
--   player, instead of every combat event in the zone. In a Cyrodiil
--   zerg this cuts handler invocations by one to two orders of
--   magnitude.
-- * EVENT_POWER_UPDATE is likewise filtered by unit tag ("player",
--   and "reticleover" + health only for the execute alert), and both
--   power features share one handler that uses the event's own
--   power values instead of re-querying GetUnitPower().
-- * Classification uses single table lookups (MCT.Result.Sets /
--   GetCCSpecial) instead of chains of Is*() calls.
-- * Notification strings are cached per (text, color) so steady-state
--   combat doesn't allocate a new string per label.
-- ============================================================

MyCombatText = MyCombatText or {}
local MCT = MyCombatText
local RF = MCT.Result           -- Combat result classifier namespace from ResultFilter.lua.
local SETS = RF.Sets
local GetCCSpecial = RF.GetCCSpecial

-- Local aliases for frequently called globals.
local GetGameTimeMs = GetGameTimeMilliseconds
local EM = EVENT_MANAGER
local tonumber = tonumber
local floor = math.floor

local SET_HEAL        = SETS.heal
local SET_DAMAGE      = SETS.damage
local SET_DAMAGETAKEN = SETS.damageTaken
local SET_CRIT        = SETS.crit
local SET_DOT         = SETS.dot
local SET_BLOCKED     = SETS.blocked
local SET_SHIELDED    = SETS.shielded
local SET_MISS        = SETS.miss
local SET_IMMUNE      = SETS.immune
local SET_PARRIED     = SETS.parried
local SET_REFLECTED   = SETS.reflected
local SET_ENERGIZE    = SETS.energize
local SET_DRAIN       = SETS.drain

local POWER_HEALTH   = COMBAT_MECHANIC_FLAGS_HEALTH
local POWER_MAGICKA  = COMBAT_MECHANIC_FLAGS_MAGICKA
local POWER_STAMINA  = COMBAT_MECHANIC_FLAGS_STAMINA
local POWER_ULTIMATE = COMBAT_MECHANIC_FLAGS_ULTIMATE
-- Legacy alias: older API versions used POWERTYPE_HEALTH.
local POWER_HEALTH_LEGACY = POWERTYPE_HEALTH

local UNIT_PLAYER = COMBAT_UNIT_TYPE_PLAYER

-- Per-type "show" toggle for crowd-control / dodge labels.
local CC_TOGGLE = {
    dodged = "showDodges",
    stunned = "showStuns",
    feared = "showFears",
    charmed = "showCharms",
    silenced = "showSilences",
    disoriented = "showDisorients",
    offbalanced = "showOffbalances",
    immobilized = "showImmobilizes",
}

-- Cached colored label text (see MCT:ColorTextCached in Formatting.lua).
local function Colored(hex, text)
    return MCT:ColorTextCached(hex, text)
end

-- ---------------------------------------------------------------
-- Player Unit ID Cache
-- ESO does not expose a direct GetPlayerUnitId() API. We derive
-- and cache the player's combat unit ID from EVENT_COMBAT_EVENT
-- callbacks where sourceType or targetType is COMBAT_UNIT_TYPE_PLAYER.
-- ---------------------------------------------------------------
MCT._playerUnitId = MCT._playerUnitId or nil

function MCT:GetPlayerUnitId()
    return MCT._playerUnitId
end

-- ---------------------------------------------------------------
-- PvP flag cache. IsUnitPvPFlagged() is a C call; in pvpOnly mode it
-- used to run on every single combat event. The flag changes rarely,
-- so re-check at most every 1000 ms.
-- ---------------------------------------------------------------
local pvpFlagCached = false
local pvpFlagCheckedAt = -1000000

local function IsPlayerPvPFlaggedCached(now)
    if now - pvpFlagCheckedAt >= 1000 then
        pvpFlagCheckedAt = now
        pvpFlagCached = IsUnitPvPFlagged("player") and true or false
    end
    return pvpFlagCached
end

-- ---------------------------------------------------------------
-- IsHealingResult: explicit ACTION_RESULT match first, then a
-- power-type heuristic for result IDs our table doesn't know yet
-- (API drift safety net).
-- ---------------------------------------------------------------
local function IsHealingResult(result, powerType, hitValue, overflow)
    if SET_HEAL[result] then
        return true
    end
    if (powerType == POWER_HEALTH or (POWER_HEALTH_LEGACY and powerType == POWER_HEALTH_LEGACY))
        and (hitValue > 0 or overflow > 0)
        and not SET_DAMAGE[result]
    then
        return true
    end
    return false
end

local function PowerName(powerType)
    if powerType == POWER_MAGICKA then return "Magicka" end
    if powerType == POWER_STAMINA then return "Stamina" end
    return "Resource"
end

-- ---------------------------------------------------------------
-- HandleCombatEvent: shared body for both filtered registrations.
--
-- Processing order:
--   1. Early-exit guards (disabled, pvpOnly).
--   2. Cache/update player unit ID; patch missing unit IDs.
--   3. Healing branch (all directions) via QueueHit.
--   4. CC labels (both directions) via ShowText.
--   5. Outgoing: mitigation / energize / drain / damage + tracking.
--   6. Incoming/self: cleanse alert + damage taken via QueueHit.
-- ---------------------------------------------------------------
local function HandleCombatEvent(result, powerType, sourceIsPlayer, targetIsPlayer, hitValue, sourceUnitId, targetUnitId, abilityId, overflow)
    local sv = MCT.sv
    if not sv or not sv.enabled then return end

    -- Cache the player's unit ID from whichever side is the player.
    if sourceIsPlayer and sourceUnitId and sourceUnitId ~= 0 then
        MCT._playerUnitId = sourceUnitId
    elseif targetIsPlayer and targetUnitId and targetUnitId ~= 0 then
        MCT._playerUnitId = targetUnitId
    end
    local playerId = MCT._playerUnitId

    -- Patch missing/zero unit IDs so downstream comparisons work.
    if (sourceUnitId == nil or sourceUnitId == 0) and sourceIsPlayer then
        sourceUnitId = playerId
    end
    if (targetUnitId == nil or targetUnitId == 0) and targetIsPlayer then
        targetUnitId = playerId
    end

    local now = GetGameTimeMs()
    if sv.pvpOnly and not IsPlayerPvPFlaggedCached(now) then return end

    local outgoing = sourceIsPlayer and not targetIsPlayer
    local incoming = targetIsPlayer and not sourceIsPlayer

    hitValue = tonumber(hitValue) or 0
    overflow = tonumber(overflow) or 0

    -- Opportunistic tracking-table cleanup (self-throttled to every 5s).
    MCT:PruneTrackingTables(now)

    -- ---- Healing branch ----
    if IsHealingResult(result, powerType, hitValue, overflow) then
        local crit = SET_CRIT[result] == true
        if sv.showHealing and (not sv.critOnly or crit) then
            if hitValue > 0 then
                local mergeGroup = (incoming and "healing:incoming")
                    or (outgoing and "healing:outgoing")
                    or "healing:self"
                MCT:QueueHit(hitValue, crit, true, sourceUnitId, targetUnitId, false, abilityId, mergeGroup)
            end
            if sv.showOverhealing and overflow > 0 then
                MCT:QueueOverhealing(overflow, crit, sourceUnitId, targetUnitId, abilityId)
            end
        end
        return
    end

    -- ---- Crowd control / dodge (either direction) ----
    local ccSpecial = GetCCSpecial(result)
    if ccSpecial then
        if sv[CC_TOGGLE[ccSpecial]] ~= false then
            MCT:ShowText(nil, false, false, ccSpecial, sourceUnitId, targetUnitId, false, abilityId)
        end
        return
    end

    -- ---- Outgoing (player acting on another unit) ----
    if outgoing then
        -- Mitigation: the player's attack was negated.
        if SET_MISS[result] then
            if sv.showMiss then
                MCT:ShowNotification(Colored(sv.missColor, "MISS"), "miss", sv.mitigationFontSize)
                return
            end
        elseif SET_IMMUNE[result] then
            if sv.showImmune then
                MCT:ShowNotification(Colored(sv.immuneColor, "IMMUNE"), "immune", sv.mitigationFontSize)
                return
            end
        elseif SET_PARRIED[result] then
            if sv.showParried then
                MCT:ShowNotification(Colored(sv.parriedColor, "PARRIED"), "parried", sv.mitigationFontSize)
                return
            end
        elseif SET_REFLECTED[result] then
            if sv.showReflected then
                MCT:ShowNotification(Colored(sv.reflectedColor, "REFLECTED"), "reflected", sv.mitigationFontSize)
                return
            end
        elseif SET_ENERGIZE[result] then
            if sv.showEnergize and hitValue > 0 then
                MCT:ShowNotification(string.format("|c%s+%s %s|r", sv.energizeColor, MCT:FormatShortNumber(hitValue), PowerName(powerType)), "energize", sv.energizeFontSize)
                return
            end
        elseif SET_DRAIN[result] then
            if sv.showDrain and hitValue > 0 then
                MCT:ShowNotification(string.format("|c%sDrain -%s %s|r", sv.drainColor, MCT:FormatShortNumber(hitValue), PowerName(powerType)), "drain", sv.energizeFontSize)
                return
            end
        end

        if hitValue > 0 and SET_DAMAGE[result] then
            local crit = SET_CRIT[result] == true
            if sv.critOnly and not crit then return end
            if not sv.showDamage then return end
            if SET_DOT[result] and not sv.showDots then return end

            MCT:QueueHit(hitValue, crit, false, sourceUnitId, targetUnitId, SET_BLOCKED[result] == true, abilityId, "damage:outgoing")
            MCT:AddDps(targetUnitId, hitValue, now)
            MCT:TrackBurst(targetUnitId, hitValue, crit, now)
            MCT:TrackShieldbreak(targetUnitId, hitValue, SET_SHIELDED[result] == true, now)
            MCT:ApplyMarkerRule(targetUnitId, "pressure")
        end
        return
    end

    -- ---- Incoming / self (player is the target) ----

    -- Cleanse alert: warn when an incoming DoT tick lands (throttled to 5s).
    if incoming and SET_DOT[result] and sv.showAlertCleanse then
        local last = MCT._cleanseAlertAt or 0
        if (now - last) > 5000 then
            MCT._cleanseAlertAt = now
            MCT:ShowNotification(Colored(sv.alertColor, "CLEANSE!"), "alert", sv.alertFontSize)
        end
    end

    if hitValue > 0 and SET_DAMAGETAKEN[result] then
        local crit = SET_CRIT[result] == true
        if sv.critOnly and not crit then return end
        if not sv.showDamageTaken then return end

        local blocked = SET_BLOCKED[result] == true
        local mergeGroup
        if not incoming then
            mergeGroup = "damage:self"
        else
            mergeGroup = blocked and "damageTaken:blocked" or "damageTaken"
        end
        MCT:QueueHit(hitValue, crit, false, sourceUnitId, targetUnitId, blocked, abilityId, mergeGroup)
    end
end

-- Registration with source == player filter. Handles outgoing + self.
local function OnCombatEventFromPlayer(_, result, isError, _, _, _, _, sourceType, _, targetType, hitValue, powerType, _, _, sourceUnitId, targetUnitId, abilityId, overflow)
    if isError then return end -- belt-and-braces; the engine filter already drops these
    HandleCombatEvent(result, powerType, true, targetType == UNIT_PLAYER, hitValue, sourceUnitId, targetUnitId, abilityId, overflow)
end

-- Registration with target == player filter. Self events (source is also
-- the player) were already delivered by the source-filtered registration,
-- so skip them here to avoid double-processing.
local function OnCombatEventToPlayer(_, result, isError, _, _, _, _, sourceType, _, _, hitValue, powerType, _, _, sourceUnitId, targetUnitId, abilityId, overflow)
    if isError or sourceType == UNIT_PLAYER then return end
    HandleCombatEvent(result, powerType, false, true, hitValue, sourceUnitId, targetUnitId, abilityId, overflow)
end

-- Unfiltered fallback (only used if the filter API is unavailable).
local function OnCombatEventUnfiltered(_, result, isError, _, _, _, _, sourceType, _, targetType, hitValue, powerType, _, _, sourceUnitId, targetUnitId, abilityId, overflow)
    if isError then return end
    local sourceIsPlayer = (sourceType == UNIT_PLAYER)
    local targetIsPlayer = (targetType == UNIT_PLAYER)
    if not sourceIsPlayer and not targetIsPlayer then return end
    HandleCombatEvent(result, powerType, sourceIsPlayer, targetIsPlayer, hitValue, sourceUnitId, targetUnitId, abilityId, overflow)
end

-- ---------------------------------------------------------------
-- MCT.lastResourceAmounts: last known power value per resource type
-- so resource restore can compute the delta.
-- ---------------------------------------------------------------
MCT.lastResourceAmounts = MCT.lastResourceAmounts or {}

-- ---------------------------------------------------------------
-- MCT:ShowResourceRestore: constructs and animates a floating label
-- for a magicka/stamina/health restoration event.
-- ---------------------------------------------------------------
local RESOURCE_LABELS = {}
local RESOURCE_TEXTURE_CODES = {}
if POWER_MAGICKA then
    RESOURCE_LABELS[POWER_MAGICKA] = "\226\156\166 Magicka"
    RESOURCE_TEXTURE_CODES[POWER_MAGICKA] = "magicka"
end
if POWER_STAMINA then
    RESOURCE_LABELS[POWER_STAMINA] = "\226\156\166 Stamina"
    RESOURCE_TEXTURE_CODES[POWER_STAMINA] = "stamina"
end
if POWER_HEALTH then
    RESOURCE_LABELS[POWER_HEALTH] = "\226\156\166 Health"
end

function MCT:ShowResourceRestore(amount, powerType, playerId)
    local label, key = MCT.pool:AcquireObject()
    if not label then return end
    local sv = MCT.sv

    label.mctAbilityId = nil
    label.mctAbilityIds = nil
    label.mctEventCode = RESOURCE_TEXTURE_CODES[powerType] or "resource"

    label:SetFont(MCT:GetCachedFTNFont(sv.resourceRestoreFontSize))
    label:SetAnchor(MCT:GetAnchor("resource"))
    label:SetText(MCT:StylizeDisplayText(
        string.format("|c%s+%s (%s)|r",
            sv.resourceRestoreColor,
            MCT:FormatShortNumber(amount),
            RESOURCE_LABELS[powerType] or "RESOURCE"
        ),
        "resource"
    ))

    MCT:Animate(label, "resourceRestore", key)
end

-- ---------------------------------------------------------------
-- Active combat tip alerts (EVENT_DISPLAY_ACTIVE_COMBAT_TIP).
-- tipId mapping: 1=block, 2=exploit weakness, 3=interrupt, 4=dodge roll.
-- ---------------------------------------------------------------
local ALERT_TIPS = {
    [1] = { toggle = "showAlertBlock",     text = "BLOCK!" },
    [2] = { toggle = "showAlertExploit",   text = "EXPLOIT!" },
    [3] = { toggle = "showAlertInterrupt", text = "INTERRUPT!" },
    [4] = { toggle = "showAlertDodge",     text = "DODGE!" },
}

local function OnAlertTip(_, tipId)
    local sv = MCT.sv
    if not sv or not sv.enabled then return end
    local tip = ALERT_TIPS[tipId]
    if tip and sv[tip.toggle] then
        MCT:ShowNotification(Colored(sv.alertColor, tip.text), "alert", sv.alertFontSize)
    end
end

-- ---------------------------------------------------------------
-- MCT:ResetCombatTracking: clears every per-fight table and all
-- visible labels. Runs whenever the player leaves combat, whether or
-- not the "Entered/Left Combat" notification is enabled.
-- ---------------------------------------------------------------
function MCT:ResetCombatTracking()
    if MCT.pool and MCT.pool.ReleaseAllObjects then
        MCT.pool:ReleaseAllObjects()
    end
    MCT.burstTargets = {}
    MCT.shields      = {}
    MCT.dps          = {}
    MCT.merge        = {}
    MCT.mergeTimers  = {}
    if MCT.ResetLaneQueues then
        MCT:ResetLaneQueues()
    end
    MCT._displayRateWindowStart = 0
    MCT._displayRateCount = 0
    MCT._eventTextureSuppressedUntil = 0
    MCT.lastPruneMs = 0
    MCT._execAlerts = {}
end

-- OnCombatState: handles EVENT_PLAYER_COMBAT_STATE.
local function OnCombatState(_, inCombat)
    local sv = MCT.sv
    if not sv then return end

    if not inCombat then
        -- Clear first so the "Left Combat" label below isn't immediately
        -- released along with everything else.
        MCT:ResetCombatTracking()
    end

    if not sv.enabled or not sv.showCombatState then return end
    if inCombat then
        MCT:ShowNotification(Colored(sv.combatStateColor, "Entered Combat"), "combatState", sv.combatStateFontSize)
    else
        MCT:ShowNotification(Colored(sv.combatStateColor, "Left Combat"), "combatState", sv.combatStateFontSize)
    end
end

-- OnAlliancePoints: handles EVENT_ALLIANCE_POINT_UPDATE.
local function OnAlliancePoints(_, alliancePoints, playSound, difference)
    local sv = MCT.sv
    if not sv or not sv.enabled or not sv.showAlliancePoints then return end
    if not difference or difference <= 0 then return end
    MCT:ShowNotification(string.format("|c%s+%s AP|r", sv.alliancePointsColor, MCT:FormatShortNumber(difference)), "points", sv.pointsFontSize)
end

-- ---------------------------------------------------------------
-- Buffered XP / CP gains (500 ms batching so multi-kill spikes merge).
-- The flush callbacks are created once instead of per event.
-- ---------------------------------------------------------------
MCT._xpGainBuffer = MCT._xpGainBuffer or 0
MCT._xpGainTimerActive = MCT._xpGainTimerActive or false
MCT._xpPreviousXp = nil
MCT._xpPreviousMaxXp = nil

local function FlushXpGain()
    local buffered = MCT._xpGainBuffer
    MCT._xpGainBuffer = 0
    MCT._xpGainTimerActive = false
    local sv = MCT.sv
    if buffered > 0 and sv and sv.enabled then
        MCT:ShowNotification(string.format("|c%s+%s XP|r", sv.experiencePointsColor, MCT:FormatShortNumber(buffered)), "points", sv.pointsFontSize)
    end
end

local function OnExperiencePoints(_, unit, currentXp, maxXp, reason)
    local sv = MCT.sv
    if not sv or not sv.enabled or not sv.showExperiencePoints then return end

    local prevXp  = MCT._xpPreviousXp  or currentXp
    local prevMax = MCT._xpPreviousMaxXp or maxXp
    local gain
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
        zo_callLater(FlushXpGain, 500)
    end
end

MCT._cpGainBuffer = MCT._cpGainBuffer or 0
MCT._cpGainTimerActive = MCT._cpGainTimerActive or false
MCT._cpPreviousPoints = nil

local function FlushCpGain()
    local buffered = MCT._cpGainBuffer
    MCT._cpGainBuffer = 0
    MCT._cpGainTimerActive = false
    local sv = MCT.sv
    if buffered > 0 and sv and sv.enabled then
        MCT:ShowNotification(string.format("|c%s+%s CP|r", sv.championPointsColor, MCT:FormatShortNumber(buffered)), "points", sv.pointsFontSize)
    end
end

local function OnChampionPoints(_, unit, currentPoints, maxPoints, reason)
    local sv = MCT.sv
    if not sv or not sv.enabled or not sv.showChampionPoints then return end

    local prev = MCT._cpPreviousPoints or currentPoints
    local gain = currentPoints - prev
    MCT._cpPreviousPoints = currentPoints

    if gain <= 0 then return end
    MCT._cpGainBuffer = MCT._cpGainBuffer + gain

    if not MCT._cpGainTimerActive then
        MCT._cpGainTimerActive = true
        zo_callLater(FlushCpGain, 500)
    end
end

-- ---------------------------------------------------------------
-- Power updates.
-- EVENT_POWER_UPDATE signature:
--   (eventCode, unitTag, powerIndex, powerType, powerValue, powerMax, powerEffectiveMax)
-- One player-filtered handler drives resource-restore, ultimate-ready
-- and low-resource warnings; a separate reticleover/health-filtered
-- handler drives the execute alert.
-- ---------------------------------------------------------------
MCT._powerWarnState  = MCT._powerWarnState  or {}
MCT._ultimateState   = MCT._ultimateState   or { notified = false, maximum = 0 }
MCT._execAlerts      = MCT._execAlerts      or {}

-- Per-power-type low-resource warning config (sv key names).
local LOW_WARN = {}
if POWER_HEALTH then
    LOW_WARN[POWER_HEALTH]  = { color = "lowHealthColor",  toggle = "showLowHealth",  threshold = "healthThreshold",  name = "HEALTH" }
end
if POWER_MAGICKA then
    LOW_WARN[POWER_MAGICKA] = { color = "lowMagickaColor", toggle = "showLowMagicka", threshold = "magickaThreshold", name = "MAGICKA" }
end
if POWER_STAMINA then
    LOW_WARN[POWER_STAMINA] = { color = "lowStaminaColor", toggle = "showLowStamina", threshold = "staminaThreshold", name = "STAMINA" }
end

-- Action-bar slot of the ultimate ability (nil-safe across API changes).
local ULTIMATE_SLOT = ACTION_BAR_ULTIMATE_SLOT_INDEX and (ACTION_BAR_ULTIMATE_SLOT_INDEX + 1) or nil

local function PlayWarningSound(sv)
    if sv.warningSoundEnabled then pcall(PlaySound, "Ability_Failed") end
end

-- Resource restore (magicka / stamina only — health gains are already
-- displayed as heals by the combat-event pipeline, so showing them here
-- too would double every heal on screen).
local function HandleResourceRestore(sv, powerType, power)
    if powerType ~= POWER_MAGICKA and powerType ~= POWER_STAMINA then return end

    local last = MCT.lastResourceAmounts[powerType]
    MCT.lastResourceAmounts[powerType] = power
    -- First sample after login/reload only seeds the baseline; without
    -- this the entire pool was reported as a "restore".
    if last == nil then return end

    if not sv.showResourceRestore then return end
    if sv.pvpOnly and not IsPlayerPvPFlaggedCached(GetGameTimeMs()) then return end

    local restoreAmount = power - last
    if restoreAmount > 50 then
        MCT:QueueResourceRestore(restoreAmount, powerType, MCT._playerUnitId)
    end
end

local function HandleUltimate(sv, power)
    local ultState = MCT._ultimateState
    local ok, cost = false, nil
    if ULTIMATE_SLOT then
        ok, cost = pcall(GetSlotAbilityCost, ULTIMATE_SLOT)
    end
    if ok and type(cost) == "number" and cost > 0 then
        ultState.maximum = cost
    end

    if sv.showUltimateReady and ultState.maximum > 0 then
        if power >= ultState.maximum then
            if not ultState.notified then
                ultState.notified = true
                MCT:ShowNotification(Colored(sv.ultimateReadyColor, "ULTIMATE READY!"), "resourceWarning", sv.resourceWarningFontSize)
                PlayWarningSound(sv)
            end
        else
            ultState.notified = false
        end
    end
end

local function HandleLowResource(sv, powerType, power, powerMax)
    local cfg = LOW_WARN[powerType]
    if not cfg or not sv[cfg.toggle] then return end
    if not powerMax or powerMax <= 0 then return end

    local pct = power / powerMax * 100
    local threshold = tonumber(sv[cfg.threshold]) or 35

    local state = MCT._powerWarnState[powerType]
    if not state then
        state = { warned = false }
        MCT._powerWarnState[powerType] = state
    end

    if pct < threshold then
        if not state.warned then
            state.warned = true
            MCT:ShowNotification(Colored(sv[cfg.color], "LOW " .. cfg.name .. "!"), "resourceWarning", sv.resourceWarningFontSize)
            PlayWarningSound(sv)
        end
    elseif pct > threshold + 10 then
        state.warned = false
    end
end

local function OnPlayerPowerUpdate(_, unitTag, powerIndex, powerType, power, powerMax)
    if unitTag ~= "player" then return end -- safety if the unit filter is unavailable
    local sv = MCT.sv
    if not sv or not sv.enabled then return end

    if powerType == POWER_ULTIMATE then
        HandleUltimate(sv, power)
        return
    end

    HandleResourceRestore(sv, powerType, power)
    HandleLowResource(sv, powerType, power, powerMax)
end

local function OnReticlePowerUpdate(_, unitTag, powerIndex, powerType, power, powerMax)
    local sv = MCT.sv
    if not sv or not sv.enabled or not sv.showAlertExecute then return end
    if unitTag ~= "reticleover" or powerType ~= POWER_HEALTH then return end
    if not powerMax or powerMax <= 0 then return end

    local pct = power / powerMax * 100
    local threshold = tonumber(sv.executeThreshold) or 20
    if pct > threshold then return end

    -- Cheap numeric checks first; only now touch the unit API.
    if IsUnitDead("reticleover") or not IsUnitAttackable("reticleover") then return end

    local now      = GetGameTimeMs()
    local freqMs   = (tonumber(sv.executeFrequency) or 8) * 1000
    local unitName = GetRawUnitName("reticleover") or "reticle"
    local last     = MCT._execAlerts[unitName] or 0
    if (now - last) > freqMs then
        MCT._execAlerts[unitName] = now
        MCT:ShowNotification(string.format("|c%sEXECUTE! (%d%%)|r", sv.alertColor, floor(pct)), "alert", sv.alertFontSize)
    end
end

-- Unfiltered fallback for EVENT_POWER_UPDATE.
local function OnPowerUpdateUnfiltered(eventCode, unitTag, ...)
    if unitTag == "player" then
        OnPlayerPowerUpdate(eventCode, unitTag, ...)
    elseif unitTag == "reticleover" then
        OnReticlePowerUpdate(eventCode, unitTag, ...)
    end
end

-- ---------------------------------------------------------------
-- InitPotionReady: hooks the quickslot action button to detect when a
-- potion cooldown finishes, then fires a notification.
-- Wrapped in pcall to survive API drift across ESO updates.
-- ---------------------------------------------------------------
local function InitPotionReady()
    local ok, btn = pcall(function()
        return ZO_ActionBar_GetButton(ACTION_BAR_FIRST_NORMAL_SLOT_INDEX + 1)
    end)
    if not ok or not btn or not btn.UpdateCooldown then return end

    local UpdateCooldown_Orig = btn.UpdateCooldown
    local inCooldown = false

    btn.UpdateCooldown = function(button, ...)
        UpdateCooldown_Orig(button, ...)
        local sv = MCT.sv
        if not sv or not sv.showPotionReady then return end
        -- Cheapest checks first: nothing to do unless a new cooldown started.
        if inCooldown or not button.inCooldown then return end

        local ok2, slotNum = pcall(button.GetSlot, button)
        if not ok2 then return end

        local ok3, snd = pcall(GetSlotItemSound, slotNum)
        if not ok3 or snd ~= ITEM_SOUND_CATEGORY_POTION then return end

        local cooldown = button.cooldown and button.cooldown:GetTimeLeft() or 0
        if cooldown <= 0 then return end

        inCooldown = true
        local ok4, slotName = pcall(function()
            return zo_strformat(SI_LINK_FORMAT_ITEM_NAME, GetSlotName(slotNum))
        end)
        local name = (ok4 and slotName and slotName ~= "") and slotName or "Potion"
        zo_callLater(function()
            local sv2 = MCT.sv
            if sv2 and sv2.enabled and sv2.showPotionReady then
                MCT:ShowNotification(string.format("|c%s%s Ready!|r", sv2.potionReadyColor, name), "resourceWarning", sv2.resourceWarningFontSize)
                PlayWarningSound(sv2)
            end
            inCooldown = false
        end, cooldown)
    end
end

-- ---------------------------------------------------------------
-- MCT:RegisterCombat: registers all event listeners with engine-side
-- filters wherever the API supports them.
-- ---------------------------------------------------------------
local function AddFilter(name, event, ...)
    if not EM.AddFilterForEvent then return false end
    local ok, res = pcall(EM.AddFilterForEvent, EM, name, event, ...)
    return ok and res ~= false
end

function MCT:RegisterCombat()
    local base = MCT.name

    -- Combat events: two filtered registrations (player as source, player as
    -- target). Falls back to one unfiltered registration on very old clients.
    local outName, inName = base .. "CombatOut", base .. "CombatIn"
    EM:RegisterForEvent(outName, EVENT_COMBAT_EVENT, OnCombatEventFromPlayer)
    EM:RegisterForEvent(inName, EVENT_COMBAT_EVENT, OnCombatEventToPlayer)
    local filtered = REGISTER_FILTER_SOURCE_COMBAT_UNIT_TYPE ~= nil
        and AddFilter(outName, EVENT_COMBAT_EVENT, REGISTER_FILTER_SOURCE_COMBAT_UNIT_TYPE, UNIT_PLAYER, REGISTER_FILTER_IS_ERROR, false)
        and AddFilter(inName, EVENT_COMBAT_EVENT, REGISTER_FILTER_TARGET_COMBAT_UNIT_TYPE, UNIT_PLAYER, REGISTER_FILTER_IS_ERROR, false)
    if not filtered then
        EM:UnregisterForEvent(outName, EVENT_COMBAT_EVENT)
        EM:UnregisterForEvent(inName, EVENT_COMBAT_EVENT)
        EM:RegisterForEvent(base .. "Combat", EVENT_COMBAT_EVENT, OnCombatEventUnfiltered)
    end

    -- Power updates: player (restore / warnings / ultimate) and reticle
    -- health (execute alert), each filtered engine-side.
    local playerPower, reticlePower = base .. "PowerPlayer", base .. "PowerReticle"
    EM:RegisterForEvent(playerPower, EVENT_POWER_UPDATE, OnPlayerPowerUpdate)
    EM:RegisterForEvent(reticlePower, EVENT_POWER_UPDATE, OnReticlePowerUpdate)
    local powerFiltered = AddFilter(playerPower, EVENT_POWER_UPDATE, REGISTER_FILTER_UNIT_TAG, "player")
        and AddFilter(reticlePower, EVENT_POWER_UPDATE, REGISTER_FILTER_UNIT_TAG, "reticleover", REGISTER_FILTER_POWER_TYPE, POWER_HEALTH)
    if not powerFiltered then
        EM:UnregisterForEvent(playerPower, EVENT_POWER_UPDATE)
        EM:UnregisterForEvent(reticlePower, EVENT_POWER_UPDATE)
        EM:RegisterForEvent(base .. "Power", EVENT_POWER_UPDATE, OnPowerUpdateUnfiltered)
    end

    -- Active combat tip alerts: block, exploit weakness, interrupt, dodge roll.
    EM:RegisterForEvent(base .. "AlertTip", EVENT_DISPLAY_ACTIVE_COMBAT_TIP, OnAlertTip)

    -- Combat state: entered / left combat (+ per-fight cleanup).
    EM:RegisterForEvent(base .. "CombatState", EVENT_PLAYER_COMBAT_STATE, OnCombatState)

    -- Alliance points gained (PvP).
    EM:RegisterForEvent(base .. "AlliancePoints", EVENT_ALLIANCE_POINT_UPDATE, OnAlliancePoints)

    -- Experience points (player only).
    EM:RegisterForEvent(base .. "ExperiencePoints", EVENT_EXPERIENCE_UPDATE, OnExperiencePoints)
    AddFilter(base .. "ExperiencePoints", EVENT_EXPERIENCE_UPDATE, REGISTER_FILTER_UNIT_TAG, "player")

    -- Champion points (player only).
    EM:RegisterForEvent(base .. "ChampionPoints", EVENT_CHAMPION_POINT_UPDATE, OnChampionPoints)
    AddFilter(base .. "ChampionPoints", EVENT_CHAMPION_POINT_UPDATE, REGISTER_FILTER_UNIT_TAG, "player")

    -- Potion ready hook (deferred 1s to let the action bar initialize first).
    zo_callLater(InitPotionReady, 1000)
end
