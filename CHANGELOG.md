# Changelog

All notable changes to Snaproll are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-07-15

A layout revamp that reorganizes the editor into a "console grid" and moves
live monitoring inline, along the signal path.

### Changed

- Editor layout revamp: every mixer and master channel control now lives in a
  single full-width mixer console band (Main / Sub / Xtra / Dry C / Dry E /
  Master) below the parameter columns, modeling a physical mixing panel. The
  parameter columns above are equalized to share one flat bottom edge instead
  of ending at ragged heights.
- Monitoring is distributed along the signal path rather than a single header
  widget: input peak meters (Center / Edge) in the header, live pressure
  pitch/mute traces in the Pressure card, and L/R output meters in the Master
  strip. Clicking any of these — or the header input meter — opens the full
  Monitor window.
- Narrower mixer pan sliders so each value readout clearly pairs with its
  slider.

### Fixed

- Release builds no longer offer the development-only mock device; when no
  serial port is found they show "No device detected" and disable Connect.

## [0.1.1] - 2026-07-13

### Fixed

- Crash on launch when the packaged `.app` is run on a machine other than the
  build machine. The app icon was loaded via SwiftPM's `Bundle.module`, whose
  lazy accessor calls `fatalError` (and so crashes uncatchably) when it can't
  locate the resource bundle after the app is copied/downloaded. The icon is
  now loaded by searching known resource paths directly.

### Changed

- `Scripts/make-app.sh` strips extended attributes before signing, so the
  ad-hoc signature seals clean files and the distributable zip is tidier.

## [0.1.0] - 2026-07-13

First public build — a native Swift/AppKit editor for the ATV aFrame, and an
Apple Silicon replacement for ATV's Intel-only aFrameEdit. Built against the
aFrame serial API (spec Ver 1.10, firmware 1.10+) and verified byte-exact
against real VER.2.00 hardware.

### Added

- Tone browser: sidebar with instrument/effect tabs and full 80-slot lists.
- Full parameter editor: sectioned, multi-column layout driven by a
  hardware-verified parameter map, with per-type controls (sliders with real
  ranges, enum popups, on/off switches) and unit-formatted values.
- Live editing: edits stream to the device in real time (coalesced writes);
  ⌘S saves the edit buffer to its slot.
- Per-section channel-strip mixer, pan controls (double-click to recenter to
  C00), and scale controls.
- Rule-based randomizer from a popover.
- Tone copy, tone picker, group editor, and monitor window; level meters and a
  compressor curve view.
- Mock device mode: run the full editor with no hardware connected.
- `aframe-capture` CLI: one-session data harvester for the connected instrument.
- Complete parameter dictionary: all 301 parameters (79 instrument + 222 effect
  across 9 algorithms) mapped with exact valid ranges, label tables, and
  composite encodings — enumerated from hardware and covered by regression tests.
- Byte-exact LZSS and project-image codecs with verified checksums.
- `Scripts/make-app.sh`: builds a release `.app` and distributable zip, with
  optional code signing + notarization.

### Known limitations

- Unsigned / not notarized — first launch requires right-click → Open (or
  clearing the quarantine attribute).
- Apple Silicon only in this build; requires macOS 13 (Ventura) or later.
- One protocol detail is unverified: how the firmware encodes a literal `0x7D`
  byte in LZ plaintext. The encoder uses a safe fallback, and a wrong guess is
  rejected by the device's project checksum, so it cannot corrupt anything.

[Unreleased]: https://github.com/CausticPuppy/snaproll/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/CausticPuppy/snaproll/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/CausticPuppy/snaproll/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/CausticPuppy/snaproll/releases/tag/v0.1.0
