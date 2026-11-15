import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/connections/profile_batch.dart';
import 'package:serverdeck/domain/actor.dart';
import 'package:serverdeck/domain/app_operations.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/runtime/owned_work.dart';

import '../connections/connection_owner_test.dart' as fixture;

String endpoint(fixture.Harness h, [int n = 1]) =>
    h.repository.state.profiles[fixture.id(n)]!.endpointId;
Future<ProfileMutationBatch> reserve(
  fixture.Harness h, {
  Map<String, int?>? ids,
  Set<String>? targets,
  void Function()? guard,
}) => h.owner.reserveProfileBatch(
  h.actors.owner,
  expectedProfiles: ids ?? {fixture.id(1): 1},
  targetEndpoints: targets ?? {endpoint(h)},
  guard: guard ?? () {},
);
Future<void> check(fixture.Harness h, ProfileMutationBatch batch) =>
    h.gate.prepare(h.actors.owner, (context) => batch.check(context));

void main() {
  test('limits and quarantined targets reject before unrelated session invalidation', () async {
    final h = fixture.Harness();
    addTearDown(h.dispose);
    final session = await h.connected();
    await expectLater(
      reserve(h, ids: {for (var n = 1; n <= 2001; n++) fixture.id(n): null}),
      throwsA(fixture.failure(FailureCode.invalidArgument)),
    );
    await expectLater(
      reserve(
        h,
        targets: {
          for (var n = 1; n <= 1001; n++) n.toRadixString(16).padLeft(64, '0'),
        },
      ),
      throwsA(fixture.failure(FailureCode.invalidArgument)),
    );
    expect(session.closes, 0);
    session.failClose = true;
    final failed = await reserve(h);
    await expectLater(
      failed.close(),
      throwsA(fixture.failure(FailureCode.cleanupRequired)),
    );
    failed.release();
    h.seed(2, host: 'other.invalid');
    final other = await h.connected(profile: fixture.id(2));
    await expectLater(
      reserve(h, ids: {fixture.id(2): 1}, targets: {endpoint(h)}),
      throwsA(fixture.failure(FailureCode.cleanupRequired)),
    );
    expect(other.closes, 0);
  });

  test('old release cannot remove a later reservation and retired absent IDs retain no history', () async {
    final h = fixture.Harness();
    addTearDown(h.dispose);
    final first = await reserve(
      h,
      ids: {fixture.id(1): 1, fixture.id(3): null},
    );
    await first.close();
    first.release();
    expect(h.owner.generation(fixture.id(3)), 0);
    final second = await reserve(h);
    addTearDown(second.release);
    first.release();
    expect((await h.connect()).error!.code, FailureCode.conflict);
    await second.close();
    await h.gate.prepare(
      h.actors.owner,
      (context) => h.repository.write((r) {
        second.check(context);
        r.deleteProfile(fixture.id(1));
      }),
    );
    second.release();
    expect(h.owner.generation(fixture.id(1)), 0);
  });

  test('batch closes all affected resources outside gate and reserves existing/new IDs', () async {
    final h = fixture.Harness();
    addTearDown(h.dispose);
    h.seed(2, host: 'second.invalid');
    final first = await h.connected(),
        second = await h.connected(profile: fixture.id(2));
    first.holdClose = Completer<void>();
    final before = h.repository.committedWrites;
    final batch = await reserve(
      h,
      ids: {fixture.id(1): 1, fixture.id(2): 1, fixture.id(3): null},
      targets: {endpoint(h), endpoint(h, 2)},
    );
    addTearDown(batch.release);
    await expectLater(
      check(h, batch),
      throwsA(fixture.failure(FailureCode.conflict)),
    );
    final closing = batch.close();
    await fixture.turns();
    // A blocked network close must not retain the command gate.
    expect(await h.gate.prepare(h.actors.owner, (_) => 'free'), 'free');
    expect(first.closes, 1);
    expect(second.closes, 1);
    expect((await h.connect()).error!.code, FailureCode.conflict);
    expect(
      (await h.owner.connect(
        h.actors.ui,
        fixture.id(3),
        expectedRevision: 1,
      )).error!.code,
      FailureCode.conflict,
    );
    final auto = await h.owner.connectForMonitoring(
      h.actors.ui,
      fixture.id(1),
      expectedRevision: 1,
      cancellation: WorkCancellation(),
    );
    expect(auto.operation.error!.code, FailureCode.conflict);
    expect(h.dials.length, 2);
    first.holdClose!.complete();
    await closing;
    await check(h, batch);
    expect(h.repository.committedWrites, before);
    expect(h.owner.liveResources, 0);
    await expectLater(
      h.gate.prepare(h.actors.ui, (context) => batch.check(context)),
      throwsA(fixture.failure(FailureCode.conflict)),
    );
    batch.release();
    batch.release();
    await expectLater(
      check(h, batch),
      throwsA(fixture.failure(FailureCode.conflict)),
    );
    expect((await h.connect()).ok, isTrue);
  });

  test('stale request and overlap reject before invalidating any additional profile', () async {
    final h = fixture.Harness();
    addTearDown(h.dispose);
    final session = await h.connected();
    final generation = h.owner.generation(fixture.id(1));
    for (final ids in [
      {fixture.id(1): 2},
      {fixture.id(1): null},
      {fixture.id(3): 1},
    ]) {
      await expectLater(reserve(h, ids: ids), throwsA(isA<OperationFailure>()));
      expect(h.owner.generation(fixture.id(1)), generation);
      expect(session.closes, 0);
    }
    final batch = await reserve(h);
    addTearDown(batch.release);
    final reservedGeneration = h.owner.generation(fixture.id(1));
    await expectLater(
      reserve(h),
      throwsA(fixture.failure(FailureCode.conflict)),
    );
    expect(h.owner.generation(fixture.id(1)), reservedGeneration);
    await batch.close();
  });

  test('every old entity fence and caller identity/data guard are rechecked after close', () async {
    for (final change in [
      'profile',
      'connection',
      'credential',
      'trust',
      'observation',
      'absence',
      'guard',
      'new',
    ]) {
      final h = fixture.Harness();
      addTearDown(h.dispose);
      var current = true;
      final batch = await reserve(
        h,
        ids: {fixture.id(1): 1, fixture.id(3): null},
        guard: () {
          if (!current) throw const OperationFailure(FailureCode.conflict);
        },
      );
      addTearDown(batch.release);
      await batch.close();
      final profile = h.repository.state.profiles[fixture.id(1)]!;
      switch (change) {
        case 'profile':
          profile.profileRevision++;
        case 'connection':
          profile.connectionRevision++;
        case 'credential':
          h
              .repository
              .state
              .credentials[profile.credentialId]!
              .secretRevision++;
        case 'trust':
          h.repository.state.endpoints[profile.endpointId]!.trustRevision++;
        case 'observation':
          h
              .repository
              .state
              .endpoints[profile.endpointId]!
              .observationRevision++;
        case 'absence':
          h.repository.state.profiles.remove(profile.profileId);
        case 'guard':
          current = false;
        case 'new':
          h.seed(3);
      }
      await expectLater(
        check(h, batch),
        throwsA(isA<OperationFailure>()),
        reason: change,
      );
    }
  });

  test('check inside actual write sees an edit made while transaction admission waited', () async {
    final h = fixture.Harness();
    addTearDown(h.dispose);
    final batch = await reserve(h);
    addTearDown(batch.release);
    await batch.close();
    h.repository.beforeWrite = () async {
      h.repository.state.profiles[fixture.id(1)]!.profileRevision++;
    };
    await expectLater(
      h.gate.prepare(
        h.actors.owner,
        (context) => h.repository.write((r) {
          batch.check(context);
          r.deleteProfile(fixture.id(1));
        }),
      ),
      throwsA(fixture.failure(FailureCode.conflict)),
    );
    expect(h.repository.state.profiles.containsKey(fixture.id(1)), isTrue);
  });

  test('failed or timed-out close quarantines endpoint and never grants commit authority', () async {
    for (final timeout in [false, true]) {
      final h = fixture.Harness();
      addTearDown(h.dispose);
      final session = await h.connected();
      if (timeout) {
        session.holdClose = Completer<void>();
      } else {
        session.failClose = true;
      }
      final batch = await reserve(h);
      addTearDown(batch.release);
      final failed = expectLater(
        batch.close(),
        throwsA(fixture.failure(FailureCode.cleanupRequired)),
      );
      await fixture.turns();
      if (timeout) h.clock.advance(const Duration(seconds: 5));
      await failed;
      expect(h.owner.isQuarantined(endpoint(h)), isTrue);
      await expectLater(check(h, batch), throwsA(isA<OperationFailure>()));
      batch.release();
      expect((await h.connect()).error!.code, FailureCode.cleanupRequired);
      expect(h.dials.length, 1);
    }
  });

  test('reservation cancels retained reconnect intent and old authentication input', () async {
    for (final reconnect in [false, true]) {
      final h = fixture.Harness();
      addTearDown(h.dispose);
      final session = reconnect ? await h.connected() : await h.ready();
      Future<void>? phrase;
      if (reconnect) {
        session.terminal.complete(
          const OperationFailure(FailureCode.networkError),
        );
        await fixture.turns();
        expect(h.owner.connection(fixture.id(1)).reconnectAttempt, 1);
      } else {
        await session.options.verifyHost(fixture.observation());
        phrase = expectLater(
          session.options.requestPassphrase(),
          throwsA(isA<WorkCancelled>()),
        );
        await fixture.turns();
        expect(h.owner.connection(fixture.id(1)).pendingInput, isNotNull);
      }
      final batch = await reserve(h);
      addTearDown(batch.release);
      await batch.close();
      await phrase;
      h.clock.advance(const Duration(seconds: 3));
      await fixture.turns();
      expect(h.dials.length, 1);
      expect(h.owner.connection(fixture.id(1)).pendingInput, isNull);
      expect(h.owner.connection(fixture.id(1)).reconnectAttempt, isNull);
    }
  });

  test('caller arguments are frozen before queued admission', () async {
    final h = fixture.Harness();
    addTearDown(h.dispose);
    final gate = Completer<void>();
    h.state.before = (_, point) async {
      if (point == AuthorizationPoint.admission) await gate.future;
    };
    final ids = {fixture.id(1): 1}, targets = {endpoint(h)};
    final pending = reserve(h, ids: ids, targets: targets);
    ids.clear();
    targets.clear();
    gate.complete();
    final batch = await pending;
    addTearDown(batch.release);
    await batch.close();
    expect((await h.connect()).error!.code, FailureCode.conflict);
  });

  test(
    'guard rejection at linearization does not close an untouched live session',
    () async {
      final h = fixture.Harness();
      addTearDown(h.dispose);
      final session = await h.connected();
      var calls = 0;
      await expectLater(
        reserve(
          h,
          guard: () {
            if (++calls == 2)
              throw const OperationFailure(FailureCode.conflict);
          },
        ),
        throwsA(fixture.failure(FailureCode.conflict)),
      );
      await fixture.turns();
      var writes = 0;
      await session.write(() => writes++);
      expect(writes, 1);
      expect(session.closes, 0);
    },
  );

  test('late response failure releases undelivered reservation and closes revoked resources', () async {
    final h = fixture.Harness();
    addTearDown(h.dispose);
    final session = await h.connected();
    h.state.before = (actor, point) async {
      if (actor is OwnerActor && point == AuthorizationPoint.response)
        throw const OperationFailure(FailureCode.conflict);
    };
    await expectLater(
      reserve(h),
      throwsA(fixture.failure(FailureCode.conflict)),
    );
    await fixture.turns();
    expect(session.closes, 1);
    expect((await h.connect()).ok, isTrue);
  });

  test('foreign owner is denied and shutdown/release during close cannot authorize apply', () async {
    final h = fixture.Harness();
    addTearDown(h.dispose);
    await expectLater(
      h.owner.reserveProfileBatch(
        ActorAuthority(fixture.id(901)).owner,
        expectedProfiles: {fixture.id(1): 1},
        targetEndpoints: {endpoint(h)},
        guard: () {},
      ),
      throwsA(fixture.failure(FailureCode.authRequired)),
    );
    final session = await h.connected();
    session.holdClose = Completer<void>();
    final batch = await reserve(h);
    final closing = expectLater(
      batch.close(),
      throwsA(fixture.failure(FailureCode.conflict)),
    );
    await fixture.turns();
    await h.owner.stopAdmission();
    session.holdClose!.complete();
    await closing;
    await expectLater(check(h, batch), throwsA(isA<OperationFailure>()));
    batch.release();
  });
}
