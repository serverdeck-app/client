import 'dart:typed_data';

import '../domain/models.dart';
import '../storage/domain_repository.dart';
import '../storage/records.dart';
import 'sync_models.dart';

const _conflict = OperationFailure(FailureCode.conflict);
const _invalid = OperationFailure(FailureCode.invalidArgument);
const _storage = OperationFailure(
  FailureCode.storageUnavailable,
  retryable: true,
);
const _exhausted = OperationFailure(FailureCode.resourceExhausted);

const syncRefreshInFlight = 'AUTH_REFRESH_IN_FLIGHT';
const syncLoginRequired = 'AUTH_LOGIN_REQUIRED';
const syncDeviceRevoked = 'AUTH_DEVICE_REVOKED';
const syncVaultReset = 'AUTH_VAULT_RESET';
const syncDisconnectPending = 'AUTH_DISCONNECT_PENDING';

/// Native reachability progress; contains no object identities or values.
final class SyncGarbagePass {
  const SyncGarbagePass(this.examined, this.removed, this.finished);
  final int examined, removed;
  final bool finished;
}

/// Owned opaque publication input. Authentication/consent belong to SyncApply;
/// this type validates only immutable IDs, references and storage bounds.
final class SyncPendingIntent {
  SyncPendingIntent({
    required this.rootId,
    required this.snapshotId,
    required this.commitId,
    required this.revision,
    required Uint8List ciphertext,
    required List<SyncBlobRef> objects,
  }) : _ciphertext = _copyCipher(
         rootId,
         snapshotId,
         commitId,
         revision,
         ciphertext,
       ),
       _objects = _copyObjects(objects) {
    final rootHash = syncSha256(_ciphertext);
    if (_objects.map((ref) => ref.sha256).toSet().length != objects.length ||
        _objects.any((ref) => ref.sha256 == rootHash) ||
        _objects.fold(_ciphertext.length, (sum, ref) => sum + ref.bytes) >
            syncMaxHeadBytes) {
      dispose();
      throw _invalid;
    }
  }
  final String rootId, snapshotId, commitId;
  final int revision;
  final Uint8List _ciphertext;
  final List<SyncBlobRef> _objects;
  bool _disposed = false;
  static Uint8List _copyCipher(
    String root,
    String snapshot,
    String commit,
    int revision,
    Uint8List bytes,
  ) {
    if (![root, snapshot, commit].every(isCanonicalUuid) ||
        revision < 1 ||
        revision > syncMaxInteger ||
        bytes.length < 28 ||
        bytes.length > syncMaxRootBytes)
      throw _invalid;
    return Uint8List.fromList(bytes);
  }

  static List<SyncBlobRef> _copyObjects(List<SyncBlobRef> objects) {
    if (objects.length > 11000) throw _invalid;
    return List<SyncBlobRef>.unmodifiable(
      List<SyncBlobRef>.of(objects)
        ..sort((a, b) => a.sha256.compareTo(b.sha256)),
    );
  }

  void dispose() {
    _disposed = true;
    _ciphertext.fillRange(0, _ciphertext.length, 0);
  }
}

/// One native preparation flight. Pins opaque working objects against GC until
/// dispose; it is not a durable root, sync authorization or plaintext spool.
final class SyncPreparation {
  SyncPreparation._(
    this._owner,
    this.fence,
    this.dataRevision,
    this.syncGeneration,
    this._state,
    this._isCurrent,
    this._rootedKeys,
  );
  final SyncRepository _owner;
  final SyncFence fence;
  final int dataRevision, syncGeneration;
  final SyncStateRecord _state;
  final bool Function() _isCurrent;
  // Snapshot of immutable active-root references under _guardPreparation's
  // alias/fence checks. Root-backed objects do not spend the new-working quota.
  final Set<String> _rootedKeys;
  final _pins = <String>{};
  final _workingPins = <String>{};
  bool _active = true;
  void dispose() {
    _active = false;
    _pins.clear();
    _workingPins.clear();
    _rootedKeys.clear();
    if (identical(_owner._preparation, this)) _owner._preparation = null;
  }
}

/// Fresh space probe plus an immutable root transition. Caller invokes commit
/// inside the same guarded transaction as its domain writes, before counters.
final class SyncPreparedTransition {
  SyncPreparedTransition._(
    this._owner,
    this._preparation,
    this._remote,
    this._pending,
    this._commitId,
    this._free,
    this._domainBytes,
    this._acknowledgeGeneration,
    this._successUtc,
    this._consumePending,
  );
  final SyncRepository _owner;
  final SyncPreparation _preparation;
  final SyncRootRecord? _remote, _pending;
  final String? _commitId;
  final int _free, _domainBytes, _acknowledgeGeneration, _successUtc;
  final bool _consumePending;
  bool _used = false;
  void commit(DomainTransaction records) {
    if (_used) throw _conflict;
    _owner._commitPrepared(records, this);
  }
}

abstract final class SyncStorageBudget {
  static void check({
    required int cipherBytes,
    required int preparedBytes,
    required int missingBytes,
    required int freeBytes,
    int writeBytes = 0,
  }) {
    if ([
      cipherBytes,
      preparedBytes,
      missingBytes,
      freeBytes,
      writeBytes,
    ].any((value) => value < 0))
      throw _storage;
    if (cipherBytes + missingBytes > syncMaxWorkingBytes ||
        cipherBytes + preparedBytes + missingBytes >
            32 * 1024 * 1024 * 1024 - syncMinFreeBytes ||
        freeBytes < syncMinFreeBytes + 2 * (missingBytes + writeBytes))
      throw _exhausted;
  }
}

/// Root-owned persistence only. Crypto authenticates content before admission;
/// transport never writes domain. All effects use the one DomainRepository.
final class SyncRepository {
  SyncRepository(
    this.domain, {
    required this.availableStorageBytes,
    int Function()? utcNow,
  }) : utcNow = utcNow ?? _utcNow;
  final DomainRepository domain;
  final Future<int> Function() availableStorageBytes;
  final int Function() utcNow;
  String? _gcCursor;
  SyncPreparation? _preparation;

