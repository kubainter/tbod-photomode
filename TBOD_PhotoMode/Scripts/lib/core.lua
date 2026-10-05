-- TBOD_PhotoMode core module
-- State, logging, config, subsystems, helpers, dispatch

local M = {}

M.VERSION = "1.6.2"

M.State = {
    photoModeActive = false,
    origDefaultFOV = nil,
    fov = 90.0,
    hudVisible = true,
    paused = false,
    stepEpoch = 0,
    hiddenWidgets = {},
    getCameraViewHooked = false,
    timeDilation = 1.0,
    roll = 0.0,
    origViewRollMin = nil,
    origViewRollMax = nil,
    origViewPitchMin = nil,
    origViewPitchMax = nil,
    playerHidden = false,
    playerPawn = nil,
    exiting = false,
    osdVisible = false,
    framingMode = "off",
    osdInputCaptured = false,
    lastInputDevice = "gamepad",
    disabledDialogueWidgets = {},
    screenshotInProgress = false,
    cachedPM = nil,
    cachedPhotoCamera = nil,
    cachedPC = nil,
    origCDO_bShouldPauseGame = true,
    origCDO_CameraMaxDistance = 1000.0,
    origCDO_CameraMovementSpeed = 1.0,
    origMaxSpeed = nil,
    origAcceleration = nil,
    origDeceleration = nil,
    origTurnRate = nil,
    origLookUpRate = nil,
    -- Caching for performance
    classToValidName = {},
    staticObjectCache = {},
    osdClasses = {},
    cachedGI = nil,
    cachedGVC = nil,
    cachedUserWidgets = nil,
    cachedToggleableContainers = nil,
    cachedBlankButtons = nil,
    cachedSequencePlayers = nil,
    -- Optics (Sprint 1.4.0) — SkyCreator-driven
    timeOfDay = 12.0,
    skyCreator = nil,
    origTimeOfDay = nil,
    dofEnabled = false,
    dofFstop = 1.4,
    focalDistance = 1000.0,
    exposureBias = 0.0,
    aspectRatioIdx = 1,
    aspectRatioValue = nil,
    weatherIdx = nil,
    weatherPresets = nil,
    weatherPresetsScanned = false,
    origWeatherSaved = false,
    dofPPComp = nil,
    uiFrontend = nil,
    viewWatchdogRunning = false,
    -- Cutscene PM state (Milestone 2)
    cutsceneCameraActor = nil,
    cutsceneCameraComponent = nil,
    origCutsceneCamCompRelRot = nil,
    origCutsceneActorRot = nil,
    origCutsceneRot = nil,
    origCutsceneExposure = nil,
    origCutsceneFocusSettings = nil,
    origCutsceneAperture = nil,
    -- Input isolation (Sprint 1.4.0)
    gameInputIsolated = false,
    isolatedPawn = nil,
    viewWasPhotoCam = false,
    photoCameraTickSaved = nil,
    suppressedContexts = nil,

    -- Clone/directing placement state (Sprint 1.5.0)
    cloneDist = 150.0,
    cloneSide = 0.0,
    cloneHeight = 0.0,
    cloneYaw = 180.0,

    -- Player pawn placement (PM move controls on target 0)
    playerMovePrepared = false,
    playerOrigLoc = nil,
    playerOrigRot = nil,
    origPlayerGravityScale = nil,
    origPlayerMovementMode = nil,
    origCapsuleCollisionEnabled = nil,
    origCapsuleProfileName = nil,

    -- Cutscene arbitration (force_cutscene_pm): sequence players paused on
    -- PM entry, resumed on exit. Entries: {player, prevDisableCameraCuts}.
    pausedSequences = {},
    -- Cutscene PM profile. This is deliberately separate from the legacy
    -- entry flag so every action can gate on an explicit mode.
    pmMode = "normal",
    cutsceneSession = nil,
    -- Cutscene PM entry flag: true when PM entered via force_cutscene_pm.
    -- Disables auto-freeze and manual F2 toggle (sequences drive pause).
    cutscenePMEntry = false,
    cutsceneFreezePending = false,
    -- Controller ignore flags snapshotted when a forced cutscene entry
    -- re-arms input for the photo camera; restored on exit.
    origIgnoreMove = nil,
    origIgnoreLook = nil,
}

M.OSD_BUILD_COUNT = 0
M.SCREENSHOT_COUNT = 0

function M.logMsg(fmt, ...)
    local msg = string.format(fmt, ...)
    print("[TBOD_PM] " .. msg .. "\n")
end

-- Verbose diagnostics — gated behind `debug = true` in photo_mode.ini.
function M.dbg(fmt, ...)
    if M.Config.debug then M.logMsg(fmt, ...) end
