#!/usr/bin/env python3
"""
preview_smoke.py — end-to-end smoke check for the LABELLE_PREVIEW pipeline.

Validates a project's `labelle run --LABELLE_PREVIEW=...` path without
having to open the gui:

  1. Snapshots ~/Library/Logs/DiagnosticReports/ before launch (macOS-only).
  2. Starts a TCP listener on an ephemeral port (the gui's role).
  3. Spawns `labelle run --timeout=<dur>` with LABELLE_PREVIEW pointing
     at the listener.
  4. Reads newline-delimited JSON messages from the game over TCP.
  5. Optionally `shm_open`s the advertised region and reads the control
     block + one frame's worth of bytes to assert the producer actually
     wrote pixels (Level 2 — currently macOS Path-A leaves pixels in
     IOSurfaces not SHM, so pixel validation is gated on `format=bgra8`).
  6. Waits for the game to exit, asserts clean exit, asserts no new
     crash dumps appeared.

Usage:
  python3 tools/preview_smoke.py [PROJECT_DIR] [--timeout SECS] [-v]

Exits 0 on pass, non-zero with a failure summary on fail.
"""

import argparse
import ctypes
import errno
import glob
import json
import mmap
import os
import platform
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path

CRASH_DUMP_DIR = Path.home() / "Library" / "Logs" / "DiagnosticReports"
DEFAULT_TIMEOUT = 5  # seconds


# ── Helpers ────────────────────────────────────────────────────────────

class Fail(Exception):
    pass


def snapshot_crash_dumps():
    """macOS-only. Returns set of pre-existing game-*.ips paths."""
    if platform.system() != "Darwin":
        return set()
    return set(glob.glob(str(CRASH_DUMP_DIR / "game-*.ips")))


def new_crash_dumps(pre):
    if platform.system() != "Darwin":
        return []
    # Crash reports can lag a couple seconds after the abort
    deadline = time.time() + 3.0
    while time.time() < deadline:
        post = set(glob.glob(str(CRASH_DUMP_DIR / "game-*.ips")))
        new = post - pre
        if new:
            return sorted(new)
        time.sleep(0.3)
    return []


def shm_open_macos(name: bytes, size: int):
    """POSIX shm_open + mmap on macOS via libc. Returns mmap.mmap or None."""
    libc = ctypes.CDLL("libc.dylib", use_errno=True)
    libc.shm_open.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_int]
    libc.shm_open.restype = ctypes.c_int
    O_RDONLY = 0
    fd = libc.shm_open(name, O_RDONLY, 0)
    if fd < 0:
        eno = ctypes.get_errno()
        return None, f"shm_open({name!r}): {errno.errorcode.get(eno, eno)}"
    try:
        buf = mmap.mmap(fd, size, prot=mmap.PROT_READ)
        return buf, None
    except (OSError, ValueError) as e:
        return None, f"mmap({size}): {e}"
    finally:
        os.close(fd)


# ── Smoke check ────────────────────────────────────────────────────────

