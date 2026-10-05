-- test_osd_state.lua
-- Unit tests for OSD Tab cycling, Row navigation, and Clean View state transitions

local T = require("microtest")

local function run()
    T.describe("OSD Navigation & Clean View State Transitions", function()

        -- Tab Cycler Simulator
        local function createTabNavigator()
            local nav = {
                currentTab = 1,
                NUM_TABS = 3, -- 1=Camera, 2=Directing, 3=Stage
            }
            function nav:osdTab(delta)
                self.currentTab = self.currentTab + delta
                if self.currentTab > self.NUM_TABS then self.currentTab = 1 end
                if self.currentTab < 1 then self.currentTab = self.NUM_TABS end
                return self.currentTab
            end
            return nav
        end

        T.it("should cycle forward and wrap tabs (1 -> 2 -> 3 -> 1)", function()
            local nav = createTabNavigator()
            T.assert_equal(1, nav.currentTab)
            T.assert_equal(2, nav:osdTab(1), "Tab next failed 1->2")
            T.assert_equal(3, nav:osdTab(1), "Tab next failed 2->3")
            T.assert_equal(1, nav:osdTab(1), "Tab wrap failed 3->1")
        end)

        T.it("should cycle backward and wrap tabs (1 -> 3 -> 2 -> 1)", function()
            local nav = createTabNavigator()
            T.assert_equal(3, nav:osdTab(-1), "Tab wrap failed 1->3")
            T.assert_equal(2, nav:osdTab(-1), "Tab prev failed 3->2")
            T.assert_equal(1, nav:osdTab(-1), "Tab prev failed 2->1")
        end)

        -- Clean View State Machine Simulator
        local function createCleanViewMachine()
            local sm = {
                osdVisible = true,
                hudVisible = true,
                cleanViewActive = false,
            }
            function sm:toggleCleanView()
                if not self.cleanViewActive then
                    -- Hide both OSD and HUD for clear framing
                    self.cleanViewActive = true
                    self.osdVisible = false
                    self.hudVisible = false
                else
                    -- Restore both
                    self.cleanViewActive = false
                    self.osdVisible = true
                    self.hudVisible = true
                end
            end
            return sm
        end

        T.it("should cleanly toggle all UI off on first press and restore on second press", function()
            local cv = createCleanViewMachine()
            T.assert_true(cv.osdVisible)
            T.assert_true(cv.hudVisible)
            T.assert_false(cv.cleanViewActive)

            -- Press 1 (Square / X): Hide everything for pristine framing
            cv:toggleCleanView()
            T.assert_true(cv.cleanViewActive, "Clean view should be active")
            T.assert_false(cv.osdVisible, "OSD should be hidden in Clean View")
            T.assert_false(cv.hudVisible, "HUD should be hidden in Clean View")

            -- Press 2 (Square / X): Restore everything
            cv:toggleCleanView()
            T.assert_false(cv.cleanViewActive, "Clean view should be inactive")
            T.assert_true(cv.osdVisible, "OSD should be restored")
            T.assert_true(cv.hudVisible, "HUD should be restored")
        end)
    end)
end

return { run = run }
