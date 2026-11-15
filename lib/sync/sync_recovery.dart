import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../domain/models.dart';
import '../storage/records.dart';
import 'sync_crypto.dart';
import 'sync_models.dart';
import 'sync_repository.dart';
import 'sync_secret_box.dart';
import 'sync_transport.dart';
import 'sync_wire.dart';

const _invalidRecovery = OperationFailure(FailureCode.invalidArgument);

abstract final class SyncRecoveryCodec {
  static String encode(Uint8List key) {
    if (key.length != 32) throw _invalidRecovery;
    return 'SD1-${base64Url.encode(key).replaceAll('=', '')}-${syncSha256(key).substring(0, 8)}';
  }

  /// Returns an owned key; caller must wipe it even on later authentication failure.
  static Uint8List decode(String code) {
    final match = RegExp(r'^SD1-([A-Za-z0-9_-]{43})-([0-9a-f]{8})$')
        .firstMatch(code.trim());
    if (match == null) throw _invalidRecovery;
    Uint8List? key;
    try {
      key = base64Url.decode('${match[1]}=');
      if (key.length != 32 || encode(key) != match[0]) throw _invalidRecovery;
      return key;
    } catch (_) {
      key?.fillRange(0, key.length, 0);
      throw _invalidRecovery;
    }
  }
}

/// Secret-only dialog payload; never part of ordinary state or public projection.
final class SyncRecoveryChallenge {
  SyncRecoveryChallenge._(this._key);
  final Uint8List _key;
  bool _disposed = false;
  bool get disposed => _disposed;
  String get code {
    if (_disposed) throw _invalidRecovery;
    return SyncRecoveryCodec.encode(_key);
  }

  String get checksum {
    if (_disposed) throw _invalidRecovery;
    return syncSha256(_key).substring(0, 8);
  }

  void dispose() {
    _key.fillRange(0, _key.length, 0);
    _disposed = true;
  }
}

enum SyncVaultPhase {
  unavailable,
  checking,
  needsInitialization,
  awaitingConfirmation,
  locked,
  unlocking,
  ready,
  error,
}

final class SyncVaultView {
  const SyncVaultView(this.phase, {this.revision, this.errorCode});
  final SyncVaultPhase phase;
  final int? revision;
  final String? errorCode;
}

final class SyncVaultContext {
  const SyncVaultContext(this.fence, this.epoch);
  final SyncFence fence;
  final int epoch;
}

/// Native root authority only; implementations fence before and after network.
abstract interface class SyncVaultAccess {
  Future<SyncVaultContext> vaultContext();
  void guardVaultContext(SyncVaultContext context);
  bool isVaultContextCurrent(SyncVaultContext context);
  Future<SyncHead> readVaultHead(
    SyncVaultContext context,
    SyncCancellation cancel,
  );
  Future<Uint8List> readVaultRoot(
    SyncVaultContext context,
    SyncManifest manifest,
    SyncCancellation cancel,
  );
}

/// Key readiness is separate from publication consent and candidate application.
final class SyncVaultOwner {
  SyncVaultOwner({
    required this.repository,
    required this.box,
    required this.access,
    Uint8List Function(int)? randomBytes,
  }) : _random = randomBytes ?? _secure;
  final SyncRepository repository;
  final SyncSecretBox box;
  final SyncVaultAccess access;
  final Uint8List Function(int) _random;
  final _changes = StreamController<SyncVaultView>.broadcast();
  SyncVaultView _view = const SyncVaultView(SyncVaultPhase.unavailable);
  SyncVaultView get view => _view;
  Stream<SyncVaultView> get changes => _changes.stream;
  SyncCrypto? _crypto;
  SyncRecoveryChallenge? _challenge;
  SyncVaultContext? _context;
  SyncHead? _head;
  SyncCancellation _cancel = SyncCancellation();
  int _generation = 0;

  /// Root scheduling metadata only; never a key, grant or public wire projection.
  int get actionGeneration => _generation;
  bool _disposed = false, _confirming = false;