  SyncPreparation beginPreparation(
    SyncFence fence, {
    required int expectedDataRevision,
    required int expectedSyncGeneration,
    required bool Function() isCurrent,
  }) {
    if (expectedDataRevision < 1 ||
        expectedDataRevision > syncMaxInteger ||
        expectedSyncGeneration < 0 ||
        expectedSyncGeneration > syncMaxInteger)
      throw _invalid;
    if (_preparation != null)
      throw const OperationFailure(
        FailureCode.resourceExhausted,
        retryable: true,
      );
    return domain.read((records) {
      _guard(records, fence);
      final state = records.syncState;
      if (!isCurrent() ||
          records.settings.dataRevision != expectedDataRevision ||
          state.syncGeneration != expectedSyncGeneration)
        throw _conflict;
      final rootedKeys = <String>{
        for (final root in _roots(records))
          if (root.role != 'detached' && fence.identity.owns(root))
            for (final hash in root.objectHashes)
              fence.identity.objectKey(hash),
      };
      return _preparation = SyncPreparation._(
        this,
        fence,
        expectedDataRevision,
        expectedSyncGeneration,
        state,
        isCurrent,
        rootedKeys,
      );
    });
  }

  void _guardPreparation(DomainRead records, SyncPreparation preparation) {
    final expected = preparation._state, current = records.syncState;
    if (!identical(preparation._owner, this) ||
        !preparation._active ||
        !identical(_preparation, preparation) ||
        !preparation._isCurrent() ||
        !preparation.fence.matches(current) ||
        records.settings.dataRevision != preparation.dataRevision ||
        current.syncGeneration != preparation.syncGeneration ||
        current.baseRevision != expected.baseRevision ||
        current.baseRootId != expected.baseRootId ||
        current.pendingRootId != expected.pendingRootId ||
        current.pendingCommitId != expected.pendingCommitId ||
        current.pendingUploadId != expected.pendingUploadId ||
        current.pendingUploadDeviceId != expected.pendingUploadDeviceId ||
        current.pendingUploadRetiring != expected.pendingUploadRetiring ||
        current.candidateRootId != expected.candidateRootId ||
        current.ackGeneration != expected.ackGeneration ||
        current.conflictLocalId != expected.conflictLocalId ||
        current.conflictRemoteId != expected.conflictRemoteId)
      throw _conflict;
  }

  /// Encrypted objects may be prepared before their final root exists. Existing
  /// putObject remains root-referenced-only; this scoped path is GC-pinned/budgeted.
  Future<void> prepareObject(
    SyncPreparation preparation,
    String hash,
    Uint8List ciphertext, {
    Uint8List? protectedCredential,
    String? credentialId,
  }) async {
    if (!isSyncHash(hash) ||
        ciphertext.length < 28 ||
        ciphertext.length > syncMaxObjectBytes ||
        syncSha256(ciphertext) != hash ||
        (protectedCredential == null
            ? credentialId != null
            : protectedCredential.isEmpty ||
                  protectedCredential.length > syncMaxRootBytes ||
                  credentialId == null ||
                  !isCanonicalUuid(credentialId)))
      throw _invalid;
    domain.read((r) => _guardPreparation(r, preparation));
    final key = preparation.fence.identity.objectKey(hash);
    if (!preparation._rootedKeys.contains(key)) {
      if (!preparation._workingPins.contains(key) &&
          preparation._workingPins.length >= 11000)
        throw _exhausted;
      preparation._workingPins.add(key);
    }
    // Keep even borrowed/root-backed keys pinned until disposal: a concurrent
    // root transition may invalidate preparation before its async work drains.
    preparation._pins.add(key);
    final bytes = Uint8List.fromList(ciphertext),
        protected = protectedCredential == null
            ? null
            : Uint8List.fromList(protectedCredential);
    final free = await _free();
    return _write((records) {
      _guardPreparation(records, preparation);
      final identity = preparation.fence.identity;
      final old = records.syncObject(key);
      if (old != null &&
          (old.reservedLength != bytes.length ||
              old.sha256 != hash ||
              old.serviceOrigin != identity.serviceOrigin ||
              old.accountId != identity.accountId ||
              old.vaultId != identity.vaultId ||
              old.cipherLength != 0 && !_bytesEqual(old.cipherBytes, bytes)))
        throw _storage;
      final value =
          old ??
          (SyncObjectRecord()
            ..objectKey = key
            ..serviceOrigin = identity.serviceOrigin
            ..accountId = identity.accountId
            ..vaultId = identity.vaultId
            ..sha256 = hash
            ..reservedLength = bytes.length);
      value.cipherBytes = bytes;
      if (protected != null) {
        value
          ..locallyPreparedCredential = protected
          ..preparedCredentialId = credentialId
          ..preparedAgainstGeneration = preparation.dataRevision;
      }
      _budget(
        records,
        _roots(records),
        free,
        writeBytes: bytes.length + (protected?.length ?? 0),
        objectKey: key,
        objectLength: bytes.length,
        preparedLength: value.locallyPreparedCredential?.length ?? 0,
        newReferences: [SyncBlobRef(hash, bytes.length)],
        referenceIdentity: identity,
      );
      records.putSyncObject(value);
    });
  }

  Future<SyncPreparedTransition> prepareTransition(
    SyncPreparation preparation, {
    required String? remoteRootId,
    SyncPendingIntent? pending,
    required bool consumePending,
    required int acknowledgeGeneration,
    required int successUtc,
    int domainWriteBytes = 0,
  }) async {
    if (domainWriteBytes < 0 ||
        domainWriteBytes > 8 * 1024 * 1024 * 1024 ||
        successUtc < 0 ||
        successUtc > syncMaxInteger ||
        remoteRootId == null && pending == null ||
        remoteRootId != null && !isCanonicalUuid(remoteRootId))
      throw _invalid;
    final remote = domain.read((records) {
      _guardPreparation(records, preparation);
      return remoteRootId == null ? null : records.syncRoot(remoteRootId);
    });
    if (remoteRootId != null && remote == null || pending?._disposed == true)
      throw _conflict;
    SyncRootRecord? next;
    if (pending != null) {
      final identity = preparation.fence.identity;
      next = SyncRootRecord()
        ..rootId = pending.rootId
        ..snapshotId = pending.snapshotId
        ..remoteRevision = pending.revision
        ..role = 'pending'
        ..sourceGeneration = preparation.syncGeneration
        ..serviceOrigin = identity.serviceOrigin
        ..accountId = identity.accountId
        ..vaultId = identity.vaultId
        ..manifestCiphertext = Uint8List.fromList(pending._ciphertext)
        ..manifestLength = pending._ciphertext.length
        ..objectHashes = pending._objects.map((ref) => ref.sha256).toList()
        ..objectLengths = pending._objects.map((ref) => ref.bytes).toList()
        ..createdAt = utcNow();
      if (next.createdAt < 0 || next.createdAt > syncMaxInteger) throw _storage;
    }
    final free = await _free();
    final transition = SyncPreparedTransition._(
      this,
      preparation,
      remote,
      next,
      pending?.commitId,
      free,
      domainWriteBytes,
      acknowledgeGeneration,
      successUtc,
      consumePending,
    );
    domain.read((records) => _checkTransition(records, transition));
    return transition;
  }

