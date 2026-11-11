# Flutter Android app — BLE remote for EPD-C6

Handoff for a new Flutter agent. Firmware lives in this Arduino sketch (`ble_remote.cpp`). The phone is a **BLE GATT client**; the ESP32-C6 e-paper board is the **server/peripheral**.

## Goal

Android app that:
1. Scans/connects to the board over BLE
2. Shows live battery + mode status
3. Lets the user set the e-paper center content: **letter**, **group**, or **pairs**
4. Stays connected for ~2h unplugged use (board uses light sleep; keep a normal BLE link, no Wi‑Fi)

No Wi‑Fi, no HTTP, no cloud. BLE only.

## Hardware / device identity

| Item | Value |
|------|--------|
| Board | Waveshare ESP32-C6-ePaper-1.54 |
| BLE advertised name | `EPD-C6` |
| Display | 200×200 e-paper (SSD1680-style), slow full refresh |
| Power | Battery latched via TCA9554; long-press PWR on device powers off |

## GATT layout

Custom 128-bit UUIDs (must match firmware exactly):

| Role | UUID |
|------|------|
| Service | `7b1e0001-5f5c-4a1a-9c3e-6f2d8a0b0001` |
| STATUS (Read + Notify) | `7b1e0002-5f5c-4a1a-9c3e-6f2d8a0b0001` |
| CMD (Write / Write Without Response) | `7b1e0003-5f5c-4a1a-9c3e-6f2d8a0b0001` |

Notes:
- STATUS has a CCCD (`0x2902`). **Enable notifications** after connect.
- CMD accepts both write-with-response and write-without-response.
- Max command length: **63 bytes** payload + NUL on device (`BLE_CMD_MAX_LEN` = 64). Keep writes ≤ 63 ASCII chars.
- Advertising includes the service UUID; filter scan by name `EPD-C6` and/or service UUID.
- On disconnect, the board restarts advertising automatically.

Suggested Flutter packages: `flutter_blue_plus` (or equivalent maintained BLE plugin). Target Android first; request `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, and location if required by API level.

## STATUS characteristic (device → phone)

UTF-8 ASCII, semicolon-separated `key=value` fields. Read anytime; also pushed via **Notify** after UI updates / successful commands / connect-driven refresh.

### Formats by mode

Mode enum (`mode=`):

| Value | Meaning |
|-------|---------|
| `0` | Letter |
| `1` | Group |
| `2` | Pairs |

Examples:

```text
bat=87;mode=0;letter=A
bat=87;mode=1;group=ABCDE
bat=87;mode=2;pairs=4
```

| Field | Type | Meaning |
|-------|------|---------|
| `bat` | 0–100 | Battery percent |
| `mode` | 0\|1\|2 | Center template |
| `letter` | A–Z | Present when `mode=0` |
| `group` | 2–5 letters | Present when `mode=1` |
| `pairs` | count | Present when `mode=2` — **count only**, not the pair list |

**Limitation:** STATUS does not echo the full pairs payload. After sending `P:...`, trust the write; use `pairs=` only as confirmation of count/mode. Letter/group are echoed.

Parse robustly: split on `;`, then on first `=`. Ignore unknown keys.

## CMD characteristic (phone → device)

UTF-8 ASCII. CR/LF stripped on device. Case for letters is normalized to uppercase.

### Commands

| Command | Example | Effect |
|---------|---------|--------|
| `L:<letter>` | `L:A` | Switch to letter mode; show one A–Z character |
| `G:<letters>` | `G:ABCDE` | Switch to group mode; **2–5** A–Z characters only |
| `P:<pairs>` | `P:A4,B2,C3` | Switch to pairs mode; letter+digit tokens |
| `M:<n>` | `M:0` | Switch mode only (`0`/`1`/`2`) without changing stored content |
| `B?` | `B?` | Request status refresh (triggers notify path) |

### Validation rules (device rejects invalid → no UI change)

**Letter (`L:`)**
- Exactly one meaningful char after prefix (first char used)
- Must be A–Z (after uppercasing)

**Group (`G:`)**
- Length **2..5**
- Every char A–Z

**Pairs (`P:`)**
- Format: `LetterDigit` tokens separated by `,`
- Optional spaces around tokens/commas
- Letter A–Z, digit `0`–`9`
- **1..8** pairs (`UI_PAIRS_MAX = 8`)
- Examples valid: `P:A4,B2,C3,D5` · `P:A4, B2`
- Examples invalid: empty, missing digit, 9+ pairs, non-letter

**Mode (`M:`)**
- Exactly one char: `0`, `1`, or `2`

**Battery poll (`B?`)**
- Exact match `B?`
- Does not change content; used to force a status/notify cycle after render

Unknown commands are ignored (logged on Serial as `BLE CMD ignored`).

## UI model on the e-paper (what the user sees)

Chrome (always):
- Top-left: BLE connected indicator (firmware-driven)
- Top-right: `NN%` battery

Center (one of three templates):

| Mode | Content |
|------|---------|
| Letter | Single large letter |
| Group | 2–5 letter string |
| Pairs | Up to 8 `L#` pairs in a 2-column layout on 200×200 |

