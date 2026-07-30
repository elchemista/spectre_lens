# Changelog

All notable changes to Spectre Lens are documented in this file.

## [Unreleased]

## [0.1.4] - 2026-07-30

### Changed

- Updated the library, GitHub dependency source, and Stack manifest for
  Spectre 0.1.4 compatibility.
- Documented the boundary between the core-owned Agent Instance and Lens'
  explicitly started, caller-owned browser runtime.

### Added

- Multi-Run Agent Instance conformance coverage proving that a passive Lens
  installation does not start a browser or own Run scheduling and Agent State.

### Not included

- Autonomous `wake on_change` scheduling and continuity-plane lifecycle remain
  later migration phases.

[Unreleased]: https://github.com/elchemista/spectre_lens/compare/v0.1.4...HEAD
[0.1.4]: https://github.com/elchemista/spectre_lens/compare/v0.1.3...v0.1.4