end

---------------------------------------------------------------------------- Config

M.Defaults = {
    toggle_key        = "F8",
    exit_guard_key    = "Escape, Gamepad_Special_Right",
    pause_key         = "F2, Gamepad_FaceButton_Bottom",
    hud_key           = "H",
    screenshot_key    = "P, Gamepad_FaceButton_Right, Gamepad_RightThumbstick",
    fov_reset_key     = "F3, Gamepad_LeftThumbstick",
    osd_reset_key     = "R, Gamepad_FaceButton_Top",
    move_up_key       = "E",
    move_down_key     = "Q",
    fov_default       = 90.0,
    fov_min           = 10.0,
    fov_max           = 170.0,
    fov_step          = 5.0,
    vertical_speed    = 10.0,
    camera_max_distance = 100000.0,
    camera_speed      = 4.0,
    slomo_step        = 0.5,
    slomo_min         = 0.02,
    slomo_max         = 1.0,
    roll_step         = 15.0,
    roll_max          = 90.0,
    exposure_step     = 0.25,
    osd_show_on_enter = true,
    osd_toggle_key   = "F1, Gamepad_FaceButton_Left",
    osd_scale        = 1.5,
    osd_tab_next_key = "PageDown",
    osd_tab_prev_key = "PageUp",

    -- Experimental (1.5.0):
    -- enable_experimental shows the Target/Pose/Spawn NPC/Frame Step OSD rows;
    -- force_cutscene_pm overrides the native CanActivatePhotomode guardian by
    -- pausing live cinematic sequences first (resumed on exit, 1.6.0).
    enable_experimental = true,
    force_cutscene_pm= false,

    -- Input Isolation (Sprint 1.4.0 — dark launch)
    enable_input_isolation = true,
    auto_exit_on_view_change = true,

    -- Auto-freeze on enter (1.5.0): on by default, mimics built-in photo
    -- modes; set 0 to keep the world running as in v1.4.x.
    pause_on_enter     = true,

    -- Clone/directing spawn offsets and step sizes (Sprint 1.5.0)
    clone_distance      = 150.0,
    clone_side          = 0.0,
    clone_height        = 0.0,
    clone_yaw           = 180.0,
    clone_step_fwd      = 10.0,
    clone_step_side     = 10.0,
    clone_step_height   = 5.0,
    clone_step_yaw      = 5.0,
    -- Max simultaneously spawned clones (1.6.0); 0 = no limit.
    max_clones          = 5,
    -- Verbose diagnostics (socket dumps, per-component scans) — release off.
    debug               = false,
}

M.Config = {}
for k, v in pairs(M.Defaults) do M.Config[k] = v end

function M.trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- UObject userdata wrappers can differ for the same underlying object;
-- compare by address (fall back to full name). Same helper as spawner's
-- local sameObject — shared here for camera/photomode ViewTarget checks.
function M.sameObject(a, b)
    if a == b then return true end
    if not (a and b) then return false end
    local okA, pa = pcall(function() return a:GetAddress() end)
    local okB, pb = pcall(function() return b:GetAddress() end)
    if okA and okB and pa and pb then return pa == pb end
    local okN, na = pcall(function() return a:GetFullName() end)
    local okM, nb = pcall(function() return b:GetFullName() end)
    return okN and okM and na == nb
end

function M.loadConfig(path)
    local f = io.open(path, "r")
    if not f then return false end
    for line in f:lines() do
        line = M.trim(line:gsub(";.*$", ""))
        if line == "" then
        elseif line:match("^%[(.+)%]$") then
        else
            local k, v = line:match("^([%w_]+)%s*=%s*(.*)$")
            if k and v and M.Config[k] ~= nil then
                k, v = M.trim(k), M.trim(v)
                if type(M.Defaults[k]) == "number" then
                    local num = tonumber((v:gsub(",", ".")))
                    if num then M.Config[k] = num end
                elseif type(M.Defaults[k]) == "string" then
                    M.Config[k] = v
                elseif type(M.Defaults[k]) == "boolean" then
                    M.Config[k] = (v:lower() == "true" or v == "1")
                end
            end
        end
    end
    f:close()
    return true
end

function M.resolveConfigPath()
    local candidates = {
        "ue4ss/Mods/TBOD_PhotoMode/Scripts/config/photo_mode.ini",
        "Mods/TBOD_PhotoMode/Scripts/config/photo_mode.ini",
        "Dawnwalker/Binaries/Win64/ue4ss/Mods/TBOD_PhotoMode/Scripts/config/photo_mode.ini",
    }
    for _, p in ipairs(candidates) do
        local f = io.open(p, "r")
        if f then f:close() return p end
    end
    return candidates[1]
