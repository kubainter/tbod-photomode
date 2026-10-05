-- run_all.lua
-- Master test runner for TBOD_PhotoMode offline unit test suite

-- Adjust package.path to discover mod source modules and test files
package.path = package.path .. ";./?.lua;./Tests/?.lua;../Tests/?.lua"
package.path = package.path .. ";./TBOD_PhotoMode/Scripts/?.lua;../TBOD_PhotoMode/Scripts/?.lua"
package.path = package.path .. ";./TBOD_PhotoMode/Scripts/lib/?.lua;../TBOD_PhotoMode/Scripts/lib/?.lua"

-- Install mock environment
local mock = require("mock_ue4ss")
mock.install()

local T = require("microtest")

print("==================================================")
print(" TBOD_PhotoMode - Automated Unit Test Suite")
print("==================================================")

-- Run individual suites
require("test_config").run()
require("test_keybinds").run()
require("test_gestures").run()
require("test_osd_state").run()
require("test_engine_e2e").run()

-- Print final summary
local success = T.summary()

if os and os.exit then
    os.exit(success and 0 or 1)
end