  static Uint8List _secure(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List.generate(length, (_) => random.nextInt(256)),
    );
  }

  void _emit(SyncVaultPhase phase, {String? error}) {
    if (_disposed) return;
    _view = SyncVaultView(phase, revision: _head?.revision, errorCode: error);
    _changes.add(_view);
  }

  void _clear() {
    _generation++;
    _cancel.cancel();
    _cancel = SyncCancellation();
    _crypto?.dispose();
    _crypto = null;
    _challenge?.dispose();
    _challenge = null;
    _context = null;
    _head = null;
    _confirming = false;
  }

  void lock() {
    _clear();
    _emit(SyncVaultPhase.unavailable);
  }

  void dispose() {
    if (_disposed) return;
    lock();
    _disposed = true;
    unawaited(_changes.close());
  }

  int _begin(SyncVaultPhase phase) {
    if (_disposed) throw const SyncTransportCancelled();
    _clear();
    _emit(phase);
    return _generation;
  }

  bool _current(int generation) =>
      !_disposed && generation == _generation && !_cancel.cancelled;
  void _guard(int generation, SyncVaultContext context) {
    if (!_current(generation)) throw const SyncTransportCancelled();
    access.guardVaultContext(context);
  }

  String _safe(Object error) => switch (error) {
    SyncUnsupportedContentVersion() => 'UNSUPPORTED_CONTENT_VERSION',
    SyncRemoteFailure() => error.code,
    OperationFailure() => error.code.wire,
    SyncTransportCancelled() => 'SYNC_CANCELLED',
    _ => 'PROTECTION_UNAVAILABLE',
  };
  void _failed(int generation, Object error) {
    if (_current(generation) && error is! SyncTransportCancelled)
      _emit(SyncVaultPhase.error, error: _safe(error));
  }

  Future<SyncHead> _readHead(int generation, SyncVaultContext context) async {
    _guard(generation, context);
    final head = await access.readVaultHead(context, _cancel);
    _guard(generation, context);
    if (head.vaultId != context.fence.identity.vaultId ||
        head.revision < repository.domain.read((r) => r.syncState.baseRevision))
      throw const OperationFailure(FailureCode.conflict);
    _head = head;
    return head;
  }

  List<SyncRootRecord> _localRoots() => repository.domain.read((r) {
    if (r.syncRootCount() > 6)
      throw const OperationFailure(FailureCode.storageUnavailable);
    return r
        .syncRoots()
        .where((root) => root.role != 'detached')
        .toList(growable: false);
  });
  void _verifyLocalRoots(
    SyncCrypto crypto,
    SyncVaultContext context,
    List<SyncRootRecord> roots,
  ) {
    for (final root in roots) {
      if (!context.fence.identity.owns(root) ||
          root.manifestLength != root.manifestCiphertext.length ||
          root.objectHashes.length != root.objectLengths.length)
        throw const OperationFailure(FailureCode.storageUnavailable);
      final ciphertext = Uint8List.fromList(root.manifestCiphertext);
      try {
        crypto.decryptRoot(
          envelope: ciphertext,
          root: SyncBlobRef(syncSha256(ciphertext), ciphertext.length),
          objects: List.generate(
            root.objectHashes.length,
            (i) => SyncBlobRef(root.objectHashes[i], root.objectLengths[i]),
          ),
          snapshotId: root.snapshotId,
          revision: root.remoteRevision,
        );
      } on SyncUnsupportedContentVersion {
        rethrow;
      } catch (_) {
        throw const OperationFailure(FailureCode.cleanupRequired);
      }
    }
  }

  Future<void> _verifyRemote(
    int generation,
    SyncVaultContext context,
    SyncHead head,
    SyncCrypto crypto,
  ) async {
    final manifest = head.manifest;
    if (manifest == null) return;
    final encrypted = await access.readVaultRoot(context, manifest, _cancel);
    try {
      _guard(generation, context);
      crypto.decryptRoot(
        envelope: encrypted,
        root: manifest.root,
        objects: manifest.objects,
        snapshotId: manifest.snapshotId,
        revision: manifest.revision,
      );
    } finally {
      encrypted.fillRange(0, encrypted.length, 0);
    }
  }

  /// Explicit inspect/retry, or foreground root initialization. Never publishes.
  Future<void> inspect() async {
    final generation = _begin(SyncVaultPhase.checking);
    Uint8List? key;
    SyncCrypto? candidate;
    try {
      final context = await access.vaultContext();
      _guard(generation, context);
      _context = context;
      final head = await _readHead(generation, context);
      final wrapped = repository.domain.read(
        (r) => r.syncSecrets.protectedVaultRootKey,
      );
      if (wrapped == null) {
        _emit(
          head.revision == 0
              ? SyncVaultPhase.needsInitialization
              : SyncVaultPhase.locked,
        );
        return;
      }
      key = await box.unprotectVaultKey(context.fence.identity, wrapped);
      _guard(generation, context);
      candidate = SyncCrypto(identity: context.fence.identity, rootKey: key);
      await _verifyRemote(generation, context, head, candidate);
      _guard(generation, context);
      _verifyLocalRoots(candidate, context, _localRoots());
      _crypto = candidate;
      candidate = null;
      _emit(SyncVaultPhase.ready);
    } catch (error) {
      _failed(generation, error);
      rethrow;
    } finally {
      key?.fillRange(0, key.length, 0);
      candidate?.dispose();
    }
  }

  Future<SyncRecoveryChallenge> beginInitialization() async {
    final generation = _begin(SyncVaultPhase.checking);
    Uint8List? key;
    try {
      final context = await access.vaultContext();
      _guard(generation, context);
      _context = context;
      final head = await _readHead(generation, context);
      if (head.revision != 0 ||
          repository.domain.read((r) => r.syncSecrets.protectedVaultRootKey) !=
              null ||
          _localRoots().isNotEmpty) {
        throw const OperationFailure(FailureCode.conflict);
      }
      key = _random(32);
      if (key.length != 32)
        throw const OperationFailure(FailureCode.protectionUnavailable);
      final challenge = SyncRecoveryChallenge._(Uint8List.fromList(key));
      _challenge = challenge;
      _emit(SyncVaultPhase.awaitingConfirmation);
      return challenge;
    } catch (error) {
      _failed(generation, error);
      rethrow;
    } finally {
      key?.fillRange(0, key.length, 0);
    }
  }

  Future<void> confirmInitialization(
    SyncRecoveryChallenge challenge, {
    required bool saved,
    required String checksum,
  }) async {
    if (_disposed ||
        _confirming ||
        !identical(_challenge, challenge) ||
        challenge.disposed ||
        _context == null)
      throw _invalidRecovery;
    if (!saved || checksum.trim() != challenge.checksum) throw _invalidRecovery;
    final generation = _generation, context = _context!;
    _guard(generation, context);
    _confirming = true;
    _emit(SyncVaultPhase.unlocking);
    SyncCrypto? candidate;
    Uint8List? wrapped;
    try {
      final head = await _readHead(generation, context);
      if (head.revision != 0)
        throw const OperationFailure(FailureCode.conflict);
      final roots = _localRoots();
      if (roots.isNotEmpty) throw const OperationFailure(FailureCode.conflict);
      candidate = SyncCrypto(
        identity: context.fence.identity,
        rootKey: challenge._key,
      );
      wrapped = await box.protectVaultKey(
        context.fence.identity,
        challenge._key,
      );
      _guard(generation, context);
      await repository.saveVaultKey(
        context.fence,
        wrapped,
        expectedKey: null,
        expectedRoots: roots,
        isCurrent: () =>
            _current(generation) && access.isVaultContextCurrent(context),
      );
      _guard(generation, context);
      _crypto = candidate;
      candidate = null;
      _challenge = null;
      challenge.dispose();
      _emit(SyncVaultPhase.ready);
    } catch (error) {
      _failed(generation, error);
      rethrow;
    } finally {
      wrapped?.fillRange(0, wrapped.length, 0);
      candidate?.dispose();
      if (_current(generation)) _confirming = false;
    }
  }

  void cancelInitialization(SyncRecoveryChallenge challenge) {
    if (identical(_challenge, challenge)) lock();
  }

  Future<void> unlock(String code) async {
    final generation = _begin(SyncVaultPhase.unlocking);
    Uint8List? key, wrapped;
    SyncCrypto? candidate;
    try {
      key = SyncRecoveryCodec.decode(code);
      final context = await access.vaultContext();
      _guard(generation, context);
      _context = context;
      final head = await _readHead(generation, context);
      // An empty vault has no authentication oracle for a supplied code.
      if (head.revision == 0)
        throw const OperationFailure(FailureCode.conflict);
      final previous = repository.domain.read(
        (r) => r.syncSecrets.protectedVaultRootKey,
      );
      candidate = SyncCrypto(identity: context.fence.identity, rootKey: key);
      await _verifyRemote(generation, context, head, candidate);
      _guard(generation, context);
      final roots = _localRoots();
      _verifyLocalRoots(candidate, context, roots);
      wrapped = await box.protectVaultKey(context.fence.identity, key);
      _guard(generation, context);
      await repository.saveVaultKey(
        context.fence,
        wrapped,
        expectedKey: previous,
        expectedRoots: roots,
        isCurrent: () =>
            _current(generation) && access.isVaultContextCurrent(context),
      );
      _guard(generation, context);
      _crypto = candidate;
      candidate = null;
      _emit(SyncVaultPhase.ready);
    } catch (error) {
      _failed(generation, error);
      rethrow;
    } finally {
      key?.fillRange(0, key.length, 0);
      wrapped?.fillRange(0, wrapped.length, 0);
      candidate?.dispose();
    }
  }

  T withCrypto<T>(T Function(SyncCrypto crypto) action) {
    final context = _context, crypto = _crypto;
    if (context == null || crypto == null || view.phase != SyncVaultPhase.ready)
      throw const OperationFailure(FailureCode.authRequired);
    _guard(_generation, context);
    return action(crypto);
  }
}
