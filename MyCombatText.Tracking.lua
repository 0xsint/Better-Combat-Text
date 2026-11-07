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
local tremove = table.remove
local tonumber = tonumber
local floor = math.floor

-- ---------------------------------------------------------------
-- GetIconCap: maximum number of ability icons per merged label,
-- honoring maxEventIcons and the performance-mode cap (1..6).
-- ---------------------------------------------------------------
local function GetIconCap()
    local maxIcons = 6
    local sv = MCT.sv
    if sv then
        local configured = tonumber(sv.maxEventIcons)
        if configured and configured > 0 then
            maxIcons = configured
        end
        if sv.performanceMode then
            local perfCap = tonumber(sv.performanceMaxIcons)
            if perfCap and perfCap > 0 and perfCap < maxIcons then
                maxIcons = perfCap
            end
        end
    end
    if maxIcons < 1 then maxIcons = 1 end
    if maxIcons > 6 then maxIcons = 6 end
    return maxIcons
end
MCT.GetIconCap = GetIconCap

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
local function AddAbilityId(list, abilityId, maxIcons)
    -- Ignore invalid or unset ability IDs.
    if not abilityId or abilityId <= 0 then return end

    local n = #list
    -- Fast path: same ability as the most recent one (multi-hit / DoT ticks).
    if n > 0 and list[n] == abilityId then return end

    -- Remove any previous occurrence of this ID to avoid duplicates.
    for i = 1, n - 1 do
        if list[i] == abilityId then
            tremove(list, i)
            n = n - 1
            break
        end
    end

    -- Append the ID at the tail (most recent position).
    n = n + 1
    list[n] = abilityId

    -- Evict the oldest ID when over the display cap.
    while n > (maxIcons or GetIconCap()) do
        tremove(list, 1)
        n = n - 1
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
    local sv = MCT.sv
    if sv and sv.debugMerge then
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
-- reschedules itself for the remaining time and returns without
-- displaying, allowing more events to accumulate.
-- Parameters:
--   key : the merge bucket string key to flush
-- ---------------------------------------------------------------
local flushCallbacks = {}  -- key -> reusable zo_callLater callback (no per-event closures)
local ScheduleFlush

local function FlushMergeKey(key)
    local data = MCT.merge[key]
    -- Bucket was already flushed by another path; clean up the timer flag.
    if not data then
        MCT.mergeTimers[key] = nil
        return
    end

    local windowMs = MCT.sv.mergeWindowMs
    local elapsed = GetGameTimeMs() - data.time
    -- Still inside the merge window: wait only for the remaining time
    -- (previously a full extra window, which delayed labels up to 2x).
    if elapsed < windowMs then
        ScheduleFlush(key, windowMs - elapsed)
        return
    end

    DebugMerge("FLUSH key=%s kind=%s value=%s", tostring(key), tostring(data.kind), tostring(data.value))

    -- Clear the bucket first so anything queued during display starts fresh.
    MCT.merge[key] = nil
    MCT.mergeTimers[key] = nil

    -- Dispatch to the correct display function based on the bucket kind.
    local kind = data.kind
    if kind == "hit" then
        MCT:ShowText(data.value, data.crit, data.heal, "", data.sID, data.unitId, data.blocked, data.abilityId, data.abilityIds)
    elseif kind == "overhealing" then
        ShowQueuedOverhealing(data.value, data.abilityId, data.abilityIds)
    elseif kind == "resource" then
        MCT:ShowResourceRestore(data.value, data.powerType, data.playerId)
    end
end

ScheduleFlush = function(key, delayMs)
    local cb = flushCallbacks[key]
    if not cb then
        cb = function() FlushMergeKey(key) end
        flushCallbacks[key] = cb
    end
    MCT.mergeTimers[key] = true
    zo_callLater(cb, delayMs)
end

-- ---------------------------------------------------------------
-- GetMergeBucket: returns the live bucket for `key` if it is still
-- inside the merge window, otherwise nil.
-- ---------------------------------------------------------------
local function GetLiveBucket(key, now)
    local bucket = MCT.merge[key]
    if bucket and now - bucket.time < MCT.sv.mergeWindowMs then
        return bucket
    end
    return nil
end

