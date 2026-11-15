import 'dart:async';
import 'dart:typed_data';

import '../domain/models.dart';
import '../domain/actor.dart';
import '../domain/app_operations.dart';
import '../connections/profile_batch.dart';
import '../profiles/endpoint_references.dart';
import '../runtime/capability.dart';
import '../storage/domain_repository.dart';
import 'sync_json.dart';
import 'sync_publication.dart';
import '../runtime/platform_ports.dart';
import '../storage/records.dart';
import 'sync_models.dart';
import 'sync_apply.dart';
import 'sync_atomic_apply.dart';
import 'sync_cycle.dart';
import '../runtime/owned_work.dart';
import 'sync_cycle_ports.dart';
import 'sync_merge.dart';
import 'sync_recovery.dart';
import 'sync_repository.dart';
import 'sync_secret_box.dart';
import 'sync_transport.dart';
import 'sync_wire.dart';

part 'sync_account_lifecycle.dart';

void Function() _scheduleAuthTimer(Duration delay, void Function() callback) {
  final timer = Timer(delay, callback);
  return timer.cancel;
}

enum SyncAuthPhase {
  disabled,
  starting,
  awaitingApproval,
  protecting,
  signedIn,
  loginRequired,
  disconnectRequired,
  revoked,
  vaultReset,
  paused,
  error,
}

/// Explicit UI projection: never carries tokens, device_code, K or recovery.
final class SyncAuthView {
  const SyncAuthView(
    this.phase, {
    this.accountId,
    this.deviceId,
    this.vaultId,
    this.userCode,
    this.activationUri,
    this.errorCode,
  });
  final SyncAuthPhase phase;
  final String? accountId, deviceId, vaultId, userCode, errorCode;
  final Uri? activationUri;
}

/// Private process-local approval only; never persisted or a data-access capability.
final class _DeviceLogin {
  _DeviceLogin(
    this.authorization,
    this.origin,
    this.generation,
    this.previous,
    this.expires,
    this.android,
  );
  final SyncDeviceAuthorization authorization;
  final SyncServiceOrigin origin;
  final int generation, expires;
  final SyncFence? previous;
  final bool android;
  final browserFinished = Completer<void>();
  int interval = 5, nextAt = 0;
  bool browserOpened = false,
      polling = false,
      suspended = false,
      invalid = false;
  String? browserError;
  void cancel() {
    invalid = true;
    if (!browserFinished.isCompleted) browserFinished.complete();
  }
}

/// One root-owned authentication state machine. Publication/merge/apply, account
/// switching and device/reset UI are added by their own feature tasks.
final class SyncOwner implements SyncCycleAccess {
  SyncOwner({
    required this.repository,
    required PlatformSecretPort secrets,
    required this.browser,
    required SyncTransport Function(SyncServiceOrigin) transport,
    int Function()? monotonicMicros,
    ScheduleOwnedDeadline? authPollSchedule,
    Uint8List Function(int)? recoveryRandomBytes,
  }) : box = SyncSecretBox(secrets),
       _transportFactory = transport,
       _authPollSchedule = authPollSchedule ?? _scheduleAuthTimer {
    final clock = Stopwatch()..start();
    _clock = monotonicMicros ?? (() => clock.elapsedMicroseconds);
    vault = SyncVaultOwner(
      repository: repository,
      box: box,
      access: this,
      randomBytes: recoveryRandomBytes,
    );
    _vaultOwnerGeneration = vault.actionGeneration;
    merge = SyncMergeController(
      repository: repository.domain,
      access: this,
      keyReady: () {
        try {
          return vault.withCrypto((_) => true);
        } catch (_) {
          return false;
        }
      },
    );
  }
  SyncAccountLifecycle? _lifecycle;
  bool _disconnectLocked = false;
  SyncAccountLifecycle? get lifecycle => _lifecycle;
  SyncAccountLifecycle configureLifecycle({
    required DomainCommandGate gate,
    required OwnerActor actor,
    required ProfileBatchPort connections,
  }) {
    if (_disposed || _lifecycle != null)
      throw const OperationFailure(FailureCode.conflict);
    return _lifecycle = SyncAccountLifecycle._(this, gate, actor, connections);
  }

  SyncCycleOwner? _cycle;
  StreamSubscription<SyncVaultView>? _cycleVaultChanges;
  SyncCycleOwner? get cycle => _cycle;

