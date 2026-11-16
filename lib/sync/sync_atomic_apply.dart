import 'dart:async';
import 'dart:typed_data';

import '../connections/profile_batch.dart';
import '../domain/actor.dart';
import '../domain/app_operations.dart';
import '../domain/models.dart';
import '../profiles/endpoint_references.dart';
import '../runtime/capability.dart';
import '../runtime/owned_work.dart';
import '../software/software_models.dart';
import '../storage/domain_repository.dart';
import '../storage/records.dart';
import 'sync_apply.dart';
import 'sync_crypto.dart';
import 'sync_json.dart';
import 'sync_merge.dart';
import 'sync_models.dart';
import 'sync_repository.dart';
import 'sync_retirement.dart';
import 'sync_transport.dart' show SyncTransportCancelled;

const _stale = OperationFailure(FailureCode.conflict);
const _invalid = OperationFailure(FailureCode.invalidArgument);
const _storage = OperationFailure(
  FailureCode.storageUnavailable,
  retryable: true,
);

final class _ProfileApply {
  _ProfileApply(
    this.after,
    this.entry,
    this.changed,
    this.credentialChanged,
    this.connectionChanged,
  );
  final Profile after;
  final SyncRootEntry entry;
  final bool changed, credentialChanged, connectionChanged;
}

final class _CardApply {
  _CardApply(this.entry, this.changed);
  final SyncRootEntry entry;
  final bool changed;
}

/// Root-only complete candidate preparation and one guarded domain/root write.
/// Publication and UI are separate; no public CRUD, grants or onboarding replay.
final class SyncApply implements RuntimeCapability {
  SyncApply({
    required this.repository,
    required this.transfer,
    required this.gate,
    required this.actor,
    required this.connections,
    required this.newId,
    required this.utcNow,
  });
  final SyncRepository repository;
  final SyncCredentialTransfer transfer;
  final DomainCommandGate gate;
  final OwnerActor actor;
  final ProfileBatchPort connections;
  final String Function() newId;
  final int Function() utcNow;
  bool _stopped = false;
  WorkCancellation? _work;
  Future<void>? _pending;
  SyncRetiredUpload? _retiredUpload;
  DomainRepository get _domain => repository.domain;
  @override
  String get id => 'sync-apply';

  String _id() {
    final value = newId();
    if (!isCanonicalUuid(value)) throw _storage;
    return value;
  }

  void _guard(SyncMergeAuthorization authority, WorkCancellation work) {
    if (_stopped) throw const OperationFailure(FailureCode.shuttingDown);
    work.check();
    authority.check();
    if (_domain.read((r) => r.syncState.pendingRootId != null)) {
      final retired = _retiredUpload;
      if (retired == null) throw _stale;
      retired.check(authority);
    }
  }

  Future<void> apply(
    SyncMergeAuthorization authority,
    SyncCrypto crypto, {
    required String? remoteRootId,
    SyncRetiredUpload? retiredUpload,
  }) {
    if (_stopped)
      return Future.error(const OperationFailure(FailureCode.shuttingDown));
    if (_pending != null)
      return Future.error(
        const OperationFailure(FailureCode.resourceExhausted, retryable: true),
      );
    _retiredUpload = retiredUpload;
    final work = _work = WorkCancellation();
    final future = _apply(authority, crypto, remoteRootId, work);
    _pending = future;
    future.then(
      (_) {
        if (identical(_pending, future)) {
          _pending = null;
          _work = null;
          _retiredUpload = null;
        }
      },
      onError: (Object _, StackTrace __) {
        if (identical(_pending, future)) {
          _pending = null;
          _work = null;
          _retiredUpload = null;
        }
      },
    );
    return future;
  }

