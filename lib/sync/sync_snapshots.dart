import 'dart:typed_data';

import '../domain/models.dart';
import '../runtime/owned_work.dart';
import '../storage/records.dart';
import 'sync_apply.dart';
import 'sync_crypto.dart';
import 'sync_cycle_ports.dart';
import 'sync_merge.dart';
import 'sync_models.dart';
import 'sync_publication.dart';
import 'sync_recovery.dart';
import 'sync_repository.dart';
import 'sync_transport.dart';
import 'sync_wire.dart';

const _staleSnapshot = OperationFailure(FailureCode.conflict);
const _badSnapshot = OperationFailure(
  FailureCode.storageUnavailable,
  retryable: true,
);

final class _MissingBase implements Exception {}

final class SyncCycleSnapshots {
  const SyncCycleSnapshots(
    this.local,
    this.remote,
    this.base,
    this.remoteRootId,
  );
  final SyncMergeSnapshot local, remote;
  final SyncMergeSnapshot? base;
  final String? remoteRootId;
}

/// Streaming native indexes over one shared encrypted cache. No plaintext spool,
/// full plaintext vault or publication/merge permission is created here.
final class SyncSnapshotReader {
  SyncSnapshotReader({
    required this.repository,
    required this.transfer,
    required this.access,
    required this.newId,
  });
  final SyncRepository repository;
  final SyncCredentialTransfer transfer;
  final SyncCycleAccess access;
  final String Function() newId;

