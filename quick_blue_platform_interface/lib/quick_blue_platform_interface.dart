library quick_blue_platform_interface;

import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:quick_blue_platform_interface/ble_events.dart';
import 'package:quick_blue_platform_interface/background_presence.dart';

import 'models.dart';

export 'method_channel_quick_blue.dart';
export 'models.dart';
export 'background_presence.dart';

typedef QuickLogger = Logger;

typedef OnConnectionChanged = void Function(
    String deviceId, BlueConnectionState state);

typedef OnServiceDiscovered = void Function(
    String deviceId, String serviceId, List<String> characteristicIds);

typedef OnRssiRead = void Function(String deviceId, int rssi);

typedef OnValueChanged = void Function(
    String deviceId, String characteristicId, Uint8List value);

abstract class QuickBluePlatform extends PlatformInterface {
  QuickBluePlatform() : super(token: _token);

  static final Object _token = Object();

  static late QuickBluePlatform _instance;

  static QuickBluePlatform get instance => _instance;

  static set instance(QuickBluePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  void setLogger(QuickLogger logger);

  Future<bool> isBluetoothAvailable();

  void reinit();

  void startScan({String? serviceId});

  void stopScan();

  void requestLatency(String deviceId, BlePackageLatency priority);

  Stream<dynamic> get scanResultStream;

  Future<void> connect(String deviceId, {bool? auto});

  Future<void> disconnect(String deviceId);

  OnConnectionChanged? onConnectionChanged;

  void discoverServices(String deviceId);

  OnServiceDiscovered? onServiceDiscovered;

  OnRssiRead? onRssiRead;

  Stream<BleEventMessage> get bleEventStream;

  Future<void> setNotifiable(String deviceId, String service,
      String characteristic, BleInputProperty bleInputProperty);

  OnValueChanged? onValueChanged;

  Future<void> readValue(
      String deviceId, String service, String characteristic);

  Future<void> writeValue(
      String deviceId,
      String service,
      String characteristic,
      Uint8List value,
      BleOutputProperty bleOutputProperty);

  Future<void> readRssi(String deviceId);

  Future<int> requestMtu(String deviceId, int expectedMtu);

  // ============ Background Presence API ============

  /// Gets the background presence capabilities for the current platform.
  ///
  /// Returns information about whether background wake is supported,
  /// whether device association is required, and OS version details.
  Future<BackgroundPresenceCapabilities> getBackgroundPresenceCapabilities();

  /// Registers a callback for background wake events.
  ///
  /// The [dispatcherHandle] is the handle for the internal callback dispatcher.
  /// The [callbackHandle] is the handle for the user-provided callback function.
  ///
  /// Both handles are obtained using [PluginUtilities.getCallbackHandle].
  Future<void> registerBackgroundWakeCallback(
      int dispatcherHandle, int callbackHandle);

  /// Associates a device for background presence monitoring.
  ///
  /// **Android**: Opens the system Companion Device Manager dialog.
  /// **iOS**: Returns success immediately (no explicit association needed).
  ///
  /// The [namePattern] is a regex pattern to filter devices (Android only).
  /// Set [singleDevice] to true to show only one matching device.
  Future<DeviceAssociationResult> associateDevice({
    required String namePattern,
    bool singleDevice = true,
  });

  /// Starts background presence observation for a device.
  ///
  /// **iOS**: Issues a pending connection that wakes the app when device connects.
  /// **Android**: Registers with CompanionDeviceService for appear/disappear events.
  ///
  /// The [deviceId] is the peripheral UUID (iOS) or MAC address (Android).
  /// The [associationId] is required on Android API 33+ for presence observation.
  Future<void> startBackgroundPresenceObservation(
    String deviceId, {
    int? associationId,
  });

  /// Stops background presence observation for a device.
  Future<void> stopBackgroundPresenceObservation(
    String deviceId, {
    int? associationId,
  });

  /// Gets all devices currently being observed for background presence.
  ///
  /// **iOS**: Returns devices with pending connections.
  /// **Android**: Returns associated devices from Companion Device Manager.
  Future<List<DeviceAssociationResult>> getBackgroundObservedDevices();

  /// Removes a device from background observation.
  ///
  /// **Android**: Also disassociates from Companion Device Manager.
  /// **iOS**: Removes from pending connections.
  Future<void> removeBackgroundObservation(
    String deviceId, {
    int? associationId,
  });

  /// Sets an automatic BLE write command to execute when device appears.
  ///
  /// **Android only**: The command runs in the system service even when app is terminated.
  /// **iOS**: No-op (handle in the background wake callback instead).
  Future<void> setAutoBleCommandOnAppear({
    required String serviceUuid,
    required String characteristicUuid,
    required Uint8List command,
  });

  /// Clears the automatic BLE write command.
  Future<void> clearAutoBleCommandOnAppear();
}
