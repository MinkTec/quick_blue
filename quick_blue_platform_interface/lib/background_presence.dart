import 'dart:typed_data';

/// Callback signature for background wake events.
///
/// The callback must be a **top-level** or **static** function annotated
/// with `@pragma('vm:entry-point')` to prevent tree-shaking.
typedef BackgroundWakeCallback = void Function(BackgroundWakeEvent event);

/// Event triggered when a device wakes the app from background.
///
/// This event is dispatched when the operating system wakes the app due to
/// Bluetooth-related activity:
/// - **iOS**: State restoration or pending connection fulfilled
/// - **Android**: Companion Device Service detected device appeared/disappeared
class BackgroundWakeEvent {
  /// Device identifier.
  ///
  /// - **iOS**: Peripheral UUID (e.g., "A1B2C3D4-E5F6-...")
  /// - **Android**: MAC address (e.g., "AA:BB:CC:DD:EE:FF")
  final String deviceId;

  /// Optional device name if available.
  final String? deviceName;

  /// Type of wake event.
  final BackgroundWakeType wakeType;

  /// Platform-specific association ID (Android CDM only).
  ///
  /// This is required for API 33+ to manage presence observation.
  /// On iOS, this is always null.
  final int? associationId;

  /// Timestamp when the event occurred.
  final DateTime timestamp;

  const BackgroundWakeEvent({
    required this.deviceId,
    this.deviceName,
    required this.wakeType,
    this.associationId,
    required this.timestamp,
  });

  /// Creates a BackgroundWakeEvent from a map (used for deserialization from native).
  factory BackgroundWakeEvent.fromMap(Map<dynamic, dynamic> map) {
    return BackgroundWakeEvent(
      deviceId: map['deviceId'] as String,
      deviceName: map['deviceName'] as String?,
      wakeType: BackgroundWakeType.values.firstWhere(
        (e) => e.name == map['wakeType'],
        orElse: () => BackgroundWakeType.unknown,
      ),
      associationId: map['associationId'] as int?,
      timestamp: map['timestamp'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int)
          : DateTime.now(),
    );
  }

  /// Converts this event to a map for serialization.
  Map<String, dynamic> toMap() {
    return {
      'deviceId': deviceId,
      'deviceName': deviceName,
      'wakeType': wakeType.name,
      'associationId': associationId,
      'timestamp': timestamp.millisecondsSinceEpoch,
    };
  }

  @override
  String toString() {
    return 'BackgroundWakeEvent(deviceId: $deviceId, deviceName: $deviceName, '
        'wakeType: $wakeType, associationId: $associationId, timestamp: $timestamp)';
  }
}

/// The type of background wake event.
enum BackgroundWakeType {
  /// Device appeared / came into range.
  ///
  /// - **iOS**: Pending connection was fulfilled (device connected)
  /// - **Android**: CompanionDeviceService.onDeviceAppeared
  deviceAppeared,

  /// Device disappeared / went out of range.
  ///
  /// - **iOS**: Not directly supported (use disconnect events)
  /// - **Android**: CompanionDeviceService.onDeviceDisappeared
  deviceDisappeared,

  /// iOS state restoration - peripherals restored from terminated state.
  ///
  /// Triggered when the app is launched due to `willRestoreState` being called
  /// by CoreBluetooth. The `deviceId` contains the first restored peripheral,
  /// check the event stream for all restored peripherals.
  stateRestored,

  /// iOS pending connection restored from cold start.
  ///
  /// Triggered when a pending connection is re-established after the app
  /// was terminated and the device came back into range.
  pendingConnectionRestored,

  /// Unknown event type.
  unknown,
}

/// Result of device association for background presence monitoring.
///
/// On **Android**, this represents the result of the Companion Device Manager
/// association dialog. On **iOS**, this is typically a success with just the
/// device UUID since no explicit association is required.
class DeviceAssociationResult {
  /// Whether the association was successful.
  final bool success;

  /// Device identifier.
  ///
  /// - **iOS**: Peripheral UUID
  /// - **Android**: MAC address
  final String? deviceId;

  /// The display name of the associated device.
  final String? deviceName;

  /// The association ID assigned by the Companion Device Manager.
  ///
  /// Required on Android API 33+ for presence observation.
  /// Always null on iOS.
  final int? associationId;

  /// Error message if association failed.
  final String? errorMessage;

  /// Error code if association failed.
  final AssociationErrorCode? errorCode;

  const DeviceAssociationResult({
    required this.success,
    this.deviceId,
    this.deviceName,
    this.associationId,
    this.errorMessage,
    this.errorCode,
  });

  /// Creates a successful DeviceAssociationResult.
  factory DeviceAssociationResult.successful({
    required String deviceId,
    String? deviceName,
    int? associationId,
  }) {
    return DeviceAssociationResult(
      success: true,
      deviceId: deviceId,
      deviceName: deviceName,
      associationId: associationId,
    );
  }

  /// Creates a failed DeviceAssociationResult.
  factory DeviceAssociationResult.failure({
    required String errorMessage,
    AssociationErrorCode? errorCode,
  }) {
    return DeviceAssociationResult(
      success: false,
      errorMessage: errorMessage,
      errorCode: errorCode,
    );
  }

