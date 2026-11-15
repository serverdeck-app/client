import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/runtime/application_settings_view.dart';
import 'package:serverdeck/runtime/platform_ports.dart';
import 'package:serverdeck/sync/sync_owner.dart';
import 'package:serverdeck/sync/sync_runtime.dart';
import 'package:serverdeck/sync/sync_transport.dart';
import 'package:serverdeck/theme/brand_theme.dart';
import 'package:serverdeck/ui/deck_components.dart';

import '../fixtures/feature_harness.dart';
import '../fixtures/sync_apply.dart' show ApplySecrets;
import '../fixtures/sync_lifecycle.dart' show LifecycleBrowser;
import 'device_actions_test.dart' as ui;
import 'transport_test.dart' as wire;

class _Life implements PlatformLifecyclePort {
  @override
  PlatformLifecyclePhase phase = PlatformLifecyclePhase.resumed;
  final controller = StreamController<PlatformLifecyclePhase>.broadcast(
    sync: true,
  );
  @override
  Stream<PlatformLifecyclePhase> get changes => controller.stream;
  void emit(PlatformLifecyclePhase value) {
    phase = value;
    controller.add(value);
  }
}

class _Harness {
  final feature = FeatureHarness(),
      life = _Life(),
      browser = LifecycleBrowser();
  bool fail = false;
  late final wire.FakeHttp http;
  late final SyncRuntime runtime;
  _Harness() {
    http = wire.FakeHttp(
      (request, _) async => switch (request.uri.path) {
        '/v1/device-authorizations' => wire.jsonResponse(
          wire.authorization(),
          status: 201,
        ),
        '/v1/device-token' => wire.jsonResponse(wire.session()),
        _ => throw StateError('Unexpected synthetic HTTP'),
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
      lifecycle: life,
      refreshClock: () async {
        if (fail) throw StateError('synthetic-private');
      },
    );
  }
  Future<void> dispose() async {
    await runtime.dispose();
    await life.controller.close();
    await feature.dispose();
  }
}

Future<void> show(WidgetTester t, _Harness h) async {
  await t.pumpWidget(
    MaterialApp(
      theme: BrandTheme.dark,
      home: Scaffold(
        body: ApplicationSettingsView(sync: h.runtime, platform: 'android'),
      ),
    ),
  );
  await t.runAsync(featureTurns);
  await t.pumpAndSettle();
}

Future<void> finish(WidgetTester t, _Harness h) async {
  await t.pumpWidget(const SizedBox.shrink());
  await t.runAsync(h.dispose);
}

void main() {
  testWidgets(
    'mobile account settings survive browser pause and clock failure without cancelling own flow',
    (t) async {
      final h = (await t.runAsync(() async {
        final value = _Harness();
        await value.runtime.initialize();
        return value;
      }))!;
      await show(t, h);
      expect(find.text('Обновления'), findsNothing);
      expect(find.text('MCP'), findsNothing);
      await t.enterText(
        find.byKey(const ValueKey('sync-service-origin')),
        'https://sync.test',
      );
      await ui.tap(t, 'sync-enable-consent');
      h.browser.onOpen = () => h.life.emit(PlatformLifecyclePhase.paused);
      await ui.tap(t, 'sync-login');
      expect(h.runtime.owner.hasPendingLogin, isTrue);
      h.fail = true;
      await t.runAsync(() async {
        h.life.emit(PlatformLifecyclePhase.resumed);
        await featureTurns();
      });
      await t.pumpAndSettle();
      expect(find.text('Повторить синхронизацию'), findsOneWidget);
      expect(h.runtime.owner.hasPendingLogin, isTrue);
      expect(find.byKey(const ValueKey('sync-cancel-login')), findsOneWidget);
      h.fail = false;
      final button = t.widget<DeckButton>(
        find.widgetWithText(DeckButton, 'Повторить синхронизацию'),
      );
      await t.runAsync(() async {
        unawaited(Future<void>.sync(button.onPressed!));
        await featureTurns();
        h.feature.clock.advance(const Duration(seconds: 5));
        await featureTurns();
      });
      await t.pumpAndSettle();
      expect(h.runtime.owner.view.phase, SyncAuthPhase.signedIn);
      expect(
        h.http.requests.where((r) => r.uri.path == '/v1/device-token').length,
        1,
      );
      await finish(t, h);
      expect(h.feature.repository.state.syncState.enabled, isTrue);
    },
  );
  testWidgets(
    'initial sync clock failure exposes retry and mounts account only after recovery',
    (t) async {
      final h = (await t.runAsync(() async {
        final value = _Harness()..fail = true;
        await value.runtime.initialize();
        return value;
      }))!;
      await show(t, h);
      expect(find.byKey(const ValueKey('sync-login')), findsNothing);
      expect(find.text('Повторить синхронизацию'), findsOneWidget);
      expect(find.textContaining('synthetic-private'), findsNothing);
      h.fail = false;
      final button = t.widget<DeckButton>(
        find.widgetWithText(DeckButton, 'Повторить синхронизацию'),
      );
      await t.runAsync(() async {
        unawaited(Future<void>.sync(button.onPressed!));
        await featureTurns();
      });
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('sync-login')), findsOneWidget);
      expect(h.http.requests, isEmpty);
      await finish(t, h);
    },
  );
}
