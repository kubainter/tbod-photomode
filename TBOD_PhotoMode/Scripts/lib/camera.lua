-- TBOD_PhotoMode camera module
-- GetCameraView hook, FOV, Roll, vertical movement

local core = require("lib.core")
local State = core.State
local Config = core.Config
local Subsystem = core.Subsystem
local logMsg = core.logMsg
local dbg = core.dbg

local M = {}

---------------------------------------------------------------------------- FOV: GetCameraView hook

local hookDiagLogged = false

function M.hookGetCameraView()
    if State.getCameraViewHooked then return end
    local ok, err = pcall(function()
        RegisterHook("/Script/Engine.CameraComponent:GetCameraView", function(self, deltaTime, outDesiredView)
            if not hookDiagLogged then
                hookDiagLogged = true
                dbg("GetCameraView hook fired (diagnostic)")
            end
            if not State.photoModeActive then return end

            -- In cutscene PM the native photomode is deliberately deactivated
            -- by the paused sequence — skip this liveness check.
            if not State.cutscenePMEntry and not core.isPhotomodeActiveNative() then
                if not State.exiting then
                    State.exiting = true
                    core.dispatch(function()
                        if State.photoModeActive then
                            pcall(function() require("lib.photomode").exitPhotoMode() end)
                        end
                        State.exiting = false
                    end)
                end
                return
            end

            -- ViewTarget theft watchdog: force a clean exit if the game stole
            -- the view (menu, map, cutscene) while PM is active. Alarm only
            -- after the photo cam was the view target once (avoids a false
            -- trigger during the entry blend). Runs on every camera's
            -- GetCameraView — once stolen, the photo cam stops ticking.
            if Config.auto_exit_on_view_change and not State.exiting then
                local photoCam = Subsystem.photoCamera()
                local pc = Subsystem.playerController()
                local pcm = pc and pc.PlayerCameraManager
                local curTarget = nil
                if pcm and pcm:IsValid() then
                    pcall(function()
                        if pcm.ViewTarget then curTarget = pcm.ViewTarget.Target end
                    end)
                end

                -- Case A: photo camera destroyed while PhotoMode was armed ->
                -- the game force-deactivated the native photomode.
                if State.viewWasPhotoCam and (not photoCam or not photoCam:IsValid()) then
                    logMsg("Watchdog: PhotoCameraActor destroyed - forcing exit")
                    State.exiting = true
                    core.dispatch(function()
                        if State.photoModeActive then
                            pcall(function() require("lib.photomode").exitPhotoMode() end)
                        end
                        State.exiting = false
                    end)
                    return
                end

                -- Case B: view stolen by another actor (inventory, map, menu).
                if curTarget and curTarget:IsValid() and photoCam and photoCam:IsValid() then
                    if core.sameObject(curTarget, photoCam) then
                        State.viewWasPhotoCam = true
                    elseif State.viewWasPhotoCam then
                        local tgtName = "unknown"
                        pcall(function() tgtName = curTarget:GetFullName() end)
                        logMsg("Watchdog: ViewTarget stolen (%s) - forcing exit", tostring(tgtName))
                        State.exiting = true
                        core.dispatch(function()
                            if State.photoModeActive then
                                pcall(function() require("lib.photomode").exitPhotoMode() end)
                            end
                            State.exiting = false
                        end)
                        return
                    end
                end
            end

            local okOwner, owner = pcall(function() return self:GetOwner() end)
            if okOwner and owner and owner:IsValid() then
                local photoCam = Subsystem.photoCamera()
                local isPhotoCam = false
                local ownerName = ""
                pcall(function() ownerName = owner:GetFullName() end)
                local compName = ""
                pcall(function() compName = self:GetFullName() end)
                if photoCam and photoCam:IsValid() and core.sameObject(owner, photoCam) then
                    isPhotoCam = true
                elseif ownerName:find("PhotoCamera") or compName:find("PhotoCamera") then
                    isPhotoCam = true
                end

                if isPhotoCam then
                    pcall(function() outDesiredView.FOV = State.fov end)
                    pcall(function() outDesiredView:set("FOV", State.fov) end)
                    if State.roll and State.roll ~= 0.0 then
                        pcall(function()
                            local rot = outDesiredView.Rotation
                            if rot then
                                rot.Roll = State.roll
                                outDesiredView.Rotation = rot
                                pcall(function() outDesiredView:set("Rotation", rot) end)
                            end
                        end)
                    end
                    if State.exposureBias and State.exposureBias ~= 0.0 then
                        pcall(function()
                            local pps = outDesiredView.PostProcessSettings
                            if pps then
                                pps.bOverride_AutoExposureBias = true
                                pps.AutoExposureBias = State.exposureBias
                                outDesiredView.PostProcessSettings = pps
                            end
                            outDesiredView.PostProcessBlendWeight = 1.0
                            outDesiredView:set("PostProcessSettings", pps)
                            outDesiredView:set("PostProcessBlendWeight", 1.0)
                        end)
                    end
                end
            end
        end)
    end)
    if ok then
        State.getCameraViewHooked = true
        dbg("GetCameraView hook registered")
    else
        logMsg("GetCameraView hook failed: %s", tostring(err))
    end
