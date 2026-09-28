# Shared provider configuration schema

`project.labelle` accepts `.provider_config`, shared with labelle-cli:

```zig
.provider_config = .{
    .{ .package = "labelle-example", .file = "providers/example.json" },
},
```

Each row has exactly `package` and `file`. A package identity is a non-empty
string that exactly matches a plugin `.name` declared in `.plugins`, and must be
unique in the mapping. There is no separate character grammar: any name the
plugin scanner accepts (including digit-leading ones such as `3d_renderer`) is
valid here once declared; an undeclared name is rejected. Files use
project-relative paths with forward slashes; absolute/drive paths, backslashes,
`..` and empty components are rejected. The mapping defaults to an empty list.

The assembler validates the mapping structure in its normal project parser,
including projects whose plugin `.params` bags require extraction. It does not
load the JSON or add its contents to generated game code. The CLI resolves the
provider, checks file existence/type, canonical containment and JSON syntax,
then supplies the absolute path in the command context. The provider owns the
JSON schema and semantic validation.

`plugin.labelle` manifest v2 preserves the existing runtime declarations and
adds CLI-owned provider commands/hooks. The assembler accepts and loads those
runtime declarations without executing the CLI extension. Pack manifests remain
on v1. Unsupported future plugin versions are still errors.

`src/provider_settings.zig` is mirrored by the CLI's corresponding schema
module. Keep their field shapes and validation rules synchronized. The focused
`zig build test-provider-config` target exercises both parser paths and the
plugin/pack version boundaries; normal `zig build test` also collects the tests.

Merge/release this assembler support before migrating projects to the CLI's new
mapping. Old assembler versions reject `.provider_config`; no compatibility
alias or implicit version replacement is provided.
