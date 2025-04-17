#include "include/quick_blue_windows/quick_blue_windows_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>
#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Radios.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.Streams.h>

#include <flutter/basic_message_channel.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_message_codec.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <iomanip>
#include <map>
#include <memory>
#include <sstream>

#define GUID_FORMAT                                                            \
  "%08x-%04hx-%04hx-%02hhx%02hhx-%02hhx%02hhx%02hhx%02hhx%02hhx%02hhx"
#define GUID_ARG(guid)                                                         \
  guid.Data1, guid.Data2, guid.Data3, guid.Data4[0], guid.Data4[1],            \
      guid.Data4[2], guid.Data4[3], guid.Data4[4], guid.Data4[5],              \
      guid.Data4[6], guid.Data4[7]

// Anonymous namespace for helper functions and types
namespace {

using namespace winrt::Windows::Foundation;
using namespace winrt::Windows::Foundation::Collections;
using namespace winrt::Windows::Storage::Streams;
using namespace winrt::Windows::Devices::Radios;
using namespace winrt::Windows::Devices::Bluetooth;
using namespace winrt::Windows::Devices::Bluetooth::Advertisement;
using namespace winrt::Windows::Devices::Bluetooth::GenericAttributeProfile;

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

union uint16_t_union {
  uint16_t uint16;
  byte bytes[sizeof(uint16_t)];
};

std::vector<uint8_t> to_bytevc(IBuffer buffer) {
  auto reader = DataReader::FromBuffer(buffer);
  auto result = std::vector<uint8_t>(reader.UnconsumedBufferLength());
  reader.ReadBytes(result);
  return result;
}

IBuffer from_bytevc(std::vector<uint8_t> bytes) {
  auto writer = DataWriter();
  writer.WriteBytes(bytes);
  return writer.DetachBuffer();
}

std::string to_hexstring(std::vector<uint8_t> bytes) {
  auto ss = std::stringstream();
  for (auto b : bytes)
    ss << std::setw(2) << std::setfill('0') << std::hex << static_cast<int>(b);
  return ss.str();
}

std::string to_uuidstr(winrt::guid guid) {
  char chars[36 + 1];
  sprintf_s(chars, GUID_FORMAT, GUID_ARG(guid));
  return std::string{chars};
}

struct BluetoothDeviceAgent {
  BluetoothLEDevice device;
  winrt::event_token connnectionStatusChangedToken;
  std::map<std::string, GattDeviceService> gattServices;
  std::map<std::string, GattCharacteristic> gattCharacteristics;
  std::map<std::string, winrt::event_token> valueChangedTokens;

  BluetoothDeviceAgent(BluetoothLEDevice device,
                       winrt::event_token connnectionStatusChangedToken)
      : device(device),
        connnectionStatusChangedToken(connnectionStatusChangedToken) {}

  ~BluetoothDeviceAgent() { device = nullptr; }

  bool IsConnected() const {
    return device &&
           device.ConnectionStatus() == BluetoothConnectionStatus::Connected;
  }

  IAsyncOperation<GattDeviceService>
  BluetoothDeviceAgent::GetServiceAsync(std::string service) {
    // First check if device is valid
    if (!device) {
      OutputDebugString(L"GetServiceAsync: Device is null\n");
      co_return nullptr;
    }

    try {
      // Check if we already have the service cached
      if (gattServices.count(service) > 0) {
        // Verify the cached service is still valid
        auto &cachedService = gattServices.at(service);
        if (cachedService) {
          co_return cachedService;
        } else {
          // Remove invalid cached service
          OutputDebugString(
              (L"GetServiceAsync: Cached service is invalid, removing: " +
               winrt::to_hstring(service) + L"\n")
                  .c_str());
          gattServices.erase(service);
        }
      }

      // Get services
      OutputDebugString((L"GetServiceAsync: Getting services for: " +
                         winrt::to_hstring(service) + L"\n")
                            .c_str());
      auto serviceResult = co_await device.GetGattServicesAsync();

      if (serviceResult == nullptr ||
          serviceResult.Status() != GattCommunicationStatus::Success) {
        OutputDebugString(
            (L"GetServiceAsync: Failed to get services, status: " +
             (serviceResult ? winrt::to_hstring((int32_t)serviceResult.Status())
                            : L"null") +
             L"\n")
                .c_str());
        co_return nullptr;
      }

      // Search for the requested service
      for (auto s : serviceResult.Services()) {
        if (s && to_uuidstr(s.Uuid()) == service) {
          gattServices.insert(std::make_pair(service, s));
          co_return s;
        }
      }

      // Service not found
      OutputDebugString((L"GetServiceAsync: Service not found: " +
                         winrt::to_hstring(service) + L"\n")
                            .c_str());
      co_return nullptr;
    } catch (const winrt::hresult_error &ex) {
      OutputDebugString((L"GetServiceAsync exception: " + ex.message() +
                         L", code: " + winrt::to_hstring(ex.code()) + L"\n")
                            .c_str());
      co_return nullptr;
    } catch (...) {
      OutputDebugString(L"GetServiceAsync unknown exception\n");
      co_return nullptr;
    }
  }