Physical buttons on device (independent of app):
- **BOOT**: cycle mode locally
- **PWR short**: advance demo content in current mode
- **PWR long (~1.5s)**: cut battery latch / power off

App should tolerate local button changes: STATUS notify will eventually reflect new mode/content where applicable.

## Connection / UX recommendations

1. Scan → connect to `EPD-C6`
2. Discover service + characteristics
3. Subscribe STATUS notifications
4. Optional: read STATUS once; send `B?` if battery looks stale
5. Screens:
   - Connection / device picker
   - Letter picker (A–Z)
   - Group text field (2–5 letters, validate client-side)
   - Pairs editor (add/remove rows letter+digit, max 8)
   - Live battery + mode header from STATUS
6. After each successful CMD write, expect STATUS notify; update UI from it
7. E-paper refresh is slow (~1s+). Disable spam: debounce writes; show “Updating…” until notify or timeout (~3–5s)
8. On disconnect: show reconnect; board is advertising again
9. Keep screen/app alive reasonably while “session” is active — firmware is tuned for connected idle with light sleep, not deep sleep

## Out of scope for v1 (unless you expand firmware)

- Reading back full pairs list over BLE
- OTA firmware update
- Wi‑Fi / Flutter web
- Multiple simultaneous centrals (treat as single-phone)
- Bonding/PIN (currently open GATT; add later if needed)
- Sending images / arbitrary text beyond letter/group/pairs

## Firmware source of truth

| File | Why |
|------|-----|
| `ble_remote.cpp` | UUIDs, parse/status, GATT properties |
| `ui_model.h` | Limits: `UI_GROUP_MAX_LEN=5`, `UI_PAIRS_MAX=8`, mode enum |
| `ui_templates.cpp` | What gets drawn on the panel |
| `power_mgmt.cpp` | Light sleep while BLE connected |
| `project_base.ino` | When STATUS is notified (after render) |

## Manual test with nRF Connect (before Flutter)

1. Connect to `EPD-C6`
2. Enable notify on STATUS `…0002…`
3. Write ASCII to CMD `…0003…`:
   - `L:Q`
   - `G:ABCDE`
   - `P:A1,B2,C3`
   - `B?`
4. Confirm panel updates and STATUS notify strings match

## Suggested Flutter milestone checklist

- [ ] Android permissions + scan/connect by name/UUID
- [ ] STATUS subscribe + parse into a Dart model
- [ ] Send `L:` / `G:` / `P:` / `M:` / `B?` with client-side validation matching firmware
- [ ] Simple three-tab or segmented UI for the three modes
- [ ] Battery display + disconnect/reconnect handling
- [ ] Debounced writes + update-in-progress feedback for e-paper latency

## Copy-paste constants (Dart)

```dart
const String kDeviceName = 'EPD-C6';
const String kServiceUuid = '7b1e0001-5f5c-4a1a-9c3e-6f2d8a0b0001';
const String kStatusCharUuid = '7b1e0002-5f5c-4a1a-9c3e-6f2d8a0b0001';
const String kCmdCharUuid = '7b1e0003-5f5c-4a1a-9c3e-6f2d8a0b0001';

const int kCmdMaxLen = 63;
const int kGroupMinLen = 2;
const int kGroupMaxLen = 5;
const int kPairsMax = 8;
```