  /// Creates a DeviceAssociationResult from a map (used for deserialization from native).
  factory DeviceAssociationResult.fromMap(Map<dynamic, dynamic> map) {
    final success = map['success'] as bool? ?? false;

    if (success) {
      return DeviceAssociationResult.successful(
        deviceId: map['deviceId'] as String,
        deviceName: map['deviceName'] as String?,
        associationId: map['associationId'] as int?,
      );
    } else {
      return DeviceAssociationResult.failure(
        errorMessage: map['errorMessage'] as String? ?? 'Unknown error',
        errorCode: AssociationErrorCode.values.firstWhere(
          (e) => e.name == map['errorCode'],
          orElse: () => AssociationErrorCode.unknown,
        ),
      );
    }
  }

  /// Converts this result to a map for serialization.
  Map<String, dynamic> toMap() {
    return {
      'success': success,
      'deviceId': deviceId,
      'deviceName': deviceName,
      'associationId': associationId,
      'errorMessage': errorMessage,
      'errorCode': errorCode?.name,
    };
  }

  @override
  String toString() {
    if (success) {
      return 'DeviceAssociationResult.success(deviceId: $deviceId, '
          'deviceName: $deviceName, associationId: $associationId)';
    } else {
      return 'DeviceAssociationResult.failure(errorMessage: $errorMessage, '
          'errorCode: $errorCode)';
    }
  }
}

/// Error codes for association failures.
enum AssociationErrorCode {
  /// User cancelled the association dialog.
  userCancelled,

  /// No device matching the filter was found.
  noDeviceFound,

  /// Bluetooth is not available or disabled.
  bluetoothUnavailable,

  /// The Companion Device Manager is not available on this device.
  cdmUnavailable,

  /// The app doesn't have the required permissions.
  permissionDenied,

  /// Activity not available to show the dialog (Android only).
  activityUnavailable,

  /// The feature is not supported on this platform/OS version.
  notSupported,

  /// Unknown error.
  unknown,
}

/// Information about background presence capabilities on the current platform.
class BackgroundPresenceCapabilities {
  /// Whether background wake is supported on this platform.
  final bool isSupported;

  /// Whether device association is required before starting observation.
  ///
  /// - **iOS**: `false` - Uses peripheral UUID from previous connection
  /// - **Android**: `true` - Requires CDM association dialog
  final bool requiresAssociation;

  /// Whether presence observation (appear/disappear events) is available.
  ///
  /// - **iOS**: `true` - Via pending connections
  /// - **Android**: `true` on API 31+, `false` otherwise
  final bool presenceObservationAvailable;

  /// Minimum OS version required for full functionality.
  final String? minimumOsVersion;

  /// Current OS version.
  final String? currentOsVersion;

  /// Current API level (Android only).
  final int? apiLevel;

  const BackgroundPresenceCapabilities({
    required this.isSupported,
    required this.requiresAssociation,
    required this.presenceObservationAvailable,
    this.minimumOsVersion,
    this.currentOsVersion,
    this.apiLevel,
  });

  /// Creates capabilities from a map (used for deserialization from native).
  factory BackgroundPresenceCapabilities.fromMap(Map<dynamic, dynamic> map) {
    return BackgroundPresenceCapabilities(
      isSupported: map['isSupported'] as bool? ?? false,
      requiresAssociation: map['requiresAssociation'] as bool? ?? false,
      presenceObservationAvailable:
          map['presenceObservationAvailable'] as bool? ?? false,
      minimumOsVersion: map['minimumOsVersion'] as String?,
      currentOsVersion: map['currentOsVersion'] as String?,
      apiLevel: map['apiLevel'] as int?,
    );
  }

  /// Converts this to a map for serialization.
  Map<String, dynamic> toMap() {
    return {
      'isSupported': isSupported,
      'requiresAssociation': requiresAssociation,
      'presenceObservationAvailable': presenceObservationAvailable,
      'minimumOsVersion': minimumOsVersion,
      'currentOsVersion': currentOsVersion,
      'apiLevel': apiLevel,
    };
  }

  @override
  String toString() {
    return 'BackgroundPresenceCapabilities(isSupported: $isSupported, '
        'requiresAssociation: $requiresAssociation, '
        'presenceObservationAvailable: $presenceObservationAvailable, '
        'minimumOsVersion: $minimumOsVersion, currentOsVersion: $currentOsVersion, '
        'apiLevel: $apiLevel)';
  }
}

/// Configuration for automatic BLE write command on device appearance.
///
/// **Android only**: When configured, the system service will automatically
/// write this command to the specified characteristic when a companion device
/// appears, even when the app is terminated.
class AutoBleCommand {
  /// UUID of the GATT service containing the characteristic.
  final String serviceUuid;

  /// UUID of the characteristic to write to.
  final String characteristicUuid;

  /// The command bytes to write.
  final Uint8List command;

  const AutoBleCommand({
    required this.serviceUuid,
    required this.characteristicUuid,
    required this.command,
  });

  /// Converts this to a map for serialization.
  Map<String, dynamic> toMap() {
    return {
      'serviceUuid': serviceUuid,
      'characteristicUuid': characteristicUuid,
      'command': command.toList(),
    };
  }

  @override
  String toString() {
    return 'AutoBleCommand(serviceUuid: $serviceUuid, '
        'characteristicUuid: $characteristicUuid, '
        'command: ${command.length} bytes)';
  }
}
