-- In-engine E2E suite: runs on the game thread via ue4ss-bridge eval;
-- enforces Rule 8 (PM Statelessness) & the TIK-008 leak audit.

local core = require("lib.core")
local State = core.State
local Config = core.Config
local Subsystem = core.Subsystem
local logMsg = core.logMsg

local photomode = require("lib.photomode")
local osd = require("lib.osd")
local spawner = require("lib.spawner")
local poses = require("lib.poses")
local eventbridge = require("lib.eventbridge")

local M = {}

-- Self-contained JSON Serializer (for structured bridge transport)

local function escapeJsonString(s)
    local matches = {
        ['\\'] = '\\\\',
        ['"']  = '\\"',
        ['\b'] = '\\b',
        ['\f'] = '\\f',
        ['\n'] = '\\n',
        ['\r'] = '\\r',
        ['\t'] = '\\t'
    }
    return '"' .. s:gsub('[\\"\b\f\n\r\t]', matches) .. '"'
end

function M.toJson(val)
    local t = type(val)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "number" then
        if val ~= val then return '"NaN"' end
        if val >= math.huge then return '"Infinity"' end
        if val <= -math.huge then return '"-Infinity"' end
        return tostring(val)
    elseif t == "string" then
        return escapeJsonString(val)
    elseif t == "table" then
        local isArray = true
        local maxIdx = 0
        local count = 0
        for k, _ in pairs(val) do
            count = count + 1
            if type(k) == "number" and k > 0 and math.floor(k) == k then
                if k > maxIdx then maxIdx = k end
            else
                isArray = false
            end
        end
        if count == 0 then
            return "[]"
        end
        if isArray and maxIdx == count then
            local parts = {}
            for i = 1, count do
                table.insert(parts, M.toJson(val[i]))
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, v in pairs(val) do
                table.insert(parts, escapeJsonString(tostring(k)) .. ":" .. M.toJson(v))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    else
        return escapeJsonString(tostring(val))
    end
end

-- Test Scenario Factory

local function newScenario(id, name)
    local s = {
        id = id,
        name = name,
        passed = true,
        duration_ms = 0,
        assertions = {},
        error = nil
    }
    function s:assert(name, condition, details)
        local ok = (condition == true or (condition ~= nil and condition ~= false))
        local entry = {
            name = name,
            passed = ok,
            details = details or (ok and "Verified" or "Assertion failed")
        }
        table.insert(self.assertions, entry)
        if not ok then
            self.passed = false
        end
        return ok
    end
    return s
end

-- Scenario Implementations

-- Scenario A: Subsystems & Reflection Liveness
local function runScenarioA()
    local s = newScenario("A", "Subsystems & Reflection Liveness")
    local t0 = os.clock()

    -- 1. DogwoodPhotomodeSubsystem
    local pm = Subsystem.photoMode()
    s:assert("DogwoodPhotomodeSubsystem present and valid",
        pm ~= nil and core.isValidInstance(pm),
        pm and "Found instance: " .. tostring(pm:GetFName():ToString()) or "Subsystem not found")

    -- 2. PlayerController & PlayerInput
    local pc = Subsystem.playerController()
    local isRealPC = pc and core.isRealPlayerController(pc)
    s:assert("PlayerController is real gameplay instance",
        isRealPC,
        pc and ("Found: " .. tostring(pc:GetFName():ToString())) or "Real PlayerController not found")

    local hasInput = false
    pcall(function() hasInput = pc and pc.PlayerInput and pc.PlayerInput:IsValid() end)
    s:assert("PlayerController has active PlayerInput",
        hasInput,
        hasInput and "PlayerInput active" or "PlayerInput missing")

    -- 3. CommonInputSubsystem
    local cis = eventbridge.getCommonInputSubsystem(pc)
    if not (cis and cis:IsValid()) then
        cis = core.findValid({"CommonInputSubsystem", "UCommonInputSubsystem"})
    end
    s:assert("CommonInputSubsystem present and valid",
        cis ~= nil and cis:IsValid(),
        cis and ("Found: " .. tostring(cis:GetFName():ToString())) or "CommonInputSubsystem not found")

    -- 4. Default__GameplayStatics
    local gs = Subsystem.gameplayStatics()
    s:assert("Default__GameplayStatics reflection is valid",
        gs ~= nil and gs:IsValid(),
        gs and "Static class found" or "Default__GameplayStatics not found")

    -- 5. Default__WidgetBlueprintLibrary
    local wbl = core.findStatic("/Script/UMG.Default__WidgetBlueprintLibrary")
    s:assert("Default__WidgetBlueprintLibrary reflection is valid",
        wbl ~= nil and wbl:IsValid(),
        wbl and "Static library found" or "WidgetBlueprintLibrary not found")

    s.duration_ms = math.floor((os.clock() - t0) * 1000)
    return s