  IAsyncOperation<GattCharacteristic>
  BluetoothDeviceAgent::GetCharacteristicAsync(std::string service,
                                               std::string characteristic) {

    // First check if device is valid
    if (!device) {
      OutputDebugString(L"GetCharacteristicAsync: Device is null\n");
      co_return nullptr;
    }

    try {
      // Check if we already have the characteristic cached
      if (gattCharacteristics.count(characteristic) > 0) {
        // Verify the cached characteristic is still valid
        auto &cachedCharacteristic = gattCharacteristics.at(characteristic);
        if (cachedCharacteristic) {
          co_return cachedCharacteristic;
        } else {
          // Remove invalid cached characteristic
          OutputDebugString((L"GetCharacteristicAsync: Cached characteristic "
                             L"is invalid, removing: " +
                             winrt::to_hstring(characteristic) + L"\n")
                                .c_str());
          gattCharacteristics.erase(characteristic);
        }
      }

      // Get the service
      auto gattService = co_await GetServiceAsync(service);
      if (!gattService) {
        OutputDebugString((L"GetCharacteristicAsync: Service not found: " +
                           winrt::to_hstring(service) + L"\n")
                              .c_str());
        co_return nullptr;
      }

      // Get characteristics
      OutputDebugString(
          (L"GetCharacteristicAsync: Getting characteristics for: " +
           winrt::to_hstring(characteristic) + L"\n")
              .c_str());
      auto characteristicResult =
          co_await gattService.GetCharacteristicsAsync();

      if (characteristicResult == nullptr ||
          characteristicResult.Status() != GattCommunicationStatus::Success) {
        OutputDebugString(
            (L"GetCharacteristicAsync: Failed to get characteristics, "
             L"status: " +
             (characteristicResult
                  ? winrt::to_hstring((int32_t)characteristicResult.Status())
                  : L"null") +
             L"\n")
                .c_str());
        co_return nullptr;
      }

      // Search for the requested characteristic
      for (auto c : characteristicResult.Characteristics()) {
        if (c && to_uuidstr(c.Uuid()) == characteristic) {
          gattCharacteristics.insert(std::make_pair(characteristic, c));
          co_return c;
        }
      }

      // Characteristic not found
      OutputDebugString((L"GetCharacteristicAsync: Characteristic not found: " +
                         winrt::to_hstring(characteristic) + L"\n")
                            .c_str());
      co_return nullptr;
    } catch (const winrt::hresult_error &ex) {
      OutputDebugString((L"GetCharacteristicAsync exception: " + ex.message() +
                         L", code: " + winrt::to_hstring(ex.code()) + L"\n")
                            .c_str());
      co_return nullptr;
    } catch (...) {
      OutputDebugString(L"GetCharacteristicAsync unknown exception\n");
      co_return nullptr;
    }
  }
};

std::vector<uint8_t>
parseManufacturerDataHead(BluetoothLEAdvertisement advertisement) {
  if (advertisement.ManufacturerData().Size() == 0)
    return std::vector<uint8_t>();

  auto manufacturerData = advertisement.ManufacturerData().GetAt(0);
  // FIXME Compat with REG_DWORD_BIG_ENDIAN
  uint8_t *prefix = uint16_t_union{manufacturerData.CompanyId()}.bytes;
  auto result = std::vector<uint8_t>{prefix, prefix + sizeof(uint16_t_union)};

  auto data = to_bytevc(manufacturerData.Data());
  result.insert(result.end(), data.begin(), data.end());
  return result;
}

} // end of anonymous namespace

// Class definition outside anonymous namespace
class QuickBlueWindowsPlugin : public flutter::Plugin,
                               public flutter::StreamHandler<EncodableValue> {
public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  QuickBlueWindowsPlugin();

  virtual ~QuickBlueWindowsPlugin();

private:
  winrt::fire_and_forget InitializeAsync();

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::StreamHandlerError<>>
  OnListenInternal(const EncodableValue *arguments,
                   std::unique_ptr<flutter::EventSink<>> &&events) override;
  std::unique_ptr<flutter::StreamHandlerError<>>
  OnCancelInternal(const EncodableValue *arguments) override;

  std::unique_ptr<flutter::BasicMessageChannel<EncodableValue>>
      message_connector_;

  std::unique_ptr<flutter::EventSink<EncodableValue>> scan_result_sink_;

  Radio bluetoothRadio{nullptr};

  BluetoothLEAdvertisementWatcher bluetoothLEWatcher{nullptr};
  winrt::event_token bluetoothLEWatcherReceivedToken;
  void
  BluetoothLEWatcher_Received(BluetoothLEAdvertisementWatcher sender,
                              BluetoothLEAdvertisementReceivedEventArgs args);
  winrt::fire_and_forget
  SendScanResultAsync(BluetoothLEAdvertisementReceivedEventArgs args);

  std::map<uint64_t, std::unique_ptr<BluetoothDeviceAgent>> connectedDevices{};

  winrt::fire_and_forget ConnectAsync(uint64_t bluetoothAddress);
  void BluetoothLEDevice_ConnectionStatusChanged(BluetoothLEDevice sender,
                                                 IInspectable args);
  void CleanConnection(uint64_t bluetoothAddress);
  winrt::fire_and_forget
  DiscoverServicesAsync(BluetoothDeviceAgent &bluetoothDeviceAgent);
  winrt::fire_and_forget
  SetNotifiableAsync(BluetoothDeviceAgent &bluetoothDeviceAgent,
                     std::string service, std::string characteristic,
                     std::string bleInputProperty);
  winrt::fire_and_forget
  RequestMtuAsync(BluetoothDeviceAgent &bluetoothDeviceAgent,
                  uint64_t expectedMtu);
  winrt::fire_and_forget
  ReadValueAsync(BluetoothDeviceAgent &bluetoothDeviceAgent,
                 std::string service, std::string characteristic);
  winrt::fire_and_forget
  WriteValueAsync(BluetoothDeviceAgent &bluetoothDeviceAgent,
                  std::string service, std::string characteristic,
                  std::vector<uint8_t> value, std::string bleOutputProperty);
  void GattCharacteristic_ValueChanged(GattCharacteristic sender,
                                       GattValueChangedEventArgs args);
};

