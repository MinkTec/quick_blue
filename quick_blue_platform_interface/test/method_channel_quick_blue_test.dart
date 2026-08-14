import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quick_blue_platform_interface/method_channel_quick_blue.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
