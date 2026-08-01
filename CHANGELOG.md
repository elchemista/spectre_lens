# Changelog

All notable changes to Spectre Lens are documented in this file.

## [Unreleased]

## [0.2.0] - 2026-08-01

### Changed

- Raised the package, Action provider, and Stack compatibility contracts to
  Spectre 0.2.0.
- Verified browser perception, portable Tab references, request guards, and
  staged Action execution against the Spectre 0.2.0 operational runtime.

### Compatibility

- Browser processes and protocol clients remain caller-owned resources and
  are never embedded in core Run or Instance checkpoints.

## [0.1.6] - 2026-07-31

### Changed

- Established a recoverable consolidation baseline with an explicit normative
  public API manifest and uniform release documentation.
- Added no runtime functionality and made no intentional breaking API change.

## [0.1.5] - 2026-07-30

### Changed

- Raised the library and Stack manifest requirement to Spectre 0.1.5.
- Verified that Lens Actions use the core's per-Run Effect ownership while
  browser processes remain caller-owned resources outside Run checkpoints.

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

[Unreleased]: https://github.com/elchemista/spectre_lens/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/elchemista/spectre_lens/compare/v0.1.6...v0.2.0
[0.1.6]: https://github.com/elchemista/spectre_lens/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/elchemista/spectre_lens/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/elchemista/spectre_lens/compare/v0.1.3...v0.1.4
