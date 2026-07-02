# aFrame Editor Gap Analysis
### API Specification (Ver 1.10) vs. aFrameEdit for Mac (Ver 2.20)

**Sources:** `aFrame_API_Specification.pdf` (API for firmware 1.10+), `aFrameEdit_mac_Ver0220_QuickReference.pdf` (editor v2.20, targets firmware 2.0), `aFrameReference_v2.01_en.pdf` (hardware reference, firmware 2.0x).

---

## 1. What the API provides

The aFrame exposes a plain-text command protocol over a CP2102 USB virtual COM port (115200 8N1, no handshake). Three command families:

- **Get (`aFG0`–`aFGF`)** — firmware version, mode, switch/encoder/LED/LCD state, current group/number, peak levels, pressure levels, current tone name/data, project group list, project tone name list, project tone data list.
- **Set (`aFS1`–`aFS7`)** — enter/leave external-edit mode, set switch/encoder/LED/LCD, group bank/number up-down (HOME mode only).
- **External Editing (`aFE0`–`aFE9`)** — requires `MODE_EDIT_EXT`; select/write group slots, change tone number, change one parameter in the edit buffer, rename tone, write edit buffer to project, get/set the whole edit buffer (binary + checksum, or text), get/set the whole project (LZSS-compressed binary, 0x7F00 bytes decoded).

The project data structure is fully specified (Appendix C): 80 instrument patches + 80 effect patches (each `algo_num`, 20-char name, `prm_num`, `short Data[84]`), an 8×40 group map of (inst, effect) patch pairs, per-group max counts, project name/signature, checksum.

## 2. What the native editor does (observed from the quick reference)

The main window is a single-screen editor with:

- Connection status, aFrame firmware version display, LCD mirror area, input level meters (Center/Edge), pressure meters (Pitch/Mute), output L/R meters
- Group / NUM / MAX selection with Original/Save
- Project load/save (`Prj Load` / `Prj Save`) to aFrame or Mac file; Tone load/save to file
- Instrument editing: Main / Sub / Xtra / Dry timbre sections (~70 named parameters with units — Hz, dB, ms, sec, note names, Frequency/Cent display toggle), mixer sliders (Lev/Snd/Pan, M+/M− bus switches), Pressure section, Master section
- Effect editing: algorithm parameters (RATE, DEPTH, MANUAL, RESO, XFB, MOD_PH, STAGE, Press*, Phaser Sw, FxPos, Ambience, Comp*), with a live **compressor curve plot**
- Inst/Effect tone selectors (80 slots each) with **Original/Edited compare**, **Save / Save As**, **Factory preset browser** (🏭 icon), **parameter Randomize** (target Main/Sub/Xtra/MSX or Reg.Prm, rate %)
- **Group Edit** view: 8 columns (A–D′), drag-and-drop tone-number ordering, insert/delete, Write to aFrame
- **Tone Edit2** view: From/To lists to copy tone sets between the aFrame and project files on the Mac, Add/Add All, blank = "NAKED" tone

## 3. Feature-to-API mapping

| Editor feature | API support | Gap? |
|---|---|---|
| Connect / version display | `GetVersion` (aFG0) | None |
| Enter/leave edit session | `SetExtModeSw` (aFS1), `GetMode` (aFG1) | None |
| Input/output level meters | `GetPeakLevel` (aFG8), 0–15 | Poll-only (no push); coarse 16-step resolution |
| Pressure meters | `GetGetPressure` (aFG9) | Poll-only |
| LCD mirror | `GetLCD`/`SetLCD` (aFG5/aFS5) | None |
| Group/NUM/MAX select + save | `ExtSelectGroup` (aFE0), `ExtWriteGroup` (aFE1) | None |
| Select inst/effect tone (0–79) | `ExtChangeToneNum` (aFE2), names via `GetProjectToneNameList` (aFGE) | None |
| Edit a parameter | `ExtChangeEditBuffParam` (aFE3), by index | **No parameter map in spec** (see §4.1) |
| Rename tone | `ExtChangeEditBuffName` (aFE4) | None |
| Save / Save As tone to project | `ExtWriteEditBuffToProject` (aFE5) | None |
| Original/Edited compare | `ExtGetEditBuff`/`ExtSetEditBuff` (aFE6/aFE7) | Client-side; API sufficient |
| Tone file load/save | aFE6/aFE7 BIN or TXT | **Old editor's file formats undocumented** (§4.4) |
| Project load/save (device ↔ Mac) | `ExtGetProject`/`ExtSetProject` (aFE8/aFE9) | **LZSS variant undocumented** (§4.2) |
| Group Edit (drag-drop mapping) | `GetProjectGroupList` (aFGD) + `ExtWriteGroup` per slot, or whole-project aFE8/aFE9 | Workable, but per-slot write flow is awkward |
| Tone Edit2 (bulk copy) | aFE8/aFE9 + file manipulation | Workable |
| Factory preset browser | **Nothing** | **No API access to factory/preset ROM** (§4.3) |
| Randomize | Client-side | Needs the same parameter metadata as §4.1 |
| Comp curve plot | Client-side from param values | Needs param semantics |
| Persistence to flash | **Nothing explicit** | Device saves at power-off only (§4.5) |

Unused API surface (opportunities): `GetSwitch`/`SetSwitch`, `GetLED`/`SetLED`, `SetEncoder`, `SetGroupBank`/`SetGroupNum` — full remote-control of the panel, usable for diagnostics or a "remote" view the old editor never had.

## 4. Critical gaps — things the API spec does *not* give you

These are the real work items beyond straightforward protocol implementation.

