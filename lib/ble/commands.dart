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
}

String lettersOnly(String input) =>
    input.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');

bool isValidLetter(String input) => _letterPattern.hasMatch(lettersOnly(input)) &&
    lettersOnly(input).length == 1;

bool isValidGroup(String input) {
  final letters = lettersOnly(input);
  return letters.length >= kGroupMinLen && letters.length <= kGroupMaxLen;
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
    final kind = mode;
    if (kind == null) return command;
    return '${kind.label} $displayPayload';
  }

  String numberedLabel(int number) => '$number. $summary';
}

List<LetterDigitPair> pairsFromCommand(String command) {
  if (!command.startsWith('P:')) return const [];
  return completePairs(
    command.substring(2).split(',').map((token) {
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
