#include "include/quick_blue_windows/quick_blue_windows_plugin.h"
#include "service_uuid.h"

// This must be included before many other Windows headers.
#include <windows.h>
#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Radios.h>
#include <winrt/Windows.Devices.Enumeration.h>
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
#include <atomic>
#include <chrono>
#include <deque>
#include <functional>
#include <iomanip>
#include <map>
#include <memory>
#include <mutex>
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
  const auto company = manufacturerData.CompanyId();
  auto result = std::vector<uint8_t>{static_cast<uint8_t>(company & 0xff),
                                     static_cast<uint8_t>(company >> 8)};

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
  std::atomic<uint64_t> scanGeneration_{0};
  struct ScanDelivery {
    std::mutex mutex;
    HWND window = nullptr;
    UINT message = RegisterWindowMessage(L"quick_blue_windows.scan_result");
    std::deque<std::pair<uint64_t, BluetoothLEAdvertisementReceivedEventArgs>>
        pending;
    std::deque<std::function<void()>> tasks;
    std::map<uint64_t, uint64_t> connectionGenerations;
  };
  std::shared_ptr<ScanDelivery> scanDelivery_ = std::make_shared<ScanDelivery>();
  flutter::PluginRegistrarWindows* registrar_ = nullptr;
  int windowProcId_ = -1;
  void SendConnectionMessage(EncodableValue message) {
    PostPlatformTask(scanDelivery_, [this, message = std::move(message)]() {
      message_connector_->Send(message);
    });
  }
  static void PostPlatformTask(const std::shared_ptr<ScanDelivery>& delivery,
                               std::function<void()> task);
  static winrt::fire_and_forget GetSystemConnectedDevicesAsync(
      std::shared_ptr<ScanDelivery> delivery, std::string serviceId,
      std::shared_ptr<flutter::MethodResult<EncodableValue>> result);
  winrt::event_token bluetoothLEWatcherReceivedToken;
  void SendScanResult(BluetoothLEAdvertisementReceivedEventArgs args);

  std::map<uint64_t, std::shared_ptr<BluetoothDeviceAgent>> connectedDevices{};

  static winrt::fire_and_forget CompleteGattOperationAsync(
      std::shared_ptr<ScanDelivery> delivery, IAsyncAction operation,
      std::shared_ptr<flutter::MethodResult<EncodableValue>> result);

  winrt::fire_and_forget ConnectAsync(uint64_t bluetoothAddress,
                                     uint64_t generation);
  void BluetoothLEDevice_ConnectionStatusChanged(BluetoothLEDevice sender,
                                                 IInspectable args);
  void CleanConnection(uint64_t bluetoothAddress);
  winrt::fire_and_forget
  DiscoverServicesAsync(std::shared_ptr<BluetoothDeviceAgent> bluetoothDeviceAgent);
  IAsyncAction
  SetNotifiableAsync(std::shared_ptr<BluetoothDeviceAgent> bluetoothDeviceAgent,
                     std::string service, std::string characteristic,
                     std::string bleInputProperty);
  winrt::fire_and_forget
  RequestMtuAsync(BluetoothDeviceAgent &bluetoothDeviceAgent,
                  uint64_t expectedMtu);
  winrt::fire_and_forget
  ReadValueAsync(BluetoothDeviceAgent &bluetoothDeviceAgent,
                 std::string service, std::string characteristic);
  IAsyncAction
  WriteValueAsync(std::shared_ptr<BluetoothDeviceAgent> bluetoothDeviceAgent,
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
  plugin->registrar_ = registrar;
  plugin->windowProcId_ = registrar->RegisterTopLevelWindowProcDelegate(
      [pointer = plugin.get()](HWND, UINT message, WPARAM, LPARAM)
          -> std::optional<LRESULT> {
        if (message != pointer->scanDelivery_->message) return std::nullopt;
        decltype(pointer->scanDelivery_->pending) pending;
        std::deque<std::function<void()>> tasks;
        {
          std::lock_guard<std::mutex> lock(pointer->scanDelivery_->mutex);
          pending.swap(pointer->scanDelivery_->pending);
          tasks.swap(pointer->scanDelivery_->tasks);
        }
        for (auto& task : tasks) task();
        for (const auto& entry : pending) {
          if (entry.first == pointer->scanGeneration_.load()) {
            pointer->SendScanResult(entry.second);
          }
        }
        return 0;
      });

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

QuickBlueWindowsPlugin::~QuickBlueWindowsPlugin() {
  {
    std::lock_guard<std::mutex> lock(scanDelivery_->mutex);
    scanDelivery_->window = nullptr;
    scanDelivery_->pending.clear();
    scanDelivery_->tasks.clear();
  }
  if (bluetoothLEWatcher) {
    try {
      bluetoothLEWatcher.Received(bluetoothLEWatcherReceivedToken);
      bluetoothLEWatcher.Stop();
    } catch (const winrt::hresult_error&) {
      // The radio may already have disappeared during application shutdown.
    }
  }
  if (registrar_) registrar_->UnregisterTopLevelWindowProcDelegate(windowProcId_);
}

winrt::fire_and_forget QuickBlueWindowsPlugin::InitializeAsync() {
  auto bluetoothAdapter = co_await BluetoothAdapter::GetDefaultAsync();
  bluetoothRadio = co_await bluetoothAdapter.GetRadioAsync();
}

void QuickBlueWindowsPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  auto method_name = method_call.method_name();
  {
    std::lock_guard<std::mutex> lock(scanDelivery_->mutex);
    scanDelivery_->window = GetAncestor(
        registrar_->GetView()->GetNativeWindow(), GA_ROOT);
  }
  OutputDebugString(
      (L"HandleMethodCall " + winrt::to_hstring(method_name) + L"\n").c_str());
  if (method_name.compare("isBluetoothAvailable") == 0) {
    result->Success(EncodableValue(bluetoothRadio &&
                                   bluetoothRadio.State() == RadioState::On));
  } else if (method_name.compare("getSystemConnectedDevices") == 0) {
    const auto* args = method_call.arguments()
        ? std::get_if<EncodableMap>(method_call.arguments()) : nullptr;
    const auto service = args ? args->find(EncodableValue("serviceId"))
                              : EncodableMap::const_iterator{};
    const auto* value = args && service != args->end()
        ? std::get_if<std::string>(&service->second) : nullptr;
    const auto uuid = value ? quick_blue::NormalizeServiceUuid(*value)
                            : std::nullopt;
    if (!uuid) {
      result->Error("invalid_service_uuid", "A service UUID is required.");
      return;
    }
    GetSystemConnectedDevicesAsync(scanDelivery_, *uuid, std::move(result));
  } else if (method_name.compare("startScan") == 0) {
    std::optional<std::string> serviceId;
    if (method_call.arguments()) {
      const auto* args = std::get_if<EncodableMap>(method_call.arguments());
      if (!args) {
        result->Error("invalid_arguments", "Scan arguments must be a map.");
        return;
      }
      const auto service = args->find(EncodableValue("serviceId"));
      if (service != args->end() &&
          !std::holds_alternative<std::monostate>(service->second)) {
        const auto* value = std::get_if<std::string>(&service->second);
        if (!value || !(serviceId = quick_blue::NormalizeServiceUuid(*value))) {
          result->Error("invalid_service_uuid",
                        "Expected a Bluetooth service UUID.");
          return;
        }
      }
    }
    // Filters cannot be changed on a running watcher. Recreate it so switching
    // from filtered to unfiltered scans cannot retain an old service filter.
    const auto generation = ++scanGeneration_;
    {
      std::lock_guard<std::mutex> lock(scanDelivery_->mutex);
      // Plugin registration precedes runner reparenting of the Flutter view.
      // Resolve its top-level window only once scanning is actually requested.
      scanDelivery_->window = GetAncestor(
          registrar_->GetView()->GetNativeWindow(), GA_ROOT);
      scanDelivery_->pending.clear();
    }
    if (bluetoothLEWatcher) {
      bluetoothLEWatcher.Stop();
      bluetoothLEWatcher.Received(bluetoothLEWatcherReceivedToken);
    }
    bluetoothLEWatcher = BluetoothLEAdvertisementWatcher();
    bluetoothLEWatcher.ScanningMode(BluetoothLEScanningMode::Active);
    std::optional<winrt::guid> requestedUuid;
    if (serviceId) {
      GUID uuid{};
      winrt::check_hresult(IIDFromString(
          winrt::to_hstring("{" + *serviceId + "}").c_str(), &uuid));
      requestedUuid = winrt::guid(uuid);
      bluetoothLEWatcher.AdvertisementFilter().Advertisement().ServiceUuids()
          .Append(*requestedUuid);
    }
    const auto delivery = scanDelivery_;
    bluetoothLEWatcherReceivedToken = bluetoothLEWatcher.Received(
        [delivery, generation, requestedUuid](
            BluetoothLEAdvertisementWatcher,
            BluetoothLEAdvertisementReceivedEventArgs args) {
          // Also enforce the advertised UUID here: radio/driver filtering must
          // never leak unrelated devices into a service-specific scan.
          if (requestedUuid) {
            bool matches = false;
            for (const auto uuid : args.Advertisement().ServiceUuids()) {
              if (uuid == *requestedUuid) {
                matches = true;
                break;
              }
            }
            if (!matches) return;
          }
          std::lock_guard<std::mutex> lock(delivery->mutex);
          if (!delivery->window) return;
          const bool notify = delivery->pending.empty();
          delivery->pending.emplace_back(generation, args);
          if (notify) PostMessage(delivery->window, delivery->message, 0, 0);
        });
    bluetoothLEWatcher.Start();
    result->Success(nullptr);
  } else if (method_name.compare("stopScan") == 0) {
    ++scanGeneration_;
    if (bluetoothLEWatcher) {
      bluetoothLEWatcher.Stop();
      bluetoothLEWatcher.Received(bluetoothLEWatcherReceivedToken);
    }
    bluetoothLEWatcher = nullptr;
    result->Success(nullptr);
  } else if (method_name.compare("connect") == 0) {
    auto args = std::get<EncodableMap>(*method_call.arguments());
    auto deviceId = std::get<std::string>(args[EncodableValue("deviceId")]);
    const auto address = std::stoull(deviceId);
    uint64_t generation;
    {
      std::lock_guard<std::mutex> lock(scanDelivery_->mutex);
      generation = ++scanDelivery_->connectionGenerations[address];
    }
    ConnectAsync(address, generation);
    result->Success(nullptr);
  } else if (method_name.compare("disconnect") == 0) {
    auto args = std::get<EncodableMap>(*method_call.arguments());
    auto deviceId = std::get<std::string>(args[EncodableValue("deviceId")]);
    const auto address = std::stoull(deviceId);
    {
      std::lock_guard<std::mutex> lock(scanDelivery_->mutex);
      ++scanDelivery_->connectionGenerations[address];
    }
    CleanConnection(address);
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
    DiscoverServicesAsync(it->second);
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

    CompleteGattOperationAsync(scanDelivery_,
        SetNotifiableAsync(it->second, service, characteristic, bleInputProperty),
        std::move(result));
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

    CompleteGattOperationAsync(scanDelivery_,
        WriteValueAsync(it->second, service, characteristic, value,
                        bleOutputProperty), std::move(result));
  } else {
    result->NotImplemented();
  }
}

