import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:quick_blue_linux/quick_blue_linux.dart';
import 'package:quick_blue_platform_interface/ble_events.dart';
import 'package:quick_blue_platform_interface/quick_blue_platform_interface.dart';
import 'package:quick_blue_platform_interface/background_presence.dart';
import 'package:quick_blue_web/quick_blue_web.dart';

import 'background_wake_dispatcher.dart' as background_dispatcher;
import 'models.dart';

export 'background_wake_dispatcher.dart' show backgroundWakeCallbackDispatcher;

export 'package:quick_blue_platform_interface/models.dart';

export 'package:quick_blue_platform_interface/ble_events.dart';

export 'package:quick_blue_platform_interface/background_presence.dart';

export 'models.dart';

bool _manualDartRegistrationNeeded = true;

QuickBluePlatform get _instance {
  // This is to manually endorse Dart implementations until automatic
  // registration of Dart plugins is implemented. For details see
  // https://github.com/flutter/flutter/issues/52267.
  if (_manualDartRegistrationNeeded) {
    // Only do the initial registration if it hasn't already been overridden
    // with a non-default instance.
    QuickBluePlatform.instance = kIsWeb
        ? QuickBlueWeb()
        : Platform.isLinux
            ? QuickBlueLinux()
            : MethodChannelQuickBlue();
    _manualDartRegistrationNeeded = false;
  }

  return QuickBluePlatform.instance;
}

class QuickBlue {
  static QuickBluePlatform _platform = _instance;

  static setInstance(QuickBluePlatform platform) {
    QuickBluePlatform.instance = platform;
    _platform = QuickBluePlatform.instance;
  }

  static void setLogger(QuickLogger logger) => _platform.setLogger(logger);

  static Future<bool> isBluetoothAvailable() =>
      _platform.isBluetoothAvailable();

  static reinit() => _platform.reinit();

  static void startScan({String? serviceId}) =>
      _platform.startScan(serviceId: serviceId);

  static void stopScan() => _platform.stopScan();

  static Stream<BlueScanResult> get scanResultStream =>
      _platform.scanResultStream.map((item) => BlueScanResult.fromMap(item));

  static Stream<BleEventMessage> get eventStream => _platform.bleEventStream;

  static Future<void> connect(String deviceId, {bool? auto}) {
    return _platform.connect(deviceId, auto: auto);
  }

  static Future<void> disconnect(String deviceId) =>
      _platform.disconnect(deviceId);

  static void setConnectionHandler(OnConnectionChanged? onConnectionChanged) =>
      _platform.onConnectionChanged = onConnectionChanged;

  static void discoverServices(String deviceId) =>
      _platform.discoverServices(deviceId);

  static void setServiceHandler(OnServiceDiscovered? onServiceDiscovered) =>
      _platform.onServiceDiscovered = onServiceDiscovered;

  static void setRssiHandler(OnRssiRead? onRssiRead) {
    _platform.onRssiRead = onRssiRead;
  }

  static Future<void> setNotifiable(String deviceId, String service,
      String characteristic, BleInputProperty bleInputProperty) {
    return _platform.setNotifiable(
        deviceId, service, characteristic, bleInputProperty);
  }

  static void setValueHandler(OnValueChanged? onValueChanged) {
    _platform.onValueChanged = onValueChanged;
  }

  static Future<void> readValue(
      String deviceId, String service, String characteristic) {
    return _platform.readValue(deviceId, service, characteristic);
  }

  static Future<void> writeValue(
      String deviceId,
      String service,
      String characteristic,
      Uint8List value,
      BleOutputProperty bleOutputProperty) {
    return _platform.writeValue(
        deviceId, service, characteristic, value, bleOutputProperty);
  }

  static Future<int> requestMtu(String deviceId, int expectedMtu) =>
      _platform.requestMtu(deviceId, expectedMtu);

  static Future<void> readRssi(String deviceId) => _platform.readRssi(deviceId);

  /// set the interval between ble packages
  /// The behaviour can vary from platfrom to platform
  static void requestLatency(String deviceId, BlePackageLatency latency) =>
      _platform.requestLatency(deviceId, latency);

  // ============ Background Presence API ============

