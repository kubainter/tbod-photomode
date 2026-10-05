-- lib/eventbridge.lua
-- Wrapper around _ModCore_UE4SSLuaEventBridge (v1.0.7) for TBOD_PhotoMode
-- Connects UE 5.5 Enhanced Input events to Photo Mode actions
-- Meets Rule 8 (PM Statelessness): full unbind and target closure on cleanup.

local core = require("lib.core")
local logMsg = core.logMsg

local M = {}

-- Internal tracking of opened targets and bindings for strict statelessness
local activeTargets = {}       -- targetHandle -> { componentPath = str, openedAt = num }
local activeBindings = {}      -- bindHandle -> { targetHandle = num, actionPath = str, eventType = str }

---------------------------------------------------------------------------- Availability & diagnostics

function M.isAvailable()
    if type(UE4SSLuaEventBridge) ~= "table" then
        return false, "UE4SSLuaEventBridge global is nil or not a table"
    end
    if type(UE4SSLuaEventBridge.OpenInputComponent) ~= "function" or
       type(UE4SSLuaEventBridge.BindAction) ~= "function" then
        return false, "UE4SSLuaEventBridge missing expected functions"
    end
    return true
end

function M.getVersion()
    if not M.isAvailable() then return nil end
    local ok, ver = pcall(function() return UE4SSLuaEventBridge.GetVersion() end)
    if ok and ver then return tostring(ver) end
    return "unknown"
end

function M.getCapabilities()
    if not M.isAvailable() then return nil end
    local ok, caps = pcall(function() return UE4SSLuaEventBridge.GetCapabilities() end)
    if ok and caps then return caps end
    return nil
end

---------------------------------------------------------------------------- Gamepad active detection (CommonInputSubsystem)

function M.getCommonInputSubsystem(pc)
    pc = pc or core.Subsystem.playerController()
    if not (pc and pc:IsValid()) then return nil end

    local sbl = core.findStatic("/Script/Engine.Default__SubsystemBlueprintLibrary")
    local cisCls = core.findStatic("/Script/CommonInput.CommonInputSubsystem")
    if not (sbl and cisCls) then return nil end

    local cis = nil
    pcall(function()
        cis = sbl:GetLocalPlayerSubSystemFromPlayerController(pc, cisCls)
    end)
    if cis and cis:IsValid() then return cis end
    return nil
end

-- Returns true if the last active input device is Gamepad (ECommonInputType::Gamepad == 1)
function M.isGamepadActive(pc)
    local cis = M.getCommonInputSubsystem(pc)
    if cis then
        local ok, inputType = pcall(function() return cis:GetCurrentInputType() end)
        if ok and inputType ~= nil then
            if inputType == 1 or tostring(inputType):lower():find("gamepad") ~= nil then
                return true
            elseif inputType == 0 or tostring(inputType):lower():find("mouse") ~= nil then
                return false
            end
        end
    end
    return core.State.lastInputDevice == "gamepad"
end

function M.getCurrentGamepadName(pc)
    local cis = M.getCommonInputSubsystem(pc)
    if cis then
        local ok, name = pcall(function()
            local n = cis:GetCurrentGamepadName()
            return n and n:ToString()
        end)
        if ok and name then return name end
    end
    return nil
end

---------------------------------------------------------------------------- Component path resolution