void QuickBlueWindowsPlugin::PostPlatformTask(
    const std::shared_ptr<ScanDelivery>& delivery, std::function<void()> task) {
  std::lock_guard<std::mutex> lock(delivery->mutex);
  if (!delivery->window) return;
  delivery->tasks.push_back(std::move(task));
  PostMessage(delivery->window, delivery->message, 0, 0);
}

winrt::fire_and_forget QuickBlueWindowsPlugin::GetSystemConnectedDevicesAsync(
    std::shared_ptr<ScanDelivery> delivery, std::string serviceId,
    std::shared_ptr<flutter::MethodResult<EncodableValue>> result) {
  try {
    GUID nativeUuid{};
    winrt::check_hresult(IIDFromString(
        winrt::to_hstring("{" + serviceId + "}").c_str(), &nativeUuid));
    const auto selector = BluetoothLEDevice::GetDeviceSelectorFromConnectionStatus(
        BluetoothConnectionStatus::Connected);
    const auto devices = co_await
        winrt::Windows::Devices::Enumeration::DeviceInformation::FindAllAsync(selector);
    EncodableList matches;
    for (const auto info : devices) {
      auto device = co_await BluetoothLEDevice::FromIdAsync(info.Id());
      if (!device) continue;
      if (device.ConnectionStatus() == BluetoothConnectionStatus::Connected) {
        const auto services = co_await device.GetGattServicesForUuidAsync(
            winrt::guid(nativeUuid), BluetoothCacheMode::Cached);
        if (services.Status() == GattCommunicationStatus::Success &&
            services.Services().Size() > 0) {
          matches.push_back(EncodableMap{
              {"name", winrt::to_string(device.Name())},
              {"deviceId", std::to_string(device.BluetoothAddress())}});
        }
      }
    }
    PostPlatformTask(delivery, [result, matches = std::move(matches)]() {
      result->Success(EncodableValue(matches));
    });
  } catch (const winrt::hresult_error& error) {
    const auto message = winrt::to_string(error.message());
    PostPlatformTask(delivery, [result, message]() {
      result->Error("system_connected_devices_failed", message);
    });
  }
}

