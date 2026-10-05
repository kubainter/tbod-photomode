-- TBOD_PhotoMode v1.6.2
-- Photo Mode mod for The Blood of Dawnwalker (UE5.5.4)
-- Subsystem discovery inspired by DWFreeCam by Rabbit (MIT)
-- Modular architecture (Sprint 1.3.0) + input isolation (Sprint 1.4.0)
-- + NPC posing/props/directing (Sprint 1.5.0) + player move/weapon/leak fixes (1.5.5)

---------------------------------------------------------------------------- Module loading

-- Resolve mod scripts path for require
local function resolveModScriptsPath()
    local candidates = {
        "ue4ss/Mods/TBOD_PhotoMode/Scripts",
        "Mods/TBOD_PhotoMode/Scripts",
        "Dawnwalker/Binaries/Win64/ue4ss/Mods/TBOD_PhotoMode/Scripts",
    }
    for _, base in ipairs(candidates) do
        local f = io.open(base .. "/lib/core.lua", "r")
        if f then f:close() return base end
    end
    return nil
end

local modScriptsPath = resolveModScriptsPath()
if modScriptsPath then
    -- Hot-reload (UE4SS "Restart Mod"): the OLD module instances may still own
    -- live actors (clones, props, weapon proxies) and poses. Tear that state
    -- down BEFORE dropping them from package.loaded — otherwise they leak
    -- into the real game world, violating the PM statelessness rule.
    local oldPoses     = package.loaded["lib.poses"]
    local oldSpawner   = package.loaded["lib.spawner"]
    local oldCore      = package.loaded["lib.core"]
    local oldGamepad   = package.loaded["lib.gamepad"]
    local oldEB        = package.loaded["lib.eventbridge"]
    if oldGamepad and oldGamepad.stopPoller then
        pcall(function() oldGamepad.stopPoller() end)
    end
    if oldEB and oldEB.cleanup then
        pcall(function() oldEB.cleanup() end)
    end
    if oldPoses or oldSpawner or oldCore then
        ExecuteInGameThread(function()
            if oldPoses   then pcall(function() oldPoses.resetAllPoses() end) end
            if oldSpawner then pcall(function() oldSpawner.destroyAll() end) end
            -- Do not call old photomode methods here: its sequence list may
            -- contain stale UObject pointers after a level transition.
            -- Clearing the old state avoids native dereferences during reload.
            if oldCore and oldCore.State then
                oldCore.State.pausedSequences = {}
                oldCore.State.cutsceneSession = nil
                oldCore.State.pmMode = "normal"
                oldCore.State.cutscenePMEntry = false
            end
        end)
    end
    -- Clear cached lib modules for hot-reload safety (Restart Mod in UE4SS)
    for k in pairs(package.loaded) do
        if k:match("^lib%.") then package.loaded[k] = nil end
    end
    package.path = modScriptsPath .. "/?.lua;" .. package.path
end

-- Load modules (order: core first, then leaf -> complex)
local core        = require("lib.core")
local keybinds    = require("lib.keybinds")
local osd         = require("lib.osd")
local camera      = require("lib.camera")
local photomode   = require("lib.photomode")
local screenshot  = require("lib.screenshot")
local input       = require("lib.input")
local gamepad     = require("lib.gamepad")
local eventbridge = require("lib.eventbridge")

local State    = core.State
local Config   = core.Config
local logMsg   = core.logMsg
local dispatch = core.dispatch

local function dispatchBound(fn, isGamepad)
    if isGamepad then
        State.lastInputDevice = "gamepad"
    else
        State.lastInputDevice = "keyboard"
    end
    dispatch(fn)
    pcall(function() osd.updateOSD() end)
end

---------------------------------------------------------------------------- Key bindings

keybinds.bindWithFallback(keybinds.keyList(Config.toggle_key), nil, function(isPad)
    State.lastInputDevice = isPad and "gamepad" or "keyboard"
    if State.photoModeActive then dispatch(photomode.exitPhotoMode) else dispatch(photomode.enterPhotoMode) end
end, "Toggle PhotoMode")

