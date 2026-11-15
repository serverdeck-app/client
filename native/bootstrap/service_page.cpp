#include <winsock2.h>
#include <ws2tcpip.h>
#include "service_page.h"
#include <stdexcept>
#include <vector>

namespace sd {
namespace {
[[noreturn]] void Invalid() { throw std::invalid_argument("INVALID_ARGUMENT"); }
bool Digit(char c) { return c >= '0' && c <= '9'; }
std::vector<std::string> Labels(const std::string& host) {
  std::vector<std::string> labels;
  size_t start = 0;
  for (;;) {
    const auto end = host.find('.', start);
    labels.push_back(host.substr(start, end == std::string::npos ? end : end - start));
    if (end == std::string::npos) return labels;
    start = end + 1;
  }
}
void Host(std::string host) {
  if (host.empty()) Invalid();
  if (host.front() == '[') {
    if (host.back() != ']') Invalid();
    const auto address = host.substr(1, host.size() - 2);
    IN6_ADDR parsed{};
    if (InetPtonA(AF_INET6, address.c_str(), &parsed) != 1) Invalid();
    return;
  }
  if (host.back() == '.') host.pop_back();
  if (host.empty() || host.size() > 253) Invalid();
  const auto labels = Labels(host);
  for (const auto& label : labels) {
    if (label.empty() || label.size() > 63 || label.front() == '-' || label.back() == '-') Invalid();
    for (const char c : label) {
      if (!Digit(c) && !(c >= 'a' && c <= 'z') && c != '-') Invalid();
    }
  }
  const auto& last = labels.back();
  bool numeric = true;
  for (const char c : last) numeric = numeric && Digit(c);
  bool hexadecimal = last.rfind("0x", 0) == 0;
  for (size_t i = 2; i < last.size(); ++i) {
    const char c = last[i];
    hexadecimal = hexadecimal && (Digit(c) || (c >= 'a' && c <= 'f'));
  }
  // Match browser numeric-host parsing, including the bare hexadecimal zero.
  if (numeric || hexadecimal) {
    if (labels.size() != 4) Invalid();
    for (const auto& label : labels) {
      if (label.size() > 3 || (label.size() > 1 && label.front() == '0')) Invalid();
      unsigned value = 0;
      for (const char c : label) { if (!Digit(c)) Invalid(); value = value * 10 + static_cast<unsigned>(c - '0'); }
      if (value > 255) Invalid();
    }
  }
}
}
std::wstring ServicePage(const std::string& origin, const std::string& page) {
  if (origin.size() > 512 || origin.rfind("https://", 0) != 0 || page.size() > 2048) Invalid();
  for (const auto& text : {origin, page}) {
    for (const unsigned char c : text) if (c <= 32 || c >= 127 || c == '\\') Invalid();
  }
  auto authority = origin.substr(8);
  if (authority.empty() || authority.find_first_of("/@?#%") != std::string::npos) Invalid();
  std::string host, port;
  if (authority.front() == '[') {
    const auto closing = authority.find(']');
    if (closing == std::string::npos) Invalid();
    host = authority.substr(0, closing + 1);
    if (closing + 1 < authority.size()) {
      if (authority[closing + 1] != ':') Invalid();
      port = authority.substr(closing + 2);
      if (port.empty()) Invalid();
    }
  } else {
    const auto colon = authority.find(':');
    host = authority.substr(0, colon);
    if (colon != std::string::npos) { port = authority.substr(colon + 1); if (port.empty()) Invalid(); }
  }
  Host(host);
  if (!port.empty()) {
    if (port.size() > 5) Invalid();
    unsigned number = 0;
    for (const char c : port) { if (!Digit(c)) Invalid(); number = number * 10 + static_cast<unsigned>(c - '0'); }
    if (number == 0 || number > 65535) Invalid();
  }
  bool allowed = page == origin + "/devices" || page == origin + "/account" || page == origin + "/activate";
  const auto prefix = origin + "/activate?user_code=";
  if (page.rfind(prefix, 0) == 0 && page.size() == prefix.size() + 10) {
    allowed = true;
    for (size_t i = prefix.size(); i < page.size(); ++i) {
      if (std::string("ABCDEFGHJKLMNPQRSTUVWXYZ23456789").find(page[i]) == std::string::npos) allowed = false;
    }
  }
  if (!allowed) Invalid();
  return std::wstring(page.begin(), page.end());
}
}