end

---------------------------------------------------------------------------- Menu detection (shared)
-- Returns true + layer/widget name when a game menu widget is active on the
-- WBP_UIFrontend layer stacks (pause menu, inventory, map, journal...).
-- GetActiveWidget() (not GetNumWidgets()): CommonUI keeps pooled/deactivated
-- widgets on the stack, so a count > 0 can stay true after the menu closes.
function M.isMenuOpen()
    local frontend = State.uiFrontend
    if not (frontend and frontend:IsValid()) then
        frontend = core.findValid({"WBP_UIFrontend_C"})
        State.uiFrontend = frontend
    end
    if not (frontend and frontend:IsValid()) then return false end
    -- Dedicated menu stacks eject unconditionally; shared game layers
    -- (GameLayer hosts the GameHub window but also gameplay widgets) eject
    -- only when the active widget's class path matches a known GameHub token.
    -- GameplayDialogueLayer is skipped: its HUD container is always active.
    for _, layerName in ipairs({
        "GameMenuLayer", "GameMenuTutorialLayer", "MenuLayer", "ModalLayer",
        "GameLayer", "GameOverlayLayer",
    }) do
        local stack = nil
        pcall(function() stack = frontend[layerName] end)
        if stack and stack:IsValid() then
            local aw = nil
            pcall(function() aw = stack:GetActiveWidget() end)
            local visible = false
            if aw and aw:IsValid() then
                -- Require a successful IsVisible()==true: a transient API
                -- failure must not force a watchdog exit.
                local okV, vis = pcall(function() return aw:IsVisible() end)
                if okV then
                    visible = (vis == true)
                else
                    logMsg("Menu detect: IsVisible failed on %s", layerName)
                end
            end
            if visible then
                local wname = "?"
                pcall(function() wname = aw:GetFullName() end)
                local menuLayer = layerName == "GameMenuLayer"
                    or layerName == "GameMenuTutorialLayer"
                    or layerName == "MenuLayer" or layerName == "ModalLayer"
                local takeover = wname:find("GameHub") or wname:find("WBP_Map_")
                    or wname:find("Inventory") or wname:find("Journal")
                    or wname:find("PauseMenu") or wname:find("MainMenu")
                    or wname:find("GameMenu")
                    or wname:find("Crafting") or wname:find("Vendor")
                    or wname:find("CharacterDevelopment") or wname:find("Bestiary")
                    or wname:find("Glossary") or wname:find("Settings")
                    or wname:find("GameOver") or wname:find("Death")
                if menuLayer or takeover then
                    return true, layerName, wname
                end
            end
        end
    end
    return false
end

-- Return the active dialogue widget without treating ordinary gameplay HUD as
-- a menu. CommonUI dialogue can live on GameplayDialogueLayer, which is
-- intentionally excluded from isMenuOpen().
function M.getActiveDialogueWidget()
    local frontend = State.uiFrontend
    if not (frontend and frontend:IsValid()) then
        frontend = core.findValid({"WBP_UIFrontend_C"})
        State.uiFrontend = frontend
    end
    if not (frontend and frontend:IsValid()) then return nil end

    for _, layerName in ipairs({
        "GameplayDialogueLayer", "GameMenuLayer", "GameMenuTutorialLayer",
        "MenuLayer", "ModalLayer", "GameLayer", "GameOverlayLayer",
    }) do
        local stack = nil
        pcall(function() stack = frontend[layerName] end)
        if stack and stack:IsValid() then
            local aw = nil
            pcall(function() aw = stack:GetActiveWidget() end)
            if aw and aw:IsValid() then
                local name = ""
                pcall(function() name = aw:GetFullName() end)
                if tostring(name):find("WBP_Dialogue", 1, true)
                    or tostring(name):find("Dialogue", 1, true) then
                    return aw
                end
            end
        end
    end
    return nil
end

