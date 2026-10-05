# 1.6.2
- Fixed: Camera Speed Spikes on FOV & DoF Adjustments - eliminated sudden speed spikes or camera freezing when modifying Field of View or Depth of Field aperture; camera flight speed is now cleanly stabilized across all zoom levels (TIK-013).
- Fixed: Interior Lighting Blowout on Player Movement - moving or posing the player character (Target = Player) inside interiors (tents, caves, houses) no longer drops interior trigger volume overlaps or causes blinding light blowouts; capsule query overlaps are preserved during movement (TIK-014).
- Added: Contextual Target Displacement Reset - pressing R (or Gamepad Y / Triangle) while selecting Move Fwd, Move Side, Move Height, Rotate, or Face Cam in the STAGE tab cleanly restores only the target's position and rotation back to starting coordinates, leaving camera, lighting, and environment untouched.

# 1.6.1
- Fixed: Keyboard & Mouse Action Bleed - removed gameplay-level Enhanced Input hooks (IA_Sprint, IA_Focus) that caused sprinting (Shift) + target lock / focus (MMB/Tab) on Keyboard & Mouse to trigger the L3+R3 gamepad chord. Gamepad stick clicks are now detected strictly via direct hardware polling.
- Fixed: Gamepad R3 HUD Toggle in Photo Mode - bound combat/focus actions via EventBridge strictly inside Photo Mode sessions with device verification and debouncing, restoring reliable right thumbstick HUD toggle on gamepads.
- Fixed: Guarded D-Pad Quickslot Actions in Photo Mode - ensured number keys (1-4) on keyboard do not interfere with Photo Mode OSD navigation.

# 1.6.0
- Added: Full Native Gamepad Support - enter Photo Mode directly from normal gameplay with Triple-Tap L3 (immune to sprint conflicts).
- Added: Complete D-Pad OSD navigation with auto-repeat (350ms delay, 100ms interval) and automatic quickslot suppression.
- Added: Full Gamepad Button Layout: LB/RB tab navigation, LT/RT analog elevation, A/Cross action/freeze, B/Circle instant exit, X/Square screenshot, Y/Triangle settings reset, L3 FOV reset, and R3 HUD toggle.
- Added: Dynamic OSD Legend - automatically detects active input device and displays clean, user-friendly button prompts ([D-Pad], [LB/RB], [A / Cross], [B / Circle], etc.) instead of raw engine key strings.
- Added: Photo Mode in cutscenes/dialogues (force_cutscene_pm, off by default). Instead of activating over a live cinematic, PM pauses every playing sequence player (CinematicNode, Dialogue, Event, Flow, Template, Level classes) - picture, sound and camera cuts stop together - then activates. Each sequence's original camera-cut state is snapshotted and it resumes exactly where it stopped on exit, on a failed activation, or on a watchdog/mod-reload teardown. No stuck frozen cutscenes.
- Added: force_cutscene_pm toggle exposed in the Mod Menu manifest (Photo Mode group).
- Changed: Controller Activation - upgraded default entry to Triple-Tap L3 with sprint conflict immunity; L3 + R3 simultaneous press retained as alternative.
- Changed: OSD Legend Formatting - sanitized all key descriptions so gamepad prompts display clean controller symbols instead of raw engine names.
- Fixed: Camera Roll 180° Gimbal Inversion - normalized Euler pitch angles and unified ControllerRotation/ActorRotation so adjusting or resetting roll smoothly tilts the camera without flipping upside down.

# 1.5.5
- Added: the STAGE directing controls (Move Fwd/Side/Height, Rotate, Face Cam) now work on the real player (Target = Player) - position the dressed, posed Coen directly, no clone needed. Collision and gravity are suspended while the player is displaced and the original position/rotation/collision/movement state is fully restored on exit.
- Added: full male pose library for the player/Coen target (merged pose sets).
- Added: more story NPCs to the Spawn Class roster (Bakhir, Xanthe, Leonica, Esme, Vladimir, Vicho, Mihai, Neberu, Lunka).
- Fixed CRITICAL: "Fatal world leaks detected" crash when loading a save after using Photo Mode - spawned weapon actors and components could survive teardown as uncollectable garbage; all spawned actors/components are now detached and destroyed on the game thread, with a forced GC pass after teardown.
- Fixed: the Auto-Exit Watchdog not detecting the in-game map and other GameHub screens (they live on UI layers that weren't monitored) - Photo Mode now cleanly auto-exits.
- Changed: clone weapons are drawn via the game's native sheathed-weapon component instead of separately spawned weapon actors (part of the world-leak fix; the weapon returns to the sheath when the pose doesn't need it).
- Removed: "Coen (clone)" from the Spawn Class list - the game's modular appearance pipeline cannot be replicated for the player class from a script. Use Target = Player instead: it is already dressed and fully posable/movable.

# 1.5.0
- Added Stage Director: spawn NPC clones with family-aware class selection (Coen, townsfolk, soldiers, bandits) and direct them from the OSD STAGE tab (Move Fwd/Side/Height, Rotate, Face Cam).
- Added pose system: apply animation poses from the game's own libraries (male/female/child sets) to clones or the player via Target/Pose OSD rows.
- Added authentic hand props: pose-accurate items attached to the game's own prop sockets - bread, ceramic bottle, hammer + stake, large wooden spoon with food, closed book.
- Added Frame Step: advance the frozen world one frame at a time.
- Added OSD tabs (CAMERA / DIRECTING / STAGE) navigated with PageUp/PageDown.
- Added gamepad shortcuts: A/Cross freeze, B/Circle screenshot, LB/RB vertical camera, D-Pad OSD navigation - all scoped to Photo Mode.
- Added pause_on_enter INI option + Mod Menu toggle: auto-freeze world on PM entry (on by default, set 0 for v1.4.x behavior).
- Changed: freeze key remapped F11 -> F2 (UE4SS HotReload conflict).

# 1.4.0
- Added Time of Day manipulation (adjust the sun's rotation safely, restoring on exit).
- Added cinematic Aspect Ratio framing bars via UMG letterbox/pillarbox overlay (16:9, 2.35:1, 4:3, 1:1, 9:16) - captured in screenshots, zero bleed into normal gameplay.
- Added Auto-Focus depth of field: center-screen focus trace drives a spawned unbound PostProcessVolume using UE5 Diaphragm DoF (f/0.5). Reversible; restores on Off/reset/exit.
- Added Weather preset cycling via SkyCreator's native weather pipeline (restored on exit; crash-safe field-level copy, no large-struct UFunction marshalling).
- Added Input Isolation: character-bound actions are disabled while Photo Mode is active (enable_input_isolation).
- Added Auto-Exit Watchdog: polls CommonUI menu layers and ViewTarget; opens of map/inventory/journal/menus or camera theft trigger a clean fully-restored exit (auto_exit_on_view_change).
- Added startup fail-safe restoring player input after a mod crash.
- Added unlocked vertical camera pitch range (-89.9 deg to +89.9 deg look up/down) to PlayerCameraManager (TIK-001).
- Fixed: photo camera actor has no camera component - post-process and aspect changes now avoid the player's shared camera (no more bleed-through into gameplay).


