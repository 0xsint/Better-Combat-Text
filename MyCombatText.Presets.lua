-- ============================================================
-- MyCombatText.Presets.lua
-- Visual and behavioral preset configurations.
--
-- Presets are named collections of MCT.sv key overrides that let
-- the player instantly switch between complete visual styles.
-- Applying a preset copies every key from the table into MCT.sv,
-- so missing preset keys will NOT revert to defaults — this means
-- each preset should be complete (all color, font, and toggle keys).
--
-- Usage:
--   MCT:ApplyPreset("LUI_ENHANCED")   -- apply by name
--   /mct preset LUI_CLASSIC           -- in-game slash command
--   /mct presets                      -- list available names
--
-- Available presets (see MCT.Presets table below):
--   LUI_ENHANCED  : Vibrant Dragonknight-molten palette, all events on,
--                   dramatic LUI-style animations (recommended default).
--   LUI_CLASSIC   : Slightly quieter LUI style; smaller fonts,
--                   shorter animations, same coverage as LUI_ENHANCED.
--   MINIMAL       : Critical information only — damage, heals, key CCs.
--                   Dodges, DoTs, resources, and overhealing suppressed.
--                   Shorter animations and no ability icons.
--   DETAILED      : Every category enabled, icons on, generous font sizes.
--                   Trade-off: more screen noise in exchange for maximum
--                   situational awareness.
-- ============================================================

MyCombatText = MyCombatText or {}
local MCT = MyCombatText

