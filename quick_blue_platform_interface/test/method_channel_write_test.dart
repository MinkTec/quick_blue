import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quick_blue_platform_interface/method_channel_quick_blue.dart';
import 'package:quick_blue_platform_interface/quick_blue_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('quick_blue/method');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('writeValue waits for the native write result', () async {
    final gate = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (_) => gate.future);
    var finished = false;
    final write = MethodChannelQuickBlue()
        .writeValue(
          'sensor',
          'service',
          'char',
          Uint8List.fromList([1]),
          BleOutputProperty.withoutResponse,
        )
        .then((_) => finished = true);
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    gate.complete();
    await write;
    expect(finished, isTrue);
  });

  test(
    'native write errors reach the awaited future, not an orphaned chain',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(
          code: 'IllegalArgument',
          message: 'Unknown deviceId: sensor',
        );
      });
      await expectLater(
        MethodChannelQuickBlue().writeValue(
          'sensor',
          'service',
          'char',
          Uint8List.fromList([1]),
          BleOutputProperty.withoutResponse,
        ),
        throwsA(isA<PlatformException>()),
      );
    },
  );
  test('incomplete service discovery messages cannot crash the handler', () async {
    final platform = MethodChannelQuickBlue();
    var calls = 0;
    platform.onServiceDiscovered = (_, __, ___) { calls++; };
    const codec = StandardMessageCodec();
    for (final message in [
      {'deviceId': 'sensor', 'ServiceState': 'discovered'},
      {'deviceId': 'sensor', 'ServiceState': 'discovered', 'service': 'service'},
    ]) {
      // ignore: deprecated_member_use
      await messenger.handlePlatformMessage('quick_blue/message.connector', codec.encodeMessage(message), (_) {});
    }
    expect(calls, 0);
  });
}
