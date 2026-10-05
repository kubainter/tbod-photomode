-- TBOD_PhotoMode photomode module
-- Photo Mode lifecycle, HUD, Player, Slomo, Pause

local core = require("lib.core")
local State = core.State
local Config = core.Config
local Subsystem = core.Subsystem
local logMsg = core.logMsg
local dbg = core.dbg

local M = {}

---------------------------------------------------------------------------- Helpers (reduce boilerplate)

local function isValidObject(obj)
    if not obj then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

local function getPC()
    local pc = Subsystem.playerController()
    return isValidObject(pc) and pc or nil
end

local function getPCM()
    local pc = getPC()
    if not pc then return nil end
    local ok, pcm = pcall(function() return pc.PlayerCameraManager end)
    return ok and isValidObject(pcm) and pcm or nil
end

local function getActiveCameraFOV(pcm)
    if not isValidObject(pcm) then return nil end
    local ok, fov = pcall(function() return pcm:GetFOVAngle() end)
    if ok and type(fov) == "number" and fov > 0 then return fov end
    local okProp, prop = pcall(function() return pcm.FOVAngle end)
    if okProp and type(prop) == "number" and prop > 0 then return prop end
    return nil
end

local function getPhotoActor()
    local pa = Subsystem.photoCamera()
    return isValidObject(pa) and pa or nil
end

local function getObjectWorld(obj)
    if not isValidObject(obj) then return nil end
    local ok, world = pcall(function() return obj:GetWorld() end)
    return ok and isValidObject(world) and world or nil
end

local function getObjectWorldIdentity(obj)
    local world = getObjectWorld(obj)
    if not world then return nil end
    local ok, identity = pcall(function() return world:GetFullName() end)
    return ok and identity and tostring(identity) or nil
end

local function getPlayerPawn()
    local pawn = State.playerPawn
    if isValidObject(pawn) then return pawn end
    local pc = getPC()
    if pc then
        local okP, p = pcall(function() return pc.Pawn or pc.Character end)
        if okP and isValidObject(p) then
            State.playerPawn = p
            return p
        end
    end
    local found = core.findValid({"BP_PlayerCharacter_C", "DawnwalkerCharacterBase", "BP_PlayerCharacter"})
    if isValidObject(found) then
        local okCtrl, isPlayer = pcall(function() return found:IsPlayerControlled() end)
        if okCtrl then
            if isPlayer then State.playerPawn = found end
            return isPlayer and found or nil
        end
        State.playerPawn = found
        return found
    end
    return nil
end

-- Common restore helper: call fn, log label, clear field
local function restoreField(label, field, fn)
    if State[field] ~= nil then
        pcall(fn)
        logMsg("  %s restored", label)
        State[field] = nil
    end
end

-- Restore a CDO setting if we snapshotted it
local function restoreCDOSetting(settings, field, origField, default)
    if State[origField] ~= nil then
        pcall(function() settings[field] = State[origField] end)
    elseif default ~= nil then
        pcall(function() settings[field] = default end)
    end
end

---------------------------------------------------------------------------- HUD: targeted hide

function M.setHUDVisible(visible)
    local osd = require("lib.osd")
    if visible then
        local restored = 0
        for _, entry in ipairs(State.hiddenWidgets) do
            local w = entry.widget
            local origVis = entry.origVis
            if w and w:IsValid() then
                pcall(function() w:SetVisibility(origVis) end)
                restored = restored + 1
            end
        end
        State.hiddenWidgets = {}
        if State.aspectRatioValue then
            pcall(function() osd.setLetterbox(State.aspectRatioValue) end)
        end
        if State.framingMode ~= "off" then
            pcall(function() osd.showFraming() end)
        end
        if State.osdVisible and osd.ensureOSD then
            pcall(function() osd.showOSD() end)
        end
        logMsg("  Restored %d widgets", restored)
    else
        local okWidgets, widgets = pcall(function() return FindAllOf("UserWidget") end)
        if okWidgets and widgets then
            local hidden = 0
            for _, w in ipairs(widgets) do
                if w and w:IsValid() then
                    local fullName = ""
                    pcall(function() fullName = w:GetFullName() end)
                    local nameStr = tostring(fullName)
                    local isModOwned = osd.isModOwnedWidget(w)
                    local isQuickslot = nameStr:find("Quickslot", 1, true) ~= nil
                    if not isModOwned and not isQuickslot then
                        local okVis, vis = pcall(function() return w.Visibility end)
                        if okVis and vis then
                            local visNum = tonumber(tostring(vis)) or -1
                            if visNum == 0 or visNum == 3 or visNum == 4 then
                                local okHide = pcall(function() w:SetVisibility(2) end)
                                if okHide then
                                    table.insert(State.hiddenWidgets, {widget = w, origVis = visNum})
                                    hidden = hidden + 1
                                end
                            end
                        end
                    end
                end
            end
            if State.aspectRatioValue then
                pcall(function() osd.setLetterbox(State.aspectRatioValue) end)
            end
            if State.framingMode ~= "off" then
                pcall(function() osd.showFraming() end)
            end
            if State.osdVisible and osd.ensureOSD then
                pcall(function() osd.showOSD() end)
            end
            logMsg("  HUD: hidden %d main widgets", hidden)
        end
    end
    State.hudVisible = visible
end

---------------------------------------------------------------------------- Cutscene sequences (force_cutscene_pm)

local SEQUENCE_PLAYER_CLASSES = {
    "CinematicNodeLevelSequencePlayer",
    "DialogueLevelSequencePlayer",
    "EventLevelSequencePlayer",
    "FlowLevelSequencePlayer",
    "TemplateSequencePlayer",
    "LevelSequencePlayer",
}

local function isSequenceCDO(pl)
    local fullName = ""
    pcall(function() fullName = pl:GetFullName() end)
    return tostring(fullName):find("Default__", 1, true) ~= nil
end

