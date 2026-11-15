import 'dart:typed_data';

import '../domain/models.dart';
import '../storage/records.dart';
import 'sync_crypto.dart';
import 'sync_cycle_ports.dart';
import 'sync_merge.dart';
import 'sync_models.dart';
import 'sync_publication.dart';
import 'sync_repository.dart';
import 'sync_transport.dart';
import 'sync_wire.dart';

const _staleRetirement = OperationFailure(FailureCode.conflict);

/// Ephemeral proof of closure, usable only by the same active merge callback.
/// The durable retiring bit alone never authorizes consuming pending.
final class SyncRetiredUpload {
  SyncRetiredUpload._(this._authority, this._current);
  final SyncMergeAuthorization _authority;
  final bool Function(bool proof) _current;
  void check(SyncMergeAuthorization authority, {bool proof = false}) {
    if (!identical(authority, _authority)) throw _staleRetirement;
    authority.check();
    if (!_current(proof)) throw _staleRetirement;
  }
}

final class SyncRetirementResult {
  const SyncRetirementResult._({this.closed, this.rebuild = false});
  final SyncRetiredUpload? closed;
  final bool rebuild;
}

final class _Retirement {
  _Retirement(this.root, this.manifest, this.commit, this.upload, this.device);
  final SyncRootRecord root;
  final SyncManifest manifest;
  final String commit;
  final String? upload, device;
}

/// Root-owned handoff from an approved replacement choice to atomic apply.
/// Normal publication/receipt recovery precedes proposing that choice. This
/// operation never commits an uncommitted old upload to discover its status.
final class SyncUploadRetirement {
  SyncUploadRetirement({
    required this.repository,
    required this.access,
    required this.publisher,
    required this.utcNow,
  });
  final SyncRepository repository;
  final SyncCycleAccess access;
  final SyncPendingPublisher publisher;
  final int Function() utcNow;

