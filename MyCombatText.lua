-- ============================================================
-- MyCombatText.lua
-- Main addon file. Initializes all systems and owns:
--
--   MCT.defaults        : SavedVariables default table
--   MCT.pool            : fixed-size label/texture pool
--   MCT:GetAnchor()     : screen position resolver
--   MCT:InitPool()      : pool factory
--   MCT:Animate()       : multi-phase lane animation engine
--   MCT:ShowText()      : render router — picks style for every
--                         damage/heal/CC event then calls Animate()
--   MCT:InitSettingsPanel() : LibAddonMenu-2.0 settings panel
--   MCT:Initialize()    : entry point called from EVENT_ADD_ON_LOADED
--
-- Sub-modules loaded before this file:
--   MyCombatText.ResultFilter.lua  : ACTION_RESULT_* hash sets
--   MyCombatText.Formatting.lua    : font cache, FormatShortNumber, icons
--   MyCombatText.Tracking.lua      : merge queue, burst, shieldbreak, DPS
--   MyCombatText.Combat.lua        : event registration and pipeline
--   MyCombatText.Presets.lua       : preset tables (LUI_ENHANCED, etc.)
-- ============================================================

MyCombatText = MyCombatText or {}
local MCT = MyCombatText
MCT.name = "MyCombatText"
local EM = EVENT_MANAGER
local WM = WINDOW_MANAGER
local AM = ANIMATION_MANAGER
local GetGameTimeMs = GetGameTimeMilliseconds
local tinsert = table.insert

MCT._abilityNameSuffixCache = MCT._abilityNameSuffixCache or {}
MCT._abilityIconCache = MCT._abilityIconCache or {}


-------------------------------------------------------
-- SavedVars Defaults
-- All keys here are merged into MCT.sv via ZO_SavedVars
-- on each login. Missing keys receive these values automatically.
-- Presets (Presets.lua) override individual keys; this table
-- acts as the final fallback so no key is ever nil at runtime.
-------------------------------------------------------
MCT.defaults = {
    enabled = true,       -- Master on/off switch; when false ALL events are ignored.
    -- ---- Colors (hex strings, no "#"; ESO |cRRGGBB format) ----
    burstColor = "ffaa00",
    reticleHighlightColor = "ff6600",
    shieldbreakColor = "aaddff",
    damageColor = "ff6633",
    healingColor = "44ff99",
    criticalColor = "ffcc00",
    criticalHealingColor = "88ffdd",
    damageTakenColor = "ff4444",
    damageTakenCritColor = "ff0000",
    dodgedColor = "ddddaa",
    ccColor = "ff66ff",
    stunColor = "ff1111",
    fearColor = "ee00ff",
    charmColor = "ff88ff",
    silenceColor = "aa88ff",
    disorientColor = "ffbb66",
    offbalanceColor = "44ffdd",
    dotColor = "dd7744",
    resourceRestoreColor = "00ff88",
    overhealingColor = "88ddff",
    -- ---- Font sizes (pixels) ----
    -- Each event category has its own size so, e.g., burst labels can be
    -- much larger than DoT ticks without changing all text at once.
    combatFontStyle = "DEFAULT",
    enableHeartTextures = false,
    heartCount = 3,
    fontSize = 32,
    damageFontSize = 42,
    healingFontSize = 42,
    burstFontSize = 54,
    shieldbreakFontSize = 40,
    damageTakenFontSize = 42,
    dodgeFontSize = 40,
    stunFontSize = 40,
    fearFontSize = 40,
    charmFontSize = 40,
    silenceFontSize = 40,
    disorientFontSize = 40,
    offbalanceFontSize = 40,
    dotFontSize = 36,
    resourceRestoreFontSize = 36,
    overhealingFontSize = 36,
    -- ---- Feature display toggles ----
    -- Each false value suppresses that category at the routing layer so
    -- no labels, animations, or DPS updates are created for it.
    showDamage = true,
    showHealing = true,
    showDamageTaken = true,
    showDodges = true,
    showStuns = true,
    showFears = true,
    showCharms = true,
    showSilences = true,
    showDisorients = true,
    showOffbalances = true,
    showImmobilizes = true,
    popAnimation = false,  -- Bouncy scale "pop" when a label appears (Sweetheart preset turns it on).
    showDots = true,
    showResourceRestore = true,
    showOverhealing = true,
    critOnly = false,
    showEventTextures = true,
    maxEventIcons = 3,

    -- ---- Behavior toggles ----
    pvpOnly = false,           -- When true, all events are skipped unless the player is PvP flagged.
    anchorToReticle = false,   -- When true, labels attach near the reticle target instead of fixed screen positions.
    consoleFriendlyMode = true,
    uiScale = 1.0,
    fontSizeMultiplier = 1.0,
    gamepadUiScaleMultiplier = 1.15,
    gamepadFontMultiplier = 1.10,
    globalOffsetX = 0,
    globalOffsetY = 0,
    reticlex = 0,
    reticley = -50,
    showAbilityNames = false,
    performanceMode = true,
    performanceMaxIcons = 2,
    performanceLaneStaggerPercent = 3,
    performanceDisableTexturesOnBurst = true,
    performanceTextureEventThreshold = 35,
    performanceTextureCooldownMs = 1200,
    damagex = 0,
    damagey = 200,
    healingx = 0,
    healingy = -200,
    burstx = 0,
    bursty = 0,
    shieldbreakx = 0,
    shieldbreaky = 100,
    damageTakenx = 0,
    damageTakeny = 100,
    dodgex = 0,
    dodgey = -100,
    ccx = 0,
    ccy = -80,
    dotx = -200,
    doty = 0,
    resourcex = 150,
    resourcey = 0,
    -- ---- Spam control ----
    -- Hits within a mergeWindowMs window are summed into one label so
    -- rapid multi-hit abilities don't produce a wall of numbers.
    mergeWindowMs = 500,   -- Rolling accumulation window in milliseconds.

    -- ---- Animation parameters ----
    luiAnimStyle = false,  -- When true, use the multi-phase descending lane animation instead of the classic upward rise.
    animDuration = 1200,
    animRise = 80,
    animJitter = 20,
    laneQueueStaggerPercent = 5,

    -- ---- Burst detection thresholds ----
    -- A burst alert fires when, within burstWindowMs, the player lands
    -- >= burstMinHits hits for >= burstMinDamage total with >= burstMinCrits crits.
    burstEnabled = true,
    burstWindowMs = 1200,
    burstMinHits = 3,
    burstMinDamage = 12000,
    burstMinCrits = 1,

    -- ---- Shieldbreak detection parameters ----
    -- Fires when a shielded hit is followed within shieldbreakWindowMs by
    -- an unshielded hit of >= shieldbreakMinDamage (shield is "broken").
    shieldbreakEnabled = true,
    shieldbreakWindowMs = 900,
    shieldbreakMinDamage = 3000,

    -- ---- Target marker system ----
    -- ESO allows setting a TARGET_MARKER_TYPE_* icon on the reticle target.
    -- Each rule maps a trigger (burst, shieldbreak, pressure) to a marker type.
    -- Higher-priority rules override lower ones via the rule cache.
    markerEnabled = true,
    markerAutoClearMs = 5000,  -- Auto-clear marker this many ms after last hit on the target.

    -- Priority marker rules — ordered from highest to lowest priority.
    -- Each entry: { name = "triggerName", marker = TARGET_MARKER_TYPE_* }
    priorityRules = {
        { name = "burst", marker = TARGET_MARKER_TYPE_EIGHT }, -- skull
        { name = "shieldbreak", marker = TARGET_MARKER_TYPE_THREE }, -- X
        { name = "pressure", marker = TARGET_MARKER_TYPE_ONE }, -- sword
    },

    -- ---- Reticle flash ----
    -- Briefly brightens a crosshair texture centered on the screen
    -- when a burst or shieldbreak fires, providing a visual pop.
    reticleHighlightEnabled = true,
    reticleHighlightMs = 900,  -- Flash duration in ms.

    -- ---- Rolling DPS window ----
    -- Accumulates per-target damage in a sliding time window.
    -- Displayed as a "DPS: X" label on burst when dpsShowOnBurst is true.
    dpsEnabled = true,
    dpsWindowSec = 6,
    dpsMinShow = 2000,
    dpsShowOnBurst = true,

    -- hard cap for floating text controls to avoid unbounded UI control growth.
    -- ESO UI controls are heavy; 40 gives enough headroom for rapid combat bursts
    -- without evicting active labels mid-animation.
    maxFloatingLabels = 40,
    debugMerge = false,  -- When true, prints merge queue activity to the chat window.

    -- ---- Combat state notification (CombatCloud parity) ----
    showCombatState = true,
    combatStateColor = "ffffff",
    combatStateFontSize = 36,

    -- ---- Active combat tip alerts: block, exploit, interrupt, dodge, cleanse, execute ----
    showAlertBlock = true,
    showAlertExploit = true,
    showAlertInterrupt = true,
    showAlertDodge = true,
    showAlertCleanse = true,
    showAlertExecute = false,
    alertColor = "ffff44",
    alertFontSize = 44,
    executeThreshold = 20,
    executeFrequency = 8,

    -- ---- Alliance / Experience / Champion points ----
    showAlliancePoints = true,
    showExperiencePoints = true,
    showChampionPoints = true,
    alliancePointsColor = "44cc44",
    experiencePointsColor = "88aaff",
    championPointsColor = "cccc88",
    pointsFontSize = 32,

    -- ---- Low resource warnings ----
    showLowHealth = true,
    showLowMagicka = true,
    showLowStamina = true,
    showUltimateReady = true,
    showPotionReady = true,
    healthThreshold = 35,
    magickaThreshold = 35,
    staminaThreshold = 35,
    lowHealthColor = "ff3333",
    lowMagickaColor = "3399cc",
    lowStaminaColor = "44cc44",
    ultimateReadyColor = "ccff44",
    potionReadyColor = "aa44cc",
    resourceWarningFontSize = 44,
    warningSoundEnabled = true,

    -- ---- Mitigation events (miss, immune, parried, reflected) ----
    showMiss = true,
    showImmune = true,
    showParried = true,
    showReflected = true,
    missColor = "ffffff",
    immuneColor = "dd3333",
    parriedColor = "88aadd",
    reflectedColor = "dd6633",
    mitigationFontSize = 32,

    -- ---- Energize / Drain display ----
    showEnergize = false,
    showDrain = false,
    energizeColor = "44ddff",
    drainColor = "ff8833",
    energizeFontSize = 28,
}


