# Changelog - TBOD Photo Mode

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.6.2] - 2026-10-05

### Added
- **Contextual Target Displacement Reset on Move Rows**: Pressing `R` (or Gamepad `Y / Triangle`) while selecting `Move Fwd`, `Move Side`, `Move Height`, `Rotate`, or `Face Cam` in the STAGE tab now cleanly resets only the target's position and rotation back to starting coordinates, without resetting camera, FOV, time of day, or weather settings.

### Fixed
- **Camera Speed Spikes on FOV & DoF Adjustments**: Decoupled flight camera speed scaling from FOV modulation and eliminated redundant FOV calls that caused sudden acceleration or camera freezing when modifying Field of View or Depth of Field aperture (TIK-013).
- **Interior Lighting Blowout on Player Movement**: Moving or posing the player character (`Target = Player`) inside enclosed structures (tents, caves, indoor rooms) no longer drops interior trigger volume overlaps or causes blinding light blowouts. Capsule query overlaps (`QueryOnly` with static/dynamic/pawn overlaps) are preserved during movement, keeping ambient post-process lighting intact (TIK-014).

---

## [1.6.1] - 2026-09-28

### Fixed
- **Keyboard & Mouse Action Bleed**: Removed gameplay-level Enhanced Input hooks (`IA_Sprint`, `IA_Focus`) that caused sprinting (`Shift`) + target lock / focus (`MMB`/`Tab`) on Keyboard & Mouse to inadvertently trigger the `L3+R3` gamepad activation chord. Gamepad stick clicks are now detected strictly via direct hardware polling (`Gamepad_LeftThumbstick`, `Gamepad_RightThumbstick`).
- **Gamepad R3 HUD Toggle in Photo Mode**: Routed combat/focus actions via EventBridge strictly during active Photo Mode sessions with device verification (`isGamepadActive`) and a 250ms debounce, ensuring clicking the right thumbstick (R3) reliably toggles HUD visibility on gamepads without conflicting with mouse buttons.
- **Guarded D-Pad Quickslots in Photo Mode**: Added active input device checks to ensure keyboard number keys (`1-4`) do not trigger D-Pad OSD navigation actions while in Photo Mode.

---

## [1.6.0] - 2026-09-28

### Added
- **Full Native Gamepad Support**:
  - **Triple-Tap L3 Activation**: Enter Photo Mode directly from normal gameplay with 3 quick clicks of the left thumbstick (within a 0.45s window). Hardware-direct detection on `Gamepad_LeftThumbstick` immune to sprint conflicts (holding L3 to run cancels the tap counter).
  - **Complete D-Pad OSD Navigation**: Full parameter selection (Up/Down) and value adjustment (Left/Right) with smooth auto-repeat (350ms delay, 100ms interval).
  - **Quickslot Suppression**: Native quickslot / potion actions on D-Pad are seamlessly suppressed during OSD navigation and 100% cleanly restored upon Photo Mode exit (preserving PM Statelessness).
  - **Full Gamepad Action Layout**:
    - `A / Cross`: Confirm action / Toggle Pause / Freeze world time
    - `B / Circle` & `Menu / Start`: Instant exit back to full gameplay with clean state restoration
    - `X / Square`: Capture borderless screenshot (auto-hides OSD)
    - `Y / Triangle`: Reset all settings to defaults
    - `LB / RB`: Switch OSD tabs (CAMERA / DIRECTING / STAGE)
    - `LT / RT`: Analog vertical flight (LT = Down, RT = Up)
    - `L3 (Click)`: Quick reset FOV to default (90°)
    - `R3 (Click)`: Toggle HUD visibility
    - `View / Select`: Toggle OSD visibility
- **Dynamic OSD Legend**: OSD footer automatically detects whether gamepad or keyboard was used and displays clean, user-friendly button names (`[D-Pad]`, `[LB/RB]`, `[A / Cross]`, `[B / Circle]`, etc.) instead of raw engine names (`Gamepad_FaceButton_Bottom`).
- **Cutscene & Dialogue Photo Mode (`force_cutscene_pm`)**: Opt-in Photo Mode during cinematics and dialogues. Pauses all playing sequence players (`CinematicNode`, `Dialogue`, `Event`, `Flow`, `Template`, `Level` classes), stops picture, sound, and camera cuts together, and cleanly resumes them with full state preservation on exit.
- **Mod Menu Integration for Cutscenes**: Added `force_cutscene_pm` toggle in *Dawnwalker Mod Menu* under the Photo Mode settings group.

