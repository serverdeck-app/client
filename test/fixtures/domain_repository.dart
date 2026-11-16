import 'dart:async';

import 'package:serverdeck/storage/domain_repository.dart';
import 'package:serverdeck/storage/records.dart';

import 'fake_store_backend.dart' show copySettings, copySecurity;

/// Snapshot model for owner unit tests. Does not load an Isar engine.
final class MemoryDomain {
  SyncStateRecord syncState = SyncStateRecord();
  SyncSecretRecord syncSecrets = SyncSecretRecord();
  final syncRoots = <String, SyncRootRecord>{};
  final syncObjects = <String, SyncObjectRecord>{};
  AppSettings settings = AppSettings();
  SecurityState security = SecurityState()..protectedReceiptHmacKey = [1];
  final profiles = <String, Profile>{};
  final softwareCards = <String, SoftwareCardRecord>{};
  final softwareEvents = <String, SoftwareEventRecord>{};
  final journalSources = <String, JournalSource>{};
  final credentials = <String, Credential>{};
  final endpoints = <String, EndpointTrust>{};
  final grants = <String, McpGrant>{};
  final receipts = <(String, String), MutationReceipt>{};
  final histories = <String, MonitoringHistoryRecord>{};
  MemoryDomain clone({bool shareUnchangedRecords = false}) => MemoryDomain()
    ..syncState = copySyncState(syncState)
    ..syncSecrets = copySyncSecrets(syncSecrets)
    ..syncRoots.addAll(
      syncRoots.map(
        (key, value) =>
            MapEntry(key, shareUnchangedRecords ? value : copySyncRoot(value)),
      ),
    )
    ..syncObjects.addAll(
      syncObjects.map(
        (key, value) => MapEntry(
          key,
          shareUnchangedRecords ? value : copySyncObject(value),
        ),
      ),
    )
    ..softwareCards.addAll(
      softwareCards.map(
        (k, v) => MapEntry(k, shareUnchangedRecords ? v : copySoftwareCard(v)),
      ),
    )
    ..softwareEvents.addAll(
      softwareEvents.map(
        (k, v) => MapEntry(k, shareUnchangedRecords ? v : copySoftwareEvent(v)),
      ),
    )
    ..journalSources.addAll(
      journalSources.map(
        // putProfile resets journal state in place when the connection changes.
        (k, v) => MapEntry(k, copyJournalSource(v)),
      ),
    )
    ..settings = copySettings(settings)
    ..security = copySecurity(security)
    ..profiles.addAll(
      profiles.map(
        (k, v) => MapEntry(k, shareUnchangedRecords ? v : copyProfile(v)),
      ),
    )
    ..credentials.addAll(
      credentials.map(
        (k, v) => MapEntry(k, shareUnchangedRecords ? v : copyCredential(v)),
      ),
    )
    ..endpoints.addAll(
      endpoints.map(
        (k, v) => MapEntry(k, shareUnchangedRecords ? v : copyEndpoint(v)),
      ),
    )
    ..grants.addAll(
      grants.map(
        (k, v) => MapEntry(k, shareUnchangedRecords ? v : copyGrant(v)),
      ),
    )
    ..receipts.addAll(
      receipts.map(
        (k, v) => MapEntry(k, shareUnchangedRecords ? v : copyReceipt(v)),
      ),
    )
    ..histories.addAll(
      histories.map(
        (k, v) => MapEntry(k, shareUnchangedRecords ? v : copyHistory(v)),
      ),
    );
}

MonitoringHistoryRecord copyHistory(MonitoringHistoryRecord value) =>
    MonitoringHistoryRecord()
      ..id = value.id
      ..profileId = value.profileId
      ..connectionRevision = value.connectionRevision
      ..payload = value.payload;

