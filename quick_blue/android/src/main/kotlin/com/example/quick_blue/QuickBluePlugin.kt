package com.example.quick_blue

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import androidx.annotation.NonNull
import androidx.annotation.RequiresApi;
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.*
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.*

private const val TAG = "QuickBluePlugin"

/** QuickBluePlugin */
@SuppressLint("MissingPermission")
class QuickBluePlugin: FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var method : MethodChannel
  private lateinit var eventScanResult : EventChannel
  private lateinit var messageConnector: BasicMessageChannel<Any>

  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    pluginBinding = flutterPluginBinding;
    method = MethodChannel(flutterPluginBinding.binaryMessenger, "quick_blue/method")
    eventScanResult = EventChannel(flutterPluginBinding.binaryMessenger, "quick_blue/event.scanResult")
    messageConnector = BasicMessageChannel(flutterPluginBinding.binaryMessenger, "quick_blue/message.connector", StandardMessageCodec.INSTANCE)

    method.setMethodCallHandler(this)
    eventScanResult.setStreamHandler(this)

    context = flutterPluginBinding.applicationContext
    mainThreadHandler = Handler(Looper.getMainLooper())
    bluetoothManager = flutterPluginBinding.applicationContext.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    context.registerReceiver(
      bluetoothStateReceiver,
      IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
    )
    bluetoothStateReceiverRegistered = true
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    if (bluetoothStateReceiverRegistered) {
      context.unregisterReceiver(bluetoothStateReceiver)
      bluetoothStateReceiverRegistered = false
    }

    bluetoothManager.adapter.bluetoothLeScanner?.stopScan(scanCallback)

    eventScanResult.setStreamHandler(null)
    //method.setMethodCallHandler(null)
  }

  private lateinit var context: Context
  private lateinit var mainThreadHandler: Handler
  private lateinit var bluetoothManager: BluetoothManager
  private lateinit var pluginBinding: FlutterPlugin.FlutterPluginBinding
  private var bluetoothStateReceiverRegistered = false

  private val bluetoothStateReceiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
      if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return

      when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
        BluetoothAdapter.STATE_ON -> sendBluetoothAvailability(true)
        BluetoothAdapter.STATE_OFF -> sendBluetoothAvailability(false)
      }
    }
  }


  private val knownGatts = mutableListOf<BluetoothGatt>()
  private val pendingWrites = mutableMapOf<BluetoothGatt, Result>()
  private val pendingNotifications = mutableMapOf<BluetoothGatt, Result>()

  private fun awaitGatt(gatt: BluetoothGatt, pending: MutableMap<BluetoothGatt, Result>, result: Result) {
    pending[gatt] = result
    mainThreadHandler.postDelayed({
      if (pending[gatt] === result) {
        pending.remove(gatt)
        result.error("GattTimeout", "GATT operation did not complete", null)
      }
    }, 5000)
  }

  private val knownServicesWithCharacteristics :
          MutableList<Pair<String,Pair<BluetoothGattService,List<BluetoothGattCharacteristic>>>> = mutableListOf();

  private fun sendMessage(messageChannel: BasicMessageChannel<Any>, message: Map<String, Any>) {
    mainThreadHandler.post { messageChannel.send(message) }
  }

  private fun sendBluetoothAvailability(available: Boolean) {
    sendMessage(messageConnector, mapOf(
      "type" to "bluetoothAvailabilityChanged",
      "available" to available
    ))
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    when (call.method) {
      "reinit" -> {
        bluetoothManager = pluginBinding.applicationContext.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
      }
      "isBluetoothAvailable" -> {
        result.success(bluetoothManager.adapter.isEnabled)
      }
      "startScan" -> {
        var filterBuilder = ScanFilter.Builder();
        var settingsBuilder = ScanSettings.Builder();
        val serviceUUID = ParcelUuid.fromString(call.argument<String>("serviceId")!!);
        filterBuilder.setServiceUuid(serviceUUID);
        var filter = filterBuilder.build();
        var settings = settingsBuilder.build();
        bluetoothManager.adapter.bluetoothLeScanner?.startScan(
          listOf(filter),
          settings,
          scanCallback)
        result.success(null)
      }
      "stopScan" -> {
        bluetoothManager.adapter.bluetoothLeScanner?.stopScan(scanCallback)
        result.success(null)
      }
      "autoConnect" -> {
        val deviceId = call.argument<String>("deviceId")!!
        if (knownGatts.find { it.device.address == deviceId } != null) {
          return result.success(null)
        }
        val remoteDevice = bluetoothManager.adapter.getRemoteDevice(deviceId)
        val gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
          remoteDevice.connectGatt(context, true, gattCallback, BluetoothDevice.TRANSPORT_LE)
        } else {
          remoteDevice.connectGatt(context, true, gattCallback)
        }
        knownGatts.add(gatt)
        result.success(null)
        // TODO connecting

      }
      "connect" -> {
        val deviceId = call.argument<String>("deviceId")!!
        if (knownGatts.find { it.device.address == deviceId } != null) {
          return result.success(null)
        }
        val remoteDevice = bluetoothManager.adapter.getRemoteDevice(deviceId)
        val gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
          remoteDevice.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        } else {
          remoteDevice.connectGatt(context, false, gattCallback)
        }
        knownGatts.add(gatt)
        result.success(null)
        // TODO connecting
      }
      "disconnect" -> {
        val deviceId = call.argument<String>("deviceId")!!
        val gatt = knownGatts.find { it.device.address == deviceId }
                ?: return result.error("IllegalArgument", "Unknown deviceId: $deviceId", null)
        cleanConnection(gatt)
        result.success(null)
        //FIXME If `disconnect` is called before BluetoothGatt.STATE_CONNECTED
        // there will be no `disconnected` message any more
      }
      "discoverServices" -> {
        val deviceId = call.argument<String>("deviceId")!!
        val gatt = knownGatts.find { it.device.address == deviceId }
                ?: return result.error("IllegalArgument", "Unknown deviceId: $deviceId", null)

        var success = gatt.discoverServices()
        sendMessage(messageConnector, mapOf(
          "type" to "servicesDiscovered",
          "success" to success
        ))
        result.success(null)
      }
      "setNotifiable" -> {
        val deviceId = call.argument<String>("deviceId")!!
        val service = call.argument<String>("service")!!
        val characteristic = call.argument<String>("characteristic")!!
        val bleInputProperty = call.argument<String>("bleInputProperty")!!
        val gatt = knownGatts.find { it.device.address == deviceId }
                ?: return result.error("IllegalArgument", "Unknown deviceId: $deviceId", null)
        if (pendingNotifications.containsKey(gatt) || pendingWrites.containsKey(gatt)) {
          return result.error("GattBusy", "Another GATT operation is pending", null)
        }
        val char = gatt.recoveryCharacteristic(service to characteristic)
          ?: return result.error("CharacteristicUnavailable", characteristic, null)
        val descriptor = char.getDescriptor(DESC__CLIENT_CHAR_CONFIGURATION)
          ?: return result.error("DescriptorUnavailable", characteristic, null)
        descriptor.value = when (bleInputProperty) {
          "notification" -> BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
          "indication" -> BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
          else -> BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
        }
        awaitGatt(gatt, pendingNotifications, result)
        if (!gatt.setCharacteristicNotification(char, bleInputProperty != "disabled") || !gatt.writeDescriptor(descriptor)) {
          pendingNotifications.remove(gatt)
          result.error("GattBusy", "Notification descriptor write was rejected", null)
        }
      }
      "requestMtu" -> {
        val deviceId = call.argument<String>("deviceId")!!
        val expectedMtu = call.argument<Int>("expectedMtu")!!
        val gatt = knownGatts.find { it.device.address == deviceId }
                ?: return result.error("IllegalArgument", "Unknown deviceId: $deviceId", null)
        gatt.requestMtu(expectedMtu)
        result.success(null)
      }
      "requestLatency" -> {
        val deviceId = call.argument<String>("deviceId")!!
        val priority = call.argument<Int>("priority")!!
        val gatt = knownGatts.find { it.device.address == deviceId }
                ?: return result.error("IllegalArgument", "Unknown deviceId: $deviceId", null)
        gatt.requestConnectionPriority(priority)
        result.success(null)
      }
      "readRssi" -> {
        val deviceId = call.argument<String>("deviceId")!!
        val gatt = knownGatts.find { it.device.address == deviceId }
                ?: return result.error("IllegalArgument", "Unknown deviceId: $deviceId", null)
        val rssi = gatt.readRemoteRssi()
        result.success(rssi);
        
      }
      "readValue" -> {
        val deviceId = call.argument<String>("deviceId")!!
        val service = call.argument<String>("service")!!
        val characteristic = call.argument<String>("characteristic")!!
        val gatt = knownGatts.find { it.device.address == deviceId }
                ?: return result.error("IllegalArgument", "Unknown deviceId: $deviceId", null)
        val readResult = gatt.recoveryCharacteristic(service to characteristic)?.let {
          gatt.readCharacteristic(it)
        }
        if (readResult == true)
          result.success(null)
        else
          result.error("read characteristic unavailable ${service} ${characteristic}", null, null)
      }
      "writeValue" -> {
        val deviceId = call.argument<String>("deviceId")!!
        val service = call.argument<String>("service")!!
        val characteristic = call.argument<String>("characteristic")!!
        val value = call.argument<ByteArray>("value")!!
        val gatt = knownGatts.find { it.device.address == deviceId }
                ?: return result.error("IllegalArgument", "Unknown deviceId: $deviceId", null)

        if (pendingNotifications.containsKey(gatt) || pendingWrites.containsKey(gatt)) {
          return result.error("GattBusy", "Another GATT operation is pending", null)
        }
        val char = gatt.recoveryCharacteristic(service to characteristic)
          ?: return result.error("CharacteristicUnavailable", characteristic, null)
        char.writeType = if (call.argument<String>("bleOutputProperty") == "withoutResponse") {
          BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        } else {
          BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        }
        char.value = value
        awaitGatt(gatt, pendingWrites, result)
        if (!gatt.writeCharacteristic(char)) {
          pendingWrites.remove(gatt)
          result.error("GattBusy", "Characteristic write was rejected", null)
        }
        return;
      }
      else -> {
        result.notImplemented()
      }
    }
  }

  private fun cleanConnection(gatt: BluetoothGatt) {
    val wasCurrent = knownGatts.remove(gatt)
    mainThreadHandler.post {
      pendingWrites.remove(gatt)?.error("Disconnected", "Connection closed during write", null)
      pendingNotifications.remove(gatt)?.error("Disconnected", "Connection closed during subscription", null)
    }
    if (!wasCurrent) return
    var servicesToRemove = knownServicesWithCharacteristics.filter {
      it.first == gatt.device.address
    }
    knownServicesWithCharacteristics.removeAll(servicesToRemove)
    gatt.disconnect()
    gatt.close()
  }

  private val scanCallback = object : ScanCallback() {
    override fun onScanFailed(errorCode: Int) {
      Log.v(TAG, "onScanFailed: $errorCode")
        sendMessage(messageConnector, mapOf(
          "type" to "scanFailed",
          "errorCode" to errorCode,
        ))
    }

    override fun onScanResult(callbackType: Int, result: ScanResult) {
      scanResultSink?.success(mapOf<String, Any>(
              "type" to "scanResult",
              "name" to (result.device.name ?: ""),
              "deviceId" to result.device.address,
              "manufacturerDataHead" to (result.recoveryManufacturerDataHead ?: byteArrayOf()),
              "rssi" to result.rssi
      ))
    }

    override fun onBatchScanResults(results: MutableList<ScanResult>?) {
      Log.v(TAG, "onBatchScanResults: $results")
    }
  }

  private var scanResultSink: EventChannel.EventSink? = null

  override fun onListen(args: Any?, eventSink: EventChannel.EventSink?) {
    val map = args as? Map<String, Any> ?: return
    when (map["name"]) {
      "scanResult" -> scanResultSink = eventSink
    }
  }

  override fun onCancel(args: Any?) {
    val map = args as? Map<String, Any> ?: return
    when (map["name"]) {
      "scanResult" -> scanResultSink = null
    }
  }

  private val gattCallback = object : BluetoothGattCallback() {
    override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
      if (!knownGatts.contains(gatt)) return
      Log.v(TAG, "onConnectionStateChange: device(${gatt.device.address}) status($status), newState($newState)")
      if (newState == BluetoothGatt.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
        sendMessage(messageConnector, mapOf(
          "type" to "connected",
          "deviceId" to gatt.device.address,
          "ConnectionState" to "connected"
        ))
      } else {
        cleanConnection(gatt)
        sendMessage(messageConnector, mapOf(
          "type" to "disconnected",
          "deviceId" to gatt.device.address,
          "ConnectionState" to "disconnected"
        ))
      }
    }

  override fun onReadRemoteRssi(gatt : BluetoothGatt, rssi : Int, status : Int){
    if (status == BluetoothGatt.GATT_SUCCESS) {
    sendMessage(messageConnector, mapOf(
      "type" to "rssiRead",
      "deviceId" to gatt.device.address,
      "rssi" to rssi,
      "statis" to status
    ))
    }
  }

    override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
      if (!knownGatts.contains(gatt)) return
      Log.v(TAG, "onServicesDiscovered ${gatt.device.address} $status")
      if (status != BluetoothGatt.GATT_SUCCESS) return

      gatt.services?.forEach { service ->
        Log.v(TAG, "Service " + service.uuid)

        knownServicesWithCharacteristics.add(gatt.device.address to (service to service.characteristics))

        service.characteristics.forEach { characteristic ->
          Log.v(TAG, "    Characteristic ${characteristic.uuid}")
          characteristic.descriptors.forEach {
            Log.v(TAG, "        Descriptor ${it.uuid}")
          }
        }

        sendMessage(messageConnector, mapOf(
        "type" to "serviceDiscovered",
          "deviceId" to gatt.device.address,
          "ServiceState" to "discovered",
          "service" to service.uuid.toString(),
          "characteristics" to service.characteristics.map { it.uuid.toString() }
        ))
      }
    }

    override fun onMtuChanged(gatt: BluetoothGatt?, mtu: Int, status: Int) {
      if (status == BluetoothGatt.GATT_SUCCESS) {
        sendMessage(messageConnector, mapOf(
          "type" to "mtuChanged",
          "mtuConfig" to mtu,
          "status" to status,
        ))
      }
    }

    override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
      Log.v(TAG, "onCharacteristicRead ${characteristic.uuid}, ${characteristic.value.contentToString()}")
      sendMessage(messageConnector, mapOf(
        "type" to "characteristicRead",
        "deviceId" to gatt.device.address,
        "characteristicValue" to mapOf(
          "characteristic" to characteristic.uuid.toString(),
          "value" to characteristic.value
        )
      ))
    }

    override fun onCharacteristicWrite(gatt: BluetoothGatt?, characteristic: BluetoothGattCharacteristic, status: Int) {
      if (gatt == null || !knownGatts.contains(gatt)) return
      mainThreadHandler.post {
        pendingWrites.remove(gatt)?.let { result ->
          if (status == BluetoothGatt.GATT_SUCCESS) result.success(null)
          else result.error("GattWriteFailed", "GATT status $status", null)
        }
      }
      Log.v(TAG, "onCharacteristicWrite ${characteristic.uuid}, ${characteristic.value.contentToString()} $status")
      sendMessage(messageConnector, mapOf(
        "type" to "characteristicWrite",
        "deviceId" to gatt?.device?.address.toString(),
        "characteristic" to characteristic.getUuid().toString(),
        "value" to characteristic.value,
        "status" to status
      ))
    }

    override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
      if (!knownGatts.contains(gatt)) return
      sendMessage(messageConnector, mapOf(
        "type" to "characteristicChanged",
        "deviceId" to gatt.device.address,
        "characteristicValue" to mapOf(
          "characteristic" to characteristic.uuid.toString(),
          "value" to characteristic.value
        )
      ))
    }
    override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
      mainThreadHandler.post {
        pendingNotifications.remove(gatt)?.let { result ->
          if (status == BluetoothGatt.GATT_SUCCESS) result.success(null)
          else result.error("GattSubscriptionFailed", "GATT status $status", null)
        }
      }
    }
  }
}

private val ScanResult.recoveryManufacturerDataHead: ByteArray?
  get() {
    val sparseArray = scanRecord?.manufacturerSpecificData ?: return null
    if (sparseArray.size() == 0) return null

    return sparseArray.keyAt(0).toShort().recoveryBytes() + sparseArray.valueAt(0)
  }

private fun Short.recoveryBytes(byteOrder: ByteOrder = ByteOrder.LITTLE_ENDIAN): ByteArray =
        ByteBuffer.allocate(2 /*Short.SIZE_BYTES*/).order(byteOrder).putShort(this).array()

private fun BluetoothGatt.recoveryCharacteristic(serviceCharacteristic: Pair<String, String>) =
        getService(UUID.fromString(serviceCharacteristic.first))?.getCharacteristic(UUID.fromString(serviceCharacteristic.second))

private val DESC__CLIENT_CHAR_CONFIGURATION = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
