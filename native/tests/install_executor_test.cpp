#include "install_executor.h"
#include "install_registration.h"
#include "setup_package.h"
#include <sddl.h>
#include <fstream>
#include <iostream>
#include <cstring>

namespace {
void Require(bool value, const char* reason) { if (!value) throw std::runtime_error(reason); }
struct Interrupted {};
struct FakeRegistration : sd::install::Registration {
  std::optional<sd::install::Installation> value;
  bool recovery = false, failNext = false;
  bool startup = false;
  bool failStartupRemoval = false;
  void CheckOwnership() override {}
  void SetRecoveryLink() override { recovery = true; }
  void Set(const sd::install::Installation& record) override {
    if (failNext) { failNext = false; throw std::runtime_error("synthetic registry failure"); }
    value = record;
  }
  bool Matches(const sd::install::Installation& record) override {
    return value && value->version == record.version && value->setup == record.setup && value->app == record.app;
  }
  void Remove() override { value.reset(); }
  void RemoveRecoveryLink() override { recovery = false; }
  void CheckStartup() override {}
  void SetStartup() override { startup = true; }
  bool StartupMatches() override { return startup; }
  void RemoveStartup() override {
    if (failStartupRemoval) throw sd::updates::Failure("STORAGE_IO");
    startup = false;
  }
};
struct FakeRegistry : sd::install::RegistryPort {
  bool exists = false;
  int failWrite = 0, writes = 0, failures = 0;
  bool failStartup = false;
  std::optional<sd::install::StartupValue> startup;
  std::map<std::wstring, std::wstring> strings;
  std::map<std::wstring, DWORD> dwords;
  bool Exists() override { return exists; }
  std::optional<std::wstring> String(const std::wstring& name) override { const auto it = strings.find(name); return it == strings.end() ? std::optional<std::wstring>{} : it->second; }
  std::optional<DWORD> Dword(const std::wstring& name) override { const auto it = dwords.find(name); return it == dwords.end() ? std::optional<DWORD>{} : it->second; }
  void Write() { exists = true; if (++writes == failWrite) { ++failures; throw std::runtime_error("synthetic partial registry"); } }
  void SetString(const std::wstring& name, const std::wstring& value) override { Write(); strings[name] = value; }
  void SetDword(const std::wstring& name, DWORD value) override { Write(); dwords[name] = value; }
  void Flush() override { Write(); }
  void Remove() override { exists = false; strings.clear(); dwords.clear(); }
  std::optional<sd::install::StartupValue> Startup() override { return startup; }
  void EnsureStartup(const sd::install::StartupValue& value) override {
    if (failStartup || (startup && startup != value)) throw sd::updates::Failure("STORAGE_IO");
    startup = value;
  }
  void RemoveStartup(const sd::install::StartupValue& value) override {
    if (startup == value) startup.reset();
  }
};
struct TestRegistryKey {
  std::wstring path = L"Software\\ServerDeckUnit-" + sd::Uuid();
  ~TestRegistryKey() { RegDeleteKeyW(HKEY_CURRENT_USER, path.c_str()); }
};
struct QueryOnlyRegistryKey {
  HKEY key = nullptr;
  std::vector<BYTE> original;
  ~QueryOnlyRegistryKey() {
    if (!key) return;
    if (!original.empty()) RegSetKeySecurity(key, DACL_SECURITY_INFORMATION, original.data());
    RegCloseKey(key);
  }
  void Lock(const std::wstring& path) {
    Require(RegOpenKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, READ_CONTROL | WRITE_DAC, &key) == ERROR_SUCCESS,
      "cannot open temporary key for ACL fixture");
    DWORD size = 0;
    Require(RegGetKeySecurity(key, DACL_SECURITY_INFORMATION, nullptr, &size) == ERROR_INSUFFICIENT_BUFFER && size,
      "cannot size temporary key ACL");
    std::vector<BYTE> saved(size);
    Require(RegGetKeySecurity(key, DACL_SECURITY_INFORMATION, saved.data(), &size) == ERROR_SUCCESS,
      "cannot read temporary key ACL");
    const auto sid = sd::UserSid();
    const auto sddl = L"D:(D;;0x0002;;;" + sid + L")(A;;KA;;;" + sid + L")";
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    Require(ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1, &descriptor, nullptr),
      "cannot construct temporary key ACL");
    const auto changed = RegSetKeySecurity(key, DACL_SECURITY_INFORMATION, descriptor);
    LocalFree(descriptor);
    Require(changed == ERROR_SUCCESS, "cannot change temporary key ACL");
    original = std::move(saved);
  }
};
struct FakeShortcuts : sd::install::ShortcutPort {
  std::map<std::filesystem::path, std::pair<std::filesystem::path, std::wstring>> values;
  bool failNext = false;
  bool Exists(const std::filesystem::path& path) override { return values.count(path) != 0; }
  bool Matches(const std::filesystem::path& path, const std::filesystem::path& target, const wchar_t* args) override {
    const auto it = values.find(path); return it != values.end() && it->second.first == target && it->second.second == args;
  }
  void Save(const std::filesystem::path& path, const std::filesystem::path& target, const wchar_t* args) override {
    if (failNext) { failNext = false; values[path] = {}; throw std::runtime_error("synthetic partial shortcut"); }
    values[path] = {target, args};
  }
  void Remove(const std::filesystem::path& path) override { values.erase(path); }
};
sd::install::Bytes View(const std::string& bytes) { return {reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size()}; }
}
int main() {
  using namespace sd::install;
  std::filesystem::path root;
  try {
    // RegGetValueW's size probe can reserve an extra terminator which the
    // successful value read does not include in its actual byte count.
    const std::wstring registryPath = L"C:\\Users\\example\\ServerDeck";
    {
      TestRegistryKey key;
      constexpr auto name = L"synthetic";
      const StartupValue owned{REG_SZ, L"\"C:\\Example Path\\ServerDeck.exe\""};
      const StartupValue foreign{REG_EXPAND_SZ, L"\"%TEMP%\\another.exe\""};
      ChangeStartupValue(key.path.c_str(), name, owned, true);
      Require(!ReadStartupValue(key.path.c_str(), name), "removing missing startup registration created a value");
      ChangeStartupValue(key.path.c_str(), name, owned, false);
      ChangeStartupValue(key.path.c_str(), name, owned, false);
      Require(ReadStartupValue(key.path.c_str(), name) == owned, "startup adapter did not store the exact command");
      ChangeStartupValue(key.path.c_str(), name, foreign, true);
      bool refused = false;
      try { ChangeStartupValue(key.path.c_str(), name, foreign, false); }
      catch (const sd::updates::Failure&) { refused = true; }
      Require(refused && ReadStartupValue(key.path.c_str(), name) == owned, "foreign startup registration changed");
      ChangeStartupValue(key.path.c_str(), name, owned, true);
      Require(!ReadStartupValue(key.path.c_str(), name), "startup adapter did not remove the owned command");
      ChangeStartupValue(key.path.c_str(), name, foreign, false);
      Require(ReadStartupValue(key.path.c_str(), name) == foreign, "startup adapter expanded or changed the stored command");
      bool wroteForeign = false;
      try {
        ChangeStartupValue(key.path.c_str(), name, foreign, true, [&] {
          const auto size = static_cast<DWORD>((owned.command.size() + 1) * sizeof(wchar_t));
          wroteForeign = RegSetKeyValueW(HKEY_CURRENT_USER, key.path.c_str(), name, owned.type,
              owned.command.c_str(), size) == ERROR_SUCCESS;
        });
      } catch (const sd::updates::Failure&) {
        if (!wroteForeign) throw;
      }
      Require(wroteForeign && ReadStartupValue(key.path.c_str(), name) == owned,
        "compare-and-delete lost a competing registry write");
      ChangeStartupValue(key.path.c_str(), name, owned, true);
      const StartupValue maximum{REG_SZ, std::wstring(260, L'x')};
      ChangeStartupValue(key.path.c_str(), name, maximum, false);
      Require(ReadStartupValue(key.path.c_str(), name) == maximum, "260-unit startup command rejected");
      ChangeStartupValue(key.path.c_str(), name, maximum, true);
      bool oversized = false;
      try { ChangeStartupValue(key.path.c_str(), name, {REG_SZ, maximum.command + L'x'}, false); }
      catch (const sd::updates::Failure&) { oversized = true; }
      Require(oversized && !ReadStartupValue(key.path.c_str(), name), "oversized startup command was stored");
      {
        HKEY handle = nullptr;
        Require(RegOpenKeyExW(HKEY_CURRENT_USER, key.path.c_str(), 0, KEY_SET_VALUE, &handle) == ERROR_SUCCESS,
          "cannot open synthetic startup fixture");
        const wchar_t malformed[] = {L'a', L'\0', L'b', L'\0'};
        const auto written = RegSetValueExW(handle, name, 0, REG_SZ,
          reinterpret_cast<const BYTE*>(malformed), sizeof(malformed));
        RegCloseKey(handle);
        Require(written == ERROR_SUCCESS, "cannot store malformed synthetic value");
      }
      ChangeStartupValue(key.path.c_str(), name, owned, true);
      Require(ReadStartupValue(key.path.c_str(), name).has_value(), "uninstall deleted a readable malformed foreign value");
      ChangeStartupValue(key.path.c_str(), L"owned", owned, false);
      QueryOnlyRegistryKey readOnly;
      readOnly.Lock(key.path);
      ChangeStartupValue(key.path.c_str(), L"missing", owned, true);
      ChangeStartupValue(key.path.c_str(), name, owned, true);
      bool denied = false;
      try { ChangeStartupValue(key.path.c_str(), L"owned", owned, true); }
      catch (const sd::updates::Failure&) { denied = true; }
      Require(denied && ReadStartupValue(key.path.c_str(), L"owned") == owned,
        "owned value with query-only access did not produce retry");
    }
    const DWORD valueBytes = static_cast<DWORD>((registryPath.size() + 1) * sizeof(wchar_t));
    for (const DWORD padding : {DWORD{0}, static_cast<DWORD>(sizeof(wchar_t)), DWORD{64}}) {
      int reads = 0;
      const auto value = ReadRegistryString([&](void* buffer, DWORD* bytes) -> LSTATUS {
        ++reads;
        if (!buffer) { *bytes = valueBytes + padding; return ERROR_SUCCESS; }
        Require(*bytes >= valueBytes, "registry buffer too small");
        std::memcpy(buffer, registryPath.c_str(), valueBytes); *bytes = valueBytes; return ERROR_SUCCESS;
      });
      Require(value && *value == registryPath && reads == 2, "registry actual-length regression");
    }
    Require(!ReadRegistryString([](void*, DWORD*) -> LSTATUS { return ERROR_FILE_NOT_FOUND; }), "absent registry string");
    for (int failure = 0; failure < 7; ++failure) {
      bool rejected = false;
      try {
        ReadRegistryString([&](void* buffer, DWORD* bytes) -> LSTATUS {
          if (!buffer) { *bytes = failure == 0 ? 65538 : valueBytes; return ERROR_SUCCESS; }
          std::memcpy(buffer, registryPath.c_str(), valueBytes);
          if (failure == 1) return ERROR_MORE_DATA;
          if (failure == 2) *bytes = 0;
          if (failure == 3) *bytes = valueBytes - 1;
          if (failure == 4) *bytes = valueBytes + 2;
          if (failure == 5) static_cast<wchar_t*>(buffer)[registryPath.size()] = L'x';
          if (failure == 6) static_cast<wchar_t*>(buffer)[1] = L'\0';
          return ERROR_SUCCESS;
        });
      } catch (const sd::updates::Failure&) { rejected = true; }
      Require(rejected, "invalid registry string accepted");
    }
    wchar_t temp[32768]{}; Require(GetTempPathW(32768, temp) != 0, "temp");
    root = std::filesystem::path(temp) / (L"ServerDeckExecutorUnit-" + sd::Uuid()); sd::SecureDirectory(root);
    const std::string oldApp = "old app bytes", oldSetup = "old setup bytes", newApp = "new app bytes", newSetup = "new setup bytes";
    const Package old{sd::updates::ParseVersion("0.3.12"), View(oldApp), View(oldSetup)};
    const Package next{sd::updates::ParseVersion("0.3.13"), View(newApp), View(newSetup)};
    const auto validate = [](const std::filesystem::path&, const sd::updates::Version&, const Identity&) {};
    const auto header = "SDSETUP001\n0.3.12\n12\n" + std::string(64, 'a') + "\n";
    Require(DecodeSetupManifest(header).version == old.version, "setup manifest codec");
    for (const auto& invalid : {std::string(), header + "extra\n", std::string("SDSETUP002\n0.1.0\n12\n") + std::string(64, 'a') + '\n'}) {
      bool refused = false; try { DecodeSetupManifest(invalid); } catch (...) { refused = true; }
      Require(refused, "invalid setup manifest accepted");
    }
    std::vector<uint8_t> pe(512, 0); pe[0] = 'M'; pe[1] = 'Z';
    const uint32_t peOffset = 128; std::memcpy(pe.data() + 0x3c, &peOffset, 4);
    std::memcpy(pe.data() + peOffset, "PE\0\0", 4);
    const uint16_t machine = 0x8664, magic = 0x20b;
    std::memcpy(pe.data() + peOffset + 4, &machine, 2); std::memcpy(pe.data() + peOffset + 24, &magic, 2);
    ValidateApplicationImage({pe.data(), pe.size()});
    pe[peOffset + 4] = 0x4c; bool wrongMachine = false;
    try { ValidateApplicationImage({pe.data(), pe.size()}); } catch (...) { wrongMachine = true; }
    Require(wrongMachine, "non-x64 app accepted");
    for (const auto* stop : {"none", "journal", "candidates", "backups", "application", "setup", "files", "registration", "registered", "committed"}) {
      const auto scenario = root / sd::Wide(stop); sd::SecureDirectory(scenario);
      const Paths paths{scenario / L"install", scenario / L"data", scenario / L"programs", sd::UserSid()};
      sd::SecureDirectory(paths.data); sd::SecureDirectory(paths.programs);
      { std::ofstream data(paths.data / L"sentinel"); data << "preserved"; }
      Files files(paths); Lease lease(paths, true); FakeRegistration registration;
      Executor executor(files, lease, registration, validate);
      Require(executor.Apply(old, false) == InstallResult::cancelled && !std::filesystem::exists(paths.install), "cancel mutated install");
      Require(executor.Apply(old, true) == InstallResult::installed, "fresh installation");
      Require(executor.Current()->version == old.version && registration.recovery, "fresh commit");
      Require(executor.Apply(old, true) == InstallResult::repaired, "equal repair");
      for (const auto& conflict : {Package{old.version, View(newApp), View(oldSetup)}, Package{old.version, View(oldApp), View(newSetup)}}) {
        bool refused = false;
        try { executor.Apply(conflict, true); } catch (const sd::updates::Failure& error) { refused = std::string(error.what()) == "SOURCE_CHANGED"; }
        Require(refused && !files.Exists(L"journal.v1") && executor.Current()->app == Identity{oldApp.size(), sd::Sha256(View(oldApp).data, oldApp.size())}, "same version conflicting bytes accepted");
      }
      bool downgradeRejected = false;
      const Package older{sd::updates::ParseVersion("0.0.0"), View(oldApp), View(oldSetup)};
      try { executor.Apply(older, true); } catch (...) { downgradeRejected = true; }
      Require(downgradeRejected && executor.Current()->version == old.version, "downgrade modified install");
      const std::string selected(stop);
      Executor injected(files, lease, registration, validate, [&](const char* point) { if (selected == point) throw Interrupted{}; });
      try { injected.Apply(next, true); } catch (const Interrupted&) {}
      const auto recovery = DecodeRecovery(files.ReadRecord(L"recovery/recovery.v1"));
      const Identity nextSetup{newSetup.size(), sd::Sha256(View(newSetup).data, newSetup.size())};
      Require(recovery.version == next.version && recovery.setup == nextSetup &&
        files.Inspect(L"recovery/ServerDeckSetup.exe") == nextSetup,
        "recovery action retained the previous setup instead of the transaction's installer");
      const bool irreversible = selected == "registered" || selected == "committed";
      if (irreversible) {
        registration.value.reset();
        registration.startup = false;
      }
      const auto verifiedStartup = executor.PrepareStartup();
      const auto current = executor.Current(); Require(current.has_value(), "recovery lost installation");
      Require(verifiedStartup.version == current->version && verifiedStartup.app == current->app, "startup exposed unverified installation");
      Require(registration.Matches(*current), "recovery registration mismatch");
      if (irreversible) Require(!registration.StartupMatches(), "recovery re-enabled user-removed startup registration");
      Require(!files.Exists(L"journal.v1"), "recovered journal retained");
      Require(std::filesystem::file_size(paths.data / L"sentinel") == 9, "data changed");
      if (irreversible || selected == "none")
        Require(current->version == next.version, "irreversible commit rolled back");
    }
    {
      const auto scenario = root / L"fresh-discard-startup-denied"; sd::SecureDirectory(scenario);
      const Paths paths{scenario / L"install", scenario / L"data", scenario / L"programs", sd::UserSid()};
      Files files(paths); Lease lease(paths, true); FakeRegistration registration;
      Executor interrupted(files, lease, registration, validate, [](const char* point) {
        if (std::string(point) == "journal") throw Interrupted{};
      });
      try { interrupted.Apply(old, true); } catch (const Interrupted&) {}
      Require(registration.recovery && files.Exists(L"journal.v1") && !files.Exists(L"ServerDeck.exe"),
        "fresh interruption fixture did not leave only the recovery entry");
      registration.failStartupRemoval = true;
      Executor maintenance(files, lease, registration, validate);
      bool refused = false;
      try { maintenance.Recover(); } catch (const sd::updates::Failure&) { refused = true; }
      Require(refused && registration.recovery && files.Exists(L"journal.v1"),
        "logon cleanup failure removed the fresh recovery entry");
      registration.failStartupRemoval = false;
      maintenance.Recover();
      Require(!registration.recovery && !registration.startup && !files.Exists(L"journal.v1"),
        "fresh installation did not finish discarding after a retry");
    }
    {
      const auto scenario = root / L"rollback-before-startup-feature"; sd::SecureDirectory(scenario);
      const Paths paths{scenario / L"install", scenario / L"data", scenario / L"programs", sd::UserSid()};
      Files files(paths); Lease lease(paths, true); FakeRegistration registration;
      const Package legacy{sd::updates::ParseVersion("0.3.11"), View(newApp), View(newSetup)};
      Executor maintenance(files, lease, registration, validate);
      Require(maintenance.Apply(legacy, true) == InstallResult::installed && !registration.startup,
        "previous version fixture unexpectedly registered startup");
      Executor interrupted(files, lease, registration, validate, [&](const char* point) {
        if (std::string(point) != "registration") return;
        Require(registration.startup, "upgrade fixture did not create startup registration");
        registration.value.reset();
        throw Interrupted{};
      });
      try { interrupted.Apply(old, true); } catch (const Interrupted&) {}
      const auto target = DecodeJournal(files.ReadRecord(L"journal.v1")).target;
      registration.failStartupRemoval = true;
      bool refused = false;
      try { maintenance.PrepareStartup(); } catch (const sd::updates::Failure&) { refused = true; }
      Require(refused && registration.startup && files.Inspect(L"ServerDeck.exe") == target.app,
        "rollback published the previous bootstrap before logon cleanup succeeded");
      registration.failStartupRemoval = false;
      bool cutDuringRollback = false;
      Executor interruptedRollback(files, lease, registration, validate, [&](const char* point) {
        if (std::string(point) != "rollback-application") return;
        Require(!registration.startup && !(files.Inspect(L"ServerDeck.exe") == target.app),
          "previous bootstrap was published with startup registration still present");
        throw Interrupted{};
      });
      try { interruptedRollback.PrepareStartup(); } catch (const Interrupted&) { cutDuringRollback = true; }
      Require(cutDuringRollback, "rollback interruption fixture did not reach app publication");
      Require(maintenance.PrepareStartup().version == legacy.version && !registration.startup &&
        DecodeRecovery(files.ReadRecord(L"recovery/recovery.v1")).version == old.version,
        "rollback left startup for a version that cannot remove it");
      Require(maintenance.Repair() == InstallResult::repaired && !registration.startup,
        "newer recovery registered startup for the restored version");
      registration.Remove();
      Require(!registration.startup, "ordinary removal would leave stale startup registration");
    }
    for (const bool repair : {false, true}) for (const auto* unknown : {L".download-owner.v1", L".download.bin"}) {
      const auto scenario = root / (sd::Uuid()); sd::SecureDirectory(scenario);
      const Paths paths{scenario / L"install", scenario / L"data", scenario / L"programs", sd::UserSid()};
      sd::SecureDirectory(paths.data); sd::SecureDirectory(paths.programs);
      Files files(paths); Lease lease(paths, true); FakeRegistration registration;
      Executor executor(files, lease, registration, validate); executor.Apply(old, true);
      const auto before = *executor.Current();
      const auto metadata = files.ReadRecord(L"installation.v1"), proof = files.ReadRecord(L"commit.v1");
      { std::ofstream external(paths.install / unknown, std::ios::binary); external << "unknown"; }
      bool refused = false;
      try { if (repair) executor.Repair(); else executor.Apply(next, true); }
      catch (const sd::updates::Failure& error) { refused = std::string(error.what()) == "RECOVERY_REQUIRED"; }
      Require(refused && !files.Exists(L"journal.v1"), "unknown download stage admitted mutation");
      Require(files.ReadRecord(L"installation.v1") == metadata && files.ReadRecord(L"commit.v1") == proof &&
        files.Inspect(L"ServerDeck.exe") == before.app && files.Inspect(L"ServerDeckSetup.exe") == before.setup &&
        registration.Matches(before), "download-stage refusal changed committed installation");
      Require(std::filesystem::file_size(paths.install / unknown) == 7, "unknown download bytes deleted");
    }
    {
      const auto scenario = root / L"registry-error"; sd::SecureDirectory(scenario);
      const Paths paths{scenario / L"install", scenario / L"data", scenario / L"programs", sd::UserSid()};
      sd::SecureDirectory(paths.data); sd::SecureDirectory(paths.programs);
      Files files(paths); Lease lease(paths, true); FakeRegistration registration;
      Executor executor(files, lease, registration, validate);
      executor.Apply(old, true); registration.failNext = true;
      bool failed = false; try { executor.Apply(next, true); } catch (...) { failed = true; }
      Require(failed && executor.Current()->version == old.version && registration.Matches(*executor.Current()), "registry failure did not restore old");
    }
    for (int failure = 0; failure <= 10; ++failure) {
      const auto scenario = root / (L"Путь с пробелом " + std::to_wstring(failure)); sd::SecureDirectory(scenario);
      const Paths paths{scenario / L"install", scenario / L"data", scenario / L"programs", sd::UserSid()};
      sd::SecureDirectory(paths.data); sd::SecureDirectory(paths.programs);
      Files files(paths); Lease lease(paths, true); FakeRegistry registry; FakeShortcuts shortcuts;
      WindowsRegistration registration(paths, &registry, &shortcuts);
      Executor executor(files, lease, registration, validate);
      executor.Apply(old, true);
      const auto projection = ProjectRegistration(paths, *executor.Current());
      Require(registry.startup == StartupValue{REG_SZ, L"\"" + projection.application.wstring() + L"\""},
        "wrong canonical startup command");
      Require(registry.strings.at(L"UninstallString") == L"\"" + projection.setup.wstring() + L"\" --uninstall", "uninstall quoting");
      Require(registry.dwords.at(L"NoModify") == 1 && registry.dwords.at(L"NoRepair") == 1, "registration options");
      registry.failWrite = registry.writes + failure;
      bool failed = false;
      try { executor.Apply(next, true); } catch (const std::exception&) { failed = true; }
      if (failure) Require(registry.failures == 1, "registry failure not injected");
      Require(executor.Current()->version == (failed ? old.version : next.version), "result did not match reconciled complete version");
      Require(registration.Matches(*executor.Current()), "real registration owner with fake ports mismatch");
      auto different = *executor.Current(); different.sid = "S-1-5-18";
      if (different.sid != sd::Utf8(sd::UserSid())) {
        bool refused = false; try { ProjectRegistration(paths, different); } catch (...) { refused = true; }
        Require(refused, "foreign registration owner accepted");
      }
    }
    {
      const auto scenario = root / L"shortcut-retry"; sd::SecureDirectory(scenario);
      const Paths paths{scenario / L"install", scenario / L"data", scenario / L"programs", sd::UserSid()};
      sd::SecureDirectory(paths.data); sd::SecureDirectory(paths.programs);
      Files files(paths); Lease lease(paths, true); FakeRegistry registry; FakeShortcuts shortcuts;
      WindowsRegistration registration(paths, &registry, &shortcuts);
      Executor executor(files, lease, registration, validate);
      shortcuts.failNext = true;
      bool failed = false; try { executor.Apply(old, true); } catch (...) { failed = true; }
      Require(failed && !files.Exists(L"ServerDeck.exe"), "failed recovery-link preparation installed app");
      executor.Apply(old, true); Require(registration.Matches(*executor.Current()), "recovery-link retry failed");
      // Explicit repair uses installed identities; no embedded recovery version
      // is applied, and a partially saved main link remains journal-owned.
      shortcuts.failNext = true;
      Require(executor.Repair() == InstallResult::repaired && registration.Matches(*executor.Current()), "explicit repair partial shortcut unreconciled");
      Require(executor.Repair() == InstallResult::repaired && !files.Exists(L"journal.v1"), "explicit repair retry failed");
      const auto proofBeforeRepair = files.ReadRecord(L"commit.v1");
      Executor repairAfterRegistration(files, lease, registration, validate, [&](const char* point) {
        if (std::string(point) != "registered") return;
        registry.startup.reset();
        throw sd::updates::Failure("STORAGE_IO");
      });
      Require(repairAfterRegistration.Repair() == InstallResult::repaired && !files.Exists(L"journal.v1") &&
        !registry.startup && files.ReadRecord(L"commit.v1") != proofBeforeRepair,
        "registered repair did not recognize the recovered proof after a user startup change");
      Require(executor.Repair() == InstallResult::repaired, "explicit repair did not restore missing startup");
      const auto recoveryMarker = files.ReadRecord(L"recovery/recovery.v1");
      files.Remove(L"recovery/recovery.v1");
      bool refused = false; try { executor.Repair(); } catch (const sd::updates::Failure& error) { refused = std::string(error.what()) == "RECOVERY_REQUIRED"; }
      Require(refused && !files.Exists(L"journal.v1"), "missing recovery marker falsely repaired");
      files.WriteRecord(L"recovery/recovery.v1", recoveryMarker);
      files.Remove(L"recovery/ServerDeckSetup.exe");
      refused = false; try { executor.Repair(); } catch (...) { refused = true; }
      Require(refused && !files.Exists(L"journal.v1"), "missing recovery image falsely repaired");
      files.WriteArtifact(L"recovery/ServerDeckSetup.exe", View(newSetup).data, newSetup.size());
      refused = false; try { executor.Repair(); } catch (...) { refused = true; }
      Require(refused && !files.Exists(L"journal.v1"), "corrupt recovery image falsely repaired");
      files.WriteArtifact(L"recovery/ServerDeckSetup.exe", View(oldSetup).data, oldSetup.size());
      shortcuts.failNext = true;
      try { executor.Apply(next, true); } catch (...) {}
      Require(registration.Matches(*executor.Current()), "partial main shortcut unreconciled");
      const auto version = executor.Current()->version;
      registry.startup.reset();
      const auto record = *executor.Current();
      const auto originalProof = files.ReadRecord(L"commit.v1");
      files.WriteRecord(L"journal.v1", EncodeJournal({sd::Utf8(sd::Uuid()), Operation::update, Stage::prepared, record, record}));
      Require(executor.PrepareStartup().version == version && !registry.startup && !files.Exists(L"journal.v1") &&
        files.ReadRecord(L"commit.v1") == originalProof,
        "interrupted repair reissued the installation proof without logon registration");
      registry.failStartup = true;
      bool failedStartup = false;
      try { executor.Apply(next, true); } catch (const sd::updates::Failure&) { failedStartup = true; }
      Require(failedStartup && executor.PrepareStartup().version == version && !registry.startup,
        "startup registration failure prevented rollback");
      registry.failStartup = false;
      const StartupValue other{REG_SZ, L"\"C:\\other.exe\""};
      Executor substituted(files, lease, registration, validate, [&](const char* point) {
        if (std::string(point) == "registration") registry.startup = other;
      });
      bool rejectedSubstitution = false;
      try { substituted.Apply(next, true); } catch (const sd::updates::Failure&) { rejectedSubstitution = true; }
      Require(rejectedSubstitution && executor.PrepareStartup().version == version && registry.startup == other,
        "competing startup change reported success or was overwritten");
      registration.RemoveStartup();
      Require(registry.startup == other, "removed a foreign startup entry");
      registry.startup.reset();
      Executor interrupted(files, lease, registration, validate, [](const char* point) {
        if (std::string(point) == "registration") throw Interrupted{};
      });
      try { interrupted.Apply(next, true); } catch (const Interrupted&) {}
      Require(DecodeJournal(files.ReadRecord(L"journal.v1")).stage == Stage::files && registration.StartupMatches(),
        "reversible logon recovery fixture was not staged");
      Executor recovering(files, lease, registration, [&](const std::filesystem::path&, const sd::updates::Version& v, const Identity&) {
        if (v == next.version) registry.startup = other;
      });
      Require(recovering.PrepareStartup().version == version && registry.startup == other && !files.Exists(L"journal.v1"),
        "recovery committed after a competing startup change");
    }
    {
      const auto scenario = root / L"native-shortcut-adapter"; sd::SecureDirectory(scenario);
      const Paths paths{scenario / L"install", scenario / L"data", scenario / L"programs", sd::UserSid()};
      sd::SecureDirectory(paths.data);
      // Only the shortcut adapter uses OS APIs here. Registry is fake and all
      // paths/target bytes are synthetic; no Explorer or application is launched.
      Files files(paths); Lease lease(paths, true); FakeRegistry registry;
      WindowsRegistration registration(paths, &registry);
      Executor executor(files, lease, registration, validate);
      executor.Apply(old, true);
      Require(registration.Matches(*executor.Current()), "native shortcut codec mismatch");
      Require(std::filesystem::exists(paths.programs / L"ServerDeck.lnk"), "native shortcut missing");
      Require(executor.Apply(old, true) == InstallResult::repaired, "native shortcut idempotency");
      registration.Remove(); registration.RemoveRecoveryLink();
      Require(!std::filesystem::exists(paths.programs / L"ServerDeck.lnk"), "native shortcut removal");
    }
    for (const auto* damage : {L"none-installed", L"application", L"retained", L"commit", L"unowned-stage", L"embedded"}) {
      const auto scenario = root / (L"startup-" + std::wstring(damage)); sd::SecureDirectory(scenario);
      const Paths paths{scenario / L"install", scenario / L"data", scenario / L"programs", sd::UserSid()};
      Files files(paths); Lease lease(paths, true); FakeRegistration registration;
      Executor executor(files, lease, registration, validate);
      if (std::wstring(damage) != L"none-installed") executor.Apply(old, true);
      sd::AtomicFile(paths.data / L"data-sentinel", {1, 2, 3, 4});
      const std::wstring kind(damage);
      if (kind == L"application") files.WriteArtifact(L"ServerDeck.exe", View(newApp).data, newApp.size());
      if (kind == L"retained") files.WriteArtifact(L"ServerDeckSetup.exe", View(newSetup).data, newSetup.size());
      if (kind == L"commit") files.WriteRecord(L"commit.v1", "invalid proof\n");
      if (kind == L"unowned-stage") { std::ofstream unknown(paths.install / L".stage.bin"); unknown << "foreign"; }
      bool validatorCalled = false;
      Executor startup(files, lease, registration, [&](const std::filesystem::path&, const sd::updates::Version&, const Identity&) {
        validatorCalled = true; if (kind == L"embedded") throw sd::updates::Failure("INVALID_ARTIFACT");
      });
      bool refused = false; try { startup.PrepareStartup(); } catch (const sd::updates::Failure&) { refused = true; }
      Require(refused && validatorCalled == (kind == L"embedded"), "startup admitted damaged/uncommitted installation");
      Require(!std::filesystem::exists(paths.data / L"owner.json") && std::filesystem::file_size(paths.data / L"data-sentinel") == 4,
        "startup published owner or changed data before verification");
      if (kind == L"unowned-stage") Require(std::filesystem::file_size(paths.install / L".stage.bin") == 7, "startup deleted foreign stage");
    }
    std::filesystem::remove_all(root); root.clear();
    std::cout << "install executor unit checks passed\n"; return 0;
  } catch (const std::exception& e) {
    std::cerr << e.what() << '\n'; if (!root.empty()) std::filesystem::remove_all(root); return 1;
  }
}