-- MCT.Presets: the preset registry.
-- The `current` key tracks which preset is active (persisted via MCT.sv).
-- Every other key is a named preset table used by MCT:ApplyPreset().
MCT.Presets = {
    current = "LUI_ENHANCED",   -- Default on first load; updated when player switches.

    -- ---------------------------------------------------------------
    -- LUI_ENHANCED
    -- The flagship preset. Inspired by the LUI Extended addon's SCT
    -- color scheme blended with ESO Dragonknight molten visual identity.
    -- Every event category is enabled; animations are long and dramatic.
    -- Recommended for PvP combat where maximum information matters.
    -- ---------------------------------------------------------------
    LUI_ENHANCED = {
        enabled = true,
        -- Colors: hot amber/orange for damage, bright cyan-green for healing.
        -- Crits are golden-yellow; CC labels use vivid magenta to stand out.
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
        
        -- Font sizes: large enough to read during fast PvP exchanges.
        -- Burst uses the biggest size (54px) to command attention.
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
        
        -- Display toggles: everything visible for full combat awareness.
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
        
        -- Animation: full LUI style with long duration (1200ms) and
        -- high rise (180px) for a fluid waterfall effect.
        luiAnimStyle = true,
        animDuration = 1200,
        animRise = 180,
        animJitter = 100,
        laneQueueStaggerPercent = 5,
        
        -- Screen positions: damage left-center, healing right-center.
        -- All offsets in pixels relative to screen center.
        pvpOnly = false,
        anchorToReticle = false,
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
        showEventTextures = true,
        mergeWindowMs = 500,
    },
    
    -- ---------------------------------------------------------------
    -- LUI_CLASSIC
    -- A quieter variant of LUI_ENHANCED. Slightly smaller fonts and
    -- shorter animations (1000ms) reduce screen noise while keeping
    -- the same comprehensive event coverage. Colors are softer variants
    -- of the Enhanced palette — slightly less saturated.
    -- ---------------------------------------------------------------
    LUI_CLASSIC = {
        enabled = true,
        burstColor = "ff9900",
        reticleHighlightColor = "ff6600",
        shieldbreakColor = "99ccff",
        damageColor = "ff5544",
        healingColor = "44ff88",
        criticalColor = "ffbb00",
        criticalHealingColor = "88ffcc",
        damageTakenColor = "ff6666",
        damageTakenCritColor = "ff2200",
        dodgedColor = "ccccaa",
        ccColor = "dd55ff",
        stunColor = "ff3333",
        fearColor = "dd00ff",
        charmColor = "ff77ff",
        silenceColor = "9977ff",
        disorientColor = "ffaa55",
        offbalanceColor = "33ffcc",
        dotColor = "cc6633",
        resourceRestoreColor = "00ff77",
        overhealingColor = "77ddff",
        
        fontSize = 28,
        damageFontSize = 38,
        healingFontSize = 38,
        burstFontSize = 48,
        shieldbreakFontSize = 36,
        damageTakenFontSize = 38,
        dodgeFontSize = 36,
        stunFontSize = 36,
        fearFontSize = 36,
        charmFontSize = 36,
        silenceFontSize = 36,
        disorientFontSize = 36,
        offbalanceFontSize = 36,
        dotFontSize = 32,
        resourceRestoreFontSize = 32,
        overhealingFontSize = 32,
        
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
        critOnly = false,
        
        luiAnimStyle = true,
        animDuration = 1000,
        animRise = 150,
        animJitter = 80,
        laneQueueStaggerPercent = 5,
        
        pvpOnly = false,
        anchorToReticle = false,
        damagex = 0,
        damagey = 180,
        healingx = 0,
        healingy = -180,
        burstx = 0,
        bursty = 0,
        shieldbreakx = 0,
        shieldbreaky = 80,
        damageTakenx = 0,
        damageTakeny = 80,
        dodgex = 0,
        dodgey = -80,
        ccx = 0,
        ccy = -60,
        dotx = -180,
        doty = 0,
        resourcex = 120,
        resourcey = 0,
        showEventTextures = true,
        mergeWindowMs = 500,
    },
    
    -- ---------------------------------------------------------------
    -- MINIMAL
    -- Show only the most critical information. Damage, healing, and
    -- key CC types (stun, fear, charm) are on; DoTs, dodges, resource
    -- restore, and overhealing are suppressed to cut clutter.
    -- Shorter animations (700ms) and no ability icons reduce visual noise.
    -- Useful in content that is primarily about resource/positioning
    -- management rather than moment-to-moment burst tracking.
    -- ---------------------------------------------------------------
    MINIMAL = {
        enabled = true,
        burstColor = "ffbb00",
        reticleHighlightColor = "ff6600",
        shieldbreakColor = "88bbff",
        damageColor = "ff6644",
        healingColor = "44ff88",
        criticalColor = "ffaa00",
        criticalHealingColor = "88ffcc",
        damageTakenColor = "ff7777",
        damageTakenCritColor = "ff1111",
        dodgedColor = "bbbbaa",
        ccColor = "dd77ff",
        stunColor = "ff4444",
        fearColor = "dd00ff",
        charmColor = "ff66ff",
        silenceColor = "9988ff",
        disorientColor = "ffaa77",
        offbalanceColor = "22ffbb",
        dotColor = "bb5544",
        resourceRestoreColor = "00ff66",
        overhealingColor = "66ddff",
        
        fontSize = 24,
        damageFontSize = 32,
        healingFontSize = 32,
        burstFontSize = 42,
        shieldbreakFontSize = 32,
        damageTakenFontSize = 32,
        dodgeFontSize = 28,
        stunFontSize = 28,
        fearFontSize = 28,
        charmFontSize = 28,
        silenceFontSize = 28,
        disorientFontSize = 28,
        offbalanceFontSize = 28,
        dotFontSize = 24,
        resourceRestoreFontSize = 28,
        overhealingFontSize = 28,
        
        showDamage = true,
        showHealing = true,
        showDamageTaken = false,
        showDodges = false,
        showStuns = true,
        showFears = true,
        showCharms = true,
        showSilences = false,
        showDisorients = false,
        showOffbalances = false,
        showDots = false,
        showResourceRestore = false,        showOverhealing = false,        critOnly = false,
        
        luiAnimStyle = false,
        animDuration = 700,
        animRise = 100,
        animJitter = 50,
        laneQueueStaggerPercent = 5,
        
        pvpOnly = false,
        anchorToReticle = false,
        damagex = 0,
        damagey = 150,
        healingx = 0,
        healingy = -150,
        burstx = 0,
        bursty = 0,
        shieldbreakx = 0,
        shieldbreaky = 60,
        damageTakenx = 0,
        damageTakeny = 60,
        dodgex = 0,
        dodgey = -60,
        ccx = 0,
        ccy = -40,
        dotx = -150,
        doty = 0,
        resourcex = 100,
        resourcey = 0,
        showEventTextures = false,
        mergeWindowMs = 500,
    },
    
    -- ---------------------------------------------------------------
    -- DETAILED
    -- Every category on, ability icons visible, generous fonts.
    -- Full animation style (1100ms) slightly shorter than LUI_ENHANCED
    -- to handle the higher label density without labels overlapping.
    -- Intended for players who want maximum situational awareness
    -- and are willing to accept more screen real estate used by numbers.
    -- ---------------------------------------------------------------
    DETAILED = {
        enabled = true,
        burstColor = "ffcc00",
        reticleHighlightColor = "ff6600",
        shieldbreakColor = "aaddff",
        damageColor = "ff5555",
        healingColor = "55ff99",
        criticalColor = "ffdd00",
        criticalHealingColor = "99ffdd",
        damageTakenColor = "ff5555",
        damageTakenCritColor = "ff0000",
        dodgedColor = "ddddbb",
        ccColor = "dd66ff",
        stunColor = "ff2222",
        fearColor = "ff00ff",
        charmColor = "ff99ff",
        silenceColor = "aa99ff",
        disorientColor = "ffbb88",
        offbalanceColor = "55ffdd",
        dotColor = "dd7755",
        resourceRestoreColor = "11ff99",
        overhealingColor = "99ddff",
        
        fontSize = 30,
        damageFontSize = 40,
        healingFontSize = 40,
        burstFontSize = 52,
        shieldbreakFontSize = 38,
        damageTakenFontSize = 40,
        dodgeFontSize = 38,
        stunFontSize = 38,
        fearFontSize = 38,
        charmFontSize = 38,
        silenceFontSize = 38,
        disorientFontSize = 38,
        offbalanceFontSize = 38,
        dotFontSize = 34,
        resourceRestoreFontSize = 36,
        overhealingFontSize = 36,
        
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
        
        luiAnimStyle = true,
        animDuration = 1100,
        animRise = 170,
        animJitter = 90,
        laneQueueStaggerPercent = 5,
        
        pvpOnly = false,
        anchorToReticle = false,
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
        showEventTextures = true,
        mergeWindowMs = 500,
    },
}

