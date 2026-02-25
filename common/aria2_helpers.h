#ifndef FLUTTER_ARIA2_COMMON_ARIA2_HELPERS_H_
#define FLUTTER_ARIA2_COMMON_ARIA2_HELPERS_H_

#include <aria2_c_api.h>

#include <string>

namespace flutter_aria2::common {

std::string GidToHex(aria2_gid_t gid);

}  // namespace flutter_aria2::common

#endif  // FLUTTER_ARIA2_COMMON_ARIA2_HELPERS_H_