end

-- Custom pose sections from photo_mode.ini: [CustomPose1], [CustomPose2], ...
M.CustomPoses = {}
function M.loadCustomPoses(path)
    M.CustomPoses = {}
    local f = io.open(path, "r")
    if not f then return end
    local section = nil
    for line in f:lines() do
        local sec = line:match("^%[CustomPose(%d+)%]$")
        if sec then
            section = tonumber(sec)
            M.CustomPoses[section] = {}
        elseif line:match("^%[") then
            section = nil -- any other section header ends the current CustomPose
        elseif section then
            local k, v = line:match("^([%w_]+)%s*=%s*(.*)$")
            if k and v then
                M.CustomPoses[section][k:lower()] = M.trim(v)
            end
        end
    end
    f:close()
end

-- Load config at module-load time
local configPath = M.resolveConfigPath()
if M.loadConfig(configPath) then
    M.loadCustomPoses(configPath)
    M.logMsg("Config loaded from %s", configPath)
else
    M.logMsg("Config file not found, using defaults")
end
M.State.fov = M.Config.fov_default
M.State.cloneDist = M.Config.clone_distance or M.State.cloneDist
M.State.cloneSide = M.Config.clone_side or M.State.cloneSide
M.State.cloneHeight = M.Config.clone_height or M.State.cloneHeight
M.State.cloneYaw = M.Config.clone_yaw or M.State.cloneYaw

function M.reloadConfig()
    local path = M.resolveConfigPath()
    if path and M.loadConfig(path) then
        M.loadCustomPoses(path)
        -- poses.lua merges CustomPoses lazily on next access (avoids a
        -- circular require from core).
        M.customPosesDirty = true
        M.logMsg("Config reloaded from %s", path)
        return true
    end
    return false
end

---------------------------------------------------------------------------- Subsystems

function M.isValidObject(obj)
    if not obj then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

function M.isValidInstance(obj)
    if not M.isValidObject(obj) then return false end
    local okName, name = pcall(function() return obj:GetFName():ToString() end)
    if okName and name and name:find("^Default__") then return false end
    return true
end

function M.isRealPlayerController(pc)
    if not M.isValidInstance(pc) then return false end
    local hasPCM = false
    pcall(function() hasPCM = pc.PlayerCameraManager and pc.PlayerCameraManager:IsValid() end)
    if not hasPCM then return false end
    local hasInput = false
    pcall(function() hasInput = pc.PlayerInput and pc.PlayerInput:IsValid() end)
    return hasInput
end

function M.isCutscenePM()
    return M.State.photoModeActive and M.State.pmMode == "cutscene"
end

function M.cutsceneBlocked(label)
    if not M.isCutscenePM() then return false end
    M.logMsg("Cutscene PM: %s disabled", label)
    return true
end

function M.findValid(classNames)
    -- Fast path: if we previously found which class name works, try it first.
    local classKey = table.concat(classNames, ",")
    local cachedName = M.State.classToValidName[classKey]
    if cachedName then
        local obj = FindFirstOf(cachedName)
        if M.isValidInstance(obj) then return obj end

        local list = nil
        pcall(function() list = FindAllOf(cachedName) end)
        if list and #list > 0 then
            for _, o in ipairs(list) do
                if M.isValidInstance(o) then return o end
            end
        end
    end

    for _, name in ipairs(classNames) do
        local list = nil
        pcall(function() list = FindAllOf(name) end)
        if list and #list > 0 then
            for _, obj in ipairs(list) do
                if M.isValidInstance(obj) then
                    M.State.classToValidName[classKey] = name
                    return obj
                end
            end
        end
        local obj = FindFirstOf(name)
        if M.isValidInstance(obj) then
            M.State.classToValidName[classKey] = name
            return obj
        end
    end
    return nil
end

function M.findStatic(path)
    if M.State.staticObjectCache[path] and M.isValidObject(M.State.staticObjectCache[path]) then
        return M.State.staticObjectCache[path]
    end
    local obj = StaticFindObject(path)
    if M.isValidObject(obj) then
        M.State.staticObjectCache[path] = obj
        return obj
    end
    return nil
end

