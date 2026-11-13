import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ble/ble_provisioner.dart';
import '../ble/epd_client.dart';
import '../ble/prov_status.dart';
import '../ble/provisioning.dart';

class WifiSetupScreen extends StatefulWidget {
  const WifiSetupScreen({
    super.key,
    required this.client,
    this.provisioner,
  });

  final EpdClient client;
  final BleProvisioner? provisioner;

  @override
  State<WifiSetupScreen> createState() => _WifiSetupScreenState();
}

class _WifiSetupScreenState extends State<WifiSetupScreen> {
  late final BleProvisioner _provisioner;
  late final bool _ownsProvisioner;

  final _ssidController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _ssidDirty = false;
  bool _obscurePassword = true;
  bool _openingRemote = false;

  @override
  void initState() {
    super.initState();
    _ownsProvisioner = widget.provisioner == null;
    _provisioner = widget.provisioner ??
        BleProvisioner(
          onProvisioned: (status) => widget.client.saveProvisionedDevice(
            ip: status.ip,
            host: status.host,
            ssid: status.ssid,
          ),
        );
    if (widget.client.savedSsid != null &&
        widget.client.savedSsid!.isNotEmpty) {
      _ssidController.text = widget.client.savedSsid!;
    }
    _provisioner.addListener(_onProvisionerChanged);
  }

