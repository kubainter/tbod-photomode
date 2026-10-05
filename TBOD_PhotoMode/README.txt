TBOD Photo Mode - UE4SS (TBOD_PhotoMode) 1.6.2
Photo Mode & FreeCam Suite for The Blood of Dawnwalker

Unlocks and enhances the game's built-in Photo Mode camera subsystem with an on-screen display (OSD) settings menu, free camera movement, world freeze, FOV zoom, clean HUD toggle, camera roll, cinematic slow motion, player visibility toggle, and borderless screenshot capture.
New in 1.6.2: Camera speed stabilization during FOV/DoF modulation (TIK-013), interior candle/room lighting preservation when repositioning the player model (TIK-014), and contextual displacement reset on movement rows via R / Reset button.
New in 1.6.1: Hotfix for Keyboard & Mouse players - eliminates inadvertent Photo Mode triggers caused by sprinting (Shift) and target lock (MMB/Tab) sharing Enhanced Input actions with controller chords. Gamepad stick clicks are now detected strictly via direct hardware polling.
New in 1.6.0: Full Native Gamepad Support (triple-tap L3 activation, D-Pad navigation with auto-repeat & quickslot suppression, LB/RB tab switching, A/B/X/Y actions, L3/R3 shortcuts, dynamic gamepad-aware OSD legend, camera roll fixes) + opt-in Cutscene Photo Mode (force_cutscene_pm pauses & resumes all sequence types seamlessly).


