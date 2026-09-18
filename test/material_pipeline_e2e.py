"""Real shaderc + generated Zig fixture; writes only under this checkout's cache."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zlib

p = argparse.ArgumentParser()
for option in ("zig", "shaderc", "core", "zbgfx"):
    p.add_argument("--" + option, required=True)
args = p.parse_args()
repo = Path(__file__).resolve().parents[1]
cache = repo / ".zig-cache"
cache.mkdir(exist_ok=True)
root = Path(tempfile.mkdtemp(prefix="material-e2e-", dir=cache))
for name in ("material_build.zig", "material_schema.zig"):
    shutil.copy2(repo / "src" / name, root / name)
for name in ("build.zig", "test.zig"):
    shutil.copy2(repo / "test/material_fixture" / name, root / name)
# Compile the exact guard emitted into game main.zig, not a rewritten facsimile.
guard_text = (repo / "src/component_collisions.zig").read_text(encoding="utf-8").split("pub const plugin_guard =", 1)[1].split("\n;\n", 1)[0]
guard = "\n".join(line.lstrip()[2:] for line in guard_text.splitlines() if line.lstrip().startswith("\\\\"))
(root / "guard.zig").write_text('const std = @import("std");\n' + guard.replace("fn rejectComponentCollisions", "pub fn rejectComponentCollisions"), encoding="utf-8")
test_source = (root / "test.zig").read_text(encoding="utf-8")
test_source += '\nconst guard = @import("guard.zig");\nconst Plugin = struct { pub const Components = struct { pub const Other = struct {}; }; };\ncomptime { guard.rejectComponentCollisions(&.{"Water"}, .{Plugin}); }\n'
(root / "test.zig").write_text(test_source, encoding="utf-8")
relative = lambda path: os.path.relpath(Path(path).resolve(), root).replace("\\", "/")
fingerprint = (zlib.crc32(b"material_fixture") << 32) | 12345
(root / "build.zig.zon").write_text(
    '.{ .name = .material_fixture, .version = "0.0.0", .fingerprint = 0x%x, '
    '.minimum_zig_version = "0.16.0", .dependencies = .{ '
    '.material_shaderc = .{ .path = "%s" }, .core = .{ .path = "%s" } }, .paths = .{""}, }'
    % (fingerprint, relative(args.zbgfx), relative(args.core)), encoding="utf-8")
descriptor = {"version": 1, "fragment": "fs.sc", "targets": ["spv", "glsl", "essl", "mtl"],
              "parameters": [{"name": "u_tint", "kind": "vec4", "defaults": [1, 1, 1, 1]}],
              "textures": [{"name": "s_mask", "sampler": "linear"}]}
shader = ('$input v_color0, v_texcoord0\n#include <bgfx_shader.sh>\n#include "color.sh"\n'
          '#include <shared/footprint.sc>\n'
          'SAMPLER2D(s_tex, 0);\nuniform vec4 u_tint;\n'
          'void main() { gl_FragColor = texture2D(s_tex, v_texcoord0) * v_color0 * u_tint * TINT * SHARED; }\n')
(root / "materials/shared").mkdir(parents=True)
(root / "materials/shared/footprint.sc").write_text("#define SHARED vec4(1.0)\n", encoding="utf-8")
for name in ("water", "fog", "lamp"):
    folder = root / "materials" / name
    folder.mkdir(parents=True)
    (folder / "material.json").write_text(json.dumps(descriptor), encoding="utf-8")
    (folder / "fs.sc").write_text(shader, encoding="utf-8")
    (folder / "color.sh").write_text("#define TINT vec4(1.0)\n", encoding="utf-8")

def build(ok=True, diagnostic=None):
    result = subprocess.run([args.zig, "build", "-Dshaderc=" + str(Path(args.shaderc).resolve()),
                             "--summary", "all"], cwd=root, text=True, capture_output=True)
    output = result.stdout + result.stderr
    if (result.returncode == 0) != ok or (diagnostic and diagnostic not in output):
        raise AssertionError(output)
    return output

initial = build()
assert "tests passed" in initial or "1 pass" in initial, initial
cached = build()
for variant in descriptor["targets"]:
    assert f"shader fog ({variant}) (fog.{variant}.bin) cached" in cached, cached
(root / "materials/fog/color.sh").write_text("#define TINT vec4(0.5)\n", encoding="utf-8")
changed = build()
for variant in descriptor["targets"]:
    assert f"shader fog ({variant}) (fog.{variant}.bin) success" in changed, changed
    assert f"shader water ({variant}) (water.{variant}.bin) success" in changed, changed
(root / "materials/shared/footprint.sc").write_text("#define SHARED vec4(0.75)\n", encoding="utf-8")
shared_changed = build()
for variant in descriptor["targets"]:
    assert f"shader fog ({variant}) (fog.{variant}.bin) success" in shared_changed, shared_changed
    assert f"shader lamp ({variant}) (lamp.{variant}.bin) success" in shared_changed, shared_changed
(root / "test.zig").write_text(test_source + '\ncomptime { guard.rejectComponentCollisions(&.{"Other"}, .{Plugin}); }\n', encoding="utf-8")
build(False, "duplicate component registration 'Other'")
(root / "test.zig").write_text(test_source + '\ncomptime { guard.rejectComponentCollisions(&.{}, .{Plugin, Plugin}); }\n', encoding="utf-8")
build(False, "duplicate component registration 'Other'")
(root / "test.zig").write_text(test_source, encoding="utf-8")
(root / "materials/fog/color.sh").write_text('#include "../outside.sc"\n', encoding="utf-8")
build(False, "EscapingShaderInclude")
(root / "materials/fog/color.sh").write_text("#define TINT vec4(1.0)\n", encoding="utf-8")
(root / "materials/fog/fs.sc").write_text(shader + "\ninvalid shader syntax!\n", encoding="utf-8")
build(False, "shader fog")
(root / "materials/fog/fs.sc").write_text(shader, encoding="utf-8")
descriptor["targets"] = ["glsl"]
(root / "materials/fog/material.json").write_text(json.dumps(descriptor), encoding="utf-8")
build(False, "target requires 'spv'")
print("PASS: 12 real shader variants, generated core descriptors, cached rebuild, include invalidation, escaping include rejection, compiler failure, missing target diagnostic")
print("Evidence fixture:", root)