---------------------------------------------------------------------------- ViewTarget watchdog (poller)
-- GetCameraView is invoked natively, not through ProcessEvent — the hook may
-- never fire, so this poller is the primary view-theft detector.

function M.startWatchdog()
    if State.viewWatchdogRunning then return end

    local delayFn = ExecuteWithDelay or executeWithDelay
    if not delayFn then
        logMsg("Watchdog: no delay function available - poller dead")
        return
    end
    State.viewWatchdogRunning = true

    local function forceExit(reason)
        logMsg("Watchdog: %s - forcing exit", reason)
        State.exiting = true
        core.dispatch(function()
            if State.photoModeActive then
                pcall(function() require("lib.photomode").exitPhotoMode() end)
            end
            State.exiting = false
        end)
    end

    local function poll()
        if not State.photoModeActive then
            State.viewWatchdogRunning = false
            return
        end

        -- In cutscene PM the native photomode is deliberately deactivated
        -- by the paused sequence — skip this liveness check.
        if not State.cutscenePMEntry and not core.isPhotomodeActiveNative() then
            if not State.exiting then
                forceExit("native photomode deactivated externally")
            end
            State.viewWatchdogRunning = false
            return
        end

        if State.cutscenePMEntry then
            local gs = Subsystem.gameplayStatics()
            local pc = Subsystem.playerController()
            local actuallyPaused = false
            if gs and pc then
                pcall(function() actuallyPaused = gs:IsGamePaused(pc) == true end)
            end
            if not actuallyPaused and not State.cutsceneFreezePending then
                State.cutsceneFreezePending = true
                core.dispatch(function()
                    local gs2 = Subsystem.gameplayStatics()
                    local pc2 = Subsystem.playerController()
                    if State.photoModeActive and State.cutscenePMEntry and gs2 and pc2 then
                        local okPause, result = pcall(function() return gs2:SetGamePaused(pc2, true) end)
                        if okPause and result ~= false then
                            State.paused = true
                            logMsg("Pause: reasserted (Cutscene PM watchdog)")
                        else
                            logMsg("WARN: Cutscene PM watchdog freeze failed")
                        end
                    end
                    State.cutsceneFreezePending = false
                end)
            end
            pcall(function() require("lib.photomode").rearmCutsceneInput() end)
            if State.osdVisible then
                pcall(function() require("lib.input").setOSDInputCapture(true) end)
            end
        end

        if Config.auto_exit_on_view_change and not State.exiting then
            local photoCam = Subsystem.photoCamera()
            local pc = Subsystem.playerController()
            local pcm = pc and pc.PlayerCameraManager
            local curTarget = nil
            if pcm and pcm:IsValid() then
                pcall(function()
                    if pcm.ViewTarget then curTarget = pcm.ViewTarget.Target end
                end)
            end

            if State.viewWasPhotoCam and (not photoCam or not photoCam:IsValid()) then
                forceExit("PhotoCameraActor destroyed")
                State.viewWatchdogRunning = false
                return
            end

            if curTarget and curTarget:IsValid() and photoCam and photoCam:IsValid() then
                if core.sameObject(curTarget, photoCam) then
                    State.viewWasPhotoCam = true
                elseif State.viewWasPhotoCam then
                    local tgtName = "unknown"
                    pcall(function() tgtName = curTarget:GetFullName() end)
                    forceExit("ViewTarget stolen (" .. tostring(tgtName) .. ")")
                    State.viewWatchdogRunning = false
                    return
                end
            end

            -- Menu detection: opening map/journal/inventory does NOT steal the
            -- ViewTarget — the game pushes widgets onto WBP_UIFrontend layer
            -- stacks over the live photo view. Eject when a menu layer is active.
            -- Dialogue is the expected owner of GameMenuLayer in cutscene PM;
            -- only eject for real menus while this mode is not active.
            local menuOpen, layerName, wname = M.isMenuOpen()
            local isDialogueWidget = wname and (tostring(wname):find("Dialogue") ~= nil or tostring(wname):find("WBP_Dialogue") ~= nil)
            if menuOpen and not (State.cutscenePMEntry and isDialogueWidget) then
                forceExit(("menu widget active on %s (%s)"):format(layerName, wname))
                State.viewWatchdogRunning = false
                return
            end
        end

        -- Re-layout letterbox bars if the viewport size changed (window resize).
        if State.aspectRatioValue then
            pcall(function() require("lib.osd").refreshLetterbox() end)
        end

        pcall(function() delayFn(400, poll) end)
    end

    pcall(function() delayFn(400, poll) end)
    dbg("Watchdog: poller started")
