-- test_engine_e2e.lua
-- Unit tests for engine_e2e module: JSON serialization, safety guards, and contract integrity

local T = require("microtest")

local function run()
    T.describe("In-Engine E2E Module & JSON Serializer Contract", function()

        local e2e = require("lib.engine_e2e")

        T.it("should serialize primitive values to valid JSON strings", function()
            T.assert_equal("null", e2e.toJson(nil), "nil should serialize to null")
            T.assert_equal("true", e2e.toJson(true), "true should serialize to true")
            T.assert_equal("false", e2e.toJson(false), "false should serialize to false")
            T.assert_equal("42", e2e.toJson(42), "42 should serialize to 42")
            T.assert_equal('"hello"', e2e.toJson("hello"), "string should serialize quoted")
            T.assert_equal('"line1\\nline2"', e2e.toJson("line1\nline2"), "newlines should be escaped")
            T.assert_equal('"quote: \\""', e2e.toJson('quote: "'), "quotes should be escaped")
        end)

        T.it("should serialize sequential array tables to JSON arrays", function()
            local arr = { 1, 2, "three", true }
            local json = e2e.toJson(arr)
            T.assert_equal('[1,2,"three",true]', json, "array mismatch")
        end)

        T.it("should serialize dictionary tables to JSON objects", function()
            local obj = { status = "PASS", count = 5 }
            local json = e2e.toJson(obj)
            -- Both keys must be present in the object
            local hasStatus = json:find('"status":"PASS"') ~= nil
            local hasCount = json:find('"count":5') ~= nil
            T.assert_true(hasStatus and hasCount, "dictionary keys mismatch in " .. json)
        end)

        T.it("should safely abort in offline mock environment without player pawn", function()
            -- In mock environment without an active player pawn, runE2E must safely abort
            local report = e2e.runE2E()
            T.assert_true(report ~= nil, "report should not be nil")
            T.assert_equal("ABORTED", report.status, "status should be ABORTED when no pawn/PC is active")
            T.assert_true(report.aborted == true, "aborted flag should be true")
            T.assert_true(type(report.error) == "string", "error string should be provided")
            T.assert_equal(0, report.summary.total, "total scenarios should be 0 on abort")
        end)

    end)
end

return { run = run }
