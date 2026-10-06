-- ===========================================
-- MyCombatText Enhanced Features Guide
-- Version 2.0 - LUI Style Update
-- ===========================================

--[[ ======================================
     QUICK START COMMANDS
     ====================================== ]]

-- Switch presets:
/mct preset LUI_ENHANCED      -- Default: Vibrant colors, large fonts, dramatic animations
/mct preset LUI_CLASSIC        -- Simpler LUI style with moderate settings
/mct preset MINIMAL            -- Minimal visual spam, only critical events
/mct preset DETAILED           -- Everything enabled, most events shown

-- List all presets:
/mct presets

-- Show all commands:
/mct help

-- Test animations:
/bct testlabel 1000 damage
/bct testlabel 5000 damageCrit
/bct testlabel 2000 healing
/bct testlabel 3000 burst


--[[ ======================================
     NEW FEATURES IN V2.0
     ====================================== ]]

-- 1. PRESET SYSTEM
--    Four ready-made visual presets that you can switch between instantly
--    Each preset has its own colors, font sizes, and animation settings
--    Presets are:
--    - LUI_ENHANCED: Bright vibrant colors like LUI addon
--    - LUI_CLASSIC: Simpler but still LUI-inspired
--    - MINIMAL: Only show critical information
--    - DETAILED: Show everything possible

-- 2. RESOURCE RESTORE TRACKING
--    Now displays when your character gains:
--    - Magicka (shown as "✦ Magicka")
--    - Stamina (shown as "✦ Stamina") 
--    - Health (shown as "✦ Health")
--    Displays as: "+2500 (✦ Magicka)" with animation

-- 3. EVENT TEXTURES & ICONS
--    Each event type can be displayed with associated textures/icons:
--    - Damage, Healing, Critical hits, Burst damage
--    - Shield breaks, Dodges, CC effects, Resource restoration
--    - Enable/disable with /bct settings panel

-- 4. LUI-STYLE ANIMATIONS
--    Enhanced animations with:
--    - Longer durations (1200ms vs original 750ms)
--    - Greater vertical rise (180px more dramatic)
--    - Wider horizontal spread (jitter up to 100px)
--    - Configurable per preset
--    - Crits fade slower so text stays visible longer


--[[ ======================================
     PRESET DETAILS
     ====================================== ]]

-- LUI_ENHANCED (Default)
-- - Colors: Vibrant and bright (orange, cyan, lime green)
-- - Font sizes: Large (32-54pt)
-- - Animation duration: 1200ms
-- - Animation rise: 180px
-- - Animation jitter: 100px
-- - Shows: All events enabled
-- - Best for: Maximum visibility and style

-- LUI_CLASSIC
-- - Colors: Slightly muted from LUI_ENHANCED
-- - Font sizes: Medium-large (28-48pt)
-- - Animation duration: 1000ms
-- - Animation rise: 150px
-- - Animation jitter: 80px
-- - Shows: All events enabled
-- - Best for: Balance of LUI style with less intensity

-- MINIMAL
-- - Colors: Muted/subdued
-- - Font sizes: Small-medium (24-42pt)
-- - Animation duration: 700ms
-- - Animation rise: 100px
-- - Animation jitter: 50px
-- - Shows: Only damage, healing, crits, and main CCs (stun/fear/charm)
-- - Disabled: dodge messages, dots, resource restore
-- - Best for: Minimal UI clutter during combat

-- DETAILED
-- - Colors: Bright and clear
-- - Font sizes: Large (30-52pt)
-- - Animation duration: 1100ms
-- - Animation rise: 170px
-- - Animation jitter: 90px
-- - Shows: Every single event type
-- - Best for: Learning and analyzing all combat events


--[[ ======================================
     CUSTOMIZATION TIPS
     ====================================== ]]

-- After selecting a preset, you can further customize:
-- 1. Right-click the addon name in ESO and select "Settings"
-- 2. Or open Settings panel from any menu