end

-- Scenario B: full PM lifecycle, split across frames - auto-pause fires
-- 600 ms after entry (pause_on_enter -> delayGameThread(600)), so the
-- pause assert must run in a later stage.
local function runScenarioB_enter()
    local s = newScenario("B", "Full Photo Mode Lifecycle")
    s._t0 = os.clock()

    -- 1. Initial State Check
    s:assert("Initial state: Photo Mode is inactive",
        not State.photoModeActive,
        "PM was already active before test start")

    -- 2. Programmatic Entry
    photomode.enterPhotoMode()
    s:assert("PhotoMode entered: State.photoModeActive == true",
        State.photoModeActive == true,
        "State.photoModeActive remained false after enterPhotoMode")

    -- 3. Camera Possession Assertion
    local photoCam = Subsystem.photoCamera()
    s:assert("PhotoCameraActor is discovered and valid",
        photoCam ~= nil and photoCam:IsValid(),
        photoCam and ("Actor: " .. tostring(photoCam:GetFName():ToString())) or "PhotoCameraActor not found")

    local pc = Subsystem.playerController()
    local pcm = pc and pc.PlayerCameraManager
    local vt = pcm and pcm.ViewTarget and pcm.ViewTarget.Target
    local camPossessed = false
    if vt and vt:IsValid() then
        if photoCam and core.sameObject(vt, photoCam) then
            camPossessed = true
        elseif vt:GetFName():ToString():find("PhotoCamera") then
            camPossessed = true
        end
    end
    s:assert("PCM ViewTarget transferred to PhotoCameraActor",
        camPossessed,
        vt and ("Current ViewTarget: " .. tostring(vt:GetFullName())) or "No ViewTarget on PCM")

    s._photoCam = photoCam
    s._pc = pc
    s._pcm = pcm
    return s
end

local function runScenarioB_finish(s)
    local pc = s._pc or Subsystem.playerController()
    local pcm = s._pcm or (pc and pc.PlayerCameraManager)
    local photoCam = s._photoCam

    -- 4. World Pause Assertion (after the 600 ms pause_on_enter delay)
    local isPaused = (State.paused == true)
    local gs = Subsystem.gameplayStatics()
    if not isPaused and gs and pc then
        pcall(function() isPaused = gs:IsGamePaused(pc) end)
    end
    s:assert("World paused upon Photo Mode entry (pause_on_enter)",
        isPaused or (Config.pause_on_enter == false),
        string.format("State.paused=%s, IsGamePaused=%s", tostring(State.paused), tostring(isPaused)))

    -- 5. Programmatic Exit
    photomode.exitPhotoMode()
    s:assert("PhotoMode exited: State.photoModeActive == false",
        State.photoModeActive == false,
        "State.photoModeActive remained true after exitPhotoMode")

    -- 6. Player Control and Camera Restored Assertion
    s:assert("Input isolation released: State.gameInputIsolated == false",
        State.gameInputIsolated == false,
        "Input isolation still active after exit")

    local vtAfter = pcm and pcm.ViewTarget and pcm.ViewTarget.Target
    local notPhotoCam = true
    if vtAfter and photoCam and core.sameObject(vtAfter, photoCam) then
        notPhotoCam = false
    end
    s:assert("Camera possession returned from PhotoCameraActor to gameplay target",
        notPhotoCam,
        vtAfter and ("Restored ViewTarget: " .. tostring(vtAfter:GetFName():ToString())) or "ViewTarget is nil")

    s.duration_ms = math.floor((os.clock() - (s._t0 or os.clock())) * 1000)
    return s