### 4.1 No parameter dictionary (biggest gap)
`ExtChangeEditBuffParam` addresses parameters by **index into `Data[84]`**, and `GetCurrentToneData` returns anonymous value lists. The spec never maps index → parameter name, range, unit, or display transform. The editor UI shows ~70 instrument parameters ("MainTune C2 +00", "MainDcay 1.5 sec", "DryC EqF 3200 Hz", Frequency/Cent toggle…) and per-algorithm effect parameter sets. You must reconstruct:
- index ↔ name mapping per algorithm (`algo_num` 0–6)
- raw value ↔ displayed value transforms (note names, Hz, dB, ms, ratios)
- valid ranges per parameter

**Mitigation:** the TXT mode of `ExtGetEditBuff` returns named dumps; change one knob at a time on a real device (in a non-EXT mode) and diff `GetCurrentToneData` output; cross-reference the parameter tables and block diagrams in the reference manual (pp. 12–13, 57–70, 90–93).

### 4.2 LZSS codec unspecified
`ExtGetProject`/`ExtSetProject` payloads are LZSS-encoded, but the spec gives no window size, match length, control-bit layout, or initial dictionary. You must reverse-engineer it from a captured dump (checksummed 0x7F00 plaintext gives you a known-plaintext target) or find the variant in ATV's other tools. Until this is solved, whole-project transfer — which Prj Load/Save, Group Edit, and Tone Edit2 all lean on — is blocked. (Per-tone BIN/TXT transfer via aFE6/aFE7 is *not* compressed, so a v1 editor could work tone-by-tone.)

### 4.3 No factory preset access
The factory tone browser in aFrameEdit cannot be fed from the API — there is no command to read the preset ROM (INT.Memory 1/2). The old editor almost certainly bundles factory tone data as files. Options: ship factory tones as data files captured once from a device (load each preset on the hardware, dump via aFE6), or drop the feature initially.

### 4.4 Old editor file-format compatibility
If you want to open projects/tones saved by aFrameEdit (`Prj Save`, `Tone Save`), those file formats are undocumented. Likely candidates: raw decoded `DSP_PROJECT` image and the aFE6 BIN/TXT tone formats — verify against real files. Also note the hardware itself exports tones via `SYS: Export TONE` (USB memory) — a third format to consider.

### 4.5 Persistence semantics
The quick reference warns: edits are held in working memory and **written to aFrame flash only at normal power-off**; disconnecting power early loses them. The API has no "commit to flash" command. The new editor must surface this to the user (the old one buried it in a PDF note).

## 5. Moderate gaps and spec ambiguities

- **Spec version skew:** the API doc is for firmware **1.10**; the editor targets **2.0+**. Firmware 1.20/2.00 added effect algorithms (Multi-Tap Delay, Compressor, Ambience, SpaceR/SpaceZ), new parameters (pressure control, MASTER MIX BUS SW, FxMtrx, expanded SC), and 120 new factory tones. `algo_num` "0–6" and per-algorithm `prm_num` in the spec are therefore stale. Assume the protocol commands are unchanged but the data vocabulary grew; verify against a 2.x device (`GetVersion` first).
- **Checksum definition:** shown only by example ("data[size−2:size−1] = checkSum", TXT example `5117`). Looks like a 16-bit sum; must confirm empirically.
- **`mode` parameter typo:** aFE6/aFE7 tables say "0:BIN **2**:TXT" but the body says "mode1(TXT)". Test which value the firmware actually accepts.
- **Two-phase writes:** aFE7/aFE9 have READY→data phases with TIME_OUT/DATA_SIZE_ERR/CHECK_SUM_ERR results, and aFE8 has a per-KB `wait` pacing parameter — with no hardware flow control, the host must pace transfers and handle retries itself.
- **No event/notification channel:** everything is request/response. Meters, mode changes, and front-panel actions require polling loops; in `MODE_EDIT_EXT` the hardware panel is locked out anyway, which simplifies state sync.
- **Minor spec typos** to not trip over: `GetGetPressure`, `<CT+LF>`, `SetGroupNum` described as "Group Bank Up".

## 6. Platform notes (Apple Silicon)

- The CP2102 bridge needs a VCP driver. Recent macOS includes a built-in CP210x driver (device appears as `/dev/cu.usbserial-*` / `/dev/cu.SLAB_USBtoUART` with the Silicon Labs driver, `/dev/cu.usbmodem*` with Apple's). Verify enumeration on the target Mac before assuming driver work is needed.
- The protocol is trivial serial I/O — any stack works (Swift + ORSSerialPort/IOKit, Electron/Tauri + serialport, Python, Web Serial in a browser). No Intel-only dependency exists in the protocol itself.

## 7. Suggested de-risking order

1. **Smoke test the protocol:** terminal session over the serial port — `aFG0`, `aFG1`, `aFS1:1`, `aFGB` — confirms driver, framing, and edit-mode entry.
2. **Dump tone data in TXT mode** (aFE6) for several factory tones and algorithms → build the parameter dictionary (§4.1) and confirm the checksum (§5).
3. **Capture an `ExtGetProject` blob** and crack the LZSS variant (§4.2) — known structure + checksum makes this tractable.
4. Build the editor core: tone select → param edit → write to project (all fully supported by aFE0–aFE7, no gaps).
5. Add project file load/save once LZSS is solved; then Group Edit and bulk tone copy.
6. Decide on factory-preset strategy (§4.3) and old-file compatibility (§4.4) last — both are optional for a functional replacement.

**Bottom line:** the API covers essentially every workflow the native editor offers — nothing in the editor is impossible to rebuild, and per-tone editing needs no reverse engineering at all. The genuinely missing pieces are *documentation*, not capability: the parameter dictionary (§4.1) and the LZSS codec (§4.2) are the two items standing between the spec and a full-featured replacement, with factory-preset data (§4.3) the only feature with no API path at all.
