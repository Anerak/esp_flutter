import 'dart:async';

import 'package:flutter/material.dart';

import 'ble/epd_client.dart';
import 'screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final client = EpdClient();
  unawaited(client.loadSavedTargetAndConnect());
  runApp(EpdApp(client: client));
}

class EpdApp extends StatefulWidget {
  const EpdApp({super.key, required this.client});

  final EpdClient client;

  @override
  State<EpdApp> createState() => _EpdAppState();
}

class _EpdAppState extends State<EpdApp> {
  @override
  void dispose() {
    widget.client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EPD-C6',
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
      ),
      home: HomeScreen(client: widget.client),
    );
  }
}