function M.pauseLevelSequences()
    if #State.pausedSequences > 0 then M.resumeLevelSequences() end
    local seen = {}
    for _, cls in ipairs(SEQUENCE_PLAYER_CLASSES) do
        local ok, players = pcall(function() return FindAllOf(cls) end)
        if ok and players then
            for _, pl in ipairs(players) do
                local identity = ""
                if isValidObject(pl) then pcall(function() identity = pl:GetFullName() end) end
                if isValidObject(pl) and not isSequenceCDO(pl)
                    and (identity == "" or not seen[identity]) then
                    if identity ~= "" then seen[identity] = true end
                    local playing = false
                    pcall(function() playing = pl:IsPlaying() == true end)
                    if playing then
                        local okPause = pcall(function() pl:Pause() end)
                        if okPause then
                            local seqName = "?"
                            pcall(function() seqName = pl:GetSequenceName(false) end)
                            logMsg("  Cutscene paused: %s [%s]", cls, tostring(seqName))
                            table.insert(State.pausedSequences,
                                { player = pl, world = getObjectWorld(pl), worldIdentity = getObjectWorldIdentity(pl) })
                        end
                    end
                end
            end
        end
    end
    return #State.pausedSequences
end

function M.resumeLevelSequences()
    local entries = State.pausedSequences
    if State.cutsceneSession and State.cutsceneSession.pausedSequences then
        entries = State.cutsceneSession.pausedSequences
    end
    local total = #entries
    if total == 0 then return 0 end
    local resumed = 0
    local currentWorld = getObjectWorld(getPC())
    local currentWorldIdentity = getObjectWorldIdentity(getPC())
    for _, entry in ipairs(entries) do
        local pl = entry.player
        local sameWorld = true
        if entry.worldIdentity and entry.worldIdentity ~= "" then
            sameWorld = currentWorldIdentity ~= nil and currentWorldIdentity == entry.worldIdentity
        elseif entry.world then
            -- Legacy entries may not have a string identity. Keep the
            -- conservative behavior rather than resuming across worlds.
            sameWorld = currentWorld ~= nil and currentWorld == entry.world
        end
        if isValidObject(pl) and sameWorld then
            if entry.prevDisableCameraCuts ~= nil then
                pcall(function() pl:SetDisableCameraCuts(entry.prevDisableCameraCuts == true) end)
            end
            pcall(function() if pl:IsPaused() then pl:Play() end end)
            resumed = resumed + 1
        elseif isValidObject(pl) then
            logMsg("  Cutscene resume skipped: sequence belongs to another world")
        end
    end
    State.pausedSequences = {}
    logMsg("  Cutscene resume: %d/%d sequence(s) running again", resumed, total)
    return resumed
end

-- Re-arm input after a forced cutscene entry.
function M.rearmCutsceneInput()
    local pc = getPC()
    if not pc then return end

    pcall(function() State.origIgnoreMove = pc:IsMoveInputIgnored() end)
    pcall(function() State.origIgnoreLook = pc:IsLookInputIgnored() end)
    pcall(function() pc:ResetIgnoreInputFlags() end)

    local photoActor = getPhotoActor()
    if photoActor then
        pcall(function() photoActor:EnableInput(pc) end)
    end

    local sbl = core.findStatic("/Script/Engine.Default__SubsystemBlueprintLibrary")
    local eiCls = core.findStatic("/Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem")
    local imc = core.findStatic("/Game/_Dawnwalker/System/PhotoMode/IMC_PhotoMode.IMC_PhotoMode")
    local eiSub = nil
    if sbl and eiCls then
        pcall(function()
            eiSub = sbl:GetLocalPlayerSubSystemFromPlayerController(pc, eiCls)
        end)
    end
    if eiSub and eiSub:IsValid() and imc then
        local okAdd, err = pcall(function()
            eiSub:AddMappingContext(imc, 1000, {})
        end)
        logMsg("  Cutscene PM: IMC_PhotoMode re-asserted (%s)", okAdd and "ok" or tostring(err))
    else
        logMsg("  Cutscene PM: input re-arm incomplete (sbl=%s eiSub=%s imc=%s)",
            tostring(sbl ~= nil), tostring(eiSub ~= nil), tostring(imc ~= nil))
    end
end

---------------------------------------------------------------------------- Photo Mode core