end

---------------------------------------------------------------------------- FOV

-- TIK-013: Camera speed guard to prevent speed multiplication during FOV/DoF modulation
function M.reassertCameraSpeed()
    local photoActor = Subsystem.photoCamera()
    if not (photoActor and photoActor:IsValid()) then return end

    local mc = photoActor.MovementComponent
    if not (mc and mc:IsValid()) then return end

    local factor = (State.timeDilation and State.timeDilation > 0.001 and State.timeDilation < 0.999) and (1.0 / State.timeDilation) or 1.0

    pcall(function()
        if not State.origMaxSpeed and mc.MaxSpeed and mc.MaxSpeed > 0 then
            State.origMaxSpeed = mc.MaxSpeed
            State.origAcceleration = mc.Acceleration
            State.origDeceleration = mc.Deceleration
        end

        if State.origMaxSpeed then
            mc.MaxSpeed = State.origMaxSpeed * factor
        end
        if State.origAcceleration then
            mc.Acceleration = State.origAcceleration * factor * factor
        end
        if State.origDeceleration then
            mc.Deceleration = State.origDeceleration * factor * factor
        end
    end)
end

function M.applyFOV()
    if not State.photoModeActive then return end

    local pc = Subsystem.playerController()
    local pcm = pc and pc.PlayerCameraManager
    if pcm and pcm:IsValid() then
        pcall(function() pcm.DefaultFOV = State.fov end)
    end

    M.reassertCameraSpeed()

    logMsg("FOV applied: %.1f", State.fov)
end

function M.adjustFOV(delta)
    if not State.photoModeActive then return end
    State.fov = math.max(Config.fov_min, math.min(Config.fov_max, State.fov + delta))
    M.applyFOV()
    logMsg("FOV: %.1f", State.fov)
    local osd = require("lib.osd")
    osd.updateOSD()
end

function M.resetFOV()
    if not State.photoModeActive then return end
    State.fov = (State.cutscenePMEntry and State.origDefaultFOV) or Config.fov_default
    M.applyFOV()
    logMsg("FOV reset to %s", tostring(State.fov))
    local osd = require("lib.osd")
    osd.updateOSD()
end

---------------------------------------------------------------------------- Camera Roll

function M.applyRoll()
    if State.pmMode == "cutscene" then return end
    local pc = Subsystem.playerController()
    local photoActor = Subsystem.photoCamera()

    local targetRoll = State.roll or 0.0

    local cRot = nil
    if pc and pc:IsValid() then
        local pcm = pc.PlayerCameraManager
        if pcm and pcm:IsValid() then
            pcall(function()
                pcm.ViewRollMin = -180.0
                pcm.ViewRollMax = 180.0
                if not State.origViewPitchMin then
                    State.origViewPitchMin = pcm.ViewPitchMin
                    State.origViewPitchMax = pcm.ViewPitchMax
                end
                pcm.ViewPitchMin = -89.9
                pcm.ViewPitchMax = 89.9
            end)
        end
        pcall(function() cRot = pc:GetControlRotation() end)
    end
    if not cRot and photoActor and photoActor:IsValid() then
        pcall(function() cRot = photoActor:K2_GetActorRotation() end)
    end

    local pitch = (cRot and cRot.Pitch and cRot.Pitch > 180.0) and (cRot.Pitch - 360.0) or (cRot and cRot.Pitch or 0.0)
    local safePitch = math.max(-89.0, math.min(89.0, pitch))
    local safeYaw = cRot and cRot.Yaw or 0.0
    local targetRot = { Pitch = safePitch, Yaw = safeYaw, Roll = targetRoll }

    if pc and pc:IsValid() then
        pcall(function() pc:SetControlRotation(targetRot) end)
    end

    if photoActor and photoActor:IsValid() then
        pcall(function()
            photoActor.bUseControllerRotationRoll = (math.abs(targetRoll) > 0.001)
            photoActor:K2_SetActorRotation(targetRot, false)
        end)
    end

    logMsg("ApplyRoll: roll=%.1f", targetRoll)
end

function M.adjustRoll(delta)
    if not State.photoModeActive then return end
    if State.pmMode == "cutscene" then return end
    State.roll = math.max(-Config.roll_max, math.min(Config.roll_max, State.roll + delta))
    M.applyRoll()
    logMsg("Roll: %.1f deg", State.roll)
    local osd = require("lib.osd")
    osd.updateOSD()
end

---------------------------------------------------------------------------- Flight, Rotation & Tether Clamping

