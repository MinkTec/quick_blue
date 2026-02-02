import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:quick_blue/quick_blue.dart';
import 'package:quick_blue_example/background_wake_storage.dart';

/// Key for storing background wake events in SharedPreferences.
///
/// We reuse the shared storage utilities in background_wake_storage.dart.

/// Page for testing the unified Background Presence API
class BackgroundPresencePage extends StatefulWidget {
  const BackgroundPresencePage({super.key});

  @override
  State<BackgroundPresencePage> createState() => _BackgroundPresencePageState();
}

class _BackgroundPresencePageState extends State<BackgroundPresencePage> {
  BackgroundPresenceCapabilities? _capabilities;
  List<DeviceAssociationResult> _observedDevices = [];
  List<PersistedWakeEvent> _wakeEvents = [];
  final Queue<BleEventMessage> _liveEvents = Queue();
  final int _maxLiveEvents = 50;
  bool _isLoading = true;
  String? _error;
  bool _callbackRegistered = false;

  final TextEditingController _namePatternController =
      TextEditingController(text: '.*'); // Match all devices

  @override
  void initState() {
    super.initState();
    _initialize();
    QuickBlue.eventStream.listen(_handleBleEvent);
  }

  @override
  void dispose() {
    _namePatternController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Get capabilities
      final capabilities = await QuickBlue.getBackgroundPresenceCapabilities();

      // Load persisted events
      final events = await loadBackgroundWakeEvents();

      // Get observed devices
      final devices = await QuickBlue.getBackgroundObservedDevices();

      setState(() {
        _capabilities = capabilities;
        _wakeEvents = events;
        _observedDevices = devices;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _handleBleEvent(BleEventMessage event) {
    setState(() {
      _liveEvents.addFirst(event);
      if (_liveEvents.length > _maxLiveEvents) {
        _liveEvents.removeLast();
      }
    });

    // Refresh observed devices on presence events
    if (event.event == BleEvent.deviceAppeared ||
        event.event == BleEvent.deviceDisappeared) {
      _loadWakeEvents();
    }
  }

  Future<void> _loadWakeEvents() async {
    final events = await loadBackgroundWakeEvents();
    if (mounted) {
      setState(() => _wakeEvents = events);
    }
  }

  Future<void> _clearWakeEvents() async {
    await clearBackgroundWakeEvents();
    if (mounted) {
      setState(() => _wakeEvents = []);
    }
  }

  Future<void> _registerCallback() async {
    try {
      await QuickBlue.initializeBackgroundWakeCallback(onBackgroundWake);
      setState(() => _callbackRegistered = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Background callback registered')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error registering callback: $e')),
      );
    }
  }

  Future<void> _associateDevice() async {
    final pattern = _namePatternController.text;
    if (pattern.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a name pattern')),
      );
      return;
    }

    try {
      final result = await QuickBlue.associateDevice(
        namePattern: pattern,
        singleDevice: true,
      );

      if (result.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Device associated: ${result.deviceName ?? result.deviceId ?? "Unknown"}',
            ),
          ),
        );
        // Start observation for the associated device
        if (result.deviceId != null) {
          await QuickBlue.startBackgroundPresenceObservation(
            result.deviceId!,
            associationId: result.associationId,
          );
        }
        await _refreshObservedDevices();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Association failed: ${result.errorMessage}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _refreshObservedDevices() async {
    try {
      final devices = await QuickBlue.getBackgroundObservedDevices();
      setState(() => _observedDevices = devices);
    } catch (e) {
      print('Error refreshing devices: $e');
    }
  }

  Future<void> _removeDevice(DeviceAssociationResult device) async {
    try {
      await QuickBlue.removeBackgroundObservation(
        device.deviceId ?? '',
        associationId: device.associationId,
      );
      await _refreshObservedDevices();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Device removed')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error removing device: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Background Presence'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _initialize,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildErrorState()
              : _buildContent(),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 64, color: Colors.red),
          const SizedBox(height: 16),
          Text('Error: $_error'),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _initialize,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return SingleChildScrollView(
      child: Column(
        children: [
          _buildCapabilitiesCard(),
          _buildCallbackCard(),
          if (_capabilities?.requiresAssociation == true)
            _buildAssociationCard(),
          _buildObservedDevicesCard(),
          _buildWakeEventsCard(),
          _buildLiveEventsCard(),
        ],
      ),
    );
  }

