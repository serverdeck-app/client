import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/storage/records.dart';
import 'package:serverdeck/sync/sync_models.dart';
import 'package:serverdeck/sync/sync_repository.dart';

import '../fixtures/domain_repository.dart';
import 'repository_test.dart' show uuid, failure;

// Opaque synthetic bodies exercise storage/atomicity only, not GCM validation.
class _Harness {
  final domain = MemoryDomainRepository();
  late final SyncRepository sync;
  late SyncFence fence;
  int free = 100 * 1024 * 1024 * 1024;
  Future<int> Function()? probe;
  bool current = true;
  Future<void> setup() async {
    sync = SyncRepository(
      domain,
      availableStorageBytes: () async => probe == null ? free : await probe!(),
      utcNow: () => 100,
    );
    fence = await sync.bind(
      expectedGeneration: 1,
      identity: SyncIdentity(
        serviceOrigin: 'https://sync.example.test',
        accountId: uuid(1),
        deviceId: uuid(2),
        vaultId: uuid(3),
      ),
      secrets: SyncSecretRecord()
        ..protectedAccess = [1]
        ..protectedRefresh = [2]
        ..protectedStatusProof = [3],
    );
  }

  SyncPreparation begin() => sync.beginPreparation(
    fence,
    expectedDataRevision: domain.state.settings.dataRevision,
    expectedSyncGeneration: domain.state.syncState.syncGeneration,
    isCurrent: () => current,
  );
  Uint8List body(int n) => Uint8List.fromList(List.filled(28, n));
  SyncBlobRef ref(int n) => SyncBlobRef(syncSha256(body(n)), 28);
  SyncPendingIntent pending(
    int n, {
    int revision = 1,
    List<SyncBlobRef> objects = const [],
  }) => SyncPendingIntent(
    rootId: uuid(n),
    snapshotId: uuid(n + 1),
    commitId: uuid(n + 2),
    revision: revision,
    ciphertext: body(n),
    objects: objects,
  );
  Future<void> stage(
    int n, {
    bool pending = true,
    int revision = 1,
    List<SyncBlobRef> objects = const [],
    int? snapshot,
    int? cipher,
  }) => sync.stageRoot(
    fence,
    rootId: uuid(n),
    snapshotId: uuid(snapshot ?? n + 1),
    revision: revision,
    sourceGeneration: domain.state.syncState.syncGeneration,
    rootCiphertext: body(cipher ?? n),
    objects: objects,
    pending: pending,
    commitId: pending ? uuid(n + 2) : null,
  );
  Future<void> base() async {
    await stage(10);
    await sync.acknowledge(
      fence,
      rootId: uuid(10),
      commitId: uuid(12),
      revision: 1,
      successUtc: 1,
    );
  }

  Future<void> diverged() async {
    await base();
    await domain.write(SyncRepository.markDirty);
    await stage(20, revision: 2);
    await stage(30, pending: false, revision: 2);
  }

  Future<SyncPreparedTransition> transition(
    SyncPreparation scope, {
    String? remote,
    SyncPendingIntent? pending,
    bool consume = false,
    int? ack,
    int domainBytes = 0,
  }) => sync.prepareTransition(
    scope,
    remoteRootId: remote,
    pending: pending,
    consumePending: consume,
    acknowledgeGeneration: ack ?? domain.state.syncState.ackGeneration,
    successUtc: 100,
    domainWriteBytes: domainBytes,
  );
}

