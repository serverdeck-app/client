import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/runtime/owned_work.dart';
import 'package:serverdeck/storage/records.dart';
import 'package:serverdeck/software/software_models.dart';
import 'package:serverdeck/sync/sync_merge.dart';
import 'package:serverdeck/sync/sync_models.dart';
import 'package:serverdeck/sync/sync_crypto.dart';
import 'package:serverdeck/sync/sync_transport.dart';

import '../fixtures/feature_harness.dart';
import '../fixtures/sync_apply.dart';
import 'content_validation_test.dart' as data;

PortableSyncProfile profile(int n, {String? password}) {
  final value = data.profile(number: n);
  if (password != null)
    (value['credential']! as Map)['originalBase64'] = base64.encode(
      utf8.encode(password),
    );
  return PortableSyncProfile.parse(value);
}

PortableSyncCard card(int n, int owner) =>
    PortableSyncCard.parse(data.card(number: n, owner: owner));

void main() {
  late ApplyHarness h;
  setUp(() async {
    h = ApplyHarness();
    await h.setup();
  });
  tearDown(() => h.dispose());

  test('whole-set replacement at the same endpoint retains exact local accepted trust', () async {
    final id = await h.feature.create(), session = await h.connected(id);
    final original = h
        .feature
        .repository
        .state
        .endpoints[h.feature.repository.state.profiles[id]!.endpointId]!;
    final value = data.profile(number: 10);
    (value['profile']! as Map)['originalHost'] = 'HOST.INVALID.';
    final remote = await h.remote([PortableSyncProfile.parse(value)]);
    await h.run(remote, choice: SyncMergeChoice.server);
    final after = h.feature.repository.state.endpoints[original.endpointId]!;
    expect(after.profileRefCount, 1);
    expect(after.acceptedKeyBytes, original.acceptedKeyBytes);
    expect(after.acceptedFingerprint, original.acceptedFingerprint);
    expect(after.trustRevision, original.trustRevision);
    expect(h.feature.repository.state.profiles.keys, [data.id(10)]);
    expect(
      h.feature.repository.state.profiles[data.id(10)]!.syncAutoBlocked,
      isTrue,
    );
    expect(session.closeCalls, 1);
  });

  test(
    'exhausted settings counter rejects before irreversible SSH cleanup',
    () async {
      final id = await h.feature.create(), session = await h.connected(id);
      h.feature.repository.state.settings.profilesListRevision = syncMaxInteger;
      final remote = await h.remote([h.stored(id, password: 'changed')]);
      await expectLater(
        h.run(remote, choice: SyncMergeChoice.server),
        throwsA(isA<OperationFailure>()),
      );
      expect(h.batches.reservations, 0);
      expect(session.closeCalls, 0);
      expect(h.feature.repository.state.profiles[id]!.connectionRevision, 1);
    },
  );

  test('exact32KiB current card cannot silently overflow when the imported target makes it historical', () async {
    final id = await h.feature.create(),
        session = await h.connected(id),
        p = h.feature.repository.state.profiles[id]!;
    final old = SoftwareCardRecord()
      ..softwareId = featureId(60)
      ..profileId = id
      ..endpointId = p.endpointId
      ..host = p.normalizedHost
      ..username = p.username
      ..name = 'Service'
      ..createdAt = 1
      ..updatedAt = 2
      ..dataPaths = List.generate(
        16,
        (i) => '/${i.toString().padLeft(2, '0')}${'a' * 1021}',
      )
      ..configPaths = [
        ...List.generate(
          15,
          (i) => '/${i.toString().padLeft(2, '0')}${'b' * 1021}',
        ),
        '/${'c' * 543}',
      ];
    expect(
      utf8
          .encode(
            jsonEncode(SoftwareCardView(old, currentTarget: true).toJson()),
          )
          .length,
      32768,
    );
    h.feature.repository.state.softwareCards[old.softwareId] = old;
    final remote = await h.remote([
      h.stored(id, host: 'new.invalid'),
      cardContent(old),
    ]);
    await expectLater(
      h.run(remote, choice: SyncMergeChoice.server),
      throwsA(isA<OperationFailure>()),
    );
    expect(h.batches.reservations, 0);
    expect(session.closeCalls, 0);
    expect(h.feature.repository.state.profiles[id]!.endpointId, p.endpointId);
    expect(
      h.feature.repository.state.softwareCards[old.softwareId]!.revision,
      1,
    );
  });

  test('card moved from a deleted profile keeps its local ID/counter after cascade', () async {
    final first = await h.feature.create(),
        second = await h.feature.create(host: 'second.invalid');
    final owner = h.feature.repository.state.profiles[first]!;
    final old = SoftwareCardRecord()
      ..id = 456
      ..softwareId = featureId(60)
      ..profileId = first
      ..endpointId = owner.endpointId
      ..host = owner.normalizedHost
      ..username = owner.username
      ..name = 'moved'
      ..revision = 7;
    h.feature.repository.state.softwareCards[old.softwareId] = old;
    final original = cardContent(old), value = original.toJson();
    value['card'] = Map<String, Object?>.of(original.card)
      ..['profileId'] = second;
    original.dispose();
    final remote = await h.remote([
      h.stored(second),
      PortableSyncCard.parse(value),
    ]);
    await h.run(remote, choice: SyncMergeChoice.server);
    final after = h.feature.repository.state.softwareCards[old.softwareId]!;
    expect(after.profileId, second);
    expect(after.id, 456);
    expect(after.revision, 8);
    expect(h.feature.repository.state.profiles.containsKey(first), isFalse);
    expect(h.feature.repository.state.profiles[second]!.profileRevision, 1);
  });

  test('credential ID reassignment removes old association before creating the new local credential', () async {
    final old = await h.feature.create(),
        previous = h.feature.repository.state.profiles[old]!;
    final value = data.profile(number: 10);
    (value['credential']! as Map)['credentialId'] = previous.credentialId;
    final remote = await h.remote([PortableSyncProfile.parse(value)]);
    await h.run(remote, choice: SyncMergeChoice.server);
    final domain = h.feature.repository.state;
    expect(domain.profiles.keys, [data.id(10)]);
    expect(domain.credentials.keys, [previous.credentialId]);
    expect(domain.credentials[previous.credentialId]!.profileId, data.id(10));
    expect(domain.credentials[previous.credentialId]!.secretRevision, 1);
  });

  test('forged private-key proof is not enough without actual imported envelope validation', () async {
    final value = data.profile(number: 10), key = featureKey();
    value['credential'] = {
      'credentialId': data.id(11),
      'kind': 'privateKey',
      'originalBase64': base64.encode(utf8.encode('not a private key')),
      'publicKeyType': key.keyType,
      'publicKeyBits': 256,
      'publicKeyBase64': base64.encode(key.blob),
    };
    final remote = await h.remote([PortableSyncProfile.parse(value)]);
    await expectLater(h.run(remote), throwsA(isA<OperationFailure>()));
    expect(h.feature.repository.state.profiles, isEmpty);
    expect(h.secrets.protects, 0);
    expect(h.batches.reservations, 0);
  });

  test('same semantic server content reuses ciphertext and writes no domain record', () async {
    final id = await h.feature.create();
    final remote = await h.remote([h.stored(id)]);
    final before = h.feature.repository.state.settings.dataRevision;
    final objects = h.feature.repository.state.syncObjects.length;
    var signals = 0;
    final subscription = h.feature.repository.domainChanges.listen(
      (_) => signals++,
    );
    addTearDown(subscription.cancel);
    await h.run(remote, choice: SyncMergeChoice.local);
    await featureTurns();
    expect(h.feature.repository.state.settings.dataRevision, before);
    expect(h.feature.repository.state.syncObjects.length, objects);
    expect(h.feature.repository.state.syncState.pendingRootId, isNull);
    expect(
      h.feature.repository.state.syncState.ackGeneration,
      h.feature.repository.state.syncState.syncGeneration,
    );
    expect(signals, 0);
  });

  test(
    'changed card keeps its local Isar ID and increments the existing counter',
    () async {
      final id = await h.feature.create();
      final p = h.feature.repository.state.profiles[id]!;
      final old = SoftwareCardRecord()
        ..id = 1234
        ..softwareId = featureId(60)
        ..profileId = id
        ..endpointId = p.endpointId
        ..host = p.normalizedHost
        ..port = p.port
        ..username = p.username
        ..name = 'old'
        ..revision = 9;
      h.feature.repository.state.softwareCards[old.softwareId] = old;
      final portable = cardContent(old), value = portable.toJson();
      value['card'] = Map<String, Object?>.of(portable.card)..['name'] = 'new';
      portable.dispose();
      final remote = await h.remote([
        h.stored(id),
        PortableSyncCard.parse(value),
      ]);
      await h.run(remote, choice: SyncMergeChoice.server);
      final after = h.feature.repository.state.softwareCards[old.softwareId]!;
      expect(after.name, 'new');
      expect(after.revision, 10);
      expect(after.id, 1234);
      expect(h.feature.repository.state.profiles[id]!.connectionRevision, 1);
      expect(h.feature.repository.state.softwareEvents, isEmpty);
    },
  );

  test('old pending and domain roll back together on partial write and commit failures', () async {
    for (final partial in [false, true]) {
      final local = ApplyHarness();
      await local.setup();
      addTearDown(local.dispose);
      final id = await local.feature.create(),
          session = await local.connected(id);
      final pending = await local.remote([local.stored(id)], pending: true);
      final remote = await local.remote([profile(10), card(20, 10)]);
      final before = local.feature.repository.state.settings.dataRevision;
      local.batches.afterClose = () async {
        if (partial) {
          local.feature.repository.failAfterWrite = 9;
        } else {
          local.feature.repository.failCommit = true;
        }
      };
      await expectLater(
        local.run(remote, choice: SyncMergeChoice.server),
        throwsA(isA<OperationFailure>()),
      );
      final domain = local.feature.repository.state;
      expect(domain.profiles.keys, [id]);
      expect(domain.credentials.length, 1);
      expect(domain.softwareCards, isEmpty);
      expect(domain.syncState.pendingRootId, pending.rootId);
      expect(domain.syncState.candidateRootId, remote.rootId);
      expect(domain.syncState.baseRootId, isNull);
      expect(domain.settings.dataRevision, before);
      expect(
        domain.endpoints.containsKey(domain.profiles[id]!.endpointId),
        isTrue,
      );
      expect(session.closeCalls, 1);
      local.feature.repository.failAfterWrite = null;
      local.batches.afterClose = null;
      expect(
        (await local.feature.connections.connect(
          local.feature.actors.ui,
          id,
          expectedRevision: 1,
        )).ok,
        isTrue,
      );
    }
  });

  test('failed close quarantines the old endpoint and preserves saved data and pending', () async {
    final id = await h.feature.create(), session = await h.connected(id);
    final pending = await h.remote([h.stored(id)], pending: true);
    final remote = await h.remote([profile(10)]);
    session.failClose = true;
    await expectLater(
      h.run(remote, choice: SyncMergeChoice.server),
      throwsA(
        isA<OperationFailure>().having(
          (e) => e.code,
          'code',
          FailureCode.cleanupRequired,
        ),
      ),
    );
    final domain = h.feature.repository.state;
    expect(domain.profiles.keys, [id]);
    expect(domain.syncState.pendingRootId, pending.rootId);
    expect(
      h.feature.connections.isQuarantined(domain.profiles[id]!.endpointId),
      isTrue,
    );
  });

  test('local edit, key loss or space failure after close cannot commit a stale candidate', () async {
    for (final defect in ['edit', 'key', 'space']) {
      final local = ApplyHarness();
      await local.setup();
      addTearDown(local.dispose);
      final id = await local.feature.create(),
          session = await local.connected(id);
      final pending = await local.remote([local.stored(id)], pending: true);
      final remote = await local.remote([profile(10)]);
      local.batches.afterClose = () async {
        switch (defect) {
          case 'edit':
            local.feature.repository.state.settings.dataRevision++;
            local.feature.repository.state.syncState.syncGeneration++;
            local.feature.repository.state.profiles[id]!.displayName =
                'new local';
          case 'key':
            local.access.current = false;
          case 'space':
            local.free = 0;
        }
      };
      await expectLater(
        local.run(remote, choice: SyncMergeChoice.server),
        throwsA(anyOf(isA<OperationFailure>(), isA<SyncTransportCancelled>())),
      );
      final domain = local.feature.repository.state;
      expect(domain.profiles.keys, [id]);
      expect(domain.syncState.pendingRootId, pending.rootId);
      expect(domain.syncState.baseRootId, isNull);
      expect(session.closeCalls, 1);
      if (defect == 'edit')
        expect(domain.profiles[id]!.displayName, 'new local');
    }
  });

  test('cancellation during native protection waits for cleanup and applies nothing', () async {
    final remote = await h.remote([profile(10)]);
    h.secrets.hold = Completer<void>();
    final running = h.run(remote);
    await featureTurns();
    expect(h.secrets.protects, 1);
    final failure = expectLater(running, throwsA(isA<WorkCancelled>()));
    await h.apply.cancelPending();
    var drained = false;
    final drain = h.apply.drain().then((_) => drained = true);
    await featureTurns();
    expect(drained, isFalse);
    h.secrets.hold!.complete();
    await failure;
    await drain;
    expect(h.feature.repository.state.profiles, isEmpty);
    expect(h.feature.repository.state.syncState.candidateRootId, remote.rootId);
    expect(h.batches.reservations, 0);
    expect(
      h.secrets.inputs.every((bytes) => bytes.every((b) => b == 0)),
      isTrue,
    );
    expect(
      h.secrets.outputs.every((bytes) => bytes.every((b) => b == 0)),
      isTrue,
    );
  });

  test(
    'shutdown waits for final transaction admission and rejects its late write',
    () async {
      final id = await h.feature.create();
      final pending = await h.remote([h.stored(id)], pending: true),
          remote = await h.remote([profile(10)]);
      final entered = Completer<void>(), release = Completer<void>();
      var closed = false;
      h.batches.afterClose = () async {
        closed = true;
      };
      h.feature.repository.beforeWrite = () async {
        if (closed && !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      final running = h.run(remote, choice: SyncMergeChoice.server);
      await entered.future;
      final failure = expectLater(
        running,
        throwsA(
          isA<OperationFailure>().having(
            (e) => e.code,
            'code',
            FailureCode.shuttingDown,
          ),
        ),
      );
      var disposed = false;
      final stop = h.apply.dispose().then((_) => disposed = true);
      await featureTurns();
      expect(disposed, isFalse);
      release.complete();
      await failure;
      await stop;
      expect(h.feature.repository.state.profiles.keys, [id]);
      expect(
        h.feature.repository.state.syncState.pendingRootId,
        pending.rootId,
      );
    },
  );

  test('single flight and wrong crypto namespace reject before a second preparation', () async {
    final remote = await h.remote([profile(10)]);
    final preview = await h.merge.propose(
      local: await h.local(),
      remote: remote.snapshot,
    );
    await h.merge.confirm(preview, SyncMergeChoice.server, (authority) async {
      final wrong = SyncCrypto(
        identity: SyncIdentity(
          serviceOrigin: h.fence.identity.serviceOrigin,
          accountId: featureId(999),
          deviceId: h.fence.identity.deviceId,
          vaultId: h.fence.identity.vaultId,
        ),
        rootKey: Uint8List(32),
      );
      try {
        await expectLater(
          h.apply.apply(authority, wrong, remoteRootId: remote.rootId),
          throwsA(isA<OperationFailure>()),
        );
      } finally {
        wrong.dispose();
      }
      h.secrets.hold = Completer<void>();
      final first = h.apply.apply(
        authority,
        h.crypto,
        remoteRootId: remote.rootId,
      );
      await featureTurns();
      await expectLater(
        h.apply.apply(authority, h.crypto, remoteRootId: remote.rootId),
        throwsA(
          isA<OperationFailure>().having(
            (e) => e.code,
            'code',
            FailureCode.resourceExhausted,
          ),
        ),
      );
      h.secrets.hold!.complete();
      await first;
    });
    expect(h.feature.repository.state.profiles.length, 1);
  });

  test('authenticated server set imports exact credentials and cards once with local counters and no events', () async {
    final remote = await h.remote([
      profile(10, password: '\uFEFF exact\n'),
      card(20, 10),
    ]);
    var signals = 0;
    final subscription = h.feature.repository.domainChanges.listen(
      (_) => signals++,
    );
    addTearDown(subscription.cancel);
    await h.run(remote);
    await featureTurns();
    final domain = h.feature.repository.state,
        p = domain.profiles[data.id(10)]!,
        c = domain.credentials[data.id(11)]!;
    expect(p.profileRevision, 1);
    expect(p.connectionRevision, 1);
    expect(p.syncAutoBlocked, isTrue);
    expect(c.secretRevision, 1);
    expect(c.protectedBytes, utf8.encode('\uFEFF exact\n'));
    expect(domain.softwareCards[data.id(20)]!.revision, 1);
    expect(domain.endpoints[p.endpointId]!.acceptedKeyBytes, isNull);
    expect(domain.endpoints[p.endpointId]!.profileRefCount, 1);
    expect(domain.softwareEvents, isEmpty);
    expect(domain.receipts, isEmpty);
    expect(domain.settings.dataRevision, 2);
    expect(domain.settings.profilesListRevision, 2);
    expect(domain.syncState.syncGeneration, 0);
    expect(domain.syncState.ackGeneration, 0);
    expect(domain.syncState.baseRootId, remote.rootId);
    expect(domain.syncState.pendingRootId, isNull);
    expect(signals, 1);
    expect(h.feature.sessions, isEmpty);
    expect(
      h.secrets.inputs.every((bytes) => bytes.every((b) => b == 0)),
      isTrue,
    );
    expect(
      h.secrets.outputs.every((bytes) => bytes.every((b) => b == 0)),
      isTrue,
    );
  });

  test('disjoint initial merge applies remote additions and freezes merged pending before publication', () async {
    final local = await h.feature.create();
    final old = h.feature.repository.state.profiles[local]!;
    final trust = h.feature.repository.state.endpoints[old.endpointId]!
      ..acceptedFingerprint = 'local trust';
    final remote = await h.remote([profile(10)]);
    final before = h.feature.repository.state.settings.dataRevision;
    await h.run(remote);
    final domain = h.feature.repository.state, state = domain.syncState;
    expect(domain.profiles.keys.toSet(), {local, data.id(10)});
    expect(domain.profiles[local]!.syncAutoBlocked, isFalse);
    expect(domain.profiles[data.id(10)]!.syncAutoBlocked, isTrue);
    expect(
      domain.endpoints[trust.endpointId]!.acceptedFingerprint,
      'local trust',
    );
    expect(domain.settings.dataRevision, before + 1);
    expect(state.baseRootId, remote.rootId);
    expect(state.baseRevision, 1);
    final pending = domain.syncRoots[state.pendingRootId]!;
    expect(pending.remoteRevision, 2);
    expect(pending.sourceGeneration, 1);
    expect(state.ackGeneration, 0);
    expect(state.syncGeneration, 1);
    expect(state.lastSuccessUtc, isNull);
    final rename = await h.feature.profiles.updateProfile(
      h.feature.actors.ui,
      local,
      const ProfilePatch(displayName: 'newer local'),
      expectedRevision: 1,
      mutationId: 'newer',
    );
    expect(rename.ok, isTrue);
    await h.repository.acknowledge(
      h.fence,
      rootId: pending.rootId,
      commitId: state.pendingCommitId!,
      revision: 2,
      successUtc: 100,
    );
    expect(h.feature.repository.state.syncState.ackGeneration, 1);
    expect(h.feature.repository.state.syncState.syncGeneration, 2);
    expect(
      h.feature.repository.state.profiles[local]!.displayName,
      'newer local',
    );
  });

  test('rename keeps the established SSH session, credential and local approval including max secret revision', () async {
    final id = await h.feature.create(), session = await h.connected(id);
    final before = h.feature.repository.state.profiles[id]!;
    // Establish the session against that revision rather than changing its fence.
    await h.feature.connections.disconnect(
      h.feature.actors.ui,
      id,
      sessionId: h.feature.connections.connection(id).sessionId!,
    );
    h
            .feature
            .repository
            .state
            .credentials[before.credentialId]!
            .secretRevision =
        syncMaxInteger;
    final current = await h.connected(id);
    final remote = await h.remote([h.stored(id, name: 'Renamed')]);
    await h.run(remote, choice: SyncMergeChoice.server);
    final after = h.feature.repository.state.profiles[id]!;
    expect(after.profileRevision, before.profileRevision + 1);
    expect(after.connectionRevision, before.connectionRevision);
    expect(after.syncAutoBlocked, isFalse);
    expect(
      h
          .feature
          .repository
          .state
          .credentials[after.credentialId]!
          .secretRevision,
      syncMaxInteger,
    );
    expect(current.closeCalls, 0);
    var writes = 0;
    await current.options.admitWrite(() => writes++);
    expect(writes, 1);
    expect(session.closeCalls, 1);
    expect(h.batches.lastIds, isEmpty);
  });

  test('credential and endpoint change closes old SSH, blocks auto-connect and cleans old endpoint/history', () async {
    final id = await h.feature.create(), session = await h.connected(id);
    final before = h.feature.repository.state.profiles[id]!;
    h.feature.repository.state.histories[id] = MonitoringHistoryRecord()
      ..profileId = id
      ..connectionRevision = 1
      ..payload = 'old';
    h.feature.repository.state.journalSources[featureId(77)] = JournalSource()
      ..sourceId = featureId(77)
      ..profileId = id
      ..connectionRevision = 1
      ..payload = 'old';
    final remote = await h.remote([
      h.stored(id, host: 'new.invalid', password: 'new exact\n'),
    ]);
    await h.run(remote, choice: SyncMergeChoice.server);
    final domain = h.feature.repository.state, after = domain.profiles[id]!;
    expect(after.connectionRevision, 2);
    expect(after.profileRevision, 2);
    expect(after.syncAutoBlocked, isTrue);
    expect(domain.credentials[after.credentialId]!.secretRevision, 2);
    expect(
      utf8.decode(domain.credentials[after.credentialId]!.protectedBytes),
      'new exact\n',
    );
    expect(session.closeCalls, 1);
    expect(domain.endpoints.containsKey(before.endpointId), isFalse);
    expect(domain.endpoints[after.endpointId]!.acceptedKeyBytes, isNull);
    expect(domain.histories.containsKey(id), isFalse);
    expect(domain.journalSources[featureId(77)]!.connectionRevision, 2);
    expect(
      domain.journalSources[featureId(77)]!.payload,
      contains('"partial":true'),
    );
    await expectLater(
      session.options.admitWrite(() => fail('old SSH write')),
      throwsA(isA<OperationFailure>()),
    );
  });

  test('explicit server deletion cascades profiles, credentials, cards, events, journals and trust', () async {
    final id = await h.feature.create(), session = await h.connected(id);
    h.feature.repository.state.softwareCards[featureId(
      60,
    )] = SoftwareCardRecord()
      ..softwareId = featureId(60)
      ..profileId = id
      ..endpointId = h.feature.repository.state.profiles[id]!.endpointId
      ..host = 'host.invalid'
      ..username = 'root'
      ..name = 'local card';
    h.feature.repository.state.softwareEvents[featureId(
      61,
    )] = SoftwareEventRecord()
      ..eventId = featureId(61)
      ..profileId = id;
    h.feature.repository.state.journalSources[featureId(62)] = JournalSource()
      ..sourceId = featureId(62)
      ..profileId = id;
    h.feature.repository.state.histories[id] = MonitoringHistoryRecord()
      ..profileId = id;
    final remote = await h.remote([]);
    await h.run(remote, choice: SyncMergeChoice.server);
    final domain = h.feature.repository.state;
    expect(domain.profiles, isEmpty);
    expect(domain.credentials, isEmpty);
    expect(domain.softwareCards, isEmpty);
    expect(domain.softwareEvents, isEmpty);
    expect(domain.journalSources, isEmpty);
    expect(domain.histories, isEmpty);
    expect(domain.endpoints, isEmpty);
    expect(session.closeCalls, 1);
    expect(domain.syncState.pendingRootId, isNull);
    expect(domain.syncState.ackGeneration, domain.syncState.syncGeneration);
  });

  test('invalid root, incomplete body and local protection refusal preserve pending and live SSH', () async {
    for (final defect in ['root', 'incomplete', 'protection']) {
      final local = ApplyHarness();
      await local.setup();
      addTearDown(local.dispose);
      final id = await local.feature.create(),
          session = await local.connected(id);
      final pending = await local.remote([local.stored(id)], pending: true);
      final remote = await local.remote([
        profile(10),
      ], complete: defect != 'incomplete');
      if (defect == 'root')
        local
            .feature
            .repository
            .state
            .syncRoots[remote.rootId]!
            .manifestCiphertext[0]++;
      if (defect == 'protection') local.secrets.fail = true;
      await expectLater(
        local.run(remote, choice: SyncMergeChoice.server),
        throwsA(isA<OperationFailure>()),
      );
      final domain = local.feature.repository.state;
      expect(domain.profiles.keys, [id]);
      expect(domain.syncState.pendingRootId, pending.rootId);
      expect(domain.syncState.candidateRootId, remote.rootId);
      expect(session.closeCalls, 0);
      expect(local.batches.reservations, 0);
    }
  });
}
