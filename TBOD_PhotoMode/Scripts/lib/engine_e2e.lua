-- lib/engine_e2e.lua
-- In-Engine Automated E2E & Integration Test Suite for TBOD_PhotoMode
-- Operates on the game thread via ue4ss-bridge / eval_lua (UE 5.5.4 Shipping, UE4SS v3.x)
-- Enforces Rule 8 (PM Statelessness) & TIK-008 Memory Leak Audit.

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

----------------------------------------------------------------------------
-- Self-contained JSON Serializer (for structured bridge transport)
----------------------------------------------------------------------------

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

----------------------------------------------------------------------------
-- Test Scenario Factory
----------------------------------------------------------------------------

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

----------------------------------------------------------------------------
-- Scenario Implementations
----------------------------------------------------------------------------

-- Scenariusz A: Subsystems & Reflection Liveness
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

-- Scenariusz B: Pełny cykl życia Photo Mode
local function runScenarioB()
    local s = newScenario("B", "Full Photo Mode Lifecycle")
    local t0 = os.clock()

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

    -- 4. World Pause Assertion
    local isPaused = (State.paused == true)
    local gs = Subsystem.gameplayStatics()
    if not isPaused and gs and pc then
        pcall(function() isPaused = gs:IsGamePaused(pc) end)
    end
    s:assert("World paused upon Photo Mode entry (pause_on_enter)",
        isPaused or (Config.pause_on_enter == false),
        "Game not paused after entry")

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

    s.duration_ms = math.floor((os.clock() - t0) * 1000)
    return s
end

-- Scenariusz C: Nawigacja OSD i modyfikacja parametrów
local function runScenarioC()
    local s = newScenario("C", "OSD Navigation & Parameter Modulation")
    local t0 = os.clock()

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
    local baselineFOV = State.fov or Config.fov_default
    osd.osdAdjust(1)
    local modifiedFOV = State.fov or baselineFOV
    s:assert("osdAdjust(1) modifies FOV",
        math.abs(modifiedFOV - baselineFOV) > 0.001,
        string.format("FOV changed from %.1f to %.1f", baselineFOV, modifiedFOV))

    -- TIK-013 Camera Speed Guard Check:
    local photoCam = Subsystem.photoCamera()
    if photoCam and photoCam:IsValid() then
        local mc = photoCam.MovementComponent
        if mc and mc:IsValid() and State.origMaxSpeed then
            s:assert("TIK-013: Camera MaxSpeed clamped to origMaxSpeed during FOV adjustment",
                math.abs(mc.MaxSpeed - State.origMaxSpeed) < 0.1,
                string.format("mc.MaxSpeed=%.1f, origMaxSpeed=%.1f", mc.MaxSpeed, State.origMaxSpeed))
        end
    end

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
    local todRow = nil
    for idx, r in ipairs(osd.OSD_ROWS) do
        if r.label == "Time of Day" then todRow = idx break end
    end
    if todRow then
        osd.currentTab = 2 -- ENVIRONMENT tab
        osd.OSD_SELECTED = todRow
        local baselineTOD = State.timeOfDay or 12.0
        osd.osdAdjust(1)
        local modifiedTOD = State.timeOfDay or baselineTOD
        s:assert("osdAdjust(1) modifies Time of Day",
            math.abs(modifiedTOD - baselineTOD) > 0.001,
            string.format("TimeOfDay changed from %.2f to %.2f", baselineTOD, modifiedTOD))
    else
        s:assert("Time of Day row discovered in OSD_ROWS", false, "Time of Day row missing")
    end

    -- 6. OSD Reset
    osd.osdReset()
    s:assert("osdReset() restores FOV to default",
        math.abs((State.fov or 0) - Config.fov_default) < 0.01,
        string.format("FOV restored to %.1f (expected %.1f)", State.fov or 0, Config.fov_default))
    s:assert("osdReset() restores Exposure to 0.0",
        math.abs(State.exposureBias or 0) < 0.01,
        string.format("Exposure restored to %.2f (expected 0.0)", State.exposureBias or 0))

    -- Exit PM
    photomode.exitPhotoMode()
    s.duration_ms = math.floor((os.clock() - t0) * 1000)
    return s
end

