-- TBOD_PhotoMode Gamepad Controller Module
-- Handles controller polling via APlayerController reflection (WasInputKeyJustPressed / IsInputKeyDown / GetInputAnalogKeyState).
-- Provides:
--   1. D-Pad navigation with auto-repeat for OSD (Up/Down/Left/Right)
--   2. Shoulder buttons for Tab switching (LB/RB)
--   3. Face buttons: A (Action/Pause), B (Back/Close OSD/Exit PM), X (Screenshot), Y (Reset OSD)
--   4. Triggers: LT (Move Down), RT (Move Up) with analog sensitivity
--   5. Special buttons: View/Select (Toggle OSD), Menu/Start (Exit PM)
--   6. Thumbstick clicks: L3 (Reset FOV), R3 (Toggle HUD)
--   7. L3 Triple-Tap (3x quick click): Enter Photo Mode from gameplay (immune to sprint conflicts)
--   8. L3 + R3 simultaneous chord: Redundant toggle path

local core = require("lib.core")
local State = core.State
local Config = core.Config
local Subsystem = core.Subsystem
local logMsg = core.logMsg
local dbg = core.dbg

local M = {}

local pollerRunning = false
local pollerStopping = false

local l3LatchedUntil = 0
local r3LatchedUntil = 0
local lastL3Log = 0
local lastR3Log = 0
local chordCooldownUntil = 0
local CHORD_WINDOW = 0.70 -- 700ms window to combine L3 + R3 presses into a chord in gameplay

local l3PressStartTime = 0
local lastL3ReleaseTime = 0
local l3WasDownPrev = false
local l3TapCount = 0
local L3_TAP_MAX_DURATION = 0.35 -- Max duration of a press to count as a tap (holding longer to sprint cancels tap sequence)
local L3_MULTI_TAP_WINDOW = 0.45 -- Max interval between tap release and subsequent press


local function recordL3Hit(source)
    local now = os.clock()
    if (now - lastL3Log) > 0.3 then
        lastL3Log = now
        dbg("Gamepad: L3 hit recorded (%s)", source or "poll")
    end
    local window = State.photoModeActive and 0.35 or CHORD_WINDOW
    l3LatchedUntil = now + window
end

local function recordR3Hit(source)
    local now = os.clock()
    if (now - lastR3Log) > 0.3 then
        lastR3Log = now
        dbg("Gamepad: R3 hit recorded (%s)", source or "poll")
    end
    local window = State.photoModeActive and 0.35 or CHORD_WINDOW
    r3LatchedUntil = now + window
end

local keyCache = {}
local lastPCAddress = nil
local kismet = nil

local function checkPCRefresh(pc)
    local addr = nil
    pcall(function() addr = pc:GetAddress() end)
    if addr and addr ~= lastPCAddress then
        lastPCAddress = addr
        -- Keep keyCache intact: FNames are engine-global and persist across PC refreshes.
    end
end

local namesLib = nil
local function getNamesLib()
    if not namesLib or not namesLib:IsValid() then
        namesLib = StaticFindObject("/Script/Engine.Default__KismetStringLibrary")
    end
    return namesLib
end

local function getKey(name)
    local k = keyCache[name]
    if not k then
        local fn = nil
        if type(FName) == "function" then
            pcall(function() fn = FName(name) end)
        end
        if not fn then
            local lib = getNamesLib()
            if lib and lib:IsValid() then
                pcall(function() fn = lib:Conv_StringToName(name) end)
            end
        end
        k = { KeyName = fn or name }
        keyCache[name] = k
    end
    return k
end

local function isKeyDown(pc, keyName)
    if not (pc and pc:IsValid() and pc.PlayerInput and pc.PlayerInput:IsValid()) then return false end
    local k = getKey(keyName)
    local down = false
    pcall(function()
        down = pc:IsInputKeyDown(k)
    end)
    return down == true
end

local function wasKeyJustPressed(pc, keyName)
    if not (pc and pc:IsValid() and pc.PlayerInput and pc.PlayerInput:IsValid()) then return false end
    local k = getKey(keyName)
    local pressed = false
    pcall(function()
        pressed = pc:WasInputKeyJustPressed(k)
    end)
    return pressed == true
end

local function getAnalog(pc, axisName)
    if not (pc and pc:IsValid() and pc.PlayerInput and pc.PlayerInput:IsValid()) then return 0.0 end
    local k = getKey(axisName)
    local val = 0.0
    pcall(function()
        val = pc:GetInputAnalogKeyState(k)
    end)
    return (type(val) == "number") and val or 0.0
end

-- Key repeat settings (in seconds)
local REPEAT_DELAY = 0.35
local REPEAT_INTERVAL = 0.10

local REPEATABLE_KEYS = {
    Gamepad_DPad_Up = true,
    Gamepad_DPad_Down = true,
    Gamepad_DPad_Left = true,
    Gamepad_DPad_Right = true,
}

