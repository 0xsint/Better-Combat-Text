-- ============================================================
-- MyCombatText.Settings.lua
-- LibAddonMenu-2.0 settings panel.
--
-- Layout (top level stays short; everything else lives in
-- collapsible submenus so the panel is scannable):
--
--   Quick setup      : enable, preset, preview, reset
--   What to show     : which combat events produce text
--   Alerts & warnings: combat tips, execute, low resources, ready cues
--   Look & feel      : font style, scale, animation
--   Font sizes       : per-category text size
--   Colors           : color pickers for every label type
--   Positions        : global + per-category offsets (with preview)
--   Combat analysis  : burst, shieldbreak, DPS, reticle flash, markers
--   Performance      : merge window, label cap, heavy-combat throttling
--
-- Controls are built from small helpers (Check/Slider/Color/...) so
-- each setting is one line and always reads/writes MCT.sv[key] with
-- MCT.defaults[key] as its reset value.
-- ============================================================

MyCombatText = MyCombatText or {}
local MCT = MyCombatText

-- ---------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------
local function Merge(t, extra)
    if extra then
        for k, v in pairs(extra) do t[k] = v end
    end
    return t
end

-- Returns a `disabled` function that is true while any listed sv key is off.
local function Off(...)
    local keys = { ... }
    return function()
        for i = 1, #keys do
            if not MCT.sv[keys[i]] then return true end
        end
        return false
    end
end

local function Header(name) return { type = "header", name = name } end
local function Text(text, title) return { type = "description", text = text, title = title } end
local function Divider() return { type = "divider" } end
local function Submenu(name, tooltip, controls) return { type = "submenu", name = name, tooltip = tooltip, controls = controls } end

-- Checkbox bound to MCT.sv[key]. extra.onChange(v) runs after the write.
local function Check(key, name, tooltip, extra)
    local onChange = extra and extra.onChange
    if extra then extra.onChange = nil end
    return Merge({
        type = "checkbox",
        name = name,
        tooltip = tooltip,
        getFunc = function() return MCT.sv[key] and true or false end,
        setFunc = function(v)
            MCT.sv[key] = v
            if onChange then onChange(v) end
        end,
        default = MCT.defaults[key],
    }, extra)
end

-- Slider bound to MCT.sv[key].
local function Slider(key, name, min, max, step, tooltip, extra)
    local onChange = extra and extra.onChange
    if extra then extra.onChange = nil end
    return Merge({
        type = "slider",
        name = name,
        tooltip = tooltip,
        min = min, max = max, step = step,
        getFunc = function()
            local v = tonumber(MCT.sv[key]) or tonumber(MCT.defaults[key]) or min
            return math.max(min, math.min(max, v))
        end,
        setFunc = function(v)
            MCT.sv[key] = v
            if onChange then onChange(v) end
        end,
        default = MCT.defaults[key],
    }, extra)
end

-- Slider shown as a percentage but stored as a multiplier (1.15 <-> 115%).
local function Percent(key, name, min, max, step, tooltip, extra)
    return Merge({
        type = "slider",
        name = name,
        tooltip = tooltip,
        min = min, max = max, step = step,
        getFunc = function()
            local v = tonumber(MCT.sv[key]) or tonumber(MCT.defaults[key]) or 1
            return math.floor(v * 100 + 0.5)
        end,
        setFunc = function(v) MCT.sv[key] = v / 100 end,
        default = math.floor((tonumber(MCT.defaults[key]) or 1) * 100 + 0.5),
    }, extra)
end

local function FontSize(key, name, extra)
    return Slider(key, name, 10, 100, 1, nil, extra)
end

-- Hex "rrggbb" <-> 0..1 floats for LAM color pickers.
local function HexToRGB(hex)
    hex = tostring(hex or "ffffff")
    local r = tonumber(hex:sub(1, 2), 16) or 255
    local g = tonumber(hex:sub(3, 4), 16) or 255
    local b = tonumber(hex:sub(5, 6), 16) or 255
    return r / 255, g / 255, b / 255