// Method implementations
void QuickBlueWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto method = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      registrar->messenger(), "quick_blue/method",
      &flutter::StandardMethodCodec::GetInstance());
  auto event_scan_result =
      std::make_unique<flutter::EventChannel<EncodableValue>>(
          registrar->messenger(), "quick_blue/event.scanResult",
          &flutter::StandardMethodCodec::GetInstance());
  auto message_connector_ =
      std::make_unique<flutter::BasicMessageChannel<EncodableValue>>(
          registrar->messenger(), "quick_blue/message.connector",
          &flutter::StandardMessageCodec::GetInstance());

  auto plugin = std::make_unique<QuickBlueWindowsPlugin>();

  method->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  auto handler = std::make_unique<flutter::StreamHandlerFunctions<>>(
      [plugin_pointer =
           plugin.get()](const EncodableValue *arguments,
                         std::unique_ptr<flutter::EventSink<>> &&events)
          -> std::unique_ptr<flutter::StreamHandlerError<>> {
        return plugin_pointer->OnListen(arguments, std::move(events));
      },
      [plugin_pointer = plugin.get()](const EncodableValue *arguments)
          -> std::unique_ptr<flutter::StreamHandlerError<>> {
        return plugin_pointer->OnCancel(arguments);
      });
  event_scan_result->SetStreamHandler(std::move(handler));

  plugin->message_connector_ = std::move(message_connector_);

  registrar->AddPlugin(std::move(plugin));
}

QuickBlueWindowsPlugin::QuickBlueWindowsPlugin() { InitializeAsync(); }

QuickBlueWindowsPlugin::~QuickBlueWindowsPlugin() {}

winrt::fire_and_forget QuickBlueWindowsPlugin::InitializeAsync() {
  auto bluetoothAdapter = co_await BluetoothAdapter::GetDefaultAsync();
  bluetoothRadio = co_await bluetoothAdapter.GetRadioAsync();
}

void QuickBlueWindowsPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  auto method_name = method_call.method_name();
  OutputDebugString(
      (L"HandleMethodCall " + winrt::to_hstring(method_name) + L"\n").c_str());
  if (method_name.compare("isBluetoothAvailable") == 0) {
    result->Success(EncodableValue(bluetoothRadio &&
                                   bluetoothRadio.State() == RadioState::On));
  } else if (method_name.compare("startScan") == 0) {
    if (!bluetoothLEWatcher) {
      bluetoothLEWatcher = BluetoothLEAdvertisementWatcher();
      bluetoothLEWatcherReceivedToken = bluetoothLEWatcher.Received(
          {this, &QuickBlueWindowsPlugin::BluetoothLEWatcher_Received});
    }
    bluetoothLEWatcher.Start();
    result->Success(nullptr);
  } else if (method_name.compare("stopScan") == 0) {
    if (bluetoothLEWatcher) {
      bluetoothLEWatcher.Stop();
      bluetoothLEWatcher.Received(bluetoothLEWatcherReceivedToken);
    }
    bluetoothLEWatcher = nullptr;
    result->Success(nullptr);
  } else if (method_name.compare("connect") == 0) {
    auto args = std::get<EncodableMap>(*method_call.arguments());
    auto deviceId = std::get<std::string>(args[EncodableValue("deviceId")]);
    ConnectAsync(std::stoull(deviceId));
    result->Success(nullptr);
  } else if (method_name.compare("disconnect") == 0) {
    auto args = std::get<EncodableMap>(*method_call.arguments());
    auto deviceId = std::get<std::string>(args[EncodableValue("deviceId")]);
    CleanConnection(std::stoull(deviceId));
    // TODO send `disconnected` message
    result->Success(nullptr);
  } else if (method_name.compare("discoverServices") == 0) {
    auto args = std::get<EncodableMap>(*method_call.arguments());
    auto deviceId = std::get<std::string>(args[EncodableValue("deviceId")]);
    auto it = connectedDevices.find(std::stoull(deviceId));
    if (it == connectedDevices.end()) {
      result->Error("IllegalArgument", "Unknown devicesId:" + deviceId);
      return;
    }
    DiscoverServicesAsync(*it->second);
    result->Success(nullptr);
  } else if (method_name.compare("setNotifiable") == 0) {
    auto args = std::get<EncodableMap>(*method_call.arguments());
    auto deviceId = std::get<std::string>(args[EncodableValue("deviceId")]);
    auto service = std::get<std::string>(args[EncodableValue("service")]);
    auto characteristic =
        std::get<std::string>(args[EncodableValue("characteristic")]);
    auto bleInputProperty =
        std::get<std::string>(args[EncodableValue("bleInputProperty")]);
    auto it = connectedDevices.find(std::stoull(deviceId));
    if (it == connectedDevices.end()) {
      result->Error("IllegalArgument", "Unknown devicesId:" + deviceId);
      return;
    }

    SetNotifiableAsync(*it->second, service, characteristic, bleInputProperty);
    result->Success(nullptr);
  } else if (method_name.compare("requestMtu") == 0) {
    auto args = std::get<EncodableMap>(*method_call.arguments());
    auto deviceId = std::get<std::string>(args[EncodableValue("deviceId")]);
    auto expectedMtu = std::get<int32_t>(args[EncodableValue("expectedMtu")]);
    auto it = connectedDevices.find(std::stoull(deviceId));
    if (it == connectedDevices.end()) {
      result->Error("IllegalArgument", "Unknown devicesId:" + deviceId);
      return;
    }

    RequestMtuAsync(*it->second, expectedMtu);
    result->Success(nullptr);
  } else if (method_name.compare("readValue") == 0) {
    auto args = std::get<EncodableMap>(*method_call.arguments());
    auto deviceId = std::get<std::string>(args[EncodableValue("deviceId")]);
    auto service = std::get<std::string>(args[EncodableValue("service")]);
    auto characteristic =
        std::get<std::string>(args[EncodableValue("characteristic")]);
    auto it = connectedDevices.find(std::stoull(deviceId));
    if (it == connectedDevices.end()) {
      result->Error("IllegalArgument", "Unknown devicesId:" + deviceId);
      return;
    }

    ReadValueAsync(*it->second, service, characteristic);
    result->Success(nullptr);
  } else if (method_name.compare("writeValue") == 0) {
    auto args = std::get<EncodableMap>(*method_call.arguments());
    auto deviceId = std::get<std::string>(args[EncodableValue("deviceId")]);
    auto service = std::get<std::string>(args[EncodableValue("service")]);
    auto characteristic =
        std::get<std::string>(args[EncodableValue("characteristic")]);
    auto value = std::get<std::vector<uint8_t>>(args[EncodableValue("value")]);
    auto bleOutputProperty =
        std::get<std::string>(args[EncodableValue("bleOutputProperty")]);
    auto it = connectedDevices.find(std::stoull(deviceId));
    if (it == connectedDevices.end()) {
      result->Error("IllegalArgument", "Unknown devicesId:" + deviceId);
      return;
    }

    WriteValueAsync(*it->second, service, characteristic, value,
                    bleOutputProperty);
    result->Success(nullptr);
  } else {
    result->NotImplemented();
  }
}

