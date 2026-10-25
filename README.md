# gdzig-zlint

ZLint with the gdzig `CODE_STYLE` rules compiled in.

ZLint custom rules are a build-time feature. The stock `zlint` binary cannot
load a rules directory, so this repository builds a `gdzig-zlint` binary from a
pinned ZLint release plus the rules in `rules/`.

## Rules

| Rule | Checks |
| --- | --- |
| `gdzig-imports-last` | Imports and import-derived aliases are placed after all other declarations |
| `gdzig-imports-sorted` | Imports are ordered std, package, file, with root groups alphabetical and separated by blank lines; safe autofix available |
| `gdzig-file-name-case` | A file with top-level container fields is a type and uses TitleCase; otherwise it is a namespace and uses snake_case |
| `gdzig-import-alias-case` | An import alias matches the imported file's name, or the selected member of a namespace file |
| `gdzig-tests-last` | Tests are at file scope, grouped after production declarations and before the final imports; `testing` sits directly above the first test |

All custom rules skip generated `*.mixin.zig` and `*.replace.zig` fragments.

## Install the binary

The release assets are single executables named
`gdzig-zlint-<os>-<arch>`. Install them with mise's `github` backend:

```toml
[tools]
"github:gdzig/gdzig-zlint" = "0.3.0"
```

```sh
mise use -g github:gdzig/gdzig-zlint@0.3.0
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
bottom of the file. The other custom rules, including `gdzig-imports-last`, are
diagnostics-only. ZLint 0.10.0 can also apply dangerous built-in fixes with
plain `--fix`, so review the diff before enabling it in pre-commit. The
import-order fix skips blocks containing comments or interleaved declarations.

## Configure a repository

Copy `zlint.template.json` to the repository as `zlint.json`. The two import
rules are independent: enable either one, or both. `gdzig-imports-last` checks
placement. `gdzig-imports-sorted` checks that imports are ordered std, then bare
package names, then file imports, with root groups alphabetical inside each
section and separated by a blank line. `build_options` is a package import
unless it is added to `std_modules`.

```json
{
  "$schema": "https://raw.githubusercontent.com/DonIsaac/zlint/refs/tags/v0.10.0/zlint.schema.json",
  "rules": {
    "gdzig-imports-sorted": [
      "warn",
      { "std_modules": ["std", "builtin"] }
    ],
    "gdzig-imports-last": "warn",
    "gdzig-file-name-case": "warn",
    "gdzig-import-alias-case": "warn",
    "gdzig-tests-last": "warn"
  }
}
```

The upstream JSON schema does not know the custom rule names, so editors may
flag those keys as unknown. ZLint still parses and applies them.

Rule options:

- `gdzig-imports-sorted`
  - `skip_fragments` (default `true`)
  - `std_modules` (default `["std", "builtin"]`; order sets priority inside the std section)
- `gdzig-imports-last`
  - `skip_fragments` (default `true`)
- `gdzig-file-name-case`
  - `skip_fragments` (default `true`)
- `gdzig-import-alias-case`
  - `skip_fragments` (default `true`)
- `gdzig-tests-last`
  - `skip_fragments` (default `true`)
  - `check_testing_namespace` (default `true`)

These are fields on the custom rules, parsed by ZLint from `zlint.json`. They
are not ZLint built-in settings.

## Build from source

Requirements:

- Zig 0.16.x. ZLint 0.10.0 does not build with Zig 0.17.
- Git, to fetch the pinned ZLint source.

```sh
mise run setup     # fetch zlint v0.10.0 into vendor/zlint
zig build          # installs zig-out/bin/gdzig-zlint
zig build test-rules
```

The release binary is built with:

```sh
zig build -Doptimize=ReleaseFast -Dversion=0.3.0
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
  interleaved declarations. `gdzig-imports-last` and the other rules remain
  diagnostics-only.
- The vendored ZLint source is pinned to v0.10.0 commit
  `3ef67af7dfed776cb03012563942cdf3a97f1b59`. `patches/` contains two small
  patches: one raises ZLint's comptime branch quota for several custom rules,
  and one exports the fix module.
- ZLint's `ignore` handling has rough edges. The rules skip fragments
  themselves, and CI should pass tracked files explicitly:
  `git ls-files '*.zig' | gdzig-zlint --stdin`.
- Run `--fix` for the import order, move any misplaced imports by hand, review
  the diff, then turn on `--deny-warnings` in CI. The custom import-order fix
  is conservative; ZLint's built-in fixes need separate review.

## Release process

Push a tag such as `v0.3.0`. `.github/workflows/release.yml` builds
`gdzig-zlint` for macOS and Linux, publishes checksums, and attaches the
binaries to the GitHub release.

## License

This repository follows the gdzig organisation's license policy. The release
binary includes ZLint, which is MIT licensed; see `THIRD_PARTY_NOTICES.md`.
