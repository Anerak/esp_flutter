# Flutter App Update Guide — BLE Wi-Fi Provisioning & HTTP Remote for EPD-C6

Handoff specification for updating the existing Flutter Android/iOS app to work with the Wi-Fi + Web Server firmware (`feat/wifi-web-server`).

In v1 (`main`), the Flutter app stayed connected over BLE to send `L:`, `G:`, `P:`, and `M:` display commands. In v2 (`feat/wifi-web-server`), **BLE is used exclusively for configuring the 2.4 GHz Wi-Fi network**, after which BLE shuts off to save memory/battery and all display control happens over **HTTP on the local Wi-Fi network** (from Windows browsers, mobile browsers, or directly inside the Flutter app).

---

## Summary of Breaking Changes from v1 (`main`)

| Area | v1 (BLE-only) | v2 (BLE Provisioning + Wi-Fi HTTP) |
|------|---------------|------------------------------------|
| **GATT UUIDs** | `7b1e0001` / `0002` / `0003` | **Unchanged** (same Service, `STATUS`, and `CMD` UUIDs) |
| **BLE Role** | Long-lived display remote | **Short-lived Wi-Fi provisioning only** (`BLEDevice::deinit(true)` runs 3s after Wi-Fi connects) |
| **BLE `CMD` writes** | `L:`, `G:`, `P:`, `M:`, `B?` | `S:`, `S+:`, `K:`, `K+:`, `W:1`, `W:0`, `W?` (`B?` still works as alias for `W?`) |
| **BLE `STATUS` payload** | `bat=87;mode=0;letter=A` | `bat=88;state=connected;ssid=MyWiFi;ip=192.168.1.42;host=epd-c6.local` |
| **Display control (`L:`/`G:`/`P:`/`M:`)** | Over BLE `CMD` characteristic | Over HTTP `POST http://<ip>/api/display` (exact same command strings!) |
| **Reading `pairs` list** | Count only (`pairs=4`) | Full array via `GET http://<ip>/api/status` (`"pairs": ["A4","B2","C3","D5"]`) |

---

## Recommended Flutter App Architecture

You have two options for updating the Flutter app depending on how much mobile UI you want to keep:

1. **Provisioning-Only Companion (Minimal change)**:
   - Keep the existing BLE scan/connect flow (`flutter_blue_plus`).
   - Replace the 3-tab BLE remote screen with a **Wi-Fi Setup Screen** (SSID + Password + Connect button).
   - When `STATUS` reports `state=connected;ip=<ip>`, display the IP address / `http://epd-c6.local/` URL (with a Copy / Share / Open in Browser button) so the user can open it on their Windows PC.
2. **Provisioning + Native Wi-Fi Remote (Recommended if keeping existing UI)**:
   - Keep the existing Letter / Group / Pairs Flutter UI, and swap its transport layer from BLE writes to `http.post(Uri.parse('http://$ip/api/display'), body: cmd)`.
   - Save the provisioned `ip` (and fallback `epd-c6.local`) in `SharedPreferences` so the phone can also control the display over Wi-Fi alongside the Windows PC.

---

## Device Lifecycle & What the User Sees on E-Paper

1. **Unconfigured / Wi-Fi unreachable on boot (after 15s timeout)**:
   - Top-left of e-paper shows **`BT Setup`**.
   - Device advertises BLE as `EPD-C6` with service UUID `7b1e0001-5f5c-4a1a-9c3e-6f2d8a0b0001`.
2. **Flutter app connects over BLE**:
   - Top-left of e-paper changes to **`BT Ready`**.