void main() {
  test('shared snapshots roll back connection-triggered journal resets', () async {
    final domain = MemoryDomainRepository()..shareUnchangedRecords = true;
    addTearDown(domain.disposeNotifications);
    const payload =
        '{"version":1,"checkpoint":{"cursor":"saved"},"entries":["saved"],"partial":false}';
    await domain.write((r) {
      r.putProfile(Profile()..profileId = uuid(6));
      r.putJournalSource(
        JournalSource()
          ..sourceId = uuid(7)
          ..profileId = uuid(6)
          ..payload = payload,
      );
    });
    final originalRevision = domain.state.profiles[uuid(6)]!.connectionRevision;
    for (final failCommit in [false, true]) {
      domain.failCommit = failCommit;
      await expectLater(
        domain.write<void>((r) {
          r.putProfile(
            r.profile(uuid(6))!..connectionRevision = originalRevision + 1,
          );
          expect(
            r.journalSource(uuid(7))!.connectionRevision,
            originalRevision + 1,
          );
          expect(r.journalSource(uuid(7))!.payload, isNot(payload));
          if (!failCommit) throw StateError('synthetic rollback');
        }),
        throwsStateError,
      );
      expect(
        domain.state.profiles[uuid(6)]!.connectionRevision,
        originalRevision,
      );
      expect(
        domain.state.journalSources[uuid(7)]!.connectionRevision,
        originalRevision,
      );
      expect(domain.state.journalSources[uuid(7)]!.payload, payload);
    }
  });
  test(
    'high-cardinality fake snapshots retain record detachment and rollback',
    () async {
      final h = _Harness();
      await h.setup();
      h.domain.shareUnchangedRecords = true;
      await h.stage(30, pending: false, objects: [h.ref(77)]);
      final scope = h.begin();
      await h.sync.prepareObject(scope, h.ref(77).sha256, h.body(77));
      final key = h.fence.identity.objectKey(h.ref(77).sha256);
      await expectLater(
        h.domain.write<void>((r) {
          final object = r.syncObject(key)!;
          object.cipherBytes[0] = 0;
          r.putSyncObject(object);
          r.putSyncState(r.syncState..candidateRootId = null);
          throw StateError('synthetic rollback');
        }),
        throwsStateError,
      );
      expect(h.domain.state.syncObjects[key]!.cipherBytes, h.body(77));
      expect(h.domain.state.syncState.candidateRootId, uuid(30));
      h.domain.read((r) => r.syncObject(key)!.cipherBytes[0] = 0);
      expect(h.domain.state.syncObjects[key]!.cipherBytes, h.body(77));
      scope.dispose();
    },
  );
  test('root-backed preparation remains GC-pinned after its root is retired until scope disposal', () async {
    final h = _Harness();
    await h.setup();
    final ref = h.ref(77);
    await h.stage(30, pending: false, objects: [ref]);
    final scope = h.begin();
    await h.sync.prepareObject(scope, ref.sha256, h.body(77));
    await h.domain.write((r) {
      r.deleteSyncRoot(uuid(30));
      r.putSyncState(r.syncState..candidateRootId = null);
    });
    expect(
      await h.sync.collectGarbage(expectedGeneration: h.fence.generation),
      0,
    );
    expect(h.domain.state.syncObjects.length, 1);
    scope.dispose();
    expect(
      (await h.sync.collectGarbagePass(
        expectedGeneration: h.fence.generation,
        restart: true,
      )).removed,
      1,
    );
    expect(h.domain.state.syncObjects, isEmpty);
  });
  late _Harness h;
  setUp(() async {
    h = _Harness();
    await h.setup();
  });
  tearDown(() => h.domain.disposeNotifications());

  test('detached roots survive preparation and active root transition in a new binding', () async {
    await h.base();
    final generation = await h.sync.detach(h.fence);
    h.fence = await h.sync.bind(
      expectedGeneration: generation,
      identity: SyncIdentity(
        serviceOrigin: 'https://sync.example.test',
        accountId: uuid(101),
        deviceId: uuid(102),
        vaultId: uuid(103),
      ),
      secrets: SyncSecretRecord()
        ..protectedAccess = [1]
        ..protectedRefresh = [2]
        ..protectedStatusProof = [3],
    );
    final scope = h.begin(), input = h.pending(20);
    addTearDown(scope.dispose);
    addTearDown(input.dispose);
    final prepared = await h.transition(scope, pending: input);
    await h.domain.write(prepared.commit);
    expect(h.domain.state.syncRoots[uuid(10)]!.role, 'detached');
    expect(h.domain.state.syncRoots[uuid(10)]!.accountId, uuid(1));
    expect(h.domain.state.syncRoots[uuid(20)]!.role, 'pending');
    expect(h.domain.state.syncRoots[uuid(20)]!.accountId, uuid(101));
  });

  test(
    'publication ciphertext is captured before awaiting the free-space probe',
    () async {
      final scope = h.begin(), input = h.pending(20), gate = Completer<int>();
      addTearDown(scope.dispose);
      addTearDown(input.dispose);
      h.probe = () => gate.future;
      final pending = h.transition(scope, pending: input);
      input.dispose();
      gate.complete(h.free);
      final prepared = await pending;
      await h.domain.write(prepared.commit);
      expect(
        h.domain.state.syncRoots[uuid(20)]!.manifestCiphertext,
        h.body(20),
      );
    },
  );

  test('remote completeness and unchanged opaque proof are checked again at commit', () async {
    await h.stage(10, pending: false, objects: [h.ref(8)]);
    final scope = h.begin();
    addTearDown(scope.dispose);
    await expectLater(
      h.transition(scope, remote: uuid(10)),
      throwsA(failure(FailureCode.conflict)),
    );
    await h.sync.putObject(h.fence, h.ref(8).sha256, h.body(8));
    final prepared = await h.transition(scope, remote: uuid(10));
    h.domain.state.syncRoots[uuid(10)]!.manifestCiphertext[0]++;
    await expectLater(
      h.domain.write(prepared.commit),
      throwsA(failure(FailureCode.conflict)),
    );
    expect(h.domain.state.syncState.candidateRootId, uuid(10));
    expect(h.domain.state.syncState.baseRootId, isNull);
  });

  test(
    'scoped encrypted cache is copied, budgeted and GC-pinned without a root',
    () async {
      final body = h.body(8),
          secret = Uint8List.fromList([3, 4]),
          hash = syncSha256(body);
      await expectLater(
        h.sync.putObject(h.fence, hash, body),
        throwsA(failure(FailureCode.conflict)),
      );
      final scope = h.begin();
      await h.sync.prepareObject(
        scope,
        hash,
        body,
        protectedCredential: secret,
        credentialId: uuid(5),
      );
      body[0] = 99;
      secret[0] = 99;
      final stored = h.sync.readObject(h.fence, hash);
      expect(stored.cipherBytes, h.body(8));
      expect(stored.locallyPreparedCredential, [3, 4]);
      expect(stored.preparedAgainstGeneration, 1);
      expect(h.domain.state.syncRoots, isEmpty);
      expect(
        await h.sync.collectGarbage(expectedGeneration: h.fence.generation),
        0,
      );
      scope.dispose();
      for (var i = 0; i < 3; i++) {
        await h.sync.collectGarbage(expectedGeneration: h.fence.generation);
      }
      expect(h.domain.state.syncObjects, isEmpty);
    },
  );

  test('single flight, foreign scope and disposed scope cannot admit preparation writes', () async {
    final first = h.begin();
    expect(h.begin, throwsA(failure(FailureCode.resourceExhausted)));
    final other = SyncRepository(
      h.domain,
      availableStorageBytes: () async => h.free,
    );
    await expectLater(
      other.prepareObject(first, h.ref(8).sha256, h.body(8)),
      throwsA(failure(FailureCode.conflict)),
    );
    first.dispose();
    final second = h.begin();
    first.dispose();
    await expectLater(
      h.sync.prepareObject(first, h.ref(8).sha256, h.body(8)),
      throwsA(failure(FailureCode.conflict)),
    );
    await h.sync.prepareObject(second, h.ref(9).sha256, h.body(9));
    second.dispose();
  });

  test('cancellation or disposal during the space probe admits no late cache object', () async {
    for (final dispose in [false, true]) {
      final scope = h.begin(), gate = Completer<int>();
      h.probe = () => gate.future;
      final future = h.sync.prepareObject(scope, h.ref(8).sha256, h.body(8));
      if (dispose) {
        scope.dispose();
      } else {
        h.current = false;
      }
      gate.complete(h.free);
      await expectLater(future, throwsA(failure(FailureCode.conflict)));
      expect(h.domain.state.syncObjects, isEmpty);
      scope.dispose();
      h.current = true;
    }
  });

  test('first publication replaces an approved old pending only in the domain transaction', () async {
    await h.stage(10);
    final scope = h.begin(), input = h.pending(20, objects: [h.ref(8)]);
    addTearDown(scope.dispose);
    addTearDown(input.dispose);
    await h.sync.prepareObject(scope, h.ref(8).sha256, h.body(8));
    await expectLater(
      h.transition(scope, pending: input),
      throwsA(failure(FailureCode.conflict)),
    );
    final prepared = await h.transition(scope, pending: input, consume: true);
    input.dispose(); // Prepared transition owns its copy.
    expect(h.domain.state.syncState.pendingRootId, uuid(10));
    var notifications = 0;
    final subscription = h.domain.domainChanges.listen((_) => notifications++);
    addTearDown(subscription.cancel);
    await h.domain.write((r) {
      prepared.commit(r);
      r.putProfile(
        Profile()
          ..profileId = uuid(6)
          ..displayName = 'atomic',
      );
      r.putSettings(r.settings..dataRevision = 2);
    });
    await Future<void>.delayed(Duration.zero);
    expect(notifications, 1);
    expect(h.domain.state.syncState.baseRevision, 0);
    expect(h.domain.state.syncState.baseRootId, isNull);
    expect(h.domain.state.syncState.pendingRootId, uuid(20));
    expect(h.domain.state.syncState.lastSuccessUtc, isNull);
    expect(h.domain.state.syncRoots.keys, [uuid(20)]);
    scope.dispose();
    await h.domain.write(SyncRepository.markDirty);
    final recreated = SyncRepository(
      h.domain,
      availableStorageBytes: () async => h.free,
    );
    await recreated.acknowledge(
      h.fence,
      rootId: uuid(20),
      commitId: uuid(22),
      revision: 1,
      successUtc: 200,
    );
    expect(h.domain.state.syncState.ackGeneration, 0);
    expect(h.domain.state.syncState.syncGeneration, 1);
    expect(h.domain.state.profiles[uuid(6)]!.displayName, 'atomic');
  });

  test('three occupied active slots rebase to observed remote plus merged pending with no fourth root', () async {
    await h.diverged();
    final scope = h.begin(),
        input = h.pending(40, revision: 3, objects: [h.ref(8)]);
    addTearDown(scope.dispose);
    addTearDown(input.dispose);
    await h.sync.prepareObject(scope, h.ref(8).sha256, h.body(8));
    final prepared = await h.transition(
      scope,
      remote: uuid(30),
      pending: input,
      consume: true,
    );
    expect(h.domain.state.syncRoots.keys, [uuid(10), uuid(20), uuid(30)]);
    await h.domain.write((r) {
      prepared.commit(r);
      r.putProfile(
        Profile()
          ..profileId = uuid(6)
          ..displayName = 'merged',
      );
      r.putSettings(r.settings..dataRevision = 2);
    });
    final state = h.domain.state.syncState;
    expect(state.baseRootId, uuid(30));
    expect(state.baseRevision, 2);
    expect(state.pendingRootId, uuid(40));
    expect(state.pendingCommitId, uuid(42));
    expect(state.ackGeneration, 0);
    expect(state.syncGeneration, 1);
    expect(state.lastSuccessUtc, 1);
    expect(h.domain.state.syncRoots.keys.toSet(), {uuid(30), uuid(40)});
    expect(h.domain.state.syncRoots[uuid(40)]!.sourceGeneration, 1);
    scope.dispose();
    await h.sync.acknowledge(
      h.fence,
      rootId: uuid(40),
      commitId: uuid(42),
      revision: 3,
      successUtc: 200,
    );
    expect(h.domain.state.syncState.ackGeneration, 1);
    expect(h.domain.state.syncState.baseRootId, uuid(40));
  });

  test('partial root transition and failed commit roll back domain, base, pending and candidate together', () async {
    for (final partial in [true, false]) {
      final local = _Harness();
      await local.setup();
      await local.diverged();
      addTearDown(local.domain.disposeNotifications);
      local.domain.state.profiles[uuid(6)] = Profile()
        ..profileId = uuid(6)
        ..displayName = 'old';
      final scope = local.begin(), input = local.pending(40, revision: 3);
      addTearDown(scope.dispose);
      addTearDown(input.dispose);
      final prepared = await local.transition(
        scope,
        remote: uuid(30),
        pending: input,
        consume: true,
      );
      if (partial) {
        local.domain.failAfterWrite = 2;
      } else {
        local.domain.failCommit = true;
      }
      await expectLater(
        local.domain.write((r) {
          prepared.commit(r);
          r.putProfile(r.profile(uuid(6))!..displayName = 'new');
          r.putSettings(r.settings..dataRevision = 2);
        }),
        throwsStateError,
      );
      expect(local.domain.state.syncState.baseRootId, uuid(10));
      expect(local.domain.state.syncState.pendingRootId, uuid(20));
      expect(local.domain.state.syncState.candidateRootId, uuid(30));
      expect(local.domain.state.syncRoots.keys, [uuid(10), uuid(20), uuid(30)]);
      expect(local.domain.state.profiles[uuid(6)]!.displayName, 'old');
      expect(local.domain.state.settings.dataRevision, 1);
      local.domain.failAfterWrite = null;
      await expectLater(
        local.domain.write(prepared.commit),
        throwsA(failure(FailureCode.conflict)),
      );
    }
  });

  test('server-only choice consumes pending explicitly and acknowledges captured generation', () async {
    await h.diverged();
    final scope = h.begin();
    addTearDown(scope.dispose);
    await expectLater(
      h.transition(scope, remote: uuid(30), ack: 1),
      throwsA(failure(FailureCode.conflict)),
    );
    final prepared = await h.transition(
      scope,
      remote: uuid(30),
      ack: 1,
      consume: true,
    );
    await h.domain.write(prepared.commit);
    expect(h.domain.state.syncState.pendingRootId, isNull);
    expect(h.domain.state.syncState.baseRootId, uuid(30));
    expect(h.domain.state.syncState.ackGeneration, 1);
    expect(h.domain.state.syncState.lastSuccessUtc, 100);
    await expectLater(
      h.domain.write(prepared.commit),
      throwsA(failure(FailureCode.conflict)),
    );
  });

  test('pending cannot acknowledge dirty generation, skip remote revision or reuse immutable IDs', () async {
    await h.diverged();
    final scope = h.begin();
    addTearDown(scope.dispose);
    final next = h.pending(40, revision: 3),
        skipped = h.pending(50, revision: 4),
        reused = h.pending(20, revision: 3);
    addTearDown(next.dispose);
    addTearDown(skipped.dispose);
    addTearDown(reused.dispose);
    await expectLater(
      h.transition(
        scope,
        remote: uuid(30),
        pending: next,
        ack: 1,
        consume: true,
      ),
      throwsA(failure(FailureCode.conflict)),
    );
    for (final input in [skipped, reused]) {
      await expectLater(
        h.transition(scope, remote: uuid(30), pending: input, consume: true),
        throwsA(failure(FailureCode.conflict)),
      );
    }
    expect(h.domain.state.syncState.pendingRootId, uuid(20));
  });

  test('same-revision fork rejects while identical opaque base proof with another local ID is accepted', () async {
    await h.base();
    await h.stage(20, pending: false);
    var scope = h.begin();
    await expectLater(
      h.transition(scope, remote: uuid(20)),
      throwsA(failure(FailureCode.conflict)),
    );
    scope.dispose();
    await h.stage(30, pending: false, snapshot: 11, cipher: 10);
    scope = h.begin();
    addTearDown(scope.dispose);
    final prepared = await h.transition(scope, remote: uuid(30));
    await h.domain.write(prepared.commit);
    expect(h.domain.state.syncState.baseRevision, 1);
    expect(h.domain.state.syncState.baseRootId, uuid(30));
  });

  test(
    'source counters/head aliases and final transaction admission are fenced',
    () async {
      for (final changed in [
        'data',
        'generation',
        'pending',
        'commit',
        'candidate',
        'ack',
        'base',
        'conflict',
        'identity',
        'owner',
      ]) {
        final local = _Harness();
        await local.setup();
        await local.diverged();
        addTearDown(local.domain.disposeNotifications);
        final scope = local.begin(), input = local.pending(40, revision: 3);
        addTearDown(scope.dispose);
        addTearDown(input.dispose);
        final prepared = await local.transition(
          scope,
          remote: uuid(30),
          pending: input,
          consume: true,
        );
        local.domain.beforeWrite = () async {
          final state = local.domain.state.syncState;
          switch (changed) {
            case 'data':
              local.domain.state.settings.dataRevision++;
            case 'generation':
              state.syncGeneration++;
            case 'pending':
              state.pendingRootId = uuid(80);
            case 'commit':
              state.pendingCommitId = uuid(81);
            case 'candidate':
              state.candidateRootId = null;
            case 'ack':
              state.ackGeneration++;
            case 'base':
              state.baseRevision++;
            case 'conflict':
              state.conflictLocalId = uuid(20);
            case 'identity':
              state.identityGeneration++;
            case 'owner':
              local.current = false;
          }
        };
        await expectLater(
          local.domain.write(prepared.commit),
          throwsA(failure(FailureCode.conflict)),
          reason: changed,
        );
        expect(local.domain.state.syncRoots.containsKey(uuid(40)), isFalse);
        expect(local.domain.state.syncRoots[uuid(20)]!.role, 'pending');
      }
    },
  );

  test('incomplete refs, disposed input and insufficient space preserve previous pending', () async {
    await h.stage(10);
    final scope = h.begin(), input = h.pending(20, objects: [h.ref(8)]);
    addTearDown(scope.dispose);
    addTearDown(input.dispose);
    await expectLater(
      h.transition(scope, pending: input, consume: true),
      throwsA(failure(FailureCode.conflict)),
    );
    await h.sync.prepareObject(scope, h.ref(8).sha256, h.body(8));
    h.free = 0;
    await expectLater(
      h.transition(scope, pending: input, consume: true),
      throwsA(failure(FailureCode.resourceExhausted)),
    );
    input.dispose();
    h.free = 100 * 1024 * 1024 * 1024;
    await expectLater(
      h.transition(scope, pending: input, consume: true),
      throwsA(failure(FailureCode.conflict)),
    );
    expect(h.domain.state.syncState.pendingRootId, uuid(10));
    expect(h.domain.state.syncRoots.keys, [uuid(10)]);
  });

  test('failed cache probe and late ledger growth do not admit an over-budget transition', () async {
    final scope = h.begin(), input = h.pending(20);
    addTearDown(scope.dispose);
    addTearDown(input.dispose);
    h.probe = () async => throw StateError('synthetic free-space failure');
    await expectLater(
      h.sync.prepareObject(scope, h.ref(8).sha256, h.body(8)),
      throwsA(failure(FailureCode.storageUnavailable)),
    );
    expect(h.domain.state.syncObjects, isEmpty);
    h.probe = null;
    h.free = syncMinFreeBytes + 1024;
    final prepared = await h.transition(
      scope,
      pending: input,
      domainBytes: 100,
    );
    h.domain.state.syncObjects['synthetic-reservation'] = SyncObjectRecord()
      ..objectKey = 'synthetic-reservation'
      ..reservedLength = 4096;
    await expectLater(
      h.domain.write(prepared.commit),
      throwsA(failure(FailureCode.resourceExhausted)),
    );
    expect(h.domain.state.syncRoots, isEmpty);
  });

  test('publication input validates duplicate/self refs and bounded IDs/aggregate before use', () {
    expect(
      () => SyncPendingIntent(
        rootId: 'bad',
        snapshotId: uuid(1),
        commitId: uuid(2),
        revision: 1,
        ciphertext: h.body(3),
        objects: [],
      ),
      throwsA(failure(FailureCode.invalidArgument)),
    );
    expect(
      () => h.pending(20, objects: [h.ref(8), h.ref(8)]),
      throwsA(failure(FailureCode.invalidArgument)),
    );
    expect(
      () => h.pending(20, objects: [h.ref(20)]),
      throwsA(failure(FailureCode.invalidArgument)),
    );
    expect(
      () => h.pending(
        20,
        objects: [
          for (var n = 0; n < 1024; n++)
            SyncBlobRef(
              n.toRadixString(16).padLeft(64, '0'),
              syncMaxObjectBytes,
            ),
        ],
      ),
      throwsA(failure(FailureCode.invalidArgument)),
    );
  });
}