  List<SyncRootRecord> _checkTransition(
    DomainRead records,
    SyncPreparedTransition transition,
  ) {
    final preparation = transition._preparation;
    _guardPreparation(records, preparation);
    final state = records.syncState,
        remote = transition._remote,
        pending = transition._pending;
    final roots = _roots(records);
    if (state.pendingRootId != null && !transition._consumePending ||
        transition._acknowledgeGeneration < state.ackGeneration ||
        transition._acknowledgeGeneration > preparation.syncGeneration ||
        pending != null &&
            transition._acknowledgeGeneration != state.ackGeneration)
      throw _conflict;
    if (remote == null) {
      if (state.baseRevision != 0 || state.baseRootId != null) throw _conflict;
    } else {
      final current = records.syncRoot(remote.rootId);
      if (remote.rootId != state.baseRootId &&
              remote.rootId != state.candidateRootId ||
          current == null ||
          !_sameRoot(current, remote) ||
          !preparation.fence.identity.owns(remote) ||
          remote.remoteRevision < state.baseRevision ||
          remote.rootId == state.baseRootId && remote.role != 'base' ||
          remote.rootId == state.candidateRootId && remote.role != 'candidate')
        throw _conflict;
      final base = state.baseRootId == null
          ? null
          : records.syncRoot(state.baseRootId!);
      if (remote.remoteRevision == state.baseRevision &&
          base != null &&
          !_sameRootContent(base, remote))
        throw _conflict;
    }
    if (pending != null &&
        (pending.remoteRevision != (remote?.remoteRevision ?? 0) + 1 ||
            roots.any(
              (root) =>
                  root.rootId == pending.rootId ||
                  root.snapshotId == pending.snapshotId,
            ) ||
            transition._commitId == state.pendingCommitId))
      throw _conflict;
    for (final root in [
      if (remote != null) remote,
      if (pending != null) pending,
    ]) {
      for (var i = 0; i < root.objectHashes.length; i++) {
        if (records.syncObjectLength(
              preparation.fence.identity.objectKey(root.objectHashes[i]),
            ) !=
            root.objectLengths[i])
          throw _conflict;
      }
    }
    final proposed = roots.where((root) => root.role == 'detached').toList()
      ..addAll([if (remote != null) remote, if (pending != null) pending]);
    _budget(
      records,
      proposed,
      transition._free,
      writeBytes:
          transition._domainBytes +
          (pending?.manifestLength ?? 0) +
          (pending?.objectHashes.length ?? 0) * 96,
    );
    return proposed;
  }

  void _commitPrepared(
    DomainTransaction records,
    SyncPreparedTransition transition,
  ) {
    if (!identical(transition._owner, this) || transition._used)
      throw _conflict;
    _checkTransition(records, transition);
    final state = records.syncState;
    final remote = transition._remote, pending = transition._pending;
    transition._used = true;
    // Active root IDs change atomically with the caller's domain write. Detached
    // roots and ciphertext caches remain; only now-obsolete active roots leave.
    for (final root in _roots(
      records,
    ).where((root) => root.role != 'detached')) {
      if (root.rootId != remote?.rootId) records.deleteSyncRoot(root.rootId);
    }
    if (remote != null) {
      final stored = records.syncRoot(remote.rootId)!..role = 'base';
      records.putSyncRoot(stored);
    }
    if (pending != null) records.putSyncRoot(pending);
    state
      ..baseRootId = remote?.rootId
      ..baseRevision = remote?.remoteRevision ?? 0
      ..pendingRootId = pending?.rootId
      ..pendingCommitId = transition._commitId
      ..pendingUploadRetiring = false
      ..pendingUploadId = pending?.rootId
      ..pendingUploadDeviceId = pending == null
          ? null
          : transition._preparation.fence.identity.deviceId
      ..candidateRootId = null
      ..conflictLocalId = null
      ..conflictRemoteId = null
      ..ackGeneration = transition._acknowledgeGeneration;
    if (pending == null) state.lastSuccessUtc = transition._successUtc;
    records.putSyncState(state);
  }

  SyncFence capture() => domain.read((records) {
    final state = records.syncState;
    if (!state.enabled ||
        state.accountId == null ||
        state.deviceId == null ||
        state.vaultId == null ||
        state.serviceOrigin == null) {
      throw const OperationFailure(FailureCode.authRequired);
    }
    return SyncFence(
      SyncIdentity(
        serviceOrigin: state.serviceOrigin!,
        accountId: state.accountId!,
        deviceId: state.deviceId!,
        vaultId: state.vaultId!,
      ),
      state.identityGeneration,
    );
  });

  static void markDirty(DomainTransaction records) {
    final state = records.syncState;
    state.syncGeneration = _next(state.syncGeneration);
    records.putSyncState(state);
  }

  static int _next(int value) {
    if (value < 0 || value >= syncMaxInteger) throw _exhausted;
    return value + 1;
  }

  void _guard(DomainRead records, SyncFence fence) {
    if (!fence.matches(records.syncState)) throw _conflict;
  }

  Future<T> _write<T>(T Function(DomainTransaction) body) async {
    try {
      return await domain.write(body);
    } on OperationFailure {
      rethrow;
    } catch (_) {
      throw _storage;
    }
  }

  Future<int> _free() async {
    try {
      final value = await availableStorageBytes();
      if (value < 0) throw _storage;
      return value;
    } on OperationFailure {
      rethrow;
    } catch (_) {
      throw _storage;
    }
  }

