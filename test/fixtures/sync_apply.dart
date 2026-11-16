import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:serverdeck/connections/profile_batch.dart';
import 'package:serverdeck/domain/actor.dart';
import 'package:serverdeck/domain/app_operations.dart';
import 'package:serverdeck/runtime/platform_ports.dart';
import 'package:serverdeck/runtime/owned_work.dart';
import 'package:serverdeck/storage/records.dart';
import 'package:serverdeck/sync/sync_apply.dart';
import 'package:serverdeck/sync/sync_atomic_apply.dart';
import 'package:serverdeck/sync/sync_crypto.dart';
import 'package:serverdeck/sync/sync_cycle_ports.dart';
import 'package:serverdeck/sync/sync_publication.dart';
import 'package:serverdeck/sync/sync_retirement.dart';
import 'package:serverdeck/sync/sync_merge.dart';
import 'package:serverdeck/sync/sync_models.dart';
import 'package:serverdeck/sync/sync_recovery.dart';
import 'package:serverdeck/sync/sync_repository.dart';
import 'package:serverdeck/sync/sync_transport.dart';
import 'package:serverdeck/sync/sync_wire.dart';

import 'feature_harness.dart';
import '../sync/credential_transfer_test.dart' show Inspector;

// Unit-only native protection: reversible synthetic bytes, no OS key or Isar.
class ApplySecrets implements PlatformSecretPort {
  bool fail = false;
  Completer<void>? hold;
  int protects = 0;
  final inputs = <Uint8List>[], outputs = <Uint8List>[];
  @override
  Future<Uint8List> protect(Uint8List bytes, String purpose) async {
    protects++;
    inputs.add(bytes);
    await hold?.future;
    if (fail) throw StateError('synthetic protection refusal');
    final result = Uint8List.fromList(bytes);
    outputs.add(result);
    return result;
  }

  @override
  Future<Uint8List> unprotect(Uint8List bytes, String purpose) async =>
      Uint8List.fromList(bytes);
}

class ApplyAuthority implements SyncCycleAccess {
  ApplyAuthority(this.h, this.context);
  @override
  Future<void> cancelVaultUpload(
    SyncVaultContext context,
    String upload,
    SyncCancellation cancel,
  ) async {
    guardVaultContext(context);
    if (cancel.cancelled) throw const SyncTransportCancelled();
    // This synthetic apply-only fixture has no live upload service row.
  }

  @override
  Future<SyncCommitReceipt> commitVaultUpload(
    SyncVaultContext context,
    String upload,
    String commit,
    SyncManifest manifest,
    SyncCancellation cancel,
  ) => throw UnimplementedError();
  @override
  Future<SyncUploadDeclaration> declareVaultUpload(
    SyncVaultContext context,
    String upload,
    SyncManifest manifest,
    SyncCancellation cancel,
  ) => throw UnimplementedError();
  @override
  Future<void> uploadVaultBlob(
    SyncVaultContext context,
    String upload,
    SyncBlobRef ref,
    Uint8List bytes,
    SyncCancellation cancel,
  ) => throw UnimplementedError();
  @override
  Future<Uint8List> readVaultBlob(
    SyncVaultContext context,
    SyncManifest manifest,
    SyncBlobRef ref,
    SyncCancellation cancel,
  ) => throw UnimplementedError();
  final ApplyHarness h;
  final SyncVaultContext context;
  bool current = true;
  late SyncHead head;
  @override
  void guardVaultContext(SyncVaultContext value) {
    if (!current ||
        value.epoch != context.epoch ||
        !value.fence.matches(h.feature.repository.state.syncState))
      throw const SyncTransportCancelled();
  }

