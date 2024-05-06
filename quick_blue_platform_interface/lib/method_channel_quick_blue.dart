import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:quick_blue_platform_interface/ble_events.dart';

import 'quick_blue_platform_interface.dart';

class MethodChannelQuickBlue extends QuickBluePlatform {
  static const MethodChannel _method = const MethodChannel('quick_blue/method');
  static const _event_scanResult =
      const EventChannel('quick_blue/event.scanResult');
  static const _message_connector = const BasicMessageChannel(
      'quick_blue/message.connector', StandardMessageCodec());

  MethodChannelQuickBlue() {
    _message_connector.setMessageHandler(_handleConnectorMessage);
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
    bool result = await _method.invokeMethod('isBluetoothAvailable');
    return result;
  }

  @override
  Future<void> startScan({String? serviceId}) {
    return _method.invokeMethod('startScan', {
      'serviceId': serviceId,
    }).onError((error, stackTrace) {
      _log('stopScan invocation failed with $error');
    }).then((_) => _log('startScan invokeMethod success'));
  }

  @override
  Future<void> stopScan() {
    return _method
        .invokeMethod('stopScan')
        .then((_) => print('stopScan invokeMethod success'));
  }

  Stream<dynamic> scanResultStream =
      _event_scanResult.receiveBroadcastStream({'name': 'scanResult'});

  StreamController<BleEventMessage> _eventMessageController =
      StreamController.broadcast();

  Stream<BleEventMessage> get bleEventStream => _eventMessageController.stream;

  @override
  Future<void> connect(String deviceId, {bool? auto}) {
    if (Platform.isAndroid && auto != null && auto) {
      return _method.invokeMethod('autoConnect', {
        'deviceId': deviceId,
      }).then((_) => _log('connect invokeMethod success'));
    } else {
      return _method.invokeMethod('connect', {
        'deviceId': deviceId,
      }).then((_) => _log('connect invokeMethod success'));
    }
  }

  void autoConnect(String deviceId) {
    _method.invokeMethod('autoConnect', {
      'deviceId': deviceId,
    }).then((_) => _log('connect invokeMethod success'));
  }

  @override
  Future<void> disconnect(String deviceId) {
    return _method.invokeMethod('disconnect', {
      'deviceId': deviceId,
    }).then((_) => _log('disconnect invokeMethod success'));
  }

  @override
  void discoverServices(String deviceId) {
    _method.invokeMethod('discoverServices', {
      'deviceId': deviceId,
    }).then((_) => _log('discoverServices invokeMethod success'));
  }

  Future<void> _handleConnectorMessage(dynamic message) async {
    if (message['ConnectionState'] != null) {
      String deviceId = message['deviceId'];
      BlueConnectionState connectionState =
          BlueConnectionState.parse(message['ConnectionState']);
      onConnectionChanged?.call(deviceId, connectionState);
    } else if (message['ServiceState'] != null) {
      if (message['ServiceState'] == 'discovered') {
        String deviceId = message['deviceId'];
        String service = message['service'];
        List<String> characteristics =
            (message['characteristics'] as List).cast();
        onServiceDiscovered?.call(deviceId, service, characteristics);
      }
    } else if (message['characteristicValue'] != null) {
      String deviceId = message['deviceId'];
      var characteristicValue = message['characteristicValue'];
      String characteristic = characteristicValue['characteristic'];
      Uint8List value = Uint8List.fromList(
          characteristicValue['value']); // In case of _Uint8ArrayView
      onValueChanged?.call(deviceId, characteristic, value);
    } else if (message['mtuConfig'] != null) {
      _mtuConfigController.add(message['mtuConfig']);
    } else if (message['type'] == "rssiRead") {
      onRssiRead?.call(message['deviceId'], message["rssi"]);
    } else if (message['type'] == "repopulatePeripherals") {
        print(message);
    }

    _eventMessageController
        .add(BleEvent.parse(message["type"]).package(message));
  }

  @override
  Future<void> setNotifiable(String deviceId, String service,
      String characteristic, BleInputProperty bleInputProperty) async {
    _method.invokeMethod('setNotifiable', {
      'deviceId': deviceId,
      'service': service,
      'characteristic': characteristic,
      'bleInputProperty': bleInputProperty.value,
    }).then((_) => _log('setNotifiable invokeMethod success'));
  }

  @override
  Future<void> readValue(
      String deviceId, String service, String characteristic) async {
    _method.invokeMethod('readValue', {
      'deviceId': deviceId,
      'service': service,
      'characteristic': characteristic,
    }).then((_) => _log('readValue invokeMethod success'));
  }

  @override
  Future<void> writeValue(
      String deviceId,
      String service,
      String characteristic,
      Uint8List value,
      BleOutputProperty bleOutputProperty) async {
    _method.invokeMethod('writeValue', {
      'deviceId': deviceId,
      'service': service,
      'characteristic': characteristic,
      'value': value,
      'bleOutputProperty': bleOutputProperty.value,
    }).then((_) {
      _log('writeValue invokeMethod success', logLevel: Level.ALL);
    }).catchError((onError) {
      // Characteristic sometimes unavailable on Android
      throw onError;
    });
  }

  // FIXME Close
  final _mtuConfigController = StreamController<int>.broadcast();

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async {
    _method.invokeMethod('requestMtu', {
      'deviceId': deviceId,
      'expectedMtu': expectedMtu,
    }).then((_) => _log('requestMtu invokeMethod success'));
    return await _mtuConfigController.stream.first;
  }

  Future<void> readRssi(String deviceId) async {
    await _method.invokeMethod('readRssi', {'deviceId': deviceId});
  }

  @override
  void reinit() {
    if (Platform.isAndroid) {
      _method.invokeMethod('reinit');
    }
  }

  @override
  void requestLatency(String deviceId, BlePackageLatency priority) {
    _method.invokeMethod('requestLatency', {
      'deviceId': deviceId,
      'priority': priority.value,
    }).then((_) => _log("requestConnectionPriority invokeMethod success"));
  }
}