-- ---------------------------------------------------------------
-- StartBucket: installs a fresh bucket and schedules its flush timer
-- (only if one isn't already pending for this key).
-- ---------------------------------------------------------------
local function StartBucket(key, data, now)
    data.time = now
    MCT.merge[key] = data
    DebugMerge("NEW key=%s kind=%s value=%s", tostring(key), tostring(data.kind), tostring(data.value))
    if not MCT.mergeTimers[key] then
        ScheduleFlush(key, MCT.sv.mergeWindowMs)
    end
end

-- ---------------------------------------------------------------
-- MCT:QueueHit: public entry point for damage and healing hits.
-- Rapid hits sharing a merge key are summed into one bucket in place;
-- a new table is only allocated when a fresh bucket starts.
-- Parameters:
--   value      : raw hit value (damage or healing amount)
--   isCrit     : boolean – was this a critical strike/heal?
--   isHeal     : boolean – healing event (true) or damage (false)
--   sID        : sourceUnitId
--   unitId     : targetUnitId
--   isBlocked  : boolean – was the hit blocked?
--   abilityId  : ESO ability ID integer for icon display
--   mergeGroup : optional override merge key; derived automatically if nil
-- ---------------------------------------------------------------
function MCT:QueueHit(value, isCrit, isHeal, sID, unitId, isBlocked, abilityId, mergeGroup)
    local key = mergeGroup or GetHitMergeKey(isHeal, sID, unitId, isBlocked)
    local now = GetGameTimeMs()
    local validAbility = abilityId and abilityId > 0

    local bucket = GetLiveBucket(key, now)
    if bucket then
        bucket.value = bucket.value + value
        bucket.time = now                          -- extend the window from this event
        if isCrit then bucket.crit = true end      -- one crit makes the batch a crit
        if isBlocked then bucket.blocked = true end
        if validAbility then
            bucket.abilityId = abilityId
            local ids = bucket.abilityIds
            if not ids then
                ids = {}
                bucket.abilityIds = ids
            end
            AddAbilityId(ids, abilityId)
        end
        DebugMerge("MERGE key=%s kind=%s value=%s", tostring(key), "hit", tostring(bucket.value))
        return
    end

    StartBucket(key, {
        kind = "hit",
        value = value,
        crit = isCrit and true or false,
        heal = isHeal,
        sID = sID,
        unitId = unitId,
        blocked = isBlocked and true or false,
        abilityId = abilityId,
        abilityIds = validAbility and { abilityId } or nil,
    }, now)
end

-- ---------------------------------------------------------------
-- MCT:QueueOverhealing: queues an overhealing event for display.
-- All overheals from the same merge window are summed into one label.
-- ---------------------------------------------------------------
function MCT:QueueOverhealing(amount, isCrit, sID, unitId, abilityId)
    local key = "overheal"
    local now = GetGameTimeMs()
    local validAbility = abilityId and abilityId > 0

    local bucket = GetLiveBucket(key, now)
    if bucket then
        bucket.value = bucket.value + amount
        bucket.time = now
        if isCrit then bucket.crit = true end
        if validAbility then
            bucket.abilityId = abilityId
            local ids = bucket.abilityIds
            if not ids then
                ids = {}
                bucket.abilityIds = ids
            end
            AddAbilityId(ids, abilityId)
        end
        return
    end

    StartBucket(key, {
        kind = "overhealing",
        value = amount,
        crit = isCrit and true or false,
        sID = sID,
        unitId = unitId,
        abilityId = abilityId,
        abilityIds = validAbility and { abilityId } or nil,
    }, now)
end

-- ---------------------------------------------------------------
-- MCT:QueueResourceRestore: queues a resource gain for display.
-- Each power type gets its own merge bucket (cached key string).
-- ---------------------------------------------------------------
local resourceKeys = {}

function MCT:QueueResourceRestore(amount, powerType, playerId)
    local pt = powerType or 0
    local key = resourceKeys[pt]
    if not key then
        key = "resource:" .. tostring(pt)
        resourceKeys[pt] = key
    end

    local now = GetGameTimeMs()
    local bucket = GetLiveBucket(key, now)
    if bucket then
        bucket.value = bucket.value + amount
        bucket.time = now
        return
    end

    StartBucket(key, {
        kind = "resource",
        value = amount,
        powerType = powerType,
        playerId = playerId,
    }, now)
end

-- ---------------------------------------------------------------
-- CanMark: returns true only when it is safe and appropriate to
-- assign a reticle marker to the current reticle-over target.
-- Guards: target must exist, must be the player's target, must be
-- attackable, and must be a player or PvP-flagged unit.
-- ---------------------------------------------------------------
local function CanMark(targetUnitId)
    -- Pure-Lua comparison first so the common case never touches the unit API.
    -- Marker must be for the unit that is currently under the reticle.
    if MCT._playerUnitId ~= targetUnitId then return false end
    if not DoesUnitExist("reticleover") then return false end
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
function MCT:TrackBurst(targetUnitId, damage, isCrit, now)
    local sv = MCT.sv
    if not sv.burstEnabled then return end
    if not targetUnitId or targetUnitId == 0 then return end

    now = now or GetGameTimeMs()
    local t = MCT.burstTargets[targetUnitId]

    -- Reset the window if there is none or the previous one has expired.
    -- Expired windows are reused in place instead of reallocated.
    if not t then
        t = { damage = 0, hits = 0, crits = 0, startTime = now }
        MCT.burstTargets[targetUnitId] = t
    elseif now - t.startTime > (tonumber(sv.burstWindowMs) or 1200) then
        t.damage, t.hits, t.crits, t.startTime = 0, 0, 0, now
    end

    -- Accumulate this hit into the current window.
    t.damage = t.damage + damage
    t.hits = t.hits + 1
    if isCrit then t.crits = t.crits + 1 end

    -- Fire the burst event if all three thresholds are satisfied.
    if t.hits >= (tonumber(sv.burstMinHits) or 3)
       and t.damage >= (tonumber(sv.burstMinDamage) or 12000)
       and t.crits >= (tonumber(sv.burstMinCrits) or 1) then
        -- Clear the window so the burst can trigger again after the next window fills.
        MCT.burstTargets[targetUnitId] = nil
        MCT:OnBurst(targetUnitId, t)
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
function MCT:TrackShieldbreak(targetUnitId, damage, isShielded, now)
    local sv = MCT.sv
    if not sv.shieldbreakEnabled then return end
    if not targetUnitId or targetUnitId == 0 then return end
    -- Ignore hits too small to be considered a meaningful shieldbreak.
    if damage < (tonumber(sv.shieldbreakMinDamage) or 3000) then return end

    now = now or GetGameTimeMs()
    local s = MCT.shields[targetUnitId]
    if not s then
        -- Nothing to detect until a shielded hit has been seen.
        if not isShielded then return end
        s = { lastShield = false, t = 0 }
        MCT.shields[targetUnitId] = s
    end

    if isShielded then
        -- Record that the last significant hit was absorbed by a shield.
        s.lastShield = true
        s.t = now
        return
    end

    -- Unshielded hit: check whether it follows a shielded hit within the window.
    if s.lastShield and now - s.t <= (tonumber(sv.shieldbreakWindowMs) or 900) then
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
    if MCT.sv.reticleHighlightEnabled and MCT.reticleFlash then
        -- Hold fully visible for most of the duration, then fade out in the last 300ms.
        -- ESO never frees animation timelines, so one is built and reused; it is
        -- only rebuilt when the configured hold duration changes.
        local holdMs = math.max(0, (tonumber(MCT.sv.reticleHighlightMs) or 600) - 300)
        local rtl = MCT.reticleFlashTL
        if rtl then rtl:Stop() end
        if not rtl or MCT._reticleFlashHoldMs ~= holdMs then
            rtl = ANIMATION_MANAGER:CreateTimeline()
            local rfade = rtl:InsertAnimation(ANIMATION_ALPHA, MCT.reticleFlash, holdMs)
            rfade:SetAlphaValues(1, 0)
            rfade:SetDuration(300)
            MCT.reticleFlashTL = rtl
            MCT._reticleFlashHoldMs = holdMs
        end
        if MCT.HexToRGB then
            local r, g, b = MCT.HexToRGB(MCT.sv.reticleHighlightColor)
            MCT.reticleFlash:SetColor(r, g, b, 1)
        end
        MCT.reticleFlash:SetAlpha(1)
        rtl:PlayFromStart()
    end

    -- Apply the burst marker to the reticle target.
    MCT:ApplyMarkerRule(targetUnitId, "burst")

    -- Optionally display the rolling DPS at the burst moment.
    if MCT.sv.dpsShowOnBurst then
        local dps = tonumber(MCT:GetDps(targetUnitId)) or 0
        if dps > 0 and dps >= (tonumber(MCT.sv.dpsMinShow) or 0) then
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
-- DPS buckets store hits in two parallel arrays (times / dmgs) with a
-- moving head index, so recording a hit allocates nothing. The dead
-- prefix is compacted in place once it grows past 64 entries.
--   bucket = { times = {}, dmgs = {}, head = 1, tail = 0, sum = 0 }
-- ---------------------------------------------------------------
local function PruneDpsBucket(bucket, now, windowMs)
    local times, dmgs = bucket.times, bucket.dmgs
    local head, tail = bucket.head, bucket.tail
    local sum = bucket.sum
    -- Walk forward from the head until we find an event still inside the window.
    while head <= tail and now - times[head] > windowMs do
        sum = sum - dmgs[head]
        times[head] = nil
        dmgs[head] = nil
        head = head + 1
    end

    if head > tail then
        -- Empty: rewind to the start of the arrays.
        bucket.head, bucket.tail, bucket.sum = 1, 0, 0
        return
    end

    -- Compact in place once the dead region at the front is large.
    if head > 64 then
        local n = 0
        for i = head, tail do
            n = n + 1
            times[n] = times[i]
            dmgs[n] = dmgs[i]
        end
        for i = n + 1, tail do
            times[i] = nil
            dmgs[i] = nil
        end
        head, tail = 1, n
    end

    bucket.head, bucket.tail, bucket.sum = head, tail, sum
end

local function GetDpsWindowMs(sv)
    return (tonumber(sv.dpsWindowSec) or 10) * 1000
end

-- ---------------------------------------------------------------
-- MCT:AddDps: records a damage hit into the rolling DPS bucket for
-- the given target and trims events outside the configured window.
-- ---------------------------------------------------------------
function MCT:AddDps(targetUnitId, damage, now)
    local sv = MCT.sv
    if not sv.dpsEnabled then return end
    if not targetUnitId then return end
    now = now or GetGameTimeMs()

    local b = MCT.dps[targetUnitId]
    if not b then
        b = { times = {}, dmgs = {}, head = 1, tail = 0, sum = 0 }
        MCT.dps[targetUnitId] = b
    end

    local tail = b.tail + 1
    b.times[tail] = now
    b.dmgs[tail] = damage
    b.tail = tail
    b.sum = b.sum + damage
    PruneDpsBucket(b, now, GetDpsWindowMs(sv))
end

-- ---------------------------------------------------------------
-- MCT:GetDps: returns the current rolling DPS for a target as an
-- integer (0 when the target has no recent damage).
-- ---------------------------------------------------------------
function MCT:GetDps(targetUnitId)
    local b = MCT.dps[targetUnitId]
    if not b then return 0 end
    local sv = MCT.sv
    PruneDpsBucket(b, GetGameTimeMs(), GetDpsWindowMs(sv))
    local windowSec = tonumber(sv.dpsWindowSec) or 10
    if windowSec <= 0 then return 0 end
    return floor(b.sum / windowSec)
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
    local burstExpiry = (tonumber(MCT.sv.burstWindowMs) or 1200) * 2
    for unitId, t in pairs(MCT.burstTargets) do
        if now - t.startTime > burstExpiry then
            MCT.burstTargets[unitId] = nil
        end
    end

    -- Evict shield-state entries that are more than 2x the shieldbreak window old.
    local shieldExpiry = (tonumber(MCT.sv.shieldbreakWindowMs) or 900) * 2
    for unitId, s in pairs(MCT.shields) do
        if now - s.t > shieldExpiry then
            MCT.shields[unitId] = nil
        end
    end

    -- Prune and evict empty DPS buckets.
    if MCT.sv.dpsEnabled then
        local windowMs = GetDpsWindowMs(MCT.sv)
        for unitId, bucket in pairs(MCT.dps) do
            PruneDpsBucket(bucket, now, windowMs)
            -- Remove the bucket entirely when all events have expired.
            if bucket.head > bucket.tail then
                MCT.dps[unitId] = nil
            end
        end
    else
        -- Feature turned off mid-session: drop any leftover buckets.
        if next(MCT.dps) then MCT.dps = {} end
    end
end
