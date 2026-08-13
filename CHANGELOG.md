# Changelog

All notable changes to Spectre Lens are documented in this file.

## [Unreleased]

### Fixed

- Compiled the Stack contract and its Agent binding in one test boundary so
  integrity validation is stable on GitHub Actions' Elixir 1.19/OTP 28 runner.
- Removed ExDoc and the documentation CI job; this GitHub-only distribution
  keeps its documentation as repository Markdown.
- Kept diagnostic endpoint redaction compatible with the opaque `URI` type on
  Elixir 1.19/OTP 28, eliminating the two Dialyzer errors without exposing
  credentials, paths, or query parameters.

## [0.3.0] - 2026-08-13

### Fixed

- Prevented `mix spectre.lens.install` and `mix spectre.lens.doctor` from
  starting the consumer application and its unrelated supervision tree.
- Removed the compile-time and runtime dependency on Spectre. Stack and Action
  integration now binds only when Spectre is separately available, while the
  repository keeps its Hex dependency test-only.
- Hardened CDP commands and event waits against malformed inputs, JSON encoding
  failures, dead transports, invalid discovery endpoints, and malformed browser
  responses without leaking pending callers or crashing the shared connection.
- Made Lightpanda installation race-safe and checksum-preserving through private
  staging directories, atomic destination commits, bounded startup polling, and
  validation of platform, path, timeout, boolean, and downloader boundaries.
- Corrected discovery result ordering, Page polling deadlines and option
  forwarding, selector escaping, session JSON normalization, watcher ownership,
  and malformed `llms.txt` fetcher/header handling.

### Performance

- Bounded selector, document-readiness, and Lightpanda startup polling by the
  actual remaining deadline, and capped runtime worker shutdown by one global
  timeout instead of multiplying it by the number of pending tabs.

### Changed

- Kept Lens distribution GitHub-only without Hex package metadata.
- Resolved the test-only Spectre dependency from Hex with the `~> 0.3.0`
  requirement.
- Raised the Lens package, Action provider, and Stack compatibility contracts
  to `0.3.0` and Spectre `~> 0.3.0`.
- Ran default Credo checks in CI alongside the existing Dialyzer job.

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

[Unreleased]: https://github.com/elchemista/spectre_lens/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/elchemista/spectre_lens/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/elchemista/spectre_lens/compare/v0.1.6...v0.2.0
[0.1.6]: https://github.com/elchemista/spectre_lens/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/elchemista/spectre_lens/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/elchemista/spectre_lens/compare/v0.1.3...v0.1.4
