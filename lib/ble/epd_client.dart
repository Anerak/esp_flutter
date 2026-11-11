import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'commands.dart';
import 'constants.dart';
import 'status.dart';

enum EpdConnectionState { disconnected, scanning, connecting, connected }

class EpdClient extends ChangeNotifier {
  EpdConnectionState connection = EpdConnectionState.disconnected;
  EpdStatus status = EpdStatus.empty;
  bool updating = false;
  String? errorMessage;
  final List<SentCommand> history = [];

  BluetoothDevice? _device;
  BluetoothCharacteristic? _cmdChar;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  Timer? _updateTimer;
  bool _silentDisconnect = false;

  bool get isConnected => connection == EpdConnectionState.connected;

  Future<void> scanAndConnect() async {
    if (connection == EpdConnectionState.scanning ||
        connection == EpdConnectionState.connecting) {
      return;
    }

    errorMessage = null;
    connection = EpdConnectionState.scanning;
    notifyListeners();

    try {
      await _ensurePermissions();
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
      final scanSub = FlutterBluePlus.onScanResults.listen((results) {
        for (final result in results) {
          if (_isEpd(result)) {
            found = result.device;
            FlutterBluePlus.stopScan();
            break;
          }
        }
      });
      FlutterBluePlus.cancelWhenScanComplete(scanSub);

      await FlutterBluePlus.startScan(
        withNames: const [kDeviceName],
        withServices: [Guid(kServiceUuid)],
        timeout: kScanTimeout,
        androidUsesFineLocation: false,
        androidCheckLocationServices: false,
      );
      await FlutterBluePlus.isScanning.where((scanning) => !scanning).first;

      if (found == null) {
        connection = EpdConnectionState.disconnected;
        errorMessage = 'EPD-C6 not found. Is the board on and nearby?';
        notifyListeners();
        return;
      }

      await _connectDevice(found!);
    } catch (error) {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      connection = EpdConnectionState.disconnected;
      errorMessage = _friendlyError(error);
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    _silentDisconnect = true;
    _updateTimer?.cancel();
    updating = false;
    try {
      await _device?.disconnect();
    } catch (_) {}
    _clearLink();
    connection = EpdConnectionState.disconnected;
    errorMessage = null;
    _silentDisconnect = false;
    notifyListeners();
  }

  Future<void> sendLetter(String input) {
    if (!isValidLetter(input)) {
      throw ArgumentError('Single mode needs one A–Z letter');
    }
    return sendCommand(letterCommand(input));
  }

  Future<void> sendGroup(String input) {
    if (!isValidGroup(input)) {
      throw ArgumentError('Multiple mode needs $kGroupMinLen–$kGroupMaxLen letters');
    }
    return sendCommand(groupCommand(input));
  }

  Future<void> sendPairs(Iterable<LetterDigitPair> pairs) {
    if (!isValidPairs(pairs)) {
      throw ArgumentError('List mode needs 1–$kPairsMax letter+digit pairs');
    }
    return sendCommand(pairsCommand(pairs));
  }

  Future<void> sendCommand(String command) async {
    final cmdChar = _cmdChar;
    if (!isConnected || cmdChar == null) {
      throw StateError('Not connected');
    }
    if (command.length > kCmdMaxLen) {
      throw ArgumentError('Command longer than $kCmdMaxLen characters');
    }
    if (updating) return;

    updating = true;
    errorMessage = null;
    notifyListeners();
    _updateTimer?.cancel();
    _updateTimer = Timer(kUpdateTimeout, () {
      if (!updating) return;
      updating = false;
      notifyListeners();
    });

    final bytes = utf8.encode(command);
    final withoutResponse = cmdChar.properties.writeWithoutResponse;
    await cmdChar.write(bytes, withoutResponse: withoutResponse);
    _remember(command);
    notifyListeners();
  }

  void _remember(String command) {
    if (command == 'B?' || !command.contains(':')) return;
    history.removeWhere((item) => item.command == command);
    history.insert(0, SentCommand(command: command, sentAt: DateTime.now()));
    if (history.length > kHistoryMax) {
      history.removeRange(kHistoryMax, history.length);
    }
  }

  BluetoothDevice? _alreadyKnownDevice() {
    for (final device in FlutterBluePlus.connectedDevices) {
      if (device.platformName == kDeviceName) return device;
    }
    return null;
  }

  bool _isEpd(ScanResult result) {
    final name = result.device.platformName.isNotEmpty
        ? result.device.platformName
        : result.advertisementData.advName;
    if (name == kDeviceName) return true;
    return result.advertisementData.serviceUuids.contains(Guid(kServiceUuid));
  }

  Future<void> _connectDevice(BluetoothDevice device) async {
    connection = EpdConnectionState.connecting;
    notifyListeners();
    _device = device;

    await _connSub?.cancel();
    _connSub = device.connectionState.listen((state) {
      if (state != BluetoothConnectionState.disconnected) return;
      if (!identical(_device, device)) return;
      _clearLink();
      connection = EpdConnectionState.disconnected;
      if (!_silentDisconnect) {
        errorMessage ??= 'Disconnected from EPD-C6';
      }
      notifyListeners();
    });

    try {
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 15),
      );

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
      _cmdChar = cmdChar;

      await _notifySub?.cancel();
      _notifySub = statusChar.onValueReceived.listen(_onStatusBytes);
      device.cancelWhenDisconnected(_notifySub!);
      await statusChar.setNotifyValue(true);

      try {
        _onStatusBytes(await statusChar.read());
      } catch (_) {}

      connection = EpdConnectionState.connected;
      if (status.battery == null) {
        try {
          await sendCommand('B?');
        } catch (_) {}
      }
      notifyListeners();
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
    status = EpdStatus.parse(utf8.decode(value, allowMalformed: true));
    updating = false;
    _updateTimer?.cancel();
    notifyListeners();
  }

  Future<void> _ensurePermissions() async {
    if (!Platform.isAndroid) return;

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
    if (Platform.isAndroid) {
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
    _cmdChar = null;
    _device = null;
    updating = false;
    _updateTimer?.cancel();
  }

  String _friendlyError(Object error) {
    final text = error.toString();
    if (text.contains('permission')) return 'Bluetooth permission denied';
    return text.replaceFirst('Exception: ', '').replaceFirst('StateError: ', '');
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    _notifySub?.cancel();
    _connSub?.cancel();
    _device?.disconnect();
    super.dispose();
  }
}
