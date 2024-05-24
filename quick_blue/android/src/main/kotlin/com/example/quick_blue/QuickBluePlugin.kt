package com.example.quick_blue

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
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
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    bluetoothManager.adapter.bluetoothLeScanner?.stopScan(scanCallback)

    eventScanResult.setStreamHandler(null)
    //method.setMethodCallHandler(null)
  }

  private lateinit var context: Context
  private lateinit var mainThreadHandler: Handler
  private lateinit var bluetoothManager: BluetoothManager
  private lateinit var pluginBinding: FlutterPlugin.FlutterPluginBinding


  private val knownGatts = mutableListOf<BluetoothGatt>()

  private val knownServicesWithCharacteristics :
          MutableList<Pair<String,Pair<BluetoothGattService,List<BluetoothGattCharacteristic>>>> = mutableListOf();

  private fun sendMessage(messageChannel: BasicMessageChannel<Any>, message: Map<String, Any>) {
    mainThreadHandler.post { messageChannel.send(message) }
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
        gatt.setNotifiable(service to characteristic, bleInputProperty)
        result.success(null)
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
        val readResult = gatt.getCharacteristic(service to characteristic)?.let {
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

        val serviceObj : BluetoothGattService = gatt.getService(UUID.fromString(service))!!

        var pair : Pair<BluetoothGattService, List<BluetoothGattCharacteristic>>? = knownServicesWithCharacteristics.filter {
          it.first == deviceId && it.second.first == serviceObj
        }?.first()?.second

        pair?.let {
          it.second.filter {
            it.getUuid() == UUID.fromString(characteristic)
          }.first()?.let {
            it.value = value
            val response = gatt.writeCharacteristic(it);
            if (response) {
              result.success(null)
            } else {
              result.error("Write characteristic unavailable ${service} ${characteristic}", null, null)
            }
          }
        }
        return;
      }
      else -> {
        result.notImplemented()
      }
    }
  }

  private fun cleanConnection(gatt: BluetoothGatt) {
    knownGatts.remove(gatt)
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
              "manufacturerDataHead" to (result.manufacturerDataHead ?: byteArrayOf()),
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
      sendMessage(messageConnector, mapOf(
        "type" to "characteristicChanged",
        "deviceId" to gatt.device.address,
        "characteristicValue" to mapOf(
          "characteristic" to characteristic.uuid.toString(),
          "value" to characteristic.value
        )
      ))
    }
  }
}

val ScanResult.manufacturerDataHead: ByteArray?
  get() {
    val sparseArray = scanRecord?.manufacturerSpecificData ?: return null
    if (sparseArray.size() == 0) return null

    return sparseArray.keyAt(0).toShort().toByteArray() + sparseArray.valueAt(0)
  }

fun Short.toByteArray(byteOrder: ByteOrder = ByteOrder.LITTLE_ENDIAN): ByteArray =
        ByteBuffer.allocate(2 /*Short.SIZE_BYTES*/).order(byteOrder).putShort(this).array()

fun BluetoothGatt.getCharacteristic(serviceCharacteristic: Pair<String, String>) =
        getService(UUID.fromString(serviceCharacteristic.first)).getCharacteristic(UUID.fromString(serviceCharacteristic.second))

private val DESC__CLIENT_CHAR_CONFIGURATION = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

fun BluetoothGatt.setNotifiable(serviceCharacteristic: Pair<String, String>, bleInputProperty: String) {
  val descriptor = getCharacteristic(serviceCharacteristic).getDescriptor(DESC__CLIENT_CHAR_CONFIGURATION)
  val (value, enable) = when (bleInputProperty) {
    "notification" -> BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE to true
    "indication" -> BluetoothGattDescriptor.ENABLE_INDICATION_VALUE to true
    else -> BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE to false
  }
  descriptor.value = value
  setCharacteristicNotification(descriptor.characteristic, enable) && writeDescriptor(descriptor)
}
