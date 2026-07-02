# aFrame Edit (Apple Silicon)

A native Swift/AppKit replacement for ATV's Intel-only aFrameEdit, built against
the aFrame serial API (spec Ver 1.10, firmware 1.10+). See
[GAP_ANALYSIS.md](GAP_ANALYSIS.md) for the API-vs-editor feature analysis that
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
- `Sources/AFrameEditApp` — the AppKit app (currently: connection scaffold
  with firmware/mode display, LCD mirror, level/pressure meters).
- `Tests/AFrameKitTests` — round-trip tests over the mock.

## Usage

```sh
swift build
swift test

# Run the app (enable "Mock device" to try it without hardware):
swift run AFrameEdit

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
