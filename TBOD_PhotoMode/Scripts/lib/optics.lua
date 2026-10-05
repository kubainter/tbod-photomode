-- TBOD_PhotoMode optics module
-- Time of Day (SkyCreator), DoF (Auto-Focus via MinimalViewInfo), Aspect Ratio, Weather (SkyCreator presets)
--
-- SkyCreatorPlugin rewrites the sun light transform from TimeOfDay every tick —
-- rotating a DirectionalLight is pointless. DoF/AspectRatio CVars and
-- PlayerCameraManager defaults are likewise ignored by the active view, so both
-- are applied per-frame on outDesiredView (FMinimalViewInfo) in the camera hook.

local core = require("lib.core")
local State = core.State
local Subsystem = core.Subsystem
local logMsg = core.logMsg

local M = {}

local ASPECT_RATIOS = {
    {label = "Off",    val = nil},
    {label = "16:9",   val = 1.7778},
    {label = "21:9",   val = 2.3333},
    {label = "2.35:1", val = 2.35},
    {label = "4:3",    val = 1.3333},
    {label = "1:1",    val = 1.0},
    {label = "9:16",   val = 0.5625},
}

local DOF_FSTOP = 0.5

---------------------------------------------------------------------------- Post-process component (DoF)
-- PhotoCameraActor has NO camera component (pawn CalcCamera); its captured
-- comp is the PLAYER's camera — writes there leak into gameplay. Our own
-- unbound PostProcessComponent on the photo pawn blends regardless of camera.

local function ensureDoFComp()
    if State.dofPPComp and State.dofPPComp:IsValid() then return State.dofPPComp end
    local cam = Subsystem.photoCamera()
    if not (cam and cam:IsValid()) then
        logMsg("Auto-Focus: no photo camera")
        return nil
    end

    -- Preferred path: a real UPostProcessVolume actor — it registers into the
    -- scene's PP volume list through the normal actor lifecycle, which a
    -- StaticConstructObject-built floating component may never reach.
    local gs = core.findStatic("/Script/Engine.Default__GameplayStatics")
    local mathLib = core.findStatic("/Script/Engine.Default__KismetMathLibrary")
    local volCls = core.findStatic("/Script/Engine.PostProcessVolume")
    if gs and mathLib and volCls then
        local vol = nil
        local ok, err = pcall(function()
            local loc = cam:K2_GetActorLocation()
            local t = mathLib:MakeTransform(loc, {Pitch = 0, Yaw = 0, Roll = 0}, {X = 1, Y = 1, Z = 1})
            -- UE5.5 added a 6th param: ESpawnActorScaleMethod
            -- (0=OverrideRootScale, 1=MultiplyWithRoot engine default).
            -- Fall back to the 5-param call for older signatures.
            local deferred = nil
            local ok6 = pcall(function()
                deferred = gs:BeginDeferredActorSpawnFromClass(cam, volCls, t, 3, nil, 1)
            end)
            if not ok6 then
                pcall(function()
                    deferred = gs:BeginDeferredActorSpawnFromClass(cam, volCls, t, 3, nil)
                end)
            end
            if deferred and deferred:IsValid() then
                deferred.bUnbound = true
                deferred.Priority = 10000.0
                deferred.bEnabled = true
                deferred.BlendWeight = 1.0
                -- FinishSpawningActor also gained ESpawnActorScaleMethod.
                local okF = pcall(function()
                    vol = gs:FinishSpawningActor(deferred, t, 1)
                end)
                if not okF then
                    pcall(function() vol = gs:FinishSpawningActor(deferred, t) end)
                end
            end
            if vol and vol:IsValid() then
                -- Re-assert after FinishSpawningActor: actor construction may
                -- have reset volume properties.
                vol.bUnbound = true
                vol.Priority = 10000.0
                vol.bEnabled = true
                vol.BlendWeight = 1.0
            end
        end)
        if ok and vol and vol:IsValid() then
            State.dofPPComp = vol
            logMsg("Auto-Focus: unbound PostProcessVolume spawned")
            return vol
        end
        logMsg("Auto-Focus: PP volume spawn failed (%s)", ok and "invalid result" or tostring(err))
    end

    -- No component fallback: RegisterComponent is a native C++ method, not a
    -- UFunction, so a floating PostProcessComponent can never be registered
    -- into the scene from Lua. Only a spawned actor registers properly.
    return nil
