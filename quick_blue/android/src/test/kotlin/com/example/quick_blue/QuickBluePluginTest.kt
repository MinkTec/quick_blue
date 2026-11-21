package com.example.quick_blue

import android.bluetooth.*
import android.os.Handler
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel.Result
import org.junit.Before
import org.junit.Test
import org.mockito.ArgumentMatchers.*
import org.mockito.Mockito.*
import java.util.UUID

class QuickBluePluginTest {
  private val plugin = QuickBluePlugin()
  private val handler = mock(Handler::class.java)
  private val gatt = mock(BluetoothGatt::class.java)
  private val device = mock(BluetoothDevice::class.java)
  private val service = mock(BluetoothGattService::class.java)
  private val characteristic = mock(BluetoothGattCharacteristic::class.java)
  private val descriptor = mock(BluetoothGattDescriptor::class.java)
  private val serviceId = UUID.fromString("6e400001-c352-11e5-953d-0002a5d5c51b")
  private val charId = UUID.fromString("6e400003-c352-11e5-953d-0002a5d5c51b")
  private val descriptorId = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
  private val address = "00:00:00:00:00:01"
  private lateinit var callback: BluetoothGattCallback
  private lateinit var timeout: Runnable

  private fun field(name: String) = QuickBluePlugin::class.java.getDeclaredField(name).apply {
    isAccessible = true
  }

  @Before fun setUp() {
    field("mainThreadHandler").set(plugin, handler)
    field("messageConnector").set(plugin, mock(BasicMessageChannel::class.java))
    @Suppress("UNCHECKED_CAST")
    (field("knownGatts").get(plugin) as MutableList<BluetoothGatt>).add(gatt)
    callback = field("gattCallback").get(plugin) as BluetoothGattCallback
    `when`(handler.post(any(Runnable::class.java))).thenAnswer { call ->
      call.getArgument<Runnable>(0).run()
      true
    }
    `when`(handler.postDelayed(any(Runnable::class.java), anyLong())).thenAnswer { call ->
      timeout = call.getArgument(0)
      true
    }
    `when`(gatt.device).thenReturn(device)
    `when`(device.address).thenReturn(address)
    `when`(gatt.getService(serviceId)).thenReturn(service)
    `when`(service.getCharacteristic(charId)).thenReturn(characteristic)
    `when`(characteristic.uuid).thenReturn(charId)
    `when`(characteristic.value).thenReturn(byteArrayOf(1))
    `when`(characteristic.getDescriptor(descriptorId)).thenReturn(descriptor)
    `when`(descriptor.uuid).thenReturn(descriptorId)
    `when`(gatt.setCharacteristicNotification(characteristic, true)).thenReturn(true)
    `when`(gatt.writeDescriptor(descriptor)).thenReturn(true)
    `when`(gatt.writeCharacteristic(characteristic)).thenReturn(true)
  }

  private fun call(method: String, result: Result, property: String = "withoutResponse") {
    plugin.onMethodCall(MethodCall(method, mapOf(
      "deviceId" to address, "service" to serviceId.toString(),
      "characteristic" to charId.toString(), "bleInputProperty" to "notification",
      "bleOutputProperty" to property, "value" to byteArrayOf(1)
    )), result)
  }

  @Test fun subscriptionWaitsForDescriptorBeforeFirstCommand() {
    val subscription = mock(Result::class.java)
    call("setNotifiable", subscription)
    verifyNoInteractions(subscription)
    callback.onDescriptorWrite(gatt, descriptor, BluetoothGatt.GATT_SUCCESS)
    verify(subscription).success(null)

    val write = mock(Result::class.java)
    call("writeValue", write)
    verify(characteristic).writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
    verifyNoInteractions(write)
    callback.onCharacteristicWrite(gatt, characteristic, BluetoothGatt.GATT_SUCCESS)
    verify(write).success(null)
  }

  @Test fun overlappingWriteDoesNotReachAndroid() {
    call("setNotifiable", mock(Result::class.java))
    val write = mock(Result::class.java)
    call("writeValue", write)
    verify(write).error(eq("GattBusy"), anyString(), isNull())
    verify(gatt, never()).writeCharacteristic(any())
  }

  @Test fun descriptorFailureIsNotReportedAsSubscribed() {
    val result = mock(Result::class.java)
    call("setNotifiable", result)
    callback.onDescriptorWrite(gatt, descriptor, BluetoothGatt.GATT_FAILURE)
    verify(result).error(eq("GattStatus"), anyString(), eq(BluetoothGatt.GATT_FAILURE))
    verify(result, never()).success(any())
  }

  @Test fun rejectedDescriptorFailsImmediatelyAndAllowsRetry() {
    `when`(gatt.writeDescriptor(descriptor)).thenReturn(false)
    val result = mock(Result::class.java)
    call("setNotifiable", result)
    verify(result).error(eq("GattRejected"), anyString(), isNull())
    `when`(gatt.writeDescriptor(descriptor)).thenReturn(true)
    val retry = mock(Result::class.java)
    call("setNotifiable", retry)
    callback.onDescriptorWrite(gatt, descriptor, 0)
    verify(retry).success(null)
  }

  @Test fun writeModeAndFailureArePreserved() {
    val result = mock(Result::class.java)
    call("writeValue", result, "withResponse")
    verify(characteristic).writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
    callback.onCharacteristicWrite(gatt, characteristic, BluetoothGatt.GATT_WRITE_NOT_PERMITTED)
    verify(result).error(eq("GattStatus"), anyString(), eq(BluetoothGatt.GATT_WRITE_NOT_PERMITTED))
  }

  @Test fun unrelatedCallbackDoesNotCompleteSubscription() {
    val result = mock(Result::class.java)
    call("setNotifiable", result)
    callback.onCharacteristicWrite(gatt, characteristic, 0)
    val otherGatt = mock(BluetoothGatt::class.java)
    callback.onDescriptorWrite(otherGatt, descriptor, 0)
    val otherDescriptor = mock(BluetoothGattDescriptor::class.java)
    `when`(otherDescriptor.uuid).thenReturn(UUID.randomUUID())
    callback.onDescriptorWrite(gatt, otherDescriptor, 0)
    verifyNoInteractions(result)
    callback.onDescriptorWrite(gatt, descriptor, 0)
    verify(result).success(null)
  }

  @Test fun disconnectFailsPendingOperationAndLateCallbackIsIgnored() {
    val result = mock(Result::class.java)
    call("setNotifiable", result)
    call("disconnect", mock(Result::class.java))
    verify(result).error(eq("GattDisconnected"), anyString(), isNull())
    callback.onDescriptorWrite(gatt, descriptor, 0)
    verifyNoMoreInteractions(result)
  }

  @Test fun missingCallbackTimesOutAndClosesConnection() {
    val result = mock(Result::class.java)
    call("setNotifiable", result)
    timeout.run()
    verify(result).error(eq("GattTimeout"), anyString(), isNull())
    verify(gatt).disconnect()
    verify(gatt).close()
    callback.onDescriptorWrite(gatt, descriptor, 0)
    verifyNoMoreInteractions(result)
  }

  @Test fun unknownCharacteristicFailsInsteadOfHanging() {
    `when`(gatt.getService(serviceId)).thenReturn(null)
    val result = mock(Result::class.java)
    call("writeValue", result)
    verify(result).error(eq("IllegalArgument"), anyString(), isNull())
  }
}