  /// Root composition installs exactly one cycle over these same native owners.
  /// Register the returned capability for awaited shutdown before closing store.
  SyncCycleOwner configureCycle({
    required SyncCredentialTransfer transfer,
    required SyncApply apply,
    required String Function() newId,
    required int Function() utcNow,
    ScheduleOwnedDeadline? schedule,
    int Function()? monotonicMicros,
  }) {
    if (_disposed ||
        _cycle != null ||
        !identical(transfer.repository, repository.domain) ||
        !identical(transfer.access, this) ||
        !identical(apply.repository, repository) ||
        !identical(apply.transfer, transfer))
      throw const OperationFailure(FailureCode.conflict);
    final value = _cycle = SyncCycleOwner(
      repository: repository,
      access: this,
      withCrypto: vault.withCrypto,
      transfer: transfer,
      merge: merge,
      apply: apply,
      newId: newId,
      utcNow: utcNow,
      schedule: schedule,
      monotonicMicros: monotonicMicros,
    );
    void changed() {
      if (_disposed || _paused || vault.view.phase != SyncVaultPhase.ready) {
        value.pause();
      } else {
        unawaited(value.resume().catchError((Object _) {}));
      }
    }

    _cycleVaultChanges = vault.changes.listen((_) => changed());
    changed();
    return value;
  }

  final SyncRepository repository;
  final SyncSecretBox box;
  late final SyncVaultOwner vault;
  late int _vaultOwnerGeneration;

  /// Last key invalidation performed by the auth/lifecycle owner itself.
  /// Root compares this with its own operation stamp; UI key actions do not set it.
  int get vaultOwnerGeneration => _vaultOwnerGeneration;
  late final SyncMergeController merge;
  final PlatformBrowserPort browser;
  final SyncTransport Function(SyncServiceOrigin) _transportFactory;
  late final int Function() _clock;
  final _changes = StreamController<SyncAuthView>.broadcast();
  SyncAuthView _view = const SyncAuthView(SyncAuthPhase.disabled);
  SyncAuthView get view => _view;
  Stream<SyncAuthView> get changes => _changes.stream;
  SyncFence? _fence;
  SyncTransport? _transport;
  SyncBoundSecret? _access, _refresh, _proof;
  _DeviceLogin? _deviceLogin;
  bool get hasPendingLogin => _deviceLogin != null;
  SyncCancellation _cancel = SyncCancellation();
  final ScheduleOwnedDeadline _authPollSchedule;
  void Function()? _cancelPoll;
  Future<void>? _restoring;
  Future<SyncBoundSecret>? _refreshing;
  int _epoch = 0, _expires = 0, _lastTime = 0;
  bool _disposed = false, _paused = false, _loaded = false;

  int _now() {
    final value = _clock();
    if (value < 0 || value < _lastTime)
      throw const OperationFailure(FailureCode.timeout);
    _lastTime = value;
    return value;
  }

  bool _current(int epoch) => !_disposed && !_paused && _epoch == epoch;
  void _local(int epoch) {
    if (!_current(epoch)) throw const SyncTransportCancelled();
  }

  void _guard(int epoch, SyncFence fence) {
    _local(epoch);
    if (!repository.domain.read((r) => fence.matches(r.syncState)))
      throw const SyncTransportCancelled();
  }

  void _loginGuard(int epoch, int generation, SyncFence? previous) {
    _local(epoch);
    if (previous != null) {
      _guard(epoch, previous);
      return;
    }
    if (!repository.domain.read(
      (r) =>
          !r.syncState.enabled &&
          r.syncState.accountId == null &&
          r.syncState.identityGeneration == generation,
    ))
      throw const SyncTransportCancelled();
  }

  void _emit(
    SyncAuthPhase phase, {
    String? error,
    SyncDeviceAuthorization? flow,
  }) {
    if (_disposed) return;
    _view = SyncAuthView(
      phase,
      accountId: _fence?.identity.accountId,
      deviceId: _fence?.identity.deviceId,
      vaultId: _fence?.identity.vaultId,
      userCode: flow?.userCode,
      activationUri: flow?.completeUri,
      errorCode: error,
    );
    _changes.add(_view);
  }

  String _safe(Object error) => switch (error) {
    OperationFailure() => error.code.wire,
    SyncRemoteFailure() => error.code,
    SyncTransportCancelled() => 'SYNC_CANCELLED',
    _ => 'AUTH_FAILED',
  };
  SyncTransport _makeTransport(SyncServiceOrigin origin) {
    final result = _transportFactory(origin);
    if (result.origin.value != origin.value) {
      result.dispose();
      throw syncInvalidWire;
    }
    return result;
  }

