# Snaproll (Apple Silicon)

Snaproll — an editor for the ATV aFrame. A native Swift/AppKit replacement for
ATV's Intel-only aFrameEdit, built against the aFrame serial API (spec Ver 1.10,
firmware 1.10+). See
[Docs/GAP_ANALYSIS.md](Docs/GAP_ANALYSIS.md) for the API-vs-editor feature analysis that
drives the plan.

## Layout

- `Sources/AFrameKit` — protocol library: serial transport, `AFrameClient`
  (all aFG/aFS/aFE commands), `DSPPatch`/`DSPProject` binary codecs, LZSS
  codec, checksum utilities, and `MockAFrame` (a full device simulation used
  by tests and offline UI development).
- `Sources/AFrameCapture` — `aframe-capture` CLI: one-session data harvester
  run with the instrument connected; collects everything needed to close the
  spec's documentation gaps (parameter dictionary, LZSS variant, checksums,
  TXT-mode value).
- `Sources/SnaprollApp` — the AppKit editor: sidebar tone browser
  (instrument/effect tabs, 80-slot lists) + a sectioned, multi-column
  parameter editor driven by `ParameterMap`. Controls are chosen per display
  type (sliders with real ranges, enum popups, on/off switches), values are
  formatted by `ParameterFormatter`, and edits stream live to the device via
  `EditorSession` (coalesced writes, ⌘S to save the edit buffer to its slot).
  Runs against the mock device or real hardware.
- `Tests/AFrameKitTests` — round-trip tests over the mock.

## Usage

```sh
swift build
swift test

# Run the app (enable "Mock device" to try it without hardware):
swift run Snaproll

# With the aFrame connected via USB:
swift run aframe-capture              # lists candidate serial ports
swift run aframe-capture --port /dev/cu.SLAB_USBtoUART
swift run aframe-capture --mock       # dry run against the simulator
```

Captures land in `captures/<timestamp>/`.

## Protocol facts verified against hardware (VER.2.00, captures 2026-07-01)

Everything below was confirmed byte-exact against a real aFrame; the mock
mirrors these behaviors.

1. **"LZSS" is an escape-byte LZ77** (`AFrameLZ` in `LZSS.swift`): 12-byte
   header (decoded size u32, compressed size u32, escape byte 0x7D + pad),
   then literals with `7D dist len` copy tokens. Distances ≥ 0x7D are stored
   +1 (0x7D never appears in the distance slot); lengths are raw (4–192
   observed); overlapping copies repeat RLE-style. Verified by decoding the
   full factory project byte-exactly with a matching trailing checksum.
2. **Checksums**: binary edit buffer = 16-bit byte-sum (stored LE in last two
   bytes); project image = 32-bit byte-sum (trailing u32); the aFE6 TXT
   checksum line is the same byte-sum value as the BIN payload's.
3. **aFE6/aFE7 binary payload is variable-length**: algo(i16) + name[20] +
   prm_num(i16) + data[prm_num] + checksum. 184 bytes for a 79-param
   instrument, 72 for a 23-param effect.
4. **TXT mode wire value is 2** (the spec table is right; its body text has
   the typo).
5. **Byte order**: little-endian throughout.
6. **Binary framing**: raw bytes with a 2-byte LE size prefix on the wire.
7. **Firmware 2.00 data vocabulary**: instruments are always algo 0 with 79
   parameters; effects use algos 1–9 (param counts 23/26/19/21/22/20/51/22/18).
   CSV data lines end with a trailing comma.
8. Factory project header: id 0x20190117, name "aFrame Initial Project",
   signature "ATV Corporation", InstPatchMax/EffectPatchMax = 79.

**Still unverified (one item):** how the firmware encodes a literal 0x7D byte
in LZ plaintext — the factory project contains none. Our encoder uses `7D 7D`
stuffing as a last resort; a wrong guess is rejected by the device's project
checksum, so it cannot corrupt anything. Definitive test: write a patch
containing a parameter value of 125 and re-download the project.

## Parameter dictionary (`ParameterMap.swift`)

The index → name/format mapping for every parameter was enumerated by the
hardware itself: `aframe-capture --probe` rewrites each parameter with its
current value and `lcd=1`, then reads the device LCD, which prints the
parameter's name, formatted value, and unit (evidence:
`captures/20260702-080734/param_probe.txt`). All 301 parameters are mapped —
79 instrument + 222 effect across 9 algorithms — and a regression test checks
every name against the probe capture.

Probe-confirmed algorithm numbering: 1 Reverb, 2 Delay, **3 Chorus,
4 Flanger** (swapped vs. the manual's block-diagram order), 5 Phaser, 6 Wah,
7 Multi-Tap Delay, 8 SpaceR, 9 SpaceZ.

The value sweep (`--sweep` / `--sweep-quick`, captures 20260702-082318 and
-083220) completed the dictionary:

- **Exact valid ranges for all 301 parameters** (`ParameterRanges.swift`,
  machine-generated from the sweep). Discovered because aFE3 *rejects*
  out-of-range values with NG, so ranges were found by accept/reject binary
  search.
- **Complete label tables** for every coded parameter: 31 overtone types,
  20 Xtra oscillator types, 29 pressure scales, comp ratio/knee, per-algorithm
  PressMode sets, Delay/Chorus/Wah types, AutoRevo, Ambience A–E, Bend curves
  A0–A8, Jx filter types.
- **Composite encodings**: mixer Lev = level + 256×mode (`--`/`P+`/`P-`),
  Snd = level + 256×mode (`M+`/`M-` = MASTER MIX BUS switch); SC = root×128 ±
  scale code; Mute = 0 OFF / 1 ON(global) / offset-by-one ± sensitivity;
  delay times: negative = BPM sync, −(division_code×256 + fine).
- Tests enforce that every enumerated label table exactly covers its
  hardware-accepted range.

Still open (cosmetic, sweep later if needed): auto-pan mode labels inside the
mixer Pan composite (23 modes), negative-zone rendering of Tune parameters
(editor-side note+cents display), and BPM division codes 3/5/6 labels.

## Disclaimer

Snaproll is an unofficial, independent tool with no affiliation with or
endorsement by ATV Corporation. "aFrame" and "ATV" are trademarks of their
respective owner and are used here only nominatively, to describe the hardware
this editor is compatible with.
