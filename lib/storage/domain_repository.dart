import 'dart:async';

import 'package:isar_community/isar.dart';

import '../domain/models.dart';
import '../monitoring/monitoring_history.dart';
import 'records.dart';
import 'workspace_store.dart';

/// Root/owners only. Returned records are detached; none is a public projection.
abstract interface class DomainRead {
  SyncStateRecord get syncState;
  SyncSecretRecord get syncSecrets;
  SyncRootRecord? syncRoot(String rootId);
  List<SyncRootRecord> syncRoots();
  int syncRootCount();
  SyncObjectRecord? syncObject(String objectKey);
  int? syncObjectLength(String objectKey);
  int? syncObjectReservedLength(String objectKey);
  int syncObjectPreparedLength(String objectKey);
  List<String> syncObjectKeys({
    int offset = 0,
    int limit = 100,
    String? afterKey,
  });
  int syncCipherByteCount();
  int syncPreparedByteCount();
  int syncReservedByteCount();
  int syncMissingByteCount();
  SoftwareCardRecord? softwareCard(String softwareId);
  int softwareCardCount({String? profileId});
  List<SoftwareCardRecord> softwareCards(
    String profileId, {
    int offset = 0,
    int limit = 100,
  });
  List<SoftwareEventRecord> softwareEvents(
    String profileId, {
    String? softwareId,
    int offset = 0,
    int limit = 100,
  });
  int softwareEventCount();
  List<JournalSource> journalSources();
  JournalSource? journalSource(String sourceId);
  AppSettings get settings;
  SecurityState get security;
  List<Profile> profiles();
  Profile? profile(String profileId);
  Credential? credential(String credentialId);
  EndpointTrust? endpoint(String endpointId);
  McpGrant? grant(String clientId);
  List<McpGrant> grants();
  MutationReceipt? receipt(String clientId, String mutationId);
  List<MutationReceipt> receipts();
  int unexpiredReceiptCount(int utcNow);
  MonitoringHistoryRecord? history(String profileId);
}

abstract interface class DomainTransaction implements DomainRead {
  void putSyncState(SyncStateRecord value);
  void putSyncSecrets(SyncSecretRecord value);
  void putSyncRoot(SyncRootRecord value);
  void putSyncObject(SyncObjectRecord value);
  void deleteSyncRoot(String rootId);
  void deleteSyncObject(String objectKey);
  void putSoftwareCard(SoftwareCardRecord value);
  void deleteSoftwareCard(String softwareId);
  void putSoftwareEvent(SoftwareEventRecord value);
  void pruneSoftwareEvents(int keep);
  void putJournalSource(JournalSource value);
  void deleteJournalSource(String sourceId);
  void putSettings(AppSettings value);
  void putSecurity(SecurityState value);
  void putProfile(Profile value);
  void putCredential(Credential value);
  void putEndpoint(EndpointTrust value);
  void putGrant(McpGrant value);
  void putReceipt(MutationReceipt value);
  void deleteProfile(String profileId);
  void deleteCredential(String credentialId);
  void deleteEndpoint(String endpointId);
  void deleteReceipt(String clientId, String mutationId);
  int pruneExpiredReceipts(int utcNow);
  void putHistory(MonitoringHistoryRecord value);
}

abstract interface class DomainRepository implements MonitoringHistoryStore {
  /// One asynchronous invalidation after a committed profile/card/event write.
  /// No record values or credentials; rollback and metadata-only writes emit none.
  Stream<void> get domainChanges;
  void disposeNotifications();
  T read<T>(T Function(DomainRead records) body);
  Future<T> write<T>(T Function(DomainTransaction records) body);
}

