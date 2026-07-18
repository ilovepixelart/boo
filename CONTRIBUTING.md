# Contributing to Boo

Thanks for helping. Boo is a portable Zig core (`src/`) exposed through a stable C API
(`include/boo.h`), with a native frontend per platform (`macos/` Swift, `linux/` GTK4 C,
`windows/` Win32 C). Most changes touch either the core or one frontend.

## Getting set up

- Core, on any OS: `zig build test`.
- A native app: `zig build app` (macOS needs one extra archive step).
- macOS: run `./scripts/make-signing-cert.sh` once so `./bundle.sh` signs with a
  stable certificate and macOS keeps your Accessibility grant across rebuilds
  (ad-hoc signing resets it every build). Free, no Apple account.
- The per-platform build, packaging, release checklist, and project layout are in
  [docs/development.md](docs/development.md); the test and coverage suites in
  [docs/testing.md](docs/testing.md). Full docs index: [docs/](docs/README.md).

## What CI checks, get it green before opening a PR

- **Format**: `zig fmt --check`, `swift format lint --strict macos/Sources`, and
  `clang-format-18` over `linux/src`, `windows/src`, `windows/tests`, and `include`.
- **Tests**: `zig build test` (Debug and ReleaseSafe), the per-frontend logic tests, and
  the Linux/Windows integration harnesses.
- **Coverage and quality**: a SonarCloud gate on new code (coverage, no new issues, no
  unreviewed security hotspots). Prefer extracting a testable unit over padding coverage,
  and exclude only genuinely-untestable OS shell; see [docs/testing.md](docs/testing.md).

## Pull requests

- Small and single-concern. Split anything that outgrows its stated purpose.
- The description states the actual code changes, not a development narrative.
- Subject line: imperative mood, under 72 characters.
- macOS is the UI source of truth; Linux and Windows mirror it. The reference is
  [docs/ui-spec.md](docs/ui-spec.md).

## Reporting

- **Bugs**: open an issue. Dictating on real Windows or Linux hardware and reporting back
  is especially valuable, it is what promotes those platforms past "experimental"
  ([docs/platform-status.md](docs/platform-status.md)).
- **Security**: see [SECURITY.md](SECURITY.md).