M.Subsystem = {
    photoMode = function()
        if M.isValidInstance(M.State.cachedPM) then return M.State.cachedPM end
        M.State.cachedPM = nil
        local pm = M.findValid({"DogwoodPhotomodeSubsystem"})
        M.State.cachedPM = pm
        return pm
    end,
    playerController = function()
        if M.isRealPlayerController(M.State.cachedPC) then return M.State.cachedPC end
        M.State.cachedPC = nil

        local okH, helpers = pcall(require, "UEHelpers")
        if okH and helpers and helpers.GetPlayerController then
            local okPC, hPC = pcall(helpers.GetPlayerController)
            if okPC and M.isRealPlayerController(hPC) then
                M.State.cachedPC = hPC
                return hPC
            end
        end

        local classNames = {"BP_PlayerController_C", "DawnwalkerPlayerControllerBase", "PlayerController"}
        for _, name in ipairs(classNames) do
            local list = nil
            pcall(function() list = FindAllOf(name) end)
            if list and #list > 0 then
                for _, obj in ipairs(list) do
                    if M.isRealPlayerController(obj) then
                        M.State.cachedPC = obj
                        return obj
                    end
                end
            end
            local obj = FindFirstOf(name)
            if M.isRealPlayerController(obj) then
                M.State.cachedPC = obj
                return obj
            end
        end
        return nil
    end,
    slowMotion = function()
        return M.findValid({"SlowMotionSubsystem", "DogwoodSlowMotionSubsystem"})
    end,
    gameplayStatics = function() return M.findStatic("/Script/Engine.Default__GameplayStatics") end,
    kismetSystem = function() return M.findStatic("/Script/Engine.Default__KismetSystemLibrary") end,
    photoModeSettings = function() return M.findStatic("/Script/DogwoodSystem.Default__DogwoodPhotomodeSettings") end,
    automationUtils = function() return M.findStatic("/Script/AutomationUtils.Default__AutomationUtilsBlueprintLibrary") end,
    photoCamera = function()
        if M.isValidInstance(M.State.cachedPhotoCamera) then return M.State.cachedPhotoCamera end
        M.State.cachedPhotoCamera = nil
        local pm = nil
        if M.isValidInstance(M.State.cachedPM) then
            pm = M.State.cachedPM
        else
            pm = M.findValid({"DogwoodPhotomodeSubsystem"})
            M.State.cachedPM = pm
        end
        if M.isValidInstance(pm) then
            local okCam, cam = pcall(function() return pm.PhotoCamera end)
            if okCam and M.isValidInstance(cam) then
                M.State.cachedPhotoCamera = cam
                return cam
            end
        end
        local cam = M.findValid({"PhotoCameraActor"})
        M.State.cachedPhotoCamera = cam
        return cam
    end,
}

function M.getActiveCutsceneCamera()
    if M.isValidObject(M.State.cutsceneCameraComponent) or M.isValidObject(M.State.cutsceneCameraActor) then
        local vt = M.State.cutsceneCameraActor
        local camComp = M.State.cutsceneCameraComponent
        if vt and vt:IsValid() and not (camComp and camComp:IsValid()) then
            pcall(function() camComp = vt.CameraComponent end)
            if not camComp or not camComp:IsValid() then
                pcall(function() camComp = vt.DialogueCameraComponent end)
            end
            if not camComp or not camComp:IsValid() then
                pcall(function() camComp = vt.CineCameraComponent end)
            end
        end
        return vt, camComp
    end
    local pc = M.Subsystem.playerController()
    local pcm = pc and pc.PlayerCameraManager
    if not (pcm and pcm:IsValid() and pcm.ViewTarget and pcm.ViewTarget.Target) then
        return nil, nil
    end
    local vt = pcm.ViewTarget.Target
    local camComp = nil
    pcall(function() camComp = vt.CameraComponent end)
    if not camComp or not camComp:IsValid() then
        pcall(function() camComp = vt.DialogueCameraComponent end)
    end
    if not camComp or not camComp:IsValid() then
        pcall(function() camComp = vt.CineCameraComponent end)
    end
    return vt, camComp
end

function M.isPhotomodeActiveNative()
    local pm = M.Subsystem.photoMode()
    if not pm then return false end
    local ok, active = pcall(function() return pm:IsPhotomodeActive() end)
    return ok and (active == true)
end

function M.consoleCommand(cmd)
    local k = M.Subsystem.kismetSystem()
    local pc = M.Subsystem.playerController()
    if not k or not pc then return false end
    return pcall(function() k:ExecuteConsoleCommand(pc, cmd, pc) end)
end

function M.setCVar(name, value)
    return M.consoleCommand(name .. " " .. tostring(value))
end

