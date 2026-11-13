import 'commands.dart';
import 'constants.dart';

enum EpdMode {
  letter,
  group,
  pairs;

  static EpdMode? fromWire(String? value) {
    return switch (value?.trim()) {
      '0' => EpdMode.letter,
      '1' => EpdMode.group,
      '2' => EpdMode.pairs,
      _ => null,
    };
  }

  static EpdMode? fromInt(int? value) {
    return switch (value) {
      0 => EpdMode.letter,
      1 => EpdMode.group,
      2 => EpdMode.pairs,
      _ => null,
    };
  }

  String get label => switch (this) {
    EpdMode.letter => 'Single',
    EpdMode.group => 'Multiple',
    EpdMode.pairs => 'List',
  };
}

class EpdStatus {
  const EpdStatus({
    this.battery,
    this.mode,
    this.letter,
    this.group,
    this.pairsCount,
    this.pairs = const [],
    this.ssid,
    this.ip,
    this.host,
    this.rendering = false,
    this.raw = '',
  });

  final int? battery;
  final EpdMode? mode;
  final String? letter;
  final String? group;
  final int? pairsCount;
  final List<LetterDigitPair> pairs;
  final String? ssid;
  final String? ip;
  final String? host;
  final bool rendering;
  final String raw;

  static const empty = EpdStatus();

  bool get isStandby =>
      mode == EpdMode.group && group?.toUpperCase() == kStandbyWord;

  String get onDeviceSummary {
    if (isStandby) return 'Stand-by ($kStandbyWord)';
    return switch (mode) {
      EpdMode.letter => letter != null ? 'Single: $letter' : 'Single',
      EpdMode.group => group != null ? 'Multiple: $group' : 'Multiple',
      EpdMode.pairs => pairs.isNotEmpty
          ? 'Pairs: ${pairs.map((p) => '${p.letter}${p.digit}').join(', ')}'
          : pairsCount != null
              ? 'Pairs ($pairsCount)'
              : 'Pairs',
      null => '',
    };
  }

  static EpdStatus parse(String raw) {
    final fields = <String, String>{};
    for (final part in raw.split(';')) {
      final separator = part.indexOf('=');
      if (separator <= 0) continue;
      final key = part.substring(0, separator).trim();
      final value = part.substring(separator + 1).trim();
      if (key.isEmpty) continue;
      fields[key] = value;
    }

    return EpdStatus(
      battery: int.tryParse(fields['bat'] ?? ''),
      mode: EpdMode.fromWire(fields['mode']),
      letter: _optional(fields['letter']),
      group: _optional(fields['group']),
      pairsCount: int.tryParse(fields['pairs'] ?? ''),
      ssid: _optional(fields['ssid']),
      ip: _optional(fields['ip']),
      host: _optional(fields['host']),
      raw: raw,
    );
  }

  factory EpdStatus.fromJson(Map<String, dynamic> json, {String raw = ''}) {
    final rawMode = json['mode'];
    final mode = rawMode is num
        ? EpdMode.fromInt(rawMode.toInt())
        : EpdMode.fromWire(rawMode?.toString());

    final rawPairs = json['pairs'];
    final parsedPairs = rawPairs is List
        ? pairsFromTokens(rawPairs.map((item) => item.toString()))
        : const <LetterDigitPair>[];
    final pairsCount = rawPairs is List
        ? parsedPairs.length
        : (rawPairs is num
            ? rawPairs.toInt()
            : int.tryParse(rawPairs?.toString() ?? ''));

    return EpdStatus(
      battery: (json['battery'] as num?)?.toInt() ??
          int.tryParse(json['battery']?.toString() ?? ''),
      mode: mode,
      letter: _optional(json['letter']?.toString()),
      group: _optional(json['group']?.toString()),
      pairsCount: pairsCount,
      pairs: parsedPairs,
      ssid: _optional(json['ssid']?.toString()),
      ip: _optional(json['ip']?.toString()),
      host: _optional(json['host']?.toString()),
      rendering: json['rendering'] == true,
      raw: raw,
    );
  }

  static String? _optional(String? value) {
    if (value == null || value.isEmpty) return null;
    return value;
  }
}