3. **User submits SSID + Password (`W:1`)**:
   - Top-left of e-paper shows **`WiFi...`**, `STATUS` notifies `state=connecting`.
   - **If connection succeeds (within 15s)**:
     - Credentials are saved to NVS flash.
     - HTTP server (`port 80`) and mDNS (`epd-c6.local`) start.
     - Top-left of e-paper displays the assigned IPv4 address (e.g. **`192.168.1.42`**).
     - `STATUS` notifies `bat=87;state=connected;ssid=MyWiFi;ip=192.168.1.42;host=epd-c6.local`.
     - **3 seconds later**, firmware calls `BLEDevice::deinit(true)` and disconnects BLE intentionally. **Treat disconnect after `state=connected` as success, not an error!**
   - **If connection fails (wrong password / 5 GHz-only SSID / timeout)**:
     - Top-left returns to **`BT Ready`** (or `BT Setup`).
     - `STATUS` notifies `state=error`. BLE stays connected so the user can retry.
4. **Subsequent boots**:
   - Board connects directly to saved Wi-Fi (BLE never starts).
5. **Re-entering Bluetooth Setup later**:
   - Hold physical **BOOT** button on the board for **3 seconds** (screen shows `BT Reset...` and reboots into `BT Setup`), **or** call `POST http://<ip>/api/wifi/reset`.

---

## Part 1: BLE GATT Provisioning Protocol

### GATT Layout (Unchanged UUIDs)

| Role | UUID | Properties |
|------|------|------------|
| Advertised Name | `EPD-C6` | Included in advertisement |
| Service | `7b1e0001-5f5c-4a1a-9c3e-6f2d8a0b0001` | Primary Service (also in advertisement) |
| `STATUS` | `7b1e0002-5f5c-4a1a-9c3e-6f2d8a0b0001` | Read + Notify (CCCD `0x2902`) |
| `CMD` | `7b1e0003-5f5c-4a1a-9c3e-6f2d8a0b0001` | Write + Write Without Response |

### MTU & Chunked Writes (Important for Flutter)

- Firmware sets preferred peripheral MTU to **`185`** (`BLE_CMD_MAX_LEN = 96` bytes).
- On Android, call `await device.requestMtu(185)` after `connect()` if desired.
- **Even better (works on both Android & iOS regardless of MTU):** Firmware supports chunked append commands (`S+:` and `K+:`). Sending in **16-byte chunks** with **Write With Response** (`withoutResponse: false`) guarantees reliable delivery even on an unnegotiated 23-byte ATT_MTU (20-byte payload limit) and handles 32-char SSIDs and 63-char WPA2 passwords safely.

### `CMD` Characteristic Commands (Phone -> Device)

UTF-8 strings. Trailing `\r`/`\n` are stripped on device, **all spaces inside SSIDs and passwords are preserved**:

| Command | Example | Effect |
|---------|---------|--------|
| `S:<ssid>` | `S:MyHomeWiFi` | Stage SSID (1–32 bytes; resets any previous staged SSID) |
| `S+:<chunk>` | `S+:_2.4G` | Append bytes to staged SSID (up to 32 bytes total) |
| `K:<pass>` | `K:my secret pass` | Stage WPA/WPA2 password (0–63 bytes; send `K:` for open network) |
| `K+:<chunk>` | `K+:word123` | Append bytes to staged password (up to 63 bytes total) |
| `W:1` | `W:1` | Start Wi-Fi connection attempt (~1–15s) and persist to NVS on success |
| `W:0` | `W:0` | Clear staged & NVS-saved Wi-Fi credentials |
| `W?` (or `B?`) | `W?` | Request immediate `STATUS` notify refresh |

> **2.4 GHz note:** ESP32-C6 supports 2.4 GHz Wi-Fi (802.11b/g/n/ax). Remind users in the Flutter form hint to enter a **2.4 GHz** network (not 5 GHz-only).

### `STATUS` Characteristic Format (Device -> Phone)

UTF-8 semicolon-separated `key=value` fields. Read once after subscribing to notifications, and listen to notifications thereafter.

Examples:

```text
bat=88;state=unconfigured;ssid=;ip=;host=epd-c6.local
bat=88;state=ready;ssid=MyHomeWiFi;ip=;host=epd-c6.local
bat=88;state=connecting;ssid=MyHomeWiFi;ip=;host=epd-c6.local
bat=87;state=connected;ssid=MyHomeWiFi;ip=192.168.1.42;host=epd-c6.local
bat=87;state=error;ssid=MyHomeWiFi;ip=;host=epd-c6.local
```