function M.enterPhotoMode()
    if State.photoModeActive then return end
    core.reloadConfig()

    if #State.pausedSequences > 0 then M.resumeLevelSequences() end
    State.fov = nil
    State.viewWasPhotoCam = false

    local pm = Subsystem.photoMode()
    if not pm then logMsg("ERROR: DogwoodPhotomodeSubsystem not found") return end
    local pc = getPC()
    local pcm = getPCM()
    local entryCameraFOV = getActiveCameraFOV(pcm)
    local entryAspectRatio = nil
    local entryConstrainAR = nil
    local entryCameraLocation = nil
    local entryCameraRotation = nil
    local entryCameraTargetActor = nil
    local entryCameraComponent = nil
    if pcm then
        -- 1. Extract directly from active ViewTarget's CameraComponent if available
        if pcm.ViewTarget and pcm.ViewTarget.Target then
            local vt = pcm.ViewTarget.Target
            local camComp = nil
            pcall(function() camComp = vt.CameraComponent end)
            if not camComp or not camComp:IsValid() then
                pcall(function() camComp = vt.DialogueCameraComponent end)
            end
            if not camComp or not camComp:IsValid() then
                pcall(function() camComp = vt.CineCameraComponent end)
            end
            entryCameraTargetActor = vt
            entryCameraComponent = camComp
            
            if camComp and camComp:IsValid() then
                local okL, cLoc = pcall(function() return camComp:K2_GetComponentLocation() end)
                local okR, cRot = pcall(function() return camComp:K2_GetComponentRotation() end)
                if okL and cLoc and okR and cRot then
                    entryCameraLocation = { X = cLoc.X or 0, Y = cLoc.Y or 0, Z = cLoc.Z or 0 }
                    entryCameraRotation = { Pitch = cRot.Pitch or 0, Yaw = cRot.Yaw or 0, Roll = cRot.Roll or 0 }
                    logMsg("  Cutscene PM: Extracted from ViewTarget CameraComponent: Loc=(%.1f, %.1f, %.1f) Rot=(Pitch=%.1f, Yaw=%.1f, Roll=%.1f)",
                        entryCameraLocation.X, entryCameraLocation.Y, entryCameraLocation.Z, 
                        entryCameraRotation.Pitch, entryCameraRotation.Yaw, entryCameraRotation.Roll)
                end
                pcall(function() entryCameraFOV = camComp.FieldOfView end)
                pcall(function() entryAspectRatio = camComp.AspectRatio end)
                pcall(function() entryConstrainAR = camComp.bConstrainAspectRatio end)
            end
        end

        -- 2. Fallback to CameraCachePrivate.POV
        if not entryCameraLocation or not entryCameraRotation then
            local okPOV, pov = pcall(function() return pcm.CameraCachePrivate.POV end)
            if okPOV and pov then
                pcall(function()
                    entryCameraLocation = { X = pov.Location.X or 0, Y = pov.Location.Y or 0, Z = pov.Location.Z or 0 }
                    entryCameraRotation = { Pitch = pov.Rotation.Pitch or 0, Yaw = pov.Rotation.Yaw or 0, Roll = pov.Rotation.Roll or 0 }
                    if pov.FOV and pov.FOV > 0 then entryCameraFOV = pov.FOV end
                    entryAspectRatio = pov.AspectRatio
                    entryConstrainAR = pov.bConstrainAspectRatio
                    logMsg("  Cutscene PM: CameraCachePrivate.POV (X=%.1f, Y=%.1f, Z=%.1f, Pitch=%.1f, Yaw=%.1f, FOV=%.1f)", 
                        entryCameraLocation.X, entryCameraLocation.Y, entryCameraLocation.Z, 
                        entryCameraRotation.Pitch, entryCameraRotation.Yaw, entryCameraFOV or 0)
                end)
            end
        end

        -- 3. Ultimate Fallback to PCM getters
        if not entryCameraLocation or not entryCameraRotation then
            pcall(function() entryCameraLocation = pcm:GetCameraLocation() end)
            pcall(function() entryCameraRotation = pcm:GetCameraRotation() end)
        end
    end
    State.entryCameraRotation = entryCameraRotation

    local forcedEntry = false
    local okCan, canAct = pcall(function() return pm:CanActivatePhotomode() end)
    if not okCan or not canAct then
        if not Config.force_cutscene_pm then
            logMsg("Cannot activate PhotoMode (Native Guardian blocked it)")
            return
        end
        forcedEntry = true
        local pausedSeqs = M.pauseLevelSequences()
        if pausedSeqs > 0 then
            local okRe, canRe = pcall(function() return pm:CanActivatePhotomode() end)
            logMsg("  force_cutscene_pm: %d sequence(s) paused, guardian %s",
                pausedSeqs, (okRe and canRe) and "now CLEAR" or "still BLOCKED - forcing")
        else
            -- A blocked guardian is not proof of an active cutscene. Do not
            -- enter the cutscene profile for menus/dialogue states we failed
            -- to identify, and do not leave any arbitrary game state paused.
            logMsg("  force_cutscene_pm: no playing sequence found - refusing forced entry")
            return
        end
    end

    if pcm then
        local okFOV, fovVal = pcall(function() return pcm.DefaultFOV end)
        if okFOV and fovVal and fovVal > 0 then State.origDefaultFOV = fovVal end
        
        pcall(function()
            State.origAspectRatio = pcm.DefaultAspectRatio
            State.origConstrainAR = pcm.bDefaultConstrainAspectRatio
        end)

        if forcedEntry then
            State.origDefaultFOV = entryCameraFOV or State.origDefaultFOV or Config.fov_default
            State.fov = State.origDefaultFOV
            logMsg("  Cutscene entry FOV captured: %.1f", State.fov)
            if entryAspectRatio and entryConstrainAR then
                pcall(function()
                    pcm.bDefaultConstrainAspectRatio = entryConstrainAR
                    pcm.DefaultAspectRatio = entryAspectRatio
                end)
                logMsg("  Cutscene entry AspectRatio applied: %.2f (Constrain: %s)", entryAspectRatio, tostring(entryConstrainAR))
            end
        else
            State.fov = Config.fov_default
        end
        pcall(function()
            State.origViewRollMin = pcm.ViewRollMin
            State.origViewRollMax = pcm.ViewRollMax
            State.origViewPitchMin = pcm.ViewPitchMin
            State.origViewPitchMax = pcm.ViewPitchMax
        end)
    end
    if State.fov == nil then State.fov = Config.fov_default end

    if pc then
        State.playerPawn = pc.Pawn or pc.Character
    end
    if not State.playerPawn or not State.playerPawn:IsValid() then
        State.playerPawn = core.findValid({"BP_PlayerCharacter_C", "DawnwalkerCharacterBase", "BP_PlayerCharacter"})
    end
    if State.playerPawn and State.playerPawn:IsValid() then
        local pawnName = ""
        pcall(function() pawnName = State.playerPawn:GetFullName() end)
        local className = pawnName:match("^(%S+)") or pawnName
        logMsg("  Player character snapshotted: %s", className)
        State.playerOrigLoc, State.playerOrigRot = nil, nil
        pcall(function() State.playerOrigLoc = State.playerPawn:K2_GetActorLocation() end)
        pcall(function() State.playerOrigRot = State.playerPawn:K2_GetActorRotation() end)
    end
    State.playerMovePrepared = false
    State.origPlayerGravityScale = nil

    logMsg("Activating PhotoMode...")

    local settings = Subsystem.photoModeSettings()
    if not settings then settings = core.findValid({"DogwoodPhotomodeSettings"}) end
    if settings then
        pcall(function()
            local p = settings.bShouldPauseGame
            if p ~= nil then State.origCDO_bShouldPauseGame = p end
            local d = settings.CameraMaxDistance
            if d ~= nil then State.origCDO_CameraMaxDistance = d end
            local s = settings.CameraMovementSpeed
            if s ~= nil then State.origCDO_CameraMovementSpeed = s end
        end)
        pcall(function() settings.CameraMaxDistance = Config.camera_max_distance end)
        pcall(function() settings.CameraMovementSpeed = Config.camera_speed end)
        pcall(function() settings.bShouldPauseGame = false end)
        logMsg("  CDO settings applied (pre-activation)")
    else
        logMsg("  WARNING: DogwoodPhotomodeSettings not found")
    end

    pcall(function() pm:ActivatePhotomode() end)

    local okActive, isActive = pcall(function() return pm:IsPhotomodeActive() end)
    if not okActive or not isActive then
        logMsg("ERROR: PhotoMode activation failed")
        M.resumeLevelSequences()
        if settings then
            pcall(function()
                settings.bShouldPauseGame = State.origCDO_bShouldPauseGame
                settings.CameraMaxDistance = State.origCDO_CameraMaxDistance
                settings.CameraMovementSpeed = State.origCDO_CameraMovementSpeed
            end)
        end
        return
    end

    State.photoModeActive = true
    
    -- Apply FOV immediately after activation, before photo camera takes over
    local camera = require("lib.camera")
    camera.applyFOV()
    State.pmMode = forcedEntry and "cutscene" or "normal"
    local osd = require("lib.osd")
    osd.currentTab = 1
    osd.OSD_SELECTED = 1
    osd.buildTabs()
    State.cutsceneSession = forcedEntry and {
        pausedSequences = State.pausedSequences,
        entryPlayer = State.playerPawn,
    } or nil
    if forcedEntry then
        State.cutscenePMEntry = true
        State.cutsceneCameraActor = entryCameraTargetActor
        State.cutsceneCameraComponent = entryCameraComponent
        State.origCutsceneRot = entryCameraRotation
        if entryCameraTargetActor and isValidObject(entryCameraTargetActor) then
            pcall(function()
                local aRot = entryCameraTargetActor:K2_GetActorRotation()
                if aRot then
                    State.origCutsceneActorRot = { Pitch = aRot.Pitch or 0, Yaw = aRot.Yaw or 0, Roll = aRot.Roll or 0 }
                end
            end)
        end
        if not State.origCutsceneActorRot and entryCameraRotation then
            State.origCutsceneActorRot = { Pitch = entryCameraRotation.Pitch or 0, Yaw = entryCameraRotation.Yaw or 0, Roll = entryCameraRotation.Roll or 0 }
        end
        if entryCameraComponent and isValidObject(entryCameraComponent) then
            pcall(function()
                local relRot = entryCameraComponent.RelativeRotation
                if relRot then
                    State.origCutsceneCamCompRelRot = { Pitch = relRot.Pitch or 0, Yaw = relRot.Yaw or 0, Roll = relRot.Roll or 0 }
                end
            end)
        end
        State.roll = 0.0
        -- Freeze FIRST: between ActivatePhotomode() and SetGamePaused the
        -- sequence can reclaim the camera and stomp the seeded transform.
        local gs = Subsystem.gameplayStatics()
        if gs and pc then
            local okPause, pauseResult = pcall(function() return gs:SetGamePaused(pc, true) end)
            if okPause and pauseResult ~= false then
                State.paused = true
                logMsg("Pause: PAUSED (Cutscene PM entry freeze)")
            else
                logMsg("WARN: Cutscene PM entry freeze failed")
            end
        else
            logMsg("WARN: Cutscene PM entry freeze unavailable (GameplayStatics/PC missing)")
        end

        local photoActor = getPhotoActor()
        if photoActor and entryCameraLocation and entryCameraRotation then
            -- DIAGNOSTICS & FIX: Subtract BaseEyeHeight from Z to counteract APawn::GetActorEyesViewPoint offset
            local eyeHeight = 0
            pcall(function() eyeHeight = photoActor.BaseEyeHeight end)
            if not eyeHeight or type(eyeHeight) ~= "number" then eyeHeight = 0 end

            local seedLoc = {
                X = entryCameraLocation.X,
                Y = entryCameraLocation.Y,
                Z = entryCameraLocation.Z - eyeHeight
            }

            -- UNLOCK View Pitch/Roll BEFORE setting control rotation to prevent clamping
            if pcm then
                pcall(function()
                    pcm.ViewRollMin = -180.0
                    pcm.ViewRollMax = 180.0
                    pcm.ViewPitchMin = -89.9
                    pcm.ViewPitchMax = 89.9
                end)
            end

            pcall(function()
                photoActor:K2_SetActorLocationAndRotation(
                    seedLoc, entryCameraRotation, false, {}, true)
            end)
            pcall(function() pc:SetControlRotation(entryCameraRotation) end)
            logMsg("  Cutscene PM: seeded view (targetZ: %.1f, eyeHeight: %.1f, seedZ: %.1f) - Pitch: %.1f, Yaw: %.1f, Roll: %.1f", 
                entryCameraLocation.Z, eyeHeight, seedLoc.Z, entryCameraRotation.Pitch or 0, entryCameraRotation.Yaw or 0, entryCameraRotation.Roll or 0)
            
            -- Verify final rendered view location (deferred to end of tick)
            local postSeedViewLoc = nil
            if pcm then pcall(function() postSeedViewLoc = pcm:GetCameraLocation() end) end
            if postSeedViewLoc then
                local dz = postSeedViewLoc.Z - entryCameraLocation.Z
                logMsg("  Cutscene PM: ViewTarget Z delta after seed: %+.1f (should be ~0)", dz)
            end
        else
            logMsg("  WARN: Cutscene PM could not seed photo camera transform")
        end
        M.rearmCutsceneInput()

        -- One-shot entry diagnostics: who owns the view after seeding?
        local diagTarget = nil
        local pcmDiag = getPCM()
        if pcmDiag then
            pcall(function()
                if pcmDiag.ViewTarget then diagTarget = pcmDiag.ViewTarget.Target end
            end)
        end
        local tgtName, paName = "nil", "nil"
        if diagTarget then pcall(function() tgtName = diagTarget:GetFullName() end) end
        if photoActor then pcall(function() paName = photoActor:GetFullName() end) end
        dbg("  Cutscene PM diag: photoActor=[%s] viewTarget=[%s]", paName, tgtName)
    end

    State.playerTickSaved = {}
    core.setActorTickableWhenPaused(State.playerPawn, true, State.playerTickSaved)
    local pausedPhotoActor = getPhotoActor()
    State.photoCameraTickSaved = {}
    core.setActorTickableWhenPaused(pausedPhotoActor, true, State.photoCameraTickSaved)
    State.pcTickSaved = {}
    core.setActorTickableWhenPaused(pc, true, State.pcTickSaved)

    if Config.pause_on_enter and not State.paused and not State.cutscenePMEntry then
        local delayFn = core.delayGameThread
        if delayFn then
            State.stepEpoch = (State.stepEpoch or 0) + 1
            local epoch = State.stepEpoch
            pcall(function() delayFn(600, function()
                if not (State.photoModeActive and State.stepEpoch == epoch) then return end
                local gs, pc2 = Subsystem.gameplayStatics(), getPC()
                if gs and pc2 then
                    State.paused = true
                    pcall(function() gs:SetGamePaused(pc2, true) end)
                    logMsg("Pause: PAUSED (auto-freeze on enter)")
                end
            end) end)
        else
            M.togglePause()
        end
    end

    pcall(function() require('lib.optics').syncTimeOfDay() end)
    logMsg("PhotoMode ACTIVE (mode=%s)", State.pmMode)

    if Config.enable_input_isolation then
        local input = require("lib.input")
        input.isolateGameInput(true)
    end



    local photoActor = getPhotoActor()
    if photoActor then
        pcall(function() photoActor:SetActorHiddenInGame(true) end)
        pcall(function() photoActor.bUseControllerRotationRoll = true end)
        
        -- Disable collision to prevent the camera from being pushed out of NPC faces by the physics engine
        pcall(function() photoActor:SetActorEnableCollision(false) end)
        local root = nil
        pcall(function() root = photoActor.RootComponent end)
        if root and root:IsValid() then
            pcall(function() root:SetCollisionEnabled(0) end) -- ECollisionEnabled::NoCollision
            pcall(function() root:SetCollisionProfileName("NoCollision") end)
        end

        local mc = photoActor.MovementComponent
        if mc and mc:IsValid() then
            pcall(function()
                State.origMaxSpeed = mc.MaxSpeed
                State.origAcceleration = mc.Acceleration
                State.origDeceleration = mc.Deceleration
            end)
        end
        pcall(function()
            State.origTurnRate = photoActor.BaseTurnRate
            State.origLookUpRate = photoActor.BaseLookUpRate
        end)
    end

    local camera = require("lib.camera")
    camera.hookGetCameraView()
    camera.startWatchdog()

    State.origMotionBlurQuality = core.getCVarInt("r.MotionBlurQuality")
    core.setCVar("r.MotionBlurQuality", 0)

    if Config.osd_show_on_enter then
        local osd = require("lib.osd")
        osd.showOSD()
    end

    pcall(function() require("lib.gamepad").startPoller() end)
    local okEB, eb = pcall(require, "lib.eventbridge")
    if okEB and eb and eb.isAvailable() then
        pcall(function() eb.setupPhotoModeBindings(photoActor, getPC()) end)
    end

    logMsg("Controls: %s=exit, %s=HUD, %s=pause, %s=screenshot, %s=reset FOV, %s/%s=move up/down",
        Config.toggle_key, Config.hud_key, Config.pause_key, Config.screenshot_key,
        Config.fov_reset_key, Config.move_up_key, Config.move_down_key)
    logMsg("  OSD: %s=toggle, Up/Down=select, Left/Right=adjust, %s=reset",
        Config.osd_toggle_key, Config.osd_reset_key)
        
    if forcedEntry and Config.debug and ExecuteWithDelay then
        ExecuteWithDelay(1000, function()
            local pcm2 = getPCM()
            if pcm2 then
                local loc, rot = nil, nil
                pcall(function() loc = pcm2:GetCameraLocation() end)
                pcall(function() rot = pcm2:GetCameraRotation() end)
                if loc and rot then
                    dbg("  Cutscene PM diag (1s): POV Z=%.1f, Pitch=%.1f, Yaw=%.1f, Roll=%.1f",
                        loc.Z or 0, rot.Pitch or 0, rot.Yaw or 0, rot.Roll or 0)
                end
            end
            local photoActor2 = getPhotoActor()
            if photoActor2 then
                local loc, rot = nil, nil
                pcall(function() loc = photoActor2:K2_GetActorLocation() end)
                pcall(function() rot = photoActor2:K2_GetActorRotation() end)
                if loc and rot then
                    dbg("  Cutscene PM diag (1s): Actor Z=%.1f, Pitch=%.1f, Yaw=%.1f, Roll=%.1f",
                        loc.Z or 0, rot.Pitch or 0, rot.Yaw or 0, rot.Roll or 0)
                end
            end
        end)
    end
