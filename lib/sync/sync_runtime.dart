import 'dart:async';

import 'package:flutter/foundation.dart';

import '../connections/profile_batch.dart';
import '../domain/actor.dart';
import '../domain/app_operations.dart';
import '../domain/models.dart';
import '../profiles/key_parse_worker.dart';
import '../runtime/capability.dart';
import '../runtime/platform_ports.dart';
import '../runtime/owned_work.dart';
import '../storage/domain_repository.dart';
import 'sync_apply.dart';
import 'sync_atomic_apply.dart';
import 'sync_cycle.dart';
import 'sync_owner.dart';
import 'sync_repository.dart';
import 'sync_recovery.dart';
import 'sync_transport.dart';
import 'sync_wire.dart';

void Function() _rootTimer(Duration delay, void Function() action) {
  final timer = Timer(delay, action);
  return timer.cancel;
}

/// One root capability over the same domain/gate/connections as local features.
/// Foreground clock failure blocks sync only; it never blocks local storage/SSH.
final class SyncRuntime extends ChangeNotifier implements RuntimeCapability {
  SyncRuntime({
    required DomainRepository domain,
    required DomainCommandGate gate,
    required OwnerActor actor,
    required ProfileBatchPort connections,
    required PlatformSecretPort secrets,
    required KeyInspector inspector,
    required PlatformBrowserPort browser,
    required Future<int> Function() availableStorageBytes,
    required String Function() newId,
    required int Function() utcNow,
    required int Function() monotonicMicros,
    required SyncTransport Function(SyncServiceOrigin) transport,
    this.lifecycle,
    this.refreshClock,
    ScheduleOwnedDeadline? schedule,
    bool Function()? isRunning,
  }) : _schedule = schedule ?? _rootTimer,
       _clock = monotonicMicros,
       _isRunning = isRunning ?? (() => true) {
    if (lifecycle != null && refreshClock == null) {
      throw ArgumentError('Mobile sync requires foreground clock calibration');
    }
    repository = SyncRepository(
      domain,
      availableStorageBytes: availableStorageBytes,
    );
    owner = SyncOwner(
      repository: repository,
      secrets: secrets,
      browser: browser,
      transport: transport,
      monotonicMicros: monotonicMicros,
      authPollSchedule: schedule,
    );
    transfer = SyncCredentialTransfer(
      repository: domain,
      secrets: secrets,
      inspector: inspector,
      access: owner,
    );
    apply = SyncApply(
      repository: repository,
      transfer: transfer,
      gate: gate,
      actor: actor,
      connections: connections,
      newId: newId,
      utcNow: utcNow,
    );
    cycle = owner.configureCycle(
      transfer: transfer,
      apply: apply,
      newId: newId,
      utcNow: utcNow,
      monotonicMicros: monotonicMicros,
      schedule: schedule,
    );
    account = owner.configureLifecycle(
      gate: gate,
      actor: actor,
      connections: connections,
    );
    owner.pause();
    _subscription = lifecycle?.changes.listen(_foreground);
    _authChanges = owner.changes.listen((view) {
      if (!identical(view, owner.view)) return;
      if (view.phase == SyncAuthPhase.signedIn) {
        _scheduleVaultRestore();
      } else {
        _clearVaultTimer();
      }
    });
    _keyChanges = owner.vault.changes.listen((view) {
      if (!identical(view, owner.vault.view)) return;
      // Explicit UI key work owns its generation. Never compete with it.
      if (!_vaultBusy && view.phase != SyncVaultPhase.error) {
        _clearVaultTimer();
        _vaultRetry = false;
      }
    });
  }
  final PlatformLifecyclePort? lifecycle;
  final Future<void> Function()? refreshClock;
  final ScheduleOwnedDeadline _schedule;
  final int Function() _clock;
  final bool Function() _isRunning;
  late final SyncRepository repository;
  late final SyncOwner owner;
  late final SyncCredentialTransfer transfer;
  late final SyncApply apply;
  late final SyncCycleOwner cycle;
  late final SyncAccountLifecycle account;
  StreamSubscription<PlatformLifecyclePhase>? _subscription;
  StreamSubscription<SyncAuthView>? _authChanges;
  StreamSubscription<SyncVaultView>? _keyChanges;
  Future<void>? _resuming;
  Future<void>? _vaultWork;
  void Function()? _cancelVaultTimer;
  bool _activated = false, _vaultBusy = false, _vaultRetry = false;
  int? _vaultSource;
  int _vaultBackoff = 5, _lastTime = 0, _rootKeyGeneration = 0;
  BigInt _vaultNotBefore = BigInt.zero;
  int _generation = 0;
  bool _wanted = false, _stopped = false, _disposed = false;
  String? foregroundError;
  bool get _foregroundNow =>
      lifecycle == null || lifecycle!.phase == PlatformLifecyclePhase.resumed;
  @override
  String get id => 'sync-runtime';