end

local function RGBToHex(r, g, b)
    local function c(x) return math.max(0, math.min(255, math.floor(x * 255 + 0.5))) end
    return string.format("%02x%02x%02x", c(r), c(g), c(b))
end
MCT.HexToRGB = HexToRGB

local function Color(key, name, tooltip, extra)
    local dr, dg, db = HexToRGB(MCT.defaults[key])
    return Merge({
        type = "colorpicker",
        name = name,
        tooltip = tooltip,
        getFunc = function()
            local r, g, b = HexToRGB(MCT.sv[key] or MCT.defaults[key])
            return r, g, b, 1
        end,
        setFunc = function(r, g, b) MCT.sv[key] = RGBToHex(r, g, b) end,
        default = { r = dr, g = dg, b = db, a = 1 },
    }, extra)
end

-- Appends every item of each list argument to `into` (lets one helper
-- contribute several controls to a submenu without Lua's "only the last
-- call in a table constructor expands" pitfall).
local function Append(into, ...)
    for i = 1, select("#", ...) do
        local list = select(i, ...)
        for j = 1, #list do into[#into + 1] = list[j] end
    end
    return into
end

local function OffsetPair(prefix, label)
    return {
        Slider(prefix .. "x", label .. " X", -800, 800, 10),
        Slider(prefix .. "y", label .. " Y", -800, 800, 10),
    }
end

local function Button(name, func, tooltip, extra)
    return Merge({ type = "button", name = name, func = func, tooltip = tooltip, width = "half" }, extra)
end

-- ---------------------------------------------------------------
-- Preview: fires one of each common label so changes to fonts,
-- colors, positions and animation can be checked out of combat.
-- ---------------------------------------------------------------
local PREVIEW_TARGET = "mct-preview-target"

function MCT:ShowPreview()
    if not MCT.pool or not MCT.sv then return end
    if not MCT.sv.enabled then
        d("[MCT] Combat text is disabled — enable it to see the preview.")
        return
    end
    local me = MCT._playerUnitId
    if me == nil then
        me = "mct-preview-player"
        MCT._playerUnitId = me
    end
    MCT:ShowText(4321, false, false, "", me, PREVIEW_TARGET, false)
    MCT:ShowText(12873, true, false, "", me, PREVIEW_TARGET, false)
    MCT:ShowText(2650, false, true, "", me, me, false)
    MCT:ShowText(1980, false, false, "", PREVIEW_TARGET, me, false)
    MCT:ShowText(nil, false, false, "stunned", me, PREVIEW_TARGET, false)
    MCT:ShowText(38200, true, false, "burst", me, PREVIEW_TARGET, false)
    MCT:ShowNotification(MCT:ColorTextCached(MCT.sv.alertColor, "BLOCK!"), "alert", MCT.sv.alertFontSize)
end

function MCT:RefreshSettingsPanel()
    if MCT.settingsPanel and CALLBACK_MANAGER then
        CALLBACK_MANAGER:FireCallbacks("LAM-RefreshPanel", MCT.settingsPanel)
    end
end

function MCT:OpenSettings()
    local LAM = LibAddonMenu2
    if LAM and MCT.settingsPanel then
        LAM:OpenToPanel(MCT.settingsPanel)
    else
        d("[MCT] Settings need LibAddonMenu-2.0.")
    end
end

-- ---------------------------------------------------------------
-- Target marker dropdowns (rules live in MCT.sv.priorityRules).
-- ---------------------------------------------------------------
local MARKER_CHOICES = { "Skull", "Sword", "Moon", "Triangle", "Star", "Circle", "Square", "Oblivion" }

local function MarkerChoiceValues()
    return {
        TARGET_MARKER_TYPE_EIGHT, TARGET_MARKER_TYPE_SEVEN, TARGET_MARKER_TYPE_FIVE, TARGET_MARKER_TYPE_FOUR,
        TARGET_MARKER_TYPE_TWO, TARGET_MARKER_TYPE_THREE, TARGET_MARKER_TYPE_ONE, TARGET_MARKER_TYPE_SIX,
    }
end

local function FindRule(ruleName)
    local rules = MCT.sv.priorityRules or {}
    for i = 1, #rules do
        if rules[i].name == ruleName then return rules[i] end
    end
end

local function MarkerDropdown(ruleName, name, fallback, tooltip)
    return {
        type = "dropdown",
        name = name,
        tooltip = tooltip,
        choices = MARKER_CHOICES,
        choicesValues = MarkerChoiceValues(),
        getFunc = function()
            local rule = FindRule(ruleName)
            return rule and rule.marker or fallback
        end,
        setFunc = function(v)
            local rule = FindRule(ruleName)
            if rule then
                rule.marker = v
                MCT:RefreshRuleCache()
            end
        end,
        disabled = Off("markerEnabled"),
    }
end

-- ---------------------------------------------------------------
-- MCT:InitSettingsPanel
-- ---------------------------------------------------------------
function MCT:InitSettingsPanel()
    local LAM = LibAddonMenu2
    if not LAM then
        d("[MCT] LibAddonMenu-2.0 missing (settings panel disabled)")
        return
    end

    local panelData = {
        type = "panel",
        name = "Better Combat Text",
        displayName = "|cff00ccBetter Combat Text|r",
        author = "Vixen Hunny",
        version = "1.2",
        slashCommand = "/bctsettings",
        registerForRefresh = true,
        registerForDefaults = true,
    }

    local fontStyleLabels, fontStyleValues = MCT:GetCombatFontStyleChoices()
    local notHearts = function()
        local style = MCT.sv.combatFontStyle or MCT.defaults.combatFontStyle
        return (style ~= "HEARTS" and style ~= "HEARTS_WHITE") or not MCT.sv.enableHeartTextures
    end
    local notConsole = Off("consoleFriendlyMode")

    local options = {
        -- ================= Quick setup =================
        Text("Floating combat text for damage, healing, crowd control and combat alerts. "
            .. "Pick a preset to start, then fine-tune anything below. "
            .. "Use |cffcc00Preview|r to see your changes without entering combat."),
        Check("enabled", "Enable combat text", "Master switch. When off, no combat text is shown."),
        {
            type = "dropdown",
            name = "Preset",
            tooltip = "Applying a preset overwrites colors, sizes, animation and which events are shown.\n\n"
                .. "LUI Enhanced: vibrant and dramatic (recommended)\n"
                .. "LUI Classic: calmer LUI look\n"
                .. "Minimal: only the essentials\n"
                .. "Detailed: everything on\n"
                .. "Sweetheart: pastel, handwritten and bouncy, with hearts and sparkles",
            choices = { "LUI Enhanced", "LUI Classic", "Minimal", "Detailed", "Sweetheart (cute)" },
            choicesValues = { "LUI_ENHANCED", "LUI_CLASSIC", "MINIMAL", "DETAILED", "SWEETHEART" },
            getFunc = function() return MCT.Presets.current or "LUI_ENHANCED" end,
            setFunc = function(v) MCT:ApplyPreset(v) end,
            warning = "Replaces your current customizations.",
            default = "LUI_ENHANCED",
        },
        Button("Preview", function() MCT:ShowPreview() end,
            "Shows sample damage, crit, heal, damage taken, stun, burst and alert labels."),
        Button("Reset to preset", function()
            MCT:ApplyPreset(MCT.Presets.current or "LUI_ENHANCED")
            MCT:RefreshSettingsPanel()
        end, "Re-applies the selected preset, discarding your changes to it.",
            { warning = "Discards your changes to the current preset." }),

        -- ================= What to show =================
        Submenu("What to show", "Choose which combat events produce floating text.", {
            Header("Damage & healing"),
            Check("showDamage", "Damage dealt"),
            Check("showDots", "Damage-over-time ticks", nil, { disabled = Off("showDamage") }),
            Check("showDamageTaken", "Damage taken"),
            Check("showHealing", "Healing"),
            Check("showOverhealing", "Overhealing", "Healing beyond the target's max health.", { disabled = Off("showHealing") }),
            Check("critOnly", "Critical hits only", "Hide every non-critical damage and healing number."),
            Check("showAbilityNames", "Ability names", "Adds the ability name after each number."),
            Check("showEventTextures", "Ability icons", "Shows the ability's icon next to its number."),
            Slider("maxEventIcons", "Max icons per label", 1, 6, 1,
                "When several abilities merge into one number, show up to this many icons.",
                { disabled = Off("showEventTextures") }),

            Header("Crowd control & avoidance"),
            Check("showDodges", "Dodges"),
            Check("showStuns", "Stuns"),
            Check("showFears", "Fears"),
            Check("showCharms", "Charms"),
            Check("showSilences", "Silences"),
            Check("showDisorients", "Disorients"),
            Check("showOffbalances", "Off-balance"),
            Check("showImmobilizes", "Roots / immobilize"),

            Header("Mitigated attacks"),
            Text("Shown when your attack doesn't land."),
            Check("showMiss", "Miss"),
            Check("showImmune", "Immune"),
            Check("showParried", "Parried"),
            Check("showReflected", "Reflected"),

            Header("Resources & progression"),
            Check("showResourceRestore", "Magicka / Stamina restores", "Gains of 50+ Magicka or Stamina."),
            Check("showEnergize", "Energize (your abilities restoring resources)"),
            Check("showDrain", "Drain (your abilities draining resources)"),
            Check("showCombatState", "Entered / Left combat"),
            Check("showExperiencePoints", "Experience (XP)"),
            Check("showChampionPoints", "Champion points (CP)"),
            Check("showAlliancePoints", "Alliance points (AP)"),
        }),

        -- ================= Alerts & warnings =================
        Submenu("Alerts & warnings", "Large center-screen cues for things that need your reaction.", {
            Header("Combat tips"),
            Check("showAlertBlock", "BLOCK!"),
            Check("showAlertExploit", "EXPLOIT!"),
            Check("showAlertInterrupt", "INTERRUPT!"),
            Check("showAlertDodge", "DODGE!"),
            Check("showAlertCleanse", "CLEANSE!", "When a damage-over-time effect lands on you (at most every 5s)."),

            Header("Execute"),
            Check("showAlertExecute", "EXECUTE! on low-health target", "Fires when your reticle target drops below the threshold."),
            Slider("executeThreshold", "Execute threshold (%)", 5, 50, 1, nil, { disabled = Off("showAlertExecute") }),
            Slider("executeFrequency", "Repeat every (seconds)", 2, 30, 1,
                "Minimum time between execute alerts for the same target.", { disabled = Off("showAlertExecute") }),

            Header("Low resources"),
            Check("showLowHealth", "Low health"),
            Slider("healthThreshold", "Health below (%)", 5, 75, 1, nil, { disabled = Off("showLowHealth") }),
            Check("showLowMagicka", "Low magicka"),
            Slider("magickaThreshold", "Magicka below (%)", 5, 75, 1, nil, { disabled = Off("showLowMagicka") }),
            Check("showLowStamina", "Low stamina"),
            Slider("staminaThreshold", "Stamina below (%)", 5, 75, 1, nil, { disabled = Off("showLowStamina") }),

            Header("Ready cues"),
            Check("showUltimateReady", "Ultimate ready"),
            Check("showPotionReady", "Potion ready"),
            Check("warningSoundEnabled", "Play a sound", "Sound for low-resource, ultimate-ready and potion-ready cues."),
        }),

        -- ================= Look & feel =================
        Submenu("Look & feel", "Text style, overall size and animation.", {
            Header("Style"),
            {
                type = "dropdown",
                name = "Text style",
                tooltip = "Default: plain combat text\nSweetheart: handwritten text framed by glossy hearts and sparkles, softer wording\n"
                    .. "Hearts / Hearts (White): heart row above each label\n"
                    .. "Imperial: [ bracketed ]\nArcane: rune wrapper\nWar Drum: << heavy frame >>",
                choices = fontStyleLabels,
                choicesValues = fontStyleValues,
                getFunc = function() return MCT.sv.combatFontStyle or MCT.defaults.combatFontStyle end,
                setFunc = function(v) MCT.sv.combatFontStyle = v end,
                default = MCT.defaults.combatFontStyle,
            },
            Check("enableHeartTextures", "Show heart row", "Only used by the Hearts styles."),
            Slider("heartCount", "Hearts per label", 1, 6, 1, nil, { disabled = notHearts }),

            Header("Size"),
            Percent("uiScale", "Overall scale (%)", 50, 250, 5, "Scales all combat text and icons."),
            Percent("fontSizeMultiplier", "Font size multiplier (%)", 50, 200, 5, "Scales every font size below at once."),
            Check("consoleFriendlyMode", "Gamepad boost", "Extra size while gamepad mode is active, for couch distance."),
            Percent("gamepadUiScaleMultiplier", "Gamepad scale boost (%)", 100, 180, 5, nil, { disabled = notConsole }),
            Percent("gamepadFontMultiplier", "Gamepad font boost (%)", 100, 180, 5, nil, { disabled = notConsole }),

            Header("Animation"),
            Check("popAnimation", "Bouncy pop",
                "Labels squish in, bounce slightly too big, then settle. Crits bounce harder. (Floating mode only.)",
                { disabled = function() return MCT.sv.luiAnimStyle == true end }),
            Check("luiAnimStyle", "Falling lanes",
                "On: numbers fall down left/right lanes (LUI style).\nOff: numbers float upward from their position."),
            Slider("animDuration", "Duration (ms)", 400, 2000, 50, "How long each label stays on screen."),
            Slider("animRise", "Rise distance (px)", 50, 300, 10, "How far floating text travels upward."),
            Slider("animJitter", "Sideways scatter (px)", 20, 150, 10, "Random horizontal spread so labels don't stack."),
            Slider("laneQueueStaggerPercent", "Spacing between labels (%)", 1, 20, 1,
                "How far a label travels before the next one in the same lane starts."),
        }),

        -- ================= Font sizes =================
        Submenu("Font sizes", "Text size per label type (before the multipliers in Look & feel).", {
            Header("Numbers"),
            FontSize("damageFontSize", "Damage dealt"),
            FontSize("damageTakenFontSize", "Damage taken"),
            FontSize("healingFontSize", "Healing"),
            FontSize("overhealingFontSize", "Overhealing"),
            FontSize("dotFontSize", "Damage over time"),
            FontSize("burstFontSize", "Burst"),
            FontSize("shieldbreakFontSize", "Shield break"),
            FontSize("resourceRestoreFontSize", "Resource restore"),
            Header("Crowd control"),
            FontSize("dodgeFontSize", "Dodge"),
            FontSize("stunFontSize", "Stun"),
            FontSize("fearFontSize", "Fear"),
            FontSize("charmFontSize", "Charm"),
            FontSize("silenceFontSize", "Silence"),
            FontSize("disorientFontSize", "Disorient"),
            FontSize("offbalanceFontSize", "Off-balance (and CC you apply)"),
            Header("Notifications"),
            FontSize("alertFontSize", "Alerts"),
            FontSize("resourceWarningFontSize", "Warnings & ready cues"),
            FontSize("combatStateFontSize", "Entered / Left combat"),
            FontSize("mitigationFontSize", "Miss / Immune / Parried / Reflected"),
            FontSize("energizeFontSize", "Energize / Drain"),
            FontSize("pointsFontSize", "XP / CP / AP"),
        }),

        -- ================= Colors =================
        Submenu("Colors", "Color of each label type.", {
            Header("Damage dealt"),
            Color("damageColor", "Damage"),
            Color("criticalColor", "Critical damage"),
            Color("dotColor", "Damage over time"),
            Color("burstColor", "Burst"),
            Color("shieldbreakColor", "Shield break"),
            Header("Damage taken"),
            Color("damageTakenColor", "Damage taken"),
            Color("damageTakenCritColor", "Critical damage taken"),
            Header("Healing & resources"),
            Color("healingColor", "Healing"),
            Color("criticalHealingColor", "Critical healing"),
            Color("overhealingColor", "Overhealing"),
            Color("resourceRestoreColor", "Resource restore"),
            Color("energizeColor", "Energize"),
            Color("drainColor", "Drain"),
            Header("Crowd control & mitigation"),
            Color("ccColor", "Crowd control"),
            Color("dodgedColor", "Dodge / root"),
            Color("missColor", "Miss"),
            Color("immuneColor", "Immune"),
            Color("parriedColor", "Parried"),
            Color("reflectedColor", "Reflected"),
            Header("Alerts & notifications"),
            Color("alertColor", "Alerts"),
            Color("lowHealthColor", "Low health"),
            Color("lowMagickaColor", "Low magicka"),
            Color("lowStaminaColor", "Low stamina"),
            Color("ultimateReadyColor", "Ultimate ready"),
            Color("potionReadyColor", "Potion ready"),
            Color("combatStateColor", "Entered / Left combat"),
            Color("experiencePointsColor", "Experience"),
            Color("championPointsColor", "Champion points"),
            Color("alliancePointsColor", "Alliance points"),
            Color("reticleHighlightColor", "Reticle flash"),
        }),

        -- ================= Positions =================
        Submenu("Positions", "Where each label type appears, in pixels from screen center.", Append({
            Text("Positive X moves right, positive Y moves down. Press Preview after moving things."),
            Button("Preview", function() MCT:ShowPreview() end),
            Header("Everything"),
            Slider("globalOffsetX", "Shift all X", -1200, 1200, 10),
            Slider("globalOffsetY", "Shift all Y", -1200, 1200, 10),
            Check("anchorToReticle", "Follow reticle target", "While you have a target, place labels near it instead."),
            Slider("reticlex", "Reticle offset X", -800, 800, 10, nil, { disabled = Off("anchorToReticle") }),
            Slider("reticley", "Reticle offset Y", -800, 800, 10, nil, { disabled = Off("anchorToReticle") }),
            Header("Per label type"),
            Text("Used by the falling-lanes animation, and as anchor points for floating text."),
        },
            OffsetPair("damage", "Damage dealt"),
            OffsetPair("damageTaken", "Damage taken"),
            OffsetPair("healing", "Healing"),
            OffsetPair("dot", "Damage over time"),
            OffsetPair("burst", "Burst"),
            OffsetPair("shieldbreak", "Shield break"),
            OffsetPair("resource", "Resource restore"),
            OffsetPair("dodge", "Dodge / root"),
            OffsetPair("cc", "Crowd control & alerts"))),

        -- ================= Combat analysis =================
        Submenu("Combat analysis", "Burst / shield-break detection, DPS readout and target markers.", {
            Header("Burst"),
            Text("Shows a big total when you land a quick combo on one target."),
            Check("burstEnabled", "Detect bursts"),
            Slider("burstWindowMs", "Combo window (ms)", 300, 2500, 50, nil, { disabled = Off("burstEnabled") }),
            Slider("burstMinHits", "Minimum hits", 2, 10, 1, nil, { disabled = Off("burstEnabled") }),
            Slider("burstMinDamage", "Minimum total damage", 1000, 60000, 500, nil, { disabled = Off("burstEnabled") }),
            Slider("burstMinCrits", "Minimum crits", 0, 10, 1, nil, { disabled = Off("burstEnabled") }),

            Header("Shield break"),
            Text("Shows SHATTER when you break through a target's damage shield."),
            Check("shieldbreakEnabled", "Detect shield breaks"),
            Slider("shieldbreakWindowMs", "Window (ms)", 200, 2500, 50, nil, { disabled = Off("shieldbreakEnabled") }),
            Slider("shieldbreakMinDamage", "Minimum hit", 0, 20000, 250, nil, { disabled = Off("shieldbreakEnabled") }),

            Header("Reticle flash"),
            Check("reticleHighlightEnabled", "Flash reticle on burst", nil, {
                onChange = function() if MCT.reticleFlash then MCT.reticleFlash:SetAlpha(0) end end,
            }),
            Slider("reticleHighlightMs", "Flash duration (ms)", 100, 2000, 50, nil, { disabled = Off("reticleHighlightEnabled") }),

            Header("DPS"),
            Check("dpsEnabled", "Track DPS", nil, { onChange = function(v) if not v then MCT.dps = {} end end }),
            Check("dpsShowOnBurst", "Show DPS with burst", nil, { disabled = Off("dpsEnabled") }),
            Slider("dpsWindowSec", "Averaging window (s)", 2, 15, 1, nil, { disabled = Off("dpsEnabled") }),
            Slider("dpsMinShow", "Only show above", 0, 20000, 250, nil, { disabled = Off("dpsEnabled") }),

            Header("Target markers"),
            Text("Marks your reticle target in PvP. ESO only allows marking the target under your reticle."),
            Check("markerEnabled", "Use target markers", nil, {
                onChange = function(v)
                    if not v and MCT.activeMarker and MCT.activeMarker.unitId then
                        AssignTargetMarkerToReticleTarget(TARGET_MARKER_TYPE_NONE)
                        MCT.activeMarker.unitId = nil
                        MCT.activeMarker.rule = nil
                    end
                end,
            }),
            Slider("markerAutoClearMs", "Clear after (ms)", 500, 15000, 250, nil, { disabled = Off("markerEnabled") }),
            MarkerDropdown("burst", "Burst marker", TARGET_MARKER_TYPE_EIGHT),
            MarkerDropdown("shieldbreak", "Shield-break marker", TARGET_MARKER_TYPE_THREE),
            MarkerDropdown("pressure", "Pressure marker", TARGET_MARKER_TYPE_ONE,
                "Low-priority marker while you keep hitting a target; never replaces burst/shield-break."),
        }),

        -- ================= Performance =================
        Submenu("Performance", "Keep combat text light in large fights.", {
            Check("pvpOnly", "Only while PvP flagged", "Skip all combat text processing outside PvP."),
            Slider("mergeWindowMs", "Merge hits within (ms)", 50, 800, 25,
                "Rapid hits in the same category are added up into one number."),
            Slider("maxFloatingLabels", "Max labels on screen", 10, 80, 1,
                "Extra events are skipped while this many labels are animating.",
                { onChange = function(v) if MCT.pool and MCT.pool.SetMaxLabels then MCT.pool:SetMaxLabels(v) end end }),
            Header("Heavy combat mode"),
            Check("performanceMode", "Enable", "Trims icon work and tightens label pacing."),
            Slider("performanceMaxIcons", "Max icons per label", 1, 6, 1, nil, { disabled = Off("performanceMode") }),
            Slider("performanceLaneStaggerPercent", "Label spacing (%)", 1, 20, 1, nil, { disabled = Off("performanceMode") }),
            Check("performanceDisableTexturesOnBurst", "Hide icons during spikes",
                "Temporarily drop icons when many labels appear per second.", { disabled = Off("performanceMode") }),
            Slider("performanceTextureEventThreshold", "Spike threshold (labels/s)", 10, 120, 1, nil,
                { disabled = Off("performanceMode", "performanceDisableTexturesOnBurst") }),
            Slider("performanceTextureCooldownMs", "Hide icons for (ms)", 200, 5000, 100, nil,
                { disabled = Off("performanceMode", "performanceDisableTexturesOnBurst") }),
        }),
    }

    MCT.settingsPanel = LAM:RegisterAddonPanel("MCTPanel", panelData)
    LAM:RegisterOptionControls("MCTPanel", options)
end