end

---------------------------------------------------------------------------- Exit: decomposed into small steps

local function restorePlayerMovement()
    if not State.playerMovePrepared then return end
    local pawn = getPlayerPawn()
    if isValidObject(pawn) then
        if State.playerOrigLoc then
            pcall(function()
                local hitRes = {}
                pawn:K2_SetActorLocationAndRotation(State.playerOrigLoc, State.playerOrigRot or pawn:K2_GetActorRotation(), false, hitRes, true)
            end)
        end
        pcall(function()
            local mc = pawn.CharacterMovement
            if mc and mc:IsValid() then
                if State.origPlayerGravityScale then mc.GravityScale = State.origPlayerGravityScale end
                local mode = State.origPlayerMovementMode
                if mode ~= nil then
                    if mode == 0 then mode = 3 end -- None -> Falling
                    mc:SetMovementMode(mode, 0)
                end
            end
        end)
        pcall(function()
            local capsule = pawn.CapsuleComponent or pawn.RootComponent
            if capsule and capsule:IsValid() then
                if State.origCapsuleProfileName then
                    capsule:SetCollisionProfileName(State.origCapsuleProfileName, true)
                end
                if State.origCapsuleCollisionEnabled ~= nil then
                    capsule:SetCollisionEnabled(State.origCapsuleCollisionEnabled)
                end
            end
            pawn:SetActorEnableCollision(true)
        end)
        logMsg("  Player transform/collision restored")
    end
    State.playerMovePrepared = false
    State.playerOrigLoc, State.playerOrigRot = nil, nil
    State.origPlayerGravityScale = nil
    State.origPlayerMovementMode = nil
    State.origCapsuleCollisionEnabled = nil
    State.origCapsuleProfileName = nil
