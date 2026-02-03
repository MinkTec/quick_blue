import 'dart:ui';

import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:quick_blue_platform_interface/background_presence.dart';

/// Internal channel for background isolate communication.
const MethodChannel _backgroundChannel = MethodChannel('quick_blue/background');

/// Stores the user's callback handler.
BackgroundWakeCallback? _backgroundWakeCallbackHandler;

bool _backgroundChannelInitialized = false;

void _initializeBackgroundChannel() {
  if (_backgroundChannelInitialized) {
    return;
  }
  _backgroundChannel.setMethodCallHandler((MethodCall call) async {
    switch (call.method) {
      case 'onPresenceEvent':
        final eventData = call.arguments as Map<dynamic, dynamic>;
        final event = BackgroundWakeEvent.fromMap(eventData);
        _backgroundWakeCallbackHandler?.call(event);
        break;
      case 'initializeCallbackHandler':
        final rawHandle = call.arguments as int;
        final callbackHandle = CallbackHandle.fromRawHandle(rawHandle);
        final callback = PluginUtilities.getCallbackFromHandle(callbackHandle);
        if (callback != null) {
          _backgroundWakeCallbackHandler = (BackgroundWakeEvent event) {
            (callback as dynamic)(event);
          };
        }
        break;
      default:
        throw UnimplementedError('Method ${call.method} not implemented');
    }
  });
  _backgroundChannelInitialized = true;
}

void dispatchBackgroundWakeEvent(BackgroundWakeEvent event) {
  _initializeBackgroundChannel();
  _backgroundWakeCallbackHandler?.call(event);
}

Future<void> notifyBackgroundIsolateReady() async {
  _initializeBackgroundChannel();
  await _backgroundChannel.invokeMethod<void>('backgroundIsolateReady');
}

/// Background callback dispatcher for wake events.
///
/// This is invoked by Android when starting the headless engine.
@pragma('vm:entry-point')
void backgroundWakeCallbackDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  _initializeBackgroundChannel();
  _backgroundChannel.invokeMethod<void>('backgroundIsolateReady');
}

class QuickBlueBackgroundCallbackDispatcher {
  QuickBlueBackgroundCallbackDispatcher._();

  static void setCallbackHandler(BackgroundWakeCallback handler) {
    _backgroundWakeCallbackHandler = handler;
    _initializeBackgroundChannel();
  }

  static int? getCallbackHandle(BackgroundWakeCallback handler) {
    final handle = PluginUtilities.getCallbackHandle(handler);
    return handle?.toRawHandle();
  }

  static int get dispatcherHandle {
    final handle = PluginUtilities.getCallbackHandle(
      backgroundWakeCallbackDispatcher,
    );
    if (handle == null) {
      throw StateError(
        'Failed to get callback handle for backgroundWakeCallbackDispatcher. '
        'Ensure it is annotated with @pragma("vm:entry-point").',
      );
    }
    return handle.toRawHandle();
  }
}
