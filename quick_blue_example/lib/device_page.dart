import 'package:flutter/material.dart';
import 'package:quick_blue/quick_blue.dart';
import 'package:quick_blue_example/components/service_display.dart';

class DevicePage extends StatefulWidget {
  final String deviceId;
  final String name;

  DevicePage(this.deviceId, this.name);

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  BlueConnectionState _connectionState = BlueConnectionState.disconnected;
  bool _discoverServices = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    QuickBlue.setConnectionHandler(_handleConnectionChange);
  }

  void _handleConnectionChange(String deviceId, BlueConnectionState state) {
    if (deviceId == widget.deviceId) {
      setState(() {
        _connectionState = state;
        if (state == BlueConnectionState.disconnected) {
          _discoverServices = false;
        }
      });
    }
  }

  void _toggleConnection() {
    if (_connectionState == BlueConnectionState.connected) {
      QuickBlue.disconnect(widget.deviceId);
    } else {
      QuickBlue.connect(widget.deviceId);
    }
  }

  Color _getConnectionColor(BlueConnectionState state) {
    if (state == BlueConnectionState.connected) {
      return Colors.green;
    } else if (state == BlueConnectionState.connecting) {
      return Colors.orange;
    } else if (state == BlueConnectionState.disconnecting) {
      return Colors.red.shade300;
    } else {
      return Colors.grey;
    }
  }

  IconData _getConnectionIcon(BlueConnectionState state) {
    if (state == BlueConnectionState.connected) {
      return Icons.bluetooth_connected;
    } else if (state == BlueConnectionState.connecting) {
      return Icons.bluetooth_searching;
    } else if (state == BlueConnectionState.disconnecting) {
      return Icons.bluetooth_disabled;
    } else {
      return Icons.bluetooth;
    }
  }

  String _getConnectionText(BlueConnectionState state) {
    if (state == BlueConnectionState.connected) {
      return 'Connected';
    } else if (state == BlueConnectionState.connecting) {
      return 'Connecting...';
    } else if (state == BlueConnectionState.disconnecting) {
      return 'Disconnecting...';
    } else {
      return 'Disconnected';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name.isNotEmpty ? widget.name : 'Unknown Device'),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            _buildDeviceInfoCard(),
            _buildConnectionCard(),
            if (_connectionState == BlueConnectionState.connected) ...[
              _buildActionsCard(),
              if (_discoverServices) _buildServicesCard(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceInfoCard() {
    return Card(
      margin: EdgeInsets.symmetric(vertical: 8, horizontal: 0),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: Colors.blue.shade900,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    Icons.bluetooth,
                    color: Colors.blue,
                    size: 32,
                  ),
                ),
                SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Device ID',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.grey,
                            ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        widget.deviceId,
                        style: Theme.of(context).textTheme.bodyMedium,
                        overflow: TextOverflow.ellipsis,
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

  Widget _buildConnectionCard() {
    return Card(
      margin: EdgeInsets.symmetric(vertical: 8, horizontal: 0),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Connection Status',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  _getConnectionIcon(_connectionState),
                  color: _getConnectionColor(_connectionState),
                  size: 32,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _getConnectionText(_connectionState),
                        style: TextStyle(
                          color: _getConnectionColor(_connectionState),
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      if (_connectionState == BlueConnectionState.connecting)
                        Text(
                          'Establishing connection...',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _toggleConnection,
                icon: Icon(
                  _connectionState == BlueConnectionState.connected
                      ? Icons.bluetooth_disabled
                      : Icons.bluetooth_connected,
                ),
                label: Text(
                  _connectionState == BlueConnectionState.connected
                      ? 'Disconnect'
                      : 'Connect',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      _connectionState == BlueConnectionState.connected
                          ? Colors.red
                          : Colors.green,
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionsCard() {
    return Card(
      margin: EdgeInsets.symmetric(vertical: 8, horizontal: 0),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Device Actions',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                if (!_discoverServices)
                  ActionChip(
                    avatar: Icon(Icons.search, size: 18),
                    label: Text('Discover Services'),
                    onPressed: () {
                      setState(() => _discoverServices = true);
                      QuickBlue.discoverServices(widget.deviceId);
                    },
                  ),
                ActionChip(
                  avatar: Icon(Icons.data_usage, size: 18),
                  label: Text('Request MTU'),
                  onPressed: () => _showMtuDialog(),
                ),
                ActionChip(
                  avatar: Icon(Icons.signal_cellular_alt, size: 18),
                  label: Text('Read RSSI'),
                  onPressed: () => QuickBlue.readRssi(widget.deviceId),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildServicesCard() {
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
                  'Services',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                IconButton(
                  icon: Icon(Icons.close, size: 20),
                  onPressed: () => setState(() => _discoverServices = false),
                  tooltip: 'Close',
                ),
              ],
            ),
          ),
          Divider(height: 1),
          // Service display
          Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: ServiceDisplay(widget.deviceId),
          ),
        ],
      ),
    );
  }

  void _showMtuDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Request MTU'),
        content: Text('Requesting MTU for device ${widget.deviceId}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              QuickBlue.requestMtu(widget.deviceId, 512);
              Navigator.pop(context);
            },
            child: Text('Request 512'),
          ),
        ],
      ),
    );
  }
}
