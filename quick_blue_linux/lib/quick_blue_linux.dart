import 'dart:async';
import 'dart:typed_data';

import 'package:bluez/bluez.dart';
import 'package:collection/collection.dart';
import 'package:logging/logging.dart';
import 'package:quick_blue_platform_interface/ble_events.dart';
import 'package:quick_blue_platform_interface/quick_blue_platform_interface.dart';

class QuickBlueLinux extends QuickBluePlatform {
  static const _connectionTimeout = Duration(seconds: 5);
  static const _servicesResolvedTimeout = Duration(seconds: 4);

  bool isInitialized = false;

  final BlueZClient _client = BlueZClient();

  BlueZAdapter? _activeAdapter;
  String? _scanServiceId;

  final _connectionStates = <String, BlueConnectionState>{};
  final _deviceSubscriptions = <String, StreamSubscription<List<String>>>{};
  final _notifySubscriptions = <String, StreamSubscription<List<String>>>{};
  final _eventMessageController = StreamController<BleEventMessage>.broadcast();

  Future<void> _ensureInitialized() async {
    if (!isInitialized) {
      await _client.connect();

      _refreshActiveAdapter();

      _client.deviceAdded.listen(_onDeviceAdd);

      isInitialized = true;
    }
  }

  void _refreshActiveAdapter() {
    _activeAdapter =
        _client.adapters.firstWhereOrNull((adapter) => adapter.powered);
  }

  QuickLogger? _logger;

  @override
  void setLogger(QuickLogger logger) {
    _logger = logger;
  }

  void _log(String message, {Level logLevel = Level.INFO}) {
    _logger?.log(logLevel, message);
  }

  @override
  Future<bool> isBluetoothAvailable() async {
    await _ensureInitialized();
    _refreshActiveAdapter();
    _log('isBluetoothAvailable invoke success');

    return _activeAdapter != null;
  }

  @override
  void reinit() {}

  @override
  void startScan({String? serviceId}) async {
    await _ensureInitialized();
    _refreshActiveAdapter();
    final adapter = _activeAdapter;
    if (adapter == null) {
      _log('startScan failed: no powered Bluetooth adapter',
          logLevel: Level.WARNING);
      return;
    }

    _scanServiceId = serviceId;
    _log('startScan invoke success');

    try {
      await adapter.setDiscoveryFilter(
        transport: 'le',
        duplicateData: true,
      );
      await adapter.startDiscovery();
    } catch (e) {
      _log('scan was already running');
      if (!e.toString().contains("org.bluez.Error.InProgress")) {
        rethrow;
      }
    }
    _client.devices
        .where((d) => _matchesScanService(d, serviceId))
        .forEach(_onDeviceAdd);
  }

  @override
  void stopScan() async {
    await _ensureInitialized();
    final adapter = _activeAdapter;
    _log('stopScan invoke success');

    try {
      await adapter?.stopDiscovery();
      await adapter?.setDiscoveryFilter();
    } catch (e) {
      _log("no scan was running");
    } finally {
      _scanServiceId = null;
    }
  }

  BlueZDevice? _device(String id) =>
      _client.devices.firstWhereOrNull((e) => e.address == id);

  // FIXME Close
  final StreamController<dynamic> _scanResultController =
      StreamController.broadcast();

  @override
  Stream get scanResultStream => _scanResultController.stream;

  void _onDeviceAdd(BlueZDevice device) {
    _watchDevice(device);
    if (!_matchesScanService(device, _scanServiceId)) return;
    _emitScanResult(device);
  }

  void _emitScanResult(BlueZDevice device) {
    _scanResultController.add({
      'deviceId': device.address,
      'name': device.alias.isNotEmpty ? device.alias : device.name,
      'manufacturerDataHead': device.manufacturerDataHead,
      'rssi': device.rssi,
    });
  }

  bool _matchesScanService(BlueZDevice device, String? serviceId) {
    if (serviceId == null) return true;
    final normalizedServiceId = _normalizeUuid(serviceId);
    final advertised = device.uuids
        .map((uuid) => _normalizeUuid(uuid.toString()))
        .contains(normalizedServiceId);
    if (advertised) return true;

    return device.gattServices
        .map((service) => _normalizeUuid(service.uuid.toString()))
        .contains(normalizedServiceId);
  }

