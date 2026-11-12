# quick_blue_windows

Windows implementation of QuickBlue.

## Service-filtered scanning

The existing QuickBlue API now supports service filtering on Windows:

```dart
QuickBlue.startScan(serviceId: '6e400001-c352-11e5-953d-0002a5d5c51b');
// All advertisements (no service filter):
QuickBlue.startScan();
```

The filter matches **advertised** service UUIDs, not services discovered through
a GATT connection. UUIDs may be canonical 128-bit strings or short 16-/32-bit
hex strings (for example `180d`). Invalid values return the native method-channel
error `invalid_service_uuid`. Null preserves unfiltered scanning.

Each scan replaces the previous watcher/filter. Stopped/replaced scan callbacks
are discarded. Scan events are delivered on Flutter's platform thread, and
device names come from advertisements without opening a GATT handle per result.

## Already-connected Windows sensors

The native `quick_blue/method` channel provides
`getSystemConnectedDevices` with a required `serviceId` UUID argument. It returns
`[{deviceId: <decimal Bluetooth address>, name: <device name>}]` for devices
Windows reports as connected and whose GATT services match the requested UUID.
This does not scan, pair, or change adapter settings. Callers should bound the
lookup and recheck cancellation/transport ownership before adopting a result.

Connection/characteristic events are marshalled to Flutter's platform thread.
Connect/disconnect generations discard late native connection completions, so
cancelled GATT discovery cannot install a stale device after disconnect.

The portable UUID validation test can be compiled and run with a C++17 compiler:

```text
clang++ -std=c++17 quick_blue_windows/test/service_uuid_test.cpp -o service_uuid_test.exe
./service_uuid_test.exe
```

Run these commands from the QuickBlue repository root. Hardware validation should
compare unfiltered scanning, a nonmatching UUID (zero results), and a known nearby
advertised service, including switching back to unfiltered scanning.

## Getting Started

This project is a starting point for a Flutter
[plug-in package](https://flutter.dev/developing-packages/),
a specialized package that includes platform-specific implementation code for
Android and/or iOS.

For help getting started with Flutter, view our
[online documentation](https://flutter.dev/docs), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