### Changed
- **Controller Activation**: Upgraded default gamepad entry from chorded `L3 + R3` to **Triple-Tap L3** (Left Stick click) with sprint conflict immunity (holding L3 to run cancels the tap counter), providing a rapid one-thumb shortcut. `L3 + R3` simultaneous press remains supported as an alternative.
- **OSD Footer Legend**: Completely overhauled hotkey legend rendering to cleanly separate keyboard primary key displays from gamepad prompts. Internal engine input tokens (e.g. `Gamepad_FaceButton_Bottom`, `Gamepad_RightShoulder`) are no longer exposed in the UI.
- **Configuration & Defaults**: Updated `photo_mode.ini` and `mod_settings.ini` to version 1.6.0 with documentation for cutscene photo mode and controller mappings.

### Fixed
- **Camera Roll 180° Gimbal Inversion**: Fixed Unreal Engine `FRotator` Euler angle ambiguity where adjusting or resetting camera roll could flip pitch/yaw and invert the camera drone upside down.

### Notes
- **Photo Mode Statelessness**: All gamepad input overrides, quickslot suppressions, camera pitch modifications, and cutscene sequence pauses are strictly scoped to the Photo Mode session. Exiting Photo Mode cleanly and completely restores gameplay and cinematics with zero persistent side effects.

---

## [1.5.5] - 2026-09-20

### Added
- **Move the Real Player**: The STAGE directing controls (Move Fwd/Side/Height, Rotate, Face Cam) now work on the real player (Target = Player) — position the dressed, posed Coen directly, no clone needed. On the first move, collision is disabled, gravity is zeroed and the movement mode switches to Flying (Height works); the original position/rotation/collision/gravity/movement state is fully restored on every exit path (TIK-008).
- **Full Male Pose Library for Coen**: The Player target gets the union of the coen and male pose libraries — the poses spawned characters had but Coen didn't are now available on the player.
- **Expanded Spawn Roster**: New story NPC classes — Bakhir, Xanthe, Leonica, Esme, Vladimir, Vicho, Mihai, Neberu, Lunka.

### Fixed
- **CRITICAL — Save-Load Crash (World Leaks)**: Fixed `Fatal world leaks detected` when loading a save after using Photo Mode. Spawned weapon actors and components could survive teardown as uncollectable garbage (Async GC flag); all spawned actors/components are now detached and destroyed on the game thread, with a forced GC pass after teardown (TIK-008).
- **Watchdog Map Detection**: The Auto-Exit Watchdog now detects the in-game map and other GameHub screens (they live on `GameLayer`/`GameOverlayLayer`, which weren't monitored) — Photo Mode cleanly auto-exits instead of leaving a broken state.

### Changed
- **Clone Weapons**: Spawned NPC weapons are now drawn via the game's own sheathed-weapon component instead of separately spawned weapon actors — part of the world-leak fix; the weapon returns to the sheath when the pose doesn't need it.

### Removed
- **Coen (Clone)** from the Spawn Class list — the game's modular appearance pipeline cannot be replicated for the player class from a script (garments spawn asynchronously, use incompatible skeletons, and never received the player's full outfit). Use **Target = Player** instead: it is already dressed and fully posable/movable.

---

## [1.5.0] - 2026-09-18

### Added
- **Stage Director**: Spawn NPC clones with family-aware class selection (Coen, townsfolk, soldiers, bandits and more) and direct them from the OSD STAGE tab — Move Fwd/Side/Height, Rotate, Face Cam.
- **Pose System**: Apply animation poses from the game's own libraries (male/female/child sets) to spawned clones or the player via the Target/Pose OSD rows.
- **Authentic Hand Props**: Pose-accurate props attached as `UStaticMeshComponent`s to the game's own `prop_l`/`prop_r`/`socket_weapon_r` sockets — bread, ceramic bottle, hammer + stake, large wooden spoon with food, closed book. Assets traced from real game sequences (e.g. `DIS_feedingEsme_Long`, `DIS_sq719_boardingWindows`).
- **Frame Step**: Advance the frozen world one frame at a time (OSD DIRECTING tab).
- **OSD Tabs**: CAMERA / DIRECTING / STAGE grouping navigated with PageUp/PageDown.
- **Gamepad Shortcuts**: A/Cross world-freeze, B/Circle screenshot, LB/RB vertical camera — all gated to Photo Mode; D-Pad OSD navigation and View/Back OSD toggle. Camera flight itself uses the game's native Photo Mode Enhanced Input mappings.
- **`pause_on_enter`**: Auto-freeze world time on Photo Mode entry (INI + Dawnwalker Mod Menu toggle), like built-in photo modes in other games. Enabled by default; set `0` to keep the world running as in v1.4.x.

