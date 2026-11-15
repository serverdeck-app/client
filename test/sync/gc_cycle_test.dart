import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/storage/records.dart';
import 'package:serverdeck/sync/sync_cycle.dart';
import 'package:serverdeck/sync/sync_models.dart';
import 'package:serverdeck/sync/sync_repository.dart';
import 'package:serverdeck/sync/sync_transport.dart';

import '../fixtures/feature_harness.dart';
import '../fixtures/sync_cycle.dart';
import '../fixtures/sync_merge.dart';

void main() {
  late CycleHarness h;
  setUp(() async {
    h = CycleHarness();
    await h.setup();
  });
  tearDown(() => h.dispose());

  test('full startup sweep frees orphan reservations before previously rejected candidate admission', () async {
    final domain = h.apply.feature.repository;
    await domain.write((r) {
      for (var i = 0; i < 6143; i++) {
        r.putSyncObject(
          SyncObjectRecord()
            ..objectKey = 'orphan-$i'
            ..reservedLength = syncMaxObjectBytes,
        );
      }
      final remaining =
          syncMaxWorkingBytes -
          r.syncCipherByteCount() -
          r.syncPreparedByteCount() -
          r.syncMissingByteCount() -
          1;
      expect(remaining, inInclusiveRange(1, syncMaxObjectBytes));
      r.putSyncObject(
        SyncObjectRecord()
          ..objectKey = 'orphan-last'
          ..reservedLength = remaining,
      );
      SyncStorageBudget.check(
        cipherBytes: r.syncCipherByteCount(),
        preparedBytes: r.syncPreparedByteCount(),
        missingBytes: r.syncMissingByteCount(),
        freeBytes: h.apply.free,
      );
    });
    final manifest = await h.cloud([mergeProfile(10)], revision: 2);
    await expectLater(
      h.apply.repository.stageRoot(
        h.apply.fence,
        rootId: h.apply.feature.newId(),
        snapshotId: manifest.snapshotId,
        revision: 2,
        sourceGeneration: domain.state.syncState.syncGeneration,
        rootCiphertext: Uint8List.fromList(
          h.server.blobs[manifest.root.sha256]!,
        ),
        objects: manifest.objects,
        pending: false,
      ),
      throwsA(featureFailure(FailureCode.resourceExhausted)),
    );
    var previous = domain.state.syncObjects.length,
        largestDelete = 0,
        deleteBatches = 0;
    domain.beforeWrite = () async {
      final delta = previous - domain.state.syncObjects.length;
      if (delta > 0) {
        deleteBatches++;
        if (delta > largestDelete) largestDelete = delta;
      }
      previous = domain.state.syncObjects.length;
    };
    await h.cycle.resume();
    expect(h.cycle.view.phase, SyncCyclePhase.synced);
    expect(
      domain.state.syncObjects.keys.where((key) => key.startsWith('orphan-')),
      isEmpty,
    );
    expect(largestDelete, lessThanOrEqualTo(1000));
    expect(deleteBatches, greaterThanOrEqualTo(7));
    expect(domain.state.profiles.length, 2);
    expect(domain.state.syncState.baseRevision, 3);
  });

  test('successive encrypted remote revisions do not retain unreachable old ciphertext', () async {
    await h.cycle.resume();
    for (var i = 0; i < 6; i++) {
      await h.cloud([mergeProfile(10, name: 'remote-$i')]);
      await h.cycle.retry();
      expect(h.cycle.view.phase, SyncCyclePhase.synced);
      final domain = h.apply.feature.repository.state;
      final reachable = <String>{};
      for (final root in domain.syncRoots.values) {
        reachable.addAll(
          root.objectHashes.map(h.apply.fence.identity.objectKey),
        );
      }
      expect(domain.syncObjects.keys.toSet(), reachable);
      expect(domain.syncObjects.length, 1);
      expect(domain.profiles[mergeId(10)]!.displayName, 'remote-$i');
    }
  });

  test(
    'GC preserves base pending candidate detached and active preparation pins',
    () async {
      final domain = h.apply.feature.repository;
      final pinned = <String>{};
      await domain.write((r) {
        final base = r.syncRoot(r.syncState.baseRootId!)!;
        for (final hash in base.objectHashes) {
          pinned.add(h.apply.fence.identity.objectKey(hash));
        }
        final pending = r.syncRoot(r.syncState.pendingRootId!)!;
        for (final hash in pending.objectHashes) {
          pinned.add(h.apply.fence.identity.objectKey(hash));
        }
        // Reachability-only synthetic ciphertext and metadata; not candidate crypto evidence.
        for (var i = 0; i < 4; i++) {
          final detached = i > 0;
          final identity = SyncIdentity(
            serviceOrigin: h.apply.fence.identity.serviceOrigin,
            accountId: detached
                ? featureId(980001)
                : h.apply.fence.identity.accountId,
            deviceId: featureId(980002),
            vaultId: detached
                ? featureId(980003)
                : h.apply.fence.identity.vaultId,
          );
          final bytes = Uint8List.fromList(List.filled(28, i + 20)),
              hash = syncSha256(bytes);
          final key = identity.objectKey(hash), id = featureId(980010 + i);
          pinned.add(key);
          r.putSyncObject(
            SyncObjectRecord()
              ..objectKey = key
              ..serviceOrigin = identity.serviceOrigin
              ..accountId = identity.accountId
              ..vaultId = identity.vaultId
              ..sha256 = hash
              ..cipherBytes = bytes
              ..reservedLength = bytes.length,
          );
          r.putSyncRoot(
            SyncRootRecord()
              ..rootId = id
              ..serviceOrigin = identity.serviceOrigin
              ..accountId = identity.accountId
              ..vaultId = identity.vaultId
              ..snapshotId = featureId(980020 + i)
              ..role = detached ? 'detached' : 'candidate'
              ..remoteRevision = 2
              ..manifestCiphertext = Uint8List(28)
              ..objectHashes = [hash]
              ..objectLengths = [28],
          );
          if (!detached) r.putSyncState(r.syncState..candidateRootId = id);
        }
        r.putSyncObject(
          SyncObjectRecord()
            ..objectKey = 'orphan-preparation'
            ..cipherBytes = [1, 2, 3],
        );
      });
      final scope = h.apply.repository.beginPreparation(
        h.apply.fence,
        expectedDataRevision: domain.state.settings.dataRevision,
        expectedSyncGeneration: domain.state.syncState.syncGeneration,
        isCurrent: () => true,
      );
      addTearDown(scope.dispose);
      final prepared = Uint8List.fromList(List.filled(28, 99));
      final preparedHash = syncSha256(prepared);
      await h.apply.repository.prepareObject(scope, preparedHash, prepared);
      pinned.add(h.apply.fence.identity.objectKey(preparedHash));
      h.server.beforeHead = () async {
        h.cycle.pause();
        throw const SyncTransportCancelled();
      };
      final rootsBefore = domain.state.syncRoots.keys.toSet();
      await h.cycle.resume();
      expect(domain.state.syncObjects.keys.toSet(), pinned);
      expect(domain.state.syncRoots.keys.toSet(), rootsBefore);
      expect(domain.state.syncRoots.length, 6);
      expect(domain.state.syncState.pendingRootId, isNotNull);
      expect(h.timerCount, 0);
    },
  );

  test(
    'pause inside GC transaction denies deletion and late scheduling',
    () async {
      final domain = h.apply.feature.repository;
      await domain.write(
        (r) => r.putSyncObject(
          SyncObjectRecord()
            ..objectKey = 'orphan'
            ..cipherBytes = [1],
        ),
      );
      domain.beforeWrite = () async => h.cycle.pause();
      await h.cycle.resume();
      expect(h.cycle.view.phase, SyncCyclePhase.paused);
      expect(domain.state.syncObjects.containsKey('orphan'), isTrue);
      expect(domain.state.syncState.pendingRootId, isNotNull);
      expect(h.server.calls, isEmpty);
      expect(h.timerCount, 0);
    },
  );

  test('rolled back GC sweep restarts its cursor on explicit retry', () async {
    final domain = h.apply.feature.repository;
    await domain.write((r) {
      for (var i = 0; i < 1100; i++) {
        r.putSyncObject(
          SyncObjectRecord()
            ..objectKey = 'orphan-$i'
            ..cipherBytes = [1],
        );
      }
    });
    domain.failCommit = true;
    await h.cycle.resume();
    expect(h.cycle.view.phase, SyncCyclePhase.error);
    expect(
      domain.state.syncObjects.keys
          .where((key) => key.startsWith('orphan-'))
          .length,
      1100,
    );
    expect(h.timerCount, 0);
    await h.cycle.retry();
    expect(h.cycle.view.phase, SyncCyclePhase.synced);
    expect(
      domain.state.syncObjects.keys.where((key) => key.startsWith('orphan-')),
      isEmpty,
    );
  });
}