REQUIREMENTS

  Mandatory:
    * The Blood of Dawnwalker (UE 5.5.4, Patch 1 or Patch 2)
    * RE-UE4SS for The Blood of Dawnwalker v1.2.1-rc6 or newer (UE4SS v3.0.1)
      https://www.nexusmods.com/thebloodofdawnwalker/mods/18
    * UE4SS Lua Event Bridge v1.0.7 or newer (Required for Enhanced Input & Gamepad support)
      https://www.nexusmods.com/thebloodofdawnwalker/mods/526
    Note: Other UE4SS builds/forks bind a different Lua API surface and mod
    features will silently fail. Check UE4SS.log for "[TBOD_PM] WARNING: API
    self-check missing" if something does not work.

  Optional (Recommended):
    * Mod Settings Menu (Nexus mod #271) - required only if you want to
      configure Photo Mode settings directly from the in-game pause menu.
      https://www.nexusmods.com/thebloodofdawnwalker/mods/271
      (Without it, all settings are easily configured via photo_mode.ini).


INSTALLATION

  With Vortex / Nexus Mod Manager (Recommended):
    1. Make sure RE-UE4SS (mod #18) and UE4SS Lua Event Bridge (mod #526) are installed.
    2. Click "Mod Manager Download" on Nexus.
    3. Enable the mod in Vortex.
    4. Vortex automatically deploys the mod into ue4ss\Mods\TBOD_PhotoMode\.

  Manual Installation:
    1. Make sure RE-UE4SS (UE5 build) is installed in:
       <GameRoot>\Dawnwalker\Binaries\Win64\ue4ss\
    2. Make sure UE4SS Lua Event Bridge is installed in:
       <GameRoot>\Dawnwalker\Binaries\Win64\ue4ss\Mods\_ModCore_UE4SSLuaEventBridge\
    3. Extract the "TBOD_PhotoMode" folder from this archive directly into:
       <GameRoot>\Dawnwalker\Binaries\Win64\ue4ss\Mods\
    4. The resulting structure must be:
       ue4ss\Mods\TBOD_PhotoMode\enabled.txt
       ue4ss\Mods\TBOD_PhotoMode\README.txt
       ue4ss\Mods\TBOD_PhotoMode\Scripts\main.lua
       ue4ss\Mods\TBOD_PhotoMode\Scripts\lib\*.lua
       ue4ss\Mods\TBOD_PhotoMode\Scripts\config\photo_mode.ini
    5. Launch the game and press F8 (or Triple-Tap L3 / L3+R3 on gamepad).


CONTROLS (default - customizable, see CONFIGURATION below)

  Camera & Flight:
    F8                      Toggle Photo Mode (Enter / Exit)
    WASD + Mouse            Move camera & look around
    E / Q                   Move camera Up / Down
    ESC                     Force exit Photo Mode

  In-Game Menu (OSD):
    F1                      Toggle OSD Menu (Hide / Show)
    PageUp / PageDown       Switch OSD tab (CAMERA / DIRECTING / STAGE)
    Up / Down               Select parameter on the active tab:
                            CAMERA: FOV, Roll, Slow Motion, Player, HUD,
                                    Time of Day, Auto-Focus, Aspect Ratio,
                                    Weather
                            DIRECTING: Target, Pose, Frame Step, ...
                            STAGE: Target, Pose, Spawn Class, Spawn NPC,
                                    Move Fwd/Side/Height, Rotate, Face Cam
                                    (Move/Rotate/Face Cam also work on
                                    Target = Player - the real Coen)
    Left / Right            Adjust selected parameter
    R                       Reset all settings to defaults

  Quick Actions:
    P                       Take screenshot (auto-hides menu, saved to Pictures\Dawnwalker)
    H                       Toggle HUD (Hide / Show game UI)
    F2                      Freeze / Unfreeze world time
    F3                      Quick reset FOV (90 deg)

  Gamepad:
    L3 (Triple-Tap)         Toggle Photo Mode from normal gameplay (3x quick click)
    Left Stick / Triggers   Move camera & vertical elevation (LT = Down, RT = Up)
    Right Stick             Rotate camera & look around (Pitch / Yaw)
    D-Pad Up / Down         Select parameter in active OSD tab
    D-Pad Left / Right      Adjust selected parameter (with auto-repeat & quickslot suppression)
    LB / RB                 Previous / Next OSD tab (CAMERA / DIRECTING / STAGE)
    A / Cross               Confirm action / Toggle Pause / Freeze world time
    Square / X              Clean View (Hide/Show Menu & HUD for framing)
    B / Circle              Take screenshot (auto-hides OSD, saves to Pictures\Dawnwalker)
    Y / Triangle            Reset all settings to defaults (safe level horizon)
    L3 (Single Click)       Quick reset FOV to default (90 deg)
    Menu / Start            Exit Photo Mode (clean full restoration)
    L3 (Triple-Tap)         Toggle Photo Mode (Enter / Exit)


CONFIGURATION

  All keys and camera parameters can be customized by editing:
    ue4ss\Mods\TBOD_PhotoMode\Scripts\config\photo_mode.ini

  Open the file in any text editor, change the values, save, and restart the game.
  Key names match standard entries (F1-F12, E, Q, R, P, H, Escape, etc.) plus
  gamepad names (Gamepad_FaceButton_Bottom, Gamepad_LeftShoulder, etc.).
  Multiple alternate keys can be separated by commas - all of them are bound.

  Available settings:
    osd_show_on_enter   - Open OSD menu automatically on Photo Mode entry (1/0)
    osd_toggle_key      - Key to toggle the OSD menu
                        (default: F1, Gamepad_Special_Left)
    osd_reset_key       - Key to reset all settings to defaults (default: R)
    pause_key           - Freeze/unfreeze world time
                        (default: F2, Gamepad_FaceButton_Bottom)
    pause_on_enter      - Freeze world time automatically on PM entry (1=default on / 0)
    force_cutscene_pm   - Allow PM during cutscenes/dialogues: pauses the playing
                          sequence (picture, sound, camera cuts), resumes it on
                          exit (default: 0 = off)
    Camera parameters   - fov_default, fov_min, fov_max, fov_step, vertical_speed,
                          camera_max_distance, camera_speed, slomo_step, slomo_min,
                          slomo_max, roll_step, roll_max

  If the INI file is missing or invalid, the mod falls back to default values.


FEATURES

  * In-Game OSD menu with real-time parameter readout and arrow navigation
  * Full 6-DOF freecam with extended range and dedicated vertical movement
  * Camera Roll / Tilt (-90 to +90 deg) for portrait and Dutch-angle shots
  * Cinematic Slow Motion (down to 0.02x) and world freeze with smooth camera
  * Hide Player Character toggle for landscape and scenery shots
  * Wide FOV range (10 - 170 deg)
  * Dedicated screenshot capture (auto-hides OSD during capture)
  * Clean HUD toggle (hides game UI)
  * Time of Day control via SkyCreator (restored on exit)
  * Auto-Focus depth of field (aim at subject, background blurs)
  * Cinematic aspect-ratio framing (letterbox/pillarbox bars, captured in screenshots)
  * Weather presets via SkyCreator (restored on exit)
  * Stage Director: spawn NPC clones (townsfolk, soldiers, bandits, story
    characters incl. Brencis, Bakhir, Esme, Vladimir, Xanthe and more), apply
    authentic animation poses (male/female/child libraries) to clones or the
    player, attach real in-game hand props (bread, bottle, hammer, spoon, book),
    and direct them via Move Fwd/Side/Height, Rotate and Face Cam
  * Move the real player: Target = Player + Move/Rotate/Face Cam repositions
    the dressed Coen directly (collision suspended while displaced; original
    position fully restored on exit)
  * Frame Step: advance the frozen world frame by frame for the perfect shot
  * Gamepad support: native photo-camera flight plus pad shortcuts for freeze,
    screenshot, vertical camera and OSD navigation
  * Freeze-on-entry like built-in photo modes (on by default, pause_on_enter=0 disables)
  * Photo Mode in cutscenes/dialogues (opt-in, force_cutscene_pm): the playing
    sequence is paused - picture, sound and camera cuts - and resumed exactly
    where it stopped when Photo Mode exits
  * Input Isolation + Auto-Exit Watchdog (clean exit when the game opens menus)
  * Fully customizable keys and camera parameters via photo_mode.ini


COMPATIBILITY

  Tested on game build:
  Dawnwalker-5.5.4-256914+dw1-pc-256914-shipping-patch2-all-97b7e501


CHANGELOG

  v1.6.2
    * Fixed: Camera Speed Spikes on FOV & DoF Adjustments - eliminated sudden
      unintended speed spikes or camera freezing when altering Field of View or
      Depth of Field aperture. Camera flight speed is now cleanly stabilized across
      all focal lengths and zoom levels (TIK-013).
    * Fixed: Interior Lighting Blowout on Player Movement - moving or posing the
      player character (Target = Player) inside interiors (tents, caves, houses)
      no longer drops interior trigger volume overlaps or causes blinding light blowouts.
      The collision capsule maintains query overlaps so interior post-process lighting
      remains intact while moving the model (TIK-014).
    * Added: Contextual Target Displacement Reset - pressing R (or Gamepad Y / Triangle)
      while selecting Move Fwd, Move Side, Move Height, Rotate, or Face Cam in the
      STAGE tab cleanly restores only the target's position and rotation back to
      its starting coordinates, leaving camera, lighting, and environment untouched.

  v1.6.1
    * Fixed: Keyboard & Mouse Action Bleed - eliminated inadvertent Photo Mode
      activations when playing on KBM (e.g. Shift + MMB/Tab). Removed gameplay
      Enhanced Input hooks (IA_Sprint, IA_Focus) in favor of direct hardware
      controller polling for L3/R3.
    * Fixed: Gamepad R3 HUD Toggle - bound combat/focus actions via EventBridge
      specifically inside Photo Mode with controller guards and debouncing,
      restoring reliable R3 HUD toggle on gamepads.
    * Fixed: Photo Mode D-Pad Quickslot Guard - ensured keyboard number keys (1-4)
      cannot trigger D-Pad OSD navigation while in Photo Mode.

  v1.6.0
    * Added: Full Native Gamepad Support - enter Photo Mode directly from
      gameplay with Triple-Tap L3 (immune to sprint conflicts).
    * Added: Complete Gamepad OSD Navigation - D-Pad Up/Down to select,
      Left/Right to adjust with smooth key-repeat and automatic quick-slot / potion
      suppression during navigation.
    * Added: Gamepad Button Mapping - LB/RB tab navigation, LT/RT analog
      elevation, A/Cross action/freeze, B/Circle instant exit, X/Square
      screenshot, Y/Triangle settings reset, L3 FOV reset, and R3 HUD toggle.
    * Added: Dynamic OSD Legend - automatically detects whether keyboard or
      gamepad is being used and displays clean, user-friendly button prompts
      ([D-Pad], [LB/RB], [A / Cross], [B / Circle], etc.) instead of raw engine names.
    * Added: Cutscene & Dialogue Photo Mode (force_cutscene_pm, opt-in in Mod Menu)
      - cleanly pauses all playing sequence players (CinematicNode, Dialogue,
      Event, Flow, Template, Level) and resumes them with full state preservation on exit.
    * Changed: Controller Activation - upgraded default entry to Triple-Tap L3
      (sprint-safe) with L3 + R3 simultaneous press retained as alternative.
    * Changed: OSD Legend - dynamically replaces engine key strings with clean
      controller button prompts ([D-Pad], [LB/RB], [A / Cross], etc.).
    * Fixed: Camera Roll 180° Gimbal Inversion - normalized Euler pitch angles
      and unified controller/actor rotation so adjusting or resetting camera roll
      smoothly tilts the camera without flipping 180 deg upside down.

  v1.5.5
    * Added: Move/Rotate/Face Cam on the real player (Target = Player) -
      position the dressed Coen directly; collision and gravity are suspended
      while displaced and everything is restored on exit.
    * Added: full male pose library for the player/Coen target.
    * Added: more story NPCs to Spawn Class (Bakhir, Xanthe, Leonica, Esme,
      Vladimir, Vicho, Mihai, Neberu, Lunka).
    * Fixed CRITICAL: "Fatal world leaks detected" crash when loading a save
      after using Photo Mode - spawned weapons/components are now destroyed
      on the game thread and force-collected.
    * Fixed: watchdog not detecting the in-game map and other GameHub screens
      - Photo Mode now cleanly auto-exits.
    * Changed: clone weapons are drawn via the game's native sheathed-weapon
      component instead of spawned weapon actors (part of the leak fix).
    * Removed: "Coen (clone)" from Spawn Class - use Target = Player instead
      (already dressed, fully posable and movable).

  v1.5.0
    * Added Stage Director: NPC clone spawning with class selection
      (family-aware: Coen, townsfolk, soldiers, bandits) via the OSD STAGE tab.
    * Added pose system: apply animation poses from the game's own libraries
      (male/female/child sets) to clones or the player via Target/Pose rows.
    * Added authentic hand props attached to the game's own prop sockets
      (bread, bottle, hammer + stake, wooden spoon with food, book).
    * Added clone directing: Move Fwd/Side/Height, Rotate, Face Cam.
    * Added Frame Step (advance the frozen world one frame at a time).
    * Added OSD tabs (CAMERA / DIRECTING / STAGE) on PageUp/PageDown.
    * Added gamepad shortcuts: A/Cross freeze, B/Circle screenshot,
      LB/RB vertical camera, D-Pad OSD navigation (all PM-scoped).
    * Added pause_on_enter option (auto-freeze world on PM entry, on by default).
    * Remapped freeze key F11 -> F2 (UE4SS HotReload conflict).
    * Fixed sword poses now showing the correct equipped weapon visuals.
    * Fixed prop cleanup on pose change/exit (components destroyed, not leaked).
    * Fixed a crash when attaching props to sockets on spawned clones.

  v1.4.0
    * Added Time of Day manipulation (sun rotation, safely restored on exit).
    * Added cinematic Aspect Ratio framing bars (16:9, 2.35:1, 4:3, 1:1, 9:16).
    * Added Auto-Focus depth of field (unbound post-process volume, UE5
      Diaphragm DoF; focal distance from center-screen trace).
    * Added Weather preset cycling via SkyCreator (restored on exit).
    * Added Input Isolation (blocks character actions while in Photo Mode).
    * Added Auto-Exit Watchdog (clean exit if the game opens a menu/map or
      steals the camera).
    * Added startup fail-safe restoring player input after a mod crash.
    * Added unlocked vertical camera pitch range (-89.9 deg to +89.9 deg look up/down).

  v1.3.0
    * Modular Architecture: Split monolith into clean library modules in Scripts/lib/.
    * Hot-Reload Safety: Automatic package.loaded cache flushing on mod restart.
    * Subsystem Caching: Cached subsystem references to eliminate per-frame scans.
    * Dynamic Config Reload: Live updates from Dawnwalker Mod Menu / INI on entry.
    * OSD Hotkeys Legend: Dynamic quick actions guide directly built into the OSD.

  v1.2.1 (Hotfix)
    * Added Dawnwalker Mod Menu Integration (mod_settings.ini).
    * Added OSD Scale setting (osd_scale) for 1440p/4K displays.
    * Hidden camera drone mesh to prevent view clipping on gamepad reset.

  v1.2.0
    * Added Dynamic On-Screen Display (OSD) menu powered by native engine UMG.
    * Real-time parameter readout (FOV, Roll, Slow Motion, Player, HUD).
    * Streamlined controls: arrow navigation (Up/Down select, Left/Right adjust, R reset all).
    * Unified hotkey layout to eliminate keyboard clutter.
    * Added screenshot guard that automatically hides OSD during capture.
    * Added HUD filter so hiding game UI (H) does not hide Photo Mode OSD.
    * Added osd_show_on_enter and osd_reset_key to photo_mode.ini.

  v1.1.1 (Hotfix)
    * Fixed dialogue camera framing in conversation scenes (strict whitelist:
      only PhotoCameraActor is modified; dialogues & cutscenes untouched).
    * Removed redundant DefaultFOV overwrite on camera manager upon exit.
    * Made in-development OSD preview optional via enable_osd in photo_mode.ini.

  v1.1.0
    * Added Camera Roll / Tilt (PageUp / PageDown, reset Home) up to +-90 deg.
    * Added Cinematic Slow Motion ([, ], reset \) using native subsystem with
      real-time camera movement and inertia compensation.
    * Added Hide Player Character toggle (K / Delete) with clean restore on exit.
    * Added cutscene camera safety filter (preserves cinematics/dialogues).
    * Added all new actions to photo_mode.ini with full alias mapping.

  v1.0.1
    * Added user-configurable key bindings and camera parameters via INI
      (Scripts/config/photo_mode.ini).
    * Falls back to defaults if INI is missing or invalid.

  v1.0.0 (Initial Release)
    * Native Photo Mode activation, 6-DOF camera, world freeze, HUD toggle,
      FOV zoom, screenshot capture, and ESC guardian safety.