  @override
  void dispose() {
    _provisioner.removeListener(_onProvisionerChanged);
    if (_ownsProvisioner) {
      _provisioner.dispose();
    }
    _ssidController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _onProvisionerChanged() {
    final remoteSsid = _provisioner.status.ssid;
    if (!_ssidDirty &&
        remoteSsid.isNotEmpty &&
        _ssidController.text != remoteSsid) {
      _ssidController.value = TextEditingValue(
        text: remoteSsid,
        selection: TextSelection.collapsed(offset: remoteSsid.length),
      );
    }
    if (mounted) setState(() {});
  }

  bool get _canSubmitCredentials {
    if (!_provisioner.isBleConnected || _provisioner.submitting) return false;
    return validateSsid(_ssidController.text) == null &&
        validatePassword(_passwordController.text) == null;
  }

  Future<void> _submitCredentials() async {
    FocusScope.of(context).unfocus();
    try {
      await _provisioner.provisionWifi(
        ssid: _ssidController.text,
        password: _passwordController.text,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
    }
  }

  Future<void> _clearSavedWifi() async {
    try {
      await _provisioner.clearCredentials();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cleared saved Wi-Fi credentials on board.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
    }
  }

  Future<void> _copyText(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied $value')),
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

  Future<void> _openInAppRemote(String ip) async {
    setState(() => _openingRemote = true);
    final connected = await widget.client.connectToAddress(ip);
    if (!mounted) return;
    setState(() => _openingRemote = false);
    if (connected) {
      Navigator.of(context).pop(ip);
    } else if (widget.client.errorMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.client.errorMessage!)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final battery = _provisioner.status.battery;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wi-Fi Setup (Bluetooth)'),
        actions: [
          if (battery != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Chip(
                  avatar: Icon(
                    battery > 20 ? Icons.battery_std : Icons.battery_alert,
                    size: 18,
                  ),
                  label: Text('$battery%'),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_provisioner.provisionSucceeded ||
                  _provisioner.link == BleLinkState.provisioned)
                _buildSuccessCard(context)
              else if (_provisioner.isBleConnected)
                _buildCredentialsForm(context)
              else
                _buildScanCard(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScanCard(BuildContext context) {
    final busy = _provisioner.link == BleLinkState.scanning ||
        _provisioner.link == BleLinkState.connecting;
    final buttonLabel = switch (_provisioner.link) {
      BleLinkState.scanning =>
        kIsWeb ? 'Choose EPD-C6 in browser…' : 'Scanning for EPD-C6…',
      BleLinkState.connecting => 'Connecting…',
      _ => 'Scan & Connect Bluetooth',
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.bluetooth_searching,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Step 1: Connect to EPD-C6',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              '1. Check that the top-left of the e-paper screen shows "BT Setup".\n'
              '2. If the board is already on Wi-Fi, hold the physical BOOT button for 3 seconds until it resets to "BT Setup".',
            ),
            if (kIsWeb) ...[
              const SizedBox(height: 10),
              Text(
                'Web tip: Use Chrome or Edge on a computer or phone with Bluetooth enabled.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: busy ? null : _provisioner.scanAndConnect,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.bluetooth),
              label: Text(buttonLabel),
            ),
            if (_provisioner.errorMessage != null) ...[
              const SizedBox(height: 14),
              Text(
                _provisioner.errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCredentialsForm(BuildContext context) {
    final status = _provisioner.status;
    final ssidError = _ssidController.text.isEmpty
        ? null
        : validateSsid(_ssidController.text);
    final passError = validatePassword(_passwordController.text);
    final isConnectingWifi =
        _provisioner.submitting || status.state == BleProvState.connecting;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.bluetooth_connected,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Step 2: Enter 2.4 GHz Wi-Fi',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        status.state.label,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: isConnectingWifi ? null : _provisioner.disconnect,
                  child: const Text('Disconnect'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _ssidController,
              enabled: !isConnectingWifi,
              decoration: InputDecoration(
                labelText: 'Wi-Fi Network Name (SSID)',
                hintText: 'MyHomeWiFi',
                helperText: 'Must be a 2.4 GHz Wi-Fi network (not 5 GHz-only).',
                errorText: ssidError,
                prefixIcon: const Icon(Icons.wifi),
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) {
                _ssidDirty = true;
                setState(() {});
              },
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              enabled: !isConnectingWifi,
              obscureText: _obscurePassword,
              decoration: InputDecoration(
                labelText: 'Password',
                hintText: 'Leave empty for open network',
                errorText: passError,
                prefixIcon: const Icon(Icons.lock_outline),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (_canSubmitCredentials) _submitCredentials();
              },
            ),
            if (isConnectingWifi) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(
                'Connecting EPD-C6 to Wi-Fi… (takes up to 15 seconds)',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (_provisioner.errorMessage != null) ...[
              const SizedBox(height: 14),
              Text(
                _provisioner.errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _canSubmitCredentials ? _submitCredentials : null,
              icon: const Icon(Icons.wifi_find),
              label: const Text('Connect Wi-Fi'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: isConnectingWifi ? null : _clearSavedWifi,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Clear Saved Wi-Fi on Board'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuccessCard(BuildContext context) {
    final status = _provisioner.status;
    final ipUrl = status.webUrl ?? 'http://${status.ip}/';
    final hostUrl = status.hostUrl;
    final isHttpsWeb = widget.client.isHttpsWeb;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.check_circle,
                  color: Theme.of(context).colorScheme.primary,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'EPD-C6 Connected to Wi-Fi!',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (status.ssid.isNotEmpty)
                        Text(
                          'Network: ${status.ssid}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Board Web URL',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    ipUrl,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    'Hostname: $hostUrl',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              isHttpsWeb
                  ? 'Bluetooth on the board turns off automatically after setup. '
                      'If Chrome or Edge asks to connect to devices on your local network, click Allow.'
                  : 'Bluetooth on the board turns off automatically after setup. '
                      'Use the URL above on any browser on the same Wi-Fi network, or control the board directly below.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            if (status.ip.isNotEmpty) ...[
              FilledButton.icon(
                onPressed:
                    _openingRemote ? null : () => _openInAppRemote(status.ip),
                icon: _openingRemote
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.settings_remote),
                label: const Text('Open Remote in App'),
              ),
              const SizedBox(height: 10),
            ],
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => _copyText(ipUrl),
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy URL'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _openBrowserUrl(ipUrl),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open in Browser'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
