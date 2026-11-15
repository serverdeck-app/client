import 'dart:async';

import '../domain/models.dart';
import '../runtime/capability.dart';
import '../runtime/owned_work.dart';
import 'sync_apply.dart';
import 'sync_atomic_apply.dart';
import 'sync_crypto.dart';
import 'sync_cycle_ports.dart';
import 'sync_merge.dart';
import 'sync_models.dart';
import 'sync_publication.dart';
import 'sync_recovery.dart';
import 'sync_repository.dart';
import 'sync_retirement.dart';
import 'sync_snapshots.dart';
import 'sync_transport.dart';
import 'sync_wire.dart';

typedef SyncCryptoScope = T Function<T>(T Function(SyncCrypto) action);

enum SyncCyclePhase {
  paused,
  waitingForKey,
  checking,
  consent,
  conflict,
  publishing,
  synced,
  offlinePending,
  error,
}

/// Counts/status only. No plaintext content, semantic hashes, key or auth secret.
final class SyncCycleView {
  const SyncCycleView(
    this.phase, {
    this.pendingChanges = 0,
    this.pendingBytes,
    this.lastSuccessUtc,
    this.errorCode,
    this.retryAfterSeconds,
    this.preview,
  });
  final SyncCyclePhase phase;
  final int pendingChanges;
  final int? lastSuccessUtc, retryAfterSeconds, pendingBytes;
  final String? errorCode;
  final SyncMergePreview? preview;
}

/// Functional UI boundary; native authority and policy remain in the owner.
abstract interface class SyncCycleActions {
  SyncCycleView get view;
  Stream<SyncCycleView> get changes;
  Future<void> retry();
  Future<void> confirm(SyncMergePreview preview, SyncMergeChoice choice);
  void cancelPreview();
}

final class _PreparedCycle {
  const _PreparedCycle(this.context, this.crypto, this.snapshots, this.preview);
  final SyncVaultContext context;
  final SyncCrypto crypto;
  final SyncCycleSnapshots snapshots;
  final SyncMergePreview preview;
}

void Function() _timer(Duration delay, void Function() callback) {
  final timer = Timer(delay, callback);
  return timer.cancel;
}

/// One root-owned foreground cycle: publication recovery, streamed B/L/R,
/// consent/conflicts, native retirement/apply and frozen-intent publication.
/// Auth and unlocked-key admission remain with their existing owners.
final class SyncCycleOwner implements RuntimeCapability, SyncCycleActions {
  SyncCycleOwner({
    required this.repository,
    required this.access,
    required this.withCrypto,
    required this.transfer,
    required this.merge,
    required this.apply,
    required this.newId,
    required this.utcNow,
    ScheduleOwnedDeadline? schedule,
    int Function()? monotonicMicros,
  }) : _schedule = schedule ?? _timer {
    final clock = Stopwatch()..start();
    _clock = monotonicMicros ?? (() => clock.elapsedMicroseconds);
    publisher = SyncPendingPublisher(
      repository: repository,
      access: access,
      newId: newId,
      utcNow: utcNow,
    );
    retirement = SyncUploadRetirement(
      repository: repository,
      access: access,
      publisher: publisher,
      utcNow: utcNow,
    );
    reader = SyncSnapshotReader(
      repository: repository,
      transfer: transfer,
      access: access,
      newId: newId,
    );
    _observedGeneration = repository.domain.read(
      (r) => r.syncState.syncGeneration,
    );
    _domainChanges = repository.domain.domainChanges.listen((_) {
      if (_paused || _stopped || _disposed) return;
      final generation = repository.domain.read(
        (r) => r.syncState.syncGeneration,
      );
      final stalePreview = _prepared != null;
      if (generation == _observedGeneration && !stalePreview) return;
      _observedGeneration = generation;
      if (stalePreview) {
        merge.cancel();
        _prepared = null;
      }
      _wanted = true;
      if (_active == null) _arm(0);
    });
  }
  final SyncRepository repository;
  final SyncCycleAccess access;
  final SyncCryptoScope withCrypto;
  final SyncCredentialTransfer transfer;
  final SyncMergeController merge;
  final SyncApply apply;
  final String Function() newId;
  final int Function() utcNow;
  late final SyncPendingPublisher publisher;
  late final SyncUploadRetirement retirement;
  late final SyncSnapshotReader reader;
  final ScheduleOwnedDeadline _schedule;
  late final int Function() _clock;
  late final StreamSubscription<void> _domainChanges;
  final _changes = StreamController<SyncCycleView>.broadcast();
  SyncCycleView _view = const SyncCycleView(SyncCyclePhase.paused);
  SyncCycleView get view => _view;
  Stream<SyncCycleView> get changes => _changes.stream;
  Future<void>? _active;
  SyncCancellation _cancel = SyncCancellation();
  void Function()? _cancelTimer;
  _PreparedCycle? _prepared;
  BigInt _notBefore = BigInt.zero;
  int _epoch = 0, _lastTime = 0, _backoff = 5, _observedGeneration = 0;
  bool _gcNeeded = true;
  bool _paused = true,
      _stopped = false,
      _disposed = false,
      _wanted = false,
      _recheck = false;
  @override
  String get id => 'sync-cycle';

