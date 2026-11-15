import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serverdeck/sync/account_view.dart';
import 'package:serverdeck/sync/sync_http.dart';
import 'package:serverdeck/sync/sync_owner.dart';
import 'package:serverdeck/sync/sync_wire.dart';
import 'package:serverdeck/theme/brand_theme.dart';
import 'package:serverdeck/ui/deck_components.dart';

import 'device_auth_test.dart' as auth;
import 'transport_test.dart' as wire;

Future<void> show(
  WidgetTester tester,
  auth.Harness h, {
  SyncOriginNormalizer? normalize,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: BrandTheme.dark,
      home: Scaffold(
        body: SingleChildScrollView(
          child: SyncAccountView(
            owner: h.owner,
            platform: 'windows',
            defaultDeviceName: 'Рабочий компьютер',
            normalizeOrigin: normalize ?? SyncServiceOrigin.new,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder key(String value) => find.byKey(ValueKey(value));
Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> draft(WidgetTester tester) async {
  await tester.enterText(key('sync-service-origin'), wire.origin.value);
  await tester.pump();
  await tap(tester, key('sync-enable-consent'));
}

Future<void> finish(WidgetTester tester, auth.Harness h) async {
  await tester.pumpWidget(const SizedBox.shrink());
  h.owner.dispose();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'disabled account remains local; editing address starts no requests',
    (tester) async {
      final h = auth.Harness(FakeAsync());
      await show(tester, h);
      expect(find.textContaining('Синхронизация выключена'), findsOneWidget);
      expect(tester.widget<DeckButton>(key('sync-login')).onPressed, isNull);
      await tester.enterText(key('sync-service-origin'), wire.origin.value);
      await tester.pump();
      expect(h.http.requests, isEmpty);
      expect(h.browser.pages, isEmpty);
      expect(tester.widget<DeckButton>(key('sync-login')).onPressed, isNull);
      await tap(tester, key('sync-enable-consent'));
      expect(tester.widget<DeckButton>(key('sync-login')).onPressed, isNotNull);
      expect(h.http.requests, isEmpty);
      await finish(tester, h);
    },
  );

  testWidgets('invalid origin and device name reject before browser or HTTP', (
    tester,
  ) async {
    final h = auth.Harness(FakeAsync());
    await show(tester, h);
    await tap(tester, key('sync-enable-consent'));
    for (final value in [
      'http://sync.example.test',
      'https://sync.example.test/path',
    ]) {
      await tester.enterText(key('sync-service-origin'), value);
      await tester.pump();
      expect(tester.widget<DeckButton>(key('sync-login')).onPressed, isNull);
    }
    await tester.enterText(key('sync-service-origin'), wire.origin.value);
    await tester.enterText(key('sync-device-name'), 'name\u200bhidden');
    await tester.pump();
    expect(tester.widget<DeckButton>(key('sync-login')).onPressed, isNull);
    await tester.enterText(key('sync-device-name'), '');
    await tester.pump();
    expect(tester.widget<DeckButton>(key('sync-login')).onPressed, isNull);
    expect(h.http.requests, isEmpty);
    expect(h.browser.pages, isEmpty);
    await finish(tester, h);
  });

  testWidgets(
    'login consumes normalized origin and shows only public approval code',
    (tester) async {
      final h = auth.Harness(FakeAsync());
      await show(
        tester,
        h,
        normalize: (value) {
          if (value == 'HTTPS://SYNC.EXAMPLE.TEST/') return wire.origin;
          return SyncServiceOrigin(value);
        },
      );
      await tester.enterText(
        key('sync-service-origin'),
        'HTTPS://SYNC.EXAMPLE.TEST/',
      );
      await tap(tester, key('sync-enable-consent'));
      await tap(tester, key('sync-login'));
      expect(h.owner.view.phase, SyncAuthPhase.awaitingApproval);
      expect(
        find.text(wire.authorization()['user_code']! as String),
        findsOneWidget,
      );
      expect(h.browser.pages.single.origin, wire.origin.value);
      expect(h.http.requests.single.uri.origin, wire.origin.value);
      expect(find.textContaining(wire.token(1)), findsNothing);
      expect(find.textContaining(wire.token(2)), findsNothing);
      expect(find.textContaining('SD1-'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(h.owner.view.phase, SyncAuthPhase.signedIn);
      expect(find.text('Шифрование и восстановление'), findsOneWidget);
      expect(
        find.text(wire.authorization()['user_code']! as String),
        findsNothing,
      );
      expect(find.textContaining(wire.token(1)), findsNothing);
      expect(h.count('/v1/vault/uploads'), 0);
      await finish(tester, h);
    },
  );

  testWidgets('explicit cancel invalidates polling and late token response', (
    tester,
  ) async {
    final h = auth.Harness(FakeAsync());
    final response = Completer<SyncHttpResponse?>();
    h.handler = (request) async =>
        request.uri.path == '/v1/device-token' ? response.future : null;
    await show(tester, h);
    await draft(tester);
    await tap(tester, key('sync-login'));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    await tap(tester, key('sync-cancel-login'));
    response.complete(wire.jsonResponse(wire.session()));
    await tester.pumpAndSettle();
    expect(h.domain.state.syncState.enabled, isFalse);
    expect(h.domain.state.syncSecrets.protectedAccess, isNull);
    expect(
      find.text(wire.authorization()['user_code']! as String),
      findsNothing,
    );
    await finish(tester, h);
  });

  testWidgets(
    'unmount and owner replacement cancel only its unfinished login',
    (tester) async {
      final h = auth.Harness(FakeAsync());
      await show(tester, h);
      await draft(tester);
      await tap(tester, key('sync-login'));
      final next = auth.Harness(FakeAsync());
      await show(tester, next);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(h.count('/v1/device-token'), 0);
      expect(h.domain.state.syncState.enabled, isFalse);
      expect(find.textContaining('Синхронизация выключена'), findsOneWidget);
      await draft(tester);
      await tap(tester, key('sync-login'));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      expect(next.count('/v1/device-token'), 0);
      h.owner.dispose();
      next.owner.dispose();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'browser failure has safe local-data message without raw exception',
    (tester) async {
      final h = auth.Harness(FakeAsync());
      h.browser.fail = true;
      await show(tester, h);
      await draft(tester);
      await tap(tester, key('sync-login'));
      expect(h.owner.view.phase, SyncAuthPhase.loginRequired);
      expect(find.textContaining('Локальные данные сохранены'), findsWidgets);
      expect(find.textContaining('synthetic secret sentinel'), findsNothing);
      expect(h.domain.state.syncState.enabled, isFalse);
      await finish(tester, h);
    },
  );

  testWidgets('closing during protected persistence cannot bind a late login', (
    tester,
  ) async {
    final h = auth.Harness(FakeAsync());
    await show(tester, h);
    await draft(tester);
    await tap(tester, key('sync-login'));
    h.secrets.protecting = Completer<void>();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(h.owner.view.phase, SyncAuthPhase.protecting);
    await tester.pumpWidget(const SizedBox.shrink());
    h.secrets.protecting!.complete();
    await tester.pumpAndSettle();
    expect(h.domain.state.syncState.enabled, isFalse);
    expect(h.domain.state.syncSecrets.protectedAccess, isNull);
    h.owner.dispose();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'synchronous owner replacement cancels login before its first native continuation',
    (tester) async {
      final h = auth.Harness(FakeAsync());
      await show(tester, h);
      await draft(tester);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final next = auth.Harness(FakeAsync());
      final action = tester.widget<DeckButton>(key('sync-login')).onPressed!();
      expect(h.owner.view.phase, SyncAuthPhase.disabled);
      // Exercise the framework owner-update boundary synchronously, before pumping
      // microtasks: beginLogin is waiting for its first restoreSession continuation.
      final element =
          tester.element(find.byType(SyncAccountView)) as StatefulElement;
      element.owner!.buildScope(
        element,
        () => element.update(
          SyncAccountView(
            owner: next.owner,
            platform: 'windows',
            defaultDeviceName: 'Другое устройство',
            normalizeOrigin: SyncServiceOrigin.new,
          ),
        ),
      );
      if (action is Future<void>) await action;
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(h.http.requests, isEmpty);
      expect(h.browser.pages, isEmpty);
      expect(h.count('/v1/device-token'), 0);
      expect(h.domain.state.syncState.enabled, isFalse);
      expect(h.domain.state.syncSecrets.protectedAccess, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      h.owner.dispose();
      next.owner.dispose();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'completed login survives view close and bound service is read-only on reauthorization',
    (tester) async {
      final h = auth.Harness(FakeAsync());
      await show(tester, h);
      await draft(tester);
      await tap(tester, key('sync-login'));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(h.owner.view.phase, SyncAuthPhase.signedIn);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(h.domain.state.syncState.enabled, isTrue);
      expect(h.owner.view.phase, SyncAuthPhase.signedIn);
      h.clock.elapse(const Duration(seconds: 901));
      h.handler = (request) async {
        if (request.uri.path == '/v1/token/refresh')
          throw StateError('private-refresh-sentinel');
        return null;
      };
      await expectLater(h.owner.accessToken(), throwsA(anything));
      await show(tester, h);
      expect(h.owner.view.phase, SyncAuthPhase.loginRequired);
      expect(
        tester.widget<DeckTextField>(key('sync-service-origin')).enabled,
        isFalse,
      );
      expect(
        tester
            .widget<DeckTextField>(key('sync-service-origin'))
            .controller!
            .text,
        wire.origin.value,
      );
      expect(find.textContaining('private-refresh-sentinel'), findsNothing);
      await finish(tester, h);
    },
  );
}
