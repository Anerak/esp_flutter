import 'package:esp_flutter/ble/commands.dart';
import 'package:esp_flutter/ble/status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses letter status', () {
    final status = EpdStatus.parse('bat=87;mode=0;letter=A');
    expect(status.battery, 87);
    expect(status.mode, EpdMode.letter);
    expect(status.letter, 'A');
    expect(status.group, isNull);
    expect(status.pairsCount, isNull);
  });

  test('parses group status', () {
    final status = EpdStatus.parse('bat=87;mode=1;group=ABCDE');
    expect(status.mode, EpdMode.group);
    expect(status.group, 'ABCDE');
    expect(status.isStandby, isFalse);
  });

  test('parses pairs count only', () {
    final status = EpdStatus.parse('bat=87;mode=2;pairs=4');
    expect(status.mode, EpdMode.pairs);
    expect(status.pairsCount, 4);
  });

  test('ignores unknown keys and extra spaces', () {
    final status = EpdStatus.parse(
      ' bat = 10 ; mode = 0 ; letter = Q ; extra=1 ',
    );
    expect(status.battery, 10);
    expect(status.mode, EpdMode.letter);
    expect(status.letter, 'Q');
  });

  test('parses /api/status JSON with full pairs list and network metadata', () {
    final status = EpdStatus.fromJson({
      'battery': 87,
      'mode': 2,
      'letter': 'A',
      'group': 'ABCDE',
      'pairs': ['A4', 'B2', 'C3', 'D5'],
      'ssid': 'MyHomeWiFi',
      'ip': '192.168.1.42',
      'host': 'epd-c6.local',
      'rendering': true,
    });

    expect(status.battery, 87);
    expect(status.mode, EpdMode.pairs);
    expect(status.pairsCount, 4);
    expect(status.pairs, const [
      LetterDigitPair(letter: 'A', digit: '4'),
      LetterDigitPair(letter: 'B', digit: '2'),
      LetterDigitPair(letter: 'C', digit: '3'),
      LetterDigitPair(letter: 'D', digit: '5'),
    ]);
    expect(status.ssid, 'MyHomeWiFi');
    expect(status.ip, '192.168.1.42');
    expect(status.host, 'epd-c6.local');
    expect(status.rendering, isTrue);
    expect(status.isStandby, isFalse);
  });

  test('detects THINK stand-by mode in status', () {
    final status = EpdStatus.fromJson({
      'battery': 92,
      'mode': 1,
      'letter': 'A',
      'group': 'THINK',
      'pairs': <String>[],
      'ssid': 'MyHomeWiFi',
      'ip': '192.168.1.42',
      'host': 'epd-c6.local',
      'rendering': false,
    });

    expect(status.isStandby, isTrue);
    expect(status.onDeviceSummary, 'Stand-by (THINK)');
  });
}