  void _foreground(PlatformLifecyclePhase phase) {
    if (_stopped || _disposed) return;
    _generation++;
    _clearVaultTimer();
    // This callback is synchronous for actual Android lifecycle delivery.
    owner.pause(
      preserveDeviceAuthorization: phase != PlatformLifecyclePhase.detached,
    );
    if (phase == PlatformLifecyclePhase.resumed) unawaited(retryForeground());
  }

  Future<void> initialize() => retryForeground();
  Future<void> retryForeground() {
    if (_stopped || _disposed || !_foregroundNow) return Future.value();
    _wanted = true;
    return _resuming ??= _resumeLoop().whenComplete(() => _resuming = null);
  }

  Future<void> _resumeLoop() async {
    while (_wanted && !_stopped && !_disposed && _foregroundNow) {
      _wanted = false;
      final generation = _generation;
      try {
        await refreshClock?.call();
        if (_stopped ||
            _disposed ||
            generation != _generation ||
            !_foregroundNow)
          continue;
        await owner.resume();
        if (_stopped ||
            _disposed ||
            generation != _generation ||
            !_foregroundNow)
          continue;
        foregroundError = null;
        _scheduleVaultRestore();
      } catch (_) {
        if (_stopped ||
            _disposed ||
            generation != _generation ||
            !_foregroundNow)
          continue;
        owner.pause(preserveDeviceAuthorization: lifecycle != null);
        foregroundError = 'SYNC_RESUME_UNAVAILABLE';
      }
      notifyListeners();
    }
  }

  /// Called after local feature initialization; defer network work until the
  /// shared runtime has admitted local owners. No optional network blocks open.
  void activate() {
    if (_stopped || _disposed) return;
    _activated = true;
    _scheduleVaultRestore();
  }

  bool get _canRestore =>
      _activated &&
      !_stopped &&
      !_disposed &&
      _foregroundNow &&
      _isRunning() &&
      owner.view.phase == SyncAuthPhase.signedIn &&
      _ownsKeyPreparation;
  bool get _ownsKeyPreparation {
    final expected = _rootKeyGeneration > owner.vaultOwnerGeneration
        ? _rootKeyGeneration
        : owner.vaultOwnerGeneration;
    return owner.vault.actionGeneration == expected;
  }

  void _clearVaultTimer() {
    _cancelVaultTimer?.call();
    _cancelVaultTimer = null;
  }

  int _now() {
    final now = _clock();
    if (now < _lastTime || now < 0 || now > 9007199254740991) {
      throw const OperationFailure(FailureCode.timeout);
    }
    _lastTime = now;
    return now;
  }

  void _clockFailed() {
    _clearVaultTimer();
    owner.pause();
    foregroundError = 'SYNC_RESUME_UNAVAILABLE';
    notifyListeners();
  }

  void _scheduleVaultRestore() {
    if (!_activated ||
        _stopped ||
        _disposed ||
        !_foregroundNow ||
        owner.view.phase != SyncAuthPhase.signedIn ||
        _vaultBusy ||
        !_ownsKeyPreparation)
      return;
    final state = repository.domain.read((r) => r.syncState);
    final hasKey = repository.domain.read(
      (r) => r.syncSecrets.protectedVaultRootKey != null,
    );
    if (!hasKey)
      return; // Initialization/recovery remains an explicit user action.
    if (_vaultSource != state.identityGeneration) {
      _vaultSource = state.identityGeneration;
      _vaultBackoff = 5;
      _vaultNotBefore = BigInt.zero;
      _vaultRetry = false;
    }
    if (owner.vault.view.phase != SyncVaultPhase.unavailable &&
        !(_vaultRetry && owner.vault.view.phase == SyncVaultPhase.error))
      return;
    _armVault();
  }