  String _normalizeUuid(String value) =>
      value.toLowerCase().replaceAll('-', '');

  void _watchDevice(BlueZDevice device) {
    final deviceId = device.address;
    if (_deviceSubscriptions.containsKey(deviceId)) return;
    _deviceSubscriptions[deviceId] =
        device.propertiesChanged.listen((properties) {
      if (properties.contains('Connected')) {
        if (device.connected) {
          _emitConnectionState(deviceId, BlueConnectionState.connected);
        } else {
          _cancelNotifySubscriptions(deviceId);
          _emitConnectionState(deviceId, BlueConnectionState.disconnected);
        }
      }

      if (_scanServiceId != null &&
          properties.any(_isScanRelevantProperty) &&
          _matchesScanService(device, _scanServiceId)) {
        _emitScanResult(device);
      }
    });
  }

  bool _isScanRelevantProperty(String property) =>
      property == 'UUIDs' ||
      property == 'RSSI' ||
      property == 'ManufacturerData' ||
      property == 'Name' ||
      property == 'Alias';

  void _emitConnectionState(String deviceId, BlueConnectionState state) {
    if (_connectionStates[deviceId] == state) return;
    _connectionStates[deviceId] = state;
    onConnectionChanged?.call(deviceId, state);
    _eventMessageController.add(
      (state == BlueConnectionState.connected
              ? BleEvent.connected
              : BleEvent.disconnected)
          .package({'type': state.value, 'deviceId': deviceId}),
    );
  }

  Future<bool> _waitForConnected(BlueZDevice device) async {
    if (device.connected) return true;
    try {
      await device.propertiesChanged
          .where((properties) => properties.contains('Connected'))
          .firstWhere((_) => device.connected)
          .timeout(_connectionTimeout);
    } on TimeoutException {
      return false;
    }
    return true;
  }

  Future<bool> _waitForServicesResolved(BlueZDevice device) async {
    if (device.servicesResolved) return true;
    try {
      await device.propertiesChanged
          .where((properties) => properties.contains('ServicesResolved'))
          .firstWhere((_) => device.servicesResolved)
          .timeout(_servicesResolvedTimeout);
    } on TimeoutException {
      return false;
    }
    return true;
  }

  @override
  Future<void> connect(String deviceId, {bool? auto}) async {
    await _ensureInitialized();
    final device = _device(deviceId);
    if (device == null) {
      _log('connect failed: unknown deviceId $deviceId',
          logLevel: Level.WARNING);
      _emitConnectionState(deviceId, BlueConnectionState.disconnected);
      return;
    }

    _watchDevice(device);

    try {
      try {
        await _activeAdapter?.stopDiscovery();
      } catch (_) {}

      if (!device.connected) {
        await device.connect().timeout(_connectionTimeout);
      }

      if (!await _waitForConnected(device)) {
        _log('connect timed out for $deviceId', logLevel: Level.WARNING);
        _emitConnectionState(deviceId, BlueConnectionState.disconnected);
        return;
      }

      final servicesResolved = await _waitForServicesResolved(device);
      if (!servicesResolved && device.gattServices.isEmpty) {
        _log('services were not resolved for $deviceId',
            logLevel: Level.WARNING);
        _emitConnectionState(deviceId, BlueConnectionState.disconnected);
        return;
      }

      _emitConnectionState(deviceId, BlueConnectionState.connected);
    } on BlueZAlreadyConnectedException {
      await _waitForServicesResolved(device);
      _emitConnectionState(deviceId, BlueConnectionState.connected);
    } catch (e) {
      _log('connect failed for $deviceId: $e', logLevel: Level.WARNING);
      _emitConnectionState(deviceId, BlueConnectionState.disconnected);
    }
  }

  @override
  Future<void> disconnect(String deviceId) async {
    await _ensureInitialized();
    _cancelNotifySubscriptions(deviceId);
    try {
      final device = _device(deviceId);
      if (device != null && device.connected) {
        await device.disconnect();
      }
    } finally {
      _emitConnectionState(deviceId, BlueConnectionState.disconnected);
    }
  }