  Future<SyncRetirementResult> retire(
    SyncMergeAuthorization authority,
    SyncCrypto crypto,
  ) {
    authority.check();
    final before = repository.domain.read(
      (r) => (
        r.syncState.pendingRootId,
        r.syncState.pendingCommitId,
        r.syncState.baseRootId,
        r.syncState.baseRevision,
        r.syncState.ackGeneration,
      ),
    );
    return publisher.withPublicationStopped(() async {
      authority.check();
      final after = repository.domain.read(
        (r) => (
          r.syncState.pendingRootId,
          r.syncState.pendingCommitId,
          r.syncState.baseRootId,
          r.syncState.baseRevision,
          r.syncState.ackGeneration,
        ),
      );
      if (before != after) return const SyncRetirementResult._(rebuild: true);
      final context = authority.source.context;
      final cancel = authority.cancellation;
      void guard() {
        authority.check();
        access.guardVaultContext(context);
        if (cancel.cancelled) throw const SyncTransportCancelled();
      }

      guard();
      final intent = repository.domain.read((r) {
        final state = r.syncState;
        if (!context.fence.matches(state)) throw _staleRetirement;
        final id = state.pendingRootId;
        if (id == null) return null;
        final root = r.syncRoot(id), commit = state.pendingCommitId;
        if (root == null ||
            root.role != 'pending' ||
            !context.fence.identity.owns(root) ||
            commit == null ||
            !isCanonicalUuid(commit) ||
            root.sourceGeneration < state.ackGeneration ||
            root.sourceGeneration > state.syncGeneration ||
            root.remoteRevision != state.baseRevision + 1 ||
            state.pendingUploadId != null &&
                !isCanonicalUuid(state.pendingUploadId!) ||
            state.pendingUploadDeviceId != null &&
                !isCanonicalUuid(state.pendingUploadDeviceId!))
          throw _staleRetirement;
        return _Retirement(
          root,
          syncManifestForRoot(root),
          commit,
          state.pendingUploadId,
          state.pendingUploadDeviceId,
        );
      });
      if (intent == null) return const SyncRetirementResult._();

      bool current(bool proof, {bool retiring = true}) {
        try {
          guard();
          return repository.domain.read((r) {
            final state = r.syncState;
            if (!context.fence.matches(state) ||
                state.pendingRootId != intent.root.rootId ||
                state.pendingCommitId != intent.commit ||
                state.pendingUploadId != intent.upload ||
                state.pendingUploadDeviceId != intent.device ||
                retiring && !state.pendingUploadRetiring)
              return false;
            if (!proof) return true;
            final root = r.syncRoot(intent.root.rootId);
            return root != null &&
                root.role == 'pending' &&
                context.fence.identity.owns(root) &&
                root.sourceGeneration == intent.root.sourceGeneration &&
                sameSyncManifest(syncManifestForRoot(root), intent.manifest);
          });
        } catch (_) {
          return false;
        }
      }

      void check() {
        if (!current(false)) throw _staleRetirement;
      }

      await repository.markPendingRetiring(
        context.fence,
        rootId: intent.root.rootId,
        commitId: intent.commit,
        uploadId: intent.upload,
        uploadDeviceId: intent.device,
        isCurrent: () => current(true, retiring: false),
      );
      check();

      Future<SyncHead> head() async {
        final value = await access.readVaultHead(context, cancel);
        check();
        if (value.vaultId != context.fence.identity.vaultId ||
            value.revision <
                repository.domain.read((r) => r.syncState.baseRevision))
          throw syncInvalidWire;
        return value;
      }

      bool published(SyncHead head) =>
          head.manifest != null &&
          sameSyncManifest(head.manifest!, intent.manifest);
      Future<SyncRetirementResult> acknowledge() async {
        final expected = context.fence.identity, actual = crypto.identity;
        if (expected.serviceOrigin != actual.serviceOrigin ||
            expected.accountId != actual.accountId ||
            expected.deviceId != actual.deviceId ||
            expected.vaultId != actual.vaultId)
          throw syncInvalidWire;
        final root = crypto.decryptRoot(
          envelope: Uint8List.fromList(intent.root.manifestCiphertext),
          root: intent.manifest.root,
          objects: intent.manifest.objects,
          snapshotId: intent.manifest.snapshotId,
          revision: intent.manifest.revision,
        );
        final index = SyncContentIndex();
        for (final entry in root.entries) {
          check();
          final cached = repository.readObject(context.fence, entry.sha256);
          final content = crypto.decryptContent(
            envelope: Uint8List.fromList(cached.cipherBytes),
            expected: entry,
          );
          try {
            index.add(content, expected: entry);
          } finally {
            content.dispose();
          }
          await Future<void>.delayed(Duration.zero);
        }
        index.finish(root);
        check();
        await repository.acknowledge(
          context.fence,
          rootId: intent.root.rootId,
          commitId: intent.commit,
          revision: intent.manifest.revision,
          successUtc: utcNow(),
          isCurrent: () => current(true),
        );
        guard();
        return const SyncRetirementResult._(rebuild: true);
      }

      if (intent.upload != null &&
          intent.device == context.fence.identity.deviceId) {
        var closed = false;
        for (var attempt = 0; attempt < 2 && !closed; attempt++) {
          try {
            await access.cancelVaultUpload(context, intent.upload!, cancel);
            check();
            closed = true;
          } on SyncRemoteFailure catch (error) {
            check();
            if (error.code == 'not_found' || error.code == 'upload_expired') {
              closed = true;
            } else if (error.code == 'idempotency_conflict') {
              // DELETE has established that commit won; replay cannot now publish
              // an abandoned uncommitted intent.
              try {
                final receipt = await access.commitVaultUpload(
                  context,
                  intent.upload!,
                  intent.commit,
                  intent.manifest,
                  cancel,
                );
                check();
                if (receipt.commitId != intent.commit ||
                    receipt.vaultId != intent.manifest.vaultId ||
                    receipt.snapshotId != intent.manifest.snapshotId ||
                    receipt.revision != intent.manifest.revision)
                  throw syncInvalidWire;
                return await acknowledge();
              } on SyncRemoteFailure catch (receiptError) {
                check();
                if (receiptError.code != 'not_found' &&
                    receiptError.code != 'upload_expired')
                  rethrow;
                if (published(await head())) return await acknowledge();
                if (attempt == 1) rethrow;
                // Receipt may have been garbage-collected: retry the exact DELETE
                // to obtain positive absence/expiry, never infer it from head.
              }
            } else {
              rethrow;
            }
          }
        }
        if (!closed) throw _staleRetirement;
      }
      final fresh = await head();
      if (published(fresh)) return await acknowledge();
      final expected = authority.remoteManifest;
      if (expected == null
          ? fresh.revision != 0 || fresh.manifest != null
          : fresh.manifest == null ||
                !sameSyncManifest(expected, fresh.manifest!))
        throw _staleRetirement;
      if (!current(true)) throw _staleRetirement;
      return SyncRetirementResult._(
        closed: SyncRetiredUpload._(authority, (proof) => current(proof)),
      );
    });
  }
}
