part of 'sync_owner.dart';

const _disconnectConflict = OperationFailure(FailureCode.conflict);
const _disconnectStorage = OperationFailure(FailureCode.storageUnavailable);

enum SyncLocalDataChoice { keep, clear }

/// Safe source-bound confirmation metadata; no token, K or domain record content.
final class SyncDisconnectPreview {
  SyncDisconnectPreview._(
    this._owner,
    this._fence,
    this._dataRevision,
    this._stamp,
    this._profiles,
    this.profileCount,
    this.cardCount,
    this.pendingChanges,
    this.activeRoots,
    this.detachedRoots,
    this.nextOrigin,
  );
  final SyncAccountLifecycle _owner;
  final SyncFence _fence;
  final int _dataRevision;
  final String _stamp;
  final Map<String, int> _profiles;
  bool _used = false;
  final int profileCount, cardCount, pendingChanges, activeRoots, detachedRoots;
  final SyncServiceOrigin? nextOrigin;
  SyncIdentity get identity => _fence.identity;
  bool get requiresPreviousResolution => activeRoots > 0 && detachedRoots > 0;
}

final class SyncDisconnectResult {
  const SyncDisconnectResult({
    required this.remoteConfirmed,
    required this.cacheReclaimed,
  });
  final bool remoteConfirmed, cacheReclaimed;
  bool get localCompleted => true;
}

final class SyncDetachedPreview {
  SyncDetachedPreview._(
    this._owner,
    this._generation,
    this._stamp,
    this.count,
    this.origin,
    this.accountId,
    this.vaultId,
  );
  final SyncAccountLifecycle _owner;
  final int _generation;
  final String _stamp;
  bool _used = false;
  final int count;
  final String? origin, accountId, vaultId;
}

/// Root-owned native logout/rebind/clear coordinator. Register this capability
/// before runtime shutdown; a failed final clear retains a durable auth stop.
final class SyncAccountLifecycle implements RuntimeCapability {
  SyncAccountLifecycle._(this.owner, this.gate, this.actor, this.connections);
  final SyncOwner owner;
  final DomainCommandGate gate;
  final OwnerActor actor;
  final ProfileBatchPort connections;
  SyncRepository get repository => owner.repository;
  DomainRepository get domain => repository.domain;
  Future<SyncDisconnectResult>? _pending;
  Future<bool>? _auxiliary;
  bool get busy => _pending != null || _auxiliary != null;
  SyncCancellation? _cancel;
  SyncTransport? _remote;
  bool _stopped = false, _disposed = false;
  @override
  String get id => 'sync-account-lifecycle';

  void _alive() {
    if (_stopped || _disposed || owner._disposed || owner._paused)
      throw const SyncTransportCancelled();
  }