end

-- Scenario C: OSD navigation & parameter modulation.
-- FOV is asserted on the Lua->native conduit (PCM DefaultFOV). The rendered
-- value (ViewTarget.POV.FOV) is only refreshed by CalcCamera, which does not
-- tick while the world is paused (pause_on_enter) - reading it under pause
-- returns a stale value. The rendered half of the path is covered by the
-- TBOD_PMFov mirror (embedded FMinimalViewInfo, logged "mirror active") and
-- Scenario B's ViewTarget assertions.

local function conduitFOV()
    local pc = Subsystem.playerController()
    local pcm = pc and pc.PlayerCameraManager
    if not (pcm and pcm:IsValid()) then return nil end
    local v = nil
    pcall(function() v = pcm.DefaultFOV end)
    if type(v) == "userdata" and type(Unwrap) == "function" then
        pcall(function() v = Unwrap(v) end)
    end
    if type(v) == "number" then return v end
    return nil
end

local function runScenarioC_enter()
    local s = newScenario("C", "OSD Navigation & Parameter Modulation")
    s._t0 = os.clock()

    -- 1. Enter PM and ensure OSD is displayed
    if not State.photoModeActive then
        photomode.enterPhotoMode()
    end
    osd.showOSD()
    s:assert("OSD is visible in Photo Mode",
        State.osdVisible == true,
        "State.osdVisible is false")

    -- 2. Tab Navigation
    local initialTab = osd.currentTab or 1
    osd.osdTab(1)
    local tabAfterNext = osd.currentTab or 1
    s:assert("osdTab(1) switches to next tab",
        tabAfterNext ~= initialTab,
        string.format("Tab changed from %d to %d", initialTab, tabAfterNext))

    osd.osdTab(-1)
    local tabAfterPrev = osd.currentTab or 1
    s:assert("osdTab(-1) returns to previous tab",
        tabAfterPrev == initialTab,
        string.format("Tab returned to %d", tabAfterPrev))

    -- 3. FOV Modulation (Tab 1 / Camera Tab)
    osd.currentTab = 1
    osd.OSD_SELECTED = 1 -- Row 1 is FOV
    s._baselineFOV = State.fov or Config.fov_default
    osd.osdAdjust(1)
    s._modifiedFOV = State.fov or s._baselineFOV
    return s
end