keybinds.bindWithFallback(keybinds.keyList(Config.pause_key), nil, function(isPad) dispatchBound(photomode.togglePause, isPad) end, "Pause toggle")
keybinds.bindWithFallback(keybinds.keyList(Config.hud_key), nil, function(isPad) dispatchBound(photomode.toggleHUD, isPad) end, "HUD toggle")
keybinds.bindWithFallback(keybinds.keyList(Config.screenshot_key), nil, function(isPad) dispatchBound(screenshot.takeScreenshot, isPad) end, "Screenshot")
keybinds.bindWithFallback(keybinds.keyList(Config.fov_reset_key), nil, function(isPad) dispatchBound(camera.resetFOV, isPad) end, "FOV reset")

keybinds.bindWithFallback(keybinds.keyList(Config.move_up_key), nil, function(isPad)
    if State.photoModeActive then dispatchBound(function() camera.movePhotoCameraVertical(Config.vertical_speed) end, isPad) end
end, "Move Up")
keybinds.bindWithFallback(keybinds.keyList(Config.move_down_key), nil, function(isPad)
    if State.photoModeActive then dispatchBound(function() camera.movePhotoCameraVertical(-Config.vertical_speed) end, isPad) end
end, "Move Down")

keybinds.bindWithFallback(keybinds.keyList(Config.exit_guard_key), nil, function(isPad)
    if State.photoModeActive then
        logMsg("Exit guard: forcing PhotoMode exit")
        dispatchBound(photomode.exitPhotoMode, isPad)
    end
end, "Exit guard")

-- OSD toggle (Kwadrat on gamepad toggles both OSD & HUD clean view; F1 on keyboard)
keybinds.bindWithFallback(keybinds.keyList(Config.osd_toggle_key), nil, function(isPad)
    if isPad then
        dispatchBound(osd.toggleCleanView, true)
    else
        dispatchBound(osd.toggleOSD, false)
    end
end, "OSD toggle")

-- OSD reset (reset all settings to defaults)
keybinds.bindWithFallback(keybinds.keyList(Config.osd_reset_key), nil, function(isPad)
    if State.photoModeActive then dispatchBound(osd.osdReset, isPad) end
end, "OSD reset")

-- OSD navigation (only active in Photo Mode)
keybinds.bindWithFallback({"Up", "Gamepad_DPad_Up"}, nil, function()
    if State.photoModeActive then dispatch(function() osd.osdSelect(-1) end) end
end, "OSD Up")
keybinds.bindWithFallback({"Down", "Gamepad_DPad_Down"}, nil, function()
    if State.photoModeActive then dispatch(function() osd.osdSelect(1) end) end
end, "OSD Down")
keybinds.bindWithFallback({"Left", "Gamepad_DPad_Left"}, nil, function()
    if State.photoModeActive then dispatch(function() osd.osdAdjust(-1) end) end
end, "OSD Left")
keybinds.bindWithFallback({"Right", "Gamepad_DPad_Right"}, nil, function()
    if State.photoModeActive then dispatch(function() osd.osdAdjust(1) end) end
end, "OSD Right")

-- OSD tab navigation (PageUp/PageDown).
keybinds.bindWithFallback(keybinds.keyList(Config.osd_tab_prev_key), nil, function()
    if State.photoModeActive then dispatchBound(function() osd.osdTab(-1) end, false) end
end, "OSD Tab Prev")

keybinds.bindWithFallback(keybinds.keyList(Config.osd_tab_next_key), nil, function()
    if State.photoModeActive then dispatchBound(function() osd.osdTab(1) end, false) end
end, "OSD Tab Next")

---------------------------------------------------------------------------- Startup logs

-- Fail-safe: if a previous mod session crashed/exited while input isolation was
-- active, the player pawn may have been left with input disabled (softlock).
-- Force EnableInput on startup to recover control. Runs on the game thread.
dispatch(function() input.recoverInputOnStart() end)

-- Start gamepad poller immediately so L3+R3 chord works before entering PM.
dispatch(function() gamepad.startPoller() end)