-- Scenariusz D: Reżyseria i Spawner
local function runScenarioD()
    local s = newScenario("D", "Directing & Spawner Integrity")
    local t0 = os.clock()

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

    -- 3. Equip Weapon on Clone
    if clone and clone:IsValid() then
        spawner.equipCloneWeapon(clone)
        local hasWeapon = false
        if spawner.spawnedWeapons and spawner.spawnedWeapons[1] ~= nil then
            hasWeapon = true
        elseif spawner.hijackedComps and spawner.hijackedComps[clone] ~= nil then
            hasWeapon = true
        elseif spawner.knownWeapons and next(spawner.knownWeapons) ~= nil then
            hasWeapon = true
        end
        s:assert("Weapon equipped or hijacked on spawned clone",
            hasWeapon,
            "Clone weapon entry verified")

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
        pcall(function() attachParent = prop:GetAttachParent() end)
        s:assert("Prop is physically attached to character socket/component",
            attachParent ~= nil and attachParent:IsValid(),
            attachParent and ("Attach parent: " .. tostring(attachParent:GetFName():ToString())) or "Prop unattached")
    else
        s:assert("Weapon and prop applied to clone", false, "Clone was invalid")
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
        if cap and cap:IsValid() then
            s:assert("TIK-014: Capsule switched to QueryOnly (1)",
                cap:GetCollisionEnabled() == 1,
                string.format("CollisionEnabled=%s", tostring(cap:GetCollisionEnabled())))
        end
    end

    -- Exit PM
    photomode.exitPhotoMode()
    s.duration_ms = math.floor((os.clock() - t0) * 1000)
    return s
end

-- Scenariusz E: Audyt bezstanowości i wycieków pamięci (Rule 8 / TIK-008 Audit)
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

----------------------------------------------------------------------------
-- Master E2E Runner Entry Point
----------------------------------------------------------------------------

function M.runE2E()
    local overallStart = os.clock()
    logMsg("==================================================")
    logMsg(" TBOD_PhotoMode - In-Engine E2E & Integration Tests")
    logMsg("==================================================")

    -- Guard 1: Verify not in Main Menu / active PlayerController check
    local pc = Subsystem.playerController()
    if not (pc and pc:IsValid() and core.isRealPlayerController(pc)) then
        local abortReport = {
            status = "ABORTED",
            aborted = true,
            error = "Active PlayerController not found or not in gameplay state (Main Menu / loading screen). Please load a game save first.",
            summary = { total = 0, passed = 0, failed = 0, status = "ABORTED", duration_ms = 0 },
            scenarios = {}
        }
        logMsg("E2E ABORTED: PlayerController not in gameplay state.")
        return abortReport
    end

    -- Guard 2: Verify active player pawn exists
    local pawn = nil
    pcall(function() pawn = pc.Pawn or pc.Character end)
    if not (pawn and pawn:IsValid()) then
        local abortReport = {
            status = "ABORTED",
            aborted = true,
            error = "Active Player Pawn not found in world. Tests require an active player character.",
            summary = { total = 0, passed = 0, failed = 0, status = "ABORTED", duration_ms = 0 },
            scenarios = {}
        }
        logMsg("E2E ABORTED: Player pawn not found.")
        return abortReport
    end

    local scenarios = {}
    local scenarioRunners = {
        runScenarioA,
        runScenarioB,
        runScenarioC,
        runScenarioD,
        runScenarioE
    }

    local allPassed = true
    local totalAssertions = 0
    local passedAssertions = 0
    local failedAssertions = 0

    for _, runner in ipairs(scenarioRunners) do
        local ok, s = xpcall(runner, function(err)
            return tostring(err) .. "\n" .. debug.traceback()
        end)

        if not ok then
            allPassed = false
            local fallback = newScenario("ERR", "Scenario execution error")
            fallback.passed = false
            fallback.error = tostring(s)
            fallback:assert("Scenario completed without unhandled error", false, tostring(s))
            table.insert(scenarios, fallback)
            failedAssertions = failedAssertions + 1
            totalAssertions = totalAssertions + 1
        else
            table.insert(scenarios, s)
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
    end

    -- Fail-safe cleanup: Rule 8 enforcement
    pcall(function()
        if State.photoModeActive then
            photomode.exitPhotoMode()
        end
        if #spawner.spawnedClones > 0 then
            spawner.destroyAll()
        end
    end)

    local totalDuration = math.floor((os.clock() - overallStart) * 1000)

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
    return report
end

function M.runE2EJson()
    local report = M.runE2E()
    return M.toJson(report)
end

return M