void QuickBlueWindowsPlugin::BluetoothLEWatcher_Received(
    BluetoothLEAdvertisementWatcher sender,
    BluetoothLEAdvertisementReceivedEventArgs args) {
  SendScanResultAsync(args);
}

winrt::fire_and_forget QuickBlueWindowsPlugin::SendScanResultAsync(
    BluetoothLEAdvertisementReceivedEventArgs args) {
  auto device = co_await BluetoothLEDevice::FromBluetoothAddressAsync(
      args.BluetoothAddress());
  auto name = device ? device.Name() : args.Advertisement().LocalName();
  OutputDebugString((L"Received BluetoothAddress:" +
                     winrt::to_hstring(args.BluetoothAddress()) + L", Name:" +
                     name + L", LocalName:" + args.Advertisement().LocalName() +
                     L"\n")
                        .c_str());
  if (scan_result_sink_) {
    scan_result_sink_->Success(EncodableMap{
        {"name", winrt::to_string(name)},
        {"deviceId", std::to_string(args.BluetoothAddress())},
        {"manufacturerDataHead",
         parseManufacturerDataHead(args.Advertisement())},
        {"rssi", args.RawSignalStrengthInDBm()},
    });
  }
}

std::unique_ptr<flutter::StreamHandlerError<EncodableValue>>
QuickBlueWindowsPlugin::OnListenInternal(
    const EncodableValue *arguments,
    std::unique_ptr<flutter::EventSink<EncodableValue>> &&events) {
  if (arguments == nullptr) {
    return nullptr;
  }
  auto args = std::get<EncodableMap>(*arguments);
  auto name = std::get<std::string>(args[EncodableValue("name")]);
  if (name.compare("scanResult") == 0) {
    scan_result_sink_ = std::move(events);
  }
  return nullptr;
}

std::unique_ptr<flutter::StreamHandlerError<EncodableValue>>
QuickBlueWindowsPlugin::OnCancelInternal(const EncodableValue *arguments) {
  if (arguments == nullptr) {
    return nullptr;
  }
  auto args = std::get<EncodableMap>(*arguments);
  auto name = std::get<std::string>(args[EncodableValue("name")]);
  if (name.compare("scanResult") == 0) {
    scan_result_sink_ = nullptr;
  }
  return nullptr;
}

