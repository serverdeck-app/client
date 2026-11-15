import 'dart:async';
import 'dart:typed_data';

import '../domain/models.dart';
import '../storage/records.dart';
import 'sync_crypto.dart';
import 'sync_cycle_ports.dart';
import 'sync_models.dart';
import 'sync_recovery.dart';
import 'sync_repository.dart';
import 'sync_transport.dart';
import 'sync_wire.dart';

const _publicationStorage = OperationFailure(
  FailureCode.storageUnavailable,
  retryable: true,
);

/// Native opaque projection only; caller separately checks namespace and GCM.
SyncManifest syncManifestForRoot(SyncRootRecord root) {
  if (root.manifestCiphertext.length < 28 ||
      root.manifestCiphertext.length > syncMaxRootBytes ||
      root.manifestLength != root.manifestCiphertext.length ||
      root.objectHashes.length > 11000 ||
      root.objectHashes.length != root.objectLengths.length)
    throw _publicationStorage;
  return SyncManifest.parse({
    'version': 1,
    'content_version': 1,
    'vault_id': root.vaultId,
    'snapshot_id': root.snapshotId,
    'revision': root.remoteRevision,
    'root': {
      'sha256': syncSha256(root.manifestCiphertext),
      'bytes': root.manifestLength,
    },
    'objects': [
      for (var i = 0; i < root.objectHashes.length; i++)
        {'sha256': root.objectHashes[i], 'bytes': root.objectLengths[i]},
    ],
  });
}

bool sameSyncManifest(SyncManifest a, SyncManifest b) {
  if (a.vaultId != b.vaultId ||
      a.snapshotId != b.snapshotId ||
      a.revision != b.revision ||
      a.root.sha256 != b.root.sha256 ||
      a.root.bytes != b.root.bytes ||
      a.objects.length != b.objects.length)
    return false;
  for (var i = 0; i < a.objects.length; i++) {
    if (a.objects[i].sha256 != b.objects[i].sha256 ||
        a.objects[i].bytes != b.objects[i].bytes)
      return false;
  }
  return true;
}

enum SyncPublicationDisposition { none, acknowledged, reconcile }

final class SyncPublicationResult {
  const SyncPublicationResult._(this.disposition, [this.head]);
  final SyncPublicationDisposition disposition;
  final SyncHead? head;
}

final class _Publication {
  _Publication(
    this.root,
    this.manifest,
    this.commitId,
    this.uploadId,
    this.uploadDeviceId,
  );
  final SyncRootRecord root;
  final SyncManifest manifest;
  final String commitId;
  String? uploadId, uploadDeviceId;
}

/// Publishes only an already approved, durable immutable pending intent. It
/// never exports current domain, chooses a merge, or mutates local records.
final class SyncPendingPublisher {
  SyncPendingPublisher({
    required this.repository,
    required this.access,
    required this.newId,
    required this.utcNow,
  });
  final SyncRepository repository;
  final SyncCycleAccess access;
  final String Function() newId;
  final int Function() utcNow;
  bool _busy = false, _retiring = false;
  SyncCancellation? _flightCancel;
  Future<SyncPublicationResult>? _flight;

  /// The sole cycle owner holds this exclusion across retirement I/O. Durable
  /// retirement then keeps admission closed after this transient lock releases.
  Future<T> withPublicationStopped<T>(Future<T> Function() action) async {
    if (_retiring) throw const OperationFailure(FailureCode.conflict);
    _retiring = true;
    try {
      _flightCancel?.cancel();
      final active = _flight;
      if (active != null) {
        try {
          await active;
        } catch (_) {
          /* Original caller owns the failure. */
        }
      }
      return await action();
    } finally {
      _retiring = false;
    }
  }

  Future<SyncPublicationResult> publish(
    SyncVaultContext context,
    SyncCrypto crypto, {
    required SyncCancellation cancel,
    required bool Function() isCurrent,
  }) {
    if (_retiring || _flight != null)
      return Future.error(
        const OperationFailure(FailureCode.resourceExhausted, retryable: true),
      );
    final child = _flightCancel = SyncCancellation();
    final unlink = cancel.listen(child.cancel);
    final future = _flight = _publish(
      context,
      crypto,
      cancel: child,
      isCurrent: isCurrent,
    );
    void done() {
      unlink();
      if (identical(_flight, future)) {
        _flight = null;
        _flightCancel = null;
      }
    }

    future.then((_) => done(), onError: (Object _, StackTrace __) => done());
    return future;
  }

