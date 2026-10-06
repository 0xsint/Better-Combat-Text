-- ============================================================
-- MyCombatText.Tracking.lua
-- Combat event merge queue, DPS window tracker, burst detection,
-- shield-break detection, priority target marker system, and
-- all stateful tracking tables used by the combat pipeline.
-- ============================================================

MyCombatText = MyCombatText or {}
local MCT = MyCombatText

-- Local aliases to avoid table lookups in hot paths.
local GetGameTimeMs = GetGameTimeMilliseconds
local tinsert = table.insert

-- ---------------------------------------------------------------
-- AddAbilityId: maintains a small ordered list of the most recent
-- ability IDs associated with a merged combat event. The list is
-- capped at maxIcons entries; the oldest ID is evicted when it
-- would exceed the cap. Duplicate IDs are removed and re-appended
-- at the end so the most recent occurrence is always last.
-- Parameters:
--   list      : the ability ID list table to update
--   abilityId : the new ESO ability ID integer to record
-- ---------------------------------------------------------------
local function AddAbilityId(list, abilityId)
    -- Ignore invalid or unset ability IDs.
    if not abilityId or abilityId <= 0 then return end

    -- Remove any previous occurrence of this ID to avoid duplicates.
    for i = 1, #list do
        if list[i] == abilityId then
            table.remove(list, i)
            break
        end
    end

    -- Append the ID at the tail (most recent position).
    list[#list + 1] = abilityId

    -- Evict the oldest ID when over the display cap.
    local maxIcons = 6
    if MCT and MCT.sv then
        local configured = tonumber(MCT.sv.maxEventIcons)
        if configured and configured > 0 then
            maxIcons = configured
        end

        if MCT.sv.performanceMode then
            local perfCap = tonumber(MCT.sv.performanceMaxIcons)
            if perfCap and perfCap > 0 and perfCap < maxIcons then
                maxIcons = perfCap
            end
        end
    end

    if maxIcons < 1 then maxIcons = 1 end
    if maxIcons > 6 then maxIcons = 6 end

    if #list > maxIcons then
        table.remove(list, 1)
    end
end

-- ---------------------------------------------------------------
-- GetHitMergeKey: returns the string merge-bucket key for a hit
-- event so related events within MCT.sv.mergeWindowMs are summed
-- into a single floating label rather than spamming the screen.
-- The key encodes the direction and type of the event:
--   "healing:incoming"    - someone else healed the player
--   "healing:outgoing"    - player healed someone else
--   "healing:self"        - player healed themselves
--   "damageTaken:blocked" - player took blocked damage
--   "damageTaken"         - player took unblocked damage
--   "damage:outgoing"     - player dealt damage to another unit
--   "damage:self"         - player damaged themselves
-- Parameters:
--   isHeal    : true when this is a healing event
--   sID       : sourceUnitId (who caused the event)
--   unitId    : targetUnitId (who received the event)
--   isBlocked : true when the hit was blocked
-- ---------------------------------------------------------------
local function GetHitMergeKey(isHeal, sID, unitId, isBlocked)
    local playerId = MCT:GetPlayerUnitId()

    if isHeal then
        -- Healing received from another unit.
        if unitId == playerId and sID ~= playerId then
            return "healing:incoming"
        -- Healing the player cast on another target.
        elseif unitId ~= playerId and sID == playerId then
            return "healing:outgoing"
        end
        -- Self-heal: source and target are both the player.
        return "healing:self"
    end

    -- Damage the player received from any source.
    if unitId == playerId and sID ~= playerId then
        return isBlocked and "damageTaken:blocked" or "damageTaken"
    -- Damage the player dealt to another unit.
    elseif unitId ~= playerId and sID == playerId then
        return "damage:outgoing"
    end

    -- Fallback: player damaged themselves (rare, e.g. thorns).
    return "damage:self"
end

-- ---------------------------------------------------------------
-- Module-level state tables. Initialized once and reused across
-- all combat events to avoid re-creating tables on hot paths.
-- ---------------------------------------------------------------

-- MCT.merge: active merge buckets indexed by merge-key string.
-- Each bucket accumulates hit values and metadata until it is
-- flushed by FlushMergeKey after the merge window expires.
MCT.merge = MCT.merge or {}

-- MCT.mergeTimers: tracks which merge keys already have a pending
-- zo_callLater flush scheduled, preventing duplicate timers.
MCT.mergeTimers = MCT.mergeTimers or {}

-- MCT.activeMarker: records the currently active reticle marker
-- assignment so the system can clear it after markerAutoClearMs.
MCT.activeMarker = MCT.activeMarker or { unitId = nil, rule = nil, time = 0 }

-- MCT.rulePriority: maps priority rule names ("burst", "shieldbreak",
-- etc.) to their integer priority index; lower = higher priority.
MCT.rulePriority = MCT.rulePriority or {}

-- MCT.ruleMarker: maps priority rule names to their TARGET_MARKER_TYPE_*
-- enum values so ApplyMarkerRule can look up the correct icon quickly.
MCT.ruleMarker = MCT.ruleMarker or {}

-- MCT.burstTargets: per-target burst window state. Each entry tracks
-- cumulative damage, hit count, and crit count within the burst window.
MCT.burstTargets = MCT.burstTargets or {}

-- MCT.shields: per-target last-known shield state. Used to detect the
-- moment a shielded hit is followed by an unshielded hit (shield break).
MCT.shields = MCT.shields or {}

-- MCT.dps: per-target rolling DPS event buckets for the DPS display.
MCT.dps = MCT.dps or {}

-- MCT.lastPruneMs: timestamp of the last garbage-collection pass on
-- tracking tables, used to throttle pruning to every 5 seconds.
MCT.lastPruneMs = MCT.lastPruneMs or 0

-- ---------------------------------------------------------------
-- DebugMerge: conditional debug printer. Only emits output when
-- MCT.sv.debugMerge is true so there is zero runtime cost when off.
-- ---------------------------------------------------------------
local function DebugMerge(fmt, ...)
    if MCT.sv and MCT.sv.debugMerge then
        if select("#", ...) > 0 then
            d("[MCT Merge] " .. string.format(fmt, ...))
        else
            d("[MCT Merge] " .. tostring(fmt))
        end
    end
end

-- ---------------------------------------------------------------
-- ShowQueuedOverhealing: immediately displays a floating overhealing
-- label. Called by FlushMergeKey when a merged overheal bucket is
-- ready to display. Styled separately from normal healing text.
-- Parameters:
--   amount     : total overheal amount to display
--   abilityId  : primary ability that caused the overheal
--   abilityIds : full list of abilities in the merged bucket
-- ---------------------------------------------------------------
local function ShowQueuedOverhealing(amount, abilityId, abilityIds)
    local label, key = MCT.pool:AcquireObject()
    if not label then return end
    label:SetHidden(false)
    label:SetAlpha(1)
    -- Record ability metadata on the label for icon display.
    label.mctAbilityId = abilityId
    label.mctAbilityIds = abilityIds or (abilityId and { abilityId } or nil)
    label.mctEventCode = "overhealing"

    -- Use the overhealing-specific font size and anchor at the healing position.
    label:SetFont(MCT:GetCachedFTNFont(MCT.sv.overhealingFontSize))
    label:SetAnchor(MCT:GetAnchor("healing"))
    local abilitySuffix = MCT:GetAbilityNameSuffix(abilityId, abilityIds)
    -- Format: "+1234 (overheal) - AbilityName" in the overhealing color.
    label:SetText(MCT:StylizeDisplayText(
        string.format("|c%s+%s (overheal)|r%s", MCT.sv.overhealingColor, MCT:FormatShortNumber(amount), abilitySuffix),
        "overhealing"
    ))
    label:SetScale(1.4)
    MCT:Animate(label, "healing", key)
end

-- ---------------------------------------------------------------
-- FlushMergeKey: attempts to display and clear a completed merge
-- bucket. If the bucket is still within the merge window it
-- reschedules itself for another mergeWindowMs delay and returns
-- without displaying, allowing more events to accumulate.
-- Parameters:
--   key : the merge bucket string key to flush
-- ---------------------------------------------------------------
local function FlushMergeKey(key)
    local data = MCT.merge[key]
    -- Bucket was already flushed by another path; clean up the timer flag.
    if not data then
        MCT.mergeTimers[key] = nil
        return
    end

    local now = GetGameTimeMs()
    -- If time since the last event in this bucket is still within the merge
    -- window, reschedule and allow more events to accumulate into it.
    if now - data.time < MCT.sv.mergeWindowMs then
        zo_callLater(function()
            FlushMergeKey(key)
        end, MCT.sv.mergeWindowMs)
        return
    end

    DebugMerge("FLUSH key=%s kind=%s value=%s", tostring(key), tostring(data.kind), tostring(data.value))

    -- Dispatch to the correct display function based on the bucket kind.
    if data.kind == "hit" then
        -- Normal combat hit: damage or healing number.
        MCT:ShowText(data.value, data.crit, data.heal, "", data.sID, data.unitId, data.blocked, data.abilityId, data.abilityIds)
    elseif data.kind == "overhealing" then
        -- Overhealing: healing that exceeded the target max health.
        ShowQueuedOverhealing(data.value, data.abilityId, data.abilityIds)
    elseif data.kind == "resource" then
        -- Resource restore: magicka/stamina/health gain outside combat hits.
        MCT:ShowResourceRestore(data.value, data.powerType, data.playerId)
    end

    -- Clear the bucket and timer flag so the key can be reused.
    MCT.merge[key] = nil
    MCT.mergeTimers[key] = nil
end

-- ---------------------------------------------------------------
-- QueueMergedValue: core merge-queue writer. Either adds a new
-- bucket for the given key or accumulates the new value into an
-- existing bucket that is still within the merge window.
-- A zo_callLater flush timer is scheduled on first write only;
-- repeat events within the window just update the bucket in-place.
-- Parameters:
--   key  : merge bucket string key (from GetHitMergeKey)
--   data : table containing kind, value, and event metadata
-- ---------------------------------------------------------------
local function QueueMergedValue(key, data)
    local now = GetGameTimeMs()
    local bucket = MCT.merge[key]

    -- Accumulate into existing bucket if it is still within the merge window.
    if bucket and now - bucket.time < MCT.sv.mergeWindowMs then
        bucket.value = bucket.value + data.value  -- sum the hit values
        bucket.time = now                          -- extend the window from this event
        -- Propagate crit flag: once one event in the bucket was a crit, the whole batch is crit.
        if data.crit ~= nil then bucket.crit = bucket.crit or data.crit end
        -- Propagate blocked flag similarly.
        if data.blocked ~= nil then bucket.blocked = bucket.blocked or data.blocked end
        -- Always keep the most recent valid ability ID in the bucket.
        if data.abilityId and data.abilityId > 0 then
            bucket.abilityId = data.abilityId
        end
        -- Merge the incoming ability ID list into the bucket's list.
        if data.abilityIds then
            bucket.abilityIds = bucket.abilityIds or {}
            for i = 1, #data.abilityIds do
                AddAbilityId(bucket.abilityIds, data.abilityIds[i])
            end
        end
        DebugMerge("MERGE key=%s kind=%s value=%s", tostring(key), tostring(bucket.kind), tostring(bucket.value))
        return
    end

    -- No existing bucket (or the old one expired): start a fresh bucket.
    data.time = now
    MCT.merge[key] = data
    DebugMerge("NEW key=%s kind=%s value=%s", tostring(key), tostring(data.kind), tostring(data.value))

    -- Schedule a flush timer only if one isn't already running for this key.
    if not MCT.mergeTimers[key] then
        MCT.mergeTimers[key] = true
        zo_callLater(function()
            FlushMergeKey(key)
        end, MCT.sv.mergeWindowMs)
    end
end

-- ---------------------------------------------------------------
-- MCT:QueueHit: public entry point for damage and healing hits.
-- Wraps QueueMergedValue with a "hit" kind bucket, automatically
-- computing the merge key from event direction if one is not supplied.
-- Parameters:
--   value      : raw hit value (damage or healing amount)
--   isCrit     : boolean – was this a critical strike/heal?
--   isHeal     : boolean – healing event (true) or damage (false)
--   sID        : sourceUnitId string
--   unitId     : targetUnitId string
--   isBlocked  : boolean – was the hit blocked?
--   abilityId  : ESO ability ID integer for icon display
--   mergeGroup : optional override merge key; derived automatically if nil
-- ---------------------------------------------------------------
function MCT:QueueHit(value, isCrit, isHeal, sID, unitId, isBlocked, abilityId, mergeGroup)
    -- Use the caller-supplied merge group or derive one from event direction.
    local key = mergeGroup or GetHitMergeKey(isHeal, sID, unitId, isBlocked)
    local abilityIds = nil
    if abilityId and abilityId > 0 then
        abilityIds = { abilityId }
    end

    QueueMergedValue(key, {
        kind = "hit",
        value = value,
        crit = isCrit,
        heal = isHeal,
        sID = sID,
        unitId = unitId,
        blocked = isBlocked and true or false,
        abilityId = abilityId,
        abilityIds = abilityIds,
    })
end

-- ---------------------------------------------------------------
-- MCT:QueueOverhealing: queues an overhealing event for display.
-- Overhealing is healing that exceeds the target's maximum health,
-- shown separately from normal healing to indicate wasted throughput.
-- All overheals from the same merge window are summed into one label.
-- Parameters:
--   amount    : overhealing amount (the overflow value from the event)
--   isCrit    : boolean – was the source heal a critical?
--   sID       : sourceUnitId
--   unitId    : targetUnitId
--   abilityId : ability that generated the overheal
-- ---------------------------------------------------------------
function MCT:QueueOverhealing(amount, isCrit, sID, unitId, abilityId)
    -- All overhealing merges into a single bucket regardless of ability/target.
    local key = "overheal"
    local abilityIds = nil
    if abilityId and abilityId > 0 then
        abilityIds = { abilityId }
    end

    QueueMergedValue(key, {
        kind = "overhealing",
        value = amount,
        crit = isCrit,
        sID = sID,
        unitId = unitId,
        abilityId = abilityId,
        abilityIds = abilityIds,
    })
end

-- ---------------------------------------------------------------
-- MCT:QueueResourceRestore: queues a resource gain event for display
-- (magicka, stamina, or health restore from regens/procs/potions).
-- Each power type gets its own merge bucket so the labels aggregate
-- correctly without mixing resource types.
-- Parameters:
--   amount    : amount of resource restored
--   powerType : POWERTYPE_MAGICKA / STAMINA / HEALTH constant
--   playerId  : player unit id for positioning
-- ---------------------------------------------------------------
function MCT:QueueResourceRestore(amount, powerType, playerId)
    -- Separate merge key per resource type prevents magicka and stamina
    -- restores from being summed together into a single number.
    local key = string.format("resource:%s", tostring(powerType or 0))
    QueueMergedValue(key, {
        kind = "resource",
        value = amount,
        powerType = powerType,
        playerId = playerId,
    })
end

-- ---------------------------------------------------------------
-- CanMark: returns true only when it is safe and appropriate to
-- assign a reticle marker to the current reticle-over target.
-- Guards: target must exist, must be the player's target, must be
-- attackable, and must be a player or PvP-flagged unit.
-- ---------------------------------------------------------------
local function CanMark(targetUnitId)
    if not DoesUnitExist("reticleover") then return false end
    -- Marker must be for the unit that is currently under the reticle.
    if MCT:GetPlayerUnitId() ~= targetUnitId then return false end
    if not IsUnitAttackable("reticleover") then return false end
    -- Only mark PvP-relevant targets to avoid cluttering PvE fights.
    if not IsUnitPvPFlagged("reticleover") and not IsUnitPlayer("reticleover") then return false end
    return true
end

-- ---------------------------------------------------------------
-- MCT:ClearMarkerIfMatch: removes the active reticle target marker
-- when the given targetUnitId matches the currently marked unit.
-- Called by a delayed timer in ApplyMarkerRule to auto-clear the
-- marker after markerAutoClearMs milliseconds.
-- ---------------------------------------------------------------
function MCT:ClearMarkerIfMatch(targetUnitId)
    -- Only clear if the marker is still on this specific target.
    if MCT.activeMarker.unitId ~= targetUnitId then return end
    AssignTargetMarkerToReticleTarget(TARGET_MARKER_TYPE_NONE)
    MCT.activeMarker.unitId = nil
    MCT.activeMarker.rule = nil
end

-- ---------------------------------------------------------------
-- MCT:RefreshRuleCache: rebuilds the rulePriority and ruleMarker
-- lookup tables from MCT.sv.priorityRules. Called lazily the first
-- time ApplyMarkerRule needs them and whenever settings change.
-- ---------------------------------------------------------------
function MCT:RefreshRuleCache()
    MCT.rulePriority = {}
    MCT.ruleMarker = {}
    for i, r in ipairs(MCT.sv.priorityRules) do
        MCT.rulePriority[r.name] = i           -- priority index; lower = more important
        MCT.ruleMarker[r.name] = r.marker      -- TARGET_MARKER_TYPE_* enum value
    end
end

-- ---------------------------------------------------------------
-- MCT:ApplyMarkerRule: assigns the correct reticle marker for the
-- given ruleName (e.g. "burst", "shieldbreak", "pressure") to the
-- current reticle-over target. Higher-priority (lower index) rules
-- can override an existing marker; same or lower priority rules
-- are silently ignored so the strongest marker survives.
-- Parameters:
--   targetUnitId : unit id of the target to potentially mark
--   ruleName     : string name matching a priority rule in MCT.sv
-- ---------------------------------------------------------------
function MCT:ApplyMarkerRule(targetUnitId, ruleName)
    if not MCT.sv.markerEnabled then return end
    if not CanMark(targetUnitId) then return end

    -- Populate lookup caches on first use or after settings reset.
    if not next(MCT.ruleMarker) then
        MCT:RefreshRuleCache()
    end

    local newMarker = MCT.ruleMarker[ruleName]
    if not newMarker then return end  -- Rule name not configured; skip.

    -- If a marker is already active on this target, only replace it
    -- when the new rule has a strictly higher priority (lower index).
    if MCT.activeMarker.unitId == targetUnitId then
        local currentPriority = MCT.rulePriority[MCT.activeMarker.rule] or 999
        local newPriority = MCT.rulePriority[ruleName] or 999
        if currentPriority <= newPriority then
            return  -- Current marker is equal or stronger; keep it.
        end
    end

    -- Assign the new marker icon to the reticle-over target.
    AssignTargetMarkerToReticleTarget(newMarker)
    MCT.activeMarker.unitId = targetUnitId
    MCT.activeMarker.rule = ruleName
    MCT.activeMarker.time = GetGameTimeMs()

    -- Schedule an auto-clear after the configured delay.
    zo_callLater(function()
        MCT:ClearMarkerIfMatch(targetUnitId)
    end, MCT.sv.markerAutoClearMs)
end

-- ---------------------------------------------------------------
-- MCT:TrackBurst: accumulates damage hits for a target within the
-- burst detection window. When the window thresholds (hit count,
-- total damage, crit count) are all met, MCT:OnBurst is triggered.
-- A new window is started whenever the previous window has expired.
-- Parameters:
--   targetUnitId : unit that received the damage
--   damage       : damage amount for this hit
--   isCrit       : whether this hit was a critical strike
-- ---------------------------------------------------------------
function MCT:TrackBurst(targetUnitId, damage, isCrit)
    if not MCT.sv.burstEnabled then return end
    if not targetUnitId or targetUnitId == 0 then return end

    local now = GetGameTimeMs()
    local t = MCT.burstTargets[targetUnitId]

    -- Reset the window if there is none or the previous one has expired.
    if not t or now - t.startTime > (tonumber(MCT.sv.burstWindowMs) or 1200) then
        t = { damage = 0, hits = 0, crits = 0, startTime = now }
        MCT.burstTargets[targetUnitId] = t
    end

    -- Accumulate this hit into the current window.
    t.damage = t.damage + damage
    t.hits = t.hits + 1
    if isCrit then t.crits = t.crits + 1 end

    -- Fire the burst event if all three thresholds are satisfied.
    if t.hits >= (tonumber(MCT.sv.burstMinHits) or 3)
       and t.damage >= (tonumber(MCT.sv.burstMinDamage) or 12000)
       and t.crits >= (tonumber(MCT.sv.burstMinCrits) or 1) then
        MCT:OnBurst(targetUnitId, t)
        -- Clear the window so the burst can trigger again after the next window fills.
        MCT.burstTargets[targetUnitId] = nil
    end
end

-- ---------------------------------------------------------------
-- MCT:TrackShieldbreak: detects when a hit that was previously
-- absorbed by a shield is followed by direct unshielded damage
-- within the shieldbreak detection window. This pattern indicates
-- the player has broken through the target's damage shield.
-- Parameters:
--   targetUnitId : unit that received the damage
--   damage       : damage amount (used for the minimum threshold guard)
--   isShielded   : true when ACTION_RESULT_DAMAGE_SHIELDED was the result
-- ---------------------------------------------------------------
function MCT:TrackShieldbreak(targetUnitId, damage, isShielded)
    if not MCT.sv.shieldbreakEnabled then return end
    if not targetUnitId or targetUnitId == 0 then return end
    -- Ignore hits too small to be considered a meaningful shieldbreak.
    if damage < (tonumber(MCT.sv.shieldbreakMinDamage) or 3000) then return end

    local now = GetGameTimeMs()
    local s = MCT.shields[targetUnitId] or { lastShield = false, t = 0 }
    MCT.shields[targetUnitId] = s

    if isShielded then
        -- Record that the last significant hit was absorbed by a shield.
        s.lastShield = true
        s.t = now
        return
    end

    -- Unshielded hit: check whether it follows a shielded hit within the window.
    if s.lastShield and now - s.t <= (tonumber(MCT.sv.shieldbreakWindowMs) or 900) then
        s.lastShield = false  -- Reset so we don't repeat the shieldbreak alert.
        MCT:OnShieldbreak(targetUnitId)
    end
end

-- ---------------------------------------------------------------
-- MCT:OnBurst: called when burst detection thresholds are all met.
-- Displays the burst label, optionally flashes the reticle overlay,
-- applies the burst priority marker, and optionally shows the current
-- rolling DPS if it exceeds MCT.sv.dpsMinShow.
-- Parameters:
--   targetUnitId : the unit that triggered the burst
--   burst        : the burst window state table from MCT.burstTargets
-- ---------------------------------------------------------------
function MCT:OnBurst(targetUnitId, burst)
    -- Show the burst damage total as a special ">> N <<" label.
    MCT:ShowText(burst.damage, true, false, "burst", MCT:GetPlayerUnitId(), targetUnitId, false)

    -- Flash the on-screen reticle highlight overlay if configured.
    if MCT.sv.reticleHighlightEnabled then
        -- Stop any in-progress flash before starting a new one.
        if MCT.reticleFlashTL then MCT.reticleFlashTL:Stop() end
        MCT.reticleFlash:SetAlpha(1)
        local rtl = ANIMATION_MANAGER:CreateTimeline()
        -- Hold fully visible for most of the duration, then fade out in the last 300ms.
        local holdMs = math.max(0, MCT.sv.reticleHighlightMs - 300)
        local rfade = rtl:InsertAnimation(ANIMATION_ALPHA, MCT.reticleFlash, holdMs)
        rfade:SetAlphaValues(1, 0)
        rfade:SetDuration(300)
        rtl:SetHandler("OnStop", function() MCT.reticleFlashTL = nil end)
        MCT.reticleFlashTL = rtl
        rtl:PlayFromStart()
    end

    -- Apply the burst marker to the reticle target.
    MCT:ApplyMarkerRule(targetUnitId, "burst")

    -- Optionally display the rolling DPS at the burst moment.
    if MCT.sv.dpsShowOnBurst then
        local dps = MCT:GetDps(targetUnitId)
        local dps = tonumber(dps)
        if dps >= tonumber(MCT.sv.dpsMinShow) then
            MCT:ShowText(dps .. " DPS", true, false, "burst", MCT:GetPlayerUnitId(), targetUnitId, false)
        end
    end
end

-- ---------------------------------------------------------------
-- MCT:OnShieldbreak: called when the shield-break pattern is detected.
-- Displays a "SHATTER" label and applies the shieldbreak priority marker.
-- ---------------------------------------------------------------
function MCT:OnShieldbreak(targetUnitId)
    MCT:ShowText("SHATTER", true, false, "shieldbreak", MCT:GetPlayerUnitId(), targetUnitId, false)
    MCT:ApplyMarkerRule(targetUnitId, "shieldbreak")
end

-- ---------------------------------------------------------------
-- PruneDpsBucket: removes event entries older than windowMs from
-- a DPS bucket and adjusts the running sum accordingly. Also
-- compacts the internal events array when the dead-entry head
-- index grows past 64 to prevent unbounded memory growth.
-- Parameters:
--   bucket   : the DPS bucket table for a target
--   now      : current time in milliseconds
--   windowMs : rolling window length in milliseconds
-- ---------------------------------------------------------------
local function PruneDpsBucket(bucket, now, windowMs)
    local ev = bucket.events
    local head = bucket.head
    -- Walk forward from the head until we find an event still inside the window.
    while head <= #ev and now - ev[head].t > windowMs do
        bucket.sum = bucket.sum - ev[head].dmg  -- remove this event from the sum
        ev[head] = nil                           -- allow GC of the entry
        head = head + 1
    end
    bucket.head = head

    -- Compact the array once the dead region at the front is large.
    if head > 64 then
        local live = {}
        for i = head, #ev do
            live[#live + 1] = ev[i]
        end
        bucket.events = live
        bucket.head = 1
    end
end

-- ---------------------------------------------------------------
-- MCT:AddDps: records a damage hit into the rolling DPS bucket for
-- the given target and trims events outside the configured window.
-- Parameters:
--   targetUnitId : the unit that received the damage
--   damage       : the damage amount to add to the DPS sum
-- ---------------------------------------------------------------
function MCT:AddDps(targetUnitId, damage)
    if not MCT.sv.dpsEnabled then return end
    local now = GetGameTimeMs()
    local windowMs = MCT.sv.dpsWindowSec * 1000  -- convert seconds to ms

    -- Create a fresh bucket for this target if none exists yet.
    local b = MCT.dps[targetUnitId]
    if not b then
        b = { events = {}, sum = 0, head = 1 }
        MCT.dps[targetUnitId] = b
    end

    -- Append the new event and keep the running sum current.
    tinsert(b.events, { t = now, dmg = damage })
    b.sum = b.sum + damage
    PruneDpsBucket(b, now, windowMs)
end

-- ---------------------------------------------------------------
-- MCT:GetDps: returns the current rolling DPS for a target as an
-- integer. Prunes stale events before calculating to ensure accuracy.
-- Returns 0 if no bucket exists (target not being damaged).
-- ---------------------------------------------------------------
function MCT:GetDps(targetUnitId)
    local b = MCT.dps[targetUnitId]
    if not b then return 0 end
    local now = GetGameTimeMs()
    local windowMs = MCT.sv.dpsWindowSec * 1000

    -- Prune first so the sum reflects only the active window.
    PruneDpsBucket(b, now, windowMs)
    -- Divide total damage in the window by window length in seconds.
    local dps  = math.floor(b.sum / MCT.sv.dpsWindowSec)
    return dps
end

-- ---------------------------------------------------------------
-- MCT:PruneTrackingTables: garbage-collects expired entries from
-- burstTargets, shields, and dps tables. Runs at most once every
-- 5 seconds to avoid per-frame overhead. Called from OnLibCombatEvent.
-- Parameters:
--   now : current GetGameTimeMilliseconds() value
-- ---------------------------------------------------------------
function MCT:PruneTrackingTables(now)
    -- Throttle: only prune once every 5 seconds.
    if now - MCT.lastPruneMs < 5000 then return end
    MCT.lastPruneMs = now

    -- Evict burst windows that are more than 2x the burst window old.
    local burstExpiry = MCT.sv.burstWindowMs * 2
    for unitId, t in pairs(MCT.burstTargets) do
        if now - t.startTime > burstExpiry then
            MCT.burstTargets[unitId] = nil
        end
    end

    -- Evict shield-state entries that are more than 2x the shieldbreak window old.
    local shieldExpiry = MCT.sv.shieldbreakWindowMs * 2
    for unitId, s in pairs(MCT.shields) do
        if now - s.t > shieldExpiry then
            MCT.shields[unitId] = nil
        end
    end

    -- Prune and evict empty DPS buckets.
    if MCT.sv.dpsEnabled then
        local windowMs = MCT.sv.dpsWindowSec * 1000
        for unitId, bucket in pairs(MCT.dps) do
            PruneDpsBucket(bucket, now, windowMs)
            -- Remove the bucket entirely when all events have expired.
            if bucket.sum <= 0 or bucket.head > #bucket.events then
                MCT.dps[unitId] = nil
            end
        end
    end
end
