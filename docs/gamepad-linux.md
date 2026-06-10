# Linux gamepad detection (sokol backend)

The sokol backend has no built-in gamepad layer, so labelle-core ships a
native Linux **detection** source (`gamepad_source/linux.zig`) that:

- enumerates the controllers already plugged in at startup, and
- watches **libudev** for hotplug `add`/`remove` events,

turning each into a `GamepadEvent` (connect/disconnect, with a stable 16-byte
GUID derived from the device's `input_id`). Reading axes/buttons (semantic
state) is handled separately — this source is identity/detection only.

libudev is **not** a build-time dependency. As of labelle-core#20 the
detection source loads it at **runtime** via `std.DynLib` (a `dlopen` of
`libudev.so.1`), so a sokol project's generated `build.zig` does **not** link
`-ludev` and you do not need `libudev-dev` to build. The raylib/SDL backends
supply their own gamepad polling and do not touch libudev at all.

## Runtime requirement

The detection source `dlopen`s `libudev.so.1` at startup. Virtually every
desktop Linux system already ships it (it is part of systemd / eudev). If it is
missing, the source **degrades gracefully**: it simply reports no controllers
rather than failing — there is no hard dependency and nothing to install to
*build* the binary.

## Runtime permissions

Reading from `/dev/input/event*` requires permission. By default these nodes
are owned by `root:input` with `0660` mode, so a process can open them only if
the user is in the `input` group **or** a udev rule has tagged the node for the
active login session (`uaccess`).

When the detection source hits `EACCES` opening a controller node it still
*detects* the device (libudev tells us it exists and its identity), but it
reports the device through `describe()` with
`unavailable_reason == .permission_denied` and logs a one-time hint. The pad
will not produce usable input until permissions are fixed.

### Option A — udev `uaccess` rule (recommended)

Install the sample rule so the logged-in user automatically gets access to any
joystick/gamepad node, no group membership or re-login required:

```sh
sudo cp share/udev/99-labelle-gamepads.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=input
```

Then replug the controller (or re-trigger udev as above). The `uaccess` tag
grants access to whoever is logged in at the seat, which is the modern
systemd-logind approach and survives across users.

### Option B — input group

```sh
sudo usermod -aG input "$USER"
```

Log out and back in (group membership is applied at login) and replug the
controller.

## Flatpak

Sandboxed Flatpak builds must request raw input-device access in the manifest:

```yaml
finish-args:
  - --device=input    # /dev/input/event* for evdev/udev gamepad detection
```

`--device=input` (added in flatpak 1.11) exposes the input device nodes inside
the sandbox. Without it the detection source sees no controllers (or only ones
the portal forwards). `--device=all` also works but is broader than needed.