end

local function restorePlayerTick()
    if State.playerTickSaved then
        local pawn = getPlayerPawn()
        core.restoreActorTickable(pawn, State.playerTickSaved)
        State.playerTickSaved = nil
    end
end

local function restorePhotoCameraTick()
    if State.photoCameraTickSaved then
        local photoActor = getPhotoActor()
        core.restoreActorTickable(photoActor, State.photoCameraTickSaved)
        State.photoCameraTickSaved = nil
    end
end

local function restorePCTick()
    if State.pcTickSaved then
        local pc = getPC()
        core.restoreActorTickable(pc, State.pcTickSaved)
        State.pcTickSaved = nil
    end
end

local function restorePlayerVisibility()
    if State.playerHidden then
        local pawn = getPlayerPawn()
        if isValidObject(pawn) then
            pcall(function() M.setPawnHidden(pawn, false) end)
        end
        State.playerHidden = false
        logMsg("  Player restored to visible")
    end
    State.playerPawn = nil
end

local function restoreCDOSettings()
    local settings = Subsystem.photoModeSettings()
    if not settings then settings = core.findValid({"DogwoodPhotomodeSettings"}) end
    if settings then
        restoreCDOSetting(settings, "bShouldPauseGame", "origCDO_bShouldPauseGame", true)
        restoreCDOSetting(settings, "CameraMaxDistance", "origCDO_CameraMaxDistance", 1000.0)
        restoreCDOSetting(settings, "CameraMovementSpeed", "origCDO_CameraMovementSpeed", 1.0)
        logMsg("  CDO settings restored (bShouldPauseGame=true)")
    end