| Key | Type | Values / Notes |
|-----|------|----------------|
| `bat` | `int` (`0`–`100`) | Battery percentage |
| `state` | `String` | `unconfigured` \| `ready` \| `connecting` \| `connected` \| `error` |
| `ssid` | `String` | Currently staged or saved SSID (`;` in SSIDs is sanitized as `_`; passwords are never echoed) |
| `ip` | `String` | Assigned IPv4 address when `state=connected`, otherwise empty |
| `host` | `String` | Always `epd-c6.local` |

### Exact BLE Provisioning Sequence for Flutter

1. Scan for `EPD-C6` or service UUID `7b1e0001-5f5c-4a1a-9c3e-6f2d8a0b0001`.
2. Connect -> discover services -> locate `STATUS` (`...0002...`) and `CMD` (`...0003...`).
3. Call `await statusChar.setNotifyValue(true)` and attach listener.
4. Call `await statusChar.read()` to populate initial battery%, state, and any previously saved SSID.
5. When user taps **Connect Wi-Fi**:
   - Validate SSID UTF-8 byte length is `1..32` and password UTF-8 byte length is `0..63`.
   - Write SSID using `S:` (and `S+:` chunks if >16 bytes) using `withoutResponse: false`.
   - Write password using `K:` (and `K+:` chunks if >16 bytes; write `K:` alone if open network) using `withoutResponse: false`.
   - Write `W:1` using `withoutResponse: false`.
6. Show a loading spinner (`Connecting EPD-C6 to Wi-Fi...`, timeout ~18s):
   - On `state == 'connected'` with non-empty `ip`:
     - Mark provisioning complete (`provisionSucceeded = true`), store `ip` & `host`.
     - Display prominent success card: **`http://<ip>/`** (for typing/sharing to Windows PC) and **`http://epd-c6.local/`**.
     - Expect BLE to disconnect automatically ~3s later — ignore disconnect event when `provisionSucceeded == true`.
   - On `state == 'error'`:
     - Stop spinner and show `"Could not connect to Wi-Fi. Check password and ensure network is 2.4 GHz."`

---

## Part 2: HTTP API (Windows Browser & Optional Flutter Wi-Fi Control)

Once provisioned, the ESP32-C6 serves both the Windows browser UI and REST endpoints on port `80` (with permissive CORS headers `*`).

### Endpoints

| Method | Path | Content-Type | Purpose |
|--------|------|--------------|---------|
| `GET` | `/` | `text/html` (gzip) | Embedded single-page Web Console for Windows/desktop browsers |
| `GET` | `/api/status` | `application/json` | Read live battery, active mode, letter, group, **full pairs list**, SSID, IP, and `rendering` flag |
| `POST` | `/api/display` | `text/plain; charset=utf-8` | Send display command (`L:`, `G:`, `P:`, `M:`) |
| `POST` | `/api/wifi/reset` | `application/json` | Clear saved Wi-Fi in NVS and reboot device into `BT Setup` mode |

### `GET /api/status` JSON Schema

```json
{
  "battery": 87,
  "mode": 2,
  "letter": "A",
  "group": "ABCDE",
  "pairs": ["A4", "B2", "C3", "D5"],
  "ssid": "MyHomeWiFi",
  "ip": "192.168.1.42",
  "host": "epd-c6.local",
  "rendering": false
}
```

### `POST /api/display` Commands (Identical to v1 BLE Strings)

Send raw plain text in the request body:

| Command | Example | Validation Rules |
|---------|---------|------------------|
| `L:<letter>` | `L:Q` | Single letter `A`–`Z` (case-insensitive) |
| `G:<letters>` | `G:ABCDE` | `2`–`5` letters `A`–`Z` |
| `P:<pairs>` | `P:A4,B2,C3,D5` | `1`–`8` comma-separated `LetterDigit` pairs (`A`–`Z` + `0`–`9`) |
| `M:<mode>` | `M:0` | Switch active mode (`0` = Letter, `1` = Group, `2` = Pairs) without changing stored values |