-------------------------------------------------------
-- UI / Label Pool
-------------------------------------------------------
-- ANCHOR_OFFSETS: maps the event-category code string to a function that
-- returns the (offsetX, offsetY) saved-variable pair for that category.
-- Used by MCT:GetAnchor so each event type has its own position on screen.
local ANCHOR_OFFSETS = {
    damage      = function(sv) return sv.damagex,       sv.damagey      end,
    healing     = function(sv) return sv.healingx,      sv.healingy     end,
    burst       = function(sv) return sv.burstx,        sv.bursty       end,
    shieldbreak = function(sv) return sv.shieldbreakx,  sv.shieldbreaky end,
    damageTaken = function(sv) return sv.damageTakenx,  sv.damageTakeny end,
    dodge       = function(sv) return sv.dodgex,        sv.dodgey       end,
    dot         = function(sv) return sv.dotx,          sv.doty         end,
    resource    = function(sv) return sv.resourcex,     sv.resourcey    end,
}
-- CC_ANCHOR: crowd-control event codes that all share the same screen position.
-- All stun/fear/charm/silence/disorient/offbalance labels draw at (ccx, ccy).
-- alert/combatState/resourceWarning also center at (ccx, ccy) for prominence.
local CC_ANCHOR = { stun=true, fear=true, charm=true, silence=true, disorient=true, offbalance=true,
                    alert=true, combatState=true, resourceWarning=true }

-- RIGHT_LANE_ANCHOR: event codes whose labels scroll in the right-side lane.
-- These are typically defensive events (healing, damage taken, etc.).
local RIGHT_LANE_ANCHOR = { healing=true, shieldbreak=true, damageTaken=true, dodge=true }

-- LEFT_LANE_ANCHOR: event codes whose labels scroll in the left-side lane.
-- These are typically offensive events (damage, burst, DoTs, resources).
local LEFT_LANE_ANCHOR = { damage=true, burst=true, dot=true, resource=true }

-- Horizontal X positions for the two fixed lane columns (screen pixels from center).
local LEFT_LANE_X = -820
local RIGHT_LANE_X = 820
local LANE_CENTER_Y = 0  -- All lane labels start at vertical center and rise from there.

function MCT:IsConsoleFriendlyActive()
    local sv = self.sv or self.defaults
    if not sv or not sv.consoleFriendlyMode then
        return false
    end
    if IsInGamepadPreferredMode then
        return IsInGamepadPreferredMode()
    end
    return false
end

function MCT:GetEffectiveUiScale()
    local sv = self.sv or self.defaults or {}
    local scale = tonumber(sv.uiScale) or 1

    if self:IsConsoleFriendlyActive() then
        scale = scale * (tonumber(sv.gamepadUiScaleMultiplier) or 1.15)
    end

    if scale < 0.5 then
        scale = 0.5
    elseif scale > 2.5 then
        scale = 2.5
    end
    return scale
end

function MCT:MarkDisplayEvent()
    local now = GetGameTimeMs()
    local windowStart = tonumber(self._displayRateWindowStart) or now
    local count = tonumber(self._displayRateCount) or 0

    if now - windowStart >= 1000 then
        windowStart = now
        count = 0
    end

    count = count + 1
    self._displayRateWindowStart = windowStart
    self._displayRateCount = count

    if self.sv
        and self.sv.performanceMode
        and self.sv.performanceDisableTexturesOnBurst
        and count >= (tonumber(self.sv.performanceTextureEventThreshold) or 35)
    then
        local cooldownMs = tonumber(self.sv.performanceTextureCooldownMs) or 1200
        self._eventTextureSuppressedUntil = now + cooldownMs
    end
end

function MCT:AreEventTexturesTemporarilySuppressed()
    if not self.sv then
        return false
    end
    if not self.sv.performanceMode then
        return false
    end
    if not self.sv.performanceDisableTexturesOnBurst then
        return false
    end

    local untilMs = tonumber(self._eventTextureSuppressedUntil) or 0
    return GetGameTimeMs() < untilMs
end

-- ---------------------------------------------------------------
-- MCT:GetAnchor: returns the ESO anchor tuple for a given event
-- category code. Respects the anchorToReticle saved var which
-- moves all labels near the reticle target when it exists.
--
-- CC codes share one position; right/left lane codes each have
-- their own fixed column; anything else defaults to the left lane.
--
-- Returns: pointOfLabel, relativeTo, relativePoint, offsetX, offsetY
-- ---------------------------------------------------------------
function MCT:GetAnchor(value)
    local sv = MCT.sv
    local globalOffsetX = tonumber(sv and sv.globalOffsetX) or 0
    local globalOffsetY = tonumber(sv and sv.globalOffsetY) or 0

    if MCT.sv.anchorToReticle and DoesUnitExist("reticleover") then
        local reticleOffsetX = tonumber(sv and sv.reticlex) or 0
        local reticleOffsetY = tonumber(sv and sv.reticley) or -50
        return CENTER, ReticleOver, CENTER, reticleOffsetX + globalOffsetX, reticleOffsetY + globalOffsetY
    end

    if CC_ANCHOR[value] then
        return CENTER, GuiRoot, CENTER, (tonumber(sv and sv.ccx) or 0) + globalOffsetX, (tonumber(sv and sv.ccy) or 0) + globalOffsetY
    end

    local anchorResolver = ANCHOR_OFFSETS[value]
    if anchorResolver then
        local x, y = anchorResolver(sv)
        return CENTER, GuiRoot, CENTER, (tonumber(x) or 0) + globalOffsetX, (tonumber(y) or 0) + globalOffsetY
    end

    if RIGHT_LANE_ANCHOR[value] then
        return CENTER, GuiRoot, CENTER, RIGHT_LANE_X + globalOffsetX, LANE_CENTER_Y + globalOffsetY
    end
    if LEFT_LANE_ANCHOR[value] then
        return CENTER, GuiRoot, CENTER, LEFT_LANE_X + globalOffsetX, LANE_CENTER_Y + globalOffsetY
    end
    return CENTER, GuiRoot, CENTER, LEFT_LANE_X + globalOffsetX, LANE_CENTER_Y + globalOffsetY
end

-- Legacy wrapper: kept for compatibility with any internal call sites that
-- call GetAnchor() as a plain function rather than MCT:GetAnchor().
local function GetAnchor(value)
    return MCT:GetAnchor(value)
end