  Future<SyncCycleSnapshots> read(
    SyncVaultContext context,
    SyncCrypto crypto,
    SyncHead head, {
    required SyncCancellation cancel,
    required bool Function() isCurrent,
    Future<void> Function()? candidateChanged,
  }) async {
    void ownerGuard() {
      if (cancel.cancelled || !isCurrent())
        throw const SyncTransportCancelled();
      access.guardVaultContext(context);
    }

    ownerGuard();
    final source = transfer.capture(context);
    final work = WorkCancellation();
    final unlink = cancel.listen(work.cancel);
    void guard() {
      ownerGuard();
      if (!repository.domain.read(
        (r) =>
            r.settings.dataRevision == source.dataRevision &&
            r.syncState.syncGeneration == source.syncGeneration,
      ))
        throw _staleSnapshot;
    }

    bool current() {
      try {
        guard();
        return true;
      } catch (_) {
        return false;
      }
    }

    try {
      final expected = context.fence.identity, actual = crypto.identity;
      if (expected.serviceOrigin != actual.serviceOrigin ||
          expected.accountId != actual.accountId ||
          expected.deviceId != actual.deviceId ||
          expected.vaultId != actual.vaultId ||
          head.vaultId != expected.vaultId ||
          head.revision <
              repository.domain.read((r) => r.syncState.baseRevision))
        throw syncInvalidWire;
      final profiles = repository.domain.read((r) => r.profiles());
      final cardCount = repository.domain.read((r) => r.softwareCardCount());
      if (profiles.length > 1000 || cardCount > 10000) throw _badSnapshot;
      final localBuilder = SyncMergeSnapshotBuilder.local(source);
      var seenCards = 0;
      for (final profile in profiles) {
        guard();
        await transfer.withExportedProfile(
          source,
          profile.profileId,
          (value, proof) => localBuilder.add(value, proof: proof),
          cancellation: work,
        );
        guard();
        for (var offset = 0; ; offset++) {
          final page = repository.domain.read(
            (r) => r.softwareCards(profile.profileId, offset: offset, limit: 1),
          );
          if (page.isEmpty) break;
          if (offset >= 1000 || ++seenCards > 10000) throw _badSnapshot;
          final card = _card(page.single);
          try {
            localBuilder.add(card);
          } finally {
            card.dispose();
          }
          await Future<void>.delayed(Duration.zero);
          guard();
        }
      }
      if (cardCount != seenCards) throw _badSnapshot;
      guard();
      final local = localBuilder.finish();

      Future<SyncMergeSnapshot> index(
        SyncRootRecord stored,
        SyncManifest manifest, {
        required bool downloadMissing,
      }) async {
        guard();
        if (!expected.owns(stored) ||
            stored.remoteRevision != manifest.revision ||
            !sameSyncManifest(syncManifestForRoot(stored), manifest))
          throw _badSnapshot;
        final root = crypto.decryptRoot(
          envelope: Uint8List.fromList(stored.manifestCiphertext),
          root: manifest.root,
          objects: manifest.objects,
          snapshotId: manifest.snapshotId,
          revision: manifest.revision,
        );
        final builder = SyncMergeSnapshotBuilder.remote(
          context,
          root,
          manifest,
        );
        for (final entry in root.entries) {
          guard();
          Uint8List? body;
          SyncPreparedCredential? prepared;
          PortableSyncContent? content;
          var downloaded = false;
          try {
            try {
              body = Uint8List.fromList(
                repository.readObject(context.fence, entry.sha256).cipherBytes,
              );
            } on OperationFailure catch (error) {
              guard();
              if (error.code != FailureCode.conflict) rethrow;
              if (!downloadMissing) throw _MissingBase();
              body = await access.readVaultBlob(
                context,
                manifest,
                SyncBlobRef(entry.sha256, entry.bytes),
                cancel,
              );
              downloaded = true;
              guard();
            }
            content = crypto.decryptContent(
              envelope: Uint8List.fromList(body),
              expected: entry,
            );
            if (content is PortableSyncProfile) {
              prepared = await transfer.prepareImported(
                source,
                content,
                cancellation: work,
              );
              guard();
            }
            if (downloaded || prepared != null) {
              await repository.putObject(
                context.fence,
                entry.sha256,
                body,
                protectedCredential: prepared?.protectedBytes,
                credentialId: prepared?.credentialId,
                preparedDataRevision: prepared == null
                    ? null
                    : source.dataRevision,
                isCurrent: current,
              );
              guard();
            }
            builder.add(content, encryptedRef: entry, proof: prepared?.proof);
          } finally {
            content?.dispose();
            prepared?.dispose();
            body?.fillRange(0, body.length, 0);
          }
          await Future<void>.delayed(Duration.zero);
          guard();
        }
        return builder.finish();
      }

      final baseRecord = repository.domain.read((r) {
        final state = r.syncState;
        return state.baseRootId == null ? null : r.syncRoot(state.baseRootId!);
      });
      SyncMergeSnapshot? base;
      if (baseRecord != null) {
        if (baseRecord.role != 'base' ||
            baseRecord.remoteRevision !=
                repository.domain.read((r) => r.syncState.baseRevision))
          throw _badSnapshot;
        try {
          base = await index(
            baseRecord,
            syncManifestForRoot(baseRecord),
            downloadMissing: false,
          );
        } on _MissingBase {
          base = null;
        }
        guard();
      }
      final manifest = head.manifest;
      if (manifest == null) {
        guard();
        return SyncCycleSnapshots(
          local,
          SyncMergeSnapshotBuilder.emptyRemote(context).finish(),
          base,
          null,
        );
      }
      if (baseRecord != null &&
          head.revision == baseRecord.remoteRevision &&
          !sameSyncManifest(syncManifestForRoot(baseRecord), manifest))
        throw syncInvalidWire;
      if (base != null && sameSyncManifest(base.manifest!, manifest))
        return SyncCycleSnapshots(local, base, base, baseRecord!.rootId);
      var stored = repository.domain.read((r) {
        final state = r.syncState;
        for (final id in [state.baseRootId, state.candidateRootId]) {
          if (id == null) continue;
          final root = r.syncRoot(id);
          if (root != null &&
              expected.owns(root) &&
              (id == state.baseRootId
                  ? root.role == 'base'
                  : root.role == 'candidate') &&
              sameSyncManifest(syncManifestForRoot(root), manifest))
            return root;
        }
        return null;
      });
      if (stored == null) {
        final bytes = await access.readVaultRoot(context, manifest, cancel);
        try {
          guard();
          crypto.decryptRoot(
            envelope: Uint8List.fromList(bytes),
            root: manifest.root,
            objects: manifest.objects,
            snapshotId: manifest.snapshotId,
            revision: manifest.revision,
          );
          final id = newId();
          if (!isCanonicalUuid(id)) throw _badSnapshot;
          await repository.stageRoot(
            context.fence,
            rootId: id,
            snapshotId: manifest.snapshotId,
            revision: manifest.revision,
            sourceGeneration: source.syncGeneration,
            rootCiphertext: bytes,
            objects: manifest.objects,
            pending: false,
            isCurrent: current,
          );
          guard();
          await candidateChanged?.call();
          guard();
          stored = repository.domain.read((r) => r.syncRoot(id));
        } finally {
          bytes.fillRange(0, bytes.length, 0);
        }
      }
      if (stored == null) throw _badSnapshot;
      final remote = await index(stored, manifest, downloadMissing: true);
      guard();
      if (base == null && stored.rootId == baseRecord?.rootId) base = remote;
      return SyncCycleSnapshots(local, remote, base, stored.rootId);
    } finally {
      work.cancel();
      unlink();
    }
  }
}

PortableSyncCard _card(SoftwareCardRecord c) => PortableSyncCard.parse({
  'kind': 'software',
  'version': 2,
  'card': {
    'softwareId': c.softwareId,
    'profileId': c.profileId,
    'endpointId': c.endpointId,
    'host': c.host,
    'port': c.port,
    'username': c.username,
    'name': c.name,
    'version': c.version,
    'service': c.service,
    'dataPaths': c.dataPaths,
    'configPaths': c.configPaths,
    'updateInstructions': c.updateInstructions,
    'createdAt': c.createdAt,
    'updatedAt': c.updatedAt,
  },
});