Responses:
- `200 OK`: `{"ok":true}`
- `400 Bad Request`: `{"ok":false,"error":"..."}`
- `503 Service Unavailable`: `{"ok":false,"error":"Display queue busy"}`

---

## Copy-Paste Dart Reference Implementation

### Constants & `BleProvStatus` Parser

```dart
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

const String kDeviceName = 'EPD-C6';
const String kServiceUuid = '7b1e0001-5f5c-4a1a-9c3e-6f2d8a0b0001';
const String kStatusCharUuid = '7b1e0002-5f5c-4a1a-9c3e-6f2d8a0b0001';
const String kCmdCharUuid = '7b1e0003-5f5c-4a1a-9c3e-6f2d8a0b0001';

const int kMaxSsidBytes = 32;
const int kMaxPassBytes = 63;
const int kBleChunkBytes = 16; // Safe even on default 23-byte ATT_MTU

enum BleProvState {
  unconfigured,
  ready,
  connecting,
  connected,
  error,
  unknown;

  static BleProvState fromString(String? raw) {
    switch (raw) {
      case 'unconfigured':
        return BleProvState.unconfigured;
      case 'ready':
        return BleProvState.ready;
      case 'connecting':
        return BleProvState.connecting;
      case 'connected':
        return BleProvState.connected;
      case 'error':
        return BleProvState.error;
      default:
        return BleProvState.unknown;
    }
  }
}

class BleProvStatus {
  final int battery;
  final BleProvState state;
  final String ssid;
  final String ip;
  final String host;

  const BleProvStatus({
    required this.battery,
    required this.state,
    required this.ssid,
    required this.ip,
    required this.host,
  });

  String? get webUrl => ip.isNotEmpty ? 'http://$ip/' : null;

  factory BleProvStatus.parse(String raw) {
    final map = <String, String>{};
    for (final part in raw.trim().split(';')) {
      final idx = part.indexOf('=');
      if (idx > 0) {
        map[part.substring(0, idx)] = part.substring(idx + 1);
      }
    }
    return BleProvStatus(
      battery: int.tryParse(map['bat'] ?? '') ?? 0,
      state: BleProvState.fromString(map['state']),
      ssid: map['ssid'] ?? '',
      ip: map['ip'] ?? '',
      host: map['host'] ?? 'epd-c6.local',
    );
  }
}
```

### Chunked BLE Credential Writer (`flutter_blue_plus`)

```dart
Future<void> writeCmd(BluetoothCharacteristic cmdChar, String cmd) async {
  await cmdChar.write(utf8.encode(cmd), withoutResponse: false);
}

Future<void> writeChunkedField(
  BluetoothCharacteristic cmdChar, {
  required String prefix,
  required String appendPrefix,
  required String value,
}) async {
  final bytes = utf8.encode(value);
  if (bytes.isEmpty) {
    // e.g. "K:" for an open Wi-Fi network with no password
    await writeCmd(cmdChar, prefix);
    return;
  }

  // Split by UTF-8 codepoint boundaries so multi-byte characters aren't torn
  var currentChunk = StringBuffer();
  var currentBytes = 0;
  var isFirst = true;

  for (final rune in value.runes) {
    final ch = String.fromCharCode(rune);
    final chBytes = utf8.encode(ch).length;
    if (currentBytes + chBytes > kBleChunkBytes && currentBytes > 0) {
      await writeCmd(
        cmdChar,
        '${isFirst ? prefix : appendPrefix}${currentChunk.toString()}',
      );
      isFirst = false;
      currentChunk = StringBuffer();
      currentBytes = 0;
    }
    currentChunk.write(ch);
    currentBytes += chBytes;
  }

  if (currentBytes > 0) {
    await writeCmd(
      cmdChar,
      '${isFirst ? prefix : appendPrefix}${currentChunk.toString()}',
    );
  }
}

/// Full Wi-Fi provisioning call after subscribing to STATUS notifications.
Future<void> provisionWifi({
  required BluetoothCharacteristic cmdChar,
  required String ssid,
  required String password,
}) async {
  final ssidBytes = utf8.encode(ssid).length;
  final passBytes = utf8.encode(password).length;

  if (ssidBytes == 0 || ssidBytes > kMaxSsidBytes) {
    throw ArgumentError('SSID must be 1..32 UTF-8 bytes');
  }
  if (passBytes > kMaxPassBytes) {
    throw ArgumentError('Password must be 0..63 UTF-8 bytes');
  }

  await writeChunkedField(
    cmdChar,
    prefix: 'S:',
    appendPrefix: 'S+:',
    value: ssid,
  );
  await writeChunkedField(
    cmdChar,
    prefix: 'K:',
    appendPrefix: 'K+:',
    value: password,
  );
  await writeCmd(cmdChar, 'W:1');
}
```

