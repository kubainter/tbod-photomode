-- TBOD_PhotoMode OSD module
-- Dynamic UMG OSD — build, update, navigation, toggle

local core = require("lib.core")
local State = core.State
local Config = core.Config
local Subsystem = core.Subsystem
local logMsg = core.logMsg
local dbg = core.dbg

local M = {}

-- ESlateVisibility enum values
local VIS_VISIBLE            = 0
local VIS_COLLAPSED          = 1
local VIS_HIDDEN             = 2
local VIS_HIT_TEST_INVISIBLE = 3

-- OSD widget references
M.OSD_UI = {
    root     = nil,
    canvas   = nil,
    border   = nil,
    vbox     = nil,
    title    = nil,
    rows     = {},
    helpLine = nil,
}
M.osdBuilt = false

-- OSD colors (FLinearColor: 0.0-1.0)
local OSD_COLOR_BG     = { R = 0.02, G = 0.02, B = 0.02, A = 0.75 }
local OSD_COLOR_TITLE  = { R = 0.88, G = 0.73, B = 0.38, A = 1.0 }
local OSD_COLOR_NORMAL = { R = 0.85, G = 0.85, B = 0.85, A = 1.0 }
local OSD_COLOR_HELP   = { R = 0.55, G = 0.55, B = 0.55, A = 0.9 }
local OSD_COLOR_ACTIVE = { R = 1.00, G = 0.85, B = 0.40, A = 1.0 }

-- OSD row definitions (live data binding via closures over State)
M.OSD_ROWS = {
    { label = "FOV",          fmt = function() return string.format("%.1f", State.fov) end },
    { label = "Roll",         fmt = function() return string.format("%.1f", State.roll) end },
    { label = "Slow Motion",  fmt = function() return string.format("%.2fx", State.timeDilation) end },
    { label = "Player",       fmt = function() return State.playerHidden and "Hidden" or "Visible" end },
    { label = "HUD",          fmt = function() return State.hudVisible and "Visible" or "Hidden" end },
}

local optics = require("lib.optics")
table.insert(M.OSD_ROWS, { label = "Time of Day", fmt = function() 
    local h = math.floor(State.timeOfDay)
    local m = math.floor((State.timeOfDay - h) * 60)
    return string.format("%02d:%02d", h, m)
end })
table.insert(M.OSD_ROWS, { label = "Auto-Focus", fmt = function()
    if not State.dofEnabled then return "Off" end
    return string.format("%.0f cm", State.focalDistance)
end })
table.insert(M.OSD_ROWS, { label = "Exposure", fmt = function() return require("lib.optics").getExposureLabel() end })
table.insert(M.OSD_ROWS, { label = "Aspect Ratio", fmt = function() return optics.getAspectRatioLabel() end })
table.insert(M.OSD_ROWS, { label = "Framing", fmt = function() return M.getFramingLabel() end })
table.insert(M.OSD_ROWS, { label = "Weather", fmt = function() return optics.getWeatherLabel() end })
-- Experimental 1.5.0 rows — hidden unless enable_experimental is set in INI.
if Config.enable_experimental then
    table.insert(M.OSD_ROWS, { label = "Target", fmt = function() return require("lib.poses").getTargetLabel() end })
    table.insert(M.OSD_ROWS, { label = "Pose", fmt = function() return require("lib.poses").getPoseLabel() end })
    table.insert(M.OSD_ROWS, { label = "Spawn NPC", fmt = function()
        local n = #require("lib.spawner").spawnedClones
        if n > 0 then
            return "[<] Despawn  [>] Spawn (" .. n .. ")"
        end
        return "[>] Spawn"
    end })
    table.insert(M.OSD_ROWS, { label = "Frame Step", fmt = function()
        if State.timeDilation > 0.05 and not State.paused then
            return "[>] Freeze & Step"
        else
            return "[<] Play  [>] Step +1"
        end
    end })
    table.insert(M.OSD_ROWS, { label = "Spawn Class", fmt = function()
        return require("lib.spawner").getSelectedNpcClassLabel()
    end })
    table.insert(M.OSD_ROWS, { label = "Move Fwd",    fmt = function() return "[<] - [>]" end })
    table.insert(M.OSD_ROWS, { label = "Move Side",   fmt = function() return "[<] - [>]" end })
    table.insert(M.OSD_ROWS, { label = "Move Height", fmt = function() return "[<] - [>]" end })
    table.insert(M.OSD_ROWS, { label = "Rotate",      fmt = function() return "[<] - [>]" end })
    table.insert(M.OSD_ROWS, { label = "Face Cam",    fmt = function() return "[>] Face" end })
end

-- Dynamic Tab definitions (Sprint 1.5.1)
M.currentTab = 1
M.TABS = nil