  @override
  bool isVaultContextCurrent(SyncVaultContext value) {
    try {
      guardVaultContext(value);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<SyncVaultContext> vaultContext() async => context;
  @override
  Future<SyncHead> readVaultHead(
    SyncVaultContext value,
    SyncCancellation cancel,
  ) async {
    guardVaultContext(value);
    if (cancel.cancelled) throw const SyncTransportCancelled();
    return head;
  }

  @override
  Future<Uint8List> readVaultRoot(
    SyncVaultContext value,
    SyncManifest manifest,
    SyncCancellation cancel,
  ) => throw UnimplementedError();
}

class ApplyBatchPort implements ProfileBatchPort {
  ApplyBatchPort(this.real);
  final ProfileBatchPort real;
  Future<void> Function()? afterClose;
  int reservations = 0;
  Map<String, int?> lastIds = {};
  @override
  Future<ProfileMutationBatch> reserveProfileBatch(
    OwnerActor actor, {
    required Map<String, int?> expectedProfiles,
    required Set<String> targetEndpoints,
    required void Function() guard,
  }) async {
    reservations++;
    lastIds = Map.of(expectedProfiles);
    return _Batch(
      await real.reserveProfileBatch(
        actor,
        expectedProfiles: expectedProfiles,
        targetEndpoints: targetEndpoints,
        guard: guard,
      ),
      this,
    );
  }
}

class _Batch implements ProfileMutationBatch {
  _Batch(this.real, this.port);
  final ProfileMutationBatch real;
  final ApplyBatchPort port;
  Future<void>? closing;
  @override
  Future<void> close() => closing ??= () async {
    await real.close();
    await port.afterClose?.call();
  }();
  @override
  void check(CommandContext context) => real.check(context);
  @override
  void release() => real.release();
}

class ApplyRemote {
  ApplyRemote(this.snapshot, this.manifest, this.rootId);
  final SyncMergeSnapshot snapshot;
  final SyncManifest manifest;
  final String rootId;
}

class ApplyHarness {
  final feature = FeatureHarness(), secrets = ApplySecrets();
  late final SyncRepository repository;
  late final SyncFence fence;
  late final ApplyAuthority access;
  late final SyncCrypto crypto;
  late final SyncCredentialTransfer transfer;
  late final SyncMergeController merge;
  late final SyncApply apply;
  late final SyncUploadRetirement retirement;
  late final ApplyBatchPort batches;
  int free = 100 * 1024 * 1024 * 1024;
  Future<int> Function()? probe;
  Future<void> setup() async {
    repository = SyncRepository(
      feature.repository,
      availableStorageBytes: () async => probe == null ? free : await probe!(),
      utcNow: feature.clock.now,
    );
    fence = await repository.bind(
      expectedGeneration: 1,
      identity: SyncIdentity(
        serviceOrigin: 'https://sync.example.test',
        accountId: featureId(8001),
        deviceId: featureId(8002),
        vaultId: featureId(8003),
      ),
      secrets: SyncSecretRecord()
        ..protectedAccess = [1]
        ..protectedRefresh = [2]
        ..protectedStatusProof = [3],
    );
    access = ApplyAuthority(this, SyncVaultContext(fence, 1));
    retirement = SyncUploadRetirement(
      repository: repository,
      access: access,
      publisher: SyncPendingPublisher(
        repository: repository,
        access: access,
        newId: feature.newId,
        utcNow: feature.clock.now,
      ),
      utcNow: feature.clock.now,
    );
    access.head = SyncHead.parse({
      'vault_id': fence.identity.vaultId,
      'revision': 0,
      'manifest': null,
    }, vaultId: fence.identity.vaultId);
    crypto = SyncCrypto(identity: fence.identity, rootKey: Uint8List(32));
    transfer = SyncCredentialTransfer(
      repository: feature.repository,
      secrets: secrets,
      inspector: Inspector(),
      access: access,
    );
    merge = SyncMergeController(
      repository: feature.repository,
      access: access,
      keyReady: () => access.current,
    );
    batches = ApplyBatchPort(feature.connections);
    apply = SyncApply(
      repository: repository,
      transfer: transfer,
      gate: feature.gate,
      actor: feature.actors.owner,
      connections: batches,
      newId: feature.newId,
      utcNow: feature.clock.now,
    );
  }

  SyncCredentialProof? proof(PortableSyncContent content) =>
      content is PortableSyncProfile
      ? content.credentialKind == 'password'
            ? SyncCredentialProof.password
            : SyncCredentialProof.validatedPrivateKey
      : null;
  Future<SyncMergeSnapshot> local() async {
    final source = transfer.capture(access.context),
        builder = SyncMergeSnapshotBuilder.local(
          transfer.capture(access.context),
        );
    for (final profile in feature.repository.state.profiles.values.toList()) {
      await transfer.withExportedProfile(source, profile.profileId, (
        content,
        proof,
      ) {
        builder.add(content, proof: proof);
      }, cancellation: WorkCancellation());
    }
    for (final card in feature.repository.state.softwareCards.values) {
      final content = cardContent(card);
      builder.add(content);
      content.dispose();
    }
    return builder.finish();
  }

  Future<ApplyRemote> remote(
    List<PortableSyncContent> values, {
    int revision = 1,
    bool pending = false,
    bool complete = true,
  }) async {
    final entries = <SyncRootEntry>[], bodies = <String, Uint8List>{};
    for (final content in values) {
      final bytes = crypto.encryptContent(content);
      final actualHash = syncSha256(bytes);
      entries.add(
        SyncRootEntry(
          kind: content.kind,
          id: content.id,
          sha256: actualHash,
          bytes: bytes.length,
        ),
      );
      bodies[actualHash] = bytes;
    }
    final root = crypto.encryptRoot(
      snapshotId: feature.newId(),
      revision: revision,
      entries: entries,
    );
    final rootId = feature.newId(), commit = pending ? feature.newId() : null;
    await repository.stageRoot(
      fence,
      rootId: rootId,
      snapshotId: root.root.snapshotId,
      revision: revision,
      sourceGeneration: feature.repository.state.syncState.syncGeneration,
      rootCiphertext: root.envelope,
      objects: root.objects,
      pending: pending,
      commitId: commit,
    );
    if (complete) {
      for (final entry in bodies.entries) {
        await repository.putObject(fence, entry.key, entry.value);
      }
    }
    final manifest = SyncManifest.parse({
      'version': 1,
      'content_version': 1,
      'vault_id': fence.identity.vaultId,
      'snapshot_id': root.root.snapshotId,
      'revision': revision,
      'objects': root.objects
          .map((ref) => {'sha256': ref.sha256, 'bytes': ref.bytes})
          .toList(),
      'root': {'sha256': root.ref.sha256, 'bytes': root.ref.bytes},
    });
    final builder = SyncMergeSnapshotBuilder.remote(
      access.context,
      root.root,
      manifest,
    );
    final refs = {
      for (final entry in root.root.entries) '${entry.kind}/${entry.id}': entry,
    };
    for (final content in values) {
      builder.add(
        content,
        encryptedRef: refs['${content.kind}/${content.id}'],
        proof: proof(content),
      );
      content.dispose();
    }
    for (final bytes in bodies.values) {
      bytes.fillRange(0, bytes.length, 0);
    }
    root.envelope.fillRange(0, root.envelope.length, 0);
    if (!pending)
      access.head = SyncHead.parse({
        'vault_id': fence.identity.vaultId,
        'revision': revision,
        'manifest': manifest.toJson(),
      }, vaultId: fence.identity.vaultId);
    return ApplyRemote(builder.finish(), manifest, rootId);
  }

  Future<void> run(
    ApplyRemote remote, {
    SyncMergeChoice choice = SyncMergeChoice.automatic,
    SyncMergeSnapshot? base,
  }) async {
    final preview = await merge.propose(
      local: await local(),
      remote: remote.snapshot,
      base: base,
    );
    await merge.confirm(preview, choice, (authority) async {
      final retired = await retirement.retire(authority, crypto);
      if (retired.rebuild) throw const SyncTransportCancelled();
      await apply.apply(
        authority,
        crypto,
        remoteRootId: remote.rootId,
        retiredUpload: retired.closed,
      );
    });
  }

  PortableSyncProfile stored(
    String id, {
    String? name,
    String? host,
    String? password,
    int? updated,
  }) {
    final p = feature.repository.state.profiles[id]!,
        c = feature.repository.state.credentials[p.credentialId]!;
    return PortableSyncProfile.parse({
      'kind': 'profile',
      'version': 1,
      'profile': {
        'profileId': id,
        'displayName': name ?? p.displayName,
        'originalHost': host ?? p.originalHost,
        'port': p.port,
        'username': p.username,
        'createdAt': p.createdAt,
        'updatedAt': updated ?? p.updatedAt,
      },
      'credential': {
        'credentialId': c.credentialId,
        'kind': c.kind,
        'originalBase64': base64.encode(
          password == null ? c.protectedBytes : utf8.encode(password),
        ),
        'publicKeyType': c.publicKeyType,
        'publicKeyBits': c.publicKeyBits,
        'publicKeyBase64': c.publicKeyBytes == null
            ? null
            : base64.encode(c.publicKeyBytes!),
      },
    });
  }

  Future<FeatureSession> connected(String id) async {
    final endpoint = feature
            .repository
            .state
            .endpoints[feature.repository.state.profiles[id]!.endpointId]!,
        key = featureKey();
    endpoint
      ..acceptedKeyBytes = [...key.blob]
      ..acceptedType = key.keyType
      ..acceptedFingerprint = key.fingerprint;
    final session = await feature.connect(id);
    await session.authenticate();
    await featureTurns();
    return session;
  }

  Future<void> dispose() async {
    if (secrets.hold != null && !secrets.hold!.isCompleted)
      secrets.hold!.complete();
    for (final session in feature.sessions) {
      session.failClose = false;
      if (session.holdClose != null && !session.holdClose!.isCompleted)
        session.holdClose!.complete();
    }
    await apply.dispose();
    merge.dispose();
    crypto.dispose();
    await feature.dispose();
    feature.repository.disposeNotifications();
  }
}

PortableSyncCard cardContent(SoftwareCardRecord c) => PortableSyncCard.parse({
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
