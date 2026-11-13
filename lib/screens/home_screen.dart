import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ble/commands.dart';
import '../ble/constants.dart';
import '../ble/epd_client.dart';
import '../ble/status.dart';
import 'wifi_setup_screen.dart';

enum RemoteTab { letters, pairs }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.client});

  final EpdClient client;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _addressController = TextEditingController();

  final Set<String> _selectedLetters = <String>{};
  final Map<String, String?> _pairDigits = {
    for (final letter in kPresetLetters) letter: null,
  };

  RemoteTab _editorTab = RemoteTab.letters;
  bool _addressDirty = false;
  bool _lettersDirty = false;
  bool _pairsDirty = false;
  bool _userPickedTab = false;

  EpdClient get _client => widget.client;

  @override
  void initState() {
    super.initState();
    _syncFromClient();
    _client.addListener(_onClientChanged);
  }

  @override
  void dispose() {
    _client.removeListener(_onClientChanged);
    _addressController.dispose();
    super.dispose();
  }

  void _onClientChanged() {
    _syncFromClient();
    if (mounted) setState(() {});
  }

  void _syncFromClient() {
    if (!_addressDirty &&
        _client.savedIp != null &&
        _client.savedIp!.isNotEmpty &&
        _addressController.text != _client.savedIp) {
      _addressController.text = _client.savedIp!;
    }

    final status = _client.status;
    if (!_lettersDirty) {
      if (status.mode == EpdMode.letter && status.letter != null) {
        final letter = lettersOnly(status.letter!);
        if (kPresetLetters.contains(letter)) {
          _selectedLetters
            ..clear()
            ..add(letter);
        }
      } else if (status.mode == EpdMode.group &&
          status.group != null &&
          !status.isStandby) {
        final synced = <String>{
          for (final ch in status.group!.toUpperCase().split(''))
            if (kPresetLetters.contains(ch)) ch,
        };
        if (synced.isNotEmpty) {
          _selectedLetters
            ..clear()
            ..addAll(synced);
        }
      }
    }

    if (!_pairsDirty && status.pairs.isNotEmpty) {
      for (final letter in kPresetLetters) {
        _pairDigits[letter] = null;
      }
      for (final pair in status.pairs) {
        if (kPresetLetters.contains(pair.letter)) {
          _pairDigits[pair.letter] = pair.digit;
        }
      }
    }

    if (!_userPickedTab && status.mode != null && !status.isStandby) {
      final targetTab =
          status.mode == EpdMode.pairs ? RemoteTab.pairs : RemoteTab.letters;
      if (_editorTab != targetTab) {
        _editorTab = targetTab;
      }
    }
  }

  List<String> get _sortedSelectedLetters =>
      normalizeLettersSelection(_selectedLetters);

  List<LetterDigitPair> get _selectedPairs => presetPairsFromMap(_pairDigits);

  bool get _canSend {
    if (!_client.isConnected || _client.updating) return false;
    return switch (_editorTab) {
      RemoteTab.letters => isValidLettersSelection(_selectedLetters),
      RemoteTab.pairs => isValidPairs(_selectedPairs),
    };
  }

  String get _sendButtonLabel {
    return switch (_editorTab) {
      RemoteTab.letters => switch (_sortedSelectedLetters.length) {
          0 => 'Select Letters to Send',
          1 => 'Send Single (${_sortedSelectedLetters.first})',
          _ => 'Send Multiple (${_sortedSelectedLetters.join()})',
        },
      RemoteTab.pairs => _selectedPairs.isEmpty
          ? 'Select Pair Numbers to Send'
          : 'Send Pairs (${_selectedPairs.map((p) => '${p.letter}${p.digit}').join(', ')})',
    };
  }

  void _toggleLetter(String letter) {
    setState(() {
      _lettersDirty = true;
      if (_selectedLetters.contains(letter)) {
        _selectedLetters.remove(letter);
      } else if (_selectedLetters.length >= kGroupMaxLen) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Up to $kGroupMaxLen letters can be selected at once.'),
            duration: Duration(seconds: 2),
          ),
        );
      } else {
        _selectedLetters.add(letter);
      }
    });
  }

  void _togglePairDigit(String letter, String digit) {
    setState(() {
      _pairsDirty = true;
      if (_pairDigits[letter] == digit) {
        _pairDigits[letter] = null;
      } else {
        _pairDigits[letter] = digit;
      }
    });
  }

  Future<void> _send() async {
    try {
      switch (_editorTab) {
        case RemoteTab.letters:
          await _client.sendLettersSelection(_selectedLetters);
          _lettersDirty = false;
        case RemoteTab.pairs:
          await _client.sendPairs(_selectedPairs);
          _pairsDirty = false;
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
    }
  }

  Future<void> _sendStandby() async {
    try {
      await _client.sendStandby();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
    }
  }

  Future<void> _resend(SentCommand item) async {
    _scaffoldKey.currentState?.closeEndDrawer();
    _applyCommand(item.command);
    try {
      await _client.sendCommand(item.command);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
    }
  }

  void _applyCommand(String command) {
    final sent = SentCommand(command: command, sentAt: DateTime.now());
    if (sent.isStandby) return;

    final kind = sent.mode;
    if (kind == null) return;
    setState(() {
      _userPickedTab = true;
      switch (kind) {
        case EpdMode.letter:
        case EpdMode.group:
          _editorTab = RemoteTab.letters;
          final letters = sent.payload.toUpperCase().split('');
          _selectedLetters
            ..clear()
            ..addAll(letters.where(kPresetLetters.contains));
          _lettersDirty = true;
        case EpdMode.pairs:
          _editorTab = RemoteTab.pairs;
          for (final letter in kPresetLetters) {
            _pairDigits[letter] = null;
          }
          for (final pair in pairsFromCommand(command)) {
            if (kPresetLetters.contains(pair.letter)) {
              _pairDigits[pair.letter] = pair.digit;
            }
          }
          _pairsDirty = true;
      }
    });
  }

  Future<void> _openWifiSetup() async {
    await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (context) => WifiSetupScreen(client: _client),
      ),
    );
    if (!mounted) return;
    if (_client.savedIp != null && _client.savedIp!.isNotEmpty) {
      _addressDirty = false;
      _addressController.text = _client.savedIp!;
      setState(() {});
    }
  }

  Future<void> _connectOverWifi() async {
    FocusScope.of(context).unfocus();
    final input = _addressController.text.trim().isEmpty
        ? _client.preferredTarget
        : _addressController.text;
    await _client.connectToAddress(input);
  }

  Future<void> _copyUrl(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied $url')),
    );
  }

  Future<void> _openBrowserUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open $url')),
      );
    }
  }

  Future<void> _confirmAndResetBoardWifi() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset Board Wi-Fi?'),
        content: const Text(
          'This clears the saved Wi-Fi credentials on the EPD-C6 and reboots it into Bluetooth Setup ("BT Setup") mode.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset to BT Setup'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _client.resetDeviceWifi();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Board is rebooting into BT Setup mode.'),
      ),
    );
  }

  void _showWifiOptionsSheet() {
    final url = _client.webConsoleUrl;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (url != null) ...[
                ListTile(
                  leading: const Icon(Icons.copy),
                  title: const Text('Copy Board Web URL'),
                  subtitle: Text(url),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _copyUrl(url);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.open_in_new),
                  title: const Text('Open Board Web Console'),
                  subtitle: Text('${_client.mDnsConsoleUrl} or $url'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _openBrowserUrl(url);
                  },
                ),
              ],
              ListTile(
                leading: const Icon(Icons.bluetooth_searching),
                title: const Text('Set Up Wi-Fi via Bluetooth'),
                subtitle: const Text('Provision a new 2.4 GHz network'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _openWifiSetup();
                },
              ),
              ListTile(
                leading: const Icon(Icons.link_off),
                title: const Text('Disconnect Remote'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _client.disconnect();
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.restart_alt,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  'Reset Board Wi-Fi (BT Setup)',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                subtitle: const Text('Clears Wi-Fi on board and re-enables BLE'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _confirmAndResetBoardWifi();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _historyDrawer(EpdClient client) {
    final canResend = client.isConnected && !client.updating;
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'History',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                client.history.isEmpty
                    ? 'No messages yet'
                    : '${client.history.length} messages',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: client.history.isEmpty
                  ? const Center(child: Text('Send a message to see it here.'))
                  : ListView.separated(
                      itemCount: client.history.length,
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final item = client.history[index];
                        return ListTile(
                          title: Text(item.numberedLabel(index + 1)),
                          trailing: IconButton(
                            tooltip: 'Send again',
                            onPressed: canResend ? () => _resend(item) : null,
                            icon: const Icon(Icons.replay),
                          ),
                          onTap: canResend ? () => _resend(item) : null,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final client = _client;
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: const Text('EPD-C6'),
        actions: [
          if (client.isConnected)
            IconButton(
              tooltip: 'Refresh status',
              onPressed: client.updating ? null : client.refreshStatus,
              icon: const Icon(Icons.refresh),
            ),
          Builder(
            builder: (context) {
              return IconButton(
                tooltip: 'History',
                onPressed: () => Scaffold.of(context).openEndDrawer(),
                icon: Badge(
                  isLabelVisible: client.history.isNotEmpty,
                  label: Text('${client.history.length}'),
                  child: const Icon(Icons.history),
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(child: _BatteryChip(battery: client.status.battery)),
          ),
        ],
      ),
      endDrawer: _historyDrawer(client),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: client.isConnected
                ? _connectedBody(client)
                : _disconnectedBody(client),
          ),
        ),
      ),
    );
  }

  Widget _disconnectedBody(EpdClient client) {
    final connecting = client.connection == EpdConnectionState.connecting;
    final previewUrl = client.webConsoleUrl;

    return ListView(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.wifi,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Connect over Wi-Fi',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if (client.savedSsid != null)
                            Text(
                              'Last network: ${client.savedSsid}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _addressController,
                  enabled: !connecting,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Board IP or Hostname',
                    hintText: '192.168.1.42 or epd-c6.local',
                    helperText:
                        'Shown in the top-left corner of the e-paper display.',
                    prefixIcon: Icon(Icons.lan_outlined),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) {
                    _addressDirty = true;
                    setState(() {});
                  },
                  onSubmitted: (_) {
                    if (!connecting) _connectOverWifi();
                  },
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: connecting ? null : _connectOverWifi,
                  icon: connecting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.settings_remote),
                  label: Text(connecting ? 'Connecting…' : 'Connect Remote'),
                ),
                if (previewUrl != null) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: () => _openBrowserUrl(previewUrl),
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: Text('Open $previewUrl'),
                      ),
                      TextButton.icon(
                        onPressed: () => _copyUrl(previewUrl),
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text('Copy URL'),
                      ),
                    ],
                  ),
                ],
                if (client.errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    client.errorMessage!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.bluetooth,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Configure Board Wi-Fi',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Is the e-paper showing "BT Setup"? Use Bluetooth to connect the EPD-C6 to a 2.4 GHz Wi-Fi network.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  onPressed: _openWifiSetup,
                  icon: const Icon(Icons.bluetooth_searching),
                  label: const Text('Set Up Wi-Fi via Bluetooth'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _connectedBody(EpdClient client) {
    final isStandby = client.status.isStandby;
    final onDevice = client.status.onDeviceSummary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusHeader(
          client: client,
          onCopyUrl: client.webConsoleUrl == null
              ? null
              : () => _copyUrl(client.webConsoleUrl!),
          onOpenOptions: _showWifiOptionsSheet,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: SegmentedButton<RemoteTab>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: RemoteTab.letters,
                    icon: Icon(Icons.sort_by_alpha, size: 18),
                    label: Text('Letters'),
                  ),
                  ButtonSegment(
                    value: RemoteTab.pairs,
                    icon: Icon(Icons.format_list_numbered, size: 18),
                    label: Text('Pairs'),
                  ),
                ],
                selected: {_editorTab},
                onSelectionChanged: (selection) {
                  setState(() {
                    _userPickedTab = true;
                    _editorTab = selection.first;
                  });
                },
              ),
            ),
            const SizedBox(width: 10),
            isStandby
                ? FilledButton.icon(
                    onPressed: client.updating ? null : _sendStandby,
                    icon: const Icon(Icons.pause_circle_filled, size: 18),
                    label: const Text(kStandbyWord),
                  )
                : FilledButton.tonalIcon(
                    onPressed: client.updating ? null : _sendStandby,
                    icon: const Icon(Icons.pause_circle_outline, size: 18),
                    label: const Text(kStandbyWord),
                  ),
          ],
        ),
        if (onDevice.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'On device: $onDevice',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (client.updating) ...[
          const SizedBox(height: 10),
          const LinearProgressIndicator(),
          const SizedBox(height: 6),
          Text(
            'Updating… e-paper refresh is slow.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (client.errorMessage != null) ...[
          const SizedBox(height: 8),
          Text(
            client.errorMessage!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 12),
        Expanded(
          child: switch (_editorTab) {
            RemoteTab.letters => _lettersEditor(),
            RemoteTab.pairs => _pairsEditor(),
          },
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _canSend ? _send : null,
          child: Text(_sendButtonLabel),
        ),
      ],
    );
  }

  Widget _lettersEditor() {
    final sorted = _sortedSelectedLetters;
    final subtitle = switch (sorted.length) {
      0 => 'Tap 1 letter for Single, or up to $kGroupMaxLen letters for Multiple.',
      1 => 'Single letter: ${sorted.first}',
      _ => 'Multiple (${sorted.length}/$kGroupMaxLen): ${sorted.join(' ')}',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                subtitle,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            TextButton(
              onPressed: _selectedLetters.isEmpty
                  ? null
                  : () => setState(() {
                        _lettersDirty = true;
                        _selectedLetters.clear();
                      }),
              child: const Text('Clear'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: SingleChildScrollView(
            child: LayoutBuilder(
              builder: (context, constraints) {
                const spacing = 12.0;
                final columns = constraints.maxWidth >= 460 ? 4 : 3;
                final tileWidth =
                    (constraints.maxWidth - spacing * (columns - 1)) / columns;

                return Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: [
                    for (final letter in kPresetLetters)
                      _LetterToggleButton(
                        letter: letter,
                        selected: _selectedLetters.contains(letter),
                        width: tileWidth,
                        onTap: () => _toggleLetter(letter),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _pairsEditor() {
    final activePairs = _selectedPairs;
    final summary = activePairs.isEmpty
        ? 'Tap a number next to each letter (A–G) to set its order.'
        : 'Selected: ${activePairs.map((p) => '${p.letter}${p.digit}').join(', ')}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                summary,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            TextButton(
              onPressed: activePairs.isEmpty
                  ? null
                  : () => setState(() {
                        _pairsDirty = true;
                        for (final letter in kPresetLetters) {
                          _pairDigits[letter] = null;
                        }
                      }),
              child: const Text('Clear all'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Expanded(
          child: ListView.separated(
            itemCount: kPresetLetters.length,
            separatorBuilder: (context, index) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final letter = kPresetLetters[index];
              final selectedDigit = _pairDigits[letter];
              return _PresetPairRow(
                letter: letter,
                selectedDigit: selectedDigit,
                onDigitTap: (digit) => _togglePairDigit(letter, digit),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _LetterToggleButton extends StatelessWidget {
  const _LetterToggleButton({
    required this.letter,
    required this.selected,
    required this.width,
    required this.onTap,
  });

  final String letter;
  final bool selected;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      height: 76,
      child: Material(
        color: selected ? scheme.primary : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Center(
            child: Text(
              letter,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: selected ? scheme.onPrimary : scheme.onSurface,
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PresetPairRow extends StatelessWidget {
  const _PresetPairRow({
    required this.letter,
    required this.selectedDigit,
    required this.onDigitTap,
  });

  final String letter;
  final String? selectedDigit;
  final ValueChanged<String> onDigitTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasDigit = selectedDigit != null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: hasDigit
            ? scheme.primaryContainer.withValues(alpha: 0.45)
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: hasDigit ? scheme.primary : scheme.outlineVariant,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: hasDigit ? scheme.primary : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              hasDigit ? '$letter$selectedDigit' : letter,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: hasDigit ? scheme.onPrimary : scheme.onSurface,
                  ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Row(
              children: [
                for (final digit in kPairOrderDigits)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: _DigitOrderButton(
                        digit: digit,
                        selected: selectedDigit == digit,
                        onTap: () => onDigitTap(digit),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DigitOrderButton extends StatelessWidget {
  const _DigitOrderButton({
    required this.digit,
    required this.selected,
    required this.onTap,
  });

  final String digit;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 38,
      child: Material(
        color: selected ? scheme.primary : scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Center(
            child: Text(
              digit,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight:
                        selected ? FontWeight.bold : FontWeight.normal,
                    color: selected ? scheme.onPrimary : scheme.onSurface,
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusHeader extends StatelessWidget {
  const _StatusHeader({
    required this.client,
    required this.onCopyUrl,
    required this.onOpenOptions,
  });

  final EpdClient client;
  final VoidCallback? onCopyUrl;
  final VoidCallback onOpenOptions;

  @override
  Widget build(BuildContext context) {
    final ssid = client.status.ssid ?? client.savedSsid;
    final address = client.status.ip ?? client.activeTarget ?? '';
    final label = ssid != null && ssid.isNotEmpty
        ? '$ssid ($address)'
        : 'Wi-Fi ($address)';

    return Row(
      children: [
        Icon(
          Icons.wifi,
          size: 20,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        if (onCopyUrl != null)
          IconButton(
            tooltip: 'Copy board web URL',
            onPressed: onCopyUrl,
            icon: const Icon(Icons.copy, size: 18),
            visualDensity: VisualDensity.compact,
          ),
        TextButton.icon(
          onPressed: onOpenOptions,
          icon: const Icon(Icons.tune, size: 18),
          label: const Text('Wi-Fi'),
        ),
      ],
    );
  }
}

class _BatteryChip extends StatelessWidget {
  const _BatteryChip({required this.battery});

  final int? battery;

  @override
  Widget build(BuildContext context) {
    final label = battery == null ? '—%' : '$battery%';
    return Chip(
      avatar: Icon(
        battery == null
            ? Icons.battery_unknown
            : battery! > 20
                ? Icons.battery_std
                : Icons.battery_alert,
        size: 18,
      ),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}
