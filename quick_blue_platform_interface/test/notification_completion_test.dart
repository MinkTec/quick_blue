import 'dart:async';

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

  test('notification future waits for native descriptor completion', () async {
    final native = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'setNotifiable');
      await native.future;
    });
    var complete = false;
    final operation = MethodChannelQuickBlue().setNotifiable(
        'sensor', 'service', 'notify', BleInputProperty.notification);
    final observed = operation.then((_) => complete = true);
    await Future<void>.delayed(Duration.zero);
    expect(complete, isFalse);
    native.complete();
    await observed;
    expect(complete, isTrue);
  });

  test('native notification failure reaches the setup owner', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'GattOperationFailed');
    });
    await expectLater(
        MethodChannelQuickBlue().setNotifiable(
            'sensor', 'service', 'notify', BleInputProperty.notification),
        throwsA(isA<PlatformException>()));
  });
}