  void _dropDeviceLogin() {
    final login = _deviceLogin;
    _deviceLogin = null;
    login?.cancel();
    _cancelPoll?.call();
    _cancelPoll = null;
  }

  void _deviceGuard(int epoch, _DeviceLogin login) {
    _loginGuard(epoch, login.generation, login.previous);
    if (!identical(login, _deviceLogin) || login.invalid || _disconnectLocked)
      throw const SyncTransportCancelled();
  }

  void _stop({bool preserveDeviceLogin = false}) {
    _cycle?.pause();
    merge.cancel();
    vault.lock();
    _vaultOwnerGeneration = vault.actionGeneration;
    _epoch++;
    _cancelPoll?.call();
    _cancelPoll = null;
    _cancel.cancel();
    _cancel = SyncCancellation();
    _transport?.dispose();
    _transport = null;
    if (!preserveDeviceLogin) _dropDeviceLogin();
    _access = null;
    _refresh = null;
    _proof = null;
    _expires = 0;
    _loaded = false;
    _restoring = null;
    _refreshing = null;
  }

  Future<void> restoreSession() {
    if (_disposed || _paused)
      return Future.error(const SyncTransportCancelled());
    if (_disconnectLocked) {
      _emit(SyncAuthPhase.disconnectRequired, error: syncDisconnectPending);
      return Future.value();
    }
    if (_loaded || _deviceLogin != null) return Future.value();
    final existing = _restoring;
    if (existing != null) return existing;
    final result = _restore();
    _restoring = result;
    unawaited(
      result.then<void>(
        (_) {
          if (identical(_restoring, result)) _restoring = null;
        },
        onError: (Object _, StackTrace __) {
          if (identical(_restoring, result)) _restoring = null;
        },
      ),
    );
    return result;
  }

  Future<void> _restore() async {
    final epoch = _epoch;
    final enabled = repository.domain.read((r) => r.syncState.enabled);
    if (!enabled) {
      _fence = null;
      _loaded = true;
      _emit(SyncAuthPhase.disabled);
      return;
    }
    var fence = repository.capture();
    _fence = fence;
    final marker = repository.domain.read((r) => r.syncState.errorCode);
    if (marker == syncRefreshInFlight) {
      fence = await repository.blockAuthorization(fence, syncLoginRequired);
      _local(epoch);
      _fence = fence;
    }
    _guard(epoch, fence);
    _transport ??= _makeTransport(
      SyncServiceOrigin(fence.identity.serviceOrigin),
    );
    final currentMarker = repository.domain.read((r) => r.syncState.errorCode);
    final blocked = _blockedPhase(currentMarker);
    if (blocked != null) {
      _loaded = true;
      _emit(blocked, error: currentMarker);
      return;
    }
    final saved = repository.domain.read((r) => r.syncSecrets);
    if (saved.protectedAccess == null ||
        saved.protectedRefresh == null ||
        saved.protectedStatusProof == null) {
      _fence = await repository.blockAuthorization(fence, syncLoginRequired);
      _local(epoch);
      _loaded = true;
      _emit(SyncAuthPhase.loginRequired, error: syncLoginRequired);
      return;
    }
    try {
      final access = await box.unprotectText(
        fence.identity,
        SyncLocalSecretKind.access,
        saved.protectedAccess!,
      );
      _guard(epoch, fence);
      final refresh = await box.unprotectText(
        fence.identity,
        SyncLocalSecretKind.refresh,
        saved.protectedRefresh!,
      );
      _guard(epoch, fence);
      final proof = await box.unprotectText(
        fence.identity,
        SyncLocalSecretKind.statusProof,
        saved.protectedStatusProof!,
      );
      _guard(epoch, fence);
      final origin = SyncServiceOrigin(fence.identity.serviceOrigin);
      _access = SyncBoundSecret(
        origin: origin,
        kind: SyncSecretKind.access,
        value: access,
      );
      _refresh = SyncBoundSecret(
        origin: origin,
        kind: SyncSecretKind.refresh,
        value: refresh,
      );
      _proof = SyncBoundSecret(
        origin: origin,
        kind: SyncSecretKind.statusProof,
        value: proof,
      );
      // Unknown lifetime after process restart: refresh before a data request.
      _expires = 0;
      _loaded = true;
      _emit(SyncAuthPhase.signedIn);
    } catch (error) {
      if (_current(epoch)) _emit(SyncAuthPhase.error, error: _safe(error));
      rethrow;
    }
  }

