# Changelog

All notable changes to Snaproll are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/CausticPuppy/snaproll/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/CausticPuppy/snaproll/releases/tag/v0.1.0
