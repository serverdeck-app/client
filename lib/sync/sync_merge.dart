import 'dart:async';

import '../domain/models.dart';
import '../storage/domain_repository.dart';
import 'sync_apply.dart';
import 'sync_json.dart';
import 'sync_models.dart';
import 'sync_recovery.dart';
import 'sync_transport.dart';
import 'sync_wire.dart';

const _invalidMerge = OperationFailure(FailureCode.invalidArgument);
const _staleMerge = OperationFailure(FailureCode.conflict);
const _mergeLimit = OperationFailure(FailureCode.resourceExhausted);

enum SyncMergeChoice { automatic, local, server }

enum SyncMergeSource { local, server }

enum SyncMergeConflictKind {
  firstDifferentId,
  concurrentCreate,
  editEdit,
  deleteEdit,
  missingProfile,
  duplicateCredential,
  duplicateReference,
  limits,
}

final class SyncMergeConflict {
  const SyncMergeConflict(this.reason, {this.kind, this.id});
  final SyncMergeConflictKind reason;
  final String? kind, id;
}

final class SyncMergeCounts {
  const SyncMergeCounts(this.profiles, this.cards, this.legacyMetadataOnlyKeys);
  final int profiles, cards, legacyMetadataOnlyKeys;
}

final class SyncMergeChanges {
  const SyncMergeChanges(this.added, this.changed, this.removed);
  final SyncMergeCounts added, changed, removed;
}

final class _MergeRecord {
  const _MergeRecord(
    this.kind,
    this.id,
    this._semantic,
    this.bytes,
    this.profileId,
    this.credentialId,
    this.proof,
    this.cipherRef,
  );
  final String kind, id, _semantic;
  final int bytes;
  final String? profileId, credentialId;
  final SyncCredentialProof? proof;
  final SyncBlobRef? cipherRef;
  String get key => '$kind/$id';
}

/// Private native metadata index, no plaintext vault or public semantic digests.
final class SyncMergeSnapshot {
  SyncMergeSnapshot._(
    this.context,
    this.localFence,
    this.manifest,
    Map<String, _MergeRecord> records,
  ) : _records = Map.unmodifiable(records);
  final SyncVaultContext context;
  final SyncTransferSnapshot? localFence;
  final SyncManifest? manifest;
  final Map<String, _MergeRecord> _records;
  bool get isLocal => localFence != null;
  int get revision => manifest?.revision ?? 0;
  SyncMergeCounts get counts => _counts(_records.values);
}

