import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/runtime/platform_ports.dart';
import 'package:serverdeck/sync/sync_owner.dart';
import 'package:serverdeck/sync/sync_runtime.dart';
import 'package:serverdeck/sync/sync_transport.dart';

import '../fixtures/feature_harness.dart';
import '../fixtures/sync_apply.dart' show ApplySecrets;
import '../fixtures/sync_lifecycle.dart' show LifecycleBrowser;
import 'transport_test.dart' as wire;

class _Foreground implements PlatformLifecyclePort {
  @override
  PlatformLifecyclePhase phase = PlatformLifecyclePhase.resumed;
  final controller = StreamController<PlatformLifecyclePhase>.broadcast(
    sync: true,
  );
  @override
  Stream<PlatformLifecyclePhase> get changes => controller.stream;
  void emit(PlatformLifecyclePhase next) {
    phase = next;
    controller.add(next);
  }
}

void main() {
  late FeatureHarness feature;
  late _Foreground foreground;
  late LifecycleBrowser browser;
  late wire.FakeHttp http;
  late SyncRuntime runtime;
  var samples = 0, fail = false;
  Future<void> Function()? sampling;
  setUp(() {
    feature = FeatureHarness();
    foreground = _Foreground();
    browser = LifecycleBrowser();
    samples = 0;
    fail = false;
    sampling = null;
    http = wire.FakeHttp(
      (request, _) async => switch (request.uri.path) {
        '/v1/device-authorizations' => wire.jsonResponse(
          wire.authorization(),
          status: 201,
        ),
        '/v1/device-token' => wire.jsonResponse(wire.session()),
        _ => throw StateError('Unexpected synthetic endpoint'),
      },
    );
    runtime = SyncRuntime(
      domain: feature.repository,
      gate: feature.gate,
      actor: feature.actors.owner,
      connections: feature.connections,
      secrets: ApplySecrets(),
      inspector: feature.parser,
      browser: browser,
      availableStorageBytes: () async => 100 * 1024 * 1024 * 1024,
      newId: feature.newId,
      utcNow: feature.clock.now,
      monotonicMicros: () => feature.clock.elapsed.inMicroseconds,
      schedule: feature.clock.schedule,
      transport: (origin) => SyncTransport(origin: origin, http: http),
      lifecycle: foreground,
      refreshClock: () async {
        samples++;
        if (sampling != null) await sampling!();
        if (fail) throw StateError('synthetic-private-clock-error');
      },
    );
  });
  tearDown(() async {
    await runtime.dispose();
    await foreground.controller.close();
    await feature.dispose();
  });
  test(
    'one shared pipeline starts only after clock and never auto starts login',
    () async {
      expect(runtime.owner.view.phase, SyncAuthPhase.paused);
      expect(identical(runtime.repository.domain, feature.repository), isTrue);
      expect(
        identical(runtime.transfer.repository, feature.repository),
        isTrue,
      );
      expect(identical(runtime.apply.connections, feature.connections), isTrue);
      expect(identical(runtime.owner.cycle, runtime.cycle), isTrue);
      expect(identical(runtime.owner.lifecycle, runtime.account), isTrue);
      await runtime.initialize();
      expect(samples, 1);
      expect(runtime.owner.view.phase, SyncAuthPhase.disabled);
      expect(http.requests, isEmpty);
    },
  );
  test('clock failure pauses sync but local commands remain available and retry recovers', () async {
    fail = true;
    await runtime.initialize();
    expect(runtime.foregroundError, 'SYNC_RESUME_UNAVAILABLE');
    expect(runtime.owner.view.phase, SyncAuthPhase.paused);
    expect(
      (await feature.operations.listProfiles(feature.actors.ui)).error,
      isNull,
    );
    fail = false;
    await runtime.retryForeground();
    expect(runtime.foregroundError, isNull);
    expect(runtime.owner.view.phase, SyncAuthPhase.disabled);
    expect(samples, 2);
    expect(http.requests, isEmpty);
  });
  test('real owner browser handoff follows injected foreground with zero paused polling', () async {
    await runtime.initialize();
    browser.onOpen = () => foreground.emit(PlatformLifecyclePhase.paused);
    await runtime.owner.beginLogin(
      origin: wire.origin,
      platform: 'android',
      name: 'Phone',
    );
    expect(runtime.owner.view.phase, SyncAuthPhase.paused);
    expect(runtime.owner.hasPendingLogin, isTrue);
    feature.clock.advance(const Duration(seconds: 30));
    await featureTurns();
    expect(
      http.requests.where((r) => r.uri.path == '/v1/device-token'),
      isEmpty,
    );
    foreground.emit(PlatformLifecyclePhase.resumed);
    await featureTurns();
    expect(samples, 2);
    feature.clock.advance(Duration.zero);
    await featureTurns();
    expect(runtime.owner.view.phase, SyncAuthPhase.signedIn);
    expect(
      http.requests.where((r) => r.uri.path == '/v1/device-token').length,
      1,
    );
  });
  test('foreground resampling observes original approval expiry', () async {
    await runtime.initialize();
    browser.onOpen = () => foreground.emit(PlatformLifecyclePhase.paused);
    await runtime.owner.beginLogin(
      origin: wire.origin,
      platform: 'android',
      name: 'Phone',
    );
    feature.clock.advance(const Duration(seconds: 601));
    foreground.emit(PlatformLifecyclePhase.resumed);
    await featureTurns();
    expect(runtime.owner.hasPendingLogin, isFalse);
    expect(runtime.owner.view.errorCode, 'expired_token');
    expect(
      http.requests.where((r) => r.uri.path == '/v1/device-token'),
      isEmpty,
    );
  });
  test('new foreground waits for old calibration then samples again and surfaces latest failure', () async {
    final held = Completer<void>();
    sampling = () async {
      if (samples == 1) await held.future;
    };
    final opening = runtime.initialize();
    foreground.emit(PlatformLifecyclePhase.paused);
    foreground.emit(PlatformLifecyclePhase.resumed);
    fail = true;
    held.complete();
    await opening;
    expect(samples, 2);
    expect(runtime.foregroundError, 'SYNC_RESUME_UNAVAILABLE');
    expect(runtime.owner.view.phase, SyncAuthPhase.paused);
  });
  test(
    'stop during calibration rejects late admission and drains same operation',
    () async {
      final held = Completer<void>();
      sampling = () => held.future;
      final opening = runtime.initialize();
      await runtime.stopAdmission();
      held.complete();
      await opening;
      await runtime.drain();
      expect(runtime.owner.view.phase, SyncAuthPhase.paused);
      await runtime.retryForeground();
      expect(samples, 1);
      expect(http.requests, isEmpty);
    },
  );
}
