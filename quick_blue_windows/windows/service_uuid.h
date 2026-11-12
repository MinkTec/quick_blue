#pragma once

#include <algorithm>
#include <cctype>
#include <optional>
#include <string>

namespace quick_blue {
// Match Android's Bluetooth UUID forms: 16-bit, 32-bit or canonical 128-bit.
inline std::optional<std::string> NormalizeServiceUuid(std::string value) {
  if (value.size() == 4) value = "0000" + value;
  if (value.size() == 8) value += "-0000-1000-8000-00805f9b34fb";
  if (value.size() != 36) return std::nullopt;
  for (size_t i = 0; i < value.size(); ++i) {
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (value[i] != '-') return std::nullopt;
    } else if (!std::isxdigit(static_cast<unsigned char>(value[i]))) {
      return std::nullopt;
    }
  }
  std::transform(value.begin(), value.end(), value.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return value;
}
}  // namespace quick_blue
