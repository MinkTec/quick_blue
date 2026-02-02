import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:quick_blue/quick_blue.dart';
import 'package:quick_blue_platform_interface/ble_events.dart';
import 'package:quick_blue_platform_interface/quick_blue_platform_interface.dart';
import 'package:quick_blue_example/background_wake_storage.dart';

class StateRestorationTestPage extends StatefulWidget {
  @override
  _StateRestorationTestPageState createState() =>
      _StateRestorationTestPageState();
}

class _StateRestorationTestPageState extends State<StateRestorationTestPage> {
  final Queue<BleEventMessage> _eventLog = Queue();
  final int _maxLogSize = 100;
  bool _isConnected = false;
  String? _lastRestoredDeviceId;
  DateTime? _lastRestorationTime;
  int _restorationCount = 0;
  List<PersistedWakeEvent> _backgroundWakeups = [];

  @override
  void initState() {
    super.initState();
    QuickBlue.eventStream.listen(_handleBleEvent);
    _loadBackgroundWakeups();

    // Also set up connection handler to track connection state
    QuickBlue.setConnectionHandler((deviceId, state) {
      setState(() {
        _isConnected = state == BlueConnectionState.connected;
        if (state == BlueConnectionState.connected) {
          _lastRestoredDeviceId = deviceId;
        }
      });
    });

    // Add initial message to log
    setState(() {
      _eventLog.addFirst(BleEventMessage(
        event: BleEvent.unkown,
        data: GenericEventData(
            data: {'message': 'Test page opened - listening for events...'}),
      ));
    });
  }

  void _handleBleEvent(BleEventMessage event) {
    setState(() {
      _eventLog.addFirst(event);
      if (_eventLog.length > _maxLogSize) {
        _eventLog.removeLast();
      }

      if (event.event == BleEvent.stateRestored) {
        _restorationCount++;
        _lastRestorationTime = DateTime.now();
        final data = event.data as StateRestoredEvent;
        if (data.restoredPeripherals.isNotEmpty) {
          _lastRestoredDeviceId = data.restoredPeripherals.first;
        }
      } else if (event.event == BleEvent.pendingConnectionRestored) {
        final data = event.data as PendingConnectionRestoredEvent;
        _lastRestoredDeviceId = data.deviceId;
        _lastRestorationTime = DateTime.now();
      } else if (event.event == BleEvent.connected) {
        _isConnected = true;
      } else if (event.event == BleEvent.disconnected) {
        _isConnected = false;
      }
    });
    if (event.event == BleEvent.stateRestored ||
        event.event == BleEvent.pendingConnectionRestored) {
      _loadBackgroundWakeups();
    }
  }

  Future<void> _loadBackgroundWakeups() async {
    final wakeups = await loadBackgroundWakeEvents();
    if (!mounted) return;
    setState(() => _backgroundWakeups = wakeups);
  }

  Future<void> _clearBackgroundWakeups() async {
    await clearBackgroundWakeEvents();
    if (!mounted) return;
    setState(() => _backgroundWakeups = []);
  }

