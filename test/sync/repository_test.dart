import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/storage/records.dart';
import 'package:serverdeck/sync/sync_models.dart';
import 'package:serverdeck/sync/sync_repository.dart';

import '../fixtures/domain_repository.dart';

String uuid(int value) =>
    '00000000-0000-4000-8000-${value.toRadixString(16).padLeft(12, '0')}';
Matcher failure(FailureCode code) =>
    isA<OperationFailure>().having((value) => value.code, 'code', code);

void main() {
  late MemoryDomainRepository domain;
  late SyncRepository sync;
  late SyncFence fence;
  late Uint8List payload;
  late String hash;
  late int free;

  SyncIdentity identity(int number) => SyncIdentity(
    serviceOrigin: 'https://sync.example.test',
    accountId: uuid(number),
    deviceId: uuid(number + 1),
    vaultId: uuid(number + 2),
  );
  SyncSecretRecord secrets() => SyncSecretRecord()
    ..protectedAccess = [1]
    ..protectedRefresh = [2]
    ..protectedStatusProof = [3];

  Future<void> stage(
    int root, {
    bool pending = true,
    int revision = 1,
    int generation = 0,
  }) => sync.stageRoot(
    fence,
    rootId: uuid(root),
    snapshotId: uuid(root + 1),
    revision: revision,
    sourceGeneration: generation,
    rootCiphertext: Uint8List(28),
    objects: [SyncBlobRef(hash, payload.length)],
    pending: pending,
    commitId: pending ? uuid(root + 2) : null,
  );

  setUp(() async {
    domain = MemoryDomainRepository();
    free = 100 * 1024 * 1024 * 1024;
    sync = SyncRepository(domain, availableStorageBytes: () async => free);
    fence = await sync.bind(
      expectedGeneration: 1,
      identity: identity(1),
      secrets: secrets(),
    );
    payload = Uint8List.fromList([1, 2, 3]);
    hash = syncSha256(payload);
  });

  test(
    'pending survives owner recreation and ACK clears only captured generation',
    () async {
      await stage(10);
      await sync.putObject(fence, hash, payload);
      await domain.write(SyncRepository.markDirty);
      sync = SyncRepository(domain, availableStorageBytes: () async => free);
      await sync.acknowledge(
        fence,
        rootId: uuid(10),
        commitId: uuid(12),
        revision: 1,
        successUtc: 1000,
      );
      domain.read((records) {
        final state = records.syncState;
        expect(state.baseRootId, uuid(10));
        expect(state.baseRevision, 1);
        expect(state.ackGeneration, 0);
        expect(state.syncGeneration, 1);
        expect(state.pendingRootId, isNull);
      });
      await stage(20, revision: 2, generation: 1);
    },
  );

  test(
    'cannot ACK incomplete root or silently mutate immutable pending',
    () async {
      await stage(10);
      await expectLater(
        sync.acknowledge(
          fence,
          rootId: uuid(10),
          commitId: uuid(12),
          revision: 1,
          successUtc: 1,
        ),
        throwsA(failure(FailureCode.conflict)),
      );
      await stage(10);
      await expectLater(stage(20), throwsA(failure(FailureCode.conflict)));
      await expectLater(
        sync.stageRoot(
          fence,
          rootId: uuid(10),
          snapshotId: uuid(11),
          revision: 1,
          sourceGeneration: 0,
          rootCiphertext: Uint8List.fromList(List.filled(28, 1)),
          objects: [SyncBlobRef(hash, 3)],
          pending: true,
          commitId: uuid(12),
        ),
        throwsA(failure(FailureCode.conflict)),
      );
      expect(
        domain.read((records) => records.syncState.pendingRootId),
        uuid(10),
      );
    },
  );

  test(
    'foreign/unreferenced or hash-mismatched objects never persist',
    () async {
      await expectLater(
        sync.putObject(fence, hash, payload),
        throwsA(failure(FailureCode.conflict)),
      );
      await stage(10);
      await expectLater(
        sync.putObject(fence, hash, Uint8List.fromList([3, 2, 1])),
        throwsA(failure(FailureCode.invalidArgument)),
      );
      await sync.putObject(fence, hash, payload);
      payload[0] = 9;
      expect(sync.readObject(fence, hash).cipherBytes, [1, 2, 3]);
    },
  );

  test(
    'space failure and late commit failure preserve old pending/current domain',
    () async {
      await stage(10);
      free = syncMinFreeBytes;
      await expectLater(
        sync.putObject(fence, hash, payload),
        throwsA(failure(FailureCode.resourceExhausted)),
      );
      expect(
        domain.read(
          (records) => records.syncObjectLength(fence.identity.objectKey(hash)),
        ),
        isNull,
      );
      free = 100 * 1024 * 1024 * 1024;
      domain.failCommit = true;
      await expectLater(
        sync.putObject(fence, hash, payload),
        throwsA(failure(FailureCode.storageUnavailable)),
      );
      expect(
        domain.read((records) => records.syncState.pendingRootId),
        uuid(10),
      );
      expect(
        domain.read(
          (records) => records.syncObjectLength(fence.identity.objectKey(hash)),
        ),
        isNull,
      );
    },
  );

  test('identity change during space await fences late write', () async {
    await stage(10);
    final space = Completer<int>();
    sync = SyncRepository(domain, availableStorageBytes: () => space.future);
    final late = sync.putObject(fence, hash, payload);
    await Future<void>.delayed(Duration.zero);
    final generation = await sync.detach(fence);
    space.complete(free);
    await expectLater(late, throwsA(failure(FailureCode.conflict)));
    expect(generation, greaterThan(fence.generation));
    expect(
      domain.read(
        (records) => records.syncObjectLength(fence.identity.objectKey(hash)),
      ),
      isNull,
    );
  });

  test('candidate/conflict aliases retain pending and replacing remote invalidates preview', () async {
    await stage(10);
    await stage(20, pending: false);
    await sync.setConflict(
      fence,
      localRootId: uuid(10),
      remoteRootId: uuid(20),
    );
    await stage(30, pending: false, revision: 2);
    domain.read((records) {
      expect(records.syncState.pendingRootId, uuid(10));
      expect(records.syncState.candidateRootId, uuid(30));
      expect(records.syncState.conflictLocalId, isNull);
      expect(records.syncRoot(uuid(20)), isNull);
    });
  });

  test(
    'detached intent requires explicit discard before a second detachment',
    () async {
      await stage(10);
      await sync.putObject(fence, hash, payload);
      final generation = await sync.detach(fence);
      expect(
        domain.read((records) => records.syncSecrets.protectedAccess),
        isNull,
      );
      final oldKey = fence.identity.objectKey(hash);
      fence = await sync.bind(
        expectedGeneration: generation,
        identity: identity(100),
        secrets: secrets(),
      );
      await stage(30);
      await expectLater(
        sync.detach(fence),
        throwsA(failure(FailureCode.conflict)),
      );
      expect(domain.read((records) => records.syncObject(oldKey)), isNotNull);
      await sync.discardDetached(expectedGeneration: fence.generation);
      await sync.detach(fence);
      expect(
        domain.read((records) => records.syncRoots().single.rootId),
        uuid(30),
      );
    },
  );

  test('protected preparation is fenced to current data revision', () async {
    await stage(10);
    await expectLater(
      sync.putObject(
        fence,
        hash,
        payload,
        protectedCredential: Uint8List.fromList([8]),
        credentialId: uuid(99),
        preparedDataRevision: 0,
      ),
      throwsA(failure(FailureCode.conflict)),
    );
    await sync.putObject(
      fence,
      hash,
      payload,
      protectedCredential: Uint8List.fromList([8]),
      credentialId: uuid(99),
      preparedDataRevision: 1,
    );
    expect(sync.readObject(fence, hash).preparedAgainstGeneration, 1);
  });

  test(
    'bounded GC progresses past pinned keys without evicting pending',
    () async {
      await stage(10);
      await sync.putObject(fence, hash, payload);
      await domain.write((records) {
        for (var index = 0; index < 5; index++) {
          records.putSyncObject(
            SyncObjectRecord()
              ..objectKey = 'orphan-$index'
              ..cipherBytes = [1],
          );
        }
      });
      for (var index = 0; index < 15; index++) {
        expect(
          await sync.collectGarbage(
            expectedGeneration: fence.generation,
            limit: 1,
          ),
          lessThanOrEqualTo(1),
        );
      }
      expect(domain.state.syncObjects.length, 1);
      expect(
        domain.read((records) => records.syncState.pendingRootId),
        uuid(10),
      );
    },
  );

  test('working-set arithmetic covers 24GiB without allocating payloads', () {
    SyncStorageBudget.check(
      cipherBytes: syncMaxWorkingBytes,
      preparedBytes: 0,
      missingBytes: 0,
      freeBytes: syncMinFreeBytes,
    );
    expect(
      () => SyncStorageBudget.check(
        cipherBytes: syncMaxWorkingBytes,
        preparedBytes: 0,
        missingBytes: 1,
        freeBytes: free,
      ),
      throwsA(failure(FailureCode.resourceExhausted)),
    );
    expect(
      () => SyncStorageBudget.check(
        cipherBytes: 1,
        preparedBytes: 1,
        missingBytes: 10,
        freeBytes: syncMinFreeBytes + 19,
      ),
      throwsA(failure(FailureCode.resourceExhausted)),
    );
  });

  test('candidate base and domain apply share one rollback boundary', () async {
    await stage(10, pending: false);
    await sync.putObject(fence, hash, payload);
    void apply(records) {
      sync.acceptCandidateInTransaction(
        records,
        fence,
        rootId: uuid(10),
        expectedDataRevision: 1,
        expectedSyncGeneration: 0,
        acknowledgeGeneration: 0,
        successUtc: 1,
      );
      records.putProfile(Profile()..profileId = uuid(70));
    }

    domain.failCommit = true;
    await expectLater(domain.write(apply), throwsStateError);
    domain.read((records) {
      expect(records.syncState.baseRevision, 0);
      expect(records.syncState.candidateRootId, uuid(10));
      expect(records.profile(uuid(70)), isNull);
    });
    await domain.write(apply);
    domain.read((records) {
      expect(records.syncState.baseRevision, 1);
      expect(records.syncState.candidateRootId, isNull);
      expect(records.profile(uuid(70)), isNotNull);
    });
  });

  test(
    'candidate captured before a later ACK cannot regress the base',
    () async {
      await stage(10);
      await sync.putObject(fence, hash, payload);
      await sync.acknowledge(
        fence,
        rootId: uuid(10),
        commitId: uuid(12),
        revision: 1,
        successUtc: 1,
      );
      await stage(20, pending: false);
      await stage(30, revision: 2);
      await sync.acknowledge(
        fence,
        rootId: uuid(30),
        commitId: uuid(32),
        revision: 2,
        successUtc: 2,
      );
      await expectLater(
        domain.write(
          (records) => sync.acceptCandidateInTransaction(
            records,
            fence,
            rootId: uuid(20),
            expectedDataRevision: 1,
            expectedSyncGeneration: 0,
            acknowledgeGeneration: 0,
            successUtc: 3,
          ),
        ),
        throwsA(failure(FailureCode.conflict)),
      );
      expect(domain.read((records) => records.syncState.baseRevision), 2);
    },
  );

  test(
    'declared 4GiB is reserved before bytes and namespaces do not deduplicate',
    () async {
      final refs = List.generate(
        1024,
        (index) => SyncBlobRef(
          index.toRadixString(16).padLeft(64, '0'),
          syncMaxObjectBytes - (index == 1023 ? 28 : 0),
        ),
      );
      Future<void> reserve(int root) => sync.stageRoot(
        fence,
        rootId: uuid(root),
        snapshotId: uuid(root + 1),
        revision: 1,
        sourceGeneration: 0,
        rootCiphertext: Uint8List(28),
        objects: refs,
        pending: true,
        commitId: uuid(root + 2),
      );
      await reserve(10);
      domain.read((records) {
        expect(records.syncReservedByteCount(), syncMaxHeadBytes);
        expect(records.syncCipherByteCount(), 28);
        expect(records.syncMissingByteCount(), syncMaxHeadBytes - 28);
      });
      final generation = await sync.detach(fence);
      fence = await sync.bind(
        expectedGeneration: generation,
        identity: identity(100),
        secrets: secrets(),
      );
      await reserve(30);
      expect(
        domain.read((records) => records.syncReservedByteCount()),
        2 * syncMaxHeadBytes,
      );
    },
  );

  test('three active plus three detached slots preserve both until explicit discard', () async {
    Future<void> populate(int offset) async {
      await stage(offset);
      await sync.putObject(fence, hash, payload);
      await sync.acknowledge(
        fence,
        rootId: uuid(offset),
        commitId: uuid(offset + 2),
        revision: 1,
        successUtc: 1,
      );
      await stage(offset + 10, revision: 2);
      await stage(offset + 20, revision: 3, pending: false);
    }

    await populate(10);
    final oldKey = fence.identity.objectKey(hash);
    final generation = await sync.detach(fence);
    fence = await sync.bind(
      expectedGeneration: generation,
      identity: identity(100),
      secrets: secrets(),
    );
    await populate(40);
    expect(domain.read((records) => records.syncRootCount()), 6);
    await expectLater(
      sync.detach(fence),
      throwsA(failure(FailureCode.conflict)),
    );
    expect(domain.read((records) => records.syncRootCount()), 6);
    await sync.discardDetached(expectedGeneration: fence.generation);
    await sync.collectGarbage(expectedGeneration: fence.generation);
    expect(domain.read((records) => records.syncObject(oldKey)), isNull);
    expect(sync.readObject(fence, hash).cipherBytes, payload);
    expect(domain.read((records) => records.syncRootCount()), 3);
  });

  test(
    'stale local export and wrong ACK identities leave frozen pending intact',
    () async {
      await stage(10);
      await sync.putObject(fence, hash, payload);
      await expectLater(
        sync.acknowledge(
          fence,
          rootId: uuid(10),
          commitId: uuid(90),
          revision: 1,
          successUtc: 1,
        ),
        throwsA(failure(FailureCode.conflict)),
      );
      await domain.write(SyncRepository.markDirty);
      await expectLater(stage(20), throwsA(failure(FailureCode.conflict)));
      expect(
        domain.read((records) => records.syncState.pendingCommitId),
        uuid(12),
      );
    },
  );
}
