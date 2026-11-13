import 'dart:convert';

import 'constants.dart';

String? validateSsid(String ssid) {
  final byteLen = utf8.encode(ssid).length;
  if (byteLen == 0) {
    return 'Enter a 2.4 GHz Wi-Fi network name (SSID)';
  }
  if (byteLen > kMaxSsidBytes) {
    return 'SSID must be at most $kMaxSsidBytes UTF-8 bytes (currently $byteLen)';
  }
  return null;
}

String? validatePassword(String password) {
  final byteLen = utf8.encode(password).length;
  if (byteLen > kMaxPassBytes) {
    return 'Password must be at most $kMaxPassBytes UTF-8 bytes (currently $byteLen)';
  }
  return null;
}

/// Builds BLE write commands split safely on UTF-8 codepoint boundaries so
/// multi-byte characters are never torn across [chunkBytes]-byte chunks.
List<String> buildChunkedCommands({
  required String prefix,
  required String appendPrefix,
  required String value,
  int chunkBytes = kBleChunkBytes,
}) {
  final bytes = utf8.encode(value);
  if (bytes.isEmpty) {
    return [prefix];
  }

  final commands = <String>[];
  var currentChunk = StringBuffer();
  var currentBytes = 0;
  var isFirst = true;

  for (final rune in value.runes) {
    final ch = String.fromCharCode(rune);
    final chBytes = utf8.encode(ch).length;
    if (currentBytes + chBytes > chunkBytes && currentBytes > 0) {
      commands.add(
        '${isFirst ? prefix : appendPrefix}${currentChunk.toString()}',
      );
      isFirst = false;
      currentChunk = StringBuffer();
      currentBytes = 0;
    }
    currentChunk.write(ch);
    currentBytes += chBytes;
  }

  if (currentBytes > 0) {
    commands.add(
      '${isFirst ? prefix : appendPrefix}${currentChunk.toString()}',
    );
  }

  return commands;
}

/// Builds the full sequence of BLE commands (`S:`/`S+:`, `K:`/`K+:`, `W:1`)
/// required to stage Wi-Fi credentials and start connecting on the EPD-C6.
List<String> buildProvisioningSequence({
  required String ssid,
  required String password,
  int chunkBytes = kBleChunkBytes,
}) {
  final ssidError = validateSsid(ssid);
  if (ssidError != null) {
    throw ArgumentError(ssidError);
  }
  final passError = validatePassword(password);
  if (passError != null) {
    throw ArgumentError(passError);
  }

  return [
    ...buildChunkedCommands(
      prefix: 'S:',
      appendPrefix: 'S+:',
      value: ssid,
      chunkBytes: chunkBytes,
    ),
    ...buildChunkedCommands(
      prefix: 'K:',
      appendPrefix: 'K+:',
      value: password,
      chunkBytes: chunkBytes,
    ),
    'W:1',
  ];
}