  SyncSecretRecord _secrets(SyncSecretRecord value) {
    for (final bytes in [
      value.protectedAccess,
      value.protectedRefresh,
      value.protectedStatusProof,
      value.protectedVaultRootKey,
    ]) {
      if (bytes != null &&
          (bytes.isEmpty ||
              bytes.length > syncMaxRootBytes ||
              bytes.any((byte) => byte < 0 || byte > 255)))
        throw _invalid;
    }
    if (value.id != 1) throw _invalid;
    return SyncSecretRecord()
      ..protectedAccess = value.protectedAccess == null
          ? null
          : [...value.protectedAccess!]
      ..protectedRefresh = value.protectedRefresh == null
          ? null
          : [...value.protectedRefresh!]
      ..protectedStatusProof = value.protectedStatusProof == null
          ? null
          : [...value.protectedStatusProof!]
      ..protectedVaultRootKey = value.protectedVaultRootKey == null
          ? null
          : [...value.protectedVaultRootKey!];
  }

  Future<SyncFence> bind({
    required int expectedGeneration,
    required SyncIdentity identity,
    required SyncSecretRecord secrets,
    bool Function()? isCurrent,
  }) async {
    final saved = _secrets(secrets);
    if (saved.protectedAccess == null ||
        saved.protectedRefresh == null ||
        saved.protectedStatusProof == null)
      throw _invalid;
    final free = await _free();
    return _write((records) {
      if (isCurrent != null && !isCurrent()) throw _conflict;
      final state = records.syncState;
      if (state.identityGeneration != expectedGeneration ||
          state.accountId != null ||
          state.enabled)
        throw _conflict;
      final roots = _roots(records);
      if (roots.any((root) => root.role != 'detached')) throw _storage;
      _budget(records, roots, free, writeBytes: _secretSize(saved));
      state
        ..serviceOrigin = identity.serviceOrigin
        ..accountId = identity.accountId
        ..deviceId = identity.deviceId
        ..vaultId = identity.vaultId
        ..identityGeneration = _next(state.identityGeneration)
        ..enabled = true
        ..ackGeneration = 0
        ..baseRevision = 0
        ..lastSuccessUtc = null
        ..errorCode = null
        ..baseRootId = null
        ..pendingRootId = null
        ..pendingCommitId = null
        ..pendingUploadRetiring = false
        ..pendingUploadId = null
        ..pendingUploadDeviceId = null
        ..candidateRootId = null
        ..conflictLocalId = null
        ..conflictRemoteId = null;
      records.putSyncSecrets(saved);
      records.putSyncState(state);
      _gcCursor = null;
      return SyncFence(identity, state.identityGeneration);
    });
  }

  int _secretSize(SyncSecretRecord value) =>
      (value.protectedAccess?.length ?? 0) +
      (value.protectedRefresh?.length ?? 0) +
      (value.protectedStatusProof?.length ?? 0) +
      (value.protectedVaultRootKey?.length ?? 0);

  Future<void> saveSecrets(SyncFence fence, SyncSecretRecord secrets) async {
    final saved = _secrets(secrets);
    domain.read((records) => _guard(records, fence));
    final free = await _free();
    return _write((records) {
      _guard(records, fence);
      _budget(records, _roots(records), free, writeBytes: _secretSize(saved));
      records.putSyncSecrets(saved);
    });
  }

  Future<void> beginAuthRefresh(SyncFence fence, List<int> expectedRefresh) =>
      _write((records) {
        _guard(records, fence);
        final state = records.syncState;
        if ({
              syncRefreshInFlight,
              syncLoginRequired,
              syncDeviceRevoked,
              syncVaultReset,
            }.contains(state.errorCode) ||
            records.syncSecrets.protectedRefresh == null ||
            !_bytesEqual(
              records.syncSecrets.protectedRefresh!,
              expectedRefresh,
            ))
          throw _conflict;
        state.errorCode = syncRefreshInFlight;
        records.putSyncState(state);
      });

  /// Partial key-slot CAS; never restores stale auth fields during refresh.
  Future<void> saveVaultKey(
    SyncFence fence,
    Uint8List key, {
    required List<int>? expectedKey,
    required List<SyncRootRecord> expectedRoots,
    bool Function()? isCurrent,
  }) async {
    final saved = _secrets(SyncSecretRecord()..protectedVaultRootKey = [...key])
        .protectedVaultRootKey!;
    final free = await _free();
    return _write((records) {
      if (isCurrent != null && !isCurrent()) throw _conflict;
      _guard(records, fence);
      if ({
        syncLoginRequired,
        syncDeviceRevoked,
        syncVaultReset,
      }.contains(records.syncState.errorCode))
        throw const OperationFailure(FailureCode.authRequired);
      final current = records.syncSecrets,
          previous = current.protectedVaultRootKey;
      if (previous == null
          ? expectedKey != null
          : expectedKey == null || !_bytesEqual(previous, expectedKey))
        throw _conflict;
      final roots = _roots(records),
          active = roots.where((root) => root.role != 'detached').toList();
      if (active.length != expectedRoots.length ||
          active.any(
            (root) =>
                !expectedRoots.any((expected) => _sameRoot(root, expected)),
          ))
        throw _conflict;
      current.protectedVaultRootKey = saved;
      _budget(records, roots, free, writeBytes: _secretSize(current));
      records.putSyncSecrets(current);
    });
  }

  Future<void> completeAuthRefresh(
    SyncFence fence, {
    required List<int> expectedRefresh,
    required Uint8List access,
    required Uint8List refresh,
    bool Function()? isCurrent,
  }) async {
    final values = _secrets(
      SyncSecretRecord()
        ..protectedAccess = [...access]
        ..protectedRefresh = [...refresh],
    );
    final free = await _free();
    return _write((records) {
      if (isCurrent != null && !isCurrent()) throw _conflict;
      _guard(records, fence);
      final state = records.syncState, current = records.syncSecrets;
      if (state.errorCode != syncRefreshInFlight ||
          current.protectedRefresh == null ||
          !_bytesEqual(current.protectedRefresh!, expectedRefresh))
        throw _conflict;
      current
        ..protectedAccess = values.protectedAccess
        ..protectedRefresh = values.protectedRefresh;
      _budget(records, _roots(records), free, writeBytes: _secretSize(current));
      state.errorCode = null;
      records.putSyncSecrets(current);
      records.putSyncState(state);
    });
  }