end

local function restoreOptics()
    pcall(function() require("lib.optics").restoreAll() end)
    logMsg("  Optics state restored")
end

local function deactivateNativePM()
    local pm = Subsystem.photoMode()
    if pm then
        logMsg("Deactivating PhotoMode...")
        pcall(function() pm:DeactivatePhotomode() end)
    end
end

local function resumeCutscenesAndInput(pc)
    local seqsRunning = M.resumeLevelSequences()

    if (State.origIgnoreMove ~= nil or State.origIgnoreLook ~= nil) and isValidObject(pc) then
        if (seqsRunning or 0) > 0 then
            pcall(function()
                if State.origIgnoreMove then pc:SetIgnoreMoveInput(true) end
                if State.origIgnoreLook then pc:SetIgnoreLookInput(true) end
            end)
        else
            logMsg("  Cutscene ended mid-PM: input flags left cleared")
        end
    end
    State.origIgnoreMove, State.origIgnoreLook = nil, nil
end

local function restoreInputIsolation()
    if State.osdInputCaptured then
        pcall(function() require("lib.input").setOSDInputCapture(false) end)
        State.osdInputCaptured = false
    end
    if State.gameInputIsolated or State.isolatedPawn then
        pcall(function() require("lib.input").isolateGameInput(false) end)
    end
end

local function handleMenuAtExit(pc, wasCutscenePM)
    local gs = Subsystem.gameplayStatics()
    if not (gs and isValidObject(pc)) then return end
    local camera = require("lib.camera")
    local menuOpen, _, wname = camera.isMenuOpen()
    local dialogueOpen = wname and (wname:find("WBP_Dialogue") or wname:find("Dialogue"))
    if wasCutscenePM and menuOpen and dialogueOpen then return end
    local wasPaused = false
    pcall(function() wasPaused = gs:IsGamePaused(pc) end)
    logMsg("  Exit: menuOpen=%s gamePaused=%s", tostring(menuOpen), tostring(wasPaused))
    if menuOpen and not wasPaused then
        pcall(function() gs:SetGamePaused(pc, true) end)
        logMsg("  Game paused (menu open at exit)")
        local delayFn = core.delayGameThread
        if delayFn then
            local function unstick()
                if State.photoModeActive then return end
                if camera.isMenuOpen() then
                    pcall(function() delayFn(500, unstick) end)
                else
                    pcall(function() gs:SetGamePaused(pc, false) end)
                    logMsg("  Menu closed - pause released")
                end
            end
            pcall(function() delayFn(500, unstick) end)
        end
    end
end