void QuickBlueWindowsPlugin::SendScanResult(
    BluetoothLEAdvertisementReceivedEventArgs args) {
  // Advertisements already carry the scan name. Opening a Windows GATT device
  // for every advertisement creates handles/async work for unrelated devices
  // and can hold up discovery when the radio/driver is busy.
  auto name = args.Advertisement().LocalName();
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
QuickBlueWindowsPlugin::ConnectAsync(uint64_t bluetoothAddress,
                                    uint64_t generation) {
  const winrt::apartment_context apartment;
  const auto delivery = scanDelivery_;
  const auto current = [delivery, bluetoothAddress, generation]() {
    std::lock_guard<std::mutex> lock(delivery->mutex);
    return delivery->window &&
           delivery->connectionGenerations[bluetoothAddress] == generation;
  };
  try {
    // Windows can transiently fail service admission after a rapid reconnect.
    // Retry only the unopened transport, at most once, within the SDK deadline.
    // No commands or measurement/replay mutations are retried here.
    for (int attempt = 0; attempt < 2; ++attempt) {
      auto device = co_await BluetoothLEDevice::FromBluetoothAddressAsync(
          bluetoothAddress);

      if (!device) {
        if (current())
          SendConnectionMessage(
              EncodableMap{{"deviceId", std::to_string(bluetoothAddress)},
                           {"ConnectionState", "disconnected"}});
        co_return;
      }
      if (!current()) {
        device.Close();
        co_return;
      }
      auto servicesResult = co_await device.GetGattServicesAsync();
      if (!current()) {
        for (const auto service : servicesResult.Services())
          service.Close();
        device.Close();
        co_return;
      }
      if (servicesResult.Status() != GattCommunicationStatus::Success) {
        OutputDebugString((L"GetGattServicesAsync error: " +
                           winrt::to_hstring((int32_t)servicesResult.Status()) +
                           L"\n")
                              .c_str());
        for (const auto service : servicesResult.Services())
          service.Close();
        device.Close();
        if (attempt == 0 &&
            servicesResult.Status() == GattCommunicationStatus::Unreachable &&
            current()) {
          OutputDebugString(
              L"ConnectAsync: retrying transient GATT admission once\n");
          co_await winrt::resume_after(std::chrono::milliseconds(300));
          // resume_after uses the thread pool. Restore the platform apartment
          // before accessing the plugin's connection map or creating handlers.
          co_await apartment;
          if (!current())
            co_return;
          continue;
        }
        SendConnectionMessage(EncodableMap{
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
      // Retain the initial GATT handles under the link owner. Dropping only COM
      // references does not deterministically release Windows service
      // resources.
      for (const auto service : servicesResult.Services()) {
        deviceAgent->gattServices.emplace(to_uuidstr(service.Uuid()), service);
      }
      auto pair = std::make_pair(bluetoothAddress, std::move(deviceAgent));
      connectedDevices.insert(std::move(pair));

      SendConnectionMessage(EncodableMap{
          {"deviceId", std::to_string(bluetoothAddress)},
          {"ConnectionState", "connected"},
      });
      co_return;
    }
  } catch (const winrt::hresult_error &ex) {
    if (!current())
      co_return;
    OutputDebugString((L"ConnectAsync exception: " + ex.message() +
                       L", code: " + winrt::to_hstring(ex.code()) + L"\n")
                          .c_str());
    SendConnectionMessage(EncodableMap{
        {"deviceId", std::to_string(bluetoothAddress)},
        {"ConnectionState", "disconnected"},
    });
  } catch (const std::exception &ex) {
    if (!current())
      co_return;
    OutputDebugString(
        (L"ConnectAsync std exception: " + winrt::to_hstring(ex.what()) + L"\n")
            .c_str());
    SendConnectionMessage(EncodableMap{
        {"deviceId", std::to_string(bluetoothAddress)},
        {"ConnectionState", "disconnected"},
    });
  } catch (...) {
    if (!current())
      co_return;
    OutputDebugString(L"ConnectAsync unknown exception\n");
    SendConnectionMessage(EncodableMap{
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
      const auto address = sender.BluetoothAddress();
      PostPlatformTask(scanDelivery_, [this, address, sender]() {
        const auto found = connectedDevices.find(address);
        if (found == connectedDevices.end() || found->second->device != sender)
          return;
        CleanConnection(address);
        SendConnectionMessage(
            EncodableMap{{"deviceId", std::to_string(address)},
                         {"ConnectionState", "disconnected"}});
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
      for (const auto &entry : deviceAgent->gattServices) {
        try {
          if (entry.second)
            entry.second.Close();
        } catch (...) {
          OutputDebugString(L"CleanConnection: Error closing GATT service\n");
        }
      }
      deviceAgent->gattServices.clear();
      deviceAgent->valueChangedTokens.clear();

      // Finally, set the device to null
      try {
        if (deviceAgent->device)
          deviceAgent->device.Close();
      } catch (...) {
        OutputDebugString(L"CleanConnection: Error closing BLE device\n");
      }
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
    std::shared_ptr<BluetoothDeviceAgent> bluetoothDeviceAgent) {
  const auto device = bluetoothDeviceAgent->device;
  if (!device)
    co_return;
  const auto address = device.BluetoothAddress();
  try {
    if (!bluetoothDeviceAgent->device) {
      OutputDebugString(
          L"DiscoverServicesAsync: Device is null or disconnected\n");
      SendConnectionMessage(EncodableMap{{"deviceId", std::to_string(address)},
                                         {"ServiceState", "discovered"}});
      co_return;
    }

    // The connection owns the already-enumerated service handles. Do not open
    // another set on every discovery/command. Copy the map across suspension so
    // cancellation can clear the owner's cache without invalidating iterators.
    const auto services = bluetoothDeviceAgent->gattServices;
    for (const auto &entry : services) {
      const auto s = entry.second;
      auto characteristicResult = co_await s.GetCharacteristicsAsync();
      if (bluetoothDeviceAgent->device != device)
        co_return;
      auto msg = EncodableMap{{"deviceId", std::to_string(address)},
                              {"ServiceState", "discovered"},
                              {"service", to_uuidstr(s.Uuid())}};
      if (characteristicResult.Status() == GattCommunicationStatus::Success) {
        EncodableList characteristics;
        for (auto c : characteristicResult.Characteristics()) {
          characteristics.push_back(to_uuidstr(c.Uuid()));
          bluetoothDeviceAgent->gattCharacteristics.emplace(
              to_uuidstr(c.Uuid()), c);
        }
        msg.insert({"characteristics", characteristics});
      }
      SendConnectionMessage(msg);
    }
  } catch (const winrt::hresult_error &ex) {
    if (bluetoothDeviceAgent->device != device)
      co_return;
    OutputDebugString((L"DiscoverServicesAsync exception: " + ex.message() +
                       L", code: " + winrt::to_hstring(ex.code()) + L"\n")
                          .c_str());
    SendConnectionMessage(EncodableMap{{"deviceId", std::to_string(address)},
                                       {"ServiceState", "discovered"}});
  } catch (const std::exception &ex) {
    if (bluetoothDeviceAgent->device != device)
      co_return;
    OutputDebugString((L"DiscoverServicesAsync std exception: " +
                       winrt::to_hstring(ex.what()) + L"\n")
                          .c_str());
    SendConnectionMessage(EncodableMap{{"deviceId", std::to_string(address)},
                                       {"ServiceState", "discovered"}});
  } catch (...) {
    if (bluetoothDeviceAgent->device != device)
      co_return;
    OutputDebugString(L"DiscoverServicesAsync unknown exception\n");
    SendConnectionMessage(EncodableMap{{"deviceId", std::to_string(address)},
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

    SendConnectionMessage(EncodableMap{
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

winrt::fire_and_forget QuickBlueWindowsPlugin::CompleteGattOperationAsync(
    std::shared_ptr<ScanDelivery> delivery, IAsyncAction operation,
    std::shared_ptr<flutter::MethodResult<EncodableValue>> result) {
  std::string error;
  try {
    co_await operation;
  } catch (const winrt::hresult_error &ex) {
    error = winrt::to_string(ex.message());
  } catch (const std::exception &ex) {
    error = ex.what();
  } catch (...) {
    error = "Unknown GATT operation failure";
  }
  PostPlatformTask(delivery, [result, error]() {
    if (error.empty()) {
      result->Success(nullptr);
    } else {
      result->Error("GattOperationFailed", error);
    }
  });
}

IAsyncAction QuickBlueWindowsPlugin::SetNotifiableAsync(
    std::shared_ptr<BluetoothDeviceAgent> bluetoothDeviceAgent, std::string service,
    std::string characteristic, std::string bleInputProperty) {
  try {
    // Critical section - first check if device is still valid and connected
    if (!bluetoothDeviceAgent->device || !bluetoothDeviceAgent->IsConnected()) {
      OutputDebugString(
          L"SetNotifiableAsync: Device is null or disconnected\n");
      throw winrt::hresult_error(E_FAIL, L"Sensor disconnected before notification setup");
    }

    OutputDebugString((L"SetNotifiableAsync: Starting for characteristic: " +
                       winrt::to_hstring(characteristic) + L", property: " +
                       winrt::to_hstring(bleInputProperty) + L"\n")
                          .c_str());

    // Get the characteristic
    auto gattCharacteristic =
        co_await bluetoothDeviceAgent->GetCharacteristicAsync(service,
                                                             characteristic);

    // Check if the characteristic was found
    if (!gattCharacteristic) {
      OutputDebugString((L"SetNotifiableAsync: Characteristic not found: " +
                         winrt::to_hstring(characteristic) + L"\n")
                            .c_str());
      throw winrt::hresult_error(E_FAIL, L"Notification characteristic not found");
    }

    // If we're disabling notifications, remove the value changed handler first
    if (bleInputProperty == "disabled") {
      // Check if we have a token for this characteristic
      if (bluetoothDeviceAgent->valueChangedTokens.count(characteristic) > 0) {
        try {
          // Remove the event handler
          auto token = bluetoothDeviceAgent->valueChangedTokens[characteristic];
          gattCharacteristic.ValueChanged(token);
          bluetoothDeviceAgent->valueChangedTokens.erase(characteristic);
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

    // If we're enabling notifications, add a value changed handler
    if (bleInputProperty != "disabled") {
      // Remove any existing handler first
      if (bluetoothDeviceAgent->valueChangedTokens.count(characteristic) > 0) {
        try {
          auto token = bluetoothDeviceAgent->valueChangedTokens[characteristic];
          gattCharacteristic.ValueChanged(token);
          bluetoothDeviceAgent->valueChangedTokens.erase(characteristic);
        } catch (...) {
          OutputDebugString(L"SetNotifiableAsync: Error removing existing "
                            L"notification handler\n");
        }
      }

      // Add the new handler
      try {
        auto token = gattCharacteristic.ValueChanged(
            {this, &QuickBlueWindowsPlugin::GattCharacteristic_ValueChanged});
        bluetoothDeviceAgent->valueChangedTokens[characteristic] = token;
        OutputDebugString(
            (L"SetNotifiableAsync: Added notification handler for: " +
             winrt::to_hstring(characteristic) + L"\n")
                .c_str());
      } catch (const std::exception &ex) {
        OutputDebugString(
            (L"SetNotifiableAsync: Error adding notification handler: " +
              winrt::to_hstring(ex.what()) + L"\n")
                .c_str());
        throw;
      }
    }

    // Install the receiver before enabling notifications. Legacy sensors may
    // start replay immediately when CCCD changes, before its write completes.
    auto writeDescriptorStatus =
        co_await gattCharacteristic
            .WriteClientCharacteristicConfigurationDescriptorAsync(
                descriptorValue);
    if (writeDescriptorStatus != GattCommunicationStatus::Success) {
      throw winrt::hresult_error(E_FAIL, L"Notification descriptor write failed");
    }

    OutputDebugString((L"SetNotifiableAsync: Successfully set property for: " +
                       winrt::to_hstring(characteristic) + L"\n")
                          .c_str());
  } catch (const winrt::hresult_error &ex) {
    OutputDebugString((L"SetNotifiableAsync exception: " + ex.message() +
                       L", code: " + winrt::to_hstring(ex.code()) + L"\n")
                          .c_str());
    throw;
  } catch (const std::exception &ex) {
    OutputDebugString((L"SetNotifiableAsync std exception: " +
                       winrt::to_hstring(ex.what()) + L"\n")
                          .c_str());
    throw;
  } catch (...) {
    OutputDebugString(L"SetNotifiableAsync unknown exception\n");
    throw;
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
    SendConnectionMessage(EncodableMap{
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
IAsyncAction QuickBlueWindowsPlugin::WriteValueAsync(
    std::shared_ptr<BluetoothDeviceAgent> bluetoothDeviceAgent, std::string service,
    std::string characteristic, std::vector<uint8_t> value,
    std::string bleOutputProperty) {
  try {
    // Critical section - first check if device is still valid
    if (!bluetoothDeviceAgent->device ||
        bluetoothDeviceAgent->device.ConnectionStatus() !=
            BluetoothConnectionStatus::Connected) {
      OutputDebugString(L"WriteValueAsync: Device is null or disconnected\n");
      throw winrt::hresult_error(E_FAIL, L"Sensor disconnected before command write");
    }

    OutputDebugString((L"WriteValueAsync: Starting for characteristic: " +
                       winrt::to_hstring(characteristic) + L", value size: " +
                       winrt::to_hstring(value.size()) + L"\n")
                          .c_str());

    // Create a copy of the vector to avoid potential memory issues
    auto valueCopy = std::vector<uint8_t>(value);

    // Get the characteristic
    auto gattCharacteristic =
        co_await bluetoothDeviceAgent->GetCharacteristicAsync(service,
                                                             characteristic);

    // Check if the characteristic was found
    if (!gattCharacteristic) {
      OutputDebugString((L"WriteValueAsync: Characteristic not found: " +
                         winrt::to_hstring(characteristic) + L"\n")
                            .c_str());
      throw winrt::hresult_error(E_FAIL, L"Write characteristic not found");
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
      throw winrt::hresult_error(E_FAIL, L"Sensor command write failed");
    }
  } catch (const winrt::hresult_error &ex) {
    OutputDebugString((L"WriteValueAsync exception: " + ex.message() +
                       L", code: " + winrt::to_hstring(ex.code()) + L"\n")
                          .c_str());
    throw;
  } catch (const std::exception &ex) {
    OutputDebugString((L"WriteValueAsync std exception: " +
                       winrt::to_hstring(ex.what()) + L"\n")
                          .c_str());
    throw;
  } catch (...) {
    OutputDebugString(L"WriteValueAsync unknown exception\n");
    throw;
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
    SendConnectionMessage(EncodableMap{
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
