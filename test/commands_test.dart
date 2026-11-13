import 'dart:convert';

import 'package:esp_flutter/ble/commands.dart';
import 'package:esp_flutter/ble/epd_client.dart';
import 'package:esp_flutter/ble/status.dart';
import 'package:esp_flutter/screens/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  test('combined letters selection command and THINK stand-by', () {
    expect(lettersSelectionCommand(['c']), 'L:C');
    expect(lettersSelectionCommand(['E', 'A', 'C']), 'G:ACE');
    expect(() => lettersSelectionCommand(const []), throwsArgumentError);
    expect(
      () => lettersSelectionCommand(['A', 'B', 'C', 'D', 'E', 'F']),
      throwsArgumentError,
    );

    expect(standbyCommand(), 'G:THINK');
    final standbySent = SentCommand(
      command: standbyCommand(),
      sentAt: DateTime(2026, 11, 11),
    );
    expect(standbySent.isStandby, isTrue);
    expect(standbySent.summary, 'Stand-by THINK');
  });

  test('preset A-G pairs map keeps A-G order', () {
    final pairs = presetPairsFromMap({
      'C': '1',
      'A': '2',
      'G': '4',
      'B': null,
    });
    expect(pairs, const [
      LetterDigitPair(letter: 'A', digit: '2'),
      LetterDigitPair(letter: 'C', digit: '1'),
      LetterDigitPair(letter: 'G', digit: '4'),
    ]);
    expect(pairsCommand(pairs), 'P:A2,C1,G4');
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

  group('EpdClient over HTTP', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('connects, sends combined letters/THINK/pairs, and resets Wi-Fi', () async {
      final postedCommands = <String>[];
      var resetCalled = false;
      var currentGroup = 'AB';
      var currentMode = 0;

      final mockHttp = MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/api/status') {
          return http.Response(
            jsonEncode({
              'battery': 91,
              'mode': currentMode,
              'letter': 'A',
              'group': currentGroup,
              'pairs': ['A2', 'B1'],
              'ssid': 'Studio24G',
              'ip': '192.168.1.42',
              'host': 'epd-c6.local',
              'rendering': false,
            }),
            200,
          );
        }
        if (request.method == 'POST' && request.url.path == '/api/display') {
          postedCommands.add(request.body);
          if (request.body.startsWith('G:')) {
            currentMode = 1;
            currentGroup = request.body.substring(2);
          } else if (request.body.startsWith('P:')) {
            currentMode = 2;
          } else if (request.body.startsWith('L:')) {
            currentMode = 0;
          }
          return http.Response('{"ok":true}', 200);
        }
        if (request.method == 'POST' && request.url.path == '/api/wifi/reset') {
          resetCalled = true;
          return http.Response('{"ok":true}', 200);
        }
        return http.Response('Not found', 404);
      });

      final client = EpdClient(
        httpClient: mockHttp,
        isHttpsWebOverride: false,
      );
      addTearDown(client.dispose);

      final connected = await client.connectToAddress('http://192.168.1.42/');
      expect(connected, isTrue);
      expect(client.isConnected, isTrue);
      expect(client.savedIp, '192.168.1.42');
      expect(client.status.battery, 91);

      await client.sendLettersSelection(['D', 'A']);
      await client.sendStandby();
      expect(client.status.isStandby, isTrue);

      await client.sendPairs(const [
        LetterDigitPair(letter: 'A', digit: '2'),
        LetterDigitPair(letter: 'B', digit: '1'),
      ]);

      expect(postedCommands, ['G:AD', 'G:THINK', 'P:A2,B1']);
      expect(client.history.length, 3);

      await client.resetDeviceWifi();
      expect(resetCalled, isTrue);
      expect(client.isConnected, isFalse);
      expect(client.savedIp, isNull);
    });

    test('allows local HTTP requests on HTTPS Web when browser permits Local Network Access', () async {
      final client = EpdClient(
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'battery': 95,
              'mode': 0,
              'letter': 'B',
              'group': 'BC',
              'pairs': <String>[],
              'ssid': 'Office24G',
              'ip': '192.168.1.42',
              'host': 'epd-c6.local',
              'rendering': false,
            }),
            200,
          ),
        ),
        isHttpsWebOverride: true,
      );
      addTearDown(client.dispose);

      final connected = await client.connectToAddress('192.168.1.42');
      expect(connected, isTrue);
      expect(client.isConnected, isTrue);
      expect(client.mixedContentBlocked, isFalse);
      expect(client.status.letter, 'B');
    });

    test('surfaces Local Network Access guidance when HTTPS Web fetch is blocked', () async {
      final client = EpdClient(
        httpClient: MockClient(
          (request) async =>
              throw http.ClientException('Failed to fetch', request.url),
        ),
        isHttpsWebOverride: true,
      );
      addTearDown(client.dispose);

      final connected = await client.connectToAddress('192.168.1.42');
      expect(connected, isFalse);
      expect(client.mixedContentBlocked, isTrue);
      expect(client.errorMessage, contains('Local network access'));
    });
  });

  testWidgets('HomeScreen toggles A-G letters, THINK, and A-G pair numbers', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final posted = <String>[];

    final mockHttp = MockClient((request) async {
      if (request.url.path == '/api/status') {
        return http.Response(
          jsonEncode({
            'battery': 85,
            'mode': 0,
            'letter': 'A',
            'group': 'AB',
            'pairs': <String>[],
            'ssid': 'Home24G',
            'ip': '192.168.1.50',
            'host': 'epd-c6.local',
            'rendering': false,
          }),
          200,
        );
      }
      if (request.url.path == '/api/display') {
        posted.add(request.body);
        return http.Response('{"ok":true}', 200);
      }
      return http.Response('{}', 404);
    });

    final client = EpdClient(httpClient: mockHttp, isHttpsWebOverride: false);
    addTearDown(client.dispose);
    await client.connectToAddress('192.168.1.50');

    await tester.pumpWidget(MaterialApp(home: HomeScreen(client: client)));
    await tester.pumpAndSettle();

    // Initially synced to 'A' from status; tap 'C' to toggle Multiple (AC)
    await tester.tap(find.text('C'));
    await tester.pump();
    expect(find.text('Send Multiple (AC)'), findsOneWidget);

    await tester.tap(find.text('Send Multiple (AC)'));
    await tester.pumpAndSettle();
    expect(posted.last, 'G:AC');

    // Tap THINK stand-by button
    await tester.tap(find.text('THINK'));
    await tester.pumpAndSettle();
    expect(posted.last, 'G:THINK');

    // Switch to Pairs tab and tap numbers next to B and A
    await tester.tap(find.text('Pairs'));
    await tester.pumpAndSettle();

    // Tap digit '2' on row A (first '2') and digit '1' on row B (second '1')
    await tester.tap(find.text('2').first);
    await tester.pump();
    await tester.tap(find.text('1').at(1));
    await tester.pump();

    expect(find.text('Send Pairs (A2, B1)'), findsOneWidget);
    await tester.tap(find.text('Send Pairs (A2, B1)'));
    await tester.pumpAndSettle();
    expect(posted.last, 'P:A2,B1');
  });
}
