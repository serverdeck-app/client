import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/storage/records.dart';

import '../fixtures/domain_repository.dart';

void main() {
  test(
    'sync metadata commits with local data and abort preserves both',
    () async {
      final repository = MemoryDomainRepository();
      await repository.write((records) {
        records.putProfile(Profile()..profileId = 'local');
        records.putSyncState(SyncStateRecord()..syncGeneration = 1);
      });
      repository.failCommit = true;
      await expectLater(
        repository.write((records) {
          final profile = records.profile('local')!;
          profile.syncAutoBlocked = true;
          records.putProfile(profile);
          final sync = records.syncState;
          sync.syncGeneration++;
          records.putSyncState(sync);
        }),
        throwsStateError,
      );
      repository.read((records) {
        expect(records.syncState.syncGeneration, 1);
        expect(records.profile('local')!.syncAutoBlocked, isFalse);
      });
      await repository.write((records) {
        final profile = records.profile('local')!..syncAutoBlocked = true;
        records.putProfile(profile);
        final sync = records.syncState;
        sync.syncGeneration++;
        records.putSyncState(sync);
      });
      repository.read((records) {
        expect(records.syncState.syncGeneration, 2);
        expect(records.profile('local')!.syncAutoBlocked, isTrue);
      });
    },
  );

  test('protected auth and binding cannot be persisted partially', () async {
    final repository = MemoryDomainRepository()..failAfterWrite = 2;
    await expectLater(
      repository.write((records) {
        records.putSyncState(SyncStateRecord()..accountId = 'account');
        records.putSyncSecrets(SyncSecretRecord()..protectedAccess = [1, 2]);
      }),
      throwsStateError,
    );
    repository.read((records) {
      expect(records.syncState.accountId, isNull);
      expect(records.syncSecrets.protectedAccess, isNull);
    });
  });

  test('stored ciphertext and protected buffers never alias callers', () async {
    final repository = MemoryDomainRepository();
    final object = SyncObjectRecord()
      ..objectKey = 'opaque-object-key'
      ..cipherBytes = [1, 2, 3]
      ..locallyPreparedCredential = [4, 5]
      ..cipherLength = 999;
    final secret = SyncSecretRecord()..protectedVaultRootKey = [6, 7];
    await repository.write((records) {
      records.putSyncObject(object);
      records.putSyncSecrets(secret);
    });
    object.cipherBytes[0] = 99;
    secret.protectedVaultRootKey![0] = 99;
    repository.read((records) {
      final copy = records.syncObject(object.objectKey)!;
      expect(copy.cipherBytes, [1, 2, 3]);
      expect(copy.locallyPreparedCredential, [4, 5]);
      expect(records.syncCipherByteCount(), 3);
      expect(records.syncPreparedByteCount(), 2);
      copy.cipherBytes[0] = 88;
      copy.locallyPreparedCredential![0] = 88;
      records.syncSecrets.protectedVaultRootKey![0] = 88;
    });
    repository.read((records) {
      expect(records.syncObject(object.objectKey)!.cipherBytes, [1, 2, 3]);
      expect(records.syncObject(object.objectKey)!.locallyPreparedCredential, [
        4,
        5,
      ]);
      expect(records.syncSecrets.protectedVaultRootKey, [6, 7]);
    });
  });

  test(
    'root and object metadata survive other domain writes independently',
    () async {
      final repository = MemoryDomainRepository();
      await repository.write((records) {
        records.putSyncRoot(
          SyncRootRecord()
            ..rootId = 'root'
            ..role = 'pending'
            ..manifestCiphertext = [1, 2]
            ..objectHashes = ['digest'],
        );
        records.putSyncState(
          SyncStateRecord()
            ..pendingRootId = 'root'
            ..pendingCommitId = 'immutable-commit',
        );
      });
      await repository.write((records) {
        final settings = records.settings;
        settings.dataRevision++;
        records.putSettings(settings);
      });
      repository.read((records) {
        expect(records.syncState.pendingCommitId, 'immutable-commit');
        expect(records.syncRoot('root')!.role, 'pending');
        expect(records.syncRoot('root')!.manifestCiphertext, [1, 2]);
        expect(records.syncCipherByteCount(), 2);
        records.syncRoot('root')!.objectHashes.clear();
      });
      expect(
        repository.read((records) => records.syncRoot('root')!.objectHashes),
        ['digest'],
      );
    },
  );
}
