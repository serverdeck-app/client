import 'dart:async';
import 'dart:typed_data';

import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/storage/records.dart';
import 'package:serverdeck/sync/sync_cycle_ports.dart';
import 'package:serverdeck/sync/sync_merge.dart';
import 'package:serverdeck/sync/sync_models.dart';
import 'package:serverdeck/sync/sync_publication.dart';
import 'package:serverdeck/sync/sync_recovery.dart';
import 'package:serverdeck/sync/sync_transport.dart';
import 'package:serverdeck/sync/sync_wire.dart';

import 'feature_harness.dart';
import 'sync_apply.dart';

class PublicationLease {
  PublicationLease(this.deviceId, this.manifest, this.missing);
  final String deviceId;
  final SyncManifest manifest;
  final List<String> missing;
  bool expired = false;
  SyncCommitReceipt? receipt;
}

/// Isolated protocol model for native owner units, not the backend service.
class PublicationServer implements SyncCycleAccess {
  PublicationServer(this.h, this.context, this.head);
  final PublicationHarness h;
  final SyncVaultContext context;
  SyncHead head;
  bool current = true;
  int publications = 0, loseResponses = 0;
  final leases = <String, PublicationLease>{};
  final blobs = <String, Uint8List>{};
  final calls = <String>[];
  final commits = <(String, String)>[];
  final cancels = <String>[];
  Future<void> Function(String upload)? beforeCancel, afterCancel;
  final sent = <(String, String, Uint8List)>[];
  final received = <Uint8List>[];
  Future<void> Function(String upload, String hash)? afterUpload;
  Future<void> Function(String upload)? beforeCommit;
  SyncCommitReceipt? substituteReceipt;
  Future<void> Function()? beforeHead;
  Future<void> Function(SyncManifest manifest, SyncBlobRef ref)? beforeRead;
  final downloads = <String>[];
  final downloadedBuffers = <Uint8List>[];