local buttonState = {} -- [keyName] = { isDown = bool, nextRepeat = number }

local function isActionKey(cfgValue, keyName)
    if not cfgValue or not keyName then return false end
    local target = keyName:upper():gsub("%s+", "")
    for part in tostring(cfgValue):gmatch("[^,]+") do
        local k = core.trim(part):upper():gsub("%s+", "")
        if k == target then return true end
    end
    return false
end

function M.handleButtonPress(keyName, isRepeat)
    State.lastInputDevice = "gamepad"
    local osd = require("lib.osd")
    local photomode = require("lib.photomode")
    local camera = require("lib.camera")
    local screenshot = require("lib.screenshot")

    -- Navigation (D-Pad)
    if keyName == "Gamepad_DPad_Up" then
        dbg("Gamepad: D-Pad Up -> OSD Select Up (repeat=%s)", tostring(isRepeat))
        pcall(function()
            if not State.osdVisible then osd.showOSD() else osd.osdSelect(-1) end
        end)
    elseif keyName == "Gamepad_DPad_Down" then
        dbg("Gamepad: D-Pad Down -> OSD Select Down (repeat=%s)", tostring(isRepeat))
        pcall(function()
            if not State.osdVisible then osd.showOSD() else osd.osdSelect(1) end
        end)
    elseif keyName == "Gamepad_DPad_Left" then
        dbg("Gamepad: D-Pad Left -> OSD Adjust Left (repeat=%s)", tostring(isRepeat))
        pcall(function()
            if not State.osdVisible then osd.showOSD() else osd.osdAdjust(-1) end
        end)
    elseif keyName == "Gamepad_DPad_Right" then
        dbg("Gamepad: D-Pad Right -> OSD Adjust Right (repeat=%s)", tostring(isRepeat))
        pcall(function()
            if not State.osdVisible then osd.showOSD() else osd.osdAdjust(1) end
        end)

    -- Tab switching (LB / RB) or configured tab keys
    elseif (keyName == "Gamepad_LeftShoulder" or isActionKey(Config.osd_tab_prev_key, keyName)) and not isRepeat then
        pcall(function() osd.osdTab(-1) end)
    elseif (keyName == "Gamepad_RightShoulder" or isActionKey(Config.osd_tab_next_key, keyName)) and not isRepeat then
        pcall(function() osd.osdTab(1) end)

    -- Face Button Bottom (A / Cross): Confirm / Action / Toggle Pause
    elseif (keyName == "Gamepad_FaceButton_Bottom" or isActionKey(Config.pause_key, keyName)) and not isRepeat then
        pcall(function()
            local rowDef = osd.OSD_ROWS and osd.OSD_SELECTED and osd.OSD_ROWS[osd.OSD_SELECTED] or nil
            local label = rowDef and rowDef.label or ""
            if label == "HUD" then
                photomode.toggleHUD()
            elseif label == "Player" then
                photomode.togglePlayerVisibility()
            elseif label == "Auto-Focus" then
                require("lib.optics").toggleAutoFocus()
            elseif label == "Slow Motion" or label == "Frame Step" then
                photomode.togglePause()
            elseif label == "Spawn NPC" or label == "Face Cam" then
                osd.osdAdjust(1)
            else
                photomode.togglePause()
            end
        end)

    -- Menu / Start (Special Right): Exit Photo Mode
    elseif (keyName == "Gamepad_Special_Right" or isActionKey(Config.exit_guard_key, keyName)) and not isRepeat then
        pcall(photomode.exitPhotoMode)

    -- Face Button Left (Square / X): Clean View (Toggle OSD + HUD)
    elseif (keyName == "Gamepad_FaceButton_Left" or keyName == "Gamepad_X" or isActionKey(Config.osd_toggle_key, keyName)) and not isRepeat then
        pcall(function() osd.toggleCleanView() end)

    -- Face Button Right (B / Circle) or Right Thumbstick (R3): Screenshot
    elseif (keyName == "Gamepad_FaceButton_Right" or keyName == "Gamepad_B" or keyName == "Gamepad_RightThumbstick" or keyName == "Gamepad_RightStick" or keyName == "Gamepad_R3" or keyName == "Gamepad_RightThumbstickButton" or isActionKey(Config.screenshot_key, keyName)) and not isRepeat then
        pcall(screenshot.takeScreenshot)

    -- Face Button Top (Y / Triangle): Reset Settings
    elseif (keyName == "Gamepad_FaceButton_Top" or isActionKey(Config.osd_reset_key, keyName)) and not isRepeat then
        pcall(osd.osdReset)

    -- Left Thumbstick (L3): Reset FOV
    elseif (keyName == "Gamepad_LeftThumbstick" or isActionKey(Config.fov_reset_key, keyName)) and not isRepeat then
        pcall(camera.resetFOV)
    end
