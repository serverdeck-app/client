#include "service_page.h"
#include <iostream>
#include <stdexcept>
#include <vector>

int main() {
  try {
    for (const auto& origin : {"https://sync.test", "https://sync.test:8443", "https://127.0.0.1", "https://[::1]:8443", "https://xn--e1afmkfd.xn--p1ai", "https://sync.0xg"}) {
      for (const auto& suffix : {"/devices", "/account", "/activate", "/activate?user_code=ABCDEFGHJK"}) {
        const std::string page = std::string(origin) + suffix;
        if (sd::ServicePage(origin, page) != std::wstring(page.begin(), page.end())) throw std::runtime_error("valid page rejected");
      }
    }
    const std::vector<std::pair<std::string, std::string>> invalid{
      {"http://sync.test", "/devices"}, {"https://sync.test/", "/devices"},
      {"https://user@sync.test", "/devices"}, {"https://sync.test:0", "/devices"},
      {"https://sync.test:65536", "/devices"}, {"https://sync.test:", "/devices"},
      {"https://127.1", "/devices"}, {"https://0x", "/devices"},
      {"https://127.0.0.0x", "/devices"}, {"https://01.2.3.4", "/devices"},
      {"https://[::1%lo]", "/devices"}, {"https://[::::]", "/devices"},
      {"https://sync.test", "/devices?token=secret"}, {"https://sync.test", "/account#secret"},
      {"https://sync.test", "/activate?user_code=ABCDEFGHJI"},
      {"https://sync.test", "/activate?user_code=ABCDEFGHJK&secret=value"},
      {"https://sync.test", "/../devices"}, {"https://sync.test", "/%64evices"},
      {"https://sync.test", "/devices\n"}, {"https://sync.test", "\\evil.test"}};
    for (const auto& item : invalid) {
      bool rejected = false;
      try { sd::ServicePage(item.first, item.first + item.second); }
      catch (const std::invalid_argument&) { rejected = true; }
      if (!rejected) throw std::runtime_error("unsafe page accepted");
    }
    bool rejected = false;
    try { sd::ServicePage("https://sync.test", "https://other.test/devices"); }
    catch (const std::invalid_argument&) { rejected = true; }
    if (!rejected) throw std::runtime_error("origin mismatch accepted");
    std::cout << "Service page synthetic unit vectors passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n'; return 1;
  }
}
