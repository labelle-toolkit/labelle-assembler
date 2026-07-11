# Plugin parameters (`.params`)

Schema-declared, validated at generate time, delivered comptime
(labelle-assembler#591, epic labelle-engine#237, RFC #730 rev 13).

Plugin-specific options never become bespoke fields on the `project.labelle`
plugin entry — they ride the generic `.params` bag:

```zig
.plugins = .{
    .{ .name = "scripting", .repo = "github.com/labelle-toolkit/labelle-scripting",
       .version = "0.4.0", .params = .{ .language = "lua" } },
    .{ .name = "pathfinder", .repo = "github.com/labelle-toolkit/labelle-pathfinder",
       .version = "4.1.0", .params = .{ .grid_size = 32, .diagonals = true } },
},
```

Values may be strings, integers, floats, bools, or enum literals
(`.language = .lua` is accepted as the string `"lua"`).

## Declaring the schema (plugin author)

A plugin publishes the params it accepts in its `plugin.labelle`:

```zig
.{
    .name = "scripting",
    .manifest_version = 1,
    .params = .{
        .{ .name = "language", .type = .@"enum",
           .values = .{ "lua", "typescript", "ruby", "rust", "crystal", "go", "csharp" },
           .required = true },
        .{ .name = "heap_kb", .type = .i64, .default = .{ .i64 = 256 } },
        .{ .name = "trace", .type = .bool, .default = .{ .bool = false } },
        .{ .name = "tick_budget", .type = .f64 }, // optional, no default
    },
}
```

Schema rules (rejected at manifest load, plugin named):

- `name` must be a valid Zig identifier (it becomes a `pub const`), unique
  across entries.
- `type` is one of `.str`, `.i64`, `.f64`, `.bool`, `.@"enum"`.
- `.@"enum"` requires a non-empty `.values` list; `.values` is invalid on
  every other type. Enum defaults ride `.str` and must be a member of
  `.values`.
- `default`'s union tag must match `type`; `required = true` and a `default`
  are mutually exclusive.

## Generate-time validation

The assembler validates each entry's `.params` against the attached plugin's
schema **before the target dir is created**:

- unknown key → error listing the plugin's declared params,
- wrong value type → error naming plugin + param + expected type
  (an integer literal is accepted for an `.f64` param),
- out-of-vocabulary enum value → error listing the allowed values,
- missing `required` param → error with the exact `.params` line to add,
- `.params` on a plugin that declares **no** schema →
  `error.PluginParamsNotAccepted`.

## Comptime delivery

For every schema-bearing plugin the assembler resolves the final set
(project values + schema defaults; optional params without a default are
omitted) and generates `plugin_<name>_params.zig` next to the generated
build.zig:

```zig
pub const language: []const u8 = "lua";
pub const heap_kb: i64 = 256;
pub const trace: bool = false;
```

The generated build.zig wires it into the plugin's module via the existing
`overrideImport` machinery under the fixed import name `plugin_config`, so
plugin code reads zero-cost comptime values:

```zig
const cfg = @import("plugin_config");
const heap = cfg.heap_kb * 1024;
const has_budget = @hasDecl(cfg, "tick_budget"); // optional, no default
```

Params-less plugins are byte-identical: no schema → no generated module, no
wiring, no output drift.

## Migration note (#589 → #591)

`scripting`'s `language` used to be the one natively-recognized `.params`
key. It now lives on the scripting plugin's schema like any other param; the
assembler keeps only the policy validations (supported-language vocabulary,
at most one scripting plugin, the script-dir scan — `language_policy.zig`)
and the splice that consumes the declared language.