function M.buildTabs()
    local findIdx = function(lbl)
        for i, r in ipairs(M.OSD_ROWS) do
            if r.label == lbl then return i end
        end
        return nil
    end

    local makeTab = function(name, labels)
        local rows = {}
        for _, l in ipairs(labels) do
            local idx = findIdx(l)
            if idx then table.insert(rows, idx) end
        end
        return { name = name, rows = rows }
    end

    local cameraTab = makeTab("CAMERA", { "FOV", "Roll", "Auto-Focus", "Exposure", "Aspect Ratio", "Framing" })
    local environmentTab = makeTab("ENVIRONMENT", { "Time of Day", "Weather" })
    if State.pmMode == "cutscene" then
        -- Cutscene PM exposes camera/optics controls without Roll
        local cutsceneCameraTab = makeTab("CAMERA", { "FOV", "Auto-Focus", "Exposure", "Aspect Ratio", "Framing" })
        M.TABS = { cutsceneCameraTab, environmentTab }
    else
        M.TABS = {
            cameraTab,
            environmentTab,
            makeTab("DIRECTING", { "Target", "Pose", "Frame Step", "Slow Motion", "Player", "HUD" }),
            makeTab("STAGE", { "Target", "Pose", "Spawn Class", "Spawn NPC", "Move Fwd", "Move Side", "Move Height", "Rotate", "Face Cam" })
        }
    end
end

M.buildTabs()

-- OSD navigation state
M.OSD_SELECTED = 1

function M.osdValid(obj)
    return obj and obj:IsValid()
end

local function getGameInstance()
    if State.cachedGI and M.osdValid(State.cachedGI) then return State.cachedGI end

    local ok, helpers = pcall(require, "UEHelpers.UEHelpers")
    if not ok or not helpers then
        ok, helpers = pcall(require, "UEHelpers")
    end
    if ok and helpers then
        local okGI, gi = pcall(helpers.GetGameInstance)
        if okGI and M.osdValid(gi) then
            State.cachedGI = gi
            return gi
        end
    end
    local gi = FindFirstOf("GameInstance")
    if M.osdValid(gi) then
        State.cachedGI = gi
        return gi
    end
    local pc = Subsystem.playerController()
    if M.osdValid(pc) then
        local okPI, pi = pcall(function() return pc.Player end)
        if okPI and M.osdValid(pi) then
            local okGI2, gi2 = pcall(function() return pi.GameInstance end)
            if okGI2 and M.osdValid(gi2) then
                State.cachedGI = gi2
                return gi2
            end
        end
    end
    return nil
end

local function osdConstruct(classPath, outer, name)
    local class = State.osdClasses[classPath]
    if not M.osdValid(class) then
        class = StaticFindObject(classPath)
        if M.osdValid(class) then
            State.osdClasses[classPath] = class
        else
            logMsg("OSD: class not found: %s", classPath)
            return nil
        end
    end

    local objName = (type(FName) == "function" and FName(name)) or name
    local ok, obj = pcall(StaticConstructObject, class, outer, objName)
    if not ok or not M.osdValid(obj) then
        logMsg("OSD: construct failed: %s (%s)", name, tostring(obj))
        return nil
    end
    return obj
end

local function osdCreateTextBlock(parent, name, text, color, fontSize)
    local tb = osdConstruct("/Script/UMG.TextBlock", parent, name)
    if not tb then return nil end
    pcall(function() tb:SetText(FText(text)) end)
    pcall(function() tb:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 }) end)
    if fontSize then
        pcall(function()
            local font = tb.Font
            if font then
                font.Size = fontSize
                tb.Font = font
            end
        end)
    end
    pcall(function() parent:AddChildToVerticalBox(tb) end)
    return tb
end

local function primaryKbKey(keyStr, fallback)
    if not keyStr or keyStr == "" then return fallback or "" end
    for part in tostring(keyStr):gmatch("[^,]+") do
        local trimmed = core.trim(part)
        if not trimmed:find("^Gamepad_") then
            return trimmed
        end
    end
    return fallback or ""
end

local function getOSDHelpText()
    if State.lastInputDevice == "gamepad" then
        return "\n[D-Pad] Select / Adjust       [LB/RB] Tab\n" ..
               "[A / Cross] Action / Pause    [Square / X] Clean View    [Y / Triangle] Reset\n" ..
               "[LT/RT] Down / Up             [L3] FOV Reset            [B / Circle] Screenshot\n" ..
               "[Menu / Start] Exit Photo Mode"
    else
        local tabHint = string.format("[%s/%s] Tab   ", primaryKbKey(Config.osd_tab_prev_key, "PgUp"), primaryKbKey(Config.osd_tab_next_key, "PgDn"))
        local text = string.format(
            "\n%s[\u{2191}/\u{2193}] Select   [\u{2190}/\u{2192}] Adjust   [%s] Reset All\n" ..
            "[%s] FOV Reset      [%s] Screenshot        [%s] Freeze\n" ..
            "[%s] Toggle HUD      [%s] Toggle OSD       [%s/%s] Down/Up\n" ..
            "[%s] Exit Photo Mode",
            tabHint,
            primaryKbKey(Config.osd_reset_key, "R"),
            primaryKbKey(Config.fov_reset_key, "F3"),
            primaryKbKey(Config.screenshot_key, "P"),
            primaryKbKey(Config.pause_key, "F2"),
            primaryKbKey(Config.hud_key, "H"),
            primaryKbKey(Config.osd_toggle_key, "F1"),
            primaryKbKey(Config.move_down_key, "Q"),
            primaryKbKey(Config.move_up_key, "E"),
            primaryKbKey(Config.exit_guard_key, "Esc")
        )
        return text
    end
end

