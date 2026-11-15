import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/sync/account_view.dart';
import 'package:serverdeck/sync/sync_owner.dart';
import 'package:serverdeck/theme/brand_theme.dart';

import '../fixtures/feature_harness.dart';
import '../fixtures/sync_lifecycle.dart';
import 'device_actions_test.dart' as ui;

Future<LifecycleHarness> prepare(WidgetTester t) async =>
    (await t.runAsync(() async {
      final h = LifecycleHarness();
      await h.setup();
      await h.lifecycle.disconnect(await h.lifecycle.preview());
      h.http.requests.clear();
      h.browser.onOpen = () => h.owner.pause(preserveDeviceAuthorization: true);
      return h;
    }))!;
Future<void> show(WidgetTester t, LifecycleHarness h) async {
  await t.pumpWidget(
    MaterialApp(
      theme: BrandTheme.dark,
      home: Scaffold(
        body: SingleChildScrollView(
          child: SyncAccountView(
            owner: h.owner,
            platform: 'android',
            defaultDeviceName: 'Phone',
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> begin(WidgetTester t, LifecycleHarness h) async {
  await show(t, h);
  await ui.tap(t, 'sync-enable-consent');
  await ui.tap(t, 'sync-login');
  expect(h.owner.view.phase, SyncAuthPhase.paused);
  expect(h.owner.hasPendingLogin, isTrue);
  expect(find.textContaining('Вход приостановлен'), findsOneWidget);
}

void main() {
  testWidgets(
    'own suspended browser flow is cancelled on view close even after login action completed',
    (t) async {
      final h = await prepare(t);
      await begin(t, h);
      await t.pumpWidget(const SizedBox.shrink());
      await t.pumpAndSettle();
      expect(h.owner.hasPendingLogin, isFalse);
      await t.runAsync(() async {
        await h.owner.resume();
        h.local.feature.clock.advance(const Duration(seconds: 10));
        await featureTurns();
      });
      expect(h.count('/v1/device-token'), 0);
      expect(h.local.feature.repository.state.syncState.enabled, isFalse);
      await t.runAsync(h.dispose);
    },
  );
  testWidgets(
    'paused UI exposes explicit cancellation without a new login or data upload',
    (t) async {
      final h = await prepare(t);
      await begin(t, h);
      await ui.tap(t, 'sync-cancel-login');
      expect(h.owner.hasPendingLogin, isFalse);
      await t.runAsync(() async {
        await h.owner.resume();
        h.local.feature.clock.advance(const Duration(seconds: 10));
        await featureTurns();
      });
      await t.pumpAndSettle();
      expect(h.count('/v1/device-token'), 0);
      expect(h.count('/v1/vault/uploads'), 0);
      expect(find.byKey(const ValueKey('sync-login')), findsOneWidget);
      await ui.finish(t, h);
    },
  );
  testWidgets(
    'return from browser completes same flow and closing completed view preserves session',
    (t) async {
      final h = await prepare(t);
      await begin(t, h);
      await t.runAsync(() async {
        await h.owner.resume();
        h.local.feature.clock.advance(const Duration(seconds: 5));
        await featureTurns();
      });
      await t.pumpAndSettle();
      expect(h.owner.view.phase, SyncAuthPhase.signedIn);
      expect(find.text('Вход выполнен.'), findsOneWidget);
      expect(h.count('/v1/device-authorizations'), 1);
      expect(h.count('/v1/device-token'), 1);
      expect(h.count('/v1/vault/uploads'), 0);
      expect(h.browser.pages.length, 1);
      await t.pumpWidget(const SizedBox.shrink());
      await t.pumpAndSettle();
      expect(h.local.feature.repository.state.syncState.enabled, isTrue);
      await t.runAsync(h.dispose);
    },
  );
  testWidgets(
    'owner replacement invalidates suspended flow and its old UI consent',
    (t) async {
      final a = await prepare(t);
      final b = await prepare(t);
      await begin(t, a);
      await show(t, b);
      expect(a.owner.hasPendingLogin, isFalse);
      await t.runAsync(() async {
        await a.owner.resume();
        a.local.feature.clock.advance(const Duration(seconds: 10));
        await featureTurns();
      });
      await t.pumpAndSettle();
      expect(a.count('/v1/device-token'), 0);
      expect(b.count('/v1/device-authorizations'), 0);
      expect(b.owner.hasPendingLogin, isFalse);
      expect(ui.enabled(t, 'sync-login'), isFalse);
      await t.runAsync(a.dispose);
      await ui.finish(t, b);
    },
  );
}
