-- test_keybinds.lua
-- Unit tests for key resolution and gamepad controller mapping integrity

local T = require("microtest")

local function run()
    local core = require("lib.core")
    local keybinds = require("lib.keybinds")

    -- Helper resolver from gamepad.lua logic
    local function isActionKey(cfgValue, keyName)
        if not cfgValue or not keyName then return false end
        local target = keyName:upper():gsub("%s+", "")
        for part in tostring(cfgValue):gmatch("[^,]+") do
            if core.trim(part):upper():gsub("%s+", "") == target then return true end
        end
        return false
    end

    T.describe("Keybind Resolution & Controller Mapping Integrity", function()
        T.it("should match action keys case-insensitively with whitespace tolerance", function()
            local cfg = "  P,  Gamepad_FaceButton_Right , Gamepad_RightThumbstick "
            T.assert_true(isActionKey(cfg, "gamepad_facebutton_right"), "Failed lowercase match")
            T.assert_true(isActionKey(cfg, "GAMEPAD_FACEBUTTON_RIGHT"), "Failed uppercase match")
            T.assert_true(isActionKey(cfg, "Gamepad_FaceButton_Right"), "Failed mixed-case match")
            T.assert_true(isActionKey(cfg, "P"), "Failed single letter match")
            T.assert_true(isActionKey(cfg, "p"), "Failed lowercase single letter match")
            T.assert_false(isActionKey(cfg, "Gamepad_FaceButton_Left"), "False positive on FaceButton_Left")
            T.assert_false(isActionKey(cfg, "X"), "False positive on X")
        end)

        T.it("should enforce Gamepad_Special_Left is NEVER bound (Anti-Hub conflict rule)", function()
            local keysToCheck = {
                core.Config.toggle_key,
                core.Config.exit_guard_key,
                core.Config.pause_key,
                core.Config.hud_key,
                core.Config.screenshot_key,
                core.Config.fov_reset_key,
                core.Config.osd_reset_key,
                core.Config.osd_toggle_key,
                core.Config.move_up_key,
                core.Config.move_down_key,
            }
            for _, val in ipairs(keysToCheck) do
                T.assert_false(isActionKey(val, "Gamepad_Special_Left"), 
                    "FATAL CONFLICT: Gamepad_Special_Left was found bound in config! This triggers native GameHub & watchdog exit CTD.")
            end
        end)

        T.it("should enforce Circle (Gamepad_FaceButton_Right) is dedicated to Screenshot, NOT Exit", function()
            T.assert_false(isActionKey(core.Config.exit_guard_key, "Gamepad_FaceButton_Right"),
                "REGRESSION: Gamepad_FaceButton_Right must NOT be bound to exit_guard_key!")
            T.assert_true(isActionKey(core.Config.screenshot_key, "Gamepad_FaceButton_Right"),
                "Gamepad_FaceButton_Right must be bound to screenshot_key!")
        end)

        T.it("should enforce Menu/Options (Gamepad_Special_Right) is bound to Exit", function()
            T.assert_true(isActionKey(core.Config.exit_guard_key, "Gamepad_Special_Right"),
                "Gamepad_Special_Right must be present in exit_guard_key!")
        end)

        T.it("should enforce Square (Gamepad_FaceButton_Left) is bound to Clean View / OSD Toggle", function()
            T.assert_true(isActionKey(core.Config.osd_toggle_key, "Gamepad_FaceButton_Left"),
                "Gamepad_FaceButton_Left must be present in osd_toggle_key!")
        end)

        T.it("should parse comma-separated key lists into clean arrays", function()
            local list = keybinds.keyList("F8, Gamepad_Special_Right, Escape")
            T.assert_equal(3, #list, "Expected 3 keys in parsed list")
            T.assert_equal("F8", list[1])
            T.assert_equal("Gamepad_Special_Right", list[2])
            T.assert_equal("Escape", list[3])
        end)
    end)
end

return { run = run }