### Changed
- **Freeze key remapped F11 → F2** (conflict with UE4SS HotReload default bind — TIK-002).

---

## [1.4.0] - 2026-09-12

### Added
- **Input Isolation ("Shield")**: While Photo Mode is active, character-bound actions (movement, combat, jump, interact) are disabled via `pawn:DisableInput()` so stray keypresses cannot disturb the shot. The photo camera retains full control via its own `InputComponent`. Configurable via `enable_input_isolation`.
- **Auto-Exit Watchdog ("Ejector")**: A 400ms poller watches the `ViewTarget` and the `WBP_UIFrontend` CommonUI layer stacks (`GameMenuLayer`, `GameMenuTutorialLayer`, `MenuLayer`, `ModalLayer`). When the game steals the camera or pushes a menu widget (map, inventory, journal, dialogs) it performs a clean, fully-restored exit instead of leaving Photo Mode in a broken state. Configurable via `auto_exit_on_view_change`.
- **Startup Fail-Safe**: On mod load / restart, the mod force-restores player input to recover from a possible softlock left behind by an earlier crash.
- **Unlocked Vertical Pitch (-89.9° to +89.9°)**: Unlocked the full vertical viewing angle on `PlayerCameraManager` so you can look directly straight up and straight down without hitting artificial pitch clamps (TIK-001).
- **Mod Menu toggles**: `Input Isolation` and `Auto-Exit Watchdog` exposed in the *Dawnwalker Mod Menu* under a new `Input` group.

### Fixed
- **Mouse Mode Camera Drift**: Fixed a bug where moving the mouse in Hybrid Mouse Mode (interactive OSD) also rotated the photo camera. Camera look is driven by Enhanced Input (`IA_Photo_Look`), which ignores `PlayerController:SetIgnoreLookInput`. The `GetCameraView` hook now freezes the camera rotation (pitch/yaw) while interactive mode is on — mouse steers the cursor only, WASD flight and Roll adjustment remain live, and no rotation snap occurs on exit.
- **Mouse Cursor Leak on Exit**: Fixed `toggleOSDInteraction` early-returning during Photo Mode exit (OSD already hidden), which left `bShowMouseCursor` and `SetIgnoreLookInput` stuck in the mouse-mode state during normal gameplay. Leaving interactive mode is now always allowed; entering is still state-gated.
- **Input Restore Symmetry**: `EnableInput` now targets the exact pawn that was disabled (`State.isolatedPawn`), instead of re-resolving `pc.Pawn` which could transiently point at the dying `PhotoCameraActor` right after `DeactivatePhotomode`.

### Notes
- Opening inventory/map/journal still triggers the game's own UI (these are Hub-level Enhanced Input actions bound on the controller, not the pawn, so `DisableInput` cannot suppress them). The auto-exit watchdog ensures the camera and player are cleanly restored when this happens.
- Requires UE4SS v3.0.1+.

---

## [1.3.0] - 2026-09-12

### Changed
- **Modular Architecture**: Completely refactored `main.lua` (1400+ lines) into library modules under `Scripts/lib/` (`core`, `keybinds`, `osd`, `camera`, `photomode`, `screenshot`) plus a slim `main.lua` entrypoint (~100 lines). This vastly improves maintainability and paves the way for upcoming new features.
- **Hot-Reload Safety**: Implemented automatic `package.loaded` cache clearing on mod restart, ensuring seamless development and testing of submodules.
- **Lazy Cross-Module Dependencies**: Modules use lazy `require` inside functions (not setter injection) to resolve circular dependencies cleanly at call time.
- **Subsystem Caching**: `DogwoodPhotomodeSubsystem` and `PhotoCameraActor` references are cached in shared `State` and validated with `:IsValid()` on each access, with fallback `FindFirstOf` discovery — eliminates per-frame object scans in the `GetCameraView` hook.
- **Dynamic Config Reloading**: Changes made in `photo_mode.ini` or via *Dawnwalker Mod Menu* are reloaded dynamically upon entering Photo Mode without restarting the game.
- **Dynamic OSD Legend**: The OSD now includes an auto-sizing help legend at the bottom displaying all current hotkeys (Screenshot, Freeze Time, Toggle HUD, etc.) loaded directly from your config.

