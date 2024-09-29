import 'package:flutter_test/flutter_test.dart';
import 'package:quick_blue_web/quick_blue_web.dart';
import 'package:quick_blue_web/quick_blue_web_platform_interface.dart';
import 'package:quick_blue_web/quick_blue_web_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockQuickBlueWebPlatform
    with MockPlatformInterfaceMixin
    implements QuickBlueWebPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final QuickBlueWebPlatform initialPlatform = QuickBlueWebPlatform.instance;

  test('$MethodChannelQuickBlueWeb is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelQuickBlueWeb>());
  });

  test('getPlatformVersion', () async {
    QuickBlueWeb quickBlueWebPlugin = QuickBlueWeb();
    MockQuickBlueWebPlatform fakePlatform = MockQuickBlueWebPlatform();
    QuickBlueWebPlatform.instance = fakePlatform;

    expect(await quickBlueWebPlugin.getPlatformVersion(), '42');
  });
}
