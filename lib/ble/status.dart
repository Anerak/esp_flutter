enum EpdMode {
  letter,
  group,
  pairs;

  static EpdMode? fromWire(String? value) {
    return switch (value) {
      '0' => EpdMode.letter,
      '1' => EpdMode.group,
      '2' => EpdMode.pairs,
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
    this.raw = '',
  });

  final int? battery;
  final EpdMode? mode;
  final String? letter;
  final String? group;
  final int? pairsCount;
  final String raw;

  static const empty = EpdStatus();

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
      raw: raw,
    );
  }

  static String? _optional(String? value) {
    if (value == null || value.isEmpty) return null;
    return value;
  }
}