  SyncAuthPhase? _blockedPhase(String? marker) => switch (marker) {
    syncLoginRequired || syncRefreshInFlight => SyncAuthPhase.loginRequired,
    syncDeviceRevoked => SyncAuthPhase.revoked,
    syncVaultReset => SyncAuthPhase.vaultReset,
    syncDisconnectPending => SyncAuthPhase.disconnectRequired,
    _ => null,
  };

  /// Explicit login action. Never called by saving an origin or ordinary startup.
  Future<void> beginLogin({
    required SyncServiceOrigin origin,
    required String platform,
    required String name,
  }) async {
    if (_disposed || _paused) throw const SyncTransportCancelled();
    final entryEpoch = _epoch;
    await restoreSession();
    _local(entryEpoch);
    if (_disconnectLocked ||
        repository.domain.read((r) => r.syncState.errorCode) ==
            syncDisconnectPending)
      throw const OperationFailure(FailureCode.conflict);
    final previous = repository.domain.read((r) => r.syncState.enabled)
        ? repository.capture()
        : null;
    if (previous != null &&
        (previous.identity.serviceOrigin != origin.value ||
            repository.domain.read((r) => r.syncState.errorCode) ==
                syncVaultReset))
      throw const OperationFailure(FailureCode.conflict);
    _stop();
    _fence = previous;
    final epoch = _epoch,
        generation = repository.domain.read(
          (r) => r.syncState.identityGeneration,
        );
    _transport = _makeTransport(origin);
    _emit(SyncAuthPhase.starting);
    _DeviceLogin? created;
    try {
      final start = _now();
      final flow = await _transport!.beginDevice(
        platform: platform,
        name: name,
        cancel: _cancel,
      );
      _loginGuard(epoch, generation, previous);
      final login = created = _DeviceLogin(
        flow,
        origin,
        generation,
        previous,
        start + 600000000,
        platform == 'android',
      );
      _deviceLogin = login;
      if (_now() >= login.expires)
        throw const OperationFailure(FailureCode.timeout);
      _emit(SyncAuthPhase.awaitingApproval, flow: flow);
      _deviceGuard(epoch, login);
      try {
        await browser.openServicePage(
          serviceOrigin: Uri.parse(origin.value),
          page: flow.completeUri,
        );
        // The same frame may be suspended or waiting for browser acknowledgement
        // in a later foreground epoch. Only record the private open outcome here.
        if (identical(login, _deviceLogin) && !login.invalid && !_disposed) {
          login.browserOpened = true;
          login.nextAt = _now() + login.interval * 1000000;
        }
      } catch (error) {
        if (identical(login, _deviceLogin) && !login.invalid)
          login.browserError = _safe(error);
        rethrow;
      } finally {
        if (!login.browserFinished.isCompleted)
          login.browserFinished.complete();
      }
      if (!identical(login, _deviceLogin) || login.invalid || _disposed)
        throw const SyncTransportCancelled();
      if (_paused || epoch != _epoch) return; // resume owns any re-arming
      _deviceGuard(epoch, login);
      _schedulePoll(epoch, login);
    } catch (error) {
      if (created != null && !created.browserFinished.isCompleted)
        created.browserFinished.complete();
      if (_current(epoch)) {
        _dropDeviceLogin();
        _emit(SyncAuthPhase.loginRequired, error: _safe(error));
      }
      rethrow;
    }
  }

  void _schedulePoll(int epoch, _DeviceLogin login) {
    _deviceGuard(epoch, login);
    final now = _now();
    final remaining = login.expires - now;
    if (remaining <= 0) {
      _dropDeviceLogin();
      _emit(SyncAuthPhase.loginRequired, error: 'expired_token');
      return;
    }
    final delay = (login.nextAt - now).clamp(0, remaining);
    _cancelPoll?.call();
    _cancelPoll = _authPollSchedule(Duration(microseconds: delay), () {
      _cancelPoll = null;
      unawaited(_poll(epoch, login));
    });
  }