  void _guard(
    SyncVaultContext context,
    SyncCancellation cancel,
    bool Function() isCurrent, [
    _Publication? pending,
  ]) {
    if (cancel.cancelled || !isCurrent()) throw const SyncTransportCancelled();
    access.guardVaultContext(context);
    if (pending != null &&
        !repository.domain.read((r) {
          final state = r.syncState;
          return !state.pendingUploadRetiring &&
              context.fence.matches(state) &&
              state.pendingRootId == pending.root.rootId &&
              state.pendingCommitId == pending.commitId &&
              state.pendingUploadId == pending.uploadId &&
              state.pendingUploadDeviceId == pending.uploadDeviceId;
        }))
      throw const OperationFailure(FailureCode.conflict);
  }

  bool _current(
    SyncVaultContext context,
    SyncCancellation cancel,
    bool Function() isCurrent,
    _Publication pending, {
    bool proof = false,
  }) {
    try {
      _guard(context, cancel, isCurrent, pending);
      if (proof) {
        final root = repository.domain.read(
          (r) => r.syncRoot(pending.root.rootId),
        );
        return root != null &&
            root.role == 'pending' &&
            root.sourceGeneration == pending.root.sourceGeneration &&
            context.fence.identity.owns(root) &&
            sameSyncManifest(syncManifestForRoot(root), pending.manifest);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<SyncPublicationResult> _publish(
    SyncVaultContext context,
    SyncCrypto crypto, {
    required SyncCancellation cancel,
    required bool Function() isCurrent,
  }) async {
    _guard(context, cancel, isCurrent);
    if (_busy)
      throw const OperationFailure(
        FailureCode.resourceExhausted,
        retryable: true,
      );
    _busy = true;
    try {
      final pending = repository.domain.read((r) {
        final state = r.syncState, id = state.pendingRootId;
        if (id == null) return null;
        if (state.pendingUploadRetiring)
          throw const OperationFailure(FailureCode.conflict);
        final root = r.syncRoot(id), commit = state.pendingCommitId;
        if (root == null ||
            commit == null ||
            !isCanonicalUuid(commit) ||
            root.role != 'pending' ||
            !context.fence.identity.owns(root) ||
            root.sourceGeneration < state.ackGeneration ||
            root.sourceGeneration > state.syncGeneration ||
            root.remoteRevision != state.baseRevision + 1 ||
            state.pendingUploadId != null &&
                !isCanonicalUuid(state.pendingUploadId!) ||
            state.pendingUploadDeviceId != null &&
                !isCanonicalUuid(state.pendingUploadDeviceId!))
          throw _publicationStorage;
        return _Publication(
          root,
          syncManifestForRoot(root),
          commit,
          state.pendingUploadId,
          state.pendingUploadDeviceId,
        );
      });
      if (pending == null)
        return const SyncPublicationResult._(SyncPublicationDisposition.none);
      final expected = context.fence.identity, actual = crypto.identity;
      if (expected.serviceOrigin != actual.serviceOrigin ||
          expected.accountId != actual.accountId ||
          expected.vaultId != actual.vaultId ||
          expected.deviceId != actual.deviceId)
        throw syncInvalidWire;
      final root = crypto.decryptRoot(
        envelope: Uint8List.fromList(pending.root.manifestCiphertext),
        root: pending.manifest.root,
        objects: pending.manifest.objects,
        snapshotId: pending.manifest.snapshotId,
        revision: pending.manifest.revision,
      );
      final index = SyncContentIndex();
      for (final entry in root.entries) {
        _guard(context, cancel, isCurrent, pending);
        final row = repository.readObject(context.fence, entry.sha256);
        final content = crypto.decryptContent(
          envelope: Uint8List.fromList(row.cipherBytes),
          expected: entry,
        );
        try {
          index.add(content, expected: entry);
        } finally {
          content.dispose();
        }
        // Bounded event-loop yield while validating a large persisted intent.
        await Future<void>.delayed(Duration.zero);
      }
      index.finish(root);
      _guard(context, cancel, isCurrent, pending);

      Future<SyncHead> head() async {
        final value = await access.readVaultHead(context, cancel);
        _guard(context, cancel, isCurrent, pending);
        if (value.vaultId != expected.vaultId ||
            value.revision <
                repository.domain.read((r) => r.syncState.baseRevision))
          throw syncInvalidWire;
        return value;
      }

      bool isPublished(SyncHead value) =>
          value.manifest != null &&
          sameSyncManifest(value.manifest!, pending.manifest);
      bool isBase(SyncHead value) {
        if (value.revision != pending.manifest.revision - 1) return false;
        return repository.domain.read((r) {
          if (value.revision == 0)
            return r.syncState.baseRevision == 0 &&
                r.syncState.baseRootId == null;
          final id = r.syncState.baseRootId,
              base = id == null ? null : r.syncRoot(id);
          if (base == null ||
              base.role != 'base' ||
              !expected.owns(base) ||
              value.manifest == null)
            return false;
          return sameSyncManifest(syncManifestForRoot(base), value.manifest!);
        });
      }

      Future<SyncPublicationResult> ack() async {
        _guard(context, cancel, isCurrent, pending);
        await repository.acknowledge(
          context.fence,
          rootId: pending.root.rootId,
          commitId: pending.commitId,
          revision: pending.manifest.revision,
          successUtc: utcNow(),
          isCurrent: () =>
              _current(context, cancel, isCurrent, pending, proof: true),
        );
        // ACK legitimately clears pending; only native frame remains applicable.
        _guard(context, cancel, isCurrent);
        return const SyncPublicationResult._(
          SyncPublicationDisposition.acknowledged,
        );
      }

      Future<void> rotate() async {
        final id = pending.uploadId == null ? pending.root.rootId : newId();
        if (!isCanonicalUuid(id) || id == pending.uploadId)
          throw syncInvalidWire;
        await repository.replacePendingUpload(
          context.fence,
          rootId: pending.root.rootId,
          commitId: pending.commitId,
          expectedUploadId: pending.uploadId,
          expectedUploadDeviceId: pending.uploadDeviceId,
          uploadId: id,
          isCurrent: () =>
              _current(context, cancel, isCurrent, pending, proof: true),
        );
        pending.uploadId = id;
        pending.uploadDeviceId = expected.deviceId;
        _guard(context, cancel, isCurrent, pending);
      }

      Future<SyncPublicationResult?> reconcileHead({
        required bool renew,
      }) async {
        final value = await head();
        if (isPublished(value)) return await ack();
        if (!isBase(value))
          return SyncPublicationResult._(
            SyncPublicationDisposition.reconcile,
            value,
          );
        if (renew) await rotate();
        return null;
      }

      if (pending.uploadId == null ||
          pending.uploadDeviceId != expected.deviceId) {
        final result = await reconcileHead(renew: true);
        if (result != null) return result;
      }
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          // A committed receipt is authoritative even after the head advanced.
          // Probe it before declaring/reconciling; retries use both durable IDs.
          try {
            final receipt = await access.commitVaultUpload(
              context,
              pending.uploadId!,
              pending.commitId,
              pending.manifest,
              cancel,
            );
            _guard(context, cancel, isCurrent, pending);
            _receipt(receipt, pending);
            return await ack();
          } on SyncRemoteFailure catch (error) {
            _guard(context, cancel, isCurrent, pending);
            // Existing uncommitted uploads can be incomplete after interruption.
            // Their original declaration/missing list is replayed idempotently.
            if (error.code != 'not_found' && error.code != 'invalid_blob')
              rethrow;
          }
          final changed = await reconcileHead(renew: false);
          if (changed != null) return changed;
          final declaration = await access.declareVaultUpload(
            context,
            pending.uploadId!,
            pending.manifest,
            cancel,
          );
          _guard(context, cancel, isCurrent, pending);
          if (declaration.uploadId != pending.uploadId) throw syncInvalidWire;
          final refs = {
            pending.manifest.root.sha256: pending.manifest.root,
            for (final ref in pending.manifest.objects) ref.sha256: ref,
          };
          final seen = <String>{};
          for (final hash in declaration.missing) {
            final ref = refs[hash];
            if (ref == null || !seen.add(hash)) throw syncInvalidWire;
            final bytes = hash == pending.manifest.root.sha256
                ? Uint8List.fromList(pending.root.manifestCiphertext)
                : Uint8List.fromList(
                    repository.readObject(context.fence, hash).cipherBytes,
                  );
            try {
              _guard(context, cancel, isCurrent, pending);
              await access.uploadVaultBlob(
                context,
                pending.uploadId!,
                ref,
                bytes,
                cancel,
              );
              _guard(context, cancel, isCurrent, pending);
            } finally {
              bytes.fillRange(0, bytes.length, 0);
            }
          }
          final receipt = await access.commitVaultUpload(
            context,
            pending.uploadId!,
            pending.commitId,
            pending.manifest,
            cancel,
          );
          _guard(context, cancel, isCurrent, pending);
          _receipt(receipt, pending);
          return await ack();
        } on SyncRemoteFailure catch (error) {
          _guard(context, cancel, isCurrent, pending);
          if (error.code == 'revision_conflict') {
            final value = await head();
            if (isPublished(value)) return await ack();
            return SyncPublicationResult._(
              SyncPublicationDisposition.reconcile,
              value,
            );
          }
          if (error.code == 'upload_expired') {
            final result = await reconcileHead(renew: attempt == 0);
            if (result != null) return result;
            if (attempt == 0) continue;
          }
          rethrow;
        }
      }
      throw const OperationFailure(FailureCode.conflict);
    } finally {
      _busy = false;
    }
  }

  void _receipt(SyncCommitReceipt receipt, _Publication pending) {
    if (receipt.vaultId != pending.manifest.vaultId ||
        receipt.snapshotId != pending.manifest.snapshotId ||
        receipt.revision != pending.manifest.revision ||
        receipt.commitId != pending.commitId)
      throw syncInvalidWire;
  }
}
