package com.example.quick_blue

import android.annotation.SuppressLint
import android.companion.AssociationInfo
import android.companion.CompanionDeviceService
import android.content.Context
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterCallbackInformation
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.UUID

/**
 * CompanionPresenceService
 *
 * A system-level service that extends Android's CompanionDeviceService to receive
 * device presence callbacks even when the app is terminated.
 *
 * This service implements the "Background Isolate Bridge" pattern:
 * 1. When a device appears/disappears, Android wakes this service
 * 2. The service creates a headless FlutterEngine
 * 3. The engine executes the callbackDispatcher Dart entrypoint
 * 4. The Dart code processes the presence event
 *
 * IMPORTANT: This service requires the following in AndroidManifest.xml:
 * - android:permission="android.permission.BIND_COMPANION_DEVICE_SERVICE"
 * - Proper intent-filter for BIND_COMPANION_DEVICE_SERVICE
 */
@RequiresApi(Build.VERSION_CODES.S)
class CompanionPresenceService : CompanionDeviceService() {

    companion object {
        private const val TAG = "QuickBluePresenceSvc"
        private const val BACKGROUND_CHANNEL_NAME = "quick_blue/background"
        private const val ISOLATE_READY_TIMEOUT_SECONDS = 30L

        // Singleton headless engine to avoid creating multiple engines
        @Volatile
        private var sBackgroundFlutterEngine: FlutterEngine? = null
        private val sEngineLock = Any()

        // Track if the background isolate is ready
        private val sBackgroundIsolateReady = AtomicBoolean(false)
        private var sBackgroundIsolateReadyLatch: CountDownLatch? = null

        // Pending events queue for events that arrive before isolate is ready
        private val sPendingEvents = mutableListOf<Map<String, Any?>>()

        // Deduplicate rapid duplicate events from CDM
        private var sLastEventKey: String? = null
        private var sLastEventTimestamp: Long = 0L

        /**
         * Shuts down the background FlutterEngine if it exists.
         *
         * This should be called when the foreground app starts to ensure
         * a clean handoff between foreground and background operation.
         */
        fun shutdownBackgroundEngine() {
            synchronized(sEngineLock) {
                val engine = sBackgroundFlutterEngine
                if (engine == null) {
                    Log.d(TAG, "No background FlutterEngine to shut down")
                    return
                }

                Log.d(TAG, "Shutting down background FlutterEngine")
                try {
                    engine.destroy()
                } catch (e: Exception) {
                    Log.w(TAG, "Error destroying background engine", e)
                }

                sBackgroundFlutterEngine = null
                sBackgroundIsolateReady.set(false)
                sBackgroundIsolateReadyLatch = null
                synchronized(sPendingEvents) {
                    sPendingEvents.clear()
                }
                sLastEventKey = null
                sLastEventTimestamp = 0L
                Log.d(TAG, "Background FlutterEngine shut down successfully")
            }
        }
    }