final class MemoryDomainRepository implements DomainRepository {
  // Optional high-cardinality fixture mode. Containers/metadata still snapshot;
  // record getters and putters below always detach their values, retaining rollback.
  bool shareUnchangedRecords = false;
  final _changes = StreamController<void>.broadcast();
  @override
  Stream<void> get domainChanges => _changes.stream;
  @override
  void disposeNotifications() => unawaited(_changes.close());
  MemoryDomain state = MemoryDomain();
  MemoryDomain? _ambient;
  Future<void> _tail = Future.value();
  Future<void> Function()? beforeWrite;
  int? failAfterWrite;
  bool failCommit = false;
  int? receiptCountOverride;
  int committedWrites = 0;
  @override
  String? loadHistory(String id, int revision) => read((r) {
    final value = r.history(id);
    return value?.connectionRevision == revision ? value!.payload : null;
  });
  @override
  Future<void> saveHistory(
    String id,
    int revision,
    String payload,
    bool Function() canCommit,
  ) => write((r) {
    if (!canCommit() || r.profile(id)?.connectionRevision != revision) return;
    final value = r.history(id) ?? MonitoringHistoryRecord();
    value
      ..profileId = id
      ..connectionRevision = revision
      ..payload = payload;
    r.putHistory(value);
  });
  @override
  T read<T>(T Function(DomainRead) body) {
    final records = _MemoryRecords(
      _ambient ?? state,
      false,
      (_) {},
      receiptCountOverride,
    );
    try {
      return body(records);
    } finally {
      records.active = false;
    }
  }

  @override
  Future<T> write<T>(T Function(DomainTransaction) body) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        await beforeWrite?.call();
        final working = state.clone(
          shareUnchangedRecords: shareUnchangedRecords,
        );
        var writes = 0;
        final records = _MemoryRecords(working, true, (_) {
          writes++;
          if (writes == failAfterWrite)
            throw StateError('synthetic write fault');
        }, receiptCountOverride);
        _ambient = working;
        try {
          final value = body(records);
          if (value is Future)
            throw StateError('Expected synchronous transaction');
          if (failCommit) {
            failCommit = false;
            throw StateError('synthetic commit fault');
          }
          state = working;
          committedWrites++;
          if (records.domainChanged && !_changes.isClosed) _changes.add(null);
          result.complete(value);
        } finally {
          records.active = false;
          _ambient = null;
        }
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }
}

final class _MemoryRecords implements DomainTransaction {
  @override
  SyncStateRecord get syncState {
    check();
    return copySyncState(state.syncState);
  }

  @override
  SyncSecretRecord get syncSecrets {
    check();
    return copySyncSecrets(state.syncSecrets);
  }

  @override
  SyncRootRecord? syncRoot(String id) {
    check();
    final value = state.syncRoots[id];
    return value == null ? null : copySyncRoot(value);
  }

  @override
  List<SyncRootRecord> syncRoots() {
    check();
    return state.syncRoots.values.take(7).map(copySyncRoot).toList();
  }

  @override
  int syncRootCount() {
    check();
    return state.syncRoots.length;
  }

  @override
  SyncObjectRecord? syncObject(String key) {
    check();
    final value = state.syncObjects[key];
    return value == null ? null : copySyncObject(value);
  }

  @override
  int? syncObjectLength(String key) {
    check();
    final length = state.syncObjects[key]?.cipherLength;
    return length == 0 ? null : length;
  }

  @override
  int? syncObjectReservedLength(String key) {
    check();
    return state.syncObjects[key]?.reservedLength;
  }

  @override
  int syncReservedByteCount() {
    check();
    return state.syncObjects.values.fold<int>(
          0,
          (sum, value) => sum + value.reservedLength,
        ) +
        state.syncRoots.values.fold<int>(
          0,
          (sum, value) => sum + value.manifestLength,
        );
  }

  @override
  int syncMissingByteCount() {
    check();
    return state.syncObjects.values.fold<int>(
      0,
      (sum, value) => sum + value.reservedLength - value.cipherLength,
    );
  }

  @override
  int syncObjectPreparedLength(String key) {
    check();
    return state.syncObjects[key]?.preparedLength ?? 0;
  }

  @override
  List<String> syncObjectKeys({
    int offset = 0,
    int limit = 100,
    String? afterKey,
  }) {
    check();
    if (offset < 0 || limit < 1 || limit > 1000)
      throw ArgumentError('Invalid internal sync page');
    return (state.syncObjects.keys.toList()..sort())
        .where((key) => afterKey == null || key.compareTo(afterKey) > 0)
        .skip(offset)
        .take(limit)
        .toList();
  }

  @override
  int syncCipherByteCount() {
    check();
    return state.syncObjects.values.fold(
          0,
          (sum, value) => sum + value.cipherLength,
        ) +
        state.syncRoots.values.fold(
          0,
          (sum, value) => sum + value.manifestLength,
        );
  }

  @override
  int syncPreparedByteCount() {
    check();
    return state.syncObjects.values.fold(
      0,
      (sum, value) => sum + value.preparedLength,
    );
  }