  /// Durable admission stop without deleting local domain or pending intent.
  /// Full detach/keep/delete/import workflow remains the lifecycle owner task.
  Future<SyncFence> blockAuthorization(
    SyncFence fence,
    String reason, {
    bool Function()? isCurrent,
  }) => _write((records) {
    _continuation(isCurrent);
    _guard(records, fence);
    if (!{
      syncLoginRequired,
      syncDeviceRevoked,
      syncVaultReset,
      syncDisconnectPending,
    }.contains(reason))
      throw _invalid;
    final state = records.syncState, current = records.syncSecrets;
    current
      ..protectedAccess = null
      ..protectedRefresh = null;
    if (reason != syncLoginRequired) current.protectedVaultRootKey = null;
    state
      ..errorCode = reason
      ..identityGeneration = _next(state.identityGeneration);
    records.putSyncSecrets(current);
    records.putSyncState(state);
    return SyncFence(fence.identity, state.identityGeneration);
  });

  Future<SyncFence> reauthorize(
    SyncFence previous,
    SyncIdentity identity,
    SyncSecretRecord secrets, {
    bool Function()? isCurrent,
  }) async {
    final saved = _secrets(secrets);
    if (saved.protectedAccess == null ||
        saved.protectedRefresh == null ||
        saved.protectedStatusProof == null ||
        identity.serviceOrigin != previous.identity.serviceOrigin ||
        identity.accountId != previous.identity.accountId ||
        identity.vaultId != previous.identity.vaultId)
      throw _invalid;
    final free = await _free();
    return _write((records) {
      if (isCurrent != null && !isCurrent()) throw _conflict;
      _guard(records, previous);
      final state = records.syncState;
      if (state.errorCode == syncVaultReset) throw _conflict;
      saved.protectedVaultRootKey = records.syncSecrets.protectedVaultRootKey;
      _budget(records, _roots(records), free, writeBytes: _secretSize(saved));
      state
        ..deviceId = identity.deviceId
        ..identityGeneration = _next(state.identityGeneration)
        ..errorCode = null;
      records.putSyncSecrets(saved);
      records.putSyncState(state);
      return SyncFence(identity, state.identityGeneration);
    });
  }

  List<SyncRootRecord> _roots(DomainRead records) {
    if (records.syncRootCount() > 6) throw _storage;
    final roots = records.syncRoots();
    if (roots.length != records.syncRootCount()) throw _storage;
    for (final root in roots) {
      if (root.manifestLength != root.manifestCiphertext.length ||
          root.objectHashes.length != root.objectLengths.length ||
          root.objectHashes.length > 11000)
        throw _storage;
    }
    final detached = roots.where((root) => root.role == 'detached').toList();
    final active = roots.where((root) => root.role != 'detached').toList();
    if (detached.length > 3 ||
        active.length > 3 ||
        roots.any(
          (root) =>
              !{'base', 'pending', 'candidate', 'detached'}.contains(root.role),
        ) ||
        detached
                .map(
                  (root) =>
                      '${root.serviceOrigin}|${root.accountId}|${root.vaultId}',
                )
                .toSet()
                .length >
            1)
      throw _storage;
    final state = records.syncState;
    final referenced = {
      state.baseRootId,
      state.pendingRootId,
      state.candidateRootId,
      state.conflictLocalId,
      state.conflictRemoteId,
    };
    if (active.any(
      (root) =>
          !state.enabled ||
          !referenced.contains(root.rootId) ||
          root.serviceOrigin != state.serviceOrigin ||
          root.accountId != state.accountId ||
          root.vaultId != state.vaultId,
    ))
      throw _storage;
    return roots;
  }

  void _budget(
    DomainRead records,
    List<SyncRootRecord> proposed,
    int free, {
    int writeBytes = 0,
    String? objectKey,
    int? objectLength,
    int? preparedLength,
    List<SyncBlobRef> newReferences = const [],
    SyncIdentity? referenceIdentity,
  }) {
    final current = _roots(records);
    var cipher =
        records.syncCipherByteCount() -
        current.fold<int>(0, (sum, root) => sum + root.manifestLength) +
        proposed.fold<int>(
          0,
          (sum, root) => sum + root.manifestCiphertext.length,
        );
    var prepared = records.syncPreparedByteCount();
    var missing = records.syncMissingByteCount();
    if (objectKey != null) {
      final delta = objectLength! - (records.syncObjectLength(objectKey) ?? 0);
      cipher += delta;
      missing -= delta;
      prepared += preparedLength! - records.syncObjectPreparedLength(objectKey);
    }
    for (final ref in newReferences) {
      final key = referenceIdentity!.objectKey(ref.sha256);
      final reserved = records.syncObjectReservedLength(key);
      if (reserved == null) {
        missing += ref.bytes;
      } else if (reserved != ref.bytes) {
        throw _invalid;
      }
    }
    SyncStorageBudget.check(
      cipherBytes: cipher,
      preparedBytes: prepared,
      missingBytes: missing,
      freeBytes: free,
      writeBytes: writeBytes,
    );
  }