end

function M.poll()
    local pc = Subsystem.playerController()
    -- Only require a real PC (PlayerCameraManager + PlayerInput present).
    -- Do NOT require pc.Pawn here — chord detection must work even when the
    -- pawn is absent (before/after PM transition), and D-pad navigation does
    -- not need a pawn at all. Pawn is only needed for camera flight (below).
    if not (pc and core.isRealPlayerController(pc)) then return end

    checkPCRefresh(pc)
    local now = os.clock()

    -- 1. Check L3 + R3 candidate keys
    local L3_CANDIDATES = { "Gamepad_LeftThumbstick", "Gamepad_LeftStick", "Gamepad_L3" }
    local R3_CANDIDATES = { "Gamepad_RightThumbstick", "Gamepad_RightStick", "Gamepad_R3", "Gamepad_RightThumbstickButton" }

    local l3RawDown = false
    for _, cand in ipairs(L3_CANDIDATES) do
        if isKeyDown(pc, cand) or wasKeyJustPressed(pc, cand) then
            l3RawDown = true
            recordL3Hit("key:" .. cand)
            break
        end
    end

    for _, cand in ipairs(R3_CANDIDATES) do
        if isKeyDown(pc, cand) or wasKeyJustPressed(pc, cand) then
            recordR3Hit("key:" .. cand)
            break
        end
    end

    -- 2. Detect L3 Triple-Tap in normal gameplay (immune to sprint hold / single taps)
    if not State.photoModeActive then
        -- Press edge detection
        if l3RawDown and not l3WasDownPrev then
            l3WasDownPrev = true
            l3PressStartTime = now

            local timeSinceRelease = now - lastL3ReleaseTime
            if lastL3ReleaseTime > 0 and timeSinceRelease > 0.03 and timeSinceRelease <= L3_MULTI_TAP_WINDOW then
                l3TapCount = l3TapCount + 1
            else
                l3TapCount = 1
            end

            if l3TapCount >= 3 then
                if now > chordCooldownUntil then
                    chordCooldownUntil = now + 1.2
                    l3TapCount = 0
                    l3PressStartTime = 0
                    lastL3ReleaseTime = 0
                    l3LatchedUntil = 0
                    r3LatchedUntil = 0
                    logMsg("Gamepad: L3 Triple-Tap triggered! -> Entering Photo Mode")
                    State.lastInputDevice = "gamepad"
                    core.dispatch(require("lib.photomode").enterPhotoMode)
                    return
                end
            end
        elseif not l3RawDown and l3WasDownPrev then
            -- Release edge detection
            l3WasDownPrev = false
            local pressDuration = now - l3PressStartTime
            l3PressStartTime = 0

            -- If player held L3 longer than L3_TAP_MAX_DURATION (e.g. sprinting), reset tap sequence
            if pressDuration > L3_TAP_MAX_DURATION then
                l3TapCount = 0
                lastL3ReleaseTime = 0
            else
                lastL3ReleaseTime = now
            end
        end
    else
        l3WasDownPrev = l3RawDown
        l3PressStartTime = 0
        l3TapCount = 0
        lastL3ReleaseTime = 0
    end

    -- 3. Check simultaneous / latched L3 + R3 chord
    if now > chordCooldownUntil then
        local chordFired = (now < l3LatchedUntil and now < r3LatchedUntil)

        -- Also allow toggle via any configured gamepad key in toggle_key (e.g. Gamepad_Special_Right)
        local padToggleHit = false
        local toggleKeyStr = tostring(Config.toggle_key or "")
        for part in toggleKeyStr:gmatch("[^,]+") do
            local k = core.trim(part)
            if k:find("^Gamepad_") then
                if wasKeyJustPressed(pc, k) or isKeyDown(pc, k) then
                    padToggleHit = true
                    logMsg("Gamepad: configured toggle key '%s' pressed", k)
                    break
                end
            end
        end

        if chordFired or padToggleHit then
            chordCooldownUntil = now + 1.2 -- 1.2s cooldown prevents bounce
            l3LatchedUntil = 0
            r3LatchedUntil = 0
            logMsg("Gamepad: Photo Mode toggle triggered! (chord=%s, toggleKey=%s)", tostring(chordFired), tostring(padToggleHit))
            local photomode = require("lib.photomode")
            if State.photoModeActive then
                core.dispatch(photomode.exitPhotoMode)
            else
                core.dispatch(photomode.enterPhotoMode)
            end
            return -- Suppress individual button processing when chord fires
        end
    end

    -- If Photo Mode is NOT active, do not process Photo Mode navigation/actions
    if not State.photoModeActive then
        buttonState = {}
        return
    end

    -- 2. Process camera flight & look via Analog Sticks & Triggers
    -- Camera flight requires a valid pawn to be present.
    local hasPawn = pc.Pawn and pc.Pawn:IsValid()
    if State.pmMode ~= "cutscene" and hasPawn then
        local camera = require("lib.camera")

        -- 2a. Triggers: Vertical camera movement (LT = Down, RT = Up)
        local lt = getAnalog(pc, "Gamepad_LeftTriggerAxis")
        local rt = getAnalog(pc, "Gamepad_RightTriggerAxis")
        if lt <= 0.1 and isKeyDown(pc, "Gamepad_LeftTrigger") then
            lt = 1.0
        end
        if rt <= 0.1 and isKeyDown(pc, "Gamepad_RightTrigger") then
            rt = 1.0
        end

        local vertSpeed = Config.vertical_speed or 10.0
        if lt > 0.15 then
            camera.movePhotoCameraVertical(-vertSpeed * (lt * 0.5))
        end
        if rt > 0.15 then
            camera.movePhotoCameraVertical(vertSpeed * (rt * 0.5))
        end

        -- 2b. Left Stick: Horizontal flight (Forward/Backward, Strafe Left/Right)
        local DEADZONE = 0.15
        local l3Down = isKeyDown(pc, "Gamepad_LeftThumbstick")
        local lx = getAnalog(pc, "Gamepad_LeftX")
        local ly = getAnalog(pc, "Gamepad_LeftY")
        if not l3Down and (math.abs(lx) > DEADZONE or math.abs(ly) > DEADZONE) then
            local flightSpeed = (Config.camera_speed or 4.0) * 3.5
            local fwd = (math.abs(ly) > DEADZONE) and ly or 0.0
            local right = (math.abs(lx) > DEADZONE) and lx or 0.0
            camera.movePhotoCameraFlight(fwd, right, flightSpeed)
        end

        -- 2c. Right Stick: Camera Look (Pitch & Yaw)
        local rx = getAnalog(pc, "Gamepad_RightX")
        local ry = getAnalog(pc, "Gamepad_RightY")
        if math.abs(rx) > DEADZONE or math.abs(ry) > DEADZONE then
            local lookSens = 1.8
            local deltaYaw = (math.abs(rx) > DEADZONE) and (rx * lookSens) or 0.0
            local deltaPitch = (math.abs(ry) > DEADZONE) and (ry * lookSens) or 0.0
            camera.rotatePhotoCamera(deltaPitch, deltaYaw)
        end
    end

    -- 3. Poll discrete buttons
    local POLL_BUTTONS = {
        "Gamepad_DPad_Up",
        "Gamepad_DPad_Down",
        "Gamepad_DPad_Left",
        "Gamepad_DPad_Right",
        "Gamepad_FaceButton_Bottom",
        "Gamepad_FaceButton_Right",
        "Gamepad_FaceButton_Left",
        "Gamepad_FaceButton_Top",
        "Gamepad_LeftShoulder",
        "Gamepad_RightShoulder",
        "Gamepad_LeftThumbstick",
        "Gamepad_RightThumbstick",
        "Gamepad_RightStick",
        "Gamepad_R3",
        "Gamepad_RightThumbstickButton",
        "Gamepad_Special_Right",
    }

    for _, keyName in ipairs(POLL_BUTTONS) do
        local isDown = isKeyDown(pc, keyName) or wasKeyJustPressed(pc, keyName)
        local st = buttonState[keyName]
        if isDown then
            if not st then
                -- Initial press
                buttonState[keyName] = { isDown = true, nextRepeat = now + REPEAT_DELAY }
                M.handleButtonPress(keyName, false)
            elseif REPEATABLE_KEYS[keyName] and now >= st.nextRepeat then
                -- Repeat
                st.nextRepeat = now + REPEAT_INTERVAL
                M.handleButtonPress(keyName, true)
            end
        else
            buttonState[keyName] = nil
        end
    end
end

local function pollTick()
    if pollerStopping or not pollerRunning then
        pollerRunning = false
        buttonState = {}
        logMsg("Gamepad poller stopped.")
        return
    end

    local ok, err = pcall(M.poll)
    if not ok and not M._lastErrorLogged then
        M._lastErrorLogged = true
        logMsg("Gamepad poll error: %s", tostring(err))
    end

    if pollerRunning and not pollerStopping then
        core.delayGameThread(25, pollTick)
    end
end

function M.startPoller()
    if pollerRunning then return end
    -- Poller runs always (not just in PM) so the L3+R3 enter-PM chord works.
    pollerRunning = true
    pollerStopping = false
    M._lastErrorLogged = false
    buttonState = {}
    logMsg("Gamepad poller starting (25ms game-thread timer)...")
    core.delayGameThread(25, pollTick)
end

function M.stopPoller()
    pollerStopping = true
    pollerRunning = false
    buttonState = {}
end

return M
