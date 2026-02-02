import 'dart:convert';
import 'dart:io';

import 'package:quick_blue/quick_blue.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Key for storing background wake events in SharedPreferences.
const String backgroundWakeEventsKey = 'quick_blue_background_wake_events';

/// A model class for persisted wake events.
class PersistedWakeEvent {
  final String deviceId;
  final String? deviceName;
  final String wakeType;
  final String platform;
  final int? associationId;
  final DateTime timestamp;

  PersistedWakeEvent({
    required this.deviceId,
    this.deviceName,
    required this.wakeType,
    required this.platform,
    this.associationId,
    required this.timestamp,
  });

  factory PersistedWakeEvent.fromBackgroundWakeEvent(BackgroundWakeEvent event) {
    return PersistedWakeEvent(
      deviceId: event.deviceId,
      deviceName: event.deviceName,
      wakeType: event.wakeType.name,
      platform: _platformLabel(),
      associationId: event.associationId,
      timestamp: event.timestamp,
    );
  }

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'wakeType': wakeType,
        'platform': platform,
        'associationId': associationId,
        'timestamp': timestamp.toIso8601String(),
      };

  factory PersistedWakeEvent.fromJson(Map<String, dynamic> json) {
    return PersistedWakeEvent(
      deviceId: json['deviceId'] as String,
      deviceName: json['deviceName'] as String?,
      wakeType: json['wakeType'] as String,
      platform: json['platform'] as String? ?? 'unknown',
      associationId: json['associationId'] as int?,
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }

  @override
  String toString() =>
      'PersistedWakeEvent($wakeType, device: $deviceId, platform: $platform, at: $timestamp)';
}

String _platformLabel() {
  if (Platform.isAndroid) {
    return 'android';
  }
  if (Platform.isIOS) {
    return 'ios';
  }
  if (Platform.isMacOS) {
    return 'macos';
  }
  if (Platform.isWindows) {
    return 'windows';
  }
  if (Platform.isLinux) {
    return 'linux';
  }
  return 'unknown';
}

/// Saves a background wake event to SharedPreferences.
Future<void> saveBackgroundWakeEvent(BackgroundWakeEvent event) async {
  final prefs = await SharedPreferences.getInstance();
  final eventsJson = prefs.getStringList(backgroundWakeEventsKey) ?? [];

  final persistedEvent = PersistedWakeEvent.fromBackgroundWakeEvent(event);
  eventsJson.insert(0, jsonEncode(persistedEvent.toJson()));

  // Keep only last 100 events.
  if (eventsJson.length > 100) {
    eventsJson.removeRange(100, eventsJson.length);
  }

  await prefs.setStringList(backgroundWakeEventsKey, eventsJson);
  print('Saved background wake event: $persistedEvent');
}

/// Loads all persisted background wake events.
Future<List<PersistedWakeEvent>> loadBackgroundWakeEvents() async {
  final prefs = await SharedPreferences.getInstance();
  final eventsJson = prefs.getStringList(backgroundWakeEventsKey) ?? [];

  return eventsJson
      .map((json) {
        try {
          return PersistedWakeEvent.fromJson(jsonDecode(json));
        } catch (e) {
          print('Error parsing event: $e');
          return null;
        }
      })
      .whereType<PersistedWakeEvent>()
      .toList();
}

/// Clears all persisted background wake events.
Future<void> clearBackgroundWakeEvents() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(backgroundWakeEventsKey);
}