  int _now() {
    final value = _clock();
    if (value < _lastTime || value < 0)
      throw const OperationFailure(FailureCode.timeout);
    _lastTime = value;
    return value;
  }

  int _remaining() {
    final micros = _notBefore - BigInt.from(_now());
    return micros <= BigInt.zero
        ? 0
        : ((micros + BigInt.from(999999)) ~/ BigInt.from(1000000)).toInt();
  }

  bool get _admitted => !_paused && !_stopped && !_disposed;
  bool _keyReady() {
    try {
      return withCrypto((_) => true);
    } catch (_) {
      return false;
    }
  }

  void _guard(int epoch, [SyncVaultContext? context, SyncCrypto? crypto]) {
    if (!_admitted || epoch != _epoch || _cancel.cancelled)
      throw const SyncTransportCancelled();
    if (context != null) access.guardVaultContext(context);
    if (crypto != null && !identical(withCrypto((value) => value), crypto))
      throw const SyncTransportCancelled();
  }

  bool _current(int epoch, SyncVaultContext context, SyncCrypto crypto) {
    try {
      _guard(epoch, context, crypto);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _emit(
    SyncCyclePhase phase, {
    String? error,
    int? retry,
    SyncMergePreview? preview,
  }) {
    if (_disposed) return;
    final state = repository.domain.read((r) => r.syncState);
    final delta = state.syncGeneration - state.ackGeneration;
    final pendingBytes = repository.domain.read((r) {
      final id = state.pendingRootId;
      if (id == null) return null;
      final root = r.syncRoot(id);
      if (root == null) return null;
      if (root.manifestLength < 28 ||
          root.manifestLength > syncMaxRootBytes ||
          root.objectLengths.length != root.objectHashes.length ||
          root.objectLengths.length > 11000 ||
          root.objectLengths.any((n) => n < 1 || n > syncMaxObjectBytes))
        return null;
      final bytes = root.objectLengths.fold<int>(
        root.manifestLength,
        (sum, n) => sum + n,
      );
      return bytes >= 0 && bytes <= syncMaxHeadBytes ? bytes : null;
    });
    _view = SyncCycleView(
      phase,
      pendingChanges: delta < 0 ? 0 : delta,
      pendingBytes: pendingBytes,
      lastSuccessUtc: state.lastSuccessUtc,
      errorCode: error,
      retryAfterSeconds: retry,
      preview: preview,
    );
    _changes.add(_view);
  }

  void _clearTimer() {
    _cancelTimer?.call();
    _cancelTimer = null;
  }

  void _arm(int seconds) {
    _clearTimer();
    if (!_admitted || !_keyReady()) return;
    final remaining = _remaining();
    final delay = seconds > remaining ? seconds : remaining;
    // Huge valid Retry-After values cannot overflow a Duration. One chunked
    // timer remains, with a BigInt monotonic deadline and no premature request.
    final chunk = delay > 300 ? 300 : delay;
    final epoch = _epoch;
    _cancelTimer = _schedule(Duration(seconds: chunk), () {
      _cancelTimer = null;
      if (!_admitted || epoch != _epoch) return;
      if (_remaining() > 0) {
        _arm(0);
        return;
      }
      unawaited(retry());
    });
  }

  Future<void> resume() {
    if (_stopped || _disposed)
      return Future.error(const SyncTransportCancelled());
    if (_paused) {
      _paused = false;
      _epoch++;
      _cancel = SyncCancellation();
    }
    if (!_keyReady()) {
      _emit(SyncCyclePhase.waitingForKey);
      return Future.value();
    }
    if (_active != null) {
      _wanted = true;
      return _active!;
    }
    return retry();
  }

  void pause() {
    if (_disposed || _paused) return;
    _paused = true;
    _epoch++;
    _clearTimer();
    _cancel.cancel();
    merge.cancel();
    _prepared = null;
    _wanted = false;
    unawaited(apply.cancelPending());
    _emit(SyncCyclePhase.paused);
  }

  Future<void> retry() {
    if (!_admitted) return Future.error(const SyncTransportCancelled());
    final active = _active;
    if (active != null) return active;
    _clearTimer();
    if (!_keyReady()) {
      _emit(SyncCyclePhase.waitingForKey);
      return Future.value();
    }
    final remaining = _remaining();
    if (remaining > 0) {
      _emit(
        SyncCyclePhase.offlinePending,
        error: _view.errorCode,
        retry: remaining,
      );
      _arm(0);
      return Future.value();
    }
    return _launch(_run);
  }

  Future<void> confirm(SyncMergePreview preview, SyncMergeChoice choice) {
    final prepared = _prepared;
    if (!_admitted ||
        _active != null ||
        prepared == null ||
        !identical(preview, prepared.preview))
      return Future.error(const OperationFailure(FailureCode.conflict));
    _clearTimer();
    _prepared = null;
    return _launch(
      (epoch, cancel) => _applyChoice(epoch, cancel, prepared, choice),
    );
  }

  void cancelPreview() {
    if (!_admitted || _active != null || _prepared == null) return;
    merge.cancel();
    _prepared = null;
    _emit(SyncCyclePhase.consent, error: 'CONSENT_CANCELLED');
    _arm(60);
  }

  Future<void> _launch(Future<void> Function(int, SyncCancellation) action) {
    final epoch = _epoch;
    final cancel = _cancel = SyncCancellation();
    _wanted = false;
    _recheck = false;
    final future = _perform(epoch, cancel, action);
    _active = future;
    void done() {
      if (!identical(_active, future)) return;
      _active = null;
      if (!_admitted || !_keyReady()) return;
      if (epoch != _epoch) {
        _arm(0);
        return;
      }
      if (_view.phase == SyncCyclePhase.error) return;
      final dirty = repository.domain.read(
        (r) =>
            r.syncState.pendingRootId != null ||
            r.syncState.syncGeneration > r.syncState.ackGeneration,
      );
      if (_view.retryAfterSeconds != null &&
          _view.phase == SyncCyclePhase.offlinePending) {
        _arm(0);
      } else {
        _arm(_recheck || _wanted && dirty && _prepared == null ? 0 : 60);
      }
    }

    future.then((_) => done(), onError: (Object _, StackTrace __) => done());
    return future;
  }

  Future<void> _perform(
    int epoch,
    SyncCancellation cancel,
    Future<void> Function(int, SyncCancellation) action,
  ) async {
    try {
      await action(epoch, cancel);
      _guard(epoch);
      _backoff = 5;
    } catch (error) {
      _gcNeeded = true;
      if (!_admitted || epoch != _epoch) return;
      if (error is SyncTransportCancelled || error is WorkCancelled) {
        _emit(SyncCyclePhase.waitingForKey);
        return;
      }
      final retryable = error is SyncRemoteFailure
          ? error.status == 429 || error.status == 503
          : error is OperationFailure &&
                (error.code == FailureCode.networkError ||
                    error.code == FailureCode.timeout);
      final code = switch (error) {
        SyncRemoteFailure() => error.code,
        OperationFailure() => error.code.wire,
        SyncUnsupportedContentVersion() => 'CONTENT_UPDATE_REQUIRED',
        _ => 'SYNC_FAILED',
      };
      if (retryable) {
        final remote = error is SyncRemoteFailure
            ? error.retryAfterSeconds ?? 0
            : 0;
        final seconds = remote > _backoff ? remote : _backoff;
        _notBefore =
            BigInt.from(_now()) + BigInt.from(seconds) * BigInt.from(1000000);
        _backoff = _backoff >= 150 ? 300 : _backoff * 2;
        _emit(SyncCyclePhase.offlinePending, error: code, retry: seconds);
        _arm(0);
      } else if (error is SyncRemoteFailure &&
              (error.code == 'revision_changed' ||
                  error.code == 'revision_conflict') ||
          error is OperationFailure && error.code == FailureCode.conflict) {
        _emit(SyncCyclePhase.offlinePending, error: code, retry: 5);
        // Reconcile boundedly rather than recursively retrying a changing head.
        _notBefore = BigInt.from(_now()) + BigInt.from(5000000);
        _arm(0);
      } else {
        _prepared = null;
        merge.cancel();
        _emit(SyncCyclePhase.error, error: code);
      }
    }
  }

  Object _rootPointers() => repository.domain.read(
    (r) => (
      r.syncState.baseRootId,
      r.syncState.pendingRootId,
      r.syncState.pendingCommitId,
      r.syncState.candidateRootId,
      r.syncState.conflictLocalId,
      r.syncState.conflictRemoteId,
    ),
  );

  Future<void> _garbage(
    int epoch,
    SyncVaultContext context,
    SyncCrypto crypto, {
    required bool full,
  }) async {
    if (full) _gcNeeded = true;
    var first = true;
    for (;;) {
      _guard(epoch, context, crypto);
      final pass = await repository.collectGarbagePass(
        expectedGeneration: context.fence.generation,
        limit: full ? 1000 : 100,
        restart: full && first,
        isCurrent: () => _current(epoch, context, crypto),
      );
      _guard(epoch, context, crypto);
      first = false;
      if (!full || pass.finished) break;
      // Bound each native transaction and yield between batches. A pinned
      // prefix is not completion; continue until the end of this key traversal.
      await Future<void>.delayed(Duration.zero);
    }
    if (full) _gcNeeded = false;
  }

  Future<void> _run(int epoch, SyncCancellation cancel) async {
    _guard(epoch);
    _prepared = null;
    merge.cancel();
    _emit(SyncCyclePhase.checking);
    final context = await access.vaultContext();
    _guard(epoch, context);
    final crypto = withCrypto((value) => value);
    _guard(epoch, context, crypto);
    SyncHead? head;
    final state = repository.domain.read((r) => r.syncState);
    _observedGeneration = state.syncGeneration;
    await _garbage(
      epoch,
      context,
      crypto,
      full:
          _gcNeeded ||
          state.pendingRootId != null ||
          state.syncGeneration > state.ackGeneration,
    );
    final beforePublication = _rootPointers();
    if (state.pendingRootId != null && !state.pendingUploadRetiring) {
      _emit(SyncCyclePhase.publishing);
      final result = await publisher.publish(
        context,
        crypto,
        cancel: cancel,
        isCurrent: () => _current(epoch, context, crypto),
      );
      _guard(epoch, context, crypto);
      head = result.head;
    }
    head ??= await access.readVaultHead(context, cancel);
    _guard(epoch, context, crypto);
    if (beforePublication != _rootPointers()) _gcNeeded = true;
    final currentState = repository.domain.read((r) => r.syncState);
    if (_gcNeeded ||
        head.revision != currentState.baseRevision ||
        currentState.syncGeneration > currentState.ackGeneration) {
      await _garbage(epoch, context, crypto, full: true);
    }
    final snapshots = await reader.read(
      context,
      crypto,
      head,
      cancel: cancel,
      isCurrent: () => _current(epoch, context, crypto),
      candidateChanged: () => _garbage(epoch, context, crypto, full: true),
    );
    _guard(epoch, context, crypto);
    final preview = await merge.propose(
      local: snapshots.local,
      remote: snapshots.remote,
      base: snapshots.base,
    );
    _guard(epoch, context, crypto);
    final prepared = _PreparedCycle(context, crypto, snapshots, preview);
    final retiring = repository.domain.read(
      (r) => r.syncState.pendingUploadRetiring,
    );
    if (preview.requiresConsent || preview.conflicts.isNotEmpty || retiring) {
      _prepared = prepared;
      _emit(
        preview.conflicts.isEmpty
            ? SyncCyclePhase.consent
            : SyncCyclePhase.conflict,
        preview: preview,
      );
      return;
    }
    await _applyChoice(epoch, cancel, prepared, SyncMergeChoice.automatic);
  }

  Future<void> _applyChoice(
    int epoch,
    SyncCancellation cancel,
    _PreparedCycle prepared,
    SyncMergeChoice choice,
  ) async {
    final context = prepared.context, crypto = prepared.crypto;
    _guard(epoch, context, crypto);
    var rebuild = false;
    final beforeApply = _rootPointers();
    await merge.confirm(prepared.preview, choice, (authority) async {
      _guard(epoch, context, crypto);
      final retired = await retirement.retire(authority, crypto);
      _guard(epoch, context, crypto);
      if (retired.rebuild) {
        rebuild = true;
        return;
      }
      await apply.apply(
        authority,
        crypto,
        remoteRootId: prepared.snapshots.remoteRootId,
        retiredUpload: retired.closed,
      );
      _guard(epoch, context, crypto);
    });
    _guard(epoch, context, crypto);
    if (rebuild) {
      _gcNeeded = true;
      _recheck = true;
      _emit(SyncCyclePhase.checking);
      return;
    }
    if (beforeApply != _rootPointers())
      await _garbage(epoch, context, crypto, full: true);
    final beforePublication = _rootPointers();
    if (repository.domain.read((r) => r.syncState.pendingRootId != null)) {
      _emit(SyncCyclePhase.publishing);
      final result = await publisher.publish(
        context,
        crypto,
        cancel: cancel,
        isCurrent: () => _current(epoch, context, crypto),
      );
      _guard(epoch, context, crypto);
      if (result.disposition == SyncPublicationDisposition.reconcile) {
        _recheck = true;
        _notBefore = BigInt.from(_now()) + BigInt.from(5000000);
        _emit(
          SyncCyclePhase.offlinePending,
          error: 'RECONCILIATION_REQUIRED',
          retry: 5,
        );
        return;
      }
    }
    if (beforePublication != _rootPointers())
      await _garbage(epoch, context, crypto, full: true);
    final dirty = repository.domain.read(
      (r) => r.syncState.syncGeneration > r.syncState.ackGeneration,
    );
    _wanted |= dirty;
    _emit(dirty ? SyncCyclePhase.offlinePending : SyncCyclePhase.synced);
  }

  @override
  Future<void> stopAdmission() async {
    _stopped = true;
    pause();
    await apply.stopAdmission();
  }

  @override
  Future<void> cancelPending() async {
    pause();
    await apply.cancelPending();
  }

  @override
  Future<void> closeSessions() async {}
  @override
  Future<void> drain() async {
    final active = _active;
    if (active != null) await active;
    await publisher.withPublicationStopped(() async {});
    await apply.drain();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await stopAdmission();
    await cancelPending();
    await drain();
    await _domainChanges.cancel();
    await apply.dispose();
    _disposed = true;
    await _changes.close();
  }
}
