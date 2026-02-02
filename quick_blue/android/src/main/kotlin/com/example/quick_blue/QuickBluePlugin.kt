package com.example.quick_blue

import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.*
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.companion.AssociationInfo
import android.companion.AssociationRequest
import android.companion.BluetoothDeviceFilter
import android.companion.CompanionDeviceManager
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import androidx.annotation.NonNull
import androidx.annotation.RequiresApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.*
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.*
import java.util.concurrent.Executor
import java.util.regex.Pattern

private const val TAG = "QuickBluePlugin"

/** QuickBluePlugin */
@SuppressLint("MissingPermission")
class QuickBluePlugin: FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler,
    ActivityAware, PluginRegistry.ActivityResultListener {
    
    companion object {
        private const val REQUEST_CODE_ASSOCIATE = 42
        const val PREFS_NAME = "quick_blue_prefs"
        const val KEY_DISPATCHER_HANDLE = "dispatcher_handle"
        const val KEY_CALLBACK_HANDLE = "callback_handle"
        const val KEY_AUTO_BLE_SERVICE_UUID = "auto_ble_service_uuid"
        const val KEY_AUTO_BLE_CHARACTERISTIC_UUID = "auto_ble_characteristic_uuid"
        const val KEY_AUTO_BLE_COMMAND = "auto_ble_command"
    }
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var method : MethodChannel
  private lateinit var eventScanResult : EventChannel
  private lateinit var messageConnector: BasicMessageChannel<Any>

  // Activity for CDM association dialogs
  private var activity: Activity? = null
  private var activityBinding: ActivityPluginBinding? = null
  private var pendingResult: Result? = null
  private var companionDeviceManager: CompanionDeviceManager? = null
  private val mainHandler = Handler(Looper.getMainLooper())

  private val mainExecutor: Executor = Executor { command ->
      mainHandler.post(command)
  }

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
    
    // Initialize Companion Device Manager if available
    companionDeviceManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        context.getSystemService(Context.COMPANION_DEVICE_SERVICE) as? CompanionDeviceManager
    } else {
        null
    }
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
      
      // ============ Background Presence API (Companion Device Manager) ============
      
      "getBackgroundPresenceCapabilities" -> {
        handleGetBackgroundPresenceCapabilities(result)
      }
      "registerBackgroundWakeCallback" -> {
        handleRegisterBackgroundWakeCallback(call, result)
      }
      "associateDevice" -> {
        handleAssociateDevice(call, result)
      }
      "startBackgroundPresenceObservation" -> {
        handleStartBackgroundPresenceObservation(call, result)
      }
      "stopBackgroundPresenceObservation" -> {
        handleStopBackgroundPresenceObservation(call, result)
      }
      "getBackgroundObservedDevices" -> {
        handleGetBackgroundObservedDevices(result)
      }
      "removeBackgroundObservation" -> {
        handleRemoveBackgroundObservation(call, result)
      }
      "setAutoBleCommandOnAppear" -> {
        handleSetAutoBleCommandOnAppear(call, result)
      }
      "clearAutoBleCommandOnAppear" -> {
        handleClearAutoBleCommandOnAppear(result)
      }
      
      else -> {
        result.notImplemented()
      }
    }
  }
  
  // ============ Background Presence API Handlers ============
  
  private fun handleGetBackgroundPresenceCapabilities(result: Result) {
    val isSupported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && companionDeviceManager != null
    val presenceAvailable = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && companionDeviceManager != null
    
    result.success(mapOf(
      "isSupported" to isSupported,
      "requiresAssociation" to true,
      "presenceObservationAvailable" to presenceAvailable,
      "minimumOsVersion" to "26",
      "currentOsVersion" to Build.VERSION.SDK_INT.toString()
    ))
  }
  
    private fun handleRegisterBackgroundWakeCallback(call: MethodCall, result: Result) {
        val dispatcherHandle = call.argument<Number>("dispatcherHandle")?.toLong()
        val callbackHandle = call.argument<Number>("callbackHandle")?.toLong()
    
    Log.d(TAG, "Registering background wake callback - dispatcher: $dispatcherHandle, callback: $callbackHandle")
    
    if (dispatcherHandle == null || callbackHandle == null) {
      Log.e(TAG, "Invalid arguments - missing dispatcher or callback handle")
      result.error("INVALID_ARGUMENTS", "Missing dispatcher or callback handle", null)
      return
    }
    
        // Store handles in SharedPreferences for retrieval by the background service
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit()
            .putLong(KEY_DISPATCHER_HANDLE, dispatcherHandle)
            .putLong(KEY_CALLBACK_HANDLE, callbackHandle)
            .apply()
    
        Log.d(TAG, "Successfully registered background wake callback: dispatcher=$dispatcherHandle, callback=$callbackHandle")
        result.success(null)
    }
  
  @RequiresApi(Build.VERSION_CODES.O)
  private fun handleAssociateDevice(call: MethodCall, result: Result) {
    if (companionDeviceManager == null) {
      result.success(mapOf(
        "success" to false,
        "errorMessage" to "Companion Device Manager not available",
        "errorCode" to "CDM_UNAVAILABLE"
      ))
      return
    }
    
    val currentActivity = activity
    if (currentActivity == null) {
      result.success(mapOf(
        "success" to false,
        "errorMessage" to "No activity available",
        "errorCode" to "ACTIVITY_UNAVAILABLE"
      ))
      return
    }
    
    val namePattern = call.argument<String>("namePattern")
    val singleDevice = call.argument<Boolean>("singleDevice") ?: true
    
    if (namePattern == null) {
      result.success(mapOf(
        "success" to false,
        "errorMessage" to "namePattern is required",
        "errorCode" to "INVALID_ARGUMENTS"
      ))
      return
    }
    
    pendingResult = result
    
    try {
      // Build Bluetooth device filter with name pattern
      val deviceFilter = BluetoothDeviceFilter.Builder()
        .setNamePattern(Pattern.compile(namePattern))
        .build()
      
      // Build association request
      val associationRequest = AssociationRequest.Builder()
        .addDeviceFilter(deviceFilter)
        .setSingleDevice(singleDevice)
        .build()
      
      // Use the appropriate callback API based on Android version
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        associateApi33(associationRequest, currentActivity)
      } else {
        associateLegacy(associationRequest, currentActivity)
      }
    } catch (e: Exception) {
      Log.e(TAG, "Error starting association", e)
      pendingResult?.success(mapOf(
        "success" to false,
        "errorMessage" to e.message,
        "errorCode" to "ASSOCIATION_ERROR"
      ))
      pendingResult = null
    }
  }
  
  @RequiresApi(Build.VERSION_CODES.TIRAMISU)
  private fun associateApi33(request: AssociationRequest, activity: Activity) {
    companionDeviceManager?.associate(
      request,
      mainExecutor,
      object : CompanionDeviceManager.Callback() {
        override fun onAssociationPending(intentSender: IntentSender) {
          try {
            activity.startIntentSenderForResult(
              intentSender,
              REQUEST_CODE_ASSOCIATE,
              null, 0, 0, 0
            )
          } catch (e: IntentSender.SendIntentException) {
            Log.e(TAG, "Error launching association intent", e)
            pendingResult?.success(mapOf(
              "success" to false,
              "errorMessage" to e.message,
              "errorCode" to "INTENT_ERROR"
            ))
            pendingResult = null
          }
        }
        
        override fun onAssociationCreated(associationInfo: AssociationInfo) {
          Log.d(TAG, "Association created: id=${associationInfo.id}, mac=${associationInfo.deviceMacAddress}, name=${associationInfo.displayName}")
          handleAssociationResultApi33(associationInfo)
        }
        
        override fun onFailure(error: CharSequence?) {
          Log.e(TAG, "Association failed: $error, api=${Build.VERSION.SDK_INT}")
          pendingResult?.success(mapOf(
            "success" to false,
            "errorMessage" to error?.toString(),
            "errorCode" to "ASSOCIATION_FAILED"
          ))
          pendingResult = null
        }
      }
    )
  }
  
  @RequiresApi(Build.VERSION_CODES.O)
  @Suppress("DEPRECATION")
  private fun associateLegacy(request: AssociationRequest, activity: Activity) {
    // IMPORTANT: For legacy API (Android 8-12), CompanionDeviceManager.associate()
    // internally calls getActivity() on the callback's context. The CDM must be
    // obtained from the Activity context, NOT the Application context.
    val activityCdm = activity.getSystemService(Context.COMPANION_DEVICE_SERVICE) as? CompanionDeviceManager
    if (activityCdm == null) {
      Log.e(TAG, "Failed to get CompanionDeviceManager from activity context")
      pendingResult?.success(mapOf(
        "success" to false,
        "errorMessage" to "CompanionDeviceManager not available from activity",
        "errorCode" to "CDM_UNAVAILABLE"
      ))
      pendingResult = null
      return
    }
    
    activityCdm.associate(
      request,
      object : CompanionDeviceManager.Callback() {
        override fun onDeviceFound(chooserLauncher: IntentSender) {
          try {
            activity.startIntentSenderForResult(
              chooserLauncher,
              REQUEST_CODE_ASSOCIATE,
              null, 0, 0, 0
            )
          } catch (e: IntentSender.SendIntentException) {
            Log.e(TAG, "Error launching association intent", e)
            pendingResult?.success(mapOf(
              "success" to false,
              "errorMessage" to e.message,
              "errorCode" to "INTENT_ERROR"
            ))
            pendingResult = null
          }
        }
        
        override fun onFailure(error: CharSequence?) {
          Log.e(TAG, "Association failed (legacy): $error, api=${Build.VERSION.SDK_INT}")
          pendingResult?.success(mapOf(
            "success" to false,
            "errorMessage" to error?.toString(),
            "errorCode" to "ASSOCIATION_FAILED"
          ))
          pendingResult = null
        }
      },
      mainHandler
    )
  }
  
  @RequiresApi(Build.VERSION_CODES.TIRAMISU)
  private fun handleAssociationResultApi33(associationInfo: AssociationInfo) {
    val resultMap = mutableMapOf<String, Any?>()
    resultMap["success"] = true
    resultMap["associationId"] = associationInfo.id
    
    // Get device address based on API level
    val deviceMacAddress = associationInfo.deviceMacAddress
    if (deviceMacAddress != null) {
      resultMap["deviceId"] = deviceMacAddress.toString().uppercase()
    }
    
    resultMap["deviceName"] = associationInfo.displayName?.toString()
    
    pendingResult?.success(resultMap)
    pendingResult = null
  }
  
  private fun handleStartBackgroundPresenceObservation(call: MethodCall, result: Result) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
      Log.e(TAG, "Presence observation requires Android 12+ (API 31), current API: ${Build.VERSION.SDK_INT}")
      result.error(
        "API_LEVEL_ERROR",
        "Presence observation requires Android 12 (API 31) or higher",
        null
      )
      return
    }
    
    val deviceId = call.argument<String>("deviceId")
    val associationId = call.argument<Int>("associationId")
    
    Log.d(TAG, "Starting background presence observation - deviceId: $deviceId, associationId: $associationId, api: ${Build.VERSION.SDK_INT}")
    
    if (deviceId == null && associationId == null) {
      Log.e(TAG, "Invalid arguments - deviceId or associationId is required")
      result.error("INVALID_ARGUMENTS", "deviceId or associationId is required", null)
      return
    }
    
    try {
      val macIsValid = deviceId?.let { isValidMacAddress(it) } ?: false

      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && associationId != null && !macIsValid) {
        Log.d(TAG, "Starting presence observation using association ID: $associationId")
        companionDeviceManager?.startObservingDevicePresence(associationId.toString())
      } else if (deviceId != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        Log.d(TAG, "Starting presence observation using MAC address: $deviceId")
        companionDeviceManager?.startObservingDevicePresence(deviceId)
      } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && associationId != null) {
        Log.d(TAG, "Starting presence observation using association ID fallback: $associationId")
        companionDeviceManager?.startObservingDevicePresence(associationId.toString())
      }

      Log.d(TAG, "Successfully started presence observation for $deviceId (id=$associationId)")
      result.success(null)
    } catch (e: Exception) {
      Log.e(TAG, "Error starting presence observation", e)
      result.error("OBSERVATION_ERROR", e.message, null)
    }
  }
  
  private fun handleStopBackgroundPresenceObservation(call: MethodCall, result: Result) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
      Log.e(TAG, "Presence observation requires Android 12+ (API 31), current API: ${Build.VERSION.SDK_INT}")
      result.error(
        "API_LEVEL_ERROR",
        "Presence observation requires Android 12 (API 31) or higher",
        null
      )
      return
    }
    
    val deviceId = call.argument<String>("deviceId")
    val associationId = call.argument<Int>("associationId")
    
    Log.d(TAG, "Stopping background presence observation - deviceId: $deviceId, associationId: $associationId, api: ${Build.VERSION.SDK_INT}")
    
    if (deviceId == null && associationId == null) {
      Log.e(TAG, "Invalid arguments - deviceId or associationId is required")
      result.error("INVALID_ARGUMENTS", "deviceId or associationId is required", null)
      return
    }
    
    try {
      val macIsValid = deviceId?.let { isValidMacAddress(it) } ?: false

      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && associationId != null && !macIsValid) {
        Log.d(TAG, "Stopping presence observation using association ID: $associationId")
        companionDeviceManager?.stopObservingDevicePresence(associationId.toString())
      } else if (deviceId != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        Log.d(TAG, "Stopping presence observation using MAC address: $deviceId")
        companionDeviceManager?.stopObservingDevicePresence(deviceId)
      } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && associationId != null) {
        Log.d(TAG, "Stopping presence observation using association ID fallback: $associationId")
        companionDeviceManager?.stopObservingDevicePresence(associationId.toString())
      }

      Log.d(TAG, "Successfully stopped presence observation for $deviceId (id=$associationId)")
      result.success(null)
    } catch (e: Exception) {
      Log.e(TAG, "Error stopping presence observation", e)
      result.error("OBSERVATION_ERROR", e.message, null)
    }
  }

  private fun isValidMacAddress(value: String): Boolean {
    val normalized = value.trim().uppercase()
    val regex = Regex("^([0-9A-F]{2}:){5}[0-9A-F]{2}$")
    return regex.matches(normalized)
  }
  
  @RequiresApi(Build.VERSION_CODES.O)
  private fun handleGetBackgroundObservedDevices(result: Result) {
    if (companionDeviceManager == null) {
      result.success(emptyList<Map<String, Any?>>())
      return
    }
    
    try {
      val associations = mutableListOf<Map<String, Any?>>()
      
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        // API 33+ returns AssociationInfo objects
        companionDeviceManager?.myAssociations?.forEach { info ->
          associations.add(mapOf(
            "success" to true,
            "associationId" to info.id,
            "deviceId" to info.deviceMacAddress?.toString()?.uppercase(),
            "deviceName" to info.displayName?.toString()
          ))
        }
      } else {
        // Legacy API returns MAC addresses
        @Suppress("DEPRECATION")
        companionDeviceManager?.associations?.forEachIndexed { index, macAddress ->
          associations.add(mapOf(
            "success" to true,
            "associationId" to index,
            "deviceId" to macAddress.uppercase(),
            "deviceName" to null
          ))
        }
      }
      
      result.success(associations)
    } catch (e: Exception) {
      Log.e(TAG, "Error getting associations", e)
      result.error("ASSOCIATIONS_ERROR", e.message, null)
    }
  }
  
  @RequiresApi(Build.VERSION_CODES.O)
  private fun handleRemoveBackgroundObservation(call: MethodCall, result: Result) {
    if (companionDeviceManager == null) {
      result.error("CDM_UNAVAILABLE", "Companion Device Manager not available", null)
      return
    }
    
    val associationId = call.argument<Int>("associationId")
    val deviceId = call.argument<String>("deviceId")
    
    if (associationId == null && deviceId == null) {
      result.error("INVALID_ARGUMENTS", "associationId or deviceId is required", null)
      return
    }
    
    try {
      // Stop observation first if on Android 12+
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        try {
          if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && associationId != null) {
            companionDeviceManager?.stopObservingDevicePresence(associationId.toString())
          } else if (deviceId != null) {
            companionDeviceManager?.stopObservingDevicePresence(deviceId)
          }
        } catch (e: Exception) {
          Log.w(TAG, "Error stopping observation during removal", e)
        }
      }
      
      // Disassociate
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && associationId != null) {
        companionDeviceManager?.disassociate(associationId)
      } else if (associationId != null) {
        // Legacy: need to find the MAC address by index
        @Suppress("DEPRECATION")
        val associations = companionDeviceManager?.associations
        if (associations != null && associationId < associations.size) {
          @Suppress("DEPRECATION")
          companionDeviceManager?.disassociate(associations[associationId])
        }
      }
      
      Log.d(TAG, "Removed background observation for associationId=$associationId deviceId=$deviceId")
      result.success(null)
    } catch (e: Exception) {
      Log.e(TAG, "Error removing background observation", e)
      result.error("DISASSOCIATE_ERROR", e.message, null)
    }
  }
  
  private fun handleSetAutoBleCommandOnAppear(call: MethodCall, result: Result) {
    val serviceUuid = call.argument<String>("serviceUuid")
    val characteristicUuid = call.argument<String>("characteristicUuid")
    val command = call.argument<List<Int>>("command")
    
    Log.d(TAG, "Setting auto BLE command - service: $serviceUuid, char: $characteristicUuid, command size: ${command?.size}")
    
    if (serviceUuid.isNullOrBlank() || characteristicUuid.isNullOrBlank() || command == null) {
      Log.e(TAG, "Invalid arguments - serviceUuid, characteristicUuid, and command are required")
      result.error("INVALID_ARGUMENTS", "serviceUuid, characteristicUuid, and command are required", null)
      return
    }
    
    val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    prefs.edit()
      .putString(KEY_AUTO_BLE_SERVICE_UUID, serviceUuid)
      .putString(KEY_AUTO_BLE_CHARACTERISTIC_UUID, characteristicUuid)
      .putString(KEY_AUTO_BLE_COMMAND, command.joinToString(","))
      .apply()
    
    Log.d(TAG, "Successfully configured auto BLE command: service=$serviceUuid characteristic=$characteristicUuid bytes=${command.size}")
    result.success(null)
  }
  
  private fun handleClearAutoBleCommandOnAppear(result: Result) {
    Log.d(TAG, "Clearing auto BLE command configuration")
    val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    prefs.edit()
      .remove(KEY_AUTO_BLE_SERVICE_UUID)
      .remove(KEY_AUTO_BLE_CHARACTERISTIC_UUID)
      .remove(KEY_AUTO_BLE_COMMAND)
      .apply()
    
    Log.d(TAG, "Successfully cleared auto BLE command")
    result.success(null)
  }
  
  // ============ ActivityAware Implementation ============
  
  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding.activity
    activityBinding = binding
    binding.addActivityResultListener(this)
  }
  
  override fun onDetachedFromActivityForConfigChanges() {
    activityBinding?.removeActivityResultListener(this)
    activity = null
    activityBinding = null
  }
  
  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    activity = binding.activity
    activityBinding = binding
    binding.addActivityResultListener(this)
  }
  
  override fun onDetachedFromActivity() {
    activityBinding?.removeActivityResultListener(this)
    activity = null
    activityBinding = null
  }
  
  // ============ ActivityResultListener Implementation ============
  
  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
    if (requestCode != REQUEST_CODE_ASSOCIATE) {
      return false
    }
    
    if (resultCode != Activity.RESULT_OK) {
      pendingResult?.success(mapOf(
        "success" to false,
        "errorMessage" to "User cancelled the association",
        "errorCode" to "USER_CANCELLED"
      ))
      pendingResult = null
      return true
    }
    
    if (data == null) {
      pendingResult?.success(mapOf(
        "success" to false,
        "errorMessage" to "No data returned from association",
        "errorCode" to "NO_DATA"
      ))
      pendingResult = null
      return true
    }
    
    try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        // API 33+: Get AssociationInfo from result
        val associationInfo = data.getParcelableExtra(
          CompanionDeviceManager.EXTRA_ASSOCIATION,
          AssociationInfo::class.java
        )
        if (associationInfo != null) {
          handleAssociationResultApi33(associationInfo)
        } else {
          pendingResult?.success(mapOf(
            "success" to false,
            "errorMessage" to "No association info returned",
            "errorCode" to "NO_ASSOCIATION"
          ))
          pendingResult = null
        }
      } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        // API 26-32: Get device from result
        @Suppress("DEPRECATION")
        val device = data.getParcelableExtra<BluetoothDevice>(
          CompanionDeviceManager.EXTRA_DEVICE
        )
        if (device != null) {
          val resultMap = mutableMapOf<String, Any?>()
          resultMap["success"] = true
          resultMap["deviceId"] = device.address
          resultMap["deviceName"] = device.name
          // Legacy API doesn't have association ID, use a placeholder
          resultMap["associationId"] = device.address.hashCode()
          pendingResult?.success(resultMap)
        } else {
          pendingResult?.success(mapOf(
            "success" to false,
            "errorMessage" to "No device returned",
            "errorCode" to "NO_DEVICE"
          ))
        }
        pendingResult = null
      }
    } catch (e: Exception) {
      Log.e(TAG, "Error processing association result", e)
      pendingResult?.success(mapOf(
        "success" to false,
        "errorMessage" to e.message,
        "errorCode" to "RESULT_ERROR"
      ))
      pendingResult = null
    }
    
    return true
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
