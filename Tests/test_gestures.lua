-- test_gestures.lua
-- Unit tests for Multi-Tap detection, sprint rejection, and screenshot debounce

local T = require("microtest")

local function run()
    T.describe("Controller Gesture & Debounce Logic", function()
        
        -- Multi-Tap State Machine Simulator based on gamepad.lua
        local function createMultiTapSimulator()
            local sim = {
                l3TapCount = 0,
                l3PressStartTime = 0,
                lastL3ReleaseTime = 0,
                l3WasDownPrev = false,
                triggered = false,
                L3_MULTI_TAP_WINDOW = 0.45,
                L3_TAP_MAX_DURATION = 0.40,
            }

            function sim:update(now, isDown)
                if isDown and not self.l3WasDownPrev then
                    self.l3WasDownPrev = true
                    self.l3PressStartTime = now

                    local timeSinceRelease = now - self.lastL3ReleaseTime
                    if self.lastL3ReleaseTime > 0 and timeSinceRelease > 0.03 and timeSinceRelease <= self.L3_MULTI_TAP_WINDOW then
                        self.l3TapCount = self.l3TapCount + 1
                    else
                        self.l3TapCount = 1
                    end

                    if self.l3TapCount >= 3 then
                        self.triggered = true
                        self.l3TapCount = 0
                        self.l3PressStartTime = 0
                        self.lastL3ReleaseTime = 0
                    end
                elseif not isDown and self.l3WasDownPrev then
                    self.l3WasDownPrev = false
                    local pressDuration = now - self.l3PressStartTime
                    self.l3PressStartTime = 0
                    if pressDuration > self.L3_TAP_MAX_DURATION then
                        self.l3TapCount = 0
                        self.lastL3ReleaseTime = 0
                    else
                        self.lastL3ReleaseTime = now
                    end
                end
            end

            return sim
        end

        T.it("should trigger Photo Mode on 3 quick clicks (L3 Triple-Tap)", function()
            local sim = createMultiTapSimulator()
            local t = 100.0

            -- Click 1: press at 100.0, release at 100.08
            sim:update(t, true); sim:update(t + 0.08, false)
            T.assert_equal(1, sim.l3TapCount, "Tap 1 count mismatch")
            T.assert_false(sim.triggered, "Should not trigger on tap 1")

            -- Click 2: press at 100.20, release at 100.28
            t = 100.20
            sim:update(t, true); sim:update(t + 0.08, false)
            T.assert_equal(2, sim.l3TapCount, "Tap 2 count mismatch")
            T.assert_false(sim.triggered, "Should not trigger on tap 2")

            -- Click 3: press at 100.40
            t = 100.40
            sim:update(t, true)
            T.assert_true(sim.triggered, "Expected Triple-Tap to trigger Photo Mode on tap 3!")
        end)

        T.it("should reject sprint hold (L3 pressed > 400ms) and reset sequence", function()
            local sim = createMultiTapSimulator()
            local t = 100.0

            -- Click 1: quick tap
            sim:update(t, true); sim:update(t + 0.08, false)
            T.assert_equal(1, sim.l3TapCount)

            -- Click 2: player holds L3 to sprint for 800ms
            t = 100.25
            sim:update(t, true)
            sim:update(t + 0.80, false) -- hold > 0.40s
            T.assert_equal(0, sim.l3TapCount, "Sprint hold should reset l3TapCount to 0")

            -- Click 3: single tap afterwards
            t = 101.20
            sim:update(t, true); sim:update(t + 0.08, false)
            T.assert_equal(1, sim.l3TapCount, "Count should be 1 after reset, not 3")
            T.assert_false(sim.triggered, "Should NOT trigger PM when previous press was sprint hold")
        end)

        T.it("should reset sequence if taps are spaced too far apart (> 450ms)", function()
            local sim = createMultiTapSimulator()
            local t = 100.0

            -- Click 1
            sim:update(t, true); sim:update(t + 0.08, false)
            T.assert_equal(1, sim.l3TapCount)

            -- Click 2 after 700ms (too slow)
            t = 100.78
            sim:update(t, true); sim:update(t + 0.08, false)
            T.assert_equal(1, sim.l3TapCount, "Slow tap should reset count to 1")
            T.assert_false(sim.triggered)
        end)

        -- Screenshot Debounce Simulator
        local function createScreenshotDebouncer()
            local debouncer = {
                lastShotTime = 0,
                inProgress = false,
                shotsTaken = 0,
            }

            function debouncer:requestShot(now)
                if (now - self.lastShotTime) < 1.0 or self.inProgress then
                    return false -- skipped
                end
                self.lastShotTime = now
                self.inProgress = true
                self.shotsTaken = self.shotsTaken + 1
                return true
            end

            function debouncer:completeShot()
                self.inProgress = false
            end

            return debouncer
        end

        T.it("should enforce 1.0s debounce on screenshots to prevent duplicate executions", function()
            local deb = createScreenshotDebouncer()
            local t = 10.0

            -- Shot 1
            local ok1 = deb:requestShot(t)
            T.assert_true(ok1, "First shot should succeed")
            deb:completeShot()

            -- Rapid second shot 25ms later (polling frequency)
            local ok2 = deb:requestShot(t + 0.025)
            T.assert_false(ok2, "Rapid second shot within 1.0s must be debounced")

            -- Third shot at 800ms
            local ok3 = deb:requestShot(t + 0.80)
            T.assert_false(ok3, "Shot at 800ms must still be debounced")

            -- Fourth shot at 1.05s
            local ok4 = deb:requestShot(t + 1.05)
            T.assert_true(ok4, "Shot after 1.0s window should succeed")
            T.assert_equal(2, deb.shotsTaken, "Total shots taken should be exactly 2")
        end)
    end)
end

return { run = run }
