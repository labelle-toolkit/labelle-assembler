# Android APK asset source

Set `.android.load_assets_from_apk = true` only with packaging that consumes
`<target>/apk_assets.json`. It is off by default until labelle-android adopts
the contract. Desktop/web output continues to embed resources.

The version-1 manifest lists paths relative to the generated target directory.
For each path `P`, stage the file as APK member `assets/P` using DEFLATE, once.
Do not also embed or stage a fallback PNG when the selected texture is ASTC.
The manifest deliberately excludes video: videos still need STORED members
for `AAsset_openFileDescriptor64`. Turning the option off emits an empty
manifest, avoiding stale packaging instructions after regeneration.

Atlas JSON is read and parsed at startup, then freed. The catalog retains the
binary asset's path string, with a loader wrapper installed before the first
acquire. Its existing async decode worker reads through `AAsset_read` (including
partial reads), delegates to the existing image/audio/font decoder and frees
the source buffer. Lazy assets are not read at registration. A catalog release
or GPU surface recovery reuses the path and reads again when acquired. Decoded
pixels, samples and font data retain the existing ownership contract. Font
parameters live in a comptime declaration, also in callback-based lifecycles.

This is assembler-only. It uses core's existing Android backend context to
find the current NativeActivity; it adds no runtime-service registration.
The native hook must stay valid until catalog workers join during shutdown,
as required by the existing engine/backend lifetime. It does not cache an
Activity or AAsset pointer across acquisitions.

Validation: the full assembler suite passed (3,467 tests, 16 skipped) before
the dedicated three-test APK step was added; that step also passes.
`zig build test-apk-assets` exercises both lifecycle emitters,
opt-in/default selection, fallback exclusion, path validation and short/error
reads. The runtime ABI fixture can be compiled without an Android device:

```
zig build-obj -target aarch64-linux-android -fPIC --dep apk \
  -Mroot=test/fixtures/apk_runtime_compile.zig \
  -Mapk=src/codegen/blocks/apk_runtime.zig -fno-emit-bin
```

This fixture checks the generated runtime against the public catalog ABI;
it is not an on-device test. No Android device is attached to this host.
SM-T505 cold-start, background/resume, async catalog and actual APK-size
measurements remain required when the packaging consumer is available.
