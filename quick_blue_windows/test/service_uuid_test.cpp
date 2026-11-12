#include "../windows/service_uuid.h"
#include <cassert>

int main() {
  using quick_blue::NormalizeServiceUuid;
  assert(NormalizeServiceUuid("180D") == "0000180d-0000-1000-8000-00805f9b34fb");
  assert(NormalizeServiceUuid("12345678") == "12345678-0000-1000-8000-00805f9b34fb");
  assert(NormalizeServiceUuid("6E400001-C352-11E5-953D-0002A5D5C51B") ==
         "6e400001-c352-11e5-953d-0002a5d5c51b");
  assert(!NormalizeServiceUuid(""));
  assert(!NormalizeServiceUuid("not-a-uuid"));
  assert(!NormalizeServiceUuid("6e400001xc352-11e5-953d-0002a5d5c51b"));
  assert(!NormalizeServiceUuid("6e400001-c352-11e5-953d-0002a5d5c51z"));
}