  /// Gets the background presence capabilities for the current platform.
  ///
  /// Returns information about whether background wake is supported,
  /// whether device association is required, and OS version details.
  ///
  /// Example:
  /// ```dart
  /// final capabilities = await QuickBlue.getBackgroundPresenceCapabilities();
  /// if (capabilities.isSupported) {
  ///   if (capabilities.requiresAssociation) {
  ///     // Android: Need to associate device first
  ///   } else {
  ///     // iOS: Can start observation directly
  ///   }
  /// }
  /// ```
  static Future<BackgroundPresenceCapabilities>
      getBackgroundPresenceCapabilities() =>
          _platform.getBackgroundPresenceCapabilities();

  /// Registers a callback for background wake events.
  ///
  /// The [callback] must be a **top-level** or **static** function annotated
  /// with `@pragma('vm:entry-point')` to prevent tree-shaking.
  ///
  /// This callback will be invoked when:
  /// - **iOS**: The app is woken due to state restoration or a pending
  ///   connection being fulfilled
  /// - **Android**: The Companion Device Service detects device appeared/disappeared
  ///
  /// Background wake events are also emitted on [eventStream] when the app
  /// is in the foreground.
  ///
  /// Example:
  /// ```dart
  /// @pragma('vm:entry-point')
  /// void onBackgroundWake(BackgroundWakeEvent event) {
  ///   print('Device ${event.deviceId} triggered wake: ${event.wakeType}');
  ///   // Handle the wake event - e.g., connect to device, sync data, etc.
  /// }
  ///
  /// void main() {
  ///   QuickBlue.initializeBackgroundWakeCallback(onBackgroundWake);
  ///   runApp(MyApp());
  /// }
  /// ```
  static Future<void> initializeBackgroundWakeCallback(
      BackgroundWakeCallback callback) async {
    background_dispatcher.QuickBlueBackgroundCallbackDispatcher
        .setCallbackHandler(callback);

    if (Platform.isIOS) {
      await background_dispatcher.notifyBackgroundIsolateReady();
    }

    final callbackHandle =
        background_dispatcher.QuickBlueBackgroundCallbackDispatcher
            .getCallbackHandle(callback);
    if (callbackHandle == null) {
      throw StateError(
        'Failed to get callback handle. Ensure the callback is a top-level '
        'or static function annotated with @pragma("vm:entry-point").',
      );
    }

    final dispatcherHandle =
        background_dispatcher.QuickBlueBackgroundCallbackDispatcher
            .dispatcherHandle;

    await _platform.registerBackgroundWakeCallback(
        dispatcherHandle, callbackHandle);
  }

  /// Deprecated: use [initializeBackgroundWakeCallback] instead.
  @Deprecated('Use initializeBackgroundWakeCallback instead.')
  static Future<void> registerBackgroundWakeCallback(
      BackgroundWakeCallback callback) {
    return initializeBackgroundWakeCallback(callback);
  }

  static void dispatchBackgroundWakeEvent(BackgroundWakeEvent event) {
    background_dispatcher.dispatchBackgroundWakeEvent(event);
  }

  /// Associates a device for background presence monitoring.
  ///
  /// **Android only**: Opens the system Companion Device Manager dialog
  /// to let the user select a device. This is required before calling
  /// [startBackgroundPresenceObservation] on Android.
  ///
  /// **iOS**: Returns success immediately as no explicit association is needed.
  /// Use the device UUID from scan results or a previous connection.
  ///
  /// The [namePattern] is a regex pattern to filter devices (Android only).
  /// Set [singleDevice] to true to show only one matching device in the dialog.
  ///
  /// Example:
  /// ```dart
  /// final result = await QuickBlue.associateDevice(namePattern: 'MyDevice.*');
  /// if (result.success) {
  ///   print('Associated with ${result.deviceId}');
  ///   await QuickBlue.startBackgroundPresenceObservation(
  ///     result.deviceId!,
  ///     associationId: result.associationId,
  ///   );
  /// } else {
  ///   print('Association failed: ${result.errorMessage}');
  /// }
  /// ```
  static Future<DeviceAssociationResult> associateDevice({
    required String namePattern,
    bool singleDevice = true,
  }) =>
      _platform.associateDevice(
        namePattern: namePattern,
        singleDevice: singleDevice,
      );

