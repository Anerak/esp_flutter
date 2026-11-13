import 'dart:convert';

import 'package:esp_flutter/ble/constants.dart';
import 'package:esp_flutter/ble/prov_status.dart';
import 'package:esp_flutter/ble/provisioning.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BleProvStatus.parse', () {
    test('parses unconfigured status', () {
      final status = BleProvStatus.parse(
        'bat=88;state=unconfigured;ssid=;ip=;host=epd-c6.local',
      );
      expect(status.battery, 88);
      expect(status.state, BleProvState.unconfigured);
      expect(status.ssid, '');
      expect(status.ip, '');
      expect(status.host, 'epd-c6.local');
      expect(status.webUrl, isNull);
    });

    test('parses connected status and preserves spaces in SSID', () {
      final status = BleProvStatus.parse(
        'bat=87;state=connected;ssid=My Home WiFi 2.4G;ip=192.168.1.42;host=epd-c6.local\r\n',
      );
      expect(status.battery, 87);
      expect(status.state, BleProvState.connected);
      expect(status.ssid, 'My Home WiFi 2.4G');
      expect(status.ip, '192.168.1.42');
      expect(status.webUrl, 'http://192.168.1.42/');
      expect(status.hostUrl, 'http://epd-c6.local/');
    });

    test('parses error and connecting states', () {
      expect(
        BleProvStatus.parse('bat=50;state=connecting;ssid=Test;ip=').state,
        BleProvState.connecting,
      );
      expect(
        BleProvStatus.parse('bat=50;state=error;ssid=Test;ip=').state,
        BleProvState.error,
      );
    });
  });

  group('UTF-8 chunking and provisioning sequence', () {
    test('emits single empty command for open Wi-Fi password', () {
      final cmds = buildChunkedCommands(
        prefix: 'K:',
        appendPrefix: 'K+:',
        value: '',
      );
      expect(cmds, ['K:']);
    });

    test('chunks 32-byte SSID and 63-byte WPA2 password within 16-byte payload limit', () {
      final ssid = 'A' * 32;
      final password = 'p' * 63;

      final seq = buildProvisioningSequence(ssid: ssid, password: password);
      expect(seq.first, 'S:${'A' * 16}');
      expect(seq[1], 'S+:${'A' * 16}');
      expect(seq[2], 'K:${'p' * 16}');
      expect(seq[3], 'K+:${'p' * 16}');
      expect(seq[4], 'K+:${'p' * 16}');
      expect(seq[5], 'K+:${'p' * 15}');
      expect(seq.last, 'W:1');
    });

    test('never splits multi-byte UTF-8 codepoints across 16-byte chunks', () {
      // 15 ASCII bytes + 2-byte 'é' + 4-byte '🔥' + '24G'
      const value = '123456789012345é🔥24G';
      final chunks = buildChunkedCommands(
        prefix: 'S:',
        appendPrefix: 'S+:',
        value: value,
      );

      final rebuilt = StringBuffer();
      for (var i = 0; i < chunks.length; i++) {
        final cmd = chunks[i];
        final expectedPrefix = i == 0 ? 'S:' : 'S+:';
        expect(cmd.startsWith(expectedPrefix), isTrue);
        final payload = cmd.substring(expectedPrefix.length);
        expect(utf8.encode(payload).length <= kBleChunkBytes, isTrue);
        rebuilt.write(payload);
      }

      expect(rebuilt.toString(), value);
    });

    test('validates SSID and password byte limits', () {
      expect(validateSsid(''), isNotNull);
      expect(validateSsid('A' * 32), isNull);
      expect(validateSsid('A' * 33), isNotNull);

      expect(validatePassword(''), isNull);
      expect(validatePassword('p' * 63), isNull);
      expect(validatePassword('p' * 64), isNotNull);

      expect(
        () => buildProvisioningSequence(ssid: '', password: 'pass'),
        throwsArgumentError,
      );
    });
  });
}
