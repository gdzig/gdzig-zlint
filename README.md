# gdzig-zlint

ZLint with the gdzig `CODE_STYLE` rules compiled in.

ZLint custom rules are a build-time feature. The stock `zlint` binary cannot
load a rules directory, so this repository builds a `gdzig-zlint` binary from a
pinned ZLint release plus the rules in `rules/`.

## Rules

| Rule | Checks |
| --- | --- |
| `gdzig-imports-placement` | Imports and import-derived aliases are placed at the configured position: `bottom` (default) or `top` |
| `gdzig-imports-sorted` | Imports are ordered std, package, file, with root groups alphabetical and separated by blank lines; safe autofix available |
| `gdzig-file-name-case` | A file with top-level container fields is a type and uses TitleCase; otherwise it is a namespace and uses snake_case |
| `gdzig-import-alias-case` | An import alias matches the imported file's name, or the selected member of a namespace file |
| `gdzig-tests-last` | Tests are at file scope, grouped after production declarations and before the final imports; `testing` sits directly above the first test |
| `gdzig-trailing-comma` | Nonempty container declarations (enums excluded) and multiline struct literals end with a trailing comma, so `zig fmt` puts each field on its own line; safe autofix available |
| `gdzig-public-docs` | Public functions, including extern declarations, have a `///` doc comment (presence only) |
| `gdzig-inferred-initializers` | Uses `.{}` and `.init(...)` when the destination type is known from an annotation, a return type, or an unannotated initializer that names a type; safe autofix available |
| `gdzig-testing-usage` | Direct references to a local `testing` namespace are limited to test code; member-access checking is opt-in |

Hand-written `*.mixin.zig` and `*.replace.zig` fragments are linted by default.
`gdzig-file-name-case` skips them because a fragment's contents cannot be
classified as a type or a namespace on its own. Set `skip_fragments` on any
rule to exclude fragments. The template also enables ZLint's built-in
`line-length` rule at 120 columns.

## Install the binary

The release assets are single executables named
`gdzig-zlint-<os>-<arch>`. Install them with mise's `github` backend:

```toml
[tools]
"github:gdzig/gdzig-zlint" = "0.6.1"
```

```sh
mise use -g github:gdzig/gdzig-zlint@0.6.1
```

The asset installs as `gdzig-zlint`; mise also verifies the release checksum.
Pin a version: a brand-new release can be hidden from `latest` by mise's
`minimum_release_age` cooldown until it ages. Then run it like ZLint:

```sh
gdzig-zlint --version
gdzig-zlint .
```

Pre-commit:

```yaml
- repo: local
  hooks:
    - id: gdzig-zlint
      name: Run gdzig-zlint
      entry: gdzig-zlint
      language: system
      types: [zig]
      # Add --deny-warnings after the existing violations are cleaned up.
```

`gdzig-imports-sorted` has a safe autofix when the imports are already at the
bottom of the file. `gdzig-trailing-comma` and `gdzig-inferred-initializers`
also have safe autofixes. The other custom rules are diagnostics-only. ZLint
0.10.0 can also apply dangerous built-in fixes with plain `--fix`, so review the
diff before enabling it in pre-commit. The import-order fix skips blocks
containing comments or interleaved declarations.

For an unannotated declaration, `gdzig-inferred-initializers` inserts the
inferred annotation and drops the prefix. It reports without a fix when the
replaced span contains a comment, or when the declaration has `align`,
`addrspace`, or `section`, because a single-span replacement would remove that
text.

Run `gdzig-zlint --fix`, then `zig fmt`, after enabling
`gdzig-trailing-comma`. The rule adds the comma; `zig fmt` expands the fields.
Multiline string fields are diagnostics-only because inserting a comma at the
token boundary would change the string value.

## Configure a repository

Copy `zlint.template.json` to the repository as `zlint.json`. The two import
rules are independent: enable either one, or both. `gdzig-imports-placement`
checks placement and takes a `position` of `bottom` (default) or `top`.
`gdzig-imports-sorted` checks that imports are ordered std, then bare package
names, then file imports, with root groups alphabetical inside each section and
separated by a blank line. `build_options` is a package import unless it is
added to `std_modules`.

