# quick_blue

A cross-platform (Android/iOS/macOS/Windows/Linux) BluetoothLE plugin for Flutter

## iOS State Restoration (Background Bluetooth)

This plugin supports iOS Bluetooth State Restoration, which allows your app to maintain connections with BLE peripherals even when the app is suspended or terminated by the OS.

### How It Works

- When a BLE wearable is connected, the plugin persists its UUID to UserDefaults
- If the app is killed by iOS due to memory pressure or system restart, the OS maintains the pending connection request
- When the wearable comes back in range, iOS automatically relaunches your app in the background
- Upon relaunch, the plugin restores the connection state and notifies your Flutter app

### Required Info.plist Configuration

Add the following keys to your `ios/Runner/Info.plist`:

```xml
<!-- Required: Background mode for Bluetooth -->
<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
</array>

<!-- Required: Bluetooth usage descriptions (should already exist) -->
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Your app uses Bluetooth to connect to BLE devices</string>

<key>NSBluetoothPeripheralUsageDescription</key>
<string>Your app uses Bluetooth to connect to BLE devices</string>
```

### Flutter Events

When state restoration occurs, your app will receive these events via `messageConnector`:

- `stateRestored` - Emitted when iOS restores the Bluetooth state after app relaunch
- `pendingConnectionRestored` - Emitted when a pending connection is restored from cold start (e.g., after phone reboot)

The connection will be automatically re-established when the device comes back in range.

# Usage

- [Scan BLE peripheral](#scan-ble-peripheral)
- [Connect BLE peripheral](#connect-ble-peripheral)
- [Discover services of BLE peripheral](#discover-services-of-ble-peripheral)
- [Transfer data between BLE central & peripheral](#transfer-data-between-ble-central--peripheral)

| API | Android | iOS | macOS | Windows | Linux |
| :--- | :---: | :---: | :---: | :---: | :---: |
| isBluetoothAvailable | ✔️ | ✔️ | ✔️ | ✔️ | ✔️ |
| startScan/stopScan | ✔️ | ✔️ | ✔️ | ✔️ | ✔️ |
| connect/disconnect | ✔️ | ✔️ | ✔️ | ✔️ |  |
| discoverServices | ✔️ | ✔️ | ✔️ | ✔️ |  |
| setNotifiable | ✔️ | ✔️ | ✔️ | ✔️ |  |
| readValue | ✔️ | ✔️ | ✔️ | ✔️ |  |
| writeValue | ✔️ | ✔️ | ✔️ | ✔️ |  |
| requestMtu | ✔️ | ✔️ | ✔️ | ✔️ |  |

> * Windows' APIs are little different on `discoverServices`: https://github.com/woodemi/quick_blue/issues/76

## Scan BLE peripheral

Android/iOS/macOS/Windows/Linux

```dart
QuickBlue.scanResultStream.listen((result) {
  print('onScanResult $result');
});

QuickBlue.startScan();
// ...
QuickBlue.stopScan();
```

## Connect BLE peripheral

Connect to `deviceId`, received from `QuickBlue.scanResultStream`

```dart
QuickBlue.setConnectionHandler(_handleConnectionChange);

void _handleConnectionChange(String deviceId, BlueConnectionState state) {
  print('_handleConnectionChange $deviceId, $state');
}

QuickBlue.connect(deviceId);
// ...
QuickBlue.disconnect(deviceId);
```

## Discover services of BLE peripheral

Discover services od `deviceId`

```dart
QuickBlue.setServiceHandler(_handleServiceDiscovery);

void _handleServiceDiscovery(String deviceId, String serviceId) {
  print('_handleServiceDiscovery $deviceId, $serviceId');
}

QuickBlue.discoverServices(deviceId);
```

## Transfer data between BLE central & peripheral

- Pull data from peripheral of `deviceId`

> Data would receive within value handler of `QuickBlue.setValueHandler`
> Because it is how [peripheral(_:didUpdateValueFor:error:)](https://developer.apple.com/documentation/corebluetooth/cbperipheraldelegate/1518708-peripheral) work on iOS/macOS

```dart
// Data would receive from value handler of `QuickBlue.setValueHandler`
QuickBlue.readValue(deviceId, serviceId, characteristicId);
```

- Send data to peripheral of `deviceId`

```dart
QuickBlue.writeValue(deviceId, serviceId, characteristicId, value);
```

- Receive data from peripheral of `deviceId`

```dart
QuickBlue.setValueHandler(_handleValueChange);

void _handleValueChange(String deviceId, String characteristicId, Uint8List value) {
  print('_handleValueChange $deviceId, $characteristicId, ${hex.encode(value)}');
}

QuickBlue.setNotifiable(deviceId, serviceId, characteristicId, true);
```
