-- TBOD_PhotoMode keybinds module
-- Key aliases, resolution, binding infrastructure

local core = require("lib.core")

local M = {}

M.KeyAliases = {
    UP              = "UP_ARROW",
    DOWN            = "DOWN_ARROW",
    LEFT            = "LEFT_ARROW",
    RIGHT           = "RIGHT_ARROW",
    ARROW_UP        = "UP_ARROW",
    ARROW_DOWN      = "DOWN_ARROW",
    ARROW_LEFT      = "LEFT_ARROW",
    ARROW_RIGHT     = "RIGHT_ARROW",
    NUMPAD0         = "NUM_ZERO",
    NUMPAD_0        = "NUM_ZERO",
    NUMPADZERO      = "NUM_ZERO",
    NUM_0           = "NUM_ZERO",
    NUMPAD1         = "NUM_ONE",
    NUMPAD_1        = "NUM_ONE",
    NUMPADONE       = "NUM_ONE",
    NUM_1           = "NUM_ONE",
    NUMPAD2         = "NUM_TWO",
    NUMPAD_2        = "NUM_TWO",
    NUMPADTWO       = "NUM_TWO",
    NUM_2           = "NUM_TWO",
    NUMPAD3         = "NUM_THREE",
    NUMPAD_3        = "NUM_THREE",
    NUMPADTHREE     = "NUM_THREE",
    NUM_3           = "NUM_THREE",
    NUMPAD4         = "NUM_FOUR",
    NUMPAD_4        = "NUM_FOUR",
    NUMPADFOUR      = "NUM_FOUR",
    NUM_4           = "NUM_FOUR",
    NUMPAD5         = "NUM_FIVE",
    NUMPAD_5        = "NUM_FIVE",
    NUMPADFIVE      = "NUM_FIVE",
    NUM_5           = "NUM_FIVE",
    NUMPAD6         = "NUM_SIX",
    NUMPAD_6        = "NUM_SIX",
    NUMPADSIX       = "NUM_SIX",
    NUM_6           = "NUM_SIX",
    NUMPAD7         = "NUM_SEVEN",
    NUMPAD_7        = "NUM_SEVEN",
    NUMPADSEVEN     = "NUM_SEVEN",
    NUM_7           = "NUM_SEVEN",
    NUMPAD8         = "NUM_EIGHT",
    NUMPAD_8        = "NUM_EIGHT",
    NUMPADEIGHT     = "NUM_EIGHT",
    NUM_8           = "NUM_EIGHT",
    NUMPAD9         = "NUM_NINE",
    NUMPAD_9        = "NUM_NINE",
    NUMPADNINE      = "NUM_NINE",
    NUM_9           = "NUM_NINE",
    NUMPADADD       = "ADD",
    NUMPAD_ADD      = "ADD",
    NUMPADPLUS      = "ADD",
    NUMPAD_PLUS     = "ADD",
    PLUS            = "ADD",
    NUMPADSUBTRACT  = "SUBTRACT",
    NUMPAD_SUBTRACT = "SUBTRACT",
    NUMPADMINUS     = "SUBTRACT",
    NUMPAD_MINUS    = "SUBTRACT",
    MINUS           = "SUBTRACT",
    NUMPADMULTIPLY  = "MULTIPLY",
    NUMPAD_MULTIPLY = "MULTIPLY",
    NUMPADDIVIDE    = "DIVIDE",
    NUMPAD_DIVIDE   = "DIVIDE",
    NUMPADDECIMAL   = "DECIMAL",
    NUMPAD_DECIMAL  = "DECIMAL",
    ESC             = "ESCAPE",
    ENTER           = "RETURN",
    CTRL            = "CONTROL",
    LCTRL           = "CONTROL",
    RCTRL           = "CONTROL",
    DEL             = "DEL",
    DELETE          = "DEL",
    INS             = "INS",
    INSERT          = "INS",
    PGUP            = "PAGE_UP",
    PAGEUP          = "PAGE_UP",
    PGDN            = "PAGE_DOWN",
    PAGEDOWN        = "PAGE_DOWN",
    BACK            = "BACKSPACE",
    LEFTBRACKET     = "OEM_FOUR",
    RIGHTBRACKET    = "OEM_SIX",
    BACKSLASH       = "OEM_FIVE",
    ["["]           = "OEM_FOUR",
    ["]"]           = "OEM_SIX",
    ["\\"]          = "OEM_FIVE",
    OEMOPENBRACKETS = "OEM_FOUR",
    OEMCLOSEBRACKETS= "OEM_SIX",
    OEMBACKSLASH    = "OEM_FIVE",
    OEMPIPE         = "OEM_FIVE",
    OEM_4           = "OEM_FOUR",
    OEM_5           = "OEM_FIVE",
    OEM_6           = "OEM_SIX",
    -- Mouse buttons
    MIDDLEMOUSEBUTTON = "MiddleMouseButton",
    MIDDLE_MOUSE     = "MiddleMouseButton",
    MOUSE_MIDDLE    = "MiddleMouseButton",
    -- Gamepad (UE4SS Key table uses mixed-case FKey names)
    GAMEPAD_DPAD_UP          = "Gamepad_DPad_Up",
    GAMEPAD_DPAD_DOWN        = "Gamepad_DPad_Down",
    GAMEPAD_DPAD_LEFT        = "Gamepad_DPad_Left",
    GAMEPAD_DPAD_RIGHT       = "Gamepad_DPad_Right",
    GAMEPAD_SPECIAL_LEFT     = "Gamepad_Special_Left",
    GAMEPAD_SPECIAL_RIGHT    = "Gamepad_Special_Right",
    GAMEPAD_LEFTTHUMBSTICK   = "Gamepad_LeftThumbstick",
    GAMEPAD_RIGHTTHUMBSTICK  = "Gamepad_RightThumbstick",
    GAMEPAD_FACEBUTTON_BOTTOM = "Gamepad_FaceButton_Bottom",
    GAMEPAD_FACEBUTTON_RIGHT  = "Gamepad_FaceButton_Right",
    GAMEPAD_FACEBUTTON_TOP    = "Gamepad_FaceButton_Top",
    GAMEPAD_FACEBUTTON_LEFT   = "Gamepad_FaceButton_Left",
}