/// Caller supplies authenticated/validated remote content and T012 proof for
/// profiles. Only IDs, private semantic hashes, relationships and refs survive.
final class SyncMergeSnapshotBuilder {
  SyncMergeSnapshotBuilder.local(SyncTransferSnapshot source)
    : context = source.context,
      localFence = source,
      manifest = null,
      _root = null;
  SyncMergeSnapshotBuilder.remote(
    this.context,
    PortableSyncRoot root,
    SyncManifest value,
  ) : localFence = null,
      manifest = value,
      _root = root {
    if (value.vaultId != context.fence.identity.vaultId) throw _invalidMerge;
    PortableSyncRoot.parse(
      root.toJson(),
      identity: context.fence.identity,
      snapshotId: value.snapshotId,
      revision: value.revision,
      publicObjects: value.objects,
      publicRoot: value.root,
    );
    for (final entry in root.entries) {
      _expected['${entry.kind}/${entry.id}'] = entry;
    }
  }
  SyncMergeSnapshotBuilder.emptyRemote(this.context)
    : localFence = null,
      manifest = null,
      _root = null;
  final SyncVaultContext context;
  final SyncTransferSnapshot? localFence;
  final SyncManifest? manifest;
  final PortableSyncRoot? _root;
  final _records = <String, _MergeRecord>{};
  final _expected = <String, SyncRootEntry>{};
  final _index = SyncContentIndex();
  bool _finished = false;
  void add(
    PortableSyncContent content, {
    SyncRootEntry? encryptedRef,
    SyncCredentialProof? proof,
  }) {
    if (_finished || localFence == null && _root == null) throw _invalidMerge;
    if (_records.length >= 11000) throw _mergeLimit;
    if (content is PortableSyncProfile) {
      if (proof == null ||
          (content.credentialKind == 'password') !=
              (proof == SyncCredentialProof.password))
        throw _invalidMerge;
    } else if (proof != null) {
      throw _invalidMerge;
    }
    final key = '${content.kind}/${content.id}';
    if (_records.containsKey(key)) throw _invalidMerge;
    if (localFence != null) {
      if (encryptedRef != null) throw _invalidMerge;
    } else {
      final expected = _expected[key];
      if (encryptedRef == null ||
          expected == null ||
          expected.kind != encryptedRef.kind ||
          expected.id != encryptedRef.id ||
          expected.sha256 != encryptedRef.sha256 ||
          expected.bytes != encryptedRef.bytes)
        throw _invalidMerge;
      _index.add(content, expected: encryptedRef);
    }
    final canonical = canonicalSyncJson(content.toJson());
    try {
      if (canonical.length + 28 > syncMaxObjectBytes) throw _mergeLimit;
      _records[key] = _MergeRecord(
        content.kind,
        content.id,
        syncSha256(canonical),
        canonical.length + 28,
        content is PortableSyncCard ? content.profileId : null,
        content is PortableSyncProfile ? content.credentialId : null,
        proof,
        encryptedRef == null
            ? null
            : SyncBlobRef(encryptedRef.sha256, encryptedRef.bytes),
      );
    } finally {
      canonical.fillRange(0, canonical.length, 0);
    }
  }

  SyncMergeSnapshot finish() {
    if (_finished) throw _invalidMerge;
    final conflicts = _graphConflicts(_records);
    if (conflicts.isNotEmpty)
      throw conflicts.any((c) => c.reason == SyncMergeConflictKind.limits)
          ? _mergeLimit
          : _invalidMerge;
    final root = _root;
    if (root != null) _index.finish(root);
    _finished = true;
    return SyncMergeSnapshot._(context, localFence, manifest, _records);
  }
}

SyncMergeCounts _counts(Iterable<_MergeRecord> records) {
  var profiles = 0, cards = 0, legacy = 0;
  for (final record in records) {
    if (record.kind == 'profile')
      profiles++;
    else
      cards++;
    if (record.proof == SyncCredentialProof.encryptedLegacyMetadataOnly)
      legacy++;
  }
  return SyncMergeCounts(profiles, cards, legacy);
}

bool _same(_MergeRecord? a, _MergeRecord? b) =>
    a == null ? b == null : b != null && a._semantic == b._semantic;
bool _sameSet(Map<String, _MergeRecord> a, Map<String, _MergeRecord> b) =>
    a.length == b.length &&
    a.entries.every((entry) => _same(entry.value, b[entry.key]));

List<SyncMergeConflict> _graphConflicts(Map<String, _MergeRecord> records) {
  final counts = _counts(records.values);
  if (counts.profiles > 1000 || counts.cards > 10000 || records.length > 11000)
    return [const SyncMergeConflict(SyncMergeConflictKind.limits)];
  final profiles = <String>{},
      credentials = <String>{},
      hashes = <String>{},
      cards = <String, int>{};
  final result = <SyncMergeConflict>[];
  var bytes = 0;
  for (final record in records.values) {
    bytes += record.bytes;
    if (record.kind == 'profile') {
      profiles.add(record.id);
      if (!credentials.add(record.credentialId!))
        result.add(
          SyncMergeConflict(
            SyncMergeConflictKind.duplicateCredential,
            kind: record.kind,
            id: record.id,
          ),
        );
    } else {
      cards.update(record.profileId!, (count) => count + 1, ifAbsent: () => 1);
    }
    if (record.cipherRef != null && !hashes.add(record.cipherRef!.sha256))
      result.add(
        SyncMergeConflict(
          SyncMergeConflictKind.duplicateReference,
          kind: record.kind,
          id: record.id,
        ),
      );
  }
  for (final record in records.values.where(
    (record) => record.kind == 'software',
  )) {
    if (!profiles.contains(record.profileId))
      result.add(
        SyncMergeConflict(
          SyncMergeConflictKind.missingProfile,
          kind: record.kind,
          id: record.id,
        ),
      );
  }
  if (cards.values.any((count) => count > 1000) || bytes > syncMaxHeadBytes)
    result.add(const SyncMergeConflict(SyncMergeConflictKind.limits));
  return result;
}