  Future<void> _poll(int epoch, _DeviceLogin login) async {
    try {
      _deviceGuard(epoch, login);
      if (_now() >= login.expires) {
        _dropDeviceLogin();
        _emit(SyncAuthPhase.loginRequired, error: 'expired_token');
        return;
      }
      final start = _now();
      login.polling =
          true; // cancellation after this point may have consumed code
      final session = await _transport!.pollDevice(
        login.authorization.deviceCode,
        cancel: _cancel,
      );
      _deviceGuard(epoch, login);
      if (_now() >= login.expires)
        throw const OperationFailure(FailureCode.timeout);
      final identity = SyncIdentity(
        serviceOrigin: login.origin.value,
        accountId: session.accountId,
        deviceId: session.deviceId,
        vaultId: session.vaultId,
      );
      final previous = login.previous;
      if (previous != null &&
          (identity.accountId != previous.identity.accountId ||
              identity.vaultId != previous.identity.vaultId))
        throw const OperationFailure(FailureCode.conflict);
      _emit(SyncAuthPhase.protecting);
      final prepared = await _sealSession(
        identity,
        session,
        () => _deviceGuard(epoch, login),
      );
      SyncFence committed;
      try {
        committed = previous == null
            ? await repository.bind(
                expectedGeneration: login.generation,
                identity: identity,
                secrets: prepared,
                isCurrent: () => _current(epoch),
              )
            : await repository.reauthorize(
                previous,
                identity,
                prepared,
                isCurrent: () => _current(epoch),
              );
      } finally {
        _wipePrepared(prepared);
      }
      _guard(epoch, committed);
      _fence = committed;
      _access = session.tokens.access;
      _refresh = session.tokens.refresh;
      _proof = session.statusProof;
      _expires = start + 900000000;
      _dropDeviceLogin();
      _loaded = true;
      _emit(SyncAuthPhase.signedIn);
    } catch (error) {
      if (!_current(epoch)) return;
      try {
        _deviceGuard(epoch, login);
      } catch (_) {
        if (identical(login, _deviceLogin)) {
          // This continuation still owns the frame, but its persistent source
          // changed. Drop its code/transport and project the current binding.
          _stop();
          _fence = null;
          _loaded = false;
          final restoringEpoch = _epoch;
          try {
            await restoreSession();
          } catch (restoreError) {
            if (_current(restoringEpoch)) {
              _emit(SyncAuthPhase.error, error: _safe(restoreError));
            }
          }
        }
        return;
      }
      if (error is SyncRemoteFailure &&
          {'authorization_pending', 'slow_down'}.contains(error.code)) {
        if (error.code == 'slow_down')
          login.interval = (login.interval + 5).clamp(5, 60);
        login.polling = false;
        login.nextAt = _now() + login.interval * 1000000;
        _schedulePoll(epoch, login);
        return;
      }
      _dropDeviceLogin();
      _emit(SyncAuthPhase.loginRequired, error: _safe(error));
    } finally {
      login.polling = false;
    }
  }

  Future<SyncSecretRecord> _sealSession(
    SyncIdentity identity,
    SyncNativeSession session,
    void Function() guard,
  ) async {
    final result = SyncSecretRecord();
    try {
      result.protectedAccess = await _seal(
        identity,
        SyncLocalSecretKind.access,
        session.tokens.access.value,
        guard,
      );
      result.protectedRefresh = await _seal(
        identity,
        SyncLocalSecretKind.refresh,
        session.tokens.refresh.value,
        guard,
      );
      result.protectedStatusProof = await _seal(
        identity,
        SyncLocalSecretKind.statusProof,
        session.statusProof.value,
        guard,
      );
      return result;
    } catch (_) {
      _wipePrepared(result);
      rethrow;
    }
  }

  Future<List<int>> _seal(
    SyncIdentity identity,
    SyncLocalSecretKind kind,
    String value,
    void Function() guard,
  ) async {
    guard();
    final protected = await box.protectText(identity, kind, value);
    try {
      guard();
      return [...protected];
    } finally {
      protected.fillRange(0, protected.length, 0);
    }
  }

  void _wipePrepared(SyncSecretRecord record) {
    for (final bytes in [
      record.protectedAccess,
      record.protectedRefresh,
      record.protectedStatusProof,
    ]) {
      bytes?.fillRange(0, bytes.length, 0);
    }
  }

  Future<SyncBoundSecret> accessToken() async {
    final entryEpoch = _epoch;
    await restoreSession();
    _local(entryEpoch);
    final fence = _fence;
    if (fence == null || _access == null || _refresh == null) {
      throw const OperationFailure(FailureCode.authRequired);
    }
    _guard(_epoch, fence);
    // A durable marker is uncertain only without this live owner's flight.
    // Callers arriving after its commit must join the same pending rotation.
    final refreshing = _refreshing;
    if (refreshing != null) return refreshing;
    if (_blockedPhase(repository.domain.read((r) => r.syncState.errorCode)) !=
        null) {
      throw const OperationFailure(FailureCode.authRequired);
    }
    if (_expires <= _now()) return _refreshOnce();
    return _access!;
  }

