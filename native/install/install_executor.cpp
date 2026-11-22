#include "install_executor.h"
#include "mcp_json.h"
#include <sstream>

namespace sd::install {
namespace {
[[noreturn]] void Block() { throw updates::Failure("RECOVERY_REQUIRED"); }
Identity Fingerprint(Bytes bytes) {
  if (!bytes.data || !bytes.size || bytes.size > updates::kArtifactLimit) throw updates::Failure("INVALID_ARTIFACT");
  return {bytes.size, Sha256(bytes.data, bytes.size)};
}
std::string RecordHash(const Installation& record) {
  const auto text = EncodeInstallation(record);
  return Sha256(reinterpret_cast<const uint8_t*>(text.data()), text.size());
}
bool ManagesStartup(const updates::Version& version) {
  static const auto first = updates::ParseVersion("0.3.12");
  return !(version < first);
}
}
Executor::Executor(Files& files, Lease& lease, Registration& registration, SetupValidator validator, Checkpoint checkpoint)
    : files_(files), lease_(lease), registration_(registration), validateSetup_(std::move(validator)), checkpoint_(std::move(checkpoint)) {
  if (!validateSetup_) Block(); Guard();
}
void Executor::Guard() const {
  files_.roots().Validate();
  if (!lease_.Owns(files_.roots(), true)) throw updates::Failure("OWNER_RUNNING");
}
void Executor::Point(const char* stage) const { if (checkpoint_) checkpoint_(stage); }
void Executor::CheckSid(const Installation& record) const { if (record.sid != Utf8(files_.roots().sid)) Block(); }
bool Executor::Matches(const std::wstring& path, const Identity& identity) {
  return files_.Exists(path) && files_.Inspect(path) == identity;
}
bool Executor::Committed(const Installation& record, const std::string& transaction) {
  if (!files_.Exists(L"commit.v1")) return false;
  const auto text = files_.ReadRecord(L"commit.v1");
  if (text.size() > kRecordLimit || text.empty() || text.back() != '\n' || text.find('\r') != std::string::npos || text.find('\0') != std::string::npos) Block();
  std::istringstream lines(text); std::string header, id, hash, extra;
  if (!std::getline(lines, header) || header != "SDCOMMIT001" || !std::getline(lines, id) ||
      !mcp::CanonicalUuid(id) || !std::getline(lines, hash) || hash.size() != 64 ||
      hash.find_first_not_of("0123456789abcdef") != std::string::npos || std::getline(lines, extra)) Block();
  return (transaction.empty() || id == transaction) && hash == RecordHash(record);
}
void Executor::Commit(const Installation& record, const std::string& id) {
  if (!mcp::CanonicalUuid(id)) Block();
  files_.WriteRecord(L"installation.v1", EncodeInstallation(record));
  files_.WriteRecord(L"commit.v1", "SDCOMMIT001\n" + id + '\n' + RecordHash(record) + '\n');
}
std::optional<Installation> Executor::Current() {
  Guard();
  if (files_.Exists(L"journal.v1")) Block();
  if (!files_.Exists(L"installation.v1")) {
    if (files_.Exists(L"ServerDeck.exe") || files_.Exists(L"ServerDeckSetup.exe") || files_.Exists(L"commit.v1")) Block();
    return {};
  }
  auto record = DecodeInstallation(files_.ReadRecord(L"installation.v1")); CheckSid(record);
  if (!Committed(record) || !Matches(L"ServerDeck.exe", record.app) || !Matches(L"ServerDeckSetup.exe", record.setup)) Block();
  return record;
}
void Executor::CleanupTransaction() {
  for (const auto* name : {L"ServerDeck.new", L"ServerDeckSetup.new", L"ServerDeck.previous", L"ServerDeckSetup.previous"}) files_.Remove(name);
  files_.CleanupStaging();
  files_.Remove(L"journal.v1");
}
Installation Executor::PrepareStartup() {
  Guard(); files_.CleanupStaging(); Recover();
  const auto current = Current(); if (!current) Block();
  validateSetup_(files_.Path(L"ServerDeckSetup.exe"), current->version, current->app);
  return *current;
}
void Executor::Recover() {
  Guard();
  if (!files_.Exists(L"journal.v1")) return;
  auto journal = DecodeJournal(files_.ReadRecord(L"journal.v1"));
  CheckSid(journal.target); if (journal.previous) CheckSid(*journal.previous);
  // Removal is resumed by the transient uninstall entry point (T023), never
  // misclassified as a completed installation merely because its old hash matches.
  if (journal.kind == Operation::remove) throw updates::Failure("UNINSTALL_PARTIAL");
  registration_.CheckOwnership(); files_.CleanupStaging();
  Observation observed;
  if (files_.Exists(L"ServerDeck.exe")) observed.app = files_.Inspect(L"ServerDeck.exe");
  if (files_.Exists(L"ServerDeckSetup.exe")) observed.setup = files_.Inspect(L"ServerDeckSetup.exe");
  if (files_.Exists(L"ServerDeck.previous")) observed.backupApp = files_.Inspect(L"ServerDeck.previous");
  if (files_.Exists(L"ServerDeckSetup.previous")) observed.backupSetup = files_.Inspect(L"ServerDeckSetup.previous");
  observed.registrationMatchesTarget = registration_.Matches(journal.target);
  const bool irreversible = journal.stage == Stage::registered || Committed(journal.target, journal.id);
  if (irreversible) {
    if (!observed.app || !(*observed.app == journal.target.app) || !observed.setup || !(*observed.setup == journal.target.setup)) Block();
    validateSetup_(files_.Path(L"ServerDeckSetup.exe"), journal.target.version, journal.target.app);
    if (!observed.registrationMatchesTarget) registration_.Set(journal.target);
    if (!registration_.Matches(journal.target)) Block();
    Commit(journal.target, journal.id); CleanupTransaction(); return;
  }
  const auto startupMatches = [&] {
    if (!ManagesStartup(journal.target.version)) return true;
    try { return registration_.StartupMatches(); }
    catch (const std::exception&) { return false; }
  };
  observed.registrationMatchesTarget = observed.registrationMatchesTarget && startupMatches();
  auto plan = PlanRecovery(journal, observed);
  if (plan.action == RecoveryAction::commit) {
    validateSetup_(files_.Path(L"ServerDeckSetup.exe"), journal.target.version, journal.target.app);
    if (registration_.Matches(journal.target) && startupMatches()) {
      journal.stage = Stage::registered;
      files_.WriteRecord(L"journal.v1", EncodeJournal(journal));
      Commit(journal.target, journal.id); CleanupTransaction(); return;
    }
    observed.registrationMatchesTarget = false;
    plan = PlanRecovery(journal, observed);
  }
  if (plan.action == RecoveryAction::rollback) {
    const auto& old = *journal.previous;
    // The previous bootstrap may resume rollback as soon as its EXE is published.
    if (!ManagesStartup(old.version) && ManagesStartup(journal.target.version))
      registration_.RemoveStartup();
    const auto restore = [&](const std::wstring& source, const std::wstring& candidate, const std::wstring& target, const Identity& expected) {
      if (source != target) {
        files_.Copy(source, candidate); files_.Publish(candidate, target);
        if (!Matches(target, expected)) Block();
      }
    };
    restore(plan.appSource, L"ServerDeck.new", L"ServerDeck.exe", old.app); Point("rollback-application");
    restore(plan.setupSource, L"ServerDeckSetup.new", L"ServerDeckSetup.exe", old.setup); Point("rollback-setup");
    validateSetup_(files_.Path(L"ServerDeckSetup.exe"), old.version, old.app);
    registration_.Set(old); if (!registration_.Matches(old)) Block();
    // A same-version repair keeps the previous proof when it rolled back.
    if (RecordHash(old) != RecordHash(journal.target) || !Committed(old)) Commit(old, journal.id);
    CleanupTransaction(); return;
  }
  if (plan.action == RecoveryAction::discardFresh) {
    if (ManagesStartup(journal.target.version)) registration_.RemoveStartup();
    registration_.Remove(); registration_.RemoveRecoveryLink();
    for (const auto* name : {L"ServerDeck.exe", L"ServerDeckSetup.exe", L"installation.v1", L"commit.v1",
        L"recovery/ServerDeckSetup.exe", L"recovery/recovery.v1"}) files_.Remove(name);
    CleanupTransaction(); return;
  }
  Block();
}
void Executor::PrepareRecovery(const std::optional<Installation>& previous, const Package& package, const Installation& target) {
  const auto& setup = target.setup;
  if (files_.Exists(L"recovery/recovery.v1")) {
    const auto recovery = DecodeRecovery(files_.ReadRecord(L"recovery/recovery.v1"));
    if (recovery.sid != target.sid) Block();
    if (recovery.version == target.version && recovery.setup == setup && Matches(L"recovery/ServerDeckSetup.exe", setup)) {
      validateSetup_(files_.Path(L"recovery/ServerDeckSetup.exe"), target.version, target.app);
      registration_.SetRecoveryLink(); return;
    }
  } else if (!previous && files_.Exists(L"recovery/ServerDeckSetup.exe") && !Matches(L"recovery/ServerDeckSetup.exe", setup)) Block();
  if (files_.FreeBytes() < setup.size + 64ull * 1024 * 1024) throw updates::Failure("DISK_SPACE");
  // Recovery must understand the registration required by this transaction.
  files_.WriteArtifact(L"recovery/ServerDeckSetup.exe", package.setup.data, package.setup.size);
  if (!Matches(L"recovery/ServerDeckSetup.exe", setup)) Block();
  validateSetup_(files_.Path(L"recovery/ServerDeckSetup.exe"), target.version, target.app);
  files_.WriteRecord(L"recovery/recovery.v1", EncodeRecovery({target.sid, target.version, setup}));
  registration_.SetRecoveryLink();
}
InstallResult Executor::Repair() {
  Guard(); Recover(); files_.CleanupStaging(); registration_.CheckOwnership();
  const auto current = Current(); if (!current) Block();
  validateSetup_(files_.Path(L"ServerDeckSetup.exe"), current->version, current->app);
  // Recovery may contain a newer version after rollback. Verify its own
  // full identity and embedded resources without refreshing a running image.
  if (!files_.Exists(L"recovery/recovery.v1")) Block();
  const auto recovery = DecodeRecovery(files_.ReadRecord(L"recovery/recovery.v1"));
  if (recovery.sid != current->sid || !Matches(L"recovery/ServerDeckSetup.exe", recovery.setup)) Block();
  validateSetup_(files_.Path(L"recovery/ServerDeckSetup.exe"), recovery.version, {});
  const bool configureStartup = ManagesStartup(current->version);
  if (configureStartup) registration_.CheckStartup();
  Journal repair{Utf8(Uuid()), Operation::update, Stage::prepared, current, *current};
  files_.WriteRecord(L"journal.v1", EncodeJournal(repair));
  try {
    registration_.SetRecoveryLink();
    registration_.Set(*current);
    if (configureStartup) registration_.SetStartup();
    if (!registration_.Matches(*current) || (configureStartup && !registration_.StartupMatches()))
      throw updates::Failure("STORAGE_IO");
    repair.stage = Stage::registered; files_.WriteRecord(L"journal.v1", EncodeJournal(repair)); Point("registered");
    Commit(*current, repair.id); CleanupTransaction(); return InstallResult::repaired;
  } catch (const std::exception&) {
    Recover();
    if (registration_.Matches(*current) &&
        (Committed(*current, repair.id) ||
          (Committed(*current) && (!configureStartup || registration_.StartupMatches()))))
      return InstallResult::repaired;
    throw;
  }
}
InstallResult Executor::Apply(const Package& package, bool confirmed, const updates::Release* consented) {
  if (!confirmed) return InstallResult::cancelled;
  Guard(); Recover(); files_.CleanupStaging(); registration_.CheckOwnership();
  const auto previous = Current();
  Installation target{Utf8(files_.roots().sid), package.version, Fingerprint(package.app), Fingerprint(package.setup), {}, {}};
  if (consented) {
    if (!(consented->version == target.version) || consented->setupSize != target.setup.size || consented->setupHash != target.setup.hash ||
        consented->appSize != target.app.size || consented->appHash != target.app.hash) throw updates::Failure("SOURCE_CHANGED");
    target.consumedVersion = target.version.text; target.consumedSetupHash = target.setup.hash;
  }
  EncodeInstallation(target);
  if (previous && target.version < previous->version) throw updates::Failure("RELEASE_INCOMPATIBLE");
  const bool configureStartup = ManagesStartup(target.version);
  if (configureStartup) registration_.CheckStartup();
  if (previous && target.version == previous->version) {
    if (!(target.app == previous->app) || !(target.setup == previous->setup)) throw updates::Failure("SOURCE_CHANGED");
    PrepareRecovery(previous, package, target);
    return Repair();
  }
  if (!previous) for (const auto* path : {L"ServerDeck.new", L"ServerDeckSetup.new", L"ServerDeck.previous", L"ServerDeckSetup.previous"})
    if (files_.Exists(path)) Block();
  const auto required = target.app.size + target.setup.size + (previous ? previous->app.size + previous->setup.size : 0) +
    target.setup.size + 64ull * 1024 * 1024;
  if (files_.FreeBytes() < required) throw updates::Failure("DISK_SPACE");
  PrepareRecovery(previous, package, target); Point("recovery");
  Journal journal{Utf8(Uuid()), previous ? Operation::update : Operation::install, Stage::prepared, previous, target};
  files_.WriteRecord(L"journal.v1", EncodeJournal(journal)); Point("journal");
  try {
    files_.WriteArtifact(L"ServerDeck.new", package.app.data, package.app.size);
    files_.WriteArtifact(L"ServerDeckSetup.new", package.setup.data, package.setup.size);
    if (!Matches(L"ServerDeck.new", target.app) || !Matches(L"ServerDeckSetup.new", target.setup)) Block(); Point("candidates");
    if (previous) {
      files_.Copy(L"ServerDeck.exe", L"ServerDeck.previous"); files_.Copy(L"ServerDeckSetup.exe", L"ServerDeckSetup.previous");
      if (!Matches(L"ServerDeck.previous", previous->app) || !Matches(L"ServerDeckSetup.previous", previous->setup)) Block();
    }
    Point("backups");
    if (files_.Publish(L"ServerDeck.new", L"ServerDeck.exe") != ERROR_SUCCESS || !Matches(L"ServerDeck.exe", target.app)) throw updates::Failure("STORAGE_IO"); Point("application");
    if (files_.Publish(L"ServerDeckSetup.new", L"ServerDeckSetup.exe") != ERROR_SUCCESS || !Matches(L"ServerDeckSetup.exe", target.setup)) throw updates::Failure("STORAGE_IO"); Point("setup");
    journal.stage = Stage::files; files_.WriteRecord(L"journal.v1", EncodeJournal(journal)); Point("files");
    registration_.Set(target);
    if (configureStartup) registration_.SetStartup();
    Point("registration");
    if (!registration_.Matches(target) || (configureStartup && !registration_.StartupMatches()))
      throw updates::Failure("STORAGE_IO");
    journal.stage = Stage::registered; files_.WriteRecord(L"journal.v1", EncodeJournal(journal)); Point("registered");
    Commit(target, journal.id); Point("committed"); CleanupTransaction();
    return InstallResult::installed;
  } catch (const std::exception&) {
    try {
      Recover();
      if (Committed(target) && Matches(L"ServerDeck.exe", target.app) && Matches(L"ServerDeckSetup.exe", target.setup) &&
          registration_.Matches(target))
        return InstallResult::installed;
    } catch (...) { Block(); }
    throw;
  }
}
}  // namespace sd::install
