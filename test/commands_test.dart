import 'package:esp_flutter/ble/commands.dart';
import 'package:esp_flutter/ble/status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('letter command', () {
    expect(isValidLetter('a'), isTrue);
    expect(isValidLetter('AB'), isFalse);
    expect(letterCommand('q'), 'L:Q');
  });

  test('group command', () {
    expect(isValidGroup('A'), isFalse);
    expect(isValidGroup('AB'), isTrue);
    expect(isValidGroup('ABCDE'), isTrue);
    expect(isValidGroup('ABCDEF'), isFalse);
    expect(groupCommand('ab c'), 'G:ABC');
  });

  test('pairs command', () {
    const pairs = [
      LetterDigitPair(letter: 'A', digit: '4'),
      LetterDigitPair(letter: 'B', digit: '2'),
      LetterDigitPair(letter: '', digit: ''),
    ];
    expect(isValidPairs(pairs), isTrue);
    expect(pairsCommand(pairs), 'P:A4,B2');
    expect(isValidPairs(const []), isFalse);
  });

  test('pairs reject more than 8', () {
    final pairs = [
      for (var i = 0; i < 9; i++)
        const LetterDigitPair(letter: 'A', digit: '1'),
    ];
    expect(isValidPairs(pairs), isFalse);
  });

  test('sent command summary and pairs parse', () {
    final stamp = DateTime(2026, 9, 18);
    final letter = SentCommand(command: 'L:Q', sentAt: stamp);
    expect(letter.mode, EpdMode.letter);
    expect(letter.summary, 'Single Q');
    expect(letter.numberedLabel(1), '1. Single Q');

    final group = SentCommand(command: 'G:ABC', sentAt: stamp);
    expect(group.mode, EpdMode.group);
    expect(group.payload, 'ABC');

    final pairsCmd = SentCommand(command: 'P:A4,B2', sentAt: stamp);
    expect(pairsCmd.mode, EpdMode.pairs);
    expect(pairsCmd.summary, 'List A4, B2');
    expect(pairsCmd.numberedLabel(2), '2. List A4, B2');
    expect(pairsFromCommand(pairsCmd.command), [
      const LetterDigitPair(letter: 'A', digit: '4'),
      const LetterDigitPair(letter: 'B', digit: '2'),
    ]);
  });
}