---

## Manual Verification with nRF Connect (Before Testing Flutter)

1. Put the board in Bluetooth setup mode (top-left of e-paper shows `BT Setup`; hold **BOOT** for 3s if already on Wi-Fi).
2. Open **nRF Connect** on Android/iOS -> connect to `EPD-C6`.
3. Enable notifications on `STATUS` (`7b1e0002-5f5c-4a1a-9c3e-6f2d8a0b0001`).
4. Write UTF-8 text to `CMD` (`7b1e0003-5f5c-4a1a-9c3e-6f2d8a0b0001`):
   - `S:Your24GHzSSID`
   - `K:YourWifiPassword`
   - `W:1`
5. Watch `STATUS` notify `state=connecting` -> `state=connected;ssid=...;ip=192.168.x.x;host=epd-c6.local`, followed by automatic BLE disconnect ~3s later.
6. Open `http://192.168.x.x/` on the Windows PC browser and verify Letter / Group / Pairs updates.

---

## Flutter Update Checklist

- [ ] Keep existing BLE scan, permissions, and GATT service/characteristic discovery (`7b1e0001` / `0002` / `0003`)
- [ ] Replace `STATUS` parser (`mode`/`letter`/`group`/`pairs`) with `BleProvStatus` (`bat`/`state`/`ssid`/`ip`/`host`)
- [ ] Replace BLE `L:`/`G:`/`P:`/`M:` writes with Wi-Fi setup form (`S:`/`S+:`, `K:`/`K+:`, `W:1`, `W:0`)
- [ ] Handle intentional BLE disconnect gracefully once `state == connected` and `ip` is received
- [ ] Display the resulting `http://<ip>/` URL clearly (with Copy / Share so it is easy to open on Windows)
- [ ] *(Optional)* Re-point the existing Flutter Letter / Group / Pairs tabs to `GET /api/status` and `POST /api/display` over HTTP so both phone and Windows PC can send messages

---

## Firmware Source of Truth (`feat/wifi-web-server`)

| File | Responsibility |
|------|----------------|
| `ble_remote.cpp` / `ble_remote.h` | BLE GATT UUIDs, `S:`/`K:`/`W:` parser, `STATUS` format, `BLEDevice::deinit(true)` |
| `net_manager.cpp` / `net_manager.h` | NVS credential storage, 15s boot timeout fallback, 3s BLE close grace window, mDNS |
| `web_server.cpp` / `web_ui.h` | HTTP endpoints (`/`, `/api/status`, `/api/display`, `/api/wifi/reset`) & embedded UI |
| `buttons.cpp` | 3-second `BOOT` hold (`BUTTON_BOOT_LONG`) to reset Wi-Fi back to `BT Setup` |
| `sketch.yaml` / `partitions.csv` | `Huge APP (3MB No OTA)` partition configuration required when flashing |