/// Uses the existing single WorkspaceStore; no cache, second DB or direct open.
final class WorkspaceDomainRepository implements DomainRepository {
  WorkspaceDomainRepository(this.store);
  final WorkspaceStore store;
  final _changes = StreamController<void>.broadcast();
  @override
  Stream<void> get domainChanges => _changes.stream;
  @override
  void disposeNotifications() => unawaited(_changes.close());
  @override
  String? loadHistory(String id, int revision) => read((records) {
    final value = records.history(id);
    return value?.connectionRevision == revision ? value!.payload : null;
  });
  @override
  Future<void> saveHistory(
    String id,
    int revision,
    String payload,
    bool Function() canCommit,
  ) => write((records) {
    if (!canCommit() || records.profile(id)?.connectionRevision != revision) {
      return;
    }
    final value = records.history(id) ?? MonitoringHistoryRecord();
    value
      ..profileId = id
      ..connectionRevision = revision
      ..payload = payload;
    records.putHistory(value);
  });
  @override
  T read<T>(T Function(DomainRead records) body) =>
      store.readSync((db) => body(_IsarRecords(db)));
  @override
  Future<T> write<T>(T Function(DomainTransaction records) body) async {
    _IsarRecords? transaction;
    final result = await store.write((db) {
      transaction = _IsarRecords(db);
      return body(transaction!);
    });
    if (transaction!.domainChanged && !_changes.isClosed) _changes.add(null);
    return result;
  }
}

final class _IsarRecords implements DomainTransaction {
  _IsarRecords(this.db);
  final Isar db;
  bool domainChanged = false;
  @override
  SyncStateRecord get syncState =>
      db.syncStateRecords.getSync(1) ?? SyncStateRecord();
  @override
  SyncSecretRecord get syncSecrets =>
      db.syncSecretRecords.getSync(1) ?? SyncSecretRecord();
  @override
  SyncRootRecord? syncRoot(String id) => db.syncRootRecords.getByRootIdSync(id);
  @override
  List<SyncRootRecord> syncRoots() =>
      db.syncRootRecords.where().limit(7).findAllSync();
  @override
  int syncRootCount() => db.syncRootRecords.countSync();
  @override
  SyncObjectRecord? syncObject(String key) =>
      db.syncObjectRecords.getByObjectKeySync(key);
  @override
  int? syncObjectLength(String key) {
    final length = db.syncObjectRecords
        .where()
        .objectKeyEqualTo(key)
        .cipherLengthProperty()
        .findFirstSync();
    return length == 0 ? null : length;
  }

  @override
  int? syncObjectReservedLength(String key) => db.syncObjectRecords
      .where()
      .objectKeyEqualTo(key)
      .reservedLengthProperty()
      .findFirstSync();
  @override
  int syncObjectPreparedLength(String key) =>
      db.syncObjectRecords
          .where()
          .objectKeyEqualTo(key)
          .preparedLengthProperty()
          .findFirstSync() ??
      0;
  @override
  List<String> syncObjectKeys({
    int offset = 0,
    int limit = 100,
    String? afterKey,
  }) {
    if (offset < 0 || limit < 1 || limit > 1000)
      throw ArgumentError('Invalid internal sync page');
    return db.syncObjectRecords
        .filter()
        .objectKeyGreaterThan(afterKey ?? '')
        .sortByObjectKey()
        .offset(offset)
        .limit(limit)
        .objectKeyProperty()
        .findAllSync();
  }

  @override
  int syncCipherByteCount() =>
      db.syncObjectRecords.where().cipherLengthProperty().sumSync() +
      db.syncRootRecords.where().manifestLengthProperty().sumSync();
  @override
  int syncPreparedByteCount() =>
      db.syncObjectRecords.where().preparedLengthProperty().sumSync();
  @override
  int syncReservedByteCount() =>
      db.syncObjectRecords.where().reservedLengthProperty().sumSync() +
      db.syncRootRecords.where().manifestLengthProperty().sumSync();
  @override
  int syncMissingByteCount() =>
      db.syncObjectRecords.where().reservedLengthProperty().sumSync() -
      db.syncObjectRecords.where().cipherLengthProperty().sumSync();
  @override
  void putSyncState(SyncStateRecord value) =>
      db.syncStateRecords.putSync(value);
  @override
  void putSyncSecrets(SyncSecretRecord value) =>
      db.syncSecretRecords.putSync(value);
  @override
  void putSyncRoot(SyncRootRecord value) {
    value.manifestLength = value.manifestCiphertext.length;
    db.syncRootRecords.putByRootIdSync(value);
  }