  SyncRemoteFailure error(String code) => SyncRemoteFailure.parse(
    switch (code) {
      'not_found' => 404,
      'upload_expired' => 410,
      'invalid_blob' => 400,
      _ => 409,
    },
    {
      'error': code,
      'request_id': featureId(900001),
      if (code == 'revision_conflict')
        'vault_id': context.fence.identity.vaultId,
      if (code == 'revision_conflict') 'revision': head.revision,
    },
    null,
  );
  @override
  void guardVaultContext(SyncVaultContext value) {
    h.apply.access.guardVaultContext(value);
    if (!current) throw const SyncTransportCancelled();
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
  void check(SyncVaultContext value, SyncCancellation cancel) {
    guardVaultContext(value);
    if (cancel.cancelled) throw const SyncTransportCancelled();
  }

  @override
  Future<SyncHead> readVaultHead(
    SyncVaultContext value,
    SyncCancellation cancel,
  ) async {
    check(value, cancel);
    calls.add('head');
    await beforeHead?.call();
    check(value, cancel);
    return head;
  }

  @override
  Future<Uint8List> readVaultRoot(
    SyncVaultContext value,
    SyncManifest manifest,
    SyncCancellation cancel,
  ) => _read(value, manifest, manifest.root, cancel);
  @override
  Future<Uint8List> readVaultBlob(
    SyncVaultContext value,
    SyncManifest manifest,
    SyncBlobRef ref,
    SyncCancellation cancel,
  ) => _read(value, manifest, ref, cancel);
  Future<Uint8List> _read(
    SyncVaultContext value,
    SyncManifest manifest,
    SyncBlobRef ref,
    SyncCancellation cancel,
  ) async {
    check(value, cancel);
    await beforeRead?.call(manifest, ref);
    check(value, cancel);
    if (head.revision != manifest.revision) throw error('revision_changed');
    final body = blobs[ref.sha256];
    if (body == null) throw error('not_found');
    downloads.add(ref.sha256);
    final bytes = Uint8List.fromList(body);
    downloadedBuffers.add(bytes);
    return bytes;
  }

  List<SyncBlobRef> refs(SyncManifest manifest) => [
    manifest.root,
    ...manifest.objects,
  ];
  @override
  Future<SyncUploadDeclaration> declareVaultUpload(
    SyncVaultContext value,
    String upload,
    SyncManifest manifest,
    SyncCancellation cancel,
  ) async {
    check(value, cancel);
    calls.add('declare:$upload');
    if (h.apply.feature.repository.state.syncState.pendingUploadId != upload)
      throw StateError('lease not persisted before HTTP');
    var row = leases[upload];
    if (row != null) {
      if (row.deviceId != value.fence.identity.deviceId)
        throw error('not_found');
      if (row.expired) throw error('upload_expired');
      if (!sameSyncManifest(row.manifest, manifest))
        throw error('idempotency_conflict');
    } else {
      if (leases.values.any(
        (row) =>
            row.deviceId == value.fence.identity.deviceId &&
            !row.expired &&
            row.receipt == null,
      ))
        throw error('idempotency_conflict');
      if (head.revision != manifest.revision - 1)
        throw error('revision_conflict');
      row = PublicationLease(
        value.fence.identity.deviceId,
        manifest,
        refs(manifest)
            .where((ref) => !blobs.containsKey(ref.sha256))
            .map((ref) => ref.sha256)
            .toList(),
      );
      leases[upload] = row;
    }
    return SyncUploadDeclaration.parse(
      {'upload_id': upload, 'expires_at': 1000000, 'missing': row.missing},
      upload,
      manifest,
    );
  }

  @override
  Future<void> uploadVaultBlob(
    SyncVaultContext value,
    String upload,
    SyncBlobRef ref,
    Uint8List bytes,
    SyncCancellation cancel,
  ) async {
    check(value, cancel);
    calls.add('put:$upload');
    final row = leases[upload];
    if (row == null || row.deviceId != value.fence.identity.deviceId)
      throw error('not_found');
    if (row.expired) throw error('upload_expired');
    if (!refs(row.manifest)
            .any((r) => r.sha256 == ref.sha256 && r.bytes == bytes.length) ||
        syncSha256(bytes) != ref.sha256)
      throw error('invalid_blob');
    received.add(bytes);
    sent.add((upload, ref.sha256, Uint8List.fromList(bytes)));
    blobs[ref.sha256] = Uint8List.fromList(bytes);
    await afterUpload?.call(upload, ref.sha256);
  }

  @override
  Future<SyncCommitReceipt> commitVaultUpload(
    SyncVaultContext value,
    String upload,
    String commit,
    SyncManifest manifest,
    SyncCancellation cancel,
  ) async {
    check(value, cancel);
    calls.add('commit:$upload');
    commits.add((upload, commit));
    await beforeCommit?.call(upload);
    final row = leases[upload];
    if (row == null || row.deviceId != value.fence.identity.deviceId)
      throw error('not_found');
    if (row.receipt != null) return substituteReceipt ?? row.receipt!;
    if (row.expired) throw error('upload_expired');
    if (head.revision != manifest.revision - 1)
      throw error('revision_conflict');
    if (refs(manifest).any((ref) => blobs[ref.sha256]?.length != ref.bytes))
      throw error('invalid_blob');
    final receipt = SyncCommitReceipt.parse(
      {
        'vault_id': manifest.vaultId,
        'snapshot_id': manifest.snapshotId,
        'revision': manifest.revision,
        'commit_id': commit,
      },
      commit,
      manifest,
    );
    row.receipt = receipt;
    publications++;
    head = SyncHead.parse({
      'vault_id': manifest.vaultId,
      'revision': manifest.revision,
      'manifest': manifest.toJson(),
    }, vaultId: manifest.vaultId);
    if (loseResponses > 0) {
      loseResponses--;
      throw const OperationFailure(FailureCode.networkError, retryable: true);
    }
    return substituteReceipt ?? receipt;
  }

  @override
  Future<void> cancelVaultUpload(
    SyncVaultContext value,
    String upload,
    SyncCancellation cancel,
  ) async {
    check(value, cancel);
    cancels.add(upload);
    await beforeCancel?.call(upload);
    final row = leases[upload];
    if (row == null || row.deviceId != value.fence.identity.deviceId)
      throw error('not_found');
    if (row.receipt != null) throw error('idempotency_conflict');
    if (row.expired) throw error('upload_expired');
    row.expired = true;
    await afterCancel?.call(upload);
  }

  void advanceHead() {
    final old = head.manifest!;
    final json = old.toJson()
      ..['revision'] = old.revision + 1
      ..['snapshot_id'] = featureId(990001)
      ..['root'] = {'sha256': 'a' * 64, 'bytes': 28};
    head = SyncHead.parse({
      'vault_id': old.vaultId,
      'revision': old.revision + 1,
      'manifest': json,
    }, vaultId: old.vaultId);
  }
}

class PublicationHarness {
  final apply = ApplyHarness();
  late final PublicationServer server;
  late final SyncPendingPublisher publisher;
  late String localId;
  Future<void> setup() async {
    await apply.setup();
    localId = await apply.feature.create();
    final remote = await apply.remote([]);
    await apply.run(remote, choice: SyncMergeChoice.local);
    server = PublicationServer(this, apply.access.context, apply.access.head);
    final base = apply.feature.repository.state.syncRoots[remote.rootId]!;
    server.blobs[remote.manifest.root.sha256] = Uint8List.fromList(
      base.manifestCiphertext,
    );
    publisher = makePublisher();
  }

  SyncPendingPublisher makePublisher() => SyncPendingPublisher(
    repository: apply.repository,
    access: server,
    newId: apply.feature.newId,
    utcNow: apply.feature.clock.now,
  );
  SyncRootRecord get pending => apply
      .feature
      .repository
      .state
      .syncRoots[apply.feature.repository.state.syncState.pendingRootId]!;
  Future<SyncPublicationResult> publish({
    SyncPendingPublisher? owner,
    SyncCancellation? cancel,
  }) => (owner ?? publisher).publish(
    apply.access.context,
    apply.crypto,
    cancel: cancel ?? SyncCancellation(),
    isCurrent: () => apply.access.current && server.current,
  );
  Future<void> dispose() => apply.dispose();
}
