#include "aria2_helpers.h"

namespace flutter_aria2 {
namespace common {

std::string GidToHex(aria2_gid_t gid) {
  char* hex = aria2_gid_to_hex(gid);
  std::string result = hex == nullptr ? "" : hex;
  if (hex != nullptr) {
    aria2_free(hex);
  }
  return result;
}

}  // namespace common
}  // namespace flutter_aria2
