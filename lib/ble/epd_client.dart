import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'commands.dart';
import 'constants.dart';
import 'local_http_client.dart';
import 'status.dart';

enum EpdConnectionState { disconnected, connecting, connected }

class EpdClient extends ChangeNotifier {
  EpdClient({
    http.Client? httpClient,
    this.isHttpsWebOverride,
  })  : _http = httpClient ?? createLocalHttpClient(),
        _ownsHttpClient = httpClient == null;

  static const _prefIpKey = 'epd_saved_ip';
  static const _prefHostKey = 'epd_saved_host';
  static const _prefSsidKey = 'epd_saved_ssid';

  final http.Client _http;
  final bool _ownsHttpClient;
  final bool? isHttpsWebOverride;

  EpdConnectionState connection = EpdConnectionState.disconnected;
  EpdStatus status = EpdStatus.empty;
  bool updating = false;
  bool mixedContentBlocked = false;
  String? errorMessage;
  String? activeTarget;
  String? savedIp;
  String? savedHost;
  String? savedSsid;
  final List<SentCommand> history = [];

  Timer? _renderPollTimer;
  int _renderPollRemaining = 0;
  bool _disposed = false;

  bool get isConnected =>
      connection == EpdConnectionState.connected && activeTarget != null;

  bool get isHttpsWeb =>
      isHttpsWebOverride ?? (kIsWeb && Uri.base.scheme == 'https');

  String get preferredTarget {
    if (savedIp != null && savedIp!.isNotEmpty) return savedIp!;
    if (savedHost != null && savedHost!.isNotEmpty) return savedHost!;
    return kDefaultHost;
  }

  String? get webConsoleUrl {
    final ip = status.ip;
    if (ip != null && ip.isNotEmpty) return 'http://$ip/';
    if (activeTarget != null && activeTarget!.isNotEmpty) {
      return 'http://$activeTarget/';
    }
    if (savedIp != null && savedIp!.isNotEmpty) return 'http://$savedIp/';
    return null;
  }

  String get mDnsConsoleUrl {
    final host = status.host ?? savedHost ?? kDefaultHost;
    return 'http://$host/';
  }

  static String normalizeTarget(String raw) {
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    trimmed = trimmed.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
    final slashIdx = trimmed.indexOf('/');
    if (slashIdx >= 0) {
      trimmed = trimmed.substring(0, slashIdx);
    }
    return trimmed.trim();
  }

  Future<void> loadSavedTargetAndConnect() async {
    final prefs = await SharedPreferences.getInstance();
    savedIp = _nonEmpty(prefs.getString(_prefIpKey));
    savedHost = _nonEmpty(prefs.getString(_prefHostKey)) ?? kDefaultHost;
    savedSsid = _nonEmpty(prefs.getString(_prefSsidKey));
    _safeNotify();

    final target = savedIp;
    if (target == null || target.isEmpty) return;

    await connectToAddress(target, silentErrorOnStartup: true);
  }

  Future<void> saveProvisionedDevice({
    required String ip,
    String? host,
    String? ssid,
  }) async {
    final normalizedIp = normalizeTarget(ip);
    final normalizedHost = normalizeTarget(host ?? '') .isEmpty
        ? kDefaultHost
        : normalizeTarget(host!);
    savedIp = normalizedIp.isEmpty ? savedIp : normalizedIp;
    savedHost = normalizedHost;
    if (ssid != null && ssid.isNotEmpty) {
      savedSsid = ssid;
    }

    final prefs = await SharedPreferences.getInstance();
    if (savedIp != null && savedIp!.isNotEmpty) {
      await prefs.setString(_prefIpKey, savedIp!);
    }
    await prefs.setString(_prefHostKey, savedHost!);
    if (savedSsid != null && savedSsid!.isNotEmpty) {
      await prefs.setString(_prefSsidKey, savedSsid!);
    }
    _safeNotify();
  }

  Future<bool> connectToAddress(
    String rawAddress, {
    bool silentErrorOnStartup = false,
  }) async {
    final target = normalizeTarget(rawAddress);
    if (target.isEmpty) {
      errorMessage =
          'Enter the board IP address (for example 192.168.1.42) or $kDefaultHost.';
      _safeNotify();
      return false;
    }

    _renderPollTimer?.cancel();
    connection = EpdConnectionState.connecting;
    mixedContentBlocked = false;
    errorMessage = null;
    _safeNotify();

    try {
      final connectTimeout =
          (kIsWeb || isHttpsWeb) ? kWebConnectTimeout : kHttpTimeout;
      final fetched = await _fetchStatusFrom(target, timeout: connectTimeout);
      activeTarget = target;
      status = fetched;
      updating = fetched.rendering;
      connection = EpdConnectionState.connected;

      await saveProvisionedDevice(
        ip: fetched.ip ?? target,
        host: fetched.host ?? kDefaultHost,
        ssid: fetched.ssid,
      );

      if (fetched.rendering) {
        _startRenderPolling();
      }
      _safeNotify();
      return true;
    } catch (error) {
      connection = EpdConnectionState.disconnected;
      activeTarget = null;
      updating = false;
      if (isHttpsWeb) {
        mixedContentBlocked = true;
        savedIp ??= target;
      }
      if (!silentErrorOnStartup) {
        errorMessage = isHttpsWeb
            ? 'Could not reach http://$target/. In Chrome or Edge, allow "Local network access" when prompted (or in Site Settings), or open http://$target/ directly in a new tab.'
            : 'Could not reach EPD-C6 at http://$target/. Make sure you are on the same Wi-Fi network.';
      }
      _safeNotify();
      return false;
    }
  }