  Future<SyncBoundSecret> _refreshOnce({SyncBoundSecret? rejected}) {
    final existing = _refreshing;
    if (existing != null) return existing;
    if (rejected != null &&
        _access != null &&
        !identical(rejected, _access) &&
        _expires > _now())
      return Future.value(_access!);
    final completer = Completer<SyncBoundSecret>();
    final future = completer.future;
    final epoch = _epoch, fence = _fence;
    _refreshing = future;
    unawaited(() async {
      try {
        final token = await _doRefresh();
        if (fence == null)
          throw const OperationFailure(FailureCode.authRequired);
        _guard(epoch, fence);
        completer.complete(token);
      } catch (error, stack) {
        completer.completeError(error, stack);
      } finally {
        if (identical(_refreshing, future)) _refreshing = null;
      }
    }());
    return future;
  }

  Future<SyncBoundSecret> _doRefresh() async {
    final epoch = _epoch,
        fence = _fence,
        refresh = _refresh,
        transport = _transport;
    if (fence == null || refresh == null || transport == null)
      throw const OperationFailure(FailureCode.authRequired);
    _guard(epoch, fence);
    final previous = repository.domain.read(
      (r) => r.syncSecrets.protectedRefresh,
    );
    if (previous == null)
      throw const OperationFailure(FailureCode.authRequired);
    try {
      await repository.beginAuthRefresh(fence, previous);
      _guard(epoch, fence);
      final start = _now();
      final tokens = await transport.refresh(refresh, cancel: _cancel);
      _guard(epoch, fence);
      final protectedAccess = await box.protectText(
        fence.identity,
        SyncLocalSecretKind.access,
        tokens.access.value,
      );
      Uint8List? protectedRefresh;
      try {
        _guard(epoch, fence);
        protectedRefresh = await box.protectText(
          fence.identity,
          SyncLocalSecretKind.refresh,
          tokens.refresh.value,
        );
        _guard(epoch, fence);
        await repository.completeAuthRefresh(
          fence,
          expectedRefresh: previous,
          access: protectedAccess,
          refresh: protectedRefresh,
          isCurrent: () => _current(epoch),
        );
      } finally {
        protectedAccess.fillRange(0, protectedAccess.length, 0);
        protectedRefresh?.fillRange(0, protectedRefresh.length, 0);
      }
      _guard(epoch, fence);
      _access = tokens.access;
      _refresh = tokens.refresh;
      _expires = start + 900000000;
      _emit(SyncAuthPhase.signedIn);
      return tokens.access;
    } catch (error) {
      if (_current(epoch) &&
          repository.domain.read((r) => fence.matches(r.syncState))) {
        // Once refresh may have reached the server, never replay its old token.
        if (repository.domain.read((r) => r.syncState.errorCode) ==
            syncRefreshInFlight) {
          if (error is SyncRemoteFailure &&
              (error.status == 401 ||
                  error.status == 403 ||
                  error.code == 'vault_reset')) {
            try {
              await _reconcileFailure(epoch, fence);
            } catch (_) {
              await _requireLogin(epoch, fence);
            }
          } else {
            await _requireLogin(epoch, fence);
          }
        }
      }
      rethrow;
    }
  }

  Future<void> _requireLogin(int epoch, SyncFence fence) async {
    _guard(epoch, fence);
    vault.lock();
    _access = null;
    _refresh = null;
    _expires = 0;
    _loaded = true;
    _emit(SyncAuthPhase.loginRequired, error: syncLoginRequired);
    final blocked = await repository.blockAuthorization(
      fence,
      syncLoginRequired,
    );
    _guard(epoch, blocked);
    _fence = blocked;
    _access = null;
    _refresh = null;
    _expires = 0;
    _loaded = true;
    _emit(SyncAuthPhase.loginRequired, error: syncLoginRequired);
  }

  Future<T> withAccess<T>(
    Future<T> Function(SyncTransport, SyncBoundSecret, SyncCancellation) action,
  ) async {
    final epoch = _epoch;
    var access = await accessToken();
    _local(epoch);
    final fence = _fence!;
    _guard(epoch, fence);
    final transport = _transport!;
    try {
      final result = await action(transport, access, _cancel);
      _guard(epoch, fence);
      return result;
    } on SyncRemoteFailure catch (error) {
      _guard(epoch, fence);
      if (error.status == 401 && error.code == 'token_expired') {
        access = await _refreshOnce(rejected: access);
        _guard(epoch, fence);
        try {
          final result = await action(transport, access, _cancel);
          _guard(epoch, fence);
          return result;
        } on SyncRemoteFailure catch (second) {
          if (second.status == 401 ||
              second.status == 403 ||
              second.code == 'vault_reset')
            await _reconcileFailure(epoch, fence);
          rethrow;
        }
      }
      if (error.status == 401 ||
          error.status == 403 ||
          error.code == 'vault_reset')
        await _reconcileFailure(epoch, fence);
      rethrow;
    }
  }