-- Extracts the live object path string from a UObject or string
function M.resolveComponentPath(componentOrActor)
    if type(componentOrActor) == "string" and #componentOrActor > 0 then
        return componentOrActor
    end

    if not componentOrActor then return nil, "componentOrActor is nil" end

    local okV, valid = pcall(function() return componentOrActor:IsValid() end)
    if not (okV and valid) then
        return nil, "target object is invalid or not a UObject"
    end

    -- Check if componentOrActor itself is already an EnhancedInputComponent
    local targetComp = componentOrActor
    local isComp = false
    local okComp, compCheck = pcall(function()
        return targetComp:IsA("/Script/EnhancedInput.EnhancedInputComponent")
    end)
    if okComp and compCheck then
        isComp = true
    end

    if not isComp then
        -- Check if it's APhotoCameraActor (has EnhancedInput property)
        local okEI, ei = pcall(function() return componentOrActor.EnhancedInput end)
        if okEI and ei and ei:IsValid() then
            targetComp = ei
        else
            -- Check if it's APlayerController (has InputComponent or OnlyMovementInputComponent)
            local okIC, ic = pcall(function() return componentOrActor.InputComponent end)
            if okIC and ic and ic:IsValid() then
                targetComp = ic
            else
                local okOMI, omi = pcall(function() return componentOrActor.OnlyMovementInputComponent end)
                if okOMI and omi and omi:IsValid() then
                    targetComp = omi
                end
            end
        end
    end

    -- Verify resolved targetComp
    local okV2, valid2 = pcall(function() return targetComp and targetComp:IsValid() end)
    if not (okV2 and valid2) then
        return nil, "could not locate valid EnhancedInputComponent on actor"
    end

    -- Get exact object path via GetPathName
    local okPath, path = pcall(function() return targetComp:GetPathName() end)
    if okPath and type(path) == "string" and #path > 0 then
        return path
    end

    -- Fallback to GetFullName() without class prefix
    local okFull, full = pcall(function() return targetComp:GetFullName() end)
    if okFull and type(full) == "string" and #full > 0 then
        local p = full:match("^%S+%s+(.+)$")
        if p and #p > 0 then return p end
        return full
    end

    return nil, "failed to obtain path from EnhancedInputComponent"
end

---------------------------------------------------------------------------- Active component discovery

function M.findActiveInputComponent(photoActor, pc)
    if photoActor then
        local okA, valA = pcall(function() return photoActor:IsValid() end)
        if okA and valA then
            local okEI, ei = pcall(function() return photoActor.EnhancedInput end)
            if okEI and ei and ei:IsValid() then
                return ei
            end
        end
    end

    if pc then
        local okP, valP = pcall(function() return pc:IsValid() end)
        if okP and valP then
            local okIC, ic = pcall(function() return pc.InputComponent end)
            if okIC and ic and ic:IsValid() then
                return ic
            end
            local okOMI, omi = pcall(function() return pc.OnlyMovementInputComponent end)
            if okOMI and omi and omi:IsValid() then
                return omi
            end
        end
    end

    return nil
end

---------------------------------------------------------------------------- Lifecycle & Binding wrappers

-- OpenComponent: returns targetHandle (positive integer) or nil, err
function M.openComponent(componentOrActor)
    local avail, why = M.isAvailable()
    if not avail then return nil, why end

    local compPath, pathErr = M.resolveComponentPath(componentOrActor)
    if not compPath then return nil, pathErr end

    local ok, targetHandle, err = pcall(function()
        return UE4SSLuaEventBridge.OpenInputComponent(compPath)
    end)
    if not ok then
        return nil, "OpenInputComponent exception: " .. tostring(targetHandle)
    end
    if not targetHandle then
        return nil, err or "OpenInputComponent returned nil"
    end

    activeTargets[targetHandle] = {
        componentPath = compPath,
        openedAt = os.clock(),
    }
    core.dbg("EventBridge: Opened component '%s' -> target %d", compPath, targetHandle)
    return targetHandle
end

-- Bind: returns bindHandle or nil, err
function M.bind(targetHandle, actionPath, eventType, callback)
    local avail, why = M.isAvailable()
    if not avail then return nil, why end

    if not targetHandle or type(targetHandle) ~= "number" then
        return nil, "invalid targetHandle"
    end
    if type(actionPath) ~= "string" or #actionPath == 0 then
        return nil, "invalid actionPath"
    end
    if type(callback) ~= "function" then
        return nil, "callback must be a function"
    end

    local phase = eventType or "Triggered"

    -- Wrap callback with error protection and game-thread guarantee
    local function safeCallback(event)
        local ok, err = pcall(callback, event)
        if not ok then
            logMsg("EventBridge callback error on %s (%s): %s", actionPath, phase, tostring(err))
        end
    end

    local ok, bindHandle, err = pcall(function()
        return UE4SSLuaEventBridge.BindAction(targetHandle, actionPath, phase, safeCallback)
    end)
    if not ok then
        return nil, "BindAction exception: " .. tostring(bindHandle)
    end
    if not bindHandle then
        return nil, err or "BindAction returned nil"
    end

    activeBindings[bindHandle] = {
        targetHandle = targetHandle,
        actionPath = actionPath,
        eventType = phase,
    }
    core.dbg("EventBridge: Bound action '%s' (%s) -> handle %d", actionPath, phase, bindHandle)
    return bindHandle