### Fixed
- **OSD Scale Clipping**: Fixed an issue where increasing the OSD scale via Mod Menu would push the UI off the left side of the screen. The UI now scales properly from the top-left anchor.
- **Default FOV Initialization**: Fixed a bug where changing `Default FOV` in the Mod Menu didn't apply as the starting FOV when entering Photo Mode.

---

## [1.2.1] - 2026-09-11 (Hotfix)

### Added
- **OSD Scale Configuration**: Added `osd_scale = 1.5` to `photo_mode.ini` to universally enlarge the OSD interface for 1440p and 4K displays.
- **Dawnwalker Mod Menu Integration**: Added `mod_settings.ini` to support in-game pause menu UI integration. Players can now adjust FOV, Camera Speed, Vertical Speed, OSD Scale, and OSD visibility directly from the game's menu if the *Dawnwalker Mod Menu* mod is installed.

### Fixed
- **Camera Drone Visibility**: The physical `PhotoCameraActor` mesh is now explicitly hidden (`SetActorHiddenInGame`). This prevents the camera model from blocking the screen if a gamepad user accidentally triggers the native "reset camera to player" function.

---

## [1.2.0] - 2026-09-10

### Added
- **Dynamic On-Screen Display (OSD)**: Native in-engine UMG overlay displaying real-time parameters for FOV, Camera Roll, Slow Motion, Player visibility, and HUD status.
- **Streamlined Arrow Navigation**: Unified camera parameter adjustments under arrow keys (`Up`/`Down` select row, `Left`/`Right` adjust value, `R` reset all to defaults).
- **OSD Key Toggle**: `F1` toggles the OSD visibility in Photo Mode, configurable via `osd_toggle_key` in `photo_mode.ini`.
- **Screenshot Guard**: Automatically hides the OSD for clean screenshot capture and restores it once the file is committed to disk.
- **HUD Guard**: Added filter to prevent the `H` (clean HUD) shortcut from hiding the Photo Mode OSD menu.
- **INI Configuration Updates**: Added `osd_show_on_enter` and `osd_reset_key` options to `photo_mode.ini`.

### Changed
- **Unified Controls**: Eliminated keyboard clutter by moving individual tuning hotkeys (separate roll/slomo/FOV increment keys) into the intuitive OSD interface while preserving dedicated quick-action keys (`P`, `H`, `F11`, `F3`, `E`/`Q`).

---

## [1.1.1] - 2026-09-10 (Hotfix)

### Fixed
- **Dialogue Camera Framing**: Fixed dialogue cameras (`DialogueCameraActor`, `DialogueCameraComponent`) having their FOV distorted to 90°. Photo Mode now uses a strict whitelist (`PhotoCameraActor` only) in `GetCameraView`, ensuring dialogues and cutscenes preserve their intended cinematic framing.
- **Cutscene Safety**: Sequencer and cinematic cutscene cameras are completely untouched.
- **Camera Manager Isolation**: Removed redundant `DefaultFOV` overwrite on exit to avoid disturbing dynamic in-game camera FOV curves.
- **OSD Feature Flag**: Made experimental OSD (Stage 1) optional via `enable_osd = false` in `photo_mode.ini` so unfinished UI does not display during normal gameplay.

---

## [1.1.0] - 2026-09-10

