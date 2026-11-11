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
  });

  test('parses pairs count only', () {
    final status = EpdStatus.parse('bat=87;mode=2;pairs=4');
    expect(status.mode, EpdMode.pairs);
    expect(status.pairsCount, 4);
  });

  test('ignores unknown keys and extra spaces', () {
    final status = EpdStatus.parse(' bat = 10 ; mode = 0 ; letter = Q ; extra=1 ');
    expect(status.battery, 10);
    expect(status.mode, EpdMode.letter);
    expect(status.letter, 'Q');
  });
}
