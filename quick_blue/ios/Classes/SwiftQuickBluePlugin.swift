import CoreBluetooth
import Flutter
import UIKit

let GATT_HEADER_LENGTH = 3

let GSS_SUFFIX = "0000-1000-8000-00805f9b34fb"

// State Restoration Keys
let kConnectedPeripheralUUIDs = "quick_blue_connected_peripheral_uuids"
let kRestoreIdentifier = "quick_blue_restore_identifier"

extension CBUUID {
  public var uuidStr: String {
    get {
      uuidString.lowercased()
    }
  }
}

extension CBPeripheral {
  // FIXME https://forums.developer.apple.com/thread/84375
  public var uuid: UUID {
    identifier
  }

  public func getCharacteristic(_ characteristic: String, of service: String) -> CBCharacteristic? {
    return self.services?.first {
			$0.uuid.uuidStr == service || "0000\($0.uuid.uuidStr)-\(GSS_SUFFIX)" == service
		}?.characteristics?.first {
			$0.uuid.uuidStr == characteristic || "0000\($0.uuid.uuidStr)-\(GSS_SUFFIX)" == characteristic
		}
  }

  public func setNotifiable(_ bleInputProperty: String, for characteristic: String, of service: String) {
	let char = getCharacteristic(characteristic, of: service)
	  if char != nil {
		  setNotifyValue(bleInputProperty != "disabled", for: char!)
	  }
  }
}