  /// Starts background presence observation for a device.
  ///
  /// Once started, the app will be woken up when the device:
  /// - **iOS**: Connects via a pending connection (comes into range and connects)
  /// - **Android**: Appears or disappears (API 31+)
  ///
  /// On **iOS**, the device must have been previously connected (UUID known).
  /// On **Android**, the device must have been previously associated via
  /// [associateDevice].
  ///
  /// The [deviceId] is:
  /// - **iOS**: The peripheral UUID (from scan results or connection)
  /// - **Android**: The MAC address (from association result)
  ///
  /// The [associationId] is required on Android API 33+ and should be passed
  /// from the [DeviceAssociationResult].
  ///
  /// Example:
  /// ```dart
  /// // After connecting to a device
  /// await QuickBlue.startBackgroundPresenceObservation(deviceId);
  ///
  /// // Or after association on Android
  /// await QuickBlue.startBackgroundPresenceObservation(
  ///   associationResult.deviceId!,
  ///   associationId: associationResult.associationId,
  /// );
  /// ```
  static Future<void> startBackgroundPresenceObservation(
    String deviceId, {
    int? associationId,
  }) =>
      _platform.startBackgroundPresenceObservation(
        deviceId,
        associationId: associationId,
      );

  /// Stops background presence observation for a device.
  ///
  /// The device will no longer wake the app when it appears/disappears.
  ///
  /// Example:
  /// ```dart
  /// await QuickBlue.stopBackgroundPresenceObservation(deviceId);
  /// ```
  static Future<void> stopBackgroundPresenceObservation(
    String deviceId, {
    int? associationId,
  }) =>
      _platform.stopBackgroundPresenceObservation(
        deviceId,
        associationId: associationId,
      );

  /// Gets all devices currently being observed for background presence.
  ///
  /// - **iOS**: Returns devices with pending connections stored in UserDefaults
  /// - **Android**: Returns associated devices from Companion Device Manager
  ///
  /// Example:
  /// ```dart
  /// final devices = await QuickBlue.getBackgroundObservedDevices();
  /// for (final device in devices) {
  ///   print('Observing: ${device.deviceId} (${device.deviceName})');
  /// }
  /// ```
  static Future<List<DeviceAssociationResult>> getBackgroundObservedDevices() =>
      _platform.getBackgroundObservedDevices();

  /// Removes a device from background observation.
  ///
  /// - **Android**: Also disassociates from Companion Device Manager
  /// - **iOS**: Removes from pending connections and UserDefaults
  ///
  /// Example:
  /// ```dart
  /// await QuickBlue.removeBackgroundObservation(deviceId);
  /// ```
  static Future<void> removeBackgroundObservation(
    String deviceId, {
    int? associationId,
  }) =>
      _platform.removeBackgroundObservation(
        deviceId,
        associationId: associationId,
      );

  /// Sets an automatic BLE write command to execute when device appears.
  ///
  /// **Android only**: When configured, the system service will automatically
  /// connect to the device and write this command to the specified characteristic
  /// when the device appears, even when the app is terminated.
  ///
  /// **iOS**: No-op. Handle BLE writes in the background wake callback instead.
  ///
  /// This is useful for scenarios like:
  /// - Sending a "wake up" command to a peripheral
  /// - Triggering an action on the device when it comes into range
  ///
  /// Example:
  /// ```dart
  /// await QuickBlue.setAutoBleCommandOnAppear(
  ///   serviceUuid: '0000180d-0000-1000-8000-00805f9b34fb',
  ///   characteristicUuid: '00002a37-0000-1000-8000-00805f9b34fb',
  ///   command: Uint8List.fromList([0x01, 0x02, 0x03]),
  /// );
  /// ```
  static Future<void> setAutoBleCommandOnAppear({
    required String serviceUuid,
    required String characteristicUuid,
    required Uint8List command,
  }) =>
      _platform.setAutoBleCommandOnAppear(
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        command: command,
      );

  /// Clears the automatic BLE write command.
  ///
  /// **Android only**: After calling this, no automatic BLE write will occur
  /// when devices appear.
  ///
  /// Example:
  /// ```dart
  /// await QuickBlue.clearAutoBleCommandOnAppear();
  /// ```
  static Future<void> clearAutoBleCommandOnAppear() =>
      _platform.clearAutoBleCommandOnAppear();

  /// Android only: shuts down the headless background FlutterEngine used for
  /// companion presence.
  static Future<void> shutdownBackgroundEngine() =>
      _platform.shutdownBackgroundEngine();
}
