import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'constants.dart';
import 'prov_status.dart';
import 'provisioning.dart';

enum BleLinkState {
  disconnected,
  scanning,
  connecting,
  connected,
  provisioned,
}

typedef OnWifiProvisioned = FutureOr<void> Function(BleProvStatus status);

class BleProvisioner extends ChangeNotifier {
  BleProvisioner({this.onProvisioned});

  final OnWifiProvisioned? onProvisioned;

  BleLinkState link = BleLinkState.disconnected;
  BleProvStatus status = BleProvStatus.empty;
  bool submitting = false;
  bool provisionSucceeded = false;
  String? errorMessage;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _statusChar;
  BluetoothCharacteristic? _cmdChar;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  Timer? _provisionTimer;
  Timer? _statusPollTimer;
  bool _silentDisconnect = false;
  bool _disposed = false;

  bool get isBleConnected => link == BleLinkState.connected;
  bool get isBusy =>
      link == BleLinkState.scanning ||
      link == BleLinkState.connecting ||
      submitting;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> scanAndConnect() async {
    if (link == BleLinkState.scanning || link == BleLinkState.connecting) {
      return;
    }

    errorMessage = null;
    provisionSucceeded = false;
    submitting = false;
    status = BleProvStatus.empty;
    link = BleLinkState.scanning;
    _safeNotify();

    try {
      if (kIsWeb) {
        // Keep navigator.bluetooth.requestDevice inside the user click gesture:
        // avoid awaiting async permission/adapter calls before startScan on Web.
        await _scanAndConnectWeb();
        return;
      }

      final supported = await FlutterBluePlus.isSupported;
      if (!supported) {
        throw StateError('Bluetooth Low Energy is not supported on this device');
      }

      if (_isAndroid) {
        await _ensureAndroidPermissions();
      }
      await _ensureAdapterOn();

      final already = _alreadyKnownDevice();
      if (already != null) {
        await _connectDevice(already);
        return;
      }

      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }

      BluetoothDevice? found;
      Object? scanError;
      final scanSub = FlutterBluePlus.onScanResults.listen(
        (results) {
          for (final result in results) {
            if (_isEpd(result)) {
              found = result.device;
              FlutterBluePlus.stopScan();
              break;
            }
          }
        },
        onError: (Object error) {
          scanError = error;
        },
      );
      FlutterBluePlus.cancelWhenScanComplete(scanSub);

      await FlutterBluePlus.startScan(
        withNames: const [kDeviceName],
        withServices: [Guid(kServiceUuid)],
        timeout: kScanTimeout,
        androidUsesFineLocation: false,
        androidCheckLocationServices: false,
      );
      await FlutterBluePlus.isScanning.where((scanning) => !scanning).first;

      if (scanError != null && found == null) {
        throw scanError!;
      }

      if (found == null) {
        link = BleLinkState.disconnected;
        errorMessage =
            'EPD-C6 not found. Make sure the screen shows "BT Setup" (hold BOOT for 3s if needed).';
        _safeNotify();
        return;
      }

      await _connectDevice(found!);
    } catch (error) {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      link = BleLinkState.disconnected;
      errorMessage = _friendlyError(error);
      _safeNotify();
    }
  }

  Future<void> _scanAndConnectWeb() async {
    final deviceCompleter = Completer<BluetoothDevice?>();

    final scanSub = FlutterBluePlus.onScanResults.listen(
      (results) {
        if (results.isNotEmpty && !deviceCompleter.isCompleted) {
          deviceCompleter.complete(results.first.device);
        }
      },
      onError: (Object error) {
        if (!deviceCompleter.isCompleted) {
          deviceCompleter.completeError(error);
        }
      },
    );

    BluetoothDevice? found;
    try {
      await FlutterBluePlus.startScan(
        withNames: const [kDeviceName],
        withServices: [Guid(kServiceUuid)],
        webOptionalServices: [Guid(kServiceUuid)],
      );

      // FlutterBluePlus buffers Web Bluetooth's requestDevice result through an
      // async* stream after startScan() returns; wait for that delivery before
      // calling stopScan(), otherwise stopScan() closes the buffer prematurely.
      if (!deviceCompleter.isCompleted &&
          FlutterBluePlus.lastScanResults.isNotEmpty) {
        deviceCompleter.complete(FlutterBluePlus.lastScanResults.first.device);
      }

      found = await deviceCompleter.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () => FlutterBluePlus.lastScanResults.isNotEmpty
            ? FlutterBluePlus.lastScanResults.first.device
            : null,
      );
    } finally {
      await scanSub.cancel();
      if (FlutterBluePlus.isScanningNow) {
        try {
          await FlutterBluePlus.stopScan();
        } catch (_) {}
      }
    }

    if (found == null) {
      link = BleLinkState.disconnected;
      errorMessage = 'No EPD-C6 device selected.';
      _safeNotify();
      return;
    }

    await _connectDevice(found);
  }

  Future<void> provisionWifi({
    required String ssid,
    required String password,
  }) async {
    final cmdChar = _cmdChar;
    if (!isBleConnected || cmdChar == null) {
      throw StateError('Not connected to EPD-C6 over Bluetooth');
    }
    if (submitting) return;

    final commands = buildProvisioningSequence(ssid: ssid, password: password);

    submitting = true;
    errorMessage = null;
    _safeNotify();

    _provisionTimer?.cancel();
    _statusPollTimer?.cancel();
    _provisionTimer = Timer(kProvisionTimeout, () {
      if (!submitting || provisionSucceeded) return;
      _statusPollTimer?.cancel();
      submitting = false;
      errorMessage =
          'Timed out waiting for Wi-Fi connection. Check password and ensure the network is 2.4 GHz.';
      _safeNotify();
    });

    try {
      for (final command in commands) {
        await _writeCmd(cmdChar, command);
      }
      _startStatusReadFallback();
    } catch (error) {
      _provisionTimer?.cancel();
      _statusPollTimer?.cancel();
      submitting = false;
      errorMessage = _friendlyError(error);
      _safeNotify();
      rethrow;
    }
  }

  void _startStatusReadFallback() {
    _statusPollTimer?.cancel();
    _statusPollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      final statusChar = _statusChar;
      if (!submitting ||
          provisionSucceeded ||
          !isBleConnected ||
          statusChar == null) {
        timer.cancel();
        return;
      }
      try {
        _onStatusBytes(await statusChar.read());
      } catch (_) {}
    });
  }

  Future<void> clearCredentials() async {
    final cmdChar = _cmdChar;
    if (!isBleConnected || cmdChar == null) {
      throw StateError('Not connected to EPD-C6 over Bluetooth');
    }
    if (submitting) return;

    errorMessage = null;
    _safeNotify();
    try {
      await _writeCmd(cmdChar, 'W:0');
      await _writeCmd(cmdChar, 'W?');
    } catch (error) {
      errorMessage = _friendlyError(error);
      _safeNotify();
      rethrow;
    }
  }

  Future<void> refreshStatus() async {
    final cmdChar = _cmdChar;
    if (!isBleConnected || cmdChar == null) return;
    try {
      await _writeCmd(cmdChar, 'W?');
    } catch (_) {}
  }

  Future<void> disconnect() async {
    _silentDisconnect = true;
    _provisionTimer?.cancel();
    _statusPollTimer?.cancel();
    submitting = false;
    try {
      await _device?.disconnect();
    } catch (_) {}
    _clearLink();
    if (!provisionSucceeded) {
      link = BleLinkState.disconnected;
    }
    errorMessage = null;
    _silentDisconnect = false;
    _safeNotify();
  }

  Future<void> _writeCmd(BluetoothCharacteristic cmdChar, String cmd) async {
    await cmdChar.write(utf8.encode(cmd), withoutResponse: false);
  }

  BluetoothDevice? _alreadyKnownDevice() {
    for (final device in FlutterBluePlus.connectedDevices) {
      if (device.platformName == kDeviceName) return device;
    }
    return null;
  }

  bool _isEpd(ScanResult result) {
    if (kIsWeb) return true;
    final name = result.device.platformName.isNotEmpty
        ? result.device.platformName
        : result.advertisementData.advName;
    if (name == kDeviceName) return true;
    return result.advertisementData.serviceUuids.contains(Guid(kServiceUuid));
  }

  Future<void> _connectDevice(BluetoothDevice device) async {
    link = BleLinkState.connecting;
    _safeNotify();
    _device = device;

    var sawConnected = false;
    await _connSub?.cancel();
    _connSub = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.connected) {
        sawConnected = true;
        return;
      }
      // Ignore the initial cached `disconnected` emission before `connect()` completes.
      if (!sawConnected || state != BluetoothConnectionState.disconnected) {
        return;
      }
      if (!identical(_device, device)) return;
      _clearLink();
      if (provisionSucceeded) {
        // Firmware calls BLEDevice::deinit(true) ~3s after Wi-Fi connects.
        link = BleLinkState.provisioned;
        errorMessage = null;
      } else {
        link = BleLinkState.disconnected;
        if (!_silentDisconnect) {
          errorMessage ??= 'Disconnected from EPD-C6';
        }
      }
      _safeNotify();
    });

    try {
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 15),
      );
      sawConnected = true;

      if (_isAndroid) {
        try {
          await device.requestMtu(kPreferredBleMtu);
        } catch (_) {}
      }

      final services = await device.discoverServices();
      BluetoothService? service;
      for (final candidate in services) {
        if (candidate.uuid == Guid(kServiceUuid)) {
          service = candidate;
          break;
        }
      }
      if (service == null) {
        throw StateError('EPD-C6 GATT service not found');
      }

      BluetoothCharacteristic? statusChar;
      BluetoothCharacteristic? cmdChar;
      for (final characteristic in service.characteristics) {
        if (characteristic.uuid == Guid(kStatusCharUuid)) {
          statusChar = characteristic;
        } else if (characteristic.uuid == Guid(kCmdCharUuid)) {
          cmdChar = characteristic;
        }
      }
      if (statusChar == null || cmdChar == null) {
        throw StateError('EPD-C6 STATUS/CMD characteristics not found');
      }
      _statusChar = statusChar;
      _cmdChar = cmdChar;

      await _notifySub?.cancel();
      _notifySub = statusChar.onValueReceived.listen(_onStatusBytes);
      device.cancelWhenDisconnected(_notifySub!);
      await statusChar.setNotifyValue(true);

      try {
        _onStatusBytes(await statusChar.read());
      } catch (_) {}

      if (!provisionSucceeded) {
        link = BleLinkState.connected;
      }

      if (status.raw.isEmpty) {
        try {
          await _writeCmd(cmdChar, 'W?');
        } catch (_) {}
      }
      _safeNotify();
    } catch (_) {
      try {
        await device.disconnect();
      } catch (_) {}
      _clearLink();
      rethrow;
    }
  }

  void _onStatusBytes(List<int> value) {
    if (value.isEmpty) return;
    final parsed = BleProvStatus.parse(utf8.decode(value, allowMalformed: true));
    status = parsed;

    if (parsed.state == BleProvState.connected && parsed.ip.isNotEmpty) {
      final firstSuccess = !provisionSucceeded;
      provisionSucceeded = true;
      submitting = false;
      errorMessage = null;
      _provisionTimer?.cancel();
      _statusPollTimer?.cancel();
      link = BleLinkState.provisioned;
      if (firstSuccess && onProvisioned != null) {
        unawaited(Future.sync(() => onProvisioned!(parsed)));
      }
    } else if (parsed.state == BleProvState.error) {
      submitting = false;
      _provisionTimer?.cancel();
      _statusPollTimer?.cancel();
      errorMessage =
          'Could not connect to Wi-Fi. Check password and ensure network is 2.4 GHz.';
    }

    _safeNotify();
  }

  Future<void> _ensureAndroidPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final scanGranted = statuses[Permission.bluetoothScan]?.isGranted ?? false;
    final connectGranted =
        statuses[Permission.bluetoothConnect]?.isGranted ?? false;
    final locationGranted =
        statuses[Permission.locationWhenInUse]?.isGranted ?? false;

    if (!(scanGranted && connectGranted) && !locationGranted) {
      throw StateError('Bluetooth permission denied');
    }
  }

  Future<void> _ensureAdapterOn() async {
    var adapter = await FlutterBluePlus.adapterState.first;
    if (adapter == BluetoothAdapterState.on) return;
    if (_isAndroid) {
      await FlutterBluePlus.turnOn();
      adapter = await FlutterBluePlus.adapterState
          .where((state) => state == BluetoothAdapterState.on)
          .first
          .timeout(const Duration(seconds: 20));
    }
    if (adapter != BluetoothAdapterState.on) {
      throw StateError('Turn on Bluetooth and try again');
    }
  }

  void _clearLink() {
    _notifySub?.cancel();
    _notifySub = null;
    _connSub?.cancel();
    _connSub = null;
    _statusChar = null;
    _cmdChar = null;
    _device = null;
    submitting = false;
    _provisionTimer?.cancel();
    _statusPollTimer?.cancel();
  }

  String _friendlyError(Object error) {
    final text = error.toString();
    final lower = text.toLowerCase();
    if (lower.contains('notfounderror') ||
        lower.contains('user cancelled') ||
        lower.contains('user canceled')) {
      return 'Bluetooth device selection cancelled.';
    }
    if (kIsWeb && lower.contains('networkerror')) {
      return 'Could not connect to EPD-C6 over Bluetooth. Make sure the screen shows "BT Setup" (hold BOOT for 3s if needed).';
    }
    if (kIsWeb &&
        (lower.contains('bluetooth') &&
            (lower.contains('undefined') ||
                lower.contains('not supported') ||
                lower.contains('availability')))) {
      return 'Web Bluetooth is unavailable. Open this app in Chrome or Edge on localhost or HTTPS.';
    }
    if (lower.contains('permission')) {
      return 'Bluetooth permission denied';
    }
    return text
        .replaceFirst('Exception: ', '')
        .replaceFirst('StateError: ', '')
        .replaceFirst('ArgumentError: ', '');
  }

  void _safeNotify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _provisionTimer?.cancel();
    _statusPollTimer?.cancel();
    _notifySub?.cancel();
    _connSub?.cancel();
    _device?.disconnect();
    super.dispose();
  }
}
