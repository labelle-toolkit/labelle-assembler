#!/usr/bin/env python3
"""Exercise the emitted strip option with a real Zig WASM build, without providers."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', required=True)
    args = parser.parse_args()
    template = (Path(__file__).resolve().parents[1] / 'src/templates/build_zig.txt').read_text()
    start = template.index('            .strip = strip: {', template.index('.wasm_exe_start'))
    end = template.index('            },', start) + len('            },')
    strip_field = template[start:end]
    with tempfile.TemporaryDirectory(prefix='wasm-strip-') as directory:
        root = Path(directory)
        (root / 'main.zig').write_text('export fn add(a: u32, b: u32) u32 { return a + b; }\n')
        (root / 'build.zig').write_text('''const std = @import("std");
pub fn build(b: *std.Build) void {
    const lib = b.addLibrary(.{
        .name = "probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = .ReleaseSafe,
''' + strip_field + '''
        }),
    });
    b.installArtifact(lib);
}
''')
        # Reuse the same generated build and cache: changing only the environment
        # must change the compiler flags and output, without regeneration.
        for value in (None, '1', '0', 'true', 'false', '', 'invalid'):
            env = os.environ.copy()
            env.pop('LABELLE_WASM_STRIP', None)
            if value is not None:
                env['LABELLE_WASM_STRIP'] = value
            result = subprocess.run([args.zig, 'build', '--verbose'], cwd=root, env=env,
                                    text=True, capture_output=True, timeout=120)
            output = result.stdout + result.stderr
            if value in ('', 'invalid'):
                assert result.returncode != 0, output
                assert 'LABELLE_WASM_STRIP must be 1, 0, true or false' in output, output
            else:
                assert result.returncode == 0, output
                binary = (root / 'zig-out/lib/libprobe.a').read_bytes()
                keep_symbols = value not in ('1', 'true')
                assert (b'.debug_info' in binary) == keep_symbols, (value, output)
            print(f'PASS LABELLE_WASM_STRIP={value!r}', flush=True)


if __name__ == '__main__':
    main()