-- ---------------------------------------------------------------
-- MCT:InitPool: creates the recycled label+texture pool used by
-- every floating combat text label. A fixed cap of maxFloatingLabels
-- controls how many CT_LABEL controls exist at any time — no new
-- controls are ever created after the cap is reached; instead the
-- oldest active label is recycled (it disappears and is reissued).
--
-- Pool API (set on MCT.pool):
--   AcquireObject()       -> label, key  : grab a ready-to-use label
--   ReleaseObject(key)    : return it to the free list and reset it
--   ReleaseAllObjects()   : release every active label (used on leaving combat)
--   SetMaxLabels(newMax)  : adjust the cap (currently clamped to 20)
-- ---------------------------------------------------------------
function MCT:InitPool()
    -- CreateLabel: allocates a single invisible CT_LABEL control under
    -- the addon root frame. All labels share the same base configuration;
    -- ShowText/Animate override font, text, and anchor per event.
    local function CreateLabel()
        local l = WM:CreateControl(nil, _G["MyCombatTextRoot"], CT_LABEL)
        l:SetFont("ZoFontCombat|"..tostring(MCT.sv.fontSize).."|soft-shadow-thick")
        l:SetDrawLayer(DL_OVERLAY)          -- Rendered above all game UI layers.
        l:SetDrawTier(DT_HIGH)              -- High tier within the overlay.
        l:SetDrawLevel(1)
        l:SetHidden(true)                   -- Hidden until acquired by the pool.
        l:SetDimensions(600, 120)           -- Wide enough for large crit numbers + icons.
        l:SetHorizontalAlignment(TEXT_ALIGN_CENTER)
        l:SetVerticalAlignment(TEXT_ALIGN_CENTER)

        return l
    end

    -- CreateTexture: allocates a single invisible CT_TEXTURE control for
    -- ability/event icons. One or more textures are associated with each label.
    local function CreateTexture()
        local t = WM:CreateControl(nil, _G["MyCombatTextRoot"], CT_TEXTURE)
        t:SetDrawLayer(DL_OVERLAY)
        t:SetDrawTier(DT_HIGH)
        t:SetDrawLevel(2)   -- Drawn on top of the label text.
        t:SetHidden(true)
        t:SetDimensions(30, 30)
        return t
    end

    -- EnsureTextureSlots: grows the texture set for a label up to `count`
    -- if needed. Called before AcquireObject returns to guarantee at least
    -- one texture slot exists for icon display.
    local function EnsureTextureSlots(textureSet, count)
        while #textureSet < count do
            textureSet[#textureSet + 1] = CreateTexture()
        end
    end

    -- ResetLabel: clears all stateful properties of label `l` and its
    -- associated texture set `t`. Called when a label is released back
    -- to the pool so the next user starts with a fully clean slate.
    local function ResetLabel(l, t)
        local tl = l.mctTimeline
        if tl then
            -- Clear first so the timeline's OnStop handler sees a stale stop
            -- and doesn't try to release this label a second time.
            l.mctTimeline = nil
            tl:Stop()               -- Stop any in-progress animation immediately.
        end
        l:SetHidden(true)
        l:ClearAnchors()
        l:SetAlpha(1)
        l:SetScale(1)
        l:SetText("")
        l.mctAbilityId  = nil   -- Single ability ID (fast path).
        l.mctAbilityIds = nil   -- List of ability IDs (multi-hit merge path).
        l.mctEventCode  = nil   -- Category code used for icon and animation lookup.
        -- Bump (never reset) the queue token so any lane-queue entry still
        -- pointing at this label is recognised as stale, even after reuse.
        l.mctQueueToken = (l.mctQueueToken or 0) + 1
        l.mctQueued     = nil

        if t then
            for i = 1, #t do
                local tex = t[i]
                if not tex:IsHidden() then
                    tex:SetHidden(true)
                    tex:ClearAnchors()
                end
                -- The texture path is kept: re-showing the same icon later
                -- then skips a SetTexture (file lookup) call entirely.
            end
        end
    end

    -- pool: the table stored as MCT.pool after Init completes.
    -- freeKeys   : stack of recycled keys ready for re-issue.
    -- activeOrder: ordered list tracking creation order for oldest-first eviction.
    -- activeSet  : fast membership check for active keys (key -> true).
    -- labels     : key -> CT_LABEL control.
    -- textures   : key -> { CT_TEXTURE, ... } list.
    -- nextKey    : next unused key; increments until maxLabels is reached.
    local pool = {
        freeKeys    = {},
        activeOrder = {},
        activeHead  = 1,
        activeCount = 0,
        activeSet   = {},
        labels      = {},
        textures    = {},
        nextKey     = 1,
        maxLabels   = tonumber(MCT.sv.maxFloatingLabels) or tonumber(MCT.defaults.maxFloatingLabels) or 20,
    }

    function pool:PopOldestActiveKey()
        while self.activeHead <= #self.activeOrder do
            local key = self.activeOrder[self.activeHead]
            self.activeOrder[self.activeHead] = nil
            self.activeHead = self.activeHead + 1
            if key and self.activeSet[key] then
                return key
            end
        end
        return nil
    end

    -- ReclaimIdleKey: finds an active label that is neither animating nor
    -- waiting in a lane queue, releases it, and returns its key for reuse.
    function pool:ReclaimIdleKey()
        for i = self.activeHead, #self.activeOrder do
            local key = self.activeOrder[i]
            if key and self.activeSet[key] then
                local label = self.labels[key]
                local tl = label and label.mctTimeline
                if label and not label.mctQueued and not (tl and tl:IsPlaying()) then
                    self:ReleaseObject(key)
                    return table.remove(self.freeKeys)
                end
            end
        end
        return nil
    end

    -- AcquireObject: returns a ready-to-use label and its pool key.
    -- Three allocation paths:
    --   1. Re-use a key from the freeKeys stack (cheapest, most common).
    --   2. Allocate a new key up to maxLabels (initial fill phase).
    --   3. Evict the oldest active label when the cap is reached.
    function pool:AcquireObject()
        local key = table.remove(self.freeKeys)

        if not key then
            if self.nextKey <= self.maxLabels then
                key = self.nextKey
                self.nextKey = self.nextKey + 1
                self.labels[key] = CreateLabel()
                self.labels[key].mctPoolKey = key
                self.textures[key] = { CreateTexture() }
            else
                -- Pool is full. Safety net: reclaim the oldest active label whose
                -- animation is no longer running (e.g. it was queued in a lane that
                -- got reset, or its timeline stopped without notifying us).
                key = self:ReclaimIdleKey()
                if not key then
                    -- Every label is genuinely mid-animation: drop this event rather
                    -- than killing an active label.
                    return nil, nil
                end
            end
        end

        EnsureTextureSlots(self.textures[key], 1)

        if not self.activeSet[key] then
            self.activeSet[key] = true
            self.activeCount = self.activeCount + 1
        end
        self.activeOrder[#self.activeOrder + 1] = key

        -- Compact stale queue entries to avoid growth during long sessions.
        if self.activeHead > 64 and self.activeHead * 2 > #self.activeOrder then
            local compacted = {}
            for i = self.activeHead, #self.activeOrder do
                local existingKey = self.activeOrder[i]
                if existingKey then
                    compacted[#compacted + 1] = existingKey
                end
            end
            self.activeOrder = compacted
            self.activeHead = 1
        end

        return self.labels[key], key
    end

    -- ReleaseObject: returns a label to the free pool.
    -- Stops the animation timeline, resets all properties, removes it from
    -- activeOrder, and pushes the key onto freeKeys for re-use.
    function pool:ReleaseObject(key)
        if not key or not self.activeSet[key] then return end

        self.activeSet[key] = nil
        self.activeCount = math.max(0, self.activeCount - 1)
        local label = self.labels[key]
        local texture = self.textures[key]
        if label then
            ResetLabel(label, texture)
        end

        self.freeKeys[#self.freeKeys + 1] = key
    end

    -- ReleaseAllObjects: release every currently active label at once.
    -- Called when leaving combat so the screen is fully cleared.
    function pool:ReleaseAllObjects()
        for i = self.activeHead, #self.activeOrder do
            local key = self.activeOrder[i]
            if key and self.activeSet[key] then
                self:ReleaseObject(key)
            end
        end
        self.activeOrder = {}
        self.activeHead = 1
    end

    -- SetMaxLabels: adjusts the pool cap at runtime (clamped to 10–80).
    -- Excess active labels are released; free keys beyond the new cap are
    -- discarded and their controls become eligible for GC.
    function pool:SetMaxLabels(newMax)
        local cap = tonumber(newMax) or self.maxLabels
        if cap < 10 then cap = 10 end
        if cap > 80 then cap = 80 end
        self.maxLabels = cap

        while self.activeCount > self.maxLabels do
            local oldestKey = self:PopOldestActiveKey()
            if not oldestKey then
                break
            end
            self:ReleaseObject(oldestKey)
        end

        for i = #self.freeKeys, 1, -1 do
            local key = self.freeKeys[i]
            if key > self.maxLabels then
                self.labels[key] = nil
                self.textures[key] = nil
                table.remove(self.freeKeys, i)
            end
        end

        if self.nextKey > (self.maxLabels + 1) then
            self.nextKey = self.maxLabels + 1
        end
    end

    MCT.pool = pool

end

-- ---------------------------------------------------------------
-- MCT:ResolveEventTexture: returns a single texture path for one
-- ability ID and/or event category code. Tries GetAbilityIcon first
-- (actual ability icons look better than generic category icons);
-- falls back to the EventTextures table if the ability has no icon.
-- Returns nil when showEventTextures is off or no texture is found.
-- ---------------------------------------------------------------
function MCT:ResolveEventTexture(abilityId, eventCode)
    if not MCT.sv.showEventTextures then
        return nil
    end

    if MCT:AreEventTexturesTemporarilySuppressed() then
        return nil
    end

    if abilityId and abilityId > 0 then
        local abilityTexture = MCT._abilityIconCache[abilityId]
        if abilityTexture == nil then
            abilityTexture = GetAbilityIcon(abilityId)
            if abilityTexture == "" then
                abilityTexture = false
            end
            MCT._abilityIconCache[abilityId] = abilityTexture
        end

        if abilityTexture and abilityTexture ~= "" then
            return abilityTexture
        end
    end

    return MCT:GetEventTexture(eventCode)
end

-- ---------------------------------------------------------------
-- MCT:ResolveEventTextures: returns a de-duplicated list of texture
-- paths for a list of ability IDs + category code. Used by merged
-- labels to show one icon per contributing ability, max 3.
-- If the ability list resolves to nothing, falls back to a single
-- category icon via MCT:GetEventTexture(eventCode).
-- ---------------------------------------------------------------
local resolvedTexturesScratch = {}

-- NOTE: the returned table is a reused scratch buffer; consume it before the
-- next call (SetEventTexture does) and don't keep a reference to it.
function MCT:ResolveEventTextures(abilityIds, eventCode, singleAbilityId)
    local textures = resolvedTexturesScratch
    for i = #textures, 1, -1 do textures[i] = nil end

    if not MCT.sv.showEventTextures or MCT:AreEventTexturesTemporarilySuppressed() then
        return textures
    end

    local maxIcons = MCT.GetIconCap and MCT.GetIconCap() or 3

    if not abilityIds and singleAbilityId then
        local texturePath = MCT:ResolveEventTexture(singleAbilityId, eventCode)
        if texturePath and texturePath ~= "" then
            textures[1] = texturePath
        end
    elseif abilityIds then
        for i = 1, #abilityIds do
            local texturePath = MCT:ResolveEventTexture(abilityIds[i], eventCode)
            if texturePath and texturePath ~= "" then
                local duplicate = false
                for j = 1, #textures do
                    if textures[j] == texturePath then
                        duplicate = true
                        break
                    end
                end
                if not duplicate then
                    textures[#textures + 1] = texturePath
                    if #textures >= maxIcons then
                        break
                    end
                end
            end
        end
    end

    if #textures == 0 then
        local fallbackTexture = MCT:GetEventTexture(eventCode)
        if fallbackTexture then
            textures[1] = fallbackTexture
        end
    end

    return textures
end

-- MCT:GetLatestAbilityId: returns the most recently contributed ability ID
-- from a merged list, or the single abilityId if no list is present.
-- Used to pick the icon / name suffix that most represents the merged hit.
function MCT:GetLatestAbilityId(abilityId, abilityIds)
    if abilityIds and #abilityIds > 0 then
        return abilityIds[#abilityIds]
    end
    return abilityId
end

-- MCT:GetAbilityNameSuffix: builds a dim gray " - AbilityName" suffix string
-- appended to damage/heal labels when an ability ID is available.
-- Returns "" when there is no ability or the ability has no name.
function MCT:GetAbilityNameSuffix(abilityId, abilityIds)
    if not (MCT.sv and MCT.sv.showAbilityNames) then
        return ""
    end

    local latestAbilityId = MCT:GetLatestAbilityId(abilityId, abilityIds)
    if not latestAbilityId or latestAbilityId <= 0 then
        return ""
    end

    local cached = MCT._abilityNameSuffixCache[latestAbilityId]
    if cached ~= nil then
        return cached
    end

    local abilityName = GetAbilityName(latestAbilityId)
    if not abilityName or abilityName == "" then
        MCT._abilityNameSuffixCache[latestAbilityId] = ""
        return ""
    end

    local suffix = string.format(" |cB8B8B8- %s|r", zo_strformat("<<C:1>>", abilityName))
    MCT._abilityNameSuffixCache[latestAbilityId] = suffix
    return suffix
end

-- GetLabelFontSize: parses the current font string of a label to extract
-- the numeric point size. ESO font strings use the format "path|size|flags".
-- Falls back to MCT.sv.fontSize if the label has no font or parsing fails.
local fontSizeByFontString = {}

local function GetLabelFontSize(label)
    local font = label and label.GetFont and label:GetFont()
    if not font then
        return tonumber(MCT.sv and MCT.sv.fontSize) or 28
    end

    -- ESO font strings are typically: "path|size|flags" or "ZoFontCombat|size|flags".
    -- Only a handful of distinct font strings exist, so parse each once.
    local size = fontSizeByFontString[font]
    if size == nil then
        size = tonumber(string.match(font, "|(%d+)|")) or false
        fontSizeByFontString[font] = size
    end
    if not size then
        size = tonumber(MCT.sv and MCT.sv.fontSize) or 28
    end
    return size
end

-- GetTextureLayoutMetrics: derives the icon size and gap in pixels that
-- closely pair with the label's current font size. Larger fonts get larger
-- icons (capped at 72px), smaller fonts get smaller ones (floor 20px).
-- Returns: iconSize, gap
local function GetTextureLayoutMetrics(label)
    local fontSize = GetLabelFontSize(label)
    -- Tighter LUI-style pairing: icon should closely match big combat font readability.
    local iconSize = math.floor(math.max(20, math.min(72, fontSize * 0.95)))
    local gap = math.max(2, math.floor(iconSize * 0.12))
    return iconSize, gap
end

-- ---------------------------------------------------------------
-- MCT:LayoutEventTexture: repositions the texture icons for poolKey
-- so they sit just to the left of the visible label text, stacked
-- right-to-left when multiple icons are present. Called every time
-- a label is shown or its text changes because text width drives the
-- icon offset calculation.
-- ---------------------------------------------------------------
function MCT:LayoutEventTexture(poolKey)
    if not MCT.pool or not MCT.pool.textures then return end

    local textureSet = MCT.pool.textures[poolKey]
    local label = MCT.pool.labels[poolKey]
    if not textureSet or not label then return end

    local textWidth = label:GetTextWidth() or 0
    local textScale = 1
    if label.GetScale then
        textScale = tonumber(label:GetScale()) or 1
        if textScale <= 0 then
            textScale = 1
        end
    end

    local scaledTextWidth = textWidth * textScale
    local iconSize, gap = GetTextureLayoutMetrics(label)
    local textureGap = math.max(2, math.floor(iconSize * 0.18))

    local offset = -gap
    if scaledTextWidth > 0 then
        -- Labels are center-aligned in a fixed box, so place the icon just left of the rendered text bounds.
        local overlapBuffer = 4
        offset = -math.floor((scaledTextWidth * 0.5) + gap + overlapBuffer)
    end

    local visibleCount = 0
    for i = 1, #textureSet do
        if not textureSet[i]:IsHidden() then
            visibleCount = visibleCount + 1
        end
    end

    if visibleCount == 0 then return end

    local slot = 0
    local step = iconSize + textureGap
    for i = 1, #textureSet do
        local texture = textureSet[i]
        if not texture:IsHidden() then
            texture:SetDimensions(iconSize, iconSize)
            texture:ClearAnchors()
            slot = slot + 1
            local textureOffset = offset - ((visibleCount - slot) * step)
            texture:SetAnchor(RIGHT, label, CENTER, textureOffset, 0)
        end
    end
end

-- ---------------------------------------------------------------
-- MCT:SetEventTexture: resolves texture paths for the given ability
-- IDs / event code and assigns them to the pool textures for poolKey.
-- Grows the texture slot array if more icons are needed than slots
-- currently exist. Hides and clears any excess slots so old icons
-- from a previously acquired label don't bleed through.
-- ---------------------------------------------------------------
function MCT:SetEventTexture(poolKey, abilityId, eventCode, abilityIds)
    if not MCT.pool or not MCT.pool.textures then return end

    local textureSet = MCT.pool.textures[poolKey]
    local label = MCT.pool.labels[poolKey]
    if not textureSet or not label then return end

    local texturePaths = MCT:ResolveEventTextures(abilityIds, eventCode, abilityId)
    if #texturePaths == 0 then
        for i = 1, #textureSet do
            local texture = textureSet[i]
            if not texture:IsHidden() then
                texture:SetHidden(true)
                texture:ClearAnchors()
            end
        end
        return
    end

    local pathCount = #texturePaths
    local maxIcons = MCT.GetIconCap and MCT.GetIconCap() or 6
    if pathCount > maxIcons then pathCount = maxIcons end
    while #textureSet < pathCount do
        textureSet[#textureSet + 1] = WM:CreateControl(nil, _G["MyCombatTextRoot"], CT_TEXTURE)
        textureSet[#textureSet]:SetDrawLayer(DL_OVERLAY)
        textureSet[#textureSet]:SetDrawTier(DT_HIGH)
        textureSet[#textureSet]:SetDrawLevel(2)
        textureSet[#textureSet]:SetHidden(true)
    end

    for i = 1, #textureSet do
        local texture = textureSet[i]
        local texturePath = (i <= pathCount) and texturePaths[i] or nil
        if texturePath then
            if texture.mctTexturePath ~= texturePath then
                texture:SetTexture(texturePath)
                texture.mctTexturePath = texturePath
            end
            texture:SetHidden(false)
        elseif not texture:IsHidden() then
            texture:SetHidden(true)
            texture:ClearAnchors()
        end
    end

    MCT:LayoutEventTexture(poolKey)
end

-- ---------------------------------------------------------------
-- MCT:InitReticleFlash: creates the overlay texture that briefly
-- brightens when a burst or shieldbreak fires. It is anchored at
-- the center of the screen slightly above the natural reticle.
-- Alpha is kept at 0 until a flash is triggered; MCT:OnBurst and
-- MCT:OnShieldbreak fade it in/out via a zo_callLater timer.
-- ---------------------------------------------------------------
function MCT:InitReticleFlash()
    MCT.reticleFlash = WM:CreateControl(nil, GuiRoot, CT_TEXTURE)
    MCT.reticleFlash:SetTexture("EsoUI/Art/Miscellaneous/hud_reticle.dds")
    MCT.reticleFlash:SetAnchor(CENTER, GuiRoot, CENTER, 0, -120)
    MCT.reticleFlash:SetDimensions(80, 80)
    MCT.reticleFlash:SetAlpha(0)
    MCT.reticleFlash:SetHidden(false)
end
-------------------------------------------------------
-- Animations
-------------------------------------------------------
local function FormatShortNumber(n)
    return MCT:FormatShortNumber(n)
end

-- ANIM_DATA: maps each animation code string to a function that returns
-- the base (x, y) position, jitter radius, and rise height for that code.
-- Crit variants add extra jitter and rise for more dramatic presentation.
-- All values are in screen pixels relative to GuiRoot center.
local ANIM_DATA = {
    damage          = function(sv) return sv.damagex,       sv.damagey,        sv.animJitter or 60,         sv.animRise or 120         end,
    damageCrit      = function(sv) return sv.damagex,       sv.damagey,        (sv.animJitter or 60) + 20,  (sv.animRise or 120) + 30  end,
    healing         = function(sv) return sv.healingx,      sv.healingy,       sv.animJitter or 60,         sv.animRise or 120         end,
    healingCrit     = function(sv) return sv.healingx,      sv.healingy,       (sv.animJitter or 60) + 20,  (sv.animRise or 120) + 30  end,
    burst           = function(sv) return sv.burstx,        sv.bursty,         (sv.animJitter or 60) + 30,  (sv.animRise or 120) + 50  end,
    shieldbreak     = function(sv) return sv.shieldbreakx,  sv.shieldbreaky,   (sv.animJitter or 60) + 10,  (sv.animRise or 120) + 15  end,
    damageTaken     = function(sv) return sv.damageTakenx,  sv.damageTakeny,   sv.animJitter or 60,         sv.animRise or 120         end,
    damageTakenCrit = function(sv) return sv.damageTakenx,  sv.damageTakeny,   (sv.animJitter or 60) + 20,  (sv.animRise or 120) + 30  end,
    dodge           = function(sv) return sv.dodgex,        sv.dodgey,         sv.animJitter or 60,         sv.animRise or 120         end,
    dot             = function(sv) return sv.dotx,          sv.doty,           (sv.animJitter or 60) - 25,  (sv.animRise or 120) - 35  end,
    dotCrit         = function(sv) return sv.dotx,          sv.doty,           (sv.animJitter or 60) - 5,   (sv.animRise or 120) - 15  end,
    resourceRestore = function(sv) return sv.resourcex,     sv.resourcey,      (sv.animJitter or 60) + 10,  (sv.animRise or 120) - 20  end,
    -- CombatCloud-parity: points (XP/AP/CP) and mitigation events use left lane
    points          = function(sv) return sv.damagex,       sv.damagey,        (sv.animJitter or 60) - 20,  (sv.animRise or 120) - 20  end,
    energize        = function(sv) return sv.resourcex,     sv.resourcey,      sv.animJitter or 60,         (sv.animRise or 120) - 20  end,
    drain           = function(sv) return sv.dotx,          sv.doty,           (sv.animJitter or 60) - 10,  (sv.animRise or 120) - 10  end,
    miss            = function(sv) return sv.damagex,       sv.damagey,        sv.animJitter or 60,         sv.animRise or 120         end,
    immune          = function(sv) return sv.damagex,       sv.damagey,        sv.animJitter or 60,         sv.animRise or 120         end,
    parried         = function(sv) return sv.damagex,       sv.damagey,        sv.animJitter or 60,         sv.animRise or 120         end,
    reflected       = function(sv) return sv.damagex,       sv.damagey,        sv.animJitter or 60,         sv.animRise or 120         end,
}
-- CC_ANIM_CODES: codes that use the CC anchor position and a simpler
-- linear rise animation rather than the multi-phase lane animation.
-- alert/combatState/resourceWarning share the center lane for high-visibility pop-ups.
local CC_ANIM_CODES = { stun=true, fear=true, charm=true, silence=true, disorient=true, offbalance=true, immobilized=true,
                        alert=true, combatState=true, resourceWarning=true }

-- RIGHT_LANE_ANIM_CODES: codes that animate in the right-side lane
-- (healing, damage taken, dodge/shieldbreak).
local RIGHT_LANE_ANIM_CODES = { healing=true, healingCrit=true, shieldbreak=true, damageTaken=true, damageTakenCrit=true, dodge=true }

-- LANE_ANIM_DURATION_MULTIPLIER: lane labels get extra time because they
-- travel a longer distance (full lane height vs a short CC rise).
local LANE_ANIM_DURATION_MULTIPLIER = 1.45

-- Lane queue state: each lane gets a FIFO queue and a next-open timestamp.
MCT._laneQueues = MCT._laneQueues or { left = {}, right = {}, center = {} }
MCT._laneQueueHeads = MCT._laneQueueHeads or { left = 1, right = 1, center = 1 }
MCT._laneQueueTails = MCT._laneQueueTails or { left = 0, right = 0, center = 0 }
MCT._laneQueueScheduled = MCT._laneQueueScheduled or { left = false, right = false, center = false }
MCT._laneNextOpenAt = MCT._laneNextOpenAt or { left = 0, right = 0, center = 0 }

local function LaneQueueHasItems(self, lane)
    local head = self._laneQueueHeads[lane] or 1
    local tail = self._laneQueueTails[lane] or 0
    return head <= tail
end

-- CRIT_ANIM_CODES: high-impact codes that get longer fade delay so the
-- number stays on screen at full alpha for longer before fading out.
local CRIT_ANIM_CODES = { damageCrit=true, healingCrit=true, damageTakenCrit=true, dotCrit=true, burst=true, shieldbreak=true }

local function GetAnimationTimingForCode(sv, code)
    local isBig = CRIT_ANIM_CODES[code]
    local baseDur = sv.animDuration or (isBig and 1100 or 900)
    local moveDur = baseDur
    local fadeDur = isBig and (baseDur + 200) or baseDur
    local fadeDelay = isBig and 200 or 0

    if not CC_ANIM_CODES[code] then
        moveDur = math.floor(moveDur * LANE_ANIM_DURATION_MULTIPLIER)
        fadeDur = math.floor(fadeDur * LANE_ANIM_DURATION_MULTIPLIER)
    end

    return moveDur, fadeDur, fadeDelay
end

local function GetLaneStaggerMs(sv, code, moveDur)
    moveDur = moveDur or GetAnimationTimingForCode(sv, code)
    local percent = tonumber(sv and sv.laneQueueStaggerPercent) or 5

    if sv and sv.performanceMode then
        local perfPercent = tonumber(sv.performanceLaneStaggerPercent)
        if perfPercent then
            percent = math.min(percent, perfPercent)
        end
    end

    if percent < 1 then percent = 1 end
    if percent > 20 then percent = 20 end

    local stagger = math.floor(moveDur * (percent / 100))
    if stagger < 35 then
        stagger = 35
    end
    return stagger
end

function MCT:GetAnimationLane(code)
    if CC_ANIM_CODES[code] then
        return "center"
    end
    if RIGHT_LANE_ANIM_CODES[code] then
        return "right"
    end
    return "left"
end

-- One reusable pump callback per lane (no closure allocated per schedule).
local lanePumpCallbacks = {}

function MCT:ScheduleLaneQueuePump(lane, delayMs)
    local delay = math.max(0, tonumber(delayMs) or 0)
    if self._laneQueueScheduled[lane] then
        return
    end

    local cb = lanePumpCallbacks[lane]
    if not cb then
        cb = function()
            MCT._laneQueueScheduled[lane] = false
            MCT:ProcessLaneQueue(lane)
        end
        lanePumpCallbacks[lane] = cb
    end

    self._laneQueueScheduled[lane] = true
    zo_callLater(cb, delay)
end

-- MCT:ResetLaneQueues: drops every queued (not yet started) label.
-- Called when leaving combat; the labels themselves are released by
-- pool:ReleaseAllObjects().
function MCT:ResetLaneQueues()
    MCT._laneQueues = { left = {}, right = {}, center = {} }
    MCT._laneQueueHeads = { left = 1, right = 1, center = 1 }
    MCT._laneQueueTails = { left = 0, right = 0, center = 0 }
    -- Pending pump timers will find empty queues and exit; keep the
    -- scheduled flags so we don't stack duplicate timers.
    MCT._laneQueueScheduled = MCT._laneQueueScheduled or { left = false, right = false, center = false }
    MCT._laneNextOpenAt = { left = 0, right = 0, center = 0 }
end

-- ---------------------------------------------------------------
-- Reusable animation timelines.
-- ANIMATION_MANAGER:CreateTimeline() objects are never garbage
-- collected by the ESO client, so the old approach (one new timeline
-- per label shown) leaked memory steadily over long play sessions and
-- cost a C-side allocation per label. Each pooled label now owns a
-- small set of timelines, one per distinct "shape" (rise vs. lane and
-- the phase offsets that are baked into a timeline at creation). Per
-- play we only update offsets/durations, which are plain setters.
-- ---------------------------------------------------------------
local function OnLabelTimelineStop(tl)
    local label = tl.mctLabel
    -- Ignore stops of a timeline the label no longer owns (explicit Stop()
    -- during release/reuse clears mctTimeline before stopping).
    if not label or label.mctTimeline ~= tl then return end
    label.mctTimeline = nil
    if MCT.pool then
        MCT.pool:ReleaseObject(label.mctPoolKey)
    end
end

local function NewLabelTimeline(label)
    local tl = AM:CreateTimeline()
    tl.mctLabel = label
    tl:SetHandler("OnStop", OnLabelTimelineStop)
    return tl
end

-- Rise timeline: one translate + one alpha fade. Keyed by fade delay.
local function GetRiseTimeline(label, fadeDelay)
    local cache = label.mctRiseTimelines
    if not cache then
        cache = {}
        label.mctRiseTimelines = cache
    end
    local entry = cache[fadeDelay]
    if not entry then
        local tl = NewLabelTimeline(label)
        entry = {
            tl = tl,
            move = tl:InsertAnimation(ANIMATION_TRANSLATE, label, 0),
            fade = tl:InsertAnimation(ANIMATION_ALPHA, label, fadeDelay),
        }
        entry.fade:SetAlphaValues(1, 0)
        cache[fadeDelay] = entry
    end
    return entry
end

-- Pop timeline: the rise timeline plus a two-step scale "boing"
-- (squish in -> overshoot -> settle). Used by the bouncy pop animation.
local POP_GROW_MS, POP_SETTLE_MS = 130, 170

local function GetPopTimeline(label, fadeDelay)
    local cache = label.mctPopTimelines
    if not cache then
        cache = {}
        label.mctPopTimelines = cache
    end
    local entry = cache[fadeDelay]
    if not entry then
        local tl = NewLabelTimeline(label)
        entry = {
            tl = tl,
            move = tl:InsertAnimation(ANIMATION_TRANSLATE, label, 0),
            grow = tl:InsertAnimation(ANIMATION_SCALE, label, 0),
            settle = tl:InsertAnimation(ANIMATION_SCALE, label, POP_GROW_MS),
            fade = tl:InsertAnimation(ANIMATION_ALPHA, label, fadeDelay),
        }
        entry.grow:SetDuration(POP_GROW_MS)
        entry.settle:SetDuration(POP_SETTLE_MS)
        entry.fade:SetAlphaValues(1, 0)
        cache[fadeDelay] = entry
    end
    return entry
end

-- Lane timeline: three translate phases + alpha fade. Keyed by the
-- phase offsets (only a few distinct values exist per settings profile).
local function GetLaneTimeline(label, fadeDelay, firstPhase, secondPhase)
    local cache = label.mctLaneTimelines
    if not cache then
        cache = {}
        label.mctLaneTimelines = cache
    end
    local sig = fadeDelay .. ":" .. firstPhase .. ":" .. secondPhase
    local entry = cache[sig]
    if not entry then
        local tl = NewLabelTimeline(label)
        entry = {
            tl = tl,
            down = tl:InsertAnimation(ANIMATION_TRANSLATE, label, 0),
            curve = tl:InsertAnimation(ANIMATION_TRANSLATE, label, firstPhase),
            settle = tl:InsertAnimation(ANIMATION_TRANSLATE, label, firstPhase + secondPhase),
            fade = tl:InsertAnimation(ANIMATION_ALPHA, label, fadeDelay),
        }
        entry.fade:SetAlphaValues(1, 0)
        cache[sig] = entry
    end
    return entry
end

local function StartLaneAnimationNow(label, code, poolKey)
    -- Stop any leftover timeline before reusing this label.
    local old = label.mctTimeline
    if old then
        label.mctTimeline = nil
        old:Stop()
    end

    local sv = MCT.sv
    local baseScale = MCT:GetEffectiveUiScale()
    label:SetHidden(false)
    label:SetAlpha(1)
    label:SetScale(baseScale)

    -- Keep texture/icon in sync with the active label event
    -- (SetEventTexture also lays the icons out).
    MCT:SetEventTexture(poolKey, label.mctAbilityId, label.mctEventCode, label.mctAbilityIds)

    local isCC = CC_ANIM_CODES[code]
    local bx, by, jitter, rise
    if not sv.luiAnimStyle then
        -- CombatCloud / "Entered Combat" style: every event rises from the same
        -- center anchor (ccx, ccy) so all text appears and floats up together.
        bx     = sv.ccx or 0
        by     = sv.ccy or 0
        jitter = sv.animJitter or 20
        rise   = sv.animRise   or 80
    elseif isCC then
        bx, by, jitter, rise = sv.ccx, sv.ccy, sv.animJitter or 20, sv.animRise or 80
    else
        local fn = ANIM_DATA[code]
        if fn then
            bx, by, jitter, rise = fn(sv)
        else
            bx, by, jitter, rise = sv.healingx, sv.healingy, 80, 80
        end
    end

    local moveDur, fadeDur, fadeDelay = GetAnimationTimingForCode(sv, code)
    local tl

    if isCC or not sv.luiAnimStyle then
        -- Classic upward-rising animation: label floats up from its anchor with a horizontal jitter.
        bx, by = tonumber(bx) or 0, tonumber(by) or 0
        jitter = math.max(0, math.floor(tonumber(jitter) or 0))
        rise = tonumber(rise) or 0
        local entry
        if sv.popAnimation and ANIMATION_SCALE then
            -- Bouncy pop: squish in, overshoot, settle — crits bounce harder.
            entry = GetPopTimeline(label, fadeDelay)
            local peak = CRIT_ANIM_CODES[code] and 1.45 or 1.22
            entry.grow:SetScaleValues(baseScale * 0.35, baseScale * peak)
            entry.settle:SetScaleValues(baseScale * peak, baseScale)
        else
            entry = GetRiseTimeline(label, fadeDelay)
        end
        entry.move:SetTranslateOffsets(bx, by, bx + zo_random(-jitter, jitter), by - rise)
        entry.move:SetDuration(moveDur)
        entry.fade:SetDuration(fadeDur)
        tl = entry.tl
    else
        -- Descending lane animation: start near top, fall, then ease outward on each side.
        local isRightLane = RIGHT_LANE_ANIM_CODES[code]
        local sideSign = isRightLane and 1 or -1
        local laneBaseX = tonumber(bx)
        if not laneBaseX then
            laneBaseX = isRightLane and RIGHT_LANE_X or LEFT_LANE_X
        end
        local laneBaseY = tonumber(by) or LANE_CENTER_Y
        local startX = laneBaseX + zo_random(-10, 10)
        local upperMidX = laneBaseX + (sideSign * zo_random(8, 18))
        local lowerMidX = laneBaseX + (sideSign * zo_random(24, 40))
        local endX = laneBaseX + (sideSign * zo_random(48, 72))

        local startY = laneBaseY - 340
        local upperMidY = laneBaseY - 200
        local lowerMidY = laneBaseY - 85
        local endY = laneBaseY

        local firstPhase = math.floor(moveDur * 0.40)
        local secondPhase = math.floor(moveDur * 0.32)
        local thirdPhase = math.max(140, moveDur - firstPhase - secondPhase)

        local entry = GetLaneTimeline(label, fadeDelay, firstPhase, secondPhase)
        entry.down:SetTranslateOffsets(startX, startY, upperMidX, upperMidY)
        entry.down:SetDuration(firstPhase)
        entry.curve:SetTranslateOffsets(upperMidX, upperMidY, lowerMidX, lowerMidY)
        entry.curve:SetDuration(secondPhase)
        entry.settle:SetTranslateOffsets(lowerMidX, lowerMidY, endX, endY)
        entry.settle:SetDuration(thirdPhase)
        entry.fade:SetDuration(fadeDur)
        tl = entry.tl
    end

    -- OnLabelTimelineStop releases the label back to the pool when the
    -- timeline finishes (or is stopped while still owned by the label).
    label.mctTimeline = tl
    tl:PlayFromStart()

    return GetLaneStaggerMs(sv, code, moveDur)
end

function MCT:ProcessLaneQueue(lane)
    local q = self._laneQueues[lane]
    if not q or not LaneQueueHasItems(self, lane) then
        return
    end

    local now = GetGameTimeMs()
    local nextOpen = tonumber(self._laneNextOpenAt[lane]) or 0
    if now < nextOpen then
        self:ScheduleLaneQueuePump(lane, nextOpen - now)
        return
    end

    local head = self._laneQueueHeads[lane] or 1
    local item = q[head]
    q[head] = nil
    self._laneQueueHeads[lane] = head + 1

    if not LaneQueueHasItems(self, lane) then
        self._laneQueueHeads[lane] = 1
        self._laneQueueTails[lane] = 0
    end

    if not item then
        return
    end

    if not item.label or item.label.mctQueueToken ~= item.token then
        if LaneQueueHasItems(self, lane) then
            self:ScheduleLaneQueuePump(lane, 0)
        end
        return
    end

    item.label.mctQueued = nil
    local staggerMs = StartLaneAnimationNow(item.label, item.code, item.poolKey)
    self._laneNextOpenAt[lane] = now + staggerMs

    if LaneQueueHasItems(self, lane) then
        self:ScheduleLaneQueuePump(lane, staggerMs)
    end
end

-- ---------------------------------------------------------------
-- MCT:Animate: attaches and plays the animation timeline for a
-- floating label. Always stops any previous timeline first to
-- prevent double-release of pool keys.
--
-- Animation types:
--   CC codes     : single ANIMATION_TRANSLATE (linear rise) +
--                  ANIMATION_ALPHA fade.
--   Lane codes   : three-phase ANIMATION_TRANSLATE (drop from
--                  top, curve, settle at bottom) + alpha fade.
--                  Left/right lane is selected by RIGHT_LANE_ANIM_CODES.
--
-- Timeline lifecycle:
--   InsertCallback at tl duration -> Release()
--   OnStop handler               -> Release()
--   Double-release is guarded by a `released` boolean flag.
--
-- Parameters:
--   label   : the CT_LABEL control from the pool
--   code    : animation category code (from ANIM_DATA or CC_ANIM_CODES)
--   poolKey : integer key to pass to MCT.pool:ReleaseObject on completion
-- ---------------------------------------------------------------
function MCT:Animate(label, code, poolKey)
    local lane = self:GetAnimationLane(code)
    local q = self._laneQueues[lane]
    if not q then
        q = {}
        self._laneQueues[lane] = q
    end

    -- Keep queued labels invisible until their lane slot opens.
    label:SetHidden(true)
    label.mctQueueToken = (tonumber(label.mctQueueToken) or 0) + 1
    label.mctQueued = true

    local nextTail = (self._laneQueueTails[lane] or 0) + 1
    self._laneQueueTails[lane] = nextTail
    q[nextTail] = {
        label = label,
        code = code,
        poolKey = poolKey,
        token = label.mctQueueToken,
    }

    self:ProcessLaneQueue(lane)
end
-- MCT:TestText: debug helper. Acquires a label and animates it with the
-- given value string and animation code. Used by /bct testlabel to verify
-- that a specific animation style looks correct in-game.
function MCT:TestText(value, valueType)
    local label, key = MCT.pool:AcquireObject()
    if not label then return end
    label:SetHidden(false)
    label:SetAlpha(1)
    label:SetText(MCT:StylizeDisplayText(tostring(value), valueType))
    label:SetAnchor(CENTER, GuiRoot, CENTER, 0, 0)
    MCT:Animate(label, valueType, key)
end
-- ParseArgs: splits a raw slash-command argument string into tokens,
-- respecting double-quoted strings (e.g. "my name" becomes one token).
-- Escape sequences: \" inside quotes produces a literal quote character.
-- Returns an array of string tokens.
local function ParseArgs(text)
    local args = {}
    local i = 1

    while i <= #text do
        -- Skip whitespace
        while i <= #text and text:sub(i,i):match("%s") do
            i = i + 1
        end

        if i > #text then break end

        local c = text:sub(i,i)

        -- Quoted argument
        if c == '"' then
            i = i + 1
            local buffer = {}

            while i <= #text do
                local ch = text:sub(i,i)

                if ch == '\\' and text:sub(i+1,i+1) == '"' then
                    -- handle escaped quote: \"
                    buffer[#buffer+1] = '"'
                    i = i + 2
                elseif ch == '"' then
                    -- end of quoted string
                    i = i + 1
                    break
                else
                    buffer[#buffer+1] = ch
                    i = i + 1
                end
            end

            args[#args+1] = table.concat(buffer)
        
        -- Unquoted argument
        else
            local buffer = {}

            while i <= #text and not text:sub(i,i):match("%s") do
                buffer[#buffer+1] = text:sub(i,i)
                i = i + 1
            end

            args[#args+1] = table.concat(buffer)
        end
    end

    return args
end

-- Applies the selected text style decoration consistently to all combat labels.
local function SetStyledLabelText(label, text, eventCode, isCrit)
    label:SetText(MCT:StylizeDisplayText(text, eventCode, isCrit))
end
-- ---------------------------------------------------------------
-- initSlashCommands: registers development/debug slash commands.
-- These are separate from the preset commands (MCT:RegisterPresetCommands)
-- so they can be toggled independently.
--
-- /bct testlabel <value> <code>
--     Directly animate a label with the given text and animation code.
--     Useful for tuning font sizes and animation timing in-game.
--
-- /mctdebug merge <on|off|toggle|seconds>
--     Enable or disable the merge-queue debug output that prints each
--     flush event to chat. Pass a number to auto-disable after N seconds.
-- ---------------------------------------------------------------
function initSlashCommands()
    SLASH_COMMANDS["/bct"] = function(args)
        local args = ParseArgs(args)
        local arg1, arg2, arg3 = args[1], args[2], args[3]
        if arg1 == "testlabel" then
            d("[MCT] Testing label...")
            MCT:TestText(arg2, arg3)
        else
            d("[MCT] Available commands:")
            d("  /bct testlabel <value> <code> - Test label display")
            d("  /mct preset <preset_name> - Switch presets")
            d("  /mct presets - List available presets")
        end
    end

    SLASH_COMMANDS["/mctdebug"] = function(args)
        local parsed = ParseArgs(args)
        local section = parsed[1]
        local action = parsed[2]

        if section ~= "merge" then
            d("[MCT] Usage: /mctdebug merge <on|off|toggle|seconds>")
            return
        end

        if not action or action == "toggle" then
            MCT.sv.debugMerge = not MCT.sv.debugMerge
            d(string.format("[MCT] Merge debug %s", MCT.sv.debugMerge and "ON" or "OFF"))
            return
        end

        if action == "on" then
            MCT.sv.debugMerge = true
            d("[MCT] Merge debug ON")
            return
        end

        if action == "off" then
            MCT.sv.debugMerge = false
            d("[MCT] Merge debug OFF")
            return
        end

        local seconds = tonumber(action)
        if seconds and seconds > 0 then
            MCT.sv.debugMerge = true
            d(string.format("[MCT] Merge debug ON for %.1fs", seconds))
            zo_callLater(function()
                MCT.sv.debugMerge = false
                d("[MCT] Merge debug OFF")
            end, math.floor(seconds * 1000))
            return
        end

        d("[MCT] Usage: /mctdebug merge <on|off|toggle|seconds>")
    end
end

-- ---------------------------------------------------------------
-- MCT:RegisterPresetCommands: registers the /mct slash command which
-- is the primary in-game command for switching visual presets.
--
-- /mct preset <name>   : apply the named preset (LUI_ENHANCED, etc.)
-- /mct presets         : print available preset names to chat
-- /mct help            : print full command reference
-- ---------------------------------------------------------------
function MCT:RegisterPresetCommands()
    SLASH_COMMANDS["/mct"] = function(args)
        local args = ParseArgs(args)
        local arg1, arg2 = args[1], args[2]
        
        if not arg1 or arg1 == "" or arg1 == "settings" then
            MCT:OpenSettings()
        elseif arg1 == "test" or arg1 == "preview" then
            MCT:ShowPreview()
        elseif arg1 == "preset" and arg2 then
            MCT:ApplyPreset(arg2:upper())
        elseif arg1 == "presets" then
            d("[MCT] Available Presets:")
            for _, name in ipairs(MCT:GetPresetNames()) do
                d("  " .. name)
            end
            d("/mct preset <name> to switch")
        elseif arg1 == "help" then
            d("[MCT] Commands:")
            d("  /mct - Open settings")
            d("  /mct test - Preview sample combat text")
            d("  /mct preset <name> - Switch to preset (LUI_ENHANCED, LUI_CLASSIC, MINIMAL, DETAILED)")
            d("  /mct presets - List all presets")
            d("")
            d("[MCT] Test Commands:")
            d("  /bct testlabel <value> <code> - Test a label")
        else
            d("[MCT] Unknown command. Type /mct help")
        end
    end
end

-- ---------------------------------------------------------------
-- MCT:ShowText: central render router. Acquires a label, picks the
-- correct text/color/font/anchor/animation for the event, and hands
-- the label to MCT:Animate.
--
-- Three top-level branches keyed on the source/target unit IDs:
--
--   Branch 1 — unitId == playerId AND sID ~= playerId
--     "Incoming to player" (damage taken, healed by another, CC on player).
--     Labels appear on the right lane or CC area.
--
--   Branch 2 — unitId ~= playerId AND sID == playerId
--     "Outgoing from player" (damage dealt, outgoing heal, outgoing CC).
--     Labels appear on the left lane (damage) or right lane (healing).
--
--   Branch 3 — unitId == playerId AND sID == playerId
--     "Self events" (self-heals, self-damage like reflect, self animation).
--     Uses the same style rules as outgoing but anchored appropriately.
--
--   Fallback — neither condition matches: release the label unused.
--
-- The `special` string overrides normal damage/heal display with a
-- named CC or special label (e.g. "stunned", "burst", "shieldbreak").
--
-- Parameters:
--   value     : numeric value to display, or nil for text-only labels
--   isCrit    : bool — true applies critical color and "!" suffix
--   isHeal    : bool — true uses healing color and "+" prefix
--   special   : string event key override ("dodged", "stunned", etc.)
--   sID       : source unit ID string
--   unitId    : target unit ID string
--   isBlocked : bool — true shows "BLOCKED *value*" styling
--   abilityId : integer ability ID for icon resolution
--   abilityIds: list of ability IDs for merged multi-hit labels
-- ---------------------------------------------------------------
-- ---------------------------------------------------------------
-- MCT:ShowNotification: displays a floating text-only label.
-- Used for CombatCloud-style alerts, combat state, resource
-- warnings, and XP/AP/CP point gains.
--
-- Parameters:
--   text     : pre-formatted string; use |cRRGGBB...|r for colour.
--   animCode : animation code — must exist in CC_ANIM_CODES or ANIM_DATA.
--   fontSize : point size passed to GetCachedFTNFont (optional).
-- ---------------------------------------------------------------
function MCT:ShowNotification(text, animCode, fontSize)
    if not MCT.pool then return end
    local sv = MCT.sv
    if not sv or not sv.enabled then return end
    MCT:MarkDisplayEvent()
    local label, key = MCT.pool:AcquireObject()
    if not label then return end
    label:SetFont(MCT:GetCachedFTNFont(fontSize or sv.fontSize or 32))
    label:SetAnchor(MCT:GetAnchor(animCode))
    label:SetText(MCT:StylizeDisplayText(text, animCode))
    label.mctAbilityId = nil
    label.mctAbilityIds = nil
    label.mctEventCode = animCode
    MCT:Animate(label, animCode, key)
end

-- ---------------------------------------------------------------
-- ShowText style tables.
-- Previously ShowText was ~300 lines of near-identical if/elseif
-- branches (and allocated an eventMap table on every call). The
-- styles now live in data; ShowText picks the row and applies it.
--
-- Special (text/CC) rows:
--   font   : sv key of the font size
--   zo     : true → use the style's burst face (GetCachedZoCombatFont)
--   rgb    : label vertex colour
--   anchor : GetAnchor() code
--   text   : fixed label text (wrapped in sv[color]); when nil the
--            label shows `value` instead, followed by `mark`
--            (or `critMark` when the hit was a crit)
--   color  : sv key of the hex colour
--   anim   : animation code (`critAnim` when crit, if present)
-- ---------------------------------------------------------------
local EVENT_CODE_FOR_SPECIAL = {
    dodged = "dodge",
    stunned = "stun",
    feared = "fear",
    charmed = "charm",
    silenced = "silence",
    disoriented = "disorient",
    offbalanced = "offbalance",
    immobilized = "dodge",
}

local SHIELDBREAK_SPEC = { font = "shieldbreakFontSize", rgb = { 0.6, 0.8, 1 }, anchor = "shieldbreak", color = "shieldbreakColor", anim = "shieldbreak" }

-- CC / specials that landed on the player.
local INCOMING_SPECIAL = {
    dodged      = { font = "dodgeFontSize",      rgb = { 1, 1, 1 },     anchor = "dodge",      text = "DODGE",      color = "dodgedColor", anim = "dodge" },
    stunned     = { font = "stunFontSize",       rgb = { 1, 0, 0 },     anchor = "stun",       text = "STUN",       color = "ccColor",     anim = "stun" },
    feared      = { font = "fearFontSize",       rgb = { 1, 0, 1 },     anchor = "fear",       text = "FEAR",       color = "ccColor",     anim = "fear" },
    charmed     = { font = "charmFontSize",      rgb = { 1, 0.6, 1 },   anchor = "charm",      text = "CHARM",      color = "ccColor",     anim = "charm" },
    silenced    = { font = "silenceFontSize",    rgb = { 0.6, 0.6, 1 }, anchor = "silence",    text = "SILENCE",    color = "ccColor",     anim = "silence" },
    disoriented = { font = "disorientFontSize",  rgb = { 1, 0.6, 0.4 }, anchor = "disorient",  text = "DISORIENT",  color = "ccColor",     anim = "disorient" },
    offbalanced = { font = "offbalanceFontSize", rgb = { 0.4, 1, 0.8 }, anchor = "offbalance", text = "OFFBALANCE", color = "ccColor",     anim = "offbalance" },
    immobilized = { font = "offbalanceFontSize", rgb = { 1, 0, 0 },     anchor = "dodge",      text = "IMMOBILIZED", color = "dodgedColor", anim = "dodge" },
    shieldbreak = SHIELDBREAK_SPEC,
}

-- CC / specials the player applied to (or triggered on) another unit.
local OUTGOING_SPECIAL = {
    dodged      = { font = "dodgeFontSize",      rgb = { 1, 1, 1 },       anchor = "dodge",      text = "TARGET DODGE",       color = "dodgedColor", anim = "dodge" },
    stunned     = { font = "offbalanceFontSize", rgb = { 1, 0, 0 },       anchor = "stun",       text = "TARGET STUN",        color = "ccColor",     anim = "stun" },
    feared      = { font = "offbalanceFontSize", rgb = { 1, 0, 1 },       anchor = "fear",       text = "TARGET FEAR",        color = "ccColor",     anim = "fear" },
    charmed     = { font = "offbalanceFontSize", rgb = { 1, 0.6, 1 },     anchor = "charm",      text = "TARGET CHARM",       color = "ccColor",     anim = "charm" },
    silenced    = { font = "offbalanceFontSize", rgb = { 0.6, 0.6, 1 },   anchor = "silence",    text = "TARGET SILENCE",     color = "ccColor",     anim = "silence" },
    disoriented = { font = "offbalanceFontSize", rgb = { 1, 0.6, 0.4 },   anchor = "disorient",  text = "TARGET DISORIENT",   color = "ccColor",     anim = "disorient" },
    offbalanced = { font = "offbalanceFontSize", rgb = { 0.4, 1, 0.8 },   anchor = "offbalance", text = "TARGET OFFBALANCE",  color = "ccColor",     anim = "offbalance" },
    immobilized = { font = "offbalanceFontSize", rgb = { 1, 0, 0 },       anchor = "dodge",      text = "TARGET IMMOBILIZED", color = "dodgedColor", anim = "dodge" },
    burst       = { font = "burstFontSize", zo = true, rgb = { 1, 0.6, 0.1 }, anchor = "burst", color = "burstColor", mark = "!", anim = "burst" },
    dot         = { font = "dotFontSize", rgb = { 0.8, 0.8, 0.8 }, anchor = "dot", color = "dotColor", critMark = "!", anim = "dot", critAnim = "dotCrit" },
    shieldbreak = SHIELDBREAK_SPEC,
}

-- Numeric rows: { font, anchor, prefix, postfix, colorKey, anim }.
-- Index with [direction][variant] where variant is one of
-- critHeal / critBlocked / crit / heal / blocked / hit.
local function NumStyle(font, anchor, prefix, postfix, color, anim)
    return { font = font, anchor = anchor, prefix = prefix, postfix = postfix, color = color, anim = anim }
end

local NUMBER_STYLES = {
    incoming = {
        critHeal    = NumStyle("healingFontSize", "healing",     "+",         "!", "criticalHealingColor", "healingCrit"),
        critBlocked = NumStyle("damageTakenFontSize", "damageTaken", "BLOCKED *", "*", "damageTakenCritColor", "damageTakenCrit"),
        crit        = NumStyle("damageTakenFontSize", "damageTaken", "",          "!", "damageTakenCritColor", "damageTakenCrit"),
        heal        = NumStyle("healingFontSize", "healing",     "+",         "",  "healingColor",         "healing"),
        blocked     = NumStyle("damageTakenFontSize", "damageTaken", "BLOCKED *", "*", "damageTakenColor",     "damageTaken"),
        hit         = NumStyle("damageTakenFontSize", "damageTaken", "",          "",  "damageTakenColor",     "damageTaken"),
    },
    outgoing = {
        critHeal    = NumStyle("healingFontSize", "healing", "+",         "!", "criticalHealingColor", "healingCrit"),
        critBlocked = NumStyle("damageFontSize",  "damage",  "",          "!", "criticalColor",        "damageCrit"),
        crit        = NumStyle("damageFontSize",  "damage",  "",          "!", "criticalColor",        "damageCrit"),
        heal        = NumStyle("healingFontSize", "healing", "+",         "",  "healingColor",         "healing"),
        blocked     = NumStyle("damageFontSize",  "damage",  "BLOCKED *", "*", "damageColor",          "damage"),
        hit         = NumStyle("damageFontSize",  "damage",  "",          "",  "damageColor",          "damage"),
    },
    self = {
        critHeal    = NumStyle("healingFontSize", "healing", "+", "!", "criticalHealingColor", "healingCrit"),
        critBlocked = NumStyle("damageFontSize",  "damage",  "",  "!", "criticalColor",        "damageTakenCrit"),
        crit        = NumStyle("damageFontSize",  "damage",  "",  "!", "criticalColor",        "damageTakenCrit"),
        heal        = NumStyle("healingFontSize", "healing", "+", "",  "healingColor",         "healing"),
        blocked     = NumStyle("damageFontSize",  "damage",  "",  "",  "damageColor",          "damageTaken"),
        hit         = NumStyle("damageFontSize",  "damage",  "",  "",  "damageColor",          "damageTaken"),
    },
}

local function ApplySpecialStyle(label, key, spec, value, isCrit, eventCode)
    local sv = MCT.sv
    if spec.zo then
        label:SetFont(MCT:GetCachedZoCombatFont(sv[spec.font]))
    else
        label:SetFont(MCT:GetCachedFTNFont(sv[spec.font]))
    end
    local rgb = spec.rgb
    label:SetColor(rgb[1], rgb[2], rgb[3], 1)
    label:SetAnchor(MCT:GetAnchor(spec.anchor))

    local text
    if spec.text then
        text = MCT:ColorTextCached(sv[spec.color], spec.text)
    else
        local mark = (isCrit and spec.critMark) or spec.mark or ""
        local shown = (type(value) == "number") and FormatShortNumber(value) or tostring(value)
        text = "|c" .. tostring(sv[spec.color]) .. shown .. mark .. "|r"
    end
    SetStyledLabelText(label, text, eventCode, isCrit)

    MCT:Animate(label, (isCrit and spec.critAnim) or spec.anim, key)
end

function MCT:ShowText(value, isCrit, isHeal, special, sID, unitId, isBlocked, abilityId, abilityIds)
    local pool = MCT.pool
    if not pool then return end

    -- Classify direction relative to the player before touching the pool.
    local playerId = MCT._playerUnitId
    local targetIsPlayer = (unitId == playerId)
    local sourceIsPlayer = (sID == playerId)
    local direction
    if targetIsPlayer and not sourceIsPlayer then
        direction = "incoming"
    elseif sourceIsPlayer and not targetIsPlayer then
        direction = "outgoing"
    elseif sourceIsPlayer and targetIsPlayer then
        direction = "self"
    else
        return -- event doesn't involve the player; nothing to show
    end

    MCT:MarkDisplayEvent()
    local label, key = pool:AcquireObject()
    if not label then return end

    local eventCode = special
    if not eventCode or eventCode == "" then
        if isHeal then
            eventCode = "healing"
        elseif direction == "incoming" then
            eventCode = "damageTaken"
        else
            eventCode = "damage"
        end
    end
    eventCode = EVENT_CODE_FOR_SPECIAL[eventCode] or eventCode

    label.mctAbilityId = abilityId
    label.mctAbilityIds = abilityIds
    label.mctEventCode = eventCode

    -- ---- Text / CC specials ----
    if special and special ~= "" then
        local spec
        if direction == "outgoing" then
            spec = OUTGOING_SPECIAL[special]
        else
            -- Incoming, or a self-applied effect: the player is the one affected.
            spec = INCOMING_SPECIAL[special] or OUTGOING_SPECIAL[special]
        end
        if spec then
            ApplySpecialStyle(label, key, spec, value, isCrit, eventCode)
            return
        end
        -- Unknown special: fall through and display as a number.
    end

    -- ---- Numeric damage / healing ----
    local variant
    if isCrit then
        variant = isHeal and "critHeal" or (isBlocked and "critBlocked" or "crit")
    else
        variant = isHeal and "heal" or (isBlocked and "blocked" or "hit")
    end
    local style = NUMBER_STYLES[direction][variant]
    local sv = MCT.sv

    if direction ~= "incoming" then
        if isHeal then
            label:SetColor(0.2, 1, 0.2, 1)
        else
            label:SetColor(1, 0.2, 0.2, 1)
        end
    end
    label:SetFont(MCT:GetCachedFTNFont(sv[style.font] or sv.damageFontSize))
    label:SetAnchor(MCT:GetAnchor(style.anchor))
    SetStyledLabelText(label,
        "|c" .. tostring(sv[style.color]) .. style.prefix .. FormatShortNumber(value) .. style.postfix .. "|r"
            .. MCT:GetAbilityNameSuffix(abilityId, abilityIds),
        eventCode, isCrit)
    MCT:Animate(label, style.anim, key)
end
-------------------------------------------------------
-- Tracking and combat pipeline moved to:
--   MyCombatText.Tracking.lua  (merge queue, burst, shieldbreak, DPS)
--   MyCombatText.Combat.lua    (event registration and parsing)
-- MCT:ShowText above dispatches to both after resolving the label.
-------------------------------------------------------

-- MCT:InitSettingsPanel lives in MyCombatText.Settings.lua.

-------------------------------------------------------
-- Init + addon load
-------------------------------------------------------

-- ---------------------------------------------------------------
-- MCT:Initialize: one-time setup called from EVENT_ADD_ON_LOADED.
-- Order of operations:
--   1. Load SavedVariables (ZO_SavedVars account-wide merge).
--   2. Apply LUI_ENHANCED preset if this is the first ever load.
--   3. Build the priority rule cache (Tracking.lua).
--   4. Create the label pool and clamp to maxFloatingLabels.
--   5. Create the reticle flash overlay.
--   6. Register all combat event listeners (Combat.lua).
--   7. Register slash commands.
--   8. Register the settings panel (requires LAM-2.0).
--   (Leaving-combat cleanup lives in Combat.lua: MCT:ResetCombatTracking.)
-- ---------------------------------------------------------------
function MCT:Initialize()
    MCT.sv = ZO_SavedVars:NewAccountWide("MCT_Saved", 1, nil, MCT.defaults)
    
    -- Apply default LUI Enhanced preset if not yet configured
    if not MCT.sv.presetApplied then
        MCT:ApplyPreset("LUI_ENHANCED")
        MCT.sv.presetApplied = true
    end
    -- Remember which preset the settings dropdown should show across reloads.
    if MCT.sv.activePreset and MCT.Presets[MCT.sv.activePreset] then
        MCT.Presets.current = MCT.sv.activePreset
    end
    
    MCT:RefreshRuleCache()

    MCT:InitPool()
    if MCT.pool and MCT.pool.SetMaxLabels then
        MCT.pool:SetMaxLabels(MCT.sv.maxFloatingLabels)
    end
    MCT:InitReticleFlash()
    MCT:RegisterCombat()
    initSlashCommands()
    MCT:InitSettingsPanel()
    MCT:RegisterPresetCommands()

    -- Per-fight cleanup (tracking tables, lane queues, visible labels) runs
    -- from the EVENT_PLAYER_COMBAT_STATE handler in MyCombatText.Combat.lua
    -- via MCT:ResetCombatTracking().
end

-- Bootstrap: wait for EVENT_ADD_ON_LOADED for this addon's name so that
-- SavedVariables are ready before Initialize() accesses them.
EM:RegisterForEvent(MCT.name, EVENT_ADD_ON_LOADED, function(_, addon)
    if addon == MCT.name then
        MCT:Initialize()
    end
end)
