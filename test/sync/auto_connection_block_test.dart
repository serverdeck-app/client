import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/domain/app_operations.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:serverdeck/monitoring/monitoring_models.dart';
import 'package:serverdeck/monitoring/linux_metrics.dart';
import 'package:serverdeck/runtime/owned_work.dart';

import '../connections/connection_owner_test.dart' as fixture;
import '../fixtures/monitoring_harness.dart' as monitoring;

void block(fixture.Harness h, [bool value = true]) =>
    h.repository.state.profiles[fixture.id(1)]!.syncAutoBlocked = value;
bool blocked(fixture.Harness h) =>
    h.repository.state.profiles[fixture.id(1)]!.syncAutoBlocked;
Future<OperationResult<ConnectionView>> automatic(fixture.Harness h) async =>
    (await h.owner.connectForMonitoring(
      h.actors.ui,
      fixture.id(1),
      expectedRevision: 1,
      cancellation: WorkCancellation(),
    )).operation;

void main() {
  test('UI reuse of a connected MCP session and host-key-only acceptance grant no approval', () async {
    final h = fixture.Harness();
    addTearDown(h.dispose);
    block(h);
    await h.connected(actor: h.mcp);
    expect((await h.connect()).ok, isTrue);
    expect(blocked(h), isTrue);
    final other = fixture.Harness();
    addTearDown(other.dispose);
    block(other);
    other.policy.wait = true;
    final session = await other.ready();
    final verified = session.options.verifyHost(fixture.observation());
    await fixture.turns();
    await other.policy.accept();
    expect(await verified, isTrue);
    expect(blocked(other), isTrue);
    expect(session.auth.isCompleted, isFalse);
  });

  test('an established automatic entry checks a new block at actual write admission', () async {
    final h = fixture.Harness();
    addTearDown(h.dispose);
    expect((await automatic(h)).ok, isTrue);
    await fixture.turns();
    final session = h.sessions.single;
    await session.authenticate();
    await fixture.turns();
    expect(h.owner.connection(fixture.id(1)).state, ConnectionState.connected);
    block(h);
    var writes = 0;
    await expectLater(
      session.write(() => writes++),
      throwsA(isA<OperationFailure>()),
    );
    expect(writes, 0);
    expect(blocked(h), isTrue);
  });

  test(
    'approval metadata counter exhaustion preserves the durable block',
    () async {
      final h = fixture.Harness();
      addTearDown(h.dispose);
      block(h);
      final session = await h.ready();
      h.repository.state.settings.dataRevision = 9007199254740991;
      await session.authenticate();
      await fixture.turns();
      expect(blocked(h), isTrue);
      expect(
        h.owner.connection(fixture.id(1)).state,
        isNot(ConnectionState.connected),
      );
      expect(session.closes, 1);
    },
  );
  test('durable block denies auto with no dial, secret access or history change across owner recreation', () async {
    final h = fixture.Harness();
    addTearDown(h.dispose);
    block(h);
    for (var i = 0; i < 2; i++) {
      expect((await automatic(h)).error!.code, FailureCode.conflict);
    }
    expect(h.owner.generation(fixture.id(1)), 0);
    expect(h.dials, isEmpty);
    expect(h.decrypts, 0);
    final fresh = fixture.Harness();
    addTearDown(fresh.dispose);
    fresh.repository.state = h.repository.state.clone();
    expect((await automatic(fresh)).error!.code, FailureCode.conflict);
    expect(fresh.dials, isEmpty);
    expect(blocked(fresh), isTrue);
  });

  test('queued auto admission observes a newly persisted block', () async {
    final h = fixture.Harness();
    addTearDown(h.dispose);
    final release = Completer<void>();
    h.state.before = (_, point) async {
      if (point == AuthorizationPoint.admission) await release.future;
    };
    final pending = automatic(h);
    await fixture.turns();
    block(h);
    release.complete();
    expect((await pending).error!.code, FailureCode.conflict);
    expect(h.dials, isEmpty);
    expect(h.owner.generation(fixture.id(1)), 0);
  });

  test('automatic attempt rechecks persistent policy before a late credential/socket effect', () async {
    final h = fixture.Harness();
    addTearDown(h.dispose);
    final release = Completer<void>();
    h.decrypt = (bytes) async {
      await release.future;
      return bytes;
    };
    expect((await automatic(h)).ok, isTrue);
    await fixture.turns();
    block(h);
    release.complete();
    await fixture.turns();
    expect(h.sessions, isEmpty);
    expect(blocked(h), isTrue);
    expect(
      h.owner.connection(fixture.id(1)).state,
      isNot(ConnectionState.connected),
    );
  });

  test(
    'only current manual UI authentication clears block as local metadata',
    () async {
      final h = fixture.Harness();
      addTearDown(h.dispose);
      block(h);
      final before = h.repository.state.settings.dataRevision;
      final session = await h.connected();
      expect(blocked(h), isFalse);
      expect(h.repository.state.settings.dataRevision, before + 1);
      expect(h.repository.state.settings.profilesListRevision, 1);
      expect(h.repository.state.profiles[fixture.id(1)]!.profileRevision, 1);
      expect(h.repository.state.profiles[fixture.id(1)]!.connectionRevision, 1);
      expect(h.repository.state.syncState.syncGeneration, 0);
      session.terminal.complete(
        const OperationFailure(FailureCode.networkError),
      );
      await fixture.turns();
      h.clock.advance(const Duration(seconds: 1));
      await fixture.turns();
      expect(h.dials.length, 2);
    },
  );

  test('successful MCP authentication cannot approve auto or native monitoring/reconnect', () async {
    final h = fixture.Harness();
    addTearDown(h.dispose);
    block(h);
    final session = await h.connected(actor: h.mcp);
    expect(blocked(h), isTrue);
    var writes = 0;
    await session.write(() => writes++);
    expect(writes, 1);
    final job = h.owner.beginMonitoring(
      h.actors.ui,
      fixture.id(1),
      h.owner.connection(fixture.id(1)).sessionId!,
      expectedConnectionRevision: 1,
      cancellation: WorkCancellation(),
    );
    final sample = await job.result;
    expect(sample.failure, MonitoringReason.disconnected);
    expect(session.collections, 0);
    session.terminal.complete(const OperationFailure(FailureCode.networkError));
    await fixture.turns();
    h.clock.advance(const Duration(seconds: 5));
    await fixture.turns();
    expect(h.dials.length, 1);
    expect(blocked(h), isTrue);
  });

  test('retained retry rechecks a block persisted after the original session ended', () async {
    final h = fixture.Harness();
    addTearDown(h.dispose);
    final session = await h.connected();
    session.terminal.complete(const OperationFailure(FailureCode.networkError));
    await fixture.turns();
    expect(h.owner.connection(fixture.id(1)).reconnectAttempt, 1);
    block(h);
    h.clock.advance(const Duration(seconds: 5));
    await fixture.turns();
    expect(h.dials.length, 1);
    expect(blocked(h), isTrue);
  });

  test('trust-only, failed authentication and cancelled/late attempts leave block intact', () async {
    for (final defect in ['trust', 'error', 'cancel', 'expired']) {
      final h = fixture.Harness();
      addTearDown(h.dispose);
      block(h);
      final session = await h.ready();
      if (defect == 'trust') {
        await session.options.verifyHost(fixture.observation());
      } else if (defect == 'error') {
        session.auth.completeError(
          const OperationFailure(FailureCode.networkError),
        );
      } else if (defect == 'cancel') {
        final attempt = h.owner.connection(fixture.id(1)).attemptId!;
        await h.owner.cancelConnection(
          h.actors.ui,
          fixture.id(1),
          attemptId: attempt,
        );
        await session.authenticate();
      } else {
        h.clock.advance(const Duration(seconds: 30));
        await session.authenticate();
      }
      await fixture.turns();
      expect(blocked(h), isTrue, reason: defect);
    }
  });

  test(
    'failed approval write never publishes connected and preserves block',
    () async {
      for (final failCommit in [false, true]) {
        final h = fixture.Harness();
        addTearDown(h.dispose);
        block(h);
        final session = await h.ready();
        if (failCommit) {
          h.repository.failCommit = true;
        } else {
          h.repository.failAfterWrite = 2;
        }
        await session.authenticate();
        await fixture.turns();
        expect(blocked(h), isTrue);
        expect(h.repository.state.settings.dataRevision, 1);
        expect(
          h.owner.connection(fixture.id(1)).state,
          isNot(ConnectionState.connected),
        );
        expect(session.closes, 1);
      }
    },
  );

  test('write admission rechecks connection revision, trust, shutdown and expiry before approval', () async {
    for (final defect in [
      'connection',
      'credential',
      'trust',
      'shutdown',
      'expiry',
    ]) {
      final h = fixture.Harness();
      addTearDown(h.dispose);
      block(h);
      final session = await h.ready();
      h.repository.beforeWrite = () async {
        final profile = h.repository.state.profiles[fixture.id(1)]!;
        switch (defect) {
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
          case 'shutdown':
            h.running = false;
          case 'expiry':
            h.clock.advance(const Duration(seconds: 30));
        }
      };
      await session.authenticate();
      await fixture.turns();
      expect(blocked(h), isTrue, reason: defect);
      expect(
        h.owner.connection(fixture.id(1)).state,
        isNot(ConnectionState.connected),
      );
      h.running = true;
      h.repository.beforeWrite = null;
    }
  });

  test('rename after handshake keeps current metadata when manual approval commits', () async {
    final h = fixture.Harness();
    addTearDown(h.dispose);
    block(h);
    final session = await h.ready();
    h.repository.beforeWrite = () async {
      final p = h.repository.state.profiles[fixture.id(1)]!;
      p.displayName = 'new local name';
      p.profileRevision = 2;
      h.repository.state.settings.dataRevision = 2;
    };
    await session.authenticate();
    await fixture.turns();
    expect(blocked(h), isFalse);
    expect(
      h.repository.state.profiles[fixture.id(1)]!.displayName,
      'new local name',
    );
    expect(h.repository.state.profiles[fixture.id(1)]!.profileRevision, 2);
    expect(h.repository.state.settings.dataRevision, 3);
    expect(h.owner.connection(fixture.id(1)).state, ConnectionState.connected);
  });

  test('secondary monitoring guard suppresses auto and collection through hide/resume and read failure', () async {
    final h = monitoring.MonitoringHarness();
    addTearDown(h.dispose);
    h.add(1);
    h.add(2, connected: true);
    h.syncBlocked.addAll([monitoring.mid(1), monitoring.mid(2)]);
    h.owner.setActive(true);
    await monitoring.settle();
    await h.tick(10);
    expect(h.port.attempts, isEmpty);
    expect(h.port.collected, isEmpty);
    h.owner.setActive(false);
    h.owner.setActive(true);
    await monitoring.settle();
    expect(h.port.attempts, isEmpty);
    h.syncBlocked.clear();
    h.failSyncPolicy = true;
    await h.owner.reconcile();
    await h.tick(10);
    expect(h.port.attempts, isEmpty);
    expect(h.port.collected, isEmpty);
    h.failSyncPolicy = false;
    await h.owner.reconcile();
    await monitoring.settle();
    expect(h.port.attempts, contains(monitoring.mid(1)));
    expect(h.port.collected, contains(monitoring.mid(2)));
  });

  test('secondary monitoring discards an already pending sample after block appears', () async {
    final h = monitoring.MonitoringHarness();
    addTearDown(h.dispose);
    h.add(1, connected: true);
    h.port.holdCollections = true;
    h.port.completeOnCancel = false;
    h.owner.setActive(true);
    await monitoring.settle();
    expect(h.port.pending.length, 1);
    h.syncBlocked.add(monitoring.mid(1));
    await h.owner.reconcile();
    h.port.pending.single.completer.complete(
      const LinuxSample(memoryPercent: 99),
    );
    await monitoring.settle();
    expect(
      h.owner.snapshot(monitoring.mid(1)).readings[MetricKind.memory]!.percent,
      isNull,
    );
  });
}