-- ---------------------------------------------------------------
-- MCT:GetPreset: returns the preset table for the given name, or
-- the current preset if name is nil. Does not apply the preset
-- (use MCT:ApplyPreset for that).
-- ---------------------------------------------------------------
function MCT:GetPreset(name)
    return MCT.Presets[name or MCT.Presets.current]
end

-- ---------------------------------------------------------------
-- MCT:ApplyPreset: deep-copies all keys from the named preset into
-- MCT.sv, overwriting any player-customized values. Updates the
-- Presets.current tracker so the settings panel dropdown knows
-- which preset is active.
--
-- Parameters:
--   presetName : string key of the preset (e.g. "LUI_ENHANCED")
-- Returns: true on success, false if the preset name was not found.
-- ---------------------------------------------------------------
function MCT:ApplyPreset(presetName)
    local preset = MCT.Presets[presetName]
    if not preset then
        d("[MCT] Preset not found: " .. tostring(presetName))
        return false
    end
    
    -- Deep copy preset to saved vars
    for k, v in pairs(preset) do
        MCT.sv[k] = v
    end
    
    MCT.Presets.current = presetName
    d("[MCT] Applied preset: " .. presetName)
    return true
end

-- ---------------------------------------------------------------
-- MCT:GetPresetNames: returns a sorted array of preset name strings.
-- Used by the settings panel dropdown and /mct presets command.
-- "current" is excluded since it is a meta-key, not a preset name.
-- ---------------------------------------------------------------
function MCT:GetPresetNames()
    local names = {}
    for name, _ in pairs(MCT.Presets) do
        if name ~= "current" then
            table.insert(names, name)
        end
    end
    table.sort(names)
    return names
end