function M.resolveKey(name)
    if not name or type(name) ~= "string" then return nil end
    local clean = core.trim(name):upper():gsub("%s+", "")
    local mapped = M.KeyAliases[clean] or clean
    return Key[mapped]
end

function M.safeBind(keyName, mods, fn)
    local k = M.resolveKey(keyName)
    if not k then return false end
    local isGamepad = tostring(keyName):upper():find("GAMEPAD_") ~= nil
    local wrappedFn = function()
        fn(isGamepad, keyName)
    end
    if mods then RegisterKeyBind(k, mods, wrappedFn) else RegisterKeyBind(k, wrappedFn) end
    return true
end

-- Binds EVERY resolvable name in the list to fn (comma-separated INI values act
-- as simultaneous alternates, e.g. "F1, Gamepad_Special_Left" binds both).
-- Unresolvable names are skipped; returns false only if nothing bound at all.
function M.bindWithFallback(keyNames, mods, fn, label)
    local bound = {}
    for _, name in ipairs(keyNames) do
        if M.safeBind(name, mods, fn) then
            table.insert(bound, name)
        end
    end
    if #bound > 0 then
        core.dbg("  Key bound: %s -> %s", table.concat(bound, ", "), label)
        return true
    end
    core.logMsg("  WARNING: no key for %s", label)
    return false
end

function M.keyList(value)
    local list = {}
    for part in tostring(value):gmatch("[^,]+") do
        local name = core.trim(part)
        if name ~= "" then table.insert(list, name) end
    end
    return list
end

return M
