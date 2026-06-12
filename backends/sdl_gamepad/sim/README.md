# gamepad-sim

Hardware-free verification harness for the shared `sdl_gamepad` source
(the parent package). Three tools, all linking the system SDL2:

- **`zig build run`** — the simulation harness (`src/main.zig`). Attaches
  an in-process SDL2 *virtual gamecontroller* (`SDL_JoystickAttachVirtual`,
  SDL 2.0.14+ — no driver, no admin, no physical hardware, no display),
  presses every button, sweeps every axis, and asserts the toolkit
  `Source` API (`isAvailable` / `isButtonDown` / `axisValue`) reports each
  one back with the correct canonical mapping. Then attaches a SECOND
  simultaneous pad and asserts multi-gamepad behavior: distinct slots,
  state independence in both directions, slot freeing on detach without
  disturbing the other pad, and lowest-free-slot reuse. Exits non-zero on
  any FAIL,
  so it doubles as a CI smoke test — see the `Run the gamepad-sim
  harness` step in `.github/workflows/ci.yml`. Because the virtual device
  lives entirely inside SDL's joystick subsystem, this works the same on
  Windows, Linux (including WSL — no USB passthrough needed), and macOS.

- **`zig build monitor`** — live monitor (`src/monitor.zig`). Creates no
  device of its own; opens whatever controller the OS exposes and streams
  the toolkit `Source` state. Pair with a real pad, or on Windows with a
  ViGEmBus virtual Xbox 360 pad driven by `feeder.py`, to verify the whole
  OS-driver path the simulation harness deliberately bypasses.

- **`gamepad_probe`** (`zig build` artifact, `src/probe.zig`) — raw-SDL
  diagnostic probe with no toolkit wrapper, for bisecting whether a
  problem lives in SDL or in the `sdl_gamepad` source.

On Windows, set `LABELLE_SDL2_LIB` to the SDL2 MinGW `lib` dir (or run
`labelle doctor --fix`); on Linux/macOS the system SDL2 is found
automatically.
