import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:quick_blue/quick_blue.dart';
import 'package:quick_blue_example/background_presence_page.dart';
import 'package:quick_blue_example/background_wake_storage.dart';
import 'package:quick_blue_example/scan.dart';
import 'package:quick_blue_example/state_restoration_test_page.dart';

Future<void> main() async {
  Logger.root.onRecord.listen((r) {
    print(r.loggerName + ' ' + r.level.name + ' ' + r.message);
  });
  WidgetsFlutterBinding.ensureInitialized();

  // Register the unified background wake callback (works on both iOS and Android)
  if (Platform.isIOS || Platform.isAndroid) {
    await QuickBlue.initializeBackgroundWakeCallback(onBackgroundWake);
  }

  runApp(MyApp());
}

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      themeMode: ThemeMode.dark,
      home: MyAppHome(),
    );
  }
}

class MyAppHome extends StatefulWidget {
  @override
  _MyAppHomeState createState() => _MyAppHomeState();
}

class _MyAppHomeState extends State<MyAppHome> {
  bool _isScanning = false;
  bool _isBluetoothAvailable = false;

  @override
  void initState() {
    super.initState();
    if (kDebugMode) {
      QuickBlue.setLogger(Logger('quick_blue_example'));
    }
    _checkBluetoothAvailability();
  }

  Future<void> _checkBluetoothAvailability() async {
    final available = await QuickBlue.isBluetoothAvailable();
    setState(() => _isBluetoothAvailable = available);
  }

  void _toggleScan() {
    if (_isScanning) {
      QuickBlue.stopScan();
    } else {
      QuickBlue.startScan(serviceId: "6e400001-c352-11e5-953d-0002a5d5c51b");
    }
    setState(() => _isScanning = !_isScanning);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Quick Blue Example'),
          actions: [
            // Background Presence - works on iOS and Android
            if (Platform.isIOS || Platform.isAndroid)
              IconButton(
                icon: Icon(Icons.sensors),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const BackgroundPresencePage(),
                  ),
                ),
                tooltip: 'Background Presence',
              ),
            // iOS-only State Restoration test page (legacy)
            if (Platform.isIOS)
              IconButton(
                icon: Icon(Icons.restore),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => StateRestorationTestPage(),
                  ),
                ),
                tooltip: 'State Restoration Test',
              ),
          ],
        ),
        body: SingleChildScrollView(
          child: Column(
            children: [
              _buildStatusCard(),
              _buildScanControlCard(),
              if (_isScanning) _buildScanResultsCard(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 0, vertical: 8),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _isBluetoothAvailable
                      ? Icons.bluetooth
                      : Icons.bluetooth_disabled,
                  color: _isBluetoothAvailable ? Colors.blue : Colors.grey,
                  size: 32,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Bluetooth Status',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        _isBluetoothAvailable ? 'Available' : 'Not Available',
                        style: TextStyle(
                          color:
                              _isBluetoothAvailable ? Colors.blue : Colors.grey,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScanControlCard() {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 0),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Device Scan',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _toggleScan,
                    icon: Icon(_isScanning ? Icons.stop : Icons.search),
                    label: Text(_isScanning ? 'Stop Scan' : 'Start Scan'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isScanning ? Colors.red : Colors.blue,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
              ],
            ),
            if (_isScanning) ...[
              SizedBox(height: 12),
              Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                    ),
                  ),
                  SizedBox(width: 8),
                  Text(
                    'Scanning for BLE devices...',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildScanResultsCard() {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 0, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Discovered Devices',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  'Tap to connect',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Divider(height: 1),
          ScanResultList(),
        ],
      ),
    );
  }
}