  @override
  void discoverServices(String deviceId) async {
    await _ensureInitialized();
    if (onServiceDiscovered == null) return;
    final device = _device(deviceId);
    if (device == null) return;
    await _waitForServicesResolved(device);
    for (final service in device.gattServices) {
      final serviceId = service.uuid.toString();
      final characteristicIds = service.characteristics
          .map((characteristic) => characteristic.uuid.toString())
          .toList();
      onServiceDiscovered!(deviceId, serviceId, characteristicIds);
      _eventMessageController.add(BleEvent.serviceDiscovered.package({
        'type': BleEvent.serviceDiscovered.name,
        'deviceId': deviceId,
        'service': serviceId,
        'characteristics': characteristicIds,
      }));
    }
  }

  BlueZGattCharacteristic? _findService(
      String deviceId, String service, String characteristic) {
    return _device(deviceId)
        ?.gattServices
        .firstWhereOrNull((s) => s.uuid.toString() == service)
        ?.characteristics
        .firstWhereOrNull((char) => char.uuid.toString() == characteristic);
  }

  @override
  Future<void> setNotifiable(String deviceId, String service,
      String characteristic, BleInputProperty bleInputProperty) async {
    final char = _findService(deviceId, service, characteristic);
    if (char == null) {
      throw ArgumentError(
          'Unknown characteristic $service/$characteristic on $deviceId');
    }

    final key = _notifyKey(deviceId, service, characteristic);
    await _notifySubscriptions.remove(key)?.cancel();

    if (bleInputProperty == BleInputProperty.disabled) {
      if (char.notifying) {
        await char.stopNotify();
      }
      return;
    }

    _notifySubscriptions[key] = char.propertiesChanged.listen((properties) {
      if (!properties.contains('Value')) return;
      onValueChanged?.call(
        deviceId,
        characteristic,
        Uint8List.fromList(char.value),
      );
    });

    if (!char.notifying) {
      await char.startNotify();
    }
  }

  String _notifyKey(String deviceId, String service, String characteristic) =>
      '$deviceId|$service|$characteristic';

  void _cancelNotifySubscriptions(String deviceId) {
    final keys = _notifySubscriptions.keys
        .where((key) => key.startsWith('$deviceId|'))
        .toList();
    for (final key in keys) {
      _notifySubscriptions.remove(key)?.cancel();
    }
  }

  @override
  Future<void> readValue(
          String deviceId, String service, String characteristic) async =>
      onValueChanged?.call(
          deviceId,
          characteristic,
          Uint8List.fromList(
              await _findService(deviceId, service, characteristic)!
                  .readValue()));

  @override
  Future<void> writeValue(
          String deviceId,
          String service,
          String characteristic,
          Uint8List value,
          BleOutputProperty bleOutputProperty) async =>
      await _findService(deviceId, service, characteristic)!
          .writeValue(value, type: bleOutputProperty.toBluez());

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async {
    _log("request mtu is not supported on linux");
    return -1;
  }

  @override
  Future<void> readRssi(String deviceId) async {
    final device = _device(deviceId);
    if (device == null) return;
    onRssiRead?.call(deviceId, device.rssi);
    _eventMessageController.add(BleEvent.rssiRead.package({
      'type': BleEvent.rssiRead.name,
      'deviceId': deviceId,
      'rssi': device.rssi,
    }));
  }

  @override
  void requestLatency(String deviceId, BlePackageLatency priority) {
    _log("request latency is not supported on linux");
  }

  @override
  Stream<BleEventMessage> get bleEventStream => _eventMessageController.stream;
}

extension BlueZDeviceExtension on BlueZDevice {
  Uint8List get manufacturerDataHead {
    if (manufacturerData.isEmpty) return Uint8List(0);

    final sorted = manufacturerData.entries.toList()
      ..sort((a, b) => a.key.id - b.key.id);
    final first = sorted.first;
    return Uint8List.fromList([
      first.key.id & 0xff,
      (first.key.id >> 8) & 0xff,
      ...first.value,
    ]);
  }
}

extension ToBluez on BleOutputProperty {
  BlueZGattCharacteristicWriteType toBluez() =>
      this == BleOutputProperty.withResponse
          ? BlueZGattCharacteristicWriteType.request
          : BlueZGattCharacteristicWriteType.command;
}
