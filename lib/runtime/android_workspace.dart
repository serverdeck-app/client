import 'dart:async';

import '../storage/store_manifest.dart';
import '../storage/workspace_store.dart';
import 'capability.dart';
import 'platform_ports.dart';

/// Storage lifetime only. The root drains feature owners before calling close.
/// Native platform disposal releases the workspace lease only after DB close.
final class AndroidWorkspace implements RuntimeStore {
  AndroidWorkspace({
    required this.storage,
    required this.secrets,
    required this.disposePlatform,
    this.backend = const IsarStoreBackend(),
  });

  final PlatformStoragePort storage;
  final PlatformSecretPort secrets;
  final Future<void> Function() disposePlatform;
  final StoreBackend backend;
  WorkspaceStore? _store;
  Future<void>? _opening, _closing;
  bool _stopped = false, _closed = false;

  WorkspaceStore get store =>
      _store ?? (throw const StoreFailure('STORAGE_UNAVAILABLE'));
  @override
  String get theme => _store?.theme ?? 'dark';

  @override
  Future<void> open() {
    if (_stopped || _closed || _closing != null) {
      return Future.error(const StoreFailure('SHUTTING_DOWN'));
    }
    return _opening ??= _open().whenComplete(() => _opening = null);
  }

  Future<void> _open() async {
    if (_store == null) {
      final location = await storage.prepareStorage();
      if (_stopped) throw const StoreFailure('SHUTTING_DOWN');
      if (location is! BundledLibraryStorageLocation) {
        throw const StoreFailure('UNSUPPORTED_STORAGE_ABI');
      }
      _store = WorkspaceStore.bundled(
        dataRoot: location.dataRoot,
        flushAtomic: storage.flushAtomic,
        backend: backend,
        protectReceiptKey: (bytes) => secrets.protect(bytes, 'receipt-hmac.v1'),
      );
    }
    await store.open();
    if (_stopped) store.stopAdmission();
  }

  @override
  void stopAdmission() {
    _stopped = true;
    _store?.stopAdmission();
  }

  @override
  Future<void> finishWrites() async {
    try {
      await _opening;
    } catch (_) {
      // Startup failures are retained by the root; any partial store still closes.
    }
    await _store?.finishWrites();
  }

  @override
  Future<void> close() {
    if (_closed) return Future.value();
    stopAdmission();
    return _closing ??= _close().whenComplete(() => _closing = null);
  }

  Future<void> _close() async {
    await finishWrites();
    await _store?.close();
    // If DB close fails, retain the lease. Both close and native dispose retry.
    await disposePlatform();
    _closed = true;
  }
}