  @override
  void putSyncState(SyncStateRecord value) {
    write('sync state');
    state.syncState = copySyncState(value);
  }

  @override
  void putSyncSecrets(SyncSecretRecord value) {
    write('sync secrets');
    state.syncSecrets = copySyncSecrets(value);
  }

  @override
  void putSyncRoot(SyncRootRecord value) {
    write('sync root');
    value.manifestLength = value.manifestCiphertext.length;
    state.syncRoots[value.rootId] = copySyncRoot(value);
  }

  @override
  void putSyncObject(SyncObjectRecord value) {
    write('sync object');
    value.cipherLength = value.cipherBytes.length;
    if (value.reservedLength < value.cipherLength)
      value.reservedLength = value.cipherLength;
    value.preparedLength = value.locallyPreparedCredential?.length ?? 0;
    state.syncObjects[value.objectKey] = copySyncObject(value);
  }

  @override
  void deleteSyncRoot(String id) {
    write('delete sync root');
    state.syncRoots.remove(id);
  }

  @override
  void deleteSyncObject(String key) {
    write('delete sync object');
    state.syncObjects.remove(key);
  }

  @override
  SoftwareCardRecord? softwareCard(String id) {
    check();
    final value = state.softwareCards[id];
    return value == null ? null : copySoftwareCard(value);
  }

  @override
  int softwareCardCount({String? profileId}) {
    check();
    return state.softwareCards.values
        .where((v) => profileId == null || v.profileId == profileId)
        .length;
  }

  @override
  List<SoftwareCardRecord> softwareCards(
    String profileId, {
    int offset = 0,
    int limit = 100,
  }) {
    check();
    final values =
        state.softwareCards.values
            .where((v) => v.profileId == profileId)
            .toList()
          ..sort((a, b) {
            final c = a.createdAt.compareTo(b.createdAt);
            return c == 0 ? a.softwareId.compareTo(b.softwareId) : c;
          });
    return values.skip(offset).take(limit).map(copySoftwareCard).toList();
  }

  @override
  List<SoftwareEventRecord> softwareEvents(
    String profileId, {
    String? softwareId,
    int offset = 0,
    int limit = 100,
  }) {
    check();
    final values =
        state.softwareEvents.values
            .where(
              (v) =>
                  v.profileId == profileId &&
                  (softwareId == null || v.softwareId == softwareId),
            )
            .toList()
          ..sort((a, b) {
            final c = b.createdAt.compareTo(a.createdAt);
            return c == 0 ? b.eventId.compareTo(a.eventId) : c;
          });
    return values.skip(offset).take(limit).map(copySoftwareEvent).toList();
  }

  @override
  int softwareEventCount() {
    check();
    return state.softwareEvents.length;
  }

  @override
  void putSoftwareCard(SoftwareCardRecord value) {
    write('software');
    state.softwareCards[value.softwareId] = copySoftwareCard(value);
    domainChanged = true;
  }

  @override
  void deleteSoftwareCard(String id) {
    write('delete software');
    if (state.softwareCards.remove(id) != null) domainChanged = true;
  }

  @override
  void putSoftwareEvent(SoftwareEventRecord value) {
    write('software event');
    state.softwareEvents[value.eventId] = copySoftwareEvent(value);
    domainChanged = true;
  }

  @override
  void pruneSoftwareEvents(int keep) {
    write('prune software events');
    final values = state.softwareEvents.values.toList()
      ..sort((a, b) {
        final c = a.createdAt.compareTo(b.createdAt);
        return c == 0 ? a.eventId.compareTo(b.eventId) : c;
      });
    for (final v in values.take(
      values.length > keep ? values.length - keep : 0,
    )) {
      state.softwareEvents.remove(v.eventId);
      domainChanged = true;
    }
  }

  @override
  List<JournalSource> journalSources() {
    check();
    return state.journalSources.values.map(copyJournalSource).toList();
  }

  @override
  JournalSource? journalSource(String id) {
    check();
    final v = state.journalSources[id];
    return v == null ? null : copyJournalSource(v);
  }

  @override
  void putJournalSource(JournalSource v) {
    write('journal');
    state.journalSources[v.sourceId] = copyJournalSource(v);
  }

  @override
  void deleteJournalSource(String id) {
    write('delete journal');
    state.journalSources.remove(id);
  }

