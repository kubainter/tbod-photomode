-- microtest.lua
-- Minimal, zero-dependency unit testing micro-framework for Lua
-- Works identically in standalone Lua CLI and embedded inside UE4SS.

local M = {}

M.totalTests = 0
M.passed = 0
M.failed = 0
M.currentSuite = ""
M.failures = {}

local function colorize(text, colorCode)
    return string.format("\27[%sm%s\27[0m", colorCode, text)
end

function M.describe(suiteName, fn)
    M.currentSuite = suiteName
    print(string.format("\n=== %s ===", suiteName))
    local ok, err = pcall(fn)
    if not ok then
        M.failed = M.failed + 1
        local failMsg = string.format("[SUITE ERROR] %s: %s", suiteName, tostring(err))
        table.insert(M.failures, failMsg)
        print(colorize(failMsg, "31"))
    end
end

function M.it(testName, fn)
    M.totalTests = M.totalTests + 1
    local ok, err = pcall(fn)
    if ok then
        M.passed = M.passed + 1
        print(string.format("  %s %s", colorize("[PASS]", "32"), testName))
    else
        M.failed = M.failed + 1
        local failMsg = string.format("%s -> %s: %s", M.currentSuite, testName, tostring(err))
        table.insert(M.failures, failMsg)
        print(string.format("  %s %s", colorize("[FAIL]", "31"), testName))
        print(string.format("    %s", colorize(tostring(err), "33")))
    end
end

-- Assertions
function M.assert_true(cond, msg)
    if not cond then
        error(msg or "Expected true, got " .. tostring(cond), 2)
    end
end

function M.assert_false(cond, msg)
    if cond then
        error(msg or "Expected false, got " .. tostring(cond), 2)
    end
end

function M.assert_equal(expected, actual, msg)
    if expected ~= actual then
        error(string.format("%s (expected '%s', got '%s')", msg or "Assertion failed", tostring(expected), tostring(actual)), 2)
    end
end

function M.assert_not_equal(expected, actual, msg)
    if expected == actual then
        error(string.format("%s (expected not equal to '%s')", msg or "Assertion failed", tostring(actual)), 2)
    end
end

function M.assert_nil(val, msg)
    if val ~= nil then
        error(msg or "Expected nil, got " .. tostring(val), 2)
    end
end

function M.assert_not_nil(val, msg)
    if val == nil then
        error(msg or "Expected non-nil value", 2)
    end
end

function M.assert_almost_equal(expected, actual, tolerance, msg)
    tolerance = tolerance or 0.0001
    if math.abs(expected - actual) > tolerance then
        error(string.format("%s (expected %f, got %f, diff=%f > tol=%f)", msg or "Math assertion failed", expected, actual, math.abs(expected - actual), tolerance), 2)
    end
end

function M.assert_match(pattern, str, msg)
    if not str or not tostring(str):match(pattern) then
        error(string.format("%s (string '%s' did not match pattern '%s')", msg or "Pattern match failed", tostring(str), pattern), 2)
    end
end

function M.summary()
    print("\n--------------------------------------------------")
    print(string.format("Test Summary: %d Total | %d Passed | %d Failed", M.totalTests, M.passed, M.failed))
    if M.failed > 0 then
        print(colorize(string.format("\nFAILED TESTS (%d):", M.failed), "31"))
        for i, f in ipairs(M.failures) do
            print(string.format("  %d) %s", i, f))
        end
        print("--------------------------------------------------\n")
        return false
    else
        print(colorize("\nALL TESTS PASSED SUCCESSFULLY! \27[1m\27[32m[OK]\27[0m", "32"))
        print("--------------------------------------------------\n")
        return true
    end
end

return M