  Future<void> _reconcileFailure(int epoch, SyncFence fence) async {
    _guard(epoch, fence);
    final proof = _proof;
    if (proof == null) {
      await _requireLogin(epoch, fence);
      return;
    }
    final status = await _transport!.status(proof, cancel: _cancel);
    _guard(epoch, fence);
    if (status == SyncDeviceStatus.active) {
      await _requireLogin(epoch, fence);
      return;
    }
    final reason = status == SyncDeviceStatus.vaultReset
        ? syncVaultReset
        : syncDeviceRevoked;
    vault.lock();
    _access = null;
    _refresh = null;
    _expires = 0;
    _loaded = true;
    _emit(
      status == SyncDeviceStatus.vaultReset
          ? SyncAuthPhase.vaultReset
          : SyncAuthPhase.revoked,
      error: reason,
    );
    final blocked = await repository.blockAuthorization(fence, reason);
    _guard(epoch, blocked);
    _fence = blocked;
    _access = null;
    _refresh = null;
    _expires = 0;
    _loaded = true;
    _emit(
      status == SyncDeviceStatus.vaultReset
          ? SyncAuthPhase.vaultReset
          : SyncAuthPhase.revoked,
      error: reason,
    );
  }

  void cancelLogin() {
    if (_disposed) return;
    _stop();
    final marker = repository.domain.read((r) => r.syncState.errorCode);
    _emit(
      _paused
          ? SyncAuthPhase.paused
          : _fence == null
          ? SyncAuthPhase.disabled
          : _blockedPhase(marker) ?? SyncAuthPhase.signedIn,
    );
  }

  /// Android root explicitly opts in only for pending foreground browser approval.
  /// A token request/protection in flight is uncertain and is never resumed.
  void pause({bool preserveDeviceAuthorization = false}) {
    if (_disposed) return;
    if (_paused) {
      if (!preserveDeviceAuthorization && _deviceLogin != null) {
        _dropDeviceLogin();
        _emit(SyncAuthPhase.paused);
      }
      return;
    }
    final login = _deviceLogin;
    final keep =
        preserveDeviceAuthorization &&
        login != null &&
        login.android &&
        !login.polling &&
        !login.invalid;
    if (keep) login.suspended = true;
    _paused = true;
    _stop(preserveDeviceLogin: keep);
    _emit(SyncAuthPhase.paused);
  }

  Future<void> resume() async {
    if (_disposed) throw const SyncTransportCancelled();
    if (!_paused) return;
    _paused = false;
    final login = _deviceLogin;
    if (login != null && login.suspended) {
      login.suspended = false;
      final epoch = _epoch;
      try {
        _deviceGuard(epoch, login);
        _fence = login.previous;
        _loaded = true;
        if (_now() >= login.expires) {
          _dropDeviceLogin();
          _emit(SyncAuthPhase.loginRequired, error: 'expired_token');
          return;
        }
        _emit(SyncAuthPhase.awaitingApproval, flow: login.authorization);
        await login.browserFinished.future;
        _deviceGuard(epoch, login);
        if (!login.browserOpened) {
          _dropDeviceLogin();
          _emit(
            SyncAuthPhase.loginRequired,
            error: login.browserError ?? 'AUTH_FAILED',
          );
          return;
        }
        _transport = _makeTransport(login.origin);
        _schedulePoll(epoch, login);
      } catch (error) {
        if (!_current(epoch) || !identical(login, _deviceLogin)) rethrow;
        _dropDeviceLogin();
        _fence = null;
        _loaded = false;
        if (error is SyncTransportCancelled) {
          // A changed persistent binding/revocation/reset owns the new projection;
          // never leave the old approval's business identity or mask its marker.
          await restoreSession();
        } else {
          _loaded = true;
          _emit(SyncAuthPhase.loginRequired, error: _safe(error));
        }
      }
      return;
    }
    await restoreSession();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stop();
    unawaited(_cycleVaultChanges?.cancel());
    unawaited(_cycle?.dispose());
    unawaited(_lifecycle?.dispose());
    vault.dispose();
    merge.dispose();
    unawaited(_changes.close());
  }

  @override
  Future<SyncVaultContext> vaultContext() async {
    final epoch = _epoch;
    await restoreSession();
    _local(epoch);
    final fence = _fence;
    if (fence == null || _access == null || _refresh == null)
      throw const OperationFailure(FailureCode.authRequired);
    final context = SyncVaultContext(fence, epoch);
    guardVaultContext(context);
    return context;
  }

