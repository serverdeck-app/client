import 'dart:typed_data';

/// Selected only by the native composition root, never by account/server input.
/// Android MVP has no desktop adapters; a false capability is not a no-op adapter.
enum PlatformCapabilities {
  windows(
    supportsMcp: true,
    supportsMonitoring: true,
    supportsJournals: true,
    supportsConsole: true,
    supportsUpdates: true,
    supportsTray: true,
  ),
  android(
    supportsMcp: false,
    supportsMonitoring: false,
    supportsJournals: false,
    supportsConsole: false,
    supportsUpdates: false,
    supportsTray: false,
  );

  const PlatformCapabilities({
    required this.supportsMcp,
    required this.supportsMonitoring,
    required this.supportsJournals,
    required this.supportsConsole,
    required this.supportsUpdates,
    required this.supportsTray,
  });

  final bool supportsMcp,
      supportsMonitoring,
      supportsJournals,
      supportsConsole,
      supportsUpdates,
      supportsTray;
}

abstract interface class PlatformCapabilityPort {
  PlatformCapabilities get capabilities;
}

/// Root-owned local protection; never exposed through public projections or MCP.
/// Inputs remain caller-owned; returned byte buffers are owned by the caller.
abstract interface class PlatformSecretPort {
  Future<Uint8List> protect(Uint8List bytes, String purpose);
  Future<Uint8List> unprotect(Uint8List bytes, String purpose);
}

abstract interface class PlatformKeyPickerPort {
  /// Cancel is null. Original bytes <=1MiB; no persistent external URI/path.
  Future<Uint8List?> pickPrivateKey();
}

abstract interface class PlatformBrowserPort {
  /// Enforce captured HTTPS origin and fixed account/activation paths before open.
  /// The only permitted activation query is user_code, never a credential/key.
  Future<void> openServicePage({required Uri serviceOrigin, required Uri page});
}

/// Library resolution only. Domain state remains in the one WorkspaceStore.
sealed class PlatformStorageLocation {
  const PlatformStorageLocation(this.dataRoot);
  final String dataRoot;
}

final class FileLibraryStorageLocation extends PlatformStorageLocation {
  const FileLibraryStorageLocation({
    required String dataRoot,
    required this.libraryPath,
  }) : super(dataRoot);

  final String libraryPath;
}

final class BundledLibraryStorageLocation extends PlatformStorageLocation {
  const BundledLibraryStorageLocation({required String dataRoot})
    : super(dataRoot);
}

abstract interface class PlatformStoragePort {
  Future<PlatformStorageLocation> prepareStorage();
  Future<void> flushAtomic(String path, Uint8List bytes);
  Future<int> availableStorageBytes();
}

enum PlatformLifecyclePhase { resumed, paused, detached }

abstract interface class PlatformLifecyclePort {
  PlatformLifecyclePhase get phase;
  Stream<PlatformLifecyclePhase> get changes;
}