  Future<void> stageRoot(
    SyncFence fence, {
    required String rootId,
    required String snapshotId,
    required int revision,
    required int sourceGeneration,
    required Uint8List rootCiphertext,
    required List<SyncBlobRef> objects,
    required bool pending,
    String? commitId,
    bool Function()? isCurrent,
  }) async {
    if (!isCanonicalUuid(rootId) ||
        !isCanonicalUuid(snapshotId) ||
        revision < 1 ||
        revision > syncMaxInteger ||
        sourceGeneration < 0 ||
        sourceGeneration > syncMaxInteger ||
        rootCiphertext.isEmpty ||
        rootCiphertext.length > syncMaxRootBytes ||
        objects.length > 11000 ||
        (pending
            ? commitId == null || !isCanonicalUuid(commitId)
            : commitId != null))
      throw _invalid;
    final refs = List<SyncBlobRef>.of(objects)
      ..sort((a, b) => a.sha256.compareTo(b.sha256));
    final rootHash = syncSha256(rootCiphertext);
    if (refs.map((ref) => ref.sha256).toSet().length != refs.length ||
        refs.any((ref) => ref.sha256 == rootHash) ||
        refs.fold(rootCiphertext.length, (sum, ref) => sum + ref.bytes) >
            syncMaxHeadBytes)
      throw _invalid;
    final root = SyncRootRecord()
      ..rootId = rootId
      ..snapshotId = snapshotId
      ..remoteRevision = revision
      ..sourceGeneration = sourceGeneration
      ..manifestCiphertext = Uint8List.fromList(rootCiphertext)
      ..manifestLength = rootCiphertext.length
      ..objectHashes = refs.map((ref) => ref.sha256).toList()
      ..objectLengths = refs.map((ref) => ref.bytes).toList()
      ..role = pending ? 'pending' : 'candidate'
      ..serviceOrigin = fence.identity.serviceOrigin
      ..accountId = fence.identity.accountId
      ..vaultId = fence.identity.vaultId;
    root.createdAt = utcNow();
    if (root.createdAt < 0 || root.createdAt > syncMaxInteger) throw _invalid;
    domain.read((records) => _guard(records, fence));
    final free = await _free();
    return _write((records) {
      _continuation(isCurrent);
      _guard(records, fence);
      final state = records.syncState;
      if (sourceGeneration > state.syncGeneration) throw _conflict;
      if (pending &&
          (sourceGeneration != state.syncGeneration ||
              revision != state.baseRevision + 1))
        throw _conflict;
      if (!pending && revision < state.baseRevision) throw _conflict;
      final old = records.syncRoot(rootId);
      if (old != null) {
        if (!_sameRoot(old, root) ||
            (pending &&
                (state.pendingRootId != rootId ||
                    state.pendingCommitId != commitId)))
          throw _conflict;
        return;
      }
      if (pending && state.pendingRootId != null) throw _conflict;
      final roots = _roots(records);
      final previousCandidate = pending ? null : state.candidateRootId;
      if (previousCandidate != null) {
        if (previousCandidate == state.baseRootId ||
            previousCandidate == state.pendingRootId)
          throw _storage;
        roots.removeWhere((value) => value.rootId == previousCandidate);
      }
      roots.add(root);
      if (roots.where((value) => value.role != 'detached').length > 3 ||
          roots.where((value) => value.role == 'detached').length > 3)
        throw _exhausted;
      _budget(
        records,
        roots,
        free,
        writeBytes: root.manifestLength + refs.length * 96,
        newReferences: refs,
        referenceIdentity: fence.identity,
      );
      if (previousCandidate != null) {
        records.deleteSyncRoot(previousCandidate);
        state
          ..conflictLocalId = null
          ..conflictRemoteId = null;
      }
      for (final ref in refs) {
        final key = fence.identity.objectKey(ref.sha256);
        if (records.syncObjectReservedLength(key) == null) {
          records.putSyncObject(
            SyncObjectRecord()
              ..objectKey = key
              ..serviceOrigin = fence.identity.serviceOrigin
              ..accountId = fence.identity.accountId
              ..vaultId = fence.identity.vaultId
              ..sha256 = ref.sha256
              ..reservedLength = ref.bytes,
          );
        }
      }
      records.putSyncRoot(root);
      if (pending) {
        state
          ..pendingRootId = rootId
          ..pendingCommitId = commitId
          ..pendingUploadRetiring = false
          ..pendingUploadId = rootId
          ..pendingUploadDeviceId = fence.identity.deviceId;
      } else {
        state.candidateRootId = rootId;
      }
      records.putSyncState(state);
    });
  }

  Future<void> putObject(
    SyncFence fence,
    String hash,
    Uint8List ciphertext, {
    Uint8List? protectedCredential,
    String? credentialId,
    int? preparedDataRevision,
    bool Function()? isCurrent,
  }) async {
    if (!isSyncHash(hash) ||
        ciphertext.isEmpty ||
        ciphertext.length > syncMaxObjectBytes ||
        syncSha256(ciphertext) != hash ||
        (protectedCredential == null
            ? credentialId != null || preparedDataRevision != null
            : protectedCredential.isEmpty ||
                  protectedCredential.length > syncMaxRootBytes ||
                  credentialId == null ||
                  !isCanonicalUuid(credentialId) ||
                  preparedDataRevision == null))
      throw _invalid;
    final bytes = Uint8List.fromList(ciphertext);
    final protected = protectedCredential == null
        ? null
        : Uint8List.fromList(protectedCredential);
    final key = fence.identity.objectKey(hash);
    domain.read((records) => _guard(records, fence));
    final free = await _free();
    return _write((records) {
      _continuation(isCurrent);
      _guard(records, fence);
      if (protected != null &&
          records.settings.dataRevision != preparedDataRevision)
        throw _conflict;
      final roots = _roots(records);
      if (!roots.any(
        (root) =>
            root.role != 'detached' &&
            fence.identity.owns(root) &&
            root.objectHashes.contains(hash),
      ))
        throw _conflict;
      final old = records.syncObject(key);
      if (old == null) throw _storage;
      if (old.reservedLength != bytes.length) throw _invalid;
      if ((old.cipherLength != 0 && !_bytesEqual(old.cipherBytes, bytes)) ||
          old.serviceOrigin != fence.identity.serviceOrigin ||
          old.accountId != fence.identity.accountId ||
          old.vaultId != fence.identity.vaultId ||
          old.sha256 != hash)
        throw _storage;
      final value = old;
      value.cipherBytes = bytes;
      if (protected != null) {
        value
          ..locallyPreparedCredential = protected
          ..preparedCredentialId = credentialId
          ..preparedAgainstGeneration = preparedDataRevision;
      }
      _budget(
        records,
        roots,
        free,
        writeBytes: bytes.length + (protected?.length ?? 0),
        objectKey: key,
        objectLength: bytes.length,
        preparedLength: value.locallyPreparedCredential?.length ?? 0,
      );
      records.putSyncObject(value);
    });
  }

