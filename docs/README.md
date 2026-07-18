# Boo documentation

Grouped by what you came for, following the [Diátaxis](https://diataxis.fr/) split: get
started, look something up, contribute, or understand a decision. New users want the
first section; the rest is there when you need it.

## Get started

Install Boo and get your first transcript. Each guide is self-contained, no cross-referencing another platform's page.

- [install-macos.md](install-macos.md) — install, model, permissions, troubleshooting
- [install-linux.md](install-linux.md) — install, model, the portal permissions the hotkey needs
- [install-windows.md](install-windows.md) — install, model, the permission model (experimental)
- [models.md](models.md) — choose, download, and switch speech models; streaming; non-English

## Reference

Precise facts to look up while working.

- [features.md](features.md) — every feature, its status on each platform, and how to accept it (UAT)
- [platform-status.md](platform-status.md) — exactly what the README's working / preview / experimental mean
- [ui-spec.md](ui-spec.md) — the macOS build as the cross-platform UI ground truth
- [logging-and-crash-reporting.md](logging-and-crash-reporting.md) — log locations and the crash-report format
- [../SECURITY.md](../SECURITY.md) — the trust boundary and how to report an issue

## Contributing

Build, test, and extend Boo. See also the top-level [CONTRIBUTING.md](../CONTRIBUTING.md).

- [development.md](development.md) — build each frontend, packaging, the release checklist, project layout
- [testing.md](testing.md) — the five-language test and coverage suites, and how to run them
- [ghostty.md](ghostty.md) — how Boo injects text into Ghostty, per platform

## Explanation and design records

Background and the "why" behind decisions.

- [transcription-quality.md](transcription-quality.md) — research and plan for improving accuracy
- [ui-feasibility.md](ui-feasibility.md) — the native mechanism for each feature, per OS
- [model-onboarding.md](model-onboarding.md) — design record for the pick-and-download first-run dialog
- [roadmap.md](roadmap.md) — where Boo is headed, distilled from a field survey
- [specs/windows-support.md](specs/windows-support.md) — the Windows support specification