winrt::fire_and_forget
QuickBlueWindowsPlugin::ConnectAsync(uint64_t bluetoothAddress) {
  try {
    auto device =
        co_await BluetoothLEDevice::FromBluetoothAddressAsync(bluetoothAddress);

    // Check if the device is null

    auto servicesResult = co_await device.GetGattServicesAsync();
    if (servicesResult.Status() != GattCommunicationStatus::Success) {
      OutputDebugString((L"GetGattServicesAsync error: " +
                         winrt::to_hstring((int32_t)servicesResult.Status()) +
                         L"\n")
                            .c_str());
      message_connector_->Send(EncodableMap{
          {"deviceId", std::to_string(bluetoothAddress)},
          {"ConnectionState", "disconnected"},
      });
      co_return;
    }
    auto connnectionStatusChangedToken = device.ConnectionStatusChanged(
        {this,
         &QuickBlueWindowsPlugin::BluetoothLEDevice_ConnectionStatusChanged});
    auto deviceAgent = std::make_unique<BluetoothDeviceAgent>(
        device, connnectionStatusChangedToken);
    auto pair = std::make_pair(bluetoothAddress, std::move(deviceAgent));
    connectedDevices.insert(std::move(pair));

    message_connector_->Send(EncodableMap{
        {"deviceId", std::to_string(bluetoothAddress)},
        {"ConnectionState", "connected"},
    });
  } catch (const winrt::hresult_error &ex) {
    OutputDebugString((L"ConnectAsync exception: " + ex.message() +
                       L", code: " + winrt::to_hstring(ex.code()) + L"\n")
                          .c_str());
    message_connector_->Send(EncodableMap{
        {"deviceId", std::to_string(bluetoothAddress)},
        {"ConnectionState", "disconnected"},
    });
  } catch (const std::exception &ex) {
    OutputDebugString(
        (L"ConnectAsync std exception: " + winrt::to_hstring(ex.what()) + L"\n")
            .c_str());
    message_connector_->Send(EncodableMap{
        {"deviceId", std::to_string(bluetoothAddress)},
        {"ConnectionState", "disconnected"},
    });
  } catch (...) {
    OutputDebugString(L"ConnectAsync unknown exception\n");
    message_connector_->Send(EncodableMap{
        {"deviceId", std::to_string(bluetoothAddress)},
        {"ConnectionState", "disconnected"},
    });
  }
}

void QuickBlueWindowsPlugin::BluetoothLEDevice_ConnectionStatusChanged(
    BluetoothLEDevice sender, IInspectable args) {
  try {
    OutputDebugString(
        (L"ConnectionStatusChanged: Device " +
         winrt::to_hstring(sender.BluetoothAddress()) + L", Status: " +
         winrt::to_hstring((int32_t)sender.ConnectionStatus()) + L"\n")
            .c_str());

    if (sender.ConnectionStatus() == BluetoothConnectionStatus::Disconnected) {
      // Clean up all resources related to this device
      CleanConnection(sender.BluetoothAddress());

      // Notify the Dart side
      message_connector_->Send(EncodableMap{
          {"deviceId", std::to_string(sender.BluetoothAddress())},
          {"ConnectionState", "disconnected"},
      });
    }
  } catch (const std::exception &ex) {
    OutputDebugString((L"ConnectionStatusChanged exception: " +
                       winrt::to_hstring(ex.what()) + L"\n")
                          .c_str());
  } catch (...) {
    OutputDebugString(L"ConnectionStatusChanged unknown exception\n");
  }
}
void QuickBlueWindowsPlugin::CleanConnection(uint64_t bluetoothAddress) {
  try {
    auto it = connectedDevices.find(bluetoothAddress);
    if (it == connectedDevices.end()) {
      OutputDebugString((L"CleanConnection: Device not found: " +
                         winrt::to_hstring(bluetoothAddress) + L"\n")
                            .c_str());
      return;
    }

    auto deviceAgent = std::move(it->second);
    connectedDevices.erase(bluetoothAddress);

    if (deviceAgent) {
      // First unregister all event handlers to prevent any callbacks
      if (deviceAgent->device) {
        try {
          deviceAgent->device.ConnectionStatusChanged(
              deviceAgent->connnectionStatusChangedToken);
        } catch (...) {
          OutputDebugString(L"CleanConnection: Error unregistering "
                            L"ConnectionStatusChanged\n");
        }
      }

      // Remove all value changed handlers for characteristics
      for (auto &tokenPair : deviceAgent->valueChangedTokens) {
        try {
          if (deviceAgent->gattCharacteristics.count(tokenPair.first) > 0) {
            auto &characteristic =
                deviceAgent->gattCharacteristics.at(tokenPair.first);
            if (characteristic) {
              characteristic.ValueChanged(tokenPair.second);
            }
          }
        } catch (...) {
          OutputDebugString((L"CleanConnection: Error unregistering "
                             L"ValueChanged for characteristic: " +
                             winrt::to_hstring(tokenPair.first) + L"\n")
                                .c_str());
        }
      }

      // Clear all cached characteristics and services
      deviceAgent->gattCharacteristics.clear();
      deviceAgent->gattServices.clear();
      deviceAgent->valueChangedTokens.clear();

      // Finally, set the device to null
      deviceAgent->device = nullptr;
    }

    OutputDebugString((L"CleanConnection: Successfully cleaned up device: " +
                       winrt::to_hstring(bluetoothAddress) + L"\n")
                          .c_str());
  } catch (const std::exception &ex) {
    OutputDebugString(
        (L"CleanConnection exception: " + winrt::to_hstring(ex.what()) + L"\n")
            .c_str());
  } catch (...) {
    OutputDebugString(L"CleanConnection unknown exception\n");
  }
}