  PortableSyncRoot? _remote(
    SyncMergeAuthorization authority,
    SyncCrypto crypto,
    String? rootId,
  ) {
    final manifest = authority.remoteManifest;
    if (manifest == null) {
      if (rootId != null) throw _stale;
      return null;
    }
    if (rootId == null) throw _stale;
    final stored = _domain.read((r) {
      final state = r.syncState, root = r.syncRoot(rootId);
      if (root == null ||
          rootId != state.baseRootId && rootId != state.candidateRootId ||
          !authority.source.context.fence.identity.owns(root) ||
          root.snapshotId != manifest.snapshotId ||
          root.remoteRevision != manifest.revision ||
          root.manifestLength != manifest.root.bytes ||
          root.objectHashes.length != manifest.objects.length)
        throw _stale;
      if (root.objectLengths.length != manifest.objects.length ||
          rootId == state.baseRootId && root.role != 'base' ||
          rootId == state.candidateRootId && root.role != 'candidate')
        throw _stale;
      for (var i = 0; i < manifest.objects.length; i++) {
        if (root.objectHashes[i] != manifest.objects[i].sha256 ||
            root.objectLengths[i] != manifest.objects[i].bytes)
          throw _stale;
      }
      return root;
    });
    return crypto.decryptRoot(
      envelope: Uint8List.fromList(stored.manifestCiphertext),
      root: manifest.root,
      objects: manifest.objects,
      snapshotId: manifest.snapshotId,
      revision: manifest.revision,
    );
  }

  (PortableSyncContent, SyncObjectRecord) _content(
    SyncMergeAuthorization authority,
    SyncCrypto crypto,
    SyncRootEntry entry,
  ) {
    final cached = repository.readObject(
      authority.source.context.fence,
      entry.sha256,
    );
    return (
      crypto.decryptContent(
        envelope: Uint8List.fromList(cached.cipherBytes),
        expected: entry,
      ),
      cached,
    );
  }

  void _validateCachedRoot(
    SyncMergeAuthorization authority,
    SyncCrypto crypto,
    PortableSyncRoot root,
  ) {
    final index = SyncContentIndex();
    for (final entry in root.entries) {
      final (content, _) = _content(authority, crypto, entry);
      try {
        index.add(content, expected: entry);
      } finally {
        content.dispose();
      }
    }
    index.finish(root);
  }