  @override
  void putSyncObject(SyncObjectRecord value) {
    value.cipherLength = value.cipherBytes.length;
    if (value.reservedLength < value.cipherLength)
      value.reservedLength = value.cipherLength;
    value.preparedLength = value.locallyPreparedCredential?.length ?? 0;
    db.syncObjectRecords.putByObjectKeySync(value);
  }

  @override
  void deleteSyncRoot(String id) => db.syncRootRecords.deleteByRootIdSync(id);
  @override
  void deleteSyncObject(String key) =>
      db.syncObjectRecords.deleteByObjectKeySync(key);
  @override
  SoftwareCardRecord? softwareCard(String id) =>
      db.softwareCardRecords.getBySoftwareIdSync(id);
  @override
  int softwareCardCount({String? profileId}) => profileId == null
      ? db.softwareCardRecords.countSync()
      : db.softwareCardRecords.where().profileIdEqualTo(profileId).countSync();
  @override
  List<SoftwareCardRecord> softwareCards(
    String profileId, {
    int offset = 0,
    int limit = 100,
  }) => db.softwareCardRecords
      .where()
      .profileIdEqualTo(profileId)
      .sortByCreatedAt()
      .thenBySoftwareId()
      .offset(offset)
      .limit(limit)
      .findAllSync();
  @override
  List<SoftwareEventRecord> softwareEvents(
    String profileId, {
    String? softwareId,
    int offset = 0,
    int limit = 100,
  }) {
    if (softwareId == null) {
      return db.softwareEventRecords
          .where()
          .profileIdEqualTo(profileId)
          .sortByCreatedAtDesc()
          .thenByEventIdDesc()
          .offset(offset)
          .limit(limit)
          .findAllSync();
    }
    return db.softwareEventRecords
        .where()
        .softwareIdEqualTo(softwareId)
        .filter()
        .profileIdEqualTo(profileId)
        .sortByCreatedAtDesc()
        .thenByEventIdDesc()
        .offset(offset)
        .limit(limit)
        .findAllSync();
  }

  @override
  int softwareEventCount() => db.softwareEventRecords.countSync();
  @override
  void putSoftwareCard(SoftwareCardRecord value) {
    db.softwareCardRecords.putSync(value);
    domainChanged = true;
  }

  @override
  void deleteSoftwareCard(String id) {
    if (db.softwareCardRecords.deleteBySoftwareIdSync(id)) domainChanged = true;
  }

  @override
  void putSoftwareEvent(SoftwareEventRecord value) {
    db.softwareEventRecords.putSync(value);
    domainChanged = true;
  }

  @override
  void pruneSoftwareEvents(int keep) {
    final excess = softwareEventCount() - keep;
    if (excess > 0) {
      db.softwareEventRecords
          .where()
          .sortByCreatedAt()
          .thenByEventId()
          .limit(excess)
          .deleteAllSync();
      domainChanged = true;
    }
  }

  @override
  List<JournalSource> journalSources() =>
      db.journalSources.where().findAllSync();
  @override
  JournalSource? journalSource(String sourceId) =>
      db.journalSources.getBySourceIdSync(sourceId);
  @override
  void putJournalSource(JournalSource value) {
    db.journalSources.putSync(value);
  }

  @override
  void deleteJournalSource(String sourceId) {
    db.journalSources.deleteBySourceIdSync(sourceId);
  }