-- Most customizable options include:
-- - Color adjustments for each event type
-- - Font size adjustments individually
-- - Position offsets (X/Y coordinates for each event category)
-- - Toggle individual event types on/off
-- - Animation speed (overall)
-- - Merge window timing

-- Example workflow:
-- 1. /mct preset LUI_ENHANCED  (Start with LUI style)
-- 2. Tweak colors in settings
-- 3. Adjust font sizes to your preference
-- 4. Position elements where you like them
-- 5. Save your customized settings


--[[ ======================================
     ANIMATION CODES FOR TESTING
     ====================================== ]]

-- Use these codes with: /bct testlabel <value> <code>
-- Value: Any number (damage/healing amount)
-- Code: One of the following:

-- Damage events:
-- damage, damageCrit, damageTaken, damageTakenCrit

-- Healing events:
-- healing, healingCrit

-- Special events:
-- burst, shieldbreak, dodge

-- DOT events:
-- dot, dotCrit

-- CC events:
-- stun, fear, charm, silence, disorient, offbalance

-- Resource events:
-- resourceRestore

-- Examples:
/bct testlabel 1234 damage          -- Regular damage
/bct testlabel 5678 damageCrit      -- Critical damage with exclamation
/bct testlabel 2000 healing         -- Healing
/bct testlabel 789 burst             -- Burst damage indicator
/bct testlabel 1 resourceRestore     -- Resource restoration


--[[ ======================================
     ANIMATION PARAMETERS BY PRESET
     ====================================== ]]

-- Current animation settings in each preset:
-- (can be modified in settings if you know the values)

-- Duration: How long the entire animation plays (milliseconds)
-- Rise: How far the text moves upward (pixels)
-- Jitter: How much horizontal scatter there is (pixels)

Preset         | Duration | Rise | Jitter
-----          | -----    | ---- | ------
LUI_ENHANCED   | 1200ms   | 180px| 100px
LUI_CLASSIC    | 1000ms   | 150px| 80px
DETAILED       | 1100ms   | 170px| 90px
MINIMAL        | 700ms    | 100px| 50px


--[[ ======================================
     TROUBLESHOOTING
     ====================================== ]]

-- Q: I don't see combat text displaying
-- A: 1. Make sure addon is enabled (/bct for test)
--    2. Check that showDamage/showHealing toggles are ON
--    3. Try a different preset: /mct preset DETAILED

-- Q: Text is appearing in the wrong location
-- A: 1. Use /mct preset to reset your positions
--    2. Or adjust X/Y offsets in settings panel
--    3. Check if anchorToReticle is enabled in settings

-- Q: I want to go back to original settings
-- A: 1. Delete your saved variables (ESO settings > Reset Addon Settings)
--    2. Or use /mct preset LUI_ENHANCED to reset to defaults

-- Q: How do I make only crits show?
-- A: 1. Use MINIMAL preset which shows critical hits prominently
--    2. Or enable critOnly in settings (shows only crits)

-- Q: The animations are too slow/fast
-- A: 1. Try a different preset
--    2. Or adjust animDuration in the settings if you're advanced

-- Q: What's the difference between LUI_ENHANCED and LUI_CLASSIC?
-- A: LUI_ENHANCED has brighter colors, larger fonts, and more dramatic animations.
--    LUI_CLASSIC is more subtle while still being LUI-inspired.


--[[ ======================================
     ADVANCED: COLOR CODES
     ====================================== ]]

-- All colors in MCT use hexadecimal RRGGBB format
-- Examples of colors used:

-- Reds: ff3333 (bright), ff0000 (pure), ff2200 (dark)
-- Blues: 4488ff (bright), 0000ff (pure), 0055ff (dark)
-- Greens: 00ff88 (bright), 00ff00 (pure), 00cc00 (dark)
-- Yellows: ffff00 (bright), ffcc00 (gold), ffaa00 (orange)
-- Purples: ff66ff (bright), ff00ff (pure), ee00ff (magenta)

-- You can customize any color in the settings panel
-- Just enter the hex code (without the 'ff' prefix for alpha)