  SyncObjectRecord readObject(SyncFence fence, String hash) =>
      domain.read((records) {
        _guard(records, fence);
        final value = records.syncObject(fence.identity.objectKey(hash));
        if (value == null || value.cipherLength == 0) throw _conflict;
        if (value.sha256 != hash ||
            syncSha256(value.cipherBytes) != hash ||
            value.cipherBytes.length != value.cipherLength ||
            value.serviceOrigin != fence.identity.serviceOrigin ||
            value.accountId != fence.identity.accountId ||
            value.vaultId != fence.identity.vaultId)
          throw _storage;
        return value;
      });

  Future<void> setConflict(
    SyncFence fence, {
    required String localRootId,
    required String remoteRootId,
  }) => _write((records) {
    _guard(records, fence);
    final state = records.syncState;
    if ((localRootId != state.pendingRootId &&
            localRootId != state.baseRootId) ||
        remoteRootId != state.candidateRootId)
      throw _conflict;
    state
      ..conflictLocalId = localRootId
      ..conflictRemoteId = remoteRootId;
    records.putSyncState(state);
  });

  /// Durable fail-closed instruction before cancelling a superseded upload.
  Future<void> markPendingRetiring(
    SyncFence fence, {
    required String rootId,
    required String commitId,
    required String? uploadId,
    required String? uploadDeviceId,
    required bool Function() isCurrent,
  }) => _write((records) {
    _continuation(isCurrent);
    _guard(records, fence);
    final state = records.syncState, root = records.syncRoot(rootId);
    if (state.pendingRootId != rootId ||
        state.pendingCommitId != commitId ||
        state.pendingUploadId != uploadId ||
        state.pendingUploadDeviceId != uploadDeviceId ||
        root == null ||
        root.role != 'pending' ||
        !fence.identity.owns(root))
      throw _conflict;
    state.pendingUploadRetiring = true;
    records.putSyncState(state);
  });

  /// Conditional native lease update. Root/header/commit/source generation remain
  /// immutable; a verified expired/foreign lease can be replaced before new HTTP.
  Future<void> replacePendingUpload(
    SyncFence fence, {
    required String rootId,
    required String commitId,
    required String? expectedUploadId,
    required String? expectedUploadDeviceId,
    required String uploadId,
    required bool Function() isCurrent,
  }) {
    if (![rootId, commitId, uploadId].every(isCanonicalUuid))
      return Future.error(_invalid);
    return _write((records) {
      _continuation(isCurrent);
      _guard(records, fence);
      final state = records.syncState, root = records.syncRoot(rootId);
      if (state.pendingUploadRetiring ||
          state.pendingRootId != rootId ||
          state.pendingCommitId != commitId ||
          state.pendingUploadId != expectedUploadId ||
          state.pendingUploadDeviceId != expectedUploadDeviceId ||
          root == null ||
          root.role != 'pending' ||
          !fence.identity.owns(root) ||
          root.sourceGeneration > state.syncGeneration ||
          root.sourceGeneration < state.ackGeneration ||
          uploadId == expectedUploadId &&
              expectedUploadDeviceId != null &&
              expectedUploadDeviceId != fence.identity.deviceId)
        throw _conflict;
      state
        ..pendingUploadId = uploadId
        ..pendingUploadDeviceId = fence.identity.deviceId;
      records.putSyncState(state);
    });
  }

  Future<void> acknowledge(
    SyncFence fence, {
    required String rootId,
    required String commitId,
    required int revision,
    required int successUtc,
    bool Function()? isCurrent,
  }) => _write((records) {
    _continuation(isCurrent);
    _guard(records, fence);
    _roots(records);
    final state = records.syncState;
    final root = records.syncRoot(rootId);
    if (root == null ||
        !fence.identity.owns(root) ||
        state.pendingRootId != rootId ||
        state.pendingCommitId != commitId ||
        root.remoteRevision != revision ||
        root.sourceGeneration > state.syncGeneration ||
        root.sourceGeneration < state.ackGeneration ||
        successUtc < 0 ||
        successUtc > syncMaxInteger)
      throw _conflict;
    for (var index = 0; index < root.objectHashes.length; index++) {
      if (records.syncObjectLength(
            fence.identity.objectKey(root.objectHashes[index]),
          ) !=
          root.objectLengths[index])
        throw _conflict;
    }
    final previousBase = state.baseRootId;
    root.role = 'base';
    state
      ..baseRootId = rootId
      ..baseRevision = revision
      ..ackGeneration = root.sourceGeneration
      ..pendingRootId = null
      ..pendingCommitId = null
      ..pendingUploadRetiring = false
      ..pendingUploadId = null
      ..pendingUploadDeviceId = null
      ..conflictLocalId = null
      ..conflictRemoteId = null
      ..lastSuccessUtc = successUtc;
    records.putSyncRoot(root);
    records.putSyncState(state);
    if (previousBase != null &&
        previousBase != rootId &&
        previousBase != state.conflictLocalId &&
        previousBase != state.conflictRemoteId &&
        previousBase != state.candidateRootId)
      records.deleteSyncRoot(previousBase);
  });

  /// SyncApply calls this before changing domain counters, inside its guarded
  /// write. This never calls public CRUD or fabricates UI/MCP events.
  void acceptCandidateInTransaction(
    DomainTransaction records,
    SyncFence fence, {
    required String rootId,
    required int expectedDataRevision,
    required int expectedSyncGeneration,
    required int acknowledgeGeneration,
    required int successUtc,
    bool consumePending = false,
  }) {
    _guard(records, fence);
    _roots(records);
    final state = records.syncState;
    final root = records.syncRoot(rootId);
    if (state.candidateRootId != rootId ||
        root == null ||
        !fence.identity.owns(root) ||
        root.remoteRevision < state.baseRevision ||
        records.settings.dataRevision != expectedDataRevision ||
        state.syncGeneration != expectedSyncGeneration ||
        acknowledgeGeneration < state.ackGeneration ||
        acknowledgeGeneration > expectedSyncGeneration ||
        successUtc < 0 ||
        successUtc > syncMaxInteger ||
        (state.pendingRootId != null && !consumePending))
      throw _conflict;
    for (var index = 0; index < root.objectHashes.length; index++) {
      if (records.syncObjectLength(
            fence.identity.objectKey(root.objectHashes[index]),
          ) !=
          root.objectLengths[index])
        throw _conflict;
    }
    final obsolete = {state.baseRootId, state.pendingRootId};
    root.role = 'base';
    state
      ..baseRootId = rootId
      ..baseRevision = root.remoteRevision
      ..ackGeneration = acknowledgeGeneration
      ..candidateRootId = null
      ..pendingRootId = null
      ..pendingCommitId = null
      ..pendingUploadRetiring = false
      ..pendingUploadId = null
      ..pendingUploadDeviceId = null
      ..conflictLocalId = null
      ..conflictRemoteId = null
      ..lastSuccessUtc = successUtc;
    records.putSyncRoot(root);
    records.putSyncState(state);
    for (final id in obsolete) {
      if (id != null && id != rootId) records.deleteSyncRoot(id);
    }
  }