function M.buildOSD()
    dbg("OSD: buildOSD started")
    if M.osdBuilt and M.osdValid(M.OSD_UI.root) then return true end

    local gi = getGameInstance()
    dbg("OSD: GameInstance = %s", tostring(gi))
    if not gi then
        logMsg("OSD: GameInstance not found")
        return false
    end

    core.OSD_BUILD_COUNT = core.OSD_BUILD_COUNT + 1
    local suffix = tostring(os.time()) .. "_" .. tostring(core.OSD_BUILD_COUNT)

    local root = osdConstruct("/Script/UMG.UserWidget", gi, "TBODPM_OSD_" .. suffix)
    dbg("OSD: root = %s", tostring(root))
    if not root then return false end

    local tree = osdConstruct("/Script/UMG.WidgetTree", root, "TBODPM_OSD_Tree_" .. suffix)
    if not tree then return false end
    pcall(function() root.WidgetTree = tree end)

    local canvas = osdConstruct("/Script/UMG.CanvasPanel", tree, "TBODPM_OSD_Canvas_" .. suffix)
    if not canvas then return false end
    pcall(function() tree.RootWidget = canvas end)

    local border = osdConstruct("/Script/UMG.Border", canvas, "TBODPM_OSD_Border_" .. suffix)
    if not border then return false end
    pcall(function() border:SetBrushColor(OSD_COLOR_BG) end)
    pcall(function() border:SetPadding({Left = 12, Top = 10, Right = 12, Bottom = 10}) end)
    pcall(function() border:SetRenderTransformPivot({X = 0, Y = 0}) end)
    pcall(function() border:SetRenderScale({X = Config.osd_scale, Y = Config.osd_scale}) end)
    pcall(function()
        local slot = canvas:AddChildToCanvas(border)
        if slot then
            pcall(function() slot:SetAnchors({Minimum = {X = 0, Y = 0}, Maximum = {X = 0, Y = 0}}) end)
            pcall(function() slot:SetAlignment({X = 0, Y = 0}) end)
            pcall(function() slot:SetPosition({X = 20, Y = 20}) end)
            pcall(function() slot:SetAutoSize(true) end)
        end
    end)

    local vbox = osdConstruct("/Script/UMG.VerticalBox", border, "TBODPM_OSD_VBox_" .. suffix)
    if not vbox then return false end
    pcall(function() border:SetContent(vbox) end)

    local title = osdCreateTextBlock(vbox, "TBODPM_OSD_Title_" .. suffix,
        "[ PHOTO MODE ]", OSD_COLOR_TITLE, 14)

    local rows = {}
    for i, row in ipairs(M.OSD_ROWS) do
        rows[i] = osdCreateTextBlock(vbox, "TBODPM_OSD_Row" .. i .. "_" .. suffix,
            "", OSD_COLOR_NORMAL, 12)
    end

    local helpLine = osdCreateTextBlock(vbox, "TBODPM_OSD_Help_" .. suffix,
        getOSDHelpText(), OSD_COLOR_HELP, 10)

    M.OSD_UI.root     = root
    M.OSD_UI.canvas   = canvas
    M.OSD_UI.border   = border
    M.OSD_UI.vbox     = vbox
    M.OSD_UI.title    = title
    M.OSD_UI.rows     = rows
    M.OSD_UI.helpLine = helpLine

    local okAdd, errAdd = pcall(function() root:AddToViewport(9000) end)
    if not okAdd then
        logMsg("OSD: AddToViewport failed: %s", tostring(errAdd))
        return false
    end

    local rootFullName = ""
    pcall(function() rootFullName = root:GetFullName() end)
    M.OSD_UI.rootFullName = rootFullName
    dbg("OSD: root FullName = %s", tostring(rootFullName))
    pcall(function() root:SetVisibility(VIS_HIT_TEST_INVISIBLE) end)
    M.osdBuilt = true

    dbg("OSD: built and added to viewport (ZOrder 9000)")
    return true
end

function M.ensureOSD()
    if M.osdBuilt and M.osdValid(M.OSD_UI.root) then
        local inViewport = false
        pcall(function() inViewport = M.OSD_UI.root:IsInViewport() end)
        if inViewport then return true end
        M.osdBuilt = false
    end
    return M.buildOSD()
end

---------------------------------------------------------------------------- Letterbox (fake aspect-ratio bars)
-- PhotoCameraActor has no camera component, so there is nowhere on the view
-- path for a real constrained aspect ratio to live. Instead we draw two black
-- bars via UMG — they frame the shot AND get baked into our window-grab
-- screenshots, which is the intended cinematic effect.

local LETTERBOX = { root = nil, canvas = nil, top = nil, bottom = nil, built = false, lastVW = 0, lastVH = 0 }

-- Photo Mode-owned widgets must not be treated as game HUD. In particular,
-- the letterbox and framing overlay are intentionally visible when the real
-- HUD is hidden.
local FRAMING = { root = nil, canvas = nil, lines = {}, built = false, visible = false }

