import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ble/commands.dart';
import '../ble/constants.dart';
import '../ble/epd_client.dart';
import '../ble/status.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.client});

  final EpdClient client;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _letterController = TextEditingController();
  final _groupController = TextEditingController();
  final _pairs = <_PairDraft>[ _PairDraft() ];

  EpdMode _editorMode = EpdMode.letter;
  bool _letterDirty = false;
  bool _groupDirty = false;
  bool _userPickedMode = false;

  EpdClient get _client => widget.client;

  @override
  void initState() {
    super.initState();
    _client.addListener(_onClientChanged);
  }

  @override
  void dispose() {
    _client.removeListener(_onClientChanged);
    _letterController.dispose();
    _groupController.dispose();
    for (final row in _pairs) {
      row.dispose();
    }
    super.dispose();
  }

  void _onClientChanged() {
    final status = _client.status;
    if (status.letter != null) {
      if (!_letterDirty || _letterController.text == status.letter) {
        _letterDirty = false;
        if (_letterController.text != status.letter) {
          _letterController.value = TextEditingValue(
            text: status.letter!,
            selection: TextSelection.collapsed(offset: status.letter!.length),
          );
        }
      }
    }
    if (status.group != null) {
      if (!_groupDirty || _groupController.text == status.group) {
        _groupDirty = false;
        if (_groupController.text != status.group) {
          _groupController.value = TextEditingValue(
            text: status.group!,
            selection: TextSelection.collapsed(offset: status.group!.length),
          );
        }
      }
    }
    if (!_userPickedMode && status.mode != null && _editorMode != status.mode) {
      _editorMode = status.mode!;
    }
    if (mounted) setState(() {});
  }

  bool get _canSend {
    if (!_client.isConnected || _client.updating) return false;
    return switch (_editorMode) {
      EpdMode.letter => isValidLetter(_letterController.text),
      EpdMode.group => isValidGroup(_groupController.text),
      EpdMode.pairs => isValidPairs(_currentPairs()),
    };
  }

  List<LetterDigitPair> _currentPairs() => [
    for (final row in _pairs)
      LetterDigitPair(letter: row.letter, digit: row.digit),
  ];

  Future<void> _send() async {
    try {
      switch (_editorMode) {
        case EpdMode.letter:
          await _client.sendLetter(_letterController.text);
        case EpdMode.group:
          await _client.sendGroup(_groupController.text);
        case EpdMode.pairs:
          await _client.sendPairs(_currentPairs());
      }
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
    final kind = SentCommand(command: command, sentAt: DateTime.now()).mode;
    if (kind == null) return;
    setState(() {
      _userPickedMode = true;
      _editorMode = kind;
      switch (kind) {
        case EpdMode.letter:
          final letter = command.substring(2);
          _letterController.text = letter;
          _letterDirty = true;
        case EpdMode.group:
          final group = command.substring(2);
          _groupController.text = group;
          _groupDirty = true;
        case EpdMode.pairs:
          for (final row in _pairs) {
            row.dispose();
          }
          _pairs
            ..clear()
            ..addAll([
              for (final pair in pairsFromCommand(command))
                _PairDraft(letter: pair.letter, digit: pair.digit),
            ]);
          if (_pairs.isEmpty) _pairs.add(_PairDraft());
      }
    });
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
              child: Text('History', style: Theme.of(context).textTheme.titleLarge),
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
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: client.isConnected ? _connectedBody(client) : _disconnectedBody(client),
      ),
    );
  }

  Widget _disconnectedBody(EpdClient client) {
    final busy = client.connection == EpdConnectionState.scanning ||
        client.connection == EpdConnectionState.connecting;
    final disconnected = client.errorMessage?.contains('Disconnected') ?? false;
    final label = switch (client.connection) {
      EpdConnectionState.scanning => 'Scanning…',
      EpdConnectionState.connecting => 'Connecting…',
      _ => disconnected ? 'Reconnect' : 'Scan & connect',
    };

    return ListView(
      children: [
        const Text('Connect to the e-paper board over Bluetooth.'),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: busy ? null : client.scanAndConnect,
          icon: busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.bluetooth_searching),
          label: Text(label),
        ),
        if (client.errorMessage != null) ...[
          const SizedBox(height: 12),
          Text(
            client.errorMessage!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }

  Widget _connectedBody(EpdClient client) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusHeader(client: client),
        const SizedBox(height: 16),
        SegmentedButton<EpdMode>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: EpdMode.letter, label: Text('Single')),
            ButtonSegment(value: EpdMode.group, label: Text('Multiple')),
            ButtonSegment(value: EpdMode.pairs, label: Text('List')),
          ],
          selected: {_editorMode},
          onSelectionChanged: (selection) {
            setState(() {
              _userPickedMode = true;
              _editorMode = selection.first;
            });
          },
        ),
        if (client.status.mode != null) ...[
          const SizedBox(height: 8),
          Text(
            'On device: ${client.status.mode!.label}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (client.updating) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Text(
            'Updating… e-paper refresh is slow.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 16),
        Expanded(child: _editor()),
        FilledButton(
          onPressed: _canSend ? _send : null,
          child: const Text('Send'),
        ),
      ],
    );
  }

  Widget _editor() {
    return switch (_editorMode) {
      EpdMode.letter => _letterEditor(),
      EpdMode.group => _groupEditor(),
      EpdMode.pairs => _pairsEditor(),
    };
  }

  Widget _letterEditor() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _letterController,
          textCapitalization: TextCapitalization.characters,
          maxLength: 1,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z]')),
            _UpperCaseFormatter(),
          ],
          decoration: const InputDecoration(
            labelText: 'Letter',
            hintText: 'A–Z',
            border: OutlineInputBorder(),
            counterText: '',
          ),
          onChanged: (_) {
            _letterDirty = true;
            setState(() {});
          },
        ),
        const SizedBox(height: 8),
        Text(
          'Shows one large letter on the panel.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _groupEditor() {
    final letters = lettersOnly(_groupController.text);
    final hint = letters.length < kGroupMinLen
        ? 'Enter $kGroupMinLen–$kGroupMaxLen letters'
        : letters.length > kGroupMaxLen
            ? 'At most $kGroupMaxLen letters'
            : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _groupController,
          textCapitalization: TextCapitalization.characters,
          maxLength: kGroupMaxLen,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z]')),
            _UpperCaseFormatter(),
          ],
          decoration: InputDecoration(
            labelText: 'Letters',
            hintText: 'ABCDE',
            border: const OutlineInputBorder(),
            errorText: _groupController.text.isEmpty ? null : hint,
          ),
          onChanged: (_) {
            _groupDirty = true;
            setState(() {});
          },
        ),
      ],
    );
  }

  Widget _pairsEditor() {
    return Column(
      children: [
        Expanded(
          child: ListView.separated(
            itemCount: _pairs.length,
            separatorBuilder: (context, index) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final row = _pairs[index];
              return Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: row.letterController,
                      textCapitalization: TextCapitalization.characters,
                      maxLength: 1,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z]')),
                        _UpperCaseFormatter(),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Letter',
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                      onChanged: (value) {
                        row.letter = lettersOnly(value);
                        setState(() {});
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: row.digitController,
                      keyboardType: TextInputType.number,
                      maxLength: 1,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9]')),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Digit',
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                      onChanged: (value) {
                        row.digit = value;
                        setState(() {});
                      },
                    ),
                  ),
                  IconButton(
                    onPressed: _pairs.length <= 1
                        ? null
                        : () {
                            setState(() {
                              row.dispose();
                              _pairs.removeAt(index);
                            });
                          },
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                ],
              );
            },
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _pairs.length >= kPairsMax
                ? null
                : () => setState(() => _pairs.add(_PairDraft())),
            icon: const Icon(Icons.add),
            label: Text('Add pair (${_pairs.length}/$kPairsMax)'),
          ),
        ),
      ],
    );
  }
}

class _PairDraft {
  _PairDraft({String letter = '', String digit = ''})
      : letter = letter,
        digit = digit,
        letterController = TextEditingController(text: letter),
        digitController = TextEditingController(text: digit);

  String letter;
  String digit;
  final TextEditingController letterController;
  final TextEditingController digitController;

  void dispose() {
    letterController.dispose();
    digitController.dispose();
  }
}

class _StatusHeader extends StatelessWidget {
  const _StatusHeader({required this.client});

  final EpdClient client;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.bluetooth_connected, size: 20),
        const SizedBox(width: 8),
        const Expanded(child: Text('Connected')),
        TextButton(
          onPressed: client.disconnect,
          child: const Text('Disconnect'),
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

class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return newValue.copyWith(text: newValue.text.toUpperCase());
  }
}