    private var backgroundChannel: MethodChannel? = null

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "CompanionPresenceService created")
    }

    override fun onDestroy() {
        super.onDestroy()
        Log.d(TAG, "CompanionPresenceService destroyed")
    }

    /**
     * Called when a companion device appears (comes into BLE/Bluetooth range).
     * This is the main entry point for presence detection.
     */
    override fun onDeviceAppeared(associationInfo: AssociationInfo) {
        Log.d(TAG, "Device appeared: id=${associationInfo.id}, mac=${associationInfo.deviceMacAddress}, name=${associationInfo.displayName}, api=${Build.VERSION.SDK_INT}")

        val eventData = buildEventData(associationInfo, "deviceAppeared")
        Log.d(TAG, "Built event data for device appeared: $eventData")
        dispatchPresenceEvent(eventData)

        val mac = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            associationInfo.deviceMacAddress?.toString()
        } else {
            null
        }
        Log.d(TAG, "Device MAC address for auto BLE: $mac")
        if (!mac.isNullOrBlank()) {
            maybeSendAutoBleCommand(mac)
        } else {
            Log.d(TAG, "Skipping auto BLE command - no MAC address available")
        }
    }

    /**
     * Called when a companion device disappears (goes out of range).
     */
    override fun onDeviceDisappeared(associationInfo: AssociationInfo) {
        Log.d(TAG, "Device disappeared: id=${associationInfo.id}, mac=${associationInfo.deviceMacAddress}, name=${associationInfo.displayName}, api=${Build.VERSION.SDK_INT}")

        val eventData = buildEventData(associationInfo, "deviceDisappeared")
        Log.d(TAG, "Built event data for device disappeared: $eventData")
        dispatchPresenceEvent(eventData)
    }

    /**
     * Legacy callback for API 31-32 (deprecated in API 33+)
     */
    @Deprecated("Deprecated in API 33")
    override fun onDeviceAppeared(address: String) {
        Log.d(TAG, "Device appeared (legacy): $address, api=${Build.VERSION.SDK_INT}")

        val eventData = mapOf(
            "deviceId" to address.uppercase(),
            "deviceName" to null,
            "wakeType" to "deviceAppeared",
            "associationId" to null,
            "timestamp" to System.currentTimeMillis()
        )
        Log.d(TAG, "Built legacy event data for device appeared: $eventData")
        dispatchPresenceEvent(eventData)

        maybeSendAutoBleCommand(address)
    }

    /**
     * Legacy callback for API 31-32 (deprecated in API 33+)
     */
    @Deprecated("Deprecated in API 33")
    override fun onDeviceDisappeared(address: String) {
        Log.d(TAG, "Device disappeared (legacy): $address, api=${Build.VERSION.SDK_INT}")

        val eventData = mapOf(
            "deviceId" to address.uppercase(),
            "deviceName" to null,
            "wakeType" to "deviceDisappeared",
            "associationId" to null,
            "timestamp" to System.currentTimeMillis()
        )
        Log.d(TAG, "Built legacy event data for device disappeared: $eventData")
        dispatchPresenceEvent(eventData)
    }

    /**
     * Builds the event data map from AssociationInfo.
     */
    private fun buildEventData(associationInfo: AssociationInfo, wakeType: String): Map<String, Any?> {
        val macAddress = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            associationInfo.deviceMacAddress?.toString()?.uppercase()
        } else {
            null
        }

        val deviceName = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            associationInfo.displayName?.toString()
        } else {
            null
        }

        return mapOf(
            "deviceId" to macAddress,
            "deviceName" to deviceName,
            "wakeType" to wakeType,
            "associationId" to associationInfo.id,
            "timestamp" to System.currentTimeMillis()
        )
    }

    /**
     * Dispatches a presence event to the Dart side via the background isolate.
     *
     * This method:
     * 1. Ensures the headless FlutterEngine is running (on main thread)
     * 2. Waits for the Dart isolate to be ready
     * 3. Sends the event via MethodChannel
     */
    private fun dispatchPresenceEvent(eventData: Map<String, Any?>) {
        Log.d(TAG, "Dispatching presence event: $eventData")
        val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

        if (isDuplicateEvent(eventData)) {
            Log.d(TAG, "Skipping duplicate presence event: $eventData")
            return
        }

        // FlutterEngine MUST be created on the main thread
        mainHandler.post {
            try {
                Log.d(TAG, "Ensuring background engine is running...")
                ensureBackgroundEngineRunning()

                // After engine is started, wait for isolate on a background thread
                // to avoid blocking the main thread
                Thread {
                    try {
                        Log.d(TAG, "Waiting for background isolate to be ready...")
                        // Wait for the isolate to be ready
                        val ready = waitForIsolateReady()
                        if (!ready) {
                            Log.e(TAG, "Background isolate not ready after timeout, queuing event")
                            synchronized(sPendingEvents) {
                                sPendingEvents.add(eventData)
                                Log.d(TAG, "Queued event, pending events count: ${sPendingEvents.size}")
                            }
                            return@Thread
                        }

                        Log.d(TAG, "Background isolate ready, sending event to Flutter")
                        // Send the event (this method already posts to main thread)
                        sendEventToFlutter(eventData)

                        // Also send any pending events
                        sendPendingEvents()

                    } catch (e: Exception) {
                        Log.e(TAG, "Error waiting for isolate/sending event", e)
                    }
                }.start()

            } catch (e: Exception) {
                Log.e(TAG, "Error creating background engine", e)
            }
        }
    }

    private fun isDuplicateEvent(eventData: Map<String, Any?>): Boolean {
        val deviceId = eventData["deviceId"]?.toString() ?: return false
        val wakeType = eventData["wakeType"]?.toString() ?: return false
        val key = "$deviceId|$wakeType"
        val now = System.currentTimeMillis()

        if (key == sLastEventKey && now - sLastEventTimestamp < 1000) {
            return true
        }

        sLastEventKey = key
        sLastEventTimestamp = now
        return false
    }

    /**
     * Ensures the background FlutterEngine is created and running.
     */
    private fun ensureBackgroundEngineRunning() {
        synchronized(sEngineLock) {
            if (sBackgroundFlutterEngine != null) {
                Log.d(TAG, "Background engine already running")
                val engine = sBackgroundFlutterEngine
                if (engine != null && backgroundChannel == null) {
                    Log.d(TAG, "Rebinding background channel to existing engine")
                    backgroundChannel = MethodChannel(
                        engine.dartExecutor.binaryMessenger,
                        BACKGROUND_CHANNEL_NAME
                    )
                    backgroundChannel?.setMethodCallHandler { call, result ->
                        Log.d(TAG, "Received method call from Dart: ${call.method}")
                        when (call.method) {
                            "backgroundIsolateReady" -> {
                                Log.d(TAG, "Background isolate signaled ready")
                                sBackgroundIsolateReady.set(true)
                                sBackgroundIsolateReadyLatch?.countDown()
                                result.success(null)
                            }
                            else -> {
                                Log.w(TAG, "Unknown method call from Dart: ${call.method}")
                                result.notImplemented()
                            }
                        }
                    }
                }
                return
            }

            Log.d(TAG, "Creating background FlutterEngine")

            // Get the stored callback handles
            val prefs = applicationContext.getSharedPreferences(
                QuickBluePlugin.PREFS_NAME,
                Context.MODE_PRIVATE
            )
            val dispatcherHandle = prefs.getLong(
                QuickBluePlugin.KEY_DISPATCHER_HANDLE,
                0L
            )
            val callbackHandle = prefs.getLong(
                QuickBluePlugin.KEY_CALLBACK_HANDLE,
                0L
            )

            Log.d(TAG, "Retrieved handles - dispatcher: $dispatcherHandle, callback: $callbackHandle")

            if (dispatcherHandle == 0L) {
                Log.e(TAG, "No dispatcher handle found. Did you call registerBackgroundWakeCallback()?")
                return
            }

            // Reset the ready state
            sBackgroundIsolateReady.set(false)
            sBackgroundIsolateReadyLatch = CountDownLatch(1)
            Log.d(TAG, "Reset background isolate ready state")

            // Get the FlutterLoader
            val flutterLoader: FlutterLoader = FlutterInjector.instance().flutterLoader()
            Log.d(TAG, "FlutterLoader initialized: ${flutterLoader.initialized()}")
            if (!flutterLoader.initialized()) {
                Log.d(TAG, "Starting FlutterLoader initialization")
                flutterLoader.startInitialization(applicationContext)
                flutterLoader.ensureInitializationComplete(applicationContext, null)
                Log.d(TAG, "FlutterLoader initialization completed")
            }

            // Create the headless engine
            val engine = FlutterEngine(applicationContext)
            sBackgroundFlutterEngine = engine
            Log.d(TAG, "Created headless FlutterEngine")

            // Set up the background method channel
            backgroundChannel = MethodChannel(
                engine.dartExecutor.binaryMessenger,
                BACKGROUND_CHANNEL_NAME
            )
            Log.d(TAG, "Created background method channel: $BACKGROUND_CHANNEL_NAME")

            // Handle calls from Dart (mainly the "ready" signal)
            backgroundChannel?.setMethodCallHandler { call, result ->
                Log.d(TAG, "Received method call from Dart: ${call.method}")
                when (call.method) {
                    "backgroundIsolateReady" -> {
                        Log.d(TAG, "Background isolate signaled ready")
                        sBackgroundIsolateReady.set(true)
                        sBackgroundIsolateReadyLatch?.countDown()

                        // Initialize the callback handler in Dart
                        if (callbackHandle != 0L) {
                            Log.d(TAG, "Initializing callback handler with handle: $callbackHandle")
                            backgroundChannel?.invokeMethod(
                                "initializeCallbackHandler",
                                callbackHandle
                            )
                        } else {
                            Log.w(TAG, "No callback handle available for initialization")
                        }

                        result.success(null)
                    }
                    else -> {
                        Log.w(TAG, "Unknown method call from Dart: ${call.method}")
                        result.notImplemented()
                    }
                }
            }

            // Get the callback information for the dispatcher
            val callbackInfo = FlutterCallbackInformation.lookupCallbackInformation(dispatcherHandle)
            if (callbackInfo == null) {
                Log.e(TAG, "Failed to lookup callback information for handle: $dispatcherHandle")
                sBackgroundFlutterEngine = null
                return
            }
            Log.d(TAG, "Retrieved callback information for dispatcher handle: $dispatcherHandle")

            // Execute the Dart entrypoint
            val appBundlePath = flutterLoader.findAppBundlePath()
            Log.d(TAG, "App bundle path: $appBundlePath")
            engine.dartExecutor.executeDartCallback(
                DartExecutor.DartCallback(
                    applicationContext.assets,
                    appBundlePath,
                    callbackInfo
                )
            )

            Log.d(TAG, "Background FlutterEngine started, waiting for isolate...")
        }
    }

    /**
     * Waits for the background isolate to signal it's ready.
     */
    private fun waitForIsolateReady(): Boolean {
        if (sBackgroundIsolateReady.get()) {
            return true
        }

        return try {
            sBackgroundIsolateReadyLatch?.await(ISOLATE_READY_TIMEOUT_SECONDS, TimeUnit.SECONDS) ?: false
        } catch (e: InterruptedException) {
            Log.e(TAG, "Interrupted while waiting for isolate", e)
            false
        }
    }

    /**
     * Sends an event to the Flutter side via MethodChannel.
     */
    private fun sendEventToFlutter(eventData: Map<String, Any?>) {
        val channel = backgroundChannel
        if (channel == null) {
            Log.e(TAG, "Background channel is null")
            return
        }

        Log.d(TAG, "Sending event to Flutter via channel: $eventData")
        // Must invoke on main thread
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            try {
                channel.invokeMethod("onPresenceEvent", eventData)
                Log.d(TAG, "Successfully sent presence event to Flutter: $eventData")
            } catch (e: Exception) {
                Log.e(TAG, "Error sending event to Flutter", e)
            }
        }
    }

    /**
     * Sends any pending events that were queued before the isolate was ready.
     */
    private fun sendPendingEvents() {
        val events: List<Map<String, Any?>>
        synchronized(sPendingEvents) {
            if (sPendingEvents.isEmpty()) {
                Log.d(TAG, "No pending events to send")
                return
            }
            events = sPendingEvents.toList()
            sPendingEvents.clear()
        }

        Log.d(TAG, "Sending ${events.size} pending events")
        for (event in events) {
            Log.d(TAG, "Sending pending event: $event")
            sendEventToFlutter(event)
        }
    }

    private fun maybeSendAutoBleCommand(macAddress: String) {
        Log.d(TAG, "Checking for auto BLE command configuration for device: $macAddress")
        try {
            val prefs = applicationContext.getSharedPreferences(
                QuickBluePlugin.PREFS_NAME,
                Context.MODE_PRIVATE
            )
            val serviceUuidStr = prefs.getString(QuickBluePlugin.KEY_AUTO_BLE_SERVICE_UUID, null)
            val characteristicUuidStr = prefs.getString(QuickBluePlugin.KEY_AUTO_BLE_CHARACTERISTIC_UUID, null)
            val commandStr = prefs.getString(QuickBluePlugin.KEY_AUTO_BLE_COMMAND, null)

            Log.d(TAG, "Auto BLE config - service: $serviceUuidStr, char: $characteristicUuidStr, cmd: $commandStr")

            if (serviceUuidStr.isNullOrBlank() || characteristicUuidStr.isNullOrBlank() || commandStr.isNullOrBlank()) {
                Log.d(TAG, "Auto BLE command not configured - missing required parameters")
                return
            }

            val serviceUuid = UUID.fromString(serviceUuidStr)
            val characteristicUuid = UUID.fromString(characteristicUuidStr)
            val commandBytes = commandStr
                .split(',')
                .mapNotNull { it.trim().takeIf { s -> s.isNotEmpty() }?.toIntOrNull() }
                .map { it.coerceIn(0, 255).toByte() }
                .toByteArray()

            Log.d(TAG, "Parsed auto BLE command - service: $serviceUuid, char: $characteristicUuid, bytes: ${commandBytes.size}")

            if (commandBytes.isEmpty()) {
                Log.w(TAG, "Auto BLE command configured but empty")
                return
            }

            val adapter = BluetoothAdapter.getDefaultAdapter()
            if (adapter == null) {
                Log.w(TAG, "BluetoothAdapter is null; cannot send auto BLE command")
                return
            }

            val device: BluetoothDevice = adapter.getRemoteDevice(macAddress)
            Log.d(TAG, "Retrieved BluetoothDevice for auto BLE: $macAddress")

            Log.d(
                TAG,
                "Auto BLE write on appear: mac=$macAddress service=$serviceUuidStr char=$characteristicUuidStr bytes=${commandBytes.size}"
            )

            connectAndWriteOnce(device, serviceUuid, characteristicUuid, commandBytes)
        } catch (e: Exception) {
            Log.e(TAG, "Error preparing auto BLE command", e)
        }
    }

    private fun connectAndWriteOnce(
        device: BluetoothDevice,
        serviceUuid: UUID,
        characteristicUuid: UUID,
        payload: ByteArray,
    ) {
        Log.d(TAG, "Starting auto BLE connect and write - device: ${device.address}, service: $serviceUuid, char: $characteristicUuid, payload size: ${payload.size}")
        // Runs independently from the Flutter isolate lifecycle.
        // Best-effort: connect, discover services, write characteristic, disconnect.
        val appCtx = applicationContext

        val callback = object : BluetoothGattCallback() {
            private var gattRef: BluetoothGatt? = null
            private var wrote = false

            private fun cleanup() {
                Log.d(TAG, "Cleaning up GATT connection")
                try {
                    gattRef?.disconnect()
                } catch (_: Exception) {
                }
                try {
                    gattRef?.close()
                } catch (_: Exception) {
                }
                gattRef = null
            }

            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                gattRef = gatt
                Log.d(TAG, "Auto BLE connection state changed - status: $status, newState: $newState")
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    Log.w(TAG, "Auto BLE connect failed: status=$status")
                    cleanup()
                    return
                }

                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    Log.d(TAG, "Auto BLE connected; discovering services")
                    gatt.discoverServices()
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    Log.d(TAG, "Auto BLE disconnected")
                    cleanup()
                }
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                Log.d(TAG, "Auto BLE services discovered - status: $status")
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    Log.w(TAG, "Auto BLE service discovery failed: status=$status")
                    cleanup()
                    return
                }

                val service: BluetoothGattService? = gatt.getService(serviceUuid)
                if (service == null) {
                    Log.w(TAG, "Auto BLE service not found: $serviceUuid")
                    cleanup()
                    return
                }
                Log.d(TAG, "Auto BLE service found: $serviceUuid")

                val characteristic: BluetoothGattCharacteristic? = service.getCharacteristic(characteristicUuid)
                if (characteristic == null) {
                    Log.w(TAG, "Auto BLE characteristic not found: $characteristicUuid")
                    cleanup()
                    return
                }
                Log.d(TAG, "Auto BLE characteristic found: $characteristicUuid, properties: ${characteristic.properties}")

                if ((characteristic.properties and BluetoothGattCharacteristic.PROPERTY_WRITE) == 0 &&
                    (characteristic.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) == 0
                ) {
                    Log.w(TAG, "Auto BLE characteristic is not writable")
                    cleanup()
                    return
                }

                wrote = true
                Log.d(TAG, "Auto BLE characteristic is writable, initiating write")

                val ok: Boolean = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    val result = gatt.writeCharacteristic(
                        characteristic,
                        payload,
                        BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                    )
                    Log.d(TAG, "Auto BLE writeCharacteristic (TIRAMISU+) result: $result")
                    result == BluetoothStatusCodes.SUCCESS
                } else {
                    @Suppress("DEPRECATION")
                    run {
                        characteristic.value = payload
                        val result = gatt.writeCharacteristic(characteristic)
                        Log.d(TAG, "Auto BLE writeCharacteristic (legacy) result: $result")
                        result
                    }
                }

                Log.d(TAG, "Auto BLE write initiated: ok=$ok")
                if (!ok) {
                    cleanup()
                }
            }

            override fun onCharacteristicWrite(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                Log.d(TAG, "Auto BLE write finished: status=$status")
                cleanup()
            }
        }

        try {
            Log.d(TAG, "Attempting GATT connection to device: ${device.address}")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                device.connectGatt(appCtx, false, callback, BluetoothDevice.TRANSPORT_LE)
            } else {
                @Suppress("DEPRECATION")
                device.connectGatt(appCtx, false, callback)
            }
            Log.d(TAG, "GATT connectGatt called")
        } catch (e: SecurityException) {
            // Missing BLUETOOTH_CONNECT or Bluetooth is disabled.
            Log.e(TAG, "Auto BLE connectGatt SecurityException", e)
        } catch (e: Exception) {
            Log.e(TAG, "Auto BLE connectGatt error", e)
        }
    }
}
