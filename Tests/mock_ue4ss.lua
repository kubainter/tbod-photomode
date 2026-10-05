-- mock_ue4ss.lua
-- Emulates UE4SS globals, structs, and engine dummies for offline unit tests.

local M = {}

function M.install()
    -- Global print if needed
    if not _G.print then _G.print = print end

    -- Virtual key table (subset of UE4SS Key table)
    _G.Key = _G.Key or {
        F1 = 0x70, F2 = 0x71, F3 = 0x72, F4 = 0x73, F5 = 0x74, F6 = 0x75,
        F7 = 0x76, F8 = 0x77, F9 = 0x78, F10 = 0x79, F11 = 0x7A, F12 = 0x7B,
        A = 0x41, B = 0x42, C = 0x43, D = 0x44, E = 0x45, F = 0x46,
        H = 0x48, P = 0x50, Q = 0x51, R = 0x52, S = 0x53, W = 0x57,
        ESCAPE = 0x1B, RETURN = 0x0D, SPACE = 0x20,
        UP_ARROW = 0x26, DOWN_ARROW = 0x28, LEFT_ARROW = 0x25, RIGHT_ARROW = 0x27,
        PAGE_UP = 0x21, PAGE_DOWN = 0x22,
    }

    -- UE4SS Keybind hooks
    _G.RegisteredKeyBinds = {}
    _G.RegisterKeyBind = function(k, modsOrFn, fn)
        local callback = type(modsOrFn) == "function" and modsOrFn or fn
        table.insert(_G.RegisteredKeyBinds, { key = k, fn = callback })
    end

    -- Threading mocks
    _G.ExecuteInGameThread = function(fn) fn() end
    _G.ExecuteInGameThreadWithDelay = function(ms, fn) fn() end
    _G.ExecuteWithDelay = function(ms, fn) fn() end

    -- Reflection mocks
    _G.FName = function(name) return { name = name, ToString = function() return name end } end
    _G.StaticFindObject = function(path) return nil end
    _G.FindFirstOf = function(cls) return nil end
    _G.FindAllOf = function(cls) return {} end

    -- FText mock
    _G.FText = function(str) return { text = str, ToString = function() return str end } end

    -- EventBridge mock
    _G.UE4SSLuaEventBridge = {
        GetVersion = function() return "1.0.7" end,
        GetCapabilities = function() return { inputHooking = true } end,
        OpenInputComponent = function(path) return 1 end,
        BindAction = function(target, path, phase, callback) return 100 end,
        UnbindAction = function(handle) return true end,
        CloseInputComponent = function(handle) return true end,
    }
end

return M