local function runScenarioC_assert(s)
    -- 3b. Conduit FOV must follow the slider (DefaultFOV -> native mirror)
    local rf = conduitFOV()
    s:assert("osdAdjust(1) modifies FOV",
        rf ~= nil and math.abs(rf - s._modifiedFOV) < 0.5,
        string.format("DefaultFOV=%s, expected=%.1f (state %.1f -> %.1f)",
            tostring(rf), s._modifiedFOV, s._baselineFOV, s._modifiedFOV))

    -- TIK-013 Camera Speed Guard Check:
    local photoCam = Subsystem.photoCamera()
    local mc = (photoCam and photoCam:IsValid()) and photoCam.MovementComponent or nil
    s:assert("TIK-013: Camera MaxSpeed clamped to origMaxSpeed during FOV adjustment",
        mc ~= nil and mc:IsValid() and State.origMaxSpeed ~= nil and math.abs(mc.MaxSpeed - State.origMaxSpeed) < 0.1,
        (mc and mc:IsValid() and State.origMaxSpeed)
            and string.format("mc.MaxSpeed=%.1f, origMaxSpeed=%.1f", mc.MaxSpeed, State.origMaxSpeed)
            or "photoCam/MovementComponent/origMaxSpeed unavailable")

    -- 4. Exposure Modulation
    local expRow = nil
    for idx, r in ipairs(osd.OSD_ROWS) do
        if r.label == "Exposure" then expRow = idx break end
    end
    if expRow then
        osd.OSD_SELECTED = expRow
        local baselineExp = State.exposureBias or 0.0
        osd.osdAdjust(1)
        local modifiedExp = State.exposureBias or baselineExp
        s:assert("osdAdjust(1) modifies Exposure",
            math.abs(modifiedExp - baselineExp) > 0.001,
            string.format("Exposure changed from %.2f to %.2f", baselineExp, modifiedExp))
    else
        s:assert("Exposure row discovered in OSD_ROWS", false, "Exposure row missing")
    end

    -- 5. Time of Day Modulation (Tab 2 / Environment Tab)
    -- adjustTimeOfDay re-syncs State.timeOfDay from the live sky on its first
    -- call, so a stale Lua baseline produces a false zero-delta — sync first.
    local todRow = nil
    for idx, r in ipairs(osd.OSD_ROWS) do
        if r.label == "Time of Day" then todRow = idx break end
    end
    if todRow then
        osd.currentTab = 2 -- ENVIRONMENT tab
        osd.OSD_SELECTED = todRow
        pcall(function() require("lib.optics").syncTimeOfDay() end)
        local baselineTOD = State.timeOfDay or 12.0
        osd.osdAdjust(1)
        local modifiedTOD = State.timeOfDay or baselineTOD
        s:assert("osdAdjust(1) modifies Time of Day",
            math.abs(modifiedTOD - baselineTOD) > 0.001,
            string.format("TimeOfDay changed from %.2f to %.2f", baselineTOD, modifiedTOD))
    else
        s:assert("Time of Day row discovered in OSD_ROWS", false, "Time of Day row missing")
    end

    -- 6. OSD Reset (rendered FOV verified in the next stage)
    osd.osdReset()
    return s
end

local function runScenarioC_finish(s)
    local rf = conduitFOV()
    s:assert("osdReset() restores FOV to default",
        rf ~= nil and math.abs(rf - Config.fov_default) < 0.5,
        string.format("DefaultFOV=%s, expected=%.1f (state %.1f)",
            tostring(rf), Config.fov_default, State.fov or 0))
    s:assert("osdReset() restores Exposure to 0.0",
        math.abs(State.exposureBias or 0) < 0.01,
        string.format("Exposure restored to %.2f (expected 0.0)", State.exposureBias or 0))

    -- Exit PM
    photomode.exitPhotoMode()
    s.duration_ms = math.floor((os.clock() - (s._t0 or os.clock())) * 1000)
    return s
end