end

local function teardownDoFComp()
    local vol = State.dofPPComp
    if vol and vol:IsValid() then
        pcall(function() vol.bEnabled = false end)
        pcall(function() vol:K2_DestroyActor() end)
    end
    State.dofPPComp = nil
end

---------------------------------------------------------------------------- SkyCreator lookup

function M.skyCreator()
    if State.skyCreator and State.skyCreator:IsValid() then return State.skyCreator end

    local sky = core.findValid({"SkyCreator", "BP_SkyCreator_C", "BP_SkyCreator"})

    -- Fallback: one-time full actor scan by name (handles unexpected class names).
    if not sky then
        local ok, actors = pcall(function() return FindAllOf("Actor") end)
        if ok and actors then
            for _, a in ipairs(actors) do
                if a and a:IsValid() then
                    local okN, nm = pcall(function() return a:GetFullName() end)
                    if okN and nm and nm:find("SkyCreator") then
                        sky = a
                        logMsg("SkyCreator found via name scan: %s", nm)
                        break
                    end
                end
            end
        end
    end

    State.skyCreator = sky
    if not sky then logMsg("SkyCreator actor not found") end
    return sky
end

---------------------------------------------------------------------------- Time of Day

function M.syncTimeOfDay()
    local sky = M.skyCreator()
    if not sky then return end
    local okT, t = pcall(function() return sky.TimeOfDay end)
    if okT and type(t) == "number" then
        State.timeOfDay = t
    end
end

function M.adjustTimeOfDay(delta)
    local sky = M.skyCreator()
    if not sky then
        require("lib.osd").updateOSD()
        return
    end

    -- First adjust: sync from the live value and snapshot it for restore.
    if State.origTimeOfDay == nil then
        local okT, t = pcall(function() return sky.TimeOfDay end)
        if okT and type(t) == "number" then
            State.origTimeOfDay = t
            State.timeOfDay = t
        end
    end

    State.timeOfDay = (State.timeOfDay + delta) % 24.0

    local okSet = pcall(function() sky:SetTime(State.timeOfDay) end)
    if not okSet then
        pcall(function() sky.TimeOfDay = State.timeOfDay end)
        pcall(function() sky:OnRep_UpdateTime() end)
    end
    logMsg("Time of Day: %.2f", State.timeOfDay)

    require("lib.osd").updateOSD()
end

---------------------------------------------------------------------------- Auto-Focus / DoF