  Future<void> _apply(
    SyncMergeAuthorization authority,
    SyncCrypto crypto,
    String? remoteRootId,
    WorkCancellation work,
  ) async {
    SyncPreparation? scope;
    SyncPendingIntent? intent;
    SyncEncryptedRoot? encryptedRoot;
    ProfileMutationBatch? batch;
    final stop = authority.cancellation.listen(work.cancel);
    try {
      _guard(authority, work);
      await gate.prepare(
        actor,
        (context) => context.read(() => _guard(authority, work)),
      );
      _guard(authority, work);
      final identity = authority.source.context.fence.identity,
          actual = crypto.identity;
      if (identity.serviceOrigin != actual.serviceOrigin ||
          identity.accountId != actual.accountId ||
          identity.deviceId != actual.deviceId ||
          identity.vaultId != actual.vaultId)
        throw _stale;
      final before = _domain.read((r) => r.profiles());
      if (before.length > 1000)
        throw const OperationFailure(FailureCode.resourceExhausted);
      final oldProfiles = {
        for (final profile in before) profile.profileId: profile,
      };
      if (oldProfiles.length != before.length) throw _storage;
      final oldCards = <String>{};
      var domainBytes = 0;
      for (final profile in before) {
        final credential = _domain.read(
          (r) => r.credential(profile.credentialId),
        );
        if (credential == null ||
            credential.profileId != profile.profileId ||
            credential.kind != profile.authKind ||
            credential.protectedBytes.isEmpty ||
            credential.protectedBytes.length > syncMaxRootBytes)
          throw _storage;
        domainBytes +=
            credential.protectedBytes.length +
            (credential.publicKeyBytes?.length ?? 0) +
            8192;
        for (var offset = 0; ; offset++) {
          final page = _domain.read(
            (r) => r.softwareCards(profile.profileId, offset: offset, limit: 1),
          );
          if (page.isEmpty) break;
          if (offset >= 1000 ||
              oldCards.length >= 10000 ||
              !oldCards.add(page.single.softwareId))
            throw _storage;
          final content = _portableCard(page.single);
          try {
            domainBytes += 2 * _size(content.toJson()) + 8192;
          } finally {
            content.dispose();
          }
        }
      }
      _guard(authority, work);
      scope = repository.beginPreparation(
        authority.source.context.fence,
        expectedDataRevision: authority.source.dataRevision,
        expectedSyncGeneration: authority.source.syncGeneration,
        isCurrent: () =>
            !_stopped && !work.isCancelled && authority.isCurrent(),
      );
      final remote = _remote(authority, crypto, remoteRootId);
      final remoteEntries = {
        for (final entry in remote?.entries ?? <SyncRootEntry>[])
          '${entry.kind}/${entry.id}': entry,
      };
      final proofs = <String, SyncCredentialProof>{};
      if (remote != null) {
        final index = SyncContentIndex();
        for (final entry in remote.entries) {
          _guard(authority, work);
          final (content, cached) = _content(authority, crypto, entry);
          try {
            index.add(content, expected: entry);
            if (content is PortableSyncProfile) {
              final prepared = await transfer.prepareImported(
                authority.source,
                content,
                cancellation: work,
              );
              try {
                _guard(authority, work);
                proofs[content.id] = prepared.proof;
                await repository.prepareObject(
                  scope,
                  entry.sha256,
                  Uint8List.fromList(cached.cipherBytes),
                  protectedCredential: prepared.protectedBytes,
                  credentialId: prepared.credentialId,
                );
                _guard(authority, work);
              } finally {
                prepared.dispose();
              }
            }
          } finally {
            content.dispose();
          }
        }
        index.finish(remote);
      }

      final profiles = <String, _ProfileApply>{},
          cards = <String, _CardApply>{};
      final selectedEntries = <SyncRootEntry>[];
      final index = SyncContentIndex();
      for (final selection in authority.target.records) {
        _guard(authority, work);
        final available = remoteEntries['${selection.kind}/${selection.id}'];
        PortableSyncContent? content;
        SyncRootEntry? entry;
        try {
          if (available != null) {
            final (received, _) = _content(authority, crypto, available);
            if (selection.source == SyncMergeSource.server &&
                (selection.cipherRef?.sha256 != available.sha256 ||
                    selection.cipherRef?.bytes != available.bytes)) {
              received.dispose();
              throw _stale;
            }
            if (selection.matchesContent(received)) {
              content = received;
              entry = available;
            } else {
              received.dispose();
            }
          }
          if (selection.source == SyncMergeSource.server && content == null)
            throw _stale;
          if (content == null) {
            if (selection.kind == 'profile') {
              final result = await transfer.withExportedProfile(
                authority.source,
                selection.id,
                (local, proof) {
                  if (!selection.matchesContent(local) ||
                      proof != selection.proof)
                    throw _stale;
                  final bytes = crypto.encryptContent(local);
                  final entry = SyncRootEntry(
                    kind: local.kind,
                    id: local.id,
                    sha256: syncSha256(bytes),
                    bytes: bytes.length,
                  );
                  index.add(local, expected: entry);
                  final old = oldProfiles[local.id];
                  if (old == null) throw _stale;
                  profiles[local.id] = _ProfileApply(
                    old,
                    entry,
                    false,
                    false,
                    false,
                  );
                  return (entry, bytes);
                },
                cancellation: work,
              );
              _guard(authority, work);
              entry = result.$1;
              try {
                await repository.prepareObject(scope, entry.sha256, result.$2);
              } finally {
                result.$2.fillRange(0, result.$2.length, 0);
              }
              _guard(authority, work);
            } else {
              final record = _domain.read((r) => r.softwareCard(selection.id));
              if (record == null) throw _stale;
              content = _portableCard(record);
              if (!selection.matchesContent(content)) throw _stale;
              final bytes = crypto.encryptContent(content);
              entry = SyncRootEntry(
                kind: content.kind,
                id: content.id,
                sha256: syncSha256(bytes),
                bytes: bytes.length,
              );
              try {
                await repository.prepareObject(scope, entry.sha256, bytes);
              } finally {
                bytes.fillRange(0, bytes.length, 0);
              }
              _guard(authority, work);
            }
          }
          if (content is PortableSyncProfile) {
            if (proofs[content.id] != selection.proof) throw _stale;
            index.add(content, expected: entry!);
            final old = oldProfiles[content.id];
            final desired = _profile(content, old);
            final public = content.copyPublicKey();
            domainBytes +=
                2 * _size(content.profile) + (public?.length ?? 0) + 8192;
            final desiredSecret = _credentialHash(content);
            // Dispose the remote credential plaintext before unprotecting local
            // original bytes for comparison. Only its private digest survives.
            content.dispose();
            content = null;
            var changed = true, secretChanged = true;
            if (old != null) {
              final compared = await transfer.withExportedProfile(
                authority.source,
                old.profileId,
                (local, _) => (
                  selection.matchesContent(local),
                  _credentialHash(local) == desiredSecret,
                ),
                cancellation: work,
              );
              _guard(authority, work);
              changed = !compared.$1;
              secretChanged = !compared.$2;
            }
            final connectionChanged =
                old == null ||
                secretChanged ||
                desired.endpointId != old.endpointId ||
                desired.username != old.username;
            if (old != null && secretChanged)
              _secretRevisions[old.profileId] = nextRevision(
                _secretRevisions[old.profileId]!,
              );
            desired.profileRevision = old == null
                ? 1
                : changed
                ? nextRevision(old.profileRevision)
                : old.profileRevision;
            desired.connectionRevision = old == null
                ? 1
                : connectionChanged
                ? nextRevision(old.connectionRevision)
                : old.connectionRevision;
            desired.syncAutoBlocked = connectionChanged || old.syncAutoBlocked;
            profiles[desired.profileId] = _ProfileApply(
              desired,
              entry,
              changed,
              secretChanged,
              connectionChanged,
            );
          } else if (content is PortableSyncCard) {
            index.add(content, expected: entry!);
            final old = _domain.read((r) => r.softwareCard(content!.id));
            var changed = true;
            if (old != null) {
              final local = _portableCard(old);
              try {
                changed = !selection.matchesContent(local);
              } finally {
                local.dispose();
              }
            }
            final record = _card(content, old, changed);
            final owner = profiles[record.profileId]?.after;
            if (owner == null) throw _invalid;
            SoftwareCardView(
              record,
              currentTarget: owner.endpointId == record.endpointId,
            );
            domainBytes += 2 * _size(content.toJson()) + 8192;
            cards[record.softwareId] = _CardApply(entry, changed);
          }
          selectedEntries.add(entry!);
        } finally {
          content?.dispose();
        }
      }
      final after = profiles.values.map((p) => p.after).toList();
      final domainChanged =
          profiles.values.any((p) => p.changed) ||
          before.any((p) => !profiles.containsKey(p.profileId)) ||
          cards.values.any((p) => p.changed) ||
          oldCards.any((id) => !cards.containsKey(id));
      if (domainChanged != authority.target.needsLocalApply) throw _stale;
      if (domainChanged) {
        _domain.read((r) {
          nextRevision(r.settings.dataRevision);
          nextRevision(r.settings.profilesListRevision);
        });
      }
      _domain.read(
        (r) =>
            EndpointReferences.validateBatch(r, before: before, after: after),
      );
      for (final profile in profiles.values.where((p) => p.changed)) {
        final cached = repository.readObject(
          authority.source.context.fence,
          profile.entry.sha256,
        );
        domainBytes += (cached.locallyPreparedCredential?.length ?? 0) + 8192;
      }
      if (authority.target.needsPublication) {
        encryptedRoot = crypto.encryptRoot(
          snapshotId: _id(),
          revision: (authority.remoteManifest?.revision ?? 0) + 1,
          entries: selectedEntries,
        );
        index.finish(encryptedRoot.root);
        intent = SyncPendingIntent(
          rootId: _id(),
          snapshotId: encryptedRoot.root.snapshotId,
          commitId: _id(),
          revision: encryptedRoot.root.revision,
          ciphertext: encryptedRoot.envelope,
          objects: encryptedRoot.objects,
        );
      } else {
        if (remote == null) throw _invalid;
        index.finish(remote);
      }
      final targetRoot = encryptedRoot?.root ?? remote!;
      final affected = <String, int?>{}, targets = <String>{};
      for (final old in before) {
        final next = profiles[old.profileId];
        if (next == null || next.connectionChanged)
          affected[old.profileId] = old.profileRevision;
      }
      for (final next in profiles.values.where((p) => p.connectionChanged)) {
        affected[next.after.profileId] =
            oldProfiles[next.after.profileId]?.profileRevision;
        targets.add(next.after.endpointId);
      }
      _guard(authority, work);
      batch = await connections.reserveProfileBatch(
        actor,
        expectedProfiles: affected,
        targetEndpoints: targets,
        guard: () => _guard(authority, work),
      );
      _guard(authority, work);
      await batch.close();
      _guard(authority, work);
      final transition = await repository.prepareTransition(
        scope,
        remoteRootId: remoteRootId,
        pending: intent,
        consumePending: true,
        acknowledgeGeneration: authority.target.needsPublication
            ? _domain.read((r) => r.syncState.ackGeneration)
            : authority.source.syncGeneration,
        successUtc: utcNow(),
        domainWriteBytes: domainBytes,
      );
      _guard(authority, work);
      final readyBatch = batch;
      await gate.prepare(
        actor,
        (context) => _domain.write(
          (r) => context.linearize(() {
            _guard(authority, work);
            readyBatch.check(context);
            _retiredUpload?.check(authority, proof: true);
            final freshRemote = _remote(authority, crypto, remoteRootId);
            if (freshRemote != null)
              _validateCachedRoot(authority, crypto, freshRemote);
            _validateCachedRoot(authority, crypto, targetRoot);
            // Validate actual destination counters/target budgets before any write.
            for (final plan in cards.values) {
              final (content, _) = _content(authority, crypto, plan.entry);
              try {
                final record = _card(
                  content as PortableSyncCard,
                  r.softwareCard(content.id),
                  plan.changed,
                );
                SoftwareCardView(
                  record,
                  currentTarget:
                      profiles[record.profileId]!.after.endpointId ==
                      record.endpointId,
                );
              } finally {
                content.dispose();
              }
            }
            transition.commit(r);
            EndpointReferences.reconcile(r, before: before, after: after);
            for (final old in before) {
              final next = profiles[old.profileId];
              if (next == null || next.credentialChanged)
                r.deleteCredential(old.credentialId);
              if (next == null) r.deleteProfile(old.profileId);
            }
            for (final plan in profiles.values) {
              if (plan.credentialChanged) {
                final (content, cached) = _content(
                  authority,
                  crypto,
                  plan.entry,
                );
                try {
                  final profile = content as PortableSyncProfile;
                  if (cached.preparedCredentialId != profile.credentialId ||
                      cached.preparedAgainstGeneration !=
                          authority.source.dataRevision ||
                      cached.locallyPreparedCredential == null ||
                      cached.locallyPreparedCredential!.isEmpty ||
                      cached.locallyPreparedCredential!.length >
                          syncMaxRootBytes)
                    throw _storage;
                  final old = oldProfiles[profile.id];
                  // Capture old counters before deleting/replacing credentials.
                  final revision = old == null
                      ? 1
                      : _secretRevisions[old.profileId]!;
                  final public = profile.copyPublicKey();
                  r.putCredential(
                    Credential()
                      ..credentialId = profile.credentialId
                      ..profileId = profile.id
                      ..kind = profile.credentialKind
                      ..protectedBytes = [...cached.locallyPreparedCredential!]
                      ..publicKeyType = profile.publicKeyType
                      ..publicKeyBits = profile.publicKeyBits
                      ..publicKeyBytes = public == null ? null : [...public]
                      ..secretRevision = revision,
                  );
                } finally {
                  content.dispose();
                }
              }
              if (plan.changed) {
                if (!plan.connectionChanged)
                  plan.after.syncAutoBlocked =
                      r.profile(plan.after.profileId)?.syncAutoBlocked ??
                      plan.after.syncAutoBlocked;
                r.putProfile(plan.after);
              }
            }
            for (final old in oldCards.where((id) => !cards.containsKey(id))) {
              r.deleteSoftwareCard(old);
            }
            for (final plan in cards.values.where((p) => p.changed)) {
              final (content, _) = _content(authority, crypto, plan.entry);
              try {
                final card = content as PortableSyncCard;
                // Profile cascade may have removed a moved card: revisions were
                // captured before the cascade, never copied from network counters.
                final record = _card(card, null, true)
                  ..revision = _cardRevisions[card.id]!;
                if (_cardIds[card.id] != null) record.id = _cardIds[card.id]!;
                r.putSoftwareCard(record);
              } finally {
                content.dispose();
              }
            }
            if (domainChanged) {
              r.putSettings(
                r.settings
                  ..dataRevision = nextRevision(r.settings.dataRevision)
                  ..profilesListRevision = nextRevision(
                    r.settings.profilesListRevision,
                  ),
              );
            }
            return MutationValue(
              entityId: identity.vaultId,
              revision: r.settings.dataRevision,
            );
          }),
        ),
      );
    } on OperationFailure {
      rethrow;
    } on WorkCancelled {
      rethrow;
    } on SyncTransportCancelled {
      rethrow;
    } catch (_) {
      throw _storage;
    } finally {
      batch?.release();
      scope?.dispose();
      intent?.dispose();
      encryptedRoot?.envelope.fillRange(0, encryptedRoot.envelope.length, 0);
      _secretRevisions.clear();
      _cardRevisions.clear();
      _cardIds.clear();
      stop();
    }
  }