winrt::fire_and_forget QuickBlueWindowsPlugin::DiscoverServicesAsync(
    BluetoothDeviceAgent &bluetoothDeviceAgent) {
  try {
    if (!bluetoothDeviceAgent.device) {
      OutputDebugString(
          L"DiscoverServicesAsync: Device is null or disconnected\n");
      message_connector_->Send(EncodableMap{
          {"deviceId",
           std::to_string(bluetoothDeviceAgent.device.BluetoothAddress())},
          {"ServiceState", "discovered"}});
      co_return;
    }

    auto serviceResult =
        co_await bluetoothDeviceAgent.device.GetGattServicesAsync();
    if (serviceResult.Status() != GattCommunicationStatus::Success) {
      OutputDebugString((L"DiscoverServicesAsync failed with status: " +
                         winrt::to_hstring((int32_t)serviceResult.Status()) +
                         L"\n")
                            .c_str());
      message_connector_->Send(EncodableMap{
          {"deviceId",
           std::to_string(bluetoothDeviceAgent.device.BluetoothAddress())},
          {"ServiceState", "discovered"}});
      co_return;
    }

    for (auto s : serviceResult.Services()) {
      auto characteristicResult = co_await s.GetCharacteristicsAsync();
      auto msg = EncodableMap{
          {"deviceId",
           std::to_string(bluetoothDeviceAgent.device.BluetoothAddress())},
          {"ServiceState", "discovered"},
          {"service", to_uuidstr(s.Uuid())}};
      if (characteristicResult.Status() == GattCommunicationStatus::Success) {
        EncodableList characteristics;
        for (auto c : characteristicResult.Characteristics()) {
          characteristics.push_back(to_uuidstr(c.Uuid()));
        }
        msg.insert({"characteristics", characteristics});
      }
      message_connector_->Send(msg);
    }
  } catch (const winrt::hresult_error &ex) {
    OutputDebugString((L"DiscoverServicesAsync exception: " + ex.message() +
                       L", code: " + winrt::to_hstring(ex.code()) + L"\n")
                          .c_str());
    message_connector_->Send(EncodableMap{
        {"deviceId",
         std::to_string(bluetoothDeviceAgent.device.BluetoothAddress())},
        {"ServiceState", "discovered"}});
  } catch (const std::exception &ex) {
    OutputDebugString((L"DiscoverServicesAsync std exception: " +
                       winrt::to_hstring(ex.what()) + L"\n")
                          .c_str());
    message_connector_->Send(EncodableMap{
        {"deviceId",
         std::to_string(bluetoothDeviceAgent.device.BluetoothAddress())},
        {"ServiceState", "discovered"}});
  } catch (...) {
    OutputDebugString(L"DiscoverServicesAsync unknown exception\n");
    message_connector_->Send(EncodableMap{
        {"deviceId",
         std::to_string(bluetoothDeviceAgent.device.BluetoothAddress())},
        {"ServiceState", "discovered"}});
  }
}

winrt::fire_and_forget QuickBlueWindowsPlugin::RequestMtuAsync(
    BluetoothDeviceAgent &bluetoothDeviceAgent, uint64_t expectedMtu) {
  try {
    if (!bluetoothDeviceAgent.device) {
      OutputDebugString(L"RequestMtuAsync: Device is null or disconnected\n");
      co_return;
    }

    OutputDebugString((L"RequestMtuAsync expectedMtu: " +
                       winrt::to_hstring(expectedMtu) + L"\n")
                          .c_str());
    auto gattSession = co_await GattSession::FromDeviceIdAsync(
        bluetoothDeviceAgent.device.BluetoothDeviceId());

    if (!gattSession) {
      OutputDebugString(L"RequestMtuAsync: Failed to get GattSession\n");
      co_return;
    }

    message_connector_->Send(EncodableMap{
        {"mtuConfig", (int64_t)gattSession.MaxPduSize()},
    });
  } catch (const winrt::hresult_error &ex) {
    OutputDebugString((L"RequestMtuAsync exception: " + ex.message() +
                       L", code: " + winrt::to_hstring(ex.code()) + L"\n")
                          .c_str());
  } catch (const std::exception &ex) {
    OutputDebugString((L"RequestMtuAsync std exception: " +
                       winrt::to_hstring(ex.what()) + L"\n")
                          .c_str());
  } catch (...) {
    OutputDebugString(L"RequestMtuAsync unknown exception\n");
  }
}