### Added
- **Camera Roll (Tilt / Dutch Angle)**: Full camera rotation up to +-90 deg (`PageUp` / `PageDown` or `NumPad 7` / `9`, reset with `Home` / `NumPad 8`). Enables dynamic Dutch angles and vertical portrait captures.
- **Cinematic Slow Motion**: Smooth variable world time dilation via `[` and `]` (reset with `\`). Integrated with native `SlowMotionSubsystem` with quadratic acceleration/braking compensation (`factor^2`) so the camera moves at full real-time responsiveness without lag or inertia sliding.
- **Hide Player Character**: Toggle on `K` or `Delete` hides Coen and attached equipment cleanly via native `OnActorHiddenInGameChanged`. Automatically restores player visibility on exit.
- **INI Mapping for All New Actions**: Full support in `photo_mode.ini` for new keys and tuning parameters (`slomo_step`, `slomo_min`, `slomo_max`, `roll_step`, `roll_max`).
- **Expanded Key Aliases**: Added comprehensive aliases for numpad, brackets, backslash, and navigation keys.

---

## [1.0.1] - 2026-09-09

### Added
- **User-Configurable Key Bindings**: All hotkeys (toggle, HUD, pause, screenshot, FOV, vertical movement, exit guard) can now be remapped by editing `Scripts/config/photo_mode.ini`. No code editing required.
- **Configurable Camera Parameters**: FOV default/min/max/step, vertical speed, camera max distance, and camera speed are now adjustable via the [Camera] section of the INI.
- **INI Fallback**: If `photo_mode.ini` is missing or invalid, the mod falls back to built-in defaults and continues to work normally.
- **Comma-Separated Key Alternates**: Key config values support multiple alternate key names separated by commas; the first available one is bound.
- **Key Aliases**: Common key name variations are automatically normalized (ESC→Escape, NumPadAdd→Add, ENTER→Return, CTRL→Control, PGUP→Page_Up, DEL→Del, INS→Ins, etc.) so users can type natural names in the INI.
- **Cross-Platform Config Path Resolution**: The mod probes multiple candidate paths (including case-sensitive variants for Linux/Proton) to locate the INI file.

### Fixed
- **European Number Parsing**: INI values with comma decimal separators (e.g. `90,0`) are now correctly parsed as `90.0`.
- **Screenshot Path Safety**: Apostrophes in Windows user profile paths (e.g. `O'Connor`) are now escaped for PowerShell.
- **TEMP Environment Fallback**: Screenshot temp script falls back to `TMP` or `.` if `TEMP` is unset (Proton/Wine compatibility).
- **Dead Code Removal**: Removed unused `section` variable in `loadConfig`.

---

## [1.0.0] - 2026-09-09 (Initial Release)

### Added
- **Native Photo Mode Subsystem Activation**: Hooked into `DogwoodPhotomodeSubsystem` with zero binary patches.
- **Free Camera Navigation**: Full 6-DOF movement using WASD + Mouse + E (Up) / Q (Down).
- **World Freeze (Time Pause)**: Independent toggle on `F11` to freeze actors and environmental physics while maintaining full camera movement.
- **Clean HUD Toggle**: `H` key hides all game UI, health bars, quest markers, and interaction prompts for unobstructed framing.
- **Dynamic FOV Control**: `NumPad +` / `NumPad -` adjustments (range 10°–170°) with instant reset to default 90° on `F3`.
- **Automatic Motion Blur Suppression**: Temporarily disables post-process motion blur while Photo Mode is active for crisp, artifact-free framing.
- **High-Resolution Screenshot System**: `P` key captures screenshots via native background pipeline and saves directly to `Pictures\DawnwalkerScreenshots\`.
- **ESC Guardian**: Safety interceptor ensuring camera control is gracefully restored and game menus do not lock the player's view.
- **Mod Manager & Manual Support**: 100% 1-click compatible with Vortex (UE4SS Rule 22) and simple manual drag-and-drop.

---

## [Nexus Mods Changelog Snippet]
> *Gotowy tekst do wklejenia w pole Changelog na Nexus Mods:*

```text
v1.6.2
* Fixed Camera Speed Spikes on FOV & DoF Adjustments: eliminated sudden rapid acceleration or freezing when altering Field of View or Depth of Field aperture (decoupled camera speed multiplier from FOV scaling).
* Fixed Interior Lighting Blowout on Player Movement: moving or posing the player character (Target = Player) in interiors (tents, caves, houses) no longer drops interior trigger volume overlaps or causes blinding light blowouts.
* Added Contextual Displacement Reset on Move Rows: pressing [R] (or Gamepad [Y / Triangle]) while selecting Move Fwd, Move Side, Move Height, Rotate, or Face Cam in the STAGE tab now cleanly resets only the target's displacement back to its starting coordinates, leaving camera, lighting, and environmental settings untouched.

v1.6.1 (Hotfix)
* Fixed Keyboard & Mouse Action Bleed: removed gameplay-level Enhanced Input hooks (Sprint + Focus) that caused Shift + MMB/Tab to inadvertently trigger the gamepad L3+R3 activation chord. Gamepad stick clicks are now detected strictly via direct hardware polling.
* Fixed Gamepad R3 HUD Toggle: clicking Right Stick (R3) in Photo Mode now reliably toggles HUD visibility without conflicting with mouse buttons.
* Fixed Guarded D-Pad Quickslots: keyboard number keys (1-4) no longer trigger D-Pad OSD navigation actions while in Photo Mode.

v1.6.0
* Native Gamepad / Controller Support:
  - Activation: Triple-tap L3 (Left Stick click) from normal gameplay (sprint-safe) or press L3 + R3 simultaneously.
  - Flight Controls: Left Stick horizontal flight, Right Stick look/aim, LT / RT analog vertical elevation.
  - Full OSD Navigation: D-Pad Up/Down to select, Left/Right to adjust (auto-repeat + automatic quickslot suppression).
  - Tab Switching: LB / RB cycle through Camera, Optics, Time, Weather, and Stage tabs.
  - Action Layout: A/Cross freeze/confirm, B/Circle exit, X/Square screenshot, Y/Triangle row reset, L3 FOV reset, R3 HUD toggle.
* Dynamic OSD Legend: automatically detects active input device and switches between keyboard keys ([F1], [F8], [Tab]) and controller prompts ([D-Pad], [LB/RB], [A / Cross], [B / Circle], etc.).
* Cutscene & Dialogue Photo Mode (force_cutscene_pm): opt-in feature to freeze cinematics, dialogues, audio, and camera tracks synchronously; resumes cleanly on exit.
* Mod Menu Integration: added force_cutscene_pm toggle in Dawnwalker Mod Menu.
* Changed: upgraded default controller activation to Triple-Tap L3 with sprint immunity; sanitized all OSD button descriptors.
* Fixed: Camera Roll 180° Gimbal Inversion — normalized Euler pitch angles so adjusting/resetting roll smoothly tilts the camera without flipping upside down.

v1.5.5
* Move the Real Player: STAGE controls (Move Fwd/Side/Height, Rotate, Face Cam) now work on Target = Player — pose and position the dressed Coen directly, no clone needed. Collision/gravity suspended while displaced; everything restored on exit.
* Full male pose library for the player: the complete male animation set is now available on Target = Player.
* More story NPCs: Bakhir, Xanthe, Leonica, Esme, Vladimir, Vicho, Mihai, Neberu, and Lunka join the Spawn Class roster.
* CRITICAL FIX: "Fatal world leaks detected" crash when loading a save after using Photo Mode — spawned actors/components could survive teardown; they are now destroyed on the game thread with a forced GC pass.
* Watchdog map detection: opening the in-game map or other GameHub screens now triggers the configured clean auto-exit.
* Changed: clone weapons are drawn via the game's native sheathed-weapon component instead of spawned actors (part of the crash fix).
* Removed: "Coen (clone)" from Spawn Class — the modular appearance pipeline can't be replicated for the player class from a script. Use Target = Player instead.

v1.5.0
* Added Stage Director: spawn NPC clones (Coen, townsfolk, soldiers, bandits) and direct them via the OSD STAGE tab — move, rotate, face camera.
* Added pose system: apply authentic animation poses from the game's own libraries (male/female/child sets) to clones or the player.
* Added authentic hand props attached to the game's own prop sockets (bread, bottle, hammer + stake, wooden spoon with food, book).
* Added Frame Step: advance the frozen world one frame at a time.
* Added OSD tabs (CAMERA / DIRECTING / STAGE) navigated with PageUp/PageDown.
* Added gamepad shortcuts: A/Cross freeze, B/Circle screenshot, LB/RB vertical camera, D-Pad menu navigation (all Photo Mode only).
* Added freeze-on-entry, enabled by default (pause_on_enter=0 restores v1.4.x behavior).
* Changed freeze key F11 -> F2 (conflict with UE4SS HotReload).

v1.4.0
* Added Time of Day control (safely restored on exit).
* Added cinematic Aspect Ratio framing bars (16:9, 2.35:1, 4:3, 1:1, 9:16) — visible in screenshots.
* Added Auto-Focus depth of field (center-screen focus, UE5 cinematic DoF).
* Added Weather preset cycling via SkyCreator (restored on exit).
* Added Input Isolation: character actions blocked while framing (enable_input_isolation).
* Added Auto-Exit Watchdog: opening map/inventory/menus or camera changes now cleanly exits Photo Mode instead of leaving a broken state.
* Added startup fail-safe recovering player input after a crash.

v1.3.0
* Completely modularized architecture (clean Scripts/lib/ separation) for better performance, faster loading, and future mod stability.
* Added live config reloading: settings changed in Dawnwalker Mod Menu or INI apply immediately on entering Photo Mode without restarting the game.
* Subsystem caching to eliminate per-frame object scans in the camera view hook.
* Automatic hot-reload safety cache clearing on mod restart.
* Added a dynamic Quick Actions legend to the bottom of the OSD displaying all active hotkeys.

v1.2.1 (Hotfix)
* Added Dawnwalker Mod Menu Integration (adjust speeds, FOV, and OSD from the pause menu).
* Added OSD Scale setting (osd_scale = 1.5 in photo_mode.ini) to increase menu size for 4K/1440p displays.
* Fixed the physical "camera drone" mesh becoming visible if a gamepad user resets the view to the player.

v1.2.0
* Added Dynamic On-Screen Display (OSD) menu powered by native engine UMG.
* Real-time parameter readout for FOV, Camera Roll, Slow Motion, Player, and HUD status.
* Streamlined navigation: Arrow keys (Up/Down select, Left/Right adjust), R to reset all, F1 to toggle menu.
* Unified controls to eliminate keyboard clutter.
* Added screenshot guard (auto-hides OSD during capture).
* Added HUD guard (clean HUD shortcut H does not hide Photo Mode OSD).
* Added osd_show_on_enter and osd_reset_key to photo_mode.ini.

v1.1.1 (Hotfix)
* Fixed dialogue camera framing (strict whitelist: only PhotoCameraActor is modified; dialogue and cutscene cameras are completely untouched).
* Fixed cutscene cameras being affected by camera view hooks.
* Removed redundant DefaultFOV overwrite on camera manager upon exit.

v1.1.0
* Added Camera Roll / Tilt (PageUp / PageDown or NumPad 7 / 9, reset Home / NumPad 8) up to +-90°.
* Added Cinematic Slow Motion ([ / ], reset \) with quadratic camera inertia compensation.
* Added Hide Player Character toggle (K / Delete) with clean visibility restore on exit.
* Added all new keys and parameters to photo_mode.ini with full alias mapping.

v1.0.1
* Added user-configurable key bindings via Scripts/config/photo_mode.ini.
* Added configurable camera parameters (FOV, speed, distance) in [Camera] section.
* Added key aliases (ESC, NumPadAdd, ENTER, CTRL, PGUP, etc.) for natural INI input.
* Falls back to defaults if INI is missing or invalid.
* Fixed European decimal parsing (90,0 -> 90.0).
* Fixed screenshot on profiles with apostrophes and on Proton/Wine (TEMP fallback).

v1.0.0 - Initial Release
* Unlocked built-in Photo Mode subsystem with freecam (WASD + Mouse + E/Q).
* Added World Freeze / Time Pause toggle (F11).
* Added Clean HUD toggle (H) to hide all UI elements.
* Added FOV zoom controls (NumPad +/-) with F3 reset (90°).
* Added Screenshot capture (P) saved to Pictures\DawnwalkerScreenshots.
* Added ESC guardian to prevent menu camera locks.
* Full 1-click Vortex Mod Manager and manual install support.
```

---

## [Planned / Roadmap]

> Full technical roadmap with feasibility analysis, risk matrix, and implementation details: see `Nexus_Assets/ROADMAP.md` (collaboratively developed with AGY).

### [2.0.0] - Virtual Studio Suite (High complexity)
- **3-Point Studio Lighting**: Portable Key, Fill, and Rim lights spawned relative to camera. Strict actor lifecycle management. Difficulty: HIGH.
- **Preset Save/Load System**: Save favorite camera angles, optics, time, and weather presets to disk and reload them at will. Difficulty: MED.
- **Advanced Character & Prop Selector**: Interactive browsing and filtering of additional NPCs and handheld props. Difficulty: MED.