  Future<int> detach(SyncFence fence) =>
      _write((records) => detachInTransaction(records, fence));

  /// Lifecycle-only final write, joined to optional guarded local-domain clear.
  int detachInTransaction(
    DomainTransaction records,
    SyncFence fence, {
    bool discardPreviousDetached = false,
    bool clearAllSync = false,
    String? nextOrigin,
  }) {
    _guard(records, fence);
    final roots = _roots(records);
    final active = roots.where((root) => root.role != 'detached').toList();
    if (nextOrigin != null) {
      SyncIdentity(
        serviceOrigin: nextOrigin,
        accountId: fence.identity.accountId,
        deviceId: fence.identity.deviceId,
        vaultId: fence.identity.vaultId,
      );
    }
    if (!clearAllSync &&
        !discardPreviousDetached &&
        active.isNotEmpty &&
        roots.any((root) => root.role == 'detached'))
      throw _conflict;
    for (final root in roots) {
      if (clearAllSync || root.role == 'detached' && discardPreviousDetached) {
        records.deleteSyncRoot(root.rootId);
      } else if (root.role != 'detached') {
        if (!fence.identity.owns(root)) throw _storage;
        root.role = 'detached';
        records.putSyncRoot(root);
      }
    }
    final state = records.syncState;
    state
      ..identityGeneration = _next(state.identityGeneration)
      ..enabled = false
      ..accountId = null
      ..deviceId = null
      ..vaultId = null
      ..baseRootId = null
      ..baseRevision = 0
      ..pendingRootId = null
      ..pendingCommitId = null
      ..pendingUploadRetiring = false
      ..pendingUploadId = null
      ..pendingUploadDeviceId = null
      ..candidateRootId = null
      ..conflictLocalId = null
      ..conflictRemoteId = null
      ..ackGeneration = 0
      ..lastSuccessUtc = null
      ..errorCode = null;
    if (nextOrigin != null) state.serviceOrigin = nextOrigin;
    if (clearAllSync) state.syncGeneration = 0;
    records.putSyncSecrets(SyncSecretRecord());
    records.putSyncState(state);
    _gcCursor = null;
    return state.identityGeneration;
  }

  Future<void> discardDetached({required int expectedGeneration}) => _write(
    (records) => discardDetachedInTransaction(
      records,
      expectedGeneration: expectedGeneration,
    ),
  );

  void discardDetachedInTransaction(
    DomainTransaction records, {
    required int expectedGeneration,
  }) {
    if (records.syncState.identityGeneration != expectedGeneration)
      throw _conflict;
    for (final root in _roots(
      records,
    ).where((root) => root.role == 'detached')) {
      records.deleteSyncRoot(root.rootId);
    }
    _gcCursor = null;
  }

  Future<int> collectGarbage({
    required int expectedGeneration,
    int limit = 100,
    bool Function()? isCurrent,
  }) async => (await collectGarbagePass(
    expectedGeneration: expectedGeneration,
    limit: limit,
    isCurrent: isCurrent,
  )).removed;

  Future<SyncGarbagePass> collectGarbagePass({
    required int expectedGeneration,
    int limit = 100,
    bool restart = false,
    bool Function()? isCurrent,
  }) => _write((records) {
    _continuation(isCurrent);
    if (limit < 1 || limit > 1000) throw _invalid;
    if (records.syncState.identityGeneration != expectedGeneration)
      throw _conflict;
    final pinned = <String>{};
    pinned.addAll(_preparation?._pins ?? const <String>{});
    for (final root in _roots(records)) {
      final identity = SyncIdentity(
        serviceOrigin: root.serviceOrigin,
        accountId: root.accountId,
        deviceId: root.accountId,
        vaultId: root.vaultId,
      );
      pinned.addAll(root.objectHashes.map(identity.objectKey));
    }
    if (restart) _gcCursor = null;
    final keys = records.syncObjectKeys(afterKey: _gcCursor, limit: limit);
    var removed = 0;
    for (final key in keys) {
      if (!pinned.contains(key)) {
        records.deleteSyncObject(key);
        removed++;
      }
    }
    _gcCursor = keys.isEmpty ? null : keys.last;
    return SyncGarbagePass(keys.length, removed, keys.length < limit);
  });
}

int _utcNow() => DateTime.now().toUtc().millisecondsSinceEpoch;

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

bool _sameRoot(SyncRootRecord left, SyncRootRecord right) =>
    left.rootId == right.rootId &&
    left.serviceOrigin == right.serviceOrigin &&
    left.accountId == right.accountId &&
    left.vaultId == right.vaultId &&
    left.snapshotId == right.snapshotId &&
    left.remoteRevision == right.remoteRevision &&
    left.sourceGeneration == right.sourceGeneration &&
    left.role == right.role &&
    _bytesEqual(left.manifestCiphertext, right.manifestCiphertext) &&
    left.objectHashes.join(',') == right.objectHashes.join(',') &&
    _bytesEqual(left.objectLengths, right.objectLengths);

bool _sameRootContent(SyncRootRecord left, SyncRootRecord right) =>
    left.serviceOrigin == right.serviceOrigin &&
    left.accountId == right.accountId &&
    left.vaultId == right.vaultId &&
    left.snapshotId == right.snapshotId &&
    left.remoteRevision == right.remoteRevision &&
    _bytesEqual(left.manifestCiphertext, right.manifestCiphertext) &&
    left.objectHashes.join(',') == right.objectHashes.join(',') &&
    _bytesEqual(left.objectLengths, right.objectLengths);

void _continuation(bool Function()? isCurrent) {
  if (isCurrent != null && !isCurrent()) throw _conflict;
}
