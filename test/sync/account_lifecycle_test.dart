import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/sync/sync_http.dart';
import 'package:serverdeck/sync/sync_apply.dart';
import 'package:serverdeck/sync/sync_atomic_apply.dart';
import 'package:serverdeck/sync/sync_cycle.dart';
import 'package:serverdeck/sync/sync_recovery.dart';
import 'package:serverdeck/sync/sync_models.dart';
import 'package:serverdeck/sync/sync_owner.dart';
import 'package:serverdeck/sync/sync_repository.dart';
import 'package:serverdeck/sync/sync_transport.dart';
import 'package:serverdeck/sync/sync_wire.dart';

import '../fixtures/feature_harness.dart';
import '../fixtures/sync_lifecycle.dart';
import 'transport_test.dart' as wire;

void main() {
  late LifecycleHarness h;
  setUp(() async {
    h = LifecycleHarness();
    await h.setup();
  });
  tearDown(() => h.dispose());

  test(
    'default keep logout retains local SSH, trust and pending encrypted roots',
    () async {
      final id = await h.local.feature.create(),
          session = await h.local.connected(id);
      final pending = await h.local.remote([h.local.stored(id)], pending: true);
      final before = h.local.feature.repository.state;
      final data = before.settings.dataRevision, profile = before.profiles[id]!;
      final secret = before.credentials[profile.credentialId]!.protectedBytes
          .toList();
      final preview = await h.lifecycle.preview();
      expect(preview.profileCount, 1);
      expect(preview.activeRoots, 1);
      final result = await h.lifecycle.disconnect(preview);
      final domain = h.local.feature.repository.state;
      expect(result.localCompleted, isTrue);
      expect(result.remoteConfirmed, isTrue);
      expect(domain.syncState.enabled, isFalse);
      expect(domain.syncState.accountId, isNull);
      expect(domain.syncSecrets.protectedAccess, isNull);
      expect(domain.syncSecrets.protectedRefresh, isNull);
      expect(domain.syncSecrets.protectedStatusProof, isNull);
      expect(domain.syncSecrets.protectedVaultRootKey, isNull);
      expect(domain.syncRoots[pending.rootId]!.role, 'detached');
      expect(domain.profiles[id]!.profileRevision, profile.profileRevision);
      expect(domain.credentials[profile.credentialId]!.protectedBytes, secret);
      expect(domain.settings.dataRevision, data);
      expect(domain.endpoints[profile.endpointId]!.acceptedKeyBytes, isNotNull);
      expect(session.closeCalls, 0);
      expect(h.owner.view.phase, SyncAuthPhase.disabled);
      expect(h.count('/v1/logout'), 1);
      expect(h.count('/v1/token/refresh'), 0);
    },
  );

  test('clear logout closes SSH then atomically deletes portable domain and sync copies', () async {
    final id = await h.local.feature.create(),
        session = await h.local.connected(id);
    await h.local.remote([h.local.stored(id)], pending: true);
    final revision = h.local.feature.repository.state.settings.dataRevision;
    final result = await h.lifecycle.disconnect(
      await h.lifecycle.preview(),
      choice: SyncLocalDataChoice.clear,
    );
    final domain = h.local.feature.repository.state;
    expect(result.localCompleted, isTrue);
    expect(result.cacheReclaimed, isTrue);
    expect(session.closeCalls, 1);
    expect(domain.profiles, isEmpty);
    expect(domain.credentials, isEmpty);
    expect(domain.endpoints, isEmpty);
    expect(domain.syncRoots, isEmpty);
    expect(domain.syncObjects, isEmpty);
    expect(domain.settings.dataRevision, revision + 1);
    expect(domain.syncState.syncGeneration, 0);
  });

  test('offline server does not prevent local logout and reports no remote confirmation', () async {
    await h.local.feature.create();
    h.handler = (request) async {
      if (request.uri.path == '/v1/logout')
        throw StateError('synthetic offline');
      return null;
    };
    final result = await h.lifecycle.disconnect(await h.lifecycle.preview());
    expect(result.localCompleted, isTrue);
    expect(result.remoteConfirmed, isFalse);
    expect(h.local.feature.repository.state.syncState.enabled, isFalse);
    expect(h.local.feature.repository.state.profiles.length, 1);
    expect(h.count('/v1/logout'), 1);
  });

  test('stale preview rejects before stopping auth', () async {
    final id = await h.local.feature.create();
    final preview = await h.lifecycle.preview();
    final changed = await h.local.feature.profiles.updateProfile(
      h.local.feature.actors.ui,
      id,
      const ProfilePatch(displayName: 'later'),
      expectedRevision: 1,
      mutationId: 'later-preview',
    );
    expect(changed.ok, isTrue);
    await expectLater(
      h.lifecycle.disconnect(preview),
      throwsA(featureFailure(FailureCode.conflict)),
    );
    expect(h.owner.view.phase, SyncAuthPhase.signedIn);
    expect(
      h.local.feature.repository.state.syncSecrets.protectedAccess,
      isNotNull,
    );
    expect(h.http.requests, isEmpty);
  });

  test('final write failure preserves data and durable disconnect blocks restart restoration', () async {
    final id = await h.local.feature.create();
    await h.local.connected(id);
    final pending = await h.local.remote([h.local.stored(id)], pending: true);
    h.local.batches.afterClose = () async {
      h.local.feature.repository.failCommit = true;
    };
    await expectLater(
      h.lifecycle.disconnect(
        await h.lifecycle.preview(),
        choice: SyncLocalDataChoice.clear,
      ),
      throwsA(isA<OperationFailure>()),
    );
    final domain = h.local.feature.repository.state;
    expect(domain.profiles.keys, [id]);
    expect(domain.syncState.pendingRootId, pending.rootId);
    expect(domain.syncState.errorCode, syncDisconnectPending);
    expect(domain.syncSecrets.protectedAccess, isNull);
    expect(domain.syncSecrets.protectedVaultRootKey, isNull);
    expect(h.owner.view.phase, SyncAuthPhase.disconnectRequired);
    expect(h.count('/v1/logout'), 0);
    h.local.batches.afterClose = null;
    await h.recreate();
    expect(h.owner.view.phase, SyncAuthPhase.disconnectRequired);
    await expectLater(h.owner.accessToken(), throwsA(isA<OperationFailure>()));
    final result = await h.lifecycle.disconnect(await h.lifecycle.preview());
    expect(result.localCompleted, isTrue);
    expect(h.local.feature.repository.state.profiles.keys, [id]);
    expect(
      h.local.feature.repository.state.syncRoots[pending.rootId]!.role,
      'detached',
    );
  });

  test('lost local barrier write is fail-closed in memory and fresh preview can retry', () async {
    await h.local.feature.create();
    h.local.feature.repository.failCommit = true;
    await expectLater(
      h.lifecycle.disconnect(await h.lifecycle.preview()),
      throwsA(isA<OperationFailure>()),
    );
    expect(h.owner.view.phase, SyncAuthPhase.disconnectRequired);
    await expectLater(h.owner.accessToken(), throwsA(isA<OperationFailure>()));
    expect(h.http.requests, isEmpty);
    final result = await h.lifecycle.disconnect(await h.lifecycle.preview());
    expect(result.localCompleted, isTrue);
  });

  test('status proof after login block distinguishes reset without access or refresh', () async {
    await h.local.feature.create();
    final pending = await h.local.remote([
      h.local.stored(h.local.feature.repository.state.profiles.keys.single),
    ], pending: true);
    await h.local.repository.blockAuthorization(
      h.local.repository.capture(),
      syncLoginRequired,
    );
    await h.recreate();
    h.status = 'vault_reset';
    expect(await h.owner.checkDeviceStatus(), SyncDeviceStatus.vaultReset);
    expect(h.owner.view.phase, SyncAuthPhase.vaultReset);
    expect(h.count('/v1/device-status'), 1);
    expect(h.count('/v1/token/refresh'), 0);
    expect(
      h.local.feature.repository.state.syncState.pendingRootId,
      pending.rootId,
    );
    expect(
      h.local.feature.repository.state.syncSecrets.protectedVaultRootKey,
      isNull,
    );
    expect(h.local.feature.repository.state.profiles.length, 1);
  });

  test(
    'proof active cannot silently restore revoked native data authority',
    () async {
      await h.local.repository.blockAuthorization(
        h.local.repository.capture(),
        syncDeviceRevoked,
      );
      await h.recreate();
      h.status = 'active';
      expect(await h.owner.checkDeviceStatus(), SyncDeviceStatus.active);
      expect(h.owner.view.phase, SyncAuthPhase.revoked);
      await expectLater(
        h.owner.accessToken(),
        throwsA(isA<OperationFailure>()),
      );
      expect(h.count('/v1/token/refresh'), 0);
    },
  );

  test('browser management carries only origin/devices and device list uses vetted projection', () async {
    h.devices.add({
      'id': h.local.fence.identity.deviceId,
      'name': 'My Windows',
      'platform': 'windows',
      'last_seen_at': 10,
    });
    final devices = await h.owner.listDevices();
    expect(devices.single.name, 'My Windows');
    await h.owner.openDeviceManagement();
    expect(
      h.browser.pages.single.$2.toString(),
      '${h.local.fence.identity.serviceOrigin}/devices',
    );
    expect(h.browser.pages.single.$2.hasQuery, isFalse);
    expect(
      h.browser.pages.single.$1.toString(),
      h.local.fence.identity.serviceOrigin,
    );
  });

  test('new account B rejects late A response and keeps old encrypted namespace detached', () async {
    final id = await h.local.feature.create();
    final pending = await h.local.remote([h.local.stored(id)], pending: true);
    final response = Completer<SyncHttpResponse>();
    h.handler = (request) async =>
        request.uri.path == '/v1/devices' ? response.future : null;
    final old = h.owner.listDevices();
    final failed = expectLater(old, throwsA(isA<SyncTransportCancelled>()));
    await featureTurns();
    await h.lifecycle.disconnect(await h.lifecycle.preview());
    h.handler = null;
    await h.login(
      account: featureId(8200),
      vault: featureId(8201),
      device: featureId(8202),
    );
    response.complete(wire.jsonResponse({'devices': <Object?>[]}));
    await failed;
    final domain = h.local.feature.repository.state;
    expect(domain.syncState.accountId, h.nextAccount);
    expect(domain.syncState.vaultId, h.nextVault);
    expect(domain.syncRoots[pending.rootId]!.role, 'detached');
    expect(
      domain.syncRoots[pending.rootId]!.accountId,
      h.local.fence.identity.accountId,
    );
    expect(domain.profiles.keys, [id]);
  });

  test('service rebind saves new origin only after auth stop and never forwards old credentials there', () async {
    final next = SyncServiceOrigin('https://new-sync.example.test');
    await h.lifecycle.disconnect(await h.lifecycle.preview(nextOrigin: next));
    expect(
      h.local.feature.repository.state.syncState.serviceOrigin,
      next.value,
    );
    expect(h.http.requests.where((r) => r.uri.origin == next.value), isEmpty);
    expect(
      h.http.requests.single.uri.origin,
      h.local.fence.identity.serviceOrigin,
    );
    expect(h.http.requests.single.uri.path, '/v1/logout');
    expect(
      h.local.feature.repository.state.syncSecrets.protectedAccess,
      isNull,
    );
  });

  test('a previous detached set requires explicit resolution before detaching another set', () async {
    final id = await h.local.feature.create();
    final old = await h.local.remote([h.local.stored(id)], pending: true);
    await h.lifecycle.disconnect(await h.lifecycle.preview());
    await h.login(
      account: featureId(8300),
      vault: featureId(8301),
      device: featureId(8302),
    );
    final fence = h.local.repository.capture(), root = featureId(8310);
    // Opaque reachability fixture: logout does not require decrypting old keys.
    await h.local.repository.stageRoot(
      fence,
      rootId: root,
      snapshotId: featureId(8311),
      revision: 1,
      sourceGeneration:
          h.local.feature.repository.state.syncState.syncGeneration,
      rootCiphertext: Uint8List(28),
      objects: const [],
      pending: true,
      commitId: featureId(8312),
    );
    final preview = await h.lifecycle.preview();
    expect(preview.requiresPreviousResolution, isTrue);
    await expectLater(
      h.lifecycle.disconnect(preview),
      throwsA(featureFailure(FailureCode.conflict)),
    );
    expect(h.owner.view.phase, SyncAuthPhase.signedIn);
    expect(
      h.local.feature.repository.state.syncRoots[old.rootId]!.role,
      'detached',
    );
    await h.lifecycle.disconnect(
      await h.lifecycle.preview(),
      discardPreviousDetached: true,
    );
    expect(h.local.feature.repository.state.syncRoots.keys, [root]);
    expect(h.local.feature.repository.state.syncRoots[root]!.role, 'detached');
    expect(h.local.feature.repository.state.profiles.keys, [id]);
  });

  test('explicit detached discard removes only old encrypted history and can reclaim while unbound', () async {
    final id = await h.local.feature.create();
    await h.local.remote([h.local.stored(id)], pending: true);
    await h.lifecycle.disconnect(await h.lifecycle.preview());
    final preview = await h.lifecycle.previewDetached();
    expect(preview.count, 1);
    expect(preview.accountId, h.local.fence.identity.accountId);
    expect(await h.lifecycle.discardDetached(preview), isTrue);
    final domain = h.local.feature.repository.state;
    expect(domain.syncRoots, isEmpty);
    expect(domain.syncObjects, isEmpty);
    expect(domain.profiles.keys, [id]);
    expect(domain.credentials.length, 1);
    expect(await h.lifecycle.reclaimCache(), isTrue);
  });

  test(
    'late status proof response from A cannot reset newly bound B',
    () async {
      final response = Completer<SyncHttpResponse>();
      h.handler = (request) async =>
          request.uri.path == '/v1/device-status' ? response.future : null;
      final old = h.owner.checkDeviceStatus();
      final cancelled = expectLater(
        old,
        throwsA(isA<SyncTransportCancelled>()),
      );
      await featureTurns();
      await h.lifecycle.disconnect(await h.lifecycle.preview());
      h.handler = null;
      await h.login(
        account: featureId(8400),
        vault: featureId(8401),
        device: featureId(8402),
      );
      final before = h
          .local
          .feature
          .repository
          .state
          .syncSecrets
          .protectedAccess!
          .toList();
      response.complete(wire.jsonResponse({'status': 'vault_reset'}));
      await cancelled;
      expect(h.owner.view.phase, SyncAuthPhase.signedIn);
      expect(
        h.local.feature.repository.state.syncState.accountId,
        featureId(8400),
      );
      expect(
        h.local.feature.repository.state.syncSecrets.protectedAccess,
        before,
      );
    },
  );

  test(
    'late rotating refresh cannot restore secrets after confirmed logout',
    () async {
      final response = Completer<SyncHttpResponse>();
      h.handler = (request) async =>
          request.uri.path == '/v1/token/refresh' ? response.future : null;
      final refresh = h.owner.accessToken();
      final cancelled = expectLater(
        refresh,
        throwsA(isA<SyncTransportCancelled>()),
      );
      await featureTurns();
      expect(
        h.local.feature.repository.state.syncState.errorCode,
        syncRefreshInFlight,
      );
      await h.lifecycle.disconnect(await h.lifecycle.preview());
      response.complete(
        wire.jsonResponse({
          'access_token': wire.token(5),
          'refresh_token': wire.token(6),
          'expires_in': 900,
        }),
      );
      await cancelled;
      expect(h.local.feature.repository.state.syncState.enabled, isFalse);
      expect(
        h.local.feature.repository.state.syncSecrets.protectedAccess,
        isNull,
      );
      expect(
        h.local.feature.repository.state.syncSecrets.protectedRefresh,
        isNull,
      );
    },
  );

  test(
    'pause at barrier write prevents mutation and retry remains explicit',
    () async {
      await h.local.feature.create();
      h.local.feature.repository.beforeWrite = () async => h.owner.pause();
      await expectLater(
        h.lifecycle.disconnect(await h.lifecycle.preview()),
        throwsA(isA<OperationFailure>()),
      );
      expect(
        h.local.feature.repository.state.syncSecrets.protectedAccess,
        isNotNull,
      );
      expect(h.local.feature.repository.state.profiles.length, 1);
      h.local.feature.repository.beforeWrite = null;
      await h.owner.resume();
      expect(h.owner.view.phase, SyncAuthPhase.disconnectRequired);
      expect(h.http.requests, isEmpty);
      expect(
        (await h.lifecycle.disconnect(await h.lifecycle.preview()))
            .localCompleted,
        isTrue,
      );
    },
  );

  test('partial final transaction rolls back roots trust credentials and domain together', () async {
    final id = await h.local.feature.create(),
        session = await h.local.connected(id);
    final root = await h.local.remote([h.local.stored(id)], pending: true);
    h.local.batches.afterClose = () async =>
        h.local.feature.repository.failAfterWrite = 3;
    await expectLater(
      h.lifecycle.disconnect(
        await h.lifecycle.preview(),
        choice: SyncLocalDataChoice.clear,
      ),
      throwsA(isA<OperationFailure>()),
    );
    final domain = h.local.feature.repository.state;
    expect(domain.profiles.keys, [id]);
    expect(domain.credentials.length, 1);
    expect(domain.endpoints.length, 1);
    expect(domain.syncState.pendingRootId, root.rootId);
    expect(domain.syncRoots[root.rootId]!.role, 'pending');
    expect(domain.syncState.errorCode, syncDisconnectPending);
    expect(session.closeCalls, 1);
    h.local.feature.repository.failAfterWrite = null;
  });

  test('new local profile after SSH close aborts clear without dropping either profile', () async {
    final id = await h.local.feature.create();
    await h.local.connected(id);
    String? second;
    h.local.batches.afterClose = () async =>
        second = await h.local.feature.create(host: 'new.invalid');
    await expectLater(
      h.lifecycle.disconnect(
        await h.lifecycle.preview(),
        choice: SyncLocalDataChoice.clear,
      ),
      throwsA(featureFailure(FailureCode.conflict)),
    );
    expect(h.local.feature.repository.state.profiles.keys.toSet(), {
      id,
      second,
    });
    expect(
      h.local.feature.repository.state.syncState.errorCode,
      syncDisconnectPending,
    );
  });

  test('counter preflight rejects clear before stopping auth but keep logout still works', () async {
    final id = await h.local.feature.create(),
        session = await h.local.connected(id);
    h.local.feature.repository.state.settings.dataRevision = syncMaxInteger;
    await expectLater(
      h.lifecycle.disconnect(
        await h.lifecycle.preview(),
        choice: SyncLocalDataChoice.clear,
      ),
      throwsA(featureFailure(FailureCode.resourceExhausted)),
    );
    expect(h.owner.view.phase, SyncAuthPhase.signedIn);
    expect(session.closeCalls, 0);
    expect(
      (await h.lifecycle.disconnect(await h.lifecycle.preview()))
          .localCompleted,
      isTrue,
    );
    expect(h.local.feature.repository.state.profiles.keys, [id]);
  });

  test('close failure quarantines and preserves saved state, keep decision remains possible', () async {
    final id = await h.local.feature.create(),
        session = await h.local.connected(id);
    session.failClose = true;
    await expectLater(
      h.lifecycle.disconnect(
        await h.lifecycle.preview(),
        choice: SyncLocalDataChoice.clear,
      ),
      throwsA(featureFailure(FailureCode.cleanupRequired)),
    );
    expect(h.local.feature.repository.state.profiles.keys, [id]);
    expect(
      h.local.feature.connections.isQuarantined(
        h.local.feature.repository.state.profiles[id]!.endpointId,
      ),
      isTrue,
    );
    expect(
      (await h.lifecycle.disconnect(await h.lifecycle.preview()))
          .localCompleted,
      isTrue,
    );
    expect(h.local.feature.repository.state.profiles.keys, [id]);
  });

  test('logout is single flight while owned SSH cleanup is waiting', () async {
    final id = await h.local.feature.create(),
        session = await h.local.connected(id);
    session.holdClose = Completer<void>();
    final preview = await h.lifecycle.preview();
    final active = h.lifecycle.disconnect(
      preview,
      choice: SyncLocalDataChoice.clear,
    );
    await featureTurns();
    expect(h.lifecycle.busy, isTrue);
    expect(
      h.local.feature.repository.state.syncSecrets.protectedAccess,
      isNull,
    );
    await expectLater(
      h.lifecycle.disconnect(preview),
      throwsA(featureFailure(FailureCode.resourceExhausted)),
    );
    expect(h.count('/v1/logout'), 0);
    session.holdClose!.complete();
    expect((await active).localCompleted, isTrue);
    expect(h.count('/v1/logout'), 1);
  });

  test('own revoke uses captured device endpoint without refreshing or deleting kept local data', () async {
    final id = await h.local.feature.create();
    final result = await h.lifecycle.disconnect(
      await h.lifecycle.preview(),
      revokeSelf: true,
    );
    expect(result.remoteConfirmed, isTrue);
    expect(h.count('/v1/devices/${h.local.fence.identity.deviceId}/revoke'), 1);
    expect(h.count('/v1/logout'), 0);
    expect(h.count('/v1/token/refresh'), 0);
    expect(h.local.feature.repository.state.profiles.keys, [id]);
  });

  test('cache failure after local commit is reported and unbound cleanup can be retried', () async {
    final id = await h.local.feature.create();
    await h.local.remote([h.local.stored(id)], pending: true);
    h.local.feature.repository.beforeWrite = () async {
      if (!h.local.feature.repository.state.syncState.enabled)
        throw StateError('synthetic GC refusal');
    };
    final result = await h.lifecycle.disconnect(
      await h.lifecycle.preview(),
      choice: SyncLocalDataChoice.clear,
    );
    expect(result.localCompleted, isTrue);
    expect(result.cacheReclaimed, isFalse);
    expect(h.local.feature.repository.state.profiles, isEmpty);
    expect(h.local.feature.repository.state.syncObjects, isNotEmpty);
    h.local.feature.repository.beforeWrite = null;
    expect(await h.lifecycle.reclaimCache(), isTrue);
    expect(h.local.feature.repository.state.syncObjects, isEmpty);
  });

  test(
    'new service login sends no old bearer or proof to its origin',
    () async {
      final next = SyncServiceOrigin('https://new-sync.example.test');
      await h.lifecycle.disconnect(await h.lifecycle.preview(nextOrigin: next));
      await h.login(
        origin: next,
        account: featureId(8500),
        vault: featureId(8501),
        device: featureId(8502),
      );
      final requests = h.http.requests
          .where((r) => r.uri.origin == next.value)
          .toList();
      expect(requests.map((r) => r.uri.path), [
        '/v1/device-authorizations',
        '/v1/device-token',
      ]);
      for (final request in requests) {
        expect(
          request.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains('authorization')),
        );
      }
      expect(
        h.local.feature.repository.state.syncState.serviceOrigin,
        next.value,
      );
      expect(
        h.local.feature.repository.state.syncSecrets.protectedVaultRootKey,
        isNull,
      );
    },
  );
  test('restored disconnect marker cannot be cleared by a proof-only status action', () async {
    await h.local.repository.blockAuthorization(
      h.local.repository.capture(),
      syncDisconnectPending,
    );
    await h.recreate();
    h.status = 'revoked';
    await expectLater(
      h.owner.checkDeviceStatus(),
      throwsA(featureFailure(FailureCode.conflict)),
    );
    expect(
      h.local.feature.repository.state.syncState.errorCode,
      syncDisconnectPending,
    );
    expect(h.owner.view.phase, SyncAuthPhase.disconnectRequired);
    expect(h.count('/v1/device-status'), 0);
  });

  test('metadata-only logout never relies on a free-space probe', () async {
    await h.local.feature.create();
    var probes = 0;
    h.local.probe = () async {
      probes++;
      throw StateError('synthetic unknown free space');
    };
    expect(
      (await h.lifecycle.disconnect(await h.lifecycle.preview()))
          .localCompleted,
      isTrue,
    );
    expect(probes, 0);
  });

  test('management of an unconfirmed former device can open its old service after rebind', () async {
    final old = SyncServiceOrigin(h.local.fence.identity.serviceOrigin);
    final next = SyncServiceOrigin('https://new-sync.example.test');
    await h.lifecycle.disconnect(await h.lifecycle.preview(nextOrigin: next));
    await h.owner.openDeviceManagement(service: old);
    expect(h.browser.pages.single.$1.toString(), old.value);
    expect(h.browser.pages.single.$2.toString(), '${old.value}/devices');
    expect(
      h.local.feature.repository.state.syncState.serviceOrigin,
      next.value,
    );
  });
  test('reset recovery uses a new vault key and still requires explicit local import consent', () async {
    final id = await h.local.feature.create();
    final old = await h.local.remote([h.local.stored(id)], pending: true);
    h.status = 'vault_reset';
    await h.owner.checkDeviceStatus();
    expect(h.owner.view.phase, SyncAuthPhase.vaultReset);
    await h.lifecycle.disconnect(await h.lifecycle.preview());
    await h.login(vault: featureId(8601), device: featureId(8602));
    expect(
      h.local.feature.repository.state.syncSecrets.protectedVaultRootKey,
      isNull,
    );
    final transfer = SyncCredentialTransfer(
      repository: h.local.feature.repository,
      secrets: h.local.secrets,
      inspector: h.local.transfer.inspector,
      access: h.owner,
    );
    final apply = SyncApply(
      repository: h.local.repository,
      transfer: transfer,
      gate: h.local.feature.gate,
      actor: h.local.feature.actors.owner,
      connections: h.local.batches,
      newId: h.local.feature.newId,
      utcNow: h.local.feature.clock.now,
    );
    final cycle = h.owner.configureCycle(
      transfer: transfer,
      apply: apply,
      newId: h.local.feature.newId,
      utcNow: h.local.feature.clock.now,
      schedule: h.local.feature.clock.schedule,
      monotonicMicros: () => h.local.feature.clock.elapsed.inMicroseconds,
    );
    await h.owner.vault.inspect();
    expect(h.owner.vault.view.phase, SyncVaultPhase.needsInitialization);
    final challenge = await h.owner.vault.beginInitialization();
    expect(challenge.code, isNot(SyncRecoveryCodec.encode(Uint8List(32))));
    await h.owner.vault.confirmInitialization(
      challenge,
      saved: true,
      checksum: challenge.checksum,
    );
    await featureTurns(100);
    expect(h.owner.vault.view.phase, SyncVaultPhase.ready);
    expect(cycle.view.phase, SyncCyclePhase.consent);
    expect(
      h.local.feature.repository.state.syncRoots[old.rootId]!.role,
      'detached',
    );
    expect(
      h.local.feature.repository.state.syncRoots[old.rootId]!.vaultId,
      h.local.fence.identity.vaultId,
    );
    expect(h.local.feature.repository.state.syncState.vaultId, featureId(8601));
    expect(h.local.feature.repository.state.profiles.keys, [id]);
    expect(h.count('/v1/vault/uploads'), 0);
  });

  test('response invalidation after committed clear does not report a rolled-back logout', () async {
    await h.local.feature.create();
    final subscription = h.local.feature.repository.domainChanges.listen((_) {
      if (!h.local.feature.repository.state.syncState.enabled)
        h.local.feature.running = false;
    });
    addTearDown(subscription.cancel);
    final result = await h.lifecycle.disconnect(
      await h.lifecycle.preview(),
      choice: SyncLocalDataChoice.clear,
    );
    expect(result.localCompleted, isTrue);
    expect(result.remoteConfirmed, isFalse);
    expect(h.local.feature.repository.state.syncState.enabled, isFalse);
    expect(h.local.feature.repository.state.profiles, isEmpty);
    expect(
      h.local.feature.repository.state.syncSecrets.protectedAccess,
      isNull,
    );
    expect(h.owner.view.phase, SyncAuthPhase.disabled);
  });
  test('public device page acknowledgement survives ordinary pause but rejects changed identity', () async {
    h.browser.onOpen = () => h.owner.pause();
    await h.owner.openDeviceManagement();
    expect(h.owner.view.phase, SyncAuthPhase.paused);
    expect(h.browser.pages.single.$2.path, '/devices');
    await h.owner.resume();
    h.browser.onOpen = () async {
      await h.lifecycle.disconnect(await h.lifecycle.preview());
    };
    await expectLater(
      h.owner.openDeviceManagement(),
      throwsA(isA<SyncTransportCancelled>()),
    );
    expect(h.local.feature.repository.state.syncState.enabled, isFalse);
  });
}