  Color _getEventColor(BleEvent event) {
    switch (event) {
      case BleEvent.stateRestored:
        return Colors.green;
      case BleEvent.pendingConnectionRestored:
        return Colors.blue;
      case BleEvent.connected:
        return Colors.green.shade700;
      case BleEvent.disconnected:
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  IconData _getEventIcon(BleEvent event) {
    switch (event) {
      case BleEvent.stateRestored:
        return Icons.restore;
      case BleEvent.pendingConnectionRestored:
        return Icons.refresh;
      case BleEvent.connected:
        return Icons.bluetooth_connected;
      case BleEvent.disconnected:
        return Icons.bluetooth_disabled;
      default:
        return Icons.info;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('iOS State Restoration Test'),
        actions: [
          IconButton(
            icon: Icon(Icons.delete),
            onPressed: () => setState(() => _eventLog.clear()),
            tooltip: 'Clear log',
          ),
        ],
      ),
      body: Column(
        children: [
          _buildStatusCard(),
          _buildBackgroundWakeupsCard(),
          _buildInstructionsCard(),
          Expanded(
            child: _buildEventLog(),
          ),
        ],
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
                  _isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                  color: _isConnected ? Colors.green : Colors.grey,
                  size: 32,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Connection Status',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        _isConnected ? 'Connected' : 'Disconnected',
                        style: TextStyle(
                          color: _isConnected ? Colors.green : Colors.grey,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Divider(height: 24),
            Row(
              children: [
                Icon(
                  Icons.restore,
                  color: _restorationCount > 0 ? Colors.green : Colors.grey,
                  size: 32,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'State Restorations',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        '$_restorationCount ${_restorationCount == 1 ? "time" : "times"}',
                        style: TextStyle(
                          color: _restorationCount > 0
                              ? Colors.green
                              : Colors.grey,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (_lastRestorationTime != null)
                        Text(
                          'Last: ${_formatTime(_lastRestorationTime!)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (_lastRestoredDeviceId != null) ...[
              SizedBox(height: 8),
              Text(
                'Last Device: $_lastRestoredDeviceId',
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInstructionsCard() {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 0),
      color: Colors.blue.shade900,
      child: ExpansionTile(
        title: Text(
          'How to Test State Restoration',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        iconColor: Colors.white,
        collapsedIconColor: Colors.white,
        children: [
          Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildInstructionStep(
                  '1',
                  'Connect to a BLE device using the main app',
                ),
                _buildInstructionStep(
                  '2',
                  'Move the device out of range or kill the app (swipe up in app switcher)',
                ),
                _buildInstructionStep(
                  '3',
                  'Bring the device back in range',
                ),
                _buildInstructionStep(
                  '4',
                  'iOS should automatically relaunch the app in background',
                ),
                _buildInstructionStep(
                  '5',
                  'Reopen this page to see the "stateRestored" event',
                ),
                SizedBox(height: 12),
                Text(
                  'Note: This requires UIBackgroundModes with bluetooth-central in Info.plist',
                  style: TextStyle(
                    color: Colors.yellow,
                    fontStyle: FontStyle.italic,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackgroundWakeupsCard() {
    final wakeupCount = _backgroundWakeups.length;

    return Card(
      margin: EdgeInsets.symmetric(horizontal: 0, vertical: 8),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Background Wakeups',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (wakeupCount > 0)
                  TextButton(
                    onPressed: _clearBackgroundWakeups,
                    child: Text('Clear'),
                  ),
              ],
            ),
            SizedBox(height: 8),
            Text(
              wakeupCount == 0
                  ? 'No background wakeups recorded yet.'
                  : 'Recorded $wakeupCount wakeups',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (wakeupCount > 0) ...[
              SizedBox(height: 12),
              for (final wakeup in _backgroundWakeups.take(5))
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    _formatWakeupLine(wakeup),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInstructionStep(String number, String text) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                number,
                style: TextStyle(
                  color: Colors.blue.shade900,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEventLog() {
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
                  'Event Log',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  '${_eventLog.length} events',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Divider(height: 1),
          Expanded(
            child: _eventLog.isEmpty
                ? Center(
                    child: Text(
                      'No events yet\nConnect to a device to see events',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    itemCount: _eventLog.length,
                    itemBuilder: (context, index) {
                      final event = _eventLog.elementAt(index);
                      return _buildEventTile(event, index);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildEventTile(BleEventMessage event, int index) {
    final color = _getEventColor(event.event);
    final isHighlight = event.event == BleEvent.stateRestored ||
        event.event == BleEvent.pendingConnectionRestored;

    return Container(
      decoration: BoxDecoration(
        color: isHighlight ? color.withOpacity(0.1) : null,
        border: Border(
          left: BorderSide(
            color: color,
            width: isHighlight ? 4 : 2,
          ),
        ),
      ),
      child: ListTile(
        dense: true,
        leading: Icon(
          _getEventIcon(event.event),
          color: color,
          size: isHighlight ? 28 : 24,
        ),
        title: Text(
          event.event.name,
          style: TextStyle(
            fontWeight: isHighlight ? FontWeight.bold : FontWeight.normal,
            color: isHighlight ? color : null,
          ),
        ),
        subtitle: Text(
          event.data.toString(),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12),
        ),
        trailing: Text(
          '#$index',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inSeconds < 60) {
      return '${diff.inSeconds}s ago';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else {
      return '${diff.inHours}h ago';
    }
  }

  String _formatAbsoluteTime(DateTime time) {
    final local = time.toLocal();
    final year = local.year.toString().padLeft(4, '0');
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    final second = local.second.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute:$second';
  }

  String _formatWakeupLine(PersistedWakeEvent event) {
    final name = event.deviceName ?? event.deviceId;
    return '${_formatAbsoluteTime(event.timestamp)} - ${event.wakeType} - ${event.platform} - $name';
  }
}
