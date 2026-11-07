-- ============================================================
-- MyCombatText.Formatting.lua
-- Font caching, number formatting, color helpers, event icon
-- paths, and the layout functions that position ability icons
-- next to floating combat text labels.
-- ============================================================

MyCombatText = MyCombatText or {}
local MCT = MyCombatText

-- Per-style+size font cache. Building font descriptor strings on every
-- event allocates garbage; cache by style/face/size tuple instead.
MCT._fontCacheByStyle = MCT._fontCacheByStyle or {}

-- Combat text font styles selectable from settings.
-- `fontFace` is the default face for most labels.
-- `burstFace` is used for high-impact burst labels.
MCT.CombatFontStyles = MCT.CombatFontStyles or {
    DEFAULT = {
        name = "Default Combat",
        fontFace = "EsoUI/Common/Fonts/FTN57.otf",
        burstFace = "ZoFontCombat",
    },
    HEARTS = {
        name = "Hearts Texture (Pink)",
        fontFace = "EsoUI/Common/Fonts/FTN57.otf",
        burstFace = "ZoFontCombat",
    },
    HEARTS_WHITE = {
        name = "Hearts Texture (White)",
        fontFace = "EsoUI/Common/Fonts/FTN57.otf",
        burstFace = "ZoFontCombat",
    },
    APPLE_WHITE_HEART = {
        name = "Apple White Heart",
        fontFace = "EsoUI/Common/Fonts/FTN57.otf",
        burstFace = "ZoFontCombat",
    },
    IMPERIAL = {
        name = "Imperial Edict",
        fontFace = "EsoUI/Common/Fonts/TrajanPro-Regular.otf",
        burstFace = "EsoUI/Common/Fonts/TrajanPro-Regular.otf",
    },
    ARCANE = {
        name = "Arcane Script",
        fontFace = "EsoUI/Common/Fonts/Univers57.otf",
        burstFace = "EsoUI/Common/Fonts/Univers67.otf",
    },
    WARDRUM = {
        name = "War Drum",
        fontFace = "EsoUI/Common/Fonts/Univers67.otf",
        burstFace = "ZoFontCombat",
    },
    -- Sweetheart: ESO's handwritten font, glossy hearts and sparkles around
    -- each number, softer wording. Pairs with the SWEETHEART preset (pastel
    -- palette + bouncy pop animation).
    CUTE = {
        name = "Sweetheart (cute)",
        fontFace = "$(HANDWRITTEN_FONT)",
        burstFace = "$(HANDWRITTEN_FONT)",
        fontEffect = "soft-shadow-thick",
        cute = true,
    },
}

-- EventTextures: maps event code strings to ESO DDS icon file paths.
-- These are the small icons shown beside floating combat text labels
-- when MCT.sv.showEventTextures is enabled. If an ability-specific
-- icon is available it takes priority; this table is the fallback.
MCT.EventTextures = {
    damage        = "EsoUI/Art/ActionBar/icon_melee.dds",          -- outgoing damage hit
    healing       = "EsoUI/Art/HUD/Compass_Health_UpSmall.dds",    -- any healing (self, outgoing, HoT)
    damageTaken   = "EsoUI/Art/ActionBar/icon_melee.dds",          -- incoming damage
    critical      = "EsoUI/Art/Miscellaneous/loot_icon_quality_legendary.dds", -- generic crit
    crit          = "EsoUI/Art/Miscellaneous/loot_icon_quality_legendary.dds", -- alias for critical
    burst         = "EsoUI/Art/Actionbar/icon_ultimate.dds",        -- burst threshold triggered
    shieldbreak   = "EsoUI/Art/ActionBar/icon_shield.dds",          -- shield broken
    dodge         = "EsoUI/Art/ActionBar/icon_dodge.dds",           -- dodge / roll
    stun          = "EsoUI/Art/CampaignStructures/campaignoverlay_emperor_icon.dds", -- stun CC
    fear          = "EsoUI/Art/ActionBar/status_fear.dds",          -- fear CC
    charm         = "EsoUI/Art/ActionBar/status_charm.dds",         -- charm / mind control CC
    silence       = "EsoUI/Art/ActionBar/status_silence.dds",       -- silence CC
    disorient     = "EsoUI/Art/ActionBar/status_disoriented.dds",   -- disorient CC
    offbalance    = "EsoUI/Art/ActionBar/status_offbalance.dds",    -- off-balance CC
    resource      = "EsoUI/Art/Miscellaneous/icon_mana.dds",        -- generic resource gain
    magicka       = "EsoUI/Art/Miscellaneous/icon_mana.dds",        -- magicka restore
    stamina       = "EsoUI/Art/Miscellaneous/icon_stamina.dds",     -- stamina restore
    overhealing   = "EsoUI/Art/HUD/Compass_Health_UpSmall.dds",    -- overhealing (excess heal)
}

