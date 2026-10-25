# gdzig-zlint

ZLint with the gdzig `CODE_STYLE` rules compiled in.

ZLint custom rules are a build-time feature. The stock `zlint` binary cannot
load a rules directory, so this repository builds a `gdzig-zlint` binary from a
pinned ZLint release plus the rules in `rules/`.

## Rules

| Rule | Checks |
| --- | --- |
| `gdzig-imports-last` | Imports and import-derived aliases are at the bottom, grouped std, third-party, project, with blank lines between groups |
| `gdzig-file-name-case` | A file with top-level container fields is a type and uses TitleCase; otherwise it is a namespace and uses snake_case |
| `gdzig-import-alias-case` | An import alias matches the imported file's name, or the selected member of a namespace file |
| `gdzig-tests-last` | Tests are at file scope, grouped after production declarations and before the final imports; `testing` sits directly above the first test |

All four rules skip generated `*.mixin.zig` and `*.replace.zig` fragments.

## Install the binary

The release assets are single executables named
`gdzig-zlint-<os>-<arch>`. Install them with mise's `github` backend:

```toml
[tools]
"github:gdzig/gdzig-zlint" = "0.1.0"
```

The repository is private, so mise needs a token with `Contents: read` for
`gdzig/gdzig-zlint`:

```sh
export MISE_GITHUB_TOKEN="ghp_..."
mise token github   # confirm mise finds the token
mise use -g github:gdzig/gdzig-zlint@0.1.0
```

An existing `GITHUB_TOKEN` or `gh auth login` also works. The asset installs
as `gdzig-zlint`; mise also verifies the release checksum. Pin a version: a
brand-new release can be hidden from `latest` by mise's `minimum_release_age`
cooldown until it ages. Then run it like ZLint:

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

Do not add `--fix` initially. ZLint 0.10.0 can apply dangerous built-in fixes
with plain `--fix`, and the custom rules are diagnostics-only.

## Configure a repository

Copy `zlint.template.json` to the repository as `zlint.json` and adjust the
project package list. `common`, `compat`, and `gdzig` are project packages in
the gdzig repository; everything else with a bare package name is third-party.
The generated `build_options` module is grouped with std.

```json
{
  "$schema": "https://raw.githubusercontent.com/DonIsaac/zlint/refs/tags/v0.10.0/zlint.schema.json",
  "rules": {
    "gdzig-imports-last": [
      "warn",
      { "project_packages": ["build_options", "common", "compat", "gdzig"] }
    ],
    "gdzig-file-name-case": "warn",
    "gdzig-import-alias-case": "warn",
    "gdzig-tests-last": "warn"
  }
}
```

The upstream JSON schema does not know the custom rule names, so editors may
flag those keys as unknown. ZLint still parses and applies them.

Rule options:

- `gdzig-imports-last`
  - `skip_fragments` (default `true`)
  - `check_group_order` (default `true`)
  - `check_blank_lines` (default `true`)
  - `project_packages` (default `[]`; `build_options` is always std)
- `gdzig-file-name-case`
  - `skip_fragments` (default `true`)
- `gdzig-import-alias-case`
  - `skip_fragments` (default `true`)
- `gdzig-tests-last`
  - `skip_fragments` (default `true`)
  - `check_testing_namespace` (default `true`)

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
zig build -Doptimize=ReleaseFast -Dversion=0.1.0
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
- Custom rules have no documented autofix API. Every rule is diagnostics-only.
- The vendored ZLint source is pinned to v0.10.0 commit
  `3ef67af7dfed776cb03012563942cdf3a97f1b59`. `patches/` contains the small
  patch that raises ZLint's comptime branch quota; without it, the rule
  configuration struct exceeds the default quota when several custom rules are
  registered.
- ZLint's `ignore` handling has rough edges. The rules skip fragments
  themselves, and CI should pass tracked files explicitly:
  `git ls-files '*.zig' | gdzig-zlint --stdin`.
- The rule set is deliberately diagnostics-first. Fix the repository or adjust
  the rule before turning on `--deny-warnings` in CI.

## Release process

Push a tag such as `v0.1.0`. `.github/workflows/release.yml` builds
`gdzig-zlint` for macOS and Linux, publishes checksums, and attaches the
binaries to the GitHub release.

## License

This repository follows the gdzig organisation's license policy. The release
binary includes ZLint, which is MIT licensed; see `THIRD_PARTY_NOTICES.md`.
