import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quick_blue_platform_interface/method_channel_quick_blue.dart';
import 'package:quick_blue_platform_interface/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const method = MethodChannel('quick_blue/method');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(method, null));

  test('setup cannot send a command until native subscription completes',
      () async {
    final platform = MethodChannelQuickBlue();
    final descriptor = Completer<void>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(method, (call) async {
      calls.add(call.method);
      if (call.method == 'setNotifiable') await descriptor.future;
      return null;
    });
    final setup = () async {
      await platform.setNotifiable(
          'device', 'service', 'notify', BleInputProperty.notification);
      await platform.writeValue('device', 'service', 'write',
          Uint8List.fromList([1]), BleOutputProperty.withoutResponse);
    }();
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['setNotifiable']);
    descriptor.complete();
    await setup;
    expect(calls, ['setNotifiable', 'writeValue']);
  });

  test('write waits for native completion and forwards its mode', () async {
    final platform = MethodChannelQuickBlue();
    final native = Completer<void>();
    var completed = false;
    messenger.setMockMethodCallHandler(method, (call) async {
      expect(call.arguments['bleOutputProperty'], 'withoutResponse');
      await native.future;
      return null;
    });
    final write = platform
        .writeValue('device', 'service', 'write', Uint8List.fromList([1]),
            BleOutputProperty.withoutResponse)
        .then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    native.complete();
    await write;
    expect(completed, isTrue);
  });

  test('native GATT failure remains a failed write', () async {
    final platform = MethodChannelQuickBlue();
    messenger.setMockMethodCallHandler(method, (_) async {
      throw PlatformException(code: 'GattStatus', details: 3);
    });
    await expectLater(
        platform.writeValue('device', 'service', 'write',
            Uint8List.fromList([1]), BleOutputProperty.withoutResponse),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'GattStatus')));
  });

  test('forwards native Bluetooth availability changes', () async {
    final platform = MethodChannelQuickBlue();
    final values = platform.bluetoothAvailabilityStream.take(2).toList();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const codec = StandardMessageCodec();

    await messenger.handlePlatformMessage(
      'quick_blue/message.connector',
      codec.encodeMessage(<String, Object>{
        'type': 'bluetoothAvailabilityChanged',
        'available': true,
      }),
      (_) {},
    );
    await messenger.handlePlatformMessage(
      'quick_blue/message.connector',
      codec.encodeMessage(<String, Object>{
        'type': 'bluetoothAvailabilityChanged',
        'available': false,
      }),
      (_) {},
    );

    expect(await values, <bool>[true, false]);
  });
}