  _MemoryRecords(
    this.state,
    this.writable,
    this.touch,
    this.receiptCountOverride,
  );
  final MemoryDomain state;
  final bool writable;
  final void Function(String) touch;
  final int? receiptCountOverride;
  bool active = true;
  bool domainChanged = false;
  @override
  MonitoringHistoryRecord? history(String id) {
    check();
    final value = state.histories[id];
    return value == null ? null : copyHistory(value);
  }

  @override
  void putHistory(MonitoringHistoryRecord value) {
    write('history');
    state.histories[value.profileId] = copyHistory(value);
  }

  void check() {
    if (!active) throw StateError('Expired record view');
  }

  void write(String kind) {
    check();
    if (!writable) throw StateError('Read-only record view');
    touch(kind);
  }

  @override
  AppSettings get settings {
    check();
    return copySettings(state.settings);
  }

  @override
  SecurityState get security {
    check();
    return copySecurity(state.security);
  }

  @override
  List<Profile> profiles() {
    check();
    return state.profiles.values.map(copyProfile).toList();
  }

  @override
  Profile? profile(String id) {
    check();
    final p = state.profiles[id];
    return p == null ? null : copyProfile(p);
  }

  @override
  Credential? credential(String id) {
    check();
    final c = state.credentials[id];
    return c == null ? null : copyCredential(c);
  }

  @override
  EndpointTrust? endpoint(String id) {
    check();
    final e = state.endpoints[id];
    return e == null ? null : copyEndpoint(e);
  }

  @override
  McpGrant? grant(String id) {
    check();
    final g = state.grants[id];
    return g == null ? null : copyGrant(g);
  }

  @override
  List<McpGrant> grants() {
    check();
    return state.grants.values.map(copyGrant).toList();
  }

  @override
  MutationReceipt? receipt(String clientId, String mutationId) {
    check();
    final r = state.receipts[(clientId, mutationId)];
    return r == null ? null : copyReceipt(r);
  }

  @override
  List<MutationReceipt> receipts() {
    check();
    return state.receipts.values.map(copyReceipt).toList();
  }

  @override
  int unexpiredReceiptCount(int now) {
    check();
    return receiptCountOverride ??
        state.receipts.values.where((r) => r.expiresAt > now).length;
  }

  @override
  int pruneExpiredReceipts(int now) {
    final expired = state.receipts.entries
        .where((e) => e.value.expiresAt <= now)
        .map((e) => e.key)
        .toList();
    if (expired.isNotEmpty) {
      write('prune receipts');
      for (final key in expired) {
        state.receipts.remove(key);
      }
    }
    return expired.length;
  }

  @override
  void putSettings(AppSettings v) {
    write('settings');
    state.settings = copySettings(v);
  }

  @override
  void putSecurity(SecurityState v) {
    write('security');
    state.security = copySecurity(v);
  }

  @override
  void putProfile(Profile v) {
    write('profile');
    domainChanged = true;
    final oldJournalProfile = state.profiles[v.profileId];
    if (oldJournalProfile != null &&
        oldJournalProfile.connectionRevision != v.connectionRevision) {
      for (final source in state.journalSources.values.where(
        (s) => s.profileId == v.profileId,
      )) {
        source.connectionRevision = v.connectionRevision;
        source.payload =
            '{"version":1,"checkpoint":{},"entries":[],"partial":true}';
      }
    }
    final previous = state.profiles[v.profileId];
    if (previous != null &&
        previous.connectionRevision != v.connectionRevision) {
      state.histories.remove(v.profileId);
    }
    if (state.profiles.containsKey(v.profileId) &&
        state.profiles[v.profileId]!.id != v.id)
      throw StateError('duplicate profile');
    state.profiles[v.profileId] = copyProfile(v);
  }

  @override
  void putCredential(Credential v) {
    write('credential');
    if (state.credentials.values.any(
      (c) => c.profileId == v.profileId && c.credentialId != v.credentialId,
    ))
      throw StateError('duplicate profile credential');
    state.credentials[v.credentialId] = copyCredential(v);
  }

  @override
  void putEndpoint(EndpointTrust v) {
    write('endpoint');
    state.endpoints[v.endpointId] = copyEndpoint(v);
  }

  @override
  void putGrant(McpGrant v) {
    write('grant');
    state.grants[v.clientId] = copyGrant(v);
  }

  @override
  void putReceipt(MutationReceipt v) {
    write('receipt');
    if (state.receipts.containsKey((v.clientId, v.mutationId)))
      throw StateError('duplicate receipt');
    state.receipts[(v.clientId, v.mutationId)] = copyReceipt(v);
  }