  @override
  MonitoringHistoryRecord? history(String id) =>
      db.monitoringHistoryRecords.getByProfileIdSync(id);
  @override
  void putHistory(MonitoringHistoryRecord value) {
    db.monitoringHistoryRecords.putSync(value);
  }

  @override
  AppSettings get settings =>
      db.appSettings.getSync(1) ??
      (throw const OperationFailure(FailureCode.storageUnavailable));
  @override
  SecurityState get security =>
      db.securityStates.getSync(1) ??
      (throw const OperationFailure(FailureCode.storageUnavailable));
  @override
  List<Profile> profiles() => db.profiles.where().findAllSync();
  @override
  Profile? profile(String id) => db.profiles.getByProfileIdSync(id);
  @override
  Credential? credential(String id) => db.credentials.getByCredentialIdSync(id);
  @override
  EndpointTrust? endpoint(String id) =>
      db.endpointTrusts.getByEndpointIdSync(id);
  @override
  McpGrant? grant(String id) => db.mcpGrants.getByClientIdSync(id);
  @override
  List<McpGrant> grants() => db.mcpGrants.where().findAllSync();
  @override
  MutationReceipt? receipt(String clientId, String mutationId) =>
      db.mutationReceipts.getByClientIdMutationIdSync(clientId, mutationId);
  @override
  List<MutationReceipt> receipts() => db.mutationReceipts.where().findAllSync();
  @override
  int unexpiredReceiptCount(int utcNow) =>
      db.mutationReceipts.where().expiresAtGreaterThan(utcNow).countSync();
  @override
  int pruneExpiredReceipts(int utcNow) => db.mutationReceipts
      .where()
      .expiresAtLessThan(utcNow, include: true)
      .deleteAllSync();
  @override
  void putSettings(AppSettings v) {
    db.appSettings.putSync(v);
  }

  @override
  void putSecurity(SecurityState v) {
    db.securityStates.putSync(v);
  }

  @override
  void putProfile(Profile v) {
    final old = db.profiles.getByProfileIdSync(v.profileId);
    if (old != null && old.connectionRevision != v.connectionRevision) {
      db.monitoringHistoryRecords.deleteByProfileIdSync(v.profileId);
      for (final source
          in db.journalSources
              .where()
              .profileIdEqualTo(v.profileId)
              .findAllSync()) {
        source.connectionRevision = v.connectionRevision;
        source.payload =
            '{"version":1,"checkpoint":{},"entries":[],"partial":true}';
        db.journalSources.putSync(source);
      }
    }
    db.profiles.putSync(v);
    domainChanged = true;
  }

  @override
  void putCredential(Credential v) {
    db.credentials.putSync(v);
  }

  @override
  void putEndpoint(EndpointTrust v) {
    db.endpointTrusts.putSync(v);
  }

  @override
  void putGrant(McpGrant v) {
    db.mcpGrants.putSync(v);
  }

  @override
  void putReceipt(MutationReceipt v) {
    db.mutationReceipts.putSync(v);
  }

  @override
  void deleteProfile(String id) {
    final cards = db.softwareCardRecords
        .where()
        .profileIdEqualTo(id)
        .deleteAllSync();
    final events = db.softwareEventRecords
        .where()
        .profileIdEqualTo(id)
        .deleteAllSync();
    db.journalSources.where().profileIdEqualTo(id).deleteAllSync();
    db.monitoringHistoryRecords.deleteByProfileIdSync(id);
    if (db.profiles.deleteByProfileIdSync(id) || cards > 0 || events > 0)
      domainChanged = true;
  }

  @override
  void deleteCredential(String id) {
    db.credentials.deleteByCredentialIdSync(id);
  }

  @override
  void deleteEndpoint(String id) {
    db.endpointTrusts.deleteByEndpointIdSync(id);
  }

  @override
  void deleteReceipt(String clientId, String mutationId) {
    db.mutationReceipts.deleteByClientIdMutationIdSync(clientId, mutationId);
  }
}
