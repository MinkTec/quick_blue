import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quick_blue_platform_interface/method_channel_quick_blue.dart';
import 'package:quick_blue_platform_interface/quick_blue_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'writes await native completion and propagate native failures',
    () async {
      final platform = MethodChannelQuickBlue();
      final pending = Completer<void>();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const method = MethodChannel('quick_blue/method');
      messenger.setMockMethodCallHandler(method, (call) async {
        expect(call.method, 'writeValue');
        expect(call.arguments['bleOutputProperty'], 'withoutResponse');
        await pending.future;
        throw PlatformException(code: 'Disconnected');
      });
      var completed = false;
      final write = platform.writeValue(
        'sensor',
        'service',
        'char',
        Uint8List.fromList([1]),
        BleOutputProperty.withoutResponse,
      );
      final expectation = expectLater(
        write.whenComplete(() => completed = true),
        throwsA(isA<PlatformException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(completed, false);
      pending.complete();
      await expectation;
      messenger.setMockMethodCallHandler(method, null);
    },
  );

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