  @override
  void deleteProfile(String id) {
    write('delete profile');
    final cards = state.softwareCards.length,
        events = state.softwareEvents.length;
    state.softwareCards.removeWhere((_, v) => v.profileId == id);
    state.softwareEvents.removeWhere((_, v) => v.profileId == id);
    state.journalSources.removeWhere((_, s) => s.profileId == id);
    state.histories.remove(id);
    if (state.profiles.remove(id) != null ||
        cards != state.softwareCards.length ||
        events != state.softwareEvents.length)
      domainChanged = true;
  }

  @override
  void deleteCredential(String id) {
    write('delete credential');
    state.credentials.remove(id);
  }

  @override
  void deleteEndpoint(String id) {
    write('delete endpoint');
    state.endpoints.remove(id);
  }

  @override
  void deleteReceipt(String clientId, String mutationId) {
    write('delete receipt');
    state.receipts.remove((clientId, mutationId));
  }
}

Profile copyProfile(Profile p) => Profile()
  ..id = p.id
  ..profileId = p.profileId
  ..profileRevision = p.profileRevision
  ..connectionRevision = p.connectionRevision
  ..displayName = p.displayName
  ..normalizedHost = p.normalizedHost
  ..originalHost = p.originalHost
  ..port = p.port
  ..username = p.username
  ..authKind = p.authKind
  ..credentialId = p.credentialId
  ..syncAutoBlocked = p.syncAutoBlocked
  ..endpointId = p.endpointId
  ..createdAt = p.createdAt
  ..updatedAt = p.updatedAt;

SyncStateRecord copySyncState(SyncStateRecord value) => SyncStateRecord()
  ..id = value.id
  ..serviceOrigin = value.serviceOrigin
  ..accountId = value.accountId
  ..deviceId = value.deviceId
  ..vaultId = value.vaultId
  ..identityGeneration = value.identityGeneration
  ..syncGeneration = value.syncGeneration
  ..ackGeneration = value.ackGeneration
  ..baseRevision = value.baseRevision
  ..baseRootId = value.baseRootId
  ..pendingRootId = value.pendingRootId
  ..pendingCommitId = value.pendingCommitId
  ..pendingUploadId = value.pendingUploadId
  ..pendingUploadDeviceId = value.pendingUploadDeviceId
  ..pendingUploadRetiring = value.pendingUploadRetiring
  ..candidateRootId = value.candidateRootId
  ..conflictLocalId = value.conflictLocalId
  ..conflictRemoteId = value.conflictRemoteId
  ..lastSuccessUtc = value.lastSuccessUtc
  ..errorCode = value.errorCode
  ..enabled = value.enabled;

SyncSecretRecord copySyncSecrets(SyncSecretRecord value) => SyncSecretRecord()
  ..id = value.id
  ..protectedAccess = value.protectedAccess == null
      ? null
      : [...value.protectedAccess!]
  ..protectedRefresh = value.protectedRefresh == null
      ? null
      : [...value.protectedRefresh!]
  ..protectedStatusProof = value.protectedStatusProof == null
      ? null
      : [...value.protectedStatusProof!]
  ..protectedVaultRootKey = value.protectedVaultRootKey == null
      ? null
      : [...value.protectedVaultRootKey!];

SyncRootRecord copySyncRoot(SyncRootRecord value) => SyncRootRecord()
  ..id = value.id
  ..rootId = value.rootId
  ..serviceOrigin = value.serviceOrigin
  ..accountId = value.accountId
  ..vaultId = value.vaultId
  ..snapshotId = value.snapshotId
  ..remoteRevision = value.remoteRevision
  ..role = value.role
  ..manifestCiphertext = [...value.manifestCiphertext]
  ..manifestLength = value.manifestLength
  ..objectHashes = [...value.objectHashes]
  ..objectLengths = [...value.objectLengths]
  ..sourceGeneration = value.sourceGeneration
  ..createdAt = value.createdAt;

SyncObjectRecord copySyncObject(SyncObjectRecord value) => SyncObjectRecord()
  ..id = value.id
  ..objectKey = value.objectKey
  ..serviceOrigin = value.serviceOrigin
  ..accountId = value.accountId
  ..vaultId = value.vaultId
  ..sha256 = value.sha256
  ..cipherBytes = [...value.cipherBytes]
  ..cipherLength = value.cipherLength
  ..reservedLength = value.reservedLength
  ..locallyPreparedCredential = value.locallyPreparedCredential == null
      ? null
      : [...value.locallyPreparedCredential!]
  ..preparedLength = value.preparedLength
  ..preparedCredentialId = value.preparedCredentialId
  ..preparedAgainstGeneration = value.preparedAgainstGeneration;