This repository checks in its own `zlint.json`, derived from the template with
local `ignore` entries for `vendor/`, build outputs, and snapshots. Consumers
should copy the template rather than this file.

Upgrading: rename `gdzig-imports-location` (0.4.0) or `gdzig-imports-last`
(0.3.0 and earlier) to `gdzig-imports-placement`. The default `position` is
`bottom`, so placement behavior is unchanged. From 0.2.0, also move
`std_modules` to `gdzig-imports-sorted`.

```json
{
  "$schema": "https://raw.githubusercontent.com/DonIsaac/zlint/refs/tags/v0.10.0/zlint.schema.json",
  "rules": {
    "gdzig-imports-sorted": [
      "warn",
      { "std_modules": ["std", "builtin"] }
    ],
    "gdzig-imports-placement": [
      "warn",
      { "position": "bottom" }
    ],
    "gdzig-file-name-case": "warn",
    "gdzig-import-alias-case": "warn",
    "gdzig-tests-last": "warn",
    "gdzig-trailing-comma": "warn",
    "gdzig-public-docs": "warn",
    "gdzig-inferred-initializers": "warn",
    "gdzig-testing-usage": "warn",
    "line-length": ["warn", { "max_length": 120 }]
  }
}
```

The upstream JSON schema does not know the custom rule names, so editors may
flag those keys as unknown. ZLint still parses and applies them.

Rule options:

- `gdzig-imports-sorted`
  - `skip_fragments` (default `false`)
  - `std_modules` (default `["std", "builtin"]`; order sets priority inside the std section)
- `gdzig-imports-placement`
  - `position` (default `"bottom"`; `bottom` or `top`)
  - `skip_fragments` (default `false`)
- `gdzig-file-name-case`
  - `skip_fragments` (default `true`)
- `gdzig-import-alias-case`
  - `skip_fragments` (default `false`)
- `gdzig-tests-last`
  - `skip_fragments` (default `false`)
  - `check_testing_namespace` (default `true`)
- `gdzig-trailing-comma`
  - `skip_fragments` (default `false`)
- `gdzig-public-docs`
  - `skip_fragments` (default `false`)
- `gdzig-inferred-initializers`
  - `skip_fragments` (default `false`)
  - `check_returns` (default `true`)
- `gdzig-testing-usage`
  - `skip_fragments` (default `false`)
  - `namespace` (default `"testing"`)
  - `check_identifier_references` (default `true`)
  - `report_member_access` (default `false`)
  - `allow_test_paths` (default `true`)

`gdzig-inferred-initializers` handles annotated variable declarations, returns
whose type matches the explicit initializer, and unannotated declarations whose
initializer names a type (`Type.fn(...)`, `Type.member`, `Type{...}`). A local
type is checked against the symbol table: a call must be an exported function
returning that type (not `!T` or `?T`), and a bare member must be an enum or
error member. Imported and cross-file paths use Zig's naming contract: the
rightmost type name is TitleCase and the selected member starts lowercase, so
`std.ArrayList(u8).init(...)` and `godot.Object.init()` are flagged while
`std.mem.zeroes(...)` is not. The fallback cannot see an imported return type,
so an imported TitleCase factory that returns a value can be misread as a type
construction, and a bare imported member such as `Foo.init` can be a function
reference rather than a value. An unannotated `[_]T{...}` is not reported
because the annotation cannot spell the inferred length. The rule does not
inspect function arguments.
`gdzig-testing-usage` ignores `std.testing` aliases and
paths under `test` or `tests`. It reports local references such as
`testing.helper()` outside test code. Set `report_member_access` to also check
`module.testing.helper`; that can reject legitimate fixture tools, so it is
off by default. The rule cannot check whether a namespace is `pub` for external
callers.

These are fields on the custom rules, parsed by ZLint from `zlint.json`. They
are not ZLint built-in settings.

## Build from source

Requirements:

- Zig 0.16.x. ZLint 0.10.0 does not build with Zig 0.17.
- Git, to fetch the pinned ZLint source.