local function verifyCleanState()
    local okV, leftovers = pcall(function()
        local sp = require("lib.spawner")
        local issues = {}
        if sp.spawnedClones and #sp.spawnedClones > 0 then
            table.insert(issues, "clones=" .. #sp.spawnedClones)
        end
        if sp.spawnedProps then
            for _ in pairs(sp.spawnedProps) do table.insert(issues, "props") break end
        end
        if sp.spawnedPropsL then
            for _ in pairs(sp.spawnedPropsL) do table.insert(issues, "propsL") break end
        end
        if sp.spawnedWeapons then
            for _ in pairs(sp.spawnedWeapons) do table.insert(issues, "weapons") break end
        end
        if sp.playerWeaponProxy and isValidObject(sp.playerWeaponProxy) then
            table.insert(issues, "playerWeaponProxy")
        end
        if State.paused then table.insert(issues, "paused") end
        if State.timeDilation and State.timeDilation ~= 1.0 then
            table.insert(issues, "timeDilation=" .. tostring(State.timeDilation))
        end
        if State.gameInputIsolated then table.insert(issues, "inputIsolated") end
        if State.playerHidden then table.insert(issues, "playerHidden") end
        if State.pausedSequences and #State.pausedSequences > 0 then
            table.insert(issues, "pausedSequences=" .. #State.pausedSequences)
        end
        if State.origWeatherSaved then table.insert(issues, "weather") end
        return issues
    end)
    if okV and leftovers and #leftovers > 0 then
        logMsg("  LEFTOVER STATE: %s", table.concat(leftovers, ", "))
    end
end

function M.exitPhotoMode()
    if not State.photoModeActive then return end
    local wasCutscenePM = State.pmMode == "cutscene" or State.cutscenePMEntry == true
    State.stepEpoch = (State.stepEpoch or 0) + 1
    State.cutsceneFreezePending = false
    local okOSD, osd = pcall(require, "lib.osd")
    if okOSD then
        pcall(function() osd.hideOSD() end)
        pcall(function() osd.setFramingMode("off") end)
    end

    local pc = getPC()
    local pcm = getPCM()

    -- FOV unlock
    if pc and pc:IsValid() then
        pcall(function() pc:FOV(0.0) end)
        pcall(function() pc:ConsoleCommand("fov 0", false) end)
    end
    if pcm then
        pcall(function() pcm:UnlockFOV() end)
        pcall(function() pcm:SetFOV(0.0) end)
        if State.origDefaultFOV then
            pcall(function() pcm.DefaultFOV = State.origDefaultFOV end)
        end
        if State.origAspectRatio ~= nil then
            pcall(function() pcm.DefaultAspectRatio = State.origAspectRatio end)
        end
        if State.origConstrainAR ~= nil then
            pcall(function() pcm.bDefaultConstrainAspectRatio = State.origConstrainAR end)
        end
    end
    core.consoleCommand("fov 0")
    State.origDefaultFOV = nil
    State.origAspectRatio = nil
    State.origConstrainAR = nil

    -- HUD
    if not State.hudVisible then
        pcall(function() M.setHUDVisible(true) end)
    end
    logMsg("  HUD restored")

    -- Motion blur
    if State.origMotionBlurQuality ~= nil then
        pcall(function() core.setCVar("r.MotionBlurQuality", State.origMotionBlurQuality) end)
    else
        pcall(function() core.setCVar("r.MotionBlurQuality", 1) end)
        logMsg("  WARN: motion-blur snapshot missing, restored engine default")
    end
    State.origMotionBlurQuality = nil

    -- Poses
    pcall(function() require("lib.poses").resetAllPoses() end)

    -- Unfreeze world if we paused it
    if State.paused then
        local gs = Subsystem.gameplayStatics()
        if gs and pc then pcall(function() gs:SetGamePaused(pc, false) end) end
        State.paused = false
    end

    -- Destroy clones/props/weapons
    pcall(function() require("lib.spawner").destroyAll() end)

    -- Time dilation
    if State.timeDilation ~= 1.0 then
        local sm = Subsystem.slowMotion()
        if sm and sm:IsValid() and pc then
            local okRem = pcall(function() sm:RemoveSlowdownCompensatePlayerDilation(pc, true) end)
            if not okRem then pcall(function() sm:RemoveSlowdown(pc) end) end
        end
        local gs = Subsystem.gameplayStatics()
        if gs and pc then pcall(function() gs:SetGlobalTimeDilation(pc, 1.0) end) end
        core.consoleCommand("slomo 1.0")
        State.timeDilation = 1.0
        logMsg("  Time dilation restored to 1.0")
    end

    -- Roll
    State.roll = 0.0
    pcall(function() require("lib.camera").applyRoll() end)

    -- Restore cutscene camera actor/comp if any rogue code or previous state touched them
    if State.cutsceneCameraActor and isValidObject(State.cutsceneCameraActor) and State.origCutsceneActorRot then
        pcall(function()
            State.cutsceneCameraActor:K2_SetActorRotation(State.origCutsceneActorRot, false)
        end)
    end
    if State.cutsceneCameraComponent and isValidObject(State.cutsceneCameraComponent) and State.origCutsceneCamCompRelRot then
        pcall(function()
            State.cutsceneCameraComponent.RelativeRotation = State.origCutsceneCamCompRelRot
        end)
    end
    State.origCutsceneActorRot = nil
    State.origCutsceneCamCompRelRot = nil
    State.origCutsceneRot = nil
    logMsg("  Roll reset to 0 deg")

    -- PCM view limits
    if pcm then
        pcall(function()
            pcm.ViewRollMin = State.origViewRollMin or 0.0
            pcm.ViewRollMax = State.origViewRollMax or 0.0
            if State.origViewPitchMin then pcm.ViewPitchMin = State.origViewPitchMin end
            if State.origViewPitchMax then pcm.ViewPitchMax = State.origViewPitchMax end
        end)
        State.origViewRollMin, State.origViewRollMax = nil, nil
        State.origViewPitchMin, State.origViewPitchMax = nil, nil
    end

    -- Explicitly zero controller roll so no residual roll lingers on player controller
    if pc and pc:IsValid() then
        pcall(function()
            local cRot = pc:GetControlRotation()
            if cRot then
                pc:SetControlRotation({ Pitch = cRot.Pitch, Yaw = cRot.Yaw, Roll = 0.0 })
            end
        end)
    end

    -- Photo actor movement/rotation settings
    local photoActor = getPhotoActor()
    if photoActor then
        pcall(function()
            photoActor.bUseControllerRotationRoll = false
            photoActor.CustomTimeDilation = 1.0
        end)
        local mc = photoActor.MovementComponent
        if mc and mc:IsValid() and State.origMaxSpeed then
            pcall(function()
                mc.MaxSpeed = State.origMaxSpeed
                mc.Acceleration = State.origAcceleration
                mc.Deceleration = State.origDeceleration
            end)
        end
        if State.origTurnRate then
            pcall(function()
                photoActor.BaseTurnRate = State.origTurnRate
                photoActor.BaseLookUpRate = State.origLookUpRate
            end)
        end
    end
    State.origMaxSpeed = nil
    State.origAcceleration = nil
    State.origDeceleration = nil
    State.origTurnRate = nil
    State.origLookUpRate = nil

    -- Player restore (movement, tick, visibility)
    restorePlayerMovement()
    restorePlayerTick()
    restorePhotoCameraTick()
    restorePCTick()
    restorePlayerVisibility()

    -- CDO settings
    restoreCDOSettings()

    -- Optics
    restoreOptics()

    -- Native PM
    deactivateNativePM()

    -- Cutscenes + cutscene input flags
    resumeCutscenesAndInput(pc)

    -- Input isolation
    restoreInputIsolation()

    -- EventBridge PhotoMode bindings teardown
    local okEB, eb = pcall(require, "lib.eventbridge")
    if okEB and eb and eb.teardownPhotoModeBindings then
        pcall(function() eb.teardownPhotoModeBindings() end)
    end

    -- Menu watchdog
    handleMenuAtExit(pc, wasCutscenePM)

    -- Verification
    verifyCleanState()

    State.cutsceneCameraActor = nil
    State.cutsceneCameraComponent = nil
    State.photoModeActive = false
    State.pmMode = "normal"
    State.cutscenePMEntry = false
    State.cutsceneSession = nil
    -- Keep gamepad poller alive so L3+R3 chord can re-enter Photo Mode from normal gameplay
    local okOSD, osd = pcall(require, "lib.osd")
    if okOSD then
        osd.currentTab = 1
        osd.OSD_SELECTED = 1
        osd.buildTabs()
    end
    logMsg("PhotoMode EXIT complete")
end

---------------------------------------------------------------------------- Pause toggle

function M.togglePause()
    if not State.photoModeActive then return end
    if core.cutsceneBlocked("world pause") then return end
    if State.cutscenePMEntry then
        logMsg("Cutscene PM: world freeze toggle disabled (sequences drive pause)")
        return
    end
    local gs = Subsystem.gameplayStatics()
    local pc = getPC()
    if not gs or not pc then return end
    State.stepEpoch = (State.stepEpoch or 0) + 1
    State.paused = not State.paused
    pcall(function() gs:SetGamePaused(pc, State.paused) end)
    logMsg("Pause: %s", State.paused and "PAUSED" or "UNPAUSED")
end

---------------------------------------------------------------------------- Slomo (time dilation)

function M.applySlomo()
    local pc = getPC()
    local sm = Subsystem.slowMotion()
    if sm and sm:IsValid() and pc then
        if State.timeDilation < 0.999 then
            local okAdd = pcall(function()
                sm:AddSlowdownCompensatePlayerDilation(pc, State.timeDilation, 0.05, false)
            end)
            if not okAdd then
                pcall(function() sm:AddSlowdown(pc, State.timeDilation, 0.05, {}, false) end)
            end
        else
            local okRem = pcall(function() sm:RemoveSlowdownCompensatePlayerDilation(pc, true) end)
            if not okRem then
                pcall(function() sm:RemoveSlowdown(pc) end)
            end
        end
    end
    local gs = Subsystem.gameplayStatics()
    if gs and pc then
        pcall(function() gs:SetGlobalTimeDilation(pc, State.timeDilation) end)
    end
    core.consoleCommand("slomo " .. tostring(State.timeDilation))

    local factor = (State.timeDilation > 0.001) and (1.0 / State.timeDilation) or 1.0
    local photoActor = getPhotoActor()
    if isValidObject(photoActor) then
        if State.timeDilation >= 0.999 then
            factor = 1.0
            pcall(function() photoActor.CustomTimeDilation = 1.0 end)
            local mc = photoActor.MovementComponent
            if mc and mc:IsValid() then
                pcall(function()
                    if State.origMaxSpeed then mc.MaxSpeed = State.origMaxSpeed end
                    if State.origAcceleration then mc.Acceleration = State.origAcceleration end
                    if State.origDeceleration then mc.Deceleration = State.origDeceleration end
                end)
            end
            if State.origTurnRate then
                pcall(function()
                    photoActor.BaseTurnRate = State.origTurnRate
                    photoActor.BaseLookUpRate = State.origLookUpRate
                end)
            end
        else
            pcall(function() photoActor.CustomTimeDilation = factor end)
        end

        local mc = photoActor.MovementComponent
        if mc and mc:IsValid() then
            pcall(function()
                local baseMax = State.origMaxSpeed or 1200.0
                local baseAcc = State.origAcceleration or 4000.0
                local baseDec = State.origDeceleration or 8000.0
                mc.MaxSpeed = baseMax * factor
                mc.Acceleration = baseAcc * factor * factor
                mc.Deceleration = baseDec * factor * factor
            end)
        end

        if State.origTurnRate then
            pcall(function()
                photoActor.BaseTurnRate = State.origTurnRate * factor
                photoActor.BaseLookUpRate = State.origLookUpRate * factor
            end)
        end
    end
end

function M.adjustSlomo(slower)
    if not State.photoModeActive or core.cutsceneBlocked("slow motion") then return end
    if slower then
        State.timeDilation = math.max(Config.slomo_min, State.timeDilation * Config.slomo_step)
    else
        State.timeDilation = math.min(Config.slomo_max, State.timeDilation / Config.slomo_step)
    end
    M.applySlomo()
    logMsg("Slomo: %.3fx", State.timeDilation)
    require("lib.osd").updateOSD()
end

function M.stepFrame()
    if not State.photoModeActive or core.cutsceneBlocked("frame step") then return end

    local pc = getPC()
    local gs = Subsystem.gameplayStatics()
    local delayFn = core.delayGameThread

    State.stepEpoch = (State.stepEpoch or 0) + 1
    local epoch = State.stepEpoch
    local function stillValid()
        return State.photoModeActive and State.stepEpoch == epoch
    end

    if State.timeDilation > 0.05 and not State.paused then
        State.timeDilation = Config.slomo_min or 0.02
        M.applySlomo()
        logMsg("Frame Step: auto-froze time to %.2fx", State.timeDilation)
        require("lib.osd").updateOSD()
        return
    end

    if not delayFn then
        logMsg("Frame Step: no delay function available")
        return
    end

    if State.paused then
        if gs and pc then
            pcall(function() gs:SetGamePaused(pc, false) end)
            pcall(function()
                delayFn(30, function()
                    if not stillValid() then return end
                    pcall(function() gs:SetGamePaused(pc, true) end)
                end)
            end)
        end
    else
        local sm = Subsystem.slowMotion()
        if sm and pc then
            pcall(function() sm:AddSlowdown(pc, 0.1, 0.05, {}, false) end)
        end
        if gs and pc then
            pcall(function() gs:SetGlobalTimeDilation(pc, 0.1) end)
        end
        core.consoleCommand("slomo 0.1")
        pcall(function()
            delayFn(35, function()
                if not stillValid() then return end
                M.applySlomo()
            end)
        end)
    end
    logMsg("Frame Step: advanced world frame")
end

function M.unfreeze()
    if not State.photoModeActive or core.cutsceneBlocked("unfreeze") then return end
    State.stepEpoch = (State.stepEpoch or 0) + 1
    if State.paused then
        local pc = getPC()
        local gs = Subsystem.gameplayStatics()
        if gs and pc then pcall(function() gs:SetGamePaused(pc, false) end) end
        State.paused = false
    end
    State.timeDilation = 1.0
    M.applySlomo()
    logMsg("Frame Step: unfrozen, time restored to 1.0x")
    require("lib.osd").updateOSD()
end

---------------------------------------------------------------------------- Player hide

function M.setPawnHidden(pawn, hide)
    if not isValidObject(pawn) then return end
    local ok = pcall(function() pawn:SetActorHiddenInGame(hide) end)
    if ok then
        State.playerHidden = hide
        logMsg("  Player %s", hide and "HIDDEN" or "VISIBLE")
    end
end

function M.toggleHidePlayer()
    if not State.photoModeActive or core.cutsceneBlocked("hide player") then return end
    local pawn = getPlayerPawn()
    if not pawn then return end
    M.setPawnHidden(pawn, not State.playerHidden)
    require("lib.osd").updateOSD()
end

---------------------------------------------------------------------------- HUD toggle

local lastHUDToggleTime = 0

function M.toggleHUD()
    if not State.photoModeActive or core.cutsceneBlocked("hide HUD") then return end
    local now = os.clock()
    if (now - lastHUDToggleTime) < 0.25 then return end
    lastHUDToggleTime = now
    M.setHUDVisible(not State.hudVisible)
    require("lib.osd").updateOSD()
end

return M