winrt::fire_and_forget QuickBlueWindowsPlugin::SetNotifiableAsync(
    BluetoothDeviceAgent &bluetoothDeviceAgent, std::string service,
    std::string characteristic, std::string bleInputProperty) {
  try {
    // Critical section - first check if device is still valid and connected
    if (!bluetoothDeviceAgent.device || !bluetoothDeviceAgent.IsConnected()) {
      OutputDebugString(
          L"SetNotifiableAsync: Device is null or disconnected\n");
      co_return;
    }

    OutputDebugString((L"SetNotifiableAsync: Starting for characteristic: " +
                       winrt::to_hstring(characteristic) + L", property: " +
                       winrt::to_hstring(bleInputProperty) + L"\n")
                          .c_str());

    // Get the characteristic
    auto gattCharacteristic =
        co_await bluetoothDeviceAgent.GetCharacteristicAsync(service,
                                                             characteristic);

    // Check if the characteristic was found
    if (!gattCharacteristic) {
      OutputDebugString((L"SetNotifiableAsync: Characteristic not found: " +
                         winrt::to_hstring(characteristic) + L"\n")
                            .c_str());
      co_return;
    }

    // If we're disabling notifications, remove the value changed handler first
    if (bleInputProperty == "disabled") {
      // Check if we have a token for this characteristic
      if (bluetoothDeviceAgent.valueChangedTokens.count(characteristic) > 0) {
        try {
          // Remove the event handler
          auto token = bluetoothDeviceAgent.valueChangedTokens[characteristic];
          gattCharacteristic.ValueChanged(token);
          bluetoothDeviceAgent.valueChangedTokens.erase(characteristic);
          OutputDebugString(
              (L"SetNotifiableAsync: Removed notification handler for: " +
               winrt::to_hstring(characteristic) + L"\n")
                  .c_str());
        } catch (const std::exception &ex) {
          OutputDebugString(
              (L"SetNotifiableAsync: Error removing notification handler: " +
               winrt::to_hstring(ex.what()) + L"\n")
                  .c_str());
        }
      }
    }

    // Determine the descriptor value based on the property
    auto descriptorValue =
        bleInputProperty == "notification"
            ? GattClientCharacteristicConfigurationDescriptorValue::Notify
        : bleInputProperty == "indication"
            ? GattClientCharacteristicConfigurationDescriptorValue::Indicate
            : GattClientCharacteristicConfigurationDescriptorValue::None;

    // Write the descriptor
    OutputDebugString((L"SetNotifiableAsync: Writing descriptor for: " +
                       winrt::to_hstring(characteristic) + L"\n")
                          .c_str());

    auto writeDescriptorStatus =
        co_await gattCharacteristic
            .WriteClientCharacteristicConfigurationDescriptorAsync(
                descriptorValue);

    if (writeDescriptorStatus != GattCommunicationStatus::Success) {
      OutputDebugString(
          (L"SetNotifiableAsync: Failed to write descriptor, status: " +
           winrt::to_hstring((int32_t)writeDescriptorStatus) + L"\n")
              .c_str());
      co_return;
    }

    // If we're enabling notifications, add a value changed handler
    if (bleInputProperty != "disabled") {
      // Remove any existing handler first
      if (bluetoothDeviceAgent.valueChangedTokens.count(characteristic) > 0) {
        try {
          auto token = bluetoothDeviceAgent.valueChangedTokens[characteristic];
          gattCharacteristic.ValueChanged(token);
          bluetoothDeviceAgent.valueChangedTokens.erase(characteristic);
        } catch (...) {
          OutputDebugString(L"SetNotifiableAsync: Error removing existing "
                            L"notification handler\n");
        }
      }

      // Add the new handler
      try {
        auto token = gattCharacteristic.ValueChanged(
            {this, &QuickBlueWindowsPlugin::GattCharacteristic_ValueChanged});
        bluetoothDeviceAgent.valueChangedTokens[characteristic] = token;
        OutputDebugString(
            (L"SetNotifiableAsync: Added notification handler for: " +
             winrt::to_hstring(characteristic) + L"\n")
                .c_str());
      } catch (const std::exception &ex) {
        OutputDebugString(
            (L"SetNotifiableAsync: Error adding notification handler: " +
             winrt::to_hstring(ex.what()) + L"\n")
                .c_str());
      }
    }

    OutputDebugString((L"SetNotifiableAsync: Successfully set property for: " +
                       winrt::to_hstring(characteristic) + L"\n")
                          .c_str());
  } catch (const winrt::hresult_error &ex) {
    OutputDebugString((L"SetNotifiableAsync exception: " + ex.message() +
                       L", code: " + winrt::to_hstring(ex.code()) + L"\n")
                          .c_str());
  } catch (const std::exception &ex) {
    OutputDebugString((L"SetNotifiableAsync std exception: " +
                       winrt::to_hstring(ex.what()) + L"\n")
                          .c_str());
  } catch (...) {
    OutputDebugString(L"SetNotifiableAsync unknown exception\n");
  }
}

winrt::fire_and_forget QuickBlueWindowsPlugin::ReadValueAsync(
    BluetoothDeviceAgent &bluetoothDeviceAgent, std::string service,
    std::string characteristic) {
  try {
    if (!bluetoothDeviceAgent.device) {
      OutputDebugString(L"ReadValueAsync: Device is null or disconnected\n");
      co_return;
    }

    auto gattCharacteristic =
        co_await bluetoothDeviceAgent.GetCharacteristicAsync(service,
                                                             characteristic);

    if (!gattCharacteristic) {
      OutputDebugString((L"ReadValueAsync: Characteristic not found: " +
                         winrt::to_hstring(characteristic) + L"\n")
                            .c_str());
      co_return;
    }

    auto readValueResult = co_await gattCharacteristic.ReadValueAsync();

    if (readValueResult.Status() != GattCommunicationStatus::Success) {
      OutputDebugString((L"ReadValueAsync failed with status: " +
                         winrt::to_hstring((int32_t)readValueResult.Status()) +
                         L"\n")
                            .c_str());
      co_return;
    }

    auto bytes = to_bytevc(readValueResult.Value());
    OutputDebugString((L"ReadValueAsync " + winrt::to_hstring(characteristic) +
                       L", " + winrt::to_hstring(to_hexstring(bytes)) + L"\n")
                          .c_str());
    message_connector_->Send(EncodableMap{
        {"deviceId",
         std::to_string(
             gattCharacteristic.Service().Device().BluetoothAddress())},
        {"characteristicValue",
         EncodableMap{
             {"characteristic", characteristic},
             {"value", bytes},
         }},
    });
  } catch (const winrt::hresult_error &ex) {
    OutputDebugString((L"ReadValueAsync exception: " + ex.message() +
                       L", code: " + winrt::to_hstring(ex.code()) + L"\n")
                          .c_str());
  } catch (const std::exception &ex) {
    OutputDebugString((L"ReadValueAsync std exception: " +
                       winrt::to_hstring(ex.what()) + L"\n")
                          .c_str());
  } catch (...) {
    OutputDebugString(L"ReadValueAsync unknown exception\n");
  }
}

