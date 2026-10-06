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
        if l.mctTimeline then
            l.mctTimeline:Stop()    -- Stop any in-progress animation immediately.
            l.mctTimeline = nil
        end
        l:SetHidden(true)
        l:ClearAnchors()
        l:SetAlpha(1)
        l:SetScale(1)
        l:SetText("")
        l.mctAbilityId  = nil   -- Single ability ID (fast path).
        l.mctAbilityIds = nil   -- List of ability IDs (multi-hit merge path).
        l.mctEventCode  = nil   -- Category code used for icon and animation lookup.
        l.mctQueueToken = nil

        if t then
            for i = 1, #t do
                t[i]:SetHidden(true)
                t[i]:ClearAnchors()
                t[i]:SetTexture("")
                t[i].mctTexturePath = ""
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
                self.textures[key] = { CreateTexture() }
            else
                -- Pool is full: drop this event rather than killing an active label
                -- mid-animation. The event is silently discarded; active labels finish
                -- their animations and return to the pool naturally.
                return nil, nil
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
function MCT:ResolveEventTextures(abilityIds, eventCode)
    local textures = {}
    local maxIcons = tonumber(MCT.sv and MCT.sv.maxEventIcons) or 3
    if maxIcons < 1 then maxIcons = 1 end
    if maxIcons > 6 then maxIcons = 6 end

    if MCT.sv and MCT.sv.performanceMode then
        local perfCap = tonumber(MCT.sv.performanceMaxIcons)
        if perfCap and perfCap > 0 and perfCap < maxIcons then
            maxIcons = perfCap
        end
    end

    if abilityIds then
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
local function GetLabelFontSize(label)
    local font = label and label.GetFont and label:GetFont()
    if not font then
        return tonumber(MCT.sv and MCT.sv.fontSize) or 28
    end

    -- ESO font strings are typically: "path|size|flags" or "ZoFontCombat|size|flags"
    local sizeStr = string.match(font, "|(%d+)|")
    local size = tonumber(sizeStr)
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
    for i = 1, #textureSet do
        local texture = textureSet[i]
        texture:SetDimensions(iconSize, iconSize)
        texture:ClearAnchors()
        if not texture:IsHidden() then
            slot = slot + 1
            local step = iconSize + textureGap
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

    local texturePaths = MCT:ResolveEventTextures(abilityIds or (abilityId and { abilityId } or nil), eventCode)
    if #texturePaths == 0 then
        for i = 1, #textureSet do
            textureSet[i]:SetHidden(true)
            textureSet[i]:ClearAnchors()
            textureSet[i]:SetTexture("")
        end
        return
    end

    while #textureSet < #texturePaths do
        textureSet[#textureSet + 1] = WM:CreateControl(nil, _G["MyCombatTextRoot"], CT_TEXTURE)
        textureSet[#textureSet]:SetDrawLayer(DL_OVERLAY)
        textureSet[#textureSet]:SetDrawTier(DT_HIGH)
        textureSet[#textureSet]:SetDrawLevel(2)
        textureSet[#textureSet]:SetHidden(true)
    end

    for i = 1, #textureSet do
        local texture = textureSet[i]
        local texturePath = texturePaths[i]
        if texturePath then
            if texture.mctTexturePath ~= texturePath then
                texture:SetTexture(texturePath)
                texture.mctTexturePath = texturePath
            end
            texture:SetHidden(false)
        else
            texture:SetHidden(true)
            texture:ClearAnchors()
            if texture.mctTexturePath ~= "" then
                texture:SetTexture("")
                texture.mctTexturePath = ""
            end
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

local function GetLaneStaggerMs(sv, code)
    local moveDur = GetAnimationTimingForCode(sv, code)
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

function MCT:ScheduleLaneQueuePump(lane, delayMs)
    local delay = math.max(0, tonumber(delayMs) or 0)
    if self._laneQueueScheduled[lane] then
        return
    end

    self._laneQueueScheduled[lane] = true
    zo_callLater(function()
        self._laneQueueScheduled[lane] = false
        self:ProcessLaneQueue(lane)
    end, delay)
end

local function StartLaneAnimationNow(label, code, poolKey)
    -- Stop any leftover timeline before reusing this label
    if label.mctTimeline then
        label.mctTimeline:Stop()
        label.mctTimeline = nil
    end

    local sv = MCT.sv
    label:SetHidden(false)
    label:SetAlpha(1)
    label:SetScale(MCT:GetEffectiveUiScale())

    -- Keep texture/icon in sync with the active label event.
    MCT:SetEventTexture(poolKey, label.mctAbilityId, label.mctEventCode, label.mctAbilityIds)
    MCT:LayoutEventTexture(poolKey)

    local bx, by, jitter, rise
    if not sv.luiAnimStyle then
        -- CombatCloud / "Entered Combat" style: every event rises from the same
        -- center anchor (ccx, ccy) so all text appears and floats up together,
        -- exactly like ESO's native "Entered Combat" / "Left Combat" notification.
        bx     = sv.ccx or 0
        by     = sv.ccy or 0
        jitter = sv.animJitter or 20
        rise   = sv.animRise   or 80
    elseif CC_ANIM_CODES[code] then
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

    local tl = ANIMATION_MANAGER:CreateTimeline()
    label.mctTimeline = tl

    if CC_ANIM_CODES[code] or not sv.luiAnimStyle then
        -- Classic upward-rising animation: label floats up from its anchor with a horizontal jitter.
        -- Used for CC/alerts (always) and all other event types when luiAnimStyle is false (default).
        local move = tl:InsertAnimation(ANIMATION_TRANSLATE, label, 0)
        move:SetTranslateOffsets(bx, by, bx + zo_random(-jitter, jitter), by - rise)
        move:SetDuration(moveDur)
    else
        -- Descending lane animation: start near top, fall, then ease outward on each side.
        -- Only active when luiAnimStyle = true.
        local isRightLane = RIGHT_LANE_ANIM_CODES[code]
        local sideSign = isRightLane and 1 or -1
        local laneBaseX = tonumber(bx)
        if not laneBaseX then
            laneBaseX = isRightLane and RIGHT_LANE_X or LEFT_LANE_X
        end
        local laneBaseY = tonumber(by) or LANE_CENTER_Y
        local laneJitter = 10
        local startX = laneBaseX + zo_random(-laneJitter, laneJitter)
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

        local moveDown = tl:InsertAnimation(ANIMATION_TRANSLATE, label, 0)
        moveDown:SetTranslateOffsets(startX, startY, upperMidX, upperMidY)
        moveDown:SetDuration(firstPhase)

        local moveCurve = tl:InsertAnimation(ANIMATION_TRANSLATE, label, firstPhase)
        moveCurve:SetTranslateOffsets(upperMidX, upperMidY, lowerMidX, lowerMidY)
        moveCurve:SetDuration(secondPhase)

        local moveSettle = tl:InsertAnimation(ANIMATION_TRANSLATE, label, firstPhase + secondPhase)
        moveSettle:SetTranslateOffsets(lowerMidX, lowerMidY, endX, endY)
        moveSettle:SetDuration(thirdPhase)
    end

    local fade = tl:InsertAnimation(ANIMATION_ALPHA, label, fadeDelay)
    fade:SetAlphaValues(1, 0)
    fade:SetDuration(fadeDur)

    -- Guard against double-release: OnStop fires on natural end AND on explicit Stop()
    local released = false
    local function Release()
        if not released then
            released = true
            label.mctTimeline = nil
            MCT.pool:ReleaseObject(poolKey)
        end
    end

    tl:InsertCallback(Release, tl:GetDuration())
    tl:SetHandler("OnStop", Release)

    tl:PlayFromStart()

    return GetLaneStaggerMs(sv, code)
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
local function SetStyledLabelText(label, text, eventCode)
    label:SetText(MCT:StylizeDisplayText(text, eventCode))
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
        
        if arg1 == "preset" and arg2 then
            MCT:ApplyPreset(arg2:upper())
        elseif arg1 == "presets" then
            d("[MCT] Available Presets:")
            for _, name in ipairs(MCT:GetPresetNames()) do
                d("  " .. name)
            end
            d("/mct preset <name> to switch")
        elseif arg1 == "help" then
            d("[MCT] Preset Commands:")
            d("  /mct preset <name> - Switch to preset (LUI_ENHANCED, LUI_CLASSIC, MINIMAL, DETAILED)")
            d("  /mct presets - List all presets")
            d("")
            d("[MCT] Test Commands:")
            d("  /bct testlabel <value> <code> - Test a label")
        else
            d("[MCT] Type /mct help for available commands")
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
    if not MCT.sv or not MCT.sv.enabled then return end
    MCT:MarkDisplayEvent()
    local label, key = MCT.pool:AcquireObject()
    if not label then return end
    label:SetHidden(false)
    label:SetAlpha(1)
    label:SetFont(MCT:GetCachedFTNFont(fontSize or MCT.sv.fontSize or 32))
    label:SetAnchor(MCT:GetAnchor(animCode))
    label:SetText(text)
    label:SetScale(1.6)
    label.mctEventCode = animCode
    MCT:Animate(label, animCode, key)
end

function MCT:ShowText(value, isCrit, isHeal, special, sID,unitId, isBlocked, abilityId, abilityIds)
    MCT:MarkDisplayEvent()

    local label, key = MCT.pool:AcquireObject()
    if not label then return end
    local playerId = MCT:GetPlayerUnitId()
    local eventCode = special
    local abilitySuffix = MCT:GetAbilityNameSuffix(abilityId, abilityIds)

    if not eventCode or eventCode == "" then
        if isHeal then
            eventCode = "healing"
        elseif unitId == playerId and sID ~= playerId then
            eventCode = "damageTaken"
        else
            eventCode = "damage"
        end
    end

    local eventMap = {
        dodged = "dodge",
        stunned = "stun",
        feared = "fear",
        charmed = "charm",
        silenced = "silence",
        disoriented = "disorient",
        offbalanced = "offbalance",
        immobilized = "dodge",
    }
    eventCode = eventMap[eventCode] or eventCode

    label.mctAbilityId = abilityId
    label.mctAbilityIds = abilityIds or (abilityId and { abilityId } or nil)
    label.mctEventCode = eventCode

    if unitId == playerId and sID ~= playerId then
        -- Anchor to center if self
        label:SetHidden(false)
    label:SetAlpha(1)
    if special == "dodged" then
        label:SetFont(MCT:GetCachedFTNFont(MCT.sv.dodgeFontSize))
        label:SetColor(1, 1, 1, 1)
        label:SetScale(1.8)
        label:SetAnchor(GetAnchor("dodge"))
        SetStyledLabelText(label, string.format("|c%sDODGE|r", MCT.sv.dodgedColor), eventCode)
        MCT:Animate(label, "dodge", key)
    elseif special == "stunned" then
        label:SetFont(MCT:GetCachedFTNFont(MCT.sv.stunFontSize))
        label:SetColor(1, 0, 0, 1)
        label:SetScale(1.8)
        label:SetAnchor(GetAnchor("stun"))
        SetStyledLabelText(label, string.format("|c%sSTUN|r", MCT.sv.ccColor), eventCode)
        MCT:Animate(label, "stun", key)
    elseif special == "feared" then
        label:SetFont(MCT:GetCachedFTNFont(MCT.sv.fearFontSize))
        label:SetColor(1, 0, 1, 1)
        label:SetScale(1.8)
        label:SetAnchor(GetAnchor("fear"))
        SetStyledLabelText(label, string.format("|c%sFEAR|r", MCT.sv.ccColor), eventCode)
        MCT:Animate(label, "fear", key)
    elseif special == "charmed" then
        label:SetFont(MCT:GetCachedFTNFont(MCT.sv.charmFontSize))
        label:SetColor(1, 0.6, 1, 1)
        label:SetScale(1.8)
        label:SetAnchor(GetAnchor("charm"))
        SetStyledLabelText(label, string.format("|c%sCHARM|r", MCT.sv.ccColor), eventCode)
        MCT:Animate(label, "charm", key)
    elseif special == "silenced" then
        label:SetFont(MCT:GetCachedFTNFont(MCT.sv.silenceFontSize))
        label:SetColor(0.6, 0.6, 1, 1)
        label:SetScale(1.8)
        label:SetAnchor(GetAnchor("silence"))
        SetStyledLabelText(label, string.format("|c%sSILENCE|r", MCT.sv.ccColor), eventCode)
        MCT:Animate(label, "silence", key)
    elseif special == "disoriented" then
        label:SetFont(MCT:GetCachedFTNFont(MCT.sv.disorientFontSize))
        label:SetColor(1, 0.6, 0.4, 1)
        label:SetScale(1.8)
        label:SetAnchor(GetAnchor("disorient"))
        SetStyledLabelText(label, string.format("|c%sDISORIENT|r", MCT.sv.ccColor), eventCode)
        MCT:Animate(label, "disorient", key)
    elseif special == "offbalanced" then
        label:SetFont(MCT:GetCachedFTNFont(MCT.sv.offbalanceFontSize))
        label:SetColor(0.4, 1, 0.8, 1)
        label:SetScale(1.8)
        label:SetAnchor(GetAnchor("offbalance"))
        SetStyledLabelText(label, string.format("|c%sOFFBALANCE|r", MCT.sv.ccColor), eventCode)
        MCT:Animate(label, "offbalance", key)
    
    elseif special == "shieldbreak" then
        label:SetFont(MCT:GetCachedFTNFont(MCT.sv.shieldbreakFontSize))
        label:SetColor(0.6, 0.8, 1, 1)
        label:SetScale(1.8)
        label:SetAnchor(GetAnchor("shieldbreak"))
        SetStyledLabelText(label, string.format("|c%s%s|r", MCT.sv.shieldbreakColor, value), eventCode)
        MCT:Animate(label, "shieldbreak", key)
    elseif special == "immobilized" then
        label:SetFont(MCT:GetCachedFTNFont(MCT.sv.offbalanceFontSize))
        label:SetColor(1, 0, 0, 1)
        label:SetScale(1.8)
        label:SetAnchor(GetAnchor("dodge"))
        SetStyledLabelText(label, string.format("|c%sIMMOBILIZED|r", MCT.sv.dodgedColor), eventCode)
        MCT:Animate(label, "dodge", key)
    else
        if isCrit then
            if isHeal then
                label:SetFont(MCT:GetCachedFTNFont(MCT.sv.healingFontSize))
                label:SetAnchor(GetAnchor("healing"))
                SetStyledLabelText(label, string.format("|c%s+%s!|r%s", MCT.sv.criticalHealingColor, FormatShortNumber(value), abilitySuffix), eventCode)
                MCT:Animate(label, "healingCrit", key)
            elseif not isHeal and isBlocked then
                label:SetAnchor(GetAnchor("damageTaken"))
                SetStyledLabelText(label, string.format("|c%sBLOCKED *%s*|r%s", MCT.sv.damageTakenCritColor, FormatShortNumber(value), abilitySuffix), eventCode)
                MCT:Animate(label, "damageTakenCrit", key)
            else
                label:SetAnchor(GetAnchor("damageTaken"))
                SetStyledLabelText(label, string.format("|c%s%s!|r%s", MCT.sv.damageTakenCritColor, FormatShortNumber(value), abilitySuffix), eventCode)
                MCT:Animate(label, "damageTakenCrit", key)
            end
        else
            if isHeal then
                label:SetFont(MCT:GetCachedFTNFont(MCT.sv.healingFontSize))
                label:SetAnchor(GetAnchor("healing"))
                SetStyledLabelText(label, string.format("|c%s+%s|r%s", MCT.sv.healingColor, FormatShortNumber(value), abilitySuffix), eventCode)
                MCT:Animate(label, "healing", key)

            elseif not isHeal and isBlocked then
                label:SetFont(MCT:GetCachedFTNFont(MCT.sv.damageFontSize))
                label:SetAnchor(GetAnchor("damageTaken"))
                SetStyledLabelText(label, string.format("|c%sBLOCKED *%s*|r%s", MCT.sv.damageTakenColor, FormatShortNumber(value), abilitySuffix), eventCode)
                MCT:Animate(label, "damageTaken", key)
            else
                label:SetFont(MCT:GetCachedFTNFont(MCT.sv.damageFontSize))
                label:SetAnchor(GetAnchor("damageTaken"))
                SetStyledLabelText(label, string.format("|c%s%s|r%s", MCT.sv.damageTakenColor, FormatShortNumber(value), abilitySuffix), eventCode)
                MCT:Animate(label, "damageTaken", key)
            end
        end
    end

elseif unitId ~= playerId and sID == playerId then
        -- Anchor to reticle if not self
        label:SetHidden(false)
    label:SetAlpha(1)

    if special == "dodged" then
        label:SetFont(MCT:GetCachedFTNFont(MCT.sv.dodgeFontSize))
        label:SetColor(1, 1, 1, 1)
        label:SetScale(1.8)
        label:SetAnchor(GetAnchor("dodge"))
        SetStyledLabelText(label, string.format("|c%sTARGET DODGE|r", MCT.sv.dodgedColor), eventCode)
        MCT:Animate(label, "dodge", key)
    elseif special == "burst" then
        label:SetFont(MCT:GetCachedZoCombatFont(MCT.sv.burstFontSize))
        label:SetColor(1, 0.6, 0.1, 1)
        label:SetScale(1.8)
        label:SetAnchor(GetAnchor("burst"))
        SetStyledLabelText(label, string.format("|c%s%s!|r", MCT.sv.burstColor, value), eventCode)
        MCT:Animate(label, "burst", key)
    elseif special == "stunned" then
        label:SetFont(MCT:GetCachedFTNFont(MCT.sv.offbalanceFontSize))
        label:SetColor(1, 0, 0, 1)
        label:SetScale(1.8)
        label:SetAnchor(GetAnchor("stun"))
        SetStyledLabelText(label, string.format("|c%sTARGET STUN|r", MCT.sv.ccColor), eventCode)
        MCT:Animate(label, "stun", key)
    elseif special == "dot" then
        label:SetFont(MCT:GetCachedFTNFont(MCT.sv.offbalanceFontSize))
        label:SetColor(0.8, 0.8, 0.8, 1)
        label:SetScale(1.8)
        label:SetAnchor(GetAnchor("dot"))
        if isCrit then
            SetStyledLabelText(label, string.format("|c%s%s!|r", MCT.sv.dotColor, value), eventCode)
            MCT:Animate(label, "dotCrit", key)
        else
            SetStyledLabelText(label, string.format("|c%s%s|r", MCT.sv.dotColor, value), eventCode)
            MCT:Animate(label, "dot", key)
        end
    elseif special == "immobilized" then
        label:SetFont(MCT:GetCachedFTNFont(MCT.sv.offbalanceFontSize))
        label:SetColor(1, 0, 0, 1)
        label:SetScale(1.8)
        label:SetAnchor(GetAnchor("dodge"))
        SetStyledLabelText(label, string.format("|c%sTARGET IMMOBILIZED|r", MCT.sv.dodgedColor), eventCode)
        MCT:Animate(label, "dodge", key)
    elseif special == "feared" then
        label:SetFont(MCT:GetCachedFTNFont(MCT.sv.offbalanceFontSize))
        label:SetColor(1, 0, 1, 1)
        label:SetScale(1.8)
        label:SetAnchor(GetAnchor("fear"))
        SetStyledLabelText(label, string.format("|c%sTARGET FEAR|r", MCT.sv.ccColor), eventCode)
        MCT:Animate(label, "fear", key)
    elseif special == "charmed" then
        label:SetFont(MCT:GetCachedFTNFont(MCT.sv.offbalanceFontSize))
        label:SetColor(1, 0.6, 1, 1)
        label:SetScale(1.8)
        label:SetAnchor(GetAnchor("charm"))
        SetStyledLabelText(label, string.format("|c%sTARGET CHARM|r", MCT.sv.ccColor), eventCode)
        MCT:Animate(label, "charm", key)
    elseif special == "silenced" then
        label:SetFont(MCT:GetCachedFTNFont(MCT.sv.offbalanceFontSize))
        label:SetColor(0.6, 0.6, 1, 1)
        label:SetScale(1.8)
        label:SetAnchor(GetAnchor("silence"))
        SetStyledLabelText(label, string.format("|c%sTARGET SILENCE|r", MCT.sv.ccColor), eventCode)
        MCT:Animate(label, "silence", key)
    elseif special == "disoriented" then
        label:SetFont(MCT:GetCachedFTNFont(MCT.sv.offbalanceFontSize))
        label:SetColor(1, 0.6, 0.4, 1)
        label:SetScale(1.8)
        label:SetAnchor(GetAnchor("disorient"))
        SetStyledLabelText(label, string.format("|c%sTARGET DISORIENT|r", MCT.sv.ccColor), eventCode)
        MCT:Animate(label, "disorient", key)
    elseif special == "offbalanced" then
        label:SetFont(MCT:GetCachedFTNFont(MCT.sv.offbalanceFontSize))
        label:SetColor(0.4, 1, 0.8, 1)
        label:SetScale(1.8)
        
        label:SetAnchor(GetAnchor("offbalance") )
        SetStyledLabelText(label, string.format("|c%sTARGET OFFBALANCE|r", MCT.sv.ccColor), eventCode)
        MCT:Animate(label, "offbalance", key)
    else
        if isHeal then
            label:SetColor(0.2, 1, 0.2, 1)
        else
            label:SetColor(1, 0.2, 0.2, 1)
        end
        label:SetScale(1.8)
        if isCrit then
            if isHeal then
                label:SetFont(MCT:GetCachedFTNFont(MCT.sv.healingFontSize))
                label:SetAnchor(GetAnchor("healing"))
                SetStyledLabelText(label, string.format("|c%s+%s!|r%s", MCT.sv.criticalHealingColor, FormatShortNumber(value), abilitySuffix), eventCode)
                MCT:Animate(label, "healingCrit", key)
            else
                label:SetFont(MCT:GetCachedFTNFont(MCT.sv.damageFontSize))
                label:SetAnchor(GetAnchor("damage"))
                SetStyledLabelText(label, string.format("|c%s%s!|r%s", MCT.sv.criticalColor, FormatShortNumber(value), abilitySuffix), eventCode)
                MCT:Animate(label, "damageCrit", key)
            end
        else
            if isHeal then
                label:SetFont(MCT:GetCachedFTNFont(MCT.sv.healingFontSize))
                label:SetAnchor(GetAnchor("healing"))
                SetStyledLabelText(label, string.format("|c%s+%s|r%s", MCT.sv.healingColor, FormatShortNumber(value), abilitySuffix), eventCode)
                MCT:Animate(label, "healing", key)
            elseif not isHeal and isBlocked then
                label:SetFont(MCT:GetCachedFTNFont(MCT.sv.damageFontSize))
                  label:SetAnchor(GetAnchor("damage"))
                SetStyledLabelText(label, string.format("|c%sBLOCKED *%s*|r%s", MCT.sv.damageColor, FormatShortNumber(value), abilitySuffix), eventCode)
                MCT:Animate(label, "damage", key)  
            else
                label:SetFont(MCT:GetCachedFTNFont(MCT.sv.damageFontSize))
                label:SetAnchor(GetAnchor("damage"))
                SetStyledLabelText(label, string.format("|c%s%s|r%s", MCT.sv.damageColor, FormatShortNumber(value), abilitySuffix), eventCode)
                MCT:Animate(label, "damage", key)
            end
        end
    end
elseif unitId == playerId and sID == playerId then
    label:SetHidden(false)
    label:SetAlpha(1)

    if isHeal then
            label:SetColor(0.2, 1, 0.2, 1)
        else
            label:SetColor(1, 0.2, 0.2, 1)
        end
        label:SetScale(1.8)
        if isCrit then
            if isHeal then
                label:SetFont(MCT:GetCachedFTNFont(MCT.sv.healingFontSize))
                label:SetAnchor(GetAnchor("healing"))
                SetStyledLabelText(label, string.format("|c%s+%s!|r%s", MCT.sv.criticalHealingColor, FormatShortNumber(value), abilitySuffix), eventCode)
                MCT:Animate(label, "healingCrit", key)
            else
                label:SetFont(MCT:GetCachedFTNFont(MCT.sv.damageFontSize))
                label:SetAnchor(GetAnchor("damage"))
                SetStyledLabelText(label, string.format("|c%s%s!|r%s", MCT.sv.criticalColor, FormatShortNumber(value), abilitySuffix), eventCode)
                MCT:Animate(label, "damageTakenCrit", key)
            end
        else
            if isHeal then
                label:SetFont(MCT:GetCachedFTNFont(MCT.sv.healingFontSize))
                label:SetAnchor(GetAnchor("healing"))
                SetStyledLabelText(label, string.format("|c%s+%s|r%s", MCT.sv.healingColor, FormatShortNumber(value), abilitySuffix), eventCode)
                MCT:Animate(label, "healing", key)
            else
                label:SetFont(MCT:GetCachedFTNFont(MCT.sv.damageFontSize))
                label:SetAnchor(GetAnchor("damage"))
                SetStyledLabelText(label, string.format("|c%s%s|r%s", MCT.sv.damageColor, FormatShortNumber(value), abilitySuffix), eventCode)
                MCT:Animate(label, "damageTaken", key)
            end
        end
else
    MCT.pool:ReleaseObject(key)   
end
end
-------------------------------------------------------
-- Tracking and combat pipeline moved to:
--   MyCombatText.Tracking.lua  (merge queue, burst, shieldbreak, DPS)
--   MyCombatText.Combat.lua    (event registration and parsing)
-- MCT:ShowText above dispatches to both after resolving the label.
-------------------------------------------------------

-- ---------------------------------------------------------------
-- MCT:InitSettingsPanel: builds and registers the LibAddonMenu-2.0
-- settings panel under "Better Combat Text". Called once from
-- MCT:Initialize. If LAM is missing the panel is silently skipped
-- and a chat warning is printed.
--
-- Panel sections:
--   Visual Presets  : quick-switch dropdown + reset button
--   General         : enable, pvpOnly, anchorToReticle
--   Animation       : duration, rise, jitter sliders
--   Font Sizes      : per-category font size sliders
--   Offsets         : per-category X/Y position sliders
--   Target Marker   : enable + auto-clear delay
--   Display         : per-category show/hide checkboxes
--   Spam control    : mergeWindowMs, maxFloatingLabels
--   Text colors     : per-category hex color editboxes
--   Reticle flash   : enable + duration
--   Burst           : enable + window/minHits/minDamage/minCrits
--   Shieldbreak     : enable + window/minDamage
--   Target markers  : marker type dropdowns per rule
--   DPS             : enable + window/minShow/showOnBurst
-- ---------------------------------------------------------------
function MCT:InitSettingsPanel()
    if not LibAddonMenu2 then
        d("[MCT] LibAddonMenu-2.0 missing (settings panel disabled)")
        return
    end

    local LAM = LibAddonMenu2

    local panelData = {
        type = "panel",
        name = "Better Combat Text",
        displayName = "Better Combat Text",
        author = "Vixen Hunny",
        version = "1.0",
        registerForRefresh = true,
        registerForDefaults = true,
    }

    local fontStyleLabels, fontStyleValues = MCT:GetCombatFontStyleChoices()

    local optionsData = {
        -- ========= Presets
        { type = "header", name = "Visual Presets" },
        {
            type = "description",
            text = "Quick-switch between 4 pre-configured visual styles. Each preset has its own colors, font sizes, and animations.",
        },
        {
            type = "dropdown",
            name = "Preset",
            tooltip = "LUI_ENHANCED: Vibrant colors & dramatic animations\nLUI_CLASSIC: Simpler LUI style\nMINIMAL: Minimal spam, critical info only\nDETAILED: Everything enabled",
            choices = {
                "LUI Enhanced (Recommended)",
                "LUI Classic",
                "Minimal",
                "Detailed",
            },
            choicesValues = {
                "LUI_ENHANCED",
                "LUI_CLASSIC",
                "MINIMAL",
                "DETAILED",
            },
            getFunc = function()
                return MCT.Presets.current or "LUI_ENHANCED"
            end,
            setFunc = function(v)
                MCT:ApplyPreset(v)
                MCT.Presets.current = v
            end,
            default = "LUI_ENHANCED",
        },
        {
            type = "button",
            name = "Reset to Preset Defaults",
            tooltip = "Reapply current preset to restore original settings",
            func = function()
                MCT:ApplyPreset(MCT.Presets.current or "LUI_ENHANCED")
                d("[MCT] Preset restored: " .. (MCT.Presets.current or "LUI_ENHANCED"))
            end,
        },

        -- ========= Global
        { type = "header", name = "General" },
        {
            type = "checkbox",
            name = "Enable",
            getFunc = function() return MCT.sv.enabled end,
            setFunc = function(v) MCT.sv.enabled = v end,
            default = MCT.defaults.enabled,
        },
        {
            type = "checkbox",
            name = "PvP only",
            tooltip = "Only run SCT/burst logic while you are PvP flagged.",
            getFunc = function() return MCT.sv.pvpOnly end,
            setFunc = function(v) MCT.sv.pvpOnly = v end,
            default = MCT.defaults.pvpOnly,
        },
        
        {
            type = "checkbox",
            name = "Anchor to reticle target",
            tooltip = "Positions combat text closer to reticle target when reticleover exists.",
            getFunc = function() return MCT.sv.anchorToReticle end,
            setFunc = function(v) MCT.sv.anchorToReticle = v end,
            default = MCT.defaults.anchorToReticle,
        },
        {
            type = "checkbox",
            name = "Console-friendly mode",
            tooltip = "When using gamepad preferred mode, this applies optional scale boosts for readability from couch distance.",
            getFunc = function() return MCT.sv.consoleFriendlyMode end,
            setFunc = function(v) MCT.sv.consoleFriendlyMode = v end,
            default = MCT.defaults.consoleFriendlyMode,
        },
        {
            type = "checkbox",
            name = "Show ability names",
            tooltip = "Adds ability names after numbers. Turning this off reduces CPU and allocations in heavy combat.",
            getFunc = function() return MCT.sv.showAbilityNames end,
            setFunc = function(v) MCT.sv.showAbilityNames = v end,
            default = MCT.defaults.showAbilityNames,
        },
        {
            type = "slider",
            name = "UI Scale",
            tooltip = "Scales all combat text and icons.",
            min = 50, max = 250, step = 5,
            getFunc = function() return math.floor((MCT.sv.uiScale or MCT.defaults.uiScale) * 100) end,
            setFunc = function(v) MCT.sv.uiScale = v / 100 end,
            default = math.floor((MCT.defaults.uiScale or 1) * 100),
        },
        {
            type = "slider",
            name = "Gamepad UI Scale Boost",
            tooltip = "Extra scale multiplier used only while gamepad preferred mode is active.",
            min = 100, max = 180, step = 5,
            getFunc = function() return math.floor((MCT.sv.gamepadUiScaleMultiplier or MCT.defaults.gamepadUiScaleMultiplier) * 100) end,
            setFunc = function(v) MCT.sv.gamepadUiScaleMultiplier = v / 100 end,
            default = math.floor((MCT.defaults.gamepadUiScaleMultiplier or 1.15) * 100),
            disabled = function() return not MCT.sv.consoleFriendlyMode end,
        },
        {
            type = "slider",
            name = "Global X offset",
            tooltip = "Moves all combat text anchors left/right together.",
            min = -1200, max = 1200, step = 10,
            getFunc = function() return MCT.sv.globalOffsetX or MCT.defaults.globalOffsetX end,
            setFunc = function(v) MCT.sv.globalOffsetX = v end,
            default = MCT.defaults.globalOffsetX,
        },
        {
            type = "slider",
            name = "Global Y offset",
            tooltip = "Moves all combat text anchors up/down together.",
            min = -1200, max = 1200, step = 10,
            getFunc = function() return MCT.sv.globalOffsetY or MCT.defaults.globalOffsetY end,
            setFunc = function(v) MCT.sv.globalOffsetY = v end,
            default = MCT.defaults.globalOffsetY,
        },

        -- ========= Animation Settings
        { type = "header", name = "Animation Settings" },
        {
            type = "description",
            text = "Customize how combat text animates. These values can be changed per-preset.",
        },
        {
            type = "slider",
            name = "Animation Duration (ms)",
            tooltip = "How long the animation plays (1200ms = LUI Enhanced, 700ms = Minimal)",
            min = 400, max = 2000, step = 50,
            getFunc = function() return MCT.sv.animDuration or 1200 end,
            setFunc = function(v) MCT.sv.animDuration = v end,
            default = 1200,
        },
        {
            type = "slider",
            name = "Animation Rise (px)",
            tooltip = "How far text moves upward (180px = dramatic, 100px = subtle)",
            min = 50, max = 300, step = 10,
            getFunc = function() return MCT.sv.animRise or 180 end,
            setFunc = function(v) MCT.sv.animRise = v end,
            default = 180,
        },
        {
            type = "slider",
            name = "Animation Jitter (px)",
            tooltip = "Horizontal scatter of text (100px = wide spread, 50px = tight)",
            min = 20, max = 150, step = 10,
            getFunc = function() return MCT.sv.animJitter or 100 end,
            setFunc = function(v) MCT.sv.animJitter = v end,
            default = 100,
        },
        {
            type = "slider",
            name = "Lane Queue Stagger (%)",
            tooltip = "How far a label must progress before the next one in the same lane can fire. Lower = tighter/faster, higher = more spacing.",
            min = 1, max = 20, step = 1,
            getFunc = function() return MCT.sv.laneQueueStaggerPercent or MCT.defaults.laneQueueStaggerPercent end,
            setFunc = function(v) MCT.sv.laneQueueStaggerPercent = v end,
            default = MCT.defaults.laneQueueStaggerPercent,
        },
        {
            type = "checkbox",
            name = "Descending lane animation",
            tooltip = "When enabled, combat numbers fall down the screen in left/right lanes (LUI style). When disabled (default), numbers float upward from their anchor — the classic ESO combat text style.",
            getFunc = function() return MCT.sv.luiAnimStyle end,
            setFunc = function(v) MCT.sv.luiAnimStyle = v end,
            default = MCT.defaults.luiAnimStyle,
        },

        { type = "header", name = "Combat Font Style" },
        {
            type = "dropdown",
            name = "Text Font Style",
            tooltip = "DEFAULT: Normal combat text\nHEARTS: Pink heart texture line above each label\nHEARTS_WHITE: White heart texture line above each label\nIMPERIAL: Clean bracketed serif style\nARCANE: Rune-flavored wrapper\nWARDRUM: Heavy framed style",
            choices = fontStyleLabels,
            choicesValues = fontStyleValues,
            getFunc = function()
                return MCT.sv.combatFontStyle or MCT.defaults.combatFontStyle
            end,
            setFunc = function(v)
                MCT.sv.combatFontStyle = v
            end,
            default = MCT.defaults.combatFontStyle,
        },
        {
            type = "checkbox",
            name = "Enable Heart Texture Overlay",
            tooltip = "When enabled, HEARTS and HEARTS_WHITE styles render the texture row above text. Disabled by default.",
            getFunc = function()
                return MCT.sv.enableHeartTextures == true
            end,
            setFunc = function(v)
                MCT.sv.enableHeartTextures = v and true or false
            end,
            default = MCT.defaults.enableHeartTextures,
        },
        {
            type = "slider",
            name = "Heart Count",
            tooltip = "How many heart textures are shown above each combat label when using HEARTS or HEARTS_WHITE style.",
            min = 1, max = 6, step = 1,
            getFunc = function()
                return MCT.sv.heartCount or MCT.defaults.heartCount
            end,
            setFunc = function(v)
                MCT.sv.heartCount = v
            end,
            default = MCT.defaults.heartCount,
            disabled = function()
                local style = MCT.sv.combatFontStyle or MCT.defaults.combatFontStyle
                local heartsEnabled = MCT.sv.enableHeartTextures == true
                return (style ~= "HEARTS" and style ~= "HEARTS_WHITE") or not heartsEnabled
            end,
        },

        { type = "header", name = "Font Sizes"

        },
        {
            type = "slider",
            name = "Global Font Multiplier",
            tooltip = "Scales all configured font sizes at once.",
            min = 50, max = 200, step = 5,
            getFunc = function() return math.floor((MCT.sv.fontSizeMultiplier or MCT.defaults.fontSizeMultiplier) * 100) end,
            setFunc = function(v) MCT.sv.fontSizeMultiplier = v / 100 end,
            default = math.floor((MCT.defaults.fontSizeMultiplier or 1) * 100),
        },
        {
            type = "slider",
            name = "Gamepad Font Boost",
            tooltip = "Extra font multiplier used only in gamepad preferred mode.",
            min = 100, max = 180, step = 5,
            getFunc = function() return math.floor((MCT.sv.gamepadFontMultiplier or MCT.defaults.gamepadFontMultiplier) * 100) end,
            setFunc = function(v) MCT.sv.gamepadFontMultiplier = v / 100 end,
            default = math.floor((MCT.defaults.gamepadFontMultiplier or 1.10) * 100),
            disabled = function() return not MCT.sv.consoleFriendlyMode end,
        },
        {
            type = "slider",
            name = "Dodge Font Size",
            min = 10, max = 100, step = 1,
            getFunc = function() return MCT.sv.dodgeFontSize end,
            setFunc = function(v) MCT.sv.dodgeFontSize = v end,
            default = MCT.defaults.dodgeFontSize,
        },
        {
            type = "slider",
            name = "Stun Font Size",
            min = 10, max = 100, step = 1,
            getFunc = function() return MCT.sv.stunFontSize end,
            setFunc = function(v) MCT.sv.stunFontSize = v end,
            default = MCT.defaults.stunFontSize,
        },
        {
            type = "slider",
            name = "Fear Font Size",
            min = 10, max = 100, step = 1,
            getFunc = function() return MCT.sv.fearFontSize end,
            setFunc = function(v) MCT.sv.fearFontSize = v end,
            default = MCT.defaults.fearFontSize,
        },
        {
            type = "slider",
            name = "Charm Font Size",
            min = 10, max = 100, step = 1,
            getFunc = function() return MCT.sv.charmFontSize end,
            setFunc = function(v) MCT.sv.charmFontSize = v end,
            default = MCT.defaults.charmFontSize,
        },
        {
            type = "slider",
            name = "Silence Font Size",
            min = 10, max = 100, step = 1,
            getFunc = function() return MCT.sv.silenceFontSize end,
            setFunc = function(v) MCT.sv.silenceFontSize = v end,
            default = MCT.defaults.silenceFontSize,
        },
        {
            type = "slider",
            name = "Disorient Font Size",
            min = 10, max = 100, step = 1,
            getFunc = function() return MCT.sv.disorientFontSize end,
            setFunc = function(v) MCT.sv.disorientFontSize = v end,
            default = MCT.defaults.disorientFontSize,
        },
        {
            type = "slider",
            name = "Offbalance Font Size",
            min = 10, max = 100, step = 1,
            getFunc = function() return MCT.sv.offbalanceFontSize end,
            setFunc = function(v) MCT.sv.offbalanceFontSize = v end,
            default = MCT.defaults.offbalanceFontSize,
        },
        {
            type = "slider",
            name = "DoT Font Size",
            min = 10, max = 100, step = 1,
            getFunc = function() return MCT.sv.dotFontSize end,
            setFunc = function(v) MCT.sv.dotFontSize = v end,
            default = MCT.defaults.dotFontSize,
        },
        {
            type = "slider",
            name = "Burst Font Size",
            min = 10, max = 100, step = 1,
            getFunc = function() return MCT.sv.burstFontSize end,
            setFunc = function(v) MCT.sv.burstFontSize = v end,
            default = MCT.defaults.burstFontSize,
        },
        {
            type = "slider",
            name = "Shieldbreak Font Size",
            min = 10, max = 100, step = 1,
            getFunc = function() return MCT.sv.shieldbreakFontSize end,
            setFunc = function(v) MCT.sv.shieldbreakFontSize = v end,
            default = MCT.defaults.shieldbreakFontSize,
        },
        {
            type = "slider",
            name = "Damage Font Size",
            min = 10, max = 100, step = 1,
            getFunc = function() return MCT.sv.damageFontSize end,
            setFunc = function(v) MCT.sv.damageFontSize = v end,
            default = MCT.defaults.damageFontSize,

        },
        {
            type = "slider",
            name = "Healing Font Size",
            min = 10, max = 100, step = 1,
            getFunc = function() return MCT.sv.healingFontSize end,
            setFunc = function(v) MCT.sv.healingFontSize = v end,
            default = MCT.defaults.healingFontSize,
        },
        {
            type = "slider",
            name = "Damage Taken Font Size",
            min = 10, max = 100, step = 1,
            getFunc = function() return MCT.sv.damageTakenFontSize end,
            setFunc = function(v) MCT.sv.damageTakenFontSize = v end,
            default = MCT.defaults.damageTakenFontSize,
        },
        {
            type = "slider",
            name = "Critical Damage Font Size",
            min = 10, max = 100, step = 1,
            getFunc = function() return MCT.sv.criticalFontSize end,
            setFunc = function(v) MCT.sv.criticalFontSize = v end,
            default = MCT.defaults.criticalFontSize,
        },
        {
            type = "slider",
            name = "Critical Healing Font Size",
            min = 10, max = 100, step = 1,
            getFunc = function() return MCT.sv.criticalHealingFontSize end,
            setFunc = function(v) MCT.sv.criticalHealingFontSize = v end,
            default = MCT.defaults.criticalHealingFontSize,
        },
        {
            type = "slider",
            name = "Resource Restore Font Size",
            min = 10, max = 100, step = 1,
            getFunc = function() return MCT.sv.resourceRestoreFontSize end,
            setFunc = function(v) MCT.sv.resourceRestoreFontSize = v end,
            default = MCT.defaults.resourceRestoreFontSize,
        },
        {
            type = "slider",
            name = "Overhealing Font Size",
            min = 10, max = 100, step = 1,
            getFunc = function() return MCT.sv.overhealingFontSize end,
            setFunc = function(v) MCT.sv.overhealingFontSize = v end,
            default = MCT.defaults.overhealingFontSize,
        },
        {
            type = "header", name = "Offsets",
        },
        {
            type = "slider",
            name = "Damage X offset",
            min = -800, max = 800, step = 10,
            getFunc = function() return MCT.sv.damagex end,
            setFunc = function(v) MCT.sv.damagex = v end,
            default = MCT.defaults.damagex,
        },
        {
            type = "slider",
            name = "Damage Y offset",
            min = -800, max = 800, step = 10,
            getFunc = function() return MCT.sv.damagey end,
            setFunc = function(v) MCT.sv.damagey = v end,
            default = MCT.defaults.damagey,
        },
        {
            type = "slider",
            name = "Healing X offset",
            min = -800, max = 800, step = 10,
            getFunc = function() return MCT.sv.healingx end,
            setFunc = function(v) MCT.sv.healingx = v end,
            default = MCT.defaults.healingx,
        },
        {
            type = "slider",
            name = "Healing Y offset",
            min = -800, max = 800, step = 10,
            getFunc = function() return MCT.sv.healingy end,
            setFunc = function(v) MCT.sv.healingy = v end,
            default = MCT.defaults.healingy,
        },
        {
            type = "slider",
            name = "Reticle target X offset",
            min = -800, max = 800, step = 10,
            getFunc = function() return MCT.sv.reticlex end,
            setFunc = function(v) MCT.sv.reticlex = v end,
            default = MCT.defaults.reticlex,
        },
        {
            type = "slider",
            name = "Reticle target Y offset",
            min = -800, max = 800, step = 10,
            getFunc = function() return MCT.sv.reticley end,
            setFunc = function(v) MCT.sv.reticley = v end,
            default = MCT.defaults.reticley,
        },
        {
            type = "slider",
            name = "Dodge X offset",
            tooltip = "Immobilize follows this offset",
            min = -800, max = 800, step = 10,
            getFunc = function() return MCT.sv.dodgex end,
            setFunc = function(v) MCT.sv.dodgex = v end,
            default = MCT.defaults.dodgex,
        },
        {
            type = "slider",
            name = "Dodge Y offset",
            tooltip = "Immobilize follows this offset",
            min = -800, max = 800, step = 10,
            getFunc = function() return MCT.sv.dodgey end,
            setFunc = function(v) MCT.sv.dodgey = v end,
            default = MCT.defaults.dodgey,
        },
        {
            type = "slider",
            name = "Crowd Control X offset",
            min = -800, max = 800, step = 10,
            getFunc = function() return MCT.sv.ccx end,
            setFunc = function(v) MCT.sv.ccx = v end,
            default = MCT.defaults.ccx,
        },
        {
            type = "slider",
            name = "Crowd Control Y offset",
            min = -800, max = 800, step = 10,
            getFunc = function() return MCT.sv.ccy end,
            setFunc = function(v) MCT.sv.ccy = v end,
            default = MCT.defaults.ccy,
        },
        {
            type = "slider",
            name = "Damage Taken X offset",
            min = -800, max = 800, step = 10,
            getFunc = function() return MCT.sv.damageTakenx end,
            setFunc = function(v) MCT.sv.damageTakenx = v end,
            default = MCT.defaults.damageTakenx,
        },
        {
            type = "slider",
            name = "Damage Taken Y offset",
            min = -800, max = 800, step = 10,
            getFunc = function() return MCT.sv.damageTakeny end,
            setFunc = function(v) MCT.sv.damageTakeny = v end,
            default = MCT.defaults.damageTakeny,

        },
        {
            type = "slider",
            name = "Burst X offset",
            min = -800, max = 800, step = 10,
            getFunc = function() return MCT.sv.burstx end,
            setFunc = function(v) MCT.sv.burstx = v end,
            default = MCT.defaults.burstx,
        },
        {
            type = "slider",
            name = "Burst Y offset",
            min = -800, max = 800, step = 10,
            getFunc = function() return MCT.sv.bursty end,
            setFunc = function(v) MCT.sv.bursty = v end,
            default = MCT.defaults.bursty,
        },
        {
            type = "slider",
            name = "Shieldbreak X offset",
            min = -800, max = 800, step = 10,
            getFunc = function() return MCT.sv.shieldbreakx end,
            setFunc = function(v) MCT.sv.shieldbreakx = v end,
            default = MCT.defaults.shieldbreakx,
        },
        {
            type = "slider",
            name = "Shieldbreak Y offset",
            min = -800, max = 800, step = 10,
            getFunc = function() return MCT.sv.shieldbreaky end,
            setFunc = function(v) MCT.sv.shieldbreaky = v end,
            default = MCT.defaults.shieldbreaky,

        },
        {
            type = "slider",
            name = "DoT X offset",
            min = -800, max = 800, step = 10,
            getFunc = function() return MCT.sv.dotx end,
            setFunc = function(v) MCT.sv.dotx = v end,
            default = MCT.defaults.dotx,
        },
        {
            type = "slider",
            name = "DoT Y offset",
            min = -800, max = 800, step = 10,
            getFunc = function() return MCT.sv.doty end,
            setFunc = function(v) MCT.sv.doty = v end,
            default = MCT.defaults.doty,
        },
        {
            type = "slider",
            name = "Resource Restore X offset",
            min = -800, max = 800, step = 10,
            getFunc = function() return MCT.sv.resourcex end,
            setFunc = function(v) MCT.sv.resourcex = v end,
            default = MCT.defaults.resourcex,
        },
        {
            type = "slider",
            name = "Resource Restore Y offset",
            min = -800, max = 800, step = 10,
            getFunc = function() return MCT.sv.resourcey end,
            setFunc = function(v) MCT.sv.resourcey = v end,
            default = MCT.defaults.resourcey,
        },

        -- ========= Target Marker
        { type = "header", name = "Target Marker" },

        {
            type = "checkbox",
            name = "Enable target marker",
            getFunc = function() return MCT.sv.markerEnabled end,
            setFunc = function(v) MCT.sv.markerEnabled = v end,
            default = MCT.defaults.markerEnabled,
        },
        {
            type = "slider",
            name = "Auto-clear delay (ms)",
            min = 1000, max = 10000, step = 500,
            getFunc = function() return MCT.sv.markerAutoClearMs end,
            setFunc = function(v) MCT.sv.markerAutoClearMs = v end,
            default = MCT.defaults.markerAutoClearMs,
        },
        -- ========= Display
        { type = "header", name = "Display" },

        {
            type = "checkbox",
            name = "Show damage",
            getFunc = function() return MCT.sv.showDamage end,
            setFunc = function(v) MCT.sv.showDamage = v end,
            default = MCT.defaults.showDamage,
        },
        {
            type = "checkbox",
            name = "Show healing",
            getFunc = function() return MCT.sv.showHealing end,
            setFunc = function(v) MCT.sv.showHealing = v end,
            default = MCT.defaults.showHealing,
        },
        {
            type = "checkbox", 
            name = "Show Dodged",
            getFunc = function() return MCT.sv.showDodged end,
            setFunc = function(v) MCT.sv.showDodged = v end,
            default = MCT.defaults.showDodged,
        },
        {
            type = "checkbox", 
            name = "Show Crowd Control",
            getFunc = function() return MCT.sv.showCC end,
            setFunc = function(v) MCT.sv.showCC = v end,
            default = MCT.defaults.showCC,
        
        },
        {
            type = "checkbox",
            name = "Show Damage Taken",
            getFunc = function() return MCT.sv.showDamageTaken end,
            setFunc = function(v) MCT.sv.showDamageTaken = v end,
            default = MCT.defaults.showDamageTaken,
        },
        {
            type = "checkbox",
            name = "Show DoT ticks",
            getFunc = function() return MCT.sv.showDots end,
            setFunc = function(v) MCT.sv.showDots = v end,
            default = MCT.defaults.showDots,
        },
        {
            type = "checkbox",
            name = "Show Resource Restore",
            tooltip = "Display notifications when you gain magicka, stamina, or health.",
            getFunc = function() return MCT.sv.showResourceRestore end,
            setFunc = function(v) MCT.sv.showResourceRestore = v end,
            default = MCT.defaults.showResourceRestore,
        },
        {
            type = "checkbox",
            name = "Show Overhealing",
            tooltip = "Display healing that exceeds the target's max health (wasted healing).",
            getFunc = function() return MCT.sv.showOverhealing end,
            setFunc = function(v) MCT.sv.showOverhealing = v end,
            default = MCT.defaults.showOverhealing,
        },
        {
            type = "checkbox",
            name = "Show Event Textures",
            tooltip = "Display icons/textures for different event types (requires restart).",
            getFunc = function() return MCT.sv.showEventTextures end,
            setFunc = function(v) MCT.sv.showEventTextures = v end,
            default = MCT.defaults.showEventTextures,
        },
        {
            type = "slider",
            name = "Max Event Icons",
            tooltip = "Maximum number of unique icons shown per merged label.",
            min = 1, max = 6, step = 1,
            getFunc = function() return MCT.sv.maxEventIcons or MCT.defaults.maxEventIcons end,
            setFunc = function(v) MCT.sv.maxEventIcons = v end,
            default = MCT.defaults.maxEventIcons,
            disabled = function() return not MCT.sv.showEventTextures end,
        },

        -- ========= Performance
        { type = "header", name = "Performance" },
        {
            type = "checkbox",
            name = "Enable Performance Mode",
            tooltip = "Aggressively reduces CPU/RAM during heavy combat by limiting icon work and tuning queue pacing.",
            getFunc = function() return MCT.sv.performanceMode end,
            setFunc = function(v) MCT.sv.performanceMode = v end,
            default = MCT.defaults.performanceMode,
        },
        {
            type = "slider",
            name = "Performance Max Icons",
            tooltip = "When performance mode is enabled, icon count per label is additionally capped to this value.",
            min = 1, max = 6, step = 1,
            getFunc = function() return MCT.sv.performanceMaxIcons or MCT.defaults.performanceMaxIcons end,
            setFunc = function(v) MCT.sv.performanceMaxIcons = v end,
            default = MCT.defaults.performanceMaxIcons,
            disabled = function() return not MCT.sv.performanceMode end,
        },
        {
            type = "slider",
            name = "Performance Lane Stagger (%)",
            tooltip = "Lower values start queued labels sooner in each lane while in performance mode.",
            min = 1, max = 20, step = 1,
            getFunc = function() return MCT.sv.performanceLaneStaggerPercent or MCT.defaults.performanceLaneStaggerPercent end,
            setFunc = function(v) MCT.sv.performanceLaneStaggerPercent = v end,
            default = MCT.defaults.performanceLaneStaggerPercent,
            disabled = function() return not MCT.sv.performanceMode end,
        },
        {
            type = "checkbox",
            name = "Auto-suppress textures at high event rate",
            tooltip = "Temporarily hides event textures when too many labels are shown per second.",
            getFunc = function() return MCT.sv.performanceDisableTexturesOnBurst end,
            setFunc = function(v) MCT.sv.performanceDisableTexturesOnBurst = v end,
            default = MCT.defaults.performanceDisableTexturesOnBurst,
            disabled = function() return not MCT.sv.performanceMode end,
        },
        {
            type = "slider",
            name = "Texture Suppression Threshold (events/sec)",
            tooltip = "If shown labels per second exceed this threshold, textures are suppressed for a short cooldown.",
            min = 10, max = 120, step = 1,
            getFunc = function() return MCT.sv.performanceTextureEventThreshold or MCT.defaults.performanceTextureEventThreshold end,
            setFunc = function(v) MCT.sv.performanceTextureEventThreshold = v end,
            default = MCT.defaults.performanceTextureEventThreshold,
            disabled = function() return (not MCT.sv.performanceMode) or (not MCT.sv.performanceDisableTexturesOnBurst) end,
        },
        {
            type = "slider",
            name = "Texture Suppression Cooldown (ms)",
            tooltip = "How long textures stay hidden after high load is detected.",
            min = 200, max = 5000, step = 100,
            getFunc = function() return MCT.sv.performanceTextureCooldownMs or MCT.defaults.performanceTextureCooldownMs end,
            setFunc = function(v) MCT.sv.performanceTextureCooldownMs = v end,
            default = MCT.defaults.performanceTextureCooldownMs,
            disabled = function() return (not MCT.sv.performanceMode) or (not MCT.sv.performanceDisableTexturesOnBurst) end,
        },

        {
            type = "checkbox",
            name = "Crits only",
            tooltip = "Only show events that are flagged as critical hits.",
            getFunc = function() return MCT.sv.critOnly end,
            setFunc = function(v) MCT.sv.critOnly = v end,
            default = MCT.defaults.critOnly,
        },

        -- ========= Spam control
        { type = "header", name = "Spam control" },

        {
            type = "slider",
            name = "Merge window (ms)",
            tooltip = "Hits inside this window merge into a single number (rolling combat text).",
            min = 50, max = 800, step = 25,
            getFunc = function() return MCT.sv.mergeWindowMs end,
            setFunc = function(v) MCT.sv.mergeWindowMs = v end,
            default = MCT.defaults.mergeWindowMs,
        },
        {
            type = "slider",
            name = "Max floating labels",
            tooltip = "Fixed rotation cap: 20 labels are reused in a loop.",
            min = 20, max = 20, step = 1,
            getFunc = function() return MCT.sv.maxFloatingLabels end,
            setFunc = function(v)
                MCT.sv.maxFloatingLabels = v
                if MCT.pool and MCT.pool.SetMaxLabels then
                    MCT.pool:SetMaxLabels(v)
                end
            end,
            default = MCT.defaults.maxFloatingLabels,
        },
        {type = "header", name = "Text colors", },

        {
            type = "editbox",
            name = "Burst Color",
            tooltip = "Burst Color",
            default = "ff9900",
            getFunc = function() return MCT.sv.burstColor end,
            setFunc = function(v) MCT.sv.burstColor = v end,
        },
        {
            type = "editbox",
            name = "Reticle Highlight Color",
            tooltip = "Reticle Highlight Color",
            default = "ffffff",
            getFunc = function() return MCT.sv.reticleHighlightColor end,
            setFunc = function(v) MCT.sv.reticleHighlightColor = v end,
        },
        {
            type = "editbox",
            name = "Shieldbreak Color",
            tooltip = "Shieldbreak Color",
            default = "99ccff",
            getFunc = function() return MCT.sv.shieldbreakColor end,
            setFunc = function(v) MCT.sv.shieldbreakColor = v end,
        },
        {
            type = "editbox",
            name = "Damage Color",
            tooltip = "Damage Color",
            default = "ff3333",
            getFunc = function() return MCT.sv.damageColor end,
            setFunc = function(v) MCT.sv.damageColor = v end,
        },
        {
            type = "editbox",
            name = "Healing Color",
            tooltip = "Healing Color",
            default = "33ff33",
            getFunc = function() return MCT.sv.healingColor end,
            setFunc = function(v) MCT.sv.healingColor = v end,
        },
        {
            type = "editbox",
            name = "Critical Color",
            tooltip = "Critical Color",
            default = "ffff00",
            getFunc = function() return MCT.sv.criticalColor end,
            setFunc = function(v) MCT.sv.criticalColor = v end,
        },
        {
            type = "editbox",
            name = "Critical Healing Color",
            tooltip = "Critical Healing Color",
            default = "66ff66",
            getFunc = function() return MCT.sv.criticalHealingColor end,
            setFunc = function(v) MCT.sv.criticalHealingColor = v end,
        },
        {
            type = "editbox",
            name = "Damage Taken Color",
            tooltip = "Damage Taken Color",
            default = "ff6666",
            getFunc = function() return MCT.sv.damageTakenColor end,
            setFunc = function(v) MCT.sv.damageTakenColor = v end,
        },
        {
            type = "editbox",
            name = "Dodged Color",
            tooltip = "Dodged Color",
            default = "cccccc",
            getFunc = function() return MCT.sv.dodgedColor end,
            setFunc = function(v) MCT.sv.dodgedColor = v end,
        },
        {
            type = "editbox",
            name = "Crowd Control Color",
            tooltip = "Crowd Control Color",
            default = "9999ff",
            getFunc = function() return MCT.sv.ccColor end,
            setFunc = function(v) MCT.sv.ccColor = v end,
        },
        {
            type = "editbox",
            name = "DoT Color",
            tooltip = "DoT Color",
            default = "ff66ff",
            getFunc = function() return MCT.sv.dotColor end,
            setFunc = function(v) MCT.sv.dotColor = v end,
        },
        {
            type = "editbox",
            name = "Resource Restore Color",
            tooltip = "Color for resource restoration (magicka, stamina, health) - hex code like '00ff88'",
            default = "00ff88",
            getFunc = function() return MCT.sv.resourceRestoreColor end,
            setFunc = function(v) MCT.sv.resourceRestoreColor = v end,
        },
        {
            type = "editbox",
            name = "Overhealing Color",
            tooltip = "Color for overhealing (wasted healing) - hex code like '88ddff'",
            default = "88ddff",
            getFunc = function() return MCT.sv.overhealingColor end,
            setFunc = function(v) MCT.sv.overhealingColor = v end,
        },
        -- ========= Reticle highlight
        { type = "header", name = "Reticle highlight" },

        {
            type = "checkbox",
            name = "Enable reticle flash",
            getFunc = function() return MCT.sv.reticleHighlightEnabled end,
            setFunc = function(v)
                MCT.sv.reticleHighlightEnabled = v
                if MCT.reticleFlash then
                    MCT.reticleFlash:SetAlpha(0)
                end
            end,
            default = MCT.defaults.reticleHighlightEnabled,
        },
        {
            type = "slider",
            name = "Reticle flash duration (ms)",
            min = 100, max = 2000, step = 50,
            getFunc = function() return MCT.sv.reticleHighlightMs end,
            setFunc = function(v) MCT.sv.reticleHighlightMs = v end,
            default = MCT.defaults.reticleHighlightMs,
            disabled = function() return not MCT.sv.reticleHighlightEnabled end,
        },

        -- ========= Burst
        { type = "header", name = "Burst detection" },

        {
            type = "checkbox",
            name = "Enable burst detection",
            getFunc = function() return MCT.sv.burstEnabled end,
            setFunc = function(v) MCT.sv.burstEnabled = v end,
            default = MCT.defaults.burstEnabled,
        },
        {
            type = "slider",
            name = "Burst window (ms)",
            min = 300, max = 2500, step = 50,
            getFunc = function() return MCT.sv.burstWindowMs end,
            setFunc = function(v) MCT.sv.burstWindowMs = v end,
            default = MCT.defaults.burstWindowMs,
            disabled = function() return not MCT.sv.burstEnabled end,
        },
        {
            type = "slider",
            name = "Burst min hits",
            min = 2, max = 10, step = 1,
            getFunc = function() return MCT.sv.burstMinHits end,
            setFunc = function(v) MCT.sv.burstMinHits = v end,
            default = MCT.defaults.burstMinHits,
            disabled = function() return not MCT.sv.burstEnabled end,
        },
        {
            type = "slider",
            name = "Burst min total damage",
            min = 1000, max = 60000, step = 500,
            getFunc = function() return MCT.sv.burstMinDamage end,
            setFunc = function(v) MCT.sv.burstMinDamage = v end,
            default = MCT.defaults.burstMinDamage,
            disabled = function() return not MCT.sv.burstEnabled end,
        },
        {
            type = "slider",
            name = "Burst min crits",
            min = 0, max = 10, step = 1,
            getFunc = function() return MCT.sv.burstMinCrits end,
            setFunc = function(v) MCT.sv.burstMinCrits = v end,
            default = MCT.defaults.burstMinCrits,
            disabled = function() return not MCT.sv.burstEnabled end,
        },

        -- ========= Shieldbreak
        { type = "header", name = "Shieldbreak" },

        {
            type = "checkbox",
            name = "Enable shieldbreak detection",
            getFunc = function() return MCT.sv.shieldbreakEnabled end,
            setFunc = function(v) MCT.sv.shieldbreakEnabled = v end,
            default = MCT.defaults.shieldbreakEnabled,
        },
        {
            type = "slider",
            name = "Shieldbreak window (ms)",
            tooltip = "If a shielded hit occurs, then shortly after you land a meaningful hit not shielded, fire SHATTER.",
            min = 200, max = 2500, step = 50,
            getFunc = function() return MCT.sv.shieldbreakWindowMs end,
            setFunc = function(v) MCT.sv.shieldbreakWindowMs = v end,
            default = MCT.defaults.shieldbreakWindowMs,
            disabled = function() return not MCT.sv.shieldbreakEnabled end,
        },
        {
            type = "slider",
            name = "Shieldbreak min damage",
            min = 0, max = 20000, step = 250,
            getFunc = function() return MCT.sv.shieldbreakMinDamage end,
            setFunc = function(v) MCT.sv.shieldbreakMinDamage = v end,
            default = MCT.defaults.shieldbreakMinDamage,
            disabled = function() return not MCT.sv.shieldbreakEnabled end,
        },

        -- ========= Markers
        { type = "header", name = "Target markers" },

        {
            type = "checkbox",
            name = "Enable marker system",
            tooltip = "Markers can only be applied to your current reticleover target (ESO limitation).",
            getFunc = function() return MCT.sv.markerEnabled end,
            setFunc = function(v)
                MCT.sv.markerEnabled = v
                if not v then
                    -- Clear any active marker
                    SetTargetMarker(TARGET_MARKER_TYPE_NONE)
                    MCT.activeMarker.unitId = nil
                    MCT.activeMarker.rule = nil
                end
            end,
            default = MCT.defaults.markerEnabled,
        },
        {
            type = "slider",
            name = "Marker auto-clear (ms)",
            min = 500, max = 15000, step = 250,
            getFunc = function() return MCT.sv.markerAutoClearMs end,
            setFunc = function(v) MCT.sv.markerAutoClearMs = v end,
            default = MCT.defaults.markerAutoClearMs,
            disabled = function() return not MCT.sv.markerEnabled end,
        },
        {
            type = "dropdown",
            name = "Burst marker",
            choices = { "Skull (8)", "Sword (7)", "Moon (5)", "Triangle (4)", "Star (2)", "Circle (3)", "Square (1)", "Oblivion (6)"},
            choicesValues = {
                TARGET_MARKER_TYPE_EIGHT,
                TARGET_MARKER_TYPE_SEVEN,
                TARGET_MARKER_TYPE_FIVE,
                TARGET_MARKER_TYPE_FOUR,
                TARGET_MARKER_TYPE_TWO,
                TARGET_MARKER_TYPE_THREE,
                TARGET_MARKER_TYPE_ONE,
                TARGET_MARKER_TYPE_SIX,
            },
            getFunc = function()
                -- read from priorityRules["burst"]
                for i = 1, #MCT.sv.priorityRules do
                    if MCT.sv.priorityRules[i].name == "burst" then
                        return MCT.sv.priorityRules[i].marker
                    end
                end
                return TARGET_MARKER_TYPE_EIGHT
            end,
            setFunc = function(v)
                for i = 1, #MCT.sv.priorityRules do
                    if MCT.sv.priorityRules[i].name == "burst" then
                        MCT.sv.priorityRules[i].marker = v
                        MCT:RefreshRuleCache()
                        return
                    end
                end
            end,
            disabled = function() return not MCT.sv.markerEnabled end,
        },
        {
            type = "dropdown",
            name = "Shieldbreak marker",
            choices = { "Skull (8)", "Sword (7)", "Moon (5)", "Triangle (4)", "Star (2)", "Circle (3)", "Square (1)", "Oblivion (6)"},
            choicesValues = {
                TARGET_MARKER_TYPE_EIGHT,
                TARGET_MARKER_TYPE_SEVEN,
                TARGET_MARKER_TYPE_FIVE,
                TARGET_MARKER_TYPE_FOUR,
                TARGET_MARKER_TYPE_TWO,
                TARGET_MARKER_TYPE_THREE,
                TARGET_MARKER_TYPE_ONE,
                TARGET_MARKER_TYPE_SIX,
            },
            getFunc = function()
                for i = 1, #MCT.sv.priorityRules do
                    if MCT.sv.priorityRules[i].name == "shieldbreak" then
                        return MCT.sv.priorityRules[i].marker
                    end
                end
                return TARGET_MARKER_TYPE_THREE
            end,
            setFunc = function(v)
                for i = 1, #MCT.sv.priorityRules do
                    if MCT.sv.priorityRules[i].name == "shieldbreak" then
                        MCT.sv.priorityRules[i].marker = v
                        MCT:RefreshRuleCache()
                        return
                    end
                end
            end,
            disabled = function() return not MCT.sv.markerEnabled end,
        },
        {
            type = "dropdown",
            name = "Pressure marker",
            tooltip = "Low priority marker applied while you are actively hitting reticle target (won't override burst/shieldbreak).",
            choices = { "Skull (8)", "Sword (7)", "Moon (5)", "Triangle (4)", "Star (2)", "Circle (3)", "Square (1)", "Oblivion (6)"},
            choicesValues = {
                TARGET_MARKER_TYPE_EIGHT,
                TARGET_MARKER_TYPE_SEVEN,
                TARGET_MARKER_TYPE_FIVE,
                TARGET_MARKER_TYPE_FOUR,
                TARGET_MARKER_TYPE_TWO,
                TARGET_MARKER_TYPE_THREE,
                TARGET_MARKER_TYPE_ONE,
                TARGET_MARKER_TYPE_SIX,
            },
            getFunc = function()
                for i = 1, #MCT.sv.priorityRules do
                    if MCT.sv.priorityRules[i].name == "pressure" then
                        return MCT.sv.priorityRules[i].marker
                    end
                end
                return TARGET_MARKER_TYPE_ONE
            end,
            setFunc = function(v)
                for i = 1, #MCT.sv.priorityRules do
                    if MCT.sv.priorityRules[i].name == "pressure" then
                        MCT.sv.priorityRules[i].marker = v
                        MCT:RefreshRuleCache()
                        return
                    end
                end
            end,
            disabled = function() return not MCT.sv.markerEnabled end,
        },

        -- ========= DPS
        { type = "header", name = "DPS tracking" },

        {
            type = "checkbox",
            name = "Enable DPS tracking",
            getFunc = function() return MCT.sv.dpsEnabled end,
            setFunc = function(v)
                MCT.sv.dpsEnabled = v
                if not v then MCT.dps = {} end
            end,
            default = MCT.defaults.dpsEnabled,
        },
        {
            type = "slider",
            name = "DPS window (seconds)",
            min = 2, max = 15, step = 1,
            getFunc = function() return MCT.sv.dpsWindowSec end,
            setFunc = function(v) MCT.sv.dpsWindowSec = v end,
            default = MCT.defaults.dpsWindowSec,
            disabled = function() return not MCT.sv.dpsEnabled end,
        },
        {
            type = "slider",
            name = "Minimum DPS to show",
            min = 0, max = 20000, step = 250,
            getFunc = function() return MCT.sv.dpsMinShow end,
            setFunc = function(v) MCT.sv.dpsMinShow = v end,
            default = MCT.defaults.dpsMinShow,
            disabled = function() return not MCT.sv.dpsEnabled end,
        },
        {
            type = "checkbox",
            name = "Show DPS on burst",
            getFunc = function() return MCT.sv.dpsShowOnBurst end,
            setFunc = function(v) MCT.sv.dpsShowOnBurst = v end,
            default = MCT.defaults.dpsShowOnBurst,
            disabled = function() return not MCT.sv.dpsEnabled end,
        },

        -- ========= CombatCloud parity: Combat State
        { type = "header", name = "Combat State" },
        {
            type = "checkbox",
            name = "Show Entered/Left Combat",
            tooltip = "Displays 'Entered Combat' and 'Left Combat' text like CombatCloud.",
            getFunc = function() return MCT.sv.showCombatState end,
            setFunc = function(v) MCT.sv.showCombatState = v end,
            default = MCT.defaults.showCombatState,
        },
        {
            type = "slider",
            name = "Combat State Font Size",
            min = 16, max = 80, step = 1,
            getFunc = function() return MCT.sv.combatStateFontSize end,
            setFunc = function(v) MCT.sv.combatStateFontSize = v end,
            default = MCT.defaults.combatStateFontSize,
            disabled = function() return not MCT.sv.showCombatState end,
        },

        -- ========= CombatCloud parity: Active Combat Tip Alerts
        { type = "header", name = "Alerts" },
        {
            type = "description",
            text = "Show floating alerts for active combat tips (block, exploit weakness, interrupt, dodge roll, cleanse DoT, execute threshold).",
        },
        {
            type = "checkbox",
            name = "Show Block Alert",
            getFunc = function() return MCT.sv.showAlertBlock end,
            setFunc = function(v) MCT.sv.showAlertBlock = v end,
            default = MCT.defaults.showAlertBlock,
        },
        {
            type = "checkbox",
            name = "Show Exploit Alert",
            getFunc = function() return MCT.sv.showAlertExploit end,
            setFunc = function(v) MCT.sv.showAlertExploit = v end,
            default = MCT.defaults.showAlertExploit,
        },
        {
            type = "checkbox",
            name = "Show Interrupt Alert",
            getFunc = function() return MCT.sv.showAlertInterrupt end,
            setFunc = function(v) MCT.sv.showAlertInterrupt = v end,
            default = MCT.defaults.showAlertInterrupt,
        },
        {
            type = "checkbox",
            name = "Show Dodge Alert",
            getFunc = function() return MCT.sv.showAlertDodge end,
            setFunc = function(v) MCT.sv.showAlertDodge = v end,
            default = MCT.defaults.showAlertDodge,
        },
        {
            type = "checkbox",
            name = "Show Cleanse Alert",
            tooltip = "Show CLEANSE! when a DoT lands on you (5 second cooldown).",
            getFunc = function() return MCT.sv.showAlertCleanse end,
            setFunc = function(v) MCT.sv.showAlertCleanse = v end,
            default = MCT.defaults.showAlertCleanse,
        },
        {
            type = "checkbox",
            name = "Show Execute Alert",
            tooltip = "Periodically shows EXECUTE! when the reticle target is at low health.",
            getFunc = function() return MCT.sv.showAlertExecute end,
            setFunc = function(v) MCT.sv.showAlertExecute = v end,
            default = MCT.defaults.showAlertExecute,
        },
        {
            type = "slider",
            name = "Execute Threshold (%)",
            min = 5, max = 50, step = 1,
            getFunc = function() return MCT.sv.executeThreshold end,
            setFunc = function(v) MCT.sv.executeThreshold = v end,
            default = MCT.defaults.executeThreshold,
            disabled = function() return not MCT.sv.showAlertExecute end,
        },
        {
            type = "slider",
            name = "Execute Frequency (sec)",
            tooltip = "Minimum seconds between execute alerts for the same target.",
            min = 2, max = 30, step = 1,
            getFunc = function() return MCT.sv.executeFrequency end,
            setFunc = function(v) MCT.sv.executeFrequency = v end,
            default = MCT.defaults.executeFrequency,
            disabled = function() return not MCT.sv.showAlertExecute end,
        },
        {
            type = "slider",
            name = "Alert Font Size",
            min = 20, max = 80, step = 1,
            getFunc = function() return MCT.sv.alertFontSize end,
            setFunc = function(v) MCT.sv.alertFontSize = v end,
            default = MCT.defaults.alertFontSize,
        },
        {
            type = "editbox",
            name = "Alert Color",
            getFunc = function() return MCT.sv.alertColor end,
            setFunc = function(v) MCT.sv.alertColor = v end,
            default = MCT.defaults.alertColor,
        },

        -- ========= CombatCloud parity: Points (XP/AP/CP)
        { type = "header", name = "Points (XP / AP / CP)" },
        {
            type = "checkbox",
            name = "Show Alliance Points",
            getFunc = function() return MCT.sv.showAlliancePoints end,
            setFunc = function(v) MCT.sv.showAlliancePoints = v end,
            default = MCT.defaults.showAlliancePoints,
        },
        {
            type = "checkbox",
            name = "Show Experience Points",
            getFunc = function() return MCT.sv.showExperiencePoints end,
            setFunc = function(v) MCT.sv.showExperiencePoints = v end,
            default = MCT.defaults.showExperiencePoints,
        },
        {
            type = "checkbox",
            name = "Show Champion Points",
            getFunc = function() return MCT.sv.showChampionPoints end,
            setFunc = function(v) MCT.sv.showChampionPoints = v end,
            default = MCT.defaults.showChampionPoints,
        },
        {
            type = "slider",
            name = "Points Font Size",
            min = 16, max = 60, step = 1,
            getFunc = function() return MCT.sv.pointsFontSize end,
            setFunc = function(v) MCT.sv.pointsFontSize = v end,
            default = MCT.defaults.pointsFontSize,
        },
        {
            type = "editbox",
            name = "Alliance Points Color",
            getFunc = function() return MCT.sv.alliancePointsColor end,
            setFunc = function(v) MCT.sv.alliancePointsColor = v end,
            default = MCT.defaults.alliancePointsColor,
        },
        {
            type = "editbox",
            name = "Experience Points Color",
            getFunc = function() return MCT.sv.experiencePointsColor end,
            setFunc = function(v) MCT.sv.experiencePointsColor = v end,
            default = MCT.defaults.experiencePointsColor,
        },
        {
            type = "editbox",
            name = "Champion Points Color",
            getFunc = function() return MCT.sv.championPointsColor end,
            setFunc = function(v) MCT.sv.championPointsColor = v end,
            default = MCT.defaults.championPointsColor,
        },

        -- ========= CombatCloud parity: Low Resource Warnings
        { type = "header", name = "Resource Warnings" },
        {
            type = "checkbox",
            name = "Show Low Health Warning",
            getFunc = function() return MCT.sv.showLowHealth end,
            setFunc = function(v) MCT.sv.showLowHealth = v end,
            default = MCT.defaults.showLowHealth,
        },
        {
            type = "checkbox",
            name = "Show Low Magicka Warning",
            getFunc = function() return MCT.sv.showLowMagicka end,
            setFunc = function(v) MCT.sv.showLowMagicka = v end,
            default = MCT.defaults.showLowMagicka,
        },
        {
            type = "checkbox",
            name = "Show Low Stamina Warning",
            getFunc = function() return MCT.sv.showLowStamina end,
            setFunc = function(v) MCT.sv.showLowStamina = v end,
            default = MCT.defaults.showLowStamina,
        },
        {
            type = "slider",
            name = "Health Threshold (%)",
            min = 5, max = 75, step = 1,
            getFunc = function() return MCT.sv.healthThreshold end,
            setFunc = function(v) MCT.sv.healthThreshold = v end,
            default = MCT.defaults.healthThreshold,
        },
        {
            type = "slider",
            name = "Magicka Threshold (%)",
            min = 5, max = 75, step = 1,
            getFunc = function() return MCT.sv.magickaThreshold end,
            setFunc = function(v) MCT.sv.magickaThreshold = v end,
            default = MCT.defaults.magickaThreshold,
        },
        {
            type = "slider",
            name = "Stamina Threshold (%)",
            min = 5, max = 75, step = 1,
            getFunc = function() return MCT.sv.staminaThreshold end,
            setFunc = function(v) MCT.sv.staminaThreshold = v end,
            default = MCT.defaults.staminaThreshold,
        },
        {
            type = "checkbox",
            name = "Show Ultimate Ready",
            getFunc = function() return MCT.sv.showUltimateReady end,
            setFunc = function(v) MCT.sv.showUltimateReady = v end,
            default = MCT.defaults.showUltimateReady,
        },
        {
            type = "checkbox",
            name = "Show Potion Ready",
            getFunc = function() return MCT.sv.showPotionReady end,
            setFunc = function(v) MCT.sv.showPotionReady = v end,
            default = MCT.defaults.showPotionReady,
        },
        {
            type = "checkbox",
            name = "Warning Sound",
            tooltip = "Play a sound when low-resource or ultimate-ready warnings fire.",
            getFunc = function() return MCT.sv.warningSoundEnabled end,
            setFunc = function(v) MCT.sv.warningSoundEnabled = v end,
            default = MCT.defaults.warningSoundEnabled,
        },
        {
            type = "slider",
            name = "Resource Warning Font Size",
            min = 20, max = 80, step = 1,
            getFunc = function() return MCT.sv.resourceWarningFontSize end,
            setFunc = function(v) MCT.sv.resourceWarningFontSize = v end,
            default = MCT.defaults.resourceWarningFontSize,
        },

        -- ========= CombatCloud parity: Mitigation Events
        { type = "header", name = "Mitigation Events" },
        {
            type = "description",
            text = "Show floating text when your outgoing attacks are mitigated by the target.",
        },
        {
            type = "checkbox",
            name = "Show Miss",
            getFunc = function() return MCT.sv.showMiss end,
            setFunc = function(v) MCT.sv.showMiss = v end,
            default = MCT.defaults.showMiss,
        },
        {
            type = "checkbox",
            name = "Show Immune",
            getFunc = function() return MCT.sv.showImmune end,
            setFunc = function(v) MCT.sv.showImmune = v end,
            default = MCT.defaults.showImmune,
        },
        {
            type = "checkbox",
            name = "Show Parried",
            getFunc = function() return MCT.sv.showParried end,
            setFunc = function(v) MCT.sv.showParried = v end,
            default = MCT.defaults.showParried,
        },
        {
            type = "checkbox",
            name = "Show Reflected",
            getFunc = function() return MCT.sv.showReflected end,
            setFunc = function(v) MCT.sv.showReflected = v end,
            default = MCT.defaults.showReflected,
        },
        {
            type = "slider",
            name = "Mitigation Font Size",
            min = 16, max = 60, step = 1,
            getFunc = function() return MCT.sv.mitigationFontSize end,
            setFunc = function(v) MCT.sv.mitigationFontSize = v end,
            default = MCT.defaults.mitigationFontSize,
        },

        -- ========= CombatCloud parity: Energize / Drain
        { type = "header", name = "Energize / Drain" },
        {
            type = "checkbox",
            name = "Show Energize",
            tooltip = "Show when an ability restores a resource on a target.",
            getFunc = function() return MCT.sv.showEnergize end,
            setFunc = function(v) MCT.sv.showEnergize = v end,
            default = MCT.defaults.showEnergize,
        },
        {
            type = "checkbox",
            name = "Show Drain",
            tooltip = "Show when an ability drains a resource from a target.",
            getFunc = function() return MCT.sv.showDrain end,
            setFunc = function(v) MCT.sv.showDrain = v end,
            default = MCT.defaults.showDrain,
        },
        {
            type = "slider",
            name = "Energize/Drain Font Size",
            min = 16, max = 60, step = 1,
            getFunc = function() return MCT.sv.energizeFontSize end,
            setFunc = function(v) MCT.sv.energizeFontSize = v end,
            default = MCT.defaults.energizeFontSize,
        },
    }

    LAM:RegisterAddonPanel("MCTPanel", panelData)
    LAM:RegisterOptionControls("MCTPanel", optionsData)
end

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
--   9. Register EVENT_PLAYER_COMBAT_STATE_CHANGED to clear all
--      tracking tables when leaving combat (memory hygiene).
-- ---------------------------------------------------------------
function MCT:Initialize()
    MCT.sv = ZO_SavedVars:NewAccountWide("MCT_Saved", 1, nil, MCT.defaults)
    
    -- Apply default LUI Enhanced preset if not yet configured
    if not MCT.sv.presetApplied then
        MCT:ApplyPreset("LUI_ENHANCED")
        MCT.sv.presetApplied = true
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

    -- Purge per-target tracking tables when leaving combat to prevent
    -- unbounded growth of the burstTargets, shields, dps, and merge tables.
    -- Also clears all visible floating labels so nothing lingers after a fight.
    EM:RegisterForEvent(MCT.name .. "Combat", EVENT_PLAYER_COMBAT_STATE_CHANGED, function(_, inCombat)
        if not inCombat then
            if MCT.pool and MCT.pool.ReleaseAllObjects then
                MCT.pool:ReleaseAllObjects()
            end
            MCT.burstTargets = {}
            MCT.shields      = {}
            MCT.dps          = {}
            MCT.merge        = {}
            MCT.mergeTimers  = {}
            MCT._laneQueues = { left = {}, right = {}, center = {} }
            MCT._laneQueueHeads = { left = 1, right = 1, center = 1 }
            MCT._laneQueueTails = { left = 0, right = 0, center = 0 }
            MCT._laneQueueScheduled = { left = false, right = false, center = false }
            MCT._laneNextOpenAt = { left = 0, right = 0, center = 0 }
            MCT._displayRateWindowStart = 0
            MCT._displayRateCount = 0
            MCT._eventTextureSuppressedUntil = 0
            MCT.lastPruneMs  = 0
        end
    end)
end

-- Bootstrap: wait for EVENT_ADD_ON_LOADED for this addon's name so that
-- SavedVariables are ready before Initialize() accesses them.
EM:RegisterForEvent(MCT.name, EVENT_ADD_ON_LOADED, function(_, addon)
    if addon == MCT.name then
        MCT:Initialize()
    end
end)