-- GetEventTexture: returns the fallback icon path for a given event code
-- string (e.g. "healing", "damage"), or nil if no icon is mapped.
-- Callers should prefer ability icons via GetAbilityIcon() first.
function MCT:GetEventTexture(eventCode)
    return MCT.EventTextures[eventCode] or nil
end

-- GetCombatFontStyleKey: resolves SavedVariables value to a valid style key.
function MCT:GetCombatFontStyleKey()
    local sv = MCT.sv
    local key = sv and sv.combatFontStyle or "DEFAULT"
    if not MCT.CombatFontStyles[key] then
        key = "DEFAULT"
    end
    return key
end

-- GetCombatFontStyle: returns the style table for the current style key.
function MCT:GetCombatFontStyle()
    return self.CombatFontStyles[self:GetCombatFontStyleKey()] or self.CombatFontStyles.DEFAULT
end

-- GetCombatFontStyleChoices: returns ordered labels and values for dropdowns.
function MCT:GetCombatFontStyleChoices()
    local order = { "DEFAULT", "CUTE", "HEARTS", "HEARTS_WHITE", "IMPERIAL", "ARCANE", "WARDRUM" }
    local labels, values = {}, {}
    for i = 1, #order do
        local key = order[i]
        local style = self.CombatFontStyles[key]
        if style then
            labels[#labels + 1] = style.name
            values[#values + 1] = key
        end
    end
    return labels, values
end

-- Heart decoration lines are identical for a given (path, count), so build
-- each one once instead of on every label.
local heartLineCache = {}

local function BuildHeartTextureLine(iconPath, iconCount)
    local count = tonumber(iconCount) or 3
    if count < 1 then count = 1 end

    local resolvedPath = tostring(iconPath or "MyCombatText/media/glossy-pink.dds")
    local byPath = heartLineCache[resolvedPath]
    if not byPath then
        byPath = {}
        heartLineCache[resolvedPath] = byPath
    end
    local cached = byPath[count]
    if cached then return cached end

    local icon = "|t18:18:" .. resolvedPath .. "|t"
    local line = {}
    for i = 1, count do
        line[i] = icon
    end
    cached = table.concat(line, "  ")
    byPath[count] = cached
    return cached
end

-- GetCachedCombatFont: style-aware cached font descriptor.
-- `useBurstFace` chooses between the style's primary face and burst face.
function MCT:GetCachedCombatFont(size, useBurstFace)
    local numericSize = tonumber(size) or 28
    local sizeMultiplier = tonumber((self.sv and self.sv.fontSizeMultiplier) or 1) or 1

    if self.IsConsoleFriendlyActive and self:IsConsoleFriendlyActive() then
        sizeMultiplier = sizeMultiplier * (tonumber((self.sv and self.sv.gamepadFontMultiplier) or 1.10) or 1.10)
    end

    numericSize = math.max(8, math.floor((numericSize * sizeMultiplier) + 0.5))

    -- Nested lookup [style][burst|normal][size] — no per-call key string or
    -- temporary table (the old version allocated both on every label).
    local styleKey = self:GetCombatFontStyleKey()
    local byStyle = self._fontCacheByStyle[styleKey]
    if not byStyle then
        byStyle = { [true] = {}, [false] = {} }
        self._fontCacheByStyle[styleKey] = byStyle
    end
    local bySize = byStyle[useBurstFace and true or false]

    local font = bySize[numericSize]
    if not font then
        local style = self.CombatFontStyles[styleKey] or self.CombatFontStyles.DEFAULT
        local face = (useBurstFace and style.burstFace) or style.fontFace or "EsoUI/Common/Fonts/FTN57.otf"
        font = tostring(face) .. "|" .. tostring(numericSize) .. "|" .. (style.fontEffect or "soft-shadow-thick")
        bySize[numericSize] = font
    end
    return font
end

-- Backward-compatible wrappers used across the addon.
function MCT:GetCachedFTNFont(size)
    return self:GetCachedCombatFont(size, false)
end

function MCT:GetCachedZoCombatFont(size)
    return self:GetCachedCombatFont(size, true)
end

-- StylizeDisplayText: applies the selected text style decoration to a label
-- payload while preserving existing color markup inside `text`.
-- ---------------------------------------------------------------
-- Sweetheart (CUTE) decorations.
-- Inline textures (|t...|t) sized in % of the font height so they scale
-- with every font size. Tinted pieces use ESO's ":inheritColor" flag so
-- the white heart / sparkle take on the label's own pastel colour.
-- ---------------------------------------------------------------
local MEDIA = "MyCombatText/media/"
local function Icon(file, pct, tinted)
    return "|t" .. pct .. "%:" .. pct .. "%:" .. MEDIA .. file .. (tinted and ":inheritColor" or "") .. "|t"
end
local PINK_HEART = function(p) return Icon("glossy-pink-heart.dds", p, false) end
local TINT_HEART = function(p) return Icon("soft-heart.dds", p, true) end
local SPARKLE    = function(p) return Icon("sparkle.dds", p, true) end

-- [isCrit][eventCode] = { left, right }. `nil` sides are left bare.
local CUTE_DECOR = { [false] = {}, [true] = {} }
local function Decor(code, normal, crit)
    CUTE_DECOR[false][code] = normal
    CUTE_DECOR[true][code] = crit or normal
end
Decor("healing",     { TINT_HEART(90) },                       { PINK_HEART(110), PINK_HEART(110) })
Decor("overhealing", { TINT_HEART(70) })
Decor("damage",      { SPARKLE(80) },                          { SPARKLE(105), SPARKLE(105) })
Decor("dot",         { SPARKLE(60) })
Decor("damageTaken", { TINT_HEART(75) },                       { TINT_HEART(95), TINT_HEART(95) })
Decor("burst",       { PINK_HEART(120) .. SPARKLE(90), SPARKLE(90) .. PINK_HEART(120) })
Decor("shieldbreak", { SPARKLE(100), SPARKLE(100) })
for _, code in ipairs({ "dodge", "stun", "fear", "charm", "silence", "disorient", "offbalance", "combatState" }) do
    Decor(code, { SPARKLE(80), SPARKLE(80) })
end
Decor("alert",           { PINK_HEART(95), PINK_HEART(95) })
Decor("resourceWarning", { PINK_HEART(95), PINK_HEART(95) })
for _, code in ipairs({ "points", "resource", "resourceRestore", "energize", "drain", "miss", "immune", "parried", "reflected" }) do
    Decor(code, { SPARKLE(70) })
end

-- Built decorated prefixes/suffixes, cached per decor row and colour.
local cuteDecorCache = setmetatable({}, { __mode = "k" })

local function CuteDecorate(s, eventCode, isCrit)
    local row = CUTE_DECOR[isCrit and true or false][eventCode]
    if not row then return s end

    -- Tinted icons must sit inside a colour span to inherit it.
    local hex = string.match(s, "^|c(%x%x%x%x%x%x)") or "ffffff"
    local byHex = cuteDecorCache[row]
    if not byHex then
        byHex = {}
        cuteDecorCache[row] = byHex
    end
    local pair = byHex[hex]
    if not pair then
        pair = {
            row[1] and ("|c" .. hex .. row[1] .. "|r ") or "",
            row[2] and (" |c" .. hex .. row[2] .. "|r") or "",
        }
        byHex[hex] = pair
    end
    return pair[1] .. s .. pair[2]
end

function MCT:StylizeDisplayText(text, eventCode, isCrit)
    local s = text
    if type(s) ~= "string" then s = tostring(text or "") end
    local styleKey = self:GetCombatFontStyleKey()
    if styleKey == "DEFAULT" then
        return s -- fast path: most users never change the style
    end
    if styleKey == "CUTE" then
        return CuteDecorate(s, eventCode, isCrit)
    end

    local sv = self.sv
    local heartsEnabled = sv and sv.enableHeartTextures == true

    if styleKey == "HEARTS" and heartsEnabled then
        local top = BuildHeartTextureLine("MyCombatText/media/glossy-pink.dds", sv.heartCount)
        return top .. "\n" .. s
    elseif styleKey == "HEARTS_WHITE" and heartsEnabled then
        local top = BuildHeartTextureLine("MyCombatText/media/glossy-white.dds", sv.heartCount)
        return top .. "\n" .. s
    elseif styleKey == "IMPERIAL" then
        return "[ " .. s .. " ]"
    elseif styleKey == "ARCANE" then
        return "^~^ " .. s .. " ^~^"
    elseif styleKey == "WARDRUM" then
        return "<< " .. s .. " >>"
    end

    return s
end

-- ColorText: wraps the given text in ESO markup color tags using a 6-char
-- hex color string (e.g. "ff4444"). An optional suffix is appended inside
-- the color tags so it matches the same color before the closing |r tag.
function MCT:ColorText(hex, text, suffix)
    if suffix then
        return "|c" .. tostring(hex) .. tostring(text) .. tostring(suffix) .. "|r"
    end
    return "|c" .. tostring(hex) .. tostring(text) .. "|r"
end

-- ColorTextCached: like ColorText(hex, text) but memoizes the result per
-- (text, hex) pair. Used for fixed labels ("MISS", "STUN", "LOW HEALTH!")
-- that are shown repeatedly, so steady-state combat creates no new strings.
-- Do not use it for numeric values (unbounded key space).
local colorTextCache = {}

-- Softer wording for fixed labels while the Sweetheart style is active.
local CUTE_WORDS = {
    ["DODGE"] = "dodged~",            ["TARGET DODGE"] = "they dodged~",
    ["STUN"] = "dizzy~",              ["TARGET STUN"] = "stunned~",
    ["FEAR"] = "eep! feared",         ["TARGET FEAR"] = "scared~",
    ["CHARM"] = "charmed~",           ["TARGET CHARM"] = "charmed~",
    ["SILENCE"] = "shh~ silenced",    ["TARGET SILENCE"] = "shh~",
    ["DISORIENT"] = "woozy~",         ["TARGET DISORIENT"] = "woozy~",
    ["OFFBALANCE"] = "wobbly~",       ["TARGET OFFBALANCE"] = "wobbly~",
    ["IMMOBILIZED"] = "stuck~",       ["TARGET IMMOBILIZED"] = "stuck~",
    ["MISS"] = "oopsie~",             ["IMMUNE"] = "immune~",
    ["PARRIED"] = "parried~",         ["REFLECTED"] = "bounced back~",
    ["BLOCK!"] = "block it!",         ["EXPLOIT!"] = "exploit!",
    ["INTERRUPT!"] = "interrupt!",    ["DODGE!"] = "roll away!",
    ["CLEANSE!"] = "cleanse!",        ["ULTIMATE READY!"] = "ultimate ready~",
    ["LOW HEALTH!"] = "low health!",  ["LOW MAGICKA!"] = "low magicka!",
    ["LOW STAMINA!"] = "low stamina!",
    ["Entered Combat"] = "let's go~", ["Left Combat"] = "phew~ all safe",
}

function MCT:ColorTextCached(hex, text)
    hex = hex or "ffffff"
    local sv = MCT.sv
    if sv and sv.combatFontStyle == "CUTE" then
        text = CUTE_WORDS[text] or text
    end
    local byText = colorTextCache[text]
    if not byText then
        byText = {}
        colorTextCache[text] = byText
    end
    local s = byText[hex]
    if not s then
        s = "|c" .. tostring(hex) .. tostring(text) .. "|r"
        byText[hex] = s
    end
    return s
end

-- FormatShortNumber: converts a large integer into a human-readable
-- abbreviated string for display in combat text labels.
-- Examples: 1234 -> "1.2k", 12345 -> "12k", 1234567 -> "1.2m",
--           1000000000 -> "1.0b". Returns the plain number string below 1000.
-- Falls back to 0 and "0" for nil or non-numeric input.
function MCT:FormatShortNumber(n)
    n = tonumber(n) or 0
    local absN = math.abs(n)

    -- Billions: 1,000,000,000+
    if absN >= 1000000000 then
        local v = n / 1000000000
        return (absN >= 10000000000) and string.format("%.0fb", v) or string.format("%.1fb", v):gsub("%.0b", "b")
    -- Millions: 1,000,000+
    elseif absN >= 1000000 then
        local v = n / 1000000
        return (absN >= 10000000) and string.format("%.0fm", v) or string.format("%.1fm", v):gsub("%.0m", "m")
    -- Thousands: 1,000+
    elseif absN >= 1000 then
        local v = n / 1000
        return (absN >= 10000) and string.format("%.0fk", v) or string.format("%.1fk", v):gsub("%.0k", "k")
    -- Below 1000: display the raw integer
    else
        return tostring(n)
    end
end