def run(project_dir: Path, timeout: int, verbose: bool):
    failures = []
    artifacts = {}

    # 1. Crash dump baseline
    pre_dumps = snapshot_crash_dumps()

    # 2. TCP listener
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    port = server.getsockname()[1]
    # Generous accept timeout — a cold `zig build` of the game can take
    # 30-60s on a sokol+imgui project before the binary even spawns. The
    # gui itself uses 60s for the same reason (see labelle-gui#136).
    server.settimeout(120)

    # 3. Spawn the game
    env = os.environ.copy()
    env["LABELLE_PREVIEW"] = f"127.0.0.1:{port}"
    env["LANG"] = env.get("LANG", "C")
    if verbose:
        print(f"→ spawn: LABELLE_PREVIEW=127.0.0.1:{port} labelle run --timeout={timeout}s")
    proc = subprocess.Popen(
        ["labelle", "run", f"--timeout={timeout}s"],
        cwd=project_dir,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    # 4. Accept + read messages
    conn = None
    messages = []
    raw_buf = b""
    try:
        conn, _ = server.accept()
        conn.settimeout(timeout + 2)
        while True:
            try:
                data = conn.recv(8192)
            except socket.timeout:
                break
            if not data:
                break
            raw_buf += data
            while b"\n" in raw_buf:
                line, raw_buf = raw_buf.split(b"\n", 1)
                line = line.strip()
                if not line:
                    continue
                if not line.startswith(b"{"):
                    # binary frames (heartbeat ticks) — skip for protocol-level checks
                    continue
                try:
                    messages.append(json.loads(line.decode("utf-8", errors="replace")))
                except json.JSONDecodeError:
                    pass
    except socket.timeout:
        failures.append("TCP accept timed out — game never connected back")
    finally:
        if conn:
            try:
                conn.close()
            except Exception:
                pass
        server.close()

    # 5. Wait for game exit
    try:
        stdout, stderr = proc.communicate(timeout=timeout + 10)
    except subprocess.TimeoutExpired:
        proc.kill()
        stdout, stderr = proc.communicate()
        failures.append("game did not exit within timeout+10s; killed")

    artifacts["exit_code"] = proc.returncode
    artifacts["messages"] = [m.get("kind", "?") for m in messages]

    # 6. Protocol assertions
    kinds = artifacts["messages"]
    if "hello" not in kinds:
        failures.append("no `hello` message received")
    frame_offer = next((m for m in messages if m.get("kind") == "frame_offer"), None)
    if not frame_offer:
        failures.append("no `frame_offer` message received")
    bye_received = "bye" in kinds
    # `bye` is best-effort: on the Path-A silent-shutdown path
    # (labelle-assembler#140 workaround), the game _exit(0)s from a
    # signal handler so main()'s `defer sendBye(.normal)` never runs.
    # Treat as warning, not failure.

    # 7. Exit code
    # labelle run --timeout returns 0 on a clean timeout (per CLAUDE.md / observed)
    if proc.returncode not in (0,):
        failures.append(f"non-zero exit code: {proc.returncode}")
        if verbose and stderr:
            tail = stderr.decode("utf-8", errors="replace").splitlines()[-10:]
            print("  stderr tail:")
            for ln in tail:
                print(f"    {ln}")

    # 8. Crash dumps
    new_dumps = new_crash_dumps(pre_dumps)
    if new_dumps:
        failures.append(f"new crash dump(s): {[Path(p).name for p in new_dumps]}")

    # 9. (Level 2) SHM pixel validation if format is plain bgra8
    if frame_offer and frame_offer.get("format") == "bgra8":
        shm_name = frame_offer["shm_name"]
        slot_size = frame_offer["slot_size_bytes"]
        ring_size = frame_offer["ring_size"]
        total = slot_size * ring_size + 4096  # +control block guess
        buf, err = shm_open_macos(shm_name.encode(), total) if platform.system() == "Darwin" else (None, "non-macOS")
        if buf:
            # Quick sanity: at least one byte non-zero somewhere in the ring
            sample = bytes(buf[:slot_size])
            buf.close()
            if all(b == 0 for b in sample):
                failures.append("frame buffer is all zeros — producer wrote nothing")
            else:
                artifacts["frame_nonzero"] = True
        else:
            failures.append(f"SHM open failed: {err}")
    elif frame_offer and frame_offer.get("format") == "iosurface_bgra8":
        # macOS Path-A: pixels in IOSurfaces, not SHM. Pixel validation needs
        # CoreFoundation/IOSurface ctypes shim — skipped for now. Protocol
        # validation above still catches most bugs.
        artifacts["frame_validation"] = "skipped (iosurface_bgra8 — pixels in IOSurfaces, not SHM)"

    # 10. Report
    print("─" * 60)
    if failures:
        print(f"❌ FAIL ({len(failures)} issue(s))")
        for f in failures:
            print(f"   • {f}")
    else:
        print("✅ PASS")
    print("─" * 60)
    print(f"  exit_code:      {artifacts.get('exit_code')}")
    print(f"  messages:       {artifacts.get('messages')}")
    if frame_offer:
        print(f"  frame_offer:    {frame_offer.get('format')}  "
              f"{frame_offer.get('width')}x{frame_offer.get('height')}  "
              f"ring={frame_offer.get('ring_size')}  "
              f"slot_bytes={frame_offer.get('slot_size_bytes')}")
    heartbeats = sum(1 for k in kinds if k == "heartbeat")
    print(f"  heartbeats:     {heartbeats}")
    print(f"  bye received:   {bye_received}{'' if bye_received else '  (expected w/ silent-shutdown #140 workaround)'}")
    if "frame_nonzero" in artifacts:
        print(f"  frame pixels:   non-zero ✓")
    if "frame_validation" in artifacts:
        print(f"  frame pixels:   {artifacts['frame_validation']}")
    print(f"  new crash dumps:{len(new_dumps)}")

    return 0 if not failures else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("project_dir", nargs="?", default=".", help="path to labelle project (default: cwd)")
    ap.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT, help=f"game run duration (default: {DEFAULT_TIMEOUT}s)")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    project_dir = Path(args.project_dir).resolve()
    if not (project_dir / "project.labelle").exists():
        print(f"error: no project.labelle in {project_dir}", file=sys.stderr)
        return 2
    return run(project_dir, args.timeout, args.verbose)


if __name__ == "__main__":
    sys.exit(main())