```sh
mise run setup     # fetch zlint v0.10.0 into vendor/zlint
zig build          # installs zig-out/bin/gdzig-zlint
zig build test     # rule tests plus self-lint
zig build lint     # self-lint only
```

`zig build lint` runs the built rules against this repository using the
checked-in `zlint.json`, and fails on warnings. `zig build test` runs the rule
tests and the same lint. CI lints tracked Zig files explicitly with
`git ls-files '*.zig' | gdzig-zlint --stdin --deny-warnings`.

The release binary is built with:

```sh
zig build -Doptimize=ReleaseFast -Dversion=0.6.1
```

`zig build -Doptimize=ReleaseFast` is the default `install` step. The binary is
installed as `gdzig-zlint`.

### Source consumers

`build.zig` exposes the rule paths for repositories that build ZLint directly:

```zig
const gdzig_zlint = @import("gdzig_zlint");
const rules_dep = b.dependency("gdzig_zlint", .{});
const zlint_dep = b.dependency("zlint", .{
    .custom_rules = gdzig_zlint.customRulePaths(rules_dep),
});
const lint = b.step("lint", "run gdzig lint");
lint.dependOn(&@import("zlint").addRunLint(b, zlint_dep).step);
```

This path requires Zig 0.16.x and a ZLint source checkout. ZLint 0.10.0's
release tarball is not usable as a Zig package dependency because its
`build.zig.zon` omits `test/` (upstream issue #433). Use a path dependency or a
patched fork. Because this repository declares `vendor/zlint` as a path
dependency, use a local checkout after `mise run setup`, not a fetched tarball,
until upstream #433 is fixed. The release binary is the primary distribution.

## Design notes and limitations

- Custom rules are compiled as separate modules. They cannot share a relative
  helper module: the same file would belong to more than one module. The
  import helpers are therefore duplicated in the rule files. This is a ZLint
  0.10.0 limitation.
- Custom rule fixes use ZLint's fix API. The vendored patch exposes
  `zlint.linter.fix` to custom rules; without it, ZLint 0.10.0 keeps the fix
  types private. `gdzig-imports-sorted` is safe-fixable. It rewrites a
  contiguous bottom import block and skips blocks containing comments or
  interleaved declarations. `gdzig-trailing-comma` and
  `gdzig-inferred-initializers` also have safe fixes. The remaining rules are
  diagnostics-only.
- The vendored ZLint source is pinned to v0.10.0 commit
  `3ef67af7dfed776cb03012563942cdf3a97f1b59`. `patches/` contains two small
  patches: one raises ZLint's comptime branch quota for several custom rules,
  and one exports the fix module.
- ZLint's `ignore` handling has rough edges. Rules can skip fragments with
  `skip_fragments`, and CI passes tracked files explicitly:
  `git ls-files '*.zig' | gdzig-zlint --stdin --deny-warnings`.
- Hand-written fragments are in scope. `*.mixin.zig` and `*.replace.zig` are
  linted by default. Generated outputs are out of scope, so consumers should
  ignore generated directories and re-include fragment files where needed.
  ZLint 0.10.0 has one rule set per run and no per-directory overrides, so
  correctness-only linting of generated output needs a separate invocation
  and config.
- ZLint 0.10.0 has no rule groups, presets, or `extends`. A preset is a
  complete `zlint.json`; this repository ships `zlint.template.json` as the
  single recommended set.
- `gdzig-imports-sorted` classifies bare module names as package imports and
  paths as file imports. It has no project graph, so a project's own bare module
  sorts with third-party packages. This is a deliberate approximation of the
  standard's third-party/project split; use a path import when the distinction
  matters.
- Run `--fix` for the import order, move any misplaced imports by hand, review
  the diff, then turn on `--deny-warnings` in CI. The custom import-order fix
  is conservative; ZLint's built-in fixes need separate review.

## Release process

Push a tag such as `v0.6.1`. `.github/workflows/release.yml` builds
`gdzig-zlint` for macOS and Linux, publishes checksums, and attaches the
binaries to the GitHub release.

## License

This project is MIT licensed. See `LICENSE`. The release binary includes ZLint
and other MIT-licensed components; see `THIRD_PARTY_NOTICES.md`.