void _rootLimit(
  SyncVaultContext context,
  Map<String, _MergeRecord> records,
  int revision,
) {
  if (revision < 1 || revision > syncMaxInteger) throw _mergeLimit;
  final ordered = records.values.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  // Size calculation only: future snapshot UUID/hash fields have fixed ASCII
  // lengths. These placeholders are never encrypted, stored or sent as a root.
  final bytes = canonicalSyncJson({
    'version': 1,
    'accountId': context.fence.identity.accountId,
    'vaultId': context.fence.identity.vaultId,
    'snapshotId': '00000000-0000-4000-8000-000000000000',
    'revision': revision,
    'objects': ordered
        .map(
          (record) => {
            'kind': record.kind,
            'id': record.id,
            'sha256': record.cipherRef?.sha256 ?? '0' * 64,
            'bytes': record.bytes,
          },
        )
        .toList(),
  });
  try {
    if (bytes.length + 28 > syncMaxRootBytes ||
        ordered.fold(bytes.length + 28, (sum, record) => sum + record.bytes) >
            syncMaxHeadBytes)
      throw _mergeLimit;
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}

SyncMergeChanges _changes(
  Map<String, _MergeRecord> from,
  Map<String, _MergeRecord> to,
) => SyncMergeChanges(
  _counts(
    to.entries.where((e) => !from.containsKey(e.key)).map((e) => e.value),
  ),
  _counts(
    to.entries
        .where((e) => from.containsKey(e.key) && !_same(e.value, from[e.key]))
        .map((e) => e.value),
  ),
  _counts(
    from.entries.where((e) => !to.containsKey(e.key)).map((e) => e.value),
  ),
);

final class SyncMergeSelection {
  const SyncMergeSelection._(this._record, this.source);
  final _MergeRecord _record;
  final SyncMergeSource source;
  String get kind => _record.kind;
  String get id => _record.id;
  int get cipherBytes => _record.bytes;
  SyncBlobRef? get cipherRef => _record.cipherRef;
  SyncCredentialProof? get proof => _record.proof;
  bool matchesContent(PortableSyncContent content) {
    if (content.kind != kind || content.id != id) return false;
    final bytes = canonicalSyncJson(content.toJson());
    try {
      return bytes.length + 28 == cipherBytes &&
          syncSha256(bytes) == _record._semantic;
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }
}

final class SyncMergeTarget {
  SyncMergeTarget._(
    List<SyncMergeSelection> records,
    this.needsPublication,
    this.needsLocalApply,
  ) : records = List.unmodifiable(records);
  final List<SyncMergeSelection> records;
  final bool needsPublication, needsLocalApply;
}

final class SyncMergePlan {
  SyncMergePlan._(
    this.local,
    this.remote,
    this.base,
    this._automatic,
    this._sides,
    List<SyncMergeConflict> conflicts,
  ) : conflicts = List.unmodifiable(conflicts);
  final SyncMergeSnapshot local, remote;
  final SyncMergeSnapshot? base;
  final Map<String, _MergeRecord> _automatic;
  final Map<String, SyncMergeSource> _sides;
  final List<SyncMergeConflict> conflicts;
  bool get requiresConsent => base == null || conflicts.isNotEmpty;
  factory SyncMergePlan.build({
    required SyncMergeSnapshot local,
    required SyncMergeSnapshot remote,
    SyncMergeSnapshot? base,
  }) {
    if (!local.isLocal ||
        remote.isLocal ||
        base?.isLocal == true ||
        base != null && base.manifest == null)
      throw _invalidMerge;
    final identity = local.context.fence.identity;
    for (final snapshot in [remote, if (base != null) base]) {
      final other = snapshot.context.fence.identity;
      if (identity.serviceOrigin != other.serviceOrigin ||
          identity.accountId != other.accountId ||
          identity.vaultId != other.vaultId)
        throw _invalidMerge;
    }
    if (base != null && base.revision > remote.revision) throw _staleMerge;
    final keys = <String>{
      ...local._records.keys,
      ...remote._records.keys,
      ...?base?._records.keys,
    }.toList()..sort();
    final merged = <String, _MergeRecord>{},
        sides = <String, SyncMergeSource>{},
        conflicts = <SyncMergeConflict>[];
    for (final key in keys) {
      final l = local._records[key],
          r = remote._records[key],
          b = base?._records[key];
      _MergeRecord? chosen;
      SyncMergeSource? side;
      if (_same(l, r)) {
        chosen = r;
        side = SyncMergeSource.server;
      } else if (base == null) {
        if (l == null) {
          chosen = r;
          side = SyncMergeSource.server;
        } else if (r == null) {
          chosen = l;
          side = SyncMergeSource.local;
        } else {
          conflicts.add(
            SyncMergeConflict(
              SyncMergeConflictKind.firstDifferentId,
              kind: l.kind,
              id: l.id,
            ),
          );
        }
      } else if (_same(l, b)) {
        chosen = r;
        side = SyncMergeSource.server;
      } else if (_same(r, b)) {
        chosen = l;
        side = SyncMergeSource.local;
      } else {
        final value = l ?? r!;
        conflicts.add(
          SyncMergeConflict(
            l == null || r == null
                ? SyncMergeConflictKind.deleteEdit
                : b == null
                ? SyncMergeConflictKind.concurrentCreate
                : SyncMergeConflictKind.editEdit,
            kind: value.kind,
            id: value.id,
          ),
        );
      }
      if (chosen != null) {
        merged[key] = chosen;
        sides[key] = side!;
      }
    }
    if (conflicts.isEmpty) {
      conflicts.addAll(_graphConflicts(merged));
      if (conflicts.isEmpty) {
        try {
          _rootLimit(
            local.context,
            merged,
            remote.revision +
                (remote.manifest == null || !_sameSet(merged, remote._records)
                    ? 1
                    : 0),
          );
        } on OperationFailure {
          conflicts.add(const SyncMergeConflict(SyncMergeConflictKind.limits));
        }
      }
    }
    return SyncMergePlan._(
      local,
      remote,
      base,
      Map.unmodifiable(merged),
      Map.unmodifiable(sides),
      conflicts,
    );
  }
  SyncMergeTarget resolve(SyncMergeChoice choice) {
    if (choice == SyncMergeChoice.automatic && conflicts.isNotEmpty)
      throw _staleMerge;
    final records = switch (choice) {
      SyncMergeChoice.local => local._records,
      SyncMergeChoice.server => remote._records,
      SyncMergeChoice.automatic => _automatic,
    };
    final publish =
        remote.manifest == null || !_sameSet(records, remote._records);
    _rootLimit(local.context, records, remote.revision + (publish ? 1 : 0));
    final sorted = records.values.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return SyncMergeTarget._(
      sorted
          .map(
            (record) => SyncMergeSelection._(
              record,
              choice == SyncMergeChoice.local
                  ? SyncMergeSource.local
                  : choice == SyncMergeChoice.server
                  ? SyncMergeSource.server
                  : _sides[record.key]!,
            ),
          )
          .toList(),
      publish,
      !_sameSet(records, local._records),
    );
  }
}

/// Safe UI projection: counts/IDs/reasons, no content values or semantic hashes.
final class SyncMergePreview {
  SyncMergePreview._(SyncMergePlan plan, {required this.baseUnavailable})
    : local = plan.local.counts,
      server = plan.remote.counts,
      merged = plan.conflicts.isEmpty ? _counts(plan._automatic.values) : null,
      automaticChanges = plan.conflicts.isEmpty
          ? _changes(plan.local._records, plan._automatic)
          : null,
      serverChanges = _changes(plan.local._records, plan.remote._records),
      conflicts = plan.conflicts,
      remoteRevision = plan.remote.revision,
      requiresConsent = plan.requiresConsent;
  final SyncMergeCounts local, server;
  final SyncMergeCounts? merged;
  final SyncMergeChanges? automaticChanges;
  final SyncMergeChanges serverChanges;
  final List<SyncMergeConflict> conflicts;
  final int remoteRevision;
  final bool requiresConsent, baseUnavailable;
}

enum SyncMergePhase { idle, checking, preview, executing, stale, error }

final class SyncMergeView {
  const SyncMergeView(this.phase, {this.preview, this.errorCode});
  final SyncMergePhase phase;
  final SyncMergePreview? preview;
  final String? errorCode;
}

/// Single-use native execution scope. Check inside the actual freeze/apply write;
/// after freezing, publication uses durable immutable pending-intent fences (T013).
final class SyncMergeAuthorization {
  SyncMergeAuthorization._(
    this.source,
    this.remoteManifest,
    this.target,
    this.cancellation,
    this._guard,
  );
  final SyncTransferSnapshot source;
  final SyncManifest? remoteManifest;
  final SyncMergeTarget target;
  final SyncCancellation cancellation;
  final void Function() _guard;
  bool _active = true;
  void check() {
    if (!_active) throw const SyncTransportCancelled();
    _guard();
  }

  bool isCurrent() {
    try {
      check();
      return true;
    } catch (_) {
      return false;
    }
  }
}

final class SyncMergeController {
  SyncMergeController({
    required this.repository,
    required this.access,
    required this.keyReady,
  });
  final DomainRepository repository;
  final SyncVaultAccess access;
  final bool Function() keyReady;
  final _changes = StreamController<SyncMergeView>.broadcast();
  SyncMergeView _view = const SyncMergeView(SyncMergePhase.idle);
  SyncMergeView get view => _view;
  Stream<SyncMergeView> get changes => _changes.stream;
  SyncMergePlan? _plan;
  SyncMergePreview? _preview;
  SyncCancellation _cancel = SyncCancellation();
  int _generation = 0;
  bool _disposed = false, _consumed = false, _executing = false;
  void _emit(SyncMergePhase phase, {SyncMergePreview? preview, String? error}) {
    if (_disposed) return;
    _view = SyncMergeView(phase, preview: preview, errorCode: error);
    _changes.add(_view);
  }

  void cancel() {
    _generation++;
    _cancel.cancel();
    _cancel = SyncCancellation();
    _plan = null;
    _preview = null;
    _consumed = false;
    _emit(SyncMergePhase.idle);
  }

  void dispose() {
    if (_disposed) return;
    cancel();
    _disposed = true;
    unawaited(_changes.close());
  }

  void _ownerGuard(int generation, SyncTransferSnapshot source) {
    if (_disposed || generation != _generation || _cancel.cancelled)
      throw const SyncTransportCancelled();
    access.guardVaultContext(source.context);
  }

  void _guard(int generation, SyncTransferSnapshot source) {
    _ownerGuard(generation, source);
    if (!repository.read(
      (r) =>
          r.settings.dataRevision == source.dataRevision &&
          r.syncState.syncGeneration == source.syncGeneration,
    ))
      throw _staleMerge;
  }

  bool _headMatches(SyncMergeSnapshot remote, SyncHead head) {
    if (head.vaultId != remote.context.fence.identity.vaultId ||
        head.revision != remote.revision ||
        head.revision < repository.read((r) => r.syncState.baseRevision))
      return false;
    final a = remote.manifest, b = head.manifest;
    if (a == null || b == null) return a == null && b == null;
    if (a.snapshotId != b.snapshotId ||
        a.root.sha256 != b.root.sha256 ||
        a.root.bytes != b.root.bytes ||
        a.objects.length != b.objects.length)
      return false;
    for (var i = 0; i < a.objects.length; i++) {
      if (a.objects[i].sha256 != b.objects[i].sha256 ||
          a.objects[i].bytes != b.objects[i].bytes)
        return false;
    }
    return true;
  }

  Future<SyncMergePreview> propose({
    required SyncMergeSnapshot local,
    required SyncMergeSnapshot remote,
    SyncMergeSnapshot? base,
  }) async {
    if (_disposed) throw const SyncTransportCancelled();
    cancel();
    final generation = _generation;
    final source = local.localFence;
    if (source == null) throw _invalidMerge;
    _guard(generation, source);
    access.guardVaultContext(remote.context);
    if (base != null) access.guardVaultContext(base.context);
    _emit(SyncMergePhase.checking);
    try {
      final plan = SyncMergePlan.build(
        local: local,
        remote: remote,
        base: base,
      );
      final head = await access.readVaultHead(source.context, _cancel);
      _guard(generation, source);
      if (!_headMatches(remote, head)) throw _staleMerge;
      final missingBase =
          base == null && repository.read((r) => r.syncState.baseRevision) > 0;
      final preview = SyncMergePreview._(plan, baseUnavailable: missingBase);
      _plan = plan;
      _preview = preview;
      _emit(SyncMergePhase.preview, preview: preview);
      return preview;
    } catch (error) {
      if (!_disposed && generation == _generation)
        _emit(
          SyncMergePhase.stale,
          error: error is OperationFailure ? error.code.wire : 'MERGE_FAILED',
        );
      rethrow;
    }
  }

  Future<T> confirm<T>(
    SyncMergePreview preview,
    SyncMergeChoice choice,
    Future<T> Function(SyncMergeAuthorization authorization) execute,
  ) async {
    final plan = _plan, generation = _generation;
    if (_disposed || plan == null || !identical(preview, _preview) || _consumed)
      throw _staleMerge;
    if (_executing)
      throw const OperationFailure(
        FailureCode.resourceExhausted,
        retryable: true,
      );
    final source = plan.local.localFence!;
    _guard(generation, source);
    if (!keyReady()) throw const OperationFailure(FailureCode.authRequired);
    final target = plan.resolve(choice);
    _executing = true;
    SyncMergeAuthorization? authorization;
    try {
      final head = await access.readVaultHead(source.context, _cancel);
      _guard(generation, source);
      if (!_headMatches(plan.remote, head)) throw _staleMerge;
      if (!keyReady()) throw const OperationFailure(FailureCode.authRequired);
      _consumed = true;
      authorization = SyncMergeAuthorization._(
        source,
        plan.remote.manifest,
        target,
        _cancel,
        () {
          _guard(generation, source);
          if (!keyReady())
            throw const OperationFailure(FailureCode.authRequired);
        },
      );
      _emit(SyncMergePhase.executing, preview: preview);
      final result = await execute(authorization);
      _ownerGuard(generation, source);
      _plan = null;
      _preview = null;
      _emit(SyncMergePhase.idle);
      return result;
    } catch (error) {
      if (!_disposed && generation == _generation) {
        _consumed = true;
        _emit(
          error is OperationFailure && error.code == FailureCode.conflict
              ? SyncMergePhase.stale
              : SyncMergePhase.error,
          preview: preview,
          error: error is OperationFailure ? error.code.wire : 'MERGE_FAILED',
        );
      }
      rethrow;
    } finally {
      authorization?._active = false;
      _executing = false;
    }
  }
}