public class SwiftQuickBluePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let method = FlutterMethodChannel(name: "quick_blue/method", binaryMessenger: registrar.messenger())
    let backgroundChannel = FlutterMethodChannel(name: "quick_blue/background", binaryMessenger: registrar.messenger())
    let eventScanResult = FlutterEventChannel(name: "quick_blue/event.scanResult", binaryMessenger: registrar.messenger())
    let messageConnector = FlutterBasicMessageChannel(name: "quick_blue/message.connector", binaryMessenger: registrar.messenger())

    let instance = SwiftQuickBluePlugin()
    registrar.addMethodCallDelegate(instance, channel: method)
    eventScanResult.setStreamHandler(instance)
    instance.messageConnector = messageConnector
    instance.backgroundChannel = backgroundChannel
    backgroundChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "backgroundIsolateReady":
        instance.backgroundChannelReady = true
        instance.flushPendingBackgroundEvents()
        instance.flushPendingFlutterMessages()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
    
  private var manager: CBCentralManager!
  private var discoveredPeripherals: Dictionary<String, CBPeripheral>!
  private let peripheralsQueue = DispatchQueue(label: "quick_blue.peripherals")

  private var scanResultSink: FlutterEventSink?
  private var messageConnector: FlutterBasicMessageChannel!
  private var backgroundChannel: FlutterMethodChannel!
  private var backgroundChannelReady = false
  private var pendingBackgroundEvents: [[String: Any]] = []
  private var pendingFlutterMessages: [[String: Any]] = []

  override init() {
    super.init()
    discoveredPeripherals = Dictionary()

    if let callback = UserDefaults.standard.value(forKey: kBackgroundCallbackKey) as? Int {
      backgroundCallbackHandle = Int64(callback)
    }
    
    // Initialize CBCentralManager with state restoration support
    let options: [String: Any] = [
      CBCentralManagerOptionRestoreIdentifierKey: kRestoreIdentifier,
      CBCentralManagerOptionShowPowerAlertKey: true
    ]
    let queue = DispatchQueue(label: "quick_blue.bluetooth", qos: .utility)
    manager = CBCentralManager(delegate: self, queue: queue, options: options)
  }
  
  // MARK: - State Restoration Helper Methods
  
  private func saveConnectedPeripheralUUID(_ uuid: String) {
    var uuids = UserDefaults.standard.array(forKey: kConnectedPeripheralUUIDs) as? [String] ?? []
    if !uuids.contains(uuid) {
      uuids.append(uuid)
      UserDefaults.standard.set(uuids, forKey: kConnectedPeripheralUUIDs)
    }
  }
  
  private func removeConnectedPeripheralUUID(_ uuid: String) {
    var uuids = UserDefaults.standard.array(forKey: kConnectedPeripheralUUIDs) as? [String] ?? []
    uuids.removeAll { $0 == uuid }
    UserDefaults.standard.set(uuids, forKey: kConnectedPeripheralUUIDs)
  }
  
  private func restorePendingConnections() {
    guard let uuids = UserDefaults.standard.array(forKey: kConnectedPeripheralUUIDs) as? [String] else {
      return
    }
    
    let identifiers = uuids.compactMap { UUID(uuidString: $0) }
    guard !identifiers.isEmpty else { return }
    
    let peripherals = manager.retrievePeripherals(withIdentifiers: identifiers)
    
    for peripheral in peripherals {
      setDiscoveredPeripheral(peripheral)
      peripheral.delegate = self
      
      // Issue pending connection
      manager.connect(peripheral, options: [
        CBConnectPeripheralOptionNotifyOnConnectionKey: true
      ])
      
      sendFlutterMessage([
        "type": "pendingConnectionRestored",
        "deviceId": peripheral.uuid.uuidString
      ])
    }
  }

  private func setDiscoveredPeripheral(_ peripheral: CBPeripheral) {
    peripheralsQueue.sync {
      discoveredPeripherals[peripheral.uuid.uuidString] = peripheral
    }
  }

  private func getDiscoveredPeripheral(_ deviceId: String) -> CBPeripheral? {
    peripheralsQueue.sync {
      discoveredPeripherals[deviceId]
    }
  }

  private func hasTrackedPeripheral(_ uuid: String) -> Bool {
    let uuids = UserDefaults.standard.array(forKey: kConnectedPeripheralUUIDs) as? [String] ?? []
    return uuids.contains(uuid)
  }

  private func sendFlutterMessage(_ message: [String: Any]) {
    DispatchQueue.main.async {
      if self.backgroundCallbackHandle != nil && !self.backgroundChannelReady {
        self.pendingFlutterMessages.append(message)
      } else {
        self.messageConnector.sendMessage(message)
      }
    }
  }
  
  /// sometimes - especially in release mode - the [discoveredPeripherals] is empty
  /// It can be refilled with the connected peripherals
  func repopulateDiscoveredPeripherals() {
    /// https://github.com/boskokg/flutter_blue_plus/blob/master/ios/Classes/FlutterBluePlusPlugin.m#L297
    let peripherals = manager.retrieveConnectedPeripherals(withServices: [CBUUID(string: "1800")])

		  sendFlutterMessage([
            "type": "repopulatePeripherals",
            "found": peripherals.count])

    for peripheral in peripherals {
      NSLog("peripheral: \(peripheral.name) \(peripheral.uuid.uuidString)");
      setDiscoveredPeripheral(peripheral)
    }
  }
  
  func getPeripheralById(_ deviceId : String, _ result:  @escaping FlutterResult) -> CBPeripheral? {
      if discoveredPeripherals.isEmpty {
        repopulateDiscoveredPeripherals();
      }
		  guard let peripheral = getDiscoveredPeripheral(deviceId) else {
        NSLog("failed to find id");
			  result(FlutterError(code: "IllegalArgument", message: "Unknown deviceId:\(deviceId)", details: nil))
			  return nil;
		  }       
      return peripheral;
  }

  // MARK: - Background State Restoration
  
  private var backgroundCallbackHandle: Int64?
  private let kBackgroundCallbackKey = "quick_blue_background_callback_handle"
  
  private func invokeBackgroundWakeCallback(deviceId: String, deviceName: String?, wakeType: String) {
    let timestamp = Int(Date().timeIntervalSince1970 * 1000)
    let payload: [String: Any] = [
      "deviceId": deviceId,
      "deviceName": deviceName as Any,
      "wakeType": wakeType,
      "associationId": nil as Int?,
      "timestamp": timestamp
    ]

    DispatchQueue.main.async {
      if self.backgroundChannelReady {
        self.backgroundChannel.invokeMethod("onPresenceEvent", arguments: payload)
      } else {
        self.pendingBackgroundEvents.append(payload)
      }
    }
  }

  private func flushPendingBackgroundEvents() {
    guard backgroundChannelReady, !pendingBackgroundEvents.isEmpty else {
      return
    }
    let events = pendingBackgroundEvents
    pendingBackgroundEvents.removeAll()
    for payload in events {
      backgroundChannel.invokeMethod("onPresenceEvent", arguments: payload)
    }
  }

  private func flushPendingFlutterMessages() {
    guard backgroundChannelReady, !pendingFlutterMessages.isEmpty else {
      return
    }
    let messages = pendingFlutterMessages
    pendingFlutterMessages.removeAll()
    for payload in messages {
      messageConnector.sendMessage(payload)
    }
  }
  
  private func invokeBackgroundStateRestorationCallback(restoredPeripherals: [String]) {
    // For backward compatibility, invoke for each restored peripheral
    for uuid in restoredPeripherals {
      let peripheral = discoveredPeripherals[uuid]
      invokeBackgroundWakeCallback(deviceId: uuid, deviceName: peripheral?.name, wakeType: "stateRestored")
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
	  switch call.method {
	  case "isBluetoothAvailable":
		  result(manager.state == .poweredOn)
    // ============ Background Presence API ============
      
    case "getBackgroundPresenceCapabilities":
      let systemVersion = UIDevice.current.systemVersion
      result([
        "isSupported": true,
        "requiresAssociation": false,
        "presenceObservationAvailable": true,
        "minimumOsVersion": "7.0",
        "currentOsVersion": systemVersion
      ])
      
    case "registerBackgroundWakeCallback":
      let arguments = call.arguments as! Dictionary<String, Any>
      let callbackHandle = arguments["callbackHandle"] as! Int
      backgroundCallbackHandle = Int64(callbackHandle)
      
      // Persist the callback handle for when app is woken from terminated state
      UserDefaults.standard.set(callbackHandle, forKey: kBackgroundCallbackKey)
      
      print("Registered background wake callback: callback=\(callbackHandle)")
      result(nil)
      
    case "associateDevice":
      // iOS doesn't require explicit association - just return success
      // The deviceId will be provided when starting observation
      result([
        "success": true,
        "deviceId": nil as String?,
        "deviceName": nil as String?,
        "associationId": nil as Int?
      ])
      
    case "startBackgroundPresenceObservation":
      let arguments = call.arguments as! Dictionary<String, Any>
      let deviceId = arguments["deviceId"] as! String
      
      // Save the UUID for restoration
      saveConnectedPeripheralUUID(deviceId)
      
      // Try to retrieve the peripheral and issue a pending connection
      if let uuid = UUID(uuidString: deviceId) {
        let peripherals = manager.retrievePeripherals(withIdentifiers: [uuid])
        if let peripheral = peripherals.first {
          discoveredPeripherals[deviceId] = peripheral
          peripheral.delegate = self
          manager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true
          ])
          print("Started background presence observation for \(deviceId)")
        } else {
          print("Warning: Peripheral not found for \(deviceId), saving UUID for future observation")
        }
      }
      result(nil)
      
    case "stopBackgroundPresenceObservation":
      let arguments = call.arguments as! Dictionary<String, Any>
      let deviceId = arguments["deviceId"] as! String
      
      // Remove from persistence
      removeConnectedPeripheralUUID(deviceId)
      
      // Cancel any pending connection
      if let peripheral = discoveredPeripherals[deviceId] {
        manager.cancelPeripheralConnection(peripheral)
      }
      
      print("Stopped background presence observation for \(deviceId)")
      result(nil)
      
    case "getBackgroundObservedDevices":
      let uuids = UserDefaults.standard.array(forKey: kConnectedPeripheralUUIDs) as? [String] ?? []
      let devices = uuids.map { uuid -> [String: Any?] in
        let peripheral = discoveredPeripherals[uuid]
        return [
          "success": true,
          "deviceId": uuid,
          "deviceName": peripheral?.name,
          "associationId": nil as Int?
        ]
      }
      result(devices)
      
    case "removeBackgroundObservation":
      let arguments = call.arguments as! Dictionary<String, Any>
      let deviceId = arguments["deviceId"] as! String
      
      // Remove from persistence
      removeConnectedPeripheralUUID(deviceId)
      
      // Cancel any pending connection
      if let peripheral = discoveredPeripherals[deviceId] {
        manager.cancelPeripheralConnection(peripheral)
        discoveredPeripherals.removeValue(forKey: deviceId)
      }
      
      print("Removed background observation for \(deviceId)")
      result(nil)
      
    case "setAutoBleCommandOnAppear":
      // iOS doesn't support auto BLE commands at the system level
      // The user should handle this in their background wake callback
      print("setAutoBleCommandOnAppear is not supported on iOS - handle in background wake callback")
      result(nil)
      
    case "clearAutoBleCommandOnAppear":
      // No-op on iOS
      result(nil)
	  case "startScan":
          let arguments = call.arguments as! Dictionary<String, Any>
          if let serviceId = arguments["serviceId"] as? String {
              manager.scanForPeripherals(withServices: [CBUUID(string: serviceId)])
          } else {
              manager.scanForPeripherals(withServices: nil)
          }
          
		  result(nil)
	  case "stopScan":
		  manager.stopScan()
		  result(nil)
	  case "connect":
		  let arguments = call.arguments as! Dictionary<String, Any>
		  let deviceId = arguments["deviceId"] as! String
      guard let peripheral = getPeripheralById(deviceId, result) else {
        return;
      }
		  peripheral.delegate = self
        manager.connect(peripheral, options: ["CBCentralManagerOptionShouldAutoReconnect": true])
		  result(nil)
	  case "disconnect":
		  let arguments = call.arguments as! Dictionary<String, Any>
		  let deviceId = arguments["deviceId"] as! String
      guard let peripheral = getPeripheralById(deviceId, result) else {
        sendFlutterMessage([
          "type" : "disconnecting",
          "deviceId": deviceId,
          "error": "failed to disconnect",
        ])
        return;
      }
    sendFlutterMessage([
      "type" : "disconnecting",
      "deviceId": peripheral.uuid.uuidString,
      "ConnectionState": "disconnecting",
    ])
    
    // Remove from persistence - this is an intentional disconnect
    removeConnectedPeripheralUUID(peripheral.uuid.uuidString)
    
		  if (peripheral.state != .disconnected) {
			  manager.cancelPeripheralConnection(peripheral)
		  }
		  result(nil)
	  case "discoverServices":
		  let arguments = call.arguments as! Dictionary<String, Any>
		  let deviceId = arguments["deviceId"] as! String
      guard let peripheral = getPeripheralById(deviceId, result) else {
        return;
      }
		  peripheral.discoverServices(nil)
		  result(nil)
	  case "setNotifiable":
		  let arguments = call.arguments as! Dictionary<String, Any>
		  let deviceId = arguments["deviceId"] as! String
		  let service = arguments["service"] as! String
		  let characteristic = arguments["characteristic"] as! String
		  let bleInputProperty = arguments["bleInputProperty"] as! String
      guard let peripheral = getPeripheralById(deviceId, result) else {
        return;
      }

		  peripheral.setNotifiable(bleInputProperty, for: characteristic, of: service)
		  result(nil)
	  case "requestMtu":
		  let arguments = call.arguments as! Dictionary<String, Any>
		  let deviceId = arguments["deviceId"] as! String
      guard let peripheral = getPeripheralById(deviceId, result) else {
        return;
      }

		  result(nil)
		  let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
		  print("peripheral.maximumWriteValueLengthForType:CBCharacteristicWriteWithoutResponse \(mtu)")
		  sendFlutterMessage([
            "type": "mtuChanged",
            "mtuConfig": mtu + GATT_HEADER_LENGTH])
    case "readRssi":
        let arguments = call.arguments as! Dictionary<String, Any>
        let deviceId = arguments["deviceId"] as! String
        guard let peripheral = getPeripheralById(deviceId, result) else {
          return;
        }
        peripheral.readRSSI()
        result(nil)
	  case "requestLatency":
          return
	  case "readValue":
		  let arguments = call.arguments as! Dictionary<String, Any>
		  let deviceId = arguments["deviceId"] as! String
		  let service = arguments["service"] as! String
		  let characteristic = arguments["characteristic"] as! String

      guard let peripheral = getPeripheralById(deviceId, result) else {
        return;
      }
		  let char = peripheral.getCharacteristic(characteristic, of: service)
		  if char != nil {
			  peripheral.readValue(for: char!)
		  }
		  result(nil)
	  case "writeValue":
		  let arguments = call.arguments as! Dictionary<String, Any>
		  let deviceId = arguments["deviceId"] as! String
		  let service = arguments["service"] as! String
		  let characteristic = arguments["characteristic"] as! String
		  let value = arguments["value"] as! FlutterStandardTypedData
		  let bleOutputProperty = arguments["bleOutputProperty"] as! String
      guard let peripheral = getPeripheralById(deviceId, result) else {
        return;
      }
		  let type = bleOutputProperty == "withoutResponse" ? CBCharacteristicWriteType.withoutResponse : CBCharacteristicWriteType.withResponse
		  let char = peripheral.getCharacteristic(characteristic, of: service)
		  if char != nil {
			  peripheral.writeValue(value.data, for: char!, type: type)
		  }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

func latencyFromInt(_ latency: Int) -> CBPeripheralManagerConnectionLatency {
  switch latency {
  case 0:
    return .low
  case 1:
    return .medium
  case 2:
    return .high
  default:
    return .low
  }
}

extension SwiftQuickBluePlugin: CBCentralManagerDelegate {
  public func centralManagerDidUpdateState(_ central: CBCentralManager) {
    print("centralManagerDidUpdateState \(central.state.rawValue)")
    
    // When Bluetooth is powered on, restore any pending connections from cold start
    if central.state == .poweredOn {
      restorePendingConnections()
    }
  }

  public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
    print("centralManager:didDiscoverPeripheral \(peripheral.name) \(peripheral.uuid.uuidString)")
    setDiscoveredPeripheral(peripheral)

    let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
    scanResultSink?([
      "name": peripheral.name ?? "",
      "deviceId": peripheral.uuid.uuidString,
      "manufacturerData": FlutterStandardTypedData(bytes: manufacturerData ?? Data()),
      "rssi": RSSI,
    ])
  }

  public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    print("centralManager:willRestoreState")

    // Resynchronize state immediately after restoration
    centralManagerDidUpdateState(central)
    
    // Extract restored peripherals from system
    if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
      var restoredUUIDs: [String] = []

      for peripheral in peripherals {
        setDiscoveredPeripheral(peripheral)
        peripheral.delegate = self
        restoredUUIDs.append(peripheral.uuid.uuidString)

        // Re-issue connect for pending connection behavior
        if peripheral.state != .connected {
          manager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true
          ])
        } else {
          // Rehydrate state for already connected peripherals
          centralManager(central, didConnect: peripheral)

          if let services = peripheral.services, !services.isEmpty {
            self.peripheral(peripheral, didDiscoverServices: nil)

            for service in services {
              if let characteristics = service.characteristics, !characteristics.isEmpty {
                self.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: nil)
                for characteristic in characteristics where characteristic.isNotifying {
                  self.peripheral(peripheral, didUpdateNotificationStateFor: characteristic, error: nil)
                }
              } else {
                peripheral.discoverCharacteristics(nil, for: service)
              }
            }
          } else {
            peripheral.discoverServices(nil)
          }
        }
      }
      
      // Notify Flutter side about restoration
      sendFlutterMessage([
        "type": "stateRestored",
        "restoredPeripherals": restoredUUIDs
      ])

      // Invoke background handler if registered
      invokeBackgroundStateRestorationCallback(restoredPeripherals: restoredUUIDs)
    }
  }

  public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    print("centralManager:didConnect \(peripheral.uuid.uuidString)")
    
    // Persist UUID for cold start restoration
    saveConnectedPeripheralUUID(peripheral.uuid.uuidString)
    
    sendFlutterMessage([
      "type" : "connected",
      "deviceId": peripheral.uuid.uuidString,
      "ConnectionState": "connected",
    ])
  }
  
  public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    print("centralManager:didDisconnectPeripheral: \(peripheral.uuid.uuidString) error: \(error)")
    sendFlutterMessage([
        "type" : "disconnected",
      "deviceId": peripheral.uuid.uuidString,
      "ConnectionState": "disconnected",
    ])
    
    if hasTrackedPeripheral(peripheral.uuid.uuidString) {
      // CRITICAL: Re-arm the pending connection for infinite connection loop
      // This ensures the OS continues looking for the device even when out of range
      manager.connect(peripheral, options: [
        CBConnectPeripheralOptionNotifyOnConnectionKey: true
      ])
    }
  }
}

