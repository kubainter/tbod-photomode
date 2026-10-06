-- TBOD_PhotoMode input module
-- Input isolation: DisableInput on player pawn, FlushPressedKeys, and a
-- startup fail-safe to restore input after a mod crash.
--
-- Hub menu actions (IA_Hub_*) are bound at the LocalPlayer/Controller level,
-- NOT on the pawn's InputComponent — DisableInput blocks character actions
-- but not menus; those are caught by the camera watchdog.

local core = require("lib.core")
local State = core.State
local Subsystem = core.Subsystem
local logMsg = core.logMsg

local M = {}

-- Flush pressed keys so no "stuck key" state survives the input transition.
-- Primary: native DogwoodBlueprintFunctionLibrary:FlushPressedKeysNextTick
-- (verified present in this game's reflection; flushes on the next tick).
-- Fallback: APlayerController::FlushPressedKeys() (stripped in some shipping
-- builds — kept inside pcall so it silently no-ops if unavailable).
local function flushKeys(pc)
    local lib = core.findStatic("/Script/DogwoodUtil.Default__DogwoodBlueprintFunctionLibrary")
    local usedLib = false
    if lib then
        usedLib = pcall(function() lib:FlushPressedKeysNextTick(pc) end)
    end
    if not usedLib then
        pcall(function() pc:FlushPressedKeys() end)
    end
end

local function resolvePlayerPawn()
    local pawn = State.playerPawn
    if pawn and pawn:IsValid() then return pawn end
    local pc = Subsystem.playerController()
    if pc and pc:IsValid() then
        local okP, p = pcall(function() return pc.Pawn or pc.Character end)
        if okP and p and p:IsValid() then
            State.playerPawn = p
            return p
        end
    end
    -- Last resort: world scan. Only trust it if the found pawn is actually
    -- player-controlled — otherwise we might grab a stray character while the
    -- controller is mid-transition and report a false "isolated" state.
    local found = core.findValid({"BP_PlayerCharacter_C", "DawnwalkerCharacterBase", "BP_PlayerCharacter"})
    if found and found:IsValid() then
        local okCtrl, isPlayer = pcall(function() return found:IsPlayerControlled() end)
        if okCtrl then
            return isPlayer and found or nil
        end
        return found -- IsPlayerControlled unavailable: keep legacy behavior
    end
    return nil
end

local function setDialogueWidgetsEnabled(enabled)
    if enabled then
        for _, entry in ipairs(State.disabledDialogueWidgets) do
            local widget = entry.widget
            if widget and widget:IsValid() then
                pcall(function() widget:SetIsEnabled(entry.wasEnabled) end)
            end
        end
        State.disabledDialogueWidgets = {}
        return
    end

    local okCamera, camera = pcall(require, "lib.camera")
    if not okCamera or not camera or not camera.getActiveDialogueWidget then return end
    local widget = camera.getActiveDialogueWidget()
    if not (widget and widget:IsValid()) then return end

    for _, entry in ipairs(State.disabledDialogueWidgets) do
        if entry.widget == widget then return end
    end

    local okEnabled, wasEnabled = pcall(function() return widget:IsEnabled() end)
    if not okEnabled or wasEnabled == false then return end
    local okDisable = pcall(function() widget:SetIsEnabled(false) end)
    if okDisable then
        table.insert(State.disabledDialogueWidgets, {widget = widget, wasEnabled = wasEnabled})
        logMsg("  Dialogue input disabled while OSD is visible")
    end
end

local function setQuickslotContainerActive(enable)
    if not State.disabledQuickslotContainers then State.disabledQuickslotContainers = {} end

    if enable then
        local restored = 0
        for _, entry in ipairs(State.disabledQuickslotContainers) do
            local c = entry.container
            if c and c:IsValid() then
                -- NamedToggleableContainer uses SetShown(true) to restore its display state
                pcall(function() c:SetShown(true) end)
                -- Force visibility to 0 (Visible) or entry.origVis if not collapsed
                local targetVis = (entry.origVis ~= nil and entry.origVis ~= 2) and entry.origVis or 0
                pcall(function() c:SetVisibility(targetVis) end)
                pcall(function() c:SetIsEnabled(true) end)
                restored = restored + 1
            end
        end
        State.disabledQuickslotContainers = {}

        -- Failsafe: ensure WBP_GameHUD QuickslotContainer is explicitly shown and visible
        local hud = core.findValid({"WBP_GameHUD_C", "WBP_GameHUD"})
        if hud and hud:IsValid() then
            local okQ, qc = pcall(function() return hud.QuickslotContainer end)
            if okQ and qc and qc:IsValid() then
                pcall(function() qc:SetShown(true) end)
                pcall(function() qc:SetVisibility(0) end)
                pcall(function() qc:SetIsEnabled(true) end)
                restored = restored + 1
            end
            if hud.WidgetTree and hud.WidgetTree:IsValid() then
                local okTreeQ, treeQC = pcall(function() return hud.WidgetTree.QuickslotContainer end)
                if okTreeQ and treeQC and treeQC:IsValid() then
                    pcall(function() treeQC:SetShown(true) end)
                    pcall(function() treeQC:SetVisibility(0) end)
                    pcall(function() treeQC:SetIsEnabled(true) end)
                    restored = restored + 1
                end
            end
        end

        -- Failsafe: guarantee all Quickslot-related UserWidgets are un-collapsed
        if not State.cachedUserWidgets then
            local okWidgets, widgets = pcall(function() return FindAllOf("UserWidget") end)
            State.cachedUserWidgets = (okWidgets and widgets) and widgets or {}
        end

        for _, w in ipairs(State.cachedUserWidgets) do
            if w and w:IsValid() then
                local fullName = ""
                pcall(function() fullName = w:GetFullName() end)
                if fullName:find("Quickslot", 1, true) then
                    pcall(function()
                        if w.Visibility == 2 then
                            w:SetVisibility(0)
                        end
                        w:SetIsEnabled(true)
                    end)
                end
            end
        end

        if restored > 0 then
            logMsg("  Quickslot container restored (%d elements)", restored)
        end
        return
    end

    -- If containers are already tracked and suppressed, re-enforce suppression without re-snapshotting
    if #State.disabledQuickslotContainers > 0 then
        for _, entry in ipairs(State.disabledQuickslotContainers) do
            local c = entry.container
            if c and c:IsValid() then
                pcall(function() c:SetShown(false) end)
                pcall(function() c:SetVisibility(2) end) -- 2 = Collapsed
                pcall(function() c:SetIsEnabled(false) end)
            end
        end
        return
    end

    local containers = {}

    -- 1. Direct path via WBP_GameHUD_C
    local hud = core.findValid({"WBP_GameHUD_C", "WBP_GameHUD"})
    if hud and hud:IsValid() then
        local okQ, qc = pcall(function() return hud.QuickslotContainer end)
        if okQ and qc and qc:IsValid() then table.insert(containers, qc) end
        if hud.WidgetTree and hud.WidgetTree:IsValid() then
            local okTreeQ, treeQC = pcall(function() return hud.WidgetTree.QuickslotContainer end)
            if okTreeQ and treeQC and treeQC:IsValid() then table.insert(containers, treeQC) end
        end
    end

    -- Optimization: Cache the lists if not already cached.
    -- These UI elements rarely respawn during a single Photo Mode session.
    if not State.cachedToggleableContainers then
        local okAll, list = pcall(function() return FindAllOf("NamedToggleableContainer") end)
        State.cachedToggleableContainers = (okAll and list) and list or {}
    end

    -- 2. Fallback: world search for NamedToggleableContainer
    for _, c in ipairs(State.cachedToggleableContainers) do
        if c and c:IsValid() then
            local name = ""
            pcall(function() name = c:GetFullName() end)
            if name:find("QuickslotContainer") then
                local already = false
                for _, existing in ipairs(containers) do
                    if existing == c then already = true break end
                end
                if not already then table.insert(containers, c) end
            end
        end
    end

    if not State.cachedBlankButtons then
        local okBtns, btnList = pcall(function() return FindAllOf("UDWW_Button_Blank_C") end)
        State.cachedBlankButtons = (okBtns and btnList) and btnList or {}
    end

    -- 3. Also grab any button widgets matching Quickslot
    for _, btn in ipairs(State.cachedBlankButtons) do
        if btn and btn:IsValid() then
            local bName = ""
            pcall(function() bName = btn:GetFullName() end)
            if bName:find("Quickslot") then
                table.insert(containers, btn)
            end
        end
    end

    for _, c in ipairs(containers) do
        local already = false
        for _, entry in ipairs(State.disabledQuickslotContainers) do
            if entry.container == c then already = true break end
        end
        if not already then
            local origVis = 0
            local origEnabled = true
            pcall(function() origVis = c.Visibility end)
            pcall(function() origEnabled = c:IsEnabled() end)
            pcall(function() c:SetShown(false) end)
            pcall(function() c:SetVisibility(2) end) -- 2 = Collapsed
            pcall(function() c:SetIsEnabled(false) end)
            table.insert(State.disabledQuickslotContainers, {
                container = c,
                origVis = tonumber(tostring(origVis)) or 0,
                origEnabled = origEnabled,
            })
        end
    end

    if #State.disabledQuickslotContainers > 0 then
        logMsg("  Quickslot container collapsed & disabled for Photo Mode (%d elements)", #State.disabledQuickslotContainers)
    else
        logMsg("  WARN: Quickslot container not found")
    end
end

local function setQuickslotIMCActive(enable)
    local pc = Subsystem.playerController()
    if not (pc and pc:IsValid()) then return end
    local lib = core.findStatic("/Script/Engine.Default__SubsystemBlueprintLibrary")
    if not lib then return end
    local cls = core.findStatic("/Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem")
    if not cls then return end
    local subsys = nil
    pcall(function() subsys = lib:GetLocalPlayerSubSystemFromPlayerController(pc, cls) end)
    if not (subsys and subsys:IsValid()) then return end

    if not State.removedMappingContexts then State.removedMappingContexts = {} end

    if enable then
        for _, entry in ipairs(State.removedMappingContexts) do
            local imc = entry.imc
            if imc and imc:IsValid() then
                pcall(function() subsys:AddMappingContext(imc, entry.priority or 0, {}) end)
            end
        end
        State.removedMappingContexts = {}
        return
    end

    local imcPaths = {
        "/Game/_Dawnwalker/Player/Input/MappingContexts/IMC_HUD.IMC_HUD",
        "/Game/_Dawnwalker/Player/Input/MappingContexts/IMC_Hub_ActiveAbilities_QuickslotBindOverlay.IMC_Hub_ActiveAbilities_QuickslotBindOverlay",
    }
    for _, path in ipairs(imcPaths) do
        local imc = core.findStatic(path)
        if imc and imc:IsValid() then
            local okHas, has = pcall(function() return subsys:HasMappingContext(imc) end)
            if okHas and has then
                local okRem = pcall(function() subsys:RemoveMappingContext(imc, {}) end)
                if okRem then
                    table.insert(State.removedMappingContexts, {imc = imc, priority = 0})
                    logMsg("  Removed mapping context %s for Photo Mode", path:match("([^/]+)$") or path)
                end
            end
        end
    end
end

-- Force the controller into game-only routing while the mod OSD is visible.
-- This prevents CommonUI/dialog widgets from consuming keyboard or gamepad
-- navigation events while the OSD owns them. The active dialogue widget is
-- also disabled because CommonUI can process Enhanced Input independently of
-- the PlayerController input mode.
function M.setOSDInputCapture(capture)
    local pc = Subsystem.playerController()
    if not (pc and pc:IsValid()) then return false end
    if capture == State.osdInputCaptured then
        if capture then setDialogueWidgetsEnabled(false) end
        return true
    end

    local lib = core.findStatic("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not lib then
        logMsg("  OSD input capture unavailable: WidgetBlueprintLibrary not found")
        return false
    end

    local ok = false
    if capture then
        -- bConsumeCaptureMouseDown = false so the first mouse click is NOT swallowed
        ok = pcall(function() lib:SetInputMode_GameOnly(pc, false) end)
        if ok then
            State.osdInputCaptured = true
            setDialogueWidgetsEnabled(false)
            flushKeys(pc)
            logMsg("  OSD input capture ENABLED (dialog/gamepad UI blocked)")
        end
    else
        -- GameAndUI is the safest public restore available here: it returns
        -- control to gameplay while allowing a dialogue/CommonUI layer to
        -- receive input again when the OSD is hidden.
        ok = pcall(function()
            lib:SetInputMode_GameAndUIEx(pc, nil, 0, true, true)
        end)
        setDialogueWidgetsEnabled(true)
        if ok then
            State.osdInputCaptured = false
            flushKeys(pc)
            logMsg("  OSD input capture DISABLED")
        end
    end
    return ok
end

-- Game input suppression:
-- NOTE: We do NOT use SetGameInputBlockerActive or AddPawnInputBlocker on the PC,
-- because in Dawnwalker that swaps to BlankInputComponent and blocks input on ALL pawns,
-- which completely kills mouse look and free cam on APhotoCameraActor (regression TIK-007).
-- Character actions are safely isolated by pawn:DisableInput(pc) on BP_PlayerCharacter_C alone.
local function setNativeInputBlockers(pc, block)
    if not (pc and pc:IsValid()) then return end

    -- Ensure PlayerController does NOT ignore move/look input, so Photo Mode camera
    -- flight and mouse look work unrestricted.
    pcall(function()
        pc:ResetIgnoreInputFlags()
    end)
end

-- enable=true  -> pawn:DisableInput(pc) + native input blockers + FlushPressedKeys
-- enable=false -> pawn:EnableInput(pc)  + clear blockers       + FlushPressedKeys
function M.isolateGameInput(enable)
    local pc = Subsystem.playerController()
    if not pc or not pc:IsValid() then
        logMsg("  Input isolation: PlayerController not found")
        return false
    end

    if enable then
        local pawn = resolvePlayerPawn()
        if not pawn or not pawn:IsValid() then
            logMsg("  Input isolation: player pawn not found")
            return false
        end
        pcall(function() pawn:DisableInput(pc) end)
        setNativeInputBlockers(pc, true)
        setQuickslotContainerActive(false)
        setQuickslotIMCActive(false)
        flushKeys(pc)
        State.isolatedPawn = pawn
        State.gameInputIsolated = true
        logMsg("  Input isolation ENABLED (pawn disabled, native UI blocker set, quickslots blocked, keys flushed)")
    else
        -- Re-enable the SAME pawn that was disabled, not whatever pc.Pawn points
        -- to now. After DeactivatePhotomode the controller may still reference the
        -- (dying) photo camera for a frame, so resolvePlayerPawn() could otherwise
        -- target the wrong actor and leave the real player pawn softlocked.
        local target = State.isolatedPawn
        if not (target and target:IsValid()) then target = resolvePlayerPawn() end
        if target and target:IsValid() then
            pcall(function() target:EnableInput(pc) end)
        end
        setNativeInputBlockers(pc, false)
        setQuickslotContainerActive(true)
        setQuickslotIMCActive(true)
        flushKeys(pc)
        State.isolatedPawn = nil
        State.gameInputIsolated = false
        logMsg("  Input isolation DISABLED (pawn restored, quickslots restored, native blockers cleared)")
    end
    return true
end

-- Fail-safe (mod startup / Restart Mod): recover a pawn left input-disabled
-- by a crashed PM session — but only when safe: during a cutscene/menu
-- (CanActivatePhotomode == false) the game disabled input deliberately.
function M.recoverInputOnStart()
    local pm = Subsystem.photoMode()
    -- If native PhotoMode is still active after a restart, close it natively —
    -- photomode.exitPhotoMode() would no-op here (fresh State early-returns).
    if pm and pm:IsValid() and core.isPhotomodeActiveNative() then
        logMsg("Startup recovery: native PhotoMode active, forcing clean exit")
        pcall(function() pm:DeactivatePhotomode() end)
        -- Pin the real player pawn so isolateGameInput(false) does not resolve
        -- to the (dying) PhotoCameraActor via pc.Pawn right after deactivation.
        local pawn = core.findValid({"BP_PlayerCharacter_C", "DawnwalkerCharacterBase", "BP_PlayerCharacter"})
        if pawn and pawn:IsValid() then
            State.isolatedPawn = pawn
        end
        M.isolateGameInput(false)
        return
    end

    -- If the game currently forbids PhotoMode (cutscene, menu, dialogue), the
    -- game itself owns the input state — do not interfere.
    if pm and pm:IsValid() then
        local okCan, canAct = pcall(function() return pm:CanActivatePhotomode() end)
        if okCan and not canAct then
            logMsg("Startup recovery skipped (game in non-photomode state / cutscene)")
            return
        end
    end

    local pc = Subsystem.playerController()
    if not pc or not pc:IsValid() then return end
    -- Prefer the pawn we actually disabled (isolatedPawn) over a fresh resolve,
    -- for symmetry with isolateGameInput(false).
    local pawn = State.isolatedPawn
    if not (pawn and pawn:IsValid()) then pawn = resolvePlayerPawn() end
    if not pawn or not pawn:IsValid() then return end
    pcall(function() pawn:EnableInput(pc) end)
    setNativeInputBlockers(pc, false)
    setQuickslotContainerActive(true)
    setQuickslotIMCActive(true)
    State.isolatedPawn = nil
    State.gameInputIsolated = false
end

M.setQuickslotContainerActive = setQuickslotContainerActive

return M