-- Compatibility self-check: foreign UE4SS builds bind a different Lua API
-- surface (missing methods, different userdata wrappers). Probe the critical
-- calls and warn once so log readers can tell "unsupported build" from a mod
-- bug. Developed and tested against RE-UE4SS v1.2.1-rc6+ (UE4SS v3.0.1).
dispatch(function()
    local Subsystem = core.Subsystem
    local missing = {}
    local function probe(name, fn)
        local ok, res = pcall(fn)
        if not (ok and res ~= nil and res ~= false) then table.insert(missing, name) end
    end
    probe("ExecuteWithDelay", function() return ExecuteWithDelay or executeWithDelay end)
    local gs = Subsystem.gameplayStatics()
    if not gs then
        table.insert(missing, "GameplayStatics")
    else
        probe("SetGamePaused", function() return gs.SetGamePaused end)
        probe("FinishSpawningActor", function() return gs.FinishSpawningActor end)
    end
    local pc = Subsystem.playerController()
    local pawn = nil
    if pc then pcall(function() pawn = pc.Pawn or pc.Character end) end
    if pawn then
        probe("K2_GetComponentsByClass", function() return pawn.K2_GetComponentsByClass end)
        probe("component:IsValid", function()
            local cls = core.findStatic("/Script/Engine.ActorComponent")
            if not cls then return nil end
            local list = pawn:K2_GetComponentsByClass(cls)
            local c = list and list[1]
            return c and c.IsValid
        end)
    end
    if #missing > 0 then
        logMsg("WARNING: API self-check missing: %s", table.concat(missing, ", "))
        logMsg("WARNING: this UE4SS build may be incompatible - mod requires RE-UE4SS v1.2.1-rc6+ (UE4SS v3.0.1)")
    end
end)

logMsg("v%s ready.", core.VERSION)
if eventbridge.isAvailable() then
    logMsg("EventBridge: Active (v%s, global UE4SSLuaEventBridge)", eventbridge.getVersion())
else
    local _, why = eventbridge.isAvailable()
    logMsg("EventBridge: Not active (%s)", tostring(why))
end

if Config.debug then
    logMsg("Controls (Keyboard):")
    logMsg("  %s  - Enter/Exit Photo Mode", Config.toggle_key)
    logMsg("  %s   - Toggle HUD", Config.hud_key)
    logMsg("  %s - Toggle Pause", Config.pause_key)
    logMsg("  %s - Screenshot", Config.screenshot_key)
    logMsg("  %s  - FOV reset to %s", Config.fov_reset_key, tostring(Config.fov_default))
    logMsg("  %s   - Move camera UP", Config.move_up_key)
    logMsg("  %s   - Move camera DOWN", Config.move_down_key)
    logMsg("  %s - Force exit Photo Mode", Config.exit_guard_key)
    logMsg("  %s - Toggle OSD", Config.osd_toggle_key)
    logMsg("  Up/Down - Select   Left/Right - Adjust   %s - Reset (Photo Mode only)", Config.osd_reset_key)
    logMsg("Controls (Gamepad):")
    logMsg("  L3 (Triple-Tap)      - Enter / Exit Photo Mode")
    logMsg("  Left Stick / Look    - Flight & Rotation")
    logMsg("  LT / RT              - Camera Down / Up")
    logMsg("  D-Pad (Up/Down)      - Select row")
    logMsg("  D-Pad (Left/Right)   - Adjust value")
    logMsg("  LB / RB              - Previous / Next Tab")
    logMsg("  A / Cross            - Confirm / Action / Pause")
    logMsg("  X / Square           - Clean View (Toggle OSD + HUD)")
    logMsg("  B / Circle           - Screenshot")
    logMsg("  Y / Triangle         - Reset Settings")
    logMsg("  Menu / Start         - Exit Photo Mode")
    logMsg("  L3 (Click)           - Reset FOV")
end

local okSmoke, smoke = pcall(require, "lib.smoke_test")
if okSmoke and smoke and smoke.runSmokeTests then
    logMsg("  F10                  - Run In-Engine Smoke Tests")
    keybinds.bindWithFallback({"F10"}, nil, function()
        dispatch(smoke.runSmokeTests)
    end, "Smoke Tests")
end

