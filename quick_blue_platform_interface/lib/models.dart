import 'dart:io';

import 'package:equatable/equatable.dart';

class BlueConnectionState extends Equatable {
  static const disconnected = BlueConnectionState._('disconnected');
  static const disconnecting = BlueConnectionState._('disconnecting');
  static const connected = BlueConnectionState._('connected');
  static const connecting = BlueConnectionState._('connecting');

  final String value;

  const BlueConnectionState._(this.value);

  static BlueConnectionState parse(String value) {
    if (value == disconnected.value) {
      return disconnected;
    } else if (value == connected.value) {
      return connected;
    } else if (value == disconnected.value) {
      return disconnected;
    } else if (value == disconnecting.value) {
      return disconnecting;
    } else if (value == connecting.value) {
      return connecting;
    }
    throw ArgumentError.value(value);
  }

  @override
  List<Object?> get props => [value];

  @override
  bool? get stringify => true;
}

class BleInputProperty {
  static const disabled = BleInputProperty._('disabled');
  static const notification = BleInputProperty._('notification');
  static const indication = BleInputProperty._('indication');

  final String value;

  const BleInputProperty._(this.value);
}

class BleOutputProperty {
  static const withResponse = BleOutputProperty._('withResponse');
  static const withoutResponse = BleOutputProperty._('withoutResponse');

  final String value;

  const BleOutputProperty._(this.value);
}

enum BlePackageLatency {
  low,
  medium,
  high;

  int get value => Platform.isAndroid
      ? switch (this) {
          BlePackageLatency.low => 1,
          BlePackageLatency.medium => 0,
          BlePackageLatency.high => 2
        }
      : switch (this) {
          BlePackageLatency.low => 0,
          BlePackageLatency.medium => 1,
          BlePackageLatency.high => 2
        };

  /// parses the interval in ms that is from
  /// android gatt onConnectionUpdated callback
  static fromInterval(int value) {
    if (value < 20) {
      return BlePackageLatency.low;
    } else if (value < 50) {
      return BlePackageLatency.medium;
    } else {
      return BlePackageLatency.high;
    }
  }
}
