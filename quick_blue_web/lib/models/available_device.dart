import 'dart:async';

import 'package:flutter_web_bluetooth/flutter_web_bluetooth.dart';
import 'package:quick_blue_platform_interface/quick_blue_platform_interface.dart';

typedef CharMap = Map<BluetoothService, List<BluetoothCharacteristic>>;

class AvailableBluetoothDevice {
  final CharMap chars = {};

  bool connected = false;

  final BluetoothDevice device;

  late final StreamSubscription _sub;

  OnConnectionChanged? onConnectionChanged;

  AvailableBluetoothDevice(this.device, {this.onConnectionChanged});

  init() {
    _sub = device.connected.listen(_onConectionStateChange);
  }

  void _onConectionStateChange(bool connect) {
    onConnectionChanged?.call(
        device.id,
        switch (connect) {
          true => BlueConnectionState.connected,
          false => BlueConnectionState.disconnected,
        });
    connected = connect;
    if (!connected) {
      chars.clear();
    }
  }

  void dispose() {
    _sub.cancel();
  }

  bool isDiscovered() => chars.isEmpty;

  Future<CharMap> discoverServices() async {
    await device.discoverServices().then((services) async {
      chars.clear();
      for (var service in services) {
        chars[service] = await service.getCharacteristics();
      }
    });
    return chars;
  }

  BluetoothCharacteristic getChar(String serviceId, String charId) =>
      chars.entries
          .firstWhere((x) => x.key.uuid == serviceId)
          .value
          .firstWhere((x) => x.uuid == charId);

  @override
  int get hashCode => device.id.hashCode;

  @override
  bool operator ==(Object other) =>
      other is AvailableBluetoothDevice && hashCode == other.hashCode;

  @override
  String toString() {
    return """AvailableDevice{id: ${device.id}, name: ${device.name}, connected: $connected, discovered: ${isDiscovered()} }""";
  }
}
