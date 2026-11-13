import 'constants.dart';
import 'status.dart';

final _letterPattern = RegExp(r'^[A-Z]$');
final _digitPattern = RegExp(r'^[0-9]$');

class LetterDigitPair {
  const LetterDigitPair({required this.letter, required this.digit});

  final String letter;
  final String digit;

  @override
  bool operator ==(Object other) =>
      other is LetterDigitPair && other.letter == letter && other.digit == digit;

  @override
  int get hashCode => Object.hash(letter, digit);

  @override
  String toString() => '$letter$digit';
}

String lettersOnly(String input) =>
    input.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');

bool isValidLetter(String input) =>
    _letterPattern.hasMatch(lettersOnly(input)) &&
    lettersOnly(input).length == 1;

bool isValidGroup(String input) {
  final letters = lettersOnly(input);
  return letters.length >= kGroupMinLen && letters.length <= kGroupMaxLen;
}

/// Normalizes selected letters to unique uppercase A–Z letters sorted in
/// alphabetical (A–G) order.
List<String> normalizeLettersSelection(Iterable<String> selected) {
  final unique = <String>{};
  for (final raw in selected) {
    final cleaned = lettersOnly(raw);
    for (var i = 0; i < cleaned.length; i++) {
      final ch = cleaned[i];
      if (_letterPattern.hasMatch(ch)) {
        unique.add(ch);
      }
    }
  }
  final sorted = unique.toList()..sort();
  return sorted;
}

bool isValidLettersSelection(Iterable<String> selected) {
  final normalized = normalizeLettersSelection(selected);
  return normalized.isNotEmpty && normalized.length <= kGroupMaxLen;
}

/// Builds `L:<X>` when 1 letter is toggled or `G:<XYZ>` (in A–G order) when
/// 2..5 letters are toggled.
String lettersSelectionCommand(Iterable<String> selected) {
  final normalized = normalizeLettersSelection(selected);
  if (normalized.isEmpty) {
    throw ArgumentError('Select at least 1 letter');
  }
  if (normalized.length > kGroupMaxLen) {
    throw ArgumentError('Select at most $kGroupMaxLen letters');
  }
  if (normalized.length == 1) {
    return letterCommand(normalized.first);
  }
  return groupCommand(normalized.join());
}

/// Builds the 1-tap stand-by display command (`G:THINK`).
String standbyCommand() => 'G:$kStandbyWord';

/// Converts a map of letter -> order digit (`'1'`..`'7'` or null) into
/// `LetterDigitPair` items ordered by [letters] (`A` through `G`).
List<LetterDigitPair> presetPairsFromMap(
  Map<String, String?> assignments, {
  List<String> letters = kPresetLetters,
}) {
  final pairs = <LetterDigitPair>[];
  for (final rawLetter in letters) {
    final letter = lettersOnly(rawLetter);
    if (!_letterPattern.hasMatch(letter)) continue;
    final digit = assignments[letter]?.trim() ?? '';
    if (_digitPattern.hasMatch(digit)) {
      pairs.add(LetterDigitPair(letter: letter, digit: digit));
    }
  }
  return pairs;
}

bool isCompletePair(LetterDigitPair pair) =>
    _letterPattern.hasMatch(pair.letter) && _digitPattern.hasMatch(pair.digit);

List<LetterDigitPair> completePairs(Iterable<LetterDigitPair> pairs) =>
    pairs.where(isCompletePair).toList(growable: false);

bool isValidPairs(Iterable<LetterDigitPair> pairs) {
  final ready = completePairs(pairs);
  return ready.isNotEmpty && ready.length <= kPairsMax;
}

String letterCommand(String input) => 'L:${lettersOnly(input)}';

String groupCommand(String input) => 'G:${lettersOnly(input)}';

String pairsCommand(Iterable<LetterDigitPair> pairs) {
  final ready = completePairs(pairs);
  return 'P:${ready.map((pair) => '${pair.letter}${pair.digit}').join(',')}';
}

class SentCommand {
  const SentCommand({required this.command, required this.sentAt});

  final String command;
  final DateTime sentAt;

  bool get isStandby => command.toUpperCase() == standbyCommand();

  EpdMode? get mode {
    if (command.startsWith('L:')) return EpdMode.letter;
    if (command.startsWith('G:')) return EpdMode.group;
    if (command.startsWith('P:')) return EpdMode.pairs;
    return null;
  }

  String get payload =>
      command.length >= 2 && command[1] == ':' ? command.substring(2) : command;

  String get displayPayload {
    if (mode != EpdMode.pairs) return payload;
    return pairsFromCommand(command)
        .map((pair) => '${pair.letter}${pair.digit}')
        .join(', ');
  }

  String get summary {
    if (isStandby) return 'Stand-by $kStandbyWord';
    final kind = mode;
    if (kind == null) return command;
    return '${kind.label} $displayPayload';
  }

  String numberedLabel(int number) => '$number. $summary';
}

List<LetterDigitPair> pairsFromCommand(String command) {
  if (!command.startsWith('P:')) return const [];
  return completePairs(pairsFromTokens(command.substring(2).split(',')));
}

List<LetterDigitPair> pairsFromTokens(Iterable<String> tokens) {
  return completePairs(
    tokens.map((token) {
      final trimmed = token.trim();
      if (trimmed.length < 2) {
        return const LetterDigitPair(letter: '', digit: '');
      }
      return LetterDigitPair(
        letter: lettersOnly(trimmed.substring(0, 1)),
        digit: trimmed.substring(1, 2),
      );
    }),
  );
}