-- DoF is written through every PP channel that might feed the photo view
-- (own unbound volume, SkyCreator's internal pipeline, captured camera comp).
-- Restore clears only the bOverride_* flags we set — no snapshots needed.
local DOF_OVERRIDE_FIELDS = {
    "bOverride_DepthOfFieldFocalDistance",
    "bOverride_DepthOfFieldFstop",
    "bOverride_DepthOfFieldMinFstop",
    "bOverride_DepthOfFieldFocalRegion",
    "bOverride_FilmSaturation",
}

local function setDoFOnSettings(pps)
    -- UE5 uses Diaphragm (physical) DoF: blur comes from focal distance +
    -- f-stop only. Near/FarBlurSize, DepthBlur*, Occlusion, SkyFocusDistance
    -- are UE4 Gaussian legacy fields the UE5 renderer ignores.
    pps.bOverride_DepthOfFieldFocalDistance = true
    pps.DepthOfFieldFocalDistance = State.focalDistance
    pps.bOverride_DepthOfFieldFstop = true
    pps.DepthOfFieldFstop = State.dofFstop or DOF_FSTOP
    pps.bOverride_DepthOfFieldMinFstop = true
    pps.DepthOfFieldMinFstop = 0.05
    -- Zero focal region so blur ramps up immediately outside the focus plane.
    pps.bOverride_DepthOfFieldFocalRegion = true
    pps.DepthOfFieldFocalRegion = 0.0
end

local function clearDoFOnSettings(pps)
    for _, f in ipairs(DOF_OVERRIDE_FIELDS) do
        pcall(function() pps[f] = false end)
    end
end

-- Exposure compensation (1.6.0) shares the same unbound volume — the actor
-- must stay enabled while either feature carries an override.
local EXPOSURE_MIN = -4.0
local EXPOSURE_MAX = 4.0

local function ppVolumeActive()
    return State.dofEnabled or (State.exposureBias or 0.0) ~= 0.0
end

local function setExposureOnSettings(pps)
    pps.bOverride_AutoExposureBias = true
    pps.AutoExposureBias = State.exposureBias
end

local function clearExposureOnSettings(pps)
    pcall(function() pps.bOverride_AutoExposureBias = false end)
end

local function clearDoFEverywhere()
    local comp = State.dofPPComp
    if comp and comp:IsValid() then
        pcall(function()
            local pps = comp.Settings
            if pps then clearDoFOnSettings(pps); comp.Settings = pps end
            comp.bEnabled = ppVolumeActive()
        end)
    end
end

function M.triggerAutoFocus()
    local pc = Subsystem.playerController()
    local pcm = pc and pc.PlayerCameraManager
    local kmath = core.findStatic("/Script/Engine.Default__KismetMathLibrary")
    local ksys = Subsystem.kismetSystem()

    if not (pc and pcm and kmath and ksys) then return end

    local traceLen = 50000.0
    local ok, hitDist = pcall(function()
        local startLoc = pcm:GetCameraLocation()
        local rot = pcm:GetCameraRotation()
        local fwd = kmath:GetForwardVector(rot)
        local endLoc = {
            X = startLoc.X + (fwd.X * traceLen),
            Y = startLoc.Y + (fwd.Y * traceLen),
            Z = startLoc.Z + (fwd.Z * traceLen)
        }

        -- ETraceTypeQuery::TraceTypeQuery1 = Visibility
        -- UE4SS Lua: OutHit is returned, not passed as argument.
        local hit, outHit = ksys:LineTraceSingle(
            pc, startLoc, endLoc, 0, false, {}, 0,
            true, -- bIgnoreSelf
            {R=0,G=0,B=0,A=0}, {R=0,G=0,B=0,A=0}, 0.0
        )
        if hit and outHit then
            return outHit.Distance
        end
        return nil
    end)

    if ok and hitDist then
        State.focalDistance = hitDist
        logMsg("Auto-Focus hit at: %.1f cm", State.focalDistance)
    else
        -- No hit (e.g. aiming at the sky): use a portrait distance, not
        -- infinity. At ~18mm equivalent FOV (90 deg), focusing at 50m puts
        -- the hyperfocal plane so close that nothing ever blurs; 400cm keeps
        -- the foreground sharp and blurs the background visibly.
        State.focalDistance = 400.0
        logMsg("Auto-Focus: no hit, focusing at 400cm")
    end

    State.dofEnabled = true
    State.dofFstop = DOF_FSTOP
    M.applyDoF()
    -- The quality CVar only ensures the DoF pass isn't scaled out.
    State.origDoFQuality = core.getCVarInt("r.DepthOfFieldQuality")
    core.setCVar("r.DepthOfFieldQuality", 4)

    require("lib.osd").updateOSD()
end

function M.applyDoF()
    -- Channel 1: our own unbound PostProcessVolume (standard PM)
    local comp = ensureDoFComp()
    if comp then
        pcall(function()
            local pps = comp.Settings
            if pps then setDoFOnSettings(pps); comp.Settings = pps end
            comp.Priority = 10000.0
            comp.BlendWeight = 1.0
            comp.bEnabled = true
            comp.bUnbound = true
        end)
    end

    -- Channel 2: Cutscene PM (UCineCameraComponent FocusSettings & Aperture)
    if State.cutscenePMEntry then
        local vt, camComp = core.getActiveCutsceneCamera()
        if camComp and camComp:IsValid() then
            pcall(function()
                if State.origCutsceneFocusSettings == nil then
                    local fs = camComp.FocusSettings
                    if fs then
                        State.origCutsceneFocusSettings = {
                            FocusMethod = fs.FocusMethod,
                            ManualFocusDistance = fs.ManualFocusDistance
                        }
                    end
                    State.origCutsceneAperture = camComp.CurrentAperture
                end

                local fs = camComp.FocusSettings
                if fs then
                    fs.FocusMethod = 1 -- Manual
                    fs.ManualFocusDistance = State.focalDistance or 400.0
                    camComp:SetFocusSettings(fs)
                end
                camComp:SetCurrentAperture(State.dofFstop or 1.4)
                logMsg("  Cutscene PM: CineCamera Focus applied (dist=%.1f, fstop=%.1f) to %s",
                    State.focalDistance or 400.0, State.dofFstop or 1.4, tostring(camComp:GetFullName()))
            end)
        end
    end
end

function M.disableDoF()
    State.dofEnabled = false
    clearDoFEverywhere()

    -- Cutscene mode: restore native focus settings
    if State.cutscenePMEntry then
        local vt, camComp = core.getActiveCutsceneCamera()
        if camComp and camComp:IsValid() then
            pcall(function()
                if State.origCutsceneFocusSettings then
                    local fs = camComp.FocusSettings
                    if fs then
                        fs.FocusMethod = State.origCutsceneFocusSettings.FocusMethod
                        fs.ManualFocusDistance = State.origCutsceneFocusSettings.ManualFocusDistance
                        camComp:SetFocusSettings(fs)
                    end
                end
                if State.origCutsceneAperture then
                    camComp:SetCurrentAperture(State.origCutsceneAperture)
                end
                logMsg("  Cutscene PM: CineCamera Focus restored")
            end)
        end
    end

    logMsg("Auto-Focus: DoF off")
    require("lib.osd").updateOSD()
end

---------------------------------------------------------------------------- Exposure (EV bias)

function M.applyExposure()
    local comp = ensureDoFComp()
    if comp then
        pcall(function()
            local pps = comp.Settings
            if pps then
                if (State.exposureBias or 0.0) ~= 0.0 then
                    setExposureOnSettings(pps)
                else
                    clearExposureOnSettings(pps)
                end
                comp.Settings = pps
            end
            comp.Priority = 10000.0
            comp.BlendWeight = 1.0
            comp.bUnbound = true
            comp.bEnabled = ppVolumeActive()
        end)
    end

    -- Cutscene mode: also apply directly to active cinematic camera component & PCM
    if State.cutscenePMEntry then
        local vt, camComp = core.getActiveCutsceneCamera()
        if camComp and camComp:IsValid() then
            pcall(function()
                local pps = camComp.PostProcessSettings
                if pps then
                    if State.origCutsceneExposure == nil then
                        State.origCutsceneExposure = {
                            bOverride = pps.bOverride_AutoExposureBias,
                            bias = pps.AutoExposureBias,
                            weight = camComp.PostProcessBlendWeight
                        }
                    end
                    if (State.exposureBias or 0.0) ~= 0.0 then
                        pps.bOverride_AutoExposureBias = true
                        pps.AutoExposureBias = State.exposureBias
                    else
                        pps.bOverride_AutoExposureBias = (State.origCutsceneExposure and State.origCutsceneExposure.bOverride) or false
                        pps.AutoExposureBias = (State.origCutsceneExposure and State.origCutsceneExposure.bias) or 0.0
                    end
                    camComp.PostProcessSettings = pps
                    camComp.PostProcessBlendWeight = 1.0
                    logMsg("  Cutscene PM: applied Exposure=%+.2f to CameraComponent", State.exposureBias or 0.0)
                end
            end)
        end
        local pc = Subsystem.playerController()
        local pcm = pc and pc.PlayerCameraManager
        if pcm and pcm:IsValid() then
            pcall(function()
                local pps = pcm.CameraCachePrivate.POV.PostProcessSettings
                if pps then
                    if (State.exposureBias or 0.0) ~= 0.0 then
                        pps.bOverride_AutoExposureBias = true
                        pps.AutoExposureBias = State.exposureBias
                    else
                        pps.bOverride_AutoExposureBias = false
                    end
                    pcm.CameraCachePrivate.POV.PostProcessSettings = pps
                    pcm.CameraCachePrivate.POV.PostProcessBlendWeight = 1.0
                end
            end)
        end
    end

    logMsg("Exposure: %+.2f EV", State.exposureBias or 0.0)
    require("lib.osd").updateOSD()
end

function M.adjustExposure(delta)
    local v = (State.exposureBias or 0.0) + delta
    if v > EXPOSURE_MAX then v = EXPOSURE_MAX end
    if v < EXPOSURE_MIN then v = EXPOSURE_MIN end
    State.exposureBias = v
    M.applyExposure()
end

function M.getExposureLabel()
    return string.format("%+.2f EV", State.exposureBias or 0.0)
end

---------------------------------------------------------------------------- Aspect Ratio

function M.applyAspectRatio()
    -- Fake letterbox: UMG black bars (see osd.setLetterbox). A real constrained
    -- aspect cannot apply to the photo pawn's componentless view.
    require("lib.osd").setLetterbox(State.aspectRatioValue)
end

function M.adjustAspectRatio(delta)
    local n = #ASPECT_RATIOS
    State.aspectRatioIdx = ((State.aspectRatioIdx + delta - 1) % n) + 1
    State.aspectRatioValue = ASPECT_RATIOS[State.aspectRatioIdx].val
    M.applyAspectRatio()
    logMsg("Aspect Ratio: %s", ASPECT_RATIOS[State.aspectRatioIdx].label)

    require("lib.osd").updateOSD()
end

function M.getAspectRatioLabel()
    return ASPECT_RATIOS[State.aspectRatioIdx].label
end

---------------------------------------------------------------------------- Weather (SkyCreatorWeatherPreset)

-- SkyCreatorWeatherSettings vs WeatherPreset: same 11 sub-structs, only the
-- MaterialFX field name differs. Field-by-field property writes — passing the
-- 17880-byte struct through a UFunction crashes this UE4SS build.
local WEATHER_FIELD_MAP = {
    {"SkyAtmosphereSettings",         "SkyAtmosphereSettings"},
    {"VolumetricCloudSettings",       "VolumetricCloudSettings"},
    {"BackgroundCloudSettings",       "BackgroundCloudSettings"},
    {"SkyLightSettings",              "SkyLightSettings"},
    {"SunLightSettings",              "SunLightSettings"},
    {"MoonLightSettings",             "MoonLightSettings"},
    {"ExponentialHeightFogSettings",  "ExponentialHeightFogSettings"},
    {"StarMapSettings",               "StarMapSettings"},
    {"WeatherFXSettings",             "WeatherFXSettings"},
    {"MaterialFXSettings",            "WeatherMaterialFXSettings"},
    {"WindSettings",                  "WindSettings"},
    {"PostProcessSettings",           "PostProcessSettings"},
}

local function loadWeatherPresets()
    if State.weatherPresetsScanned then return end
    State.weatherPresetsScanned = true
    State.weatherPresets = {}

    local ok, presets = pcall(function() return FindAllOf("SkyCreatorWeatherPreset") end)
    if ok and presets then
        for _, p in ipairs(presets) do
            if p and p:IsValid() then
                local nm = ""
                pcall(function() nm = p:GetFName():ToString() end)
                -- skip the Class Default Object
                if nm ~= "" and not nm:match("^Default__") then
                    table.insert(State.weatherPresets, {name = nm, obj = p})
                end
            end
        end
        table.sort(State.weatherPresets, function(a, b) return a.name < b.name end)
    end
    logMsg("Weather: %d SkyCreator presets loaded", #State.weatherPresets)
end

local function copyPresetToSky(sky, preset, targetField)
    local ws = nil
    pcall(function() ws = sky[targetField] end)
    if not ws then return false end
    for _, pair in ipairs(WEATHER_FIELD_MAP) do
        local src = nil
        pcall(function() src = preset[pair[2]] end)
        if src then
            pcall(function() ws[pair[1]] = src end)
        end
    end
    pcall(function() sky:OnRep_UpdateWeather() end)
    return true
end

function M.adjustWeather(delta)
    local sky = M.skyCreator()
    if not sky then
        require("lib.osd").updateOSD()
        return
    end

    loadWeatherPresets()
    local n = #State.weatherPresets
    if n == 0 then
        logMsg("Weather: no SkyCreatorWeatherPreset assets loaded")
        require("lib.osd").updateOSD()
        return
    end

    State.weatherIdx = (((State.weatherIdx or 0) + delta - 1) % n) + 1
    local preset = State.weatherPresets[State.weatherIdx]

    -- When editor weather mode is on, the live settings live in
    -- EditorWeatherSettings instead of WeatherSettings — write there.
    local targetField = "WeatherSettings"
    local okB, editorMode = pcall(function() return sky.bUseEditorWeatherSettings end)
    if okB and editorMode then targetField = "EditorWeatherSettings" end

    -- Snapshot live weather once. Normal path stashes live settings in
    -- SkyCreator's unused EditorWeatherSettings field (same struct type). In
    -- editor mode that field IS the live one — snapshot into Lua instead.
    if not State.origWeatherSaved then
        if targetField == "WeatherSettings" then
            pcall(function() sky.EditorWeatherSettings = sky.WeatherSettings end)
            State.origWeatherSaved = true
        else
            -- Only mark the snapshot valid when the live struct was actually
            -- readable — an empty table must not claim "Weather restored".
            local saved = {}
            local ws = nil
            pcall(function() ws = sky.EditorWeatherSettings end)
            if ws then
                for _, pair in ipairs(WEATHER_FIELD_MAP) do
                    local f = pair[1]
                    pcall(function() saved[f] = ws[f] end)
                end
                State.origWeatherFields = saved
                State.origWeatherSaved = true
            else
                logMsg("Weather: editor-settings read failed, snapshot skipped")
            end
        end
    end

    local okApply, err = pcall(function() copyPresetToSky(sky, preset.obj, targetField) end)
    if okApply then
        logMsg("Weather: %s", preset.name)
    else
        logMsg("Weather: apply failed (%s)", tostring(err))
    end

    require("lib.osd").updateOSD()
end

function M.getWeatherLabel()
    if not State.weatherIdx or not State.weatherPresets or not State.weatherPresets[State.weatherIdx] then
        return "Default"
    end
    return State.weatherPresets[State.weatherIdx].name
end

---------------------------------------------------------------------------- Restore / Reset

function M.restoreAll()
    local sky = State.skyCreator
    if sky and sky:IsValid() then
        if State.origTimeOfDay ~= nil then
            local okSet = pcall(function() sky:SetTime(State.origTimeOfDay) end)
            if not okSet then
                pcall(function() sky.TimeOfDay = State.origTimeOfDay end)
                pcall(function() sky:OnRep_UpdateTime() end)
            end
            State.timeOfDay = State.origTimeOfDay
            State.origTimeOfDay = nil
            logMsg("  Time of Day restored")
        end
        if State.origWeatherSaved then
            if State.origWeatherFields then
                -- Editor-mode snapshot lives in Lua — write each sub-struct
                -- back into the live EditorWeatherSettings field.
                local ws = nil
                pcall(function() ws = sky.EditorWeatherSettings end)
                if ws then
                    for fname, val in pairs(State.origWeatherFields) do
                        pcall(function() ws[fname] = val end)
                    end
                    -- Write-back: harmless if ws is a live ref (the proven
                    -- preset path suggests it is), required if it's a copy.
                    pcall(function() sky.EditorWeatherSettings = ws end)
                end
                State.origWeatherFields = nil
            else
                pcall(function() sky.WeatherSettings = sky.EditorWeatherSettings end)
            end
            pcall(function() sky:OnRep_UpdateWeather() end)
            State.origWeatherSaved = false
            logMsg("  Weather restored")
        end
    end
    State.skyCreator = nil
    State.weatherIdx = nil
    State.weatherPresets = nil
    State.weatherPresetsScanned = false

    clearDoFEverywhere()
    teardownDoFComp()
    require("lib.osd").setLetterbox(nil)

    State.dofEnabled = false
    State.exposureBias = 0.0
    State.focalDistance = 1000.0
    if State.origDoFQuality ~= nil then
        core.setCVar("r.DepthOfFieldQuality", State.origDoFQuality)
    else
        -- Snapshot failed: user's original value is unrecoverable. Restore the
        -- engine default rather than leaving our forced 4 — and say so.
        core.setCVar("r.DepthOfFieldQuality", 2)
        logMsg("  WARN: DoF quality snapshot missing, restored engine default")
    end
    -- Restore Cutscene PM camera adjustments
    if State.origCutsceneExposure then
        local vt, camComp = core.getActiveCutsceneCamera()
        if camComp and camComp:IsValid() then
            pcall(function()
                local pps = camComp.PostProcessSettings
                if pps then
                    pps.bOverride_AutoExposureBias = State.origCutsceneExposure.bOverride or false
                    pps.AutoExposureBias = State.origCutsceneExposure.bias or 0.0
                    camComp.PostProcessSettings = pps
                    camComp.PostProcessBlendWeight = State.origCutsceneExposure.weight or 1.0
                end
            end)
        end
        State.origCutsceneExposure = nil
    end

    local pc = Subsystem.playerController()
    local pcm = pc and pc.PlayerCameraManager
    if pcm and pcm:IsValid() then
        pcall(function()
            local pps = pcm.CameraCachePrivate.POV.PostProcessSettings
            if pps then
                pps.bOverride_AutoExposureBias = false
                pcm.CameraCachePrivate.POV.PostProcessSettings = pps
            end
        end)
    end

    if State.origCutsceneFocusSettings or State.origCutsceneAperture then
        local vt, camComp = core.getActiveCutsceneCamera()
        if camComp and camComp:IsValid() then
            pcall(function()
                if State.origCutsceneFocusSettings then
                    local fs = camComp.FocusSettings
                    if fs then
                        fs.FocusMethod = State.origCutsceneFocusSettings.FocusMethod
                        fs.ManualFocusDistance = State.origCutsceneFocusSettings.ManualFocusDistance
                        camComp:SetFocusSettings(fs)
                    end
                end
                if State.origCutsceneAperture then
                    camComp:SetCurrentAperture(State.origCutsceneAperture)
                end
            end)
        end
        State.origCutsceneFocusSettings = nil
        State.origCutsceneAperture = nil
    end

    State.aspectRatioIdx = 1
    State.aspectRatioValue = nil
end

return M

