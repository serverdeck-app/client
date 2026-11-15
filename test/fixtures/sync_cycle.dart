import 'dart:typed_data';

import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/sync/sync_crypto.dart';
import 'package:serverdeck/sync/sync_cycle.dart';
import 'package:serverdeck/sync/sync_merge.dart';
import 'package:serverdeck/sync/sync_models.dart';
import 'package:serverdeck/sync/sync_wire.dart';

import 'sync_publication.dart';

class CycleHarness extends PublicationHarness {
  late SyncCycleOwner cycle;
  late SyncMergeController cycleMerge;
  bool keyReady = true;
  @override
  Future<void> setup() async {
    await super.setup();
    cycleMerge = SyncMergeController(
      repository: apply.feature.repository,
      access: server,
      keyReady: () => keyReady && apply.access.current && server.current,
    );
    cycle = SyncCycleOwner(
      repository: apply.repository,
      access: server,
      withCrypto: cryptoScope,
      transfer: apply.transfer,
      merge: cycleMerge,
      apply: apply.apply,
      newId: apply.feature.newId,
      utcNow: apply.feature.clock.now,
      schedule: apply.feature.clock.schedule,
      monotonicMicros: () => apply.feature.clock.elapsed.inMicroseconds,
    );
  }

  T cryptoScope<T>(T Function(SyncCrypto) action) {
    if (!keyReady || !apply.access.current || !server.current)
      throw const OperationFailure(FailureCode.authRequired);
    return action(apply.crypto);
  }

  int get timerCount =>
      apply.feature.clock.timers.where((t) => !t.cancelled).length;
  Duration? get nextDelay {
    final timers = apply.feature.clock.timers
        .where((t) => !t.cancelled)
        .toList();
    if (timers.isEmpty) return null;
    timers.sort((a, b) => a.at.compareTo(b.at));
    return timers.first.at - apply.feature.clock.elapsed;
  }

  Future<SyncManifest> cloud(
    List<PortableSyncContent> values, {
    int? revision,
  }) async {
    final entries = <SyncRootEntry>[];
    for (final content in values) {
      try {
        final body = apply.crypto.encryptContent(content);
        final hash = syncSha256(body);
        server.blobs[hash] = Uint8List.fromList(body);
        entries.add(
          SyncRootEntry(
            kind: content.kind,
            id: content.id,
            sha256: hash,
            bytes: body.length,
          ),
        );
        body.fillRange(0, body.length, 0);
      } finally {
        content.dispose();
      }
    }
    entries.sort((a, b) => '${a.kind}/${a.id}'.compareTo('${b.kind}/${b.id}'));
    final root = apply.crypto.encryptRoot(
      snapshotId: apply.feature.newId(),
      revision: revision ?? server.head.revision + 1,
      entries: entries,
    );
    final manifest = SyncManifest.parse({
      'version': 1,
      'content_version': 1,
      'vault_id': apply.fence.identity.vaultId,
      'snapshot_id': root.root.snapshotId,
      'revision': root.root.revision,
      'root': {'sha256': root.ref.sha256, 'bytes': root.ref.bytes},
      'objects': root.objects
          .map((r) => {'sha256': r.sha256, 'bytes': r.bytes})
          .toList(),
    });
    server.blobs[root.ref.sha256] = Uint8List.fromList(root.envelope);
    root.envelope.fillRange(0, root.envelope.length, 0);
    server.head = SyncHead.parse({
      'vault_id': manifest.vaultId,
      'revision': manifest.revision,
      'manifest': manifest.toJson(),
    }, vaultId: manifest.vaultId);
    return manifest;
  }

  void freshCloud() {
    final domain = apply.feature.repository.state;
    domain.syncRoots.clear();
    domain.syncState
      ..baseRootId = null
      ..baseRevision = 0
      ..pendingRootId = null
      ..pendingCommitId = null
      ..pendingUploadId = null
      ..pendingUploadDeviceId = null
      ..pendingUploadRetiring = false
      ..candidateRootId = null
      ..ackGeneration = 0;
    server.leases.clear();
    server.blobs.clear();
    server.head = SyncHead.parse({
      'vault_id': apply.fence.identity.vaultId,
      'revision': 0,
      'manifest': null,
    }, vaultId: apply.fence.identity.vaultId);
  }

  @override
  Future<void> dispose() async {
    await cycle.dispose();
    cycleMerge.dispose();
    await super.dispose();
  }
}