// Add a new method to safely get a characteristic and handle nulls
winrt::fire_and_forget QuickBlueWindowsPlugin::WriteValueAsync(
    BluetoothDeviceAgent &bluetoothDeviceAgent, std::string service,
    std::string characteristic, std::vector<uint8_t> value,
    std::string bleOutputProperty) {
  try {
    // Critical section - first check if device is still valid
    if (!bluetoothDeviceAgent.device ||
        bluetoothDeviceAgent.device.ConnectionStatus() !=
            BluetoothConnectionStatus::Connected) {
      OutputDebugString(L"WriteValueAsync: Device is null or disconnected\n");
      co_return;
    }

    OutputDebugString((L"WriteValueAsync: Starting for characteristic: " +
                       winrt::to_hstring(characteristic) + L", value size: " +
                       winrt::to_hstring(value.size()) + L"\n")
                          .c_str());

    // Create a copy of the vector to avoid potential memory issues
    auto valueCopy = std::vector<uint8_t>(value);

    // Get the characteristic
    auto gattCharacteristic =
        co_await bluetoothDeviceAgent.GetCharacteristicAsync(service,
                                                             characteristic);

    // Check if the characteristic was found
    if (!gattCharacteristic) {
      OutputDebugString((L"WriteValueAsync: Characteristic not found: " +
                         winrt::to_hstring(characteristic) + L"\n")
                            .c_str());
      co_return;
    }

    // Prepare write option
    auto writeOption = bleOutputProperty.compare("withoutResponse") == 0
                           ? GattWriteOption::WriteWithoutResponse
                           : GattWriteOption::WriteWithResponse;

    // Create buffer from value
    auto buffer = from_bytevc(valueCopy);

    OutputDebugString((L"WriteValueAsync: About to write to characteristic: " +
                       winrt::to_hstring(characteristic) + L"\n")
                          .c_str());

    // Write value to characteristic
    auto writeValueStatus =
        co_await gattCharacteristic.WriteValueAsync(buffer, writeOption);

    OutputDebugString((L"WriteValueAsync: Completed with status: " +
                       winrt::to_hstring((int32_t)writeValueStatus) + L"\n")
                          .c_str());

    // Notify the caller of the write status
    if (writeValueStatus != GattCommunicationStatus::Success) {
      OutputDebugString((L"WriteValueAsync failed with status: " +
                         winrt::to_hstring((int32_t)writeValueStatus) + L"\n")
                            .c_str());
    }
  } catch (const winrt::hresult_error &ex) {
    OutputDebugString((L"WriteValueAsync exception: " + ex.message() +
                       L", code: " + winrt::to_hstring(ex.code()) + L"\n")
                          .c_str());
  } catch (const std::exception &ex) {
    OutputDebugString((L"WriteValueAsync std exception: " +
                       winrt::to_hstring(ex.what()) + L"\n")
                          .c_str());
  } catch (...) {
    OutputDebugString(L"WriteValueAsync unknown exception\n");
  }
}

void QuickBlueWindowsPlugin::GattCharacteristic_ValueChanged(
    GattCharacteristic sender, GattValueChangedEventArgs args) {
  try {
    if (!sender) {
      OutputDebugString(L"GattCharacteristic_ValueChanged: Sender is null\n");
      return;
    }

    if (!args) {
      OutputDebugString(L"GattCharacteristic_ValueChanged: Args is null\n");
      return;
    }

    auto uuid = to_uuidstr(sender.Uuid());

    OutputDebugString(
        (L"GattCharacteristic_ValueChanged: Event for characteristic: " +
         winrt::to_hstring(uuid) + L"\n")
            .c_str());

    // Get the value from the arguments
    auto value = args.CharacteristicValue();
    if (!value) {
      OutputDebugString(
          L"GattCharacteristic_ValueChanged: Value buffer is null\n");
      return;
    }

    auto bytes = to_bytevc(value);

    // Get device address
    uint64_t deviceAddress = 0;
    try {
      auto service = sender.Service();
      if (!service) {
        OutputDebugString(
            L"GattCharacteristic_ValueChanged: Service is null\n");
        return;
      }

      auto device = service.Device();
      if (!device) {
        OutputDebugString(L"GattCharacteristic_ValueChanged: Device is null\n");
        return;
      }

      deviceAddress = device.BluetoothAddress();
    } catch (const std::exception &ex) {
      OutputDebugString(
          (L"GattCharacteristic_ValueChanged: Error getting device address: " +
           winrt::to_hstring(ex.what()) + L"\n")
              .c_str());
      return;
    }

    OutputDebugString((L"GattCharacteristic_ValueChanged: Received " +
                       winrt::to_hstring(bytes.size()) +
                       L" bytes from device " +
                       winrt::to_hstring(deviceAddress) + L"\n")
                          .c_str());

    // Send the value back to Dart
    message_connector_->Send(EncodableMap{
        {"deviceId", std::to_string(deviceAddress)},
        {"characteristicValue",
         EncodableMap{
             {"characteristic", uuid},
             {"value", bytes},
         }},
    });
  } catch (const winrt::hresult_error &ex) {
    OutputDebugString((L"GattCharacteristic_ValueChanged exception: " +
                       ex.message() + L", code: " +
                       winrt::to_hstring(ex.code()) + L"\n")
                          .c_str());
  } catch (const std::exception &ex) {
    OutputDebugString((L"GattCharacteristic_ValueChanged std exception: " +
                       winrt::to_hstring(ex.what()) + L"\n")
                          .c_str());
  } catch (...) {
    OutputDebugString(L"GattCharacteristic_ValueChanged unknown exception\n");
  }
}

extern "C" __declspec(dllexport) void QuickBlueWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  QuickBlueWindowsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
