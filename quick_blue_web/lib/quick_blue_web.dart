import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_web_bluetooth/js_web_bluetooth.dart';
import 'package:quick_blue_platform_interface/ble_events.dart';
import 'package:quick_blue_platform_interface/quick_blue_platform_interface.dart';
import 'package:flutter_web_bluetooth/flutter_web_bluetooth.dart' as ble;
import 'package:flutter_web_bluetooth/web_bluetooth_logger.dart';
import 'package:quick_blue_web/models/available_device.dart';

typedef ServiceWithChars = (
  ble.BluetoothService,
  List<ble.BluetoothCharacteristic>
);

typedef DiscoveredProperties = Map<ble.BluetoothDevice, List<ServiceWithChars>>;

class QuickBlueWeb extends QuickBluePlatform {
  static final QuickBlueWeb _instance = QuickBlueWeb._();

  factory QuickBlueWeb() => _instance;

  QuickBlueWeb._() {
    _init();
  }

  final bool _isAvailable = false;

  void _init() {
    ble.FlutterWebBluetooth.instance.isAvailable.listen((x) => _isAvailable);
    ble.FlutterWebBluetooth.instance.devices.listen(_updateDevices);
  }

  _updateDevices(Set<ble.BluetoothDevice> devices) {
    for (var device in devices.map((x) => AvailableBluetoothDevice(x,
        onConnectionChanged: onConnectionChanged))) {
      if (!_devices.contains(device)) {
        device.init();
        _devices.add(device);
      }
    }
  }

  final Set<AvailableBluetoothDevice> _devices = {};

  AvailableBluetoothDevice _device(String deviceId) =>
      _devices.firstWhere((x) => x.device.id == deviceId);

  @override
  Stream<BleEventMessage> get bleEventStream => throw UnimplementedError();

  @override
  Future<void> connect(String deviceId, {bool? auto}) async {
    await _device(deviceId).device.connect();
  }

  @override
  Future<void> disconnect(String deviceId) async =>
      _device(deviceId).device.disconnect();

  @override
  void discoverServices(String deviceId) async {
    final device = await _device(deviceId).discoverServices();
    for (var entry in device.entries) {
      onServiceDiscovered?.call(
          deviceId, entry.key.uuid, entry.value.map((x) => x.uuid).toList());
    }
  }

  @override
  Future<bool> isBluetoothAvailable() async => _isAvailable;

  @override
  Future<void> readRssi(String deviceId) {
    throw UnimplementedError("no implemented on web");
  }

  @override
  Future<void> readValue(
          String deviceId, String service, String characteristic) =>
      _device(deviceId)
          .getChar(service, characteristic)
          .readValue()
          .then((data) {
        onValueChanged?.call(
            deviceId, characteristic, data.buffer.asUint8List());
      });

  @override
  void reinit() {
    throw UnimplementedError("not implemented on web");
  }

  @override
  void requestLatency(String deviceId, BlePackageLatency priority) {
    throw UnimplementedError("not implemented on web");
  }

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) {
    throw UnimplementedError("not implemented on web");
  }

  final StreamController<dynamic> _scanStreamController =
      StreamController.broadcast();

  @override
  Stream get scanResultStream => _scanStreamController.stream;

  @override
  void setLogger(QuickLogger logger) {
    setWebBluetoothLogger(logger);
  }

  final Map<String, StreamSubscription> _subs = {};

  @override
  Future<void> setNotifiable(String deviceId, String service,
      String characteristic, BleInputProperty bleInputProperty) {
    final char = _device(deviceId).getChar(service, characteristic);
    _subs[deviceId]?.cancel();
    _subs[deviceId] = char.value.listen((x) {
      onValueChanged?.call(deviceId, service, x.buffer.asUint8List());
    });
    return char.startNotifications();
  }

  BluetoothLEScan? _scan;

  @override
  void startScan({String? serviceId}) {
    ble.FlutterWebBluetooth.instance
        .requestDevice(serviceId == null
            ? ble.RequestOptionsBuilder.acceptAllDevices()
            : ble.RequestOptionsBuilder([
                ble.RequestFilterBuilder(services: [serviceId])
              ]))
        .then((x) {
      _scanStreamController.add({
        "name": x.name,
        "deviceId": x.id,
        "rssi": 0,
      });
    });
  }

  @override
  void stopScan() {
    _scan?.stop();
    _scan = null;
  }

  @override
  Future<void> writeValue(
      String deviceId,
      String service,
      String characteristic,
      Uint8List value,
      BleOutputProperty bleOutputProperty) async {
    final char = _device(deviceId).getChar(service, characteristic);
    switch (bleOutputProperty) {
      case BleOutputProperty.withResponse:
        return await char.writeValueWithResponse(value);
      case BleOutputProperty.withoutResponse:
        return await char.writeValueWithoutResponse(value);
    }
  }
}
