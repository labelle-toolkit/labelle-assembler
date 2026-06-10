# Gamepad input demo — Android (sokol + imgui)

On-device sibling of [`examples/gamepad`](../gamepad) (raylib desktop). It is
the **try-it-on-real-hardware** vehicle for the merged gamepad detection
(#248) + analog state (#250), and the verification vehicle for #261. Sideload
the APK to an Android phone or Android TV, pair a controller, and watch the
HUD react live.

## What it does

A Dear ImGui HUD that, for each of the up-to-4 gamepad slots:

- lists connected gamepads (name + type hint from the engine
  `gamepad_connected` event);
- reacts live to **hotplug** connect / disconnect;
- highlights currently-pressed buttons in green — face (A/B/X/Y), d-pad,
  shoulders (LB/RB), thumbs (L3/R3), select/start;
- shows left/right stick X/Y and the analog triggers (LT/RT) as bars;
- shows a clean **"No gamepad connected"** empty state when nothing is paired.

The HUD logic is **shared verbatim** with the raylib demo
(`scripts/gamepad_hud.zig`, `scripts/connected_pads.zig`,
`hooks/gamepad_hooks.zig`): it polls the engine input-mixin forwarders
(`game.isGamepadAvailable` / `isGamepadButtonDown` / `isGamepadButtonPressed`
/ `getGamepadAxisValue`) and reads the connected-pad registry fed by the
engine hotplug events. None of that is backend-specific.

## How it differs from the raylib demo

- `backend = .sokol`, `platform = android`.
- The HUD draws through the `imgui` plugin's **sokol** bridge. The assembler
  resolves `@import("gui_backend").ig` to sokol-imgui because the backend is
  sokol, so the same cimgui calls compile against sokol instead of rlImGui.
- On-device, the availability/button/axis state is driven by the patched
  sokol fork's Android gamepad AInputEvent forwarding +
  labelle-core's `gamepad_source/android.zig` (#248 JNI detection), instead of
  raylib's desktop polling.

## Build the APK

```sh
labelle android doctor          # confirm SDK/NDK toolchain
labelle android build --all-abis  # arm64-v8a + x86_64 fat APK, debug-signed
# → APK at .labelle/sokol_android/game.apk
```

Drop `--all-abis` for an arm64-v8a-only APK. The debug keystore is auto-created
so the APK installs without a release keystore.

## Install

**Phone (USB):**

```sh
adb install -r .labelle/sokol_android/game.apk
```

**Android TV (network adb):**

```sh
adb connect <tv-ip>:5555
adb install -r .labelle/sokol_android/game.apk
```

(Enable Developer Options + USB/Network debugging on the device first. On
Android TV, "Network debugging" lives under Settings → Device Preferences →
Developer options.) You can also sideload the APK via a file manager / Send
Files to TV if adb isn't available.

## Pair a controller

1. On the device: Settings → Connected devices / Remotes & accessories →
   **Pair accessory** (Bluetooth).
2. Put the controller into pairing mode (Xbox: hold the pair button until the
   logo flashes; DualShock/DualSense: hold **Share + PS**; 8BitDo: per its
   mode).
3. Once paired, launch **LaBelle Gamepad Demo**. The HUD should switch from
   "No gamepad connected" to a `Pad 0: <name> [<type>]` panel. USB-OTG
   controllers work too.

Pressing buttons lights them green; moving sticks / squeezing triggers moves
the bars. Connect/disconnect updates the list live.

## Notes / stacking

- `engine_version` points at the `eng-gpinput` worktree (the input-mixin
  `game.isGamepad*` forwarders). The `imgui` plugin comes from the
  `labelle-imgui` worktree, whose `gui.labelle` declares the sokol bridge.
  Repin both to released versions once they land.
- The sokol fork is pinned to `ba7363f`
  (`feat/forward-android-gamepad-events`) across the assembler `backends/sokol`
  and both labelle-imgui sokol pins — a single unified pin so only one
  `sokol_clib` is built (mismatched pins previously caused
  `cimgui.h file not found` on Android).
