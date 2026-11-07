# MyCombatText (MCT)

**Better Combat Text** — a floating combat text (FCT/SCT) addon for The Elder Scrolls Online. It replaces/augments ESO's built-in combat text with animated, color-coded, configurable labels for damage, healing, crowd control, resource changes, burst/shield-break detection, DPS tracking, and more.

- **Title:** Better Combat Text
- **Author:** Vixen Hunny
- **API Version:** 101048
- **Saved Variables:** `MCT_Saved`
- **Dependencies:** [LibAddonMenu-2.0](https://www.esoui.com/downloads/info7-LibAddonMenu.html)

## Installation / Load Order

Defined in [MyCombatText.addon](/c:/Users/Admin/AppData/Local/Elder Scrolls Online/pccert/CachedData/AddOnsManaged/MyCombatText/MyCombatText.addon), files load in this order:

1. [MyCombatText.xml](/c:/Users/Admin/AppData/Local/Elder Scrolls Online/pccert/CachedData/AddOnsManaged/MyCombatText/MyCombatText.xml) — defines the root `TopLevelControl` (`MyCombatTextRoot`) that all labels/textures are parented to.
2. [MyCombatText.Formatting.lua](/c:/Users/Admin/AppData/Local/Elder Scrolls Online/pccert/CachedData/AddOnsManaged/MyCombatText/MyCombatText.Formatting.lua)
3. [MyCombatText.Presets.lua](/c:/Users/Admin/AppData/Local/Elder Scrolls Online/pccert/CachedData/AddOnsManaged/MyCombatText/MyCombatText.Presets.lua)
4. [MyCombatText.ResultFilter.lua](/c:/Users/Admin/AppData/Local/Elder Scrolls Online/pccert/CachedData/AddOnsManaged/MyCombatText/MyCombatText.ResultFilter.lua)
5. [MyCombatText.lua](/c:/Users/Admin/AppData/Local/Elder Scrolls Online/pccert/CachedData/AddOnsManaged/MyCombatText/MyCombatText.lua) — main entry point / orchestrator
6. [MyCombatText.Tracking.lua](/c:/Users/Admin/AppData/Local/Elder Scrolls Online/pccert/CachedData/AddOnsManaged/MyCombatText/MyCombatText.Tracking.lua)
7. [MyCombatText.Combat.lua](/c:/Users/Admin/AppData/Local/Elder Scrolls Online/pccert/CachedData/AddOnsManaged/MyCombatText/MyCombatText.Combat.lua)

## Architecture Overview

All modules share a single global namespace table, `MyCombatText` (aliased everywhere as `local MCT = MyCombatText`). There is no OOP/class hierarchy — just a flat table of functions, caches, and state attached to `MCT`.

| File | Responsibility |
|---|---|
| [MyCombatText.lua](/c:/Users/Admin/AppData/Local/Elder Scrolls Online/pccert/CachedData/AddOnsManaged/MyCombatText/MyCombatText.lua) | Main file. Owns `MCT.defaults` (SavedVariables schema), the fixed-size label/texture control pool (`MCT:InitPool`), the screen-anchor resolver (`MCT:GetAnchor`), the multi-phase lane animation engine (`MCT:Animate`), the render router (`MCT:ShowText` / `MCT:ShowNotification`), the LibAddonMenu-2.0 settings panel (`MCT:InitSettingsPanel`), slash commands, and `MCT:Initialize()` (the `EVENT_ADD_ON_LOADED` entry point). |
| [MyCombatText.Combat.lua](/c:/Users/Admin/AppData/Local/Elder Scrolls Online/pccert/CachedData/AddOnsManaged/MyCombatText/MyCombatText.Combat.lua) | Registers native ESO events (`EVENT_COMBAT_EVENT`, `EVENT_POWER_UPDATE`, `EVENT_ALERT_TEXT_NOTIFICATION_TIP`, `EVENT_PLAYER_COMBAT_STATE_CHANGED`, `EVENT_ALLIANCE_POINT_UPDATE`, `EVENT_EXPERIENCE_GAIN`, `EVENT_CHAMPION_POINT_GAIN`, `EVENT_POWER_UPDATE` warnings, potion-ready, etc.), classifies them, applies per-feature toggles, and dispatches to the Tracking merge queue. No external library dependencies — pure ESO API. |
| [MyCombatText.Tracking.lua](/c:/Users/Admin/AppData/Local/Elder Scrolls Online/pccert/CachedData/AddOnsManaged/MyCombatText/MyCombatText.Tracking.lua) | Stateful tracking: the hit-merge queue (groups rapid multi-hits into one label within `mergeWindowMs`), burst-damage detection, shield-break detection, a rolling DPS window per target, and the reticle priority-marker system (auto-marks high-value targets with `TARGET_MARKER_TYPE_*` icons). |
| [MyCombatText.Formatting.lua](/c:/Users/Admin/AppData/Local/Elder Scrolls Online/pccert/CachedData/AddOnsManaged/MyCombatText/MyCombatText.Formatting.lua) | Font caching (by style/face/size to avoid per-event string allocation), `FormatShortNumber` (e.g. `12.3k`), color helpers (`ColorText`), combat font style definitions, and ability-icon/heart-texture layout helpers. |
| [MyCombatText.Presets.lua](/c:/Users/Admin/AppData/Local/Elder Scrolls Online/pccert/CachedData/AddOnsManaged/MyCombatText/MyCombatText.Presets.lua) | `MCT.Presets` registry — complete named overrides of `MCT.sv` (colors, font sizes, animation timing, toggles) for instant visual style switching via `MCT:ApplyPreset(name)`. |
| [MyCombatText.ResultFilter.lua](/c:/Users/Admin/AppData/Local/Elder Scrolls Online/pccert/CachedData/AddOnsManaged/MyCombatText/MyCombatText.ResultFilter.lua) | Maps ESO's numeric `ACTION_RESULT_*` combat constants into named boolean-lookup sets, exposed as `MCT.Result.IsDamage(result)`, `IsHeal`, `IsCrit`, `IsDodged`, `IsStunned`, `IsBlocked`, `IsMiss`, `IsEnergize`, etc. — avoids magic numbers throughout the rest of the addon. |
| [media/](/c:/Users/Admin/AppData/Local/Elder Scrolls Online/pccert/CachedData/AddOnsManaged/MyCombatText/media) | Icon textures (`glossy-pink`, `glossy-pink-heart`, `glossy-white`, `glossy-white-heart`, `.dds`/`.png` pairs) used by the optional "heart texture" critical-hit decoration, plus `texconv.exe` (a DDS texture conversion dev tool, not loaded by the addon). |

### Event pipeline

```
ESO native event (EVENT_COMBAT_EVENT, EVENT_POWER_UPDATE, ...)
        │  (MyCombatText.Combat.lua)
        ▼
Classify result via MCT.Result.Is*() (ResultFilter.lua)
        │
        ▼
Apply feature toggles / filters (MCT.sv.show*)
        │
        ▼
MCT:QueueHit / QueueOverhealing / QueueResourceRestore (Tracking.lua)
        │  (merges rapid multi-hits within mergeWindowMs)
        ▼
MCT:ShowText / MCT:ShowNotification (MyCombatText.lua)
        │  (acquires a pooled label, picks color/font/icon/anchor)
        ▼
MCT:Animate — multi-phase lane animation (rise, jitter, fade)
```

### Control pooling & lanes

Floating labels are not created per-event; `MCT:InitPool()` pre-allocates a fixed-size pool (`maxFloatingLabels`, default 40) of label/texture controls that are recycled. Active animations are scheduled into **left / right / center lanes** with staggered timing (`MCT:GetAnimationLane`, `MCT:ProcessLaneQueue`) so simultaneous hits don't visually overlap.

### Performance design

- **Engine-side event filtering.** `EVENT_COMBAT_EVENT` is registered twice with `AddFilterForEvent` (source = player, target = player, `IS_ERROR = false`), so the client only calls into Lua for events that involve you — not every combat event in the zone. `EVENT_POWER_UPDATE` is filtered to `player` and to `reticleover` health.
- **Reused animation timelines.** ESO never frees `ANIMATION_MANAGER` timelines, so each pooled label owns a few reusable timelines instead of creating a new one per label shown (which previously grew memory for the whole play session).
- **Allocation-free hot paths.** Merged hits update their bucket in place, the DPS window uses parallel arrays, fonts/colored strings/heart lines are memoized, and `ShowText` is table-driven rather than building lookup tables per call.
- **Cheap classification.** Combat results are classified with single table lookups (`MCT.Result.Sets`, `MCT.Result.GetCCSpecial`).

## Features

- **Damage / healing / critical hits** with per-category colors and font sizes, including damage dealt vs. damage taken.
- **Crowd control labels**: stun, fear, charm, silence, disorient, immobilize, off-balance (each independently toggleable and colorable).
- **Burst damage detection** — fires when the player lands `burstMinHits` within `burstWindowMs` totaling `burstMinDamage` with `burstMinCrits` crits.
- **Shield-break detection** — fires when a shielded hit is followed by an unshielded hit above `shieldbreakMinDamage` within `shieldbreakWindowMs`.
- **Reticle priority marker system** — automatically sets a `TARGET_MARKER_TYPE_*` icon (skull/X/sword) on the reticle target based on burst/shieldbreak/pressure rules, with auto-clear and a reticle "flash" visual pop.
- **Rolling DPS window** — per-target sliding-window DPS, optionally shown on burst.
- **Resource restore tracking** — Magicka/Stamina gains shown as `+N (✦ Resource)` (health gains are already shown as heals).
- **Hit merging** — rapid multi-hit abilities collapse into a single summed label instead of spamming the screen.
- **Overhealing tracking**.
- **Ability icons / "event textures"** next to labels, with performance safeguards (auto-suppressed during high-event-rate bursts).
- **Optional heart-texture decoration** for crits (`media/glossy-*-heart`).
- **Combat state, low-resource warnings** (health/magicka/stamina thresholds), **ultimate-ready** and **potion-ready** alerts.
- **Alliance Points / Experience / Champion Points gain** notifications (buffered/batched).
- **Mitigation events**: miss, immune, parried, reflected.
- **Energize / drain** display (opt-in, off by default).
- **Five visual presets** (`LUI_ENHANCED`, `LUI_CLASSIC`, `MINIMAL`, `DETAILED`, `SWEETHEART`) for one-command style switching.
- **Full LibAddonMenu-2.0 settings panel** exposing colors, font sizes, position offsets, thresholds, and behavior toggles for every category above.
- **PvP-only mode**, reticle anchoring, gamepad-aware UI scaling, and a "performance mode" that throttles icons/textures during heavy combat.

## Slash Commands

| Command | Description |
|---|---|
| `/mct` | Open the settings panel. |
| `/mct test` | Preview sample labels (damage, crit, heal, damage taken, stun, burst, alert) so you can check styling out of combat. |
| `/mct preset <name>` | Switch to a preset: `LUI_ENHANCED`, `LUI_CLASSIC`, `MINIMAL`, `DETAILED`, `SWEETHEART`. |
| `/mct presets` | List all available preset names. |
| `/mct help` | Print command reference to chat. |
| `/bct testlabel <value> <code>` | Spawn a test label (e.g. `damage`, `damageCrit`, `healing`, `burst`, `shieldbreak`, `dodge`, `dot`, `stun`, `fear`, `charm`, `silence`, `disorient`, `offbalance`, `resourceRestore`). |
| `/bct` (no args) | Print quick command help. |
| `/mctdebug merge <on\|off\|toggle\|seconds>` | Toggle (or time-box) merge-queue debug logging to chat. |

## Presets

| Preset | Style | Font size | Anim duration | Rise | Jitter | Coverage |
|---|---|---|---|---|---|---|
| `LUI_ENHANCED` (default) | Vibrant, dramatic | 32–54pt | 1200ms | 180px | 100px | All events |
| `LUI_CLASSIC` | Quieter LUI style | 28–48pt | 1000ms | 150px | 80px | All events |
| `MINIMAL` | Critical info only | 24–42pt | 700ms | 100px | 50px | Damage/heal/crit/key CC only — dodges, DoTs, resources, icons suppressed |
| `DETAILED` | Maximum awareness | 30–52pt | 1100ms | 170px | 90px | Every event type, icons on |
| `SWEETHEART` | Pastel & cute | 34–58pt, handwritten | 1300ms | 140px | 70px | Every event type; glossy hearts frame heals/crits, sparkles frame damage, softer wording ("dizzy~", "oopsie~"), bouncy pop animation |

See [FEATURES_GUIDE.md](/c:/Users/Admin/AppData/Local/Elder Scrolls Online/pccert/CachedData/AddOnsManaged/MyCombatText/FEATURES_GUIDE.md) for the full feature walkthrough, animation test codes, color-code reference, and troubleshooting FAQ.

## Configuration

All user settings live in `MCT.sv` (backed by `ZO_SavedVars`, saved variable name `MCT_Saved`) and are seeded from `MCT.defaults` in [MyCombatText.lua](/c:/Users/Admin/AppData/Local/Elder Scrolls Online/pccert/CachedData/AddOnsManaged/MyCombatText/MyCombatText.lua). Applying a preset overwrites the relevant keys in `MCT.sv`. Settings are editable in-game via **Settings → Add-Ons → Better Combat Text** (or `/mct`), built in `MyCombatText.Settings.lua`. The panel opens with a short quick-setup block (enable, preset, **Preview**, reset) followed by collapsible sections:

| Section | Contents |
|---|---|
| What to show | Damage, DoTs, damage taken, healing, overhealing, crits-only, ability names/icons, each crowd-control type, mitigated attacks, resources, XP/CP/AP |
| Alerts & warnings | Block/exploit/interrupt/dodge/cleanse tips, execute alert, low health/magicka/stamina (each with its own threshold), ultimate/potion ready, sound |
| Look & feel | Text style, hearts, overall scale, font multiplier, gamepad boosts, animation |
| Font sizes | One slider per label type |
| Colors | Color pickers for every label type |
| Positions | Global shift, follow-reticle, per-category X/Y offsets, Preview button |
| Combat analysis | Burst, shield break, reticle flash, DPS, target markers |
| Performance | PvP-only, merge window, max labels on screen, heavy-combat mode |

## Requirements

- [LibAddonMenu-2.0](https://www.esoui.com/downloads/info7-LibAddonMenu.html) must be installed for the in-game settings panel.
