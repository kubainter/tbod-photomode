-- test_config.lua
-- Unit tests for configuration loading and validation

local T = require("microtest")

local function run()
    local core = require("lib.core")
    
    T.describe("Configuration Defaults and INI Parser", function()
        T.it("should have all required default settings defined", function()
            T.assert_not_nil(core.Defaults.toggle_key, "toggle_key missing in Defaults")
            T.assert_not_nil(core.Defaults.pause_key, "pause_key missing in Defaults")
            T.assert_not_nil(core.Defaults.screenshot_key, "screenshot_key missing in Defaults")
            T.assert_not_nil(core.Defaults.osd_toggle_key, "osd_toggle_key missing in Defaults")
            T.assert_not_nil(core.Defaults.exit_guard_key, "exit_guard_key missing in Defaults")
            T.assert_not_nil(core.Defaults.fov_default, "fov_default missing in Defaults")
            T.assert_not_nil(core.Defaults.vertical_speed, "vertical_speed missing in Defaults")
        end)

        T.it("should maintain sane camera bounds in Defaults", function()
            T.assert_true(core.Defaults.fov_min >= 5.0, "fov_min too low")
            T.assert_true(core.Defaults.fov_max <= 180.0, "fov_max exceeds 180")
            T.assert_true(core.Defaults.fov_default >= core.Defaults.fov_min, "fov_default below min")
            T.assert_true(core.Defaults.fov_default <= core.Defaults.fov_max, "fov_default above max")
            T.assert_true(core.Defaults.camera_speed > 0, "camera_speed must be positive")
            T.assert_true(core.Defaults.vertical_speed > 0, "vertical_speed must be positive")
        end)

        T.it("should parse an actual photo_mode.ini cleanly", function()
            local iniPath = "TBOD_PhotoMode/Scripts/config/photo_mode.ini"
            local f = io.open(iniPath, "r")
            if not f then
                -- Try relative path if running from Tests/
                iniPath = "../TBOD_PhotoMode/Scripts/config/photo_mode.ini"
                f = io.open(iniPath, "r")
            end
            T.assert_not_nil(f, "Could not open photo_mode.ini for testing at path: " .. tostring(iniPath))
            f:close()

            local ok = core.loadConfig(iniPath)
            T.assert_true(ok, "loadConfig failed on photo_mode.ini")
            T.assert_equal("F8", core.Config.toggle_key, "toggle_key should be F8")
            T.assert_match("Gamepad_Special_Right", core.Config.exit_guard_key, "exit_guard_key should contain Gamepad_Special_Right")
            T.assert_match("Gamepad_FaceButton_Right", core.Config.screenshot_key, "screenshot_key should contain Gamepad_FaceButton_Right")
        end)
    end)
end

return { run = run }