function M.isModOwnedWidget(widget)
    if not widget or not widget:IsValid() then return false end

    -- 1. Direct Lua reference check
    if widget == LETTERBOX.root or widget == M.OSD_UI.root or widget == FRAMING.root then
        return true
    end

    -- 2. C++ UObject address comparison (critical for UE4SS wrapper instances from FindAllOf)
    local wAddr = nil
    pcall(function() wAddr = widget:GetAddress() end)
    if wAddr and wAddr ~= 0 then
        local function matchAddr(modObj)
            if modObj and modObj:IsValid() then
                local a = nil
                pcall(function() a = modObj:GetAddress() end)
                return a and a == wAddr
            end
            return false
        end
        if matchAddr(M.OSD_UI.root) or matchAddr(LETTERBOX.root) or matchAddr(FRAMING.root) then
            return true
        end
    end

    -- 3. Stored FullName comparison (exact match)
    local fullName = ""
    pcall(function() fullName = widget:GetFullName() end)
    local nameStr = tostring(fullName)
    if (M.OSD_UI.rootFullName and nameStr == M.OSD_UI.rootFullName)
        or (LETTERBOX.rootFullName and nameStr == LETTERBOX.rootFullName)
        or (FRAMING.rootFullName and nameStr == FRAMING.rootFullName) then
        return true
    end

    -- 4. Substring checks (if engine preserved custom names)
    if nameStr:find("TBODPM_OSD", 1, true) ~= nil
        or nameStr:find("TBODPM_LB_", 1, true) ~= nil
        or nameStr:find("TBODPM_FRAME_", 1, true) ~= nil then
        return true
    end
    local objectName = ""
    pcall(function() objectName = widget:GetName() end)
    objectName = tostring(objectName)
    return objectName:find("TBODPM_OSD", 1, true) ~= nil
        or objectName:find("TBODPM_LB_", 1, true) ~= nil
        or objectName:find("TBODPM_FRAME_", 1, true) ~= nil
end

local function getViewportSize()
    local pc = Subsystem.playerController()
    if pc and pc:IsValid() then
        local ok, w, h = pcall(function() return pc:GetViewportSize() end)
        if ok and w and h and w > 0 and h > 0 then return w, h end
        -- Some UE4SS builds need the out-params passed in.
        ok, w, h = pcall(function() return pc:GetViewportSize(0, 0) end)
        if ok and w and h and w > 0 and h > 0 then return w, h end
    end

    if not State.cachedGVC or not M.osdValid(State.cachedGVC) then
        local gvc = FindFirstOf("GameViewportClient")
        if M.osdValid(gvc) then
            State.cachedGVC = gvc
        end
    end

    local gvc = State.cachedGVC
    if M.osdValid(gvc) then
        local ok, sz = pcall(function() return gvc:GetViewportSize() end)
        if ok and sz and sz.X and sz.X > 0 then return sz.X, sz.Y end
        ok, sz = pcall(function() return gvc:GetViewportSize({X = 0, Y = 0}) end)
        if ok and sz and sz.X and sz.X > 0 then return sz.X, sz.Y end
    end
    return 1920, 1080
end