  void _armVault() {
    _clearVaultTimer();
    if (!_activated || _stopped || _disposed || !_foregroundNow) return;
    final epoch = _generation, source = _vaultSource;
    int seconds;
    try {
      final remaining = _vaultNotBefore - BigInt.from(_now());
      final rounded = (remaining + BigInt.from(999999)) ~/ BigInt.from(1000000);
      seconds = rounded <= BigInt.zero
          ? 0
          : rounded > BigInt.from(300)
          ? 300
          : rounded.toInt();
    } catch (_) {
      _clockFailed();
      return;
    }
    _cancelVaultTimer = _schedule(Duration(seconds: seconds), () {
      _cancelVaultTimer = null;
      if (!_canRestore ||
          epoch != _generation ||
          source !=
              repository.domain.read((r) => r.syncState.identityGeneration))
        return;
      try {
        if (BigInt.from(_now()) < _vaultNotBefore) {
          _armVault();
        } else {
          _startVaultRestore(epoch, source);
        }
      } catch (_) {
        _clockFailed();
      }
    });
  }

  void _startVaultRestore(int epoch, int? source) {
    if (_vaultBusy || !_canRestore) return;
    final phase = owner.vault.view.phase;
    if (phase != SyncVaultPhase.unavailable &&
        !(_vaultRetry && phase == SyncVaultPhase.error))
      return;
    _vaultBusy = true;
    final work = _restoreVault(epoch, source).catchError((Object _) {
      if (!_stopped && !_disposed) _clockFailed();
    });
    _vaultWork = work;
    unawaited(
      work.whenComplete(() {
        if (identical(_vaultWork, work)) _vaultWork = null;
        _vaultBusy = false;
        if (!_stopped &&
            !_disposed &&
            (epoch != _generation ||
                source !=
                    repository.domain.read(
                      (r) => r.syncState.identityGeneration,
                    ))) {
          _scheduleVaultRestore();
        }
      }),
    );
  }

  Future<void> _restoreVault(int epoch, int? source) async {
    try {
      final inspection = owner.vault.inspect();
      _rootKeyGeneration = owner.vault.actionGeneration;
      await inspection;
      if (!_canRestore ||
          epoch != _generation ||
          source !=
              repository.domain.read((r) => r.syncState.identityGeneration))
        return;
      _vaultRetry = false;
      _vaultBackoff = 5;
      _vaultNotBefore = BigInt.zero;
    } catch (error) {
      if (!_canRestore ||
          epoch != _generation ||
          source !=
              repository.domain.read((r) => r.syncState.identityGeneration))
        return;
      final retryable = error is SyncRemoteFailure
          ? error.status == 429 || error.status == 503
          : error is OperationFailure &&
                {
                  FailureCode.timeout,
                  FailureCode.networkError,
                }.contains(error.code);
      if (!retryable) {
        _vaultRetry = false;
        return;
      }
      final remote = error is SyncRemoteFailure
          ? error.retryAfterSeconds ?? 0
          : 0;
      final delay = remote > _vaultBackoff ? remote : _vaultBackoff;
      _vaultRetry = true;
      _vaultBackoff = (_vaultBackoff * 2).clamp(5, 300);
      _vaultNotBefore =
          BigInt.from(_now()) + BigInt.from(delay) * BigInt.from(1000000);
      _armVault();
    }
  }

  @override
  Future<void> stopAdmission() async {
    _stopped = true;
    _generation++;
    _wanted = false;
    _clearVaultTimer();
    owner.pause();
    await Future.wait([cycle.stopAdmission(), account.stopAdmission()]);
  }

  @override
  Future<void> cancelPending() async {
    _clearVaultTimer();
    owner.pause();
    await Future.wait([cycle.cancelPending(), account.cancelPending()]);
  }

  @override
  Future<void> closeSessions() async {}
  @override
  Future<void> drain() async {
    await _resuming;
    await _vaultWork;
    await Future.wait([cycle.drain(), account.drain()]);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await stopAdmission();
    await cancelPending();
    await drain();
    await _subscription?.cancel();
    await _authChanges?.cancel();
    await _keyChanges?.cancel();
    await Future.wait([cycle.dispose(), account.dispose()]);
    owner.dispose();
    _disposed = true;
    super.dispose();
  }
}
