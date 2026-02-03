import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:quick_blue_platform_interface/ble_events.dart';
import 'package:quick_blue_platform_interface/background_presence.dart';

import 'quick_blue_platform_interface.dart';

class MethodChannelQuickBlue extends QuickBluePlatform {
  static const MethodChannel _method = const MethodChannel('quick_blue/method');
  static const _event_scanResult =
      const EventChannel('quick_blue/event.scanResult');
  static const _message_connector = const BasicMessageChannel(
      'quick_blue/message.connector', StandardMessageCodec());
  static const MethodChannel _backgroundChannel =
      MethodChannel('quick_blue/background');

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
    print("scanStop Stacktrace: ${StackTrace.current}");
    return _method
        .invokeMethod('stopScan')
        .then((_) => _log('stopScan invokeMethod success'));
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

      // Also send to event stream for state restoration test page
      if (message['type'] != null) {
        _eventMessageController
            .add(BleEvent.parse(message["type"]).package(message));
      }
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
    } else if (message['type'] == "backgroundStateRestoration") {
      // Legacy handler - convert to new BackgroundWakeEvent format
      final restoredPeripherals =
          (message['restoredPeripherals'] as List).cast<String>();
      if (restoredPeripherals.isNotEmpty) {
        _handleBackgroundWakeEvent({
          'deviceId': restoredPeripherals.first,
          'deviceName': null,
          'wakeType': BackgroundWakeType.stateRestored.name,
          'associationId': null,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
      }
    } else if (message['type'] == "backgroundWakeEvent") {
      // New unified background wake event handler
      _handleBackgroundWakeEvent(message);
    } else if (message['type'] == "repopulatePeripherals") {
      print(message);
    } else if (message['type'] != null) {
      _eventMessageController
          .add(BleEvent.parse(message["type"]).package(message));
    } else {
      print('unknown message: $message');
    }
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
      // sometimes android reports a fialed write, but writes the value anyways
      if (Platform.isAndroid) {
        bleEventStream.firstWhere((x) {
          return x.data is CharacteristicWriteEvent &&
              listEquals(value, (x.data as CharacteristicWriteEvent).value);
        }).timeout(Duration(milliseconds: 1250), onTimeout: () {
          throw onError;
        });
      } else {
        throw onError;
      }
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

  // ============ Background Presence API Implementation ============

  /// Stored callback handles for background wake events
  void _handleBackgroundWakeEvent(dynamic message) {
    final event = BackgroundWakeEvent.fromMap(message);

    if (message['wakeType'] == BackgroundWakeType.stateRestored.name) {
      _eventMessageController.add(BleEvent.parse('stateRestored').package({
        'restoredPeripherals': [event.deviceId],
      }));
    } else if (message['wakeType'] ==
        BackgroundWakeType.pendingConnectionRestored.name) {
      _eventMessageController.add(BleEvent.parse('pendingConnectionRestored')
          .package({'deviceId': event.deviceId}));
    }

    _eventMessageController.add(BleEvent.parse(
      event.wakeType == BackgroundWakeType.deviceAppeared
          ? 'deviceAppeared'
          : event.wakeType == BackgroundWakeType.deviceDisappeared
              ? 'deviceDisappeared'
              : event.wakeType.name,
    ).package({
      'deviceId': event.deviceId,
      'deviceName': event.deviceName,
      'wakeType': event.wakeType.name,
      'associationId': event.associationId,
      'timestamp': event.timestamp.millisecondsSinceEpoch,
    }));

    _backgroundChannel.invokeMethod('onPresenceEvent', message).then(
      (_) => _log('background wake event forwarded'),
    );
  }

  @override
  Future<BackgroundPresenceCapabilities>
      getBackgroundPresenceCapabilities() async {
    final result = await _method.invokeMethod<Map<dynamic, dynamic>>(
        'getBackgroundPresenceCapabilities');
    if (result == null) {
      // Return default capabilities if platform doesn't respond
      return BackgroundPresenceCapabilities(
        isSupported: Platform.isIOS || Platform.isAndroid,
        requiresAssociation: Platform.isAndroid,
        presenceObservationAvailable: Platform.isIOS,
      );
    }
    return BackgroundPresenceCapabilities.fromMap(result);
  }

  @override
  Future<void> registerBackgroundWakeCallback(
      int dispatcherHandle, int callbackHandle) async {
    await _method.invokeMethod('registerBackgroundWakeCallback', {
      'dispatcherHandle': dispatcherHandle,
      'callbackHandle': callbackHandle,
    });
    _log('registerBackgroundWakeCallback invokeMethod success');
  }

  @override
  Future<DeviceAssociationResult> associateDevice({
    required String namePattern,
    bool singleDevice = true,
  }) async {
    try {
      final result = await _method.invokeMethod<Map<dynamic, dynamic>>(
        'associateDevice',
        {
          'namePattern': namePattern,
          'singleDevice': singleDevice,
        },
      );

      if (result == null) {
        return DeviceAssociationResult.failure(
          errorMessage: 'No result returned from native',
          errorCode: AssociationErrorCode.unknown,
        );
      }

      return DeviceAssociationResult.fromMap(result);
    } on PlatformException catch (e) {
      return DeviceAssociationResult.failure(
        errorMessage: e.message ?? 'Platform error',
        errorCode: _mapAssociationErrorCode(e.code),
      );
    }
  }

  AssociationErrorCode _mapAssociationErrorCode(String code) {
    switch (code) {
      case 'USER_CANCELLED':
        return AssociationErrorCode.userCancelled;
      case 'NO_DEVICE_FOUND':
        return AssociationErrorCode.noDeviceFound;
      case 'BLUETOOTH_UNAVAILABLE':
        return AssociationErrorCode.bluetoothUnavailable;
      case 'CDM_UNAVAILABLE':
        return AssociationErrorCode.cdmUnavailable;
      case 'PERMISSION_DENIED':
        return AssociationErrorCode.permissionDenied;
      case 'ACTIVITY_UNAVAILABLE':
        return AssociationErrorCode.activityUnavailable;
      case 'NOT_SUPPORTED':
        return AssociationErrorCode.notSupported;
      default:
        return AssociationErrorCode.unknown;
    }
  }

  @override
  Future<void> startBackgroundPresenceObservation(
    String deviceId, {
    int? associationId,
  }) async {
    await _method.invokeMethod('startBackgroundPresenceObservation', {
      'deviceId': deviceId,
      'associationId': associationId,
    });
    _log('startBackgroundPresenceObservation invokeMethod success');
  }

  @override
  Future<void> stopBackgroundPresenceObservation(
    String deviceId, {
    int? associationId,
  }) async {
    await _method.invokeMethod('stopBackgroundPresenceObservation', {
      'deviceId': deviceId,
      'associationId': associationId,
    });
    _log('stopBackgroundPresenceObservation invokeMethod success');
  }

  @override
  Future<List<DeviceAssociationResult>> getBackgroundObservedDevices() async {
    final result = await _method
        .invokeMethod<List<dynamic>>('getBackgroundObservedDevices');

    if (result == null) return [];

    return result
        .cast<Map<dynamic, dynamic>>()
        .map((map) => DeviceAssociationResult.fromMap(map))
        .toList();
  }

  @override
  Future<void> removeBackgroundObservation(
    String deviceId, {
    int? associationId,
  }) async {
    await _method.invokeMethod('removeBackgroundObservation', {
      'deviceId': deviceId,
      'associationId': associationId,
    });
    _log('removeBackgroundObservation invokeMethod success');
  }

  @override
  Future<void> setAutoBleCommandOnAppear({
    required String serviceUuid,
    required String characteristicUuid,
    required Uint8List command,
  }) async {
    await _method.invokeMethod('setAutoBleCommandOnAppear', {
      'serviceUuid': serviceUuid,
      'characteristicUuid': characteristicUuid,
      'command': command.toList(),
    });
    _log('setAutoBleCommandOnAppear invokeMethod success');
  }

  @override
  Future<void> clearAutoBleCommandOnAppear() async {
    await _method.invokeMethod('clearAutoBleCommandOnAppear');
    _log('clearAutoBleCommandOnAppear invokeMethod success');
  }

  @override
  Future<void> shutdownBackgroundEngine() async {
    if (!Platform.isAndroid) {
      return;
    }
    await _method.invokeMethod('shutdownBackgroundEngine');
    _log('shutdownBackgroundEngine invokeMethod success');
  }
}
