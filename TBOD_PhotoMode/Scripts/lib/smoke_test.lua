-- lib/smoke_test.lua
-- In-Engine Runtime Smoke Test Suite for TBOD_PhotoMode
-- Validates live Unreal Engine 5.5 reflection, Subsystems, EventBridge, and Statelessness.

local core = require("lib.core")
local State = core.State
local Subsystem = core.Subsystem
local logMsg = core.logMsg

local M = {}

local function testLog(fmt, ...)
    local msg = string.format(fmt, ...)
    print("[TBOD_PM_TEST] " .. msg .. "\n")
end

function M.runSmokeTests()
    testLog("==================================================")
    testLog(" TBOD_PhotoMode - In-Engine Smoke Test Suite")
    testLog("==================================================")

    local total = 0
    local passed = 0
    local failed = 0

    local function assertTest(name, cond, details)
        total = total + 1
        if cond then
            passed = passed + 1
            testLog("  [PASS] %s", name)
        else
            failed = failed + 1
            testLog("  [FAIL] %s - %s", name, details or "Assertion failed")
        end
    end

    -- 1. PlayerController & Subsystems
    local pc = Subsystem.playerController()
    assertTest("PlayerController is valid and has PlayerInput",
        pc and pc:IsValid() and pc.PlayerInput and pc.PlayerInput:IsValid(),
        "PlayerController or PlayerInput is invalid or missing")

    local pmSub = Subsystem.photoMode()
    assertTest("DogwoodPhotomodeSubsystem is present",
        pmSub and pmSub:IsValid(),
        "DogwoodPhotomodeSubsystem instance not found")

    -- 2. Static Libraries Reflection
    local gs = Subsystem.gameplayStatics()
    assertTest("Default__GameplayStatics reflection is valid",
        gs and gs:IsValid(),
        "GameplayStatics static object not found")

    local wbl = core.findStatic("/Script/UMG.Default__WidgetBlueprintLibrary")
    assertTest("WidgetBlueprintLibrary reflection is valid",
        wbl and wbl:IsValid(),
        "WidgetBlueprintLibrary static object not found")

    -- 3. Photo Camera Actor Class Check
    local photoCam = Subsystem.photoCamera()
    assertTest("PhotoCameraActor discovery",
        photoCam ~= nil,
        "PhotoCameraActor could not be located via Subsystem or world scan")

    -- 4. EventBridge Check
    local eb = require("lib.eventbridge")
    local ebAvail, ebWhy = eb.isAvailable()
    assertTest("UE4SSLuaEventBridge availability",
        ebAvail,
        tostring(ebWhy))

    if ebAvail then
        local ebVer = eb.getVersion()
        assertTest("UE4SSLuaEventBridge version >= 1.0.7",
            ebVer and ebVer >= "1.0.7",
            "EventBridge version is " .. tostring(ebVer))
    end

    -- 5. Controller Mapping Rules Integrity
    local isSpecialLeftBound = false
    local cfg = core.Config
    local keysToCheck = {
        cfg.toggle_key, cfg.exit_guard_key, cfg.pause_key, cfg.hud_key,
        cfg.screenshot_key, cfg.fov_reset_key, cfg.osd_reset_key, cfg.osd_toggle_key
    }
    for _, v in ipairs(keysToCheck) do
        if tostring(v):upper():find("GAMEPAD_SPECIAL_LEFT") then
            isSpecialLeftBound = true
            break
        end
    end
    assertTest("Anti-GameHub Rule: Gamepad_Special_Left is completely unbound",
        not isSpecialLeftBound,
        "Gamepad_Special_Left is bound, which will cause GameHub conflict!")

    local isFaceButtonRightExit = tostring(cfg.exit_guard_key or ""):upper():find("GAMEPAD_FACEBUTTON_RIGHT") ~= nil
    assertTest("Circle (Gamepad_FaceButton_Right) freed from Exit Guard",
        not isFaceButtonRightExit,
        "Gamepad_FaceButton_Right is still bound to exit_guard_key!")

    local isFaceButtonRightScreenshot = tostring(cfg.screenshot_key or ""):upper():find("GAMEPAD_FACEBUTTON_RIGHT") ~= nil
    assertTest("Circle (Gamepad_FaceButton_Right) mapped to Screenshot",
        isFaceButtonRightScreenshot,
        "Gamepad_FaceButton_Right is missing from screenshot_key!")

    local isSpecialRightExit = tostring(cfg.exit_guard_key or ""):upper():find("GAMEPAD_SPECIAL_RIGHT") ~= nil
    assertTest("Menu/Start (Gamepad_Special_Right) mapped to Exit Guard",
        isSpecialRightExit,
        "Gamepad_Special_Right is missing from exit_guard_key!")

    -- 6. Statelessness Initial Check
    assertTest("Mod Statelessness: no dangling clones on idle",
        #State.spawnedClones == 0,
        string.format("Found %d lingering spawned clones!", #State.spawnedClones))

    assertTest("Mod Statelessness: no lingering hidden widgets on idle",
        #State.hiddenWidgets == 0,
        string.format("Found %d lingering hidden widget entries!", #State.hiddenWidgets))

    testLog("--------------------------------------------------")
    testLog("Smoke Test Summary: %d Total | %d Passed | %d Failed", total, passed, failed)
    if failed == 0 then
        testLog("ALL IN-ENGINE SMOKE TESTS PASSED [OK]")
    else
        testLog("WARNING: %d SMOKE TESTS FAILED", failed)
    end
    testLog("==================================================")

    return failed == 0
end

return M