  String _stamp(DomainRead r) {
    final s = r.syncState,
        roots = r.syncRoots()..sort((a, b) => a.rootId.compareTo(b.rootId));
    if (r.syncRootCount() > 6 || roots.length != r.syncRootCount())
      throw _disconnectStorage;
    final bytes = canonicalSyncJson({
      'binding': [
        s.enabled,
        s.serviceOrigin,
        s.accountId,
        s.deviceId,
        s.vaultId,
      ],
      'versions': [s.syncGeneration, s.ackGeneration, s.baseRevision],
      'roots': [
        s.baseRootId,
        s.pendingRootId,
        s.pendingCommitId,
        s.pendingUploadId,
        s.pendingUploadDeviceId,
        s.pendingUploadRetiring,
        s.candidateRootId,
        s.conflictLocalId,
        s.conflictRemoteId,
      ],
      'proofs': [
        for (final root in roots)
          {
            'id': root.rootId,
            'role': root.role,
            'origin': root.serviceOrigin,
            'account': root.accountId,
            'vault': root.vaultId,
            'generation': root.sourceGeneration,
            'created': root.createdAt,
            'manifest': syncManifestForRoot(root).toJson(),
          },
      ],
    });
    try {
      return syncSha256(bytes);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  void _source(SyncDisconnectPreview preview, {SyncFence? fence}) {
    _alive();
    if (!identical(preview._owner, this)) throw _disconnectConflict;
    domain.read((r) {
      if (!(fence ?? preview._fence).matches(r.syncState) ||
          r.settings.dataRevision != preview._dataRevision ||
          _stamp(r) != preview._stamp)
        throw _disconnectConflict;
    });
  }

  Future<SyncDisconnectPreview> preview({SyncServiceOrigin? nextOrigin}) async {
    _alive();
    if (busy) throw _disconnectConflict;
    return gate.prepare(
      actor,
      (context) => context.read(() {
        _alive();
        final fence = repository.capture();
        return domain.read((r) {
          final state = r.syncState, profiles = r.profiles();
          if (profiles.length > 1000 || r.softwareCardCount() > 10000)
            throw _disconnectStorage;
          // Reserve both barrier and detach generations before any irreversible stop.
          final needsBarrier = state.errorCode != syncDisconnectPending;
          if (state.identityGeneration >
              syncMaxInteger - (needsBarrier ? 2 : 1))
            throw const OperationFailure(FailureCode.resourceExhausted);
          final roots = r.syncRoots();
          return SyncDisconnectPreview._(
            this,
            fence,
            r.settings.dataRevision,
            _stamp(r),
            Map.unmodifiable({
              for (final p in profiles) p.profileId: p.profileRevision,
            }),
            profiles.length,
            r.softwareCardCount(),
            state.syncGeneration - state.ackGeneration,
            roots.where((r) => r.role != 'detached').length,
            roots.where((r) => r.role == 'detached').length,
            nextOrigin,
          );
        });
      }),
    );
  }

  Future<SyncDisconnectResult> disconnect(
    SyncDisconnectPreview preview, {
    SyncLocalDataChoice choice = SyncLocalDataChoice.keep,
    bool discardPreviousDetached = false,
    bool revokeSelf = false,
  }) {
    if (busy)
      return Future.error(
        const OperationFailure(FailureCode.resourceExhausted, retryable: true),
      );
    if (preview._used || !identical(preview._owner, this))
      return Future.error(_disconnectConflict);
    preview._used = true;
    final result = _disconnect(
      preview,
      choice,
      discardPreviousDetached,
      revokeSelf,
    );
    _pending = result;
    void done() {
      if (identical(_pending, result)) {
        _pending = null;
        _cancel = null;
      }
    }

    result.then((_) => done(), onError: (Object _, StackTrace __) => done());
    return result;
  }

  Future<SyncDisconnectResult> _disconnect(
    SyncDisconnectPreview preview,
    SyncLocalDataChoice choice,
    bool discardPrevious,
    bool revokeSelf,
  ) async {
    ProfileMutationBatch? batch;
    void Function()? unlink;
    SyncFence fence = preview._fence;
    int? committedGeneration;
    var epoch = owner._epoch;
    var stoppedAuth = false;
    final clear = choice == SyncLocalDataChoice.clear;
    try {
      await gate.prepare(
        actor,
        (context) => context.read(() {
          _source(preview);
          if (!clear && preview.requiresPreviousResolution && !discardPrevious)
            throw _disconnectConflict;
          if (clear && preview.profileCount > 0) {
            domain.read((r) {
              nextRevision(r.settings.dataRevision);
              nextRevision(r.settings.profilesListRevision);
              EndpointReferences.validateBatch(
                r,
                before: r.profiles(),
                after: const [],
              );
            });
          }
        }),
      );
      _source(preview);
      final access = owner._access;
      owner._disconnectLocked = true;
      owner._stop();
      stoppedAuth = true;
      epoch = owner._epoch;
      owner._fence = fence;
      owner._loaded = true;
      owner._emit(
        SyncAuthPhase.disconnectRequired,
        error: syncDisconnectPending,
      );
      final cancel = _cancel = SyncCancellation();
      unlink = owner._cancel.listen(cancel.cancel);
      void guard() {
        _source(preview, fence: fence);
        if (epoch != owner._epoch ||
            cancel.cancelled ||
            !owner._disconnectLocked)
          throw const SyncTransportCancelled();
      }

      bool current() {
        try {
          guard();
          return true;
        } catch (_) {
          return false;
        }
      }

      guard();
      if (domain.read((r) => r.syncState.errorCode) != syncDisconnectPending) {
        fence = await repository.blockAuthorization(
          fence,
          syncDisconnectPending,
          isCurrent: current,
        );
      }
      guard();
      owner._fence = fence;
      if (owner._cycle != null) {
        await owner._cycle!.drain();
        guard();
      }
      final before = domain.read((r) => r.profiles());
      if (clear) {
        batch = await connections.reserveProfileBatch(
          actor,
          expectedProfiles: preview._profiles,
          targetEndpoints: const {},
          guard: guard,
        );
        guard();
        await batch.close();
        guard();
      }
      final readyBatch = batch;
      // The callback marks committed only after the actual native transaction,
      // before a possible command response rejection during runtime shutdown.
      await gate.prepare(
        actor,
        (context) => domain
            .write(
              (r) => context.linearize(() {
                guard();
                readyBatch?.check(context);
                if (r.syncState.errorCode != syncDisconnectPending ||
                    r.syncSecrets.protectedAccess != null ||
                    r.syncSecrets.protectedRefresh != null ||
                    r.syncSecrets.protectedVaultRootKey != null)
                  throw _disconnectConflict;
                final generation = repository.detachInTransaction(
                  r,
                  fence,
                  discardPreviousDetached: discardPrevious,
                  clearAllSync: clear,
                  nextOrigin: preview.nextOrigin?.value,
                );
                if (clear) {
                  EndpointReferences.reconcile(
                    r,
                    before: before,
                    after: const [],
                  );
                  for (final profile in before) {
                    r.deleteCredential(profile.credentialId);
                    r.deleteProfile(profile.profileId);
                  }
                  if (before.isNotEmpty) {
                    r.putSettings(
                      r.settings
                        ..dataRevision = nextRevision(r.settings.dataRevision)
                        ..profilesListRevision = nextRevision(
                          r.settings.profilesListRevision,
                        ),
                    );
                  }
                }
                return MutationValue(
                  entityId: preview.identity.vaultId,
                  revision: generation,
                );
              }),
            )
            .then((value) {
              committedGeneration = value.revision;
              return value;
            }),
      );
      final reclaimed = await _reclaim(epoch, committedGeneration!);
      final confirmed = await _notify(
        access,
        preview.identity,
        revokeSelf,
        cancel,
      );
      _finishMemory(committedGeneration!);
      return SyncDisconnectResult(
        remoteConfirmed: confirmed,
        cacheReclaimed: reclaimed,
      );
    } catch (error) {
      if (committedGeneration != null) {
        _finishMemory(committedGeneration!);
        return const SyncDisconnectResult(
          remoteConfirmed: false,
          cacheReclaimed: false,
        );
      }
      if (stoppedAuth) {
        owner._disconnectLocked = true;
        if (!owner._disposed && !owner._paused)
          owner._emit(
            SyncAuthPhase.disconnectRequired,
            error: syncDisconnectPending,
          );
      }
      if (error is OperationFailure ||
          error is WorkCancelled ||
          error is SyncTransportCancelled)
        rethrow;
      throw _disconnectStorage;
    } finally {
      batch?.release();
      unlink?.call();
      _remote?.dispose();
      _remote = null;
    }
  }

  Future<SyncDetachedPreview> previewDetached() {
    _alive();
    if (busy) return Future.error(_disconnectConflict);
    return gate.prepare(
      actor,
      (context) => context.read(
        () => domain.read((r) {
          _alive();
          final roots = r
              .syncRoots()
              .where((root) => root.role == 'detached')
              .toList();
          return SyncDetachedPreview._(
            this,
            r.syncState.identityGeneration,
            _stamp(r),
            roots.length,
            roots.isEmpty ? null : roots.first.serviceOrigin,
            roots.isEmpty ? null : roots.first.accountId,
            roots.isEmpty ? null : roots.first.vaultId,
          );
        }),
      ),
    );
  }

  Future<bool> discardDetached(SyncDetachedPreview preview) {
    if (preview._used || !identical(preview._owner, this))
      return Future.error(_disconnectConflict);
    preview._used = true;
    return _aux(() async {
      final epoch = owner._epoch;
      bool committed = false;
      try {
        await gate.prepare(
          actor,
          (context) => domain
              .write(
                (r) => context.linearize(() {
                  _alive();
                  if (epoch != owner._epoch ||
                      r.syncState.identityGeneration != preview._generation ||
                      _stamp(r) != preview._stamp)
                    throw _disconnectConflict;
                  repository.discardDetachedInTransaction(
                    r,
                    expectedGeneration: preview._generation,
                  );
                  return MutationValue(
                    entityId: preview.vaultId ?? 'local-sync-cache',
                    revision: r.settings.dataRevision,
                  );
                }),
              )
              .then((value) {
                committed = true;
                return value;
              }),
        );
        return await _reclaim(epoch, preview._generation);
      } catch (_) {
        if (committed) return false;
        rethrow;
      }
    });
  }

  /// Unbound local cleanup can be retried without logging back in. Active
  /// bindings use the cycle's GC owner instead of a concurrent sweep here.
  Future<bool> reclaimCache() => _aux(() async {
    final epoch = owner._epoch;
    final generation = await gate.prepare(
      actor,
      (context) => context.read(
        () => domain.read((r) {
          _alive();
          if (r.syncState.enabled) throw _disconnectConflict;
          return r.syncState.identityGeneration;
        }),
      ),
    );
    return _reclaim(epoch, generation);
  });

  Future<bool> _aux(Future<bool> Function() action) {
    if (busy)
      return Future.error(
        const OperationFailure(FailureCode.resourceExhausted, retryable: true),
      );
    _alive();
    final cancel = _cancel = SyncCancellation();
    final unlink = owner._cancel.listen(cancel.cancel);
    final future = _auxiliary = action();
    void done() {
      unlink();
      if (identical(_auxiliary, future)) {
        _auxiliary = null;
        _cancel = null;
      }
    }

    future.then((_) => done(), onError: (Object _, StackTrace __) => done());
    return future;
  }

  Future<bool> _reclaim(int epoch, int generation) async {
    var first = true;
    try {
      for (;;) {
        final pass = await repository.collectGarbagePass(
          expectedGeneration: generation,
          limit: 1000,
          restart: first,
          isCurrent: () =>
              !_stopped &&
              !_disposed &&
              !owner._disposed &&
              !owner._paused &&
              epoch == owner._epoch &&
              !(_cancel?.cancelled ?? true),
        );
        first = false;
        if (pass.finished) return true;
        await Future<void>.delayed(Duration.zero);
      }
    } catch (_) {
      return false;
    }
  }

  Future<bool> _notify(
    SyncBoundSecret? access,
    SyncIdentity identity,
    bool revokeSelf,
    SyncCancellation cancel,
  ) async {
    if (access == null ||
        cancel.cancelled ||
        _stopped ||
        _disposed ||
        owner._disposed)
      return false;
    try {
      final transport = _remote = owner._makeTransport(
        SyncServiceOrigin(identity.serviceOrigin),
      );
      if (revokeSelf) {
        await transport.revokeSelf(access, identity.deviceId, cancel: cancel);
      } else {
        await transport.logout(access, cancel: cancel);
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      _remote?.dispose();
      _remote = null;
    }
  }

  void _finishMemory(int generation) {
    final matches = domain.read(
      (r) =>
          !r.syncState.enabled &&
          r.syncState.identityGeneration == generation &&
          r.syncState.accountId == null,
    );
    if (!matches)
      return; // Never adopt another owner/binding's later generation.
    owner._disconnectLocked = false;
    owner._fence = null;
    owner._access = null;
    owner._refresh = null;
    owner._proof = null;
    owner._loaded = true;
    if (!owner._disposed)
      owner._emit(
        owner._paused ? SyncAuthPhase.paused : SyncAuthPhase.disabled,
      );
  }

  @override
  Future<void> stopAdmission() async {
    _stopped = true;
    await cancelPending();
  }

  @override
  Future<void> cancelPending() async {
    _cancel?.cancel();
    _remote?.dispose();
  }

  @override
  Future<void> closeSessions() async {}
  @override
  Future<void> drain() async {
    final pending = _pending;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
    final auxiliary = _auxiliary;
    if (auxiliary != null) {
      try {
        await auxiliary;
      } catch (_) {}
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await stopAdmission();
    await drain();
    _disposed = true;
  }
}

extension SyncAccountSessionActions on SyncOwner {
  Future<List<SyncRemoteDevice>> listDevices() => withAccess(
    (transport, access, cancel) => transport.devices(access, cancel: cancel),
  );

  /// Explicit proof-only check remains available after token expiry/login block.
  /// An active result never clears a durable auth stop or authorizes data requests.
  Future<SyncDeviceStatus> checkDeviceStatus() async {
    final entryEpoch = _epoch;
    await restoreSession();
    _local(entryEpoch);
    if (_disconnectLocked ||
        repository.domain.read((r) => r.syncState.errorCode) ==
            syncDisconnectPending)
      throw _disconnectConflict;
    final fence = _fence;
    if (fence == null) throw const OperationFailure(FailureCode.authRequired);
    _guard(entryEpoch, fence);
    final protected = repository.domain.read(
      (r) => r.syncSecrets.protectedStatusProof,
    );
    final saved =
        _proof?.value ??
        (protected == null
            ? null
            : await box.unprotectText(
                fence.identity,
                SyncLocalSecretKind.statusProof,
                protected,
              ));
    _guard(entryEpoch, fence);
    if (saved == null) throw const OperationFailure(FailureCode.authRequired);
    final proof = SyncBoundSecret(
      origin: SyncServiceOrigin(fence.identity.serviceOrigin),
      kind: SyncSecretKind.statusProof,
      value: saved,
    );
    final transport = _transport ??= _makeTransport(proof.origin);
    final status = await transport.status(proof, cancel: _cancel);
    _guard(entryEpoch, fence);
    _proof = proof;
    if (status != SyncDeviceStatus.active) {
      final reason = status == SyncDeviceStatus.vaultReset
          ? syncVaultReset
          : syncDeviceRevoked;
      vault.lock();
      _cycle?.pause();
      _access = null;
      _refresh = null;
      _expires = 0;
      final blocked =
          repository.domain.read((r) => r.syncState.errorCode) == reason
          ? fence
          : await repository.blockAuthorization(
              fence,
              reason,
              isCurrent: () => _current(entryEpoch),
            );
      _guard(entryEpoch, blocked);
      _fence = blocked;
      _loaded = true;
      _emit(
        status == SyncDeviceStatus.vaultReset
            ? SyncAuthPhase.vaultReset
            : SyncAuthPhase.revoked,
        error: reason,
      );
    }
    return status;
  }

  /// Browser recent-auth handles other-device revoke and destructive cloud reset.
  /// Never attach native tokens/proofs/keys or untrusted query parameters to URI.
  Future<void> openDeviceManagement({SyncServiceOrigin? service}) async {
    final epoch = _epoch;
    _local(epoch);
    final generation = repository.domain.read(
      (r) => r.syncState.identityGeneration,
    );
    final value =
        service?.value ??
        repository.domain.read((r) => r.syncState.serviceOrigin);
    if (value == null)
      throw const OperationFailure(FailureCode.invalidArgument);
    final origin = SyncServiceOrigin(value);
    await browser.openServicePage(
      serviceOrigin: Uri.parse(origin.value),
      page: Uri.parse(origin.value).replace(path: '/devices'),
    );
    // This is only an acknowledgement of an already-opened public page. Android
    // browser handoff may pause/resume this owner; it grants no data authority.
    if (_disposed ||
        repository.domain.read((r) => r.syncState.identityGeneration) !=
            generation)
      throw const SyncTransportCancelled();
  }
}
