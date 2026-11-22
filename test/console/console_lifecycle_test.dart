import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/console/console_models.dart';
import 'package:serverdeck/console/console_owner.dart';
import 'package:serverdeck/console/console_port.dart';
import 'package:serverdeck/domain/models.dart';
import 'package:xterm/core.dart' show Buffer;

import '../fixtures/feature_harness.dart';
import 'fakes.dart';

void main() {
  late FeatureHarness h;
  late FakeConsolePort port;
  late ConsoleOwner owner;
  late String profile;
  late ConsoleCaller ui;
  setUp(() async {
    h = FeatureHarness();
    profile = await h.create();
    port = FakeConsolePort(h.state.versions);
    owner = ConsoleOwner(
      actors: h.actors,
      gate: h.gate,
      state: h.state,
      repository: h.repository,
      connections: port,
      configuration: () => const ConsoleConfiguration(),
      newId: h.newId,
      monotonicNow: h.clock.monotonic,
      schedule: h.clock.schedule,
    );
    ui = ConsoleCaller.ui(h.actors.ui);
  });
  tearDown(() async {
    await owner.dispose();
    await port.events.close();
    await h.dispose();
  });
  Future<ConsoleActionValue> open() async {
    final result = await owner.openConsole(ui, profile);
    await featureTurns();
    return result.value!.console as ConsoleActionValue;
  }

  test('hidden and disabled keyboard preserve output and channel; ended keeps final text', () async {
    final s = await open();
    final engine = owner.engine(s.sessionId)!;
    owner.setVisible(s.sessionId, true);
    owner.setKeyboardActive(false);
    engine.terminal.textInput('hidden-input');
    port.openings.single.channel.emit(utf8.encode('final text'));
    port.openings.single.channel.end(7);
    await featureTurns();
    expect(port.openings.single.channel.writes, isEmpty);
    final page =
        (await owner.readConsole(
              ui,
              profile,
              s.sessionId,
              generation: 1,
            )).value!.console
            as ConsoleHistoryValue;
    expect(page.rows.map((r) => r.text).join(), contains('final text'));
    expect(page.session.state, 'ended');
    expect(page.session.exitCode, 7);
    expect(page.session.inputOwner.kind, 'free');
    expect(
      (await owner.closeConsole(ui, profile, s.sessionId, generation: 1)).ok,
      true,
    );
    expect(port.connected, true);
  });
  test('disconnect keeps parsed history and discards queued output and UTF-8 carry', () async {
    final s = await open();
    final channel = port.openings.single.channel;
    final engine = owner.engine(s.sessionId)!;
    channel.emit([...utf8.encode('old-history\x1b[?1049hsecret-alt'), 0xe2]);
    await featureTurns();
    final version = engine.historyVersion;
    channel.emit(utf8.encode('queued'));
    channel.exitCode = 9;
    port.connected = false;
    port.events.add(ConsoleInvalidation(profile, clear: false));
    channel.emit(utf8.encode('late'));

    final kept =
        (await owner.readConsole(
              ui,
              profile,
              s.sessionId,
              generation: 1,
            )).value!.console
            as ConsoleHistoryValue;
    expect(kept.rows.map((r) => r.text).join(), contains('secret-alt'));
    expect(
      kept.rows.map((r) => r.text).join(),
      isNot(contains(RegExp('queued|late|�'))),
    );
    expect(kept.historyVersion, version);
    expect(kept.partial, true);
    expect(kept.session.state, 'disconnected');
    expect(kept.session.exitCode, 9);
    expect(channel.closed, true);

    port.events.add(ConsoleInvalidation(profile, clear: true));
    final cleared = await owner.readConsole(
      ui,
      profile,
      s.sessionId,
      generation: 1,
    );
    expect(cleared.error?.code, FailureCode.consoleNotFound);
    await featureTurns();
    expect(owner.engine(s.sessionId), isNull);
    expect(
      Buffer.plainText(engine.terminal.mainBuffer.lines[0]),
      isNot(contains('old-history')),
    );
    expect(
      engine.screen.map((r) => r.text).join(),
      isNot(contains('secret-alt')),
    );
  });

  test(
    'archived output and cursor survive late resize from the old renderer',
    () async {
      final s = await open();
      final engine = owner.engine(s.sessionId)!;
      final oldRenderer = engine.terminal;
      port.openings.single.channel.emit(utf8.encode('first\r\nsecond'));
      await featureTurns();
      final before =
          (await owner.readConsole(
                ui,
                profile,
                s.sessionId,
                generation: 1,
                limit: 1,
              )).value!.console
              as ConsoleHistoryValue;
      expect(before.nextCursor, isNotNull);

      port.connected = false;
      port.events.add(ConsoleInvalidation(profile, clear: false));
      engine.resize(20, 10);
      expect(engine.historyVersion, before.historyVersion);
      oldRenderer.resize(30, 12);
      oldRenderer.write('unexpected output');

      final after =
          (await owner.readConsole(
                ui,
                profile,
                s.sessionId,
                generation: 1,
                cursor: before.nextCursor,
              )).value!.console
              as ConsoleHistoryValue;
      expect(after.historyVersion, before.historyVersion);
      expect(after.historyGap, false);
      expect(after.rows.map((row) => row.text).join(), contains('second'));
      expect(
        after.rows.map((row) => row.text).join(),
        isNot(contains('unexpected output')),
      );
    },
  );

  test(
    'transport close wins when PTY done arrives before invalidation',
    () async {
      final s = await open();
      final channel = port.openings.single.channel;
      channel.emit([...utf8.encode('parsed output'), 0xe2]);
      await featureTurns();
      final version = owner.engine(s.sessionId)!.historyVersion;

      port.connected = false;
      channel.failure = 'channelFailure';
      channel.end();
      await featureTurns();
      expect(owner.liveSessionsFor(profile), isEmpty);
      expect(owner.historyFor(profile).single.state, 'disconnected');

      port.events.add(ConsoleInvalidation(profile, clear: false));
      final page =
          (await owner.readConsole(
                ui,
                profile,
                s.sessionId,
                generation: 1,
              )).value!.console
              as ConsoleHistoryValue;
      expect(page.session.state, 'disconnected');
      expect(page.session.reason, 'connectionLost');
      expect(page.historyVersion, version);
      expect(page.partial, true);
      expect(page.rows.map((r) => r.text).join(), contains('parsed output'));
      expect(page.rows.map((r) => r.text).join(), isNot(contains('�')));
    },
  );

  test(
    'transport close wins when a pending opening fails before invalidation',
    () async {
      port.autoOpen = false;
      final s = await open();
      port.openings.single.channel.exitCode = 11;
      port.connected = false;
      port.openings.single.ready.completeError(
        const ConsoleOpenFailure(ConsoleOpenFailureCode.networkError),
      );
      await featureTurns();
      expect(owner.liveSessionsFor(profile), isEmpty);
      expect(owner.historyFor(profile).single.sessionId, s.sessionId);
      expect(owner.historyFor(profile).single.state, 'disconnected');
      expect(owner.historyFor(profile).single.reason, 'connectionLost');
      expect(owner.historyFor(profile).single.exitCode, 11);
      port.events.add(ConsoleInvalidation(profile, clear: false));
      expect(owner.historyFor(profile), hasLength(1));
    },
  );

  test(
    'opening failure discards queued output before the opened callback',
    () async {
      port.autoOpen = false;
      final s = await open();
      final opening = port.openings.single;
      opening.channel.emit(utf8.encode('parsed before ACK'));
      await featureTurns();
      opening.channel.emit(utf8.encode('queued after ACK failure'));
      opening.failure = ConsoleOpenFailureCode.shellDenied;
      opening.ready.completeError(
        const ConsoleOpenFailure(ConsoleOpenFailureCode.shellDenied),
      );
      await featureTurns();

      final page =
          (await owner.readConsole(
                ui,
                profile,
                s.sessionId,
                generation: 1,
              )).value!.console
              as ConsoleHistoryValue;
      expect(page.session.state, 'error');
      expect(page.session.reason, 'shellDenied');
      expect(page.partial, true);
      final output = page.rows.map((row) => row.text).join();
      expect(output, contains('parsed before ACK'));
      expect(output, isNot(contains('queued after ACK failure')));
      expect(owner.liveSessionsFor(profile), isEmpty);
    },
  );

  test(
    'forced channel error archives only the handled output and keeps SSH',
    () async {
      final s = await open();
      final channel = port.openings.single.channel;
      channel.emit([...utf8.encode('kept'), 0xe2]);
      await featureTurns();
      channel.emit(utf8.encode('queued after carry'));
      channel.failure = 'channelFailure';
      channel.end();
      await featureTurns();

      final page =
          (await owner.readConsole(
                ui,
                profile,
                s.sessionId,
                generation: 1,
              )).value!.console
              as ConsoleHistoryValue;
      expect(page.session.state, 'error');
      expect(page.session.reason, 'channelFailure');
      expect(page.partial, true);
      final text = page.rows.map((r) => r.text).join();
      expect(text, contains('kept'));
      expect(text, isNot(contains(RegExp('queued|�'))));
      expect(owner.liveSessionsFor(profile), isEmpty);
      expect(port.connected, true);
    },
  );

  test(
    'streamsDone drains queued bytes and finishes UTF-8 before archiving',
    () async {
      final s = await open();
      final channel = port.openings.single.channel;
      channel.emit([...utf8.encode('${'\x1b[0m' * 5000}final text'), 0xe2]);
      channel.end(7);
      await featureTurns();

      final page =
          (await owner.readConsole(
                ui,
                profile,
                s.sessionId,
                generation: 1,
              )).value!.console
              as ConsoleHistoryValue;
      expect(page.rows.map((r) => r.text).join(), contains('final text�'));
      expect(page.session.state, 'ended');
      expect(page.session.exitCode, 7);
      expect(page.partial, false);
      expect(owner.liveSessionsFor(profile), isEmpty);
    },
  );

  test(
    'parser failure invalidates positions into before-failure output',
    () async {
      final s = await open();
      final channel = port.openings.single.channel;
      channel.emit(utf8.encode('first\r\n'));
      await featureTurns();
      final before =
          (await owner.readConsole(
                ui,
                profile,
                s.sessionId,
                generation: 1,
                limit: 1,
              )).value!.console
              as ConsoleHistoryValue;
      expect(before.nextCursor, isNotNull);
      channel.emit(utf8.encode('parsed prefix\x1b[1234567m'));
      await featureTurns();

      final after =
          (await owner.readConsole(
                ui,
                profile,
                s.sessionId,
                generation: 1,
                cursor: before.nextCursor,
              )).value!.console
              as ConsoleHistoryValue;
      expect(after.historyGap, true);
      expect(after.session.state, 'error');
      expect(after.partial, true);
      expect(owner.liveSessionsFor(profile), isEmpty);
    },
  );

  test('close one channel preserves another; shutdown removes buffers without reopen', () async {
    final a = await open(), b = await open();
    final engine = owner.engine(b.sessionId)!;
    await owner.closeConsole(
      ui,
      profile,
      a.sessionId,
      generation: 1,
      leaseToken: a.leaseToken,
      confirmed: true,
    );
    expect(port.openings.first.channel.closed, true);
    expect(port.openings.last.channel.closed, false);
    port.openings.last.channel.emit(utf8.encode('survives'));
    await featureTurns();
    await owner.stopAdmission();
    await owner.cancelPending();
    await owner.closeSessions();
    await owner.drain();
    expect(port.openings.last.channel.closed, true);
    expect(owner.sessionsFor(profile), isEmpty);
    expect(
      engine.screen.map((r) => r.text).join(),
      isNot(contains('survives')),
    );
    expect(port.openings.length, 2);
  });
  test(
    'whole action input cap and lease cancellation never send queued suffix',
    () async {
      final s = await open();
      owner.setVisible(s.sessionId, true);
      final channel = port.openings.single.channel;
      channel.hold = Completer<void>();
      final first = owner.writeConsole(
        ui,
        profile,
        s.sessionId,
        generation: 1,
        leaseToken: s.leaseToken,
        text: 'a' * 65536,
      );
      await featureTurns();
      final over = await owner.writeConsole(
        ui,
        profile,
        s.sessionId,
        generation: 1,
        leaseToken: s.leaseToken,
        text: 'b',
      );
      expect(over.error?.code, FailureCode.resourceExhausted);
      await owner.releaseConsole(
        ui,
        profile,
        s.sessionId,
        generation: 1,
        leaseToken: s.leaseToken!,
      );
      channel.hold!.complete();
      final result = (await first).value!.console as ConsoleActionValue;
      expect(result.status, 'cancelledBeforeSend');
      expect(channel.writes, isEmpty);
    },
  );
  test('raw flood ends only its channel with partial output marker', () async {
    final a = await open();
    await open();
    port.openings.first.channel.emit(List.filled(1048577, 65));
    final failed = owner.historyFor(profile).single;
    expect(failed.sessionId, a.sessionId);
    expect(failed.state, 'error');
    expect(failed.partial, true);
    expect(port.openings.first.channel.closed, true);
    expect(port.openings.last.channel.closed, false);
    expect(
      owner.engine(a.sessionId)!.screen.map((r) => r.text).join(),
      isNot(contains('A')),
    );
  });
  test('rename preserves buffer; endpoint edit clears and profile deletion removes records', () async {
    final s = await open();
    port.openings.single.channel.emit(utf8.encode('private-history'));
    await featureTurns();
    final rename = await h.operations.updateProfile(
      h.actors.ui,
      profile,
      const ProfilePatch(displayName: 'Renamed'),
      expectedRevision: 1,
      mutationId: h.newId(),
    );
    expect(rename.ok, true);
    expect(
      (await owner.readConsole(ui, profile, s.sessionId, generation: 1)).ok,
      true,
    );
    expect(owner.sessionsFor(profile).single.state, 'active');
    final changed = await h.operations.updateProfile(
      h.actors.ui,
      profile,
      const ProfilePatch(host: 'new.invalid'),
      expectedRevision: 2,
      mutationId: h.newId(),
    );
    expect(changed.ok, true);
    expect(
      (await owner.readConsole(
        ui,
        profile,
        s.sessionId,
        generation: 1,
      )).error?.code,
      FailureCode.consoleNotFound,
    );
    final next = await open();
    port.openings.last.channel.end();
    await featureTurns();
    expect(owner.historyFor(profile).single.sessionId, next.sessionId);
    expect(
      (await h.operations.deleteProfile(
        h.actors.ui,
        profile,
        expectedRevision: 3,
        confirmed: true,
      )).ok,
      true,
    );
    expect(
      (await owner.readConsole(
        ui,
        profile,
        next.sessionId,
        generation: 1,
      )).error?.code,
      FailureCode.consoleNotFound,
    );
    expect(owner.sessionsFor(profile), isEmpty);
  });
  test(
    'disconnect releases four slots without affecting other profiles',
    () async {
      final targets = [profile];
      for (var server = 1; server <= 4; server++) {
        targets.add(await h.create(host: '$server.invalid'));
      }
      final originals = [for (var i = 0; i < 4; i++) await open()];
      for (final target in targets.skip(1).take(3)) {
        for (var i = 0; i < 4; i++) {
          expect((await owner.openConsole(ui, target)).ok, true);
          await featureTurns();
        }
      }
      expect(
        (await owner.openConsole(ui, targets.last)).error?.code,
        FailureCode.resourceExhausted,
      );

      port.events.add(ConsoleInvalidation(profile, clear: false));
      expect(owner.liveSessionsFor(profile), isEmpty);
      expect(
        owner.historyFor(profile).map((s) => s.sessionId),
        originals.reversed.map((s) => s.sessionId),
      );
      expect(port.openings.take(4).every((o) => o.channel.closed), true);
      expect(port.openings.skip(4).every((o) => !o.channel.closed), true);
      for (var i = 0; i < 4; i++) {
        await open();
      }
      expect(owner.liveSessionsFor(profile), hasLength(4));
      expect(owner.historyFor(profile), hasLength(4));
      expect(
        (await owner.openConsole(ui, targets.last)).error?.code,
        FailureCode.resourceExhausted,
      );

      port.openings.last.channel.end();
      await featureTurns();
      expect(owner.historyFor(profile), hasLength(4));
      expect(
        (await owner.readConsole(
          ui,
          profile,
          originals.first.sessionId,
          generation: 1,
        )).error?.code,
        FailureCode.consoleNotFound,
      );
      expect((await owner.openConsole(ui, targets.last)).ok, true);
    },
  );

  test('global history evicts by completion order independently of reads and live slots', () async {
    final first = await open(), second = await open();
    port.openings[1].channel.end();
    await featureTurns();
    port.openings[0].channel.end();
    await featureTurns();
    expect(
      (await owner.readConsole(
        ui,
        profile,
        second.sessionId,
        generation: 1,
      )).ok,
      true,
    );

    for (var server = 1; server <= 5; server++) {
      final target = await h.create(host: '$server.invalid');
      for (var i = 0; i < (server == 5 ? 1 : 4); i++) {
        expect((await owner.openConsole(ui, target)).ok, true);
        await featureTurns();
        if (server == 5 && i == 0) break;
        port.openings.last.channel.end();
        await featureTurns();
      }
      if (server == 4) {
        expect(owner.historyFor(profile), isEmpty);
      }
      if (server == 3) {
        expect(owner.historyFor(profile).map((s) => s.sessionId), [
          first.sessionId,
          second.sessionId,
        ]);
      }
      if (server == 5) {
        expect(owner.liveSessionsFor(target), hasLength(1));
      }
    }
  });
}