Credential copyCredential(Credential c) => Credential()
  ..id = c.id
  ..credentialId = c.credentialId
  ..profileId = c.profileId
  ..kind = c.kind
  ..protectedBytes = [...c.protectedBytes]
  ..publicKeyType = c.publicKeyType
  ..publicKeyBits = c.publicKeyBits
  ..publicKeyBytes = c.publicKeyBytes == null ? null : [...c.publicKeyBytes!]
  ..secretRevision = c.secretRevision;
EndpointTrust copyEndpoint(EndpointTrust e) => EndpointTrust()
  ..id = e.id
  ..endpointId = e.endpointId
  ..normalizedHost = e.normalizedHost
  ..port = e.port
  ..trustRevision = e.trustRevision
  ..observationRevision = e.observationRevision
  ..acceptedKeyBytes = e.acceptedKeyBytes?.toList()
  ..acceptedType = e.acceptedType
  ..acceptedFingerprint = e.acceptedFingerprint
  ..acceptedAt = e.acceptedAt
  ..changed = e.changed
  ..observedKeyBytes = e.observedKeyBytes?.toList()
  ..observedType = e.observedType
  ..observedFingerprint = e.observedFingerprint
  ..detectedAt = e.detectedAt
  ..lastSeenAt = e.lastSeenAt
  ..profileRefCount = e.profileRefCount;
McpGrant copyGrant(McpGrant g) => McpGrant()
  ..id = g.id
  ..clientId = g.clientId
  ..name = g.name
  ..grantVersion = g.grantVersion
  ..authorizationEpoch = g.authorizationEpoch
  ..protectedSecret = [...g.protectedSecret]
  ..createdAt = g.createdAt
  ..expiresAt = g.expiresAt
  ..revokedAt = g.revokedAt
  ..ownerUserSid = g.ownerUserSid
  ..exportPending = g.exportPending;
MutationReceipt copyReceipt(MutationReceipt r) => MutationReceipt()
  ..id = r.id
  ..clientId = r.clientId
  ..mutationId = r.mutationId
  ..method = r.method
  ..payloadHmac = [...r.payloadHmac]
  ..createdAt = r.createdAt
  ..expiresAt = r.expiresAt
  ..resultCode = r.resultCode
  ..entityIds = [...r.entityIds]
  ..entityRevisions = [...r.entityRevisions]
  ..committedDataRevision = r.committedDataRevision;

JournalSource copyJournalSource(JournalSource v) => JournalSource()
  ..id = v.id
  ..sourceId = v.sourceId
  ..profileId = v.profileId
  ..connectionRevision = v.connectionRevision
  ..kind = v.kind
  ..target = v.target
  ..name = v.name
  ..enabled = v.enabled
  ..payload = v.payload;

SoftwareCardRecord copySoftwareCard(SoftwareCardRecord v) =>
    SoftwareCardRecord()
      ..id = v.id
      ..softwareId = v.softwareId
      ..profileId = v.profileId
      ..endpointId = v.endpointId
      ..host = v.host
      ..port = v.port
      ..username = v.username
      ..name = v.name
      ..version = v.version
      ..service = v.service
      ..dataPaths = List.of(v.dataPaths)
      ..configPaths = List.of(v.configPaths)
      ..updateInstructions = v.updateInstructions
      ..revision = v.revision
      ..createdAt = v.createdAt
      ..updatedAt = v.updatedAt;

SoftwareEventRecord copySoftwareEvent(SoftwareEventRecord v) =>
    SoftwareEventRecord()
      ..id = v.id
      ..eventId = v.eventId
      ..profileId = v.profileId
      ..endpointId = v.endpointId
      ..host = v.host
      ..port = v.port
      ..username = v.username
      ..softwareId = v.softwareId
      ..softwareName = v.softwareName
      ..kind = v.kind
      ..action = v.action
      ..summary = v.summary
      ..outcome = v.outcome
      ..changedFields = List.of(v.changedFields)
      ..actorKind = v.actorKind
      ..clientId = v.clientId
      ..createdAt = v.createdAt;