  // Per-flight scalar counters only; no credential/card plaintext snapshot.
  final _secretRevisions = <String, int>{}, _cardRevisions = <String, int>{};
  final _cardIds = <String, int>{};
  Profile _profile(PortableSyncProfile content, Profile? old) {
    final fields = content.fields;
    final value = Profile()
      ..profileId = content.id
      ..displayName = fields.displayName
      ..originalHost = fields.originalHost
      ..normalizedHost = fields.normalizedHost
      ..port = fields.port
      ..username = fields.username
      ..endpointId = fields.endpointId
      ..authKind = content.credentialKind
      ..credentialId = content.credentialId
      ..createdAt = content.profile['createdAt']! as int
      ..updatedAt = content.profile['updatedAt']! as int;
    if (old != null) {
      value.id = old.id;
      final credential = _domain.read((r) => r.credential(old.credentialId));
      if (credential == null) throw _storage;
      _secretRevisions[old.profileId] = credential.secretRevision;
    }
    return value;
  }

  SoftwareCardRecord _card(
    PortableSyncCard content,
    SoftwareCardRecord? old,
    bool changed,
  ) {
    final c = content.card;
    final revision = old == null
        ? 1
        : changed
        ? nextRevision(old.revision)
        : old.revision;
    _cardRevisions.putIfAbsent(content.id, () => revision);
    if (old != null) _cardIds.putIfAbsent(content.id, () => old.id);
    return SoftwareCardRecord()
      ..softwareId = content.id
      ..profileId = content.profileId
      ..endpointId = c['endpointId']! as String
      ..host = c['host']! as String
      ..port = c['port']! as int
      ..username = c['username']! as String
      ..name = c['name']! as String
      ..version = (c['version'] as String?)
      ..service = (c['service'] as String?)
      ..dataPaths = List<String>.from(c['dataPaths']! as List)
      ..configPaths = List<String>.from(c['configPaths']! as List)
      ..updateInstructions = c['updateInstructions'] as String?
      ..createdAt = c['createdAt']! as int
      ..updatedAt = c['updatedAt']! as int
      ..revision = revision;
  }

  static PortableSyncCard _portableCard(SoftwareCardRecord c) =>
      PortableSyncCard.parse({
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
  static String _credentialHash(PortableSyncProfile p) {
    final bytes = canonicalSyncJson(p.toJson()['credential']);
    try {
      return syncSha256(bytes);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  static int _size(Object? value) {
    final bytes = canonicalSyncJson(value);
    try {
      return bytes.length;
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  @override
  Future<void> stopAdmission() async {
    _stopped = true;
    _work?.cancel();
  }

  @override
  Future<void> cancelPending() async {
    _work?.cancel();
  }

  @override
  Future<void> closeSessions() async {}
  @override
  Future<void> drain() async {
    try {
      await _pending;
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    await stopAdmission();
    await drain();
  }
}