  @override
  bool isVaultContextCurrent(SyncVaultContext context) =>
      _current(context.epoch);
  @override
  void guardVaultContext(SyncVaultContext context) {
    _guard(context.epoch, context.fence);
    final marker = repository.domain.read((r) => r.syncState.errorCode);
    if ({
          syncLoginRequired,
          syncDeviceRevoked,
          syncVaultReset,
          syncDisconnectPending,
        }.contains(marker) ||
        marker == syncRefreshInFlight && _refreshing == null) {
      throw const OperationFailure(FailureCode.authRequired);
    }
  }

  Future<T> _vaultRequest<T>(
    SyncVaultContext context,
    SyncCancellation cancel,
    Future<T> Function(SyncTransport, SyncBoundSecret) action,
  ) async {
    guardVaultContext(context);
    return withAccess((transport, access, ownerCancel) async {
      guardVaultContext(context);
      final remove = ownerCancel.listen(cancel.cancel);
      try {
        final result = await action(transport, access);
        guardVaultContext(context);
        return result;
      } finally {
        remove();
      }
    });
  }

  @override
  Future<SyncHead> readVaultHead(
    SyncVaultContext context,
    SyncCancellation cancel,
  ) => _vaultRequest(
    context,
    cancel,
    (transport, access) => transport.head(
      access,
      vaultId: context.fence.identity.vaultId,
      cancel: cancel,
    ),
  );
  @override
  Future<Uint8List> readVaultRoot(
    SyncVaultContext context,
    SyncManifest manifest,
    SyncCancellation cancel,
  ) {
    if (manifest.vaultId != context.fence.identity.vaultId)
      return Future.error(syncInvalidWire);
    return _vaultRequest(
      context,
      cancel,
      (transport, access) => transport.download(
        access,
        ref: manifest.root,
        revision: manifest.revision,
        cancel: cancel,
      ),
    );
  }

  void _manifestContext(SyncVaultContext context, SyncManifest manifest) {
    guardVaultContext(context);
    if (manifest.vaultId != context.fence.identity.vaultId)
      throw syncInvalidWire;
  }

  @override
  Future<Uint8List> readVaultBlob(
    SyncVaultContext context,
    SyncManifest manifest,
    SyncBlobRef ref,
    SyncCancellation cancel,
  ) {
    _manifestContext(context, manifest);
    if (!manifest.objects.any(
      (value) => value.sha256 == ref.sha256 && value.bytes == ref.bytes,
    ))
      return Future.error(syncInvalidWire);
    return _vaultRequest(
      context,
      cancel,
      (transport, access) => transport.download(
        access,
        ref: ref,
        revision: manifest.revision,
        cancel: cancel,
      ),
    );
  }

  @override
  Future<SyncUploadDeclaration> declareVaultUpload(
    SyncVaultContext context,
    String uploadId,
    SyncManifest manifest,
    SyncCancellation cancel,
  ) {
    _manifestContext(context, manifest);
    return _vaultRequest(
      context,
      cancel,
      (transport, access) => transport.declare(
        access,
        uploadId: uploadId,
        expectedRevision: manifest.revision - 1,
        manifest: manifest,
        cancel: cancel,
      ),
    );
  }

  @override
  Future<void> uploadVaultBlob(
    SyncVaultContext context,
    String uploadId,
    SyncBlobRef ref,
    Uint8List bytes,
    SyncCancellation cancel,
  ) => _vaultRequest(
    context,
    cancel,
    (transport, access) => transport.upload(
      access,
      uploadId: uploadId,
      ref: ref,
      ciphertext: bytes,
      cancel: cancel,
    ),
  );
  @override
  Future<SyncCommitReceipt> commitVaultUpload(
    SyncVaultContext context,
    String uploadId,
    String commitId,
    SyncManifest manifest,
    SyncCancellation cancel,
  ) {
    _manifestContext(context, manifest);
    return _vaultRequest(
      context,
      cancel,
      (transport, access) => transport.commit(
        access,
        uploadId: uploadId,
        commitId: commitId,
        manifest: manifest,
        cancel: cancel,
      ),
    );
  }

  @override
  Future<void> cancelVaultUpload(
    SyncVaultContext context,
    String uploadId,
    SyncCancellation cancel,
  ) => _vaultRequest(
    context,
    cancel,
    (transport, access) =>
        transport.cancelUpload(access, uploadId, cancel: cancel),
  );
}
