#pragma once
#include <string>

namespace sd {
// Pure validation: only an ASCII HTTPS origin and fixed public account pages.
// Throws INVALID_ARGUMENT; never launches a browser or accepts credential queries.
std::wstring ServicePage(const std::string& origin, const std::string& page);
}
