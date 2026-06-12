"""Drive a REAL OS-level virtual Xbox 360 controller via ViGEmBus.

Creates an XInput pad that Windows (and therefore SDL2 / the labelle toolkit)
sees as genuine hardware, then loops a clear input pattern so a separate
monitor process can observe it. Each action is printed with an elapsed
timestamp so the feeder timeline can be matched against what the toolkit
reports.

Usage: python feeder.py [seconds]
"""
import sys
import time
import vgamepad as vg

DURATION = float(sys.argv[1]) if len(sys.argv) > 1 else 22.0
B = vg.XUSB_BUTTON

t0 = time.monotonic()
def log(msg):
    print(f"[{time.monotonic() - t0:5.1f}s] feeder: {msg}", flush=True)

pad = vg.VX360Gamepad()
log("virtual Xbox 360 pad created (ViGEmBus)")
time.sleep(2.0)  # let the monitor catch the connect

def tap_button(name, btn, hold=1.2, gap=0.5):
    log(f"press {name}")
    pad.press_button(button=btn); pad.update()
    time.sleep(hold)
    pad.release_button(button=btn); pad.update()
    log(f"release {name}")
    time.sleep(gap)

def stick(name, lx=0.0, ly=0.0, hold=1.2, gap=0.5):
    log(f"left stick -> {name}")
    pad.left_joystick_float(x_value_float=lx, y_value_float=ly); pad.update()
    time.sleep(hold)
    pad.left_joystick_float(x_value_float=0.0, y_value_float=0.0); pad.update()
    log("left stick -> center")
    time.sleep(gap)

def trigger(name, value=1.0, hold=1.2, gap=0.5):
    log(f"right trigger -> {name}")
    pad.right_trigger_float(value_float=value); pad.update()
    time.sleep(hold)
    pad.right_trigger_float(value_float=0.0); pad.update()
    log("right trigger -> released")
    time.sleep(gap)

# Repeat the sequence until DURATION elapses so the monitor sees full cycles
# regardless of small start-up skew between the two processes.
cycle = 0
while time.monotonic() - t0 < DURATION:
    cycle += 1
    log(f"--- cycle {cycle} ---")
    tap_button("A (south)", B.XUSB_GAMEPAD_A)
    tap_button("B (east)", B.XUSB_GAMEPAD_B)
    tap_button("D-Pad Up", B.XUSB_GAMEPAD_DPAD_UP)
    tap_button("Start", B.XUSB_GAMEPAD_START)
    stick("full LEFT", lx=-1.0)
    trigger("full pull", value=1.0)

log("done — releasing pad")
del pad
