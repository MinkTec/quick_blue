import 'package:quick_blue_platform_interface/models.dart';

class BleEventMessage {
  final BleEvent event;
  final EventData data;

  BleEventMessage({
    required this.event,
    required this.data,
  });

  @override
  String toString() {
    return "BleEventMessage{${event.name}, ${data}}";
  }
}

typedef EventDataMap = Map;

enum BleEvent {
  connected,
  disconnected,
  mtuChanged,
  characteristicRead,
  characteristicChanged,
  characteristicWrite,
  serviceDiscovered,
  latencyChanged,
  rssiRead,
  connectionStateChanged,
  scanFailed,
  scanResult,
  connectionUpdate,
  unkown,
  ;

  static BleEvent parse(String string) => BleEvent.values.firstWhere(
        (e) => e.name == string,
        orElse: () => BleEvent.unkown,
      );

  BleEventMessage package(EventDataMap data) {
    try {
      return BleEventMessage(event: this, data: _parseEventData(data));
    } catch (e) {
      print("ble event construction error: ${e}");
      rethrow;
    }
  }

  EventData _parseEventData(EventDataMap data) {
    return switch (this) {
      BleEvent.mtuChanged => MtuEvent(mtu: data["mtuConfig"]),
      BleEvent.rssiRead =>
        RssiEvent(rssi: data["rssi"], deviceId: data["deviceId"]),
      BleEvent.scanFailed => ScanFailedEvent(errorCode: data["errorCode"]),
      BleEvent.connected => ConnectionChangeEvent(deviceId: data["deviceId"]),
      BleEvent.disconnected =>
        ConnectionChangeEvent(deviceId: data["deviceId"]),
      BleEvent.serviceDiscovered => ServiceDiscoveredData(
            deviceId: data["deviceId"],
            service: data["service"],
            characteristics: <String>[
              for (var e in data["characteristics"]) e.toString()
            ]),
      BleEvent.characteristicWrite => CharacteristicWriteEvent(
          deviceId: data["deviceId"],
          status: data["status"],
          value: data["value"],
          characteristic: data["characteristic"]),
      _ => GenericEventData(data: data)
    };
  }
}

abstract class EventData {
  EventData();
}

class DeviceBoundEventData extends EventData {
  DeviceBoundEventData({required this.deviceId});

  String deviceId;
}

class GenericEventData extends EventData {
  GenericEventData({required this.data});

  EventDataMap? data;

  @override
  String toString() => "BleEventData: ${data.toString()}";
}

class MtuEvent extends EventData {
  MtuEvent({required this.mtu});

  final int mtu;

  @override
  String toString() => "Mtu: ${mtu}";
}

class RssiEvent extends DeviceBoundEventData {
  final int rssi;

  RssiEvent({required this.rssi, required super.deviceId});

  @override
  String toString() => "RSSI: ${rssi}";
}

class ScanFailedEvent extends EventData {
  ScanFailedEvent({required this.errorCode});

  int errorCode;

  @override
  String toString() => "error code: ${errorCode}";
}

class ConnectionChangeEvent extends DeviceBoundEventData {
  ConnectionChangeEvent({required super.deviceId, this.latency});

  BlePackageLatency? latency;

  @override
  String toString() {
    return "device: ${deviceId}";
  }
}

class CharacteristicWriteEvent extends DeviceBoundEventData {
  final int status;
  final String characteristic;
  final List<int>? value;

  CharacteristicWriteEvent({
    required super.deviceId,
    required this.status,
    required this.characteristic,
    this.value,
  });

  @override
  String toString() {
    return """CharacteristicWriteEvent{
  characteristic : ${characteristic},
  value : ${value},
  status : ${status},
}""";
  }
}

class ServiceDiscoveredData extends DeviceBoundEventData {
  ServiceDiscoveredData(
      {required super.deviceId,
      required this.service,
      required this.characteristics});

  String service;
  List<String> characteristics;

  @override
  String toString() {
    return """service: ${service},
    ${characteristics.join("\n")}
""";
  }
}