  void disconnect() {
    _renderPollTimer?.cancel();
    connection = EpdConnectionState.disconnected;
    activeTarget = null;
    updating = false;
    errorMessage = null;
    _safeNotify();
  }

  Future<void> refreshStatus() async {
    final target = activeTarget;
    if (target == null) return;
    try {
      final fetched = await _fetchStatusFrom(target);
      status = fetched;
      updating = fetched.rendering;
      errorMessage = null;
      if (!fetched.rendering) {
        _renderPollTimer?.cancel();
      }
      _safeNotify();
    } catch (_) {
      errorMessage = 'Lost Wi-Fi connection to http://$target/.';
      _safeNotify();
    }
  }

  Future<void> sendLettersSelection(Iterable<String> selected) {
    return sendCommand(lettersSelectionCommand(selected));
  }

  Future<void> sendStandby() {
    return sendCommand(standbyCommand());
  }

  Future<void> sendLetter(String input) {
    if (!isValidLetter(input)) {
      throw ArgumentError('Single mode needs one A–Z letter');
    }
    return sendCommand(letterCommand(input));
  }

  Future<void> sendGroup(String input) {
    if (!isValidGroup(input)) {
      throw ArgumentError(
        'Multiple mode needs $kGroupMinLen–$kGroupMaxLen letters',
      );
    }
    return sendCommand(groupCommand(input));
  }

  Future<void> sendPairs(Iterable<LetterDigitPair> pairs) {
    if (!isValidPairs(pairs)) {
      throw ArgumentError('List mode needs 1–$kPairsMax letter+digit pairs');
    }
    return sendCommand(pairsCommand(pairs));
  }

  Future<void> sendCommand(String command) async {
    final target = activeTarget;
    if (!isConnected || target == null) {
      throw StateError('Not connected to EPD-C6 over Wi-Fi');
    }
    if (command.length > kCmdMaxLen) {
      throw ArgumentError('Command longer than $kCmdMaxLen characters');
    }
    if (updating) return;

    updating = true;
    errorMessage = null;
    _safeNotify();

    try {
      final uri = Uri.http(target, '/api/display');
      final response = await _http
          .post(
            uri,
            headers: const {'Content-Type': 'text/plain; charset=utf-8'},
            body: command,
          )
          .timeout(kHttpTimeout);

      if (response.statusCode != 200) {
        final message = _extractApiError(response) ??
            'Display request failed (HTTP ${response.statusCode})';
        updating = false;
        errorMessage = message;
        _safeNotify();
        throw StateError(message);
      }

      _remember(command);

      try {
        final latest = await _fetchStatusFrom(target);
        status = latest;
        updating = latest.rendering;
        if (latest.rendering) {
          _startRenderPolling();
        }
      } catch (_) {
        updating = false;
      }
      _safeNotify();
    } catch (error) {
      updating = false;
      if (error is StateError) {
        rethrow;
      }
      final friendly = 'Failed to send command to http://$target/.';
      errorMessage = friendly;
      _safeNotify();
      throw StateError(friendly);
    }
  }

  Future<void> resetDeviceWifi() async {
    final target = activeTarget;
    if (target == null) {
      throw StateError('Not connected to EPD-C6 over Wi-Fi');
    }

    _renderPollTimer?.cancel();
    updating = true;
    errorMessage = null;
    _safeNotify();

    try {
      final uri = Uri.http(target, '/api/wifi/reset');
      await _http.post(uri).timeout(kHttpTimeout);
    } catch (_) {
      // Board may reboot immediately while closing the socket after /api/wifi/reset.
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefIpKey);

    savedIp = null;
    activeTarget = null;
    updating = false;
    status = EpdStatus.empty;
    connection = EpdConnectionState.disconnected;
    _safeNotify();
  }

  Future<EpdStatus> _fetchStatusFrom(
    String target, {
    Duration timeout = kHttpTimeout,
  }) async {
    final uri = Uri.http(target, '/api/status');
    final response = await _http.get(uri).timeout(timeout);
    if (response.statusCode != 200) {
      throw StateError('HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Unexpected /api/status JSON');
    }
    return EpdStatus.fromJson(decoded, raw: response.body);
  }

  void _startRenderPolling() {
    _renderPollTimer?.cancel();
    _renderPollRemaining = 8;
    _renderPollTimer = Timer.periodic(kRenderPollInterval, (timer) async {
      final target = activeTarget;
      if (!isConnected || target == null || _renderPollRemaining <= 0) {
        timer.cancel();
        if (updating) {
          updating = false;
          _safeNotify();
        }
        return;
      }
      _renderPollRemaining--;
      try {
        final latest = await _fetchStatusFrom(target);
        status = latest;
        updating = latest.rendering;
        if (!latest.rendering) {
          timer.cancel();
        }
        _safeNotify();
      } catch (_) {
        timer.cancel();
        updating = false;
        _safeNotify();
      }
    });
  }

  String? _extractApiError(http.Response response) {
    if (response.body.isEmpty) return null;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['error'] != null) {
        return decoded['error'].toString();
      }
    } catch (_) {}
    return null;
  }

  void _remember(String command) {
    if (command == 'B?' || command == 'W?' || !command.contains(':')) return;
    history.removeWhere((item) => item.command == command);
    history.insert(0, SentCommand(command: command, sentAt: DateTime.now()));
    if (history.length > kHistoryMax) {
      history.removeRange(kHistoryMax, history.length);
    }
  }

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  void _safeNotify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _renderPollTimer?.cancel();
    if (_ownsHttpClient) {
      _http.close();
    }
    super.dispose();
  }
}