local function buildLetterbox()
    if LETTERBOX.built and M.osdValid(LETTERBOX.root) then
        local inViewport = false
        pcall(function() inViewport = LETTERBOX.root:IsInViewport() end)
        if inViewport then return true end
        LETTERBOX.built = false
    end

    local gi = getGameInstance()
    if not gi then return false end

    local suffix = tostring(os.time()) .. "_LB"
    local root = osdConstruct("/Script/UMG.UserWidget", gi, "TBODPM_LB_" .. suffix)
    if not root then return false end
    local tree = osdConstruct("/Script/UMG.WidgetTree", root, "TBODPM_LB_Tree_" .. suffix)
    if not tree then return false end
    pcall(function() root.WidgetTree = tree end)
    local canvas = osdConstruct("/Script/UMG.CanvasPanel", tree, "TBODPM_LB_Canvas_" .. suffix)
    if not canvas then return false end
    pcall(function() tree.RootWidget = canvas end)

    local bars = {}
    for i = 1, 2 do
        local b = osdConstruct("/Script/UMG.Border", canvas, "TBODPM_LB_Bar" .. i .. "_" .. suffix)
        if not b then return false end
        pcall(function() b:SetBrushColor({ R = 0, G = 0, B = 0, A = 1 }) end)
        local slot = nil
        pcall(function() slot = canvas:AddChildToCanvas(b) end)
        bars[i] = { border = b, slot = slot }
    end

    pcall(function() root:AddToViewport(8000) end)
    -- AddToViewport does NOT stretch the widget across the screen — the root
    -- gets a point anchor at (0,0) and shrinks to desired size, which makes
    -- every normalized anchor inside the canvas evaluate to the top-left
    -- corner. Stretch the root's viewport slot to fill the whole screen.
    pcall(function()
        root:SetAnchorsInViewport({ Minimum = {X = 0, Y = 0}, Maximum = {X = 1, Y = 1} })
        root:SetOffsetsInViewport({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
    end)
    LETTERBOX.root = root
    local lbFullName = ""
    pcall(function() lbFullName = root:GetFullName() end)
    LETTERBOX.rootFullName = lbFullName
    LETTERBOX.canvas = canvas
    LETTERBOX.top = bars[1]
    LETTERBOX.bottom = bars[2]
    LETTERBOX.built = true
    return true
end

-- ratio = target aspect (w/h) or nil/false to hide the bars.
function M.setLetterbox(ratio)
    if not ratio then
        if LETTERBOX.built and M.osdValid(LETTERBOX.root) then
            pcall(function() LETTERBOX.root:SetVisibility(VIS_COLLAPSED) end)
        end
        return
    end
    if not buildLetterbox() then
        logMsg("Letterbox: build failed")
        return
    end

    local vw, vh = getViewportSize()
    local screenAspect = vw / vh
    if vw ~= LETTERBOX.lastVW or vh ~= LETTERBOX.lastVH then
        logMsg("Letterbox: viewport %dx%d (aspect %.3f), target %.4f", vw, vh, screenAspect, ratio)
        LETTERBOX.lastVW, LETTERBOX.lastVH = vw, vh
    end

    -- FMargin semantics on a canvas slot: on a STRETCHED axis (Min ~= Max)
    -- Left/Top/Right/Bottom are edge margins; on a POINT axis (Min == Max)
    -- Left/Top are position offsets and Right/Bottom are the widget SIZE.
    -- Alignment shifts the widget relative to the anchor point, so we anchor
    -- each bar at its own edge and give it a matching alignment.
    local function setBar(bar, minX, minY, maxX, maxY, alX, alY, l, t, r, b)
        if not (bar and bar.slot) then return end
        pcall(function()
            bar.slot:SetAnchors({ Minimum = {X = minX, Y = minY}, Maximum = {X = maxX, Y = maxY} })
            bar.slot:SetAlignment({X = alX, Y = alY})
            bar.slot:SetOffsets({Left = l, Top = t, Right = r, Bottom = b})
        end)
    end

    if ratio > screenAspect then
        -- target wider than screen: horizontal bars (letterbox)
        local barH = math.max(0, (vh - vw / ratio) / 2)
        setBar(LETTERBOX.top,    0, 0, 1, 0, 0, 0, 0, 0, 0, barH)  -- full width, barH from top
        setBar(LETTERBOX.bottom, 0, 1, 1, 1, 0, 1, 0, 0, 0, barH)  -- full width, barH from bottom
    else
        -- target narrower than screen: vertical bars (pillarbox)
        local barW = math.max(0, (vw - vh * ratio) / 2)
        setBar(LETTERBOX.top,    0, 0, 0, 1, 0, 0, 0, 0, barW, 0)  -- full height, barW from left
        setBar(LETTERBOX.bottom, 1, 0, 1, 1, 1, 0, 0, 0, barW, 0)  -- full height, barW from right
    end

    pcall(function() LETTERBOX.root:SetVisibility(VIS_HIT_TEST_INVISIBLE) end)
end

---------------------------------------------------------------------------- Framing guides (overlay only)

local FRAMING_MODES = { "off", "thirds", "crosshair", "safe" }
local FRAMING_LABELS = {
    off = "Off",
    thirds = "Thirds",
    crosshair = "Crosshair",
    safe = "Safe Frame",
}
local FRAME_COLOR = { R = 1.0, G = 1.0, B = 1.0, A = 0.65 }

function M.getFramingLabel()
    return FRAMING_LABELS[State.framingMode] or "Off"
end

local function buildFraming()
    if FRAMING.built and M.osdValid(FRAMING.root) then
        local inViewport = false
        pcall(function() inViewport = FRAMING.root:IsInViewport() end)
        if inViewport then return true end
        pcall(function() FRAMING.root:RemoveFromParent() end)
        FRAMING.built = false
        FRAMING.root = nil
    end

    local gi = getGameInstance()
    if not gi then return false end
    local suffix = tostring(os.time()) .. "_FRAME"
    local root = osdConstruct("/Script/UMG.UserWidget", gi, "TBODPM_FRAME_" .. suffix)
    if not root then return false end
    local tree = osdConstruct("/Script/UMG.WidgetTree", root, "TBODPM_FRAME_Tree_" .. suffix)
    if not tree then return false end
    pcall(function() root.WidgetTree = tree end)
    local canvas = osdConstruct("/Script/UMG.CanvasPanel", tree, "TBODPM_FRAME_Canvas_" .. suffix)
    if not canvas then return false end
    pcall(function() tree.RootWidget = canvas end)

    local lines = {}
    for i = 1, 4 do
        local line = osdConstruct("/Script/UMG.Border", canvas, "TBODPM_FRAME_Line" .. i .. "_" .. suffix)
        if not line then return false end
        pcall(function() line:SetBrushColor(FRAME_COLOR) end)
        local slot = nil
        pcall(function() slot = canvas:AddChildToCanvas(line) end)
        lines[i] = { widget = line, slot = slot }
    end

    pcall(function() root:AddToViewport(8001) end)
    pcall(function()
        root:SetAnchorsInViewport({ Minimum = {X = 0, Y = 0}, Maximum = {X = 1, Y = 1} })
        root:SetOffsetsInViewport({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        root:SetVisibility(VIS_HIT_TEST_INVISIBLE)
    end)
    FRAMING.root, FRAMING.canvas, FRAMING.lines = root, canvas, lines
    local frFullName = ""
    pcall(function() frFullName = root:GetFullName() end)
    FRAMING.rootFullName = frFullName
    FRAMING.built = true
    return true
end

local function setFrameLine(line, minX, minY, maxX, maxY, alignX, alignY, left, top, right, bottom)
    if not (line and line.slot) then return end
    pcall(function()
        line.slot:SetAnchors({ Minimum = {X = minX, Y = minY}, Maximum = {X = maxX, Y = maxY} })
        line.slot:SetAlignment({ X = alignX, Y = alignY })
        line.slot:SetOffsets({ Left = left, Top = top, Right = right, Bottom = bottom })
        line.widget:SetVisibility(VIS_HIT_TEST_INVISIBLE)
    end)
end

function M.setFramingMode(mode)
    local valid = false
    for _, candidate in ipairs(FRAMING_MODES) do
        if candidate == mode then valid = true; break end
    end
    if not valid then mode = "off" end
    State.framingMode = mode

    if mode == "off" then
        FRAMING.visible = false
        if FRAMING.built and M.osdValid(FRAMING.root) then
            pcall(function() FRAMING.root:SetVisibility(VIS_COLLAPSED) end)
        end
        return true
    end
    if not buildFraming() then
        logMsg("Framing: build failed")
        State.framingMode = "off"
        return false
    end

    for _, line in ipairs(FRAMING.lines) do
        if line.widget and M.osdValid(line.widget) then
            pcall(function() line.widget:SetVisibility(VIS_COLLAPSED) end)
        end
    end

    if mode == "thirds" then
        setFrameLine(FRAMING.lines[1], 1/3, 0, 1/3, 1, 0.5, 0, -1, 0, 1, 0)
        setFrameLine(FRAMING.lines[2], 2/3, 0, 2/3, 1, 0.5, 0, -1, 0, 1, 0)
        setFrameLine(FRAMING.lines[3], 0, 1/3, 1, 1/3, 0, 0.5, 0, -1, 0, 1)
        setFrameLine(FRAMING.lines[4], 0, 2/3, 1, 2/3, 0, 0.5, 0, -1, 0, 1)
    elseif mode == "crosshair" then
        setFrameLine(FRAMING.lines[1], 0.5, 0, 0.5, 1, 0.5, 0, -1, 0, 1, 0)
        setFrameLine(FRAMING.lines[2], 0, 0.5, 1, 0.5, 0, 0.5, 0, -1, 0, 1)
    else
        setFrameLine(FRAMING.lines[1], 0.1, 0, 0.1, 1, 0.5, 0, -1, 0, 1, 0)
        setFrameLine(FRAMING.lines[2], 0.9, 0, 0.9, 1, 0.5, 0, -1, 0, 1, 0)
        setFrameLine(FRAMING.lines[3], 0, 0.1, 1, 0.1, 0, 0.5, 0, -1, 0, 1)
        setFrameLine(FRAMING.lines[4], 0, 0.9, 1, 0.9, 0, 0.5, 0, -1, 0, 1)
    end
    pcall(function() FRAMING.root:SetVisibility(VIS_HIT_TEST_INVISIBLE) end)
    FRAMING.visible = true
    return true
end

function M.cycleFraming(delta)
    local index = 1
    for i, mode in ipairs(FRAMING_MODES) do
        if mode == State.framingMode then index = i; break end
    end
    index = ((index + delta - 1) % #FRAMING_MODES) + 1
    M.setFramingMode(FRAMING_MODES[index])
    logMsg("Framing: %s", M.getFramingLabel())
end

function M.isFramingVisible()
    return FRAMING.visible and M.osdValid(FRAMING.root)
end

function M.hideFraming()
    if FRAMING.built and M.osdValid(FRAMING.root) then
        pcall(function() FRAMING.root:SetVisibility(VIS_COLLAPSED) end)
    end
    FRAMING.visible = false
end

function M.showFraming()
    if State.framingMode ~= "off" then M.setFramingMode(State.framingMode) end
end

-- Re-layout the bars when the viewport size changed while a ratio is active
-- (window resize / resolution change). Cheap no-op otherwise — call from the
-- camera watchdog poller.
function M.refreshLetterbox()
    if not State.aspectRatioValue then return end
    local vw, vh = getViewportSize()
    if vw == LETTERBOX.lastVW and vh == LETTERBOX.lastVH then return end
    M.setLetterbox(State.aspectRatioValue)
end

-- Format a single OSD row text: "  Label:          [value]"
local function osdRowText(idx)
    local row = M.OSD_ROWS[idx]
    if not row then return "" end
    local ok, val = pcall(row.fmt)
    if not ok or val == nil then val = "???" end
    return string.format("  %-14s [%s]", tostring(row.label) .. ":", tostring(val))
end

local CUTSCENE_ALLOWED_ROWS = {
    ["FOV"] = true,
    ["Auto-Focus"] = true,
    ["Exposure"] = true,
    ["Aspect Ratio"] = true,
    ["Framing"] = true,
    ["Time of Day"] = true,
    ["Weather"] = true,
}

local function isRowAllowedInCurrentMode(row)
    return State.pmMode ~= "cutscene" or CUTSCENE_ALLOWED_ROWS[row.label] == true
end

function M.getActiveRows()
    local source
    if M.TABS and M.TABS[M.currentTab] then
        source = M.TABS[M.currentTab].rows
    else
        source = {}
        for i = 1, #M.OSD_ROWS do table.insert(source, i) end
    end
    local active = {}
    for _, rowIdx in ipairs(source) do
        local row = M.OSD_ROWS[rowIdx]
        if row and isRowAllowedInCurrentMode(row) then
            table.insert(active, rowIdx)
        end
    end
    return active
end

function M.updateOSD()
    if not M.osdBuilt or not M.osdValid(M.OSD_UI.root) then return end
    
    local activeRows = M.getActiveRows()
    
    -- Ensure OSD_SELECTED is within active rows
    local found = false
    for _, rowIdx in ipairs(activeRows) do
        if rowIdx == M.OSD_SELECTED then found = true; break end
    end
    if not found then M.OSD_SELECTED = activeRows[1] or 1 end
    
    for i, tb in ipairs(M.OSD_UI.rows) do
        if M.osdValid(tb) then
            local rowIdx = activeRows[i]
            if rowIdx and M.OSD_ROWS[rowIdx] then
                pcall(function() 
                    local textStr = osdRowText(rowIdx)
                    tb:SetVisibility(0) -- VIS_VISIBLE
                    tb:SetText(FText(textStr or "")) 
                end)
                local color = (rowIdx == M.OSD_SELECTED) and OSD_COLOR_ACTIVE or OSD_COLOR_NORMAL
                pcall(function() tb:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 }) end)
            else
                -- ESlateVisibility::Collapsed (1), not Hidden (2) — Hidden
                -- still occupies layout space in the VerticalBox and leaves
                -- a blank gap above the help text on inactive tabs.
                pcall(function() tb:SetVisibility(1) end) -- VIS_COLLAPSED
            end
        end
    end
    
    if M.osdValid(M.OSD_UI.title) then
        pcall(function()
            if M.TABS and M.TABS[M.currentTab] then
                local tabName = M.TABS[M.currentTab].name or ""
                M.OSD_UI.title:SetText(FText(string.format("[ PHOTO MODE ] - %s (%d/%d)", tabName, M.currentTab, #M.TABS)))
            else
                M.OSD_UI.title:SetText(FText("[ PHOTO MODE ]"))
            end
        end)
    end

    if M.osdValid(M.OSD_UI.helpLine) then
        pcall(function()
            M.OSD_UI.helpLine:SetText(FText(getOSDHelpText()))
        end)
    end
end

function M.osdSelect(delta)
    if not State.photoModeActive or not State.osdVisible then return end
    local activeRows = M.getActiveRows()
    if #activeRows == 0 then return end
    
    local currentIndex = 1
    for i, rowIdx in ipairs(activeRows) do
        if rowIdx == M.OSD_SELECTED then currentIndex = i; break end
    end
    
    currentIndex = currentIndex + delta
    if currentIndex < 1 then currentIndex = #activeRows end
    if currentIndex > #activeRows then currentIndex = 1 end
    
    M.OSD_SELECTED = activeRows[currentIndex]
    M.updateOSD()
end

function M.osdTab(delta)
    if not M.TABS or #M.TABS == 0 then return end
    if not State.photoModeActive or not State.osdVisible then return end
    
    M.currentTab = M.currentTab + delta
    if M.currentTab < 1 then M.currentTab = #M.TABS end
    if M.currentTab > #M.TABS then M.currentTab = 1 end
    
    local tabRows = M.TABS[M.currentTab].rows
    if tabRows and #tabRows > 0 then
        M.OSD_SELECTED = tabRows[1]
    end
    M.updateOSD()
end

-- OSD action: reset ALL settings to defaults (lazy require for cross-module)
-- Uses lower-level setPawnHidden/setHUDVisible directly to avoid per-toggle
-- updateOSD calls — updateOSD is called exactly once at the end.
function M.osdReset()
    if not State.photoModeActive or not State.osdVisible then return end
    if State.pmMode == "cutscene" then
        local camera = require("lib.camera")
        State.fov = State.origDefaultFOV or Config.fov_default
        camera.applyFOV()
        State.roll = 0.0
        camera.applyRoll()
        -- Reset only the cutscene-safe optics/environment controls. Do not
        -- touch pause, player/HUD state, poses, stage actors, or time of day.
        require("lib.optics").restoreAll()
        M.setFramingMode("off")
        M.updateOSD()
        logMsg("OSD: cutscene-safe settings reset")
        return
    end

    local curRow = M.OSD_ROWS[M.OSD_SELECTED]
    local label = curRow and curRow.label
    if label == "Move Fwd" or label == "Move Side" or label == "Move Height" or label == "Rotate" or label == "Face Cam" then
        local poses = require("lib.poses")
        local target = poses.getActiveTarget()
        if target then
            require("lib.spawner").resetTargetLocation(target)
            M.updateOSD()
            logMsg("OSD: target location reset to initial")
            return
        end
    end

    local camera = require("lib.camera")
    local photomode = require("lib.photomode")
    -- FOV
    State.fov = Config.fov_default
    camera.applyFOV()
    -- Roll
    State.roll = 0.0
    camera.applyRoll()
    -- Slomo
    State.timeDilation = 1.0
    photomode.applySlomo()
    -- Player visibility (unhide if hidden)
    if State.playerHidden then
        local pawn = State.playerPawn
        if not pawn or not pawn:IsValid() then
            pawn = core.findValid({"BP_PlayerCharacter_C", "DawnwalkerCharacterBase", "BP_PlayerCharacter"})
            State.playerPawn = pawn
        end
        if pawn and pawn:IsValid() then
            photomode.setPawnHidden(pawn, false)
        end
        State.playerHidden = false
    end
    -- HUD (restore if hidden)
    if not State.hudVisible then
        photomode.setHUDVisible(true)
    end
    -- Optics (restores Time of Day + Weather on SkyCreator, disables DoF/Aspect)
    require("lib.optics").restoreAll()
    M.setFramingMode("off")
    -- Poses (all targets, not just the selected one)
    require("lib.poses").resetAllPoses()
    M.updateOSD()
    logMsg("OSD: all settings reset to defaults")
end

-- OSD action: adjust selected row left/right (lazy require for cross-module)
function M.osdAdjust(delta)
    if not State.photoModeActive or not State.osdVisible then return end
    local camera = require("lib.camera")
    local photomode = require("lib.photomode")
    local rowDef = M.OSD_ROWS[M.OSD_SELECTED]
    if not rowDef then return end
    
    local label = rowDef.label
    if State.pmMode == "cutscene" and not CUTSCENE_ALLOWED_ROWS[label] then
        logMsg("Cutscene PM: OSD action '%s' disabled", label)
        return
    end
    if label == "FOV" then
        camera.adjustFOV(delta * Config.fov_step)
    elseif label == "Roll" then
        camera.adjustRoll(delta * Config.roll_step)
    elseif label == "Slow Motion" then
        photomode.adjustSlomo(delta < 0)
    elseif label == "Player" then
        photomode.toggleHidePlayer()
    elseif label == "HUD" then
        photomode.toggleHUD()
    elseif label == "Time of Day" then
        require("lib.optics").adjustTimeOfDay(delta * 0.25) -- 15 mins per click
    elseif label == "Auto-Focus" then
        if delta < 0 and State.dofEnabled then
            require("lib.optics").disableDoF()
        else
            require("lib.optics").triggerAutoFocus()
        end
    elseif label == "Exposure" then
        require("lib.optics").adjustExposure(delta * Config.exposure_step)
    elseif label == "Aspect Ratio" then
        require("lib.optics").adjustAspectRatio(delta > 0 and 1 or -1)
    elseif label == "Framing" then
        M.cycleFraming(delta > 0 and 1 or -1)
    elseif label == "Weather" then
        require("lib.optics").adjustWeather(delta > 0 and 1 or -1)
    elseif label == "Target" then
        require("lib.poses").adjustTarget(delta > 0 and 1 or -1)
    elseif label == "Pose" then
        require("lib.poses").adjustPose(delta > 0 and 1 or -1)
    elseif label == "Spawn Class" then
        require("lib.spawner").adjustNpcClass(delta > 0 and 1 or -1)
    elseif label == "Spawn NPC" then
        if delta > 0 then
            require("lib.spawner").spawnClone()
        else
            -- restore clone AnimBPs before they vanish; keeps the player's
            -- pose untouched (resetClonePoses clears clone poseState keys
            -- and resets targetIdx)
            require("lib.poses").resetClonePoses()
            require("lib.spawner").destroyAll()
        end
    elseif label == "Move Fwd" then
        local poses = require("lib.poses")
        local target = poses.getActiveTarget()
        if target then
            require("lib.spawner").moveClone(target, "fwd", delta > 0 and 1 or -1)
        end
    elseif label == "Move Side" then
        local poses = require("lib.poses")
        local target = poses.getActiveTarget()
        if target then
            require("lib.spawner").moveClone(target, "side", delta > 0 and 1 or -1)
        end
    elseif label == "Move Height" then
        local poses = require("lib.poses")
        local target = poses.getActiveTarget()
        if target then
            require("lib.spawner").moveClone(target, "height", delta > 0 and 1 or -1)
        end
    elseif label == "Rotate" then
        local poses = require("lib.poses")
        local target = poses.getActiveTarget()
        if target then
            require("lib.spawner").moveClone(target, "yaw", delta > 0 and 1 or -1)
        end
    elseif label == "Face Cam" then
        if delta > 0 then
            local poses = require("lib.poses")
            local target = poses.getActiveTarget()
            if target then
                require("lib.spawner").faceCamera(target)
            end
        end
    elseif label == "Frame Step" then
        if delta > 0 then
            require("lib.photomode").stepFrame()
        else
            require("lib.photomode").unfreeze()
        end
    end
    M.updateOSD()
end



function M.showOSD()
    dbg("OSD: showOSD called, osdBuilt=%s validRoot=%s", tostring(M.osdBuilt), tostring(M.osdValid(M.OSD_UI.root)))
    if not M.ensureOSD() then
        dbg("OSD: ensureOSD returned false")
        return
    end
    -- Update render scale dynamically if changed in config/mod menu
    if M.osdValid(M.OSD_UI.border) then
        pcall(function() M.OSD_UI.border:SetRenderScale({X = Config.osd_scale, Y = Config.osd_scale}) end)
    end
    pcall(function() M.OSD_UI.root:SetVisibility(VIS_HIT_TEST_INVISIBLE) end)
    State.osdVisible = true
    pcall(function() require("lib.input").setOSDInputCapture(true) end)
    M.updateOSD()
end

function M.hideOSD()
    if not M.osdBuilt or not M.osdValid(M.OSD_UI.root) then
        if not State.screenshotInProgress then
            pcall(function() require("lib.input").setOSDInputCapture(false) end)
        end
        return
    end
    pcall(function() M.OSD_UI.root:SetVisibility(VIS_COLLAPSED) end)
    State.osdVisible = false
    if not State.screenshotInProgress then
        pcall(function() require("lib.input").setOSDInputCapture(false) end)
    end
end

function M.toggleOSD()
    if not State.photoModeActive then return end
    if State.osdVisible then M.hideOSD() else M.showOSD() end
end

-- Clean View: toggles both OSD and game HUD simultaneously for a completely clear viewport
function M.toggleCleanView()
    if not State.photoModeActive then return end
    local photomode = require("lib.photomode")
    if State.osdVisible or State.hudVisible then
        M.hideOSD()
        photomode.setHUDVisible(false)
        logMsg("OSD: Clean View -> Hidden (OSD + HUD)")
    else
        M.showOSD()
        photomode.setHUDVisible(true)
        logMsg("OSD: Clean View -> Restored (OSD + HUD)")
    end
end

dbg("OSD: section loaded (show=%s build=%s)", tostring(M.showOSD), tostring(M.buildOSD))

return M