  Widget _buildCapabilitiesCard() {
    final caps = _capabilities;
    if (caps == null) return const SizedBox.shrink();

    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Platform Capabilities',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            _buildCapabilityRow(
              'Supported',
              caps.isSupported,
              Icons.check_circle,
              Icons.cancel,
            ),
            _buildCapabilityRow(
              'Requires Association',
              caps.requiresAssociation,
              Icons.link,
              Icons.link_off,
            ),
            _buildCapabilityRow(
              'Presence Observation',
              caps.presenceObservationAvailable,
              Icons.visibility,
              Icons.visibility_off,
            ),
            const SizedBox(height: 8),
            Text(
              'Platform: ${Platform.isIOS ? "iOS" : Platform.isAndroid ? "Android" : "Other"}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (caps.minimumOsVersion != null)
              Text(
                'Min OS: ${caps.minimumOsVersion}, Current: ${caps.currentOsVersion ?? "Unknown"}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCapabilityRow(
    String label,
    bool value,
    IconData trueIcon,
    IconData falseIcon,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            value ? trueIcon : falseIcon,
            color: value ? Colors.green : Colors.grey,
            size: 20,
          ),
          const SizedBox(width: 8),
          Text(label),
          const Spacer(),
          Text(
            value ? 'Yes' : 'No',
            style: TextStyle(
              color: value ? Colors.green : Colors.grey,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCallbackCard() {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Background Callback',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              _callbackRegistered
                  ? 'Callback is registered. Background events will be logged.'
                  : 'Register a callback to receive background wake events.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _callbackRegistered ? null : _registerCallback,
                icon: Icon(
                    _callbackRegistered ? Icons.check : Icons.notifications),
                label: Text(_callbackRegistered ? 'Registered' : 'Register'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _callbackRegistered ? Colors.green : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAssociationCard() {
    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Device Association (Android CDM)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Associate a device to enable background presence detection.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _namePatternController,
              decoration: const InputDecoration(
                labelText: 'Device Name Pattern (Regex)',
                hintText: 'e.g., MyDevice.* or .*',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _associateDevice,
                icon: const Icon(Icons.add_link),
                label: const Text('Associate Device'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildObservedDevicesCard() {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Observed Devices',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed: _refreshObservedDevices,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_observedDevices.isEmpty)
              Text(
                Platform.isIOS
                    ? 'Connect to a device to enable presence observation.'
                    : 'No associated devices. Use the association button above.',
                style: Theme.of(context).textTheme.bodySmall,
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _observedDevices.length,
                itemBuilder: (context, index) {
                  final device = _observedDevices[index];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.bluetooth),
                    title: Text(device.deviceName ?? 'Unknown Device'),
                    subtitle: Text(
                      device.deviceId ?? 'ID: ${device.associationId}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: () => _removeDevice(device),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildWakeEventsCard() {
    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Persisted Wake Events',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 20),
                      onPressed: _loadWakeEvents,
                    ),
                    if (_wakeEvents.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.delete, size: 20),
                        onPressed: _clearWakeEvents,
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'These events were logged when the app was woken in background.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (_wakeEvents.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'No background wake events recorded yet.\n\n'
                    'To test:\n'
                    '1. Associate/connect a device\n'
                    '2. Kill the app\n'
                    '3. Move device in/out of range\n'
                    '4. Reopen app to see events',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _wakeEvents.length.clamp(0, 20),
                itemBuilder: (context, index) {
                  final event = _wakeEvents[index];
                  return _buildWakeEventTile(event);
                },
              ),
            if (_wakeEvents.length > 20)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  '... and ${_wakeEvents.length - 20} more events',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildWakeEventTile(PersistedWakeEvent event) {
    final isAppeared = event.wakeType == 'deviceAppeared';
    final color = isAppeared ? Colors.green : Colors.orange;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: color, width: 3)),
        color: color.withValues(alpha: 0.1),
      ),
      child: ListTile(
        dense: true,
        leading: Icon(
          isAppeared ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
          color: color,
        ),
        title: Text(
          event.wakeType,
          style: TextStyle(fontWeight: FontWeight.bold, color: color),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(event.deviceName ?? event.deviceId),
            Text(
              'Platform: ${event.platform}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              _formatAbsoluteTime(event.timestamp),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveEventsCard() {
    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Live BLE Events',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (_liveEvents.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.delete, size: 20),
                    onPressed: () => setState(() => _liveEvents.clear()),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_liveEvents.isEmpty)
              Text(
                'No live events yet.',
                style: Theme.of(context).textTheme.bodySmall,
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _liveEvents.length.clamp(0, 10),
                itemBuilder: (context, index) {
                  final event = _liveEvents.elementAt(index);
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(_getEventIcon(event.event)),
                    title: Text(event.event.name),
                    subtitle: Text(
                      event.data.toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  IconData _getEventIcon(BleEvent event) {
    switch (event) {
      case BleEvent.deviceAppeared:
        return Icons.bluetooth_connected;
      case BleEvent.deviceDisappeared:
        return Icons.bluetooth_disabled;
      case BleEvent.connected:
        return Icons.link;
      case BleEvent.disconnected:
        return Icons.link_off;
      case BleEvent.stateRestored:
        return Icons.restore;
      default:
        return Icons.info;
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
}

/// Background wake callback that gets called when app is woken.
/// This is a top-level function exported for use in main.dart.
@pragma('vm:entry-point')
void onBackgroundWake(BackgroundWakeEvent event) {
  saveBackgroundWakeEvent(event);
}