-- Snapshot a console variable before we touch it — the PM statelessness rule
-- forbids restoring hardcoded values over the user's own settings.
function M.getCVarInt(name)
    local k = M.Subsystem.kismetSystem()
    if k then
        local ok, v = pcall(function() return k:GetConsoleVariableIntValue(name) end)
        if ok and type(v) == "number" then return v end
    end
    -- Fallback: UKismetSystemLibrary::GetConsoleVariableIntValue is not
    -- reflectable in this build. UPlayer::ConsoleCommand echoes
    -- 'r.Foo = "N"  (Help: ...)' for a bare CVar name — parse the value.
    local pc = M.Subsystem.playerController()
    if pc then
        -- Diagnostics: this path also failed in the field — log what the call
        -- actually returns so the snapshot gap is identifiable.
        local ok, res = pcall(function() return pc:ConsoleCommand(name, false) end)
        M.dbg("getCVarInt(%s): ConsoleCommand ok=%s res=%s",
            name, tostring(ok), tostring(res))
        if ok and type(res) == "string" then
            local n = res:match('"(%-?%d+)"') or res:match('=%s*(%-?%d+)') or res:match('(%-?%d+)')
            if n then return tonumber(n) end
        end
    end
    return nil
end

-- PM freeze helper: SetGamePaused stops actor/component ticks, stalling NPC
-- appearance assembly and anim evaluation — mark the actor + components
-- bTickEvenWhenPaused so they finish while the world is frozen.
-- Pass `saved` (a table) to record previous flags for restoration on exit.
function M.setActorTickableWhenPaused(actor, enabled, saved)
    if not (actor and actor:IsValid()) then return end
    pcall(function()
        if saved then saved.actorFlag = actor.PrimaryActorTick.bTickEvenWhenPaused end
        actor.PrimaryActorTick.bTickEvenWhenPaused = enabled
    end)
    local compCls = M.findStatic("/Script/Engine.ActorComponent")
    if not compCls then return end
    local okL, list = pcall(function() return actor:K2_GetComponentsByClass(compCls) end)
    if not (okL and list) then return end
    for _, c in ipairs(list) do
        -- pcall the IsValid probe itself: foreign UE4SS builds return
        -- component userdata without the method -> degrade silently.
        local okV, valid = pcall(function() return c and c:IsValid() end)
        if okV and valid then
            pcall(function()
                if saved then saved[c] = c.PrimaryComponentTick.bTickEvenWhenPaused end
                c.PrimaryComponentTick.bTickEvenWhenPaused = enabled
            end)
            pcall(function() c:SetTickableWhenPaused(enabled) end)
        end
    end
end

function M.restoreActorTickable(actor, saved)
    if not saved then return end
    if actor and actor:IsValid() and saved.actorFlag ~= nil then
        pcall(function() actor.PrimaryActorTick.bTickEvenWhenPaused = saved.actorFlag end)
    end
    for c, v in pairs(saved) do
        local okV, valid = pcall(function() return c and c:IsValid() end)
        if c ~= "actorFlag" and okV and valid then
            pcall(function() c.PrimaryComponentTick.bTickEvenWhenPaused = v end)
        end
    end
end

---------------------------------------------------------------------------- Game-thread queue

function M.dispatch(fn)
    ExecuteInGameThread(function()
        local ok, err = pcall(fn)
        if not ok then M.logMsg("error: %s", tostring(err)) end
    end)
end

-- Delayed callback that runs ON THE GAME THREAD. Async-thread callbacks give
-- created UObjects the Async GC-keep flag: never collected even pending-kill,
-- they keep Outer->Level->World alive and trip the world-leak check on save
-- load (TIK-008); mutating renderable comps off the game thread also races
-- the render thread. Prefer the native game-thread delay API when present.
function M.delayGameThread(ms, fn)
    local gtDelay = ExecuteInGameThreadWithDelay
    if gtDelay then
        local ok = pcall(function()
            gtDelay(ms, function()
                local okI, errI = pcall(fn)
                if not okI then M.logMsg("delayGameThread: %s", tostring(errI)) end
            end)
        end)
        if ok then return true end
    end
    local delayFn = ExecuteWithDelay or executeWithDelay
    if not delayFn then return false end
    local ok = pcall(function()
        delayFn(ms, function()
            M.dispatch(fn)
        end)
    end)
    return ok
end

function M.clearCaches()
    M.State.cachedPM = nil
    M.State.cachedPhotoCamera = nil
    M.State.cachedPC = nil
    M.State.suppressedContexts = nil
    M.State.classToValidName = {}
    M.State.staticObjectCache = {}
    M.State.osdClasses = {}
    M.State.cachedGI = nil
    M.State.cachedGVC = nil
    M.State.cachedUserWidgets = nil
    M.State.cachedToggleableContainers = nil
    M.State.cachedBlankButtons = nil
    M.State.cachedSequencePlayers = nil
end

return M




