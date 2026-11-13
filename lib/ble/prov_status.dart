import 'constants.dart';

enum BleProvState {
  unconfigured,
  ready,
  connecting,
  connected,
  error,
  unknown;

  static BleProvState fromString(String? raw) {
    switch (raw?.trim()) {
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

  String get label => switch (this) {
    BleProvState.unconfigured => 'Unconfigured',
    BleProvState.ready => 'Ready for Wi-Fi setup',
    BleProvState.connecting => 'Connecting to Wi-Fi…',
    BleProvState.connected => 'Connected to Wi-Fi',
    BleProvState.error => 'Wi-Fi connection failed',
    BleProvState.unknown => 'Connected over Bluetooth',
  };
}

class BleProvStatus {
  const BleProvStatus({
    this.battery,
    this.state = BleProvState.unknown,
    this.ssid = '',
    this.ip = '',
    this.host = kDefaultHost,
    this.raw = '',
  });

  final int? battery;
  final BleProvState state;
  final String ssid;
  final String ip;
  final String host;
  final String raw;

  static const empty = BleProvStatus();

  String? get webUrl => ip.isNotEmpty ? 'http://$ip/' : null;

  String get hostUrl => 'http://${host.isNotEmpty ? host : kDefaultHost}/';

  factory BleProvStatus.parse(String raw) {
    final cleaned = raw.replaceAll('\r', '').replaceAll('\n', '');
    final map = <String, String>{};
    for (final part in cleaned.split(';')) {
      final idx = part.indexOf('=');
      if (idx <= 0) continue;
      final key = part.substring(0, idx).trim();
      final value = part.substring(idx + 1);
      if (key.isEmpty) continue;
      map[key] = value;
    }

    final hostValue = (map['host'] ?? '').trim();
    return BleProvStatus(
      battery: int.tryParse((map['bat'] ?? '').trim()),
      state: BleProvState.fromString(map['state']),
      ssid: map['ssid'] ?? '',
      ip: (map['ip'] ?? '').trim(),
      host: hostValue.isEmpty ? kDefaultHost : hostValue,
      raw: raw,
    );
  }
}