local function clampTether(targetLoc)
    local anchor = State.playerOrigLoc
    if not anchor and State.playerPawn and State.playerPawn:IsValid() then
        pcall(function() anchor = State.playerPawn:K2_GetActorLocation() end)
    end
    if anchor and anchor.X and anchor.Y and anchor.Z then
        local maxDist = Config.camera_max_distance or 5000.0
        local dx = targetLoc.X - anchor.X
        local dy = targetLoc.Y - anchor.Y
        local dz = targetLoc.Z - anchor.Z
        local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
        if dist > maxDist and dist > 0.001 then
            targetLoc.X = anchor.X + dx * (maxDist / dist)
            targetLoc.Y = anchor.Y + dy * (maxDist / dist)
            targetLoc.Z = anchor.Z + dz * (maxDist / dist)
        end
    end
    return targetLoc
end

function M.movePhotoCameraVertical(deltaZ)
    local photoActor = Subsystem.photoCamera()
    if not photoActor or not photoActor:IsValid() then
        logMsg("  PhotoCameraActor not found")
        return
    end

    local okLoc, loc = pcall(function() return photoActor:K2_GetActorLocation() end)
    if okLoc and loc then
        local targetLoc = clampTether({X = loc.X, Y = loc.Y, Z = loc.Z + deltaZ})
        local okSet, errSet = pcall(function()
            photoActor:K2_SetActorLocation(
                targetLoc,
                false, {}, false
            )
        end)
        if okSet then
            return
        else
            logMsg("  K2_SetActorLocation failed: %s", tostring(errSet))
        end
    else
        logMsg("  K2_GetActorLocation failed: %s", tostring(loc))
    end

    local okRoot, rootComp = pcall(function() return photoActor.RootComponent end)
    if okRoot and rootComp and rootComp:IsValid() then
        local okRel, relLoc = pcall(function() return rootComp.RelativeLocation end)
        if okRel and relLoc then
            local targetRel = clampTether({
                X = relLoc.X,
                Y = relLoc.Y,
                Z = relLoc.Z + deltaZ
            })
            local okSetRel = pcall(function()
                rootComp.RelativeLocation = targetRel
            end)
            if okSetRel then
                return
            end
        end
    end

    logMsg("  Vertical move FAILED - no method worked")
end

function M.movePhotoCameraFlight(forwardInput, rightInput, speed)
    local photoActor = Subsystem.photoCamera()
    if not (photoActor and photoActor:IsValid()) then return end
    local pc = Subsystem.playerController()
    if not (pc and pc:IsValid()) then return end

    local cRot = nil
    pcall(function() cRot = pc:GetControlRotation() end)
    if not cRot then
        pcall(function() cRot = photoActor:K2_GetActorRotation() end)
    end
    if not cRot then return end

    local okLoc, loc = pcall(function() return photoActor:K2_GetActorLocation() end)
    if not (okLoc and loc) then return end

    local yawRad = math.rad(cRot.Yaw or 0)
    local cosY = math.cos(yawRad)
    local sinY = math.sin(yawRad)

    -- Forward vector: (cos(yaw), sin(yaw), 0)
    -- Right vector: (-sin(yaw), cos(yaw), 0)
    local deltaX = (cosY * forwardInput - sinY * rightInput) * speed
    local deltaY = (sinY * forwardInput + cosY * rightInput) * speed

    local targetLoc = clampTether({ X = loc.X + deltaX, Y = loc.Y + deltaY, Z = loc.Z })

    pcall(function()
        photoActor:K2_SetActorLocation(targetLoc, false, {}, false)
    end)
end

function M.rotatePhotoCamera(deltaPitch, deltaYaw)
    local pc = Subsystem.playerController()
    if not (pc and pc:IsValid()) then return end

    local cRot = nil
    pcall(function() cRot = pc:GetControlRotation() end)
    if not cRot then
        local photoActor = Subsystem.photoCamera()
        if photoActor and photoActor:IsValid() then
            pcall(function() cRot = photoActor:K2_GetActorRotation() end)
        end
    end
    if not cRot then return end

    local curPitch = (cRot.Pitch and cRot.Pitch > 180.0) and (cRot.Pitch - 360.0) or (cRot.Pitch or 0.0)
    local newPitch = math.max(-89.0, math.min(89.0, curPitch + deltaPitch))
    local newYaw = (cRot.Yaw or 0.0) + deltaYaw
    local targetRot = { Pitch = newPitch, Yaw = newYaw, Roll = State.roll or 0.0 }

    pcall(function() pc:SetControlRotation(targetRot) end)
end

return M