extension SwiftQuickBluePlugin: FlutterStreamHandler {
  open func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    guard let args = arguments as? Dictionary<String, Any>, let name = args["name"] as? String else {
      return nil
    }
    print("QuickBlueMacosPlugin onListenWithArguments：\(name)")
    if name == "scanResult" {
      scanResultSink = events
    }
    return nil
  }

  open func onCancel(withArguments arguments: Any?) -> FlutterError? {
    guard let args = arguments as? Dictionary<String, Any>, let name = args["name"] as? String else {
      return nil
    }
    print("QuickBlueMacosPlugin onCancelWithArguments：\(name)")
    if name == "scanResult" {
      scanResultSink = nil
    }
    return nil
  }
}

extension SwiftQuickBluePlugin: CBPeripheralDelegate {
  public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    print("peripheral: \(peripheral.uuid.uuidString) didDiscoverServices: \(error)")
    for service in peripheral.services! {
      peripheral.discoverCharacteristics(nil, for: service)
    }
  }
    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
      print("peripheral:didReadRSSI (\(RSSI))")
      self.sendFlutterMessage([
        "type" : "rssiRead",
        "deviceId": peripheral.uuid.uuidString,
        "rssi": RSSI
      ])
    }
    
  public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    for characteristic in service.characteristics! {
      print("peripheral:didDiscoverCharacteristicsForService (\(service.uuid.uuidStr), \(characteristic.uuid.uuidStr)")
    }
    self.sendFlutterMessage([
      "type" : "serviceDiscovered",
      "deviceId": peripheral.uuid.uuidString,
      "ServiceState": "discovered",
      "service": service.uuid.uuidStr,
      "characteristics": service.characteristics!.map { $0.uuid.uuidStr }
    ])
  }
    
  public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    print("peripheral:didWriteValueForCharacteristic \(characteristic.uuid.uuidStr) \(characteristic.value as? NSData) error: \(error)")
    self.sendFlutterMessage([
    "type" : "characteristicWrite",
    "characteristic" : characteristic.uuid.uuidStr
    ])
  }
    
  public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    // print("peripheral:didUpdateValueForForCharacteristic \(characteristic.uuid) \(characteristic.value as! NSData) error: \(error)")
    self.sendFlutterMessage([
      "type" : "characteristicRead",
      "deviceId": peripheral.uuid.uuidString,
      "characteristicValue": [
        "characteristic": characteristic.uuid.uuidStr,
        "value": FlutterStandardTypedData(bytes: characteristic.value!)
      ]
    ])
  }

  public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
    guard characteristic.isNotifying else {
      return
    }
    sendFlutterMessage([
      "type": "characteristicChanged",
      "deviceId": peripheral.uuid.uuidString,
      "characteristic": characteristic.uuid.uuidStr
    ])
  }
}