-- Scenario D: directing & spawner, two stages - spawn is synchronous but the
-- clone appearance pipeline assembles over several frames via the spawner's
-- own 40 ms pulses (3 x 200 ms, TIK-008). Weapon/prop asserts run in a later
-- stage (~1.5 s) or the clone has no SkeletalMeshComponent yet (false FAIL).
local function runScenarioD_spawn()
    local s = newScenario("D", "Directing & Spawner Integrity")
    s._t0 = os.clock()

    -- 1. Enter PM
    if not State.photoModeActive then
        photomode.enterPhotoMode()
    end

    -- 2. Spawn Clone
    local initialCount = #spawner.spawnedClones
    local clone = spawner.spawnClone()
    s:assert("spawner.spawnClone() returns valid actor",
        clone ~= nil and clone:IsValid(),
        clone and ("Spawned: " .. tostring(clone:GetFName():ToString())) or "Clone actor is nil/invalid")

    s:assert("Clone registered in spawner.spawnedClones",
        #spawner.spawnedClones == initialCount + 1,
        string.format("Clone count is %d (was %d)", #spawner.spawnedClones, initialCount))

    return s, clone
end

local function runScenarioD_finish(s, clone)
    -- Re-resolve: the captured ref dangles if the appearance pipeline or a
    -- premature teardown destroyed the clone; the spawner table is authoritative.
    if not (clone and clone:IsValid()) then
        clone = spawner.spawnedClones[#spawner.spawnedClones]
    end

    -- 3. Equip Weapon on Clone (after the appearance pipeline has assembled)
    if clone and clone:IsValid() then
        local w = spawner.equipCloneWeapon(clone)
        local hasWeapon = w ~= nil and w:IsValid()
        s:assert("Weapon equipped or hijacked on spawned clone",
            hasWeapon,
            hasWeapon and ("Weapon comp: " .. tostring(w:GetFName():ToString())) or "equipCloneWeapon returned nil/invalid")

        -- 4. Apply Prop to Clone
        local propPreset = poses.PROP_PRESETS and (poses.PROP_PRESETS.hammer or poses.PROP_PRESETS.spoon or poses.PROP_PRESETS.book)
        if not propPreset then
            propPreset = { mesh = "/Game/_Dawnwalker/Environment/Megascans/3D_Assets/LargeWoodenSpoon/SM_LargeWoodenSpoon_02_withFood.SM_LargeWoodenSpoon_02_withFood" }
        end
        local prop = spawner.spawnProp(clone, propPreset, "r")
        s:assert("spawner.spawnProp() returns valid prop instance",
            prop ~= nil and prop:IsValid(),
            prop and ("Prop: " .. tostring(prop:GetFName():ToString())) or "Prop is nil/invalid")

        local attachParent = nil
        if prop then pcall(function() attachParent = prop:GetAttachParent() end) end
        s:assert("Prop is physically attached to character socket/component",
            attachParent ~= nil and attachParent:IsValid(),
            attachParent and ("Attach parent: " .. tostring(attachParent:GetFName():ToString())) or "Prop unattached")
    else
        s:assert("Weapon equipped or hijacked on spawned clone", false, "Clone invalid before delayed stage")
        s:assert("spawner.spawnProp() returns valid prop instance", false, "Clone invalid")
        s:assert("Prop is physically attached to character socket/component", false, "Clone invalid")
    end

    -- 5. Destroy All Spawner Entities
    spawner.destroyAll()
    s:assert("spawner.destroyAll() clears all clones",
        #spawner.spawnedClones == 0,
        string.format("Remaining clones: %d", #spawner.spawnedClones))

    local lingeringProps = 0
    for _, p in pairs(spawner.spawnedProps or {}) do
        if p and p:IsValid() then lingeringProps = lingeringProps + 1 end
    end
    for _, p in pairs(spawner.spawnedPropsL or {}) do
        if p and p:IsValid() then lingeringProps = lingeringProps + 1 end
    end
    s:assert("spawner.destroyAll() clears all props",
        lingeringProps == 0,
        string.format("Lingering props: %d", lingeringProps))

    local lingeringWeapons = 0
    for _, w in pairs(spawner.spawnedWeapons or {}) do
        if w and w:IsValid() then lingeringWeapons = lingeringWeapons + 1 end
    end
    s:assert("spawner.destroyAll() clears all weapons",
        lingeringWeapons == 0,
        string.format("Lingering weapons: %d", lingeringWeapons))

    -- 6. TIK-014: Player Move QueryOnly & Overlap preservation
    local player = State.playerPawn
    if player and player:IsValid() then
        local cap = player.CapsuleComponent or player.RootComponent
        spawner.moveClone(player, "fwd", 1.0)
        s:assert("TIK-014: Player move prepared flag set", State.playerMovePrepared == true, "playerMovePrepared is false")
        s:assert("TIK-014: Actor collision preserved on player during move",
            player:GetActorEnableCollision() == true,
            "Actor collision was disabled")
        s:assert("TIK-014: Capsule switched to QueryOnly (1)",
            cap ~= nil and cap:IsValid() and cap:GetCollisionEnabled() == 1,
            cap and string.format("CollisionEnabled=%s", tostring(cap:GetCollisionEnabled())) or "CapsuleComponent unavailable")
    else
        s:assert("TIK-014: Player move prepared flag set", false, "playerPawn unavailable")
        s:assert("TIK-014: Actor collision preserved on player during move", false, "playerPawn unavailable")
        s:assert("TIK-014: Capsule switched to QueryOnly (1)", false, "playerPawn unavailable")
    end

    -- Exit PM
    photomode.exitPhotoMode()
    s.duration_ms = math.floor((os.clock() - (s._t0 or os.clock())) * 1000)
    return s
end

-- Scenario E: statelessness & memory leak audit (Rule 8 / TIK-008)
local function runScenarioE()
    local s = newScenario("E", "Statelessness & Memory Leak Audit (Rule 8 / TIK-008)")
    local t0 = os.clock()

    -- 1. Ensure PM is fully inactive
    if State.photoModeActive then
        photomode.exitPhotoMode()
    end
    s:assert("Rule 8: Photo Mode is completely inactive",
        not State.photoModeActive,
        "photoModeActive is true")

    -- 2. Force GC passes
    pcall(function() collectgarbage("collect") end)
    pcall(function() core.consoleCommand("obj gc") end)
    local pc = Subsystem.playerController()
    if pc and pc:IsValid() then
        pcall(function() pc:ClientForceGarbageCollection() end)
    end

    -- 3. Audit Clones Table
    local totalClones = #(State.spawnedClones or {}) + #(spawner.spawnedClones or {})
    s:assert("Rule 8: Zero lingering spawned clones in mod tables",
        totalClones == 0,
        string.format("Remaining clones: %d", totalClones))

    -- 4. Audit Props and Weapons
    local totalProps = 0
    for _, p in pairs(spawner.spawnedProps or {}) do
        if p and p:IsValid() then totalProps = totalProps + 1 end
    end
    for _, p in pairs(spawner.spawnedPropsL or {}) do
        if p and p:IsValid() then totalProps = totalProps + 1 end
    end
    s:assert("Rule 8: Zero lingering prop references",
        totalProps == 0,
        string.format("Lingering props: %d", totalProps))

    local totalWeapons = 0
    for _, w in pairs(spawner.spawnedWeapons or {}) do
        if w and w:IsValid() then totalWeapons = totalWeapons + 1 end
    end
    s:assert("Rule 8: Zero lingering weapon references",
        totalWeapons == 0,
        string.format("Lingering weapons: %d", totalWeapons))

    local proxyValid = spawner.playerWeaponProxy and spawner.playerWeaponProxy:IsValid()
    s:assert("Rule 8: Player weapon proxy is cleaned up",
        not proxyValid,
        proxyValid and "playerWeaponProxy is still valid!" or "Proxy clean")

    -- 5. Audit Hidden Widgets
    local lingeringHiddenWidgets = #(State.hiddenWidgets or {})
    s:assert("Rule 8: Zero lingering hidden game widgets",
        lingeringHiddenWidgets == 0,
        string.format("Hidden widgets: %d", lingeringHiddenWidgets))

    -- 6. Audit Async GC Flags (0x04000000 / EInternalObjectFlags.Async) on Pawn Comps
    local ASYNC_FLAG = (EInternalObjectFlags and EInternalObjectFlags.Async) or 0x04000000
    local asyncLeakedComps = 0
    local pawn = pc and (pc.Pawn or pc.Character)
    if pawn and pawn:IsValid() then
        local compCls = core.findStatic("/Script/Engine.ActorComponent")
        if compCls then
            local comps = pawn:K2_GetComponentsByClass(compCls)
            if comps then
                for _, comp in ipairs(comps) do
                    if comp and comp:IsValid() and comp.HasAnyInternalFlags then
                        local hasAsync = false
                        pcall(function() hasAsync = comp:HasAnyInternalFlags(ASYNC_FLAG) end)
                        if hasAsync then
                            asyncLeakedComps = asyncLeakedComps + 1
                        end
                    end
                end
            end
        end
    end
    s:assert("TIK-008 Audit: Zero player components tagged with Async GC flag (0x04000000)",
        asyncLeakedComps == 0,
        string.format("Async flag leaks detected: %d", asyncLeakedComps))

    -- 7. Audit Hijacked Components Table
    local lingeringHijacked = 0
    for clone, hijacked in pairs(spawner.hijackedComps or {}) do
        if hijacked and hijacked:IsValid() then
            lingeringHijacked = lingeringHijacked + 1
        end
    end
    s:assert("Rule 8: Zero lingering hijacked component registrations",
        lingeringHijacked == 0,
        string.format("Lingering hijacked comps: %d", lingeringHijacked))

    -- 8. TIK-014: Verify player capsule collision restored after PM exit
    local playerPawn = pc and (pc.Pawn or pc.Character)
    if playerPawn and playerPawn:IsValid() then
        local cap = playerPawn.CapsuleComponent or playerPawn.RootComponent
        if cap and cap:IsValid() then
            s:assert("TIK-014: Capsule collision restored after PM exit",
                cap:GetCollisionEnabled() ~= 1,
                string.format("Capsule CollisionEnabled=%s (expected normal physics/query)", tostring(cap:GetCollisionEnabled())))
        end
        s:assert("TIK-014: playerMovePrepared reset after exit",
            State.playerMovePrepared == false,
            "playerMovePrepared still true")
    end

    s.duration_ms = math.floor((os.clock() - t0) * 1000)
    return s
end

-- Master E2E Runner - staged across frames
--
-- One eval blocks the GameThread, so no delayed callback (auto-pause at
-- +600 ms, appearance pulses at +200..640 ms) can fire inside it. The suite
-- therefore runs as a chain of delayGameThread stages: synchronous steps
-- between frames, with the pause/clone asserts deferred past the delays.
-- The bridge runner starts it and polls getE2EStatus() for the report.

M._run = nil
M._lastReport = nil

local function finishRun()
    local run = M._run
    if not run then return end

    -- Fail-safe cleanup: Rule 8 enforcement
    pcall(function()
        if State.photoModeActive then
            photomode.exitPhotoMode()
        end
        if #spawner.spawnedClones > 0 then
            spawner.destroyAll()
        end
    end)

    local scenarios = run.scenarios
    local allPassed = true
    local totalAssertions = 0
    local passedAssertions = 0
    local failedAssertions = 0
    for _, s in ipairs(scenarios) do
        -- Strip private stage fields (UObject refs) before serialization
        for k in pairs(s) do
            if type(k) == "string" and k:sub(1, 1) == "_" then s[k] = nil end
        end
        if not s.passed then allPassed = false end
        for _, a in ipairs(s.assertions) do
            totalAssertions = totalAssertions + 1
            if a.passed then
                passedAssertions = passedAssertions + 1
            else
                failedAssertions = failedAssertions + 1
            end
        end
    end

    local totalDuration = math.floor((os.clock() - run.startedAt) * 1000)
    local summary = {
        total_scenarios = #scenarios,
        total_assertions = totalAssertions,
        passed_assertions = passedAssertions,
        failed_assertions = failedAssertions,
        duration_ms = totalDuration,
        status = allPassed and "PASS" or "FAIL"
    }

    logMsg("--------------------------------------------------")
    logMsg("E2E Summary: %d Scenarios | %d Assertions (%d Passed, %d Failed) | %d ms",
        #scenarios, totalAssertions, passedAssertions, failedAssertions, totalDuration)
    logMsg("Overall Result: %s", summary.status)
    logMsg("==================================================")

    local report = {
        status = summary.status,
        aborted = false,
        summary = summary,
        scenarios = scenarios
    }
    report.json = M.toJson(report)

    M._lastReport = report
    M._run = nil
end

local function addScenario(s)
    if M._run and s then table.insert(M._run.scenarios, s) end
end

-- Run one stage; on error record an ERR scenario and keep the chain alive
local function runStage(label, fn)
    local ok, err = xpcall(fn, function(e)
        return tostring(e) .. "\n" .. debug.traceback()
    end)
    if not ok and M._run then
        local fallback = newScenario("ERR", "Scenario " .. label .. " error")
        fallback.passed = false
        fallback:assert("Scenario completed without unhandled error", false, tostring(err))
        table.insert(M._run.scenarios, fallback)
    end
end

local function runChain(steps, idx)
    local st = steps[idx]
    if not st then finishRun() return end
    local function step()
        runStage(st.label, st.fn)
        runChain(steps, idx + 1)
    end
    local delay = st.delay or 0
    if not core.delayGameThread(delay, step) then
        step() -- last resort: run inline (delays unavailable)
    end
end

local function buildSteps()
    return {
        { label = "A", delay = 0,
          fn = function() addScenario(runScenarioA()) end },
        { label = "B-enter", delay = 0,
          fn = function() M._run.ctx.b = runScenarioB_enter() end },
        -- auto-pause fires 600 ms after entry; assert at +900 ms
        { label = "B-finish", delay = 900,
          fn = function() addScenario(runScenarioB_finish(M._run.ctx.b)) end },
        { label = "C-enter", delay = 0,
          fn = function() M._run.ctx.c = runScenarioC_enter() end },
        -- conduit DefaultFOV follows the slider (POV.FOV is stale under pause)
        { label = "C-assert", delay = 200,
          fn = function() runScenarioC_assert(M._run.ctx.c) end },
        -- conduit DefaultFOV back to default after osdReset
        { label = "C-finish", delay = 200,
          fn = function() addScenario(runScenarioC_finish(M._run.ctx.c)) end },
        { label = "D-spawn", delay = 0,
          fn = function()
              local s, clone = runScenarioD_spawn()
              M._run.ctx.d = s
              M._run.ctx.clone = clone
          end },
        -- appearance pulses finish ~640 ms after spawn; assert at +1500 ms
        { label = "D-finish", delay = 1500,
          fn = function() addScenario(runScenarioD_finish(M._run.ctx.d, M._run.ctx.clone)) end },
        { label = "E", delay = 0,
          fn = function() addScenario(runScenarioE()) end },
    }
end

local function abortReport(errorText)
    M._lastReport = {
        status = "ABORTED",
        aborted = true,
        error = errorText,
        summary = { total_scenarios = 0, total_assertions = 0, passed_assertions = 0,
                    failed_assertions = 0, status = "ABORTED", duration_ms = 0 },
        scenarios = {}
    }
    return { status = "ABORTED", report = M._lastReport }
end

-- Starts the staged suite; returns immediately. Poll getE2EStatus() for the report.
function M.startE2E()
    if M._run then return { status = "BUSY" } end

    logMsg("==================================================")
    logMsg(" TBOD_PhotoMode - In-Engine E2E & Integration Tests")
    logMsg("==================================================")

    local pc = Subsystem.playerController()
    if not (pc and pc:IsValid() and core.isRealPlayerController(pc)) then
        logMsg("E2E ABORTED: PlayerController not in gameplay state.")
        return abortReport("Active PlayerController not found or not in gameplay state (Main Menu / loading screen). Please load a game save first.")
    end

    local pawn = nil
    pcall(function() pawn = pc.Pawn or pc.Character end)
    if not (pawn and pawn:IsValid()) then
        logMsg("E2E ABORTED: Player pawn not found.")
        return abortReport("Active Player Pawn not found in world. Tests require an active player character.")
    end

    -- Normalize: a PM session left open (manual entry, previous run, crash)
    -- would contaminate every scenario - inherited OSD state, poses, clones.
    if State.photoModeActive then
        logMsg("E2E: PM already active - exiting first for a clean baseline")
        photomode.exitPhotoMode()
    end

    M._lastReport = nil
    M._run = { scenarios = {}, ctx = {}, startedAt = os.clock() }
    runChain(buildSteps(), 1)
    return { status = "STARTED" }
end

-- Polled by RunEngineTests.ps1 (one bridge eval per poll).
function M.getE2EStatus()
    if M._run then
        return { status = "RUNNING", scenarios_done = #M._run.scenarios }
    end
    if M._lastReport then
        return { status = "DONE", report = M._lastReport }
    end
    return { status = "IDLE" }
end

-- Async entry point: starts the suite, returns the STARTED/BUSY/ABORTED ack.
function M.runE2E()
    return M.startE2E()
end

return M