end

-- Unbind: unbinds a specific action binding
function M.unbind(bindHandle)
    if not bindHandle or type(bindHandle) ~= "number" then return false, "invalid bindHandle" end
    local info = activeBindings[bindHandle]
    if not info then return false, "bindHandle not tracked" end

    local avail = M.isAvailable()
    if avail then
        pcall(function() UE4SSLuaEventBridge.Unbind(bindHandle) end)
    end
    activeBindings[bindHandle] = nil
    return true
end

-- CloseComponent: closes a target handle and unbinds its actions
function M.closeComponent(targetHandle)
    if not targetHandle or type(targetHandle) ~= "number" then return false, "invalid targetHandle" end
    if not activeTargets[targetHandle] then return false, "targetHandle not tracked" end

    -- Unbind all actions registered on this target
    local toRemove = {}
    for bh, info in pairs(activeBindings) do
        if info.targetHandle == targetHandle then
            toRemove[#toRemove + 1] = bh
        end
    end
    for _, bh in ipairs(toRemove) do
        M.unbind(bh)
    end

    local avail = M.isAvailable()
    local okClose = false
    if avail then
        local ok, res = pcall(function() return UE4SSLuaEventBridge.CloseInputComponent(targetHandle) end)
        okClose = ok and res
    end
    activeTargets[targetHandle] = nil
    core.dbg("EventBridge: Closed target %d", targetHandle)
    return okClose
end

-- UnbindAll / cleanup: full stateless teardown of all bindings and targets
function M.unbindAll()
    pmTargetHandle = nil
    pmBindings = {}

    local avail = M.isAvailable()
    local targetCount = M.count(activeTargets)
    local bindCount = M.count(activeBindings)
    if targetCount > 0 or bindCount > 0 then
        core.dbg("EventBridge: Cleaning up %d active target(s) and %d binding(s)", targetCount, bindCount)
    end

    -- 1. Unbind individual tracked bindings
    local bindingHandles = {}
    for bh in pairs(activeBindings) do bindingHandles[#bindingHandles + 1] = bh end
    for _, bh in ipairs(bindingHandles) do
        M.unbind(bh)
    end

    -- 2. Close individual tracked targets
    local targets = {}
    for th in pairs(activeTargets) do targets[#targets + 1] = th end
    for _, th in ipairs(targets) do
        if avail then
            pcall(function() UE4SSLuaEventBridge.CloseInputComponent(th) end)
        end
    end

    -- 3. Native bulk unbind if available
    if avail and type(UE4SSLuaEventBridge.UnbindAll) == "function" then
        pcall(function() UE4SSLuaEventBridge.UnbindAll() end)
    end

    activeTargets = {}
    activeBindings = {}
    return true
end

M.cleanup = M.unbindAll

---------------------------------------------------------------------------- Photo Mode D-Pad bindings (Step 3)

local pmTargetHandle = nil
local pmBindings = {}

local QUICKSLOT_ACTIONS = {
    Top    = "/Game/_Dawnwalker/Player/Input/Actions/Quickslots/IA_Quickslot_Top.IA_Quickslot_Top",
    Bottom = "/Game/_Dawnwalker/Player/Input/Actions/Quickslots/IA_Quickslot_Bottom.IA_Quickslot_Bottom",
    Left   = "/Game/_Dawnwalker/Player/Input/Actions/Quickslots/IA_Quickslot_Left.IA_Quickslot_Left",
    Right  = "/Game/_Dawnwalker/Player/Input/Actions/Quickslots/IA_Quickslot_Right.IA_Quickslot_Right",
}

function M.isPhotoModeBound()
    return pmTargetHandle ~= nil and #pmBindings > 0
end

function M.teardownPhotoModeBindings()
    if pmTargetHandle then
        M.closeComponent(pmTargetHandle)
        pmTargetHandle = nil
        pmBindings = {}
        logMsg("EventBridge: D-Pad OSD bindings torn down")
    end
end

function M.setupPhotoModeBindings(photoActor, pc)
    if not M.isAvailable() then return false, "EventBridge unavailable" end

    M.teardownPhotoModeBindings()

    pc = pc or core.Subsystem.playerController()

    -- We bind on the player controller's InputComponent where IMC_Base routes quickslots
    local comp = nil
    if pc and pc:IsValid() then
        local okIC, ic = pcall(function() return pc.InputComponent end)
        if okIC and ic and ic:IsValid() then comp = ic end
    end
    if not comp and photoActor and photoActor:IsValid() then
        local okEI, ei = pcall(function() return photoActor.EnhancedInput end)
        if okEI and ei and ei:IsValid() then comp = ei end
    end
    if not comp then
        comp = M.findActiveInputComponent(photoActor, pc)
    end
    if not comp then
        logMsg("EventBridge: Could not locate active EnhancedInputComponent for PhotoMode bindings")
        return false, "component not found"
    end

    local target, err = M.openComponent(comp)
    if not target then
        logMsg("EventBridge: Failed to open component for PhotoMode bindings: %s", tostring(err))
        return false, err
    end
    pmTargetHandle = target

    local osd = require("lib.osd")
    local State = core.State

    -- Bind D-Pad Top -> OSD Up (Select -1)
    local bTop = M.bind(target, QUICKSLOT_ACTIONS.Top, "Triggered", function(event)
        core.dispatch(function()
            if not State.photoModeActive then return end
            if not M.isGamepadActive(pc) then return end
            if not State.osdVisible then osd.showOSD() else osd.osdSelect(-1) end
        end)
    end)
    if bTop then pmBindings[#pmBindings + 1] = bTop end

    -- Bind D-Pad Bottom -> OSD Down (Select +1)
    local bBottom = M.bind(target, QUICKSLOT_ACTIONS.Bottom, "Triggered", function(event)
        core.dispatch(function()
            if not State.photoModeActive then return end
            if not M.isGamepadActive(pc) then return end
            if not State.osdVisible then osd.showOSD() else osd.osdSelect(1) end
        end)
    end)
    if bBottom then pmBindings[#pmBindings + 1] = bBottom end

    -- Bind D-Pad Left -> OSD Left (Adjust -1)
    local bLeft = M.bind(target, QUICKSLOT_ACTIONS.Left, "Triggered", function(event)
        core.dispatch(function()
            if not State.photoModeActive then return end
            if not M.isGamepadActive(pc) then return end
            if not State.osdVisible then osd.showOSD() else osd.osdAdjust(-1) end
        end)
    end)
    if bLeft then pmBindings[#pmBindings + 1] = bLeft end

    -- Bind D-Pad Right -> OSD Right (Adjust +1)
    local bRight = M.bind(target, QUICKSLOT_ACTIONS.Right, "Triggered", function(event)
        core.dispatch(function()
            if not State.photoModeActive then return end
            if not M.isGamepadActive(pc) then return end
            if not State.osdVisible then osd.showOSD() else osd.osdAdjust(1) end
        end)
    end)
    if bRight then pmBindings[#pmBindings + 1] = bRight end

    logMsg("EventBridge: D-Pad OSD bindings registered on target %d (%d bindings)",
        target, #pmBindings)
    return true
end

function M.count(tbl)
    local n = 0
    for _ in pairs(tbl) do n = n + 1 end
    return n
end

function M.getActiveCounts()
    return M.count(activeTargets), M.count(activeBindings)
end

return M
