-- TBOD_PhotoMode screenshot module
-- Screenshot capture (PowerShell + GetClientRect + reactive watcher + debounce)
--
-- Timing contract: the OSD is hidden first, then we wait ~500 ms so a few frames
-- render without it BEFORE PowerShell grabs the screen. A per-shot marker file
-- avoids stale-marker races. The PS script refuses to capture when the game
-- window is not foreground (Alt-Tab) and reports "SKIPPED" instead.

local core = require("lib.core")
local State = core.State
local logMsg = core.logMsg

local M = {}

local canOsExec = type(os.execute) == "function"
local lastShotTime = 0

function M.takeScreenshot()
    -- Debounce: block new screenshots until the current one finishes saving
    local now = os.clock()
    if (now - lastShotTime) < 1.0 or State.screenshotInProgress then
        if State.screenshotInProgress then
            logMsg("  Screenshot skipped (already in progress)")
        end
        return
    end
    lastShotTime = now
    State.screenshotInProgress = true
    core.SCREENSHOT_COUNT = core.SCREENSHOT_COUNT + 1

    local baseFileName = "dw_" .. os.date("%Y%m%d_%H%M%S") .. "_" .. tostring(core.SCREENSHOT_COUNT) .. ".png"
    logMsg("Taking screenshot (resolving OneDrive/Pictures path automatically)...")

    if not canOsExec then
        logMsg("  ERROR: os.execute unavailable. Use Win+PrintScreen or Steam F12.")
        State.screenshotInProgress = false
        return
    end

    -- Screenshot Guard: hide OSD before capture
    local osd = require("lib.osd")
    local osdWasVisible = false
    local framingWasVisible = osd.isFramingVisible() or State.framingMode ~= "off"
    if osd.osdBuilt and osd.osdValid(osd.OSD_UI.root) and State.osdVisible then
        osdWasVisible = true
        pcall(function() osd.hideOSD() end)
    end
    if framingWasVisible then pcall(function() osd.hideFraming() end) end

    local function restoreOverlayState()
        if not State.photoModeActive then return end
        if osdWasVisible then pcall(function() osd.showOSD() end) end
        if framingWasVisible and State.framingMode ~= "off" then
            pcall(function() osd.showFraming() end)
        end
    end

    local tmpDir = os.getenv("TEMP") or os.getenv("TMP") or "."
    local tmpPs1 = tmpDir .. "\\dw_shot_" .. tostring(core.SCREENSHOT_COUNT) .. ".ps1"
    local tmpOut = tmpDir .. "\\dw_last_screenshot_" .. tostring(core.SCREENSHOT_COUNT) .. ".txt"

    -- Launch after a short delay so the frame without OSD actually reaches the
    -- screen before CopyFromScreen runs.
    local function launch()
        local f = io.open(tmpPs1, "w")
        if not f then
            logMsg("  ERROR: cannot write temp script")
            State.screenshotInProgress = false
            restoreOverlayState()
            return
        end

        f:write(string.format([[
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
}
"@
$picFolder = [Environment]::GetFolderPath('MyPictures')
$dir = Join-Path $picFolder "Dawnwalker"
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$savePath = Join-Path $dir "%s"

Add-Type -AssemblyName System.Drawing
$proc = Get-Process -Name "Dawnwalker*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($proc -and $proc.MainWindowHandle -ne [IntPtr]::Zero) {
    $hwnd = $proc.MainWindowHandle
    if ([Win32]::GetForegroundWindow() -ne $hwnd) {
        Set-Content -Path "%s" -Value "SKIPPED" -Encoding UTF8
        exit
    }
    $rect = New-Object Win32+RECT
    $pt = New-Object Win32+POINT
    [Win32]::GetClientRect($hwnd, [ref]$rect)
    [Win32]::ClientToScreen($hwnd, [ref]$pt)
    $w = $rect.Right - $rect.Left
    $h = $rect.Bottom - $rect.Top
    if ($w -gt 100 -and $h -gt 100) {
        $b = New-Object System.Drawing.Bitmap($w, $h)
        $g = [System.Drawing.Graphics]::FromImage($b)
        $g.CopyFromScreen($pt.X, $pt.Y, 0, 0, (New-Object System.Drawing.Size($w, $h)))
        $b.Save($savePath)
        $g.Dispose(); $b.Dispose()
        Set-Content -Path "%s" -Value $savePath -Encoding UTF8
        exit
    }
}
Set-Content -Path "%s" -Value "SKIPPED" -Encoding UTF8
]], baseFileName, tmpOut, tmpOut, tmpOut))
        f:close()

        os.execute('start "" /B powershell -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' .. tmpPs1 .. '"')

        -- Reactive watcher: poll for the marker file before restoring OSD
        local attempts = 0
        local function checkDone()
            attempts = attempts + 1
            local checkF = io.open(tmpOut, "r")
            if checkF then
                local finalPath = checkF:read("*l")
                checkF:close()
                if finalPath and finalPath ~= "" then
                    if finalPath == "SKIPPED" then
                        logMsg("  Screenshot skipped (game window not focused)")
                    else
                        -- Try to get file size for log
                        local imgF = io.open(finalPath, "rb")
                        local sizeStr = ""
                        if imgF then
                            local sz = imgF:seek("end")
                            imgF:close()
                            if sz then sizeStr = string.format(" (%.1f MB)", sz / (1024 * 1024)) end
                        end
                        logMsg("  Screenshot saved: %s%s", finalPath, sizeStr)
                    end
                    State.screenshotInProgress = false
                    restoreOverlayState()
                    os.execute('del "' .. tmpPs1 .. '" 2>NUL')
                    os.execute('del "' .. tmpOut .. '" 2>NUL')
                    return
                end
            end

            if attempts < 40 then
                pcall(function() core.delayGameThread(150, checkDone) end)
            else
                logMsg("  Screenshot polling timed out")
                State.screenshotInProgress = false
                restoreOverlayState()
                os.execute('del "' .. tmpPs1 .. '" 2>NUL')
                os.execute('del "' .. tmpOut .. '" 2>NUL')
            end
        end

        pcall(function() core.delayGameThread(200, checkDone) end)
    end

    local okDelay, scheduled = pcall(function() return core.delayGameThread(500, launch) end)
    if not okDelay or scheduled == false then launch() end
end

return M
